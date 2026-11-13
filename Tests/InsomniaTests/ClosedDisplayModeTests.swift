import XCTest
@testable import Insomnia

/// A MacBook used closed on an external display (issue #97): a session
/// takes that lid as open.
@MainActor
final class ClosedDisplayModeTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func atDesk() {
        h.clamshell.closed = true
        h.clamshell.atDesk = true
    }

    func testASessionStartedAtADeskRunsItsCountdown() async throws {
        atDesk()
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        XCTAssertTrue(m.countdownTimerArmed)
        XCTAssertFalse(m.lidTakenAsClosed)
    }

    func testASessionStartedUnderALidWithNoDisplayStaysPaused() async throws {
        h.clamshell.closed = true
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertFalse(m.countdownTimerArmed)
        XCTAssertTrue(m.lidTakenAsClosed)
    }

    func testARelaunchAtADeskWithNothingToUndoRunsTheCountdown() async throws {
        atDesk()
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNotNil(m.session)
        XCTAssertTrue(m.countdownTimerArmed)
        XCTAssertFalse(m.lidTakenAsClosed)
    }

    /// The lid closed in a bag, then a display was plugged in: the lid stays
    /// closed until it opens, so the built-in panel is not written while
    /// it is shut.
    func testARelaunchAtADeskKeepsLidActionsFromAClose() async throws {
        atDesk()
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5)]
        st.savedDisplayBrightness = 0.8
        try h.store.saveState(st)
        h.procs.stoppedNow = [111]
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNotNil(m.session)
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.display.sets, [])
        XCTAssertFalse(m.countdownTimerArmed)
        XCTAssertTrue(m.lidTakenAsClosed)
    }
}
