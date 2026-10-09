# Security

Insomnia is experimental software. There is no security-response SLA. Report
suspected vulnerabilities against the current main branch
or a release tag, including the affected revision and a minimal,
non-destructive reproduction.

Do not publish passwords, Keychain data, personal logs, or weaponized exploit
details in a public issue. If GitHub shows a **Report a vulnerability** action
on this repository's Security page, use that private channel. Otherwise open a
public issue containing only a request for a private security contact, without
the sensitive details, and wait for the maintainer to arrange one.

The installer grants the user account passwordless access to three exact pmset
commands listed in the README: turn sleep back on (`pmset -a disablesleep 0`)
and switch battery Low Power Mode on or off (`pmset -b lowpowermode 1` and
`0`). This grant is not exclusive to the Insomnia app: other processes running
as that user can invoke them too. None of them can keep the Mac awake. Turning
sleep off (`pmset -a disablesleep 1`) has no passwordless line; the app runs it
through the standard macOS administrator dialog, with a fixed command string,
each time the user starts a session, and never on relaunch or from the recovery
agent. That command turns sleep off only while the start that asked still
holds its random nonce in `pending-start`, and only before the start's
`expires` (the session's end, or 130 s after that file was written if
sooner), which it receives as an argument and compares with the clock as
root. It holds a `lockf` lock on that file, and an flock(2) lock on the
user's receipt (below), from before the checks until pmset exits.
The start deletes the file when it finishes, and the app at launch, the recovery agent and uninstall delete it
under the recovery lock before they undo anything; every one of them takes the
file's own lock first, and deletes it only while its path still names the
file it locked, so the file never goes while that command is past its
check. A start that gave up on a stuck dialog counts it as voided only if
the file it locked is the one it wrote. The app after a relaunch, the
recovery agent and uninstall cannot make that last check, since they did
not write the file: a process running as you that puts a copy in its place
while the command runs could get it deleted early. Such a process could
already clear the journal entry in `state.json` directly. A dialog answered after its start was abandoned (the app died, recovery
ran, the start rolled back, a newer start began) runs nothing. The app shows
the dialog only when the `backstop.sh` sealed in its bundle, the copy the
recovery agent runs, declares in its `# insomnia-backstop-version:` line a
version that deletes `pending-start` and settles an unfinished start from
its receipt (below), so recovery after a crash under the dialog never
depends on an older script.

Before the dialog the app runs nothing through sudo. It reads `pmset -g`,
and a SleepDisabled 1 the journal does not claim is left alone: Start is
refused with nothing run and gives the command that turns sleep back on. An
unreadable `pmset -g` refuses too. After the password, under the marker's
and the receipt's locks and after the receipt, nonce and deadline checks,
the root command checks
whether the session's end will be able to turn sleep back on without a
password, and writes nothing until it has the answer. As root it first
reads two files that change what the restore does but not what a listing
shows:

- `/private/etc/sudo.conf` must not exist, as a file, a link or anything
  else. Apple's sudo reads plugins from that one path, compiled in, with no
  override, and without the file it loads only its built-in sudoers
  policy, I/O and audit plugins. With the file it can load an approval
  plugin that prints nothing in `sudo -V` (sudo skips a plugin with no
  `show_version`) and that sudo consults only when it runs a command, so
  that plugin can refuse the restore while every listing passes. macOS
  installs no sudo.conf.
- `/private/etc/pam.d/sudo` must have exactly one uncommented line that
  mentions a session, `session required pam_permit.so`, as macOS installs
  it. sudo opens a PAM session only to run a command, never for a listing,
  and a session module that fails fails the restore.

Root then drops to the user who pressed Start (`sudo -n -u "#<uid>"`: sudo
never asks root for a password, and macOS's default `root ALL = (ALL) ALL`
permits it), empties the environment with `/usr/bin/env -i LC_ALL=C`, and
runs that user's `/usr/bin/sudo` three times, with stdin from /dev/null.
The answers must be the ones sudo 1.9.17p2 prints. That is the sudo in
macOS 26.2, whose manuals are headed Sudo 1.9.17p2 and whose source is
Apple's sudo-114.100.11. Only that source was read for what a listing
shares with running a command, so any other version refuses, older or
newer, until an Insomnia release is checked against it:

- `sudo -V` must show `Sudo version 1.9.17p2`, the sudoers policy plugin
  1.9.17p2, sudoers file grammar version 50, and after them nothing but the
  sudoers I/O and audit plugins' own lines.
