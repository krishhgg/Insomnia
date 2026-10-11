import Darwin
import Foundation
import XCTest

/// The fixtures that start and end processes for the lock and log tests:
/// LockfHolder ends every process it starts and reaps it, and
/// PatchedBackstop.LogWriters serves each request before it settles.
final class OwnedChildTests: XCTestCase {
    private var dir: URL!
    private var holders: [LockfHolder] = []

    override func setUpWithError() throws {
        dir = ProcessTestHome.temporaryDirectory.appendingPathComponent("owned-child-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A holder that has not exited keeps the folder it locks in.
    override func tearDown() {
        for holder in holders where !holder.isSettled { holder.stop() }
        let unsettled = holders.filter { !$0.isSettled }
        guard unsettled.isEmpty else {
            XCTFail("keeping \(dir.path) for lockf holders that did not exit: \(unsettled.map(\.problems))")
            return
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private var lockFile: URL { dir.appendingPathComponent("lock") }

    private func holder(wait: Int) throws -> LockfHolder {
        let holder = try LockfHolder(
            file: lockFile, wait: wait, errors: dir.appendingPathComponent("errors-\(holders.count)"),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], directory: dir)
        holders.append(holder)
        return holder
    }

    /// Whether this process can take `lockFile`'s lock now, as lockf does.
    private func lockIsFree() throws -> Bool {
        let fd = open(lockFile.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChildError("could not open \(lockFile.path): errno \(errno)") }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
        guard errno == EWOULDBLOCK else { throw ChildError("flock \(lockFile.path): errno \(errno)") }
        return false
    }

    func testAHolderStopsOnceItsInputEndsAndIsReaped() throws {
        let holder = try holder(wait: 0)
        XCTAssertTrue(holder.held(within: 5), "\(holder.problems) \(holder.errorText())")
        XCTAssertFalse(try lockIsFree())
        XCTAssertEqual(holder.stop(), 0, "\(holder.problems)")
        XCTAssertTrue(holder.isSettled)
        XCTAssertEqual(holder.problems, [])
        XCTAssertEqual(holder.child.signal(0), -1, "a reaped holder is not signalled")
        XCTAssertTrue(try lockIsFree())
        XCTAssertEqual(holder.stop(), 0, "a second stop returns the same")
    }

    /// cat stuck writing to a full pipe does not end when its input
    /// closes. SIGINT to the group ends cat; lockf, which ignores SIGINT
    /// once it has run its command, reaps it and exits 70, and is reaped.
    func testAHolderWhoseCommandCannotFinishIsInterruptedAndReaped() throws {
        let holder = try holder(wait: 0)
        XCTAssertTrue(holder.held(within: 5), "\(holder.problems) \(holder.errorText())")
        XCTAssertGreaterThan(holder.jam(quietFor: 0.3), 0, "\(holder.problems)")
        XCTAssertEqual(holder.stop(within: 0.5, grace: 5), 70, "\(holder.problems)")
        XCTAssertTrue(holder.isSettled)
        XCTAssertEqual(holder.problems.count, 1, "\(holder.problems)")
        XCTAssertTrue(holder.problems.first?.contains("SIGINT to its group: sent") ?? false, "\(holder.problems)")
        XCTAssertTrue(try lockIsFree())
    }

    /// A holder that never gets the lock prints nothing back, and lockf
    /// gives up at its -t limit with 75.
    func testAHolderThatNeverGetsTheLockGivesUpAtItsLimit() throws {
        let fd = open(lockFile.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let holder = try holder(wait: 1)
        XCTAssertFalse(holder.held(within: 0.3))
        XCTAssertEqual(holder.stop(), 75, "\(holder.problems)")
        XCTAssertTrue(holder.isSettled)
    }

    /// The writer serves a request: it takes the log's lock, writes
    /// `held sh`, acknowledges, writes `ort` a second later and lets go.
    /// Two settles at once get one outcome.
    func testTheLogWriterServesARequestAndSettlesOnce() async throws {
        let log = dir.appendingPathComponent("insomnia.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let writers = try PatchedBackstop.LogWriters(dir: dir.appendingPathComponent("writers", isDirectory: true), log: log)
        // As the fake does: made under a dot name, then renamed.
        let made = writers.requests.appendingPathComponent(".r1")
        try Data().write(to: made)
        try FileManager.default.moveItem(at: made, to: writers.requests.appendingPathComponent("r1"))
        let ack = writers.acks.appendingPathComponent("r1")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ack.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ack.path))
        let fd = open(log.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "the writer holds the log's lock once it acknowledges")
        close(fd)
        try Data().write(to: writers.seen.appendingPathComponent("r1"))

        async let first = writers.settle()
        async let second = writers.settle()
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, [0])
        XCTAssertEqual(b, [0])
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "held short")
    }

    /// A request the fake did not see answered in time fails the settle.
    func testTheLogWriterSettleFailsForALateAcknowledgment() async throws {
        let log = dir.appendingPathComponent("insomnia.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let writers = try PatchedBackstop.LogWriters(dir: dir.appendingPathComponent("writers", isDirectory: true), log: log)
        try Data().write(to: writers.late.appendingPathComponent("r1"))
        do {
            _ = try await writers.settle()
            XCTFail("settled with a late acknowledgment")
        } catch let error as PatchedBackstop.LogWriters.Unsettled {
            XCTFail("\(error)")
        } catch {
            XCTAssertTrue("\(error)".contains("late [\"r1\"]"), "\(error)")
        }
    }
}
