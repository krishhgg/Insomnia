import Foundation
@testable import Insomnia

/// A copy of backstop.sh whose tools are fakes in `dir`, for tests that run
/// the real agent beside a SessionManager on the same INSOMNIA_HOME: pmset
/// reports an internal battery on battery power at 25% or the level set
/// with `setBattery`, notifyutil the thermal pressure level set with
/// `setThermal`, sudo succeeds. Each call is recorded in dir/calls, and
/// each sudo call also copies state.json as it was at that moment to
/// dir/state-at-sudo (removed when there is none) and lists the names in
/// INSOMNIA_HOME to dir/names-at-sudo.
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
        let state = home.appendingPathComponent("state.json").path
        try "0".write(toFile: thermal, atomically: true, encoding: .utf8)
        try "25".write(toFile: battery, atomically: true, encoding: .utf8)
        let fakes: [String: String] = [
            "PMSET": #"""
            printf 'pmset %s\n' "$*" >> '\#(calls)'
            [[ "$*" == "-g batt" ]] || exit 99
            printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4567)\t%s%%; discharging; 1:00 remaining present: true\n" "$(cat '\#(battery)')"
            """#,
            "NOTIFYUTIL": #"""
            printf 'notifyutil %s\n' "$*" >> '\#(calls)'
            printf 'com.apple.system.thermalpressurelevel %s\n' "$(cat '\#(thermal)')"
            """#,
            "SUDO": #"""
            printf 'sudo %s\n' "$*" >> '\#(calls)'
            /bin/cp '\#(state)' '\#(stateAtSudo)' 2>/dev/null || /bin/rm -f '\#(stateAtSudo)'
            /bin/ls -a '\#(home.path)' > '\#(namesAtSudo)'
            """#,
            "IOREG": "exit 0",
            "PS": "exit 1",
            "SYSCTL": "echo fake-boot",
            "KILL": #"printf 'kill %s\n' "$*" >> '\#(calls)'; exit 1"#,
            "DEFAULTS": #"printf 'defaults %s\n' "$*" >> '\#(calls)'; exit 1"#,
            "INSOMNIA_BIN": "exit 1",
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
        constants["INSOMNIA_INFO"] = dir.appendingPathComponent("no-Info.plist").path
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

    /// One run, as launchd starts it. Returns its exit status.
    func run() async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "INSOMNIA_HOME": home.path, "HOME": home.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let exit = ProcessExit(p)
        try p.run()
        await exit.exited()
        return p.terminationStatus
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
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = "MKTEMP=/usr/bin/mktemp"
        guard text.components(separatedBy: line).count == 2 else { throw PatchError(constant: "MKTEMP", hits: text.components(separatedBy: line).count - 1) }
        try text.replacingOccurrences(of: line, with: "MKTEMP=/usr/bin/false").write(to: script, atomically: true, encoding: .utf8)
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
}
