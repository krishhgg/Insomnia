import Foundation

/// The only things Insomnia ever does as root. Turning sleep off goes
/// through the administrator password dialog (see AdministratorPrompt);
/// everything else goes through the three passwordless pmset lines
/// install.sh writes to sudoers, none of which can keep the Mac awake.
protocol SleepGuarding: Sendable {
    /// Proves, without prompting, that `enableSleep` needs no password,
    /// by running it. Start calls it before anything is written or shown:
    /// sleep may be turned off only while it can be turned back on with
    /// nobody at the keyboard. `sleepOffIsOurs` is the journal's
    /// `sleepDisabledByUs`: when it is set, the restore is owed anyway
    /// and runs whatever the setting is. Otherwise it runs only while
    /// `pmset -g` reports SleepDisabled 0, where it changes nothing, and a
    /// 1 fails the check with nothing run. Throws
    /// `PasswordlessRestoreError` when the restore is not confirmed.
    func checkPasswordlessRestore(sleepOffIsOurs: Bool) async throws
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

/// Why `checkPasswordlessRestore` could not prove that sleep can be
/// turned back on without a password.
enum PasswordlessRestoreError: Error, LocalizedError, Sendable {
    /// `pmset -g` already reports SleepDisabled 1 and the journal does not
    /// say Insomnia set it. Proving the restore would turn sleep back on
    /// for whoever turned it off, so nothing is run.
    case sleepAlreadyOff
    /// `pmset -g` could not be read, so it is not known whether the
    /// restore would change anything. Nothing is run.
    case sleepSettingUnreadable(String)
    /// The restore command did not exit 0: what sudo answered, or why it
    /// could not be run.
    case notConfirmed(String)

    var errorDescription: String? {
        switch self {
        case .sleepAlreadyOff:
            "sleep is already off (pmset reports SleepDisabled 1) and Insomnia did not turn it off, so Start leaves it alone: checking that sleep can be turned back on without a password would turn it on. To re-enable sleep: sudo pmset -a disablesleep 0, then start again"
        case let .sleepSettingUnreadable(detail):
            "`pmset -g` could not be read (\(detail)), so it was not checked that sleep can be turned back on without a password"
        case let .notConfirmed(detail):
            "sleep can only be turned off while it can be turned back on without a password, and `\(PmsetSleepGuard.restoreCheckCommand)` did not confirm that (\(detail)); /etc/sudoers.d/insomnia is missing or not in effect, run scripts/install.sh again"
        }
    }
}

/// `sudo -n pmset …` for everything but `disablesleep 1`. `sudo -n` never
/// prompts; if the sudoers rule is missing the call fails fast with a
/// readable error instead of hanging on a password prompt. `disablesleep
/// 1` has no sudoers line and runs through `prompt` instead.
struct PmsetSleepGuard: SleepGuarding {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"
    /// What `enableSleep` passes to pmset, and what
    /// `checkPasswordlessRestore` runs.
    static let restoreArguments = ["-a", "disablesleep", "0"]
    /// The sudo options `checkPasswordlessRestore` adds. `-k` ignores a
    /// cached credential (a recent sudo in a terminal), and `-n` fails
    /// instead of prompting, so exit 0 means the sudoers policy itself
    /// lets the exact restore command run as root without a password.
    static let restoreCheckOptions = ["-k", "-n"]
    static var restoreCheckCommand: String {
        ([sudo] + restoreCheckOptions + [pmset] + restoreArguments).joined(separator: " ")
    }
    /// pmset normally returns in well under a second; a hung powerd must not
    /// hang a quit or a lid action forever.
    static let timeout: TimeInterval = 20
    /// How long a `sudo pmset` gets to exit after SIGTERM before it is
    /// reported as still running. The same 3 s as KILL_GRACE_SECONDS in
    /// scripts/backstop.sh.
    static let stopGrace: TimeInterval = 3

    /// Shows the administrator password dialog for `disableSleep`.
    let prompt: any AdministratorPromptRunning
    /// The sudo that is run. Only tests pass another (a fake that records
    /// its arguments); the app always runs `PmsetSleepGuard.sudo`.
    let sudoPath: String
    /// The pmset that `pmset -g` reads run. Only tests pass another; what
    /// sudo runs is always `PmsetSleepGuard.pmset`, the path the sudoers
    /// rule names.
    let pmsetPath: String
    let commandTimeout: TimeInterval
    let grace: TimeInterval
    let runner: CancellableCommand

