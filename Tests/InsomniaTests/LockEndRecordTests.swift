import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// The last place the end of a session is recorded: the recovery lock file,
/// for an end that cannot remove session.json while ended-session.json, the
/// journal and both folders of records aside refuse the record. The file
/// exists already, so the record needs no new file; it is written in place,
/// so the file keeps its inode and stays the lock the app and the agent
/// take. Content that is not a whole record counts as the end of whatever
/// session.json holds until that file is gone. The agent is the real
/// backstop.sh with its tools patched to fakes (PatchedBackstop).
@MainActor
final class LockEndRecordTests: XCTestCase {
    var h: Harness!
    var agent: PatchedBackstop!

    override func setUp() async throws {
        h = Harness()
        try h.home.paths.createDirectories()
        agent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent", isDirectory: true))
    }

    override func tearDown() async throws {
        try? TestACL.removeAll(h.home.paths.appSupport)
        try? TestACL.removeAll(h.home.paths.logs)
        unpinAll()
        h.home.destroy()
    }

    private var lockFile: URL { h.home.paths.recoveryLock }
    private let unrelatedRecord = Data("an end record of some other session.json".utf8)

    private func inode(_ url: URL) throws -> UInt64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw POSIXError(.ENOENT) }
        return UInt64(st.st_ino)
    }

    private func lockBytes() -> Data? { try? Data(contentsOf: lockFile) }

    private func record(of data: Data) -> Data {
        Data("\(Store.lockEndRecordTag) \(data.base64EncodedString())\n".utf8)
    }

    /// Writes `data` into the file at `url` in place, keeping its inode.
    private func writeInPlace(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    private func sleepHeldAgain(since count: Int) -> Bool {
        h.guardFake.calls.dropFirst(count).contains("disablesleep 1")
    }

    private func runAgent(expecting status: Int32, file: StaticString = #filePath, line: UInt = #line) async throws {
        let exit = try await agent.run()
        XCTAssertEqual(exit, status, logText(), file: file, line: line)
    }

    private var pinnable: [URL] { [h.home.paths.sessionFile, h.home.paths.endedSessionFile, h.home.paths.stateFile] }

    /// A running session whose files take no record: session.json, an
    /// unrelated ended-session.json and state.json are immutable.
    private func startThenPinAll() async throws -> SessionManager {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        try unrelatedRecord.write(to: h.home.paths.endedSessionFile)
        for file in pinnable { try setImmutable(file, true) }
        return m
    }

    private func unpinAll() {
        for file in pinnable { try? setImmutable(file, false) }
    }

    private let endedInLockLine = "reconcile: session.json holds a session already ended (recorded in .recovery.lock); restoring, not resuming"

    // MARK: Reading

    /// The app's reader (Store.lockEndRecord) and the agent's
    /// (read_lock_record) on the same bytes, one fresh home per case:
    /// whether they count the session in session.json as ended, and that a
    /// whole record of other bytes is emptied by the agent while the
    /// session stays. The app is alive and the machine within every floor,
    /// so the agent ends only a session it finds recorded as ended.
    func testTheAppAndTheAgentReadEveryShapeOfContentAlike() async throws {
        enum Kind { case none, record, unknown }
        let tag = Store.lockEndRecordTag
        let other = Data("an earlier session.json".utf8).base64EncodedString()
        let cases: [(name: String, kind: Kind, ends: Bool, content: (String) -> Data)] = [
            ("empty", .none, false, { _ in Data() }),
            ("this session", .record, true, { Data("\(tag) \($0)\n".utf8) }),
            ("another session", .record, false, { _ in Data("\(tag) \(other)\n".utf8) }),
            ("no newline", .unknown, true, { Data("\(tag) \($0)".utf8) }),
            ("two newlines", .unknown, true, { Data("\(tag) \($0)\n\n".utf8) }),
            ("carriage return", .unknown, true, { Data("\(tag) \($0)\r\n".utf8) }),
            ("other tag", .unknown, true, { Data("ended-session-v2 \($0)\n".utf8) }),
            ("two spaces", .unknown, true, { Data("\(tag)  \($0)\n".utf8) }),
            ("cut base64", .unknown, true, { Data("\(tag) \($0.dropLast())\n".utf8) }),
            ("cut short", .unknown, true, { Data("\(tag) \($0)\n".utf8.prefix(10)) }),
            ("three pads", .unknown, true, { _ in Data("\(tag) Q===\n".utf8) }),
            ("pads only", .unknown, true, { _ in Data("\(tag) ====\n".utf8) }),
            ("pad inside", .unknown, true, { _ in Data("\(tag) QQ==QQ==\n".utf8) }),
            ("NUL byte", .unknown, true, { Data("\(tag) \($0)".utf8) + Data([0]) + Data("\n".utf8) }),
            ("trailing byte", .unknown, true, { Data("\(tag) \($0)\nx".utf8) }),
            ("newline only", .unknown, true, { _ in Data("\n".utf8) }),
            ("other text", .unknown, true, { _ in Data("pid 4242\n".utf8) }),
            ("over the bound", .unknown, true, { _ in Data(repeating: 0x41, count: Store.lockEndRecordMaxBytes + 1) }),
        ]
        for c in cases {
            let home = Harness()
            defer { home.home.destroy() }
            try home.home.paths.createDirectories()
            let caseAgent = try PatchedBackstop(home: home.home.root, dir: home.home.root.appendingPathComponent("agent", isDirectory: true))
            let m = home.makeManager()
            await m.reconcile()
            await m.start(duration: 3600)
            XCTAssertTrue(m.isActive, c.name)
            let marker = try XCTUnwrap(home.store.sessionEndMarker())
            let lock = home.home.paths.recoveryLock
            let lockInode = try inode(lock)
            let content = c.content(marker)
            try writeInPlace(content, to: lock)

            switch (c.kind, Store.parseLockEndRecord(content)) {
            case (.none, .none), (.record, .record), (.unknown, .unknown): break
            case let (_, parsed): XCTFail("\(c.name): parsed as \(parsed)")
            }
            if content.count > Store.lockEndRecordMaxBytes {
                XCTAssertEqual(home.store.lockEndRecord(), .unknown("it holds \(content.count) bytes, more than an end record"), c.name)
            }
            XCTAssertEqual(home.store.sessionEndRecordedInLock() != nil, c.ends, c.name)

            let alive = AppAliveLock(url: home.home.paths.appAliveFile)
            XCTAssertTrue(try alive.tryAcquire())
            let status = try await caseAgent.run()
            alive.release()
            let log = (try? String(contentsOf: home.home.paths.logFile, encoding: .utf8)) ?? ""
            XCTAssertEqual(status, 0, "\(c.name): \(log)")
            XCTAssertEqual(try home.store.loadSession() == nil, c.ends, "\(c.name): \(log)")
            XCTAssertEqual(log.contains("already ended (recorded in \(lock.path)"), c.ends, "\(c.name): \(log)")
            XCTAssertEqual(caseAgent.calls.contains("pmset -g batt"), !c.ends, "\(c.name): checked only when not ended")
            // Emptied once its session.json is gone, and a whole record of
            // other bytes at once; nothing else while the session stays.
            XCTAssertEqual(try Data(contentsOf: lock), c.ends || c.kind == .record || c.kind == .none ? Data() : content, c.name)
            XCTAssertEqual(try inode(lock), lockInode, c.name)
        }
    }

    /// A file the app cannot read whole counts as the end of any session,
    /// as does content that is not a whole record; neither ends anything
    /// once session.json is gone. A directory at the path is no record.
    func testContentThatCannotBeReadWholeCountsAsTheEndUntilSessionJSONIsGone() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        FileManager.default.createFile(atPath: lockFile.path, contents: Data("\(Store.lockEndRecordTag) QUJ".utf8))
        XCTAssertEqual(h.store.lockEndRecord(), .unknown("it holds bytes other than one whole end record"))
        XCTAssertEqual(h.store.sessionEndRecordedInLock(), ".recovery.lock, which it holds bytes other than one whole end record, so it counts as the end of any session")

        let whole = record(of: try Data(contentsOf: h.home.paths.sessionFile))
        try writeInPlace(whole, to: lockFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: lockFile.path)
        if case let .unknown(why) = h.store.lockEndRecord() {
            XCTAssertTrue(why.hasPrefix("it could not be read"), why)
        } else {
            XCTFail("an unreadable lock file read as \(h.store.lockEndRecord())")
        }
        XCTAssertNil(h.store.lockContents(), "a start cannot put back what it cannot read")
        XCTAssertNotNil(h.store.sessionEndRecordedInLock())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockFile.path)
        XCTAssertEqual(h.store.sessionEndRecordedInLock(), ".recovery.lock")

        try h.store.remove(at: h.home.paths.sessionFile)
        XCTAssertNil(h.store.sessionEndRecordedInLock(), "nothing to end without session.json")

        try FileManager.default.removeItem(at: lockFile)
        try FileManager.default.createDirectory(at: lockFile, withIntermediateDirectories: false)
        XCTAssertEqual(h.store.lockEndRecord(), .none)
        XCTAssertEqual(h.store.lockContents(), Data())
    }

    // MARK: Writing

    /// The Store writes and empties the record through the handle of the
    /// lock this process holds, in place: the inode stays, the file stays
    /// the lock, and its descriptors still pass to a child. Without a held
    /// lock nothing is written or emptied. A record of one session.json
    /// ends no other.
    func testTheStoreWritesAndEmptiesTheRecordInPlaceOnlyThroughTheHeldLock() throws {
        let lock = RecoveryLock(url: lockFile)
        let held = try XCTUnwrap(try lock.tryAcquire())
        defer { held.release() }
        let lockInode = try inode(lockFile)
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)

        XCTAssertFalse(h.store.recordSessionEndInLock(lock: nil))
        XCTAssertEqual(lockBytes(), Data(), "nothing is written without the lock")
        XCTAssertTrue(h.store.recordSessionEndInLock(lock: held))
        XCTAssertEqual(lockBytes(), record(of: bytes))
        XCTAssertEqual(try inode(lockFile), lockInode)
        XCTAssertEqual(h.store.sessionEndRecordedInLock(), ".recovery.lock")
        XCTAssertTrue(h.store.recordSessionEndInLock(lock: nil), "a record already there is used again")
        XCTAssertNil(try lock.tryAcquire(), "the file is still the lock")
        let child = try XCTUnwrap(held.descriptorForChild())
        var onChild = stat()
        XCTAssertEqual(fstat(child, &onChild), 0)
        XCTAssertEqual(UInt64(onChild.st_ino), lockInode)
        close(child)

        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(1200)))
        XCTAssertNil(h.store.sessionEndRecordedInLock(), "a record of other bytes ends nothing")
        XCTAssertFalse(h.store.clearLockEndRecord(lock: nil))
        XCTAssertEqual(lockBytes(), record(of: bytes), "nothing is emptied without the lock")
        XCTAssertTrue(h.store.clearLockEndRecord(lock: held))
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)

        // Shorter content over longer is cut to its length.
        XCTAssertTrue(held.replaceContents(with: Data(repeating: 0x41, count: 4096), at: lockFile.path))
        XCTAssertTrue(held.replaceContents(with: Data("short\n".utf8), at: lockFile.path))
        XCTAssertEqual(lockBytes(), Data("short\n".utf8))
        XCTAssertTrue(h.store.restoreLockContents(Data(), lock: held))
        XCTAssertEqual(lockBytes(), Data())

        held.release()
        XCTAssertFalse(held.replaceContents(with: Data("x".utf8), at: lockFile.path), "a released handle writes nothing")
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// A symlink at the lock path is never read or written as a record,
    /// even when the file it points to holds a matching one and the lock
    /// was taken through it. A file the handle does not hold is not
    /// written either.
    func testASymlinkOrAnotherFileAtTheLockPathIsNeverReadOrWrittenAsARecord() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        let target = h.home.root.appendingPathComponent("elsewhere.lock")
        try record(of: bytes).write(to: target)
        try? FileManager.default.removeItem(at: lockFile)
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: target)

        XCTAssertEqual(h.store.lockEndRecord(), .none)
        XCTAssertNil(h.store.sessionEndRecordedInLock())
        // The handle's descriptor is open on the target, so anything
        // written or emptied through it would show there.
        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }
        var onHandle = stat()
        let child = try XCTUnwrap(held.descriptorForChild())
        XCTAssertEqual(fstat(child, &onHandle), 0)
        close(child)
        XCTAssertEqual(UInt64(onHandle.st_ino), try inode(target))
        XCTAssertFalse(h.store.recordSessionEndInLock(lock: held))
        XCTAssertTrue(h.store.clearLockEndRecord(lock: held), "a symlink holds no record to empty")
        XCTAssertFalse(held.replaceContents(with: Data("x".utf8), at: lockFile.path))
        XCTAssertFalse(h.store.restoreLockContents(Data("x".utf8), lock: held))
        XCTAssertEqual(try Data(contentsOf: target), record(of: bytes), "nothing written or emptied through the symlink")

        // The path now names a regular file the handle does not hold.
        try FileManager.default.removeItem(at: lockFile)
        try Data().write(to: lockFile)
        XCTAssertFalse(h.store.recordSessionEndInLock(lock: held))
        XCTAssertEqual(lockBytes(), Data())
    }

    // MARK: The app's end

    /// The app ends a session whose files take no record and neither
    /// folder takes a new file: the end is recorded in the lock file, in
    /// place, before anything is undone. After every file and both folders
    /// are repaired, a relaunch with SleepDisabled still 1 ends it instead
    /// of holding sleep again, removes session.json and empties the lock
    /// file, which keeps its inode throughout.
    func testAnAppEndRecordedOnlyInTheLockFileIsNotResumedAfterAFullRepair() async throws {
        let m = try await startThenPinAll()
        let lockInode = try inode(lockFile)
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        try TestACL.denyNewFiles(in: h.home.paths.logs)

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .sessionRetained)
        XCTAssertEqual(lockBytes(), record(of: bytes))
        XCTAssertEqual(try inode(lockFile), lockInode)
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        XCTAssertTrue(logText().contains("could not remove session.json: "), logText())
        XCTAssertTrue(logText().contains("; its end is recorded in the recovery lock file .recovery.lock"), logText())
        XCTAssertTrue(h.notifier.posts.last?.body.contains("its end is recorded, so a relaunch will not resume it") == true, "\(h.notifier.posts)")

        try TestACL.removeAll(h.home.paths.appSupport)
        try TestACL.removeAll(h.home.paths.logs)
        unpinAll()
        h.guardFake.sleepDisabled = true
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, logText())
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertTrue(logText().contains(endedInLockLine), logText())
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// An ordinary end leaves the lock file empty, and so does an end that
    /// cannot remove session.json while the journal takes the record: the
    /// lock file is only the last place.
    func testAnOrdinaryEndAndAWritableJournalLeaveTheLockFileEmpty() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        let lockInode = try inode(lockFile)
        _ = await m.end(reason: .user)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(lockBytes(), Data())

        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        try unrelatedRecord.write(to: h.home.paths.endedSessionFile)
        try setImmutable(h.home.paths.sessionFile, true)
        try setImmutable(h.home.paths.endedSessionFile, true)
        _ = await m.end(reason: .user)
        XCTAssertTrue(logText().contains("its end is recorded in state.json"), logText())
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    // MARK: The agent's end

    /// The reviewer's case: session.json, an unrelated ended-session.json
    /// and state.json immutable, neither folder takes a new file, and the
    /// restore fails. The agent records the end in the lock file before the
    /// undo and keeps the inode. After every flag and both ACLs are
    /// repaired, the app launches first with SleepDisabled still 1: it ends
    /// the session instead of holding sleep again, removes session.json
    /// and empties the lock file. Neither folder takes the run's status
    /// files either, so it waits for a status that never comes; the fake
    /// commands get a 2 s limit instead of 30 s to shorten that wait.
    func testAnAgentEndRecordedOnlyInTheLockFileIsNotRevivedAfterAFullRepair() async throws {
        _ = try await startThenPinAll()
        try agent.setCommandTimeout(2)
        let lockInode = try inode(lockFile)
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        try agent.failSudo()
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        try TestACL.denyNewFiles(in: h.home.paths.logs)

        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(lockBytes(), record(of: bytes))
        XCTAssertEqual(try inode(lockFile), lockInode)
        XCTAssertTrue(logText().contains("its end is recorded in the recovery lock file \(lockFile.path) instead"), logText())

        try TestACL.removeAll(h.home.paths.appSupport)
        try TestACL.removeAll(h.home.paths.logs)
        unpinAll()
        XCTAssertTrue(h.guardFake.sleepDisabled, "the failed restore left it at 1")
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, logText())
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLockLine), logText())
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// The same end with a restore that works and no record aside possible
    /// (MKTEMP fails): sleep is restored, then something else sets
    /// SleepDisabled to 1 again. After the repair, the app does not hold
    /// sleep again for the session: the lock file says it ended.
    func testAForeignHoldAfterTheAgentsRestoreDoesNotReviveASessionEndedInTheLockFile() async throws {
        _ = try await startThenPinAll()
        let lockInode = try inode(lockFile)
        try agent.refuseRecordsAside()

        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall))
        XCTAssertEqual(lockBytes(), record(of: try Data(contentsOf: h.home.paths.sessionFile)))
        h.guardFake.sleepDisabled = false

        unpinAll()
        h.guardFake.sleepDisabled = true
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, logText())
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLockLine), logText())
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// The app still running when the agent ends its session that way: the
    /// next tick finds the end in the lock file and ends the session too.
    func testTheTickEndsASessionTheAgentEndedInTheLockFile() async throws {
        let m = try await startThenPinAll()
        try agent.refuseRecordsAside()
        try await runAgent(expecting: 1)
        XCTAssertNotNil(h.store.sessionEndRecordedInLock())

        await m.noticeAgentEnd()

        XCTAssertFalse(m.isActive)
        XCTAssertTrue(logText().contains("is recorded as ended in .recovery.lock: the recovery agent ended it"), logText())
    }

    /// The agent writes the record but cannot read it back (CAT fails): it
    /// does not count it as recorded, logs that nothing took the record and
    /// keeps the sleep entry. Its next run reads the file as unreadable,
    /// which counts as the end. The app reads the whole record and does not
    /// resume the session after a repair.
    func testARecordTheAgentCannotReadBackStillEndsTheSession() async throws {
        _ = try await startThenPinAll()
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        try agent.refuseRecordsAside()
        try agent.failLockReadBack()

        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("or the recovery lock file \(lockFile.path). Sleep is restored anyway"), logText())
        XCTAssertEqual(lockBytes(), record(of: bytes), "written, though not read back")

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        agent.clearCalls()
        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(lockFile.path), which it could not be read, so it counts as the end of any session)"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"))

        unpinAll()
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLockLine), logText())
    }

    // MARK: Other sessions and cleanup

    /// A crash with the lock file empty, and with a whole record of an
    /// earlier session's bytes, resumes: neither ends this session. The
    /// agent then empties the stale record and checks the session as
    /// usual. Content that is not a whole record ends it (the cost of the
    /// safe side).
    func testAStaleRecordEndsNoNewerSessionAndOnlyContentThatIsNoWholeRecordDoes() async throws {
        let first = h.makeManager()
        await first.reconcile()
        await first.start(duration: 3600)
        let lockInode = try inode(lockFile)

        var before = h.guardFake.calls.count
        let crashed = h.makeManager()
        await crashed.reconcile()
        XCTAssertTrue(crashed.isActive, logText())
        XCTAssertTrue(sleepHeldAgain(since: before))

        let stale = record(of: Data("an earlier session.json".utf8))
        try writeInPlace(stale, to: lockFile)
        before = h.guardFake.calls.count
        let again = h.makeManager()
        await again.reconcile()
        XCTAssertTrue(again.isActive, logText())
        XCTAssertTrue(sleepHeldAgain(since: before))
        XCTAssertEqual(lockBytes(), stale)

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertTrue(agent.calls.contains("pmset -g batt"))
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)

        try writeInPlace(Data("\(Store.lockEndRecordTag) QUJ".utf8), to: lockFile)
        before = h.guardFake.calls.count
        let partial = h.makeManager()
        await partial.reconcile()
        XCTAssertFalse(partial.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before))
        XCTAssertTrue(logText().contains("recorded in .recovery.lock, which it holds bytes other than one whole end record, so it counts as the end of any session"), logText())
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// A start empties whatever the lock file held before (it ended no
    /// session.json once the new one is written), and a start that fails
    /// puts back the session.json it replaced together with the record of
    /// its end. A lock file that cannot be read whole refuses a start over
    /// a session.json, which a rollback could not put back with its record.
    func testAStartEmptiesTheRecordAndARollbackPutsItBack() async throws {
        let m = h.makeManager()
        await m.reconcile()
        try writeInPlace(Data("left over".utf8), to: lockFile)
        let lockInode = try inode(lockFile)
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(lockBytes(), Data())
        _ = await m.end(reason: .user)

        let earlier = #"{"endsAt":"2027-01-15T08:30:00Z","extensions":[],"startedAt":"2027-01-15T08:00:00Z"}"#
        try Data(earlier.utf8).write(to: h.home.paths.sessionFile)
        let ended = record(of: Data(earlier.utf8))
        try writeInPlace(ended, to: lockFile)
        h.backstop.failArm = true
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), Data(earlier.utf8))
        XCTAssertEqual(lockBytes(), ended, "the record goes back with the file it ends")
        XCTAssertEqual(try inode(lockFile), lockInode)

        try writeInPlace(Data(repeating: 0x41, count: Store.lockEndRecordMaxBytes + 1), to: lockFile)
        h.backstop.failArm = false
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertTrue(logText().contains("start refused, nothing changed: \(lockFile.path) could not be read whole"), logText())
        XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), Data(earlier.utf8))

        try writeInPlace(ended, to: lockFile)
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertNotEqual(try Data(contentsOf: h.home.paths.sessionFile), Data(earlier.utf8))
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// session.json removed outside the lock cannot empty the record: it
    /// is logged and stays, ending nothing, and the agent's next run
    /// empties it in place.
    func testARecordLeftByACleanupWithoutTheLockIsEmptiedByTheNextRun() async throws {
        let m = h.makeManager()
        await m.reconcile()
        let lockInode = try inode(lockFile)
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let ended = record(of: try Data(contentsOf: h.home.paths.sessionFile))
        try writeInPlace(ended, to: lockFile)

        try h.store.deleteSession()

        XCTAssertEqual(lockBytes(), ended)
        XCTAssertTrue(logText().contains("could not empty \(lockFile.path) of the record of a session's end"), logText())
        try await runAgent(expecting: 0)
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }
}
