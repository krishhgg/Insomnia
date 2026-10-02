import Foundation
import XCTest
@testable import Insomnia

/// The recovery lock is a kernel flock on one kept file, so it is shared
/// with backstop.sh and released by the kernel if the holder dies.
final class RecoveryLockTests: XCTestCase {
    var home: TempHome!
    var lock: RecoveryLock!

    override func setUp() {
        home = TempHome()
        lock = RecoveryLock(url: home.paths.recoveryLock)
    }

    override func tearDown() { home.destroy() }

    func testSecondHolderIsRefusedUntilRelease() throws {
        let first = try XCTUnwrap(try lock.tryAcquire())
        XCTAssertNil(try lock.tryAcquire())
        first.release()
        XCTAssertNotNil(try lock.tryAcquire())
        // The file is kept: both sides must keep locking the same inode.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.recoveryLock.path))
    }

    func testAcquireGivesUpAfterTheBoundInsteadOfWaitingForever() async throws {
        let held = try XCTUnwrap(try lock.tryAcquire())
        defer { held.release() }
        let started = ContinuousClock.now
        do {
            _ = try await lock.acquire(timeout: 0.2)
            XCTFail("acquired a lock another holder had")
        } catch let error as RecoveryLockError {
            guard case .busy = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    func testAcquireSucceedsOnceTheHolderReleases() async throws {
        let held = try XCTUnwrap(try lock.tryAcquire())
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            held.release()
        }
        let mine = try await lock.acquire(timeout: 3)
        mine.release()
    }

    func testHandleGoingAwayReleasesTheLock() throws {
        var handle: RecoveryLockHandle? = try lock.tryAcquire()
        XCTAssertNotNil(handle)
        XCTAssertNil(try lock.tryAcquire())
        handle = nil
        XCTAssertNotNil(try lock.tryAcquire())
    }

    /// backstop.sh locks with `/usr/bin/lockf -k` on the same path. Prove the
    /// two really contend: a lockf holder in another process blocks the app.
    func testLockHeldByLockfInAnotherProcessIsRespected() async throws {
        let ready = home.root.appendingPathComponent("holder-ready")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        holder.arguments = ["-k", "-t", "0", home.paths.recoveryLock.path, "/bin/sh", "-c", "touch '\(ready.path)'; sleep 30"]
        try holder.run()
        defer { holder.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "lockf holder never started")

        XCTAssertNil(try lock.tryAcquire(), "flock did not see the lock lockf holds")
        holder.terminate()
        holder.waitUntilExit()
        XCTAssertNotNil(try lock.tryAcquire())
    }
}