    /// The app uses the defaults; tests point `sudo` at a fake, shorten the
    /// limits, and start the deadline once the fake is ready.
    init(
        prompt: any AdministratorPromptRunning = OsascriptAdministratorPrompt(),
        sudo: String = Self.sudo,
        pmset: String = Self.pmset,
        timeout: TimeInterval = Self.timeout,
        stopGrace: TimeInterval = Self.stopGrace,
        runner: CancellableCommand = CancellableCommand()
    ) {
        self.prompt = prompt
        sudoPath = sudo
        pmsetPath = pmset
        commandTimeout = timeout
        grace = stopGrace
        self.runner = runner
    }

    /// Runs the restore itself, `sudo -k -n /usr/bin/pmset -a disablesleep
    /// 0`, because only running a command shows whether sudo would ask for
    /// a password: `sudo -l` lists a command the admin group may run with
    /// its password, and lists without one whenever any passwordless entry
    /// exists. A restore the journal owes (`sleepOffIsOurs`) is what any
    /// end or backstop.sh run does next, so it runs as it is. Otherwise
    /// it runs only while `pmset -g` reports SleepDisabled 0, where it
    /// changes nothing. A 1 is left as it is and the check fails, the same
    /// as a cancelled dialog leaves it: proving the restore then would
    /// turn sleep back on for whoever turned it off. Something that sets
    /// the bit between the read and the run is the one case the run can
    /// change.
    func checkPasswordlessRestore(sleepOffIsOurs: Bool) async throws {
        if !sleepOffIsOurs {
            let sleepOff: Bool
            do {
                sleepOff = try await isSleepDisabled()
            } catch {
                throw PasswordlessRestoreError.sleepSettingUnreadable(error.localizedDescription)
            }
            guard !sleepOff else { throw PasswordlessRestoreError.sleepAlreadyOff }
        }
        let args = Self.restoreCheckOptions + [Self.pmset] + Self.restoreArguments
        let r: ShellResult
        do {
            r = try await CancellableCommand().run(sudoPath, args, timeout: Self.timeout)
        } catch {
            throw PasswordlessRestoreError.notConfirmed("could not be run: \(error.localizedDescription)")
        }
        guard r.succeeded else {
            let said = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PasswordlessRestoreError.notConfirmed("exit \(r.status)" + (said.isEmpty ? "" : ": \(said)"))
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
        let r = try await runner.run(pmsetPath, ["-g"], timeout: commandTimeout)
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g", status: r.status, stderr: r.stderr)
        }
        return Self.parseSleepDisabled(r.stdout)
    }

    func isLowPowerModeOn() async throws -> Bool {
        let r = try await runner.run(pmsetPath, ["-g", "custom"], timeout: commandTimeout)
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

    /// The one path for every `sudo pmset` the app runs, including a check
    /// that runs one of the sudoers commands only to see that it passes
    /// (`sudoOptions` such as `-k` go before the `-n` that is always there).
    ///
    /// Throws `CommandStillRunningError` when sudo does not stop on SIGTERM
    /// within `stopGrace`: the child is never SIGKILLed, because that would
    /// orphan a root pmset that can still change power state after the
    /// journal has moved on. The caller must keep its lock and journal
    /// entry until `error.command.waitUntilExit()` returns.
    ///
    /// Runs only inside a recovery transaction (`RecoveryLock.held`), and
    /// the command holds that lock itself until it exits: if Insomnia
    /// crashes or is force-quit while it runs, the backstop still cannot
    /// run an undo beside it, or before it, and have it change power state
    /// afterwards with no journal entry left.
    func sudoPmset(_ args: [String], sudoOptions: [String] = []) async throws {
        let full = [Self.pmset] + args
        let options = sudoOptions + ["-n"]
        let command = "sudo \(options.joined(separator: " ")) \(full.joined(separator: " "))"
        guard let lock = RecoveryLock.held else {
            throw SleepGuardError(command: command, status: -1, stderr: "not run: no recovery transaction holds the lock")
        }
        // CancellableCommand, not Shell.run(timeout:): it reports a child
        // that had to be stopped at the deadline as a timeout even if the
        // child exits 0 on SIGTERM, and a caller cancelled mid-flight stops
        // the child instead of leaving it running.
        let r = try await runner.run(sudoPath, options + full, timeout: commandTimeout, stop: .terminateOnly(grace: grace), holding: lock)
        guard r.succeeded else {
            throw SleepGuardError(command: command, status: r.status, stderr: r.stderr)
        }
    }
}
