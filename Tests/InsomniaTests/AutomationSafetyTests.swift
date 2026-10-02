import Darwin
import XCTest
@testable import Insomnia

// Doubles live here on purpose: TestSupport.swift belongs to another worker.

/// Runs the tmux runner double: optionally blocks on `gate` for one target,
/// records every target in order and the task cancellation state seen when
/// the runner was released.
private final class RunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _cancelledAtRelease: [Bool] = []
    private var _calls = 0
    var sent: [String] { lock.withLock { _sent } }
    var cancelledAtRelease: [Bool] { lock.withLock { _cancelledAtRelease } }
    func record(_ target: String, cancelled: Bool) {
        lock.withLock {
            _sent.append(target)
            _cancelledAtRelease.append(cancelled)
        }
    }
    /// 1-based call number, incremented atomically.
    func nextCall() -> Int { lock.withLock { _calls += 1; return _calls } }
}

private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out waiting for \(what)")
}

/// A real AF_UNIX socket bound at `path`; closes and unlinks on deinit.
private final class UnixSocketFixture {
    let path: String
    private let fd: Int32

    init?(path: String) {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { buf in
                path.withCString { c in
                    guard strlen(c) < MemoryLayout.size(ofValue: tuple.pointee) else { return false }
                    strcpy(buf, c)
                    return true
                }
            }
        }
        guard ok else { close(fd); return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return nil }
    }

    deinit {
        close(fd)
        unlink(path)
    }
}

/// Hotspot joiner double that blocks inside `join` until released.
private final class GatedJoiner: HotspotJoining, @unchecked Sendable {
    let gate = AsyncGate()
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        lock.withLock { _calls += 1 }
        await gate.wait()
        return true
    }
}

// MARK: - NetworkFailover: ending a session must end its nudges

@MainActor
final class NetworkFailoverCancellationTests: XCTestCase {
    var home: TempHome!
    var notifier: RecordingNotifier!
    var clock: FakeClock!

    override func setUp() async throws {
        home = TempHome()
        notifier = RecordingNotifier()
        clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDown() async throws { home.destroy() }

    private func makeDriver(targets: [String], nudge: TmuxNudge) -> NetworkFailover {
        var config = Config()
        config.tmuxTargets = targets
        let clock = self.clock!
        return NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: nudge, notifier: notifier, clock: { clock.now }) { config }
    }

    /// Audit group 6: the first pane is mid-send when the user ends the
    /// session. The keystroke already in flight cannot be retracted, but the
    /// second pane must never receive `continue` + Enter.
    func testStopDuringRecoveryLeavesRemainingPanesUntouched() async throws {
        let gate = AsyncGate()
        let log = RunnerLog()
        let nudge = TmuxNudge { target in
            if target == "first" { await gate.wait() }
            log.record(target, cancelled: Task.isCancelled)
            return true
        }
        let n = makeDriver(targets: ["first", "second"], nudge: nudge)
        let gaps = Locked<[TimeInterval]>([])
        n.onRecovered = { gaps.value.append($0) }

        await n.simulate(satisfied: false)
        clock.advance(100)
        let recovering = Task { await n.simulate(satisfied: true) }
        await gate.waitUntilStarted()
        n.stop()
        await gate.open()
        await recovering.value

        XCTAssertEqual(log.sent, ["first"], "a pane was nudged after the session ended")
        // The user is still told about the keystroke that did go out...
        XCTAssertEqual(notifier.posts.map(\.body), ["Network was down 1m 40s. Nudged 1 tmux pane. Check GUI agents."])
        // ...but the stopped driver must not report a gap into the next session's status.
        XCTAssertEqual(gaps.value, [])
    }

    /// Stop, then a fresh outage and recovery on the same driver: the new
    /// recovery nudges every pane, the old one still only finishes the send
    /// it was already inside.
    func testRecoveryAfterRestartDoesNotResumeOldSessionNudges() async throws {
        let gate = AsyncGate()
        let log = RunnerLog()
        let nudge = TmuxNudge { target in
            if log.nextCall() == 1 { await gate.wait() }
            log.record(target, cancelled: Task.isCancelled)
            return true
        }
        let n = makeDriver(targets: ["first", "second"], nudge: nudge)

        await n.simulate(satisfied: false)
        clock.advance(100)
        let oldRecovery = Task { await n.simulate(satisfied: true) }
        await gate.waitUntilStarted()
        n.stop()

        await n.simulate(satisfied: false)
        clock.advance(200)
        await n.simulate(satisfied: true)
        XCTAssertEqual(log.sent, ["first", "second"], "new session did not nudge every pane")

        await gate.open()
        await oldRecovery.value
        XCTAssertEqual(log.sent, ["first", "second", "first"], "old recovery resumed after restart")
    }

