import Darwin
import XCTest
@testable import Insomnia

/// Real child processes (tiny `/bin/sh` scripts in a private temp dir) driven
/// through `CancellableCommand`. Nothing here touches user processes.
final class CommandCancellationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func file(_ name: String) -> String { dir.appendingPathComponent(name).path }

    /// A script that records its own pid and then *becomes* `sleep`, so the
    /// recorded pid is the one the runner signals.
    private func sleeper() throws -> (exe: String, pidFile: String) {
        let pidFile = file("pid")
        let exe = try script("sleeper", "printf '%s' $$ > '\(pidFile)'\nexec sleep 30")
        return (exe, pidFile)
    }

    private func waitForFile(_ path: String) async throws {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "child never started")
    }

    private func recordedPid(_ pidFile: String) throws -> pid_t {
        try XCTUnwrap(pid_t(try String(contentsOfFile: pidFile, encoding: .utf8)))
    }

    private func assertGone(_ pid: pid_t) async throws {
        for _ in 0..<300 {
            if kill(pid, 0) != 0, errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("child \(pid) is still alive")
    }

    func testSuccessfulCommandReturnsOutput() async throws {
        let exe = try script("ok", "printf 'hi'\nexit 0")
        let r = try await CancellableCommand().run(exe, [], timeout: 5)
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout, "hi")
        XCTAssertTrue(r.succeeded)
    }

    func testNonZeroStatusIsReturnedNotThrown() async throws {
        let exe = try script("fail", "printf 'boom' >&2\nexit 3")
        let r = try await CancellableCommand().run(exe, ["ignored"], timeout: 5)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.stderr, "boom")
        XCTAssertFalse(r.succeeded)
    }

    func testTimeoutKillsChildAndThrows() async throws {
        let (exe, pidFile) = try sleeper()
        // One second leaves room for a slow spawn under parallel test load;
        // the script still records its pid long before the limit.
        do {
            _ = try await CancellableCommand().run(exe, [], timeout: 1)
            XCTFail("command outlived its timeout")
        } catch is ShellTimeoutError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile), "child never recorded its pid before the timeout")
        try await assertGone(try recordedPid(pidFile))
    }

    /// A child that dies from a signal of its own, well before the deadline,
    /// is a failed command, not a timeout.
    func testChildKilledBySignalBeforeDeadlineIsNotATimeout() async throws {
        let exe = try script("suicide", "kill -TERM $$")
        let started = Date()
        let r = try await CancellableCommand().run(exe, [], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "runner waited for the deadline")
        XCTAssertNotEqual(r.status, 0)
    }

    /// A child that traps TERM and exits 0 after the deadline still timed
    /// out: the deadline handler had to stop it.
    func testTimeoutIsReportedWhenChildTrapsTermAndExitsZero() async throws {
        let exe = try script("trapper", "trap 'exit 0' TERM\nwhile :; do sleep 0.05; done")
        do {
            let r = try await CancellableCommand().run(exe, [], timeout: 0.5)
            XCTFail("deadline-stopped child reported as success with status \(r.status)")
        } catch is ShellTimeoutError {}
    }

    func testCancelWhileRunningTerminatesChild() async throws {
        let (exe, pidFile) = try sleeper()
        let task = Task { try await CancellableCommand().run(exe, [], timeout: 30) }
        try await waitForFile(pidFile)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled command returned a result")
        } catch is CancellationError {}
        try await assertGone(try recordedPid(pidFile))
    }

    /// The window Greptile flagged: the caller has already passed its
    /// cancellation check, the launch is queued, and the task is cancelled
    /// before `Process.run`. The child must never start.
    func testCancelBeforeLaunchNeverRunsTheChild() async throws {
        let sentinel = file("ran")
        let exe = try script("sentinel", "printf '' > '\(sentinel)'")
        let gate = AsyncGate()
        let command = CancellableCommand(beforeLaunch: { await gate.wait() })
        let task = Task { try await command.run(exe, [], timeout: 5) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("cancelled command returned a result")
        } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel), "child was launched after cancellation")
    }
}
