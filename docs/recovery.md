# How recovery works

The [README](../README.md#how-recovery-works) has the short version. This page
has every case.

Insomnia records pending changes in a recovery journal. On session end, the app
attempts to undo them. An independent `launchd` agent checks every minute and
restores the journal once the saved deadline has passed. It also ends a valid
session early, restoring the journal the same way, in three cases. No Insomnia
process holds the liveness lock: `.app.alive` is an `flock(2)` the app takes at
launch, and the kernel releases it when the process dies, however it dies. A
second copy that cannot take it quits at launch without changing anything. The
Mac is on battery power with the charge below the end floor from `config.json`
(default 10%); a battery that is present but cannot be read counts as below
it. Or the thermal pressure level reported by `notifyutil` is critical while
the thermal rule is on. The agent normally does not parse `config.json` itself.
It passes the file to the app's binary in `~/Applications/Insomnia.app` with
`--agent-cutoffs`, which decodes it with the app's own code, prints the end
floor and the thermal setting, and exits without starting the app. This runs
once a minute while a session is valid, the app is running and the file exists.
Without the file, or with one the app rejects or cannot read, the agent uses
the end floor and thermal setting the app recorded for the session in
`state.json`, read the same way with `--agent-session-cutoffs`. The app records
them before a session starts or resumes and before a change to either takes
effect; when it cannot, it refuses the change or ends the session. A journal
without them (a session an older build started) gives the app's defaults (10%,
on). When the binary cannot answer (it was removed or replaced by an older or
newer build after the agent checked the bundle's signature, it gives no answer
in its form within 30 seconds, or `config.json` is over 8 MiB), the agent reads
`config.json` itself and logs that it did. It copies the file once, at most
8 MiB, and reads the copy's text with its own reader, without `plutil`, as the
app's decoder reads it: the first copy of a key, keys after their escapes,
numbers as the setting's type reads them (`1e-400` as an end floor of 0), and
what the decoder skips skipped. A file the decoder rejects (text that is not
JSON it reads, a setting of a type it does not take, a number the type does
not hold) counts as rejected. A file over 8 MiB, one the reader does not
finish within 30 seconds, and one with an Int64 on which Foundation stops the
app (the app stops there; it neither loads nor rejects the file) are not
used: what the app makes of them is not known here, and they count as read
neither way, below. For a rejected file, and one the agent does not use, it
reads the recorded values from `state.json` itself. On either path, a
recorded value the app does not write
counts as none, as the app reads it, and so does a `state.json` that is a
symlink to nothing, which the app reads as no journal. With `config.json`
missing, not a regular file, not readable by you, or rejected, none gives the
app's defaults (10%, on). With `config.json` a regular file you can read but
read neither by the binary nor by the agent, none gives the strictest values,
a 95% end floor with the thermal rule on, and a log line says why. The values the app enforces are not known to the agent then, though
they may be on disk: a valid `config.json` over 8 MiB, or one the reader does
not finish within 30 seconds, still holds the values the app takes from it. A
file on which Foundation stops the app is not a decode; the app never loads it.
So the agent can end a session on battery below 95%, or at critical heat with
the thermal rule off, that the app would keep. A running app that answers writes its record
within a second, so these cases need an app that has stopped answering. The
defaults and the 95% values here are stopgaps no one has approved; spec section
6 lists them as open. Before it reads them, or ends a session, the agent checks
the parts of `state.json` the app decodes. It reads the file's text as the
app's decoder reads it: a key written twice counts by its first copy, and a
number `plutil` would read otherwise is read as the app reads it. When the
parts do not load as the app loads them, or the check cannot tell what the app
makes of them (an Int64 on which Foundation stops the app, text it does not
finish reading within 30 seconds), the agent keeps the session, changes
nothing and logs why, until the app or a person fixes the file; the first run
after the fix ends the session if it is over. A string the app reads that
holds `\u0000`, which `plutil` cannot hold, is read through a placeholder that
no string of the journal holds, whatever its length and whatever else the
journal holds; when no placeholder can be had (the system's `grep` fails), the
check refuses the journal as not known (spec section 6). A running app
rewrites the journal in its own form the next time it writes it, but with the
app crashed or hung, a journal the check refuses keeps the session and its
sleep hold, past the deadline too, until someone fixes the file. A journal
the agent edits is published only when the edited copy loads as the app loads
it, holds every `Float` the app decodes bit for bit as before, and has the
text of each string that holds `\u0000` back once, in the entry and under the
key it had (when the agent takes entries out of an array, each entry that
moves up keeps its own strings); otherwise
the agent keeps the old journal, with what it still has to undo, and exits 1. Each
early end is logged with its reason, and the saved session is deleted before
the restore starts. A restore that cannot finish leaves entries in the journal
for the next run and the app. If the saved session cannot be deleted, its end
is recorded before anything is restored: in `ended-session.json`; when that
file cannot be written, in the journal (`endedSession` in `state.json`); when
neither can be written, in a new file beside them named `ended-session.json.`
followed by eight letters or digits; when that folder takes no new file,
in a file with such a name in `~/Library/Logs/Insomnia`; and when neither
folder takes one, in the recovery lock file `.recovery.lock`, which exists
already. That record is written in place, so the file keeps its inode and stays
the lock both sides take. A writer cuts the file back to bytes it shares with
the start of the record, or to nothing, before it appends the rest, so a writer
stopped partway leaves the old bytes, an empty file or the record's first
bytes. A writer counts the record only once it reads it back whole. The saved
session's record cut short as a writer leaves it when it stops partway (its
first bytes, or the whole record followed by bytes the file held before) still
counts as that session's end, and a writer completes it instead of emptying it.
Other content there (other bytes, a record of other bytes cut short, more than
1 MiB) ends no session, and the agent empties it, as the app does before it
starts or resumes a session. A record's first bytes are also the first bytes of
a later session's record, so a start empties everything but a record of the
saved session it replaces before it writes its own. A lock file that cannot be
read on three tries 0.1 s apart counts as the end of the saved session, since
it may hold one, and no writer writes over it. That rule keeps to the safe
side and is no proof: a lock file that holds no record but keeps failing to
read (an I/O error) ends a session nobody ended. When the log holds a record of
that session, the app and the agent name the log instead. When the lock file
takes no write either, the end goes into `insomnia.log` as one line holding the
saved session's bytes. A line that lacks only its newline at the end of the log
counts too, so Insomnia's writers of the log (the app, the agent and its
LaunchAgent) put a newline first when the log does not end in one, and hold
flock(2) on the log from that check until their line is written. An ordinary
line they cannot lock in time waits in memory in the app and goes to standard
error from the agent; a record they cannot lock in time is not written. A
process that appends without that lock can still join a line to a record that
already read back, and that record then ends nothing. A record counts only once
it reads back as a whole line, a saved session over 64 KiB is never recorded
there, and the app and the agent do not search a log that cannot be read or is
over 64 MiB, so a record such a log holds ends nothing for them. The app rotates that log only while it holds the recovery
lock and copies such a line forward when it does, so the record lasts while the
saved session stays. The agent reads each
record back before it restores anything. The app and the agent count a record
aside or in the lock file only if it is a regular file you own, not a link,
and the log folder only if it is a real folder you own, not a link.
`ended-session.json` counts as `session.json` does: a link there is
followed to a regular file, and its owner is not checked. While a record matches the saved
session byte for byte, the app restores that session instead of resuming it,
whatever `pmset` reports, and every agent run ends it again. A record matches
bytes, not a session: a saved session written later with the same bytes,
which takes the same start and end times to the second, would read as ended
too. A session the app was running when it crashed, with no record of its
bytes in any of these places, resumes at the next launch under the rules
below. Only when neither folder takes a new file, the lock file takes no
write and `insomnia.log` takes no new line either (a full disk, say) is
nothing recorded. The agent still runs the restore,
but it cannot confirm the result, so it keeps the journal and exits 1. The app
resumes no session while it cannot write `state.json`, none whose journal says
sleep is held while `pmset` reports it is not, and none whose `session.json`
it cannot replace with the same bytes. That last rule has a cost: a session
the app was running when it crashed is ended at the next launch, not resumed,
while its `session.json` cannot be replaced. Once `session.json` can be
replaced and `state.json` written again, an app launched before the next agent
run resumes a session ended with nothing recorded if sleep still reads as
disabled (the restore failed, or something else disabled sleep), because
nothing on disk tells that end from a crash. An end stopped before any record
of it counts (before `session.json` is removed and before a record is whole, or
before the first byte of one in the lock file) has undone nothing yet, so a
relaunch before the next agent run resumes that session too, and an end you
asked for is lost. Both cases are open limits, not accepted ones. Otherwise the
session stands until its deadline, and sessions are capped at 24 hours by
default (`maxDuration`).

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
was treated as ended. The app says where it went. If the rename fails, the
app keeps trying it and will not quit until the file is gone.
`uninstall.sh --purge` removes the renamed copies that are regular files;
without `--purge` they stay.

