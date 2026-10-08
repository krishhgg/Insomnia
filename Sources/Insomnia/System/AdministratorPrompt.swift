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
    /// The status alone cannot show whether any of these came after
    /// `disablesleep 1`; the receipt can show that none did (see
    /// `SleepOffReceipts` and `AdministratorPrompt.rootCommand`).
    case failed(status: Int32, stderr: String)
    /// The password was accepted, but the root command could not confirm
    /// that the user who pressed Start can turn sleep back on without a
    /// password (exit 5): no usable uid came with it, /etc/sudo.conf
    /// exists, /etc/pam.d/sudo has session lines other than macOS's own,
    /// root could not switch to that user, or that user's sudo is not
    /// 1.9.17p2 with only the sudoers plugins, did not list without a
    /// password, listed a Defaults entry the check does not accept, or did
    /// not show /etc/sudoers.d/insomnia's restore line as the matching
    /// rule. Every one of these comes before the command writes anything.
    case restoreNeedsPassword(stderr: String)
    /// The root command stopped before it wrote anything, and its exit
    /// status says why: the start was over (3); the session had ended,
    /// before the sudo checks, during them or while `pmset -g` was read
    /// (4); `pmset -g` showed a SleepDisabled 1 the start did not own, or
    /// could not be read (6); or the receipt was missing or unsafe, or
    /// could not be written, synced and read back (7). Or lockf
    /// never started it: the marker was gone (69) or stayed locked for
    /// 10 s (75). `rootStatus` is that status, which osascript ends its
    /// error line with; osascript itself exits 1.
    case refused(rootStatus: Int32, stderr: String)
    case launchFailed(String)

    /// Nothing the caller would undo is left in place: the dialog was
    /// cancelled, osascript never started, or the root command stopped
    /// with one of its refusals (`.restoreNeedsPassword`, `.refused`), all
    /// of which come before its only write. An undo would add nothing but a
    /// chance to clear a SleepDisabled 1 another tool set. Every other
    /// failure may have left `disablesleep 1` in place, so the caller
    /// undoes it like an end, unless the receipt shows that no command for
    /// the start reached its write. `AdministratorPrompt.rootCommand` says
    /// why a refusal keeps its status even when the dialog's output is gone.
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
            return "sleep was not turned off: sudo did not confirm that `sudo -n /usr/bin/pmset -a disablesleep 0` runs for you without a password" + (detail.isEmpty ? "" : " (\(detail))") + ", so a session could not end without you. If /etc/sudoers.d/insomnia is missing or not in effect, run scripts/install.sh again. The check also stops on any sudo but 1.9.17p2, on an /etc/sudo.conf, on session lines in /etc/pam.d/sudo other than macOS's own, and on sudoers Defaults it does not accept. install.sh changes none of those, and the message above names the one found"
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
/// right before its only write. The command never writes the marker: what
/// it did is recorded in the root-owned receipt (`SleepOffReceipts`).
struct PendingStart: Sendable, Equatable {
    let marker: URL
    let nonce: String
    let deadline: Date
    /// The journal already owned a SleepDisabled 1 before this start (an
    /// earlier restore failed), the same `sleepDisabledByUs` Start's own
    /// read is skipped for. Only then does the root command skip its reads
    /// of `pmset -g`; by default it reads, and a 1 stops it.
    var sleepOffIsOurs = false

    /// `deadline` in whole seconds since 1970, rounded down, so a refusal
    /// comes at most a second early, never late. session.json holds the
    /// session's end the same way (ISO 8601 drops the fraction).
    var deadlineSeconds: Int { Int(deadline.timeIntervalSince1970.rounded(.down)) }

