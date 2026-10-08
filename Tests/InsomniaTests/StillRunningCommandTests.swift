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
    /// are refused. The command exits 0: its undo is journaled as done under
    /// the lock, and the end runs again for what is left, without running
    /// the same command a second time.
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
        let record = try XCTUnwrap(h.store.loadUnfinishedCommand(), "nothing on disk names the command if Insomnia dies first")
        XCTAssertEqual(record.pid, 4242)
        XCTAssertEqual(record.command, "/usr/bin/sudo -n /usr/bin/pmset disablesleep 0")
        XCTAssertEqual(record.identity, FakeSleepGuard.identity(of: 4242), "nothing tells the pid apart once the command has exited")
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
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0", "lowpowermode 0"], "an undo that exited 0 was run again")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(h.store.loadUnfinishedCommand(), "the record outlived the command")
        XCTAssertEqual(h.guardFake.unlockedPrivilegedCalls, [], "a sudo pmset ran without the recovery lock")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertNil(m.unfinishedCommand)
        XCTAssertFalse(try lockIsHeld(), "recovery lock still held after the command exited")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.notifier.posts.last?.title, "Session restored")
    }

    /// The same live `disablesleep 0` exits 1: nothing is confirmed, and the
    /// end runs it again before it goes on.
    func testEndRunsAnUndoAgainIfItExitsNonzero() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let lowPower = await m.setLowPower(true)
        XCTAssertTrue(lowPower)
        let before = h.guardFake.calls
        h.guardFake.stillRunning = ["disablesleep 0"]
        _ = await m.end(reason: .user)
        XCTAssertEqual(m.pendingEnd, .user)

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands(status: 1)
        await waitUntil("pending end never retried") { m.pendingEnd == nil }
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0", "disablesleep 0", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(try lockIsHeld())
    }

    /// Every undo is slower than the deadline and grace, and every one goes
    /// through: each is left running, then exits 0. Each is journaled as
    /// done when it exits, so the end finishes. Run again, any of them would
    /// be left running again, and its exit would start it once more, for
    /// ever.
    func testUndosThatEachExit0LateAreNotRunAgain() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let lowPower = await m.setLowPower(true)
        XCTAssertTrue(lowPower)
        var st = try XCTUnwrap(try h.store.loadState())
        st.displayRestoredUnderLowPower = 0.6
        try h.store.saveState(st)
        h.display.brightness = 0.6
        let before = h.guardFake.calls
        h.guardFake.stillRunning = ["disablesleep 0", "lowpowermode 0"]

        let outcome = await m.end(reason: .user)
        XCTAssertEqual(outcome, .privilegedCommandRunning(pid: 4242))
        h.guardFake.exitStuckCommands()
        await waitUntil("the end never reached the second undo") { m.unfinishedCommand?.pid == 4243 }
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, false, "the first undo exited 0 and was not journaled")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        h.display.brightness = 0.45
        h.guardFake.exitStuckCommands()

        await waitUntil("the end never finished") { m.pendingEnd == nil }
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0", "lowpowermode 0"])
        XCTAssertEqual(h.guardFake.stuck.count, 0)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.display.sets, [0.6], "the display write owed for the end of the mode was lost")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertNil(m.unfinishedCommand)
        XCTAssertFalse(try lockIsHeld())
        XCTAssertEqual(h.notifier.posts.last?.title, "Session restored")
        XCTAssertEqual(h.guardFake.unlockedPrivilegedCalls, [])
    }

    /// After a crash or force quit, the command the earlier run left
    /// running holds the lock (stood in for by another handle here), and
    /// its pid still has the recorded start time and boot session. The
    /// relaunch changes nothing, names the recorded command and pid in the
    /// menu with `sudo kill`, and notifies once, not on every refusal. Once
    /// the lock is free, the next transaction removes the record.
    func testBusyLockNamesTheCommandAnEarlierRunLeftRunning() async throws {
        let identity = FakeSleepGuard.identity(of: 4321)
        try h.store.saveUnfinishedCommand(UnfinishedCommandRecord(
            pid: 4321,
            command: "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0",
            since: h.clock.now,
            identity: identity
        ))
        h.processes.run(4321, as: identity)
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let m = h.makeManager()

        await m.reconcile()

        let error = try XCTUnwrap(m.lastError)
        XCTAssertTrue(error.hasPrefix("reconcile skipped, nothing changed"), error)
        XCTAssertTrue(error.contains("`/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0`, left running by Insomnia since"), error)
        XCTAssertTrue(error.contains("still runs as pid 4321"), error)
        XCTAssertTrue(error.contains("sudo kill 4321"), error)
        let notices = h.notifier.posts.filter { $0.title == SessionManager.commandRunningTitle }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.body.contains("sudo kill 4321") == true, notices.first?.body ?? "")
        await m.start(duration: 60)
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("sudo kill 4321"), m.lastError ?? "")
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.commandRunningTitle }.count, 1, "announced again on every refusal")
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertNotNil(h.store.loadUnfinishedCommand())

        other.release()
        await m.reconcile()
        XCTAssertNil(h.store.loadUnfinishedCommand(), "a record of a command that no longer holds the lock was kept")
    }

    /// The lock is busy, but the recorded pid is not provably the command
    /// any more: gone, given to a process with another start time or boot
    /// session, not readable, or recorded without them by an older build.
    /// No pid is offered for `sudo kill` and nothing is announced: the
    /// advice could stop an unrelated process. The record stays until a
    /// transaction holds the lock.
    func testBusyLockNamesNoPidTheCommandNoLongerProvablyHas() async throws {
        let recorded = FakeSleepGuard.identity(of: 4321)
        let reused = ProcessIdentity(startedAt: recorded.startedAt + 90, startedAtMicros: recorded.startedAtMicros, bootSession: recorded.bootSession)
        let otherBoot = ProcessIdentity(startedAt: recorded.startedAt, startedAtMicros: recorded.startedAtMicros, bootSession: "another-boot")
        let running: (ProcessIdentity) -> ProcessLookup = { .present(ProcessSignalState(ppid: 1, stopped: false, identity: $0)) }
        let cases: [(name: String, identity: ProcessIdentity?, live: ProcessLookup, says: String)] = [
            ("gone", recorded, .absent, "has exited since, so another process holds it"),
            ("reused", recorded, running(reused), "has exited since, so another process holds it"),
            ("other boot", recorded, running(otherBoot), "has exited since, so another process holds it"),
            ("unreadable", recorded, .unreadable(EPERM), "cannot confirm that pid 4321 is still that command, so it names no process to stop"),
            ("no identity", nil, running(recorded), "cannot confirm that pid 4321 is still that command, so it names no process to stop"),
        ]
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        defer { other.release() }
        let m = h.makeManager()
        for c in cases {
            try h.store.saveUnfinishedCommand(UnfinishedCommandRecord(
                pid: 4321,
                command: "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0",
                since: h.clock.now,
                identity: c.identity
            ))
            h.processes.entries = [4321: c.live]

            await m.reconcile()

            let error = try XCTUnwrap(m.lastError, c.name)
            XCTAssertTrue(error.hasPrefix("reconcile skipped, nothing changed"), "\(c.name): \(error)")
            XCTAssertTrue(error.contains(c.says), "\(c.name): \(error)")
            XCTAssertFalse(error.contains("kill"), "\(c.name): a kill offered for an unverified pid: \(error)")
            XCTAssertNotNil(h.store.loadUnfinishedCommand(), "\(c.name): the record went without the lock")
        }
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.commandRunningTitle }.count, 0, "announced a pid that is not the command")
        XCTAssertEqual(h.guardFake.calls, [])
    }

    /// The record goes when the command exits, before the lock is
    /// released, not only when a later transaction finds it stale: here
    /// nothing runs after the exit (no session, nothing pending).
    func testRecordIsRemovedWhenTheCommandExits() async throws {
        let m = h.makeManager()
        h.guardFake.stillRunning = ["lowpowermode 1"]
        _ = await m.setLowPower(true)
        XCTAssertEqual(h.store.loadUnfinishedCommand()?.pid, 4242)

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("the lock was never released") { m.unfinishedCommand == nil }

        XCTAssertNil(h.store.loadUnfinishedCommand(), "the record outlived the command")
        XCTAssertEqual(h.guardFake.calls, ["pmset -g custom", "lowpowermode 1"], "a transaction ran after the exit")
        XCTAssertFalse(try lockIsHeld())
    }

    /// The session on disk, journaled with sleep and Low Power Mode as
    /// Insomnia's, as an earlier run left it. Returns that session.
    private func liveSessionOnDisk() throws -> Session {
        let now = h.clock.now
        let session = Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600))
        try h.store.saveSession(session)
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        journal.lowPowerSetByUs = true
        try h.store.saveState(journal)
        h.guardFake.sleepDisabled = true
        return session
    }

    /// Insomnia crashed while a `lowpowermode 1` it ran was left running,
    /// and the command keeps the lock past the relaunch's bound. The launch
    /// reconcile changes nothing and runs again after each retry delay
    /// while the lock stays busy, announcing the command once. Once the
    /// command has exited, a retry resumes the session and checks the mode
    /// the command left: it failed, so the mode is off, and the ownership
    /// is cleared after a `lowpowermode 0` of Insomnia's own. The floors
    /// then act on the session again: Low Power Mode goes on under its
    /// floor, and a battery under the end floor ends the session.
    func testLaunchReconcileRefusedForABusyLockRunsAgainOnceTheCommandExits() async throws {
        let session = try liveSessionOnDisk()
        let journal = try XCTUnwrap(try h.store.loadState())
        let identity = FakeSleepGuard.identity(of: 4321)
        try h.store.saveUnfinishedCommand(UnfinishedCommandRecord(
            pid: 4321,
            command: "/usr/bin/sudo -n /usr/bin/pmset -a lowpowermode 1",
            since: h.clock.now,
            identity: identity
        ))
        h.processes.run(4321, as: identity)
        // Stands in for the command, which holds the lock through its stdin.
        let command = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let m = h.makeManager(retryDelay: 0.1)
        let resyncs = Locked<[Bool]>([])
        m.resyncAfterCommand = { resyncs.value.append($0) }
        let floors = FloorRuleDriver(manager: m, notifier: h.notifier)

        await m.reconcile()
        // Long enough for several refused retries: each waits out the
        // 0.3 s lock bound, then 0.1 s.
        try await Task.sleep(for: .seconds(1.5))

        XCTAssertNil(m.session)
        XCTAssertTrue(m.lastError?.hasPrefix("reconcile skipped, nothing changed") == true, m.lastError ?? "")
        XCTAssertEqual(h.guardFake.calls, [], "pmset ran without the lock")
        XCTAssertEqual(try h.store.loadSession(), session)
        XCTAssertEqual(try h.store.loadState(), journal)
        XCTAssertEqual(h.notifier.posts.filter { $0.title == SessionManager.commandRunningTitle }.count, 1, "announced again on every retry")

        command.release()
        h.processes.entries = [:]
        await waitUntil("the reconcile never ran again once the lock was free") { resyncs.value == [false] }

        XCTAssertEqual(m.session, session)
        XCTAssertNil(h.store.loadUnfinishedCommand())
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false, "ownership of a mode that is off was kept")

        await floors.run(battery: .percent(30), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn, "the Low Power Mode floor did not act on the resumed session")
        await floors.run(battery: .percent(5), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(m.isActive, "the end floor did not end the resumed session")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.lowPowerOn)
    }

    /// Quit is requested while the refused launch reconcile waits to run
    /// again. The end restores the earlier run's journal once the lock
    /// frees, and the reconcile is dropped: it would resume the session
    /// the user quit, holding sleep for it.
    func testLaunchReconcileWaitingToRunAgainIsDroppedForAnEnd() async throws {
        _ = try liveSessionOnDisk()
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let m = h.makeManager(retryDelay: 0.2)

        await m.reconcile()
        XCTAssertNil(m.session)
        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .locked)
        other.release()
        await waitUntil("the end was never retried") { m.pendingEnd == nil }
        // Past the time any reconcile retry would have run.
        try await Task.sleep(for: .seconds(1))

        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "the reconcile resumed a session the user quit: \(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// The record an earlier run left of a `lowpowermode 1` that did not
    /// stop on SIGTERM. The command has since exited and failed: Low Power
    /// Mode is off (`FakeSleepGuard` starts with it off).
    private func recordFailedLowPowerEnable() throws {
        try h.store.saveUnfinishedCommand(UnfinishedCommandRecord(
            pid: 4321,
            command: "/usr/bin/sudo -n /usr/bin/pmset -a lowpowermode 1",
            since: h.clock.now,
            identity: FakeSleepGuard.identity(of: 4321)
        ))
    }

    /// The relaunch finds the record of the command and a free lock, but
    /// state.json does not decode. The refusal removes the record; once
    /// the file is fixed, the retry still checks the mode for the session
    /// it resumes, and the Low Power Mode floor acts on it again.
    func testLaunchReconcileRefusedForAnUnreadableJournalStillChecksTheMode() async throws {
        let session = try liveSessionOnDisk()
        try recordFailedLowPowerEnable()
        let stateFile = h.home.paths.stateFile
        let journal = try Data(contentsOf: stateFile)
        try Data("{".utf8).write(to: stateFile)
        let m = h.makeManager(retryDelay: 0.1)
        let resyncs = Locked<[Bool]>([])
        m.resyncAfterCommand = { resyncs.value.append($0) }
        let floors = FloorRuleDriver(manager: m, notifier: h.notifier)

        await m.reconcile()

        XCTAssertNil(m.session)
        XCTAssertNil(h.store.loadUnfinishedCommand(), "precondition: the refusal removes the record")
        XCTAssertEqual(h.guardFake.calls, [])
        try journal.write(to: stateFile)
        await waitUntil("the resumed session was never checked against the mode") { resyncs.value == [false] }

        XCTAssertEqual(m.session, session)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false, "ownership of a mode that is off was kept")
        await floors.run(battery: .percent(30), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn, "the Low Power Mode floor did not act on the resumed session")
    }

    /// The command exits while the refused launch reconcile waits to run
    /// again, and the user starts a session first. The start drops the
    /// reconcile and runs the check it owed: the journal it keeps still
    /// claims the mode the failed command never switched on.
    func testStartBeforeTheReconcileRetryTakesOverTheModeCheck() async throws {
        let old = try liveSessionOnDisk()
        try recordFailedLowPowerEnable()
        h.processes.run(4321, as: FakeSleepGuard.identity(of: 4321))
        // Stands in for the command, which holds the lock through its stdin.
        let command = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let m = h.makeManager()
        let resyncs = Locked<[Bool]>([])
        m.resyncAfterCommand = { resyncs.value.append($0) }
        let floors = FloorRuleDriver(manager: m, notifier: h.notifier)

        await m.reconcile()
        XCTAssertNil(m.session)
        command.release()
        h.processes.entries = [:]
        await m.start(duration: 3600)

        let session = try XCTUnwrap(m.session)
        XCTAssertNotEqual(session, old)
        XCTAssertEqual(try h.store.loadSession(), session)
        XCTAssertNil(h.store.loadUnfinishedCommand())
        XCTAssertEqual(resyncs.value, [false], "the started session was never checked against the mode")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false, "ownership of a mode that is off was kept")
        await floors.run(battery: .percent(30), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn, "the Low Power Mode floor did not act on the started session")
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
        XCTAssertEqual(
            h.guardFake.calls.suffix(3), ["lowpowermode 1", "pmset -g custom", "lowpowermode 0"],
            "the mode read off, then switched off by the check before the ownership is cleared"
        )
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false, "ownership of a mode that is off kept after the command exited")
        XCTAssertFalse(try lockIsHeld())

        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["lowpowermode 0", "disablesleep 0"])
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
    /// once it has exited; it exited 0, so there is nothing left to undo.
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
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(try lockIsHeld())
    }

    /// `lowpowermode 1` fails outright and the rollback `lowpowermode 0` is
    /// the command left running: it is tracked like any other, so the lock
    /// stays with it and ownership stays journaled while it runs. The
    /// rollback exits 0 in the end: the ownership is cleared under the
    /// lock, and the floors run on the corrected journal and switch the
    /// mode on again, which a stale flag would have stopped them doing.
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
            ["disablesleep 1", "pmset -g custom", "lowpowermode 1", "lowpowermode 0", "pmset -g custom", "lowpowermode 1"],
            "the floors' enable on a journal that no longer claims the mode, and no second switch-off"
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
        // Exit 1, so the retry runs the command again and shows where the
        // first end stopped.
        h.guardFake.stuckExitStatus = 1

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
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.first?.volume, 0.6)
        h.guardFake.stillRunning = ["lowpowermode 1"]
        _ = await m.setLowPower(true)

        await actions.onOpen()

        XCTAssertTrue(m.lidEventDeferred)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.first?.volume, 0.6, "lid actions undone beside the live pmset")
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
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])

        let replays = Locked<[Bool]>([])
        m.resyncAfterCommand = { replay in
            replays.value.append(replay)
            if replay { Task { @MainActor in await actions.onClose() } }
        }
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("refused lid close never replayed") { self.h.audio.mutes == 1 }
        XCTAssertEqual(replays.value, [true])
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.first?.volume, 0.6)
        XCTAssertFalse(m.lidEventDeferred)
    }

    /// A reconnect refused while the command runs is not something the
    /// command's exit replays, and CoreAudio sends no second event: the
    /// in-process audio retry gives the headset its volume back once the
    /// command has exited.
    func testAReconnectRefusedWhileTheCommandRunsIsRetriedAfterItExits() async throws {
        let headset = SavedAudioOutput(deviceUID: "usb-headset", name: "USB Headset", volume: 0.3, muted: false, saveID: "save-1")
        var earlier = RuntimeState()
        earlier.savedAudioOutputs = [headset]
        try h.store.saveState(earlier)
        let m = h.makeManager(retryDelay: 0.2)
        await m.reconcile()
        XCTAssertEqual(m.outputsWaitingForRestore, [headset])
        await m.start(duration: 3600)
        h.guardFake.stillRunning = ["lowpowermode 1"]
        _ = await m.setLowPower(true)
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)

        await m.outputDevicesChanged()

        XCTAssertTrue(h.audio.applied.isEmpty, "restored beside the live pmset")
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [headset])

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("refused reconnect never retried") {
            (try? self.h.store.loadState())?.savedAudioOutputs.isEmpty == true
        }
        XCTAssertEqual(h.audio.device("usb-headset")?.volume, 0.3)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertNotNil(m.session)
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

    /// The rollback `lowpowermode 0` is left running, as above. The tests
    /// that use this end it with a nonzero exit (`exitTheRollback`) while
    /// the mode reads off, so the flag claims a mode that is off and only
    /// the check can correct it. Started with the flag journaled and the
    /// floors running on it, as AppServices runs them.
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

    /// Exit 1 confirms nothing; the mode reads off all the same (the
    /// `lowpowermode 1` it rolls back never took effect).
    private func exitTheRollback() {
        h.guardFake.exitStuckCommands(status: 1)
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
        exitTheRollback()

        await waitUntil("the check never ran again after the failed read") { floorRuns.value == 2 }
        XCTAssertEqual(
            Array(h.guardFake.calls.dropFirst(before.count)),
            ["pmset -g custom", "pmset -g custom", "lowpowermode 0", "pmset -g custom", "lowpowermode 1"],
            "the failed read, the retried check and its switch-off, then the floors' enable on the corrected journal"
        )
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")
        XCTAssertFalse(try lockIsHeld())
    }

    /// The rollback exits 0, but the journal cannot be written, so its
    /// undo cannot be journaled as done. The check after it reads the mode
    /// off and switches it off, and cannot write the journal either. The
    /// flag stays on disk, the clear is owed, and the check runs again
    /// after the retry delay. By then the journal takes writes: the owed
    /// clear lands as the transaction starts, so the check finds no
    /// ownership and runs no second `lowpowermode 0`, and the floors switch
    /// the mode on again.
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
            ["pmset -g custom", "lowpowermode 0", "pmset -g custom", "lowpowermode 1"],
            "the check whose write failed, then the floors' enable after the retried check landed the owed clear"
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

        exitTheRollback()

        await waitUntil("the unreadable journal was never reported") {
            self.h.notifier.posts.contains { $0.title == SessionManager.journalTitle }
        }
        XCTAssertEqual(floorRuns.value, 0, "the floors ran on a journal that could not be read")
        try journal.write(to: stateFile)
        await waitUntil("the check never ran again after the journal was fixed") { floorRuns.value == 1 }
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.guardFake.calls.suffix(4), ["pmset -g custom", "lowpowermode 0", "pmset -g custom", "lowpowermode 1"])
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
        exitTheRollback()
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

    /// The mode reads off after the exit, but the check's own
    /// `lowpowermode 0` fails. A reading is no confirmed undo, so the
    /// ownership stays journaled for the floors' pass that runs at once,
    /// and the check runs again after the retry delay: that switch-off
    /// exits 0, the ownership is cleared, and the floors switch the mode
    /// on again.
    func testCheckWhoseSwitchOffFailsKeepsTheOwnershipAndRunsAgain() async throws {
        let m = h.makeManager(retryDelay: 0.2)
        let flags = Locked<[Bool?]>([])
        let floorRuns = floorsOnBattery(m) { [guardFake = h.guardFake, store = h.store] in
            flags.value.append(try? store.loadState()?.lowPowerSetByUs)
            guardFake.throwOn = []
        }
        try await startWithRollbackLeftRunning(m)
        let before = h.guardFake.calls

        h.guardFake.throwOn = ["lowpowermode 0"]
        exitTheRollback()

        await waitUntil("the check never ran again after the failed switch-off") { floorRuns.value == 2 }
        XCTAssertEqual(flags.value, [true, false], "ownership cleared on a lowpowermode 0 that failed")
        XCTAssertEqual(
            Array(h.guardFake.calls.dropFirst(before.count)),
            ["pmset -g custom", "lowpowermode 0", "pmset -g custom", "lowpowermode 0", "pmset -g custom", "lowpowermode 1"],
            "the failed switch-off, the retried check, then the floors' enable"
        )
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertFalse(try lockIsHeld())
    }

    /// The check's own `lowpowermode 0` is left running in turn. It is
    /// tracked like any other: the ownership stays, the lock goes to it,
    /// and nothing is replayed or run beside it. It exits 0: the ownership
    /// is cleared under its lock, and the pass runs the floors.
    func testCheckWhoseSwitchOffIsLeftRunningRunsAgainWhenItExits() async throws {
        let m = h.makeManager()
        let floorRuns = floorsOnBattery(m) {}
        try await startWithRollbackLeftRunning(m)
        let before = h.guardFake.calls

        h.guardFake.stillRunning = ["lowpowermode 0"]
        exitTheRollback()

        await waitUntil("the check's switch-off was never tracked") { m.unfinishedCommand?.pid == 4243 }
        XCTAssertEqual(Array(h.guardFake.calls.dropFirst(before.count)), ["pmset -g custom", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true, "ownership cleared beside the live switch-off")
        XCTAssertTrue(try lockIsHeld(), "recovery lock released with the check's switch-off still running")
        XCTAssertTrue(try XCTUnwrap(m.commandWarning).contains("sudo kill 4243"), m.commandWarning ?? "")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(floorRuns.value, 0, "the floors ran beside the live switch-off")

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("the pass never ran again after the switch-off exited") { floorRuns.value == 1 }
        XCTAssertEqual(
            Array(h.guardFake.calls.dropFirst(before.count)),
            ["pmset -g custom", "lowpowermode 0", "pmset -g custom", "lowpowermode 1"]
        )
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertNil(m.commandWarning)
        XCTAssertFalse(try lockIsHeld())
    }

    /// A display write is owed for the end of the mode, and the
    /// `lowpowermode 0` that would settle it is left running and goes
    /// through, so powerd rescales the panel. Exit 0 confirms the switch-off
    /// and the owed value is written, rescaled panel or not.
    func testSwitchOffThatExits0WritesTheOwedDisplayOverTheRescale() async throws {
        let m = h.makeManager()
        m.resyncAfterCommand = { _ in }
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        var st = try XCTUnwrap(try h.store.loadState())
        st.displayRestoredUnderLowPower = 0.6
        try h.store.saveState(st)
        h.display.brightness = 0.6
        h.guardFake.stillRunning = ["lowpowermode 0"]

        let off = await m.setLowPower(false)

        XCTAssertFalse(off)
        XCTAssertEqual(try h.store.loadState()?.displayRestoredUnderLowPower, 0.6, "write dropped though the panel had not moved")
        h.display.brightness = 0.45
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("ownership never cleared after the exit") { (try? self.h.store.loadState()?.lowPowerSetByUs) == false }
        XCTAssertEqual(h.display.sets, [0.6], "the panel left at powerd's rescaled value")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertNil(try h.store.loadState()?.displayRestoredUnderLowPower)
    }

    /// The same, but state.json does not decode when the switch-off exits
    /// 0: nothing is written or cleared, and the mode is known off. The
    /// end once the file reads again writes the owed value over powerd's
    /// rescale and does not switch the mode off again, which would read
    /// the rescale as a change by the user and drop the write.
    func testSwitchOffThatExits0OnAnUnreadableJournalStillWritesTheOwedDisplay() async throws {
        let m = h.makeManager(retryDelay: 3600)
        m.resyncAfterCommand = { _ in }
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        var st = try XCTUnwrap(try h.store.loadState())
        st.displayRestoredUnderLowPower = 0.6
        try h.store.saveState(st)
        h.display.brightness = 0.6
        h.guardFake.stillRunning = ["lowpowermode 0"]
        let off = await m.setLowPower(false)
        XCTAssertFalse(off)
        let stateFile = h.home.paths.stateFile
        let journal = try Data(contentsOf: stateFile)
        let broken = Data("{ not json".utf8)
        try broken.write(to: stateFile)

        h.display.brightness = 0.45
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()

        await waitUntil("the lock never went with the exit") { m.unfinishedCommand == nil }
        XCTAssertEqual(h.display.sets, [], "written on a journal not read")
        XCTAssertEqual(try Data(contentsOf: stateFile), broken, "an unreadable journal was overwritten")
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("low power mode is off, and the clear and the display write owed after it (0.6) wait for the journal to read again"), log)
        XCTAssertFalse(try lockIsHeld())

        try journal.write(to: stateFile)
        let before = h.guardFake.calls
        let ended = await m.end(reason: .user)

        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(h.display.sets, [0.6])
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertFalse(h.guardFake.calls.dropFirst(before.count).contains("lowpowermode 0"), "the mode known off was switched off again")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse((m.lastError ?? "").contains("wait for the journal to read again"), m.lastError ?? "")
    }

    /// The same, and the file that reads again no longer owes the write:
    /// the panel is left as it is.
    func testSwitchOffThatExits0OnAnUnreadableJournalWritesNothingTheFixedJournalDoesNotOwe() async throws {
        let m = h.makeManager(retryDelay: 3600)
        m.resyncAfterCommand = { _ in }
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        var st = try XCTUnwrap(try h.store.loadState())
        st.displayRestoredUnderLowPower = 0.6
        try h.store.saveState(st)
        h.display.brightness = 0.6
        h.guardFake.stillRunning = ["lowpowermode 0"]
        _ = await m.setLowPower(false)
        try Data("{ not json".utf8).write(to: h.home.paths.stateFile)
        h.display.brightness = 0.45
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("the lock never went with the exit") { m.unfinishedCommand == nil }

        st.displayRestoredUnderLowPower = nil
        try h.store.saveState(st)
        _ = await m.end(reason: .user)

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.45)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The same, but the switch-off exits 1 after switching the mode off,
    /// and powerd rescales the panel. The check reads the mode off and runs
    /// its own `lowpowermode 0`. It does not compare the panel with the
    /// owed value first: with the mode off, the rescale looks the same as a
    /// user's change. The owed value is written once the switch-off is
    /// confirmed.
    func testCheckKeepsTheOwedDisplayWriteThroughTheRescale() async throws {
        let m = h.makeManager()
        m.resyncAfterCommand = { _ in }
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        var st = try XCTUnwrap(try h.store.loadState())
        st.displayRestoredUnderLowPower = 0.6
        try h.store.saveState(st)
        h.display.brightness = 0.6
        h.guardFake.stillRunning = ["lowpowermode 0"]
        _ = await m.setLowPower(false)
        let before = h.guardFake.calls

        h.guardFake.lowPowerOn = false
        h.display.brightness = 0.45
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands(status: 1)
        await waitUntil("ownership never cleared after the check") { (try? self.h.store.loadState()?.lowPowerSetByUs) == false }
        XCTAssertEqual(Array(h.guardFake.calls.dropFirst(before.count)), ["pmset -g custom", "lowpowermode 0"])
        XCTAssertEqual(h.display.sets, [0.6], "the rescale was taken for a user's change and the owed write dropped")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertNil(try h.store.loadState()?.displayRestoredUnderLowPower)
    }

    // MARK: A late undo whose journal entry cannot be cleared

    /// Rename over an immutable state.json is refused, so no journal write
    /// lands; the file still reads.
    private func lockJournal(_ locked: Bool) throws {
        let file = h.home.paths.stateFile.path
        if locked { addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) } }
        try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: file)
    }

    /// A `lowpowermode 0` left running exits 0, and the write that would
    /// clear its entry fails. The command's line goes with the exit; the
    /// menu says instead that the entry stays and is retried. The check
    /// that follows cannot read the mode here, which it only logs, so that
    /// line stays in the menu. The clear is owed: once the journal takes
    /// writes, the retried check's transaction lands it first, and the
    /// check runs no second `lowpowermode 0` after the one that exited 0.
    /// The line goes with the entry while the session still runs.
    func testLateSwitchOffWhoseClearFailsIsShownInTheMenu() async throws {
        let m = h.makeManager(retryDelay: 0.2)
        m.resyncAfterCommand = { _ in }
        try await startWithRollbackLeftRunning(m)
        let before = h.guardFake.calls
        try lockJournal(true)
        h.guardFake.throwOn = ["pmset -g custom"]

        h.guardFake.exitStuckCommands()

        await waitUntil("the lock never went with the exit") { m.unfinishedCommand == nil }
        XCTAssertNil(m.commandWarning)
        let error = try XCTUnwrap(m.lastError, "the failed clear left the menu silent")
        XCTAssertTrue(error.hasPrefix("low power mode switched off (`/usr/bin/sudo -n /usr/bin/pmset lowpowermode 0` (pid 4242) exited 0) but the journal entry could not be cleared"), error)
        XCTAssertTrue(error.hasSuffix("it will be retried"), error)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(m.lastError, error, "a retried check that only logs took the line away")

        try lockJournal(false)
        h.guardFake.throwOn = []
        await waitUntil("the retried check never cleared the entry") { (try? self.h.store.loadState()?.lowPowerSetByUs) == false }
        let after = Array(h.guardFake.calls.dropFirst(before.count))
        XCTAssertFalse(after.isEmpty, "the check never read the mode")
        XCTAssertEqual(after.filter { $0 != "pmset -g custom" }, [], "the mode switched off again after a lowpowermode 0 that exited 0")
        XCTAssertNil(m.lastError, "the line still says a clear that went through will be retried")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertFalse(try lockIsHeld())
    }

    /// The rollback exits 1, so the check runs its own `lowpowermode 0`;
    /// that exits 0 and its clear fails. The menu says so.
    func testCheckWhoseClearFailsIsShownInTheMenu() async throws {
        let m = h.makeManager()
        m.resyncAfterCommand = { _ in }
        try await startWithRollbackLeftRunning(m)
        let before = h.guardFake.calls
        try lockJournal(true)

        exitTheRollback()

        await waitUntil("the check never ran") { h.guardFake.calls.count == before.count + 2 && m.unfinishedCommand == nil }
        await waitUntil("the failed clear left the menu silent") { m.lastError?.hasPrefix("low power mode confirmed off after the power command but the journal entry could not be cleared") == true }
        XCTAssertEqual(Array(h.guardFake.calls.dropFirst(before.count)), ["pmset -g custom", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertNil(m.commandWarning)
    }

    /// An end's `disablesleep 0` left running exits 0, and the clear fails.
    /// The command's line goes with the exit and the menu says the entry
    /// stays. The retried end runs the undo again (held at the fake's gate
    /// while the menu is read), and finishes once the journal takes writes;
    /// the line goes then.
    func testLateUndoOfAnEndWhoseClearFailsIsShownAndRunAgain() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let before = h.guardFake.calls
        h.guardFake.stillRunning = ["disablesleep 0"]
        _ = await m.end(reason: .user)
        XCTAssertEqual(m.pendingEnd, .user)
        // The stuck call never reached the gate; the retry's waits there.
        let gate = AsyncGate()
        h.guardFake.restoreGate = gate
        try lockJournal(true)

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()

        await gate.waitUntilStarted()
        XCTAssertNil(m.commandWarning)
        let error = try XCTUnwrap(m.lastError, "the failed clear left the menu silent")
        XCTAssertTrue(error.hasPrefix("sleep restored (`/usr/bin/sudo -n /usr/bin/pmset disablesleep 0` (pid 4242) exited 0) but the journal entry could not be cleared"), error)
        XCTAssertTrue(error.hasSuffix("it will be retried"), error)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)

        try lockJournal(false)
        await gate.open()
        await waitUntil("the retried end never finished") { m.pendingEnd == nil && (try? self.h.store.loadState()) == RuntimeState.clean }
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0", "disablesleep 0"], "the unconfirmed undo was not run again")
        XCTAssertNil(m.lastError, "the line still says a clear that went through will be retried")
        XCTAssertFalse(try lockIsHeld())
    }

    /// A `lowpowermode 0` left running exits 0 while state.json does not
    /// decode: nothing is cleared or overwritten, and the menu says the
    /// entry could not be cleared. No session, so no check runs after; the
    /// line goes once the file is fixed and a switch-off clears the entry.
    func testLateSwitchOffOnAnUnreadableJournalIsShownInTheMenu() async throws {
        var st = RuntimeState.clean
        st.lowPowerSetByUs = true
        try h.store.saveState(st)
        h.guardFake.lowPowerOn = true
        let m = h.makeManager()
        h.guardFake.stillRunning = ["lowpowermode 0"]
        _ = await m.setLowPower(false)
        XCTAssertEqual(m.unfinishedCommand?.pid, 4242)
        let broken = Data("{ not json".utf8)
        try broken.write(to: h.home.paths.stateFile)

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()

        await waitUntil("the lock never went with the exit") { m.unfinishedCommand == nil }
        let error = try XCTUnwrap(m.lastError, "the unreadable journal left the menu silent")
        XCTAssertTrue(error.hasPrefix("`/usr/bin/sudo -n /usr/bin/pmset lowpowermode 0` (pid 4242) exited 0, but the journal could not be read to clear its entry"), error)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), broken, "an unreadable journal was overwritten")
        XCTAssertFalse(try lockIsHeld())

        try h.store.saveState(st)
        let off = await m.setLowPower(false)
        XCTAssertTrue(off)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.lastError, "the line still says a clear that went through will be retried")
    }
}
