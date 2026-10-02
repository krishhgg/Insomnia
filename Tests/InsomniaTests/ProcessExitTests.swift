import Foundation
import XCTest
@testable import Insomnia

/// `ProcessExit` returns once the child has exited, whichever thread
/// launched it and whichever thread waits. Every wait here runs under a time
/// limit, so a wait that never returns fails the test instead of hanging the
/// suite.
final class ProcessExitTests: XCTestCase {
    /// The shape that hung `waitUntilExit()` in RecoveryLockTests: the waiting
    /// thread launched an earlier `Process` at the same address, and another
    /// thread launched this one. Foundation's per-thread list of launches
    /// then says "launched here", and `waitUntilExit()` without a termination
    /// handler waits for a notification queued on the launching thread's run
    /// loop, which that thread never runs. With `waitUntilExit()` in place of
    /// `ProcessExit`, every trial that reuses an address times out here.
    func testWaitReturnsWhenAnotherThreadLaunchedAProcessAtAnAddressThisThreadLaunchedBefore() throws {
        var reused = 0
        for trial in 0..<10 {
            let t = AddressReuseTrial()
            t.start()
            guard t.finished.wait(timeout: .now() + 10) == .success else {
                return XCTFail("trial \(trial): the wait did not return within 10 s after a child that exits at once (address reused: \(t.addressReused))")
            }
            if let error = t.error { return XCTFail("trial \(trial): \(error)") }
            XCTAssertEqual(t.status, 0)
            if t.addressReused { reused += 1 }
            if reused >= 3 { break }
        }
        if reused == 0 {
            throw XCTSkip("no new Process landed on a freed address in 10 trials, so the case that hung waitUntilExit never came up")
        }
    }

    /// The RecoveryLockTests shape without the lock: launch on a cooperative
    /// thread, suspend, then await the exit wherever the task resumes.
    func testExitedResumesAfterASuspensionBetweenLaunchAndWait() async throws {
        for _ in 0..<20 {
            let p = Self.process("/bin/sh", ["-c", "exit 3"])
            let childExit = ProcessExit(p)
            try p.run()
            try await Task.sleep(for: .milliseconds(5))
            try await Self.awaitExit(childExit)
            XCTAssertEqual(p.terminationStatus, 3)
            XCTAssertEqual(p.terminationReason, .exit)
        }
    }

    func testExitedResumesForAChildThatExitedBeforeTheCall() async throws {
        let p = Self.process("/bin/sh", ["-c", "exit 4"])
        let childExit = ProcessExit(p)
        try p.run()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(p.isRunning, "the child did not exit within 10 s")
        try await Task.sleep(for: .milliseconds(50))
        try await Self.awaitExit(childExit)
        XCTAssertEqual(p.terminationStatus, 4)
    }

    /// A child that is still running when the wait starts, and is ended by a
    /// signal: the reason ShellTimeout classifies by is final after the wait.
    /// Two blocking waiters and one awaiting caller all return.
    func testEveryWaiterReturnsForAChildThatExitsAfterTheCall() async throws {
        let p = Self.process("/bin/sleep", ["30"])
        let childExit = ProcessExit(p)
        try p.run()
        let blocking = DispatchGroup()
        for _ in 0..<2 {
            blocking.enter()
            Thread {
                childExit.wait()
                blocking.leave()
            }.start()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(p.isRunning)
        p.terminate()
        try await Self.awaitExit(childExit)
        XCTAssertEqual(blocking.wait(timeout: .now() + 10), .success, "a blocking waiter did not return")
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        XCTAssertEqual(p.terminationStatus, SIGTERM)
    }

    /// A launch that fails leaves nothing that crashes when it is released.
    func testAProcessThatNeverStartedIsReleasedCleanly() {
        for _ in 0..<5 {
            let p = Self.process("/nonexistent/insomnia-test-tool", [])
            _ = ProcessExit(p)
            XCTAssertThrowsError(try p.run())
        }
    }

    // MARK: Helpers

    private static func process(_ exe: String, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return p
    }

    /// Awaits `exited()` under a 10 s limit.
    private static func awaitExit(_ childExit: ProcessExit) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await childExit.exited(); return true }
            group.addTask { try await Task.sleep(for: .seconds(10)); return false }
            let exited = try await group.next() ?? false
            group.cancelAll()
            if !exited { XCTFail("exited() did not return within 10 s") }
        }
    }
}

/// One trial of the address-reuse case, on threads of its own: a waiter
/// thread launches and reaps eight children, makes a new `Process` (which
/// usually lands on one of their freed addresses), has a second thread
/// launch it, then waits for it.
private final class AddressReuseTrial: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private(set) var addressReused = false
    private(set) var status: Int32?
    private(set) var error: String?

    private final class Box: @unchecked Sendable {
        let process: Process
        var launchError: Error?
        init(_ process: Process) { self.process = process }
    }

    private static func address(_ p: Process) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(p).toOpaque())
    }

    private static func exitsAtOnce() -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return p
    }

    func start() {
        Thread { [self] in
            defer { finished.signal() }
            var launchedHere = Set<UInt>()
            for _ in 0..<8 {
                let p = Self.exitsAtOnce()
                let childExit = ProcessExit(p)
                do { try p.run() } catch {
                    self.error = "launch failed: \(error)"
                    return
                }
                childExit.wait()
                launchedHere.insert(Self.address(p))
            }
            let box = Box(Self.exitsAtOnce())
            addressReused = launchedHere.contains(Self.address(box.process))
            let childExit = ProcessExit(box.process)
            let launched = DispatchSemaphore(value: 0)
            Thread {
                do { try box.process.run() } catch { box.launchError = error }
                launched.signal()
            }.start()
            launched.wait()
            if let launchError = box.launchError {
                self.error = "launch failed: \(launchError)"
                return
            }
            childExit.wait()
            status = box.process.terminationStatus
        }.start()
    }
}
