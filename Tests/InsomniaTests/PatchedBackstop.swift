import Foundation
@testable import Insomnia

/// A copy of backstop.sh whose tools are fakes in `dir`, for tests that run
/// the real agent beside a SessionManager on the same INSOMNIA_HOME: pmset
/// reports an internal battery on battery power at 25% or the level set
/// with `setBattery`, notifyutil the thermal pressure level set with
/// `setThermal`, sudo succeeds. Each call is recorded in dir/calls, and
/// each sudo call also copies state.json as it was at that moment to
/// dir/state-at-sudo (removed when there is none) and lists the names in
/// INSOMNIA_HOME to dir/names-at-sudo and in its Logs folder to
/// dir/logs-at-sudo. The app binary is the one this build made, for
/// `--agent-cutoffs` and `--agent-session-cutoffs` only (`BuiltApp`),
/// unrecorded, so config.json and the journal's cutoffs are read by the
/// app's own decoder as in production; its Info.plist declares those modes
/// and not `--resume-frozen`.
struct PatchedBackstop {
    let dir: URL
    let script: URL
    let home: URL

    struct PatchError: Error, CustomStringConvertible {
        let constant: String
        let hits: Int
        var description: String { "backstop.sh has \(hits) lines setting \(constant), not one" }
    }

    init(home: URL, dir: URL) throws {
        self.home = home
        self.dir = dir
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let calls = dir.appendingPathComponent("calls").path
        let thermal = dir.appendingPathComponent("thermal").path
        let battery = dir.appendingPathComponent("battery").path
        let stateAtSudo = dir.appendingPathComponent("state-at-sudo").path
        let namesAtSudo = dir.appendingPathComponent("names-at-sudo").path
        let logsAtSudo = dir.appendingPathComponent("logs-at-sudo").path
        let state = home.appendingPathComponent("state.json").path
        try "0".write(toFile: thermal, atomically: true, encoding: .utf8)
        try "25".write(toFile: battery, atomically: true, encoding: .utf8)
        let fakes: [String: String] = [
            "PMSET": #"""
            printf 'pmset %s\n' "$*" >> '\#(calls)'
            [[ "$*" == "-g batt" ]] || exit 99
            printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4567)\t%s%%; discharging; 1:00 remaining present: true\n" "$(/bin/cat '\#(battery)')"
            """#,
            "NOTIFYUTIL": #"""
            printf 'notifyutil %s\n' "$*" >> '\#(calls)'
            printf 'com.apple.system.thermalpressurelevel %s\n' "$(/bin/cat '\#(thermal)')"
            """#,
            "SUDO": #"""
            printf 'sudo %s\n' "$*" >> '\#(calls)'
            /bin/cp '\#(state)' '\#(stateAtSudo)' 2>/dev/null || /bin/rm -f '\#(stateAtSudo)'
            /bin/ls -a '\#(home.path)' > '\#(namesAtSudo)'
            /bin/ls -a '\#(home.path)/Logs' > '\#(logsAtSudo)' 2>/dev/null || : > '\#(logsAtSudo)'
            """#,
            "IOREG": "exit 0",
            "PS": "exit 1",
            "SYSCTL": "echo fake-boot",
            "KILL": #"printf 'kill %s\n' "$*" >> '\#(calls)'; exit 1"#,
            "DEFAULTS": #"printf 'defaults %s\n' "$*" >> '\#(calls)'; exit 1"#,
            "INSOMNIA_BIN": #"""
            [[ "${1:-}" == --agent-cutoffs || "${1:-}" == --agent-session-cutoffs ]] && exec '\#(BuiltApp.binary.path)' "$@"
            exit 1
            """#,
        ]
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/backstop.sh")
        var lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
        var constants = [String: String]()
        for (name, body) in fakes {
            let fake = dir.appendingPathComponent(name.lowercased())
            try "#!/bin/bash\n\(body)\n".write(to: fake, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
            constants[name] = fake.path
        }
        let info = dir.appendingPathComponent("Info.plist")
        try BuiltApp.infoPlist(agentCutoffsVersion: "\(AgentCutoffsCommand.version)").write(to: info, atomically: true, encoding: .utf8)
        constants["INSOMNIA_INFO"] = info.path
        for (name, value) in constants {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            guard hits.count == 1 else { throw PatchError(constant: name, hits: hits.count) }
            lines[hits[0]] = "\(name)='\(value)'"
        }
        script = dir.appendingPathComponent("backstop.sh")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
    }

    func setThermal(_ level: Int) throws {
        try "\(level)".write(to: dir.appendingPathComponent("thermal"), atomically: true, encoding: .utf8)
    }

    func setBattery(_ percent: Int) throws {
        try "\(percent)".write(to: dir.appendingPathComponent("battery"), atomically: true, encoding: .utf8)
    }

    /// One run, as launchd starts it, or with another PATH. Returns its
    /// exit status. The fakes call every tool by its full path.
    func run(path: String = "/usr/bin:/bin:/usr/sbin:/sbin") async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["PATH": path, "INSOMNIA_HOME": home.path, "HOME": home.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let exit = ProcessExit(p)
        try p.run()
        await exit.exited()
        return p.terminationStatus
    }

    /// Runs each agent once, at most `width` at a time, and returns their
    /// exit statuses in order. The agents must act on separate homes. Every
    /// run that started is waited for, also when another fails to start:
    /// the group waits for its tasks before it throws.
    static func runAll(_ agents: [PatchedBackstop], width: Int = 8) async throws -> [Int32] {
        var statuses = [Int32](repeating: -1, count: agents.count)
        try await withThrowingTaskGroup(of: (Int, Int32).self) { group in
            var next = 0
            func add() {
                guard next < agents.count else { return }
                let (i, agent) = (next, agents[next])
                group.addTask { (i, try await agent.run()) }
                next += 1
            }
            for _ in 0..<width { add() }
            while let (i, status) = try await group.next() {
                statuses[i] = status
                add()
            }
        }
        return statuses
    }

    func clearCalls() {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("calls"))
    }

    var calls: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Makes every sudo call fail (exit 1) after it is recorded: the
    /// restore does not happen.
    func failSudo() throws {
        let sudo = dir.appendingPathComponent("sudo")
        try (String(contentsOf: sudo, encoding: .utf8) + "exit 1\n").write(to: sudo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sudo.path)
    }

    /// Points MKTEMP at /usr/bin/false, so the agent cannot create the
    /// record aside (ended-session.json.<8 letters or digits>). In a folder
    /// that really takes no new file the agent's status files fail too;
    /// RecoveryScriptTests runs that case.
    func refuseRecordsAside() throws {
        try patch("MKTEMP=/usr/bin/mktemp", "MKTEMP=/usr/bin/false")
    }

    /// Sets LOCK_RECORD_MAX_BYTES to 0, so no record fits in the recovery
    /// lock file and the agent writes none there: a stand-in for a lock
    /// file that refuses the write (a full disk). Content already in the
    /// file then reads as more than any record, which ends no session.
    func refuseLockRecord() throws {
        try patch("LOCK_RECORD_MAX_BYTES=1048576", "LOCK_RECORD_MAX_BYTES=0")
    }

    /// Points CAT at a fake that fails on the recovery lock file and runs
    /// /bin/cat on anything else, so the agent cannot read the lock file
    /// back after it writes a record there, and reads session.json and its
    /// other files as usual.
    func failLockReadBack() throws {
        let cat = dir.appendingPathComponent("cat")
        try #"""
        #!/bin/bash
        [[ "${1:-}" == */.recovery.lock ]] && exit 1
        exec /bin/cat "$@"

        """#.write(to: cat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cat.path)
        try patch("CAT=/bin/cat", "CAT='\(cat.path)'")
    }

    /// Sets LOG_RECORD_MAX_BYTES to 0, so no session.json fits in an end
    /// record in insomnia.log: the agent writes none there and reads none
    /// back, a stand-in for a log that refuses the line (a full disk).
    func refuseLogRecord() throws {
        try patch("LOG_RECORD_MAX_BYTES=65536", "LOG_RECORD_MAX_BYTES=0")
    }

    /// Points GREP at a fake that finds no end record line in a log (exit
    /// 1 for `-Fxq -e insomnia-ended-session-v1 ...`) and runs /usr/bin/grep
    /// on anything else: the agent's line goes into insomnia.log, but
    /// neither the read-back nor a later run finds it.
    func failLogReadBack() throws {
        let grep = dir.appendingPathComponent("grep")
        try #"""
        #!/bin/bash
        [[ "${1:-}" == -Fxq && "${2:-}" == -e && "${3:-}" == "insomnia-ended-session-v1 "* ]] && exit 1
        exec /usr/bin/grep "$@"

        """#.write(to: grep, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grep.path)
        try patch("GREP=/usr/bin/grep", "GREP='\(grep.path)'")
    }

    private func patch(_ line: String, _ replacement: String) throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        let hits = text.components(separatedBy: "\n").filter { $0 == line }.count
        guard hits == 1 else { throw PatchError(constant: String(line.prefix { $0 != "=" }), hits: hits) }
        try text.replacingOccurrences(of: "\n\(line)\n", with: "\n\(replacement)\n").write(to: script, atomically: true, encoding: .utf8)
    }

    /// The call that restores sleep.
    var restoreCall: String { "sudo -n \(dir.appendingPathComponent("pmset").path) -a disablesleep 0" }

    /// state.json as the last sudo call found it, or nil when there was none.
    var stateAtSudo: Data? { try? Data(contentsOf: dir.appendingPathComponent("state-at-sudo")) }

    /// The names in INSOMNIA_HOME as the last sudo call found them.
    var namesAtSudo: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("names-at-sudo"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The names in INSOMNIA_HOME/Logs as the last sudo call found them.
    var logsAtSudo: [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("logs-at-sudo"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Makes the app binary unusable for the agent: its Info.plist then
    /// declares no `--agent-cutoffs` version, so the binary is not run.
    func withdrawAgentCutoffs() throws {
        try BuiltApp.infoPlist(agentCutoffsVersion: nil).write(to: dir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    /// The app binary the agent runs (INSOMNIA_BIN).
    var appBinary: URL { dir.appendingPathComponent("insomnia_bin") }

    /// Replaces the app binary with a script running `body`.
    func replaceAppBinary(with body: String) throws {
        try "#!/bin/bash\n\(body)\n".write(to: appBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appBinary.path)
    }

    /// Sets COMMAND_TIMEOUT_SECONDS, the limit on each read, in this copy.
    func setCommandTimeout(_ seconds: Int) throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = "COMMAND_TIMEOUT_SECONDS=30"
        guard text.components(separatedBy: "\n").filter({ $0 == line }).count == 1 else { throw PatchError(constant: "COMMAND_TIMEOUT_SECONDS", hits: 0) }
        try text.replacingOccurrences(of: "\n\(line)\n", with: "\nCOMMAND_TIMEOUT_SECONDS=\(seconds)\n").write(to: script, atomically: true, encoding: .utf8)
    }
}
