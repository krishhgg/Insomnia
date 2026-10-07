# Release validation

This record separates automated evidence from real-machine safety validation.
It is not a certification that unattended or lid-closed use is safe.

## September 14, 2026 baseline

The pre-fix audit found lifecycle races, incomplete recovery reporting,
uninstall recovery loss, Docker daemon-selection ambiguity, and tmux work
continuing after session end. The main-branch baseline passed 178 Swift tests;
the separate icon PR added one packaging test. Seven audit-only failure-path
tests reproduced bugs despite that green baseline. A historical secret scan
reported no detected secrets across 175 locally available commits.

## Remediation evidence

- [CI PR #2](https://github.com/kgarg2468/Insomnia/pull/2), commit
  `f20a860`: hosted macOS tests/release build, ShellCheck, and Greptile check
  succeeded. No unresolved review threads were present at verification.
- [Automation PR #3](https://github.com/kgarg2468/Insomnia/pull/3), commit
  `52a3b29`: after addressing three Greptile findings and a timeout-reporting
  defect, an independent snapshot passed 206 tests, release compilation, and
  ShellCheck. The three review threads are resolved. Follow-up `ba82712`
  installs tmux on the hosted runner: CI now executes the pane tests instead
  of skipping them. Hosted CI reports 206 tests with one animation-dependent
  UI test skipped, zero failures, and a successful release build and ShellCheck.
  The Greptile check also passed. These tests include
  private tmux-server tests and a fake Docker executable against a temporary
  Unix socket. Removing cancellation and endpoint guards caused regression
  tests to fail. Additional cases cover cancelling a queued command before
  launch, retaining the checked tmux pane across an active-pane change, and
  stopping during a suspended hotspot join. This is not a live Docker-freeze
  or hotspot validation.
- Recovery/lifecycle remediation before PR review: an independent snapshot of the source,
  test, and script tree passed 315 tests with zero failures, zero skips, and no
  compiler warnings. Release compilation and ShellCheck passed. A redacted
  source secret scan detected no findings. Tests exercise injected power/audio
  failures, lifecycle races, process identity, launchd sequencing, and temporary
  recovery/install/uninstall fixtures; they do not mutate live power settings or
  install/remove the working app. Hosted CI and automated review must also be
  checked on the resulting PR's latest head.
- PR #4 review reproduced two further failure paths: unconfirmed process
  ownership after a failed journal save, and installer loss of the previous
  recovery agent. Follow-up tests cover provisional non-resumable freeze
  entries, preserving the trusted plist on bootstrap failure, and holding the
  shared recovery lock throughout installer recovery and agent replacement.
  The hosted lock-test fixture now uses an explicit release signal instead of
  assuming its simulated command stays alive for a fixed number of seconds.
  Independent verification of the combined follow-up source/tests/scripts
  passed 329 tests with zero failures, zero skips, and no compiler warnings;
  release compilation and ShellCheck also passed. Hosted checks remain a
  separate gate on the PR's latest commit.

Check each PR's latest commit and check results; this record does not make an
earlier green run evidence for subsequent changes.

## September 16, 2026 lid-close audit

During an active session on the development MacBook the user closed the lid
and the panel stayed lit with the keyboard backlight on. The log shows the
session starting at 00:48:12, the lid closing at 00:48:19 and opening at
00:48:25, with Insomnia's lid-close transaction running and freezing Slack
(6 pids) only. `pmset -g log` has no "Display is turned off" event in that
window; the next display-off is the 2-minute idle timer at 01:08:51. Root
cause: `pmset -a disablesleep 1` (the sleep guard) removes the only path by
which macOS turns the built-in panel and keyboard backlight off on clamshell
close (the system-sleep path), and spec section 4 claimed both were "already
off by hardware", so `LidActions` never touched them. Primitives measured on
that machine, without root, and now used by `DisplayPower.swift`:
`DisplayServicesGetBrightness` / `SetBrightness` / `CanChangeBrightness`
(present, rc 0, immediate; `GetBrightness` can return a dimmed value during
the "delayDisplayOff" phase); display sleep via `IORequestIdle` on
`IODisplayWrangler` (honoured only without `PreventUserIdleDisplaySleep`
assertions and deferred ~30 s after a wake, so best effort); wake via
`IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` within ~1 s; and
`KeyboardBrightnessClient` (`copyKeyboardBacklightIDs`, `isKeyboardBuiltIn:`,
`brightnessForKeyboard:`, `setBrightness:forKeyboard:`; one built-in id).
Display brightness 0 does not switch the keyboard backlight off. The
computer-use agent declares `UserIsActive` and `PreventUserIdleDisplaySleep`
every ~40 s, so the design does not fight it: brightness 0 keeps the panel
dark either way. No sudoers or install change was needed. The fix is covered
by unit tests with fakes only; the rows below stay "Not run" until exercised
on hardware.

A simulated run of that fix on the same machine, later on September 16, 2026
(`scripts/simulate-lid.sh` during a session, lid open), found a defect in
what was saved. The close happened after the panel had idle-dimmed and slept:
`DisplayServicesGetBrightness` returned the idle-dim value (0.0625, user value
0.5), and with the display asleep the keyboard backlight was suppressed
(`isBacklightSuppressedOnKeyboard:` true), so `brightnessForKeyboard:`
returned 0; the journal held 0.0625 and 0, and the open restored a dim panel
and a dead backlight. Also measured: powerd keeps its own "pre-dim"
brightness and re-applies it asynchronously on every display wake, so a
restore written right after `IOPMAssertionDeclareUserActivity` can be
overridden a moment later; writes made while the display is asleep never
update that memory; the keyboard idle-dims on its own
(`isBacklightDimmedOnKeyboard:`); and
`CGEventSource.secondsSinceLastEventType(.hidSystemState, kCGAnyInputEventType)`
(public, no permission) gives the idle time, with the idle dim never starting
within 30 s of input. The fix: a reading is trusted only with idle under 30 s
and the device awake/unsuppressed, `BrightnessSampler` keeps the last trusted
reading (every 30 s with the lid open, at start, 3 s after each open), the
close journals the trusted value or the sample, leaves the keyboard alone when
neither exists, and the open re-asserts the restore 2 s after the wake. Unit
tests with fakes only; the hardware rows below are unchanged.

## Hardware validation still required

None of the cases below is certified by the automated regression suite. Record
the tested commit, hardware, macOS version, date, and actual evidence when each
is performed. Do not replace "not run" with "passed" based on source review.

| Scenario | Status |
| --- | --- |
| Normal end, deadline expiry, and repeated Quit restore live power state | Not run for release fixes |
| Force-quit followed by launchd deadline recovery and retry after failure | Not run |
| Unreadable session.json moved aside by the app at launch and by the agent, then uninstall with and without --purge | Not run |
| session.json without read permission during a session: the agent restores sleep within a minute and renames the file to session.json.unreadable-<time>, or the app does both at launch and notifies; after fixing the copy's permissions, a relaunch does not resume the session | Not run |
| Reboot/login with active or dirty journals | Not run |
| Backstop resuming a frozen test process through the installed `Insomnia --resume-frozen`, and keeping the entry when the bundle is removed or its Info.plist lacks `InsomniaResumeFrozenVersion` | Not run |
| Lid-close/open and safe recovery of explicitly selected test processes | Not run |
| Lid-close display/keyboard darkening and restore | Not run |
| Freeze-all scope with agents running (Cursor/T3 Code/Claude untouched) | Not run |
| Freeze-all off on a fresh config.json (list only) and on with a terminal, a non-Chrome browser and a JetBrains IDE open (all untouched) | Not run |
| Real lid close with freeze-all on during a Zoom or Teams call on AirPods, with Wispr Flow or Granola taking notes: none of their processes stopped (`ps -o stat` shows no `T`), the call and the notes continue, other Dock apps frozen, sound muted | Not run |
| Upgrade notice: install over a build whose config.json has `freezeAllApps: true` and `muteOnLidClose: false`; the first launch posts one "Lid-close settings changed" notification and shows the same line in Settings (also with notifications off for Insomnia), both settings change and config.json gets `lidCloseDefaultsApplied: true`; a setting turned back stays back after a relaunch with no second notice; Dismiss removes the line; a fresh install shows no notice | Not run |
| Mute with a changing output: close the lid on AirPods, put them in the case so the speakers take over, open the lid; the speakers keep their volume and mute and the AirPods are unmuted when reconnected. Close the lid again on the speakers while the AirPods are still away: the speakers are muted too, and the next lid open restores them | Not run |
| Output away at session end: close the lid on AirPods, put them in the case, choose End; sleep is restored, the notification and the menu say the AirPods are still muted. Take them out with Insomnia running: their volume comes back and the menu line goes. Again with Quit instead of End, then launch Insomnia with the AirPods connected: restored at launch. "Stop waiting for AirPods" drops the entry and leaves them muted; uninstall stops while one is waiting | Not run |
| Lid close with a freeze-list app stopped beforehand by `kill -STOP` (left stopped on lid open, not in the journal) | Not run |
| Lid close during a session after `chflags uchg` on state.json (mode 0444 is not enough: the app writes a new file and renames it over state.json, and rename needs write access only to the folder): no process stopped, every app logged as left running; `chflags nouchg` before lid open | Not run |
| Simulated lid close/open via scripts/simulate-lid.sh on a build installed with `INSOMNIA_LID_SIMULATION=1 ./scripts/install.sh` (the launch log, status menu and Settings show "Lid simulation build") | Not run |
| A normal install (no `INSOMNIA_LID_SIMULATION`) ignores scripts/simulate-lid.sh during a session: no log line, no lid actions, trigger file left in place; no "Lid simulation build" marker anywhere | Not run |
| Existing Low Power Mode preference and saved audio restoration | Not run |
| App Nap opt-in: previous `NSAppSleepDisabled` put back at session end, by the backstop after a force-quit, and by uninstall | Not run |
| Docker Desktop idle/busy behavior with another Docker context selected | Not run |
| Docker rule off on a fresh config.json (no `docker ps`, Docker untouched) and on with a container started between the two idle checks (Docker untouched, both checks logged with their answers) | Not run |
| Docker rule on, lid opened while an idle check is still running (Docker never paused, the display and frozen apps restored without waiting for `docker ps`, insomnia.log says the lid opened during that check), and a session started with the lid already closed (no countdown redraw until the lid opens) | Not run |
| Hotspot permission, association, cancellation, and reconnect | Not run |
| Hotspot password after a reinstall: menu and Settings report it unreadable, no prompt during an outage, re-save replaces the item (prompt on Save allowed) | Not run |
| Settings location note matches what System Settings shows after the grant | Not run |
| tmux cancellation with a dedicated disposable pane | Not run |
| tmux nudge on the user's own tmux server: marked pane gets `continue` only, Enter toggle submits it, unmarked pane untouched | Not run |
| Headed-browser throttling with the lid closed | Not run |
| Relaunch unthrottled: confirmation alert, profile arguments carried over, a browser that has not quit after 10 s is left as it is and the notification names it, a browser not running 5 s after `open` is reported | Not run |
| Relaunch failure while Insomnia is frontmost: with notifications allowed, the "Browser not relaunched" banner shows without switching apps after the confirmation; with notifications off for Insomnia, the reason is a warning line in the right-click menu | Not run |
| Battery/thermal event behavior on supported hardware | Not run |
| A `sudo pmset` that ignores SIGTERM: left running, lock held, journal intact, quit refused until it exits | Not run |
| The same command with the app force-quit: the backstop does not take the lock until the command exits; the relaunch names the pid from `unfinished-command.json`, and at its next retry after the command exits (retries start 30 s after each refusal) resumes the session with its battery floors | Not run |
| A left-running `disablesleep 0` that exits 0: the end finishes without running it again | Not run |
| After that command exits: Low Power Mode ownership matches the mode, and a lid open made meanwhile is undone | Not run |
| `SleepDisabled 1` set by hand with no session: left alone and reported at launch, not cleared | Not run |
| Unreadable battery (IOKit miss) ends the session on a laptop after the second read; desktop unaffected | Not run |
| Settings floor steppers keep the end floor below the Low Power Mode floor by moving the other stepper | Not run |
| Install/upgrade/uninstall with recoverable failure conditions | Not run |
| Start shows the administrator password dialog (names Insomnia's purpose, not just osascript) and `pmset -g` shows `SleepDisabled 1` after it | Not run |
| Cancel in the dialog rolls the start back with no pmset: no session, journal clean, `SleepDisabled` still absent, "Session not started" notification saying nothing was changed | Not run |
| With `SleepDisabled 1` set by hand (`sudo pmset -a disablesleep 1`), Start shows no dialog, `pmset -g` still shows `SleepDisabled 1`, no session.json, and the message gives `sudo pmset -a disablesleep 0`; after that command Start shows the dialog | Not run |
| A wrong password and no answer for 120 s each roll the start back through `disablesleep 0`: no session, `SleepDisabled` absent, journal clean, "Session not started" notification; the dialog closes when the 120 s SIGTERM lands | Not run |
| Relaunch (and login) with a valid session and `SleepDisabled 1` keeps the session without a prompt | Not run |
| Relaunch with a valid session after `sudo pmset -a disablesleep 0` by hand ends the session with the "turned back on" notification, no prompt | Not run |
| Reinstall over an older four-line `/etc/sudoers.d/insomnia` leaves exactly the three passwordless lines | Not run |
| A dialog whose osascript has not exited 3 s after the 120 s SIGTERM is reported with its pid (notification and menu warning line) and nothing is killed; the start rolls back at once (no session, `SleepDisabled` absent, a new Start shows a new dialog), the menu line names the pid until osascript exits and goes once it has | Not run |
| A one-minute session whose password is entered after 70 s: the dialog's command reports the session has already ended, `pmset -g` shows no `SleepDisabled 1`, "Session not started" | Not run |
| With `/etc/sudoers.d/insomnia` moved aside by hand (`sudo mv`), Start shows the password dialog; after the password `pmset -g` shows no `SleepDisabled 1`, there is no session.json, the journal is clean, and the message names `sudo -k -n /usr/bin/pmset -a disablesleep 0` and says to run `scripts/install.sh` again; after the rerun Start turns sleep off | Not run |
| The same with the rule moved aside, another passwordless sudoers entry of your own in place (so `sudo -n -l /usr/bin/pmset -a disablesleep 0` exits 0) and a `sudo -v` in Terminal just before: after the password Start still turns nothing off and names `sudo -k -n /usr/bin/pmset -a disablesleep 0` | Not run |
| With the rule in place, `log show --last 5m --predicate 'process == "sudo"'` after a Start shows no sudo from Insomnia before the dialog, then root running `/usr/bin/sudo -k -n /usr/bin/pmset -a disablesleep 0` as your user and that restore running, before `pmset -g` shows `SleepDisabled 1` | Not run |
| `sudo pmset -a disablesleep 1` run in Terminal while a Start's dialog is up: after the password the session starts and `pmset -g` shows `SleepDisabled 1`; ending the session sets it to 0 (the documented limit: pmset has no compare-and-set) | Not run |
| `scripts/install.sh` prints that `sudo -k -n -l` lists the three commands and runs no `pmset` command of its own: `pmset -g` before and after shows the same `SleepDisabled` value, also when it is set by hand | Not run |
| An upgrade from a build before this change (four-line rule, `backstop.sh` in Application Support) leaves exactly the three passwordless lines, removes the old `backstop.sh`, and the first Start shows the dialog | Not run |
| An upgrade over a build whose Info.plist has no `InsomniaResumeFrozenVersion`, with a lid-frozen test process in the journal: the new build's staged binary resumes it before the bundle swap (`ps -o stat` shows no `T`), the old app does not open, and the install finishes. Again with a browser-downloaded (quarantined) prebuilt bundle: the process is resumed the same way, or, if macOS blocks the staged binary, the entry stays, the install stops before the swap and the previous app and agent stay | Not run |
| Force-quit Insomnia while its password dialog is up, then relaunch it (or wait a minute for the agent), then enter the password in the old dialog: `pending-start` is gone, the dialog's command reports the start is over, and `pmset -g` shows no `SleepDisabled 1` | Not run |
| `chflags uchg` on `pending-start` while a password dialog is up, then force-quit and relaunch: sleep restored, "Restore incomplete" names the file, the journal keeps `sleepDisabledByUs`, Start is refused; after `chflags nouchg` the next agent run or relaunch deletes the file and clears the entry | Not run |
| An upgrade whose running app refuses to quit stops after the password prompt and before the rule, and leaves `/etc/sudoers.d/insomnia` byte for byte as it was | Not run |
| An upgrade stopped after the installer quit the app and before the rule (open the app again while the installer waits for the recovery lock, for example while a password dialog of a Start holds it) leaves `/etc/sudoers.d/insomnia` byte for byte as it was and keeps the old bundle, so the old build still starts sessions; the rerun finishes the install | Not run |
| With a session running, the installer prints "A session is running and the upgrade will end it." before the password prompt; answering anything but y at "Continue?" in a terminal stops it with no password prompt, the app running and the session counting down | Not run |
| Cancelling the installer's password prompt during a session leaves the app running and the session counting down; `/etc/sudoers.d/insomnia`, the bundle and the LaunchAgent are unchanged | Not run |
| Recovery agent refuses to run after the installed bundle or its sealed backstop.sh is modified, and logs why | Not run |
| Running app refuses to arm (session start refused, reason shown) after its installed bundle is edited or re-signed under it | Not run |
| Upgrade whose new agent fails to load puts the previous bundle back and reloads the previous agent, on a working Mac | Not run |
| Upgrade whose new agent plist cannot be saved, and a rerun after an install killed mid-swap, leave the app and the agent's plist matching, on a working Mac | Not run |
| Upgrade whose bundle rename is refused (the new build cannot be moved in, or the previous app cannot be moved back) puts the previous app back and reloads its agent, or keeps both bundles and prints the commands, on a working Mac | Not run |
| Install whose `sudo -k -n -l` check or `launchctl` call stalls while it holds the recovery lock (for example a directory-service lookup that does not answer) stops after 30 s and releases the lock, and the agent's next run can take it, on a working Mac | Not run |
| Install from a release zip with `install.sh --allow-unverified-origin --app` on a working Mac, first launch of the downloaded app | Not run |
| Installed bundle from a release zip has no group or other write bit and no ACL (`ls -leR ~/Applications/Insomnia.app`), keeps its quarantine flag (`xattr -p com.apple.quarantine`) and passes `codesign --verify --strict --deep`, on a working Mac | Not run |
| `uninstall.sh` run from a release zip unpacked in `/tmp` runs the installed app's sealed `backstop.sh` after `codesign --verify`, on a working Mac | Not run |
| `install.sh` and `uninstall.sh` from a release zip unpacked in `/tmp`, with a `build-app.sh` and a `backstop.sh` added to the unpacked folder, run neither (install without `--app` stops, uninstall runs the sealed copy), on a working Mac | Not run |
| `install.sh --app` from a release zip stops with the Apple Silicon message on an Intel Mac, and installs on an Apple Silicon Mac from a Terminal running under Rosetta | Not run |
| Release workflow end to end: tag push, tests, package, attestation, GitHub Release, `gh attestation verify` of the download | Not run |
| Install or uninstall whose own process is killed (`kill -9 <pid>`) during a `launchctl bootout` keeps the recovery lock until that bootout has ended or been stopped, about 33 s at most, and the app started afterwards keeps its agent loaded, on a working Mac | Not run |
| First launch over an existing install tightens Application Support/Insomnia and Logs/Insomnia to 0700 and their files to 0600 | Not run |
| Launch at login survives a reinstall by install.sh, including a second install.sh run on the same unchanged build (switch on, reinstall, relaunch: the log shows the launch-time check, System Settings > General > Login Items lists Insomnia as enabled, and the Settings switch reads on; a pending approval shows the note and the Open Login Items button) | Not run |
| Launch at login heals on the first upgrade from a build without the install record (switch on in the previous build, upgrade with install.sh, relaunch: the log shows "registering once and recording the install", Login Items lists Insomnia, and config.json has `launchAtLoginInstall`) | Not run |
| Launch at login removed in System Settings stays removed (switch on, relaunch once so the install is on file, remove Insomnia under System Settings > General > Login Items, relaunch: the log says the removal was respected, the Settings switch is off, and Login Items does not list Insomnia again) | Not run |
| Pending approval withdrawn from Settings (switch on while macOS reports it waiting for approval, turn the switch off: Login Items no longer lists Insomnia and the next launch does not register it) | Not run |
| Approval given in System Settings shows in an open Settings window (turn the switch on, approve under Login Items, click back into the Settings window: the pending note goes away without reopening the window) | Not run |

Hardware tests must be supervised and must not endanger active user work. Use
a stable, ventilated surface, not an enclosure. Do not intentionally overheat a
machine to validate thermal handling; exercise injected thermal events first.

Launchd sequencing tests use a fake command runner. Actual bootstrap of the
private candidate plist, login loading, and crash recovery must still be
checked on the supported macOS release. PackagingTests run the agent's
verify-then-exec command line against a scratch ad-hoc bundle with the real
codesign: an intact bundle runs its sealed script, and an edited script or
another build's requirement is refused and logged. Whether launchd runs that
command line as installed, and whether the installed app's plist is the one
install.sh wrote, has not been checked on a working Mac. Installer tests
redirect every app, LaunchAgent, sudoers, and command target into a temporary
fixture. Real build, signing, privileged installation, and quit refusal by a
running app have not been exercised as an end-to-end installation on a
working Mac.

## Distribution boundary

Packaging is automated: `scripts/build-app.sh` makes the bundle, and the
Release workflow tests, packages, checksums, attests and publishes it for a
`v*` tag (`docs/releasing.md`). PackagingTests run a patched copy of
`build-app.sh` with the real codesign, RecoveryScriptTests run `install.sh
--app` against prebuilt fixtures, one of them ad-hoc signed by the real
codesign, and ReleaseWorkflowTests check that every action in the workflows
is pinned to a commit and that no job has more than read access except the
one that publishes. No release has been produced with it yet. Releases are
ad-hoc signed and not notarized, published as prereleases. A consumer
installation and recovery walkthrough from a downloaded zip has not
been done. Open-source availability and a passing PR are not equivalent to
readiness for a public binary release.
