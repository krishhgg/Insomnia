import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// `Insomnia --agent-cutoffs`: the one-shot mode backstop.sh runs to read
/// config.json with the app's decoder. The mapping is tested in process
/// with injected input; the built binary is run with its input in a file or
/// an open pipe, in a temp INSOMNIA_HOME and HOME that it must leave empty.
final class AgentCutoffsCommandTests: XCTestCase {
    /// Runs the mode in process with `input`. The lifetime is recorded,
    /// never armed: an alarm would end the test runner.
    private func run(_ arguments: [String], input: Data?, armed: Locked<[UInt32]> = Locked([])) -> ResumeFrozenCommand.Output? {
        AgentCutoffsCommand.run(arguments, input: { input }, endAfter: { armed.value.append($0) })
    }

    /// Other command lines are not this mode, and standard input is not
    /// read for them.
    func testOtherCommandLinesAreNotThisMode() {
        let read = Locked(0)
        let armed = Locked<[UInt32]>([])
        let input: () -> Data? = { read.value += 1; return Data("{}".utf8) }
        let arm: (UInt32) -> Void = { armed.value.append($0) }
        for arguments in [[], ["--resume-frozen", "30"], ["30", "--agent-cutoffs"], ["-NSDocumentRevisionsDebugMode", "YES"]] {
            XCTAssertNil(AgentCutoffsCommand.run(arguments, input: input, endAfter: arm), "\(arguments)")
        }
        XCTAssertEqual(read.value, 0)
        XCTAssertEqual(armed.value, [], "the menu bar app must never get a lifetime")
    }

    /// A missing or malformed lifetime, or any argument after it, answers
    /// "usage" with EX_USAGE before standard input is read.
    func testBadArgumentsAreAUsageErrorBeforeAnythingIsRead() {
        for arguments in [["--agent-cutoffs"], ["--agent-cutoffs", "0"], ["--agent-cutoffs", "301"], ["--agent-cutoffs", "x"],
                          ["--agent-cutoffs", "-5"], ["--agent-cutoffs", "0030"], ["--agent-cutoffs", "30", "30"]] {
            let read = Locked(0)
            let armed = Locked<[UInt32]>([])
            let out = AgentCutoffsCommand.run(arguments, input: { read.value += 1; return Data("{}".utf8) }, endAfter: { armed.value.append($0) })
            XCTAssertEqual(out, .init(lines: ["usage"], status: AgentCutoffsCommand.usageStatus), "\(arguments)")
            XCTAssertEqual(read.value, 0, "\(arguments)")
            XCTAssertEqual(armed.value, [], "\(arguments)")
        }
    }

    /// The lifetime is armed before standard input is read, so a caller
    /// that never closes it cannot keep the process waiting.
    func testTheLifetimeIsArmedBeforeStandardInputIsRead() {
        let order = Locked<[String]>([])
        let out = AgentCutoffsCommand.run(["--agent-cutoffs", "33"],
                                          input: { order.value.append("read"); return Data("{}".utf8) },
                                          endAfter: { order.value.append("armed \($0)") })
        XCTAssertEqual(order.value, ["armed 33", "read"])
        XCTAssertEqual(out, .init(lines: ["cutoffs 10 true"], status: 0))
    }

    func testInputThatCannotBeReadIsUnreadable() {
        XCTAssertEqual(run(["--agent-cutoffs", "5"], input: nil), .init(lines: ["unreadable"], status: AgentCutoffsCommand.unreadableStatus))
    }

