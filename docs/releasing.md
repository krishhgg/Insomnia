# Releasing

How a downloadable Insomnia build is made, what signs it, and how to verify
one. The Release workflow (`.github/workflows/release.yml`) does the work;
this page is the checklist around it.

## Channels

| | Stable | Nightly |
| --- | --- | --- |
| Made by | pushing a tag `v<version>` | the daily schedule (07:17 UTC), or a manual run with the nightly input, on `main` |
| Tag | `v<version>`, pushed by the maintainer | `nightly-<YYYYMMDD>-<first 12 hex digits of the commit>`, created by the workflow |
| Zip | `Insomnia-<version>-macos.zip` | `Insomnia-<version>-nightly-<YYYYMMDD>-<commit>-macos.zip` |
| Title | `Insomnia <version> (stable)` | `Insomnia nightly <YYYY-MM-DD> (<commit>)` |
| GitHub marks | Latest, not a prerelease | Pre-release, never Latest |
| Attestation source ref | `refs/tags/v<version>` | `refs/heads/main` |

Both channels run the same tests, build, package, checksum and attestation
steps; they differ only in how the run starts, the names and the release
flags. Nobody chooses a nightly: it is whatever `main` held when the run
started.

`v0.1.0` is an exception to this table. It was packaged by hand from the
app installed on the maintainer's Mac and published as the first stable
release; no workflow built it. Its zip is `Insomnia-0.1.0-macos-arm64.zip`
with `scripts/install.sh`, `scripts/uninstall.sh` and `scripts/backstop.sh`
from the `v0.1.0` tag, it has no attestation, and its release notes give its
own checksum and install commands. Version 0.1.0 belongs to that release,
so the next stable release needs a new version in `Resources/Info.plist`.

## What a release contains

`Insomnia-<version>-macos.zip` (or the nightly name above) holds one folder
with `Insomnia.app`, `install.sh` and `uninstall.sh`. `SHA256SUMS` lists the
zip's SHA-256. Both files are attached to the GitHub Release, and the zip
carries a GitHub build provenance attestation that names the repository, the
ref, the commit and the workflow run that produced it.

The binary is arm64 only, because the build job runs on an Apple Silicon
runner and no universal build is made. A release therefore runs on Apple
Silicon Macs only: the release notes and the README say so, and
`install.sh --app` stops on a Mac where `sysctl -n hw.optional.arm64` does not
read 1.

The bundle is the one `scripts/build-app.sh` makes: the release binary,
`Resources/Info.plist`, the icon, and `backstop.sh` sealed under
`Contents/Resources` before signing. `install.sh` runs the same script for
a source install, so a downloaded app and a source-built app have the same
bundle layout and are both ad-hoc signed. Their contents can still differ,
because a source build may use another checkout, toolchain or architecture,
or `INSOMNIA_LID_SIMULATION=1`. The workflow sets `INSOMNIA_LID_SIMULATION`
empty, so a release never carries the `simulate-lid.sh` watcher.

The two scripts sit at the zip's top level, so the folder above theirs is
wherever the user unpacked it. They never take scripts from the folder
above their own (`ReleaseWorkflowTests` checks the ones the Package step
copies), and they take sibling scripts only from a source checkout's
`scripts/` folder with `Package.swift` one level up. The zip's folder is not
one, so its `install.sh` needs `--app`, and its `uninstall.sh` runs only the
`backstop.sh` sealed in the installed app, after verifying the app. A
`build-app.sh` or `backstop.sh` added to the unpacked folder is not run.

## Cutting a stable release

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the new
   version (and bump `CFBundleVersion`). Commit on main. `0.1.0` is taken
   (see Channels).
