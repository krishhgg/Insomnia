import XCTest
@testable import Insomnia

/// Start shows the password dialog only when the installed backstop.sh
/// declares a version that deletes the pending-start marker.
final class BackstopVersionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-backstop-version-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var repoBackstop: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/backstop.sh")
    }

    private func script(_ text: String) throws -> URL {
        let url = dir.appendingPathComponent("backstop.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The script this build installs passes the check this build makes.
    func testTheRepositoryScriptDeclaresTheRequiredVersion() throws {
        let text = try String(contentsOf: repoBackstop, encoding: .utf8)
        XCTAssertEqual(BackstopVersion.declared(in: text), BackstopVersion.required)
        XCTAssertNoThrow(try BackstopVersion.check(scriptAt: repoBackstop))
    }

    func testReadsTheFirstVersionLine() {
        XCTAssertEqual(BackstopVersion.declared(in: "#!/bin/bash\n# insomnia-backstop-version: 3\n# insomnia-backstop-version: 1\n"), 3)
        XCTAssertEqual(BackstopVersion.declared(in: "#!/bin/bash\n# insomnia-backstop-version: 2 \n"), 2)
        XCTAssertNil(BackstopVersion.declared(in: "#!/bin/bash\nset -e\n"))
        XCTAssertNil(BackstopVersion.declared(in: "# insomnia-backstop-version: two\n"))
        XCTAssertNil(BackstopVersion.declared(in: "  # insomnia-backstop-version: 2\n"), "only a line that starts with the prefix counts")
    }

    func testAcceptsTheRequiredVersionAndNewer() throws {
        XCTAssertNoThrow(try BackstopVersion.check(scriptAt: script("#!/bin/bash\n# insomnia-backstop-version: 5\n")))
        XCTAssertNoThrow(try BackstopVersion.check(scriptAt: script("#!/bin/bash\n# insomnia-backstop-version: 7\n")))
    }

    /// An older script (version 2 deletes the marker but does not settle
    /// a journaled start from its receipt; version 3 reads the 45-byte
    /// receipt without its lock or the start's claim; version 4 gives the
    /// claim back before it publishes the settlement and refuses a settled
    /// record), one with no version line (every backstop.sh before the
    /// marker) and a missing one all say to run install.sh again.
    func testRefusesOlderMissingAndUnreadableScripts() throws {
        for text in ["#!/bin/bash\n# insomnia-backstop-version: 1\n", "#!/bin/bash\n# insomnia-backstop-version: 2\n", "#!/bin/bash\n# insomnia-backstop-version: 3\n", "#!/bin/bash\n# insomnia-backstop-version: 4\n", "#!/bin/bash\nPMSET=/usr/bin/pmset\n"] {
            let url = try script(text)
            XCTAssertThrowsError(try BackstopVersion.check(scriptAt: url)) { error in
                let message = error.localizedDescription
                XCTAssertTrue(message.contains(url.path), message)
                XCTAssertTrue(message.contains("older than this build"), message)
                XCTAssertTrue(message.hasSuffix("run scripts/install.sh again"), message)
            }
        }
        let missing = dir.appendingPathComponent("nothing-here.sh")
        XCTAssertThrowsError(try BackstopVersion.check(scriptAt: missing)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("could not read backstop.sh at \(missing.path)"), message)
            XCTAssertTrue(message.hasSuffix("run scripts/install.sh again"), message)
        }
    }

    /// The launchd scheduler checks the script its agent runs: the copy
    /// sealed in the bundle it pins.
    func testLaunchdBackstopChecksTheScriptItsAgentRuns() throws {
        let home = TempHome()
        defer { home.destroy() }
        let bundle = home.paths.appBundle
        let script = Paths.backstopScript(inBundle: bundle)
        let backstop = LaunchdBackstop(paths: home.paths, bundle: bundle, run: { _, _ in ShellResult(status: 0, stdout: "", stderr: "") })
        XCTAssertEqual(backstop.scriptPath, script.path)
        XCTAssertThrowsError(try backstop.checkVoidsPrompts())
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\n# insomnia-backstop-version: 1\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try backstop.checkVoidsPrompts())
        try FileManager.default.removeItem(at: script)
        try FileManager.default.copyItem(at: repoBackstop, to: script)
        XCTAssertNoThrow(try backstop.checkVoidsPrompts())
    }
}