- `sudo -k -n -l` must list the user's rules without a password, and each
  Defaults entry it shows for the user must be one the check accepts:
  sudo lists there the entries set for everyone and those bound to the
  requesting user or to this host. The
  list holds env_reset, env_keep, env_check and env_delete, which choose
  only the environment pmset gets; log_allowed and log_denied, which only
  turn logging to syslog and the audit log on or off; and lecture,
  lecture_file, passprompt, badpass_message, passwd_timeout, passwd_tries,
  timestamp_timeout, timestamp_type, tty_tickets, pwfeedback and insults,
  which sudo reads only when it asks for a password. A log sudo cannot
  write stops no command while `ignore_logfile_errors` keeps its default,
  and the list accepts no entry that changes it. Any other entry refuses,
  and the message names it. I/O logging is one example: under
  `log_output`, sudo will not run a command whose I/O log it cannot write,
  which a listing never tries. Defaults bound to a Runas user or a command
  (`Defaults>user`, `Defaults!command`) refuse too, since they apply when
  the restore runs but not to a listing, and so does a Defaults line with a
  backslash or a tab, which cannot be split back into entries with
  certainty.
- `sudo -k -n -ll /usr/bin/pmset -a disablesleep 0` must print exactly the
  rule install.sh writes, in six lines: `Sudoers entry:` naming
  /etc/sudoers.d/insomnia (as /private/etc or /etc), `RunAsUsers: root`,
  `Options: !authenticate` (NOPASSWD and no other tag), the restore as the
  only command, and `Matched:` the restore. Given a command, sudo prints
  the rule that decides it, the last one that matches, so a later rule
  that asks for a password, denies the command, or runs it as anyone else
  is the one shown, and it refuses.

`-k` ignores a credential cached by a recent sudo, and `-n` fails instead
of prompting. None of the three runs a command, and none is `sudo -l` alone,
`sudo -v`, an exit status read alone, or a search for NOPASSWD: the admin
group's `(ALL) ALL` lists commands the user may run with a password, and a
listing passes without one whenever any of the user's entries is
passwordless. A file check or query that fails, prints anything else, is
cut short, or asks for a password (a `listpw` setting that wants one) exits
5. The clock is then compared with the start's `expires` (exit 4).

The receipt is `/private/var/db/com.kgarg.insomnia/<uid>`, exactly 82
bytes on one line: a start's nonce (an uppercase UUID), a space, the nonce
the receipt held before that start (its predecessor), a space, `writing` or
`refused`, and a newline. install.sh makes the folder (mode 0755) and the
file (mode 0600, holding the all-zero nonce twice and `refused`), both
root's, through `sudo -n` with those fixed paths, after checking by lstat
that every folder from `/private/var/db` up to / is root's, is not a link,
has no group or other write permission and no access control entry that
allows anything. It then gives the file one access control entry, `sudo
-n chmod +a "user:<name> allow read"`, for the account that ran it. Only
root and that account can open the receipt, so no other account can take
its lock. It checks the folder and the file again once they exist. A
receipt an earlier build made (root's, one link, 82 bytes, no group or
other write, with no entry or only that one) is repaired in place by `sudo
-n chmod`, keeping its bytes and its inode, and only while the release
file shows no claim: there is none, or it holds a nonce and `free`. A
claim, or a release file that is not a regular file, cannot be read or
holds anything else, stops the install before any change: settle that
start first, or remove both files by hand when no Insomnia folder has a
start to settle. A receipt the user can open (any mode but 0600) is
locked first, as the root command and every reader lock it, the release
file is read under that lock, and before each chmod the receipt must
still be the locked file with the same line. One the user cannot open
(0600 with no entry) is refused by the app, backstop.sh and the root
command until it has the entry, so nothing can claim it or write it
meanwhile; it gets the entry, then is locked and checked with the release
file below. The entry goes on before the mode, so the user can read the
receipt throughout. The readers of earlier builds of this change refuse a
repaired receipt, and they stay installed when the install stops later,
or rolls back to the bundle it was replacing. A folder or
file already there in any other form (another owner, a looser mode, a
link, another type or size, a second hard link, an allowing ACL on a
folder, any other entry on the file) stops the install: it never changes
the owner of something it did not make, and says to remove it by hand.
That includes the 45-byte receipt of earlier builds of this change, which
is not converted. A receipt already as it makes it is kept. Nothing
running as the user can write the receipt or replace it or any folder
above it. Every Insomnia folder of the user (`INSOMNIA_HOME`) shares the
one receipt.

