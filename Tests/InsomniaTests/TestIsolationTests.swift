import Foundation
import XCTest
import InsomniaTestHome
@testable import Insomnia

/// The suite must never write to the places in ~/Library that hold
/// Insomnia's real files: its Application Support and Logs folders and the
/// LaunchAgents folder, nor to the installed app. `Log.append` and
/// `SessionManager.live` resolve INSOMNIA_HOME at call time, so these tests
/// check that the variable names an existing directory outside those
/// places, that every path the app resolves sits inside it, that a
/// default-argument log line lands there, and that a TempHome hands the
/// variable back instead of unsetting it. They compare against those places,
/// not all of ~/Library, so a run whose TMPDIR is a folder of its own under
/// ~/Library passes. When the run sets TMPDIR they also check that the
/// loader's home, and the scratch directory TempHome and the fixtures use,
/// are in it. This class extends XCTestCase directly on purpose: isolation
/// must not depend on a base class or on which tests a `--filter` selects.
final class TestIsolationTests: XCTestCase {
    /// Where the app keeps its real files (`Paths.standard`). Only compared
    /// against, never read or written.
    private var realLocations: [URL] {
        let real = Paths.standard
        return [real.appSupport, real.logs, real.launchAgents, real.appBundle]
    }

    /// `url` is one of the real locations or sits inside one.
    private func isInsideReal(_ url: URL) -> Bool {
        realLocations.contains { isInside(url, $0) }
    }

    /// `url` is `dir` or sits inside it. `standardized` only removes `.` and
    /// `..`; `standardizedFileURL` would also drop a leading /private, but
    /// only for paths that already exist, so a home under /private/tmp and
    /// its not-yet-created files would stop matching.
    private func isInside(_ url: URL, _ dir: URL) -> Bool {
        let path = url.standardized.path
        let base = dir.standardized.path
        return path == base || path.hasPrefix(base + "/")
    }

    /// Every directory and file the app resolves from `paths`.
    private func locations(_ paths: Paths) -> [URL] {
        [
            paths.appSupport, paths.logs, paths.launchAgents,
            paths.sessionFile, paths.stateFile, paths.configFile, paths.backstopScript,
            paths.recoveryLock, paths.simulateLidFile,
            paths.logFile, paths.handoffsLog, paths.backstopPlist,
        ]
    }

    /// True only when nothing the app would write resolves into one of its
    /// real locations. Callers that would write must stop when this is false.
    private func isIsolated(_ paths: Paths) -> Bool {
        paths != Paths.standard && !locations(paths).contains { isInsideReal($0) }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func testLoaderCreatedItsHomeOutsideTheRealLibrary() {
        XCTAssertEqual(String(cString: insomnia_test_home_key()), Paths.environmentKey)
        let root = ProcessTestHome.root
        XCTAssertTrue(root.lastPathComponent.hasPrefix("insomnia-tests-process-"), root.path)
        XCTAssertTrue(isDirectory(root), "the loader's directory does not exist: \(root.path)")
        XCTAssertFalse(isInsideReal(root), root.path)
    }

    /// TMPDIR as the run set it. Unset or empty sends the loader to Darwin's
    /// per-user temp directory, then /tmp, and there is nothing to compare.
    private func runTMPDIR() throws -> URL {
        guard let raw = getenv("TMPDIR"), raw.pointee != 0 else { throw XCTSkip("TMPDIR is unset") }
        return URL(fileURLWithPath: String(cString: raw), isDirectory: true)
    }

    /// `a` and `b` are the same directory: the same device and inode.
    private func assertSameDirectory(_ a: URL, _ b: URL, file: StaticString = #filePath, line: UInt = #line) {
        var sa = stat(), sb = stat()
        XCTAssertEqual(stat(a.path, &sa), 0, "stat \(a.path): errno \(errno)", file: file, line: line)
        XCTAssertEqual(stat(b.path, &sb), 0, "stat \(b.path): errno \(errno)", file: file, line: line)
        XCTAssertEqual(sa.st_dev, sb.st_dev, "\(a.path) and \(b.path)", file: file, line: line)
        XCTAssertEqual(sa.st_ino, sb.st_ino, "\(a.path) and \(b.path)", file: file, line: line)
    }

    func testLoaderHomeSitsInTMPDIRWhenTheRunSetsIt() throws {
        let tmp = try runTMPDIR()
        let parent = ProcessTestHome.root.deletingLastPathComponent()
        // The loader joins TMPDIR and the name, so the path matches too.
        XCTAssertEqual(parent.standardized.path, tmp.standardized.path)
        assertSameDirectory(parent, tmp)
    }

    func testScratchDirectoryIsTMPDIRWhenTheRunSetsIt() throws {
        let tmp = try runTMPDIR()
        assertSameDirectory(ProcessTestHome.temporaryDirectory, tmp)
        let home = TempHome()
        defer { home.destroy() }
        assertSameDirectory(home.root.deletingLastPathComponent(), tmp)
    }

    func testEveryResolvedPathSitsInsideTheTestHome() throws {
        let value = try XCTUnwrap(ProcessTestHome.current, "INSOMNIA_HOME is unset")
        XCTAssertFalse(value.isEmpty, "INSOMNIA_HOME is empty")
        let home = URL(fileURLWithPath: value, isDirectory: true)
        XCTAssertTrue(isDirectory(home), "INSOMNIA_HOME does not exist: \(home.path)")
        XCTAssertFalse(isInsideReal(home), home.path)

        let resolved = Paths.fromEnvironment()
        XCTAssertNotEqual(resolved, Paths.standard)
        for url in locations(resolved) {
            XCTAssertTrue(isInside(url, home), "\(url.path) is outside INSOMNIA_HOME \(home.path)")
            XCTAssertFalse(isInsideReal(url), url.path)
        }
    }

    func testDefaultLogLineStaysOutOfTheRealLog() throws {
        let resolved = Paths.fromEnvironment()
        // Stop here rather than write the probe into the real log, which is
        // the outcome this test exists to prevent.
        guard isIsolated(resolved) else {
            return XCTFail("INSOMNIA_HOME does not isolate the run (log would go to \(resolved.logFile.path)); not writing a probe")
        }

        // A line written the way production code writes one (default paths).
        let probe = "test isolation probe \(UUID().uuidString)"
        Log.append(level: "info", probe)

        let written = try String(contentsOf: resolved.logFile, encoding: .utf8)
        XCTAssertTrue(written.contains(probe), "probe line missing from \(resolved.logFile.path)")

        // Read-only look at the real log, if the machine has one.
        let real = Paths.standard.logFile
        if FileManager.default.fileExists(atPath: real.path) {
            let contents = try String(contentsOf: real, encoding: .utf8)
            XCTAssertFalse(contents.contains(probe), "probe line reached the real log at \(real.path)")
        }
    }

    func testTempHomeDestroyKeepsTheProcessWideHome() {
        let home = TempHome()
        XCTAssertEqual(ProcessTestHome.current, home.root.path)
        XCTAssertFalse(isInsideReal(home.root), home.root.path)

        home.destroy()

        // Not unset: a task that outlives its test still logs to a temp dir.
        XCTAssertEqual(ProcessTestHome.current, ProcessTestHome.root.path)
        XCTAssertTrue(isIsolated(Paths.fromEnvironment()))
    }
}