    /// Path updates from the monitor run in driver-owned tasks. `stop()` must
    /// cancel them so a live runner that is about to shell out sees the
    /// cancellation before issuing its command.
    func testStopCancelsDriverOwnedRecoveryTask() async throws {
        let gate = AsyncGate()
        let log = RunnerLog()
        let nudge = TmuxNudge { target in
            if target == "first" { await gate.wait() }
            log.record(target, cancelled: Task.isCancelled)
            return true
        }
        let n = makeDriver(targets: ["first", "second"], nudge: nudge)

        n.handlePath(satisfied: false)
        try await waitUntil("outage to start") { n.machine.inOutage }
        clock.advance(100)
        n.handlePath(satisfied: true)
        await gate.waitUntilStarted()
        n.stop()
        await gate.open()
        try await waitUntil("recovery to finish") { self.notifier.posts.count == 1 }

        XCTAssertEqual(log.cancelledAtRelease, [true], "runner's task was not cancelled by stop()")
        XCTAssertEqual(log.sent, ["first"])
    }

    /// A path update that was queued before `stop()` but runs after it must
    /// not schedule a retry timer (and later a hotspot join) for a session
    /// that no longer exists.
    func testQueuedPathUpdateAfterStopDoesNotStartOutage() async throws {
        let n = makeDriver(targets: [], nudge: TmuxNudge { _ in true })
        n.handlePath(satisfied: false)
        n.stop()
        // Give the queued task every chance to run.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(n.machine.inOutage, "stopped driver entered an outage from a stale path update")
    }

    private func makeJoiningDriver(joiner: GatedJoiner) throws -> NetworkFailover {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "secret")
        var config = Config()
        config.hotspotSSID = "Phone"
        let clock = self.clock!
        return NetworkFailover(paths: home.paths, keychain: keychain, hotspotJoiner: joiner,
            notifier: notifier, wifiInterface: "en0", clock: { clock.now }) { config }
    }

    /// A retry tick yields `[.joinHotspot, .scheduleRetry]`. If the session
    /// ends while the join is in flight, the retry must not be scheduled
    /// afterwards: that timer would outlive the session it belonged to.
    func testStopDuringHotspotJoinDoesNotRescheduleRetry() async throws {
        let joiner = GatedJoiner()
        let n = try makeJoiningDriver(joiner: joiner)
        await n.simulate(satisfied: false)
        clock.advance(FailoverMachine.initialDelay)
        n.fireTimer()
        await joiner.gate.waitUntilStarted()

        n.stop()
        XCTAssertNil(n.retryTimer)
        await joiner.gate.open()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(joiner.calls, 1)
        XCTAssertNil(n.retryTimer, "cancelled join re-armed the retry timer after stop()")
    }

    /// Stop, start a new outage, then let the old join finish: the new
    /// outage's retry timer must survive untouched.
    func testOldJoinCannotReplaceNewSessionsRetryTimer() async throws {
        let joiner = GatedJoiner()
        let n = try makeJoiningDriver(joiner: joiner)
        await n.simulate(satisfied: false)
        clock.advance(FailoverMachine.initialDelay)
        n.fireTimer()
        await joiner.gate.waitUntilStarted()
        n.stop()

        clock.advance(60)
        await n.simulate(satisfied: false)
        let fresh = try XCTUnwrap(n.retryTimer, "new outage did not arm a retry")
        await joiner.gate.open()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(n.retryTimer === fresh, "old session's outputs replaced the new session's retry timer")
        XCTAssertTrue(n.machine.inOutage)
        XCTAssertEqual(n.machine.joins, 0, "old session's join leaked into the new outage")
    }
}

// MARK: - TmuxNudge loop

final class TmuxNudgeTests: XCTestCase {
    func testLoopStopsOncePermissionIsWithdrawn() async {
        let log = RunnerLog()
        let allowed = Locked(true)
        let nudge = TmuxNudge { target in
            log.record(target, cancelled: Task.isCancelled)
            if target == "a" { allowed.value = false }
            return true
        }
        let count = await nudge.nudge(targets: ["a", "b", "c"]) { allowed.value }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(log.sent, ["a"])
    }

