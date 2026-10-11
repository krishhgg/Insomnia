import Foundation
import XCTest
@testable import Insomnia

/// The recovery lock is a kernel flock on one kept file, so it is shared
/// with backstop.sh and released by the kernel if the holder dies.
final class RecoveryLockTests: XCTestCase {
    var home: TempHome!
    var lock: RecoveryLock!
    /// The lockf holder a test started, if any.
    var holder: LockfHolder?

    override func setUp() {
        home = TempHome()
        lock = RecoveryLock(url: home.paths.recoveryLock)
    }

    /// Stops a holder the test left running. One that still has not
    /// exited keeps the home it locks.
    override func tearDown() {
        if let holder, !holder.isSettled, holder.stop() == -1 {
            XCTFail("the lockf holder \(holder.child.pid) did not exit; keeping \(home.root.path): \(holder.problems)")
            home.keep()
            return
        }
        home.destroy()
    }

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
    /// The holder's command is cat, which prints back a line only once lockf
    /// holds the lock and runs it. Closing cat's input ends cat, lockf reaps
    /// it and exits 0, and the test reaps lockf (LockfHolder).
    func testLockHeldByLockfInAnotherProcessIsRespected() throws {
        let holder = try LockfHolder(
            file: home.paths.recoveryLock, wait: 0, errors: home.root.appendingPathComponent("holder-errors"),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], directory: home.root)
        self.holder = holder
        XCTAssertTrue(holder.held(within: 5), "lockf holder never ran its command: \(holder.problems) \(holder.errorText())")

        XCTAssertNil(try lock.tryAcquire(), "flock did not see the lock lockf holds")
        XCTAssertEqual(holder.stop(), 0, "lockf, reaped once its cat read the end of its input: \(holder.problems) \(holder.errorText())")
        XCTAssertNotNil(try lock.tryAcquire())
    }
}
