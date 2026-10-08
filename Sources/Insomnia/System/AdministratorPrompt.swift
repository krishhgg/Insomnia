import Foundation

/// Why the administrator password dialog did not turn sleep off.
enum AdministratorPromptError: Error, LocalizedError, Sendable {
    /// The user dismissed the dialog.
    case cancelled
    /// No answer within the limit. osascript was sent SIGTERM, which takes
    /// the dialog down with it, and it exited.
    case timedOut(seconds: TimeInterval)
    /// SIGTERM was sent at the deadline and `grace` seconds later the
    /// prompt had still not finished: osascript is still running, or it
    /// exited and a command it started as root still holds its output.
    /// Nothing is killed. The caller keeps what it is protecting (the
    /// recovery lock, session.json, the journal entry) until
    /// `prompt.waitUntilExit()` returns, because the command may still turn
    /// sleep off.
    case stillRunning(UnfinishedPrompt, grace: TimeInterval)
    /// osascript exited non-zero for another reason: the password was wrong
    /// too many times, pmset itself failed (the root command's 1), or the
    /// command ended some other way (a signal, a status it never uses).
    /// Any of these may have come after `disablesleep 1`.
    case failed(status: Int32, stderr: String)
    /// The password was accepted, but the root command found that sleep
    /// could not be turned back on without a password: `sudo -k -n
    /// /usr/bin/pmset -a disablesleep 0`, run as the user who pressed
    /// Start, failed (exit 5). The command had turned sleep off for the
    /// check, and turned it back on as root before it exited.
    case restoreNeedsPassword(stderr: String)
    /// The root command stopped without leaving sleep off, and its exit
    /// status says why: the start was over (3); the session had ended,
    /// before the check or while it ran (4); or `pmset -g` showed a
    /// SleepDisabled 1 the start did not own, or could not be read, before
    /// the check or after it (6). Or lockf never started it: the marker was
    /// gone (69) or stayed locked for 10 s (75). `rootStatus` is that
    /// status, which osascript ends its error line with; osascript itself
    /// exits 1.
    case refused(rootStatus: Int32, stderr: String)
    case launchFailed(String)

