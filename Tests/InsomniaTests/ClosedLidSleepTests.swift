import XCTest
@testable import Insomnia

/// A timer or floor-rule end with the lid closed asks macOS to sleep, after
/// sleep is restored and the recovery lock is free (spec section 6).
@MainActor
final class ClosedLidSleepTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    /// A request made with sleep restored and the lock free.
    private static let asked = FakeClosedLidSleep.Request(sleepDisabled: false, lockHeld: false)
    /// A request macOS refused because sleep was still disabled.
    private static let refused = FakeClosedLidSleep.Request(sleepDisabled: true, lockHeld: false)

    /// A session started with the lid open, then the lid closed.
    private func sessionWithTheLidClosed(_ h: Harness, lockTimeout: TimeInterval = 0.3, retryDelay: TimeInterval = 60) async -> SessionManager {
        let m = h.makeManager(lockTimeout: lockTimeout, retryDelay: retryDelay)
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        h.clamshell.closed = true
        return m
    }

    /// The end that a command's exit runs again runs on the main actor
    /// after the fake child exits; poll for its effect.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), what)
    }

    /// The case from the bag: a critical thermal state with the lid closed
    /// ends the session through the floor rules, and the Mac is asked to
    /// sleep after `disablesleep 0`, with the lock free.
    func testCriticalThermalStateWithTheLidClosedEndsTheSessionAndAsksForSleep() async throws {
        let m = await sessionWithTheLidClosed(h)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)

        await driver.run(battery: .percent(80), isCharging: false, thermal: .critical, lidClosed: true)

        XCTAssertNil(m.session)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(h.lidSleep.requests, [Self.asked], "no sleep asked for, or asked before sleep was restored or the lock released")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The timer end too (#94): another app's idle assertion can hold off
    /// idle sleep for hours.
    func testTimerAndBatteryEndsWithTheLidClosedAskForSleep() async {
        for reason in [EndReason.timer, .batteryFloor, .batteryUnreadable] {
            let h = Harness()
            defer { h.home.destroy() }
            let m = await sessionWithTheLidClosed(h)

            let outcome = await m.end(reason: reason)

            XCTAssertEqual(outcome, .restored, "\(reason)")
            XCTAssertEqual(h.lidSleep.requests, [Self.asked], "\(reason)")
        }
    }

    /// Ends the floor rules do not make leave a closed Mac to macOS, as
    /// before.
    func testOtherEndsWithTheLidClosedAskNothing() async {
        for reason in [EndReason.user, .quit] {
            let h = Harness()
            defer { h.home.destroy() }
            let m = await sessionWithTheLidClosed(h)

            let outcome = await m.end(reason: reason)

            XCTAssertEqual(outcome, .restored, "\(reason)")
            XCTAssertEqual(h.lidSleep.requests, [], "\(reason)")
        }
    }

    /// The user is at an open lid, or the lid cannot be read: no request.
    func testFloorEndWithTheLidOpenOrUnknownAsksNothing() async {
        for lid in [false, nil] as [Bool?] {
            let h = Harness()
            defer { h.home.destroy() }
            let m = h.makeManager()
            await m.start(duration: 3600)
            h.clamshell.closed = lid

            let outcome = await m.end(reason: .thermalCritical)

            XCTAssertEqual(outcome, .restored)
            XCTAssertEqual(h.lidSleep.requests, [], "lid \(String(describing: lid))")
        }
    }

    /// macOS keeps this closed Mac awake (an external display in clamshell
    /// mode), or its answer cannot be read: no request, so a Mac in use on
    /// an external display is never put to sleep.
    func testFloorEndWhenMacOSKeepsAClosedMacAwakeAsksNothing() async {
        for causesSleep in [false, nil] as [Bool?] {
            let h = Harness()
            defer { h.home.destroy() }
            let m = await sessionWithTheLidClosed(h)
            h.lidSleep.causesSleep = causesSleep

            let outcome = await m.end(reason: .thermalCritical)

            XCTAssertEqual(outcome, .restored)
            XCTAssertEqual(h.lidSleep.requests, [], "causes sleep \(String(describing: causesSleep))")
        }
    }

    /// An end refused for a busy lock changed nothing and asks nothing;
    /// the end that runs once the lock is free asks.
    func testEndRefusedForTheLockAsksWhenItRunsAgain() async throws {
        let m = await sessionWithTheLidClosed(h)
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())

        let refused = await m.end(reason: .thermalCritical)

        XCTAssertEqual(refused, .locked)
        XCTAssertEqual(h.lidSleep.requests, [], "asked for sleep with sleep still disabled")
        other.release()

        let again = await m.end(reason: .thermalCritical)

        XCTAssertEqual(again, .restored)
        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
    }

    /// An end stopped at a live `disablesleep 0` asks nothing while the
    /// command runs; the end its exit runs again asks, after the lock the
    /// command held is free.
    func testEndStoppedAtALiveCommandAsksOnceTheCommandExits() async throws {
        let m = await sessionWithTheLidClosed(h)
        h.guardFake.stillRunning = ["disablesleep 0"]

        let outcome = await m.end(reason: .thermalCritical)

        XCTAssertEqual(outcome, .privilegedCommandRunning(pid: 4242))
        XCTAssertEqual(h.lidSleep.requests, [], "asked for sleep beside a live sudo pmset")

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }

        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// A failed `disablesleep 0` leaves sleep disabled, and macOS refuses
    /// the request. It is asked again until the recovery agent restores
    /// sleep, then once more, and no further.
    func testRefusedRequestAsksAgainOnceSleepIsRestored() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        h.guardFake.throwOn = ["disablesleep 0"]

        let outcome = await m.end(reason: .thermalCritical)

        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertEqual(h.lidSleep.requests, [Self.refused])
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)

        h.guardFake.sleepDisabled = false
        await waitUntil("not asked again once sleep was restored") { h.lidSleep.requests.last == Self.asked }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.lidSleep.requests.filter { $0 != Self.refused }, [Self.asked])
    }

    /// A quit whose `disablesleep 0` fails again lets the recovery agent
    /// restore sleep, but only the app asks for the sleep, so it stays.
    func testQuitWaitsWhileTheSleepIsOwed() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)

        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .incomplete(agentArmed: true))
        XCTAssertTrue(m.closedLidSleepOwed, "the quit would drop the owed sleep")
        XCTAssertFalse(m.letsQuitGo(after: quit), "the quit would drop the owed sleep")
        XCTAssertFalse(m.quitRequested, "starts stay refused while the app stays")
        h.guardFake.sleepDisabled = false
        await waitUntil("not asked once sleep was restored") { h.lidSleep.requests.last == Self.asked }
        XCTAssertFalse(m.closedLidSleepOwed)
    }

    /// Sleep is never restored (the sudoers rule went away during the
    /// session, say): every `disablesleep 0` fails, so macOS refuses every
    /// request, recovery agent or not. The owed sleep is given up after a
    /// bounded number of refusals and a quit goes through. A restore that
    /// comes later asks nothing: the person may be using the Mac by then.
    func testSleepThatIsNeverRestoredIsGivenUpAndTheQuitGoes() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.02)
        h.guardFake.throwOn = ["disablesleep 0"]
        let limit = SessionManager.closedLidSleepRefusalLimit

        let ended = await m.end(reason: .thermalCritical)

        XCTAssertEqual(ended, .incomplete(agentArmed: true))
        XCTAssertTrue(m.closedLidSleepOwed)
        await waitUntil("the owed sleep was never given up") { !m.closedLidSleepOwed }
        XCTAssertEqual(h.lidSleep.requests, Array(repeating: Self.refused, count: limit))

        // Ten more retry intervals with sleep restored: nothing asks.
        h.guardFake.sleepDisabled = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.lidSleep.requests.count, limit, "asked again after giving up")

        h.guardFake.sleepDisabled = true
        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .incomplete(agentArmed: true))
        XCTAssertTrue(m.letsQuitGo(after: quit), "the quit is still held for a sleep that is never granted")
        XCTAssertEqual(h.lidSleep.requests.count, limit, "the quit asked again after giving up")
    }

    /// An ask postponed while a `sudo pmset` is left running is not a
    /// refusal: a command that runs for longer than the bound does not use
    /// it up, and the sleep is asked once the command exits.
    func testPostponedRequestsDoNotCountTowardTheBound() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.02)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        XCTAssertEqual(h.lidSleep.requests, [Self.refused])
        h.guardFake.throwOn = []
        h.guardFake.stillRunning = ["disablesleep 0"]
        let stuck = await m.end(reason: .user)
        XCTAssertEqual(stuck, .privilegedCommandRunning(pid: 4242))

        // Over twice the bound's worth of retry intervals beside the command.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(m.closedLidSleepOwed, "postponed requests used up the bound")
        XCTAssertEqual(h.lidSleep.requests, [Self.refused], "asked for sleep beside a live sudo pmset")

        h.guardFake.sleepDisabled = false
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("not asked once the command exited") { h.lidSleep.requests.last == Self.asked }
        XCTAssertEqual(h.lidSleep.requests, [Self.refused, Self.asked])
    }

    /// The bound belongs to one owed sleep. A later session's end that owes
    /// one is asked up to the bound again, whatever the last one used.
    func testANewOwedSleepStartsANewCount() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        let limit = SessionManager.closedLidSleepRefusalLimit
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        await waitUntil("not asked again") { h.lidSleep.requests.count >= 3 }
        h.guardFake.throwOn = []
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        XCTAssertFalse(m.closedLidSleepOwed)
        let before = h.lidSleep.requests.count

        h.guardFake.throwOn = ["disablesleep 0"]
        let outcome = await m.end(reason: .batteryFloor)

        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertTrue(m.closedLidSleepOwed, "the earlier refusals counted against this end")
        await waitUntil("the owed sleep was never given up") { !m.closedLidSleepOwed }
        XCTAssertEqual(h.lidSleep.requests.count - before, limit)
    }

    /// Once the lid opens, a refused request is not asked again.
    func testOpeningTheLidStopsAskingAgain() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)

        h.clamshell.closed = false
        h.guardFake.sleepDisabled = false
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(h.lidSleep.requests, [Self.refused], "asked an open Mac to sleep")
    }

    /// The lid opened and closed again between two asks: no ask sees the
    /// open, so only the lid watcher can. The open drops the owed sleep and
    /// the close does not bring it back, so nothing asks once sleep is
    /// restored, and a quit no longer waits.
    func testOpeningAndClosingTheLidBetweenAsksDropsTheOwedSleep() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        XCTAssertEqual(h.lidSleep.requests, [Self.refused])
        XCTAssertTrue(h.lidWatcher.running, "the lid is not watched while the sleep is owed")

        // Both moves land before the next ask can run.
        h.moveLid(closed: false)
        h.moveLid(closed: true)

        XCTAssertFalse(m.closedLidSleepOwed, "the open did not drop the owed sleep")
        XCTAssertFalse(h.lidWatcher.running, "the lid is still watched with nothing owed")
        h.guardFake.sleepDisabled = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.lidSleep.requests, [Self.refused], "put the Mac to sleep after the lid was opened")

        let quit = await m.end(reason: .quit)

        XCTAssertTrue(m.letsQuitGo(after: quit), "the quit still waits for a dropped sleep")
        XCTAssertEqual(h.lidSleep.requests, [Self.refused], "the quit asked for a dropped sleep")
    }

    /// The same open and close while the end waits for a `disablesleep 0`
    /// left running, before the first ask. The end that the command's exit
    /// runs again asks nothing, though the lid is closed by then.
    func testOpeningTheLidWhileTheEndWaitsForACommandDropsTheOwedSleep() async throws {
        let m = await sessionWithTheLidClosed(h)
        h.guardFake.stillRunning = ["disablesleep 0"]
        let outcome = await m.end(reason: .thermalCritical)
        XCTAssertEqual(outcome, .privilegedCommandRunning(pid: 4242))

        h.moveLid(closed: false)
        h.moveLid(closed: true)
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }

        XCTAssertEqual(h.lidSleep.requests, [], "put the Mac to sleep after the lid was opened")
        XCTAssertFalse(m.closedLidSleepOwed)
        XCTAssertFalse(h.lidWatcher.running)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// At launch too: the sleep a reconcile owes for an expired session is
    /// dropped by an open while its end waits for a command left running.
    func testOpeningTheLidWhileTheLaunchReconcileWaitsForACommandDropsTheOwedSleep() async throws {
        try seedExpiredSession(h)
        h.clamshell.closed = true
        h.guardFake.stillRunning = ["disablesleep 0"]
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertTrue(m.closedLidSleepOwed)
        XCTAssertTrue(h.lidWatcher.running, "the lid is not watched while the sleep is owed")

        h.moveLid(closed: false)
        h.moveLid(closed: true)
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }

        XCTAssertEqual(h.lidSleep.requests, [], "put the Mac to sleep after the lid was opened")
        XCTAssertFalse(m.closedLidSleepOwed)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// An open while the end is suspended, still restoring sleep at the
    /// `disablesleep 0`: the ask after the end finds nothing owed.
    func testOpeningTheLidWhileTheEndRestoresSleepDropsTheOwedSleep() async throws {
        let m = await sessionWithTheLidClosed(h)
        let gate = AsyncGate()
        h.guardFake.restoreGate = gate

        let end = Task { await m.end(reason: .thermalCritical) }
        await gate.waitUntilStarted()
        XCTAssertTrue(h.lidWatcher.running, "the lid is not watched while the end restores sleep")
        h.moveLid(closed: false)
        h.moveLid(closed: true)
        await gate.open()
        let outcome = await end.value

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(h.lidSleep.requests, [], "put the Mac to sleep after the lid was opened")
        XCTAssertFalse(m.closedLidSleepOwed)
        XCTAssertFalse(h.lidWatcher.running)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// An open while an end refused for the lock waits to run again. The
    /// session is still active, so that end has not happened yet: the open
    /// drops the sleep, and the end that runs once the lock is free finds
    /// the session and owes it anew for the lid closed at that end.
    func testEndRunAgainAfterTheLockOwesTheSleepAnewAfterAnOpen() async throws {
        let m = await sessionWithTheLidClosed(h)
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let refused = await m.end(reason: .thermalCritical)
        XCTAssertEqual(refused, .locked)
        XCTAssertTrue(h.lidWatcher.running, "the lid is not watched while the sleep is owed")

        h.moveLid(closed: false)
        XCTAssertFalse(m.closedLidSleepOwed, "the open did not drop the owed sleep")
        h.moveLid(closed: true)
        other.release()
        let again = await m.end(reason: .thermalCritical)

        XCTAssertEqual(again, .restored)
        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
        XCTAssertFalse(h.lidWatcher.running)
    }

    /// Only an open drops the owed sleep. A heat end with the lid open
    /// stops at a `disablesleep 0` left running, and the lid closes
    /// meanwhile: macOS refused that close's sleep, so the end that the
    /// command's exit runs again asks for it.
    func testClosingTheLidWhileTheSleepIsOwedKeepsIt() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.stillRunning = ["disablesleep 0"]
        let outcome = await m.end(reason: .thermalCritical)
        XCTAssertEqual(outcome, .privilegedCommandRunning(pid: 4242))
        XCTAssertTrue(h.lidWatcher.running, "the lid is not watched while the sleep is owed")

        h.moveLid(closed: true)
        XCTAssertTrue(m.closedLidSleepOwed, "a close dropped the owed sleep")
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }

        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
        XCTAssertFalse(h.lidWatcher.running)
    }

    /// The lid is watched only while a sleep is owed: not during a session,
    /// whose own observer stops with its end, not after an end that owes
    /// nothing, and no longer once the sleep is asked, given up or dropped
    /// by a start.
    func testTheLidIsWatchedOnlyWhileTheSleepIsOwed() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.02)
        XCTAssertFalse(h.lidWatcher.running, "watched during the session")

        _ = await m.end(reason: .timer)
        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
        XCTAssertFalse(h.lidWatcher.running, "still watched once the sleep was asked")

        await m.start(duration: 3600)
        _ = await m.end(reason: .user)
        XCTAssertEqual(h.lidWatcher.starts, 1, "watched after an end that owes nothing")

        await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .batteryFloor)
        XCTAssertTrue(h.lidWatcher.running)
        await waitUntil("the owed sleep was never given up") { !m.closedLidSleepOwed }
        XCTAssertFalse(h.lidWatcher.running, "still watched once the sleep was given up")

        h.guardFake.throwOn = []
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        XCTAssertTrue(h.lidWatcher.running)
        h.guardFake.throwOn = []
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        XCTAssertFalse(h.lidWatcher.running, "still watched once a start dropped the sleep")
    }

    /// A start drops the owed sleep: the person wants the Mac awake. An
    /// end of that session asks nothing.
    func testStartDropsTheOwedSleep() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        h.guardFake.throwOn = []

        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        let outcome = await m.end(reason: .user)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(h.lidSleep.requests, [Self.refused])
    }

    /// A start refused for a busy lock changed nothing, so the owed sleep
    /// stays and is asked once sleep is restored.
    func testStartRefusedForTheLockKeepsTheOwedSleep() async throws {
        let m = await sessionWithTheLidClosed(h, lockTimeout: 0.05, retryDelay: 0.05)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())

        await m.start(duration: 3600)

        XCTAssertNil(m.session)
        other.release()
        h.guardFake.sleepDisabled = false
        await waitUntil("the refused start dropped the owed sleep") { h.lidSleep.requests.last == Self.asked }
    }

    /// A start queued behind a heat end runs before any sleep request, and
    /// its session needs none.
    func testStartQueuedBehindAFloorEndIsNotPutToSleep() async throws {
        let m = await sessionWithTheLidClosed(h)
        let gate = AsyncGate()
        h.guardFake.restoreGate = gate

        let end = Task { await m.end(reason: .thermalCritical) }
        await gate.waitUntilStarted()
        let start = await runUntilSuspended { await m.start(duration: 600) }
        await gate.open()
        _ = await end.value
        await start.value

        XCTAssertNotNil(m.session)
        XCTAssertEqual(h.lidSleep.requests, [], "asked for sleep with a start queued")
    }

    /// A quit refused while a heat end waits for a live command replaces
    /// the pending end. The end that runs when the command exits still
    /// asks.
    func testQuitWhileTheEndWaitsForACommandStillAsks() async throws {
        let m = await sessionWithTheLidClosed(h)
        h.guardFake.stillRunning = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .privilegedCommandRunning(pid: 4242))
        XCTAssertEqual(m.pendingEnd, .quit)

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }

        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
    }

    /// A repeat never asks beside a live `sudo pmset`, even once sleep reads
    /// restored. The end that runs when the command exits asks.
    func testRepeatWaitsForALiveCommand() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .thermalCritical)
        h.guardFake.throwOn = []
        h.guardFake.stillRunning = ["disablesleep 0"]
        let stuck = await m.end(reason: .user)
        XCTAssertEqual(stuck, .privilegedCommandRunning(pid: 4242))

        h.guardFake.sleepDisabled = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(h.lidSleep.requests.contains(Self.asked), "asked for sleep beside a live sudo pmset")

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("not asked once the command exited") { h.lidSleep.requests.last == Self.asked }
    }

    /// A session.json that cannot be removed keeps the end pending, but
    /// sleep is restored, so the closed Mac is asked to sleep. Asked once:
    /// each retry runs the same end again, and a Mac woken since (for
    /// remote access, say) is not sent back to sleep by it.
    func testEndThatCannotRemoveTheSessionFileAsksOnceOverItsRetries() async throws {
        let m = await sessionWithTheLidClosed(h, retryDelay: 0.05)
        let file = h.home.paths.sessionFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        let notifier = h.notifier
        let attempts = { notifier.posts.filter { $0.title == SessionManager.incompleteTitle }.count }

        let outcome = await m.end(reason: .batteryFloor)

        XCTAssertEqual(outcome, .sessionRetained)
        XCTAssertEqual(m.pendingEnd, .batteryFloor)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.lidSleep.requests, [Self.asked])

        await waitUntil("the end was not retried three times") { attempts() >= 4 }
        XCTAssertEqual(m.pendingEnd, .batteryFloor)
        XCTAssertEqual(h.lidSleep.requests, [Self.asked], "a retry asked for sleep again")

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        await waitUntil("the end never finished") { m.pendingEnd == nil }
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.lidSleep.requests, [Self.asked], "the retry that finished asked for sleep again")
        XCTAssertFalse(m.closedLidSleepOwed)
    }

    /// A quit that arrives while a heat end restores sleep queues behind
    /// it. The heat end asks once, with sleep restored; the quit asks
    /// nothing.
    func testQuitDuringAFloorEndAsksOnce() async throws {
        let m = await sessionWithTheLidClosed(h)
        let gate = AsyncGate()
        h.guardFake.restoreGate = gate

        let end = Task { await m.end(reason: .thermalCritical) }
        await gate.waitUntilStarted()
        let quit = await runUntilSuspended { await m.end(reason: .quit) }
        XCTAssertEqual(h.lidSleep.requests, [], "asked for sleep while sleep was still disabled")
        await gate.open()
        let ended = await end.value
        let quitted = await quit.value

        XCTAssertEqual(ended, .restored)
        XCTAssertEqual(quitted, .restored)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
    }

    /// An expired session on disk, and the lid closed, at launch: the app
    /// was not running when the timer ran out (#94 after a relaunch). The
    /// reconcile restores sleep, then asks for it once its lock is free.
    func testExpiredSessionAtLaunchWithTheLidClosedAsksForSleep() async throws {
        try seedExpiredSession(h)
        h.clamshell.closed = true
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertNil(m.session)
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"))
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.lidSleep.requests, [Self.asked], "no sleep asked for, or asked before sleep was restored or the lock released")
        XCTAssertFalse(m.closedLidSleepOwed)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The reconcile's end stops at a `disablesleep 0` left running: no
    /// request while it runs. The end its exit runs again finds no session
    /// and owes nothing new, but asks the sleep the reconcile owed.
    func testExpiredSessionAtLaunchAsksOnceALiveCommandExits() async throws {
        try seedExpiredSession(h)
        h.clamshell.closed = true
        h.guardFake.stillRunning = ["disablesleep 0"]
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertEqual(h.lidSleep.requests, [], "asked for sleep beside a live sudo pmset")
        XCTAssertTrue(m.closedLidSleepOwed)
        XCTAssertEqual(m.pendingEnd, .timer)

        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        await waitUntil("pending end never retried") { m.pendingEnd == nil }

        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// A reconcile refused for a busy lock changed nothing and owes
    /// nothing; the reconcile that runs again once the lock is free asks.
    func testExpiredSessionAtLaunchAsksWhenTheReconcileRunsAgain() async throws {
        try seedExpiredSession(h)
        h.clamshell.closed = true
        let m = h.makeManager(lockTimeout: 0.05, retryDelay: 0.05)
        let other = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())

        await m.reconcile()

        XCTAssertEqual(h.lidSleep.requests, [])
        XCTAssertFalse(m.closedLidSleepOwed, "a refused reconcile owed the sleep")
        other.release()
        await waitUntil("the reconcile was not run again") { !h.lidSleep.requests.isEmpty }

        XCTAssertEqual(h.lidSleep.requests, [Self.asked])
        XCTAssertNil(try h.store.loadSession())
    }

    /// The same launch with the lid open asks nothing. A dirty journal with
    /// no session owes nothing either: its end is not known to be the
    /// timer's. The app's own end leaves it when it is cut short, since
    /// session.json goes first, and the sleep that end owed was only in the
    /// process that died, like a session the recovery agent ends after a
    /// crash.
    func testLaunchReconcileWithTheLidOpenOrNoSessionAsksNothing() async throws {
        for (sessionOnDisk, lidClosed) in [(true, false), (false, true)] {
            let h = Harness()
            defer { h.home.destroy() }
            try seedExpiredSession(h, withSession: sessionOnDisk)
            h.clamshell.closed = lidClosed
            let m = h.makeManager()

            await m.reconcile()

            let which = "session on disk \(sessionOnDisk), lid closed \(lidClosed)"
            XCTAssertFalse(h.guardFake.sleepDisabled, which)
            XCTAssertEqual(h.lidSleep.requests, [], which)
            XCTAssertFalse(m.closedLidSleepOwed, which)
        }
    }

    /// A session that ran out a minute ago, with sleep still disabled for
    /// it; with `withSession` false, only its journal.
    private func seedExpiredSession(_ h: Harness, withSession: Bool = true) throws {
        let now = h.clock.now
        if withSession {
            try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-3600), endsAt: now.addingTimeInterval(-60)))
        }
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
    }
}
