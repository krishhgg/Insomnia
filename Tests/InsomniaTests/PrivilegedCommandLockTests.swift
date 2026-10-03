import Darwin
import XCTest
@testable import Insomnia

/// A privileged command holds the recovery lock itself until it exits, so a
/// crash or force quit of Insomnia cannot free the lock beside a live
/// `sudo pmset`. The crash is stood in for by `release()`, which closes this
/// process's descriptor as exiting would; `sudo` is a tiny `/bin/sh` script
/// in a private temp dir. Nothing here runs sudo or pmset, or signals a
/// process other than the test's own children.
final class PrivilegedCommandLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-held-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A child still waiting exits once the directory is gone.
        try? FileManager.default.removeItem(at: dir)
    }

    private var lock: RecoveryLock { RecoveryLock(url: dir.appendingPathComponent(".recovery.lock")) }

    private func file(_ name: String) -> String { dir.appendingPathComponent(name).path }

    private func script(_ name: String, _ body: String) throws -> String {
        let path = file(name)
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Writes `ready`, then runs until the test creates `go` or removes the
    /// directory (20 s at most) and exits 0. With `ignoreTerm`, SIGTERM is ignored first, as by a
    /// `sudo pmset` stuck in powerd.
    private func waiter(_ name: String, ignoreTerm: Bool = false) throws -> String {
        try script(name, """
        \(ignoreTerm ? "trap '' TERM" : ":")
        printf '%s' "$*" > '\(file("args"))'
        printf '' > '\(file("ready"))'
        i=0
        while [ ! -e '\(file("go"))' ] && [ -d '\(dir.path)' ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
        exit 0
        """)
    }

    private func waitForFile(_ path: String) async throws {
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "child never started")
    }

    private func lockIsFree() throws -> Bool {
        guard let probe = try lock.tryAcquire() else { return false }
        probe.release()
        return true
    }

    /// The command's own descriptor keeps the lock after the transaction's
    /// is closed, and the lock is free once the command exits.
    func testCommandKeepsTheLockAfterTheTransactionsDescriptorCloses() async throws {
        let exe = try waiter("command")
        let handle = try XCTUnwrap(try lock.tryAcquire())
        let run = Task { try await CancellableCommand().run(exe, [], timeout: 30, holding: handle) }
        try await waitForFile(file("ready"))

        handle.release()

        XCTAssertFalse(try lockIsFree(), "the lock was free beside the running command")
        FileManager.default.createFile(atPath: file("go"), contents: nil)
        let result = try await run.value
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(try lockIsFree(), "the lock stayed held after the command exited")
    }

    /// A child run without `holding` gets no descriptor on the lock: the
    /// lock file is opened close-on-exec.
    func testCommandRunWithoutHoldingGetsNoLock() async throws {
        let exe = try waiter("command")
        let handle = try XCTUnwrap(try lock.tryAcquire())
        let run = Task { try await CancellableCommand().run(exe, [], timeout: 30) }
        try await waitForFile(file("ready"))

        handle.release()

        XCTAssertTrue(try lockIsFree(), "a child inherited the lock by accident")
        FileManager.default.createFile(atPath: file("go"), contents: nil)
        _ = try await run.value
    }

    /// A transaction whose lock is already released runs no command that
    /// would need it.
    func testCommandIsNotRunOnAReleasedLock() async throws {
        let exe = try waiter("command")
        let handle = try XCTUnwrap(try lock.tryAcquire())
        handle.release()

        do {
            _ = try await CancellableCommand().run(exe, [], timeout: 5, holding: handle)
            XCTFail("ran with a released lock")
        } catch ShellError.launchFailed {}
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("ready")), "the command was launched")
    }

    /// The case the backstop would otherwise hit: a `sudo pmset` ignores
    /// SIGTERM and is left running, then Insomnia crashes. The lock stays
    /// held by the command, so the backstop cannot take it and run an undo
    /// that the live command would then override, until the command exits.
    func testPmsetLeftRunningKeepsTheLockThroughACrash() async throws {
        let sudo = try waiter("sudo", ignoreTerm: true)
        let ready = file("ready")
        let runner = CancellableCommand(beforeDeadline: {
            for _ in 0..<500 where !FileManager.default.fileExists(atPath: ready) {
                try? await Task.sleep(for: .milliseconds(10))
            }
        })
        let pmset = PmsetSleepGuard(sudo: sudo, pmset: "/usr/bin/pmset", timeout: 0.2, stopGrace: 0.3, runner: runner)
        let handle = try XCTUnwrap(try lock.tryAcquire())

        var leftRunning: UnfinishedCommand?
        do {
            try await RecoveryLock.$held.withValue(handle) { try await pmset.setSleepDisabled(false) }
            XCTFail("a command that ignores TERM returned")
        } catch let error as CommandStillRunningError {
            leftRunning = error.command
        }
        let command = try XCTUnwrap(leftRunning)
        XCTAssertEqual(try String(contentsOfFile: file("args"), encoding: .utf8), "-n /usr/bin/pmset -a disablesleep 0")

        handle.release()

        XCTAssertFalse(try lockIsFree(), "the crash freed the lock beside the live sudo pmset")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(try lockIsFree())
        FileManager.default.createFile(atPath: file("go"), contents: nil)
        await command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
        XCTAssertTrue(try lockIsFree(), "the lock stayed held after the command exited")
    }

    /// Outside a recovery transaction no `sudo pmset` runs at all: it
    /// could not hold the lock.
    func testPmsetIsNotRunWithoutTheLock() async throws {
        let sudo = try waiter("sudo")
        let pmset = PmsetSleepGuard(sudo: sudo, pmset: "/usr/bin/pmset", timeout: 5, stopGrace: 1)

        do {
            try await pmset.setLowPowerMode(true)
            XCTFail("ran without the recovery lock")
        } catch let error as SleepGuardError {
            XCTAssertEqual(error.status, -1)
            XCTAssertTrue(error.stderr.contains("no recovery transaction holds the lock"), error.stderr)
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("ready")), "the command was launched")
    }
}
