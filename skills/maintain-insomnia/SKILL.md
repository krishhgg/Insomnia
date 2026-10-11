---
name: maintain-insomnia
description: Check on, troubleshoot, or uninstall an installed Insomnia (the macOS menu bar app that keeps a Mac awake for a timed session). Use when the user asks why Insomnia shows a warning, whether a session cleaned up after itself, why the hotspot password stopped working, or how to remove it.
---

# Maintain Insomnia

Reference pages in https://github.com/krishhgg/Insomnia:
[docs/recovery.md](https://github.com/krishhgg/Insomnia/blob/main/docs/recovery.md),
[docs/install.md](https://github.com/krishhgg/Insomnia/blob/main/docs/install.md),
[docs/lid-close.md](https://github.com/krishhgg/Insomnia/blob/main/docs/lid-close.md) and
[docs/extras.md](https://github.com/krishhgg/Insomnia/blob/main/docs/extras.md).

## Rules

- Never run `sudo`, `pmset` changes, `kill` or `kill -CONT` yourself. Show the
  user the command, say why, and let them run it.
- Never edit or delete files in `~/Library/Application Support/Insomnia/`.
  `state.json` there is the recovery journal: the list of changes Insomnia
  still has to undo.
- Never signal a pid taken from an old log line. Pids get reused. Check it with
  `ps -o pid,stat,lstart,command -p <pid>` first.
- Kong's Insomnia API client uses the same support folder name.
  `brew uninstall --zap insomnia` for that app moves this app's journal to the
  Trash. Check which app the user means before anything like that.

## Check the state

1. `tail -n 100 ~/Library/Logs/Insomnia/insomnia.log` shows what the app and
   the recovery agent did last. A `could not read the time now` line, or a
   `recovery stopped: ... did not finish within 30s` line that says
   `nothing was read or undone this run`, means that run undid nothing. One
   that says `nothing more is changed this run` stopped partway, so it may
   have undone some entries first; check steps 2 and 3 for what is left.
   Either way the agent tries again a minute later.
2. `pmset -g | grep -i sleepdisabled` shows `1` while sleep is turned off.
3. `cat ~/Library/Application\ Support/Insomnia/state.json` shows what is
   still waiting to be undone. These entries are pending:
   - `sleepDisabledByUs`, `lowPowerSetByUs` or `dockerFrozen` set to `true`
   - a non-empty `frozenProcesses`, `appNapOverrides` or `savedAudioOutputs`
   - `savedOutputVolume` or `savedMuted`
   - `savedDisplayBrightness` or `savedKeyboardBrightness`, unless
     `displayRestoreRefused` or `keyboardRestoreRefused` is `true`

   Other keys, such as `keptDisplayReadLit`, `keptDisplayUnderLowPower` and
   `displayRestoredUnderLowPower`, are records the app keeps, not changes to
   undo. A brightness value kept after a refused restore blocks nothing.
   Saved audio for an output that isn't connected waits for it to reconnect
   and doesn't block ending a session.
4. `launchctl print gui/$(id -u)/com.insomnia.backstop` shows whether the
   recovery agent is loaded.

## Warnings in the menu

Match the warning to docs/recovery.md, "Recovery limits and manual attention".

- **A stuck power command with a pid.** The user checks the pid, then runs the
  `sudo kill <pid>` the menu shows.
- **Stopped processes Insomnia cannot prove it froze.** The user checks each
  pid with `ps` and decides whether to run `kill -CONT <pid>`.
- **An output device still muted.** Reconnect it and open Insomnia, or choose
  "Stop waiting for <device>" in the menu.
- **Sleep disabled by something else.** Insomnia did not set it and leaves it
  alone. Whoever set it turns sleep back on with
  `sudo pmset -a disablesleep 0`.
- **Hotspot password unreadable by this build.** A reinstall changes the app's
  signature. Enter the password again in Settings.

## Uninstall

Follow "Uninstall" in docs/install.md and hand the user the command, since it
asks for the password. It stops when something is still waiting to be
undone. Fix that first, then run it again. It also stops when the sudoers
rule has a line for another account or changed while it ran, when an access
control list on the rule or its folders allows more than reading, or when a
process named Insomnia that it cannot identify is running. When one of its
own steps did not finish within 30s, it says so and removes nothing more.
"Nothing was removed" means it stopped before removing anything; "Nothing
more was removed" means it may already have removed some of the install,
so check what is left. The user reruns it once that step has ended. It may
name a file it left in `/etc/sudoers.d` under a dotted name, which sudo
does not read. For this account's rule it prints a `sudo rm` command to
hand to the user. A changed rule it could not put back may be another
account's, so the user checks it with `sudo cat` before deciding. Show the
user its message and never edit `/etc/sudoers.d` yourself. A failed
uninstall does not mean the power settings are back to normal, so check
`pmset -g` afterward.