    /// Nothing the caller would undo is left in place: the dialog was
    /// cancelled, osascript never started, or the root command stopped
    /// with one of its refusals (`.restoreNeedsPassword`, `.refused`).
    /// Those refusals come either before it writes anything, or after the
    /// restore check (or, when the check fails, root itself) has set 0 over
    /// the command's own temporary 1. An undo would add nothing but a
    /// chance to clear a SleepDisabled 1 another tool set since. Every
    /// other failure may have left `disablesleep 1` in place, so the caller
    /// undoes it like an end. `AdministratorPrompt.rootCommand` names the
    /// moments in which another tool's 1 is still cleared.
    var nothingToUndo: Bool {
        switch self {
        case .cancelled, .launchFailed, .restoreNeedsPassword, .refused: true
        case .timedOut, .stillRunning, .failed: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "the administrator password prompt was cancelled"
        case let .timedOut(seconds):
            return "the administrator password prompt was not answered within \(Int(seconds)) s"
        case let .stillRunning(prompt, grace):
            if prompt.osascriptAlive {
                return "osascript (pid \(prompt.pid)) did not stop within \(Int(grace)) s of SIGTERM; it is left running, not killed"
            }
            return "osascript (pid \(prompt.pid)) exited after SIGTERM, but a command it started still holds its output; it is left running, not killed"
        case let .failed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "the administrator password prompt failed (osascript exited \(status))" + (detail.isEmpty ? "" : ": \(detail)")
        case let .restoreNeedsPassword(stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "sleep was not left off: turning it back on needs a password (`sudo -k -n /usr/bin/pmset -a disablesleep 0` failed" + (detail.isEmpty ? "" : ": \(detail)") + "), so a session could not end without you. /etc/sudoers.d/insomnia is missing or not in effect; run scripts/install.sh again"
        case let .refused(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Insomnia did not leave sleep off (the command behind the password dialog stopped with status \(status) and undid anything it had changed)" + (detail.isEmpty ? "" : ": \(detail)")
        case let .launchFailed(detail):
            return "could not launch osascript for the administrator password prompt: \(detail)"
        }
    }
}

/// A prompt the runner stopped waiting for. Two exits are tracked: osascript's
/// own (`waitUntilOsascriptExits()`), which is when its pid stops being ours
/// to name, and the whole prompt's (`waitUntilExit()`), once osascript has
/// been reaped and both its pipes have closed, which a root command it
/// started can delay. Nothing polls the pid, so a reused pid is never
/// mistaken for the child. Same shape as the handle the sudo pmset runner
/// hands out for a stuck `sudo pmset`.
final class UnfinishedPrompt: @unchecked Sendable, CustomStringConvertible {
    /// osascript's pid. Only meaningful while `osascriptAlive`.
    let pid: pid_t

    private let lock = NSLock()
    private var osascriptRunning: Bool
    private var exited = false
    private var osascriptWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(pid: pid_t, osascriptAlive: Bool) {
        self.pid = pid
        self.osascriptRunning = osascriptAlive
    }

    var description: String { "osascript (pid \(pid))" }

    /// Whether osascript itself is still running. False means it has exited
    /// and something it started (the root command behind the dialog) may
    /// still hold its output; there is then no pid of ours to signal.
    var osascriptAlive: Bool { lock.withLock { osascriptRunning } }

    var isRunning: Bool { lock.withLock { !exited } }

    /// Returns once osascript itself has exited, possibly before its output
    /// closes.
    func waitUntilOsascriptExits() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if !osascriptRunning { return true }
                osascriptWaiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    func waitUntilExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if exited { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Called by the runner when osascript has been reaped, whether or not
    /// its output has closed. Tests call it in place of a child.
    func markOsascriptExited() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard osascriptRunning else { return [] }
            osascriptRunning = false
            let w = osascriptWaiters
            osascriptWaiters.removeAll()
            return w
        }
        for waiter in waiting { waiter.resume() }
    }

    /// Called by the runner once the child has exited and its output has
    /// closed. Tests call it in place of a child.
    func markExited() {
        markOsascriptExited()
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !exited else { return [] }
            exited = true
            let w = waiters
            waiters.removeAll()
            return w
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// One Start's claim on the password dialog. Just before the dialog is
/// shown, the start transaction writes `nonce` (random, fresh per attempt)
/// to `marker`, and it deletes the file before it releases the recovery
/// lock. Everyone else who takes that lock (reconcile at launch, any later
/// transaction, backstop.sh, uninstall.sh) deletes it first: holding the
/// lock means no start is waiting on a dialog, so a dialog still on screen
/// was abandoned (the app crashed or was force-quit under it). The command
/// the dialog runs as root turns sleep off only while the file holds this
/// nonce, and holds a lock on the file until pmset exits; every deleter
/// takes that lock first. A late answer to an abandoned dialog therefore
/// cannot act for a newer start, and cannot leave sleep off after recovery
/// cleared the journal: until the marker is gone, the journal keeps the
/// sleep entry. Nor can an answer that comes after the session's end,
/// `deadline`, leave sleep off: the root command compares it with the
/// clock before it writes anything and again after the restore check.
struct PendingStart: Sendable, Equatable {
    let marker: URL
    let nonce: String
    let deadline: Date
    /// The journal already owned a SleepDisabled 1 before this start (an
    /// earlier restore failed), the same `sleepDisabledByUs` Start's own
    /// read is skipped for. Only then does the root command skip its reads
    /// of `pmset -g`; by default it reads, and a 1 stops it.
    var sleepOffIsOurs = false

    /// `deadline` as the root command's `$3`: whole seconds since 1970,
    /// rounded down, so a refusal comes at most a second early, never late.
    var deadlineArgument: String { String(Int(deadline.timeIntervalSince1970.rounded(.down))) }

    /// `sleepOffIsOurs` as the root command's `$5`: `1` skips its reads,
    /// anything else keeps them.
    var ownershipArgument: String { sleepOffIsOurs ? "1" : "0" }
}

/// The one privileged command Insomnia cannot run without a password:
/// `pmset -a disablesleep 1`, through the standard macOS administrator
/// dialog. The sudoers rule install.sh writes only covers turning sleep
/// back on and the battery Low Power Mode floor, so nothing running as the
/// user can keep the Mac awake unattended. Only an explicit Start by the
/// user may reach this; relaunch and reconcile read `pmset -g` instead.
protocol AdministratorPromptRunning: Sendable {
    /// Returns once `pmset -a disablesleep 1` has run as root and been left
    /// in place, which happens only while `start.marker` holds
    /// `start.nonce`, before `start.deadline`, while `pmset -g` reads sleep
    /// on (unless `start.sleepOffIsOurs`), and once sudo has run the
    /// restore for this user without a password. Throws an
    /// `AdministratorPromptError` when the dialog was cancelled, the
    /// password was wrong, the root command stopped without leaving sleep
    /// off (`.refused`: the marker was gone or no longer matched, the
    /// deadline had passed, or someone else's SleepDisabled 1 was found),
    /// the restore needed a password (`.restoreNeedsPassword`), pmset
    /// failed, nothing came back in time, or the prompt's process would not
    /// stop (`.stillRunning`).
    func disableSleep(_ start: PendingStart) async throws
}

enum AdministratorPrompt {
    /// The first half of what runs as root. `lockf` opens the marker
    /// (`-n`: never creates it, and exits 69 when it is gone), takes an
    /// flock(2) lock on it within 10 s (exit 75 otherwise), runs the rest
    /// and holds the lock until that exits; `-k` leaves the file in place.
    /// Everyone who deletes the marker takes the same lock first
    /// (Store.removePendingStart, backstop.sh, uninstall.sh), so the
    /// marker cannot go between the nonce check and the end of pmset: it
    /// goes before the check, which then fails, or after pmset, whose
    /// effect the journal entry the start wrote first still covers.
    static let markerLock = "/usr/bin/lockf -k -n -t 10"
    /// What runs as root under that lock, as `/bin/sh -c <this> insomnia
    /// <marker> <nonce> <deadline> <uid> <owned>`. Fixed text: the marker
    /// path, nonce, deadline, the uid of the user who pressed Start and
    /// whether the journal already owned a SleepDisabled 1 arrive only as
    /// `$1` to `$5`, and the marker's content is only compared, never run.
    /// pmset runs only while the marker holds the nonce and the clock is
    /// before the deadline (seconds since 1970). Exit 3: the start was over
    /// before the password was accepted. Exit 4: the session had ended by
    /// then, or `$3` is not a number `[` can compare, which fails the test
    /// and so refuses too. Either way nothing ran. So does a `$4` that is
    /// not a positive whole number (exit 5).
    ///
    /// Then root reads `pmset -g` itself, under the marker's lock. Start
    /// read it before the dialog, and another tool may have turned sleep
    /// off while the password was typed. A SleepDisabled 1 (the first
    /// `SleepDisabled` line with a value, as
    /// `PmsetSleepGuard.parseSleepDisabled` reads it), or a `pmset -g` that
    /// fails, exits 6 with nothing changed: that tool's setting stays, and
    /// the start rolls back with nothing to undo. `$5` is `1` only when the
    /// journal already owned a 1 before this start (an earlier restore
    /// failed); that 1 is Insomnia's own, so nothing is read, as at Start.
    ///
    /// Then root turns sleep off, a change the start journaled before the
    /// dialog, and runs the restore every end and backstop.sh depend on the
    /// way they run it: as that user, through sudo, with no password. Root
    /// drops to the user with `sudo -n -u "#$4"`, and the user's sudo runs
    /// the restore with `-k`, which ignores a credential cached by a recent
    /// sudo in a terminal, and `-n`, which fails instead of prompting. So it
    /// passes only when the sudoers policy itself lets that user run the
    /// exact restore without a password. No listing or dry run stands in
    /// for it: the check is the restore itself. Because sleep was turned
    /// off first, what the restore turns back on is this command's own
    /// change, never a 1 it found. When the restore fails, root turns sleep
    /// back on itself before it prints anything (a closed dialog cannot
    /// kill it by SIGPIPE first), then exits 5; a root pmset that fails
    /// there exits 1, which the start undoes like an end.
    ///
    /// The check can take a while (sudo may look the user up in a directory
    /// service), so the clock is compared with the deadline once more after
    /// it: past the end, the command exits 4 and sleep stays on as the
    /// check left it. `pmset -g` is read again, and a 1 set after the
    /// check's write, or a read that fails, exits 6 with that setting left
    /// alone. Only then is sleep turned off for the session. A session that
    /// ended in the moment before that change ends at once, because the
    /// deadline timer the start arms next fires immediately for a date in
    /// the past. Each refusal (3 to 6) therefore leaves no change of the
    /// command's own, and the start rolls back without running pmset.
    ///
    /// What this cannot do: pmset has one SleepDisabled setting and no
    /// compare-and-set, so a 1 another tool sets in the moment between a
    /// read of 0 and root's next `disablesleep 1` cannot be told from
    /// Insomnia's own, and the restore check or the session's end sets it
    /// to 0. The same holds for a 1 another tool sets while Insomnia's 1 is
    /// in effect, during the check as during a session. And sleep is off
    /// for as long as the check runs, even when it then fails; if root's
    /// shell dies in that time (power loss, a root kill), sleep stays off
    /// with the journal entry the start wrote, and a missing rule means the
    /// next restore needs the user. pmset is not `exec`ed, so its own exit
    /// status can never read as 5 or 6.
    static let rootCommand = ##"m=$(/usr/bin/head -c 64 "$1" 2>/dev/null); if [ -z "$2" ] || [ "$m" != "$2" ]; then echo "the start that asked for this password is over; sleep was not turned off" >&2; exit 3; fi; if ! [ "$(/bin/date +%s)" -lt "$3" ] 2>/dev/null; then echo "the session this password was for has already ended; sleep was not turned off" >&2; exit 4; fi; if ! [ "$4" -gt 0 ] 2>/dev/null; then echo "turning sleep back on needs a password, so sleep was not turned off" >&2; exit 5; fi; foreign() { [ "$1" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ "$(printf %s "$s" | /usr/bin/awk '$1 == "SleepDisabled" && NF > 1 { print $2; exit }')" = 1 ]; }; }; if foreign "$5"; then echo "pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off" >&2; exit 6; fi; /usr/bin/pmset -a disablesleep 1 || exit 1; if ! /usr/bin/sudo -n -u "#$4" /usr/bin/sudo -k -n /usr/bin/pmset -a disablesleep 0; then /usr/bin/pmset -a disablesleep 0 || exit 1; echo "turning sleep back on needs a password, so it was turned back on at once and not left off" >&2; exit 5; fi; if ! [ "$(/bin/date +%s)" -lt "$3" ] 2>/dev/null; then echo "the session this password was for ended while the restore was checked; the check turned sleep back on and it was not left off" >&2; exit 4; fi; if foreign "$5"; then echo "pmset -g shows a SleepDisabled 1 set after the restore check turned sleep back on, or could not be read; it was left alone and this start did not turn sleep off again" >&2; exit 6; fi; /usr/bin/pmset -a disablesleep 1 || exit 1"##
    /// The whole AppleScript, as one literal: `markerLock`, `rootCommand`
    /// (each `"` escaped for AppleScript), the privilege flag and the
    /// dialog text are fixed at compile time. Its only inputs are the
    /// marker path, the nonce, the deadline, the uid and the ownership flag,
    /// `item 1` to `item 5 of argv`, and each reaches the root shell
    /// through `quoted form of`, as lockf's file and as positional
    /// parameters. No configuration value or environment variable reaches
    /// the command that runs as root.
    static let disableSleepScript = #"""
    on run argv
    do shell script "/usr/bin/lockf -k -n -t 10 " & quoted form of (item 1 of argv) & " /bin/sh -c " & quoted form of "m=$(/usr/bin/head -c 64 \"$1\" 2>/dev/null); if [ -z \"$2\" ] || [ \"$m\" != \"$2\" ]; then echo \"the start that asked for this password is over; sleep was not turned off\" >&2; exit 3; fi; if ! [ \"$(/bin/date +%s)\" -lt \"$3\" ] 2>/dev/null; then echo \"the session this password was for has already ended; sleep was not turned off\" >&2; exit 4; fi; if ! [ \"$4\" -gt 0 ] 2>/dev/null; then echo \"turning sleep back on needs a password, so sleep was not turned off\" >&2; exit 5; fi; foreign() { [ \"$1\" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ \"$(printf %s \"$s\" | /usr/bin/awk '$1 == \"SleepDisabled\" && NF > 1 { print $2; exit }')\" = 1 ]; }; }; if foreign \"$5\"; then echo \"pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off\" >&2; exit 6; fi; /usr/bin/pmset -a disablesleep 1 || exit 1; if ! /usr/bin/sudo -n -u \"#$4\" /usr/bin/sudo -k -n /usr/bin/pmset -a disablesleep 0; then /usr/bin/pmset -a disablesleep 0 || exit 1; echo \"turning sleep back on needs a password, so it was turned back on at once and not left off\" >&2; exit 5; fi; if ! [ \"$(/bin/date +%s)\" -lt \"$3\" ] 2>/dev/null; then echo \"the session this password was for ended while the restore was checked; the check turned sleep back on and it was not left off\" >&2; exit 4; fi; if foreign \"$5\"; then echo \"pmset -g shows a SleepDisabled 1 set after the restore check turned sleep back on, or could not be read; it was left alone and this start did not turn sleep off again\" >&2; exit 6; fi; /usr/bin/pmset -a disablesleep 1 || exit 1" & " insomnia " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv) with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session."
    end run
    """#
    /// The user is typing a password, so the limit is generous. At the
    /// deadline osascript gets SIGTERM, and the start is rolled back.
    static let timeout: TimeInterval = 120
    /// How long after SIGTERM the runner keeps waiting before it answers
    /// the caller with `.stillRunning`. The same 3 s as KILL_GRACE_SECONDS
    /// in scripts/backstop.sh.
    static let stopGrace: TimeInterval = 3
}

/// `/usr/bin/osascript -e <script>` as a child process, not NSAppleScript
/// in-process: AppleScript is main-thread only, and a dialog waited on
/// from the main actor would freeze the menu bar, the lifecycle queue and
/// every timer for as long as the dialog is up, with no way to time out.
/// A child can be waited on from a background queue and signalled at the
/// deadline.
///
/// Only SIGTERM is ever sent. The command osascript runs after the dialog
/// is a root sudo and pmset; a SIGKILL could not reach them and would only
/// orphan them. The wait is bounded all the same: `grace` seconds after the
/// deadline the caller is answered with `.stillRunning`, carrying the pid
/// and a handle that resolves when the child and its pipes are gone, so
/// the caller can say what is running, keep its lock, and roll back after
/// the exit instead of beside a root pmset.
struct OsascriptAdministratorPrompt: AdministratorPromptRunning {
    static let osascript = "/usr/bin/osascript"

    let executable: String
    let timeout: TimeInterval
    let grace: TimeInterval
    /// Runs on a background queue after osascript is launched and before
    /// the `timeout` clock starts. Production passes nothing. Tests block in
    /// it until their fake has installed its signal handlers, so SIGTERM
    /// never lands before the handler it is meant to meet.
    let beforeDeadline: @Sendable () -> Void

    /// `executable` is only ever overridden by tests, with a fake that
    /// records its arguments and never shows a dialog.
    init(
        executable: String = Self.osascript,
        timeout: TimeInterval = AdministratorPrompt.timeout,
        grace: TimeInterval = AdministratorPrompt.stopGrace,
        beforeDeadline: @escaping @Sendable () -> Void = {}
    ) {
        self.executable = executable
        self.timeout = timeout
        self.grace = grace
        self.beforeDeadline = beforeDeadline
    }

    /// The uid passed is this process's, the user who pressed Start: the
    /// one whose sudoers rule every end and backstop.sh run depend on.
    func disableSleep(_ start: PendingStart) async throws {
        let r = try await run(["-e", AdministratorPrompt.disableSleepScript, start.marker.path, start.nonce, start.deadlineArgument, String(getuid()), start.ownershipArgument])
        guard r.status == 0 else {
            if Self.isCancel(r.stderr) { throw AdministratorPromptError.cancelled }
            if Self.isRestoreRefusal(r.stderr) { throw AdministratorPromptError.restoreNeedsPassword(stderr: r.stderr) }
            if let status = Self.rootStatus(r.stderr), Self.refusalStatuses.contains(status) {
                throw AdministratorPromptError.refused(rootStatus: status, stderr: r.stderr)
            }
            throw AdministratorPromptError.failed(status: r.status, stderr: r.stderr)
        }
    }

    /// The exits that mean the root command stopped without leaving sleep
    /// off (`AdministratorPromptError.refused`): its own 3, 4 and 6, and
    /// lockf's 69 (no marker) and 75 (the marker stayed locked), for which
    /// it never started. None of them can come from pmset, whose failure
    /// the command turns into 1. 5 is `isRestoreRefusal`.
    static let refusalStatuses: Set<Int32> = [3, 4, 6, 69, 75]

    /// The status osascript ends its error line with, `(<status>)`, when it
    /// is a positive whole number: the exit status of the command `do shell
    /// script` ran. A cancel's -128 and other AppleScript errors are not.
    static func rootStatus(_ stderr: String) -> Int32? {
        let line = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int32(digits)
    }

    /// The dialog's Cancel button ends osascript with `execution error:
    /// User canceled. (-128)`, and nothing has run as root. A command that
    /// ran ends the same line with its own exit status instead, so its
    /// output (a lockf message naming the marker path, say) is never taken
    /// for a cancel, whatever text it contains.
    static func isCancel(_ stderr: String) -> Bool {
        stderr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
    }

    /// The root command exited 5: its restore check failed, and root
    /// turned sleep back on before exiting. osascript ends its error line
    /// with the shell's exit status, the same way it ends a cancel with
    /// -128.
    static func isRestoreRefusal(_ stderr: String) -> Bool {
        rootStatus(stderr) == 5
    }

    /// The one place that knows whether the child exists, whether this
    /// runner signalled it, and whether the caller has already been
    /// answered, so none of the three is decided separately.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private let timeout: TimeInterval
        private let grace: TimeInterval
        private var process: Process?
        private var continuation: CheckedContinuation<ShellResult, Error>?
        /// SIGTERM was sent by this runner.
        private var signalled = false
        /// Set once the caller was answered with `.stillRunning`; the exit
        /// then goes to this handle.
        private var unfinished: UnfinishedPrompt?
        /// osascript itself has been reaped (its output may still be open).
        private var osascriptGone = false

        init(timeout: TimeInterval, grace: TimeInterval) {
            self.timeout = timeout
            self.grace = grace
        }

        func attach(_ c: CheckedContinuation<ShellResult, Error>) {
            lock.withLock { continuation = c }
        }

        func launched(_ p: Process) {
            lock.withLock { process = p }
        }

        /// Answer the caller before the child has exited (launch failure).
        func finish(_ result: Result<ShellResult, Error>) {
            let c: CheckedContinuation<ShellResult, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: result)
        }

        /// The limit passed. A child still running gets SIGTERM, once.
        /// Either way, if the exit has not answered the caller `grace`
        /// seconds from now, `graceExpired` does.
        func deadline() {
            let pending: Bool = lock.withLock {
                guard continuation != nil, let p = process else { return false }
                if p.isRunning {
                    signalled = true
                    p.terminate()
                }
                return true
            }
            guard pending else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in graceExpired() }
        }

        private func graceExpired() {
            let (c, error): (CheckedContinuation<ShellResult, Error>?, AdministratorPromptError?) = lock.withLock {
                guard let c = continuation, let p = process else { return (nil, nil) }
                let handle = UnfinishedPrompt(pid: p.processIdentifier, osascriptAlive: !osascriptGone && p.isRunning)
                unfinished = handle
                continuation = nil
                return (c, .stillRunning(handle, grace: grace))
            }
            if let c, let error { c.resume(throwing: error) }
        }

        /// osascript has been reaped; its pipes may still be open. A handle
        /// already given out learns it now, so nothing keeps naming the pid.
        func osascriptExited() {
            let handle: UnfinishedPrompt? = lock.withLock {
                osascriptGone = true
                return unfinished
            }
            handle?.markOsascriptExited()
        }

        /// The child has been reaped and both pipes have closed. Classified
        /// by what *this* runner did to the child, not by how the child
        /// happened to exit: one that traps TERM and exits 0 after the
        /// deadline is still a timeout. A caller already answered with
        /// `.stillRunning` is not answered again; its handle is told.
        func exited(_ result: ShellResult) {
            let (c, handle, outcome): (CheckedContinuation<ShellResult, Error>?, UnfinishedPrompt?, Result<ShellResult, Error>) = lock.withLock {
                defer { continuation = nil }
                let outcome: Result<ShellResult, Error> = signalled
                    ? .failure(AdministratorPromptError.timedOut(seconds: timeout))
                    : .success(result)
                return (continuation, unfinished, outcome)
            }
            handle?.markExited()
            c?.resume(with: outcome)
        }
    }

    private func run(_ args: [String]) async throws -> ShellResult {
        let exe = executable
        let state = RunState(timeout: timeout, grace: grace)
        let timeout = self.timeout
        let beforeDeadline = self.beforeDeadline
        return try await withCheckedThrowingContinuation { continuation in
            state.attach(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let osascriptExit = ProcessExit(process)

                do {
                    try process.run()
                } catch {
                    state.finish(.failure(AdministratorPromptError.launchFailed(error.localizedDescription)))
                    return
                }
                state.launched(process)

                nonisolated(unsafe) let deadline = DispatchWorkItem { state.deadline() }
                DispatchQueue.global().async {
                    beforeDeadline()
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                }

                // Each pipe is drained on its own thread and the child is
                // reaped here; none of the three waits blocks the answer
                // the grace path gives, it only delays `exited`. osascript's
                // own exit is reported as soon as it is reaped, before its
                // output closes.
                let group = DispatchGroup()
                nonisolated(unsafe) var outData = Data()
                nonisolated(unsafe) var errData = Data()
                let outHandle = out.fileHandleForReading
                let errHandle = err.fileHandleForReading
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = outHandle.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errHandle.readDataToEndOfFile()
                    group.leave()
                }
                osascriptExit.wait()
                state.osascriptExited()
                group.wait()
                deadline.cancel()

                state.exited(ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
