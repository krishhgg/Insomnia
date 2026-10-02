import XCTest
@testable import Insomnia

@MainActor
final class ReconcileTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    // (a) expired session on disk -> sleep restored, pids resumed, low power cleared, files cleared
    func testExpiredSessionIsFullyRestored() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.lowPowerSetByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5), FrozenProcess(pid: 222, startedAt: 6)]
        st.dockerFrozen = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertNil(m.session)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(m.state, RuntimeState.clean)
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"))
        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"))
        XCTAssertEqual(h.procs.resumed, [[111, 222]])
        // A clean end needs no launchd work; the agent stays loaded as installed.
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    // (b) valid session -> agent confirmed, disablesleep re-applied idempotently, timer rescheduled
    func testValidSessionIsReappliedAndRearmed() async throws {
        let now = h.clock.now
        let s = Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(2 * 3600 + 14 * 60 + 30))
        try h.store.saveSession(s)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.session, s)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertEqual(m.scheduledDeadline, s.endsAt)
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertEqual(m.remainingText, "2h 14m")
        XCTAssertEqual(try h.store.loadSession(), s)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
    }

    // (b') valid session whose state.json was lost -> state rewritten before pmset
    func testValidSessionWithMissingStateMarksSleepDisabledByUs() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(3600)))
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
    }

    // (c) no session but pmset reports SleepDisabled -> set to 0
    func testNoSessionButSleepDisabledIsCleared() async throws {
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, ["pmset -g", "disablesleep 0"])
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertNil(try h.store.loadSession())
    }

    // (c') no session, clean state, pmset clean -> nothing but the check
    func testNoSessionCleanIsNoop() async throws {
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(h.guardFake.calls, ["pmset -g"])
        XCTAssertEqual(h.procs.resumed, [])
    }

    // (d) savedOutputVolume / savedMuted are restored through AudioControlling
    // and cleared; if the restore fails they stay on disk for the next run.
    func testSavedVolumeIsRestoredAndCleared() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-1)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.savedOutputVolume = 0.6
        st.savedMuted = false
        try h.store.saveState(st)

        let m = h.makeManager()
        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.sleepDisabledByUs)
        XCTAssertNil(after.savedOutputVolume)
        XCTAssertNil(after.savedMuted)
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.volume, 0.6)
        XCTAssertEqual(h.audio.applied.first?.muted, false)
        XCTAssertEqual(m.state, after)
    }

    func testSavedVolumeIsPreservedWhenRestoreFails() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-1)))
        var st = RuntimeState()
        st.savedOutputVolume = 0.6
        st.savedMuted = true
        try h.store.saveState(st)
        h.audio.throwOnApply = true

        let m = h.makeManager()
        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedOutputVolume, 0.6)
        XCTAssertEqual(after.savedMuted, true)
        XCTAssertEqual(m.state, after)
    }

    // Start ordering: journal first, then pmset. A pmset failure is
    // ambiguous (the setting may have been applied), so the start is undone
    // from the journal; once the undo is confirmed nothing remains.
    func testStartUndoesFromJournalWhenPmsetFails() async throws {
        h.guardFake.throwOn = ["disablesleep 1"]
        let m = h.makeManager()
        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(m.state, RuntimeState.clean)
        // The agent was confirmed before pmset; it stays loaded (it is idle
        // with no session and a clean journal).
        XCTAssertEqual(h.backstop.arms, 1)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("password is required"), err)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
    }

    func testStartFailsBeforeDisablingSleepWhenBackstopCannotBeArmed() async throws {
        h.backstop.failArm = true
        let m = h.makeManager()
        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.guardFake.calls, [], "sleep must never be disabled without a backstop")
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("backstop"), err)
    }

    func testExtendKeepsOldDeadlineWhenBackstopCannotBeConfirmed() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let original = try XCTUnwrap(m.session)
        h.backstop.failArm = true
        await m.extend(by: 3600)

        XCTAssertEqual(m.session, original)
        XCTAssertEqual(try h.store.loadSession(), original)
        XCTAssertEqual(m.scheduledDeadline, original.endsAt)
        XCTAssertNotNil(m.lastError)
    }

    func testStartWritesJournalThenDisablesSleep() async throws {
        let m = h.makeManager()
        await m.start(duration: 30 * 60)

        let s = try XCTUnwrap(m.session)
        XCTAssertEqual(s.startedAt, h.clock.now)
        XCTAssertEqual(s.endsAt, h.clock.now.addingTimeInterval(1800))
        XCTAssertEqual(try h.store.loadSession(), s)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertEqual(m.scheduledDeadline, s.endsAt)
        XCTAssertEqual(m.remainingText, "30m")
        XCTAssertNil(m.lastError)
    }

    func testStartClampsToMaxDuration() async throws {
        let m = h.makeManager()
        await m.start(duration: 365 * 24 * 3600)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(m.config.maxDuration))
    }

    func testExtendRewritesJournalAndReschedules() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.clock.advance(600)
        await m.extend(by: 3600)
        let s = try XCTUnwrap(m.session)
        XCTAssertEqual(s.endsAt, h.clock.now.addingTimeInterval(6600))
        XCTAssertEqual(s.extensions, [3600])
        XCTAssertEqual(try h.store.loadSession(), s)
        XCTAssertEqual(h.backstop.arms, 2)
        XCTAssertEqual(m.remainingText, "1h 50m")
    }

    func testEndRestoresFromDiskAndLeavesAgentLoaded() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let outcome = await m.end(reason: .user)
        XCTAssertEqual(outcome, .restored)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertEqual(m.remainingText, "")
        XCTAssertNil(m.scheduledDeadline)
    }

    func testEndKeepsFlagWhenRestoreFailsSoBackstopRetries() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        let outcome = await m.end(reason: .quit)
        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNotNil(m.lastError)
        // The failed end re-confirms the agent so something retries the journal.
        XCTAssertEqual(h.backstop.arms, 2)
    }

    func testCountdownPauseResume() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertEqual(m.remainingText, "1h")
        m.pauseCountdown()
        h.clock.advance(120)
        XCTAssertEqual(m.remainingText, "1h")
        m.resumeCountdown()
        XCTAssertEqual(m.remainingText, "58m")
    }

    func testDeadlineTimerFiresEnd() async throws {
        // Use the real clock for this one so the Timer can actually fire.
        let real = Harness(now: Date())
        defer { real.home.destroy() }
        let m = SessionManager(
            paths: real.home.paths,
            sleepGuard: real.guardFake,
            processControl: real.procs,
            backstop: real.backstop,
            clock: { Date() }
        )
        // Bypass clamping by writing a near-expired session and reconciling.
        try real.store.saveSession(Session(startedAt: Date(), endsAt: Date().addingTimeInterval(1.5)))
        await m.reconcile()
        XCTAssertTrue(m.isActive)
        let deadline = Date().addingTimeInterval(8)
        while m.isActive && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try real.store.loadSession())
        XCTAssertEqual(real.guardFake.calls.last, "disablesleep 0")
    }

    // MARK: Unreadable session.json

    private var movedAsideSessions: [String] {
        get throws {
            try FileManager.default.contentsOfDirectory(atPath: h.home.paths.appSupport.path)
                .filter { $0.hasPrefix(Paths.unreadableSessionPrefix) }.sorted()
        }
    }

    /// A session.json that is not a session says nothing about what to undo
    /// (the journal does). It is renamed to a timestamped sibling under the
    /// lock, the user is told where, and reconcile goes on as with no
    /// session: the pmset check still runs.
    func testUnreadableSessionIsMovedAsideAndReported() async throws {
        let bytes = Data("not json".utf8)
        try bytes.write(to: h.home.paths.sessionFile)
        try h.store.saveState(RuntimeState())

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.sessionFile.path), "session.json left in place")
        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
        let moved = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        XCTAssertEqual(try Data(contentsOf: moved), bytes, "the bytes are kept as they were")
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, ["pmset -g"])
        let posts = h.notifier.posts.filter { $0.title == SessionManager.sessionFileTitle }
        XCTAssertEqual(posts.count, 1, "\(h.notifier.posts)")
        XCTAssertTrue(posts.first?.body.contains(moved.path) == true, posts.first?.body ?? "")
        XCTAssertNil(m.lastError)

        // Next launch: no session file, nothing new moved, no second notice.
        await m.reconcile()
        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.sessionFileTitle }.count, 1)
    }

    /// With a dirty journal the file is moved aside first, then the journal
    /// is restored exactly as it would be with no session file.
    func testUnreadableSessionWithDirtyJournalIsMovedAsideAndJournalRestored() async throws {
        try Data("{\"endsAt\": 12}".utf8).write(to: h.home.paths.sessionFile)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.sessionFile.path))
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        let moveNotice = h.notifier.posts.filter { $0.title == SessionManager.sessionFileTitle }
        XCTAssertEqual(moveNotice.count, 1)
        XCTAssertFalse(moveNotice.first?.body.lowercased().contains("restored") == true,
                       "the move notice must not speak for the restore, which has its own outcome: \(moveNotice)")
    }

    /// A session.json that exists but cannot be read at all (here: it is a
    /// directory) may be a valid session. Nothing is moved, decided or
    /// undone; the user is told, and the next launch retries.
    func testSessionThatCannotBeReadAtAllIsLeftInPlaceAndNothingIsDecided() async throws {
        try FileManager.default.createDirectory(at: h.home.paths.sessionFile, withIntermediateDirectories: true)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertTrue(FileManager.default.fileExists(atPath: h.home.paths.sessionFile.path), "session.json was moved or removed")
        XCTAssertEqual(try movedAsideSessions, [])
        XCTAssertEqual(h.guardFake.calls, [], "something was undone or checked from a session that could not be read")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), st, "the journal was changed")
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("could not be read"), m.lastError ?? "")
        let posts = h.notifier.posts.filter { $0.title == SessionManager.sessionFileTitle }
        XCTAssertEqual(posts.count, 1, "\(h.notifier.posts)")
        XCTAssertTrue(posts.first?.body.contains("left in place") == true, posts.first?.body ?? "")
    }

    /// An earlier moved-aside file with the same stamp is never overwritten;
    /// the new one gets a -1 suffix.
    func testUnreadableSessionNeverOverwritesAnEarlierMovedAsideFile() async throws {
        let earlier = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        try FileManager.default.createDirectory(at: h.home.paths.appSupport, withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: earlier)
        try Data("later".utf8).write(to: h.home.paths.sessionFile)

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(try movedAsideSessions, [
            "session.json.unreadable-20270115T080000Z",
            "session.json.unreadable-20270115T080000Z-1",
        ])
        XCTAssertEqual(try String(contentsOf: earlier, encoding: .utf8), "earlier")
        let later = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z-1")
        XCTAssertEqual(try String(contentsOf: later, encoding: .utf8), "later")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("20270115T080000Z-1") == true, h.notifier.posts.last?.body ?? "")
    }

    /// An unreadable state.json refuses every transaction, reconcile
    /// included, so an unreadable session.json beside it is not moved
    /// either: nothing of that pair is touched until a person looks.
    func testUnreadableSessionStaysWhenTheJournalIsUnreadable() async throws {
        let session = Data("not json".utf8)
        try session.write(to: h.home.paths.sessionFile)
        try Data("{not json".utf8).write(to: h.home.paths.stateFile)

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), session)
        XCTAssertEqual(try movedAsideSessions, [])
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.sessionFileTitle }, "\(h.notifier.posts)")
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.journalTitle }.count, 1)
    }
}
