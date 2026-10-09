import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// The place after the recovery lock file: one line appended to
/// insomnia.log (`LogEndRecord`), for an end that cannot remove
/// session.json while ended-session.json, the journal, both folders of
/// records aside and the lock file all refuse the record. The line holds
/// session.json's exact bytes and their count, and counts only as a whole
/// line equal to the one built from session.json as it is now, in
/// insomnia.log or insomnia.log.1. The app rotates the log only under the
/// recovery lock and copies a record still in force into the file it
/// renames. The agent is the real backstop.sh with its tools patched to
/// fakes (PatchedBackstop). The app's lock file refuses its record through
/// `Store.lockRecordWriteLimitForTesting`, as the agent's does through
/// `refuseLockRecord`.
@MainActor
final class LogEndRecordTests: XCTestCase {
    var h: Harness!
    var agent: PatchedBackstop!

    override func setUp() async throws {
        h = Harness()
        try h.home.paths.createDirectories()
        agent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent", isDirectory: true))
    }

    override func tearDown() async throws {
        Store.lockRecordWriteLimitForTesting = nil
        try? TestACL.removeAll(h.home.paths.appSupport)
        try? TestACL.removeAll(h.home.paths.logs)
        unpinAll()
        for url in [logFile, rotatedLog, h.home.paths.sessionFile] {
            try? setImmutable(url, false)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        h.home.destroy()
    }

    private var logFile: URL { h.home.paths.logFile }
    private var rotatedLog: URL { OwnerOnly.rotated(h.home.paths.logFile) }
    private var lockFile: URL { h.home.paths.recoveryLock }
    private let unrelatedRecord = Data("an end record of some other session.json".utf8)

    /// The record line of `data`, without its newline.
    private func line(of data: Data) -> String {
        "\(LogEndRecord.tag) \(data.count) \(data.base64EncodedString())"
    }

    private func sessionBytes() throws -> Data { try Data(contentsOf: h.home.paths.sessionFile) }

    private func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func logText() -> String { text(logFile) }

    /// How many lines of `url` equal `line`.
    private func count(_ line: String, in url: URL) -> Int {
        text(url).components(separatedBy: "\n").filter { $0 == line }.count
    }

    private func size(_ url: URL) throws -> UInt64 {
        try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value)
    }