    func testLoopStopsWhenTaskIsCancelled() async {
        let gate = AsyncGate()
        let log = RunnerLog()
        let nudge = TmuxNudge { target in
            if target == "a" { await gate.wait() }
            log.record(target, cancelled: Task.isCancelled)
            return true
        }
        let task = Task { await nudge.nudge(targets: ["a", "b"]) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()
        let count = await task.value
        XCTAssertEqual(count, 1)
        XCTAssertEqual(log.sent, ["a"])
    }

    func testPaneStateGate() {
        // Real `display-message -p -F "#{pane_id} #{pane_dead} #{pane_in_mode} #{pane_input_off}"` output.
        XCTAssertEqual(TmuxNudge.check(paneState: "%0 0 0 0\n"), .ready(paneId: "%0"))
        XCTAssertEqual(TmuxNudge.check(paneState: "%12 0 0 0\n"), .ready(paneId: "%12"))
        for unsafe in ["%0 1 0 0\n", "%0 0 1 0\n", "%0 0 0 1\n"] {
            guard case .skip = TmuxNudge.check(paneState: unsafe) else {
                return XCTFail("\(unsafe.debugDescription) was not skipped")
            }
        }
        // tmux prints blank fields (exit 0) for a target it cannot find. A
        // missing or malformed pane id fails closed even with clean flags.
        for unverifiable in ["   \n", "", "0 0 0\n", "%0 0 0\n", "%0 0 0 0 0\n", "0 0 0 0\n", "% 0 0 0\n", "%x 0 0 0\n", "nudge:0.0 0 0 0\n", "no server running\n"] {
            guard case .skip = TmuxNudge.check(paneState: unverifiable) else {
                return XCTFail("\(unverifiable.debugDescription) was not skipped")
            }
        }
    }
}

// MARK: - TmuxNudge live runner against a private tmux server

final class TmuxLiveRunnerTests: XCTestCase {
    private var tmux: String!
    private var socket: String!