The app, backstop.sh, uninstall.sh and the root command accept the
receipt only at mode 0600 with exactly that one entry: allow, the read
right alone, for the user's uid, not inherited and with no flags. Another
account's or a group's entry, a deny entry, a second entry, or any other
right or flag refuses. The app reads the list through acl(3) and sees
every entry. The scripts and the root command read it through `ls -le`,
which never prints the synchronize right, prints folder-only rights and
the inherit flags only for folders, and skips an entry it cannot read; a
receipt with one of those added can pass their check. They then ask
`id -u` whether the entry's name is the user's uid. The two checks are not
equivalent: such a receipt passes the scripts and the root command, and the
app refuses it. The app also refuses the receipt when an acl(3) call on
the list fails or gives an answer acl(3) does not document, rather than
take it for the end of the list or for a flag that is clear.

Beside it, install.sh makes `<uid>.released` through `sudo -n install`:
the user's own file, mode 0600, 42 bytes, holding a nonce and `free` or
`held`. A start claims the receipt before its dialog, under the receipt's
lock, and only while this file shows the receipt's current nonce `free`;
it then writes its own nonce `held`. The claim goes back (the receipt's
nonce, `free`) only once that start is settled. While a claim is out, a
start from any other Insomnia folder of the user is refused, so no root
command can replace the line that the claimed start's settlement will
read. Anything running as the user can rewrite this file, so it never
shows that a start did not turn sleep off. A false line can only make a
settlement find a later start's line, which shows nothing and leads to an
undo, or refuse every Start. install.sh keeps a `held` claim on an
existing receipt and otherwise writes the receipt's nonce `free`.

The receipt is also the lock for every party that acts on a start. The
root command opens it read-only and takes an exclusive flock(2) lock on it
(`lockf -s -t 10` on the open descriptor) before any other check. Its shell
and every tool it starts, pmset included, inherit that descriptor, so the
lock lasts until all of them have exited. The app, backstop.sh, install.sh
and uninstall.sh open the receipt read-only and take the same lock before a
start claims it, before they read it to settle a start, before install.sh
writes the release file, and before uninstall.sh removes it. Each of them
therefore reads the receipt before a command took the lock or after that
command and its pmset exited, whichever marker file the command opened.
Taking the lock needs read access, which only root and the user have
(mode 0600 and the one entry), so no other account can hold it. While root
or a process of the user does, Start is refused after 10 s, the root
command refuses with exit 75 after 10 s, and a
settlement decides nothing (below). The lock is advisory: root can change
the file without it.

Under that lock the root command checks the receipt: the uid must be plain
digits, and `stat` and `ls -le` of the receipt and of every folder above it
up to / must show a regular file with one link, 82 bytes, mode 0600 and
the one entry for the user under folders, each of them root's, with no
group or other write permission and no allowing entry. The open
descriptor and the path must both be the file
(device and inode) the start claimed. Anything else exits 7 with nothing
written. Exit 3 means the marker no longer holds the nonce. Exit 4 means the
clock is not before the start's `expires`. Then come the sudo checks above
and the clock again (exit 4). The receipt must still begin with the
predecessor the start claimed it from, or the command exits 8: another
start or a recovery came first. Then it reads `pmset -g` (exit 6 on a
SleepDisabled 1 or a failed read; it reads nothing only when the journal
claimed the 1 before this start).

Then it writes `<nonce> <predecessor> writing` into the receipt in place.
`/usr/bin/perl`, run with an empty environment, opens the path for writing
without creating, truncating or following a link, checks that the
descriptor it got is the locked file, writes the 82 bytes with one write(2)
that must write them all, calls `fcntl(F_FULLFSYNC)`, closes the file,
opens it again and reads the line back. Any failure, a missing perl
included, tries to write `refused` the same way and exits 7, so a Mac
without `/usr/bin/perl` cannot start a session. Apple's fcntl(2) manual
describes F_FULLFSYNC as an fsync(2) followed by a request to the drive to
flush its own cache, and says that some drives ignore that request. Once
the line is read back, the command reads `pmset -g` again, under the same
rule: a SleepDisabled 1 set while the line was written, or a
read that fails, writes `refused` and exits 6, and that 1 stays. The
clock is compared once more: at or after `expires` the command writes
`refused` and exits 4. Only then does it run `pmset -a disablesleep 1`, its
only power write, which the start journaled before the dialog. If pmset
fails, the command exits 1. Root reads the marker but never writes it, and
never writes anything into the user's folders. The command ignores
SIGPIPE, so a refusal keeps its own status when the dialog's output is
already gone. Exits 3 to 8, and lockf's 69 and 75, leave the sleep setting
as the command found it, and roll the start back with nothing to undo: no
session, the journal and session.json as they were, the claim given back,
no pmset, and for exit 5 a message that names the check that stopped it.
That happens without the rule (an uninstall that stopped part way, a
hand-deleted file), on a Mac whose sudoers lacks root's default entry, and
with any sudo, sudo.conf, PAM file or sudoers setting the check does not
accept, even one under which the restore would run. Rerunning the
installer fixes only a missing rule: it changes no sudo version,
sudo.conf, PAM file or Defaults, and macOS keeps its sudo on the sealed
system volume. The user has typed the password by the time a refusal is
reported.

