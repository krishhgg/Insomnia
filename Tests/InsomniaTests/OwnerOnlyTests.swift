import Darwin
import XCTest
@testable import Insomnia

/// Files Insomnia creates are owner-only (0600; its directories 0700), a
/// looser existing file is tightened when opened, and the two logs rotate
/// to `<name>.1` once they pass the cap.
final class OwnerOnlyTests: XCTestCase {
    var home: TempHome!

    override func setUp() { home = TempHome() }
    override func tearDown() { home.destroy() }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? Int)
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attrs[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    /// A file the way an older build or a wide umask left it.
    private func writeLoose(_ text: String, to url: URL, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: insomnia.log

    func testLogIsCreatedOwnerOnlyInAnOwnerOnlyDirectory() throws {
        Log.append(level: "info", "hello", paths: home.paths)

        XCTAssertEqual(try mode(home.paths.logFile), 0o600)
        XCTAssertEqual(try mode(home.paths.logs), 0o700)
        XCTAssertTrue(try String(contentsOf: home.paths.logFile, encoding: .utf8).hasSuffix("insomnia: hello\n"))
    }

    func testLooseLogAndDirectoryAreTightenedOnAppendAndKeepTheirText() throws {
        try writeLoose("old line\n", to: home.paths.logFile)
        XCTAssertEqual(try mode(home.paths.logFile), 0o644)
        XCTAssertEqual(try mode(home.paths.logs), 0o755)

        Log.append(level: "info", "new line", paths: home.paths)

        XCTAssertEqual(try mode(home.paths.logFile), 0o600)
        XCTAssertEqual(try mode(home.paths.logs), 0o700)
        let text = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("old line\n"), text)
        XCTAssertTrue(text.hasSuffix("insomnia: new line\n"), text)
    }

    func testLogPastTheCapRotatesToDotOneAndStartsAFreshFile() throws {
        let log = home.paths.logFile
        let rotated = OwnerOnly.rotated(log)
        XCTAssertEqual(rotated.lastPathComponent, "insomnia.log.1")
        try FileManager.default.createDirectory(at: home.paths.logs, withIntermediateDirectories: true)
        let first = Data(repeating: UInt8(ascii: "a"), count: Int(OwnerOnly.maxLogBytes) + 1)
        try first.write(to: log)

        Log.append(level: "info", "after first rotation", paths: home.paths)

        XCTAssertEqual(try Data(contentsOf: rotated), first, "the full log was not moved aside intact")
        let fresh = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(fresh.hasSuffix("insomnia: after first rotation\n"), fresh)
        XCTAssertLessThan(fresh.utf8.count, 200, "the new file must hold only the new line")
        XCTAssertEqual(try mode(log), 0o600)

        // The next rotation replaces .1; nothing becomes .2.
        let second = Data(repeating: UInt8(ascii: "b"), count: Int(OwnerOnly.maxLogBytes) + 1)
        try second.write(to: log)
        Log.append(level: "info", "after second rotation", paths: home.paths)
        XCTAssertEqual(try Data(contentsOf: rotated), second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.paths.logs.path).sorted(), ["insomnia.log", "insomnia.log.1"])
    }

    /// Exactly at the cap nothing moves; one byte over, the next append rotates.
    func testRotationHappensOnlyOncePastTheCap() throws {
        let log = home.paths.logs.appendingPathComponent("small.log")
        try OwnerOnly.appendToLog("0123456789", at: log, maxBytes: 10)
        try OwnerOnly.appendToLog("x", at: log, maxBytes: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: OwnerOnly.rotated(log).path), "rotated at, not past, the cap")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "0123456789x")

        try OwnerOnly.appendToLog("y", at: log, maxBytes: 10)

        XCTAssertEqual(try String(contentsOf: OwnerOnly.rotated(log), encoding: .utf8), "0123456789x")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "y")
        XCTAssertEqual(try mode(OwnerOnly.rotated(log)), 0o600, "the rotated file keeps the owner-only mode")
    }

    // MARK: Rotation races and failures that must be reported

    /// Two processes can both find the log oversized. The one that gets to
    /// rotate second must not rename the fresh log over the retained copy.
    /// The appender is stopped after it has found the file it holds past the
    /// cap; the test then plays the other process, rotating and writing its
    /// own line, and only then opens the gate that lets the appender go on.
    func testRotationByAnotherProcessIsNoticedAndTheRetainedCopyKept() throws {
        let log = home.paths.logs.appendingPathComponent("race.log")
        let big = "0123456789ABCDEF\n"
        try OwnerOnly.appendToLog(big, at: log)
        let reached = DispatchSemaphore(value: 0)
        let gate = Gate()
        let appender = DispatchGroup()
        let failure = Locked<String?>(nil)
        appender.enter()
        DispatchQueue.global().async {
            do {
                try OwnerOnly.appendToLog("second\n", at: log, maxBytes: 10) {
                    reached.signal()
                    try gate.pass()
                }
            } catch {
                failure.value = "\(error)"
            }
            appender.leave()
        }
        // Every way out of the test closes the gate, which stops the
        // appender before it rotates, and waits for the appender to end.
        defer {
            gate.close()
            _ = appender.wait(timeout: .now() + 60)
        }
        guard reached.wait(timeout: .now() + 60) == .success else {
            return XCTFail("the appender never found the log past the cap")
        }

        XCTAssertEqual(rename(log.path, OwnerOnly.rotated(log).path), 0)
        try OwnerOnly.appendToLog("first\n", at: log, maxBytes: 10)
        gate.open()

        XCTAssertEqual(appender.wait(timeout: .now() + 60), .success)
        XCTAssertNil(failure.value)
        XCTAssertEqual(try String(contentsOf: OwnerOnly.rotated(log), encoding: .utf8), big, "the retained copy was replaced")
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "first\nsecond\n")
    }

    /// A legacy 0644 log that is already past the cap is tightened before it
    /// becomes `.1`, so the retained copy is owner-only too.
    func testLooseLogPastTheCapIsTightenedBeforeItIsRotated() throws {
        let log = home.paths.logs.appendingPathComponent("legacy.log")
        try writeLoose(String(repeating: "x", count: 20), to: log)
        XCTAssertEqual(try mode(log), 0o644)

        try OwnerOnly.appendToLog("y", at: log, maxBytes: 10)

        XCTAssertEqual(try mode(OwnerOnly.rotated(log)), 0o600)
        XCTAssertEqual(try mode(log), 0o600)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "y")
    }

    /// A rotation that cannot happen (here `.1` is a directory) is thrown
    /// after the line is written, so the caller can say why the cap no
    /// longer holds; the line itself is not lost.
    func testFailedRotationIsThrownAfterTheLineIsWritten() throws {
        let log = home.paths.logs.appendingPathComponent("stuck.log")
        try OwnerOnly.appendToLog("0123456789A", at: log, maxBytes: 10)
        try FileManager.default.createDirectory(at: OwnerOnly.rotated(log), withIntermediateDirectories: true)

        XCTAssertThrowsError(try OwnerOnly.appendToLog("B", at: log, maxBytes: 10)) { error in
            guard case .rotate(let path, _)? = error as? OwnerOnlyError else { return XCTFail("\(error)") }
            XCTAssertEqual(path, log.path)
            XCTAssertTrue(error.localizedDescription.hasPrefix("could not rotate \(log.path) to \(log.path).1: "), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "0123456789AB")
    }

    /// A file this user cannot chmod (here: immutable) is still read, and
    /// the failure is logged once, not on every transaction.
    func testUnfixableLooseFileIsReportedOnceAndStillRead() throws {
        try writeLoose(#"{"lowPowerFloor": 25}"#, to: home.paths.configFile)
        XCTAssertEqual(chflags(home.paths.configFile.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(home.paths.configFile.path, 0) }
        let store = Store(paths: home.paths)

        XCTAssertEqual(try store.loadConfig()?.lowPowerFloor, 25)
        XCTAssertEqual(try store.loadConfig()?.lowPowerFloor, 25)

        XCTAssertEqual(try mode(home.paths.configFile), 0o644, "chmod cannot succeed on an immutable file")
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        let lines = log.split(whereSeparator: \.isNewline).filter { $0.contains("config.json") }
        XCTAssertEqual(lines.count, 1, log)
        XCTAssertTrue(lines.first?.hasSuffix("[error] insomnia: could not make \(home.paths.configFile.path) owner-only: Operation not permitted") ?? false, log)
    }

    /// Tightening only clears bits outside the owner-only mode. It never
    /// adds one: a file its owner made unreadable stays unreadable, a
    /// directory without the owner's write bit keeps it off, and a
    /// write-only log stays write-only.
    func testTighteningNeverAddsAPermission() throws {
        let file = home.root.appendingPathComponent("unreadable.json")
        try writeLoose("{}", to: file, mode: 0o044)
        let dir = home.root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o555])
        let log = home.paths.logs.appendingPathComponent("write-only.log")
        try writeLoose("", to: log, mode: 0o266)
        defer { _ = chmod(log.path, 0o600) }

        XCTAssertNil(OwnerOnly.tighten(path: file.path))
        XCTAssertNil(OwnerOnly.tighten(path: dir.path, to: OwnerOnly.directoryMode))
        try OwnerOnly.appendToLog("line\n", at: log)

        XCTAssertEqual(try mode(file), 0o000, "tightening gave the owner read access")
        XCTAssertEqual(try mode(dir), 0o500)
        XCTAssertEqual(try mode(log), 0o200)
    }

    /// The log's own directory: the line is still written and the chmod
    /// failure is thrown afterwards for the caller to report.
    func testUnfixableLogDirectoryIsThrownAfterTheLineIsWritten() throws {
        let log = home.paths.logs.appendingPathComponent("held.log")
        try writeLoose("", to: log)
        XCTAssertEqual(try mode(home.paths.logs), 0o755)
        XCTAssertEqual(chflags(home.paths.logs.path, UInt32(UF_IMMUTABLE)), 0)
        defer { _ = chflags(home.paths.logs.path, 0) }

        XCTAssertThrowsError(try OwnerOnly.appendToLog("line\n", at: log)) { error in
            guard case .chmod(let path, _)? = error as? OwnerOnlyError else { return XCTFail("\(error)") }
            XCTAssertEqual(path, home.paths.logs.path)
        }
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "line\n")
        XCTAssertEqual(try mode(home.paths.logs), 0o755)
    }

    /// A symlinked config.json is read, but the target's mode is not
    /// touched: it may be shared with other users or programs. Same for a
    /// Logs directory that is a symlink elsewhere.
    func testSymlinkedFileAndDirectoryAreLeftAlone() throws {
        let shared = home.root.appendingPathComponent("shared-config.json")
        try writeLoose(#"{"lowPowerFloor": 25}"#, to: shared)
        try FileManager.default.createDirectory(at: home.paths.appSupport, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.paths.configFile, withDestinationURL: shared)
        let store = Store(paths: home.paths)

        XCTAssertEqual(try store.loadConfig()?.lowPowerFloor, 25)

        XCTAssertEqual(try mode(shared), 0o644)
        let elsewhere = home.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try? FileManager.default.removeItem(at: home.paths.logs)
        try FileManager.default.createSymbolicLink(at: home.paths.logs, withDestinationURL: elsewhere)

        Log.append(level: "info", "via symlink", paths: home.paths)

        XCTAssertEqual(try mode(elsewhere), 0o755)
        XCTAssertTrue(try String(contentsOf: home.paths.logFile, encoding: .utf8).hasSuffix("insomnia: via symlink\n"))

        let sharedLog = home.root.appendingPathComponent("shared.log")
        try writeLoose("", to: sharedLog)
        try FileManager.default.removeItem(at: home.paths.logFile)
        try FileManager.default.createSymbolicLink(at: home.paths.logFile, withDestinationURL: sharedLog)

        Log.append(level: "info", "via symlinked file", paths: home.paths)

        XCTAssertEqual(try mode(sharedLog), 0o644)
        XCTAssertTrue(try String(contentsOf: sharedLog, encoding: .utf8).hasSuffix("insomnia: via symlinked file\n"))

        // Past the cap, the symlinked log is not rotated: a rename would move
        // the link to `.1` and the next line would start a plain file.
        XCTAssertThrowsError(try OwnerOnly.appendToLog("past the cap\n", at: home.paths.logFile, maxBytes: 10)) { error in
            guard case .symlinkNotRotated = error as? OwnerOnlyError else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try OwnerOnly.appendToLog("again\n", at: home.paths.logFile, maxBytes: 10), "reported once per path")

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home.paths.logFile.path), sharedLog.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: OwnerOnly.rotated(home.paths.logFile).path))
        XCTAssertTrue(try String(contentsOf: sharedLog, encoding: .utf8).hasSuffix("past the cap\nagain\n"))
        XCTAssertEqual(try mode(sharedLog), 0o644)
    }

    // MARK: Journal, session, config

    func testStoreCreatesItsFilesAndDirectoryOwnerOnly() throws {
        let store = Store(paths: home.paths)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        try store.saveSession(Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600), extensions: []))
        try store.saveState(RuntimeState())
        try store.saveConfig(Config())

        for file in [home.paths.sessionFile, home.paths.stateFile, home.paths.configFile] {
            XCTAssertEqual(try mode(file), 0o600, file.lastPathComponent)
        }
        XCTAssertEqual(try mode(home.paths.appSupport), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path).filter { $0.contains(".tmp-") }, [], "temp file left behind")
    }

    func testStoreWriteReplacesALooseFileWithAnOwnerOnlyOne() throws {
        try writeLoose("{}", to: home.paths.configFile)
        let store = Store(paths: home.paths)

        try store.saveConfig(Config())

        XCTAssertEqual(try mode(home.paths.configFile), 0o600)
        XCTAssertEqual(try store.loadConfig(), Config())
    }

    func testStoreReadTightensALooseFile() throws {
        try writeLoose(#"{"lowPowerFloor": 25}"#, to: home.paths.configFile)
        let store = Store(paths: home.paths)

        let config = try store.loadConfig()

        XCTAssertEqual(config?.lowPowerFloor, 25)
        XCTAssertEqual(try mode(home.paths.configFile), 0o600)
    }

    // MARK: Recovery lock

    func testLockFileIsCreatedOwnerOnly() throws {
        try home.paths.createDirectories()
        let handle = try XCTUnwrap(try RecoveryLock(url: home.paths.recoveryLock).tryAcquire())
        defer { handle.release() }
        XCTAssertEqual(try mode(home.paths.recoveryLock), 0o600)
    }

    /// The lock is never unlinked or replaced (both sides must lock one
    /// inode), so an older 0644 lock is chmodded in place.
    func testLooseLockIsTightenedInPlaceKeepingItsInode() throws {
        try writeLoose("", to: home.paths.recoveryLock)
        let before = try inode(home.paths.recoveryLock)

        let handle = try XCTUnwrap(try RecoveryLock(url: home.paths.recoveryLock).tryAcquire())
        defer { handle.release() }

        XCTAssertEqual(try mode(home.paths.recoveryLock), 0o600)
        XCTAssertEqual(try inode(home.paths.recoveryLock), before)
    }

    // MARK: Directories

    func testCreateDirectoriesMakesInsomniasOwnDirectoriesOwnerOnly() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.paths.appSupport.path)

        try home.paths.createDirectories()

        XCTAssertEqual(try mode(home.paths.appSupport), 0o700)
        XCTAssertEqual(try mode(home.paths.logs), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.paths.launchAgents.path))
    }
}

