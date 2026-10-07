<p align="center">
  <img src="docs/assets/eye-open.svg" alt="Insomnia: an open eye with a round pupil and five lashes above it" width="112">
</p>

<h1 align="center">Insomnia</h1>

<p align="center">
  <strong>Keep your Mac awake. Give the session an end time.</strong>
</p>

<p align="center">
  A native macOS menu bar app for timed awake sessions. Pick a duration for your
  long-running work, choose what happens when the lid closes, and see when
  recovery needs your attention.
</p>

<p align="center">
  <a href="#install"><strong>Install</strong></a> ·
  <a href="#using-it"><strong>Using it</strong></a> ·
  <a href="#how-recovery-works"><strong>Recovery</strong></a> ·
  <a href="SECURITY.md"><strong>Security</strong></a>
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/License-MIT-536D78?style=flat-square"></a>
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-303336?style=flat-square">
  <img alt="Experimental source build" src="https://img.shields.io/badge/Status-experimental-536D78?style=flat-square">
</p>

> **Use a stable, well-ventilated surface—not a closed bag.** Insomnia is
> experimental software. Recovery can fail; a running timer is not a safety
> guarantee.
> [Validation status](docs/release-validation.md) · [Apple's ventilation guidance](https://support.apple.com/en-us/102336)

<p align="center">
  <img src="docs/assets/session-flow.svg" alt="Illustrated menu-bar controls: enter Days, Hours, and Minutes, watch the countdown, and hold the end control to finish early. Click the eye or countdown to add time. Closing the lid is optional, and incomplete recovery needs attention." width="880">
</p>

## Install

Requires **macOS 26 or later on an Apple Silicon Mac**.

Paste this into your coding agent:

```text
Install Insomnia from https://github.com/krishhgg/Insomnia by following its README. If a step needs my password, give me the command to run in Terminal.
```

Or run it yourself:

1. Download `Insomnia-<version>-macos.zip` and `SHA256SUMS` from the newest
   release on the [releases page](https://github.com/krishhgg/Insomnia/releases)
   (releases are marked Pre-release). If the page has no release yet, build
   from source (below).
2. Verify the download (`gh` is the [GitHub CLI](https://cli.github.com)):

   ```bash
   shasum -a 256 -c SHA256SUMS
   gh attestation verify Insomnia-<version>-macos.zip -R krishhgg/Insomnia \
     --signer-workflow krishhgg/Insomnia/.github/workflows/release.yml \
     --source-ref refs/tags/v<version>
   ```

   The second command checks that this repository's Release workflow built
   this exact zip for that tag.

3. Unzip and run the installer that comes in the zip:

   ```bash
   ditto -x -k Insomnia-<version>-macos.zip .
   cd Insomnia-<version>-macos
   ./install.sh --allow-unverified-origin --app ./Insomnia.app
   open "$HOME/Applications/Insomnia.app"
   ```

   Releases are ad-hoc signed and not notarized. The installer can check that
   the bundle is intact but not who made it, so it refuses to install without
   `--allow-unverified-origin`, which says you ran the two commands in step 2.
   macOS blocks the first launch of a downloaded copy until you allow it in
   System Settings > Privacy & Security.

The installer checks the bundle's signature, identifier and version before it
asks for anything. It then installs the app and a background recovery agent,
and asks for administrator access to install a narrowly scoped sudoers rule. It grants
**your user account**, not just Insomnia, passwordless access to three
power-setting commands, none of which can keep the Mac awake: they turn sleep
back on and switch battery Low Power Mode on or off. Turning sleep off is not
in the rule; Insomnia asks for your administrator password each time you start
a session. Review that permission before installing.

Release zips are built for arm64 only, and their `install.sh --app` stops on
an Intel Mac. On Intel, building from source (below) is the only option, and
it is untested there.

### Build from source (experimental)

Requires **Xcode with Swift 6.2 or later**. Clone the newest release tag
rather than `main`. While no release exists, leave out `--branch v<version>`
to build `main`:

```bash
git clone --branch v<version> --depth 1 https://github.com/krishhgg/Insomnia.git
cd Insomnia
./scripts/install.sh
open "$HOME/Applications/Insomnia.app"
```

`scripts/install.sh` builds the same bundle the release workflow builds
(`scripts/build-app.sh`), ad-hoc signed, and installs it the same way. It
builds only when it runs from a checkout's `scripts` folder, with
`Package.swift` one level up, and then runs the `build-app.sh` beside it. The
`install.sh` from a release zip stops and asks for `--app` instead, even when
a `build-app.sh` was added to its folder after unpacking.
[docs/releasing.md](docs/releasing.md) describes the release pipeline.

<details>
<summary><strong>Exactly what gets installed</strong></summary>

| Location | Purpose |
| --- | --- |
| `~/Applications/Insomnia.app` | The menu bar app, with `backstop.sh` sealed inside it at `Contents/Resources` |
| `~/Library/Application Support/Insomnia/` | Configuration and the session/recovery journals |
| `~/Library/LaunchAgents/com.insomnia.backstop.plist` | Per-user recovery agent: verifies the app's code signature, then runs the sealed `backstop.sh` |
| `~/Library/Logs/Insomnia/` | `insomnia.log` and `handoffs.log`, each capped at 1 MiB with one older copy kept as `.1`, unless you replace it with a symlink |
| `/etc/sudoers.d/insomnia` | Permission for the three commands below |

```text
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -b lowpowermode 1
/usr/bin/pmset -b lowpowermode 0
```

The grant is available to other processes running as your user. It lets them
turn sleep back on and toggle Low Power Mode on battery, and nothing else; the
command that keeps the Mac awake, `pmset -a disablesleep 1`, always goes
through the standard macOS administrator password dialog. A reinstall over an
older install replaces the file, so the old `disablesleep 1` line is removed.
The installer never writes that line, on any path. It asks for your password
before it quits a running Insomnia, so cancelling the password prompt changes
nothing and a running session keeps going. When a session is running it says
the upgrade will end it before asking, and in a terminal it asks whether to
continue. It stops with nothing changed if the app will not quit. Then,
under the recovery lock, it writes the rule and replaces the app. If it stops
between the two, an older build left installed cannot start a session until
you rerun `./scripts/install.sh`, and the installer says so.
Insomnia is not sandboxed. The app, scripts, and journals are local; hotspot
passwords use the login Keychain, not the configuration file.

The recovery agent runs at login and every 60 seconds. Its command line pins
the installed bundle's code requirement (for an ad-hoc build, the cdhash of
that build) and runs `codesign --verify --strict` against it before executing
the `backstop.sh` sealed inside the bundle. An edited bundle or script fails
that check: the agent writes one line to `insomnia.log` and runs nothing until
you reinstall. So no other account can edit it, the installer removes group
and other write permission and every ACL from the bundle it installs. The
signature covers neither, so the bundle still verifies, and extended
attributes such as a download's quarantine flag are kept. No executable is
kept in a writable support directory. The plist in `~/Library/LaunchAgents`
is still a per-user file that any program running as you can edit, like
every LaunchAgent; the app rewrites it at the next session start when it does
not match, which is a repair, not a tamper check.

What the app pins is the requirement of the code it is itself running, read
through the Security framework after checking that the bundle on disk is still
that code and still passes the agent's check. A bundle whose sealed script was
edited, or that was re-signed under the running app, is refused rather than
pinned: the app does not start a session, or reports the end as incomplete,
and names the reason, until you reinstall. With ad-hoc signatures this guards
against accidental edits and against the app relaying a tampered bundle into
the agent, not against a process running as you: that process can edit the
plist, load its own agent, quit the app and launch a replacement, and run the
three `pmset` commands of the sudoers rule itself.

An upgrade asks the running app to quit and stops if it refuses. The new
bundle is built in a staging directory next to the app and moved into place in
the same step that replaces the recovery agent. That step starts only after
`launchctl print` confirms the previous agent is unloaded; otherwise nothing is
replaced. If the new agent cannot be loaded, or its plist cannot be saved, the
installer unloads it, waits for `launchctl print` to confirm that, and puts the
previous bundle back, so the loaded agent always matches the installed app. A
bundle that cannot be moved during that step is handled the same way: the
previous bundle goes back and its agent is loaded again. If the previous bundle
itself cannot be moved back, nothing is deleted: it stays at
`~/Applications/.Insomnia.app.previous`, the installer prints the two commands
that put it back and load its agent, and until then the agent finds no app, so
run them or rerun the installer before you log out. If
the unload is not confirmed, the new bundle stays with the agent that pins it
and the installer asks you to rerun it. After that, or after an install killed
in the middle of that step, the next run keeps whichever bundle the agent's
plist on disk pins. It does that only after its own recovery step succeeds:
while recovery is unresolved, an agent the earlier run left loaded may be the
one retrying it, so the installer stops without unloading that agent or
moving either bundle. Once recovery succeeds, it unloads that agent, moves the
bundle back and loads the plist on disk again, and it stops if `launchctl
print` does not confirm the unload or the reload. Unresolved recovery prevents
replacing either; follow the reported instructions before retrying. The
installer checks the sudoers rule again once it holds the recovery lock, and
stops if the rule is gone, as after an `uninstall.sh` that took the lock first.
Each call it makes to `sudo`, `pgrep`, `launchctl` or `codesign` while it
holds the lock has a 30 s limit, which a supervising process enforces even
if the installer is killed meanwhile. The call keeps the lock until it has
exited or been stopped, so no `launchctl bootout` it started is still
running once the lock is released. A call that does not answer in time gets SIGTERM, then SIGKILL
one to two seconds later, and the install stops, so the lock is released and the app
and the agent's backstop can take it again to undo a session. `sudo` only
ever gets SIGTERM: one that ignores it keeps the lock until it ends, and the
installer prints its pid.

</details>

## Using it

1. **Start:** click the eye in the menu bar, enter Days / Hours / Minutes, and
   press Enter. macOS asks for your administrator password to turn system
   sleep off. It asks only while sleep is on: if another tool has already
   turned sleep off, Start changes nothing and shows the command that turns
   it back on, so that tool's setting stays. Cancelling the dialog starts
   no session and changes nothing. A wrong password, no answer within 120
   seconds, or a pmset failure also starts no session, but Insomnia cannot
   tell whether pmset ran first, so it runs `pmset -a disablesleep 0`,
   which puts sleep back on as it was when the dialog appeared. A
   password typed after the session would already have ended turns nothing
   off. If the dialog's process will not close, Insomnia voids its start so
   it can no longer turn sleep off, rolls the start back at once, and names
   the process with its pid in the menu until it exits; only a command that
   is already turning sleep off when the time runs out is waited for. A
   dialog left on screen after Insomnia crashed or was force-quit does
   nothing when you answer it, once Insomnia has relaunched or the recovery
   agent has run (within a minute). Insomnia shows no dialog at all while
   the `backstop.sh` sealed in its bundle is missing or older than the app
   expects, because an older one cannot void such a dialog: Start then says
   to run `./scripts/install.sh` again. A password typed while the sudoers
   rule is missing turns nothing off either: the start is undone and
   Insomnia says to run the installer again (see How recovery works). If
   the `pending-start` file that guards such a dialog cannot be deleted,
   Insomnia still turns sleep back on, but says so in the menu and a
   notification, keeps the journal entry, refuses new sessions, and retries
   until the file is gone.
2. **Extend:** click the eye or countdown during a session and enter more time.
3. **End early:** press and hold the end control beside the countdown.
4. **Inspect or configure:** right-click for status, recovery warnings,
   **Settings**, and **Quit Insomnia**. Quitting requests session cleanup and
   can be refused while required recovery remains.

You do not need to close the lid to use a timed session. Opening the lid does
not end it, and a sleeping display is not the same as a sleeping Mac.

Before the first session, review the settings. Some lid actions are on by
default, including pausing the apps on the freeze list (Slack, WhatsApp and
Discord) while the lid is closed; pausing every other Dock app is off until
you turn it on. Start with a short, supervised session on a ventilated surface
and check the status menu and `~/Library/Logs/Insomnia/insomnia.log` afterward.

## What happens when the lid closes

<p align="center">
  <img src="docs/assets/lid-actions.svg" alt="Illustrated Settings defaults: Slack, WhatsApp, and Discord on the freeze list, Docker's idle rule off, mute on. During a session, lid close applies configured actions; reopening attempts to resume verified owned freezes and restore saved audio. The session continues. Without an active session, lid changes do nothing." width="880">
</p>

During a session, Insomnia turns the display and keyboard backlight off
(saving their brightness first), pauses the apps on the freeze list (and, if
you opt in, every other Dock app that is not an agent app), checks whether
Docker Desktop is idle before pausing it, and saves then mutes audio.
Reopening the lid attempts to undo those lid actions. If the lid opens
while Insomnia is still checking Docker, Docker is left running and the undo
starts right away. **The timer keeps counting down while the lid is
closed**; only its on-screen redraw pauses, also for a session started with
the lid already closed.

The display step exists because the sleep guard stops macOS from doing it:
with sleep disabled, closing the lid no longer turns the panel or the keys off
by itself. Insomnia sets both to zero and restores them when the lid opens.
The display comes back to the brightness sampled while the lid was open, not
the reading at the moment of closing (auto-brightness has already dimmed the
panel under the closing lid by then, and Low Power Mode rescales it), and if
Insomnia's own Low Power Mode was on while the lid was closed the value is
written once more when the mode ends. If Insomnia is not running when you open
the lid, press the brightness-up key.

The defaults are worth knowing:

- **Selected apps:** Slack, WhatsApp, and Discord are on the freeze list.
  Configured agent apps are excluded from this ordinary list.
- **Every other app:** "Freeze every other app while the lid is closed" is
  off, so a fresh install pauses the freeze list only. Turn it on to also pause
  every Dock app that is not an agent app, an Apple app, Docker Desktop or a
  built-in protected app (editors, terminals, browsers, AI apps, password
  managers, local databases, Tailscale, local model servers; JetBrains IDEs by
  bundle-id prefix), so only agents keep running with the lid shut. Menu-bar
  apps are never picked up automatically; add them to the freeze list if you
  want them paused. Settings shows a "Would freeze now" line listing what the
  automatic scope would pause at that moment.
- **Meeting, recording and dictation apps:** never frozen by "Freeze every
  other app", with their helper apps: Zoom, Microsoft Teams (new and classic),
  Webex (and the older Webex Meetings app), FaceTime, Wispr Flow, Granola,
  Otter, OBS and Loom. Freezing one ends the call, the recording or the
  meeting notes when the lid closes. Putting one on the freeze list by hand
  still freezes it, except FaceTime, which is an Apple app.
- **Docker rule:** off. Turn it on to pause Docker Desktop on lid close when
  no container is running. The local Desktop socket is asked once to pick
  Docker up and once more right before the pause; a busy answer, a failed
  `docker ps` or a timeout at either point leaves Docker running. A container
  that starts between the second check and the pause is still paused with
  Desktop, so leave the rule off for Docker workloads an unexpected pause
  would hurt.
- **Mute on close:** on, so sound stops when the lid closes. Lid open
  restores each output that was muted, even if another one is in use by then.
  An output that is not connected stays muted until it reconnects: Insomnia
  restores it then if it is running, or at the next launch. Ending or
  quitting a session does not wait for it. The end notification and the menu
  name it, and the menu's "Stop waiting for <device>" leaves it as it is. A
  restore that fails on a connected output is retried by Insomnia while it
  runs, and at the next launch.
- **Microphone:** on Mac laptops with Apple silicon or a T2 chip, closing the
  lid disconnects the built-in microphone in hardware. Recording a meeting
  with the lid closed needs AirPods or an external mic; Settings says the same
  next to the lid-close options.
- **Display and keyboard backlight:** on ("Turn off the display and keyboard
  backlight" in Settings). Both values are saved to the journal before they
  are changed.
- **Low Power Mode while the lid is closed:** on. With sleep disabled a closed
  Mac otherwise keeps running at full speed; the mode is switched off again
  when the lid opens, unless a battery or thermal rule still wants it.
- **Battery rules:** below 40% on battery, request Low Power Mode; below 10%,
  end the session. A battery that is present but cannot be read on two
  consecutive reads while on battery also ends the session, with a
  notification saying why: the floor cannot be applied to a level nobody can
  read. One failed read is tolerated, and the level is re-read every 30 s
  until it is readable again. A desktop has no battery and no floor. Serious
  thermal state requests Low Power Mode; critical thermal state ends the
  session. These rules require the app to be running.
  Setting the end floor to 0 turns the battery end off. Otherwise the end
  floor stays below the Low Power Mode floor. The Settings steppers move the
  other floor when the two would cross, and a hand-edited `config.json` with
  the floors out of order is corrected at launch, and logged, by raising the
  Low Power Mode floor.

Upgrading from an earlier build changes two of these once. On the first
launch of this version, a config.json saved by an earlier build gets "Freeze
every other app" turned off and "Mute audio on lid close" turned on, and
Insomnia posts a notification naming what changed. Settings shows the same
line at the top of Lid-close actions until you dismiss it, for anyone with
notifications off. The toggles are right below it. config.json records that
the update ran (`lidCloseDefaultsApplied`), so a setting you turn back stays
the way you set it. A fresh install starts with the new defaults and no
notice.

To exercise the lid actions without closing the lid, run
`scripts/simulate-lid.sh closed` and then `scripts/simulate-lid.sh open` during
a session; the app runs the same actions it would on a real lid event. Only a
build with the file watcher compiled in reads that trigger: a debug build, or
a release build installed with `INSOMNIA_LID_SIMULATION=1 ./scripts/install.sh`.
A normal install has no watcher, so no program running as your user can replay
the lid actions by writing a file. A build that has it logs "Lid simulation
build" at launch and shows the same line in the status menu and in Settings.

## How recovery works

<p align="center">
  <img src="docs/assets/recovery-flow.svg" alt="The app and a launchd backstop coordinate through a shared lock and recovery journal. The app handles normal cleanup. The backstop checks every minute and attempts due recovery, leaving valid active sessions alone. Failed or unreadable recovery evidence stays on disk; saved audio needs the app and unconfirmed stopped processes need inspection." width="880">
</p>

Insomnia records pending changes in a recovery journal. On session end, the app
attempts to undo them. An independent `launchd` agent checks every minute and
can attempt recovery after the app exits unexpectedly, once the saved deadline
has passed. It leaves a valid, unexpired session alone.

Undoing never needs a password: the sudoers rule covers turning sleep back on,
so the app, the agent, and the uninstaller can all restore sleep unattended.
Turning sleep off is the only step that asks, and only when you press Enter.
After you type the password, and before it turns sleep off, the command
behind the dialog checks that turning sleep back on still needs no password
by doing it: as root it switches to your account and runs
`sudo -k -n /usr/bin/pmset -a disablesleep 0`, the command the session's end
runs. `-k` makes sudo ignore a password you typed into it recently and `-n`
makes it fail instead of asking, so only the sudoers rule lets the command
through. If `/etc/sudoers.d/insomnia` is gone or not in effect, sleep is not
turned off, the start is undone, and Insomnia tells you to run
`scripts/install.sh` again. You find this out only after typing the
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
was treated as ended. The app says where it went. If the rename fails, the
app keeps trying it and will not quit until the file is gone.
`uninstall.sh --purge` removes the renamed copies that are regular files;
without `--purge` they stay.

**Recovery is not “everything always gets undone.”** The backstop does not
monitor battery or temperature. Saved audio needs the app to reopen, and
unconfirmed process freezes may need manual inspection. If a warning remains,
resolve it before leaving the Mac unattended. Real-machine crash, reboot, and
installation scenarios still need [release validation](docs/release-validation.md).

<details>
<summary><strong>Recovery limits and manual attention</strong></summary>

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
  30 s while the session lasts. The password dialog is different: it is
  never killed either, but a dialog whose start was voided can no longer
  change anything, so that start rolls back at once and the menu names the
  dialog until it exits.
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
  turn sleep back on. That check is a read at Start: pmset cannot change
  the setting only if it still holds a given value, so a `SleepDisabled 1`
  another tool sets after Start has read `pmset -g` is not seen. Ending the
  session sets it to 0 whoever set it, and if the tool sets it while the
  password dialog is up, the check behind the dialog sets it to 0 for a
  moment before Insomnia sets 1.
- **Low Power Mode:** Insomnia checks the existing setting so it does not
  claim ownership of an already-enabled preference.
- **App Nap:** off by default. When the setting is on, Insomnia journals each
  agent app's previous `NSAppSleepDisabled` value before writing it and puts
  it back at session end, in the backstop, and in uninstall. Values an older
  build wrote without a record are not guessed at: uninstall prints the
  `defaults delete` command for each one and continues.
- **Uninstall:** refuses to remove recovery machinery while unresolved changes
  remain. A failed uninstall is not confirmation that power settings are normal.

</details>

## Optional extras

<details>
<summary><strong>iPhone hotspot handoff and tmux</strong></summary>

Set **System Settings → Wi-Fi → Ask to join hotspots → Automatically**, then
enter the hotspot SSID and password in Insomnia Settings. The password is
stored in the login Keychain under service `insomnia-hotspot`. Insomnia uses
CoreWLAN to find and join that network without putting the password in process
arguments.

The Keychain item's access list names only the build of Insomnia that saved
it, and Insomnia reads it with Keychain prompts switched off, so a join during
an outage never raises a dialog. The installer signs each build ad hoc, which
gives every install a new identity: after a reinstall the saved password is
unreadable by the new build. Insomnia then skips the join, shows "Hotspot
password unreadable by this build" in the right-click menu and in Settings,
and sends one notification per outage. The warning belongs to the SSID it was
read for. Change the SSID and it goes, and Settings checks the new SSID's
saved password instead. Enter the password again in Settings and save; the
save writes the new password before it removes the old item,
and macOS may ask you to allow Insomnia to delete the old one, or to unlock
the login keychain. If that save is cut off after the old item is gone,
the password reads as missing and you enter it once more: Insomnia never
reads a half-finished save's copy. The Save button reads "Saving…" until
macOS answers, and "Saved" only while the SSID and password fields still
hold what was saved. A join that was waiting while you changed the SSID is
dropped, and the next retry uses the new SSID. A Settings read that was
waiting is dropped too, and Settings reads the new SSID's password instead.
Anything you type in the password field while Settings is still loading the
saved one stays, even if you delete it again. The rest of Insomnia,
including the battery floor and End, keeps running while the dialog is open.
A build signed with a stable identity would keep the item readable across
upgrades.

macOS requires Location Services permission to reveal network names. Insomnia
requests it on the first hotspot save, or when starting a session with a
configured hotspot—not merely on launch. If denied, use the Location row in
Settings to open **Privacy & Security → Location Services**. Mac apps have no
when-in-use grant, so System Settings records it as Location Services access
for Insomnia. Insomnia uses it only to read Wi-Fi network names through
CoreWLAN and never requests your location.

After a long outage (90 seconds by default) Insomnia types `continue` into
each configured tmux target. The default target list is empty, and a listed
pane is only nudged if you have marked it yourself, with a pane option that
is read again before every send:

```bash
tmux set-option -p -t <session:window.pane> @insomnia-nudge on
```

Mark a dedicated, disposable agent pane, not one you type in, because pending
text is opaque to Insomnia. Enter is off by default, so the word is typed and
nothing submits it. Turn on "Press Enter after continue" in Settings to submit
it, knowing that Enter also submits anything already typed in that pane. The
option must be on the pane itself (`-p`). One set on the session or window
does not count. Pane options need tmux 3.0 or later. Ending a session cancels
pending automation but cannot retract keystrokes already sent.

</details>

<details>
<summary><strong>Chrome, Chromium, and Arc throttling</strong></summary>

Chromium browsers can throttle windows macOS considers occluded, including
when the lid is closed. Insomnia detects supported running browsers missing
`--disable-backgrounding-occluded-windows` or `--disable-renderer-backgrounding`
and offers **Relaunch [browser] unthrottled** in the right-click menu. The item
asks first, because the browser is quit and its windows and tabs come back only
if it is set to reopen them on startup. If the browser has quit by the time you
confirm, nothing is quit or launched and a notification says so. Insomnia reads the browser's profile
arguments before quitting and carries them over. If it cannot read them, cannot
read the kernel's start time that ties them to the browser, or the browser
quits on its own while they are read, it quits nothing and says so. If the
browser has not quit after 10 s, nothing is launched, and a notification says
so: a second copy beside the first would be worse than a throttled one. The
quit request stands, so a browser that closes later has to be opened again by
hand. After `open` returns, Insomnia waits up to 5 s for the browser to show up
as running and notifies if it does not. Each of these reasons also stays in the
right-click menu as a warning line, one per browser, until that browser's next
relaunch or the next session, so it is there even with notifications off. A
relaunch that ends after its session ended, or after a newer relaunch of the
same browser started, reports nothing. This is not a guarantee that every web
app will keep working while the lid is closed.

</details>

<details>
<summary><strong>Configuration and privacy</strong></summary>

Configuration lives in `~/Library/Application Support/Insomnia/config.json`.
Use Settings for the app's controls; [Config.swift](Sources/Insomnia/Model/Config.swift)
defines the full configuration and defaults. Local logs can contain SSIDs,
process metadata, and tmux targets. Check them before sharing publicly.
Lines the app writes to `insomnia.log` also go to the unified log with their
bodies marked private, so `log show` and other local programs see `<private>`
in place of the text unless private data logging is enabled on the Mac. The
backstop's lines go only to `insomnia.log`, which keeps the full text of both.
The files in Application Support/Insomnia and Logs/Insomnia (config, session,
journal, recovery lock, the record of a power command left running, the two
logs) are owner-only, mode 0600 with those two directories 0700, and one left
looser by an older build is tightened the next time the app or the backstop
opens it. Insomnia sets only these modes and
leaves any access control list (ACL) on these files and folders as it is, so
an ACL someone added, or one inherited from a parent folder, can still give
another account access (`ls -le` shows it). The LaunchAgent plist and the installed
scripts hold no private data and keep the modes the installer gives them.
`insomnia.log` and `handoffs.log` are capped at 1 MiB: a
log past the cap is renamed to `insomnia.log.1` or `handoffs.log.1`,
replacing the previous copy, and a new file starts. The cap does not apply
to a log you replace with a symlink. Insomnia writes through the link and
never rotates it, since the rename would move the link and not the file it
points to, and it logs that once. You set up the link, so trimming the file
it points to is up to you.

`INSOMNIA_HOME` relocates app support files, logs, and LaunchAgents for testing.
It is **not an installation sandbox**: installation/removal also involves the
app bundle and sudoers rule. The installer refuses a relocated home. See
[Paths.swift](Sources/Insomnia/Store/Paths.swift) for the layout.

</details>

## Uninstall

From your checkout:

```bash
./scripts/uninstall.sh
# Also remove Insomnia-owned configuration and logs:
./scripts/uninstall.sh --purge
```

From the unpacked release zip, run `./uninstall.sh` (or `./uninstall.sh
--purge`) in the `Insomnia-<version>-macos` folder. A checkout's uninstaller
(in `scripts`, with `Package.swift` one level up) runs the `backstop.sh`
beside it. Anywhere else, such as the zip's folder, the uninstaller runs only
the copy sealed in the installed app, after `codesign --verify --strict`
passes on the app, and stops without removing anything when there is none.
The zip has no `backstop.sh`, so one added beside its uninstaller is not run.
Neither looks in the folder above its own.

The uninstaller requests cleanup before removing the app, agent, and sudoers
rule. If recovery is incomplete or the app refuses to quit, it stops; resolve
the reported problem and retry. With the app it removes what an interrupted
install left beside it: `~/Applications/.Insomnia.app.previous`, and
`.Insomnia.app.staging.*` directories of installs that are no longer running.
Nothing else in `~/Applications` is touched. Purge removes owned files, not arbitrary
directory contents. A small shared lock file is retained to keep concurrent
recovery operations coordinated.

## Development

```bash
swift build
swift test
```

CI runs Swift tests, a release build with warnings as errors, a bash 3.2
syntax check of the scripts, ShellCheck, and actionlint plus zizmor over the
workflows. tmux integration tests need tmux installed; check skip counts
rather than assuming missing integration coverage passed. Tests use injected
dependencies and temporary fixtures—not live installation or power changes
on a contributor's machine.

The app icon is the menu bar's open eye on a charcoal tile: [AppIconArtwork](Sources/Insomnia/UI/AppIconArtwork.swift) draws it from the same [vector geometry](Sources/Insomnia/UI/EyeMarkGeometry.swift) as the menu bar's closed eye, which opens while a session runs.
After changing the artwork, run `./scripts/generate-app-icon.sh` to regenerate
the packaged PNG and ICNS assets and the README's SVG. The script draws them
offline with Xcode's swiftc and iconutil.

[Contributing](CONTRIBUTING.md) · [Security reporting](SECURITY.md) ·
[Release validation](docs/release-validation.md) · [Design notes](docs/spec.md)

## License

[MIT](LICENSE)
