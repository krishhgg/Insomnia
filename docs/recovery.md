# How recovery works

The [README](../README.md#how-recovery-works) has the short version. This page
has every case.

Insomnia records pending changes in a recovery journal. On session end, the app
attempts to undo them. An independent `launchd` agent checks every minute and
can attempt recovery after the app exits unexpectedly, once the saved deadline
has passed. It leaves a valid, unexpired session alone.

Undoing never needs a password: the sudoers rule covers turning sleep back on,
so the app, the agent, and the uninstaller can all restore sleep unattended.
Turning sleep off is the only step that asks, and only when you press Enter.
After you type the password, and before it changes anything, the command
behind the dialog checks whether the session's end will be able to turn
sleep back on without a password. As root it first checks that there is no
`/etc/sudo.conf`, which can load sudo plugins that a listing does not show,
and that `/etc/pam.d/sudo` has macOS's own single session line. Then it
switches to your account and runs your sudo three times: `sudo -V`,
`sudo -k -n -l`, and `sudo -k -n -ll /usr/bin/pmset -a disablesleep 0`,
which prints the sudoers rule that decides
`sudo -n /usr/bin/pmset -a disablesleep 0`, the command the session's end
runs. `-k` makes sudo ignore a password you typed into it recently and `-n`
makes it fail instead of asking. None of the three runs a command. Sleep is
turned off only when sudo is 1.9.17p2 (the sudo in macOS 26.2) with only
its built-in plugins, every Defaults entry sudo lists as applying to you
(set for everyone, for your account or for this Mac) is one the check
accepts, sudo lists no Defaults bound to a Runas user or a command, and the
rule is the one in `/etc/sudoers.d/insomnia`, as
root, with NOPASSWD and nothing else. Otherwise nothing is changed, the
start is undone, and the message names what stopped it. If the rule file
is gone or not in effect, run `scripts/install.sh` again. The installer
does not change the other checks: another sudo version (a newer macOS
included) needs an Insomnia release checked against it, and a sudo.conf, a
changed PAM file, Defaults bound to a Runas user or a command
(`Defaults>root`, `Defaults!/usr/bin/pmset`), Defaults for you or for
everyone that the check does not accept, or a later rule for the same command stop every
Start until you remove them. You find this out only after typing the
password: the check needs root, and before the dialog the app runs nothing
through sudo, it only reads `pmset -g`.
When Insomnia starts up (login, or a relaunch after a crash) and finds a valid
session on disk, it checks whether sleep is still off. If it is, the session
continues; if something turned sleep back on in the meantime, the session ends
with a notification instead of asking for a password with nobody at the
keyboard.

The app and backstop use the same lock so they do not restore and rewrite the
journal over one another. Failed restoration keeps the relevant entries;
unreadable journals are preserved instead of treated as clean. A session file
that does not parse counts as expired and is renamed to
`session.json.unreadable-<time>` beside it, never deleting or overwriting
anything: the app does this at launch, before restoring whatever the journal
holds, and says where the file went; the agent does it once the journal is
clean. A session file that cannot be read at all (permissions, or not a
regular file, which is never opened) also counts as expired, since its end
time is unknown: the journal is restored and the file is renamed the same
way without being opened, so a later launch cannot resume a session that
was treated as ended. The app says where it went. A session file whose
extensions do not add up to a first end between 1970 and 9999 (an extension
too large to add, which no session Insomnia wrote has) counts as expired
too: the app renames it at launch and restores the journal. The agent reads
only the file's end time and honors it until the app has renamed the file.
If the rename fails, the
app keeps trying it and will not quit until the file is gone.
`uninstall.sh --purge` removes the renamed copies that are regular files;
without `--purge` they stay.

**Recovery is not "everything always gets undone."** The backstop does not
monitor battery or temperature. Saved audio needs the app to reopen, and
unconfirmed process freezes may need manual inspection. If a warning remains,
resolve it before leaving the Mac unattended. Real-machine crash, reboot, and
installation scenarios still need [release validation](release-validation.md).

## Starting a session

When you press Enter, macOS asks for your administrator password to turn system
sleep off. It asks only while sleep is on: if another tool has already
turned sleep off, Start changes nothing and shows the command that turns
it back on, so that tool's setting stays. After you type the password,
the command behind the dialog reads the setting again before it changes
anything. If another tool turned sleep off while the dialog was up, the
command stops there: no session starts, nothing is changed, and that
tool's setting stays. A password typed after the session would already
have ended turns nothing off.

Insomnia keeps a receipt that says whether that command turned sleep
off: `/private/var/db/com.kgarg.insomnia/<your user id>`, a file
`scripts/install.sh` makes and only root can change. Every Insomnia
folder of your account shares it. A start claims the receipt before its
dialog, in `<your user id>.released` beside it, and Insomnia gives the
claim back only after the start's settlement is written to its journal.
Until then, Start in any other Insomnia
folder of yours is refused. The command locks the receipt before its
first check and keeps it locked until it and its pmset have exited.
Insomnia, the recovery agent and the scripts read the receipt only under
that lock. Right before the command turns sleep off, it uses
`/usr/bin/perl` to write the start's random code, the code the receipt
held before, and `writing` into the receipt. It then asks the drive to
flush its cache (`F_FULLFSYNC`) and reads the sleep setting again: if
something turned sleep off meanwhile, or the read fails, it writes
`refused` and stops, and that setting stays. If the start's answer
window has ended by then, it writes `refused` and stops. That window
ends when the
session would, or 130 seconds after Start if that is sooner: the
dialog's 120 seconds, the 3 seconds Insomnia waits after stopping it,
and 7 seconds for it to launch.

When a start fails in a way the dialog's answer does not explain,
Insomnia first deletes the start's `pending-start` file, so no command
for that start can pass its check any more. Then it reads the receipt
under its lock. Three receipts show that sleep was never turned off:
this start's code with `refused`; another start's line that names the
same earlier code; and the earlier code itself, once the dialog has
ended on its own or its answer window has ended. Then nothing is
changed, and a restore an earlier session still owes stays owed.
Anything else shows nothing, and Insomnia runs
`pmset -a disablesleep 0`, which turns sleep back on even if another
tool turned it off in the meantime. It does so at once for this
start's `writing` or a later start's line. A missing, replaced or
unreadable receipt waits for the answer window to end, since a command
for the start could still write until then. Until then, for as long as
the receipt stays locked, and at any time while a check of the receipt
or a folder above it cannot be made (an owner, a mode or an access
control list that cannot be read whole), nothing is decided: the start stays
recorded with its claim, Start is refused, and sleep is left as it is,
even when an earlier session still owes a restore. Insomnia's other
changes (Low Power Mode, stopped processes, audio) are undone as usual.
The window's end only shows that no new command for the start can
begin, and only while the clock is not set back. A command already
running keeps the receipt locked until its pmset exits, so Insomnia
waits for the lock however long that takes: a command that never exits
means Insomnia never turns sleep back on for that start. The next run
after the window ends that can lock the receipt settles it. It writes
the result into the journal first, then gives the claim back, then
drops the start's record. If it stops after the first step (a crash, or
a `.released` file or journal it cannot write), the next run finishes
those steps from the journaled result without reading the receipt
again, and Start stays refused until then.

