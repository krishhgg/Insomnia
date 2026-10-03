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

    func testDeadlineTimerFiresEnd() async throws {
        // Use the real clock for this one so the Timer can actually fire.
        let real = Harness(now: Date())
        defer { real.home.destroy() }
        let m = SessionManager(
            paths: real.home.paths,
            sleepGuard: real.guardFake,
            processControl: real.procs,
            backstop: real.backstop,
            notifier: real.notifier,
            clamshell: { false },
            clock: { Date() }
        )
        // Bypass clamping by writing a near-expired session and reconciling.
        // session.json keeps whole seconds, so a fractional deadline would
        // come back up to a second earlier than written.
        let endsAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 2).rounded(.up))
        try real.store.saveSession(Session(startedAt: Date(), endsAt: endsAt))
        await m.reconcile()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.scheduledDeadline, endsAt)

        // Wait for the end to finish, not for it to start: `isActive` goes
        // false at the top of the end, before `disablesleep 0` and the
        // journal write. The notification is the end's last step.
        for _ in 0..<1000 where !real.notifier.posts.contains(where: { $0.title == "Session ended" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        // When the restore was called, not when this loop noticed it: a poll
        // that resumes late would hide an end that came early.
        let restoredAt = try XCTUnwrap(real.guardFake.restoreCalledAt, "the end never restored sleep")
        XCTAssertGreaterThanOrEqual(restoredAt, endsAt, "the session ended before its deadline")
        XCTAssertEqual(real.notifier.posts.last?.body, "Time is up. Sleep is back to normal.")
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try real.store.loadSession())
        XCTAssertEqual(try real.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(real.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertFalse(real.guardFake.sleepDisabled)
    }

    // MARK: Unreadable session.json

    private var movedAsideSessions: [String] {
        get throws {
            try FileManager.default.contentsOfDirectory(atPath: h.home.paths.appSupport.path)
                .filter { $0.hasPrefix(Paths.unreadableSessionPrefix) }.sorted()
        }
    }

    /// Whether anything is at `url`, a dangling symlink included.
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The file type bits of `url` itself (S_IFIFO, S_IFDIR, ...), or 0.
    private func fileType(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : 0
    }

    /// A session.json whose dates carry an offset in place of Z (a person
    /// may write one by hand) is the same session, and backstop.sh reads
    /// the same dates (RecoveryScriptTests), so the app resumes it.
    func testSessionWithOffsetDatesIsResumed() async throws {
        // h.clock.now is 2027-01-15T08:00:00Z; the end is an hour later.
        let json = #"{"startedAt":"2027-01-15T09:50:00+02:00","endsAt":"2027-01-15T11:00:00+02:00","extensions":[]}"#
        try Data(json.utf8).write(to: h.home.paths.sessionFile)
        try h.store.saveState(RuntimeState())

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(m.scheduledDeadline, h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertEqual(try movedAsideSessions, [])
    }

    /// A date JSONDecoder's `.iso8601` took but backstop.sh refuses (here,
    /// text after the zone) is not a session for the app either. Before,
    /// the app resumed it while the agent undid it every minute.
    func testSessionWithADateTheScriptsRefuseIsNotResumed() async throws {
        let json = #"{"startedAt":"2027-01-15T07:50:00Z","endsAt":"2027-01-15T09:00:00Zjunk","extensions":[]}"#
        try Data(json.utf8).write(to: h.home.paths.sessionFile)
        try h.store.saveState(RuntimeState())

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
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

    /// A session.json that is a FIFO is never opened: open(2) on it blocks
    /// until a writer appears, and reconcile runs on the main actor under
    /// the recovery lock. Its end time is unknown, and sleep is never held
    /// without a deadline that can be enforced, so it counts as expired:
    /// the journal is restored. The FIFO is renamed aside, still a FIFO,
    /// and the notification names the file type instead of a permissions
    /// problem.
    func testSessionThatIsAFIFOIsNeverOpenedAndIsMovedAsideWhileTheJournalIsRestored() async throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        let fifo = try FIFOWatch(at: h.home.paths.sessionFile)
        defer { fifo.stop() }
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertFalse(fifo.readerSeen, "session.json was opened although it is a FIFO")
        XCTAssertFalse(exists(h.home.paths.sessionFile), "session.json was not moved aside")
        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
        let moved = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        XCTAssertEqual(fileType(moved), S_IFIFO, "the FIFO was replaced instead of renamed")
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.session)
        let posts = h.notifier.posts.filter { $0.title == SessionManager.sessionFileTitle }
        XCTAssertEqual(posts.count, 1, "\(h.notifier.posts)")
        let body = posts.first?.body ?? ""
        XCTAssertTrue(body.contains("not a regular file"), body)
        XCTAssertTrue(body.contains("treats the session as expired"), body)
        XCTAssertTrue(body.contains("moved, unopened, to \(moved.path)"), body)
    }

    /// A session.json that exists but cannot be read at all (here: it is a
    /// directory) is handled the same way: the journal is restored and the
    /// directory is renamed aside with its contents, never removed. The
    /// next launch, with nothing journaled and no session.json, changes
    /// nothing.
    func testSessionThatCannotBeReadAtAllIsTreatedAsExpiredAndMovedAside() async throws {
        try FileManager.default.createDirectory(at: h.home.paths.sessionFile, withIntermediateDirectories: true)
        try "inside".write(to: h.home.paths.sessionFile.appendingPathComponent("note"), atomically: true, encoding: .utf8)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertFalse(exists(h.home.paths.sessionFile), "session.json was not moved aside")
        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
        let moved = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("note"), encoding: .utf8), "inside")
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let posts = h.notifier.posts.filter { $0.title == SessionManager.sessionFileTitle }
        XCTAssertEqual(posts.count, 1, "\(h.notifier.posts)")
        XCTAssertTrue(posts.first?.body.contains("could not be read") == true, posts.first?.body ?? "")
        XCTAssertTrue(posts.first?.body.contains("moved, unopened, to \(moved.path)") == true, posts.first?.body ?? "")

        let callsBefore = h.guardFake.calls.count
        await m.reconcile()
        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
        XCTAssertFalse(h.guardFake.calls.dropFirst(callsBefore).contains { $0.hasPrefix("disablesleep") }, "\(h.guardFake.calls)")
    }

    /// A valid session without read permission is treated as expired and
    /// renamed aside with its bytes. The user then quits. When the file is
    /// readable again with its end still ahead, the next launch must not
    /// resume the session the first one treated as ended: it is no longer
    /// named session.json.
    func testSessionWithoutReadPermissionIsMovedAsideAndNeverResumedOnceReadable() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(3600)))
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.home.paths.sessionFile.path)
        let moved = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path) }
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.session)
        XCTAssertFalse(exists(h.home.paths.sessionFile), "session.json was not moved aside")
        XCTAssertEqual(try movedAsideSessions, ["session.json.unreadable-20270115T080000Z"])
        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .restored)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        XCTAssertEqual(try Data(contentsOf: moved), bytes, "the file was rewritten")
        let callsBefore = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertNil(next.session, "a session that was treated as ended came back")
        XCTAssertFalse(h.guardFake.calls.dropFirst(callsBefore).contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertEqual(h.backstop.arms, 0)
    }

    /// When session.json can neither be read nor moved aside (the name it
    /// would get is taken by a dangling symlink, which the existence check
    /// does not see and the rename will not replace), it is kept in place.
    /// Every end restores the journal and tries the rename again; while it
    /// fails the end is not finished, since the file would be resumed if it
    /// became readable there. Once the name is free, the retry moves it.
    func testSessionThatCannotBeReadOrMovedAsideKeepsTheEndPendingUntilItMoves() async throws {
        try FileManager.default.createDirectory(at: h.home.paths.sessionFile, withIntermediateDirectories: true)
        let taken = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        try FileManager.default.createSymbolicLink(atPath: taken.path, withDestinationPath: h.home.paths.appSupport.appendingPathComponent("missing").path)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
        h.guardFake.throwOn = ["disablesleep 0"]

        let m = h.makeManager()
        await m.reconcile()
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the failed restore cleared the journal")
        let posts = h.notifier.posts.filter { $0.title == SessionManager.sessionFileTitle }
        XCTAssertEqual(posts.count, 1, "\(h.notifier.posts)")
        let body = posts.first?.body ?? ""
        XCTAssertTrue(body.contains("treats the session as expired"), body)
        XCTAssertTrue(body.contains("could not be moved aside"), body)
        XCTAssertTrue(body.contains("will not quit until it is gone"), body)
        XCTAssertTrue(body.contains("Remove it or move it out of \(h.home.paths.appSupport.path)"), body)

        h.guardFake.throwOn = []
        let outcome = await m.end(reason: .backstop)

        XCTAssertEqual(outcome, .sessionRetained)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(fileType(h.home.paths.sessionFile), S_IFDIR, "session.json was removed, not kept")
        let retained = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(retained.title, SessionManager.incompleteTitle)
        XCTAssertTrue(retained.body.contains("could not be read or moved aside"), retained.body)
        XCTAssertTrue(retained.body.contains("a relaunch would resume it"), retained.body)

        try FileManager.default.removeItem(at: taken)
        let retried = await m.end(reason: .backstop)

        XCTAssertEqual(retried, .restored)
        XCTAssertFalse(exists(h.home.paths.sessionFile))
        XCTAssertEqual(fileType(taken), S_IFDIR, "the retry did not move session.json aside")
        XCTAssertTrue(h.notifier.posts.contains { $0.title == SessionManager.sessionFileTitle && $0.body.contains("moved, unopened, to \(taken.path)") }, "\(h.notifier.posts)")
        XCTAssertNil(m.pendingEnd)
    }

    /// A session.json without read permission that cannot be renamed, a
    /// clean journal, and a quit. The quit is
    /// refused while the file is in place, since making it readable would
    /// let the next launch resume a session that was treated as ended. Once
    /// the rename works, the quit goes through and a later launch finds no
    /// session, even with the copy readable again.
    func testQuitIsRefusedWhileASessionThatCannotBeReadStaysInPlace() async throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(3600)))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.home.paths.sessionFile.path)
        let moved = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: h.home.paths.sessionFile.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        }
        try FileManager.default.createSymbolicLink(atPath: moved.path, withDestinationPath: h.home.paths.appSupport.appendingPathComponent("missing").path)
        try h.store.saveState(RuntimeState())

        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNil(m.session)
        XCTAssertTrue(exists(h.home.paths.sessionFile))

        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .sessionRetained, "quit went through with a resumable session.json in place")
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertTrue(exists(h.home.paths.sessionFile), "the fixture did not keep session.json")

        try FileManager.default.removeItem(at: moved)
        let retried = await m.end(reason: .quit)

        XCTAssertEqual(retried, .restored)
        XCTAssertFalse(exists(h.home.paths.sessionFile))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: moved.path)
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertNil(next.session, "a session that was treated as ended came back")
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertEqual(h.backstop.arms, 0)
    }

    /// A person may remove the file instead: the next end finds nothing at
    /// session.json and finishes.
    func testEndFinishesOnceASessionThatCannotBeReadIsRemoved() async throws {
        try FileManager.default.createDirectory(at: h.home.paths.sessionFile, withIntermediateDirectories: true)
        let taken = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        try FileManager.default.createSymbolicLink(atPath: taken.path, withDestinationPath: h.home.paths.appSupport.appendingPathComponent("missing").path)
        try h.store.saveState(RuntimeState())
        let m = h.makeManager()
        await m.reconcile()
        let refused = await m.end(reason: .quit)
        XCTAssertEqual(refused, .sessionRetained)

        try FileManager.default.removeItem(at: h.home.paths.sessionFile)
        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .restored)
        XCTAssertNil(m.pendingEnd)
        XCTAssertEqual(fileType(taken), S_IFLNK, "nothing was moved")
    }

    /// A start never replaces a session.json it cannot read: one that
    /// appeared after reconcile may be a valid session, and a rollback could
    /// not restore it. The start is refused before anything is written.
    func testStartIsRefusedWhileSessionCannotBeRead() async throws {
        try h.store.saveState(RuntimeState())
        let m = h.makeManager()
        await m.reconcile()
        try FileManager.default.createDirectory(at: h.home.paths.sessionFile, withIntermediateDirectories: true)
        try "inside".write(to: h.home.paths.sessionFile.appendingPathComponent("note"), atomically: true, encoding: .utf8)

        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(try String(contentsOf: h.home.paths.sessionFile.appendingPathComponent("note"), encoding: .utf8), "inside")
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("start refused, nothing changed: session.json could not be read"), m.lastError ?? "")
    }

    /// A session.json that is not a session and cannot be moved aside (the
    /// name it would get is taken by a dangling symlink, which the existence
    /// check does not see and the rename will not replace) is kept with its
    /// bytes, not deleted by the end that restores the journal.
    func testSessionThatCannotBeMovedAsideIsKeptWhileTheJournalIsRestored() async throws {
        let bytes = Data("not json".utf8)
        try bytes.write(to: h.home.paths.sessionFile)
        let taken = h.home.paths.appSupport.appendingPathComponent("session.json.unreadable-20270115T080000Z")
        try FileManager.default.createSymbolicLink(atPath: taken.path, withDestinationPath: h.home.paths.appSupport.appendingPathComponent("missing").path)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), bytes, "session.json was removed or changed")
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("could not be moved aside"), m.lastError ?? "")
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("left in place"), m.lastError ?? "")
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
