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

    // (c) no session, no journal entry, but pmset reports SleepDisabled:
    // something else set it. Left alone, reported once with the command to
    // undo it; an Insomnia session's end still sets it to 0 as always.
    func testNoSessionButSleepDisabledIsLeftAloneAndReported() async throws {
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, ["pmset -g"], "a SleepDisabled bit Insomnia did not set was cleared")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.notifier.posts.map(\.title), [SessionManager.foreignSleepTitle])
        XCTAssertTrue(h.notifier.posts[0].body.contains(SessionManager.foreignSleepCommand), h.notifier.posts[0].body)
        XCTAssertTrue(try XCTUnwrap(m.foreignSleepWarning).contains(SessionManager.foreignSleepCommand), m.foreignSleepWarning ?? "")
        XCTAssertNil(m.lastError, "a bit someone else set is not an Insomnia failure")

        // A second reconcile keeps the warning line but does not post again.
        await m.reconcile()
        XCTAssertEqual(h.notifier.posts.count, 1)
        XCTAssertEqual(m.foreignSleepWarning, SessionManager.foreignSleepLine)

        // Insomnia's own session clears the line, and its end sets the bit to 0.
        await m.start(duration: 3600)
        XCTAssertNil(m.foreignSleepWarning)
        XCTAssertNil(m.lastError)
        _ = await m.end(reason: .user)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    // (c4) step 1 fails to clear Low Power Mode and step 3 finds a foreign
    // SleepDisabled bit in the same reconcile. Both stay visible: the
    // restore failure in `lastError`, the bit on its own line.
    func testForeignSleepLineDoesNotReplaceARestoreError() async throws {
        var st = RuntimeState()
        st.lowPowerSetByUs = true
        try h.store.saveState(st)
        h.guardFake.lowPowerOn = true
        h.guardFake.throwOn = ["lowpowermode 0"]
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(h.guardFake.calls, ["lowpowermode 0", "pmset -g"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("could not clear low power mode"), m.lastError ?? "")
        XCTAssertEqual(m.foreignSleepWarning, SessionManager.foreignSleepLine)
        XCTAssertEqual(h.notifier.posts.map(\.title), [SessionManager.incompleteTitle, SessionManager.foreignSleepTitle])
    }

    // (c5) the line is rechecked on menu open and dropped once the bit
    // reads 0; a bit still set, or an unreadable pmset, keeps it. No read
    // is made while the line is down.
    func testForeignSleepLineIsDroppedOnceTheBitReadsZero() async throws {
        let m = h.makeManager()
        await m.recheckForeignSleep()
        XCTAssertEqual(h.guardFake.calls, [], "nothing to recheck without the line")

        h.guardFake.sleepDisabled = true
        await m.reconcile()
        XCTAssertEqual(m.foreignSleepWarning, SessionManager.foreignSleepLine)

        await m.recheckForeignSleep()
        XCTAssertEqual(m.foreignSleepWarning, SessionManager.foreignSleepLine, "the bit is still set")

        h.guardFake.throwOn = ["pmset -g"]
        await m.recheckForeignSleep()
        XCTAssertEqual(m.foreignSleepWarning, SessionManager.foreignSleepLine, "an unreadable pmset proves nothing")
        h.guardFake.throwOn = []

        h.guardFake.sleepDisabled = false // its owner re-enabled sleep
        await m.recheckForeignSleep()
        XCTAssertNil(m.foreignSleepWarning)
        XCTAssertEqual(h.guardFake.calls, ["pmset -g", "pmset -g", "pmset -g", "pmset -g"])
        XCTAssertEqual(h.notifier.posts.count, 1, "clearing the line posts nothing")
        XCTAssertNil(m.lastError)

        await m.recheckForeignSleep()
        XCTAssertEqual(h.guardFake.calls.count, 4, "no read once the line is down")
    }

    // (c2) journaled as ours with no session -> cleared through the journal
    // in step 1; step 3 finds nothing foreign to report.
    func testNoSessionButJournaledSleepDisabledIsClearedFromTheJournal() async throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0", "pmset -g"])
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.foreignSleepTitle }, "\(h.notifier.posts)")
    }

    // (c3) journaled as ours and the restore fails -> the bit is ours, still
    // journaled for the retry, and not reported as someone else's.
    func testFailedJournaledRestoreIsNotReportedAsForeign() async throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
        h.guardFake.throwOn = ["disablesleep 0"]
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0", "pmset -g"])
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.foreignSleepTitle }, "\(h.notifier.posts)")
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("could not restore sleep"), m.lastError ?? "")
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

    // MARK: A session the recovery agent ended while the app could not act

    /// backstop.sh ended the session (battery below the floor while the app
    /// was stopped, say) and restored from the journal: session.json gone,
    /// state.json clean. The app still holds the session in memory. Its next
    /// transaction (an extend here) ends it on the app's side from the clean
    /// journal: no pmset, no session written back, countdown stopped, and a
    /// notification that says who ended it. A later end by the user is then
    /// an ordinary end with nothing left to do.
    func testASessionTheAgentEndedIsDroppedAtTheNextTransaction() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        try h.store.deleteSession()
        try h.store.saveState(.clean)

        await m.extend(by: 600)

        XCTAssertNil(m.session)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession(), "the extend must not write the session back")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "the agent restored sleep; nothing to undo here")
        XCTAssertFalse(m.countdownTimerArmed)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session ended")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("recovery agent ended the session") ?? false, "\(h.notifier.posts)")

        let outcome = await m.end(reason: .user)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
    }

    /// What the agent could not undo stays in its journal, and the app's end
    /// retries it from there: the agent restored sleep but left a frozen
    /// process, which the app resumes.
    func testTheAppRetriesWhatTheAgentLeftJournaled() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        try h.store.deleteSession()
        var left = RuntimeState.clean
        left.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5)]
        try h.store.saveState(left)

        await m.extend(by: 600)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.procs.resumed, [[111]])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// An end requested by the user does the same work itself and must not
    /// be doubled by the check: one end, one notification.
    func testAUserEndAfterTheAgentsEndIsOneEnd() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        try h.store.deleteSession()
        try h.store.saveState(.clean)
        let before = h.notifier.posts.count

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .restored)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.notifier.posts.count, before + 1)
        XCTAssertEqual(h.notifier.posts.last?.body, "Ended by you. Sleep is back to normal.")
    }

    /// With the lid open the countdown ticks once a second, and a tick that
    /// finds session.json gone ends the session within about a second, with
    /// no transaction of the user's needed.
    func testTheCountdownTickNoticesASessionTheAgentEnded() async throws {
        // Real-time harness so the 1 Hz Timer actually fires.
        let real = Harness(now: Date())
        defer { real.home.destroy() }
        let m = real.makeManager()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertTrue(m.countdownTimerArmed)
        try real.store.deleteSession()
        try real.store.saveState(.clean)

        let deadline = Date().addingTimeInterval(8)
        while m.isActive && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(m.isActive)
        XCTAssertFalse(m.countdownTimerArmed)
        XCTAssertEqual(real.guardFake.calls, ["disablesleep 1"])
        XCTAssertTrue(real.notifier.posts.last?.body.contains("recovery agent") ?? false, "\(real.notifier.posts)")
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
}
