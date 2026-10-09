import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// The last place the end of a session is recorded: the recovery lock file,
/// for an end that cannot remove session.json while ended-session.json, the
/// journal and both folders of records aside refuse the record. The file
/// exists already, so the record needs no new file; it is written in place,
/// so the file keeps its inode and stays the lock the app and the agent
/// take. Content read whole that is not a whole record ends no session,
/// unless it is the record of the session in session.json cut short as a
/// writer leaves it (its first bytes, or the whole record with old bytes
/// after it), which counts as that session's end; a file that cannot be
/// read counts as the end of whatever session.json holds until that file
/// is gone. The agent is the real backstop.sh with its tools patched to
/// fakes (PatchedBackstop).
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
        Store.lockReadErrnoForTesting = nil
        Store.lockReadFailuresForTesting = nil
        RecoveryLockHandle.pwriteForTesting = nil
        try? FileManager.default.setAttributes([.appendOnly: false], ofItemAtPath: lockFile.path)
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

    private func logText(since mark: Int) -> String { String(logText().dropFirst(mark)) }

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

    private var cutShortLine: String {
        "already ended (recorded in \(lockFile.path), which holds this session's end record cut short, so it counts as one)"
    }

    /// A session.json an earlier session left, written directly.
    private let earlier = Data(#"{"endsAt":"2027-01-15T08:30:00Z","extensions":[],"startedAt":"2027-01-15T08:00:00Z"}"#.utf8)

    /// session.json, state.json and the lock file as a crash would leave
    /// them; nil for a file that is not there.
    private struct DiskCopy: Equatable {
        let session: Data?
        let state: Data?
        let lock: Data?
    }

    private func diskCopy() -> DiskCopy {
        DiskCopy(session: try? Data(contentsOf: h.home.paths.sessionFile),
                 state: try? Data(contentsOf: h.home.paths.stateFile),
                 lock: lockBytes())
    }

    /// Puts a copy back, the lock file in place.
    private func putBack(_ copy: DiskCopy) throws {
        for (url, data) in [(h.home.paths.sessionFile, copy.session), (h.home.paths.stateFile, copy.state)] {
            if let data {
                try data.write(to: url)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try writeInPlace(copy.lock ?? Data(), to: lockFile)
    }

    /// One agent run while the app is running (its alive lock held).
    private func runAgentBesideTheApp() async throws -> (status: Int32, log: String) {
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        agent.clearCalls()
        let mark = logText().count
        let status = try await agent.run()
        return (status, logText(since: mark))
    }

    // MARK: Reading

    /// The app's reader (Store.lockEndRecord) and the agent's
    /// (read_lock_record) on the same bytes, one fresh home per case:
    /// whether they count the session in session.json as ended, and that
    /// the agent empties a whole record of other bytes and content that is
    /// no record while the session stays. This session's record cut short
    /// (its first bytes, or the whole record and more) counts as its end
    /// for both; another session's record cut short past the first byte
    /// where the two differ does not. The app is alive and the machine
    /// within every floor, so the agent ends only a session it finds
    /// recorded as ended. The homes are set up one at a time (each Harness
    /// points INSOMNIA_HOME at its own), and the agent runs go several at a
    /// time.
    func testTheAppAndTheAgentReadEveryShapeOfContentAlike() async throws {
        enum Kind { case none, record, foreign }
        let tag = Store.lockEndRecordTag
        let other = Data("an earlier session.json".utf8).base64EncodedString()
        let cases: [(name: String, kind: Kind, ends: Bool, content: (String) -> Data)] = [
            ("empty", .none, false, { _ in Data() }),
            ("this session", .record, true, { Data("\(tag) \($0)\n".utf8) }),
            ("another session", .record, false, { _ in Data("\(tag) \(other)\n".utf8) }),
            ("no newline", .foreign, true, { Data("\(tag) \($0)".utf8) }),
            ("two newlines", .foreign, true, { Data("\(tag) \($0)\n\n".utf8) }),
            ("carriage return", .foreign, false, { Data("\(tag) \($0)\r\n".utf8) }),
            ("other tag", .foreign, false, { Data("ended-session-v2 \($0)\n".utf8) }),
            ("two spaces", .foreign, false, { Data("\(tag)  \($0)\n".utf8) }),
            ("cut base64", .foreign, false, { Data("\(tag) \($0.dropLast())\n".utf8) }),
            ("cut short", .foreign, true, { Data("\(tag) \($0)\n".utf8.prefix(10)) }),
            ("first byte", .foreign, true, { Data("\(tag) \($0)\n".utf8.prefix(1)) }),
            ("cut inside the base64", .foreign, true, { Data("\(tag) \($0)\n".utf8.prefix(tag.utf8.count + 1 + $0.utf8.count / 2)) }),
            ("record and old bytes", .foreign, true, { Data("\(tag) \($0)\n".utf8) + Data(repeating: 0x41, count: 4096) }),
            ("another session cut short", .foreign, false, { _ in Data("\(tag) \(other)\n".utf8.prefix(tag.utf8.count + 1 + 8)) }),
            ("three pads", .foreign, false, { _ in Data("\(tag) Q===\n".utf8) }),
            ("pads only", .foreign, false, { _ in Data("\(tag) ====\n".utf8) }),
            ("pad inside", .foreign, false, { _ in Data("\(tag) QQ==QQ==\n".utf8) }),
            ("NUL byte", .foreign, false, { Data("\(tag) \($0)".utf8) + Data([0]) + Data("\n".utf8) }),
            ("trailing byte", .foreign, true, { Data("\(tag) \($0)\nx".utf8) }),
            ("newline only", .foreign, false, { _ in Data("\n".utf8) }),
            ("other text", .foreign, false, { _ in Data("pid 4242\n".utf8) }),
            ("over the bound", .foreign, false, { _ in Data(repeating: 0x41, count: Store.lockEndRecordMaxBytes + 1) }),
        ]
        var homes: [Harness] = []
        defer { homes.forEach { $0.home.destroy() } }
        // Each row keeps its manager, as the app runs beside its agent.
        var rows: [(home: Harness, agent: PatchedBackstop, manager: SessionManager, alive: AppAliveLock, lockInode: UInt64)] = []
        for c in cases {
            let home = Harness()
            homes.append(home)
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
            case (.none, .none), (.record, .record), (.foreign, .foreign): break
            case let (_, parsed): XCTFail("\(c.name): parsed as \(parsed)")
            }
            if content.count > Store.lockEndRecordMaxBytes {
                XCTAssertEqual(home.store.lockEndRecord(), .foreign("it holds \(content.count) bytes, more than an end record"), c.name)
            }
            XCTAssertEqual(home.store.sessionEndRecordedInLock() != nil, c.ends, c.name)

            let alive = AppAliveLock(url: home.home.paths.appAliveFile)
            XCTAssertTrue(try alive.tryAcquire())
            rows.append((home, caseAgent, m, alive, lockInode))
        }

        let statuses = try await PatchedBackstop.runAll(rows.map(\.agent))

        for (c, (row, status)) in zip(cases, zip(rows, statuses)) {
            let (home, caseAgent, lockInode) = (row.home, row.agent, row.lockInode)
            row.alive.release()
            let lock = home.home.paths.recoveryLock
            let log = (try? String(contentsOf: home.home.paths.logFile, encoding: .utf8)) ?? ""
            XCTAssertEqual(status, 0, "\(c.name): \(log)")
            XCTAssertEqual(try home.store.loadSession() == nil, c.ends, "\(c.name): \(log)")
            XCTAssertEqual(log.contains("already ended (recorded in \(lock.path)"), c.ends, "\(c.name): \(log)")
            XCTAssertEqual(log.contains("already ended (recorded in \(lock.path), which holds this session's end record cut short, so it counts as one)"), c.ends && c.kind == .foreign, "\(c.name): \(log)")
            XCTAssertEqual(caseAgent.calls.contains("pmset -g batt"), !c.ends, "\(c.name): checked only when not ended")
            // Emptied once its session.json is gone, and a whole record of
            // other bytes or content that is no record and not this
            // session's record cut short at once.
            XCTAssertEqual(try Data(contentsOf: lock), Data(), c.name)
            XCTAssertEqual(log.contains("emptying \(lock.path): "), c.kind == .foreign, "\(c.name): \(log)")
            XCTAssertEqual(try inode(lock), lockInode, c.name)
        }
    }

    /// Content read whole that is not a whole record ends no session, a
    /// file over the bound included, which a start does not keep. A file
    /// the app cannot read counts as the end of the session in
    /// session.json, as it may hold its record, and ends nothing once
    /// session.json is gone. A directory at the path is no record.
    func testContentThatIsNoRecordEndsNothingAndAnUnreadableFileCountsAsTheEnd() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        FileManager.default.createFile(atPath: lockFile.path, contents: Data("\(Store.lockEndRecordTag) QUJ".utf8))
        XCTAssertEqual(h.store.lockEndRecord(), .foreign("it holds bytes other than one whole end record"))
        XCTAssertNil(h.store.sessionEndRecordedInLock())
        XCTAssertEqual(h.store.lockContents(), Data("\(Store.lockEndRecordTag) QUJ".utf8))

        let large = Data(repeating: 0x41, count: Store.lockEndRecordMaxBytes + 1)
        try writeInPlace(large, to: lockFile)
        XCTAssertEqual(h.store.lockEndRecord(), .foreign("it holds \(large.count) bytes, more than an end record"))
        XCTAssertNil(h.store.sessionEndRecordedInLock())
        XCTAssertEqual(h.store.lockContents(), Data(), "a start does not put back content that ends nothing")

        let whole = record(of: try Data(contentsOf: h.home.paths.sessionFile))
        try writeInPlace(whole, to: lockFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: lockFile.path)
        if case let .unreadable(why) = h.store.lockEndRecord() {
            XCTAssertTrue(why.hasPrefix("it could not be read"), why)
        } else {
            XCTFail("an unreadable lock file read as \(h.store.lockEndRecord())")
        }
        XCTAssertNil(h.store.lockContents(), "a start cannot put back what it cannot read")
        XCTAssertEqual(h.store.sessionEndRecordedInLock(), ".recovery.lock, which it could not be read (Permission denied), so it may hold this session's end and counts as one")
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

        // A record goes over content that is no record. A file that cannot
        // be read counts as the end already and is never written over: what
        // it holds is unknown, and a write over it could leave fewer bytes
        // of a whole record than it held. The end goes on to the log.
        let current = try Data(contentsOf: h.home.paths.sessionFile)
        try writeInPlace(Data("pid 4242\n".utf8), to: lockFile)
        XCTAssertTrue(h.store.recordSessionEndInLock(lock: held))
        XCTAssertEqual(lockBytes(), record(of: current))
        try writeInPlace(record(of: bytes), to: lockFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: lockFile.path)
        XCTAssertNotNil(h.store.sessionEndRecordedInLock(), "a file that cannot be read counts as the end")
        XCTAssertFalse(h.store.recordSessionEndInLock(lock: held), "nor is it written over")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockFile.path)
        XCTAssertEqual(lockBytes(), record(of: bytes), "left as it was")
        XCTAssertTrue(h.store.clearLockEndRecord(lock: held))
        XCTAssertEqual(try inode(lockFile), lockInode)

        held.release()
        XCTAssertFalse(held.replaceContents(with: Data("x".utf8), at: lockFile.path), "a released handle writes nothing")
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// A write in place that writes no byte ends the attempt instead of
    /// being tried again forever: `replaceContents` returns false after
    /// that one write, and the file keeps the bytes it shared with the
    /// start of the new content.
    func testAWriteInPlaceThatWritesNothingEndsTheAttempt() throws {
        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }
        XCTAssertTrue(held.replaceContents(with: Data("same start, old end".utf8), at: lockFile.path))
        let calls = Locked(0)
        RecoveryLockHandle.pwriteForTesting = { _, _, _, _ in
            calls.value += 1
            return 0
        }
        defer { RecoveryLockHandle.pwriteForTesting = nil }

        XCTAssertFalse(held.replaceContents(with: Data("same start, new end".utf8), at: lockFile.path))
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(lockBytes(), Data("same start, ".utf8))
    }

    /// Every state a writer leaves when it stops partway through this
    /// session's record, over old content of each kind and length it can
    /// find there. The app keeps the bytes the file shares with the start
    /// of the record (p of them), cuts the file to them, then appends the
    /// rest (`RecoveryLockHandle.replaceContents`). A file size limit of k
    /// bytes stops its real write, for every k up to all but one byte and
    /// each length and shared part around it: below p the cut itself fails
    /// (macOS refuses ftruncate to a length past the limit), so the file is
    /// unchanged; from p on, it holds the record's first k bytes, nothing
    /// at all when p and k are 0. A stop between the cut and the append, or
    /// in the append, leaves the record's first j bytes for j from p on,
    /// which the test writes itself, as it does the agent's states. The
    /// agent leaves content that already counts as the end as it is or
    /// appends the rest to the record's first bytes, and empties anything
    /// else with `>` before it writes (record_end_in_lock). Each state is
    /// one of three, told apart here: the old bytes unchanged, which count
    /// exactly as they did; an empty file, the zero bytes before a first
    /// byte, reached only from content that shares no first byte with the
    /// record and so did not count; or the record's first bytes, a partial
    /// record, which counts. So no state counts for less than the content
    /// found. The app's writer then completes the record from each start in
    /// place.
    func testAWriterStoppedPartwayNeverLeavesLessOfThisEndThanItFound() throws {
        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }
        let lockInode = try inode(lockFile)
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let whole = record(of: try Data(contentsOf: h.home.paths.sessionFile))
        let other = record(of: Data("an earlier session.json".utf8))
        let tagged = Store.lockEndRecordTag.utf8.count + 1
        let starts: [(name: String, content: Data, counts: Bool)] = [
            ("empty", Data(), false),
            ("one byte of other text", Data("p".utf8), false),
            ("other text", Data("pid 4242\n".utf8), false),
            ("other text as long as the record", Data(repeating: 0x41, count: whole.count), false),
            ("more bytes than the record", Data(repeating: 0x41, count: whole.count * 3), false),
            ("another session's record", other, false),
            ("another session's record cut short", other.prefix(whole.count / 2), false),
            ("this record's first byte", whole.prefix(1), true),
            ("this record's tag", whole.prefix(tagged), true),
            ("this record's first bytes", whole.prefix(whole.count / 2), true),
            ("this record but its last byte", whole.prefix(whole.count - 1), true),
            ("this record's first bytes, then another byte", whole.prefix(whole.count / 2) + Data("x".utf8), false),
            ("this record and old bytes", whole + Data(repeating: 0x41, count: 64), true),
        ]
        func counts(_ content: Data) throws -> Bool {
            try writeInPlace(content, to: lockFile)
            return h.store.sessionEndRecordedInLock() != nil
        }
        for (name, start, counted) in starts {
            XCTAssertEqual(try counts(start), counted, name)
            let p = zip(start, whole).prefix { $0 == $1 }.count
            let ks = Set([0, 1, 2, p - 1, p, p + 1, tagged, whole.count / 3, whole.count / 2, whole.count - 1, start.count, start.count + 1])
                .filter { (0..<whole.count).contains($0) }.sorted()
            // The app's own writer, stopped by a limit of k bytes.
            for k in ks {
                try writeInPlace(start, to: lockFile)
                XCTAssertFalse(try withFileSizeLimit(k) { held.replaceContents(with: whole, at: lockFile.path) }, "\(name): \(k)")
                let left = try XCTUnwrap(lockBytes(), "\(name): \(k)")
                XCTAssertEqual(left, k < p ? start : whole.prefix(k), "\(name): stopped by a limit of \(k) bytes")
                let now = h.store.sessionEndRecordedInLock() != nil
                if left == start {
                    XCTAssertEqual(now, counted, "\(name), unchanged at \(k)")
                } else if left.isEmpty {
                    XCTAssertEqual(p, 0, "\(name): emptied only where nothing was shared")
                    XCTAssertFalse(counted, "\(name): emptied at \(k), so it ended nothing before")
                    XCTAssertFalse(now, "\(name): empty at \(k)")
                } else {
                    XCTAssertEqual(left, whole.prefix(left.count), "\(name): a partial record at \(k)")
                    XCTAssertTrue(now, "\(name): a partial record at \(k) counts")
                }
            }
            // The app stopped after its cut or in its append.
            let appStates = Set([p, p + 1, whole.count / 2, whole.count - 1]).filter { (p..<whole.count).contains($0) }.sorted()
            for j in appStates {
                XCTAssertEqual(try counts(whole.prefix(j)), j > 0, "\(name): the app stopped after \(j) bytes")
                XCTAssertTrue(j > 0 || !counted, name)
            }
            // The agent: content that counts is left, or its first bytes
            // grow; anything else is emptied, then written.
            if counted {
                let agentStates: [Data] = start.count < whole.count
                    ? Set([start.count, start.count + 1, whole.count - 1]).filter { (start.count..<whole.count).contains($0) }.sorted().map { whole.prefix($0) }
                    : [start]
                for state in agentStates {
                    XCTAssertTrue(try counts(state), "\(name): the agent left \(state.count) bytes")
                }
            } else {
                XCTAssertFalse(try counts(Data()), "\(name): the agent's file between its > and its write")
                for j in [1, tagged, whole.count / 2, whole.count - 1] {
                    XCTAssertTrue(try counts(whole.prefix(j)), "\(name): the agent's first \(j) bytes")
                }
            }
            try writeInPlace(start, to: lockFile)
            XCTAssertTrue(h.store.recordSessionEndInLock(lock: held), name)
            XCTAssertEqual(lockBytes(), whole, name)
            XCTAssertEqual(try inode(lockFile), lockInode, name)
        }
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

    /// The app's end stopped partway through its write to the lock file,
    /// with session.json still in place and SleepDisabled still 1: the
    /// record's first bytes, or the whole record with the file's old bytes
    /// after it. A relaunch ends the session instead of holding sleep
    /// again, removes session.json and empties the lock file in place. A
    /// new session then starts, and a crash during it resumes as usual.
    func testARelaunchEndsTheSessionWhoseRecordInTheLockFileWasCutShort() async throws {
        await h.makeManager().reconcile()
        let lockInode = try inode(lockFile)
        for form in ["first bytes", "record and old bytes"] {
            h.clock.advance(60)
            let m = h.makeManager()
            await m.reconcile()
            await m.start(duration: 3600)
            XCTAssertTrue(m.isActive, form)
            let whole = record(of: try Data(contentsOf: h.home.paths.sessionFile))
            try writeInPlace(form == "first bytes" ? whole.prefix(whole.count / 2) : whole + Data(repeating: 0x41, count: 64), to: lockFile)
            XCTAssertTrue(h.guardFake.sleepDisabled, form)

            var before = h.guardFake.calls.count
            let mark = logText().count
            let next = h.makeManager()
            await next.reconcile()
            XCTAssertFalse(next.isActive, "\(form): \(logText(since: mark))")
            XCTAssertFalse(sleepHeldAgain(since: before), "\(form): \(h.guardFake.calls)")
            XCTAssertFalse(h.guardFake.sleepDisabled, form)
            XCTAssertTrue(logText(since: mark).contains("reconcile: session.json holds a session already ended (recorded in .recovery.lock, which holds this session's end record cut short, so it counts as one); restoring, not resuming"), logText(since: mark))
            XCTAssertNil(try h.store.loadSession(), form)
            XCTAssertEqual(lockBytes(), Data(), form)
            XCTAssertEqual(try inode(lockFile), lockInode, form)

            await next.start(duration: 3600)
            XCTAssertTrue(next.isActive, form)
            before = h.guardFake.calls.count
            let resumed = h.makeManager()
            await resumed.reconcile()
            XCTAssertTrue(resumed.isActive, "\(form): \(logText(since: mark))")
            XCTAssertTrue(sleepHeldAgain(since: before), form)
            XCTAssertEqual(lockBytes(), Data(), form)
            _ = await resumed.end(reason: .user)
            XCTAssertNil(try h.store.loadSession(), form)
        }
    }

    /// A session resumed after a crash over a lock file holding bytes that
    /// end nothing (other text, another session's record): the resume
    /// empties the file. Its end then cannot remove session.json and stops
    /// partway through its write to the lock file (a file size limit of k
    /// bytes), which leaves the record's first k bytes: from the first one
    /// they count as the end. So a relaunch from those files with
    /// SleepDisabled still 1 ends the session without holding sleep again,
    /// and so does the agent, the app still running. A write stopped before
    /// its first byte (k = 0) leaves the file empty, which records nothing:
    /// a relaunch resumes the session and the agent keeps it, the open
    /// residual of an end that reached no file (docs/spec.md). For k = 1
    /// ("e", the first byte of every record) the agent's cleanup cannot
    /// empty the file once session.json is gone (its fake rm makes the file
    /// append-only): the "e" stays, the app cannot open the lock file, so
    /// a relaunch and a start change nothing, and once the file is repaired
    /// a start empties it first, so the agent's next run keeps the new
    /// session, a crash resumes it and its end empties the file.
    func testAnEndStoppedPartwayAfterAResumeEndsTheSessionFromItsFirstByte() async throws {
        await h.makeManager().reconcile()
        let lockInode = try inode(lockFile)
        defer { try? FileManager.default.setAttributes([.appendOnly: false], ofItemAtPath: lockFile.path) }
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        let count = record(of: try Data(contentsOf: h.home.paths.sessionFile)).count
        try h.store.deleteSession()
        for (index, k) in [0, 1, 17, count / 2, count - 1].enumerated() {
            h.clock.advance(60)
            let m = h.makeManager()
            await m.reconcile()
            await m.start(duration: 3600)
            XCTAssertTrue(m.isActive, "\(k)")
            try writeInPlace(index % 2 == 0 ? Data("pid 4242\n".utf8) : record(of: Data("an earlier session.json".utf8)), to: lockFile)
            var before = h.guardFake.calls.count
            let resumed = h.makeManager()
            await resumed.reconcile()
            XCTAssertTrue(resumed.isActive, "\(k): \(logText())")
            XCTAssertTrue(sleepHeldAgain(since: before), "\(k)")
            XCTAssertEqual(lockBytes(), Data(), "\(k): the resume empties it")

            let whole = record(of: try Data(contentsOf: h.home.paths.sessionFile))
            XCTAssertEqual(whole.count, count)
            let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
            XCTAssertFalse(try withFileSizeLimit(k) { h.store.recordSessionEndInLock(lock: held) }, "\(k)")
            held.release()
            XCTAssertEqual(lockBytes(), whole.prefix(k), "\(k)")
            XCTAssertEqual(try inode(lockFile), lockInode, "\(k)")
            let crashed = diskCopy()

            XCTAssertTrue(h.guardFake.sleepDisabled, "\(k)")
            before = h.guardFake.calls.count
            var mark = logText().count
            let next = h.makeManager()
            await next.reconcile()
            if k == 0 {
                XCTAssertTrue(next.isActive, "the residual: \(logText(since: mark))")
                XCTAssertTrue(sleepHeldAgain(since: before))
                let run = try await runAgentBesideTheApp()
                XCTAssertEqual(run.status, 0, run.log)
                XCTAssertTrue(agent.calls.contains("pmset -g batt"))
                XCTAssertNotNil(try h.store.loadSession())
                _ = await next.end(reason: .user)
                XCTAssertNil(try h.store.loadSession())
                XCTAssertEqual(lockBytes(), Data())
                continue
            }
            XCTAssertFalse(next.isActive, "\(k): \(logText(since: mark))")
            XCTAssertFalse(sleepHeldAgain(since: before), "\(k): \(h.guardFake.calls)")
            XCTAssertFalse(h.guardFake.sleepDisabled, "\(k)")
            XCTAssertTrue(logText(since: mark).contains("reconcile: session.json holds a session already ended (recorded in .recovery.lock, which holds this session's end record cut short, so it counts as one); restoring, not resuming"), logText(since: mark))
            XCTAssertNil(try h.store.loadSession(), "\(k)")
            XCTAssertEqual(lockBytes(), Data(), "\(k)")
            XCTAssertEqual(try inode(lockFile), lockInode, "\(k)")

            try putBack(crashed)
            h.guardFake.sleepDisabled = true
            let cleanupFails = k == 1
            let caseAgent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent-\(k)", isDirectory: true))
            if cleanupFails { try caseAgent.makeLockAppendOnly(whenRemoving: h.home.paths.sessionFile, lock: lockFile) }
            let alive = AppAliveLock(url: h.home.paths.appAliveFile)
            XCTAssertTrue(try alive.tryAcquire())
            mark = logText().count
            _ = try await caseAgent.run()
            alive.release()
            XCTAssertTrue(logText(since: mark).contains(cutShortLine), "\(k): \(logText(since: mark))")
            XCTAssertFalse(caseAgent.calls.contains("pmset -g batt"), "\(k)")
            XCTAssertTrue(caseAgent.calls.contains(caseAgent.restoreCall), "\(k): \(caseAgent.calls)")
            XCTAssertNil(try h.store.loadSession(), "\(k)")
            XCTAssertEqual(try inode(lockFile), lockInode, "\(k)")
            guard cleanupFails else {
                XCTAssertEqual(lockBytes(), Data(), "\(k)")
                continue
            }

            // The agent's cleanup could not empty the "e".
            XCTAssertEqual(lockBytes(), whole.prefix(1))
            XCTAssertTrue(logText(since: mark).contains("could not empty \(lockFile.path) of content that ends no session"), logText(since: mark))
            let refused = diskCopy()
            h.guardFake.sleepDisabled = false
            before = h.guardFake.calls.count
            mark = logText().count
            let blocked = h.makeManager()
            await blocked.reconcile()
            await blocked.start(duration: 3600)
            XCTAssertFalse(blocked.isActive, logText(since: mark))
            XCTAssertFalse(sleepHeldAgain(since: before))
            XCTAssertTrue(logText(since: mark).contains("start skipped, nothing changed: could not open recovery lock \(lockFile.path)"), logText(since: mark))
            XCTAssertEqual(diskCopy(), refused, "nothing changed")

            try FileManager.default.setAttributes([.appendOnly: false], ofItemAtPath: lockFile.path)
            await blocked.start(duration: 3600)
            XCTAssertTrue(blocked.isActive, logText(since: mark))
            XCTAssertEqual(lockBytes(), Data())
            let kept = try await runAgentBesideTheApp()
            XCTAssertEqual(kept.status, 0, kept.log)
            XCTAssertTrue(agent.calls.contains("pmset -g batt"))
            XCTAssertNotNil(try h.store.loadSession())
            before = h.guardFake.calls.count
            let again = h.makeManager()
            await again.reconcile()
            XCTAssertTrue(again.isActive, logText(since: mark))
            XCTAssertTrue(sleepHeldAgain(since: before))
            _ = await again.end(reason: .user)
            XCTAssertNil(try h.store.loadSession())
            XCTAssertFalse(h.guardFake.sleepDisabled)
            XCTAssertEqual(lockBytes(), Data())
            XCTAssertEqual(try inode(lockFile), lockInode)
        }
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

    /// The agent writes the record but cannot read it back (CAT fails), and
    /// insomnia.log takes none (`refuseLogRecord`): it does not count it as
    /// recorded, logs that nothing took the record and keeps the sleep
    /// entry. Its next run reads the file as unreadable,
    /// which counts as the end. The app reads the whole record and does not
    /// resume the session after a repair.
    func testARecordTheAgentCannotReadBackStillEndsTheSession() async throws {
        _ = try await startThenPinAll()
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        try agent.refuseRecordsAside()
        try agent.failLockReadBack()
        try agent.refuseLogRecord()

        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("the recovery lock file \(lockFile.path), or the log file \(h.home.paths.logFile.path). Sleep is restored anyway"), logText())
        XCTAssertEqual(lockBytes(), record(of: bytes), "written, though not read back")

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        agent.clearCalls()
        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(lockFile.path), which it could not be read, so it may hold this session's end and counts as one)"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"))

        unpinAll()
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLockLine), logText())
    }

    /// The agent finds this session's record cut short in the lock file, as
    /// a run or the app leaves it when stopped partway, while session.json,
    /// an unrelated ended-session.json and state.json are immutable, no
    /// record aside can be made and the restore fails. It counts as the
    /// end, and the agent never empties it:
    /// - its first bytes: the agent appends the rest. The fake rm sets the
    ///   append-only flag on the lock file (chflags uappnd) when the run
    ///   tries to remove session.json, after the run opened its fd 9 there,
    ///   so from then on a write with `>`, which empties the file first,
    ///   fails and only an append goes through.
    /// - the whole record with old bytes after it: the agent leaves it as
    ///   it is and records the end in insomnia.log.
    /// A lock file the agent cannot read (CAT fails on it) counts as the
    /// end too, and the agent leaves it as it is as well. After the repair
    /// the app relaunches with SleepDisabled still 1, ends the session
    /// instead of resuming it, removes session.json and empties the lock
    /// file, which keeps its inode throughout.
    func testTheAgentNeverEmptiesThisSessionsRecordCutShort() async throws {
        await h.makeManager().reconcile()
        let lockInode = try inode(lockFile)
        defer { try? FileManager.default.setAttributes([.appendOnly: false], ofItemAtPath: lockFile.path) }
        for (index, form) in ["first bytes", "record and old bytes", "unreadable"].enumerated() {
            h.clock.advance(60)
            _ = try await startThenPinAll()
            let whole = record(of: try Data(contentsOf: h.home.paths.sessionFile))
            let found = form == "first bytes" ? whole.prefix(whole.count / 2)
                : form == "record and old bytes" ? whole + Data(repeating: 0x41, count: 64)
                : Data("pid 4242\n".utf8)
            try writeInPlace(found, to: lockFile)
            let caseAgent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent-\(index)", isDirectory: true))
            try caseAgent.refuseRecordsAside()
            try caseAgent.failSudo()
            if form == "first bytes" {
                try caseAgent.makeLockAppendOnly(whenRemoving: h.home.paths.sessionFile, lock: lockFile)
            } else if form == "unreadable" {
                try caseAgent.failLockReadBack()
            }

            var mark = logText().count
            let exit = try await caseAgent.run()
            let log = logText(since: mark)
            XCTAssertEqual(exit, 1, "\(form): \(log)")
            XCTAssertFalse(caseAgent.calls.contains("pmset -g batt"), form)
            if form == "first bytes" {
                XCTAssertTrue(log.contains("already ended (recorded in \(lockFile.path), which holds this session's end record cut short, so it counts as one)"), log)
                XCTAssertTrue(log.contains("its end is recorded in the recovery lock file \(lockFile.path) instead"), log)
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: lockFile.path)[.appendOnly] as? Bool, true, "the fake rm ran")
                XCTAssertEqual(lockBytes(), whole)
                try FileManager.default.setAttributes([.appendOnly: false], ofItemAtPath: lockFile.path)
            } else {
                let why = form == "unreadable" ? "which it could not be read, so it may hold this session's end and counts as one"
                    : "which holds this session's end record cut short, so it counts as one"
                XCTAssertTrue(log.contains("already ended (recorded in \(lockFile.path), \(why))"), log)
                XCTAssertTrue(log.contains("its end is recorded in the log file \(h.home.paths.logFile.path) instead"), log)
                XCTAssertEqual(lockBytes(), found, form)
            }
            XCTAssertEqual(try inode(lockFile), lockInode, form)

            unpinAll()
            XCTAssertTrue(h.guardFake.sleepDisabled, "\(form): the failed restore left it at 1")
            let before = h.guardFake.calls.count
            mark = logText().count
            let next = h.makeManager()
            await next.reconcile()
            let recordedIn = form == "first bytes" ? ".recovery.lock"
                : form == "record and old bytes" ? ".recovery.lock, which holds this session's end record cut short, so it counts as one"
                : "insomnia.log"
            XCTAssertFalse(next.isActive, "\(form): \(logText(since: mark))")
            XCTAssertFalse(sleepHeldAgain(since: before), "\(form): \(h.guardFake.calls)")
            XCTAssertTrue(logText(since: mark).contains("reconcile: session.json holds a session already ended (recorded in \(recordedIn)); restoring, not resuming"), logText(since: mark))
            XCTAssertNil(try h.store.loadSession(), form)
            XCTAssertEqual(lockBytes(), Data(), form)
            XCTAssertEqual(try inode(lockFile), lockInode, form)
        }
    }

    // MARK: Reads that fail

    /// A read of the lock file that fails is tried again, up to
    /// `Store.lockReadAttempts` reads in all (`Store.lockReadErrnoForTesting`
    /// with `lockReadFailuresForTesting`). A crash whose lock file holds
    /// content that is no record, read on the last try, resumes, and the
    /// resume empties the file. A file that fails every try still counts as
    /// the end, as it may hold one. A whole record of the session in
    /// insomnia.log is named then instead, since it shows the end that the
    /// file only may hold.
    func testTheAppReadsALockFileAgainBeforeItCountsAsTheEnd() async throws {
        let first = h.makeManager()
        await first.reconcile()
        await first.start(duration: 3600)
        let lockInode = try inode(lockFile)
        let foreign = Data("pid 4242\n".utf8)
        try writeInPlace(foreign, to: lockFile)
        Store.lockReadErrnoForTesting = EIO
        Store.lockReadFailuresForTesting = Store.lockReadAttempts - 1
        var before = h.guardFake.calls.count
        var mark = logText().count
        let resumed = h.makeManager()
        await resumed.reconcile()
        XCTAssertTrue(resumed.isActive, logText(since: mark))
        XCTAssertTrue(sleepHeldAgain(since: before))
        XCTAssertEqual(Store.lockReadFailuresForTesting, 0, "every failed read was tried again")
        XCTAssertFalse(logText(since: mark).contains("recorded in .recovery.lock"), logText(since: mark))
        XCTAssertEqual(lockBytes(), Data(), "the resume empties it")

        try writeInPlace(foreign, to: lockFile)
        Store.lockReadFailuresForTesting = Store.lockReadAttempts
        before = h.guardFake.calls.count
        mark = logText().count
        let ended = h.makeManager()
        await ended.reconcile()
        XCTAssertFalse(ended.isActive, logText(since: mark))
        XCTAssertFalse(sleepHeldAgain(since: before))
        XCTAssertTrue(logText(since: mark).contains("reconcile: session.json holds a session already ended (recorded in .recovery.lock, which it could not be read (Input/output error), so it may hold this session's end and counts as one); restoring, not resuming"), logText(since: mark))
        XCTAssertNil(try h.store.loadSession())

        Store.lockReadErrnoForTesting = nil
        Store.lockReadFailuresForTesting = nil
        let second = h.makeManager()
        await second.reconcile()
        await second.start(duration: 3600)
        XCTAssertTrue(second.isActive, logText())
        let line = try XCTUnwrap(LogEndRecord.line(for: try Data(contentsOf: h.home.paths.sessionFile)))
        let log = try FileHandle(forWritingTo: h.home.paths.logFile)
        try log.seekToEnd()
        try log.write(contentsOf: line + Data("\n".utf8))
        try log.close()
        try writeInPlace(foreign, to: lockFile)
        Store.lockReadErrnoForTesting = EIO
        before = h.guardFake.calls.count
        mark = logText().count
        let named = h.makeManager()
        await named.reconcile()
        Store.lockReadErrnoForTesting = nil
        XCTAssertFalse(named.isActive, logText(since: mark))
        XCTAssertFalse(sleepHeldAgain(since: before))
        XCTAssertTrue(logText(since: mark).contains("reconcile: session.json holds a session already ended (recorded in insomnia.log); restoring, not resuming"), logText(since: mark))
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// The agent reads the lock file again too, LOCK_READ_ATTEMPTS reads
    /// LOCK_READ_RETRY_SECONDS apart (the app's two values), while it cannot
    /// read it (CAT fails, `failLockReadBack(times:)`). Content that is no
    /// record, read on the last try, ends nothing: the agent empties it and
    /// checks the session as usual. When every read fails the file counts
    /// as the end, and a whole record of the session in insomnia.log is
    /// named then instead.
    func testTheAgentReadsALockFileAgainBeforeItCountsAsTheEnd() async throws {
        let text = try String(contentsOf: agent.script, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(text.filter { $0.hasPrefix("LOCK_READ_ATTEMPTS=") }, ["LOCK_READ_ATTEMPTS=\(Store.lockReadAttempts)"])
        XCTAssertEqual(Store.lockReadRetryMicroseconds, 100_000)
        XCTAssertEqual(text.filter { $0.hasPrefix("LOCK_READ_RETRY_SECONDS=") }, ["LOCK_READ_RETRY_SECONDS=0.1"])

        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let lockInode = try inode(lockFile)
        let foreign = Data("pid 4242\n".utf8)
        try writeInPlace(foreign, to: lockFile)
        try agent.failLockReadBack(times: Store.lockReadAttempts - 1)
        var (status, log) = try await runAgentBesideTheApp()
        XCTAssertEqual(status, 0, log)
        XCTAssertEqual(try agent.lockReads(), Store.lockReadAttempts, "the failed reads were tried again")
        XCTAssertNotNil(try h.store.loadSession(), log)
        XCTAssertTrue(agent.calls.contains("pmset -g batt"), log)
        XCTAssertFalse(log.contains("already ended"), log)
        XCTAssertTrue(log.contains("emptying \(lockFile.path): it holds bytes other than one whole end record, which ends no session"), log)
        XCTAssertEqual(lockBytes(), Data())

        let line = try XCTUnwrap(LogEndRecord.line(for: try Data(contentsOf: h.home.paths.sessionFile)))
        let handle = try FileHandle(forWritingTo: h.home.paths.logFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: line + Data("\n".utf8))
        try handle.close()
        try writeInPlace(foreign, to: lockFile)
        let failing = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent-failing", isDirectory: true))
        try failing.failLockReadBack()
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        let mark = logText().count
        status = try await failing.run()
        alive.release()
        log = logText(since: mark)
        XCTAssertEqual(status, 0, log)
        XCTAssertFalse(failing.calls.contains("pmset -g batt"), log)
        XCTAssertTrue(log.contains("already ended (recorded in \(h.home.paths.logFile.path))"), log)
        XCTAssertFalse(log.contains("already ended (recorded in \(lockFile.path)"), log)
        XCTAssertGreaterThanOrEqual(try failing.lockReads(), Store.lockReadAttempts)
        XCTAssertNil(try h.store.loadSession(), log)
        XCTAssertEqual(lockBytes(), Data(), "emptied once session.json is gone, when it ends nothing")
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    // MARK: Other sessions and cleanup

    /// A crash with the lock file empty, with a whole record of an earlier
    /// session's bytes, and with content that is no whole record (another
    /// session's record cut short) resumes: none of them ends this session,
    /// and the resume empties the file. The same content written after the
    /// resume, while the app runs, ends nothing for the agent either: it
    /// empties it and checks the session as usual.
    func testAStaleRecordOrContentThatIsNoRecordEndsNoNewerSession() async throws {
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
        XCTAssertEqual(lockBytes(), Data(), "the resume empties it")
        XCTAssertEqual(try inode(lockFile), lockInode)
        try writeInPlace(stale, to: lockFile)

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertTrue(agent.calls.contains("pmset -g batt"))
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)

        let cut = Data("\(Store.lockEndRecordTag) QUJ".utf8)
        try writeInPlace(cut, to: lockFile)
        before = h.guardFake.calls.count
        let partial = h.makeManager()
        await partial.reconcile()
        XCTAssertTrue(partial.isActive, logText())
        XCTAssertTrue(sleepHeldAgain(since: before))
        XCTAssertFalse(logText().contains("recorded in .recovery.lock"), logText())
        XCTAssertEqual(lockBytes(), Data(), "the resume empties it")
        try writeInPlace(cut, to: lockFile)

        agent.clearCalls()
        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertTrue(agent.calls.contains("pmset -g batt"))
        XCTAssertTrue(logText().contains("emptying \(lockFile.path): it holds bytes other than one whole end record, which ends no session"), logText())
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// A start empties whatever the lock file held before (it ended no
    /// session.json once the new one is written), and a start that fails
    /// puts back the session.json it replaced together with the record of
    /// its end. A lock file over the bound holds no record: it neither
    /// refuses a start over a session.json nor goes back with it. (A lock
    /// file that cannot be read refuses such a start:
    /// testALockFileThatCannotBeReadIsNeverWrittenOverOrReplacedWithASession.)
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
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(logText().contains("start refused, nothing changed"), logText())
        XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), Data(earlier.utf8))
        XCTAssertEqual(lockBytes(), Data(), "content that ends nothing is not put back")

        h.backstop.failArm = false

        try writeInPlace(ended, to: lockFile)
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertNotEqual(try Data(contentsOf: h.home.paths.sessionFile), Data(earlier.utf8))
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }

    /// A start over bytes in the lock file that end no session.json, as a
    /// cleanup that could not empty them leaves them: a stale record's
    /// first byte ("e", the first byte of every record, the new session's
    /// too), another session's record, other text. The start empties them
    /// before it writes session.json, so at each step after that the file
    /// holds nothing: a crash just after session.json is written resumes,
    /// and the agent then checks the session as usual. The same "e" written
    /// once the session runs ends it. A start over an earlier session.json
    /// whose record the lock file holds cut short completes that record (or
    /// keeps it with the old bytes after it) before it writes the new file
    /// and keeps it until its last step, then empties it. A lock file the
    /// start cannot settle (made append-only once the start has read it,
    /// so it is neither cut nor written past its end without O_APPEND)
    /// rolls the start back with nothing changed; once repaired, the start
    /// goes through.
    func testAStartLeavesNothingInTheLockFileThatEndsItsOwnSession() async throws {
        await h.makeManager().reconcile()
        let lockInode = try inode(lockFile)
        var copies: [SessionManager.StartStep: DiskCopy] = [:]
        func manager() async -> SessionManager {
            let m = h.makeManager()
            await m.reconcile()
            m.onStartStepForTesting = { step in copies[step] = self.diskCopy() }
            return m
        }
        func resumesFrom(_ copy: DiskCopy?, _ name: String) async throws {
            try putBack(try XCTUnwrap(copy, name))
            h.guardFake.sleepDisabled = false
            let before = h.guardFake.calls.count
            let mark = logText().count
            let relaunched = h.makeManager()
            await relaunched.reconcile()
            XCTAssertTrue(relaunched.isActive, "\(name): \(logText(since: mark))")
            XCTAssertTrue(sleepHeldAgain(since: before), name)
            XCTAssertEqual(lockBytes(), Data(), name)
            let run = try await runAgentBesideTheApp()
            XCTAssertEqual(run.status, 0, "\(name): \(run.log)")
            XCTAssertTrue(agent.calls.contains("pmset -g batt"), name)
            XCTAssertNotNil(try h.store.loadSession(), name)
            _ = await relaunched.end(reason: .user)
            XCTAssertNil(try h.store.loadSession(), name)
            XCTAssertEqual(lockBytes(), Data(), name)
        }

        let stale: [(name: String, bytes: Data)] = [
            ("a stale record's first byte", Data("e".utf8)),
            ("another session's record", record(of: Data("an earlier session.json".utf8))),
            ("other text", Data("pid 4242\n".utf8)),
        ]
        for (name, bytes) in stale {
            h.clock.advance(60)
            let m = await manager()
            try writeInPlace(bytes, to: lockFile)
            copies = [:]
            await m.start(duration: 3600)
            XCTAssertTrue(m.isActive, name)
            XCTAssertEqual(copies[.sessionWritten]?.lock, Data(), name)
            XCTAssertEqual(copies[.journalWritten]?.lock, Data(), name)
            XCTAssertNotNil(copies[.sessionWritten]?.session, name)
            XCTAssertEqual(lockBytes(), Data(), name)
            XCTAssertEqual(try inode(lockFile), lockInode, name)
            try await resumesFrom(copies[.sessionWritten], name)
        }

        h.clock.advance(60)
        let control = await manager()
        await control.start(duration: 3600)
        try writeInPlace(Data("e".utf8), to: lockFile)
        let ended = try await runAgentBesideTheApp()
        XCTAssertTrue(ended.log.contains(cutShortLine), ended.log)
        XCTAssertNil(try h.store.loadSession(), "the control: the same byte after the start ends it")
        try writeInPlace(Data(), to: lockFile)

        let earlierRecord = record(of: earlier)
        for found in [earlierRecord.prefix(1), earlierRecord.prefix(earlierRecord.count / 2), earlierRecord + Data(repeating: 0x41, count: 64)] {
            let name = "\(found.count) bytes of the earlier session's record"
            h.clock.advance(60)
            let m = await manager()
            try earlier.write(to: h.home.paths.sessionFile)
            try writeInPlace(found, to: lockFile)
            copies = [:]
            await m.start(duration: 3600)
            XCTAssertTrue(m.isActive, name)
            let whole = found.count > earlierRecord.count ? found : earlierRecord
            XCTAssertEqual(copies[.sessionWritten]?.lock, whole, name)
            XCTAssertEqual(copies[.journalWritten]?.lock, whole, name)
            XCTAssertNotEqual(copies[.sessionWritten]?.session, earlier, name)
            XCTAssertEqual(lockBytes(), Data(), name)
            XCTAssertEqual(try inode(lockFile), lockInode, name)
            try await resumesFrom(copies[.sessionWritten], name)
        }

        for previous in [nil, earlier] as [Data?] {
            let found = previous == nil ? Data("e".utf8) : earlierRecord.prefix(earlierRecord.count / 2)
            let name = previous == nil ? "no session.json" : "an earlier session.json"
            h.clock.advance(60)
            let m = await manager()
            if let previous { try previous.write(to: h.home.paths.sessionFile) }
            try writeInPlace(found, to: lockFile)
            let before = diskCopy()
            let calls = h.guardFake.calls.count
            let mark = logText().count
            m.onStartStepForTesting = { [lockFile] step in
                guard step == .lockFileRead else { return }
                try? FileManager.default.setAttributes([.appendOnly: true], ofItemAtPath: lockFile.path)
            }
            await m.start(duration: 3600)
            m.onStartStepForTesting = nil
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: lockFile.path)[.appendOnly] as? Bool, true, name)
            try FileManager.default.setAttributes([.appendOnly: false], ofItemAtPath: lockFile.path)
            XCTAssertFalse(m.isActive, name)
            XCTAssertTrue(logText(since: mark).contains("could not write session: \(lockFile.path) holds bytes that may record a session's end and could not be rewritten"), logText(since: mark))
            XCTAssertEqual(diskCopy(), before, "\(name): nothing changed")
            XCTAssertFalse(sleepHeldAgain(since: calls), name)
            await m.start(duration: 3600)
            XCTAssertTrue(m.isActive, name)
            XCTAssertEqual(lockBytes(), Data(), name)
            _ = await m.end(reason: .user)
            XCTAssertNil(try h.store.loadSession(), name)
        }
    }

    /// A start that fails puts back session.json, state.json and the lock
    /// file exactly as they were, whatever the lock file held. With no
    /// session.json: nothing, or bytes that end nothing ("e", other text,
    /// another session's record), which go back once the new session.json
    /// is gone. With an earlier session.json: its record whole, cut short
    /// or with old bytes after it, which goes back before that file, and
    /// other text, which goes back after it. The start fails when the agent
    /// cannot be armed, or at its last step, when the lock file cannot be
    /// emptied of the earlier session's record (append-only from the
    /// journal write on). Neither touches SleepDisabled. At the last step
    /// the file holds that record whole and still cannot be cut, so its
    /// first bytes cannot go back: the whole record stays, which counts as
    /// the earlier session's end as its first bytes did.
    func testAFailedStartPutsBackSessionJournalAndLockFileExactly() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        _ = await m.end(reason: .user)
        let lockInode = try inode(lockFile)
        let ended = record(of: earlier)
        let other = Data("pid 4242\n".utf8)
        let cases: [(name: String, previous: Data?, lock: Data)] = [
            ("no session.json, nothing", nil, Data()),
            ("no session.json, a stale record's first byte", nil, Data("e".utf8)),
            ("no session.json, other text", nil, other),
            ("no session.json, another session's record", nil, ended),
            ("an earlier session.json, nothing", earlier, Data()),
            ("its record", earlier, ended),
            ("its record's first byte", earlier, ended.prefix(1)),
            ("its record's first bytes", earlier, ended.prefix(ended.count / 2)),
            ("its record and old bytes", earlier, ended + Data(repeating: 0x41, count: 64)),
            ("an earlier session.json, other text", earlier, other),
        ]
        for (name, previous, lock) in cases {
            for failure in ["arm", "last step"] {
                let label = "\(name), \(failure)"
                h.clock.advance(60)
                if let previous { try previous.write(to: h.home.paths.sessionFile) }
                try writeInPlace(lock, to: lockFile)
                let before = diskCopy()
                let calls = h.guardFake.calls.count
                let mark = logText().count
                if failure == "arm" {
                    h.backstop.failArm = true
                } else {
                    m.onStartStepForTesting = { [lockFile] step in
                        guard step == .journalWritten else { return }
                        try? FileManager.default.setAttributes([.appendOnly: true], ofItemAtPath: lockFile.path)
                    }
                }
                await m.start(duration: 3600)
                h.backstop.failArm = false
                m.onStartStepForTesting = nil
                try FileManager.default.setAttributes([.appendOnly: false], ofItemAtPath: lockFile.path)
                let counted = previous.map { Store.lockContents(lock, endSessionWithBytes: $0) } ?? false
                guard failure == "arm" || counted else {
                    XCTAssertTrue(m.isActive, "\(label): \(logText(since: mark))")
                    XCTAssertEqual(lockBytes(), Data(), label)
                    _ = await m.end(reason: .user)
                    continue
                }
                XCTAssertFalse(m.isActive, label)
                XCTAssertFalse(sleepHeldAgain(since: calls), label)
                let cutShort = failure == "last step" && lock.count < ended.count
                XCTAssertEqual(diskCopy(), DiskCopy(session: before.session, state: before.state, lock: cutShort ? ended : before.lock), "\(label): \(logText(since: mark))")
                XCTAssertEqual(try inode(lockFile), lockInode, label)
                if cutShort {
                    XCTAssertTrue(logText(since: mark).contains("could not restore \(lockFile.path) after a failed start"), logText(since: mark))
                }
                if previous != nil { try FileManager.default.removeItem(at: h.home.paths.sessionFile) }
            }
        }
    }

    /// A lock file that cannot be read (a read error once it is open, set
    /// through `Store.lockReadErrnoForTesting`; the app's own lock
    /// descriptor still works) may hold the end of the session.json in
    /// place. A start over that session.json is refused with nothing
    /// changed. With no session.json the file ends nothing, and a start
    /// empties it. An end that can neither remove session.json nor record
    /// it anywhere before the lock file never writes over it: it records
    /// the end in insomnia.log.
    func testALockFileThatCannotBeReadIsNeverWrittenOverOrReplacedWithASession() async throws {
        let m = h.makeManager()
        await m.reconcile()
        let lockInode = try inode(lockFile)
        try earlier.write(to: h.home.paths.sessionFile)
        let found = record(of: earlier).prefix(20)
        try writeInPlace(found, to: lockFile)
        Store.lockReadErrnoForTesting = EIO
        let before = diskCopy()
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertTrue(logText().contains("start refused, nothing changed: \(lockFile.path) could not be read whole, and it may record the end of the session.json in place"), logText())
        Store.lockReadErrnoForTesting = nil
        XCTAssertEqual(diskCopy(), before)

        try FileManager.default.removeItem(at: h.home.paths.sessionFile)
        Store.lockReadErrnoForTesting = EIO
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive, logText())
        XCTAssertEqual(lockBytes(), Data())
        _ = await m.end(reason: .user)
        Store.lockReadErrnoForTesting = nil
        XCTAssertNil(try h.store.loadSession())

        let running = try await startThenPinAll()
        let whole = record(of: try Data(contentsOf: h.home.paths.sessionFile))
        let held = whole.prefix(whole.count / 2)
        try writeInPlace(held, to: lockFile)
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        try TestACL.denyNewFiles(in: h.home.paths.logs)
        Store.lockReadErrnoForTesting = EIO
        let outcome = await running.end(reason: .user)
        Store.lockReadErrnoForTesting = nil
        XCTAssertEqual(outcome, .sessionRetained)
        XCTAssertEqual(lockBytes(), held, "never written over")
        XCTAssertEqual(try inode(lockFile), lockInode)
        XCTAssertTrue(logText().contains("; its end is recorded in the log file insomnia.log"), logText())
        XCTAssertNotNil(h.store.sessionEndRecordedInLog())
    }

    /// session.json removed outside the lock cannot empty the record, whole
    /// or cut short: it is logged and stays, ending nothing, and the
    /// agent's next run empties it in place. Content that is no record
    /// stays while session.json cannot be read.
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

        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let cut = ended.prefix(ended.count / 2)
        try writeInPlace(cut, to: lockFile)
        XCTAssertNotNil(h.store.sessionEndRecordedInLock())
        try h.store.deleteSession()
        XCTAssertEqual(lockBytes(), cut)
        XCTAssertNil(h.store.sessionEndRecordedInLock(), "nothing to end without session.json")
        agent.clearCalls()
        try await runAgent(expecting: 0)
        XCTAssertTrue(logText().contains("emptying \(lockFile.path): it holds bytes other than one whole end record, which ends no session"), logText())
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)

        // While session.json cannot be read, nothing shows that such content
        // ends nothing, so the run keeps it. That run removes session.json,
        // whose end time is unknown, and the next run empties the content.
        h.clock.advance(60)
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let unread = record(of: try Data(contentsOf: h.home.paths.sessionFile)).prefix(40)
        try writeInPlace(unread, to: lockFile)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: h.home.paths.sessionFile.path)
        var mark = logText().count
        agent.clearCalls()
        try await runAgent(expecting: 0)
        XCTAssertTrue(logText(since: mark).contains("session.json cannot be read"), logText(since: mark))
        XCTAssertFalse(logText(since: mark).contains("emptying \(lockFile.path)"), logText(since: mark))
        XCTAssertEqual(lockBytes(), unread)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.sessionFile.path), logText(since: mark))
        mark = logText().count
        try await runAgent(expecting: 0)
        XCTAssertTrue(logText(since: mark).contains("emptying \(lockFile.path): it holds bytes other than one whole end record, which ends no session"), logText(since: mark))
        XCTAssertEqual(lockBytes(), Data())
        XCTAssertEqual(try inode(lockFile), lockInode)
    }
}