2. Test that commit before anything is published. Start a manual run on it
   (Actions, Release, Run workflow, with the nightly box left unticked),
   download the zip from the run's artifact, check it with
   `shasum -a 256 -c SHA256SUMS`, and install it with
   `./install.sh --allow-unverified-origin --app ./Insomnia.app` on a Mac you
   can afford to reinstall on. Then run the
   [real-Mac checks](#real-mac-checks-before-a-release), all but the
   release channel ones, and record the results in
   `docs/release-validation.md`. Fix anything that fails and start again
   from step 1.
3. Tag the tested commit `v<version>`, the same digits, and push the tag:

   ```bash
   git tag v0.2.0 <tested commit>
   git push origin v0.2.0
   ```

   The workflow refuses a tag whose digits differ from the plist.
4. Watch the run. It runs `swift test`, builds and ad-hoc signs the bundle,
   packages it, attests the zip and creates the GitHub Release, marked
   Latest, with notes that include the checksum and the verify commands.
   `gh release create` fails if the tag already has a release, so a rerun
   never replaces published assets.
5. Download the zip from the release and check it the way a user would (see
   below), then install it with the command in the release notes on a Mac
   you can afford to reinstall on. This is the stable release channel check;
   record its result with the others.

A manual run (Actions, Release, Run workflow) with the nightly box left
unticked builds and packages the chosen branch and uploads the zip and
`SHA256SUMS` as a workflow artifact. It does not attest or publish anything,
so it is the way to try the pipeline and to get the build that step 2
tests.

## Nightly prereleases

The schedule runs the workflow on `main` once a day. A first job, with
read-only access, lists the repository's `nightly-*` tags and releases:

- If a nightly tag already names the head of `main` and has a release,
  nothing is built. A day without new commits publishes nothing.
- If such a tag exists without a release, the run fails and builds nothing,
  until `main` moves on. That happens only when an earlier run created the
  tag and then failed to create the release: rerun that run's failed jobs
  (the nightly job finds its own tag on the same commit and goes on), or
  delete the tag.
- If a nightly tag with this commit's first 12 hex digits points at another
  commit, the run fails.
- Otherwise it picks the tag `nightly-<today, UTC>-<commit>` and the run
  goes on to test, build and package that commit.

The publishing job creates the tag through the API call that fails when the
ref exists, so it never moves a tag, then creates the release with
`--prerelease --latest=false`. Scheduled and manual runs on `main` share one
concurrency group, so two runs never publish the same commit at once.

To publish a nightly now, start a manual run on `main` with the nightly box
ticked. The same checks apply, and a run on any other branch fails before
it builds.

GitHub disables scheduled workflows in a public repository after 60 days
without repository activity; the Release workflow then has to be enabled
again under Actions. The tags are not protected by a repository rule, so
someone with write access could still move or delete one by hand.

## Signing

Releases on both channels are ad-hoc signed and not notarized.
`build-app.sh` signs with `codesign --sign -`, so the workflow uses no
secrets and no keychain, and the signature identifies only that build (its
cdhash). The stable label is about the channel, not the signature: macOS
blocks the first launch of any downloaded release until the user allows it
in System Settings > Privacy & Security.

## Verifying a download

```bash
shasum -a 256 -c SHA256SUMS
gh attestation verify <zip> -R krishhgg/Insomnia \
  --signer-workflow krishhgg/Insomnia/.github/workflows/release.yml \
  --source-ref <ref> --source-digest <commit>
```

`<ref>` is `refs/tags/v<version>` for a stable release and `refs/heads/main`
for a nightly; `<commit>` is the full commit the release was built from. The
release notes carry the command filled in.

The first line checks the zip against the checksum published with it. The
second asks GitHub for the attestation signed when the workflow ran and
checks that this zip is its subject, that the signing workflow is this
repository's `release.yml` (`--signer-workflow`; with `-R` alone any workflow
of the repository would do), that it ran for that ref (`--source-ref`), so a
nightly built from `main` does not pass for a stable tag, and that it built
that commit (`--source-digest`). Together they show the bytes are what the
Release workflow built from that commit. They do not show the code is safe;
the README's warnings apply to every build. `v0.1.0` has no attestation; only
the checksum in its release notes covers it.

