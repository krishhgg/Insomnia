import Foundation
import ObjectiveC
import XCTest
@testable import Insomnia

/// The suite must never write under the real ~/Library. `Log.append` and
/// `SessionManager.live` resolve INSOMNIA_HOME at call time, so these
/// tests check the variable itself, the file a default-argument log line
/// lands in, and that every test class inherits the installer.
final class TestIsolationTests: InsomniaTestCase {
    private var realHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func isUnderRealHome(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(realHome.standardizedFileURL.path + "/")
    }

    func testDefaultLogLineResolvesOutsideRealHome() throws {
        let resolved = Paths.fromEnvironment()
        XCTAssertNotEqual(resolved, Paths.standard, "INSOMNIA_HOME is unset; a log line would reach the real log")
        XCTAssertFalse(isUnderRealHome(resolved.logFile), resolved.logFile.path)
        XCTAssertFalse(isUnderRealHome(resolved.appSupport), resolved.appSupport.path)
        XCTAssertFalse(isUnderRealHome(resolved.launchAgents), resolved.launchAgents.path)

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
        XCTAssertFalse(isUnderRealHome(Paths.fromEnvironment().logFile))
        XCTAssertNotEqual(Paths.fromEnvironment(), Paths.standard)
    }

    func testProcessWideHomeIsATempDirectory() {
        let root = ProcessTestHome.root
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertFalse(isUnderRealHome(root), root.path)
        XCTAssertTrue(
            root.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path),
            root.path
        )
    }

    /// A test class declared `: XCTestCase` would run without the installer
    /// if XCTest picked it first. Walk the classes in this test image and
    /// refuse any XCTestCase subclass that does not go through
    /// InsomniaTestCase. Only names come back from the runtime, and only
    /// our own classes are looked up, so no private system class is touched.
    func testEveryTestClassInheritsTheInstaller() throws {
        let image = try XCTUnwrap(class_getImageName(InsomniaTestCase.self))
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else { return XCTFail("no classes in image") }
        defer { free(names) }

        var checked = 0
        var offenders: [String] = []
        for i in 0..<Int(count) {
            let name = String(cString: names[i])
            guard let cls = NSClassFromString(name) else { continue }
            guard inherits(cls, from: XCTestCase.self), cls != InsomniaTestCase.self else { continue }
            checked += 1
            if !inherits(cls, from: InsomniaTestCase.self) {
                offenders.append(name)
            }
        }
        XCTAssertGreaterThan(checked, 1, "expected to find the test classes in \(String(cString: image))")
        XCTAssertEqual(offenders, [], "test classes must extend InsomniaTestCase, not XCTestCase")
    }

    /// Superclass walk through the runtime, not `isSubclass(of:)`.
    private func inherits(_ cls: AnyClass, from ancestor: AnyClass) -> Bool {
        var current: AnyClass? = class_getSuperclass(cls)
        while let c = current {
            if c == ancestor { return true }
            current = class_getSuperclass(c)
        }
        return false
    }
}