/// handoffs.log is written by the failover driver on every recovery.
@MainActor
final class HandoffsLogPermissionTests: XCTestCase {
    var home: TempHome!

    override func setUp() async throws { home = TempHome() }
    override func tearDown() async throws { home.destroy() }

    func testHandoffsLogIsCreatedOwnerOnly() async throws {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: TmuxNudge { _ in true }, notifier: RecordingNotifier(), clock: { clock.now }) { Config() }

        await n.simulate(satisfied: false)
        clock.advance(20)
        await n.simulate(satisfied: true)

        let attrs = try FileManager.default.attributesOfItem(atPath: home.paths.handoffsLog.path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        let logsAttrs = try FileManager.default.attributesOfItem(atPath: home.paths.logs.path)
        XCTAssertEqual(logsAttrs[.posixPermissions] as? Int, 0o700)
        XCTAssertTrue(try String(contentsOf: home.paths.handoffsLog, encoding: .utf8).contains("gap=20s"))
    }
}

/// Holds a worker until the test decides. Only `open` lets it through;
/// `close`, or no decision before the wait runs out, makes `pass` throw so
/// the worker stops where it is. The first decision stands.
private final class Gate: @unchecked Sendable {
    struct Closed: Error {}

    private let lock = NSLock()
    private let decided = DispatchSemaphore(value: 0)
    private var isOpen: Bool?

    func open() { decide(true) }
    func close() { decide(false) }

    func pass(timeout: TimeInterval = 60) throws {
        guard decided.wait(timeout: .now() + timeout) == .success, lock.withLock({ isOpen == true }) else {
            throw Closed()
        }
    }

    private func decide(_ open: Bool) {
        lock.withLock {
            guard isOpen == nil else { return }
            isOpen = open
            decided.signal()
        }
    }
}