A start's `expires` is the session's end, or 130 s after the start wrote
`pending-start` if that is sooner: the dialog's 120 s, the 3 s the app
waits after SIGTERM, and 7 s for osascript to start. No query and no read
has a time limit of its own. The dialog's 120 s limit is only how long the
app waits before it sends osascript SIGTERM, and that wait includes a
command that runs after the password was accepted. SIGTERM does not stop
the root command, and nothing is ever sent SIGKILL. If osascript has not
finished 3 s after SIGTERM, the app deletes the marker it wrote, under the
marker's lock. When that works, no command for the start is past its nonce
check: the start is settled from the receipt once `expires` has passed, a
few seconds later, and the menu names the leftover process until it exits.
While a root command holds the marker's lock (any time from its nonce
check to its exit, so in a sudo query that never returns too), the start
keeps session.json, the journal entry and the recovery lock, waits with no
limit for the command to exit and its output to close, and names what is
running in a notification and the menu. Starts, ends and the recovery
agent wait behind it. When the command does return at or after `expires`,
the clock check that follows every query and the read stops the write.

After a failure whose status the app cannot trust (a wrong password, a
dialog that reached its time limit, a signal the app did not send, a pmset
failure, any other osascript error), the app deletes the marker under its
lock, so no command for this start can pass its nonce check any more, and
then reads the receipt under the receipt's lock. The receipt shows that no
command for the start turned sleep off only when it passes the checks
above (by lstat, then through an `O_NOFOLLOW` descriptor whose fstat
matches), is the file the start claimed (device and inode), and holds one
of three lines:

- this start's nonce with `refused`;
- another start's line that names the same predecessor: that start wrote
  first, and this start's command writes only while the receipt begins
  with the predecessor;
- the predecessor itself, once no command for the start can still write.
  That needs the dialog to have ended by itself (osascript exited on its
  own, after any command it ran) or `expires` to have passed: a command
  that takes the lock later refuses with exit 4 before it writes. After a
  timeout the app waits up to 15 s for `expires` (about 10 s) rather than
  leave the start unsettled.

The start then rolls back with no pmset, and a SleepDisabled 1 another
tool set while the dialog was up stays. This start's `writing` and a
later start's line that names another predecessor are undone like an end
at once. A receipt that is missing, replaced, unreadable, of another size
or shape or under a folder someone other than root could change is undone
like an end once `expires` has passed. Before then it decides nothing
(below), and neither does the predecessor after a dialog that may still
be answered, nor, at any time, a receipt that stays locked or whose lock
fails. A wrong
password never starts the command, so the receipt still holds the
predecessor. A cancelled dialog never starts it either, and rolls back on
its status alone.

A start journals its attempt before its claim and before the dialog can run
anything: `sleepOffAttempt` in state.json, written with
`sleepDisabledByUs`, holds the nonce, the predecessor, the receipt's
device and inode, the session's end, the `sleepDisabledByUs` from before
the start (`owedBefore`) and, once the marker exists, `expires` and the
marker's device and inode. A start that finishes or rolls back marks the
attempt `settled` in the journal, then gives its claim back, then removes
the attempt. One left in the journal belongs to a start that never
finished (the app crashed or was force-quit) or to a settlement that
could not finish. The next holder of the recovery lock (the app at the
start of every transaction, backstop.sh or uninstall.sh)
settles it once it has deleted the marker under the marker's lock, before
it reads the session or restores anything. Which marker file went decides
nothing: the receipt does, read under its lock.

