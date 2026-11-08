import Foundation

/// The only two things Insomnia ever does as root, both through the four
/// sudoers-allowed pmset commands written by install.sh.
protocol SleepGuarding: Sendable {
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

/// `pmset -a disablesleep 1` exited 0, but `pmset -g` read SleepDisabled 0
/// again `settle` seconds later.
struct SleepDisableRevertedError: Error, LocalizedError, Sendable {
    let settle: TimeInterval

    var errorDescription: String? {
        "SleepDisabled read 0 again within \(Int(settle)) s of `pmset -a disablesleep 1`; another process may be resetting it, so closing the lid would still sleep this Mac"
    }
}

/// `sudo -n pmset …`. Never prompts; if the sudoers rule is missing the call
/// fails fast with a readable error instead of hanging on a password prompt.
struct PmsetSleepGuard: SleepGuarding {
    static let sudo = "/usr/bin/sudo"
    static let pmset = "/usr/bin/pmset"
    /// pmset normally returns in well under a second; a hung powerd must not
    /// hang a quit or a lid action forever.
    static let timeout: TimeInterval = 20
    /// How long a `sudo pmset` gets to exit after SIGTERM before it is
    /// reported as still running. The same 3 s as KILL_GRACE_SECONDS in
    /// scripts/backstop.sh.
    static let stopGrace: TimeInterval = 3
    /// How long after `pmset -a disablesleep 1` the bit is read back. pmset
    /// can exit 0 while another process puts the bit back: on one Mac a root
    /// LaunchDaemon from another keep-awake tool ran `pmset -a disablesleep 0`
    /// every 2 s outside its own schedule, so `pmset -g` read SleepDisabled 1
    /// for about 2 s and then 0, and a closed lid slept the Mac mid-session.
    static let settle: TimeInterval = 5

    /// The app uses the defaults; tests point `sudo` at a fake, shorten the
    /// limits, start the deadline once the fake is ready, and replace the
    /// settle wait with one that tells the fake pmset the time has passed.
    let sudoPath: String
    let pmsetPath: String
    let commandTimeout: TimeInterval
    let grace: TimeInterval
    let settleDelay: TimeInterval
    let settleWait: @Sendable (TimeInterval) async throws -> Void
    let runner: CancellableCommand

    init(
        sudo: String = Self.sudo,
        pmset: String = Self.pmset,
        timeout: TimeInterval = Self.timeout,
        stopGrace: TimeInterval = Self.stopGrace,
        settle: TimeInterval = Self.settle,
        settleWait: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        runner: CancellableCommand = CancellableCommand()
    ) {
        sudoPath = sudo
        pmsetPath = pmset
        commandTimeout = timeout
        grace = stopGrace
        settleDelay = settle
        self.settleWait = settleWait
        self.runner = runner
    }

    /// A disable that reads SleepDisabled 0 after `settle` throws
    /// `SleepDisableRevertedError`, and one that cannot be read back throws
    /// `SleepGuardError`; callers handle both like a failed pmset. Restoring
    /// sleep is not read back.
    func setSleepDisabled(_ disabled: Bool) async throws {
        try await sudoPmset(["-a", "disablesleep", disabled ? "1" : "0"])
        guard disabled else { return }
        try await settleWait(settleDelay)
        switch Self.readSleepDisabled(try await pmsetG()) {
        case true?:
            return
        case false?:
            throw SleepDisableRevertedError(settle: settleDelay)
        case nil:
            throw SleepGuardError(command: "pmset -g", status: 0, stderr: "no SleepDisabled line reading 0 or 1, so `pmset -a disablesleep 1` could not be read back")
        }
    }

    func setLowPowerMode(_ on: Bool) async throws {
        try await sudoPmset(["-b", "lowpowermode", on ? "1" : "0"])
    }

    func isSleepDisabled() async throws -> Bool {
        Self.parseSleepDisabled(try await pmsetG())
    }

