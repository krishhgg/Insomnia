import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// The alive lock is a kernel flock on one kept file, held by the app for
/// its whole lifetime and probed by backstop.sh with `lockf -t 0`: acquired
/// means no app is running. The kernel releases it when the holder dies.
final class AppAliveLockTests: XCTestCase {
    var home: TempHome!

    override func setUp() {
        home = TempHome()
    }

    override func tearDown() { home.destroy() }

    private func makeLock() -> AppAliveLock { AppAliveLock(url: home.paths.appAliveFile) }

    /// What backstop.sh runs: 75 while held, 0 when it could take the lock.
    private func probe() throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        p.arguments = ["-k", "-s", "-t", "0", home.paths.appAliveFile.path, "/usr/bin/true"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    func testSecondHolderIsRefusedUntilRelease() throws {
        let first = makeLock()
        XCTAssertTrue(try first.tryAcquire())
        XCTAssertTrue(first.isHeld)
        XCTAssertTrue(try first.tryAcquire(), "taking one's own lock again is a no-op")
        let second = makeLock()
        XCTAssertFalse(try second.tryAcquire())
        XCTAssertFalse(second.isHeld)
        first.release()
        XCTAssertFalse(first.isHeld)
        first.release()
        XCTAssertTrue(try second.tryAcquire())
        // The file is kept: the app and the probe must keep locking the same inode.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.appAliveFile.path))
    }

    func testFileIsPrivateAndTheDescriptorIsNotInheritedByChildren() throws {
        let lock = makeLock()
        XCTAssertTrue(try lock.tryAcquire())
        let attrs = try FileManager.default.attributesOfItem(atPath: lock.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let flags = fcntl(lock.fileDescriptor, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0, "a child such as pmset or osascript must not keep the app's liveness alive")
    }

    func testGoingAwayReleases() throws {
        var lock: AppAliveLock? = makeLock()
        XCTAssertTrue(try lock!.tryAcquire())
        let other = makeLock()
        XCTAssertFalse(try other.tryAcquire())
        lock = nil
        XCTAssertTrue(try other.tryAcquire())
    }

    func testAcquireGivesUpAfterTheBoundWhileHeldAndSucceedsOnceReleased() async throws {
        let held = makeLock()
        XCTAssertTrue(try held.tryAcquire())
        let mine = makeLock()
        let started = ContinuousClock.now
        let whileHeld = try await mine.acquire(timeout: 0.2)
        XCTAssertFalse(whileHeld)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertFalse(mine.isHeld)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(150))
            held.release()
        }
        let afterRelease = try await mine.acquire(timeout: 3)
        XCTAssertTrue(afterRelease)
        XCTAssertTrue(mine.isHeld)
    }

    /// A launch that found the lock held keeps trying: the moment the other
    /// holder exits, this one holds it, so the backstop counts it as running.
    func testAcquireEventuallyTakesTheLockOnceTheHolderIsGone() async throws {
        let held = makeLock()
        XCTAssertTrue(try held.tryAcquire())
        let mine = makeLock()
        let waiter = Task { await mine.acquireEventually(pollEvery: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(mine.isHeld, "still held elsewhere")
        held.release()
        await waiter.value
        XCTAssertTrue(mine.isHeld)
    }

    func testAcquireEventuallyStopsWhenCancelled() async throws {
        let held = makeLock()
        XCTAssertTrue(try held.tryAcquire())
        let mine = makeLock()
        let waiter = Task { await mine.acquireEventually(pollEvery: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(60))
        waiter.cancel()
        await waiter.value
        XCTAssertFalse(mine.isHeld)
        XCTAssertTrue(held.isHeld)
    }

    /// backstop.sh probes with `lockf -k -s -t 0 <file> /usr/bin/true` in
    /// another process: 75 (EX_TEMPFAIL) while the app holds the lock, 0
    /// once it is gone, and the probe's own hold is gone with the probe.
    func testLockfProbeSeesTheHeldLockAndItsRelease() throws {
        let lock = makeLock()
        XCTAssertTrue(try lock.tryAcquire())
        XCTAssertEqual(try probe(), 75, "the probe must not get the lock while the app holds it")
        lock.release()
        XCTAssertEqual(try probe(), 0, "released: the probe takes it, so the app is not running")
        XCTAssertTrue(try lock.tryAcquire(), "the probe gave it back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path), "lockf -k keeps the file")
    }
}
