import XCTest
@testable import Insomnia

/// Failure-path guarantees for recovery: what stays journaled, what is
/// reported, and what is never touched.
@MainActor
final class RecoverySafetyTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func seedExpiredSession() throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
    }

    // MARK: Frozen process recovery

    func testFailedResumptionStaysJournaledAndIsReported() async throws {
        try seedExpiredSession()
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5), FrozenProcess(pid: 222, startedAt: 6)]
        try h.store.saveState(st)
        h.procs.failResume = [222]

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(h.procs.resumed, [[111, 222]])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenProcesses, [FrozenProcess(pid: 222, startedAt: 6)])
        XCTAssertFalse(after.sleepDisabledByUs, "a stuck pid must not hold sleep disabled")
        XCTAssertTrue(after.isDirty)
        XCTAssertEqual(m.state, after)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("222"), err)
    }

    /// A journal from an older build lists bare pids. One that is still
    /// stopped cannot be proven ours: it is not signaled, stays journaled,
    /// and the user is told exactly what to do. One that is running or gone
    /// needs nothing and is cleared.
    func testLegacyEntryStillStoppedStaysJournaledWithGuidance() async throws {
        try seedExpiredSession()
        try Data(#"{"sleepDisabledByUs": true, "frozenPids": [111, 222]}"#.utf8).write(to: h.home.paths.stateFile)
        h.procs.stoppedNow = [111]

        let m = h.makeManager()
        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenProcesses, [FrozenProcess(pid: 111, startedAt: nil)])
        XCTAssertFalse(after.sleepDisabledByUs, "sleep restore must not be held back by an unverifiable pid")
        XCTAssertTrue(after.isDirty)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("111"), err)
        XCTAssertTrue(err.contains("kill -CONT"), err)
    }

    // MARK: Lifecycle under suspended operations (release the hold, then await)

    /// Reconcile's final pmset check is answered late, after a new session
    /// started. It must not clear that session's sleep guard.
    func testLateReconcileMustNotClearNewSessionSleepGuard() async throws {
        let gate = AsyncGate()
        h.guardFake.readGate = gate
        h.guardFake.sleepDisabled = true // stale flag from a crashed run
        let m = h.makeManager()

        let reconcile = Task { await m.reconcile() }
        await gate.waitUntilStarted()
        let start = Task { await m.start(duration: 3600) }
        await settleQueuedRequests()
        await gate.open()
        await reconcile.value
        await start.value

        XCTAssertTrue(m.isActive)
        XCTAssertTrue(h.guardFake.sleepDisabled, "the new session's sleep guard was cleared by the late reconcile")
        XCTAssertEqual(h.guardFake.calls, ["pmset -g", "disablesleep 0", "disablesleep 1"])
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
    }

    /// `lowpowermode 1` completes after the session ended. The mode must not
    /// stay on outside the journal.
    func testLowPowerCompletionAfterEndMustNotEscapeJournal() async throws {
        let gate = AsyncGate()
        h.guardFake.lowPowerGate = gate
        let m = h.makeManager()
        await m.start(duration: 3600)

        let lowPower = Task { await m.setLowPower(true) }
        await gate.waitUntilStarted()
        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        await gate.open()
        let changed = await lowPower.value
        _ = await end.value

        XCTAssertFalse(changed, "a Low Power change that lands after an end request must not be announced as ours")
        XCTAssertFalse(h.guardFake.lowPowerOn, "Low Power Mode left on with a clean journal")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 1", "disablesleep 0", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.session)
    }

    /// End requested while start's `disablesleep 1` is in flight. After both
    /// finish, sleep must be back to normal and nothing journaled.
    func testEndDuringStartMustNotDisableSleepAfterCleanup() async throws {
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let m = h.makeManager()

        let start = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        await gate.open()
        await start.value
        _ = await end.value

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled, "sleep left disabled after the end completed")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// End requested while extend waits on launchd. The extend must not
    /// write the session back after the end removed it.
    func testEndDuringExtendMustNotResurrectSession() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let gate = AsyncGate()
        h.backstop.armGate = gate

        let extend = Task { await m.extend(by: 3600) }
        await gate.waitUntilStarted()
        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        await gate.open()
        await extend.value
        _ = await end.value

        XCTAssertNil(m.session, "session resurrected by the late extend")
        XCTAssertNil(try h.store.loadSession(), "session.json rewritten after the end deleted it")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.scheduledDeadline)
    }

    /// A valid session on disk whose agent cannot be armed is ended, never
    /// held: sleep is not disabled without something guaranteed to release it.
    func testReconcileMustNotHoldSleepWithoutBackstop() async throws {
        let now = h.clock.now
        let s = Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600))
        try h.store.saveSession(s)
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
        h.backstop.failArm = true

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "sleep held with no agent to release it")
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("backstop") || err.contains("recovery agent"), err)
    }

    /// When `disablesleep 0` fails at end, the user must be told recovery is
    /// incomplete, not that sleep is back to normal.
    func testFailedRestoreMustNotPromiseNormalSleep() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertFalse(h.notifier.posts.contains { $0.body.contains("back to normal") }, "\(h.notifier.posts)")
        let last = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(last.title, SessionManager.incompleteTitle)
        XCTAssertTrue(last.body.contains("could not restore sleep"), last.body)
        XCTAssertNotNil(m.lastError)
    }

    // MARK: Ambiguous power-command failures keep ownership

    /// `disablesleep 1` applied the setting and then failed (a timeout). The
    /// journal already says sleep is ours, so the start is undone from it,
    /// not rolled back from memory.
    func testStartWhoseSleepCommandFailsAfterTakingEffectIsUndoneFromTheJournal() async throws {
        h.guardFake.throwAfterEffect = ["disablesleep 1"]
        let m = h.makeManager()
        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled, "sleep left disabled after a failed start")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("disable sleep"), m.lastError ?? "")
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// Same failure, and the undo fails too: the entry stays journaled and
    /// the agent is re-confirmed, so something will retry it.
    func testStartWhoseSleepCommandFailsAmbiguouslyKeepsOwnershipUntilUndoIsConfirmed() async throws {
        h.guardFake.throwAfterEffect = ["disablesleep 1"]
        h.guardFake.throwOn = ["disablesleep 0"]
        let m = h.makeManager()
        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "journal dropped the entry while sleep is still disabled")
        XCTAssertEqual(h.backstop.arms, 2, "agent not re-confirmed for the dirty journal")
        XCTAssertEqual(h.notifier.posts.last?.title, SessionManager.incompleteTitle)
        XCTAssertFalse(h.notifier.posts.contains { $0.body.contains("back to normal") }, "\(h.notifier.posts)")
    }

    // MARK: Fresh journal under the lock

    /// A previous restore failed and left sleep journaled as Insomnia's. A
    /// new start that cannot arm the agent must roll back only what it
    /// added: the old ownership is evidence, not this attempt's doing.
    func testFailedStartMustNotEraseOwnershipLeftByAnEarlierFailedRestore() async throws {
        var old = RuntimeState()
        old.sleepDisabledByUs = true
        old.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5)]
        try h.store.saveState(old)
        h.guardFake.sleepDisabled = true
        h.backstop.failArm = true
        let m = h.makeManager()

        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), old, "rollback erased ownership this start did not create")
        XCTAssertEqual(m.state, old)
        XCTAssertEqual(h.guardFake.calls, [], "pmset ran without an agent")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertNotNil(m.lastError)
    }

    /// Same old ownership; the start is abandoned because an end was
    /// requested while launchd was slow. The end that runs next must still
    /// find the old entry and restore it.
    func testStartAbandonedForAnEndKeepsOldOwnershipForThatEnd() async throws {
        var old = RuntimeState()
        old.sleepDisabledByUs = true
        try h.store.saveState(old)
        h.guardFake.sleepDisabled = true
        let gate = AsyncGate()
        h.backstop.armGate = gate
        let m = h.makeManager()

        let start = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        await gate.open()
        await start.value
        _ = await end.value

        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled, "old ownership erased by the abandoned start, so the end never restored it")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// backstop.sh (or an older run) writes the journal between two of the
    /// app's transactions. The next transaction must build on what is on
    /// disk, not on the copy cached at initialization.
    func testJournalWrittenByAnotherProcessIsHonouredByTheNextTransaction() async throws {
        let m = h.makeManager()
        var external = RuntimeState()
        external.lowPowerSetByUs = true
        external.savedOutputVolume = 0.4
        external.savedMuted = false
        try h.store.saveState(external)
        h.guardFake.lowPowerOn = true

        await m.start(duration: 3600)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(after.sleepDisabledByUs)
        XCTAssertTrue(after.lowPowerSetByUs, "entry written by another process was overwritten from the cached journal")
        XCTAssertEqual(after.savedOutputVolume, 0.4)
        XCTAssertEqual(m.state, after)

        await m.end(reason: .user)
        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.audio.applied.first?.volume, 0.4)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    // MARK: session.json that will not go away

    /// The machine is restored, but a session file that could not be removed
    /// would make a relaunch hold sleep again. The end stays pending: quit
    /// is deferred, starts are refused, and the retry finishes the job.
    func testSessionFileThatCannotBeRemovedKeepsTheEndPendingAndRefusesQuit() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let file = h.home.paths.sessionFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .sessionRetained)
        XCTAssertNotNil(try h.store.loadSession(), "fixture did not keep session.json")
        XCTAssertFalse(h.guardFake.sleepDisabled, "the machine must still be restored")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertFalse(m.quitRequested)
        let last = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(last.title, SessionManager.incompleteTitle)
        XCTAssertTrue(last.body.contains("session.json"), last.body)
        XCTAssertFalse(h.notifier.posts.contains { $0.body.contains("back to normal") }, "\(h.notifier.posts)")

        await m.start(duration: 60)
        XCTAssertNil(m.session, "a new session started over a pending end")

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let second = await m.end(reason: .user)
        XCTAssertEqual(second, .restored)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertNil(m.pendingEnd)

        // A fresh launch finds nothing to hold.
        let again = h.makeManager()
        await again.reconcile()
        XCTAssertNil(again.session)
        XCTAssertFalse(h.guardFake.calls.dropFirst(2).contains("disablesleep 1"), "\(h.guardFake.calls)")
    }

    // MARK: Cross-process lock: fail closed

    /// The backstop holds the recovery lock. An end must change nothing:
    /// no pmset, no journal write, session intact, failure reported.
    func testEndUnderLockContentionChangesNothingAndReports() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let session = try XCTUnwrap(m.session)
        let stateBefore = try XCTUnwrap(try h.store.loadState())
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .locked)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "pmset ran without the lock")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadSession(), session, "session.json touched without the lock")
        XCTAssertEqual(try h.store.loadState(), stateBefore, "journal written without the lock")
        XCTAssertEqual(m.session, session, "session dropped from memory while still live on disk")
        XCTAssertEqual(h.notifier.posts.last?.title, SessionManager.notEndedTitle)
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("lock"), m.lastError ?? "")
        XCTAssertEqual(m.pendingEnd, .user)

        // Lock freed: the next end completes normally.
        held.release()
        let second = await m.end(reason: .user)
        XCTAssertEqual(second, .restored)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.pendingEnd)
    }

    func testStartUnderLockContentionMakesNoJournalOrPowerChange() async throws {
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        defer { held.release() }
        let m = h.makeManager()
        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertEqual((try h.store.loadState()) ?? .clean, RuntimeState.clean)
        XCTAssertNotNil(m.lastError)
    }

    /// A locked end is retried in process once the lock frees, so a quit
    /// that was refused does not leave a live session with nobody ending it.
    func testLockedEndIsRetriedInProcessOnceTheLockFrees() async throws {
        let m = h.makeManager(retryDelay: 0.3)
        await m.start(duration: 3600)
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let locked = await m.end(reason: .quit)
        XCTAssertEqual(locked, .locked)
        XCTAssertFalse(m.quitRequested, "quit stays requested although the app has to stay for the retry")
        held.release()

        let deadline = Date().addingTimeInterval(5)
        while m.isActive, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(m.isActive, "pending end was never retried")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.pendingEnd)
    }

    /// While an end is pending, a new session would be ended by the retry;
    /// starts are refused until it resolves.
    func testStartIsRefusedWhileAnEndIsPending() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let locked = await m.end(reason: .user)
        XCTAssertEqual(locked, .locked)
        held.release()

        await m.start(duration: 60)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "a second session started over a pending end")
        XCTAssertEqual(h.backstop.arms, 1)
    }

    // MARK: Quit

    func testQuitBlocksNewStarts() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let outcome = await m.end(reason: .quit)
        XCTAssertEqual(outcome, .restored)
        await m.start(duration: 3600)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
    }

    /// A start that is queued when the quit arrives must not run through
    /// the restoration and leave a fresh session behind.
    func testStartQueuedBehindQuitNeverRuns() async throws {
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let m = h.makeManager()
        let first = Task { await m.start(duration: 3600) }
        await gate.waitUntilStarted()
        let quit = Task { await m.end(reason: .quit) }
        await settleQueuedRequests()
        let second = Task { await m.start(duration: 3600) }
        await settleQueuedRequests()
        await gate.open()
        await first.value
        _ = await quit.value
        await second.value

        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
    }

    // MARK: Corrupt journal

    /// An unreadable state.json is the only record of what a previous run
    /// changed. It stays exactly where it is, every transaction refuses to
    /// run, nothing touches pmset or launchd, and the user is told once.
    func testCorruptJournalIsLeftInPlaceAndBlocksEveryTransaction() async throws {
        let bytes = Data("{not json".utf8)
        try bytes.write(to: h.home.paths.stateFile)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains(h.home.paths.stateFile.path), m.lastError ?? "")

        await m.reconcile()
        await m.start(duration: 3600)

        XCTAssertEqual(h.guardFake.calls, [], "pmset ran against an unreadable journal")
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), bytes, "the corrupt journal was rewritten or moved")
        XCTAssertThrowsError(try h.store.loadState(), "the next reader must still see the corruption")
        let names = try FileManager.default.contentsOfDirectory(atPath: h.home.paths.appSupport.path)
        XCTAssertFalse(names.contains { $0.contains("corrupt") }, "\(names)")
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.journalTitle }.count, 1, "\(h.notifier.posts)")
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("refused"), m.lastError ?? "")
    }

    /// The journal breaks while a session is live. The end must not guess:
    /// nothing is undone, nothing is claimed restored, and the session stays
    /// until a person repairs the file, after which the next end restores.
    func testJournalCorruptedAfterStartStopsEndWithoutSideEffectsOrRestoredClaim() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let session = try XCTUnwrap(m.session)
        let bytes = Data(#"{"sleepDisabledByUs": tru"#.utf8)
        try bytes.write(to: h.home.paths.stateFile)

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .journalUnreadable)
        XCTAssertEqual(m.session, session, "session dropped although nothing was undone")
        XCTAssertEqual(try h.store.loadSession(), session)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "pmset ran against an unreadable journal")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), bytes, "the corrupt journal was rewritten")
        XCTAssertFalse(h.notifier.posts.contains { $0.body.contains("back to normal") }, "\(h.notifier.posts)")
        XCTAssertEqual(h.notifier.posts.last?.title, SessionManager.journalTitle)
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertFalse(m.quitRequested)

        // Repaired by hand: the next end restores from what it says.
        var repaired = RuntimeState()
        repaired.sleepDisabledByUs = true
        try h.store.saveState(repaired)
        let second = await m.end(reason: .user)
        XCTAssertEqual(second, .restored)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertNil(m.pendingEnd)
    }
}