    /// The answer is `Store.decodeConfig` on the same bytes, as
    /// `Store.loadConfig` reads the file: the first of two duplicate keys,
    /// escaped key names, numbers the decoder rounds, and any field's
    /// error rejecting the whole file.
    func testTheAnswerIsTheAppsDecoding() throws {
        let cases: [(text: String, answer: String)] = [
            (#"{"endFloor":30,"thermalRules":false}"#, "cutoffs 30 false"),
            (#"{"endFloor":95,"endFloor":0,"thermalRules":false}"#, "cutoffs 95 false"),
            (#"{"endFloor":0,"endFloor":95,"thermalRules":false}"#, "cutoffs 0 false"),
            (#"{"end\u0046loor":95,"endFloor":0}"#, "cutoffs 95 true"),
            (#"{"endFloor":95,"end\u0046loor":0}"#, "cutoffs 95 true"),
            (#"{"thermal\u0052ules":false,"thermalRules":true}"#, "cutoffs 10 false"),
            (#"{"thermalRules":true,"thermalRules":false}"#, "cutoffs 10 true"),
            (#"{"thermalRules":false,"thermalRules":true}"#, "cutoffs 10 false"),
            (#"{"endFloor":1e-400}"#, "cutoffs 0 true"),
            (#"{"endFloor":4.9999999999999999}"#, "cutoffs 5 true"),
            (#"{"endFloor":9223372036854775807}"#, "cutoffs 95 true"),
            (#"{"endFloor":-9223372036854775808}"#, "cutoffs 0 true"),
            ("{}", "cutoffs 10 true"),
            (" \n{ \"endFloor\" : 20 }\n", "cutoffs 20 true"),
            (#"{"endFloor":0,"thermalRules":false,"lowPowerFloor":"bad"}"#, "rejected"),
            (#"{"endFloor":0,"thermalRules":false,"presets":["bad"]}"#, "rejected"),
            (#"{"endFloor":0,"thermalRules":false,"lowPowerFloor":-9223372036854775809}"#, "rejected"),
            (#"{"endFloor":-9223372036854775809}"#, "rejected"),
            (#"{"endFloor":30.5}"#, "rejected"),
            (#"{"endFloor":"30"}"#, "rejected"),
            (#"{"endFloor":+30}"#, "rejected"),
            (#"{"thermalRules":"false"}"#, "rejected"),
            (#"{"endFloor":30} trailing"#, "rejected"),
            (#"["endFloor",30]"#, "rejected"),
            ("", "rejected"),
            ("not json", "rejected"),
            (#"<?xml version="1.0"?><plist version="1.0"><dict><key>endFloor</key><integer>0</integer></dict></plist>"#, "rejected"),
        ]
        let home = TempHome()
        defer { home.destroy() }
        try home.paths.createDirectories()
        let store = Store(paths: home.paths)
        for (text, answer) in cases {
            let data = Data(text.utf8)
            let out = AgentCutoffsCommand.answer(for: data)
            XCTAssertEqual(out.lines, [answer], text)
            XCTAssertEqual(out.status, answer == "rejected" ? AgentCutoffsCommand.rejectedStatus : 0, text)
            try data.write(to: home.paths.configFile)
            let app = try? store.loadConfig()?.agentCutoffs
            XCTAssertEqual(app.map { "cutoffs \($0.endFloor) \($0.thermalRules)" } ?? "rejected", answer, "Store.loadConfig on \(text)")
        }
    }

    // MARK: The built binary

    private var builtBinary: URL { BuiltApp.binary }

    /// Runs the built binary with `arguments` and `input` in a file on
    /// standard input, HOME and INSOMNIA_HOME in a temp dir, and output and
    /// error in files. Returns what it printed and the names it left in
    /// that temp dir besides the three files.
    private func runBinary(_ arguments: [String], input: Data) throws -> (status: Int32, stdout: String, stderr: String, left: [String]) {
        guard FileManager.default.isExecutableFile(atPath: builtBinary.path) else {
            throw XCTSkip("no built Insomnia executable at \(builtBinary.path)")
        }
        let home = TempHome()
        defer { home.destroy() }
        let io = FileManager.default.temporaryDirectory.appendingPathComponent("insomnia-tests-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: io, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: io) }
        let inURL = io.appendingPathComponent("stdin")
        let outURL = io.appendingPathComponent("stdout")
        let errURL = io.appendingPathComponent("stderr")
        try input.write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: inURL)
        let stdout = try FileHandle(forWritingTo: outURL)
        let stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let before = try FileManager.default.contentsOfDirectory(atPath: home.root.path)
        let p = Process()
        p.executableURL = builtBinary
        p.arguments = arguments
        p.environment = ["INSOMNIA_HOME": home.root.path, "HOME": home.root.path, "PATH": "/usr/bin:/bin"]
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        let after = try FileManager.default.contentsOfDirectory(atPath: home.root.path)
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "",
                after.filter { !before.contains($0) }.sorted())
    }

    /// The real binary answers before AppKit starts, prints one line, and
    /// writes no file: no config.json, no log, no lock in its home.
    func testBuiltBinaryAnswersWithoutStartingTheAppOrWritingAFile() throws {
        let cases: [(input: String, line: String, status: Int32)] = [
            (#"{"endFloor":95,"endFloor":0,"thermalRules":false}"#, "cutoffs 95 false", 0),
            (#"{"endFloor":4.9999999999999999}"#, "cutoffs 5 true", 0),
            (#"{"endFloor":0,"lowPowerFloor":"bad"}"#, "rejected", AgentCutoffsCommand.rejectedStatus),
        ]
        for c in cases {
            let r = try runBinary(["--agent-cutoffs", "30"], input: Data(c.input.utf8))
            XCTAssertEqual(r.status, c.status, c.input)
            XCTAssertEqual(r.stdout, c.line + "\n", c.input)
            XCTAssertEqual(r.stderr, "", c.input)
            XCTAssertEqual(r.left, [], c.input)
        }
        let usage = try runBinary(["--agent-cutoffs"], input: Data("{}".utf8))
        XCTAssertEqual(usage.status, AgentCutoffsCommand.usageStatus)
        XCTAssertEqual(usage.stdout, "usage\n")
        XCTAssertTrue(usage.stderr.hasPrefix("usage: Insomnia --agent-cutoffs"), usage.stderr)
        XCTAssertEqual(usage.left, [])
    }

    /// Standard input up to `maxInputBytes` is read whole; one byte more is
    /// unreadable, whatever it holds.
    func testBuiltBinaryReadsUpToTheLimitAndNoMore() throws {
        let object = Data(#"{"endFloor":20}"#.utf8)
        let padded = Data(repeating: UInt8(ascii: " "), count: AgentCutoffsCommand.maxInputBytes - object.count) + object
        let whole = try runBinary(["--agent-cutoffs", "30"], input: padded)
        XCTAssertEqual(whole.stdout, "cutoffs 20 true\n")
        XCTAssertEqual(whole.status, 0)
        let over = try runBinary(["--agent-cutoffs", "30"], input: Data(" ".utf8) + padded)
        XCTAssertEqual(over.stdout, "unreadable\n")
        XCTAssertEqual(over.status, AgentCutoffsCommand.unreadableStatus)
    }

    /// The built binary ends itself with SIGALRM once its lifetime is up,
    /// here 1 s while it waits for standard input that never ends. The test
    /// sends no signal: a binary that did not end gets end of input when
    /// the test closes the pipe after 15 s, answers, and fails the SIGALRM
    /// assertion.
    func testBuiltBinaryEndsItselfWhenItsLifetimeIsUp() throws {
        guard FileManager.default.isExecutableFile(atPath: builtBinary.path) else {
            throw XCTSkip("no built Insomnia executable at \(builtBinary.path)")
        }
        let home = TempHome()
        defer { home.destroy() }
        let pipe = Pipe()
        let p = Process()
        p.executableURL = builtBinary
        p.arguments = ["--agent-cutoffs", "1"]
        p.environment = ["INSOMNIA_HOME": home.root.path, "HOME": home.root.path, "PATH": "/usr/bin:/bin"]
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        let start = Date()
        try p.run()
        try pipe.fileHandleForWriting.write(contentsOf: Data(#"{"endFloor":"#.utf8))
        let ended = exited.wait(timeout: .now() + 15) == .success
        let seconds = Date().timeIntervalSince(start)
        if !ended {
            try? pipe.fileHandleForWriting.close()
            exited.wait()
        }
        XCTAssertTrue(ended, "still running after 15 s")
        XCTAssertEqual(p.terminationReason, .uncaughtSignal)
        XCTAssertEqual(p.terminationStatus, SIGALRM)
        XCTAssertGreaterThan(seconds, 0.5, "ended before its lifetime")
    }

    // MARK: The interface version

    /// The --agent-cutoffs interface version is the same in the binary, in
    /// the bundle's Info.plist, and in backstop.sh, which runs the binary
    /// only when the installed bundle declares it.
    func testTheAgentCutoffsVersionIsTheSameEverywhere() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scripts = root.appendingPathComponent("scripts")
        let info = root.appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        XCTAssertEqual(plist["InsomniaAgentCutoffsVersion"] as? Int, AgentCutoffsCommand.version)
        let text = try String(contentsOf: scripts.appendingPathComponent("backstop.sh"), encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("AGENT_CUTOFFS_VERSION=") }
        XCTAssertEqual(lines, ["AGENT_CUTOFFS_VERSION=\(AgentCutoffsCommand.version)"])
    }
}