The `install.sh --app` in a workflow-built zip then copies the bundle into
a private temporary directory and checks that copy before the password
prompt: it runs
`codesign --verify --strict --deep` and checks the bundle identifier and
version. It installs that copy, not the path it was given, so a bundle
replaced at that path while the prompt waits is never installed. The copy it
puts in `~/Applications` is checked once more against the requirement the
recovery agent pins.

What is verified: the checksum shows the zip was not altered after
`SHA256SUMS` was written; the attestation shows this repository's Release
workflow built this exact zip from that ref and commit; `install.sh --app`
shows the bundle inside is intact (signature and resource seal), has the
expected identifier and a version, and carries the sealed backstop. What is
not: `install.sh` cannot tell a bundle from this repository apart from one
anyone else signed with the same identifier, and it does not take any
signature, ad-hoc or not, as proof of where a bundle came from. So it
refuses to install without `--allow-unverified-origin`, the flag that says
you ran the two commands above yourself. The release notes carry that flag
in the install command.

## What is not automated

The workflow does not install anything anywhere. The real-Mac checks below
are run by hand after a real install, and their results go in
`docs/release-validation.md`. Nothing checks a nightly beyond the workflow's
`swift test`.

## Real-Mac checks before a release

Run these on a real Mac before each stable release, on a workflow build of
the commit the release will be tagged on (step 2 of
[Cutting a stable release](#cutting-a-stable-release)), and record the
results in `docs/release-validation.md` with the commit, the Mac, the macOS
version and the date. A passing `swift test`, a source review or a green CI
run is not a result.

Two kinds of check are exceptions. A release build leaves out the
`simulate-lid.sh` watcher, so run the simulated lid close/open check on a
source build of the same commit installed with
`INSOMNIA_LID_SIMULATION=1 ./scripts/install.sh`, and record that build
setting with its result. The release channel checks need a published
release, so the stable one runs at step 5, after the tag push, and the
nightly one after a nightly run publishes.

Run them under supervision and never at the cost of active work. Use a
stable, ventilated surface, not an enclosure. Do not overheat a Mac on
purpose to check thermal handling; try injected thermal events first.

`swift test` covers the same paths with fakes. Launchd sequencing uses a
fake command runner. PackagingTests run the agent's verify-then-exec command
line against a scratch ad-hoc bundle with the real codesign: an intact
bundle runs its sealed script, and an edited script or another build's
requirement is refused and logged. Installer tests redirect every app,
LaunchAgent, sudoers and command target into a temporary folder. The checks
below cover what only a real Mac shows.

### Sessions and recovery

- Normal end, deadline expiry, and repeated Quit restore live power state
- `Insomnia --session start 120` from Terminal while the app runs: the menu bar counts the session down and `pmset -g` reads SleepDisabled 1, `--session extend 60` moves the countdown out, and hold-to-end and `--session end` each end the session with SleepDisabled 0; with the app quit, the command prints that Insomnia is not running, and the next launch starts nothing
- Sleep guard read back: on macOS 26.6.2 (25G83), where `pmset -g` reads SleepDisabled 0 again about 2 s after `pmset -a disablesleep 1`, Start fails after about 5 s with "macOS set SleepDisabled back to 0" and no session runs; on a macOS where the bit holds, the session starts about 5 s after Start and `pmset -g` reads SleepDisabled 1
- Force-quit followed by launchd deadline recovery and retry after failure
- Unreadable session.json moved aside by the app at launch and by the agent, then uninstall with and without --purge
- session.json without read permission during a session: the agent restores sleep within a minute and renames the file to `session.json.unreadable-<time>`, or the app does both at launch and notifies; after fixing the copy's permissions, a relaunch does not resume the session
- Reboot/login with active or dirty journals
- Backstop resuming a frozen test process through the installed `Insomnia --resume-frozen`, and keeping the entry when the bundle is removed or its Info.plist lacks `InsomniaResumeFrozenVersion`
- Existing Low Power Mode preference and saved audio restoration
- Low Power Mode on macOS 27, where `pmset -g custom` prints `powermode` and no `lowpowermode` (a session on battery with the lid closed and "Low Power Mode while the lid is closed" on, or below the Low Power floor): the log has no "could not read low power mode" line, `pmset -g custom` shows `powermode 1` under Battery Power while the mode is on, and the session end leaves it at `0`; with High Power set beforehand (`powermode 2` under Battery Power), the read is refused, the log says so, and `powermode 2` is still set after the session
- App Nap opt-in: previous `NSAppSleepDisabled` put back at session end, by the backstop after a force-quit, and by uninstall
- Battery/thermal event behavior on supported hardware
- A `sudo pmset` that ignores SIGTERM: left running, lock held, journal intact, quit refused until it exits
- The same command with the app force-quit: the backstop does not take the lock until the command exits; the relaunch names the pid from `unfinished-command.json`, and at its next retry after the command exits (retries start 30 s after each refusal) resumes the session with its battery floors
- A left-running `disablesleep 0` that exits 0: the end finishes without running it again
- After that command exits: Low Power Mode ownership matches the mode, and a lid open made meanwhile is undone
- `SleepDisabled 1` set by hand with no session: left alone and reported at launch, not cleared
- Unreadable battery (IOKit miss) ends the session on a laptop after the second read; desktop unaffected
- Settings floor steppers keep the end floor below the Low Power Mode floor by moving the other stepper
- First launch over an existing install tightens Application Support/Insomnia and Logs/Insomnia to 0700 and their files to 0600

### Lid close

- Lid-close/open and safe recovery of explicitly selected test processes
- Freeze-all scope with agents running (Cursor/T3 Code/Claude untouched)
- Freeze-all off on a fresh config.json (list only) and on with a terminal, a non-Chrome browser and a JetBrains IDE open (all untouched)
- Real lid close with freeze-all on during a Zoom or Teams call on AirPods, with Wispr Flow or Granola taking notes: none of their processes stopped (`ps -o stat` shows no `T`), the call and the notes continue, other Dock apps frozen, sound muted
- Upgrade notice: install over a build whose config.json has `freezeAllApps: true` and `muteOnLidClose: false`; the first launch posts one "Lid-close settings changed" notification and shows the same line in Settings (also with notifications off for Insomnia), both settings change and config.json gets `lidCloseDefaultsApplied: true`; a setting turned back stays back after a relaunch with no second notice; Dismiss removes the line; a fresh install shows no notice
- Mute with a changing output: close the lid on AirPods, put them in the case so the speakers take over, open the lid; the speakers keep their volume and mute and the AirPods are unmuted when reconnected. Close the lid again on the speakers while the AirPods are still away: the speakers are muted too, and the next lid open restores them
- Output away at session end: close the lid on AirPods, put them in the case, choose End; sleep is restored, the notification and the menu say the AirPods are still muted. Take them out with Insomnia running: their volume comes back and the menu line goes. Again with Quit instead of End, then launch Insomnia with the AirPods connected: restored at launch. "Stop waiting for AirPods" drops the entry and leaves them muted; uninstall stops while one is waiting
- Backstop and uninstall over saved audio of an output device renamed to `Headset \u0041` (a Bluetooth headset renamed in Bluetooth settings, the lid closed on it with muting on, then the app quit with `kill -9` and the session left to expire): the backstop log has no "malformed" and shows "pmset -a disablesleep 0 ok", state.json keeps the headset's entry, and the next launch with the headset connected restores its volume and mute
- Lid close with a freeze-list app stopped beforehand by `kill -STOP` (left stopped on lid open, not in the journal)
- Lid close during a session after `chflags uchg` on state.json (mode 0444 is not enough: the app writes a new file and renames it over state.json, and rename needs write access only to the folder): no process stopped, every app logged as left running; `chflags nouchg` before lid open
- Simulated lid close/open via scripts/simulate-lid.sh on a build installed with `INSOMNIA_LID_SIMULATION=1 ./scripts/install.sh` (the launch log, status menu and Settings show "Lid simulation build")
- A normal install (no `INSOMNIA_LID_SIMULATION`) ignores scripts/simulate-lid.sh during a session: no log line, no lid actions, trigger file left in place; no "Lid simulation build" marker anywhere
- Docker Desktop idle/busy behavior with another Docker context selected
- Docker rule off on a fresh config.json (no `docker ps`, Docker untouched) and on with a container started between the two idle checks (Docker untouched, both checks logged with their answers)
- Docker rule on, lid opened while an idle check is still running (Docker never paused, the display and frozen apps restored without waiting for `docker ps`, insomnia.log says the lid opened during that check), and a session started with the lid already closed (no countdown redraw until the lid opens)
- tmux cancellation with a dedicated disposable pane
- tmux nudge on the user's own tmux server: marked pane gets `continue` only, Enter toggle submits it, unmarked pane untouched
- Headed-browser throttling with the lid closed
- Relaunch unthrottled: confirmation alert, profile arguments carried over, a browser that has not quit after 10 s is left as it is and the notification names it, a browser not running 5 s after `open` is reported
- Relaunch failure while Insomnia is frontmost: with notifications allowed, the "Browser not relaunched" banner shows without switching apps after the confirmation; with notifications off for Insomnia, the reason is a warning line in the right-click menu
- Comet (`ai.perplexity.comet`): with freeze-all on and Comet running but not on the freeze list, a lid close leaves it untouched; "Relaunch Comet unthrottled" carries its profile arguments over, and the headed-browser throttling check above passes in Comet after it

### Display and keyboard backlight

- Lid-close display/keyboard darkening and restore
- Darkening still runs under the private-call guards on macOS 26 (close the lid during a session: the log shows "display darkened" and "keyboard backlight off" and no "refused" line; Settings shows no note under the darken toggle)
- Darkening refused on an unmeasured macOS version (a macOS major other than 26 or 27, or a `KeyboardBrightnessClient` whose methods changed: the log shows the "refused" line once and "skipped" at lid close, nothing is journaled for that device, and Settings names the reason under the darken toggle; with both refused the log shows "display sleep not requested" and the panel is lit when the lid opens; a level saved by the earlier build stays in state.json with `displayRestoreRefused` or `keyboardRestoreRefused` after the first open or launch, the menu says it could not be restored on this macOS build and names each saved level, Settings shows the saved level under the darken toggle, no "Restore incomplete" follows, and the backstop log does not fail for it)
- A kept brightness on a build that can make the call (after a refused restore, set the keyboard backlight by hand, put the display to sleep, then launch that build and wake the display): the log shows "not read: macOS has the backlight suppressed or dimmed" and then "set since its restore", and the backlight stays at the level set
- A kept keyboard backlight when a session ends with the lid closed, on a build that can make the call: the log shows "the lid is not known to be open, so the kept value is not read", and about a minute or less after the lid opens, with no session, "set since its restore" or "keyboard backlight restored"
- A kept brightness at a launch with no session and the lid closed (an external display in clamshell mode, after a refused restore), on a build that can make the call: the log shows "not read: the lid is not known to be open" for each kept device and nothing is written, and once the lid opens "set since its restore" or "restored"
- A kept display brightness restored late during a session (launch with the display asleep after a refused restore, wake it, start a session at once, wait for "display restored", then close and open the lid within 30 s): the close logs "display darkened (was brightness" with the restored level, and the open brings the panel back at that level, not black
- A kept display brightness under Insomnia's own Low Power Mode, on a build that can make the call (after a refused restore, set the display by hand, start a session on battery below the floor so Insomnia switches the mode on, then open the lid): the log shows "under our low power mode, which rescales it" and nothing is written; once the mode is off, "after our low power mode was or may have been on in this run" and nothing is written, and a close logs "stays journaled and undecided, and the display is not darkened" and the panel goes dark only if the display sleep request is honored; after a relaunch with the lid open, "since the Mac last started" and nothing is written; after a restart, "set since its restore" with the level set by hand, and a close and open after that bring back that level
- A kept display brightness over a restart with Insomnia's Low Power Mode claimed (as in the row above, quit the app with `kill -9` while the mode is on, restart the Mac, set the display by hand, then launch on battery): the log shows "journaled as ours before the Mac last started, reads on" or "reads off; it may have gone off only a moment ago"; either way nothing is written and the display is not darkened at a close until the next restart, and after it "set since its restore" with the level set by hand. After an open under the mode read the panel above 0, set the display to 0 by hand, relaunch and then restart: the kept value never comes back over that 0, after the restart the log shows "only a reading above 0 tells them apart" and the entry stays in state.json, and once the display is raised above 0 by hand, "set since its restore" with that level
- A kept display brightness when the recovery agent switches Insomnia's Low Power Mode off after a restart (as in the row above, quit with `kill -9` while the mode is on, restart the Mac, and wait for "pmset -b lowpowermode 0 ok" in the backstop log before launching on battery): the backstop log shows "kept display entry's record given this boot" before "pmset -b lowpowermode 0 ok", state.json's `keptDisplayUnderLowPowerBoot` is this boot's `kern.bootsessionuuid`, the launch logs "since the Mac last started" and writes nothing, and after the next restart "set since its restore"
- Quit while a reading above 0 of the kept display entry is not yet in state.json (as in the restart row above, `chflags uchg` state.json before the launch after the restart that reads the panel above 0, then Quit): the menu says "do not quit until state.json can be written" and Insomnia keeps running; after `chflags nouchg`, Quit within the next retry quits, and state.json has `keptDisplayReadLit`
- The recovery agent when state.json refuses writes over a kept display entry (as in the agent row above, `chflags uchg` state.json in the new boot before the agent runs): the backstop log shows "Low Power Mode left on, keeping journal entry for retry", `pmset -g` still shows lowpowermode 1, and sleep is restored; after `chflags nouchg`, the next run logs "record given this boot" and then "pmset -b lowpowermode 0 ok"
- Quit while the clear of a settled kept display brightness is not yet in state.json (after a refused restore, set the display by hand above 0, `chflags uchg` state.json, launch with no session so the log shows "set since its restore", set the display to 0 by hand, then Quit): the notification says "do not quit until state.json can be written", Insomnia keeps running and Start is refused; after `chflags nouchg`, the next retry clears the entry from state.json, Quit quits, and a relaunch leaves the display at 0
- A kept display brightness read above 0 that a close under the closing lid reads at 0 (as in the row above, after the launch that leaves the entry waiting, keep the display asleep until the session starts, wake it with auto-brightness on, then close the lid in a dark room before the next re-read): the close logs "where auto-brightness under the closing lid may have pulled it down" and "stays journaled and undecided", nothing is written at the close or the open, and while the panel reads 0 the open and every re-read log "only a reading above 0 tells them apart" and the entry stays in state.json; once the panel reads above 0, "set since its restore" with that level, and the kept value is never written
- The same entry across a relaunch (as in the row above, quit Insomnia after the close with the lid still closed, open the lid, and relaunch Insomnia while the panel still reads 0): the launch logs "only a reading above 0 tells them apart" while the panel reads 0, nothing is written, and once the panel reads above 0, "set since its restore" with that level
- Backstop and uninstall with a hand-edited state.json whose `keptDisplayReadLit` is `1e-400` (a copy of a journal from the restart row above, in a test home): the backstop logs "is unreadable or malformed; nothing undone, evidence kept", uninstall prints "state.json is unreadable or malformed" and removes nothing, and state.json is unchanged

### Hotspot

- Hotspot permission, association, cancellation, and reconnect
- Hotspot password after a reinstall: menu and Settings report it unreadable, no prompt during an outage, re-save replaces the item (prompt on Save allowed)
- Settings location note matches what System Settings shows after the grant

### Install, upgrade and uninstall

- Install/upgrade/uninstall with recoverable failure conditions
- Recovery agent refuses to run after the installed bundle or its sealed backstop.sh is modified, and logs why
- Running app refuses to arm (session start refused, reason shown) after its installed bundle is edited or re-signed under it
- Upgrade whose new agent fails to load puts the previous bundle back and reloads the previous agent, on a working Mac
- Upgrade whose new agent plist cannot be saved, and a rerun after an install killed mid-swap, leave the app and the agent's plist matching, on a working Mac
- Upgrade whose bundle rename is refused (the new build cannot be moved in, or the previous app cannot be moved back) puts the previous app back and reloads its agent, or keeps both bundles and prints the commands, on a working Mac
- Install whose `sudo -n -l` check or `launchctl` call stalls while it holds the recovery lock (for example a directory-service lookup that does not answer) stops after 30 s and releases the lock, and the agent's next run can take it, on a working Mac
- Install from a release zip with `install.sh --allow-unverified-origin --app` on a working Mac, first launch of the downloaded app
- Installed bundle from a release zip has no group or other write bit and no ACL (`ls -leR ~/Applications/Insomnia.app`), keeps its quarantine flag (`xattr -p com.apple.quarantine`) and passes `codesign --verify --strict --deep`, on a working Mac
- `uninstall.sh` run from a release zip unpacked in `/tmp` runs the installed app's sealed `backstop.sh` after `codesign --verify`, on a working Mac
- `install.sh` and `uninstall.sh` from a release zip unpacked in `/tmp`, with a `build-app.sh` and a `backstop.sh` added to the unpacked folder, run neither (install without `--app` stops, uninstall runs the sealed copy), on a working Mac
- `install.sh --app` from a release zip stops with the Apple Silicon message on an Intel Mac, and installs on an Apple Silicon Mac from a Terminal running under Rosetta
- Install or uninstall whose own process is killed (`kill -9 <pid>`) during a `launchctl bootout` keeps the recovery lock until that bootout has ended or been stopped, about 33 s at most, and the app started afterwards keeps its agent loaded, on a working Mac
- The installed recovery agent on the supported macOS release: launchd bootstraps its plist, loads it at login and runs its verify-then-exec command line, and the agent recovers a session after the app crashes
- The installed agent's plist is the one install.sh wrote
- A source install end to end: `./scripts/install.sh` builds, signs and installs the app with the administrator password, and stops while a running app refuses to quit

### Release channels

- Release workflow end to end: tag push, tests, package, attestation, GitHub Release, `gh attestation verify` of the download
- Nightly channel end to end: scheduled run on `main`, tag `nightly-<date>-<commit>` created by the workflow, prerelease not marked Latest, `gh attestation verify --source-ref refs/heads/main --source-digest <commit>` of the download, and a second run on the same commit skipped before building

### Launch at login

- Launch at login survives a reinstall by install.sh, including a second install.sh run on the same unchanged build (switch on, reinstall, relaunch: the log shows the launch-time check, System Settings > General > Login Items lists Insomnia as enabled, and the Settings switch reads on; a pending approval shows the note and the Open Login Items button)
- Launch at login heals on the first upgrade from a build without the install record (switch on in the previous build, upgrade with install.sh, relaunch: the log shows "registering once and recording the install", Login Items lists Insomnia, and config.json has `launchAtLoginInstall`)
- Launch at login removed in System Settings stays removed (switch on, relaunch once so the install is on file, remove Insomnia under System Settings > General > Login Items, relaunch: the log says the removal was respected, the Settings switch is off, and Login Items does not list Insomnia again)
- Pending approval withdrawn from Settings (switch on while macOS reports it waiting for approval, turn the switch off: Login Items no longer lists Insomnia and the next launch does not register it)
- Approval given in System Settings shows in an open Settings window (turn the switch on, approve under Login Items, click back into the Settings window: the pending note goes away without reopening the window)
