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
    /// `SleepOffReceipts` and `AdministratorPrompt.rootCommand`). osascript
    /// exited by itself, so its dialog is over.
    case failed(status: Int32, stderr: String)
    /// A signal the runner did not send stopped osascript. A command it
    /// had started as root may still be running, or about to start.
    case interrupted(signal: Int32, stderr: String)
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
    /// before the sudo checks, during them or while `pmset -g` was read,
    /// or the start had run out of time for an answer (4); `pmset -g`
    /// showed a SleepDisabled 1 the start did not own, or could not be read
    /// (6); the receipt was missing, unsafe or not the file the start
    /// claimed, or could not be written, flushed and read back (7); or the
    /// receipt no longer held the nonce the start claimed it from: another
    /// start or a recovery came first (8). Or the receipt stayed locked for
    /// 10 s (75), or lockf never started the command: the marker was gone
    /// (69) or stayed locked for 10 s (75). `rootStatus` is that status,
    /// which osascript ends its error line with; osascript itself exits 1.
    case refused(rootStatus: Int32, stderr: String)
    case launchFailed(String)

    /// Nothing the caller would undo is left in place: the dialog was
    /// cancelled, osascript never started, or the root command stopped
    /// with one of its refusals (`.restoreNeedsPassword`, `.refused`), all
    /// of which come before the sleep write. An undo would add nothing but
    /// a chance to clear a SleepDisabled 1 another tool set. Every other
    /// failure may have left `disablesleep 1` in place, so the caller
    /// undoes it like an end, unless the receipt shows that no command for
    /// the start reached that write. `AdministratorPrompt.rootCommand` says
    /// why a refusal keeps its status even when the dialog's output is gone.
    var nothingToUndo: Bool {
        switch self {
        case .cancelled, .launchFailed, .restoreNeedsPassword, .refused: true
        case .timedOut, .stillRunning, .failed, .interrupted: false
        }
    }

    /// The dialog has ended by itself: osascript exited on its own, after
    /// the command it ran as root (if any) exited, and no other command
    /// can start for that dialog. A timeout, a prompt left running and a
    /// signal the runner did not send leave that open: a command may still
    /// start, or hold the receipt, until the start's answer window ends.
    var dialogOver: Bool {
        switch self {
        case .cancelled, .launchFailed, .restoreNeedsPassword, .refused, .failed: true
        case .timedOut, .stillRunning, .interrupted: false
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
        case let .interrupted(signal, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "osascript, behind the administrator password prompt, was stopped by signal \(signal)" + (detail.isEmpty ? "" : ": \(detail)")
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
/// cannot act for a newer start. Nor can an answer that comes at or after
/// `expires` (the session's end, or `AdministratorPrompt.answerWindow`
/// after the marker, if sooner) leave sleep off: the root command compares
/// it with the clock once it holds the receipt's lock, again after the
/// sudo checks, and again right before pmset. The command never writes the
/// marker: what it did is recorded in the root-owned receipt
/// (`SleepOffReceipts`), and only while the receipt still holds
/// `predecessor`.
struct PendingStart: Sendable, Equatable {
    let marker: URL
    let nonce: String
    /// The session's end.
    let deadline: Date
    /// The journal already owned a SleepDisabled 1 before this start (an
    /// earlier restore failed), the same `sleepDisabledByUs` Start's own
    /// read is skipped for. Only then does the root command skip its reads
    /// of `pmset -g`; by default it reads, and a 1 stops it.
    var sleepOffIsOurs: Bool
    /// The receipt's nonce when this start claimed it
    /// (`SleepOffReceipts.claim`).
    var predecessor: String
    /// "device:inode" of the receipt this start claimed.
    var receipt: String
    /// From when the root command refuses. Set again when the marker is
    /// written, and journaled with it.
    var expires: Date

    init(marker: URL, nonce: String, deadline: Date, sleepOffIsOurs: Bool = false, predecessor: String = SleepOffReceipts.zero, receipt: String = "", expires: Date? = nil) {
        self.marker = marker
        self.nonce = nonce
        self.deadline = deadline
        self.sleepOffIsOurs = sleepOffIsOurs
        self.predecessor = predecessor
        self.receipt = receipt
        self.expires = expires ?? deadline
    }

    /// `deadline` in whole seconds since 1970, rounded down. session.json
    /// holds the session's end the same way (ISO 8601 drops the fraction).
    var deadlineSeconds: Int { Int(deadline.timeIntervalSince1970.rounded(.down)) }

    /// `expires` in whole seconds since 1970, rounded down, so a refusal
    /// comes at most a second early, never late.
    var expiresSeconds: Int { Int(expires.timeIntervalSince1970.rounded(.down)) }

    /// `expiresSeconds` as the root command's `$3`.
    var expiresArgument: String { String(expiresSeconds) }

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
    /// only under the receipt's lock, while `start.marker` holds
    /// `start.nonce` and the receipt holds `start.predecessor`, before
    /// `start.expires`, once sudo has confirmed without running anything
    /// that this user can run the restore without a password, while
    /// `pmset -g` shows no SleepDisabled 1 (unless `start.sleepOffIsOurs`),
    /// and after `<nonce> <predecessor> writing` is in the user's receipt,
    /// flushed and read back. Throws an `AdministratorPromptError` when the
    /// dialog was cancelled, the password was wrong, the root command
    /// stopped before writing (`.refused`: the marker was gone or no longer
    /// matched, the start had expired, someone else's SleepDisabled 1 was
    /// found, the receipt was missing, unsafe, locked, claimed by another
    /// start or could not take the record), sudo did not confirm the
    /// restore (`.restoreNeedsPassword`), pmset failed, a signal stopped
    /// osascript (`.interrupted`), nothing came back in time, or the
    /// prompt's process would not stop (`.stillRunning`).
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
    /// <marker> <nonce> <expires> <uid> <owned> <predecessor> <receipt>`.
    /// Fixed text: the marker path, the nonce, the time from which the
    /// start takes no answer (`PendingStart.expires`), the uid of the user
    /// who pressed Start, whether the journal already owned a SleepDisabled
    /// 1, the nonce the start claimed the receipt from and the receipt's
    /// "device:inode" arrive only as `$1` to `$7`, and the marker's and the
    /// receipt's content are only compared, never run. Root changes two
    /// things: the user's receipt, in a folder only root can change, and,
    /// as its last step, `pmset -a disablesleep 1`. Every refusal comes
    /// before the sleep write, so none leaves a change to the sleep
    /// setting, and the start rolls back without running pmset.
    ///
    /// It first ignores SIGPIPE: a refusal printed to a dialog whose output
    /// is gone then still exits with its own status instead of dying by the
    /// signal, which lockf would report as 70. It sets `LC_ALL=C` for every
    /// tool it runs, all by absolute path. Exit 5: `$4` is not a positive
    /// whole number. Exit 7: it is not plain digits with no leading zero,
    /// so it names no receipt.
    ///
    /// Then, before any other check, it takes the receipt's lock. It opens
    /// /private/var/db/com.kgarg.insomnia/`$4` (`SleepOffReceipts`)
    /// read-only as descriptor 8 (exit 7 when it cannot) and runs `lockf -s
    /// -t 10 8`, which takes an exclusive flock(2) lock on that open file
    /// and exits, leaving the lock with the shell's descriptor. A receipt
    /// that stays locked for 10 s exits 75. The shell never closes
    /// descriptor 8, and every tool it starts afterwards inherits it, pmset
    /// included, so the lock lasts until the shell and pmset have both
    /// exited; nothing in the command releases it earlier. The app,
    /// backstop.sh and uninstall.sh take the same lock on the same file
    /// before a start claims the receipt, before they read it to settle a
    /// start and before uninstall.sh removes it, so each reads the receipt
    /// before a command took the lock or after the command and its pmset
    /// exited.
    ///
    /// Under the lock, one lstat-based `stat` of the receipt, its folder and
    /// every folder above them up to / must show each one root's, with no
    /// write permission for group or others, the receipt a regular file
    /// with one link, 82 bytes and mode 600, and the rest folders. `ls -lde`
    /// must show no access control entry that allows anything on the
    /// folders, and `ls -le` exactly one on the receipt, `0: user:<name>
    /// allow read`, where `id -u <name>` is `$4`: ls(1) prints `inherited`
    /// after the name of an inherited entry, every right after `allow`, and
    /// a UUID in place of `user:<name>` for an account the directory cannot
    /// name, so each of those fails. So no other account can open the
    /// receipt and hold its lock. ls(1) never prints synchronize, prints the
    /// rights and flags only folders use only for a folder, and skips an
    /// entry it cannot read, so those pass here; the app's own check
    /// (`SleepOffReceipts`) reads every entry, right and flag. A link anywhere on
    /// that path fails the type check. Both the open descriptor
    /// and the path must be the file `$7` names, the one the start claimed.
    /// Each of these exits 7. Exit 3: the marker no longer holds the nonce
    /// (the start was over before the password was accepted). Exit 4: the
    /// clock (seconds since 1970) is not before `$3`, or `$3` is not a
    /// number `[` can compare, which fails the test and so refuses too.
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
    /// directory service), so the clock is compared with `$3` again after
    /// them (exit 4).
    ///
    /// Then the receipt's line. `$2` and `$6` must be two different
    /// uppercase UUIDs, and `$2` not the zero one (exit 7). The receipt must
    /// still begin with `$6`, the nonce the start claimed it from (exit 8):
    /// otherwise another start's command, or a newer claim, came first.
    /// Then root reads `pmset -g` itself: another tool may have turned
    /// sleep off while the password was typed. A SleepDisabled 1 (the first
    /// `SleepDisabled` line with a value, as
    /// `PmsetSleepGuard.parseSleepDisabled` reads it), or a `pmset -g` that
    /// fails, exits 6 with nothing written, and that tool's setting stays.
    /// `$5` is `1` only when the journal already owned a 1 before this start
    /// (an earlier restore failed); that 1 is Insomnia's own, so nothing is
    /// read, as at Start.
    ///
    /// Only then does root write the receipt: `<nonce> <predecessor>
    /// writing` and a newline, 82 bytes over the file's 82. /usr/bin/perl,
    /// with an empty environment and descriptor 8 as its input, opens the
    /// path for writing without creating, truncating or following a link,
    /// checks that the descriptor it got is the locked file (same device
    /// and inode as its input), writes the line with one write(2) that must
    /// write all 82 bytes, calls fcntl(F_FULLFSYNC) (51), closes the file,
    /// opens it again and reads the line back. fcntl(2) describes
    /// F_FULLFSYNC as fsync(2) followed by a request to the drive to flush
    /// its own cache, and notes that some drives ignore that request. Any
    /// failure, a missing perl included, tries to write `<nonce>
    /// <predecessor> refused` the same way and exits 7.
    ///
    /// Every `refused` goes through `no`, which runs only on a branch that
    /// has already decided to exit without the sleep write, while the
    /// command still holds the receipt's lock. When the write, flush or
    /// read-back fails, `no` waits a second and tries again, at most three
    /// tries in all, and starts a try only while fewer than 3 seconds of
    /// `/bin/date` have passed since the first failure: a clock it cannot
    /// read allows no retry. Each try is the same perl program, so it
    /// checks the locked inode, writes the whole line, flushes it with
    /// F_FULLFSYNC and reads it back. When every try fails, the message
    /// says so, and the exit status stays the branch's own (7, 6 or 4).
    /// The limit counts tries and time between them, not one try: a
    /// write or flush the drive stalls holds the command, and the
    /// receipt's lock, for as long as it stalls. Storage that stays broken
    /// leaves the line as it was, and a reader that never gets the exit
    /// status may still undo the start like an end (below). Then root reads
    /// `pmset -g` once more, as before, unless `$5` is `1`: the write and
    /// its flush can take a while, and another tool may have turned sleep
    /// off meanwhile. A SleepDisabled 1, or a read that fails, writes
    /// `refused` the same way and exits 6, and that tool's setting stays.
    /// The clock is compared once more (exit 4, after `refused` is
    /// written), and the last step is `pmset -a disablesleep 1`. A session that ends in the
    /// moment between that comparison and the write ends at once, because
    /// the deadline timer the start arms next fires immediately for a date
    /// in the past.
    ///
    /// So a start's own line, `refused`, shows that its command never
    /// turned sleep off, and so does another start's line that names the
    /// same predecessor: that start wrote first, and this start's command
    /// cannot write once the receipt no longer holds the predecessor.
    /// Once the start's dialog is over, or `$3` has passed, a receipt that
    /// still holds the predecessor shows it too: a command that took the
    /// lock later refuses with 4 before writing. Every reader that settles
    /// a start the journal still records (the next transaction,
    /// backstop.sh, uninstall.sh) reads that under the lock, and then puts
    /// the journal back without an undo, which would clear a SleepDisabled
    /// 1 another tool set meanwhile (SessionManager). The start's own
    /// `writing`, a line it cannot place, and a receipt it cannot lock as
    /// the file the start claimed once `$3` has passed are undone like an
    /// end. Before then a receipt that still holds the predecessor, or that
    /// is locked, decides nothing: the start stays journaled, Starts stay
    /// refused, and the next transaction or recovery reads it again.
    ///
    /// What this cannot do: pmset has one SleepDisabled setting and no
    /// compare-and-set, so a 1 another tool sets between root's last read
    /// of 0 and its write cannot be told from Insomnia's own, and the
    /// session's end sets it to 0, as it does for a 1 another tool sets
    /// during a session. The second read only moves that window past the
    /// receipt's write and flush; it is not a lock on the setting. A
    /// failure after `writing` is undone even when it came before the
    /// sleep write. So is a second read that refused but could not write
    /// `refused` over `writing` in any of its tries, when the app never gets its exit 6 (it
    /// died), or gets it but cannot journal the rollback before it quits
    /// or backstop.sh or uninstall.sh settles the start: every reader but
    /// that app then sees `writing`, undoes the start like an end, and
    /// clears the 1 the second read found. The receipt, the journal and pmset's own
    /// setting are separate files, and nothing makes the three change
    /// together: F_FULLFSYNC only puts the receipt's line on the drive
    /// before pmset runs, on a drive that honours it. The clock is the
    /// wall clock, as session.json's end is: a clock set back after a
    /// settlement lets a dialog left on screen pass the comparison with
    /// `$3` again, though only while the marker still holds its nonce. The
    /// marker's lock and the receipt's lock are advisory, so anything
    /// running as root can still change either file while a command holds
    /// it; the receipt then shows nothing about that command, and the
    /// start is undone like an end. A listing is not the restore: a rule
    /// removed, a sudo.conf or PAM change, or a host name or group
    /// membership that changes which Defaults apply, after the check, can
    /// still make a later restore fail, and backstop.sh then keeps the
    /// journal entry and retries. pmset is not `exec`ed, so its own exit
    /// status can never read as 3 to 8.
    static let rootCommand = ##"trap '' PIPE; LC_ALL=C; export LC_ALL; if ! [ "$4" -gt 0 ] 2>/dev/null; then echo "no user id came with the password, so sudo could not be asked whether sleep can be turned back on without one; sleep was not turned off" >&2; exit 5; fi; bad() { echo "$1; sleep was not turned off" >&2; exit 7; }; case $4 in *[!0-9]*|0*) bad "the user id $4 is not plain digits, so it names no receipt";; esac; k=/private/var/db/com.kgarg.insomnia; f=$k/$4; { exec 8<"$f"; } 2>/dev/null || bad "$f could not be opened. Run install.sh again"; /usr/bin/lockf -s -t 10 8 || { echo "$f stayed locked for 10 s by another Insomnia start or recovery; sleep was not turned off" >&2; exit 75; }; d=; n=1; p=$k; while [ -n "$p" ]; do d="$d $p"; n=$((n + 1)); p=${p%/*}; done; d="$d /"; n=$((n + 1)); t=$(/usr/bin/stat -f '%u %Lp %l %z %HT' $f $d 2>/dev/null) && printf '%s\n' "$t" | /usr/bin/awk -v o=0 -v n=$n 'NR == 1 { k = NF == 6 && $5 == "Regular" && $6 == "File" && $3 == 1 && $4 == 82 && $2 == 600 }; NR > 1 { k = k && NF == 5 && $5 == "Directory" }; { k = k && ($1 == 0 || $1 == o) && $2 !~ /[2367].?$/ }; END { exit !(k && NR == n) }' && l=$(/bin/ls -lde $d 2>/dev/null) && printf '%s\n' "$l" | /usr/bin/awk '$1 ~ /^[0-9]+:$/ && / allow / { f = 1 }; END { exit f }' && l=$(/bin/ls -le $f 2>/dev/null) && e=$(printf '%s\n' "$l" | /usr/bin/awk 'NR == 1 { k = /^-/ }; NR == 2 && k && /^ 0: user:[^ :]+ allow read$/ { n = substr($2, 6) }; END { if (NR == 2) print n }') && [ -n "$e" ] && [ "$(/usr/bin/id -u -- "$e" 2>/dev/null)" = "$4" ] || bad "$f is missing, is not the 82-byte file install.sh made, mode 600 with one access control entry that lets uid $4 read it and nothing else, or someone other than root can change it or a folder above it. Run install.sh again"; i=$(/usr/bin/stat -f '%d:%i' <&8 2>/dev/null) && [ "$i" = "$7" ] && [ "$i" = "$(/usr/bin/stat -f '%d:%i' "$f" 2>/dev/null)" ] || bad "$f is not the file it was when this start began. Run install.sh again"; m=$(/usr/bin/head -c 64 "$1" 2>/dev/null); if [ -z "$2" ] || [ "$m" != "$2" ]; then echo "the start that asked for this password is over; sleep was not turned off" >&2; exit 3; fi; late() { ! [ "$(/bin/date +%s)" -lt "$1" ] 2>/dev/null; }; if late "$3"; then echo "this password came after the start that asked for it had timed out, or after its session ended; sleep was not turned off" >&2; exit 4; fi; c=/private/etc/sudo.conf; if [ -e "$c" ] || [ -L "$c" ]; then echo "/etc/sudo.conf exists. sudo -V does not list every plugin that file can load, and an approval plugin can show nothing there and still refuse the restore, so this check works only with sudo's built-in plugins and no /etc/sudo.conf; sleep was not turned off" >&2; exit 5; fi; /usr/bin/awk '$1 !~ /^#/ && tolower($0) ~ /session/ { n++; k = $1 == "session" && $2 == "required" && $3 == "pam_permit.so" && NF == 3 }; END { exit !(n == 1 && k) }' /private/etc/pam.d/sudo 2>/dev/null || { echo "/etc/pam.d/sudo could not be read, or its session lines are not macOS's own single session required pam_permit.so. sudo runs them for the restore but not for a listing, so this check cannot tell whether the restore runs; sleep was not turned off" >&2; exit 5; }; w=$4; u() { /usr/bin/sudo -n -u "#$w" /usr/bin/env -i LC_ALL=C "$@" </dev/null; }; q() { u /usr/bin/sudo "$@"; }; v=$(q -V) && printf %s "$v" | /usr/bin/awk 'BEGIN { v = "1.9.17p2" }; NR == 1 { k = $0 == "Sudo version " v; next }; NR == 2 { k = k && $0 == "Sudoers policy plugin version " v; next }; NR == 3 { k = k && $0 == "Sudoers file grammar version 50"; next }; $0 == "Sudoers I/O plugin version " v && !i && !a { i = 1; next }; $0 == "Sudoers audit plugin version " v && !a { a = 1; next }; { k = 0 }; END { exit !(k && NR >= 3) }' || { echo "sudo -V, run as this user, failed or does not show sudo 1.9.17p2 with only the sudoers plugins. This check follows how sudo 1.9.17p2 lists and runs commands, and another version needs an Insomnia release checked against it; sleep was not turned off" >&2; exit 5; }; l=$(q -k -n -l) || { echo "sudo -k -n -l did not list this user's sudoers rules without a password; sleep was not turned off" >&2; exit 5; }; d=$(printf %s "$l" | /usr/bin/awk 'function ok(e, n, o) { o = ""; n = e; if (match(n, /[-+]?=/)) { o = substr(n, RSTART, RLENGTH); n = substr(n, 1, RSTART - 1) }; if (n ~ /^!/) return (o == "" && index(" env_reset env_keep env_check env_delete lecture lecture_file log_allowed log_denied passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type tty_tickets pwfeedback insults ", " " substr(n, 2) " ") > 0); if (o == "") return (index(" env_reset lecture log_allowed log_denied tty_tickets pwfeedback insults ", " " n " ") > 0); if (o != "=") return (index(" env_keep env_check env_delete ", " " n " ") > 0); return (index(" env_keep env_check env_delete lecture lecture_file passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type ", " " n " ") > 0) }; NR == 1 && index($0, "Matching Defaults entries for ") == 1 { s = 1; next }; s == 1 { s = 2; t = $0; if (substr(t, 1, 4) != "    " || index(t, sprintf("%c", 92)) || index(t, sprintf("%c", 9))) { print "a backslash, a tab or a layout it cannot read"; f = 1; exit }; t = substr(t, 5); while (1) { if (!match(t, /^!?[a-z_]+([-+]?=("[^"]*"|[^ ",:=#]*))?/)) { print substr(t, 1, 80); f = 1; exit }; e = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1); if (!ok(e)) { print substr(e, 1, 80); f = 1; exit }; if (t == "") break; if (substr(t, 1, 2) != ", ") { print substr(t, 1, 80); f = 1; exit }; t = substr(t, 3) }; next }; s == 2 { if ($0 != "") { print "a layout it cannot read"; f = 1; exit }; s = 3; next }; index($0, "Runas and Command-specific defaults for ") == 1 { print "Defaults bound to a Runas user or a command, which apply to the restore but not to a listing"; f = 1; exit }; index($0, "Matching Defaults entries for ") == 1 { print "a layout it cannot read"; f = 1; exit }; END { exit f || s == 1 || s == 2 }') || { echo "sudo -k -n -l shows a Defaults entry this check does not accept: ${d:-output it cannot read}. Settings like that can make the restore fail where a listing does not; sleep was not turned off" >&2; exit 5; }; r=$(q -k -n -ll /usr/bin/pmset -a disablesleep 0) && printf %s "$r" | /usr/bin/awk 'BEGIN { c = "/usr/bin/pmset -a disablesleep 0" }; NR == 1 { k = $0 == "Sudoers entry: /private/etc/sudoers.d/insomnia" || $0 == "Sudoers entry: /etc/sudoers.d/insomnia" }; NR == 2 { k = k && $0 == "    RunAsUsers: root" }; NR == 3 { k = k && $0 == "    Options: !authenticate" }; NR == 4 { k = k && $0 == "    Commands:" }; NR == 5 { k = k && $0 == sprintf("%c", 9) c }; NR == 6 { k = k && $0 == "    Matched: " c }; END { exit !(k && NR == 6) }' || { echo "sudo -k -n -ll does not show the rule in /etc/sudoers.d/insomnia that lets this user turn sleep back on as root without a password; sleep was not turned off" >&2; exit 5; }; if late "$3"; then echo "the start this password was for timed out, or its session ended, while sudo was asked about the restore; sleep was not turned off" >&2; exit 4; fi; case $2$6 in *[!0-9A-F-]*) bad "the nonces are not uppercase UUIDs, so they cannot go in the receipt";; esac; [ ${#2} -eq 36 ] && [ ${#6} -eq 36 ] && [ "$2" != "$6" ] && [ "$2" != 00000000-0000-0000-0000-000000000000 ] || bad "the nonces are not two different uppercase UUIDs, so they cannot go in the receipt"; h=$(/usr/bin/head -c 36 <&8 2>/dev/null); if [ "$h" != "$6" ]; then echo "$f changed after this start read it: another start or a recovery came first; sleep was not turned off" >&2; exit 8; fi; foreign() { [ "$1" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ "$(printf %s "$s" | /usr/bin/awk '$1 == "SleepDisabled" && NF > 1 { print $2; exit }')" = 1 ]; }; }; if foreign "$5"; then echo "pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off" >&2; exit 6; fi; put() { /usr/bin/env -i /usr/bin/perl -e 'my ($f, $l) = @ARGV; $l .= chr 10; sysopen(my $h, $f, 257) or exit 1; my @w = stat $h; my @g = stat STDIN; exit 1 unless @w && @g && $w[0] == $g[0] && $w[1] == $g[1]; my $n = syswrite $h, $l; exit 1 unless defined $n && $n == length $l; fcntl($h, 51, 0) or exit 1; close $h or exit 1; sysopen(my $r, $f, 256) or exit 1; my $s = q(); my $k = sysread $r, $s, 128; exit 1 unless defined $k && $s eq $l; exit 0' "$f" "$2 $3 $1" <&8; }; no() { o=; put refused "$1" "$2" && return; a=$(/bin/date +%s); j=1; [ "$a" -gt 0 ] 2>/dev/null && while [ $j -lt 3 ] && /bin/sleep 1 && [ "$(/bin/date +%s)" -lt $((a + 3)) ] 2>/dev/null; do j=$((j + 1)); put refused "$1" "$2" && return; done; o="; its refused line could not be written either (attempts: $j), so a recovery that never gets this exit status may undo the start like an end"; return 1; }; put writing "$2" "$6" || { no "$2" "$6"; echo "$f could not be written, flushed to the drive with F_FULLFSYNC and read back with this start's nonce; sleep was not turned off$o" >&2; exit 7; }; if foreign "$5"; then no "$2" "$6"; echo "pmset -g, read again once this start's record was written, shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off$o" >&2; exit 6; fi; if late "$3"; then no "$2" "$6"; echo "the start this password was for timed out, or its session ended, while pmset -g was read; sleep was not turned off$o" >&2; exit 4; fi; /usr/bin/pmset -a disablesleep 1 || exit 1"##
    /// The whole AppleScript, as one literal: `markerLock`, `rootCommand`
    /// (each `"` escaped for AppleScript), the privilege flag and the
    /// dialog text are fixed at compile time. Its only inputs are the
    /// marker path, the nonce, the time the start stops taking answers, the
    /// uid, the ownership flag, the predecessor nonce and the receipt's
    /// "device:inode", `item 1` to `item 7 of argv`, and each reaches the
    /// root shell
    /// through `quoted form of`, as lockf's file and as positional
    /// parameters. No configuration value or environment variable reaches
    /// the command that runs as root.
    static let disableSleepScript = #"""
    on run argv
    do shell script "/usr/bin/lockf -k -n -t 10 " & quoted form of (item 1 of argv) & " /bin/sh -c " & quoted form of "trap '' PIPE; LC_ALL=C; export LC_ALL; if ! [ \"$4\" -gt 0 ] 2>/dev/null; then echo \"no user id came with the password, so sudo could not be asked whether sleep can be turned back on without one; sleep was not turned off\" >&2; exit 5; fi; bad() { echo \"$1; sleep was not turned off\" >&2; exit 7; }; case $4 in *[!0-9]*|0*) bad \"the user id $4 is not plain digits, so it names no receipt\";; esac; k=/private/var/db/com.kgarg.insomnia; f=$k/$4; { exec 8<\"$f\"; } 2>/dev/null || bad \"$f could not be opened. Run install.sh again\"; /usr/bin/lockf -s -t 10 8 || { echo \"$f stayed locked for 10 s by another Insomnia start or recovery; sleep was not turned off\" >&2; exit 75; }; d=; n=1; p=$k; while [ -n \"$p\" ]; do d=\"$d $p\"; n=$((n + 1)); p=${p%/*}; done; d=\"$d /\"; n=$((n + 1)); t=$(/usr/bin/stat -f '%u %Lp %l %z %HT' $f $d 2>/dev/null) && printf '%s\\n' \"$t\" | /usr/bin/awk -v o=0 -v n=$n 'NR == 1 { k = NF == 6 && $5 == \"Regular\" && $6 == \"File\" && $3 == 1 && $4 == 82 && $2 == 600 }; NR > 1 { k = k && NF == 5 && $5 == \"Directory\" }; { k = k && ($1 == 0 || $1 == o) && $2 !~ /[2367].?$/ }; END { exit !(k && NR == n) }' && l=$(/bin/ls -lde $d 2>/dev/null) && printf '%s\\n' \"$l\" | /usr/bin/awk '$1 ~ /^[0-9]+:$/ && / allow / { f = 1 }; END { exit f }' && l=$(/bin/ls -le $f 2>/dev/null) && e=$(printf '%s\\n' \"$l\" | /usr/bin/awk 'NR == 1 { k = /^-/ }; NR == 2 && k && /^ 0: user:[^ :]+ allow read$/ { n = substr($2, 6) }; END { if (NR == 2) print n }') && [ -n \"$e\" ] && [ \"$(/usr/bin/id -u -- \"$e\" 2>/dev/null)\" = \"$4\" ] || bad \"$f is missing, is not the 82-byte file install.sh made, mode 600 with one access control entry that lets uid $4 read it and nothing else, or someone other than root can change it or a folder above it. Run install.sh again\"; i=$(/usr/bin/stat -f '%d:%i' <&8 2>/dev/null) && [ \"$i\" = \"$7\" ] && [ \"$i\" = \"$(/usr/bin/stat -f '%d:%i' \"$f\" 2>/dev/null)\" ] || bad \"$f is not the file it was when this start began. Run install.sh again\"; m=$(/usr/bin/head -c 64 \"$1\" 2>/dev/null); if [ -z \"$2\" ] || [ \"$m\" != \"$2\" ]; then echo \"the start that asked for this password is over; sleep was not turned off\" >&2; exit 3; fi; late() { ! [ \"$(/bin/date +%s)\" -lt \"$1\" ] 2>/dev/null; }; if late \"$3\"; then echo \"this password came after the start that asked for it had timed out, or after its session ended; sleep was not turned off\" >&2; exit 4; fi; c=/private/etc/sudo.conf; if [ -e \"$c\" ] || [ -L \"$c\" ]; then echo \"/etc/sudo.conf exists. sudo -V does not list every plugin that file can load, and an approval plugin can show nothing there and still refuse the restore, so this check works only with sudo's built-in plugins and no /etc/sudo.conf; sleep was not turned off\" >&2; exit 5; fi; /usr/bin/awk '$1 !~ /^#/ && tolower($0) ~ /session/ { n++; k = $1 == \"session\" && $2 == \"required\" && $3 == \"pam_permit.so\" && NF == 3 }; END { exit !(n == 1 && k) }' /private/etc/pam.d/sudo 2>/dev/null || { echo \"/etc/pam.d/sudo could not be read, or its session lines are not macOS's own single session required pam_permit.so. sudo runs them for the restore but not for a listing, so this check cannot tell whether the restore runs; sleep was not turned off\" >&2; exit 5; }; w=$4; u() { /usr/bin/sudo -n -u \"#$w\" /usr/bin/env -i LC_ALL=C \"$@\" </dev/null; }; q() { u /usr/bin/sudo \"$@\"; }; v=$(q -V) && printf %s \"$v\" | /usr/bin/awk 'BEGIN { v = \"1.9.17p2\" }; NR == 1 { k = $0 == \"Sudo version \" v; next }; NR == 2 { k = k && $0 == \"Sudoers policy plugin version \" v; next }; NR == 3 { k = k && $0 == \"Sudoers file grammar version 50\"; next }; $0 == \"Sudoers I/O plugin version \" v && !i && !a { i = 1; next }; $0 == \"Sudoers audit plugin version \" v && !a { a = 1; next }; { k = 0 }; END { exit !(k && NR >= 3) }' || { echo \"sudo -V, run as this user, failed or does not show sudo 1.9.17p2 with only the sudoers plugins. This check follows how sudo 1.9.17p2 lists and runs commands, and another version needs an Insomnia release checked against it; sleep was not turned off\" >&2; exit 5; }; l=$(q -k -n -l) || { echo \"sudo -k -n -l did not list this user's sudoers rules without a password; sleep was not turned off\" >&2; exit 5; }; d=$(printf %s \"$l\" | /usr/bin/awk 'function ok(e, n, o) { o = \"\"; n = e; if (match(n, /[-+]?=/)) { o = substr(n, RSTART, RLENGTH); n = substr(n, 1, RSTART - 1) }; if (n ~ /^!/) return (o == \"\" && index(\" env_reset env_keep env_check env_delete lecture lecture_file log_allowed log_denied passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type tty_tickets pwfeedback insults \", \" \" substr(n, 2) \" \") > 0); if (o == \"\") return (index(\" env_reset lecture log_allowed log_denied tty_tickets pwfeedback insults \", \" \" n \" \") > 0); if (o != \"=\") return (index(\" env_keep env_check env_delete \", \" \" n \" \") > 0); return (index(\" env_keep env_check env_delete lecture lecture_file passprompt badpass_message passwd_timeout passwd_tries timestamp_timeout timestamp_type \", \" \" n \" \") > 0) }; NR == 1 && index($0, \"Matching Defaults entries for \") == 1 { s = 1; next }; s == 1 { s = 2; t = $0; if (substr(t, 1, 4) != \"    \" || index(t, sprintf(\"%c\", 92)) || index(t, sprintf(\"%c\", 9))) { print \"a backslash, a tab or a layout it cannot read\"; f = 1; exit }; t = substr(t, 5); while (1) { if (!match(t, /^!?[a-z_]+([-+]?=(\"[^\"]*\"|[^ \",:=#]*))?/)) { print substr(t, 1, 80); f = 1; exit }; e = substr(t, 1, RLENGTH); t = substr(t, RLENGTH + 1); if (!ok(e)) { print substr(e, 1, 80); f = 1; exit }; if (t == \"\") break; if (substr(t, 1, 2) != \", \") { print substr(t, 1, 80); f = 1; exit }; t = substr(t, 3) }; next }; s == 2 { if ($0 != \"\") { print \"a layout it cannot read\"; f = 1; exit }; s = 3; next }; index($0, \"Runas and Command-specific defaults for \") == 1 { print \"Defaults bound to a Runas user or a command, which apply to the restore but not to a listing\"; f = 1; exit }; index($0, \"Matching Defaults entries for \") == 1 { print \"a layout it cannot read\"; f = 1; exit }; END { exit f || s == 1 || s == 2 }') || { echo \"sudo -k -n -l shows a Defaults entry this check does not accept: ${d:-output it cannot read}. Settings like that can make the restore fail where a listing does not; sleep was not turned off\" >&2; exit 5; }; r=$(q -k -n -ll /usr/bin/pmset -a disablesleep 0) && printf %s \"$r\" | /usr/bin/awk 'BEGIN { c = \"/usr/bin/pmset -a disablesleep 0\" }; NR == 1 { k = $0 == \"Sudoers entry: /private/etc/sudoers.d/insomnia\" || $0 == \"Sudoers entry: /etc/sudoers.d/insomnia\" }; NR == 2 { k = k && $0 == \"    RunAsUsers: root\" }; NR == 3 { k = k && $0 == \"    Options: !authenticate\" }; NR == 4 { k = k && $0 == \"    Commands:\" }; NR == 5 { k = k && $0 == sprintf(\"%c\", 9) c }; NR == 6 { k = k && $0 == \"    Matched: \" c }; END { exit !(k && NR == 6) }' || { echo \"sudo -k -n -ll does not show the rule in /etc/sudoers.d/insomnia that lets this user turn sleep back on as root without a password; sleep was not turned off\" >&2; exit 5; }; if late \"$3\"; then echo \"the start this password was for timed out, or its session ended, while sudo was asked about the restore; sleep was not turned off\" >&2; exit 4; fi; case $2$6 in *[!0-9A-F-]*) bad \"the nonces are not uppercase UUIDs, so they cannot go in the receipt\";; esac; [ ${#2} -eq 36 ] && [ ${#6} -eq 36 ] && [ \"$2\" != \"$6\" ] && [ \"$2\" != 00000000-0000-0000-0000-000000000000 ] || bad \"the nonces are not two different uppercase UUIDs, so they cannot go in the receipt\"; h=$(/usr/bin/head -c 36 <&8 2>/dev/null); if [ \"$h\" != \"$6\" ]; then echo \"$f changed after this start read it: another start or a recovery came first; sleep was not turned off\" >&2; exit 8; fi; foreign() { [ \"$1\" != 1 ] && { s=$(/usr/bin/pmset -g) || return 0; [ \"$(printf %s \"$s\" | /usr/bin/awk '$1 == \"SleepDisabled\" && NF > 1 { print $2; exit }')\" = 1 ]; }; }; if foreign \"$5\"; then echo \"pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off\" >&2; exit 6; fi; put() { /usr/bin/env -i /usr/bin/perl -e 'my ($f, $l) = @ARGV; $l .= chr 10; sysopen(my $h, $f, 257) or exit 1; my @w = stat $h; my @g = stat STDIN; exit 1 unless @w && @g && $w[0] == $g[0] && $w[1] == $g[1]; my $n = syswrite $h, $l; exit 1 unless defined $n && $n == length $l; fcntl($h, 51, 0) or exit 1; close $h or exit 1; sysopen(my $r, $f, 256) or exit 1; my $s = q(); my $k = sysread $r, $s, 128; exit 1 unless defined $k && $s eq $l; exit 0' \"$f\" \"$2 $3 $1\" <&8; }; no() { o=; put refused \"$1\" \"$2\" && return; a=$(/bin/date +%s); j=1; [ \"$a\" -gt 0 ] 2>/dev/null && while [ $j -lt 3 ] && /bin/sleep 1 && [ \"$(/bin/date +%s)\" -lt $((a + 3)) ] 2>/dev/null; do j=$((j + 1)); put refused \"$1\" \"$2\" && return; done; o=\"; its refused line could not be written either (attempts: $j), so a recovery that never gets this exit status may undo the start like an end\"; return 1; }; put writing \"$2\" \"$6\" || { no \"$2\" \"$6\"; echo \"$f could not be written, flushed to the drive with F_FULLFSYNC and read back with this start's nonce; sleep was not turned off$o\" >&2; exit 7; }; if foreign \"$5\"; then no \"$2\" \"$6\"; echo \"pmset -g, read again once this start's record was written, shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off$o\" >&2; exit 6; fi; if late \"$3\"; then no \"$2\" \"$6\"; echo \"the start this password was for timed out, or its session ended, while pmset -g was read; sleep was not turned off$o\" >&2; exit 4; fi; /usr/bin/pmset -a disablesleep 1 || exit 1" & " insomnia " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv) & " " & quoted form of (item 6 of argv) & " " & quoted form of (item 7 of argv) with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session."
    end run
    """#
    /// The user is typing a password, so the limit is generous. At the
    /// deadline osascript gets SIGTERM, and the start is rolled back.
    static let timeout: TimeInterval = 120
    /// How long after SIGTERM the runner keeps waiting before it answers
    /// the caller with `.stillRunning`. The same 3 s as KILL_GRACE_SECONDS
    /// in scripts/backstop.sh.
    static let stopGrace: TimeInterval = 3
    /// How long after the marker is written the root command still takes an
    /// answer (`PendingStart.expires`): the dialog's own limit, the grace
    /// after SIGTERM, and 7 s for osascript to start. A dialog that is still
    /// on screen after that (SIGTERM did not stop it) gets exit 4 from the
    /// command. A crashed or timed-out start keeps Starts refused at least
    /// this long. Its settlement then decides only once it can lock the
    /// receipt and finish: a root query or pmset still running, another
    /// start or recovery holding the receipt's lock, or a claim or journal
    /// that cannot be cleaned up keeps Starts refused longer, with no
    /// limit.
    static let answerWindow: TimeInterval = timeout + stopGrace + 7
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
        let r = try await run(["-e", AdministratorPrompt.disableSleepScript, start.marker.path, start.nonce, start.expiresArgument, String(getuid()), start.ownershipArgument, start.predecessor, start.receipt])
        guard r.status == 0 else {
            if Self.isCancel(r.stderr) { throw AdministratorPromptError.cancelled }
            if Self.isRestoreRefusal(r.stderr) { throw AdministratorPromptError.restoreNeedsPassword(stderr: r.stderr) }
            if let status = Self.rootStatus(r.stderr), Self.refusalStatuses.contains(status) {
                throw AdministratorPromptError.refused(rootStatus: status, stderr: r.stderr)
            }
            throw AdministratorPromptError.failed(status: r.status, stderr: r.stderr)
        }
    }

    /// The exits that mean the root command stopped before the sleep write
    /// (`AdministratorPromptError.refused`): its own 3, 4, 6, 7, 8 and 75
    /// (the receipt stayed locked), and lockf's 69 (no marker) and 75 (the
    /// marker stayed locked), for which it never started. None of them can
    /// come from pmset, whose failure the command turns into 1, or from a
    /// signal, which lockf reports as 70. 5 is `isRestoreRefusal`.
    static let refusalStatuses: Set<Int32> = [3, 4, 6, 7, 8, 69, 75]

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
        /// deadline is still a timeout. A child a signal stopped that this
        /// runner did not send is `.interrupted`, never `.failed`: its root
        /// command may outlive it. A caller already answered with
        /// `.stillRunning` is not answered again; its handle is told.
        func exited(_ result: ShellResult, signal: Int32?) {
            let (c, handle, outcome): (CheckedContinuation<ShellResult, Error>?, UnfinishedPrompt?, Result<ShellResult, Error>) = lock.withLock {
                defer { continuation = nil }
                let outcome: Result<ShellResult, Error> = if signalled {
                    .failure(AdministratorPromptError.timedOut(seconds: timeout))
                } else if let signal {
                    .failure(AdministratorPromptError.interrupted(signal: signal, stderr: result.stderr))
                } else {
                    .success(result)
                }
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
                ), signal: process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil)
            }
        }
    }
}
