import Foundation
import XCTest
import InsomniaTestHome
@testable import Insomnia

/// The suite must never write under the real ~/Library. `Log.append` and
/// `SessionManager.live` resolve INSOMNIA_HOME at call time, so these
/// tests check that the InsomniaTestHome loader set the variable before
/// XCTest ran, the file a default-argument log line lands in, and that a
/// TempHome hands the variable back instead of unsetting it. This class
/// extends XCTestCase directly on purpose: isolation must not depend on
/// a base class or on which tests a `--filter` selects.
final class TestIsolationTests: XCTestCase {
    private var realHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func isUnderRealHome(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(realHome.standardizedFileURL.path + "/")
    }

    /// True only when every location the app writes to resolves outside
    /// the real home. Callers that would write must stop when this is false.
    private func isIsolated(_ paths: Paths) -> Bool {
        paths != Paths.standard
            && !isUnderRealHome(paths.logFile)
            && !isUnderRealHome(paths.appSupport)
            && !isUnderRealHome(paths.launchAgents)
    }

    func testLoaderSetTheHomeBeforeAnyTestRan() {
        XCTAssertEqual(String(cString: insomnia_test_home_key()), Paths.environmentKey)
        let root = ProcessTestHome.root
        XCTAssertEqual(ProcessTestHome.current, root.path, "INSOMNIA_HOME is not the loader's directory")
        XCTAssertTrue(root.lastPathComponent.hasPrefix("insomnia-tests-process-"), root.path)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertFalse(isUnderRealHome(root), root.path)
        XCTAssertTrue(
            root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path),
            root.path
        )
    }

    func testDefaultLogLineResolvesOutsideRealHome() throws {
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
        XCTAssertFalse(isUnderRealHome(home.root))

        home.destroy()

        // Not unset: a task that outlives its test still logs to a temp dir.
        XCTAssertEqual(ProcessTestHome.current, ProcessTestHome.root.path)
        XCTAssertTrue(isIsolated(Paths.fromEnvironment()))
    }
}