    /// `deadlineSeconds` as the root command's `$3`.
    var deadlineArgument: String { String(deadlineSeconds) }

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
    /// that this user can run the restore without a password, while
    /// `pmset -g` shows no SleepDisabled 1 (unless `start.sleepOffIsOurs`),
    /// and after `<nonce> writing` is in the user's receipt, synced and read
    /// back. Throws an `AdministratorPromptError` when the dialog was
    /// cancelled, the password was wrong, the root command stopped before
    /// writing (`.refused`: the marker was gone or no longer matched, the
    /// deadline had passed, someone else's SleepDisabled 1 was found, or the
    /// receipt was missing, unsafe or could not take the record), sudo did
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
    /// Root changes two things: the user's receipt, in a folder only root
    /// can change, and, as its last step, `pmset -a disablesleep 1`. Every
    /// refusal comes before the sleep write, so none leaves a change to the
    /// sleep setting, and the start rolls back without running pmset.
    ///
    /// It first ignores SIGPIPE: a refusal printed to a dialog whose output
    /// is gone then still exits with its own status instead of dying by the
    /// signal, which lockf would report as 70. It sets `LC_ALL=C` for every
    /// tool it runs, all by absolute path. Exit 3: the marker no longer
    /// holds the nonce (the start was over before the password was
    /// accepted). Exit 4: the clock (seconds since 1970) is not before the
    /// deadline, or `$3` is not a number `[` can compare, which fails the
    /// test and so refuses too. Exit 5: `$4` is not a positive whole number.
    ///
    /// Then it checks, without running anything, that the restore every end
    /// and backstop.sh run, `sudo -n /usr/bin/pmset -a disablesleep 0`, runs
    /// for that user without a password. A check that fails exits 5, with
    /// nothing written. Root reads two files first:
    ///
    /// - /private/etc/sudo.conf must not exist in any form, a dangling link
    ///   included. Apple's sudo reads plugins from that one path, compiled
    ///   in, with no environment or command-line override, and without the
    ///   file it uses its built-in sudoers policy, I/O and audit plugins.
    ///   With the file it can load an approval plugin that prints no
    ///   version line, so `sudo -V` and both listings look the same, and
    ///   that plugin is consulted only when a command runs. macOS installs
    ///   no sudo.conf.
    /// - /private/etc/pam.d/sudo must have exactly one line that mentions a
    ///   session, `session required pam_permit.so`, as macOS installs it.
    ///   sudo opens a PAM session only to run a command, never for a
    ///   listing, and a session module that failed would fail the restore.
    ///
    /// The rest ask sudo. Root drops to the user with `sudo -n -u "#$4"` and
    /// starts the user's sudo with an empty environment but `LC_ALL=C` and
    /// stdin from /dev/null. The answers must be the ones sudo 1.9.17p2
    /// (Apple's sudo-114.100.11) prints for the rule install.sh writes. Only
    /// that source was read for what a listing shares with running a
    /// command, so any other version fails:
    ///
    /// - `sudo -V` shows `Sudo version 1.9.17p2`, `Sudoers policy plugin
    ///   version 1.9.17p2`, `Sudoers file grammar version 50`, and at most
    ///   the sudoers I/O and audit plugins' own lines after them.
    /// - `sudo -k -n -l` lists the user's rules without a password, and each
    ///   Defaults entry it shows for the user is one that cannot stop a
    ///   NOPASSWD rule from running: env_reset, env_keep, env_check and
    ///   env_delete, which only choose the environment pmset gets;
    ///   log_allowed and log_denied, which only decide what goes to syslog;
    ///   and lecture, lecture_file, passprompt, badpass_message,
    ///   passwd_timeout, passwd_tries, timestamp_timeout, timestamp_type,
    ///   tty_tickets, pwfeedback and insults, which sudo reads only when it
    ///   asks for a password. Any other entry fails, and the message names
    ///   it. So do Defaults bound to a Runas user or a command (the "Runas
    ///   and Command-specific defaults" header), which apply when the
    ///   restore runs but not to a listing, and a Defaults line with a
    ///   backslash or a tab in it: sudo does not escape a backslash inside
    ///   a quoted value, so such a line cannot be split back into entries
    ///   with certainty. The listing goes to a pipe, so sudo prints all the
    ///   user's Defaults on one line, unwrapped.
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
    /// after them (exit 4).
    ///
    /// Then come the receipt's checks, each of which exits 7 with nothing
    /// written. `$4` must be plain digits with no leading zero and `$2` an
    /// uppercase UUID, since the receipt is named by one and holds the
    /// other. The receipt is /private/var/db/com.kgarg.insomnia/`$4`
    /// (`SleepOffReceipts`). One lstat-based `stat` of it, its folder and
    /// every folder above them up to / must show each one root's, with no
    /// write permission for group or others, the receipt a regular file
    /// with one link and 45 bytes, and the rest folders; `ls -lde` must
    /// show no access control entry that allows anything on any of them. A
    /// link anywhere on that path fails the type check, so root's write
    /// below never follows a path the user can change.
    ///
    /// Then root reads `pmset -g` itself, under the marker's lock: another
    /// tool may have turned sleep off while the password was typed. A
    /// SleepDisabled 1 (the first `SleepDisabled` line with a value, as
    /// `PmsetSleepGuard.parseSleepDisabled` reads it), or a `pmset -g` that
    /// fails, exits 6 with nothing written, and that tool's setting stays.
    /// `$5` is `1` only when the journal already owned a 1 before this start
    /// (an earlier restore failed); that 1 is Insomnia's own, so nothing is
    /// read, as at Start.
    ///
    /// Only then does root write the receipt: `<nonce> writing` and a
    /// newline, 45 bytes over the file's 45 with `dd conv=notrunc,fsync`,
    /// so the file keeps its inode, owner and size, and `dd` returns only
    /// after fsync(2). It reads the bytes back and compares them. A failure
    /// tries to write `<nonce> refused` and exits 7. The clock is compared
    /// once more (exit 4, after `<nonce> refused`), and the last step is
    /// `pmset -a disablesleep 1`. A session that ends in the moment between
    /// that comparison and the write ends at once, because the deadline
    /// timer the start arms next fires immediately for a date in the past.
    ///
    /// So once the marker a start wrote is gone under its lock, no command
    /// for that start can write again, and a receipt that is still the file
    /// it was when the start began and holds another nonce, or this nonce
    /// with `refused`, shows that none did. Every reader that settles a
    /// start the journal still records (the next transaction, backstop.sh,
    /// uninstall.sh) or a live start whose failure status it cannot trust
    /// (a lost answer, a signal, a timeout) reads that, and then puts the
    /// journal back without an undo, which would clear a SleepDisabled 1
    /// another tool set meanwhile (SessionManager). Anything else, this
    /// nonce with `writing` included, is undone like an end.
    ///
    /// What this cannot do: pmset has one SleepDisabled setting and no
    /// compare-and-set, so a 1 another tool sets in the moment between
    /// root's read of 0 and its write cannot be told from Insomnia's own,
    /// and the session's end sets it to 0, as it does for a 1 another tool
    /// sets during a session. A failure after `<nonce> writing` is undone
    /// even when it came before the write. fsync(2) is not F_FULLFSYNC: it
    /// does not flush the drive's own cache, and no tool the command can
    /// run does. After a power cut the receipt can come back with a torn
    /// mix, which is not a valid line and reads as "may have written", or
    /// with its older content while pmset's write survived. The older
    /// content reads as "never", the journal entry goes, and a
    /// SleepDisabled 1 that survived is then reported as set by something
    /// else, with the command that clears it. The marker's lock is advisory, so a process
    /// running as the user can still delete or replace the marker while a
    /// root command holds it; the receipt then shows what that command did,
    /// once it ends. A listing is not the restore: a rule removed, a
    /// sudo.conf or PAM change, or a host name or group membership that
    /// changes which Defaults apply, after the check, can still make a
    /// later restore fail, and backstop.sh then keeps the journal entry and
    /// retries. pmset is not `exec`ed, so its own exit status can never
    /// read as 3 to 7.
    static let rootCommand = ##"trap '' PIPE; LC_ALL=C; export LC_ALL; m=$(/usr/bin/head -c 64 "$1" 2>/dev/null); if [ -z "$2" ] || [ "$m" != "$2" ]; then echo "the start that asked for this password is over; sleep was not turned off" >&2; exit 3; fi; late() { ! [ "$(/bin/date +%s)" -lt "$1" ] 2>/dev/null; }; if late "$3"; then echo "the session this password was for has already ended; sleep was not turned off" >&2; exit 4; fi; if ! [ "$4" -gt 0 ] 2>/dev/null; then echo "no user id came with the password, so sudo could not be asked whether sleep can be turned back on without one; sleep was not turned off" >&2; exit 5; fi; c=/private/etc/sudo.conf; if [ -e "$c" ] || [ -L "$c" ]; then echo "/etc/sudo.conf exists. sudo -V does not list every plugin that file can load, and an approval plugin can show nothing there and still refuse the restore, so this check works only with sudo's built-in plugins and no /etc/sudo.conf; sleep was not turned off" >&2; exit 5; fi; /usr/bin/awk '$1 !~ /^#/ && tolower($0) ~ /session/ { n++; k = $1 == "session" && $2 == "required" && $3 == "pam_permit.so" && NF == 3 }; END { exit !(n == 1 && k) }' /private/etc/pam.d/sudo 2>/dev/null || { echo "/etc/pam.d/sudo could not be read, or its session lines are not macOS's own single session required pam_permit.so. sudo runs them for the restore but not for a listing, so this check cannot tell whether the restore runs; sleep was not turned off" >&2; exit 5; }; w=$4; u() { /usr/bin/sudo -n -u "#$w" /usr/bin/env -i LC_ALL=C "$@" </dev/null; }; q() { u /usr/bin/sudo "$@"; }; v=$(q -V) && printf %s "$v" | /usr/bin/awk 'BEGIN { v = "1.9.17p2" }; NR == 1 { k = $0 == "Sudo version " v; next }; NR == 2 { k = k && $0 == "Sudoers policy plugin version " v; next }; NR == 3 { k = k && $0 == "Sudoers file grammar version 50"; next }; $0 == "Sudoers I/O plugin version " v && !i && !a { i = 1; next }; $0 == "Sudoers audit plugin version " v && !a { a = 1; next }; { k = 0 }; END { exit !(k && NR >= 3) }' || { echo "sudo -V, run as this user, failed or does not show sudo 1.9.17p2 with only the sudoers plugins. This check follows how sudo 1.9.17p2 lists and runs commands, and another version needs an Insomnia release checked against it; sleep was not turned off" >&2; exit 5; }; l=$(q -k -n -l) || { echo "sudo -k -n -l did not list this user's sudoers rules without a password; sleep was not turned off" >&2; exit 5; }; d=$(printf %s "$l" | /usr/bin/awk 'function ok(e, n, o) { o = ""; n = e; if (match(n, /[-+]?=/)) { o = substr(n, RSTART, RLENGTH); n = substr(n, 1, RSTART - 1) }; if (n ~ /^!/) return (o == "" && index(" env_reset env_keep env_check env_delete lecture lecture_file log_allowed log_denied passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type tty_tickets pwfeedback insults ", " " substr(n, 2) " ") > 0); if (o == "") return (index(" env_reset lecture log_allowed log_denied tty_tickets pwfeedback insults ", " " n " ") > 0); if (o != "=") return (index(" env_keep env_check env_delete ", " " n " ") > 0); return (index(" env_keep env_check env_delete lecture lecture_file passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type ", " " n " ") > 0) }; NR == 1 && index($0, "Matching Defaults entries for ") == 1 { s = 1; next }; s == 1 { s = 2; t = $0; if (substr(t, 1, 4) != "    " || index(t, sprintf("%c", 92)) || index(t, sprintf("%c", 9))) { print "a backslash, a tab or a layout it cannot read"; f = 1; exit }; t = substr(t, 5); while (1) { if (!match(t, /^!?[a-z_]+([-+]?=("[^"]*"|[^ ",:=#]*))?/)) { print substr(t, 1, 80); f = 1; exit }; e = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1); if (!ok(e)) { print substr(e, 1, 80); f = 1; exit }; if (t == "") break; if (substr(t, 1, 2) != ", ") { print substr(t, 1, 80); f = 1; exit }; t = substr(t, 3) }; next }; s == 2 { if ($0 != "") { print "a layout it cannot read"; f = 1; exit }; s = 3; next }; index($0, "Runas and Command-specific defaults for ") == 1 { print "Defaults bound to a Runas user or a command, which apply to the restore but not to a listing"; f = 1; exit }; index($0, "Matching Defaults entries for ") == 1 { print "a layout it cannot read"; f = 1; exit }; END { exit f || s == 1 || s == 2 }') || { echo "sudo -k -n -l shows a Defaults entry this check does not accept: ${d:-output it cannot read}. Settings like that can make the restore fail where a listing does not; sleep was not turned off" >&2; exit 5; }; r=$(q -k -n -ll /usr/bin/pmset -a disablesleep 0) && printf %s "$r" | /usr/bin/awk 'BEGIN { c = "/usr/bin/pmset -a disablesleep 0" }; NR == 1 { k = $0 == "Sudoers entry: /private/etc/sudoers.d/insomnia" || $0 == "Sudoers entry: /etc/sudoers.d/insomnia" }; NR == 2 { k = k && $0 == "    RunAsUsers: root" }; NR == 3 { k = k && $0 == "    Options: !authenticate" }; NR == 4 { k = k && $0 == "    Commands:" }; NR == 5 { k = k && $0 == sprintf("%c", 9) c }; NR == 6 { k = k && $0 == "    Matched: " c }; END { exit !(k && NR == 6) }' || { echo "sudo -k -n -ll does not show the rule in /etc/sudoers.d/insomnia that lets this user turn sleep back on as root without a password; sleep was not turned off" >&2; exit 5; }; if late "$3"; then echo "the session this password was for ended while sudo was asked about the restore; sleep was not turned off" >&2; exit 4; fi; bad() { echo "$1; sleep was not turned off" >&2; exit 7; }; case $4 in *[!0-9]*|0*) bad "the user id $4 is not plain digits, so it names no receipt";; esac; case $2 in *[!0-9A-F-]*) bad "the nonce is not an uppercase UUID, so it cannot go in the receipt";; esac; [ ${#2} -eq 36 ] || bad "the nonce is not an uppercase UUID, so it cannot go in the receipt"; k=/private/var/db/com.kgarg.insomnia; f=$k/$4; a=$f; n=1; p=$k; while [ -n "$p" ]; do a="$a $p"; n=$((n + 1)); p=${p%/*}; done; a="$a /"; n=$((n + 1)); t=$(/usr/bin/stat -f '%u %Lp %l %z %HT' $a 2>/dev/null) && printf '%s\n' "$t" | /usr/bin/awk -v o=0 -v n=$n 'NR == 1 { k = NF == 6 && $5 == "Regular" && $6 == "File" && $3 == 1 && $4 == 45 }; NR > 1 { k = k && NF == 5 && $5 == "Directory" }; { k = k && ($1 == 0 || $1 == o) && $2 !~ /[2367].?$/ }; END { exit !(k && NR == n) }' && l=$(/bin/ls -lde $a 2>/dev/null) && printf '%s\n' "$l" | /usr/bin/awk '$1 ~ /^[0-9]+:$/ && / allow / { f = 1 }; END { exit f }' || bad "$f is missing, is not the 45-byte file install.sh made, or someone other than root can change it or a folder above it. Run install.sh again"; foreign() { [ "$1" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ "$(printf %s "$s" | /usr/bin/awk '$1 == "SleepDisabled" && NF > 1 { print $2; exit }')" = 1 ]; }; }; if foreign "$5"; then echo "pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off" >&2; exit 6; fi; put() { printf '%s %s\n' "$2" "$1" | /bin/dd of="$f" conv=notrunc,fsync 2>/dev/null && [ "$(/usr/bin/head -c 45 "$f" 2>/dev/null)" = "$2 $1" ]; }; put writing "$2" || { put refused "$2"; bad "$f could not be written, synced and read back with this start's nonce"; }; if late "$3"; then put refused "$2"; echo "the session this password was for ended while pmset -g was read; sleep was not turned off" >&2; exit 4; fi; /usr/bin/pmset -a disablesleep 1 || exit 1"##
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
    do shell script "/usr/bin/lockf -k -n -t 10 " & quoted form of (item 1 of argv) & " /bin/sh -c " & quoted form of "trap '' PIPE; LC_ALL=C; export LC_ALL; m=$(/usr/bin/head -c 64 \"$1\" 2>/dev/null); if [ -z \"$2\" ] || [ \"$m\" != \"$2\" ]; then echo \"the start that asked for this password is over; sleep was not turned off\" >&2; exit 3; fi; late() { ! [ \"$(/bin/date +%s)\" -lt \"$1\" ] 2>/dev/null; }; if late \"$3\"; then echo \"the session this password was for has already ended; sleep was not turned off\" >&2; exit 4; fi; if ! [ \"$4\" -gt 0 ] 2>/dev/null; then echo \"no user id came with the password, so sudo could not be asked whether sleep can be turned back on without one; sleep was not turned off\" >&2; exit 5; fi; c=/private/etc/sudo.conf; if [ -e \"$c\" ] || [ -L \"$c\" ]; then echo \"/etc/sudo.conf exists. sudo -V does not list every plugin that file can load, and an approval plugin can show nothing there and still refuse the restore, so this check works only with sudo's built-in plugins and no /etc/sudo.conf; sleep was not turned off\" >&2; exit 5; fi; /usr/bin/awk '$1 !~ /^#/ && tolower($0) ~ /session/ { n++; k = $1 == \"session\" && $2 == \"required\" && $3 == \"pam_permit.so\" && NF == 3 }; END { exit !(n == 1 && k) }' /private/etc/pam.d/sudo 2>/dev/null || { echo \"/etc/pam.d/sudo could not be read, or its session lines are not macOS's own single session required pam_permit.so. sudo runs them for the restore but not for a listing, so this check cannot tell whether the restore runs; sleep was not turned off\" >&2; exit 5; }; w=$4; u() { /usr/bin/sudo -n -u \"#$w\" /usr/bin/env -i LC_ALL=C \"$@\" </dev/null; }; q() { u /usr/bin/sudo \"$@\"; }; v=$(q -V) && printf %s \"$v\" | /usr/bin/awk 'BEGIN { v = \"1.9.17p2\" }; NR == 1 { k = $0 == \"Sudo version \" v; next }; NR == 2 { k = k && $0 == \"Sudoers policy plugin version \" v; next }; NR == 3 { k = k && $0 == \"Sudoers file grammar version 50\"; next }; $0 == \"Sudoers I/O plugin version \" v && !i && !a { i = 1; next }; $0 == \"Sudoers audit plugin version \" v && !a { a = 1; next }; { k = 0 }; END { exit !(k && NR >= 3) }' || { echo \"sudo -V, run as this user, failed or does not show sudo 1.9.17p2 with only the sudoers plugins. This check follows how sudo 1.9.17p2 lists and runs commands, and another version needs an Insomnia release checked against it; sleep was not turned off\" >&2; exit 5; }; l=$(q -k -n -l) || { echo \"sudo -k -n -l did not list this user's sudoers rules without a password; sleep was not turned off\" >&2; exit 5; }; d=$(printf %s \"$l\" | /usr/bin/awk 'function ok(e, n, o) { o = \"\"; n = e; if (match(n, /[-+]?=/)) { o = substr(n, RSTART, RLENGTH); n = substr(n, 1, RSTART - 1) }; if (n ~ /^!/) return (o == \"\" && index(\" env_reset env_keep env_check env_delete lecture lecture_file log_allowed log_denied passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type tty_tickets pwfeedback insults \", \" \" substr(n, 2) \" \") > 0); if (o == \"\") return (index(\" env_reset lecture log_allowed log_denied tty_tickets pwfeedback insults \", \" \" n \" \") > 0); if (o != \"=\") return (index(\" env_keep env_check env_delete \", \" \" n \" \") > 0); return (index(\" env_keep env_check env_delete lecture lecture_file passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type \", \" \" n \" \") > 0) }; NR == 1 && index($0, \"Matching Defaults entries for \") == 1 { s = 1; next }; s == 1 { s = 2; t = $0; if (substr(t, 1, 4) != \"    \" || index(t, sprintf(\"%c\", 92)) || index(t, sprintf(\"%c\", 9))) { print \"a backslash, a tab or a layout it cannot read\"; f = 1; exit }; t = substr(t, 5); while (1) { if (!match(t, /^!?[a-z_]+([-+]?=(\"[^\"]*\"|[^ \",:=#]*))?/)) { print substr(t, 1, 80); f = 1; exit }; e = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1); if (!ok(e)) { print substr(e, 1, 80); f = 1; exit }; if (t == \"\") break; if (substr(t, 1, 2) != \", \") { print substr(t, 1, 80); f = 1; exit }; t = substr(t, 3) }; next }; s == 2 { if ($0 != \"\") { print \"a layout it cannot read\"; f = 1; exit }; s = 3; next }; index($0, \"Runas and Command-specific defaults for \") == 1 { print \"Defaults bound to a Runas user or a command, which apply to the restore but not to a listing\"; f = 1; exit }; index($0, \"Matching Defaults entries for \") == 1 { print \"a layout it cannot read\"; f = 1; exit }; END { exit f || s == 1 || s == 2 }') || { echo \"sudo -k -n -l shows a Defaults entry this check does not accept: ${d:-output it cannot read}. Settings like that can make the restore fail where a listing does not; sleep was not turned off\" >&2; exit 5; }; r=$(q -k -n -ll /usr/bin/pmset -a disablesleep 0) && printf %s \"$r\" | /usr/bin/awk 'BEGIN { c = \"/usr/bin/pmset -a disablesleep 0\" }; NR == 1 { k = $0 == \"Sudoers entry: /private/etc/sudoers.d/insomnia\" || $0 == \"Sudoers entry: /etc/sudoers.d/insomnia\" }; NR == 2 { k = k && $0 == \"    RunAsUsers: root\" }; NR == 3 { k = k && $0 == \"    Options: !authenticate\" }; NR == 4 { k = k && $0 == \"    Commands:\" }; NR == 5 { k = k && $0 == sprintf(\"%c\", 9) c }; NR == 6 { k = k && $0 == \"    Matched: \" c }; END { exit !(k && NR == 6) }' || { echo \"sudo -k -n -ll does not show the rule in /etc/sudoers.d/insomnia that lets this user turn sleep back on as root without a password; sleep was not turned off\" >&2; exit 5; }; if late \"$3\"; then echo \"the session this password was for ended while sudo was asked about the restore; sleep was not turned off\" >&2; exit 4; fi; bad() { echo \"$1; sleep was not turned off\" >&2; exit 7; }; case $4 in *[!0-9]*|0*) bad \"the user id $4 is not plain digits, so it names no receipt\";; esac; case $2 in *[!0-9A-F-]*) bad \"the nonce is not an uppercase UUID, so it cannot go in the receipt\";; esac; [ ${#2} -eq 36 ] || bad \"the nonce is not an uppercase UUID, so it cannot go in the receipt\"; k=/private/var/db/com.kgarg.insomnia; f=$k/$4; a=$f; n=1; p=$k; while [ -n \"$p\" ]; do a=\"$a $p\"; n=$((n + 1)); p=${p%/*}; done; a=\"$a /\"; n=$((n + 1)); t=$(/usr/bin/stat -f '%u %Lp %l %z %HT' $a 2>/dev/null) && printf '%s\\n' \"$t\" | /usr/bin/awk -v o=0 -v n=$n 'NR == 1 { k = NF == 6 && $5 == \"Regular\" && $6 == \"File\" && $3 == 1 && $4 == 45 }; NR > 1 { k = k && NF == 5 && $5 == \"Directory\" }; { k = k && ($1 == 0 || $1 == o) && $2 !~ /[2367].?$/ }; END { exit !(k && NR == n) }' && l=$(/bin/ls -lde $a 2>/dev/null) && printf '%s\\n' \"$l\" | /usr/bin/awk '$1 ~ /^[0-9]+:$/ && / allow / { f = 1 }; END { exit f }' || bad \"$f is missing, is not the 45-byte file install.sh made, or someone other than root can change it or a folder above it. Run install.sh again\"; foreign() { [ \"$1\" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ \"$(printf %s \"$s\" | /usr/bin/awk '$1 == \"SleepDisabled\" && NF > 1 { print $2; exit }')\" = 1 ]; }; }; if foreign \"$5\"; then echo \"pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off\" >&2; exit 6; fi; put() { printf '%s %s\\n' \"$2\" \"$1\" | /bin/dd of=\"$f\" conv=notrunc,fsync 2>/dev/null && [ \"$(/usr/bin/head -c 45 \"$f\" 2>/dev/null)\" = \"$2 $1\" ]; }; put writing \"$2\" || { put refused \"$2\"; bad \"$f could not be written, synced and read back with this start's nonce\"; }; if late \"$3\"; then put refused \"$2\"; echo \"the session this password was for ended while pmset -g was read; sleep was not turned off\" >&2; exit 4; fi; /usr/bin/pmset -a disablesleep 1 || exit 1" & " insomnia " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv) with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session."
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
    /// (`AdministratorPromptError.refused`): its own 3, 4, 6 and 7, and
    /// lockf's 69 (no marker) and 75 (the marker stayed locked), for which
    /// it never started. None of them can come from pmset, whose failure
    /// the command turns into 1, or from a signal, which lockf reports as
    /// 70. 5 is `isRestoreRefusal`.
    static let refusalStatuses: Set<Int32> = [3, 4, 6, 7, 69, 75]

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
