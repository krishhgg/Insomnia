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

    /// Round 39 (item 4): only a regular file at the path is locked. A
    /// symbolic link fails the open (O_NOFOLLOW), so nothing is made or
    /// locked where it points; a FIFO is opened without waiting for a
    /// writer (O_NONBLOCK) and refused; a folder fails the open. Each
    /// stays as it was: the lock path is never unlinked or replaced.
    func testOnlyARegularFileIsLocked() throws {
        let path = home.paths.recoveryLock.path
        let target = home.root.appendingPathComponent("elsewhere").path
        XCTAssertEqual(symlink(target, path), 0)
        XCTAssertThrowsError(try lock.tryAcquire()) { error in
            XCTAssertEqual(error as? RecoveryLockError, .open(path: path, errno: ELOOP))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "nothing is made where the link points")
        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFLNK, "the link stays")
        XCTAssertEqual(unlink(path), 0)

        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let started = ContinuousClock.now
        XCTAssertThrowsError(try lock.tryAcquire()) { error in
            XCTAssertEqual(error as? RecoveryLockError, .notRegularFile(path: path))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO, "the FIFO stays")
        XCTAssertEqual(unlink(path), 0)

        XCTAssertEqual(mkdir(path, 0o700), 0)
        XCTAssertThrowsError(try lock.tryAcquire()) { error in
            XCTAssertEqual(error as? RecoveryLockError, .open(path: path, errno: EISDIR))
        }
        XCTAssertEqual(rmdir(path), 0)

        let held = try XCTUnwrap(try lock.tryAcquire(), "the control: a regular file is made and locked")
        held.release()
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
        let holderExit = ProcessExit(holder)
        try holder.run()
        defer { holder.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "lockf holder never started")

        XCTAssertNil(try lock.tryAcquire(), "flock did not see the lock lockf holds")
        holder.terminate()
        let exited = await holderExit.exited(within: 10)
        XCTAssertTrue(exited, "the lockf holder did not exit within 10 s of SIGTERM")
        XCTAssertNotNil(try lock.tryAcquire())
    }
}