Start refuses with nothing changed while the receipt is missing or
unsafe (it says to run `./scripts/install.sh` again), while a start
from another Insomnia folder of yours is not settled, and while
something holds the receipt's lock for more than 10 seconds. Only root
and your account can open the receipt, so another account cannot hold
that lock; anything running as you can. A Mac
without `/usr/bin/perl` cannot start a session: the command refuses
after you type the password. SECURITY.md lists what the receipt cannot
show.

How a start that does not turn sleep off ends:

- **Cancel** starts no session and changes nothing.
- **A wrong password** starts no session. The command never ran, the
  dialog ended on its own, and the receipt still holds the earlier code,
  so nothing is changed.
- **No answer within 120 seconds** starts no session. Insomnia sends
  the dialog SIGTERM, but a dialog can still be answered until its
  answer window ends, a few seconds later. Insomnia waits up to 15
  seconds for the window to end, then reads the receipt: the command
  never ran, so nothing is changed. If the window ends later than that,
  the start stays recorded until then, and Start is refused meanwhile.
- **The command takes too long.** The 120 seconds count from when the
  dialog appears, so they include the command that runs after you type
  the password. When they run out, Insomnia sends the dialog SIGTERM,
  never SIGKILL. A command still running behind it (asking sudo,
  reading the setting or turning sleep off) is waited for with no time
  limit: the session file, the journal entry and the recovery lock stay,
  Start and End wait, and the menu says what is still running and, while
  it is the dialog itself, its pid and how to stop it. Once nothing is
  running, the receipt decides as above: if the command had already
  written `writing`, sleep is turned back on. A pmset failure, or an
  answer lost to a signal, is settled the same way.
- **The dialog will not close** but no command behind it has started:
  Insomnia deletes the start's `pending-start` file, so a command the
  dialog starts from now on stops at that check, and settles the start
  from the receipt once its answer window has ended and no command for
  it holds the receipt's lock. The menu names the process with its pid
  until it exits.
