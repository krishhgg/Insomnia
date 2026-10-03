import Observation
import XCTest
@testable import Insomnia

/// A `sudo pmset` that ignores SIGTERM is never SIGKILLed (see
/// `StopPolicy.terminateOnly`). These tests pin what the transaction that ran
/// it does meanwhile: keeps the recovery lock, leaves the journal as it was,
/// refuses other transactions and quit, and finishes once the command exits.
/// The command itself is a fake child; nothing here signals a process.
@MainActor
final class StillRunningCommandTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func lockIsHeld() throws -> Bool {
        guard let handle = try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire() else { return true }
        handle.release()
        return false
    }

    /// The waiter runs on the main actor after the fake child exits; poll
    /// for its effect rather than counting yields.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), what)
    }

    /// The end stops at the live `disablesleep 0`: Low Power Mode is not
    /// touched, both journal flags stay, the lock stays held, quit and start
    /// are refused. When the command exits the end runs again and finishes.
    func testEndStopsAtTheLiveCommandAndFinishesWhenItExits() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let lowPower = await m.setLowPower(true)
        XCTAssertTrue(lowPower)
        let before = h.guardFake.calls
        h.guardFake.stillRunning = ["disablesleep 0"]

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .privilegedCommandRunning(pid: 4242))
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0"], "something ran beside the live pmset")
        let journal = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(journal.sleepDisabledByUs, "journal entry dropped while the command that undoes it is still running")
        XCTAssertTrue(journal.lowPowerSetByUs)
        XCTAssertTrue(try lockIsHeld(), "recovery lock released with a sudo pmset still running")
        XCTAssertEqual(m.unfinishedCommand?.pid, 4242)
        XCTAssertEqual(m.pendingEnd, .user)
        XCTAssertNil(m.session)
        let last = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(last.title, SessionManager.commandRunningTitle)
        XCTAssertTrue(last.body.contains("sudo kill 4242"), last.body)
        XCTAssertTrue(try XCTUnwrap(m.commandWarning).contains("sudo kill 4242"), m.commandWarning ?? "")
        XCTAssertNil(m.lastError, "the live command reported as a failure the next success would not clear")
        let postsBefore = h.notifier.posts.count

        // Quit is refused without running anything, and a start is refused.
        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .privilegedCommandRunning(pid: 4242))
        XCTAssertFalse(m.quitRequested)
        await m.start(duration: 60)
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0"], "a transaction ran while the lock was held for the command")
        XCTAssertEqual(h.notifier.posts.count, postsBefore, "told again on every refused transaction")
        XCTAssertTrue(try XCTUnwrap(m.commandWarning).hasPrefix("end skipped"), m.commandWarning ?? "")
        XCTAssertTrue(try XCTUnwrap(m.commandWarning).contains("sudo kill 4242"), m.commandWarning ?? "")
        let startRefused = try XCTUnwrap(m.lastError, "the start refused for the pending end said nothing")

        // The command exits: the lock is released and the end retried.
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }
        XCTAssertNil(m.commandWarning, "the menu still names a command that has exited")
        XCTAssertEqual(m.lastError, startRefused, "the exit took a newer error with the command's line")
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0", "disablesleep 0", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertNil(m.unfinishedCommand)
        XCTAssertFalse(try lockIsHeld(), "recovery lock still held after the command exited")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.notifier.posts.last?.title, "Session restored")
    }

    /// A start whose `disablesleep 1` is left running is not surfaced, and
    /// nothing is rolled back: session.json and the journal entry stay so
    /// the backstop can honour the deadline if Insomnia dies first. The undo
    /// runs once the command has exited.
    func testStartStopsAtTheLiveCommandAndUndoesItselfWhenItExits() async throws {
        h.guardFake.stillRunning = ["disablesleep 1"]
        let m = h.makeManager()

        await m.start(duration: 3600)

        XCTAssertNil(m.session, "a session was surfaced over a pmset of unknown effect")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertEqual(m.pendingEnd, .startFailed)
        XCTAssertNotNil(try h.store.loadSession(), "session.json rolled back beside the live pmset")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "journal entry dropped beside the live pmset")
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertTrue(try lockIsHeld())
        XCTAssertEqual(h.notifier.posts.last?.title, SessionManager.commandRunningTitle)
        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .privilegedCommandRunning(pid: 4242))
        XCTAssertFalse(m.quitRequested)
        await m.start(duration: 60)
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands(status: 1)
        await waitUntil("pending end never retried") { m.pendingEnd == nil }
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(try lockIsHeld())
        XCTAssertNil(m.session)
    }

    /// A live `lowpowermode 1` is not rolled back with a `lowpowermode 0`
    /// beside it. Ownership stays journaled, the session stays active, and
    /// the lock is held for the command alone. Once it exits nothing is
    /// pending; the mode reads off (the command failed in the end), so the
    /// ownership is cleared and the end has no mode to switch off.
    func testLowPowerOnStopsAtTheLiveCommandWithoutARollback() async throws {
        h.guardFake.stillRunning = ["lowpowermode 1"]
        let m = h.makeManager()
        let resyncs = Locked<[Bool]>([])
        m.resyncAfterCommand = { resyncs.value.append($0) }
        await m.start(duration: 3600)

        let changed = await m.setLowPower(true)

        XCTAssertFalse(changed)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 1"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true, "ownership dropped beside the live pmset")
        XCTAssertNotNil(m.session)
        XCTAssertNil(m.pendingEnd)
        XCTAssertTrue(try lockIsHeld())
        var ran = false
        let admitted = await m.runExclusive("probe") { ran = true }
        XCTAssertFalse(admitted)
        XCTAssertFalse(ran, "a transaction ran while the lock was held for the command")

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands(status: 1)
        await waitUntil("session never settled after the exit") { resyncs.value.count == 1 }
        XCTAssertNil(m.unfinishedCommand)
        XCTAssertNotNil(m.session, "session ended though nothing was pending")
        XCTAssertNil(m.pendingEnd)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["lowpowermode 1", "pmset -g custom"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false, "ownership of a mode that is off kept after the command exited")
        XCTAssertFalse(try lockIsHeld())

        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["pmset -g custom", "disablesleep 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The same live `lowpowermode 1`, which this time switched the mode on
    /// before it exited: the ownership stays, and the end switches it off.
    func testLowPowerOnThatTookEffectBeforeExitingStaysOurs() async throws {
        h.guardFake.stillRunning = ["lowpowermode 1"]
        let m = h.makeManager()
        let resyncs = Locked<[Bool]>([])
        m.resyncAfterCommand = { resyncs.value.append($0) }
        await m.start(duration: 3600)
        _ = await m.setLowPower(true)

        h.guardFake.stillRunning = []
        h.guardFake.lowPowerOn = true
        h.guardFake.exitStuckCommands()
        await waitUntil("session never settled after the exit") { resyncs.value.count == 1 }
        XCTAssertEqual(resyncs.value, [false], "no lid event was refused, so only the floors run")
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["lowpowermode 1", "pmset -g custom"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true, "ownership of a mode Insomnia switched on dropped")

        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["disablesleep 0", "lowpowermode 0"])
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// Reconcile restoring an expired session, with that `disablesleep 0`
    /// left running: step 3 must not run a second one beside it. Nothing
    /// else runs, the lock goes to the command, and the end runs again
    /// once it has exited.
    func testReconcileRestoreStopsAtTheLiveCommandAndRunsNoSecondOne() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
        h.guardFake.stillRunning = ["disablesleep 0"]
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0"], "a second pmset ran beside the live one")
        XCTAssertEqual(m.pendingEnd, .timer)
        XCTAssertEqual(m.unfinishedCommand?.pid, 4242)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertTrue(try lockIsHeld())

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0", "disablesleep 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(try lockIsHeld())
    }

    /// `lowpowermode 1` fails outright and the rollback `lowpowermode 0` is
    /// the command left running: it is tracked like any other, so the lock
    /// stays with it and ownership stays journaled while it runs. The
    /// rollback goes through in the end: the mode reads off after the exit,
    /// the ownership is cleared, and the floors run on the corrected
    /// journal and switch the mode on again, which a stale flag would have
    /// stopped them doing.
    func testLowPowerRollbackLeftRunningKeepsTheLockAndIsCheckedWhenItExits() async throws {
        h.guardFake.throwOn = ["lowpowermode 1"]
        h.guardFake.stillRunning = ["lowpowermode 0"]
        let m = h.makeManager()
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        let floorRuns = Locked(0)
        m.resyncAfterCommand = { _ in
            Task { @MainActor in
                await driver.run(battery: .percent(30), isCharging: false, thermal: .nominal, lidClosed: false)
                floorRuns.value += 1
            }
        }
        await m.start(duration: 3600)

        let changed = await m.setLowPower(true)

        XCTAssertFalse(changed)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 1", "lowpowermode 0"])
        XCTAssertEqual(m.unfinishedCommand?.pid, 4242)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true, "ownership dropped with the rollback still running")
        XCTAssertTrue(try lockIsHeld(), "recovery lock released with the rollback still running")
        let enableFailed = try XCTUnwrap(m.lastError)
        XCTAssertTrue(enableFailed.hasPrefix("could not enable low power mode"), enableFailed)
        XCTAssertTrue(try XCTUnwrap(m.commandWarning).contains("sudo kill 4242"), m.commandWarning ?? "")
        var ran = false
        let admitted = await m.runExclusive("probe") { ran = true }
        XCTAssertFalse(admitted)
        XCTAssertFalse(ran)

        h.guardFake.stillRunning = []
        h.guardFake.throwOn = []
        h.guardFake.exitStuckCommands()
        await waitUntil("floors never ran after the exit") { floorRuns.value == 1 }
        XCTAssertNotNil(m.session)
        XCTAssertEqual(
            h.guardFake.calls,
            ["disablesleep 1", "pmset -g custom", "lowpowermode 1", "lowpowermode 0", "pmset -g custom", "pmset -g custom", "lowpowermode 1"],
            "the check, then the floors' enable on a journal that no longer claims the mode"
        )
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")
        XCTAssertFalse(try lockIsHeld())
        XCTAssertNil(m.commandWarning, "the menu still names the rollback after it exited")
        XCTAssertEqual(m.lastError, enableFailed)

        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["disablesleep 0", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The command exits in the moment between being reported and the
    /// transaction's own check. The end is still stopped and pending, the
    /// lock still goes to the holder, and the holder retries the end: a fast
    /// exit must not leave the cleanup pending with nothing to retry it.
    ///
    /// The holder can retry before this test's next line runs, so nothing
    /// here waits on that ordering. The fake reports the command stuck once
    /// and clears it itself, and where the first end stopped is read from
    /// the order of the calls afterwards, not from a check in between.
    func testCommandThatExitsAsSoonAsReportedStillGetsTheRetry() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let lowPower = await m.setLowPower(true)
        XCTAssertTrue(lowPower)
        h.guardFake.stillRunning = ["disablesleep 0"]
        h.guardFake.stuckExitsAtOnce = true

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .privilegedCommandRunning(pid: 4242))
        XCTAssertEqual(h.guardFake.stillRunning, [], "a fast-exiting command is reported stuck once")
        await waitUntil("pending end never retried after a fast exit") { m.pendingEnd == nil }
        // One stuck report, one retry, nothing between them: the first end
        // stopped at the stuck command instead of going on to lowpowermode 0.
        XCTAssertEqual(h.guardFake.calls.suffix(4), ["lowpowermode 1", "disablesleep 0", "disablesleep 0", "lowpowermode 0"])
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.commandRunningTitle }.count, 1, "\(h.notifier.posts)")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.unfinishedCommand)
        XCTAssertFalse(try lockIsHeld())
    }

    /// Reconcile re-applying sleep for a session found on disk, with that
    /// pmset left running: the session is not surfaced, the files stay, and
    /// the end that undoes it runs once the command has exited.
    func testReconcileStopsAtTheLiveReapplyAndEndsWhenItExits() async throws {
        let first = h.makeManager()
        await first.start(duration: 3600)
        h.guardFake.stillRunning = ["disablesleep 1"]
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 1"])
        XCTAssertEqual(m.pendingEnd, .recoveryUnavailable)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertTrue(try lockIsHeld())

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 1", "disablesleep 0"])
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(try lockIsHeld())
    }

    // MARK: Work refused while the command runs

    /// Lid actions over the harness fakes, as AppServices builds them.
    /// Nothing to freeze; muting is on, so a close journals the volume.
    private func makeLidActions(_ m: SessionManager) -> LidActions {
        m.config.muteOnLidClose = true
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        return LidActions(manager: m, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { false }), audio: h.audio, display: h.display, keyboard: h.keyboard)
    }

    /// An end refused while the command runs is recorded by the refusal
    /// itself, before `end()` resumes. Here the command exits inside the
    /// refusal, so its holder can run before the caller does: the holder
    /// must find the end, and the caller resuming after it has finished
    /// must not mark the end pending again with nothing left to retry it.
    func testEndRefusedWhileTheCommandRunsIsRecordedBeforeTheCallerResumes() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.stillRunning = ["lowpowermode 1"]
        _ = await m.setLowPower(true)
        XCTAssertNil(m.pendingEnd)
        h.guardFake.stillRunning = []
        let pendingAtRefusal = Locked<EndReason?>(nil)
        withObservationTracking {
            _ = m.commandWarning
        } onChange: { [guardFake = h.guardFake] in
            // The refusal reports through `commandWarning`: this runs inside it.
            MainActor.assumeIsolated { pendingAtRefusal.value = m.pendingEnd }
            guardFake.exitStuckCommands()
        }

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .privilegedCommandRunning(pid: 4242))
        XCTAssertEqual(pendingAtRefusal.value, .user, "the refused end was not recorded before the caller resumed")
        await waitUntil("end refused before the exit never retried") {
            m.pendingEnd == nil && (try? self.h.store.loadState()) == RuntimeState.clean
        }
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.guardFake.calls.suffix(3), ["lowpowermode 1", "disablesleep 0", "lowpowermode 0"])
        XCTAssertFalse(try lockIsHeld())
    }

    /// A lid open refused while the command runs leaves the lid actions
    /// journaled and is replayed once the command has exited, for the
    /// lid's latest state (open), through the LidActions AppServices uses.
    func testLidOpenRefusedWhileTheCommandRunsIsReplayedWhenItExits() async throws {
        let m = h.makeManager()
        let actions = makeLidActions(m)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedOutputVolume, 0.6)
        h.guardFake.stillRunning = ["lowpowermode 1"]
        _ = await m.setLowPower(true)

        await actions.onOpen()

        XCTAssertTrue(m.lidEventDeferred)
        XCTAssertEqual(try h.store.loadState()?.savedOutputVolume, 0.6, "lid actions undone beside the live pmset")
        XCTAssertTrue(h.audio.applied.isEmpty)

        let replays = Locked<[Bool]>([])
        m.resyncAfterCommand = { replay in
            replays.value.append(replay)
            if replay { Task { @MainActor in await actions.onOpen() } }
        }
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("refused lid open never replayed") { (try? self.h.store.loadState())?.hasLidActions == false }
        XCTAssertEqual(replays.value, [true])
        XCTAssertFalse(m.lidEventDeferred)
        XCTAssertEqual(h.audio.applied.last?.volume, 0.6)
        XCTAssertEqual(h.audio.applied.last?.muted, false)
        XCTAssertNotNil(m.session)
        XCTAssertFalse(try lockIsHeld())
    }

    /// The same for a lid close: nothing is muted beside the live pmset,
    /// and the close runs once the command has exited.
    func testLidCloseRefusedWhileTheCommandRunsIsReplayedWhenItExits() async throws {
        let m = h.makeManager()
        let actions = makeLidActions(m)
        await m.start(duration: 3600)
        h.guardFake.stillRunning = ["lowpowermode 1"]
        _ = await m.setLowPower(true)

        await actions.onClose()

        XCTAssertTrue(m.lidEventDeferred)
        XCTAssertEqual(h.audio.mutes, 0, "muted beside the live pmset")
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)

        let replays = Locked<[Bool]>([])
        m.resyncAfterCommand = { replay in
            replays.value.append(replay)
            if replay { Task { @MainActor in await actions.onClose() } }
        }
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("refused lid close never replayed") { self.h.audio.mutes == 1 }
        XCTAssertEqual(replays.value, [true])
        XCTAssertEqual(try h.store.loadState()?.savedOutputVolume, 0.6)
        XCTAssertFalse(m.lidEventDeferred)
    }

    /// With an end pending, the end runs first and alone: it undoes every
    /// lid action from the journal itself, so a lid event refused meanwhile
    /// owes nothing and nothing is replayed into the ended session.
    func testPendingEndGoesBeforeALidEventRefusedMeanwhile() async throws {
        let m = h.makeManager()
        let actions = makeLidActions(m)
        let replays = Locked<[Bool]>([])
        m.resyncAfterCommand = { replays.value.append($0) }
        await m.start(duration: 3600)
        await actions.onClose()
        h.guardFake.stillRunning = ["disablesleep 0"]
        _ = await m.end(reason: .user)
        await m.undoLidActions()
        XCTAssertTrue(m.lidEventDeferred)
        XCTAssertEqual(m.pendingEnd, .user)

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.audio.applied.last?.volume, 0.6)
        XCTAssertFalse(m.lidEventDeferred)
        XCTAssertEqual(replays.value, [], "lid event replayed after the end")
    }

    /// The check after the exit takes the lock like any transaction. If
    /// another process holds it, nothing is checked or replayed, and the
    /// pass runs again after the retry delay instead of being dropped.
    func testCheckAfterTheCommandRunsAgainAfterABusyLock() async throws {
        let m = h.makeManager(retryDelay: 0.2)
        let resyncs = Locked<[Bool]>([])
        m.resyncAfterCommand = { resyncs.value.append($0) }
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        h.guardFake.lowPowerOn = false
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())

        await m.settleAfterCommand()

        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true, "checked without the lock")
        XCTAssertEqual(resyncs.value, [])
        other.release()
        await waitUntil("check never ran again after the busy lock") { resyncs.value == [false] }
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
    }

    /// The rollback `lowpowermode 0` is left running and goes through, as
    /// above, so the flag claims a mode that is off. Started with the flag
    /// journaled and the floors running on it, as AppServices runs them.
    private func startWithRollbackLeftRunning(_ m: SessionManager) async throws {
        h.guardFake.throwOn = ["lowpowermode 1"]
        h.guardFake.stillRunning = ["lowpowermode 0"]
        await m.start(duration: 3600)
        let changed = await m.setLowPower(true)
        XCTAssertFalse(changed)
        XCTAssertEqual(m.unfinishedCommand?.pid, 4242)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        h.guardFake.stillRunning = []
        h.guardFake.throwOn = []
    }

    private func floorsOnBattery(_ m: SessionManager, before run: @escaping @MainActor () -> Void) -> Locked<Int> {
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        let floorRuns = Locked(0)
        m.resyncAfterCommand = { _ in
            run()
            Task { @MainActor in
                await driver.run(battery: .percent(30), isCharging: false, thermal: .nominal, lidClosed: false)
                floorRuns.value += 1
            }
        }
        return floorRuns
    }

    /// The check after the exit cannot read the mode. The flag stays, the
    /// floors run on it at once (and do nothing, trusting it), and the
    /// check runs again after the retry delay instead of leaving the stale
    /// flag for the rest of the session: the mode reads off, the ownership
    /// is cleared, and the floors run again and switch the mode on.
    func testCheckThatCouldNotReadTheModeRunsAgain() async throws {
        let m = h.makeManager(retryDelay: 0.2)
        let floorRuns = floorsOnBattery(m) { [guardFake = h.guardFake] in
            // Each pass reads the mode before the floors run; only the
            // first read fails.
            guardFake.throwOn = []
        }
        try await startWithRollbackLeftRunning(m)
        let before = h.guardFake.calls

        h.guardFake.throwOn = ["pmset -g custom"]
        h.guardFake.exitStuckCommands()

        await waitUntil("the check never ran again after the failed read") { floorRuns.value == 2 }
        XCTAssertEqual(
            Array(h.guardFake.calls.dropFirst(before.count)),
            ["pmset -g custom", "pmset -g custom", "pmset -g custom", "lowpowermode 1"],
            "the failed read, the retried check, then the floors' enable on the corrected journal"
        )
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")
        XCTAssertFalse(try lockIsHeld())
    }

    /// The check reads the mode off but cannot write the journal. The flag
    /// stays on disk, and the check runs again after the retry delay; once
    /// the journal takes the write the floors switch the mode on again.
    func testCheckThatCouldNotWriteTheJournalRunsAgain() async throws {
        let m = h.makeManager(retryDelay: 0.2)
        let dir = h.home.paths.appSupport.path
        addTeardownBlock { _ = chmod(dir, 0o755) }
        let floorRuns = floorsOnBattery(m) {
            // The journal takes writes again from the second pass on.
            _ = chmod(dir, 0o755)
        }
        try await startWithRollbackLeftRunning(m)
        let before = h.guardFake.calls

        // Read-only: state.json cannot be replaced; it and the lock file
        // still open.
        XCTAssertEqual(chmod(dir, 0o500), 0)
        h.guardFake.exitStuckCommands()

        await waitUntil("the check never ran again after the failed journal write") { floorRuns.value == 2 }
        XCTAssertEqual(
            Array(h.guardFake.calls.dropFirst(before.count)),
            ["pmset -g custom", "pmset -g custom", "pmset -g custom", "lowpowermode 1"],
            "the check whose write failed, the retried check, then the floors' enable"
        )
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertFalse(try lockIsHeld())
    }

    /// The journal does not decode when the command exits: nothing is
    /// checked or replayed, and the pass runs again after the retry delay
    /// until the file is fixed, instead of being dropped.
    func testCheckAfterTheCommandRunsAgainOnceTheJournalReadsAgain() async throws {
        let m = h.makeManager(retryDelay: 0.2)
        let floorRuns = floorsOnBattery(m) {}
        try await startWithRollbackLeftRunning(m)
        let stateFile = h.home.paths.stateFile
        let journal = try Data(contentsOf: stateFile)
        try Data("{".utf8).write(to: stateFile)

        h.guardFake.exitStuckCommands()

        await waitUntil("the unreadable journal was never reported") {
            self.h.notifier.posts.contains { $0.title == SessionManager.journalTitle }
        }
        XCTAssertEqual(floorRuns.value, 0, "the floors ran on a journal that could not be read")
        try journal.write(to: stateFile)
        await waitUntil("the check never ran again after the journal was fixed") { floorRuns.value == 1 }
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.guardFake.calls.suffix(3), ["pmset -g custom", "pmset -g custom", "lowpowermode 1"])
    }

    /// An end refused for the unreadable journal is pending when the file
    /// is fixed. The pass that was waiting for the journal does not check
    /// the mode or run the floors, which would switch the mode on with the
    /// session ending: the end owes the cleanup and restores it all.
    func testPassWaitingForTheJournalLeavesAPendingEndTheCleanup() async throws {
        let m = h.makeManager(retryDelay: 0.2)
        let floorRuns = floorsOnBattery(m) {}
        try await startWithRollbackLeftRunning(m)
        let stateFile = h.home.paths.stateFile
        let journal = try Data(contentsOf: stateFile)
        try Data("{".utf8).write(to: stateFile)
        h.guardFake.exitStuckCommands()
        await waitUntil("the unreadable journal was never reported") {
            self.h.notifier.posts.contains { $0.title == SessionManager.journalTitle }
        }

        let refused = await m.end(reason: .user)
        XCTAssertEqual(refused, .journalUnreadable)
        XCTAssertEqual(m.pendingEnd, .user)
        try journal.write(to: stateFile)
        let calls = h.guardFake.calls
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(floorRuns.value, 0, "the floors ran with an end pending")
        XCTAssertEqual(h.guardFake.calls, calls, "the pass ran with an end pending")
        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.lowPowerOn)
    }
}
