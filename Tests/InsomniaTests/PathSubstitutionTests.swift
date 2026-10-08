import Foundation
import XCTest
@testable import Insomnia

/// A PATH whose cat, grep, head, tr, iconv, id, stat, awk, basename and
/// dirname are stand-ins, for the tests that show the recovery scripts take
/// every tool that reads state from its fixed path (CAT, GREP, HEAD, TR,
/// ICONV, ID, STAT, AWK), never from PATH, and that neither script names a
/// folder with basename or dirname (uninstall.sh finds its own folder by
/// parameter expansion; install.sh, which still runs dirname, is not run
/// here). iconv runs only on a journal in UTF-16, which these tests do not
/// write. A stand-in called by a process whose
/// command line holds one of `scripts` (a recovery script, or a subshell of
/// one) logs the call and answers with something that would change the
/// run: a 0% end floor from the app's binary, a full battery, a file that
/// is not JSON, uid 0. Called by anything else (a test's fake sudo), it
/// runs the real tool.
enum PathSubstitutes {
    static let tools: [(name: String, real: String, answer: String)] = [
        ("cat", "/bin/cat", "printf 'cutoffs 0 false\\n'"),
        ("grep", "/usr/bin/grep", #"printf ' -InternalBattery-0 (id=1)\t100%%; charged; 0:00 remaining present: true\n'"#),
        ("head", "/usr/bin/head", "printf x"),
        ("tr", "/usr/bin/tr", ":"),
        ("iconv", "/usr/bin/iconv", "printf '{}'"),
        ("id", "/usr/bin/id", "echo 0"),
        ("stat", "/usr/bin/stat", "echo 0"),
        ("awk", "/usr/bin/awk", ":"),
        ("basename", "/usr/bin/basename", "echo Insomnia.app"),
        ("dirname", "/usr/bin/dirname", "echo /"),
    ]

    /// Writes the stand-ins in `dir` and returns the PATH that puts them
    /// first. Each call a script makes is a line in `log`.
    static func path(in dir: URL, log: URL, scripts: [String]) throws -> String {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let callers = scripts.map { "*'\($0)'*" }.joined(separator: "|")
        for tool in tools {
            let url = dir.appendingPathComponent(tool.name)
            try """
            #!/bin/bash
            case "$(/bin/ps -o command= -p "$PPID" 2>/dev/null)" in
              \(callers))
                printf '%s %s\\n' \(tool.name) "$*" >> '\(log.path)'
                \(tool.answer)
                exit 0 ;;
            esac
            exec \(tool.real) "$@"

            """.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return "\(dir.path):/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// The calls the scripts made to a stand-in.
    static func calls(in log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

/// Greptile 4219151895, backstop.sh's side (RecoveryScriptTests runs
/// uninstall.sh's): the agent, run on twin homes with the usual PATH (the
/// control) and with PathSubstitutes first in PATH, ends the same session
/// the same way, and calls no stand-in.
@MainActor
final class PathSubstitutionTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws {
        h = Harness()
        try h.home.paths.createDirectories()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    /// A session at 25% on battery power with a 30% end floor, the app
    /// alive: the agent reads session.json, the cutoffs through the app's
    /// binary (whose answer it reads back from a file), the battery from
    /// pmset and the journal, then ends the session. A script that took cat,
    /// grep or head from PATH here would read a 0% floor or a full battery
    /// and keep the session, or find session.json or the journal not JSON.
    func testTheAgentTakesNoToolFromPath() async throws {
        let config = Data(#"{"endFloor":30,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#.utf8)
        let control = try SeparateRun(in: h, name: "control", config: config, battery: 25)
        let twin = try SeparateRun(in: h, name: "twin", config: config, battery: 25)
        let log = h.home.root.appendingPathComponent("substitutes.log")
        let path = try PathSubstitutes.path(in: h.home.root.appendingPathComponent("substitutes", isDirectory: true), log: log,
                                            scripts: [twin.agent.script.path])

        let controlStatus = try await control.agent.run()
        let status = try await twin.agent.run(path: path)
        control.alive.release()
        twin.alive.release()

        XCTAssertEqual(PathSubstitutes.calls(in: log), [], "the agent called a tool from PATH")
        XCTAssertEqual(controlStatus, 0, control.log)
        XCTAssertEqual(status, 0, twin.log)
        XCTAssertNil(try Store(paths: control.paths).loadSession(), control.log)
        XCTAssertNil(try Store(paths: twin.paths).loadSession(), twin.log)
        XCTAssertTrue(control.log.contains("below the 30% end floor"), control.log)
        XCTAssertTrue(twin.log.contains("below the 30% end floor"), twin.log)
        let calls = { (run: SeparateRun) in run.agent.calls.map { $0.replacingOccurrences(of: run.agent.dir.path, with: "<agent>") } }
        XCTAssertEqual(calls(twin), calls(control))
        XCTAssertTrue(control.agent.calls.contains(control.agent.restoreCall), control.agent.calls.joined(separator: "\n"))
        XCTAssertEqual(try Store(paths: twin.paths).loadState(), try Store(paths: control.paths).loadState())
    }
}