    override func setUpWithError() throws {
        guard let found = Shell.locate(TmuxNudge.candidates) else {
            throw XCTSkip("tmux is not installed")
        }
        tmux = found
        socket = "insomnia-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    }

    override func tearDown() async throws {
        if let tmux, let socket {
            // tmux does not unlink its socket file on kill-server.
            let path = try? await Shell.run(tmux, ["-L", socket, "display-message", "-p", "#{socket_path}"], timeout: 5)
            _ = try? await Shell.run(tmux, ["-L", socket, "kill-server"], timeout: 5)
            if let p = path?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
    }

    private func tmuxRun(_ args: [String]) async throws -> ShellResult {
        try await Shell.run(tmux, ["-L", socket] + args, timeout: 5)
    }

    private func startPane(command: String) async throws {
        let r = try await tmuxRun(["new-session", "-d", "-s", "nudge", "-x", "80", "-y", "24", command])
        XCTAssertTrue(r.succeeded, r.stderr)
    }

    private func capture() async throws -> String {
        try await tmuxRun(["capture-pane", "-p", "-t", "nudge:0.0"]).stdout
    }

    func testLivePaneReceivesContinueAndEnter() async throws {
        try await startPane(command: "cat")
        let run = TmuxNudge.makeLiveRunner(socketName: socket)

        let accepted = try await run("nudge:0.0")

        XCTAssertTrue(accepted)
        // The pty echoes the typed line and `cat` prints it back once Enter
        // arrives, so two complete `continue` lines prove both keys landed.
        // Poll until both are present; stopping at the first would race the echo.
        var seen = ""
        var lines = 0
        for _ in 0..<100 {
            seen = try await capture()
            lines = seen.split(whereSeparator: \.isNewline).filter { $0 == "continue" }.count
            if lines >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(lines, 2, seen)
    }

    /// `select-pane -d` turns pane input off: tmux then accepts `send-keys`
    /// with exit 0 and silently drops the keys, so only the state check can
    /// tell the caller the nudge did not happen.
    func testInputOffPaneIsSkipped() async throws {
        try await startPane(command: "cat")
        let off = try await tmuxRun(["select-pane", "-d", "-t", "nudge:0.0"])
        XCTAssertTrue(off.succeeded, off.stderr)
        let run = TmuxNudge.makeLiveRunner(socketName: socket)

        let accepted = try await run("nudge:0.0")

        XCTAssertFalse(accepted, "nudge reported success for a pane that cannot receive input")
        let on = try await tmuxRun(["select-pane", "-e", "-t", "nudge:0.0"])
        XCTAssertTrue(on.succeeded, on.stderr)
        try await Task.sleep(for: .milliseconds(100))
        let seen = try await capture()
        XCTAssertFalse(seen.contains("continue"), seen)
    }

    /// A pane whose program has exited (`remain-on-exit`) also takes
    /// `send-keys` with exit 0 and nowhere for the keys to go.
    func testDeadPaneIsSkipped() async throws {
        try await startPane(command: "sleep 0.2")
        let keep = try await tmuxRun(["set-option", "-t", "nudge", "remain-on-exit", "on"])
        XCTAssertTrue(keep.succeeded, keep.stderr)
        var dead = false
        for _ in 0..<50 {
            let flags = try await tmuxRun(["display-message", "-p", "-t", "nudge:0.0", "-F", "#{pane_dead}"])
            if flags.stdout.hasPrefix("1") { dead = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(dead, "fixture pane never died")
        let run = TmuxNudge.makeLiveRunner(socketName: socket)

        let accepted = try await run("nudge:0.0")

        XCTAssertFalse(accepted, "nudge reported success for a dead pane")
    }

    func testMissingTargetIsSkipped() async throws {
        try await startPane(command: "cat")
        let run = TmuxNudge.makeLiveRunner(socketName: socket)
        let accepted = try await run("elsewhere:0.0")
        XCTAssertFalse(accepted)
        let seen = try await capture()
        XCTAssertFalse(seen.contains("continue"), seen)
    }

    /// The runner is released into a task that was cancelled while it
    /// waited, which is what `NetworkFailover.stop()` does to a recovery
    /// in flight: it must throw before issuing any tmux command.
    func testCancelledTaskSendsNothing() async throws {
        try await startPane(command: "cat")
        let run = TmuxNudge.makeLiveRunner(socketName: socket)
        let gate = AsyncGate()
        let task = Task { () throws -> Bool in
            await gate.wait()
            return try await run("nudge:0.0")
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()
        do {
            let accepted = try await task.value
            XCTFail("cancelled runner issued its command (accepted=\(accepted))")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(200))
        let seen = try await capture()
        XCTAssertFalse(seen.contains("continue"), seen)
    }
}

// MARK: - TmuxNudge live runner: target aliases and the check-to-send window

final class TmuxTargetResolutionTests: XCTestCase {
    private var tmux: String!
    private var socket: String!

    override func setUpWithError() throws {
        guard let found = Shell.locate(TmuxNudge.candidates) else {
            throw XCTSkip("tmux is not installed")
        }
        tmux = found
        socket = "insomnia-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    }

    override func tearDown() async throws {
        if let tmux, let socket {
            let path = try? await Shell.run(tmux, ["-L", socket, "display-message", "-p", "#{socket_path}"], timeout: 5)
            _ = try? await Shell.run(tmux, ["-L", socket, "kill-server"], timeout: 5)
            if let p = path?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
    }

    private func tmuxRun(_ args: [String]) async throws -> ShellResult {
        try await Shell.run(tmux, ["-L", socket] + args, timeout: 5)
    }

    private func continueLines(in pane: String) async throws -> Int {
        let seen = try await tmuxRun(["capture-pane", "-p", "-t", pane]).stdout
        return seen.split(whereSeparator: \.isNewline).filter { $0 == "continue" }.count
    }

    /// Two `cat` panes in one window; the second (`%1`) is active.
    private func startSplitWindow() async throws {
        let r = try await tmuxRun(["new-session", "-d", "-s", "nudge", "-x", "80", "-y", "24", "cat"])
        XCTAssertTrue(r.succeeded, r.stderr)
        let split = try await tmuxRun(["split-window", "-t", "nudge:0", "cat"])
        XCTAssertTrue(split.succeeded, split.stderr)
        let panes = try await tmuxRun(["list-panes", "-t", "nudge:0", "-F", "#{pane_id} #{pane_active}"])
        XCTAssertEqual(panes.stdout, "%0 0\n%1 1\n")
    }

    /// A window alias resolves to whichever pane is active *when tmux looks*.
    /// The active pane is switched between the state read and the send: the
    /// keys must land in the pane whose state was checked, not the alias.
    func testKeysGoToTheCheckedPaneWhenActivePaneChanges() async throws {
        try await startSplitWindow()
        let tmux = self.tmux!
        let socket = self.socket!
        let launches = RunnerLog()
        let command = CancellableCommand(beforeLaunch: {
            // Second launch is the send: flip the window's active pane first.
            if launches.nextCall() == 2 {
                _ = try? await Shell.run(tmux, ["-L", socket, "select-pane", "-t", "%0"], timeout: 5)
            }
        })
        let run = TmuxNudge.makeLiveRunner(socketName: socket, command: command)

        let accepted = try await run("nudge:0")

        XCTAssertTrue(accepted)
        var checked = 0
        for _ in 0..<100 {
            checked = try await continueLines(in: "%1")
            if checked >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let other = try await continueLines(in: "%0")
        XCTAssertEqual(checked, 2, "checked pane %1 did not receive continue + Enter")
        XCTAssertEqual(other, 0, "unchecked pane %0 received the keystrokes")
    }

    /// Cancellation that lands after the state read but before the send is
    /// queued must stop the send from ever launching.
    func testCancellationBetweenCheckAndSendSendsNothing() async throws {
        let r = try await tmuxRun(["new-session", "-d", "-s", "nudge", "-x", "80", "-y", "24", "cat"])
        XCTAssertTrue(r.succeeded, r.stderr)
        let gate = AsyncGate()
        let launches = RunnerLog()
        let command = CancellableCommand(beforeLaunch: {
            if launches.nextCall() == 2 { await gate.wait() }
        })
        let run = TmuxNudge.makeLiveRunner(socketName: socket, command: command)
        let task = Task { try await run("nudge:0.0") }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()
        do {
            let accepted = try await task.value
            XCTFail("send launched after cancellation (accepted=\(accepted))")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(300))
        let lines = try await continueLines(in: "%0")
        XCTAssertEqual(lines, 0, "keys were sent by a cancelled runner")
    }
}

// MARK: - DockerRule endpoint binding

final class DockerRuleEndpointTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        // Short path: sockaddr_un limits socket paths to ~104 bytes.
        dir = URL(fileURLWithPath: "/tmp/ins-\(getpid())-\(UInt16.random(in: 0...UInt16.max))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes an executable that records its argv and behaves as `stdout`/`exit` say.
    private func fakeDocker(stdout: String, exit: Int32) throws -> (exe: String, argvFile: String) {
        let argv = dir.appendingPathComponent("argv").path
        let exe = dir.appendingPathComponent("docker").path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(argv)'
        printf '%s' '\(stdout)'
        exit \(exit)
        """
        try script.write(toFile: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe)
        return (exe, argv)
    }

    private func recordedArgv(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testProbeBindsToDesktopSocketAndReportsIdle() async throws {
        let sock = dir.appendingPathComponent("d.sock").path
        let fixture = try XCTUnwrap(UnixSocketFixture(path: sock))
        let (exe, argv) = try fakeDocker(stdout: "\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: fixture.path)

        let idle = try await probe()

        XCTAssertTrue(idle)
        XCTAssertEqual(try recordedArgv(argv), ["--host", "unix://\(sock)", "ps", "-q"])
    }

    func testProbeReportsBusyWhenDesktopListsContainers() async throws {
        let fixture = try XCTUnwrap(UnixSocketFixture(path: dir.appendingPathComponent("d.sock").path))
        let (exe, _) = try fakeDocker(stdout: "fe9b30f60a57\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: fixture.path)
        let idle = try await probe()
        XCTAssertFalse(idle)
    }

    func testProbeFailureIsAnError() async throws {
        let fixture = try XCTUnwrap(UnixSocketFixture(path: dir.appendingPathComponent("d.sock").path))
        let (exe, _) = try fakeDocker(stdout: "", exit: 1)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: fixture.path)
        do {
            _ = try await probe()
            XCTFail("failed docker ps reported an answer")
        } catch {}
    }

    func testMissingDesktopSocketSkipsDockerWithoutRunningTheCLI() async throws {
        let (exe, argv) = try fakeDocker(stdout: "\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: dir.appendingPathComponent("absent.sock").path)
        do {
            _ = try await probe()
            XCTFail("probe answered without a Desktop endpoint")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: argv), "docker CLI ran against an unverified endpoint")
    }

    func testRegularFileAtSocketPathIsNotAnEndpoint() async throws {
        let notASocket = dir.appendingPathComponent("d.sock").path
        try "".write(toFile: notASocket, atomically: true, encoding: .utf8)
        let (exe, argv) = try fakeDocker(stdout: "\n", exit: 0)
        let probe = DockerRule.makeProbe(docker: exe, socketPath: notASocket)
        do {
            _ = try await probe()
            XCTFail("probe answered through a plain file")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: argv))
    }
}