- **Insomnia crashed or was force-quit with the dialog up.** The next
  run that holds the recovery lock (Insomnia after a relaunch, the
  recovery agent or `uninstall.sh`) deletes the start's `pending-start`
  file. launchd schedules the agent every minute but does not promise
  when it runs; it does not run while the Mac sleeps. A file that cannot
  be deleted, because a command behind the dialog still holds it or for
  any other reason, is retried on every later run. The unfinished
  session is never resumed. Until the start's answer window has ended,
  the old dialog can still be answered, so the start stays recorded,
  Start is refused, and sleep is left as it is. After that the receipt
  decides, once it can be locked: a start that never
  turned sleep off changes nothing and keeps any restore an earlier
  session still owes, and anything else turns sleep back on. If the
  journal cannot be updated with that result, the start stays recorded,
  Start is refused, and every run tries again. Meanwhile sleep is
  turned back on only when the receipt showed nothing or an earlier
  restore is owed. Once the result is journaled, a claim that cannot be
  given back or a record that cannot be removed keeps Start refused
  until a later run finishes them; the result is not read again. A
  session that start began goes on, a relaunch resumes it while sleep is
  still off, and the menu says the start is still recorded and why. The
  record names the session to resume, so an earlier session a failed
  start put back resumes too, and any other session file beside that
  record ends at the relaunch. A record an older build wrote, or one the
  scripts settled, has no such name: then only a session whose first end
  is the start's deadline resumes, and only while sleep is still
  recorded as Insomnia's.

Insomnia shows no dialog at all while the `backstop.sh` sealed in its
bundle is missing or older than the app expects, because an older one
cannot settle such a start from the receipt: Start then says to run `./scripts/install.sh`
again. A password typed while the sudoers rule is missing turns nothing
off either: the start is undone and Insomnia says to run the installer
again (see the start of this page). If the `pending-start` file that guards
such a dialog cannot be deleted, Insomnia still turns sleep back on, but
says so in the menu and a notification, keeps the journal entry, refuses
new sessions, and retries until the file is gone.

## Recovery limits and manual attention

- **Process ownership:** automatic resume checks the recorded process start
  time and boot session. The app journals each pid before it sends SIGSTOP,
  and sends nothing when that write fails. The identity is added only after
  the kernel confirms Insomnia's own stop, so a process somebody else had
  stopped is never resumed. If the confirming write fails, the app sends
  SIGCONT at once to each pid it just stopped whose identity still matches,
  even one that does not show as stopped yet: SIGCONT also cancels a stop
  that is still pending. It then drops those entries from the journal,
  shows the failure in the status menu, and stops counting them as frozen
  even if the disk refuses that write too. If the app dies between the stop and that write,
  the stopped pids stay journaled without identity, like entries from builds
  that recorded the pid alone, and are not automatically resumed while
  stopped. Verify the live process and whether it should be resumed; never
  blindly signal a PID from an old log.
- **Identity is not an atomic guarantee:** the app checks start time to the
  microsecond, and the backstop asks the installed app binary
  (`Insomnia --resume-frozen`) to do the same check and send the signal for
  every entry that records microseconds, all such entries in one call with a
  30-second limit. The entries go to the binary on standard input, so a long
  journal cannot exceed the argument size limit. The backstop never signals those entries itself. It keeps
  them when the binary is missing, does not finish in time, or answers
  anything but one expected line per entry. It runs the binary only when the
  installed bundle declares `InsomniaResumeFrozenVersion` in its
  `Info.plist`, so it never starts an older build. During an upgrade,
  `install.sh` runs the recovery of the bundle it staged and verified with
  `--own-bundle`, so the binary and `Info.plist` checked are the staged
  build's, not the build being replaced. The binary holds the
  recovery lock while it can still send a signal and ends itself after the
  same limit, so a backstop run that is killed mid-call leaves no helper
  that could act later without the lock. `uninstall.sh` uses the backstop
  installed with an app that does not declare that version. With no such
  copy, the checkout's backstop keeps those entries and uninstall stops
  before removing anything. Entries written by builds before
  microseconds were recorded keep the one-second `ps` comparison in the
  shell. A lookup and a signal are still separate operations, one pid at a
  time.