A settlement knows of no dialog that is over, so a start whose `expires`
has not passed and whose receipt still holds the predecessor stays
journaled: its dialog can still be answered. So do the other receipts that
decide nothing before `expires`, and, at any time, a receipt that stays
locked or cannot be locked: a command for that start may hold it and still
be in pmset. While a start stays journaled, new Starts in that Insomnia
folder are refused, its claim keeps Starts in every other folder of the
user refused, an unexpired session of that start is ended rather than
resumed, and no pmset runs for sleep, whatever an earlier session owes.
`expires` only stops commands that have not yet reached their last clock
check; one already past it may still turn sleep off after an undo, which
would then not hold. The rest of the undo (Low Power Mode, frozen
processes, audio) still runs. A start whose receipt stays locked keeps
that hold for as long as the lock is held, with no limit, so a command
that never exits leaves sleep as it is with no restore from Insomnia.
Otherwise session.json goes first if its end is that start's deadline
(that session never began, and is never resumed on a SleepDisabled 1
someone else may have set). Then, while the
claim is still held, the journal records the decision: the attempt marked
`settled`, with `sleepDisabledByUs` put back to `owedBefore` when the
receipt shows no command turned sleep off (an attempt with no marker never
showed a dialog), so a restore an earlier session still owes stays owed
and no pmset runs, and kept otherwise, so the restore runs. Then the claim
goes back, then the journal drops the attempt. A record already marked
`settled` is finished the same way from its decision, and never read
against the receipt again: once its claim went back, a later start's line
may show something else.

A settlement step that fails before the decision is in the journal keeps
the attempt unsettled, with the claim, so the next run reads the same
line: a session.json that cannot be removed (then nothing is removed) or a
journal that cannot be written. One that fails after it (a claim that
cannot be given back, a settled record that cannot be removed, a receipt
that cannot be locked to finish it) keeps the settled record. That record
holds nothing back, since its decision is made: the undo follows it,
Starts stay refused until it is finished, and every run tries again. A
crash at any point leaves one of those two journals. The menu, the log and
uninstall.sh's message say whether session.json of that start was removed
and whether the decision was journaled. While the receipt cannot decide
yet, or shows that no command turned sleep off with no earlier restore
owed, no pmset runs for sleep: the app refuses Start and retries at every
transaction, backstop.sh logs that sleep is left as it is, keeps the
journal dirty and exits 1, and uninstall.sh stops with nothing else
removed. Otherwise the app and backstop.sh run the restore and keep the
attempt. uninstall.sh runs no pmset while an attempt stays unsettled or a
settled one cannot be finished: it says what it removed or journaled and
stops. A marker the lock holder deletes that no journaled start accounts
for (left by an older build, or by a start that finished but could not
delete it) takes session.json with it, for the same reason.

Only install.sh (which creates the receipt), uninstall.sh (which removes
this user's receipt and release file and then the folder once it is empty,
as root, after the same checks) and the root command of an authenticated
Start change the receipt. uninstall.sh removes the two files only under the
receipt's lock, and only while the release file shows the receipt's own
nonce `free`. It stops before removing anything, says why and exits 1 when
the lock stays busy, a start claims the receipt, the release file shows
another nonce, the receipt, the release file or a folder above them cannot
be read or fails the checks, or one of the two files is there without the
other. One lone release file is let through: the one an uninstall of the
same folder left when it stopped between removing the receipt and
removing the release file. Just before it removes the receipt, under the
receipt's lock, it writes `.uninstall-receipt-removal` in its own folder
with the release file's device, inode, change time to the nanosecond and
line. A rerun removes the lone release file only while it is a regular
file of this user's with one link, mode 0600 and 42 bytes, matching that
record exactly, with `free`. A start claims and gives back only by
writing to the release file, through the receipt, which is gone, and any
write changes the change time. The record has no fsync(2): a crash may
lose it, and the rerun then refuses, the safe side. It runs `sudo -v` first, which asks for the password before
anything is removed, then `sudo -n -v`, which stops it there when sudo
kept no credential. Every command it then runs as root goes through `sudo
-n` with its 30 s call limit, while it holds the recovery lock and the
receipt's lock. A call that fails, is stopped by SIGTERM at that limit, or
is still running after it stops the uninstall there: what it did is not
known, so nothing after it is removed. sudo only ever gets SIGTERM, and a
sudo still running keeps both locks until it exits. The app, backstop.sh
and uninstall.sh also write the release file, which is the user's. Each
start rewrites the same 82 bytes in place, so nothing accumulates. A new
start's nonce is random and never
the all-zero one.

What this design does not close. pmset has no compare-and-set and one
SleepDisabled value with no owner, so no read is atomic with the write
after it, and a 1 another tool writes over a 1 already in effect leaves no
trace.

- A SleepDisabled 1 another tool sets in the instant between the root
  command's second read and its `disablesleep 1` (the clock check and the
  time pmset takes to start) cannot be told from Insomnia's, and the
  session's end sets it to 0. One set during the session is set to 0 by
  the session's end.
