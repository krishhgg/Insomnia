import Foundation
import XCTest
import InsomniaTestHome
@testable import Insomnia

/// The suite must never write to the real ~/Library, which holds Insomnia's
/// Logs, Application Support files and LaunchAgent. `Log.append` and
/// `SessionManager.live` resolve INSOMNIA_HOME at call time, so these tests
/// check that the variable names an existing directory outside ~/Library,
/// that every path the app resolves sits inside it, that a default-argument
/// log line lands there, and that a TempHome hands the variable back instead
/// of unsetting it. They do not check which temp directory the loader used:
/// it prefers Darwin's per-user temp dir and falls back to TMPDIR, and
/// Foundation's temporaryDirectory need not match either. This class extends
/// XCTestCase directly on purpose: isolation must not depend on a base class
/// or on which tests a `--filter` selects.
final class TestIsolationTests: XCTestCase {
    /// The real ~/Library. Only compared against, never read or written.
    private var realLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
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

    /// True only when nothing the app would write resolves into the real
    /// ~/Library. Callers that would write must stop when this is false.
    private func isIsolated(_ paths: Paths) -> Bool {
        paths != Paths.standard && !locations(paths).contains { isInside($0, realLibrary) }
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
        XCTAssertFalse(isInside(root, realLibrary), root.path)
    }

    func testEveryResolvedPathSitsInsideTheTestHome() throws {
        let value = try XCTUnwrap(ProcessTestHome.current, "INSOMNIA_HOME is unset")
        XCTAssertFalse(value.isEmpty, "INSOMNIA_HOME is empty")
        let home = URL(fileURLWithPath: value, isDirectory: true)
        XCTAssertTrue(isDirectory(home), "INSOMNIA_HOME does not exist: \(home.path)")
        XCTAssertFalse(isInside(home, realLibrary), home.path)

        let resolved = Paths.fromEnvironment()
        XCTAssertNotEqual(resolved, Paths.standard)
        for url in locations(resolved) {
            XCTAssertTrue(isInside(url, home), "\(url.path) is outside INSOMNIA_HOME \(home.path)")
            XCTAssertFalse(isInside(url, realLibrary), url.path)
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
        XCTAssertFalse(isInside(home.root, realLibrary), home.root.path)

        home.destroy()

        // Not unset: a task that outlives its test still logs to a temp dir.
        XCTAssertEqual(ProcessTestHome.current, ProcessTestHome.root.path)
        XCTAssertTrue(isIsolated(Paths.fromEnvironment()))
    }
}