- **Stuck power commands:** a `sudo pmset` that has not finished after 20 s
  is sent SIGTERM, never SIGKILL: killing sudo could leave a root pmset
  changing power settings after the journal has moved on. If it is still
  running 3 s later the transaction stops where it is, as the backstop's
  does: nothing else is undone, the journal keeps its entries, and the
  recovery lock stays held until the command exits. The command holds the
  lock itself (its stdin is a descriptor on the lock file), so if Insomnia
  crashes or is force-quit meanwhile, the backstop still waits for the
  command instead of running an undo the command would then override. A
  notification and a menu warning give the pid and `sudo kill <pid>`; the
  warning goes away when the command exits. The pid is also written to
  `unfinished-command.json` with the command's start time and boot
  session. A relaunch that finds the lock busy names the command in the
  menu. It gives the pid and `sudo kill`, in one notification as well,
  only while that pid still has the recorded start time and boot session;
  otherwise it says the command has exited, since the pid may now belong
  to another process. The relaunch tries again 30 s after each refusal.
  Once the command has exited, it resumes a session that has not expired,
  with its battery floors, and checks Low Power Mode the way it does after
  its own command exits, described below. A session the user starts
  before that next try gets the same check. Until the command exits,
  Insomnia refuses to quit or start a session, and records any end or lid
  event it refuses. A
  `disablesleep 0` or `lowpowermode 0` that exits 0 counts as done: its
  journal entry is cleared before the lock is released, and the command
  is not run again. If that journal write fails, the menu says so and the
  undo runs again; the line goes once a later write clears the entry. Any
  other exit counts as a failure. Then a pending end runs again.
  Otherwise Insomnia reads Low Power Mode. If it reads off, Insomnia runs
  its own `lowpowermode 0` and forgets the mode only once that succeeds.
  Then it replays a refused lid event, after waiting out the 2 s lid
  debounce, and runs the floor rules again. If the mode cannot be read or
  switched off, or the journal cannot be written, it tries again every
  30 s while the session lasts. The password dialog is different: it is
  never killed either, but a dialog whose `pending-start` file is gone can
  no longer change anything once its answer window has ended, so that
  start is settled from the receipt then, a few seconds later, and the menu
  names the dialog until it exits.
- **Audio:** the backstop preserves volume/mute entries but cannot restore
  CoreAudio. Reopen the app for recovery. An output device that is not
  connected keeps its entry until it reconnects, and uninstall stops while
  one is waiting: connect it and open Insomnia, or choose "Stop waiting for
  <device>" in the menu.
- **Sleep disabled by something else:** at launch, with no session and no
  journal entry, a `SleepDisabled 1` in `pmset -g` is left alone: Insomnia
  did not set it and only its owner should undo it. The menu shows a warning
  and a notification gives the command, `sudo pmset -a disablesleep 0`.
  Start is refused until it reads 0 again, since the session's end would
  turn sleep back on. Start reads it before the dialog, and the command
  behind the dialog reads it as root after it has asked sudo, and once
  more after it has written its receipt line, right before its last clock
  check and its only write; a 1 at either read stops the command, and the
  1 stays. Nothing writes 0 before that write. pmset cannot change the
  setting only if it still holds a given value, though, so one moment
  remains uncovered, and this is not fixed. A `SleepDisabled 1` another
  tool sets in the instant between the command's second read and its own
  `disablesleep 1` looks like Insomnia's own, and the session's end sets
  it to 0. One set during the session is set to 0 when the session
  ends. One set while the dialog is up stays when the start then fails or
  is abandoned (a crash included) and the receipt shows that the command
  never turned sleep off, also while the journal cannot take that result.
  One set while the command writes its receipt line stops it at the second
  read and stays too, unless the command's `refused` line cannot be
  written and its exit status is lost, or Insomnia gets the status but
  cannot save the rollback before it quits or the recovery agent or
  uninstall.sh settles the start: the receipt then still shows
  `writing`, and the 1 is set to 0. It is set to 0 when the receipt shows
  nothing: at once when the command
  wrote `writing` and then failed or was stopped, or a later start's line
  names another earlier code, and once the start's answer window has
  ended when the receipt is missing, replaced or unreadable. While the
  receipt stays locked, or a check of it cannot be made, nothing is set
  to 0. On a drive that ignores the
  flush request, a
  power loss can bring back an older receipt while pmset's 1 persists;
  that 1 then reads as set by something else. And while Insomnia still
  owes a restore from an earlier session, another tool's 1 looks like
  Insomnia's own. A program running as you can change `pending-start`, the
  `.released` file and the journal, and with them which of these happens;
  SECURITY.md says how.
- **Low Power Mode:** Insomnia checks the existing setting so it does not
  claim ownership of an already-enabled preference.
- **App Nap:** off by default. When the setting is on, Insomnia journals each
  agent app's previous `NSAppSleepDisabled` value before writing it and puts
  it back at session end, in the backstop, and in uninstall. Values an older
  build wrote without a record are not guessed at: uninstall prints the
  `defaults delete` command for each one and continues.
- **Uninstall:** refuses to remove recovery machinery while unresolved changes
  remain. A failed uninstall is not confirmation that power settings are normal.
