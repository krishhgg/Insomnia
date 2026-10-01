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
