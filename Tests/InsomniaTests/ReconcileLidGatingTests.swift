import XCTest
@testable import Insomnia

/// Spec section 8 step 2: lid-close actions still on disk are undone at
/// reconcile only when the lid is open.
@MainActor
final class ReconcileLidGatingTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func seedValidSessionWithLidActions() throws -> Session {
        let now = h.clock.now
        let s = Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600))
        try h.store.saveSession(s)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5), FrozenProcess(pid: 222, startedAt: 6)]
        st.dockerFrozen = true
        st.savedOutputVolume = 0.4
        st.savedMuted = false
        st.savedDisplayBrightness = 0.8
        st.savedKeyboardBrightness = 0.3
        try h.store.saveState(st)
        return s
    }

    func testLidClosedKeepsFrozenPids() async throws {
        let s = try seedValidSessionWithLidActions()
        h.clamshell.closed = true
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.session, s)
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.wakes, 0)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenPids, [111, 222])
        XCTAssertEqual(after.frozenProcesses.map { $0.identity?.startedAt }, [5, 6], "identity lost across reconcile")
        XCTAssertTrue(after.dockerFrozen)
        XCTAssertEqual(after.savedOutputVolume, 0.4)
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.savedKeyboardBrightness, 0.3)
        XCTAssertEqual(m.state, after)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
    }

    /// A journal holding only saved brightness (no freeze, no audio) is
    /// still a lid-close action: kept while the lid is shut.
    func testLidClosedKeepsSavedBrightnessAlone() async throws {
        let now = h.clock.now
        let s = Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600))
        try h.store.saveSession(s)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.savedDisplayBrightness = 0.8
        st.savedKeyboardBrightness = 0.3
        try h.store.saveState(st)
        h.clamshell.closed = true
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.session, s)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.savedKeyboardBrightness, 0.3)
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("keeping lid-close actions"), log)
    }

    func testLidOpenResumesFrozenPidsAndRestoresAudio() async throws {
        let s = try seedValidSessionWithLidActions()
        h.clamshell.closed = false
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.session, s)
        XCTAssertEqual(h.procs.resumed, [[111, 222]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.volume, 0.4)
        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(h.keyboard.sets, [0.3])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenPids, [])
        XCTAssertFalse(after.dockerFrozen)
        XCTAssertNil(after.savedOutputVolume)
        XCTAssertNil(after.savedMuted)
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertNil(after.savedKeyboardBrightness)
        XCTAssertTrue(after.sleepDisabledByUs)
        XCTAssertEqual(m.state, after)
    }

    func testUnknownLidStateKeepsActions() async throws {
        _ = try seedValidSessionWithLidActions()
        h.clamshell.closed = nil
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [111, 222])
    }

    func testExpiredSessionRestoresRegardlessOfLid() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-1)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5)]
        try h.store.saveState(st)
        h.clamshell.closed = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(h.procs.resumed, [[111]])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session restored")
    }

    func testEndPostsNotificationWithReason() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        await m.end(reason: .user)
        XCTAssertEqual(h.notifier.posts.count, 1)
        XCTAssertEqual(h.notifier.posts[0].title, "Session ended")
        XCTAssertTrue(h.notifier.posts[0].body.contains("Ended by you"))
    }

    /// A session that ends while the lid is shut must not leave the 1 Hz
    /// redraw running when the lid reopens; there is nothing to draw and the
    /// timer would wake the run loop every second indefinitely.
    func testLidOpenAfterSessionEndedLeavesNoCountdownTimer() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertTrue(m.countdownTimerArmed)

        m.pauseCountdown()
        XCTAssertFalse(m.countdownTimerArmed)

        await m.end(reason: .timer)
        m.resumeCountdown()

        XCTAssertFalse(m.countdownTimerArmed)
        XCTAssertEqual(m.countdownText, "")
    }

    func testLidOpenDuringAnActiveSessionRearmsTheCountdown() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        m.pauseCountdown()
        m.resumeCountdown()
        XCTAssertTrue(m.countdownTimerArmed)
    }
}