    /// One line longer than the log's cap, so the next line written under
    /// the recovery lock rotates it.
    nonisolated static func appendFiller(to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(repeating: UInt8(ascii: "a"), count: Int(OwnerOnly.maxLogBytes)) + Data("\n".utf8))
    }

    private func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path), "the start wrote the log")
        try unrelatedRecord.write(to: h.home.paths.endedSessionFile)
        for file in pinnable { try setImmutable(file, true) }
        return m
    }

    private func unpinAll() {
        for file in pinnable { try? setImmutable(file, false) }
    }

    /// The app can record the end nowhere but the log: neither folder
    /// takes a new file and the lock file takes no record.
    private func refuseAllButTheLogForTheApp() throws {
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        try TestACL.denyNewFiles(in: h.home.paths.logs)
        Store.lockRecordWriteLimitForTesting = 0
    }

    private func repairAll() throws {
        try TestACL.removeAll(h.home.paths.appSupport)
        try TestACL.removeAll(h.home.paths.logs)
        Store.lockRecordWriteLimitForTesting = nil
        unpinAll()
    }

    private func endedInLogLine(_ name: String = "insomnia.log") -> String {
        "reconcile: session.json holds a session already ended (recorded in \(name)); restoring, not resuming"
    }

    // MARK: Reading

    /// The app's reader (Store.sessionEndRecordedInLog) and the agent's
    /// (end_recorded_in_log) on the same logs, one home per case: whether
    /// they count the session in session.json as ended. Only a whole line
    /// equal to the record of exactly these bytes counts, in a regular file
    /// (not a symlink) that can be read. The app is alive and the machine
    /// within every floor, so the agent ends only a session it finds
    /// recorded as ended. The homes are built one at a time and the agents
    /// run up to 8 at once (SeparateRun).
    func testTheAppAndTheAgentReadEveryShapeOfLineAlike() async throws {
        enum Shape { case file, symlink, directory, writeOnly }
        /// The record with its byte count one higher.
        func recount(_ l: String) -> String {
            var parts = l.components(separatedBy: " ")
            parts[1] = String(Int(parts[1])! + 1)
            return parts.joined(separator: " ")
        }
        let tag = LogEndRecord.tag
        let cases: [(name: String, ends: Bool, shape: Shape, log: (String, String) -> String, rotated: ((String, String) -> String)?)] = [
            ("no record", false, .file, { _, _ in "2027-01-15T08:00:00Z [info] insomnia: hello\n" }, nil),
            ("this session", true, .file, { l, _ in "a line\n\(l)\nanother line\n" }, nil),
            ("this session, last line without its newline", true, .file, { l, _ in "a line\n\(l)" }, nil),
            ("this session twice", true, .file, { l, _ in "\(l)\n\(l)\n" }, nil),
            ("this session after a line too long to be a record", true, .file, { l, _ in String(repeating: "a", count: LogEndRecord.maxLineBytes + 10) + "\n\(l)\n" }, nil),
            ("this session in insomnia.log.1", true, .file, { _, _ in "a line\n" }, { l, _ in "\(l)\n" }),
            ("a NUL byte on another line", true, .file, { l, _ in "a\u{0}b\n\(l)\n" }, nil),
            ("another session", false, .file, { _, o in "\(o)\n" }, { _, o in "\(o)\n" }),
            ("another byte count", false, .file, { l, _ in recount(l) + "\n" }, nil),
            ("these bytes under the lock file's tag", false, .file, { l, _ in "ended-session-v1 \(l.components(separatedBy: " ")[2])\n" }, nil),
            ("cut short", false, .file, { l, _ in String(l.dropLast(4)) + "\n" }, nil),
            ("cut short at the end of the file", false, .file, { l, _ in String(l.dropLast(1)) }, nil),
            ("text before it on its line", false, .file, { l, _ in "2027-01-15T08:00:00Z [info] insomnia: \(l)\n" }, nil),
            ("broken by another line", false, .file, { l, _ in String(l.prefix(40)) + "\n2027-01-15T08:00:00Z [info] insomnia: x\n" + String(l.dropFirst(40)) + "\n" }, nil),
            ("carriage return", false, .file, { l, _ in "\(l)\r\n" }, nil),
            ("trailing space", false, .file, { l, _ in "\(l) \n" }, nil),
            ("two spaces after the tag", false, .file, { l, _ in l.replacingOccurrences(of: "\(tag) ", with: "\(tag)  ") + "\n" }, nil),
            ("insomnia.log a symlink to a file holding it", false, .symlink, { l, _ in "\(l)\n" }, nil),
            ("insomnia.log a directory, insomnia.log.1 holding it", true, .directory, { _, _ in "" }, { l, _ in "\(l)\n" }),
            ("insomnia.log unreadable, insomnia.log.1 holding it", true, .writeOnly, { _, _ in "a line\n" }, { l, _ in "\(l)\n" }),
            ("insomnia.log unreadable and holding it", false, .writeOnly, { l, _ in "\(l)\n" }, nil),
        ]
        let config = try Store.makeEncoder().encode(Config())
        let other = line(of: Data("an earlier session.json".utf8))
        var runs: [SeparateRun] = []
        for (i, c) in cases.enumerated() {
            let run = try SeparateRun(in: h, name: "\(i)", config: config, battery: 25)
            runs.append(run)
            let paths = run.paths
            let l = line(of: try Data(contentsOf: paths.sessionFile))
            let log = Data(c.log(l, other).utf8)
            switch c.shape {
            case .file, .writeOnly:
                try log.write(to: paths.logFile)
            case .symlink:
                let target = paths.logs.appendingPathComponent("elsewhere.log")
                try log.write(to: target)
                try FileManager.default.createSymbolicLink(at: paths.logFile, withDestinationURL: target)
            case .directory:
                try FileManager.default.createDirectory(at: paths.logFile, withIntermediateDirectories: false)
            }
            if let rotated = c.rotated { try Data(rotated(l, other).utf8).write(to: OwnerOnly.rotated(paths.logFile)) }
            if c.shape == .writeOnly { try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: paths.logFile.path) }
            XCTAssertEqual(Store(paths: paths).sessionEndRecordedInLog() != nil, c.ends, "the app: \(c.name)")
        }

        let results = try await SeparateRun.runAll(runs)

        for (i, c) in cases.enumerated() {
            let paths = runs[i].paths
            if c.shape == .writeOnly { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.logFile.path) }
            let log = try c.shape == .file ? runs[i].log : ""
            XCTAssertEqual(results[i].status, 0, "\(c.name): \(log)")
            XCTAssertEqual(results[i].ended, c.ends, "the agent: \(c.name): \(log)")
            XCTAssertEqual(runs[i].agent.calls.contains("pmset -g batt"), !c.ends, "\(c.name): checked only when not ended")
            if c.shape == .file {
                XCTAssertEqual(log.contains("already ended (recorded in \(paths.logFile.path)"), c.ends, "\(c.name): \(log)")
            }
        }
    }

    // MARK: Writing

    /// The Store appends the record only through the recovery lock this
    /// process holds on this home's lock file, never through a symlink,
    /// never into a log it would have to create, and counts it only once it
    /// reads back whole. A record already there is used again. A log that
    /// takes no write records nothing; one that cannot be read back gets
    /// the line, which counts once the log can be read.
    func testTheStoreAppendsTheRecordOnlyUnderTheHeldLockAndCountsItOnlyOnceItReadsBack() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let bytes = try sessionBytes()
        let record = line(of: bytes)
        XCTAssertEqual(LogEndRecord.line(for: bytes), Data(record.utf8))
        try Data("an earlier line\n".utf8).write(to: logFile)
        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }

        XCTAssertFalse(h.store.recordSessionEndInLog(lock: nil))
        let elsewhere = try XCTUnwrap(try RecoveryLock(url: h.home.root.appendingPathComponent("other.lock")).tryAcquire())
        XCTAssertFalse(h.store.recordSessionEndInLog(lock: elsewhere), "a lock on another file does not count")
        elsewhere.release()
        XCTAssertFalse(logText().contains(LogEndRecord.tag), "nothing is written without the lock")

        XCTAssertTrue(h.store.recordSessionEndInLog(lock: held))
        XCTAssertTrue(logText().hasPrefix("an earlier line\n"), logText())
        XCTAssertEqual(count(record, in: logFile), 1)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")
        XCTAssertTrue(h.store.recordSessionEndInLog(lock: held), "a record already there is used again")
        XCTAssertEqual(count(record, in: logFile), 1)

        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(1200)))
        let newer = line(of: try sessionBytes())
        XCTAssertNil(h.store.sessionEndRecordedInLog(), "a record of other bytes ends nothing")

        try setImmutable(logFile, true)
        XCTAssertFalse(h.store.recordSessionEndInLog(lock: held), "a log that takes no write")
        try setImmutable(logFile, false)
        XCTAssertEqual(count(newer, in: logFile), 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: logFile.path)
        XCTAssertFalse(h.store.recordSessionEndInLog(lock: held), "a log that cannot be read back")
        XCTAssertNil(h.store.sessionEndRecordedInLog())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        XCTAssertEqual(count(newer, in: logFile), 1, "written, though not read back")
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log", "whole, so it counts once it can be read")

        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(1800)))
        try FileManager.default.removeItem(at: logFile)
        XCTAssertFalse(h.store.recordSessionEndInLog(lock: held))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path), "no log is created for it")

        let target = h.home.root.appendingPathComponent("elsewhere.log")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: logFile, withDestinationURL: target)
        XCTAssertFalse(h.store.recordSessionEndInLog(lock: held))
        XCTAssertEqual(try Data(contentsOf: target), Data(), "nothing written through the symlink")
        try Data((line(of: try sessionBytes()) + "\n").utf8).write(to: target)
        XCTAssertNil(h.store.sessionEndRecordedInLog(), "nothing read through the symlink")
        try FileManager.default.removeItem(at: logFile)
        try Data().write(to: logFile)

        let big = Data(repeating: 0x20, count: LogEndRecord.maxSessionBytes + 1)
        XCTAssertNil(LogEndRecord.line(for: big))
        XCTAssertNil(LogEndRecord.line(for: Data()))
        XCTAssertNotNil(LogEndRecord.line(for: Data(repeating: 0x20, count: LogEndRecord.maxSessionBytes)))
        XCTAssertEqual(LogEndRecord.line(for: Data(repeating: 0x20, count: LogEndRecord.maxSessionBytes))?.count, LogEndRecord.maxLineBytes)
        try big.write(to: h.home.paths.sessionFile)
        XCTAssertFalse(h.store.recordSessionEndInLog(lock: held), "a session.json past the largest a record copies")

        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(2400)))
        held.release()
        XCTAssertFalse(h.store.recordSessionEndInLog(lock: held), "a released handle writes nothing")
        XCTAssertEqual(try Data(contentsOf: logFile), Data())
    }

    // MARK: Rotation

    /// Without the recovery lock the log is not rotated: the line goes to
    /// the file as it is. Under the lock it is, and each rotation copies a
    /// record of session.json's bytes from the old insomnia.log.1 into the
    /// file it renames, so three rotations in a row keep it. Once
    /// session.json holds other bytes, or is gone, the record ends nothing
    /// and a rotation drops it.
    func testRotationsUnderTheLockCarryARecordForwardWhileItsSessionJSONIsThere() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let record = line(of: try sessionBytes())
        try Data("\(record)\n".utf8).write(to: logFile)
        Self.appendFiller(to: logFile)

        Log.append(level: "info", "no lock held", paths: h.home.paths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotatedLog.path), "not rotated without the lock")
        XCTAssertTrue(logText().hasSuffix("insomnia: no lock held\n"))
        XCTAssertGreaterThan(try size(logFile), OwnerOnly.maxLogBytes)

        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }
        func rotate(_ text: String) {
            RecoveryLock.$held.withValue(held) { Log.append(level: "info", text, paths: h.home.paths) }
        }
        rotate("first rotation")
        XCTAssertEqual(count(record, in: rotatedLog), 1)
        XCTAssertEqual(count(record, in: logFile), 0)
        XCTAssertTrue(logText().hasSuffix("insomnia: first rotation\n"))
        XCTAssertLessThan(try size(logFile), 200)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log.1")

        for n in ["second", "third"] {
            Self.appendFiller(to: logFile)
            rotate("\(n) rotation")
            XCTAssertEqual(count(record, in: rotatedLog), 1, "copied forward before the old .1 went: \(n)")
            XCTAssertEqual(count(record, in: logFile), 0, n)
            XCTAssertTrue(logText().hasSuffix("insomnia: \(n) rotation\n"), n)
            XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log.1", n)
        }

        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(1200)))
        Self.appendFiller(to: logFile)
        rotate("other bytes")
        XCTAssertEqual(count(record, in: rotatedLog) + count(record, in: logFile), 0, "a record of other bytes is dropped")

        let newer = line(of: try sessionBytes())
        try append("\(newer)\n", to: logFile)
        Self.appendFiller(to: logFile)
        rotate("into .1")
        XCTAssertEqual(count(newer, in: rotatedLog), 1)
        try FileManager.default.removeItem(at: h.home.paths.sessionFile)
        Self.appendFiller(to: logFile)
        rotate("session.json gone")
        XCTAssertEqual(count(newer, in: rotatedLog) + count(newer, in: logFile), 0, "dropped once session.json is gone")
    }

    /// A rotation that cannot tell whether the old insomnia.log.1 holds a
    /// record still in force waits: .1 cannot be read, or session.json
    /// cannot be read and .1 holds any record. The line goes to the file
    /// as it is, and the next line under the lock rotates once both can be
    /// read, copying the record forward.
    func testARotationWaitsWhileItCannotTellWhetherDotOneHoldsARecordInForce() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let record = line(of: try sessionBytes())
        try Data("\(record)\n".utf8).write(to: rotatedLog)
        try Data("a line\n".utf8).write(to: logFile)
        Self.appendFiller(to: logFile)
        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }
        func rotate(_ text: String) {
            RecoveryLock.$held.withValue(held) { Log.append(level: "info", text, paths: h.home.paths) }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: rotatedLog.path)
        rotate(".1 unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotatedLog.path)
        XCTAssertTrue(logText().hasSuffix("insomnia: .1 unreadable\n"), "the line goes to the file as it is")
        XCTAssertGreaterThan(try size(logFile), OwnerOnly.maxLogBytes)
        XCTAssertEqual(text(rotatedLog), "\(record)\n", ".1 is kept")

        rotate("readable again")
        XCTAssertEqual(count(record, in: rotatedLog), 1, "copied forward")
        XCTAssertTrue(logText().hasSuffix("insomnia: readable again\n"))
        XCTAssertLessThan(try size(logFile), 200)

        Self.appendFiller(to: logFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: h.home.paths.sessionFile.path)
        rotate("session.json unreadable")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: h.home.paths.sessionFile.path)
        XCTAssertGreaterThan(try size(logFile), OwnerOnly.maxLogBytes, "kept while .1 holds a record")
        XCTAssertEqual(count(record, in: rotatedLog), 1)

        rotate("session.json readable again")
        XCTAssertEqual(count(record, in: rotatedLog), 1)
        XCTAssertLessThan(try size(logFile), 200)
    }

    /// The agent ends a session whose end it can record only in the log
    /// while this process writes lines beside it and, now and then, takes
    /// the recovery lock and rotates a log past the cap. The record reads
    /// back whole, and two more rotations after the run keep it while
    /// session.json is there.
    func testTheAgentsRecordReadsBackWholeBesideOtherLinesAndLockedRotations() async throws {
        _ = try await startThenPinAll()
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()
        let record = line(of: try sessionBytes())
        let beside = BesideTheAgent(paths: h.home.paths)
        beside.start()

        let exit = try await agent.run()
        let (lines, rotations) = beside.stop()

        XCTAssertEqual(exit, 1, logText())
        XCTAssertGreaterThan(lines, 0)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(count(record, in: logFile) + count(record, in: rotatedLog), 1, "rotations \(rotations)")
        XCTAssertNotNil(h.store.sessionEndRecordedInLog())
        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        for n in 1...2 {
            Self.appendFiller(to: logFile)
            RecoveryLock.$held.withValue(held) { Log.append(level: "info", "rotation \(n) after the run", paths: h.home.paths) }
        }
        held.release()
        XCTAssertEqual(count(record, in: rotatedLog), 1)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log.1")

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        agent.clearCalls()
        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(rotatedLog.path))"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"))
    }

    // MARK: The app's end

    /// The app ends a session whose end it can record only in the log
    /// (every file pinned, neither folder takes a new file, the lock file
    /// takes no record): the record goes in before anything is undone.
    /// After every file, both folders and the lock file are repaired, a
    /// relaunch with SleepDisabled still 1 ends it instead of holding sleep
    /// again, and removes session.json.
    func testAnAppEndRecordedOnlyInTheLogIsNotResumedAfterAFullRepair() async throws {
        let m = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try refuseAllButTheLogForTheApp()

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .sessionRetained)
        XCTAssertEqual(count(record, in: logFile), 1)
        XCTAssertEqual(try Data(contentsOf: lockFile), Data(), "no record in the lock file")
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        XCTAssertTrue(logText().contains("could not remove session.json: "), logText())
        XCTAssertTrue(logText().contains("; its end is recorded in the log file insomnia.log"), logText())
        XCTAssertTrue(h.notifier.posts.last?.body.contains("its end is recorded, so a relaunch will not resume it") == true, "\(h.notifier.posts)")

        try repairAll()
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
        XCTAssertTrue(logText().contains(endedInLogLine()), logText())
        XCTAssertNil(try h.store.loadSession())

        let again = h.makeManager()
        await again.reconcile()
        XCTAssertFalse(again.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
    }

    /// Settings' change of the end floor that config.json refuses, with a
    /// journal record that cannot be put back either, ends the session on
    /// disk under the lock it holds (`updateConfig`). Here the end can be
    /// recorded only in the log. A relaunch from the files as the refused
    /// change left them does not hold sleep again; after the repair the
    /// end in process, pending until then, finishes on its retry and
    /// nothing holds sleep again either.
    func testARefusedSettingsChangeThatCannotBePutBackRecordsTheEndInTheLog() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let holds = h.guardFake.calls.filter { $0 == "disablesleep 1" }.count
        let record = line(of: try sessionBytes())
        try unrelatedRecord.write(to: h.home.paths.endedSessionFile)
        try setImmutable(h.home.paths.sessionFile, true)
        try setImmutable(h.home.paths.endedSessionFile, true)
        try setImmutable(h.home.paths.configFile, true)
        defer { try? setImmutable(h.home.paths.configFile, false) }
        Store.lockRecordWriteLimitForTesting = 0
        // The journal takes the new cutoffs first; then it, both folders
        // and the lock file refuse everything.
        let paths = h.home.paths
        m.beforeRecordedCutoffsPutBack = {
            do {
                try setImmutable(paths.stateFile, true)
                try TestACL.denyNewFiles(in: paths.appSupport)
                try TestACL.denyNewFiles(in: paths.logs)
            } catch { XCTFail("not refused: \(error)") }
        }

        XCTAssertFalse(m.updateConfig { $0.setEndFloor(m.config.agentCutoffs.endFloor == 30 ? 10 : 30) })

        // Nothing has awaited yet: the disk is what the refused change left.
        XCTAssertEqual(count(record, in: logFile), 1)
        let error = try XCTUnwrap(m.configSaveError)
        XCTAssertTrue(error.contains("so Insomnia ended the session: session.json could not be removed ("), error)
        XCTAssertTrue(error.contains("its end is recorded, so a relaunch will not resume it."), error)
        let copy = Harness()
        setenv(Paths.environmentKey, h.home.root.path, 1)
        defer { try? FileManager.default.removeItem(at: copy.home.root) }
        try copy.home.paths.createDirectories()
        for file in [h.home.paths.sessionFile, h.home.paths.stateFile, h.home.paths.configFile, h.home.paths.endedSessionFile, logFile] {
            try Data(contentsOf: file).write(to: file == logFile ? copy.home.paths.logFile : copy.home.paths.appSupport.appendingPathComponent(file.lastPathComponent))
        }
        copy.guardFake.sleepDisabled = true
        let relaunch = copy.makeManager()
        await relaunch.reconcile()
        XCTAssertFalse(relaunch.isActive)
        XCTAssertFalse(copy.guardFake.calls.contains("disablesleep 1"), "\(copy.guardFake.calls)")
        XCTAssertTrue(copy.guardFake.calls.contains("disablesleep 0"), "\(copy.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLogLine()), logText())

        try repairAll()
        try setImmutable(paths.stateFile, false)
        try setImmutable(h.home.paths.configFile, false)
        m.beforeRecordedCutoffsPutBack = nil
        // The end in process ran while the files refused it, so it is
        // pending; this is its retry, as the retry timer runs it.
        XCTAssertEqual(m.pendingEnd, .cutoffsNotRecorded)
        _ = await m.end(reason: .cutoffsNotRecorded)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(m.pendingEnd, logText())
        let again = h.makeManager()
        await again.reconcile()
        XCTAssertFalse(again.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, holds, "nothing held sleep again")
    }

    // MARK: The agent's end

    /// The agent ends a session whose end it can record only in the log
    /// (every file pinned, MKTEMP fails, the lock file takes no record),
    /// and the restore fails, so SleepDisabled stays 1. Its next run reads
    /// the record and does not check the session again. After every file
    /// is repaired, the app launches first with SleepDisabled still 1: it
    /// ends the session instead of holding sleep again and removes
    /// session.json.
    func testAnAgentEndRecordedOnlyInTheLogIsNotRevivedAfterAFailedRestoreAndAFullRepair() async throws {
        _ = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try agent.failSudo()
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()

        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(count(record, in: logFile), 1)
        XCTAssertEqual(try Data(contentsOf: lockFile), Data())
        XCTAssertTrue(logText().contains("its end is recorded in the log file \(logFile.path) instead"), logText())
        XCTAssertTrue(h.guardFake.sleepDisabled, "the failed restore left it at 1")

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        agent.clearCalls()
        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(logFile.path))"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"))
        XCTAssertEqual(count(record, in: logFile), 1, "used again, not appended again")

        unpinAll()
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, logText())
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLogLine()), logText())
        XCTAssertNil(try h.store.loadSession())
        agent.clearCalls()
        try await runAgent(expecting: 0)
        XCTAssertFalse(agent.calls.contains(agent.restoreCall), "nothing left to restore: \(agent.calls)")
    }

    /// The app still running when the agent ends its session that way: the
    /// tick, which read the logs before the run and found nothing, reads
    /// them again once they changed and ends the session too.
    func testTheTickEndsASessionTheAgentEndedInTheLog() async throws {
        let m = try await startThenPinAll()
        await m.noticeAgentEnd()
        XCTAssertTrue(m.isActive)
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()
        try await runAgent(expecting: 1)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")

        let before = h.guardFake.calls.count
        await m.noticeAgentEnd()

        XCTAssertFalse(m.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("is recorded as ended in insomnia.log: the recovery agent ended it"), logText())
    }

    /// The agent appends the record but cannot read it back (GREP finds no
    /// record line): it does not count it, keeps the sleep entry and says
    /// the end is recorded nowhere. The line is whole, so the app reads it
    /// and does not resume the session after the repair.
    func testARecordTheAgentCannotReadBackDoesNotCountForTheAgent() async throws {
        _ = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()
        try agent.failLogReadBack()

        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall))
        XCTAssertEqual(count(record, in: logFile), 1, "written, though not read back")
        XCTAssertTrue(logText().contains("the recovery lock file \(lockFile.path), or the log file \(logFile.path). Sleep is restored anyway"), logText())
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)

        unpinAll()
        h.guardFake.sleepDisabled = true
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLogLine()), logText())
    }

    // MARK: Lines cut short

    /// A record whose newline alone is missing counts, and the app's
    /// ordinary lines (`Log.append`) put a newline first, so it still
    /// counts after them; a log that ends in a newline gets no blank line.
    /// A record of other bytes at the end of the file ends nothing, before
    /// or after. The record writer separates a line cut short the same
    /// way, whether another write left it or one of the app's lines
    /// stopped partway (the file size limit), and its record reads back on
    /// the first attempt. Part of a record counts as nothing and stays a
    /// line of its own; the retry then counts. In a log this user may only
    /// write to, the last byte cannot be read, so a newline always goes
    /// first.
    func testEveryAppWriterStartsOnALineOfItsOwnAfterALineCutShort() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let record = line(of: try sessionBytes())
        let other = line(of: Data("an earlier session.json".utf8))
        func lines() -> [String] { logText().components(separatedBy: "\n") }

        try Data("a line\n\(other)".utf8).write(to: logFile)
        XCTAssertNil(h.store.sessionEndRecordedInLog())
        Log.append(level: "info", "after another record", paths: h.home.paths)
        XCTAssertEqual(Array(lines().prefix(2)), ["a line", other])
        XCTAssertNil(h.store.sessionEndRecordedInLog())

        try Data("a line\n\(record)".utf8).write(to: logFile)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log", "at the end of the file, without its newline")
        Log.append(level: "info", "after the record", paths: h.home.paths)
        Log.append(level: "info", "and again", paths: h.home.paths)
        XCTAssertEqual(lines().count, 5, logText())
        XCTAssertEqual(Array(lines().prefix(2)), ["a line", record])
        XCTAssertTrue(lines()[2].hasSuffix("insomnia: after the record"), logText())
        XCTAssertTrue(lines()[3].hasSuffix("insomnia: and again"), logText())
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")

        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }
        try Data("a line\ncut sh".utf8).write(to: logFile)
        XCTAssertTrue(h.store.recordSessionEndInLog(lock: held), "the first attempt")
        XCTAssertEqual(logText(), "a line\ncut sh\n\(record)\n")

        // The size limit stops these writes in an empty log, where the end
        // of the file and the start of a new descriptor are the same offset:
        // an append here is measured from the descriptor's offset.
        try Data().write(to: logFile)
        try withFileSizeLimit(6) { Log.append(level: "info", "stopped partway", paths: h.home.paths) }
        XCTAssertEqual(try size(logFile), 6, "six bytes of the line")
        XCTAssertTrue(h.store.recordSessionEndInLog(lock: held))
        XCTAssertEqual(lines().count, 3, logText())
        XCTAssertEqual(lines()[1], record)

        try Data().write(to: logFile)
        XCTAssertFalse(try withFileSizeLimit(20) { h.store.recordSessionEndInLog(lock: held) })
        XCTAssertEqual(logText(), String(record.prefix(20)))
        XCTAssertNil(h.store.sessionEndRecordedInLog(), "part of a record counts as nothing")
        Log.append(level: "info", "after the part", paths: h.home.paths)
        XCTAssertEqual(lines()[0], String(record.prefix(20)))
        XCTAssertNil(h.store.sessionEndRecordedInLog())
        XCTAssertTrue(h.store.recordSessionEndInLog(lock: held), "the retry")
        XCTAssertEqual(count(record, in: logFile), 1)
        XCTAssertEqual(lines().count, 4, logText())

        try Data("a line\n\(record)".utf8).write(to: logFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: logFile.path)
        Log.append(level: "info", "write-only", paths: h.home.paths)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        XCTAssertEqual(Array(lines().prefix(2)), ["a line", record])
        XCTAssertTrue(lines()[2].hasSuffix("insomnia: write-only"), logText())
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")
    }

    /// Two rotations under the lock with lines cut short. A record whose
    /// newline alone is missing goes to .1 as it is and still counts there.
    /// The next rotation copies it forward into a log that ends in a line
    /// cut short, after a newline, so the copy reads back and .1 then holds
    /// it whole beside that line.
    func testTwoRotationsKeepARecordWithoutItsNewlineAndALineCutShortApart() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let record = line(of: try sessionBytes())
        try Data("a line\n".utf8).write(to: logFile)
        Self.appendFiller(to: logFile)
        try append(record, to: logFile)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")
        let held = try XCTUnwrap(try RecoveryLock(url: lockFile).tryAcquire())
        defer { held.release() }
        func rotate(_ text: String) {
            RecoveryLock.$held.withValue(held) { Log.append(level: "info", text, paths: h.home.paths) }
        }

        rotate("first rotation")
        XCTAssertTrue(text(rotatedLog).hasSuffix("a\n\(record)"), "renamed as it was")
        XCTAssertEqual(count(record, in: logFile), 0)
        XCTAssertTrue(logText().hasSuffix("insomnia: first rotation\n"), logText())
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log.1")

        Self.appendFiller(to: logFile)
        try append("cut sh", to: logFile)
        rotate("second rotation")
        XCTAssertTrue(text(rotatedLog).hasSuffix("a\ncut sh\n\(record)\n"), String(text(rotatedLog).suffix(120)))
        XCTAssertEqual(count(record, in: rotatedLog), 1)
        XCTAssertEqual(count(record, in: logFile), 0)
        XCTAssertTrue(logText().hasSuffix("insomnia: second rotation\n"), logText())
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log.1")
    }

    /// The tick adopts an end recorded only in the log as a record whose
    /// newline alone is missing (a write that stopped at its last byte) and
    /// logs that before it ends the session; every other file still
    /// refuses the end. The lines it logs start on lines of their own, so
    /// the record still counts: a relaunch after a full repair, with
    /// SleepDisabled still 1, ends the session instead of holding sleep
    /// again.
    func testTheTickAdoptsARecordWithoutItsNewlineAndKeepsIt() async throws {
        let m = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try refuseAllButTheLogForTheApp()
        try append(record, to: logFile)

        await m.noticeAgentEnd()

        XCTAssertFalse(m.isActive, logText())
        XCTAssertTrue(logText().contains("is recorded as ended in insomnia.log: the recovery agent ended it"), logText())
        XCTAssertTrue(logText().contains("\(record)\n"), logText())
        XCTAssertEqual(count(record, in: logFile), 1)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")
        XCTAssertNotNil(try h.store.loadSession(), "session.json could not be removed")

        try repairAll()
        h.guardFake.sleepDisabled = true
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, logText())
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(endedInLogLine()), logText())
        XCTAssertNil(try h.store.loadSession())
    }

    /// The agent finds the end recorded in the log as a record whose
    /// newline alone is missing, ends the session again without the checks
    /// and logs that. Each line it writes starts on a line of its own, so
    /// the record still counts for its next run and for the app.
    func testTheAgentsLinesLeaveARecordWithoutItsNewlineWhole() async throws {
        _ = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()
        try append(record, to: logFile)
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }

        try await runAgent(expecting: 1)

        XCTAssertTrue(logText().contains("already ended (recorded in \(logFile.path))"), logText())
        XCTAssertTrue(logText().contains("\(record)\n"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"))
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(count(record, in: logFile), 1)
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")

        agent.clearCalls()
        try await runAgent(expecting: 1)
        XCTAssertFalse(agent.calls.contains("pmset -g batt"), "still ended for the next run")
        XCTAssertEqual(count(record, in: logFile), 1, "used again, not appended again")
    }

    /// The agent writes its record into a log that ends in a line cut
    /// short: another write leaves `cut sh` at the end before each of its
    /// checks for a record, the one just before the write included. The
    /// record starts on a line of its own and reads back on the first
    /// attempt, the line cut short stays as it was, and the app counts the
    /// record too.
    func testTheAgentsRecordAfterALineCutShortReadsBackOnTheFirstAttempt() async throws {
        _ = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()
        try agent.cutTheLogShortAtEveryRecordCheck(log: logFile)

        try await runAgent(expecting: 1)

        XCTAssertTrue(logText().contains("its end is recorded in the log file \(logFile.path) instead"), logText())
        XCTAssertTrue(logText().contains("cut sh\n\(record)\n"), logText())
        XCTAssertEqual(count(record, in: logFile), 1)
        let cut = logText().components(separatedBy: "\n").filter { $0.contains("cut sh") }
        XCTAssertFalse(cut.isEmpty)
        XCTAssertEqual(Set(cut), ["cut sh"], logText())
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")
    }

    /// The agent's writes to the log wait for another writer that holds
    /// the log's lock. Before each of the agent's checks for a record made
    /// while no one holds that lock, another writer takes it, writes
    /// `held sh`, waits a second, writes `ort` and lets go. The record,
    /// and the line the agent logs right after its last check, each wait
    /// for the whole of that line and start on lines of their own: no
    /// write lands inside it. The record reads back on the first attempt
    /// and the app counts it.
    func testTheAgentsWritesWaitForAWriterThatHoldsTheLog() async throws {
        _ = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()
        try agent.holdTheLogAtEveryRecordCheck(log: logFile)

        try await runAgent(expecting: 1)
        try await waitUntilNoWriterHoldsTheLog()

        let recorded = "its end is recorded in the log file \(logFile.path) instead"
        XCTAssertTrue(logText().contains("held short\n\(record)\nheld short\n"), logText())
        let after = try XCTUnwrap(logText().components(separatedBy: "held short\n\(record)\nheld short\n").last)
        XCTAssertTrue(try XCTUnwrap(after.components(separatedBy: "\n").first).hasSuffix(recorded + ", so Insomnia restores the session instead of resuming it. Every run retries the removal"), after)
        XCTAssertEqual(count(record, in: logFile), 1)
        let held = logText().components(separatedBy: "\n").filter { $0.contains("held sh") || $0.hasPrefix("ort") }
        XCTAssertGreaterThanOrEqual(held.count, 2)
        XCTAssertEqual(Set(held), ["held short"], logText())
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")
    }

    /// While another writer holds the log's lock for the whole run, every
    /// write of the agent's to the log waits at most
    /// LOG_LOCK_TIMEOUT_SECONDS (1 here) and then writes nothing there:
    /// the log keeps exactly what that writer left, a line cut short. The
    /// record goes in nowhere, so the agent keeps the sleep entry, and each
    /// line it would have logged goes to standard error instead, saying
    /// why. Once that writer lets go, the next run's first line starts
    /// after a newline, and it records the end in the log.
    func testTheAgentWritesNothingToALogItCannotLockAndSaysSo() async throws {
        _ = try await startThenPinAll()
        let record = line(of: try sessionBytes())
        try agent.refuseRecordsAside()
        try agent.refuseLockRecord()
        try agent.setLogLockTimeout(1)
        let holder = try LogLockHolder(logFile)
        defer { holder.release() }
        try holder.write("cut sh")
        let before = logText()

        try await runAgent(expecting: 1)

        XCTAssertEqual(logText(), before)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        let refused = "(not in \(logFile.path): not locked within 1s (lockf exit 75))"
        let lines = agent.lastStderr.components(separatedBy: "\n").filter { $0.contains("backstop: ") }
        XCTAssertFalse(lines.isEmpty, agent.lastStderr)
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(refused) }, agent.lastStderr)
        XCTAssertTrue(lines.contains { $0.contains("the recovery lock file \(lockFile.path), or the log file \(logFile.path). Sleep is restored anyway") }, agent.lastStderr)

        holder.release()
        agent.clearCalls()
        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().hasPrefix(before + "\n"), "the line cut short stays as it was: \(logText())")
        XCTAssertEqual(count(record, in: logFile), 1)
        XCTAssertTrue(logText().contains("its end is recorded in the log file \(logFile.path) instead"), logText())
        XCTAssertEqual(h.store.sessionEndRecordedInLog(), "insomnia.log")
    }

    /// Waits, at most 10 s, until no writer holds the log's lock, so every
    /// writer a fake started has let go.
    private func waitUntilNoWriterHoldsTheLog() async throws {
        let fd = open(logFile.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return XCTFail("could not open \(logFile.path)") }
        defer { close(fd) }
        for _ in 0..<500 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("another writer still holds \(logFile.path) after 10 s")
    }

    // MARK: Other sessions and ordinary ends

    /// A crash beside a record of an earlier session's bytes and lines that
    /// are no whole record of this one resumes: none of them ends it. The
    /// agent then checks the session as usual and keeps it.
    func testACrashResumesBesideRecordsOfOtherBytesAndLinesThatAreNoWholeRecord() async throws {
        let first = h.makeManager()
        await first.reconcile()
        await first.start(duration: 3600)
        let record = line(of: try sessionBytes())
        let other = line(of: Data("an earlier session.json".utf8))
        try append("\(other)\n\(record.dropLast(2))\nx \(record)\n\(record)\r\n\(record) \n", to: logFile)
        try Data("\(other)\n".utf8).write(to: rotatedLog)
        XCTAssertNil(h.store.sessionEndRecordedInLog())

        let before = h.guardFake.calls.count
        let crashed = h.makeManager()
        await crashed.reconcile()
        XCTAssertTrue(crashed.isActive, logText())
        XCTAssertTrue(sleepHeldAgain(since: before))

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertTrue(agent.calls.contains("pmset -g batt"))
        XCTAssertFalse(logText().contains("already ended"), logText())
    }

    /// Ends that can remove session.json, or record the end in
    /// ended-session.json, write no record to the log: the app's, and the
    /// agent's.
    func testOrdinaryEndsWriteNoRecordToTheLog() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        _ = await m.end(reason: .user)
        XCTAssertNil(try h.store.loadSession())

        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        try await runAgent(expecting: 0)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(agent.calls.contains(agent.restoreCall))

        await m.noticeAgentEnd()
        XCTAssertFalse(m.isActive)
        await m.start(duration: 3600)
        try setImmutable(h.home.paths.sessionFile, true)
        try await runAgent(expecting: 1)
        XCTAssertTrue(h.store.sessionEndIsRecorded(), "recorded in ended-session.json")
        XCTAssertFalse(logText().contains(LogEndRecord.tag), logText())
    }
}