- One set while a dialog is up, before the root command's first read, or
  while its `writing` line is written, before the second read, stops the
  command and stays, after a crash too, when the command reports exit 6 or
  writes its `refused` line. When that line cannot be written, the
  receipt still shows `writing`. The app that gets the exit 6 rolls the
  start back with no undo, and while it cannot journal that rollback its
  own later settlements of the start keep the exit 6 as their verdict.
  When the status is lost (a signal, the dialog's time limit, a crash
  before the app acts on it), or the app quits or crashes before it can
  journal the rollback, or backstop.sh or uninstall.sh settles the start
  first, that settlement reads `writing` and sets that 1 to 0. One set
  after the
  second read is set to 0 when the start then fails (a pmset failure, or a
  signal or the dialog's time limit before pmset). The second read narrows
  the window; it is not an owner token and does not close it.
- When the receipt shows nothing once `expires` has passed (missing,
  replaced, unreadable, under a changed folder, or a later start's line
  that names another predecessor), the start is undone like an end, and a
  1 another tool set is set to 0. A receipt that stays locked decides
  nothing at any time, and the sleep undo waits for it (below).
- The receipt's line reaches the drive before pmset runs only on a drive
  that honours F_FULLFSYNC. On one that does not, a power loss can bring
  the receipt back with older content while pmset's 1 persists. That 1 is
  then reported as set by something else, Start is refused until it reads
  0, and the menu gives the command. A torn write shows nothing, and the
  start is undone like an end. The app writes the release file with
  fsync(2); backstop.sh and uninstall.sh write it with no fsync, since the
  shell offers none. state.json and session.json are replaced by rename
  without an fsync. A crash cannot put back a session.json from before the
  start that the start overwrote. Nothing makes the receipt, the release
  file, the journal and pmset's setting change together.
- A settlement journals its decision before it gives the claim back, so a
  crash between the two leaves a settled record that the next run
  finishes. An Insomnia folder deleted or abandoned while one of its
  starts is still journaled (settled or not), or a release file someone
  damaged, leaves a claim nothing gives back. Every Start of the user is
  then refused, with the claim's nonce in the message, until `sudo rm -f
  /private/var/db/com.kgarg.insomnia/<uid>
  /private/var/db/com.kgarg.insomnia/<uid>.released` and
  `./scripts/install.sh` again. install.sh alone keeps a `held` claim,
  read under the receipt's lock, even right after it made the receipt, and
  stops at a claim in a file that is not the user's 0600 file with one
  link. It replaces a release file with no claim by rename, after checking
  that the file still holds the bytes it read; a write between that check
  and the rename is lost.
- Only root and the user can open the receipt (mode 0600 and one read
  entry for the user), so another account cannot take its lock. Anything
  running as the user can hold it for as long as it likes, since the lock
  is advisory; the user's own processes can already rewrite the journal.
  Starts are then refused, and a journaled start is retried, unsettled,
  with its sleep undo held, for as long as the lock is held, after its
  `expires` too. A root
  command that never exits (a hung pmset or sudo query) holds the lock the
  same way, and Insomnia then never restores sleep for that start.
  Deleting the marker does not stop a command already past its nonce
  check, and the lock that command holds can outlast the dialog's answer
  window. A crash or timeout under a dialog keeps Starts in that folder
  refused for at least about 130 s, and with no limit while a command
  for that start runs or the receipt's lock, the claim or the journal
  cannot be had. A start in one Insomnia folder keeps
  Starts in every other folder of the user refused until it is settled.
  uninstall.sh holds the recovery lock and the receipt's lock while `sudo
  -v` asks for the password, with no time limit. A credential that runs
  out after `sudo -n -v` found it makes the next `sudo -n` fail, and the
  uninstall stops after the LaunchAgent is gone, so no recovery agent runs
  until a rerun finishes the uninstall or install.sh runs again. After
  uninstall.sh removes the shared receipt, any other Insomnia folder of the
  user needs `./scripts/install.sh` again before its next start. A Mac
  without `/usr/bin/perl` refuses every Start with exit 7.
- uninstall.sh removes the shared rule and receipt when the release file
  shows no claim, and no claim does not prove that no other Insomnia
  folder of the user owes a restore. A start gives its claim back once it
  is settled, while the session it began still runs, and a settlement
  gives the claim back before an undo that may then fail. An uninstall run
  from another folder at that point removes the rule that folder's restore
  of sleep needs: that restore then fails and is retried, and sleep stays
  off until install.sh runs again or the user runs `sudo pmset -a
  disablesleep 0`. Nothing in this change closes that, and it is not
  waived.
- On a full disk backstop.sh keeps its copies of session.json and
  state.json in memory and still restores what the journal records, but
  two things need room, as on main: a log line it cannot append ends the
  run, which can be before the restore, and a journal it cannot publish
  stays as it was until a later run can. A command whose supervisor
  cannot write its status files counts as not known to have finished, so
  the journal keeps its entry. A journal holding a NUL byte cannot be
  kept in memory and is then left as it is.
- The clock is the wall clock, as session.json's end is, and `expires`
  proves that no command for a start will begin only while that clock does
  not go back. A clock set back after a settlement lets a dialog left on
  screen pass the comparison with `expires` again, though only while a
  marker holds its nonce. A settled record that says a command never wrote
  is a record of what the receipt showed; it revokes nothing.
- The recovery agent is scheduled every 60 s, but launchd does not promise
  when it runs, and it does not run while the Mac sleeps, so no recovery
  has a fixed time bound.
- A process running as the user can write the marker, state.json,
  session.json and the release file, so it can erase or rewrite the
  journal entry and the attempt outright. It can swap a copy in for the
  marker while a command holds the original; the settlement still waits
  for the receipt's lock, which that command holds until pmset exits, and
  then finds its `writing`. A settled start's nonce written into a new
  marker turns nothing off: a start whose receipt still holds the
  predecessor settles only once its dialog ended by itself or `expires`
  passed, and its command refuses at or after `expires`. Without changing
  state.json it cannot make a start that wrote `writing` read as one that
  did not, since it cannot write the receipt or a folder above it, and a
  forged release file only lets a later start's line in, which names this
  start's nonce as its predecessor and shows nothing. The marker's and the
  receipt's locks are advisory.
- A start that turned sleep off but could not then mark its attempt
  settled keeps it unsettled; a later settlement finds its `writing`,
  removes the session.json whose end is that deadline and so ends that
  session early, with sleep restored. One that marked it settled but could
  not give the claim back or remove the record keeps its session, and an
  app relaunched over that record resumes it while sleep is still off and
  the journal still holds the sleep entry. The menu keeps a line saying
  that the start is still recorded and why, and new Starts stay refused
  until a run gives the claim back and removes the record. Only that
  start's own session resumes: it began at least a minute before the
  start's deadline, and its first end (its end less every extension) falls
  in the second the deadline names, or up to a second earlier for each
  extension with a fraction of a second (one cut short at the maximum).
  Any other session.json beside that record is ended rather than resumed.
  That includes the earlier session a failed start put back as it was when
  it then could not give its claim back: a relaunch ends that session
  while the record stays. That cost is not waived. A session whose marker
  could not be deleted when it started ends early too, when a later run
  deletes that marker with no attempt journaled.
- The app reads a session.json whose extensions do not add up (one that
  is not a finite number, a sum that is not, or a first end outside 1970
  to 9999) as one that does not parse: it moves the file aside and
  restores the journal. No session the app wrote has such a history; a
  process running as the user, or damage on disk, can write one.
  backstop.sh reads only the session's end, so it honors that end until
  the app moves the file aside; uninstall.sh ends any session either way.
- While the journal claims a 1 from an earlier session, another tool's 1
  is taken for it, and a refused start leaves that 1 in place with its
  restore still owed.
- sudo answers for the moment it is asked: a rule removed later, a
  sudo.conf or PAM change made later, or other groups for the user when
  the app or backstop.sh runs sudo than when root switched to that user,
  can still make a later restore fail, and backstop.sh then keeps the
  journal entry and retries. Any sudo but 1.9.17p2 refuses every Start, a
  newer macOS's included, until an Insomnia release is checked against it,
  and so do an /etc/sudo.conf, PAM session lines other than macOS's own, a
  Defaults entry for the user, the host or everyone outside the accepted
  list, Defaults bound to a Runas user or a command, `listpw` set to
  always, and a later rule for the restore, even a passwordless one.
  Reinstalling Insomnia changes none of these.
- The stock ancestry of `/private/var/db` (root's, no group or other
  write, no allowing ACL) is what macOS installs; a Mac where it differs
  refuses install and Start. Neither the receipt, its lock, perl's
  F_FULLFSYNC nor any of this was run on a Mac as root in testing: every
  check above ran against fakes and files in a temporary folder.
- These rules cost availability, and none of that cost is waived: Start
  is refused under any sudo, sudo.conf, PAM or Defaults setting the checks
  do not accept, without `/usr/bin/perl`, while the user or root holds
  the receipt's lock, while a claim nothing gives back is out, and
  over the 45-byte receipt of earlier builds of this change, which
  install.sh refuses rather than convert. A start can stay unsettled, with
  Starts refused and its sleep undo held, for as long as its receipt stays
  locked.

Closing the ownership gaps needs a sleep assertion owned by a process, or
a pmset that compares before it sets, which this design does not have.

The installer runs no pmset: right after writing the rule it confirms that `sudo -k -n -l` lists the
three commands without a password, which catches a rule sudo does not read
but is not proof that the restore runs, because the listing passes once any
of the user's rules is passwordless. At every Start the root command's
`sudo -k -n -ll` reads the rule that decides the restore. A file that
cannot be deleted (its command is still running, an immutable flag, an ACL)
does not stop sleep from being turned back on, but the journal keeps the sleep
entry, the app and the agent report it and retry, and new sessions are refused
until it is gone. The rule stays in place after a failed install (the README says what
was installed). The installer never writes a passwordless `disablesleep 1`
line, on any path, including failed upgrades. It asks for the password before
it quits a running Insomnia, so a cancelled password changes nothing, and it
quits the app before it writes the rule, stopping with nothing changed if the
app will not quit. It writes the rule under the recovery lock, after the
app has quit. If it stops after the rule is written but before the app is replaced, an
older build left installed cannot start a session until the installer is
rerun; it fails closed and the installer prints the rerun command. The
uninstaller removes the file.

The app is not sandboxed; local logs can contain SSIDs, process metadata, and
tmux target names. The lines the app writes to `insomnia.log` also reach the unified log with the
body marked private, so programs reading `log show` see `<private>` instead of
those names unless private data logging is enabled on the Mac. The files
Insomnia creates (logs, journal, session, config, recovery lock) are mode 0600
and its directories 0700; the backstop runs with `umask 077`. Insomnia sets
only these modes and leaves any access control list (ACL) on these files as it
is, so an ACL someone added can still give another account access. Logs are capped at
1 MiB with one older copy kept. A log the user replaced with a symlink is not
rotated: the file it points to is the user's to manage. Location
Services access is requested only when a hotspot is saved or a session starts
with one configured; it is used to read Wi-Fi network names and the app never
requests location updates. With the App Nap setting on (off by default), the
app writes `NSAppSleepDisabled` into the preferences of each app on the agent
list, after recording the previous value in its journal, and puts it back at
session end.

The hotspot password is a generic-password item in the login Keychain
(service `insomnia-hotspot`). Its access list names only the Insomnia build
that saved it, so any other program asking for it gets the system Keychain
prompt, which you can refuse. Insomnia itself reads the item with prompts
switched off: an item it may not read is reported in the menu and in Settings
instead of being prompted for or silently ignored. Two limits remain. Ad-hoc
signing gives every install a new code identity, so the access list pins one
build and the password must be entered again after a reinstall; a stable
signing identity (Developer ID) would let the access list name every build
signed with it. And the item lives in the file-based login Keychain, which
ignores the data-protection accessibility classes (this device only, when
unlocked); using that Keychain needs an access-group entitlement, which needs
a team id. Releases are ad-hoc signed, so both limits stay.

The recovery LaunchAgent runs only the `backstop.sh` sealed inside the signed
app bundle, after `codesign --verify --strict` passes against the code
requirement pinned in its plist (the build's cdhash for an ad-hoc signature).
An edited bundle or script is refused and logged. The app pins the code it is
running (its own designated requirement, after confirming that the bundle on
disk is still that code and passes the agent's check), so a bundle edited or
re-signed under the running app is refused, not re-pinned. The plist itself
lives in `~/Library/LaunchAgents` and, like every per-user LaunchAgent, can be
edited by any program running as that user. With ad-hoc signatures these
checks are integrity against accidents and against the app relaying a
tampered bundle; they are not a boundary against a process running as the
same user, which can edit the plist, load its own agent, replace and relaunch
the app, and invoke the three pmset commands of the sudoers rule directly.

Release zips are built by the Release workflow from the tagged commit and
published with a `SHA256SUMS` file and a GitHub build provenance attestation.
Verify both before installing (`shasum -a 256 -c SHA256SUMS`,
`gh attestation verify <zip> -R krishhgg/Insomnia --signer-workflow
krishhgg/Insomnia/.github/workflows/release.yml --source-ref
refs/tags/v<version>`); `install.sh --app` then checks the signature,
identifier and version of a private copy of the bundle before asking for a
password, installs that copy, and refuses
it unless `--allow-unverified-origin` is given, because it cannot verify where
a bundle came from, whatever its signature names. The attestation shows which workflow run produced
the bytes, not that the code is free of defects. Releases are ad-hoc signed and
not notarized ([docs/releasing.md](docs/releasing.md)), so macOS blocks their
first launch.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
