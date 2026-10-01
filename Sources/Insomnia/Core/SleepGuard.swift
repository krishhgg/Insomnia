import Foundation

/// The only things Insomnia ever does as root. Turning sleep off goes
/// through the administrator password dialog (see AdministratorPrompt);
/// everything else goes through the three passwordless pmset lines
/// install.sh writes to sudoers, none of which can keep the Mac awake.
protocol SleepGuarding: Sendable {
    /// `true` shows the administrator password dialog and waits for it;
    /// only an explicit Start by the user may call it. `false` never
    /// prompts, so a crashed or stuck session can always be ended.
    func setSleepDisabled(_ disabled: Bool) async throws
    func isSleepDisabled() async throws -> Bool
    func setLowPowerMode(_ on: Bool) async throws
    /// Battery Low Power Mode as pmset reports it now. Throws when it cannot
    /// be read; callers must then not take ownership of the mode.
    func isLowPowerModeOn() async throws -> Bool
}

struct SleepGuardError: Error, LocalizedError, Sendable {
    let command: String
    let status: Int32
    let stderr: String

    var errorDescription: String? {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        var msg = "`\(command)` failed with status \(status)"
        if !detail.isEmpty { msg += ": \(detail)" }
        if detail.contains("password") || detail.contains("sudo") {
            msg += " (run scripts/install.sh to install /etc/sudoers.d/insomnia)"
        }
        return msg
    }
}

/// `sudo -n pmset …` for everything but `disablesleep 1`. `sudo -n` never
/// prompts; if the sudoers rule is missing the call fails fast with a
/// readable error instead of hanging on a password prompt. `disablesleep
/// 1` has no sudoers line and runs through `prompt` instead.
struct PmsetSleepGuard: SleepGuarding {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"
    /// pmset normally returns in well under a second; a hung powerd must not
    /// hang a quit or a lid action forever.
    static let timeout: TimeInterval = 20

    let prompt: any AdministratorPromptRunning

    init(prompt: any AdministratorPromptRunning = OsascriptAdministratorPrompt()) {
        self.prompt = prompt
    }

    func setSleepDisabled(_ disabled: Bool) async throws {
        if disabled {
            try await prompt.disableSleep()
        } else {
            try await sudoPmset(["-a", "disablesleep", "0"])
        }
    }

    func setLowPowerMode(_ on: Bool) async throws {
        try await sudoPmset(["-b", "lowpowermode", on ? "1" : "0"])
    }

    func isSleepDisabled() async throws -> Bool {
        let r = try await CancellableCommand().run(Self.pmset, ["-g"], timeout: Self.timeout)
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g", status: r.status, stderr: r.stderr)
        }
        return Self.parseSleepDisabled(r.stdout)
    }

    func isLowPowerModeOn() async throws -> Bool {
        let r = try await CancellableCommand().run(Self.pmset, ["-g", "custom"], timeout: Self.timeout)
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g custom", status: r.status, stderr: r.stderr)
        }
        guard let on = Self.parseLowPowerMode(r.stdout) else {
            throw SleepGuardError(command: "pmset -g custom", status: 0, stderr: "no lowpowermode line under Battery Power")
        }
        return on
    }

    /// True when `pmset -g` output has a line whose first token is
    /// `SleepDisabled` and whose value is `1`.
    static func parseSleepDisabled(_ output: String) -> Bool {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("SleepDisabled") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "SleepDisabled" else { continue }
            return parts[1] == "1"
        }
        return false
    }

    /// `lowpowermode` in the `Battery Power:` section of `pmset -g custom`
    /// (the one `pmset -b` writes). nil when the section or key is absent,
    /// as on a desktop, or when the value is anything but an explicit `0`
    /// or `1`: an unreadable value is not proof that the mode is off, and
    /// treating it as off would take over a preference the user may have set.
    static func parseLowPowerMode(_ output: String) -> Bool? {
        var inBattery = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                inBattery = line == "Battery Power:"
                continue
            }
            guard inBattery else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "lowpowermode" else { continue }
            switch parts[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    private func sudoPmset(_ args: [String]) async throws {
        let full = [Self.pmset] + args
        // CancellableCommand, not Shell.run(timeout:): it reports a child
        // that had to be stopped at the deadline as a timeout even if the
        // child exits 0 on SIGTERM, and a caller cancelled mid-flight kills
        // the child instead of leaving it running.
        let r = try await CancellableCommand().run(Self.sudo, ["-n"] + full, timeout: Self.timeout)
        guard r.succeeded else {
            throw SleepGuardError(command: "sudo -n \(full.joined(separator: " "))", status: r.status, stderr: r.stderr)
        }
    }
}