/// Lines written to insomnia.log from another thread while a test runs
/// the agent, as the app logs from any thread: every 25th line takes the
/// recovery lock when it is free and rotates a log made longer than the
/// cap first.
private final class BesideTheAgent: @unchecked Sendable {
    private let mutex = NSLock()
    private var stopped = false
    private var lines = 0
    private var rotations = 0
    private let done = DispatchSemaphore(value: 0)
    let paths: Paths

    init(paths: Paths) { self.paths = paths }

    func start() {
        Thread.detachNewThread { [self] in
            var n = 0
            while !mutex.withLock({ stopped }) {
                Log.append(level: "info", "a line beside the agent \(n)", paths: paths)
                n += 1
                if n % 25 == 0, let handle = try? RecoveryLock(url: paths.recoveryLock).tryAcquire() {
                    LogEndRecordTests.appendFiller(to: paths.logFile)
                    RecoveryLock.$held.withValue(handle) { Log.append(level: "info", "a rotation beside the agent", paths: paths) }
                    handle.release()
                    mutex.withLock { rotations += 1 }
                }
                usleep(2000)
            }
            mutex.withLock { lines = n }
            done.signal()
        }
    }

    /// Stops the thread and waits for it. Returns how many lines it wrote
    /// and how many times it took the lock to rotate.
    func stop() -> (lines: Int, rotations: Int) {
        mutex.withLock { stopped = true }
        done.wait()
        return mutex.withLock { (lines, rotations) }
    }
}
