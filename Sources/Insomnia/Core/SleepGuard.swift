import Foundation

/// The only things Insomnia ever does as root. Turning sleep off goes
/// through the administrator password dialog (see AdministratorPrompt);
/// everything else goes through the three passwordless pmset lines
/// install.sh writes to sudoers, none of which can keep the Mac awake.
protocol SleepGuarding: Sendable {
    /// Proves, without prompting and without running pmset, that
    /// `enableSleep` needs no password. Start calls it before anything is
    /// written or shown: sleep may be turned off only while it can be
    /// turned back on with nobody at the keyboard. Throws
    /// `PasswordlessRestoreError` when that is not confirmed.
    func checkPasswordlessRestore() async throws
    /// Shows the administrator password dialog and waits for it; only an
    /// explicit Start by the user may call it, after writing `start`'s
    /// marker. Sleep is turned off only while that marker holds its nonce.
    /// The wait is bounded: an `AdministratorPromptError.stillRunning` means
    /// the dialog's process would not stop and may still turn sleep off, so
    /// the caller must keep its lock and journal entry until the handle it
    /// carries resolves.
    func disableSleep(_ start: PendingStart) async throws
    /// Turns sleep back on. Never prompts, so a crashed or stuck session can
    /// always be ended.
    func enableSleep() async throws
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

/// The passwordless rule that turns sleep back on is not in effect.
struct PasswordlessRestoreError: Error, LocalizedError, Sendable {
    /// What sudo answered, or why it could not be asked.
    let detail: String

    var errorDescription: String? {
        "sleep can only be turned off while it can be turned back on without a password, and `sudo -n -l \(PmsetSleepGuard.pmset) \(PmsetSleepGuard.restoreArguments.joined(separator: " "))` did not confirm that (\(detail)); /etc/sudoers.d/insomnia is missing or not in effect, run scripts/install.sh again"
    }
}

/// `sudo -n pmset …` for everything but `disablesleep 1`. `sudo -n` never
/// prompts; if the sudoers rule is missing the call fails fast with a
/// readable error instead of hanging on a password prompt. `disablesleep
/// 1` has no sudoers line and runs through `prompt` instead.
struct PmsetSleepGuard: SleepGuarding {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"
    /// What `enableSleep` passes to pmset, and the command
    /// `checkPasswordlessRestore` asks sudo about.
    static let restoreArguments = ["-a", "disablesleep", "0"]
    /// pmset normally returns in well under a second; a hung powerd must not
    /// hang a quit or a lid action forever.
    static let timeout: TimeInterval = 20

    let prompt: any AdministratorPromptRunning
    /// The sudo that is run. Only tests pass another (a fake that records
    /// its arguments); the app always runs `PmsetSleepGuard.sudo`.
    let sudoPath: String

    init(prompt: any AdministratorPromptRunning = OsascriptAdministratorPrompt(), sudoPath: String = PmsetSleepGuard.sudo) {
        self.prompt = prompt
        self.sudoPath = sudoPath
    }

    /// `sudo -n -l <restore command>` exits 0 only when sudo permits that
    /// exact command and could list it without a password. A missing
    /// /etc/sudoers.d/insomnia leaves no passwordless entry, so listing
    /// needs a password and `-n` makes that a failure, not a prompt.
    /// pmset is not run.
    func checkPasswordlessRestore() async throws {
        let args = ["-n", "-l", Self.pmset] + Self.restoreArguments
        let r: ShellResult
        do {
            r = try await CancellableCommand().run(sudoPath, args, timeout: Self.timeout)
        } catch {
            throw PasswordlessRestoreError(detail: "could not be run: \(error.localizedDescription)")
        }
        guard r.succeeded else {
            let said = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PasswordlessRestoreError(detail: "exit \(r.status)" + (said.isEmpty ? "" : ": \(said)"))
        }
    }

    func disableSleep(_ start: PendingStart) async throws {
        try await prompt.disableSleep(start)
    }

    func enableSleep() async throws {
        try await sudoPmset(Self.restoreArguments)
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
        let r = try await CancellableCommand().run(sudoPath, ["-n"] + full, timeout: Self.timeout)
        guard r.succeeded else {
            throw SleepGuardError(command: "sudo -n \(full.joined(separator: " "))", status: r.status, stderr: r.stderr)
        }
    }
}