**Recovery is not "everything always gets undone."** The backstop checks the
battery and the thermal level once a minute and only for the two ends above.
Low Power Mode requests and notifications need the app. Saved audio needs the
app to reopen, and unconfirmed process freezes may need manual inspection. If a
warning remains, resolve it before leaving the Mac unattended. Real-machine
crash, reboot, and installation scenarios still need
[release validation](release-validation.md).

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
  `Info.plist`, so it never starts an older build. The binary holds the
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
  30 s while the session lasts.
- **Audio:** the backstop preserves volume/mute entries but cannot restore
  CoreAudio. Reopen the app for recovery. An output device that is not
  connected keeps its entry until it reconnects, and uninstall stops while
  one is waiting: connect it and open Insomnia, or choose "Stop waiting for
  <device>" in the menu.
- **Sleep disabled by something else:** at launch, with no session and no
  journal entry, a `SleepDisabled 1` in `pmset -g` is left alone: Insomnia
  did not set it and only its owner should undo it. The menu shows a warning
  and a notification gives the command, `sudo pmset -a disablesleep 0`.
  Ending an Insomnia session sets it to 0 whoever set it.
- **Low Power Mode:** Insomnia checks the existing setting so it does not
  claim ownership of an already-enabled preference.
- **App Nap:** off by default. When the setting is on, Insomnia journals each
  agent app's previous `NSAppSleepDisabled` value before writing it and puts
  it back at session end, in the backstop, and in uninstall. Values an older
  build wrote without a record are not guessed at: uninstall prints the
  `defaults delete` command for each one and continues.
- **Uninstall:** refuses to remove recovery machinery while unresolved changes
  remain. A failed uninstall is not confirmation that power settings are normal.
