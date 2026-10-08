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

Measured on October 1, 2026 on the same machine (macOS 26.2, 25C56, arm64),
read-only through the Objective-C runtime, the `KeyboardBrightnessClient`
instance method type encodings: `copyKeyboardBacklightIDs` `@16@0:8`,
`isKeyboardBuiltIn:` `B24@0:8Q16`, `brightnessForKeyboard:` `f24@0:8Q16`,
`setBrightness:forKeyboard:` `B28@0:8f16Q20`,
`isBacklightSuppressedOnKeyboard:` `B24@0:8Q16`,
`isBacklightDimmedOnKeyboard:` `B24@0:8Q16`. `DisplayPower.swift` now
refuses the DisplayServices calls on any macOS major other than 26, and the
keyboard class when a required method is missing or an encoding (offsets
removed) differs from these; on an Intel Mac `BOOL` encodes as `c`, so the
keyboard backlight is refused there until measured. A refused device is
skipped at lid close, journals nothing, and is named in Settings; with
both devices refused the close does not request display sleep, since the
open wakes the display only for a journaled brightness. A value
journaled before an update that the guard now refuses stays journaled,
flagged as refused so it no longer counts as dirty, with an error that
names each saved level and says to set it by hand; backstop.sh and
uninstall.sh read the flag. A later build that can make the call writes
the kept value only while the device still reads 0, the level the close
left, so a level set by hand since is not overwritten. It decides only
on a reading taken with the lid known to be open, the display awake and
the keyboard backlight neither suppressed nor dimmed, keeps the entry
when the read fails, and reads again every 3 s for a minute, then every
minute while the entry waits, reading nothing while the lid is not known
to be open. An entry found set since, or written, that state.json cannot
clear is not read or written again, and only its clear is retried; the
clear goes into the journal ahead of any later write, so a lid close
journals the level the device reads. When the write fails and state.json
cannot take the cleared flag either, backstop.sh would pass over the
entry, so Insomnia retries it in process and holds Quit until the write
lands or the flag is on disk. The sampler takes no reading of a device
whose brightness is journaled, and each level written from the journal
or found set since becomes its sample, so a close right after a late
restore journals that level. A display reading above 0 under Insomnia's
own Low Power Mode, or after it in the same boot, relaunches included,
decides nothing, and a launch after a restart reads the entry again. A
backstop run whose `lowpowermode 0` exits 0 gives that record its own boot,
so a launch in that boot doubts the reading too. A later reading of 0, in
that run, a relaunch or after a restart, does not bring the kept value back
either (the reading above 0 is journaled), unless the reading above 0 was
taken under a closing lid, of a panel asleep, or of another entry. That 0
is not taken as a level set since either, however late it is read, since
macOS may still hold the panel at a closing lid's 0: the entry stays
flagged until the panel reads above 0. If state.json refuses that record,
Quit waits until it lands. A Low Power Mode claim journaled before a
restart is read before the switch-off, and a mode read off then puts no
doubt on the panel's reading. A close with no trusted level leaves the
entry flagged and the panel lit, and only asks the display to sleep. After
a reading above 0, a close whose only level is a 0 read under the closing
lid leaves the entry flagged too. A write whose clear state.json refuses is still written again 2 s
later and, under the mode, after it. A `lowpowermode 0` that exits 0 while
state.json refuses the ownership clear still does the write owed after
the mode, and the display sample stays the level written after it until
the clear lands; one that exits 0 while state.json cannot be read does
that write once state.json reads again and still owes it. A write after
the mode dropped while state.json refuses that clear stays dropped. Unit
tests with an injected version and
fake classes only; the rows below stay "Not run", and the guards do not
stand in for them.

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
| Darkening still runs under the private-call guards on macOS 26 (close the lid during a session: the log shows "display darkened" and "keyboard backlight off" and no "refused" line; Settings shows no note under the darken toggle) | Not run |
| Darkening refused on an unmeasured macOS version (a macOS major other than 26, or a `KeyboardBrightnessClient` whose methods changed: the log shows the "refused" line once and "skipped" at lid close, nothing is journaled for that device, and Settings names the reason under the darken toggle; with both refused the log shows "display sleep not requested" and the panel is lit when the lid opens; a level saved by the earlier build stays in state.json with `displayRestoreRefused` or `keyboardRestoreRefused` after the first open or launch, the menu says it could not be restored on this macOS build and names each saved level, Settings shows the saved level under the darken toggle, no "Restore incomplete" follows, and the backstop log does not fail for it) | Not run |
| A kept brightness on a build that can make the call (after a refused restore, set the keyboard backlight by hand, put the display to sleep, then launch that build and wake the display): the log shows "not read: macOS has the backlight suppressed or dimmed" and then "set since its restore", and the backlight stays at the level set | Not run |
| A kept keyboard backlight when a session ends with the lid closed, on a build that can make the call: the log shows "the lid is not known to be open, so the kept value is not read", and about a minute or less after the lid opens, with no session, "set since its restore" or "keyboard backlight restored" | Not run |
| A kept brightness at a launch with no session and the lid closed (an external display in clamshell mode, after a refused restore), on a build that can make the call: the log shows "not read: the lid is not known to be open" for each kept device and nothing is written, and once the lid opens "set since its restore" or "restored" | Not run |
| A kept display brightness restored late during a session (launch with the display asleep after a refused restore, wake it, start a session at once, wait for "display restored", then close and open the lid within 30 s): the close logs "display darkened (was brightness" with the restored level, and the open brings the panel back at that level, not black | Not run |
| A kept display brightness under Insomnia's own Low Power Mode, on a build that can make the call (after a refused restore, set the display by hand, start a session on battery below the floor so Insomnia switches the mode on, then open the lid): the log shows "under our low power mode, which rescales it" and nothing is written; once the mode is off, "after our low power mode was on in this run" and nothing is written, and a close logs "stays journaled and undecided, and the display is not darkened" and the panel goes dark only if the display sleep request is honored; after a relaunch with the lid open, "since the Mac last started" and nothing is written; after a restart, "set since its restore" with the level set by hand, and a close and open after that bring back that level | Not run |
| A kept display brightness over a restart with Insomnia's Low Power Mode claimed (as in the row above, quit the app with `kill -9` while the mode is on, restart the Mac, set the display by hand, then launch on battery): the log shows "journaled as ours before the Mac last started, reads on" or "reads off"; with "reads off", "set since its restore" at that launch; with "reads on", nothing is written until the next restart. After an open under the mode read the panel above 0, set the display to 0 by hand, relaunch and then restart: the kept value never comes back over that 0, after the restart the log shows "only a reading above 0 tells them apart" and the entry stays in state.json, and once the display is raised above 0 by hand, "set since its restore" with that level | Not run |
| A kept display brightness when the recovery agent switches Insomnia's Low Power Mode off after a restart (as in the row above, quit with `kill -9` while the mode is on, restart the Mac, and wait for "pmset -b lowpowermode 0 ok" in the backstop log before launching on battery): the backstop log shows "kept display entry's record given this boot" before "pmset -b lowpowermode 0 ok", state.json's `keptDisplayUnderLowPowerBoot` is this boot's `kern.bootsessionuuid`, the launch logs "since the Mac last started" and writes nothing, and after the next restart "set since its restore" | Not run |
| Quit while a reading above 0 of the kept display entry is not yet in state.json (as in the restart row above, `chflags uchg` state.json before the launch after the restart that reads the panel above 0, then Quit): the menu says "do not quit until state.json can be written" and Insomnia keeps running; after `chflags nouchg`, Quit within the next retry quits, and state.json has `keptDisplayReadLit` | Not run |
| The recovery agent when state.json refuses writes over a kept display entry (as in the agent row above, `chflags uchg` state.json in the new boot before the agent runs): the backstop log shows "Low Power Mode left on, keeping journal entry for retry", `pmset -g` still shows lowpowermode 1, and sleep is restored; after `chflags nouchg`, the next run logs "record given this boot" and then "pmset -b lowpowermode 0 ok" | Not run |
| Quit while the clear of a settled kept display brightness is not yet in state.json (after a refused restore, set the display by hand above 0, `chflags uchg` state.json, launch with no session so the log shows "set since its restore", set the display to 0 by hand, then Quit): the notification says "do not quit until state.json can be written", Insomnia keeps running and Start is refused; after `chflags nouchg`, the next retry clears the entry from state.json, Quit quits, and a relaunch leaves the display at 0 | Not run |
| Backstop and uninstall over saved audio of an output device renamed to `Headset \u0041` (a Bluetooth headset renamed in Bluetooth settings, the lid closed on it with muting on, then the app quit with `kill -9` and the session left to expire): the backstop log has no "malformed" and shows "pmset -a disablesleep 0 ok", state.json keeps the headset's entry, and the next launch with the headset connected restores its volume and mute | Not run |
| A kept display brightness read above 0 that a close under the closing lid reads at 0 (as in the row above, after the launch that leaves the entry waiting, keep the display asleep until the session starts, wake it with auto-brightness on, then close the lid in a dark room before the next re-read): the close logs "where auto-brightness under the closing lid may have pulled it down" and "stays journaled and undecided", nothing is written at the close or the open, and while the panel reads 0 the open and every re-read log "only a reading above 0 tells them apart" and the entry stays in state.json; once the panel reads above 0, "set since its restore" with that level, and the kept value is never written | Not run |
| The same entry across a relaunch (as in the row above, quit Insomnia after the close with the lid still closed, open the lid, and relaunch Insomnia while the panel still reads 0): the launch logs "only a reading above 0 tells them apart" while the panel reads 0, nothing is written, and once the panel reads above 0, "set since its restore" with that level | Not run |
| Backstop and uninstall with a hand-edited state.json whose `keptDisplayReadLit` is `1e-400` (a copy of a journal from the restart row above, in a test home): the backstop logs "is unreadable or malformed; nothing undone, evidence kept", uninstall prints "state.json is unreadable or malformed" and removes nothing, and state.json is unchanged | Not run |
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
| Recovery agent refuses to run after the installed bundle or its sealed backstop.sh is modified, and logs why | Not run |
| Running app refuses to arm (session start refused, reason shown) after its installed bundle is edited or re-signed under it | Not run |
| Upgrade whose new agent fails to load puts the previous bundle back and reloads the previous agent, on a working Mac | Not run |
| Upgrade whose new agent plist cannot be saved, and a rerun after an install killed mid-swap, leave the app and the agent's plist matching, on a working Mac | Not run |
| Upgrade whose bundle rename is refused (the new build cannot be moved in, or the previous app cannot be moved back) puts the previous app back and reloads its agent, or keeps both bundles and prints the commands, on a working Mac | Not run |
| Install whose `sudo -n -l` check or `launchctl` call stalls while it holds the recovery lock (for example a directory-service lookup that does not answer) stops after 30 s and releases the lock, and the agent's next run can take it, on a working Mac | Not run |
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
