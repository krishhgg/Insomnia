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
    /// The password was accepted, but sudo did not confirm that the user
    /// who pressed Start can turn sleep back on without a password (exit
    /// 5): no usable uid came with it, root could not switch to that user,
    /// or that user's sudo did not show a supported version, did not list
    /// without a password, listed Defaults bound to a Runas user or a
    /// command, or did not show /etc/sudoers.d/insomnia's restore line as
    /// the matching rule. Every one of these comes before the command
    /// writes anything.
    case restoreNeedsPassword(stderr: String)
    /// The root command stopped before it wrote anything, and its exit
    /// status says why: the start was over (3); the session had ended,
    /// before the sudo checks, during them or while `pmset -g` was read
    /// (4); or `pmset -g` showed a SleepDisabled 1 the start did not own,
    /// or could not be read (6). Or lockf never started it: the marker was
    /// gone (69) or stayed locked for 10 s (75). `rootStatus` is that
    /// status, which osascript ends its error line with; osascript itself
    /// exits 1.
    case refused(rootStatus: Int32, stderr: String)
    case launchFailed(String)

    /// Nothing the caller would undo is left in place: the dialog was
    /// cancelled, osascript never started, or the root command stopped
    /// with one of its refusals (`.restoreNeedsPassword`, `.refused`), all
    /// of which come before its only write. An undo would add nothing but a
    /// chance to clear a SleepDisabled 1 another tool set. Every other
    /// failure may have left `disablesleep 1` in place, so the caller
    /// undoes it like an end. `AdministratorPrompt.rootCommand` says why a
    /// refusal keeps its status even when the dialog's output is gone.
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
            return "sleep was not turned off: sudo did not confirm that `sudo -n /usr/bin/pmset -a disablesleep 0` runs for you without a password" + (detail.isEmpty ? "" : " (\(detail))") + ", so a session could not end without you. Run scripts/install.sh again if /etc/sudoers.d/insomnia is missing or not in effect. The check also stops on a sudo older than 1.9.15 or one with other plugins, and on Defaults bound to a Runas user or a command"
        case let .refused(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Insomnia did not turn sleep off (the command behind the password dialog stopped with status \(status) before it changed anything)" + (detail.isEmpty ? "" : ": \(detail)")
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
/// clock once it holds the lock, again after the sudo checks, and again
/// right before its only write.
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
    /// Returns once `pmset -a disablesleep 1` has run as root, which happens
    /// only while `start.marker` holds `start.nonce`, before
    /// `start.deadline`, once sudo has confirmed without running anything
    /// that this user can run the restore without a password, and while
    /// `pmset -g` reads sleep on (unless `start.sleepOffIsOurs`). Throws an
    /// `AdministratorPromptError` when the dialog was cancelled, the
    /// password was wrong, the root command stopped before writing
    /// (`.refused`: the marker was gone or no longer matched, the deadline
    /// had passed, or someone else's SleepDisabled 1 was found), sudo did
    /// not confirm the restore (`.restoreNeedsPassword`), pmset failed,
    /// nothing came back in time, or the prompt's process would not stop
    /// (`.stillRunning`).
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
    /// It writes once, as its last step: `pmset -a disablesleep 1`. Every
    /// refusal comes before that write, so none leaves a change of the
    /// command's own, and the start rolls back without running pmset.
    ///
    /// It first ignores SIGPIPE: a refusal printed to a dialog whose output
    /// is gone then still exits with its own status instead of dying by the
    /// signal, which lockf would report as 70 and the start would undo like
    /// a failure. It sets `LC_ALL=C` for every tool it runs, all by
    /// absolute path. Exit 3: the marker no longer holds the nonce (the
    /// start was over before the password was accepted). Exit 4: the clock
    /// (seconds since 1970) is not before the deadline, or `$3` is not a
    /// number `[` can compare, which fails the test and so refuses too.
    /// Exit 5: `$4` is not a positive whole number.
    ///
    /// Then sudo is asked, without running anything, whether the restore
    /// every end and backstop.sh run, `sudo -n /usr/bin/pmset -a
    /// disablesleep 0`, runs for that user without a password. Root drops
    /// to the user with `sudo -n -u "#$4"` and starts the user's sudo with
    /// an empty environment but `LC_ALL=C` and stdin from /dev/null. Exit 5,
    /// with nothing written, unless all three answers are the ones
    /// sudo 1.9.15 to 1.9.x prints for the rule install.sh writes:
    ///
    /// - `sudo -V` shows `Sudo version 1.9.N` (N at least 15, an optional
    ///   `pN`), `Sudoers policy plugin version` with the same version, a
    ///   `Sudoers file grammar version` line, and at most the sudoers I/O
    ///   and audit plugins' own lines after them. Anything else (another
    ///   policy plugin, an approval plugin, which sudo consults only when a
    ///   command runs, a version whose listing has not been checked) fails.
    /// - `sudo -k -n -l` lists the user's rules without a password and
    ///   shows no "Runas and Command-specific defaults" header: Defaults
    ///   bound to a command (`Defaults!/usr/bin/pmset ...`) apply when the
    ///   restore runs but not to a listing, so any such Defaults fail.
    /// - `sudo -k -n -ll /usr/bin/pmset -a disablesleep 0` exits 0 and
    ///   prints exactly the six lines of the matching rule: `Sudoers entry:`
    ///   /private/etc/sudoers.d/insomnia (or /etc/sudoers.d/insomnia),
    ///   `RunAsUsers: root`, `Options: !authenticate` (NOPASSWD, and no
    ///   other option), `Commands:`, a tab and the restore line, and
    ///   `Matched:` with the restore line. sudo picks the last rule that
    ///   matches, as when the command runs, and prints it only when that
    ///   rule allows the command; a denial prints nothing. A rule from
    ///   another file, any other run-as list or option, a time limit, a
    ///   broader command, a path-only answer from an older sudo, a
    ///   truncated or extra line all fail.
    ///
    /// `-k` keeps a credential cached by a recent sudo in a terminal from
    /// answering for the user, and `-n` fails instead of prompting, so a
    /// `listpw` setting that wants a password refuses too. Nothing here can
    /// change the power settings.
    ///
    /// The checks can take a while (sudo may look the user up in a
    /// directory service), so the clock is compared with the deadline again
    /// after them (exit 4). Then root reads `pmset -g` itself, under the
    /// marker's lock: another tool may have turned sleep off while the
    /// password was typed. A SleepDisabled 1 (the first `SleepDisabled`
    /// line with a value, as `PmsetSleepGuard.parseSleepDisabled` reads it),
    /// or a `pmset -g` that fails, exits 6, and that tool's setting stays.
    /// `$5` is `1` only when the journal already owned a 1 before this start
    /// (an earlier restore failed); that 1 is Insomnia's own, so nothing is
    /// read, as at Start. The clock is compared once more, right before the
    /// write (exit 4). A session that ends in the moment between that last
    /// comparison and the write ends at once, because the deadline timer
    /// the start arms next fires immediately for a date in the past.
    ///
    /// What this cannot do: pmset has one SleepDisabled setting and no
    /// compare-and-set, so a 1 another tool sets in the moment between
    /// root's read of 0 and its write cannot be told from Insomnia's own,
    /// and the session's end sets it to 0, as it does for a 1 another tool
    /// sets during a session. A listing is not the restore: a rule removed
    /// after the check, a log sudo cannot write when the command runs, or
    /// other groups for the user when the app or backstop.sh runs sudo than
    /// when root switched to that user, can still make a later restore
    /// fail, and backstop.sh then keeps the journal entry and retries.
    /// pmset is not `exec`ed, so its own exit status can never read as 3 to
    /// 6.
    static let rootCommand = ##"trap '' PIPE; LC_ALL=C; export LC_ALL; m=$(/usr/bin/head -c 64 "$1" 2>/dev/null); if [ -z "$2" ] || [ "$m" != "$2" ]; then echo "the start that asked for this password is over; sleep was not turned off" >&2; exit 3; fi; late() { ! [ "$(/bin/date +%s)" -lt "$1" ] 2>/dev/null; }; if late "$3"; then echo "the session this password was for has already ended; sleep was not turned off" >&2; exit 4; fi; if ! [ "$4" -gt 0 ] 2>/dev/null; then echo "no user id came with the password, so sudo could not be asked whether sleep can be turned back on without one; sleep was not turned off" >&2; exit 5; fi; w=$4; q() { /usr/bin/sudo -n -u "#$w" /usr/bin/env -i LC_ALL=C /usr/bin/sudo "$@" </dev/null; }; v=$(q -V) && printf %s "$v" | /usr/bin/awk 'NR == 1 { k = $0 ~ /^Sudo version 1[.]9[.][0-9]+(p[0-9]+)?$/ && substr($0, 18) + 0 >= 15; v = substr($0, 14); next }; NR == 2 { k = k && $0 == "Sudoers policy plugin version " v; next }; NR == 3 { k = k && $0 ~ /^Sudoers file grammar version [0-9]+$/; next }; $0 == "Sudoers I/O plugin version " v && !i && !a { i = 1; next }; $0 == "Sudoers audit plugin version " v && !a { a = 1; next }; { k = 0 }; END { exit !(k && NR >= 3) }' || { echo "sudo -V, run as this user, failed or does not show sudo 1.9.15 or later with only the sudoers plugins, the only sudo whose answers this check can read; sleep was not turned off" >&2; exit 5; }; l=$(q -k -n -l) && printf %s "$l" | /usr/bin/awk 'index($0, "Runas and Command-specific defaults for ") == 1 { exit 1 }' || { echo "sudo -k -n -l did not list this user's sudoers rules without a password, or listed Runas or command-specific Defaults, which apply to the restore but not to this check; sleep was not turned off" >&2; exit 5; }; r=$(q -k -n -ll /usr/bin/pmset -a disablesleep 0) && printf %s "$r" | /usr/bin/awk 'BEGIN { c = "/usr/bin/pmset -a disablesleep 0" }; NR == 1 { k = $0 == "Sudoers entry: /private/etc/sudoers.d/insomnia" || $0 == "Sudoers entry: /etc/sudoers.d/insomnia" }; NR == 2 { k = k && $0 == "    RunAsUsers: root" }; NR == 3 { k = k && $0 == "    Options: !authenticate" }; NR == 4 { k = k && $0 == "    Commands:" }; NR == 5 { k = k && $0 == sprintf("%c", 9) c }; NR == 6 { k = k && $0 == "    Matched: " c }; END { exit !(k && NR == 6) }' || { echo "sudo -k -n -ll does not show the rule in /etc/sudoers.d/insomnia that lets this user turn sleep back on as root without a password; sleep was not turned off" >&2; exit 5; }; if late "$3"; then echo "the session this password was for ended while sudo was asked about the restore; sleep was not turned off" >&2; exit 4; fi; foreign() { [ "$1" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ "$(printf %s "$s" | /usr/bin/awk '$1 == "SleepDisabled" && NF > 1 { print $2; exit }')" = 1 ]; }; }; if foreign "$5"; then echo "pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off" >&2; exit 6; fi; if late "$3"; then echo "the session this password was for ended while pmset -g was read; sleep was not turned off" >&2; exit 4; fi; /usr/bin/pmset -a disablesleep 1 || exit 1"##
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
    do shell script "/usr/bin/lockf -k -n -t 10 " & quoted form of (item 1 of argv) & " /bin/sh -c " & quoted form of "trap '' PIPE; LC_ALL=C; export LC_ALL; m=$(/usr/bin/head -c 64 \"$1\" 2>/dev/null); if [ -z \"$2\" ] || [ \"$m\" != \"$2\" ]; then echo \"the start that asked for this password is over; sleep was not turned off\" >&2; exit 3; fi; late() { ! [ \"$(/bin/date +%s)\" -lt \"$1\" ] 2>/dev/null; }; if late \"$3\"; then echo \"the session this password was for has already ended; sleep was not turned off\" >&2; exit 4; fi; if ! [ \"$4\" -gt 0 ] 2>/dev/null; then echo \"no user id came with the password, so sudo could not be asked whether sleep can be turned back on without one; sleep was not turned off\" >&2; exit 5; fi; w=$4; q() { /usr/bin/sudo -n -u \"#$w\" /usr/bin/env -i LC_ALL=C /usr/bin/sudo \"$@\" </dev/null; }; v=$(q -V) && printf %s \"$v\" | /usr/bin/awk 'NR == 1 { k = $0 ~ /^Sudo version 1[.]9[.][0-9]+(p[0-9]+)?$/ && substr($0, 18) + 0 >= 15; v = substr($0, 14); next }; NR == 2 { k = k && $0 == \"Sudoers policy plugin version \" v; next }; NR == 3 { k = k && $0 ~ /^Sudoers file grammar version [0-9]+$/; next }; $0 == \"Sudoers I/O plugin version \" v && !i && !a { i = 1; next }; $0 == \"Sudoers audit plugin version \" v && !a { a = 1; next }; { k = 0 }; END { exit !(k && NR >= 3) }' || { echo \"sudo -V, run as this user, failed or does not show sudo 1.9.15 or later with only the sudoers plugins, the only sudo whose answers this check can read; sleep was not turned off\" >&2; exit 5; }; l=$(q -k -n -l) && printf %s \"$l\" | /usr/bin/awk 'index($0, \"Runas and Command-specific defaults for \") == 1 { exit 1 }' || { echo \"sudo -k -n -l did not list this user's sudoers rules without a password, or listed Runas or command-specific Defaults, which apply to the restore but not to this check; sleep was not turned off\" >&2; exit 5; }; r=$(q -k -n -ll /usr/bin/pmset -a disablesleep 0) && printf %s \"$r\" | /usr/bin/awk 'BEGIN { c = \"/usr/bin/pmset -a disablesleep 0\" }; NR == 1 { k = $0 == \"Sudoers entry: /private/etc/sudoers.d/insomnia\" || $0 == \"Sudoers entry: /etc/sudoers.d/insomnia\" }; NR == 2 { k = k && $0 == \"    RunAsUsers: root\" }; NR == 3 { k = k && $0 == \"    Options: !authenticate\" }; NR == 4 { k = k && $0 == \"    Commands:\" }; NR == 5 { k = k && $0 == sprintf(\"%c\", 9) c }; NR == 6 { k = k && $0 == \"    Matched: \" c }; END { exit !(k && NR == 6) }' || { echo \"sudo -k -n -ll does not show the rule in /etc/sudoers.d/insomnia that lets this user turn sleep back on as root without a password; sleep was not turned off\" >&2; exit 5; }; if late \"$3\"; then echo \"the session this password was for ended while sudo was asked about the restore; sleep was not turned off\" >&2; exit 4; fi; foreign() { [ \"$1\" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ \"$(printf %s \"$s\" | /usr/bin/awk '$1 == \"SleepDisabled\" && NF > 1 { print $2; exit }')\" = 1 ]; }; }; if foreign \"$5\"; then echo \"pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off\" >&2; exit 6; fi; if late \"$3\"; then echo \"the session this password was for ended while pmset -g was read; sleep was not turned off\" >&2; exit 4; fi; /usr/bin/pmset -a disablesleep 1 || exit 1" & " insomnia " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv) with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session."
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

    /// The exits that mean the root command stopped before its only write
    /// (`AdministratorPromptError.refused`): its own 3, 4 and 6, and
    /// lockf's 69 (no marker) and 75 (the marker stayed locked), for which
    /// it never started. None of them can come from pmset, whose failure
    /// the command turns into 1, or from a signal, which lockf reports as
    /// 70. 5 is `isRestoreRefusal`.
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

    /// The root command exited 5: sudo did not confirm the restore, and
    /// nothing was written. osascript ends its error line with the shell's
    /// exit status, the same way it ends a cancel with -128.
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
