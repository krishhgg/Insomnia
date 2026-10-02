import Foundation
import XCTest
@testable import Insomnia

/// scripts/check-lid-simulation-gate.sh with `swift`, `nm` and `strings`
/// replaced by stubs, so each case decides what the two "binaries" hold and
/// whether they can be read. Nothing is built.
final class LidSimulationGateScriptTests: XCTestCase {
    private static var repoRoot: URL {
        // .../Tests/InsomniaTests/LidSimulationGateScriptTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private let fm = FileManager.default
    private var root: URL!
    private var plain: URL { root.appendingPathComponent("plain", isDirectory: true) }
    private var sim: URL { root.appendingPathComponent("sim", isDirectory: true) }

    private static let watcherSymbol = "0000000100012340 T _$s8Insomnia13LidSimulationC5startyyF"
    private static let otherSymbol = "0000000100001000 T _$s8Insomnia14SessionManagerC5startyyF"
    private static let watcherStrings = "lid SIMULATED: closed\nLid simulation build: lid events come from a file"
    private static let otherStrings = "launched\nRestore incomplete"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("lid-gate-\(UUID().uuidString)", isDirectory: true)
        let scripts = root.appendingPathComponent("scripts", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for dir in [scripts, bin, plain, sim] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.copyItem(at: Self.repoRoot.appendingPathComponent("scripts/check-lid-simulation-gate.sh"),
                        to: scripts.appendingPathComponent("check-lid-simulation-gate.sh"))
        // `swift build` succeeds without building; --show-bin-path names the
        // plain directory, or the sim one for the opt-in scratch path.
        try stub("swift", """
            for a in "$@"; do [[ $a == --scratch-path ]] && dir=\(sim.path); done
            for a in "$@"; do [[ $a == --show-bin-path ]] && echo "${dir:-\(plain.path)}"; done
            exit 0
            """)
        // nm and strings print the binary's directory's <tool>.out, or fail
        // when <tool>.fail is there.
        for tool in ["nm", "strings"] {
            try stub(tool, """
                d=$(dirname "$1")
                if [[ -e $d/\(tool).fail ]]; then echo "\(tool): can't read $1" >&2; exit 1; fi
                cat "$d/\(tool).out"
                """)
        }
        for dir in [plain, sim] {
            try Data().write(to: dir.appendingPathComponent("Insomnia"))
        }
        try write(plain, nm: Self.otherSymbol, strings: Self.otherStrings)
        try write(sim, nm: Self.otherSymbol + "\n" + Self.watcherSymbol, strings: Self.otherStrings + "\n" + Self.watcherStrings)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    func testPassesWhenOnlyTheOptInBuildHasTheWatcher() throws {
        let r = try runGate()

        XCTAssertEqual(r.status, 0, r.stdout + r.stderr)
        XCTAssertTrue(r.stdout.contains("plain release build (\(plain.path)/Insomnia): 0 symbol(s) of the watcher class"), r.stdout)
        XCTAssertTrue(r.stdout.contains("INSOMNIA_LID_SIMULATION build (\(sim.path)/Insomnia): 1 symbol(s) of the watcher class"), r.stdout)
        XCTAssertTrue(r.stdout.contains("compiled out of the plain release build"), r.stdout)
    }

    func testFailsWhenThePlainBuildHasTheWatcher() throws {
        try write(plain, nm: Self.watcherSymbol, strings: Self.otherStrings)

        let r = try runGate()

        XCTAssertNotEqual(r.status, 0, r.stdout + r.stderr)
        XCTAssertTrue(r.stderr.contains("expected the lid simulation to be absent"), r.stderr)
        XCTAssertFalse(r.stdout.contains("compiled out of the plain release build"), r.stdout)
    }

    /// A plain binary that nm or strings cannot read, or reads as nothing,
    /// was never inspected, so it must not pass as "compiled out".
    func testAPlainBinaryThatCannotBeReadFailsTheGate() throws {
        let cases: [(name: String, setUp: () throws -> Void, message: String)] = [
            ("nm fails", { try Data().write(to: self.plain.appendingPathComponent("nm.fail")) }, "nm could not read the binary"),
            ("strings fails", { try Data().write(to: self.plain.appendingPathComponent("strings.fail")) }, "strings could not read the binary"),
            ("nm prints nothing", { try self.write(self.plain, nm: "", strings: Self.otherStrings) }, "nm could not read the binary"),
            ("strings prints nothing", { try self.write(self.plain, nm: Self.otherSymbol, strings: "") }, "strings could not read the binary"),
        ]
        for c in cases {
            try tearDownWithError()
            try setUpWithError()
            try c.setUp()

            let r = try runGate()

            XCTAssertNotEqual(r.status, 0, "\(c.name): " + r.stdout + r.stderr)
            XCTAssertTrue(r.stderr.contains("plain release build (\(plain.path)/Insomnia): \(c.message)"), "\(c.name): " + r.stderr)
            XCTAssertFalse(r.stdout.contains("plain release build (\(plain.path)/Insomnia): 0 "), "\(c.name): " + r.stdout)
            XCTAssertFalse(r.stdout.contains("compiled out of the plain release build"), "\(c.name): " + r.stdout)
        }
    }

    // MARK: - Fixture

    private func write(_ dir: URL, nm: String, strings: String) throws {
        try nm.write(to: dir.appendingPathComponent("nm.out"), atomically: true, encoding: .utf8)
        try strings.write(to: dir.appendingPathComponent("strings.out"), atomically: true, encoding: .utf8)
    }

    private func stub(_ name: String, _ body: String) throws {
        let url = root.appendingPathComponent("bin/\(name)")
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runGate() throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [root.appendingPathComponent("scripts/check-lid-simulation-gate.sh").path]
        let bin = root.appendingPathComponent("bin").path
        p.environment = ["PATH": "\(bin):/usr/bin:/bin", "SWIFT": "\(bin)/swift", "TMPDIR": NSTemporaryDirectory()]
        // Capture to files rather than pipes: nothing to drain, nothing to deadlock.
        let outURL = root.appendingPathComponent("stdout")
        let errURL = root.appendingPathComponent("stderr")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        p.standardOutput = out
        p.standardError = err
        let childExit = ProcessExit(p)
        try p.run()
        childExit.wait()
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }
}
