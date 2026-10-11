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
   the recovery agent did last. A line with `ending the session before its
   deadline` gives the agent's reason: Insomnia was not running, the battery
   was below the end floor, or the Mac was critically hot. A line saying
   `state.json` "is unreadable or malformed" means the agent kept the session
   and its sleep hold. Ask the user to open Insomnia. The app rewrites a
   journal it loads the next time it writes it. Don't edit the file.
2. `pmset -g | grep -i sleepdisabled` shows `1` while sleep is turned off.
3. `cat ~/Library/Application\ Support/Insomnia/state.json` shows what is
   still waiting to be undone. These entries are pending:
   - `sleepDisabledByUs`, `lowPowerSetByUs` or `dockerFrozen` set to `true`
   - a non-empty `frozenProcesses`, `appNapOverrides` or `savedAudioOutputs`
   - `savedOutputVolume` or `savedMuted`
   - `savedDisplayBrightness` or `savedKeyboardBrightness`, unless
     `displayRestoreRefused` or `keyboardRestoreRefused` is `true`

   Other keys, such as `keptDisplayReadLit`, `keptDisplayUnderLowPower`,
   `displayRestoredUnderLowPower`, `sessionCutoffs` and `endedSession`, are
   records the app keeps, not changes to undo. So are `ended-session.json` and
   files named `ended-session.json.` plus eight letters or digits, here or in
   `~/Library/Logs/Insomnia/`: each says a session ended whose `session.json`
   could not be removed yet. A brightness value kept after a refused restore
   blocks nothing.
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
undone. Fix that first, then run it again. A failed uninstall does not mean
the power settings are back to normal, so check `pmset -g` afterward.