    /// `pmset -g` output; throws when pmset fails.
    private func pmsetG() async throws -> String {
        let r = try await runner.run(pmsetPath, ["-g"], timeout: commandTimeout)
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g", status: r.status, stderr: r.stderr)
        }
        return r.stdout
    }

    func isLowPowerModeOn() async throws -> Bool {
        let r = try await runner.run(pmsetPath, ["-g", "custom"], timeout: commandTimeout)
        guard r.succeeded else {
            throw SleepGuardError(command: "pmset -g custom", status: r.status, stderr: r.stderr)
        }
        guard let on = Self.parseLowPowerMode(r.stdout) else {
            throw SleepGuardError(command: "pmset -g custom", status: 0, stderr: Self.lowPowerModeUnreadable(r.stdout))
        }
        return on
    }

    /// True when `pmset -g` output has a line whose first token is
    /// `SleepDisabled` and whose value is `1`.
    static func parseSleepDisabled(_ output: String) -> Bool {
        readSleepDisabled(output) == true
    }

    /// The first `SleepDisabled` line in `pmset -g` output: true for `1`,
    /// false for `0`, nil when there is no such line or its value is
    /// anything else. The read back after a disable uses this, so output it
    /// cannot read is not reported as the bit being put back.
    static func readSleepDisabled(_ output: String) -> Bool? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("SleepDisabled") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "SleepDisabled" else { continue }
            switch parts[1] {
            case "1": return true
            case "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// `lowpowermode` in the `Battery Power:` section of `pmset -g custom`
    /// (the one `pmset -b` writes). macOS 27 no longer prints that key and
    /// reports the mode as `powermode` instead (`0` automatic, `1` Low Power,
    /// `2` High Power), while `pmset -b lowpowermode 0|1` still sets it, so
    /// `powermode` is read when `lowpowermode` is absent. A `lowpowermode`
    /// line always wins over `powermode`, even one with no value. nil when
    /// the section or both keys are absent, as on a desktop, or when the
    /// value is anything but an explicit `0` or `1`: an unreadable value is
    /// not proof that the mode is off, and treating it as off would take
    /// over a preference the user may have set. High Power (`powermode 2`)
    /// is such a preference.
    static func parseLowPowerMode(_ output: String) -> Bool? {
        switch lowPowerModeLine(output)?.value {
        case "1"?: return true
        case "0"?: return false
        default: return nil
        }
    }

    /// The line `parseLowPowerMode` reads: the first `lowpowermode` line in
    /// the `Battery Power:` section, else the first `powermode` line there.
    /// A `lowpowermode` line with no value still wins, so its value reads as
    /// unknown rather than falling back to `powermode`. The value is "" when
    /// the line has none.
    static func lowPowerModeLine(_ output: String) -> (key: String, value: String)? {
        var inBattery = false
        var lowPowerValue: String?
        var powerModeValue: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(":") {
                inBattery = line == "Battery Power:"
                continue
            }
            guard inBattery else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = parts.first else { continue }
            let value = parts.count >= 2 ? String(parts[1]) : ""
            if key == "lowpowermode", lowPowerValue == nil { lowPowerValue = value }
            if key == "powermode", powerModeValue == nil { powerModeValue = value }
        }
        if let lowPowerValue { return ("lowpowermode", lowPowerValue) }
        if let powerModeValue { return ("powermode", powerModeValue) }
        return nil
    }

    /// Why `parseLowPowerMode` returned nil for `output`, for the log: no
    /// line, High Power, or a value other than `0` or `1`. It describes only
    /// the reading, since each caller decides what to do about it.
    static func lowPowerModeUnreadable(_ output: String) -> String {
        guard let line = lowPowerModeLine(output) else {
            return "no lowpowermode or powermode line under Battery Power"
        }
        if line.key == "powermode", line.value == "2" {
            return "powermode 2 under Battery Power is High Power, not Low Power Mode on or off"
        }
        let value = line.value.isEmpty ? "no value" : "value \(line.value)"
        return "\(line.key) under Battery Power has \(value), not 0 or 1"
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
        let full = [pmsetPath] + args
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
