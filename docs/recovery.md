# How recovery works

The [README](../README.md#how-recovery-works) has the short version. This page
has every case.

Insomnia records pending changes in a recovery journal. On session end, the app
attempts to undo them. An independent `launchd` agent checks every minute and
can attempt recovery after the app exits unexpectedly, once the saved deadline
has passed. It leaves a valid, unexpired session alone.

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

**Recovery is not "everything always gets undone."** The backstop does not
monitor battery or temperature. Saved audio needs the app to reopen, and
unconfirmed process freezes may need manual inspection. If a warning remains,
resolve it before leaving the Mac unattended. Each release's real-Mac crash,
reboot and installation checks are in [release validation](release-validation.md).

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
