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
    /// thread, suspend, then await the exit wherever the task resumes. Either
    /// path in `exited()` may run here; the next two tests pin one each.
    func testExitedResumesAfterASuspensionBetweenLaunchAndWait() async throws {
        for _ in 0..<20 {
            let p = Self.process("/bin/sh", ["-c", "exit 3"])
            let childExit = ProcessExit(p)
            try p.run()
            try await Task.sleep(for: .milliseconds(5))
            guard await childExit.exited(within: 10) else {
                return XCTFail("exited() did not return within 10 s")
            }
            XCTAssertEqual(p.terminationStatus, 3)
            XCTAssertEqual(p.terminationReason, .exit)
        }
    }

    /// `exited()` called after the exit handler ran returns without
    /// suspending.
    func testExitedResumesForAChildThatExitedBeforeTheCall() async throws {
        let p = Self.process("/bin/sh", ["-c", "exit 4"])
        let childExit = ProcessExit(p)
        try p.run()
        // wait() returns only after the handler has recorded the exit, so the
        // call below takes the already-exited path.
        let reaped = XCTestExpectation(description: "wait() returned")
        Thread {
            childExit.wait()
            reaped.fulfill()
        }.start()
        guard await XCTWaiter().fulfillment(of: [reaped], timeout: 10) == .completed else {
            return XCTFail("wait() did not return within 10 s")
        }
        guard await childExit.exited(within: 10) else {
            return XCTFail("exited() did not return within 10 s")
        }
        XCTAssertEqual(p.terminationStatus, 4)
    }

    /// A child that is still running when every wait starts, and is ended by
    /// a signal: the reason ShellTimeout classifies by is final after the
    /// wait. Two blocking waiters and one suspended caller all return.
    func testEveryWaiterReturnsForAChildThatExitsAfterTheCall() async throws {
        let p = Self.process("/bin/sleep", ["30"])
        let childExit = ProcessExit(p)
        try p.run()
        defer { if p.isRunning { p.terminate() } }

        // wait() has one path whether the exit comes before or after the
        // call, so the blocking waiters only need to have called it.
        let blockingCalled = (0..<2).map { XCTestExpectation(description: "blocking waiter \($0) called wait()") }
        let blockingReturned = (0..<2).map { XCTestExpectation(description: "blocking waiter \($0) returned") }
        for i in 0..<2 {
            Thread {
                blockingCalled[i].fulfill()
                childExit.wait()
                blockingReturned[i].fulfill()
            }.start()
        }
        // exited() has two paths. The child exits only once this caller has
        // suspended, so the handler has to resume it.
        let awaitReturned = XCTestExpectation(description: "exited() returned")
        Task {
            await childExit.exited()
            awaitReturned.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: blockingCalled, timeout: 10) == .completed else {
            return XCTFail("the blocking waiters did not start within 10 s")
        }
        guard try await Self.poll(within: 10, until: { childExit.suspendedCount == 1 }) else {
            return XCTFail("exited() did not suspend within 10 s")
        }
        XCTAssertTrue(p.isRunning, "the child exited before every wait had started")

        p.terminate()
        await fulfillment(of: blockingReturned + [awaitReturned], timeout: 10)
        XCTAssertEqual(childExit.suspendedCount, 0)
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

    /// Checks `condition` every 5 ms for at most `seconds`.
    private static func poll(within seconds: TimeInterval, until condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

extension ProcessExit {
    /// Awaits `exited()` for at most `seconds` and says whether it returned.
    /// The await runs in an unstructured task that nothing waits on, so if
    /// `exited()` never resumes, the caller still gets `false` at the limit
    /// instead of hanging the suite.
    func exited(within seconds: TimeInterval) async -> Bool {
        let returned = XCTestExpectation(description: "exited() returned")
        Task {
            await exited()
            returned.fulfill()
        }
        return await XCTWaiter().fulfillment(of: [returned], timeout: seconds) == .completed
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
