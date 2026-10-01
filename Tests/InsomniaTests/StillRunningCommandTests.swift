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
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("pid 4242"), m.lastError ?? "")
        let postsBefore = h.notifier.posts.count

        // Quit is refused without running anything, and a start is refused.
        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .privilegedCommandRunning(pid: 4242))
        XCTAssertFalse(m.quitRequested)
        await m.start(duration: 60)
        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, before + ["disablesleep 0"], "a transaction ran while the lock was held for the command")
        XCTAssertEqual(h.notifier.posts.count, postsBefore, "told again on every refused transaction")

        // The command exits: the lock is released and the end retried.
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }
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
    /// the lock is held for the command alone: once it exits nothing is
    /// pending, and the session end clears the mode as usual.
    func testLowPowerOnStopsAtTheLiveCommandWithoutARollback() async throws {
        h.guardFake.stillRunning = ["lowpowermode 1"]
        let m = h.makeManager()
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
        h.guardFake.exitStuckCommands()
        await waitUntil("lock never released") { (try? self.lockIsHeld()) == false }
        XCTAssertNil(m.unfinishedCommand)
        XCTAssertNotNil(m.session, "session ended though nothing was pending")
        XCTAssertNil(m.pendingEnd)

        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["disablesleep 0", "lowpowermode 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
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
}
