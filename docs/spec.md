# Insomnia — keep the Mac awake and working with the lid closed

These are design notes, not a release certification. The
[README](../README.md) describes supported use and recovery limits; the
[release validation record](release-validation.md) tracks unverified hardware
scenarios. Historical model sketches and UI proposals below are not exhaustive
descriptions of the current code.

## Purpose

Insomnia is a menu bar app for timed awake sessions on a MacBook, used on a
stable, well-ventilated surface. It must not be used to keep a Mac awake in a
closed bag. Its design goals are to:

1. Prevent lid-close sleep for a fixed, user-chosen duration. Never a toggle.
2. Reduce battery waste while the lid is closed without slowing the agents.
3. Shorten Wi-Fi to hotspot handoffs so agent API retries succeed.
4. Journal changes and support recovery after interruption, while reporting
   incomplete restoration rather than promising unconditional success.

## Non-goals

- Not a kernel extension, not a signed privileged helper, not a notarized
  download. Built from source, ad-hoc signed, installed by a script.
- Does not manage or restart the agents themselves. The only agent interaction
  is an optional "continue" keystroke into tagged tmux panes.
- Does not touch sleep behaviour outside an active session.
- Prefer OS events for live observations; recovery retries and countdown redraws
  require bounded recurring work.

## Platform

- macOS 26 on Apple Silicon (built and tested on MacBook Pro M5).
- Swift 6, SwiftUI content hosted in a custom `NSStatusItem`, Swift Package.
  No Xcode project.
- `install.sh` assembles a minimal `Insomnia.app` bundle (`LSUIElement = true`,
  no Dock icon), ad-hoc codesigns it, and installs it to `~/Applications`.

## Core model

```
Session {
  startedAt:   Date
  endsAt:      Date          // the only thing that keeps sleep disabled
  extendedBy:  [TimeInterval]
}

RuntimeState {                // everything Insomnia changed and must undo
  sleepDisabledByUs:  Bool
  lowPowerSetByUs:    Bool
  frozenProcesses:    [{pid, startedAt, startedAtMicros, bootSession}]
  dockerFrozen:       Bool
  savedOutputVolume:  Float?  // nil when mute is off or lid is open
  savedMuted:         Bool?
  savedDisplayBrightness:  Float?  // nil when darkening is off or lid is open
  savedKeyboardBrightness: Float?  // nil when there is no backlight, too
  displayRestoredUnderLowPower: Float?  // restored on open under our Low Power Mode; written again when it ends
  appNapOverrides:    [{bundleId, previous?}]  // previous absent when the app had no NSAppSleepDisabled key
}
```

Both are written to `~/Library/Application Support/Insomnia/` as JSON on every
change. They are the source of truth for reconcile and for the backstop.
Legacy `frozenPids` entries lack ownership identity and need conservative
recovery; newly written journals use `frozenProcesses`.

## Features

### 1. Timed sessions (the only way to keep the Mac awake)

- Time is entered inline in the menu bar as Days / Hours / Minutes pills.
  Enter with empty fields uses the configured default preset. Maximum 30 days.
- While active the menu bar shows a second-resolution countdown. The redraw
  timer runs at 1 Hz and stops while the lid is closed.
- Click the cup/countdown to enter an extension; hold the end control to end.
  Right-click opens the status, browser actions, Settings, and Quit menu.
- Session start: write session + state to disk, arm the launchd backstop, and
  only then run `sudo pmset -a disablesleep 1`. A session never starts unless
  the backstop is armed. If pmset fails, delete the session file and surface
  the error. The journal and backstop always exist before sleep is disabled.
- Session end (timer, End now, Quit, battery floor, thermal critical):
  `sudo pmset -a disablesleep 0`, undo every RuntimeState entry, delete
  session, notify.
- Quitting Insomnia always ends the session. There is no "keep awake after quit".

### 2. Sleep guard and root access

- `install.sh` writes `/etc/sudoers.d/insomnia` allowing the user to run,
  without a password, exactly:
  - `/usr/bin/pmset -a disablesleep 1`
  - `/usr/bin/pmset -a disablesleep 0`
  - `/usr/bin/pmset -b lowpowermode 1`
  - `/usr/bin/pmset -b lowpowermode 0`
- Nothing else runs as root.

### 3. Lid observer

- IOKit interest notification on `IOPMrootDomain` for `AppleClamshellState`.
  Insomnia sleeps in its run loop; the kernel wakes it on change. Zero cost
  between events.
- 2-second debounce to ignore flapping.
- Lid close and open each run a fixed, reversible action list (below).
- Lid events do nothing when no session is active.

### 4. Lid-close actions (battery)

All actions are recorded in RuntimeState and reversed on lid open, session end,
Quit, or reconcile.

| action | on close | on open |
|---|---|---|
| Display (optional, default on) | save brightness, set it to 0, request display sleep (best effort) | wake the display, restore the saved brightness |
| Keyboard backlight (optional, same toggle) | save brightness, set it to 0 | restore the saved brightness |
| Freeze scope | `SIGSTOP` every process whose responsible app is in the freeze scope (rules below) | `SIGCONT` the recorded pids only |
| Docker rule | if Docker Desktop is running and `docker ps -q` is empty, freeze it | resume |
| Mute (optional) | save volume and mute state, then mute | restore both exactly |
| Low Power Mode | on (optional, default on) | off unless a battery or thermal floor still wants it |
| Countdown redraw | stop timer | restart timer |

Freeze scope rules:

- Two scopes. The explicit freeze list: apps the user picks by bundle id from
  a list of currently running apps; always frozen. The automatic scope
  (`freezeAllApps`, default on): every running app with a regular activation
  policy (a Dock app) and a bundle id, so that only agents keep running while
  the lid is closed. Menu-bar (accessory) and background apps are never picked
  up automatically; they can be put on the explicit list by hand. With the
  toggle off the explicit list is the whole scope.
- Hard denylist that can never be frozen, from either scope: `com.apple.*`,
  Insomnia itself, Docker Desktop (handled by the Docker rule), and any bundle
  id in the agent list (below).
- Built-in protected set (`FreezePlanner.builtInProtected`): editors and agent
  hosts (VS Code, Cursor, Zed, Antigravity, Claude, ChatGPT/Codex, Conductor,
  T3 Code, Windsurf, JetBrains IDEs), terminals (Warp, Ghostty, iTerm),
  browsers agents drive (Arc, Chrome, Chromium), Tailscale, LM Studio, Ollama
  and Docker Desktop's Electron front end. The automatic scope leaves them
  alone even when they are not on the agent list. Code level and not
  persisted: an existing config.json already carries its own agent list, so
  new agent-list defaults never reach it. An explicit freeze-list entry
  overrides this set; the hard denylist does not.
- Order: the explicit list first, in its own order, then the automatic
  candidates by app name, de-duplicated. One info log line names the
  automatic candidates on each close.
- Only pids Insomnia stopped are resumed. An app launched while the lid is
  closed is left alone.
- Electron apps are stopped as a whole process tree (main + helpers), found
  via the responsible-pid relationship, so no helper keeps spinning.

Display and keyboard backlight are handled by Insomnia, not by the hardware.
The September 16, 2026 audit (docs/release-validation.md) found that the
sleep guard (`pmset -a disablesleep 1`) removes the only path by which macOS
turns the built-in panel and keyboard backlight off on clamshell close: that
happens on the system-sleep path, which the guard disables. The earlier claim
here that both are "already off by hardware" was wrong under the guard, so
the panel and keys stayed lit for the whole closed period. A display sleep
request (`IORequestIdle` on `IODisplayWrangler`, what `pmset displaysleepnow`
does) is ignored while any process holds a display assertion, and agents
routinely do, so brightness 0 is the primary mechanism and the sleep request
is best effort. Display brightness 0 does not switch the keyboard backlight
off; it is set separately. Both values are journaled before they are changed
and restored on open, session end, Quit, or reconcile with the lid open; the
backstop keeps the entries and only the app restores them (private
frameworks). What is journaled is the user's value, not whatever the device
reads at that instant. A reading is trusted only when the last keyboard,
mouse or trackpad input was under 30 s ago (`CGEventSource`; the idle dim
never starts sooner) and the panel is awake (`CGDisplayIsAsleep`, else it
reads the idle-dim value) or the keyboard backlight is neither suppressed by
display sleep (it reads 0) nor idle-dimmed, and the app keeps the last trusted
reading of each, sampled every 30 s with the lid open, at start, 3 s after
each lid open, and just before Insomnia switches Low Power Mode on itself.
The display at the close event is never the user's value when it can be
avoided: the lid coming down covers the ambient light sensor and
auto-brightness has already pulled the panel down by the time the close is
reported (measured 0.75 to 0.335 with the user at the keyboard, so the idle
rule alone does not catch it), and Low Power Mode rescales it (0.75 reads
0.5). So the display journals the last open-lid sample; without one, the
value a lid open restored under Insomnia's own Low Power Mode if that is
still journaled as owed and the mode still ours (the app relaunched under
the mode, so the new sampler has nothing and is held); only without either
the current read,
dim or not, since a dim panel on open beats a black one.
While Low Power Mode is on because Insomnia switched it on (the journal's
`lowPowerSetByUs`), the display sample is held: the panel reads the mode's
value, and the sample taken just before the mode went on is the one to
restore. The keyboard journals the current
read if trusted now, else its last sample; when nothing trustworthy is
known for it, it is left to macOS entirely (no journal entry, no write),
because restoring a suppressed 0 would leave the backlight off. On open the
restore is written, the entries cleared, and the same values written once
more 2 s later, because powerd re-applies its own remembered brightness
asynchronously after the wake and can override the first write; that second
write is skipped if the lid closed again in the meantime (the close journals
fresh values first) and superseded by any newer restore. A display restore
written while Insomnia's own Low Power Mode was on is journaled as
`displayRestoredUnderLowPower` and written once more, then re-asserted the
same way, right after Insomnia switches the mode off (lid open, charger,
thermal recovery or session end), because the mode's end rescales the panel
and can leave it elsewhere than the value written under it. That second
write is owed only while the panel still reads what was written (within
0.05, auto-brightness drift): a panel the user has moved with the keys
since the open is theirs and is left alone. It is dropped, too, if the lid
closed again meanwhile (the next open restores with the mode already off),
and if the mode turns out to have been cleared by someone else (the
backstop after a kill: it keeps the entry but never writes brightness);
taking the mode over discards any entry left from an earlier interval in
the same journal write. A Low Power Mode interval with no lid restore under
it writes nothing. The
sample the display journals dates from the last 30 s window in which the
user was active with the lid open and the panel awake, and is held from
before Insomnia's own Low Power Mode: a brightness change made within 30 s
of closing the lid, or under that mode, is not seen. If Insomnia is not running when the lid
opens, the brightness-up key restores the panel. Bluetooth is still left alone (needed for Instant
Hotspot, and negligible).

Low Power Mode on lid close is decided by the same rule as the battery and
thermal floors (section 6), so the three causes never fight over the mode: it
stays on while any of them holds and is switched off when none does. It applies
whether or not the charger is connected, because with sleep disabled a closed
Mac otherwise runs at full speed and heats up. A lid-caused change is logged
but not announced: switching the mode off is announced only when the cause that
last held while it was on was the battery or thermal floor, not the lid.


### 5. Agent apps: keep them fast

- Agent list (bundle ids, default: T3 Code, Conductor, Terminal, iTerm,
  Ghostty, Warp, Chrome, Chromium, Arc, Docker Desktop, VS Code, Cursor, Zed,
  Antigravity, Claude, ChatGPT/Codex, Tailscale, LM Studio, Ollama). Editable.
- Built-in protection (section 4): the same editors, agent hosts, terminals,
  browsers, VPN and local model runtimes are protected from the automatic
  lid-close scope even on an install whose config.json predates these
  defaults and never lists them. Only the agent list can also turn App Nap
  off; only an explicit freeze-list entry overrides the built-in protection.
- Turning App Nap off is opt-in (`disableAppNapForAgents`, default off). With
  it off Insomnia never writes another app's preferences. With it on, session
  start reads each listed app's `NSAppSleepDisabled`, journals the previous
  value (absent, true or false) in `appNapOverrides`, and only then writes
  `YES`. A journal write failure means no preference write. An app whose key
  is already `YES` is skipped: there is nothing to put back. So is an entry
  `defaults` would not read as that app's domain (a leading `-`, a path,
  `NSGlobalDomain`, anything but ASCII letters, digits, `.`, `-` and `_`),
  since the backstop could not put it back; it is logged. Session end,
  reconcile, the backstop and uninstall write the recorded value back
  (`defaults delete` when it was absent) and clear the entry only after that
  write succeeded. Settings shows the toggle, the list of apps it affects,
  and what it changes.
- Values written by builds before this were never recorded and are not
  guessed at: uninstall reads the key for every app on the shipped agent
  list and on config.json's (an app taken off the list may still carry one),
  lists each whose key is `YES` with no journal entry, prints the
  shell-quoted `defaults delete` command for it, and continues. The summary
  says how many apps were checked; an app whose key cannot be read is
  reported, not counted. Each read has a 30 s limit, like every other call
  uninstall makes under the recovery lock (`pgrep`, `launchctl`); a read
  that does not answer ends the check with the command to run by hand, and
  uninstall goes on. A call past its limit gets SIGTERM, then SIGKILL, and
  never holds the lock.
- Browser throttling: Chromium browsers throttle windows macOS reports as
  occluded, which is every window once the lid is closed with no external
  display. Timers drop to 1 Hz, animation frames stop, pages report hidden.
  This can break computer-use and browser-use agents.
  - Insomnia inspects running Chromium processes for
    `--disable-backgrounding-occluded-windows` and
    `--disable-renderer-backgrounding`.
  - If a browser is running without them, the menu shows a warning and a
    "Relaunch <browser> unthrottled" item that quits and relaunches it with
    both flags and the same profile.
  - Headless Playwright is unaffected and needs nothing.
  - **Must be verified on the real machine with the lid shut** (see test plan).
    If macOS 26 does not mark windows occluded in this state, the feature is
    reduced to the App Nap default and the warning is removed.

### 6. Battery and thermal floors

Event sources: `IOPSNotificationCreateRunLoopSource` (fires on every battery
percentage change) and `ProcessInfo.thermalStateDidChangeNotification`. While
the battery is unreadable the power source list is re-read every 30 s, since
IOKit sends no event for a read that keeps failing.

| condition | action | undo |
|---|---|---|
| battery below `lowPowerFloor` (default 40%) | `pmset -b lowpowermode 1` | charger connected, or session end |
| battery below `endFloor` (default 10%; 0 turns the end off) | end session, notify | — |
| battery present but unreadable on two consecutive reads, on battery, `endFloor` above 0 | end session, notify | — |
| thermal state `serious` | `lowpowermode 1` | thermal back to `nominal`/`fair`, or session end |
| thermal state `critical` | end session, notify | — |
| lid closed (if `lowPowerOnLidClose`, charging or not) | `lowpowermode 1`, no notification | lid opened, or session end |

`PowerMonitor` tells a machine with no internal battery (desktop: no floor
applies) from one whose battery is present but not reported, by checking for
the `AppleSmartBattery` service when the power source list has no battery
entry or cannot be read at all. On that laptop, charger or battery comes from
the driver's `ExternalConnected` property in the I/O Registry rather than the
list that failed; when that cannot be read either, the laptop is taken to be
on battery, so the session ends rather than holding sleep with no floor on a
battery that may be draining. One missed read is tolerated as transient; the
second ends the session, because the end floor cannot be applied to a level
nobody can read. Only the IOKit event and the 30 s re-read count misses; the
menu's own refresh reads the level but leaves the count where it is, so a
menu opened during a transient miss is not the second one, and the count
never moves without the floor rules running. An unreadable level never counts
as below a floor, so it does not enable Low Power Mode by itself.

A non-zero `endFloor` stays below `lowPowerFloor`, which gives Low Power Mode
a chance to come on before the session ends. It is not a guarantee: a reading
already below both floors, or one that crosses both between evaluations, ends
the session without it. Settings enforces the order in 5% steps by moving the
other floor when the two would cross (`endFloor` at most 95). A `config.json`
that violates it is corrected at load by raising `lowPowerFloor` to `endFloor`
+ 5 (capped at 100), logged, and written back.

Insomnia does not enable Low Power Mode merely because a session starts; the
causes are the battery floor, a serious thermal state, and (by default) a closed
lid. One evaluation owns the mode: it is switched off only when no cause holds.
Battery and thermal rules run only while the app is alive; they are not
provided by the standalone backstop. Performance effects depend on workload.

### 7. Network failover

- `NWPathMonitor` on the Wi-Fi interface. Event-driven.
- Path unsatisfied for more than 5 s: use CoreWLAN to run an SSID-filtered
  scan, then join with `associate(to:password:)`. The password is read from
  the login Keychain (generic-password service `insomnia-hotspot`, account =
  SSID) and is never placed in process arguments. Retry with backoff (5 s,
  10 s, 20 s, 30 s, then every 30 s) until the path is satisfied or the
  session ends.
- macOS 26 requires Location Services permission before CoreWLAN exposes SSIDs
  or returns results for an SSID-filtered scan. Insomnia requests when-in-use
  access when the hotspot is saved or a configured session starts, never at
  launch. Mac apps have no when-in-use state: a grant settles on
  `authorizedAlways`, and System Settings records it as Location Services
  access for Insomnia (the Settings window says so next to the Location
  row). Insomnia never starts location updates. The real hotspot join still
  must be run on the Mac in the manual test plan below.
- Log lines naming the SSID, a tmux target or a process reach the unified
  log as private data (`Log.swift`), so `log show` prints `<private>` for
  the body; `insomnia.log` keeps the text.
- Each outage is logged with start, end, and gap length to
  `~/Library/Logs/Insomnia/handoffs.log`. The menu shows the last gap.
- Path satisfied again after a gap longer than `nudgeThreshold` (default 90 s):
  - For every configured tmux target (`session:window.pane`), resolve the
    concrete pane, read its state and then its mark, the pane-scoped user
    option `@insomnia-nudge` (`show-options -qpv -t %N`, without `-A`, so
    a session or window option never counts). Only a pane marked `on` by
    the user (`tmux set-option -p -t <target> @insomnia-nudge on`) gets
    `tmux send-keys -t %N continue`, followed by `Enter` only when
    `tmuxNudgePressesEnter` is on (default off). An unmarked pane is
    skipped and logged.
  - Post a notification: "Network was down 2m 10s. Nudged 2 tmux panes.
    Check GUI agents."
- Recommended one-time setting, documented in the README: System Settings >
  Wi-Fi > "Ask to join hotspots" = Automatically.

### 8. Reconcile and backstop (recovery goals)

Invariants:

- Sleep is never disabled unless a session file with a future `endsAt` exists.
- Every change Insomnia makes is in RuntimeState before it is made, and is
  undone from RuntimeState, never from memory.

Reconcile runs at every Insomnia launch:

1. Session file missing or expired → restore journaled changes: sleep,
   verified owned processes, Low Power Mode if we set it, saved audio, and
   recorded App Nap values.
   Unverified entries and failed restoration remain unresolved, not successful.
   A session file that does not decode counts as expired: it is renamed under
   the lock to `session.json.unreadable-<UTC stamp>` (never deleted, never
   overwriting an earlier copy), the user is told where, and the journal is
   restored as with no session. `backstop.sh` does the same once the journal
   is clean. A session file that decodes as JSON but lacks a key or type
   the `Session` decoder needs (`startedAt`, `endsAt`, `extensions`) is not
   a session either; `backstop.sh` checks the same keys and types. The app
   and both scripts read a date in one form only: `2027-01-15T08:00:00Z`,
   as Store writes it, or the same with an offset such as `+02:00` in place
   of `Z`, in whole seconds, naming a date and time that exist, years 1970
   to 9999 (`Store.parseDate`, `epoch_of` in the scripts). A session file that exists
   but cannot be read at all, or is not a regular file (never opened: a
   FIFO would block under the lock), has no end time that can be enforced,
   so it also counts as expired and the journal is restored. It may have
   been a valid session, so it is never opened or removed: it is renamed
   aside the same way (the app at once, `backstop.sh` once the journal is
   clean), which keeps it as evidence and keeps a later launch from
   resuming a session that was treated as ended. The app notifies with the
   new path. If the rename fails the file stays and a start is refused
   while it is there. Every end then restores the journal and tries the
   rename again; while it fails the end is not finished, so quit is refused
   and the end is retried, because the file would be resumed if it became
   readable in place. The messages say to remove it or move it out of the
   folder. `backstop.sh` tries the rename again on every run.
   An unreadable journal still refuses every transaction and leaves both
   files in place.
2. Session valid → establish the independent recovery agent before reapplying
   the sleep guard, then resume observers. If the lid is open, restore recorded
   lid-close actions. Arming or restoration errors must remain visible.
3. `pmset -g` reports `SleepDisabled 1` with no session and no journal
   entry → leave it. Step 1 has already undone a disable Insomnia journaled,
   so this one was set by something else (a hand-run `pmset`, another tool)
   and is not Insomnia's to undo. Log it, show it on the menu's warning line,
   and notify once per launch with `sudo pmset -a disablesleep 0`. A bit
   still journaled as ours after a failed restore is retried from the
   journal, not from this check. Nothing clears `SleepDisabled` without a
   journal entry, in the app or in the agent.

Backstop, independent of the app:

- The agent reads the saved deadline; recurring recovery checks avoid replacing
  the loaded job for every extension and allow retries after a failure.
- App and script transactions must coordinate through a shared lock. Failure
  to acquire it must not permit an unprotected journal write or side effect.
- Successful restores may clear their entries; failures must stay journaled.
  Process recovery must verify identity and avoid resuming a process that
  Insomnia did not stop. Old PID-only entries need conservative handling.
- The shell does not restore CoreAudio settings. Saved audio must remain in
  the journal for the app to restore. Uninstall must preserve recovery tools
  and state when restoration is incomplete, including saved audio.
- The shell puts `appNapOverrides` back with `defaults write <id>
  NSAppSleepDisabled -bool <previous>` or `defaults delete` when the key was
  absent. A delete that fails counts as done only when `defaults read` then
  says the key does not exist; a read that succeeds or fails any other way
  keeps the entry.
- The agent is a recovery mechanism, not a guarantee of crash/reboot behavior
  or a replacement for battery/thermal observers. These scenarios require
  the separate hardware validation record.

### 9. Notifications

`UNUserNotificationCenter`: session ended (with reason), extend reminder 5
minutes before end, battery floor reached, battery unreadable twice in a row,
thermal action taken, network gap recovered (with nudge summary), sleep
restored by backstop, sleep disabled by something other than Insomnia
(reconcile step 3, once per launch).

### 10. Settings

JSON at `~/Library/Application Support/Insomnia/config.json`, edited through a
small settings window:

- presets, default preset
- freeze list (bundle ids), freeze every other app on/off, Docker rule
  on/off, mute on lid close on/off
- agent list (bundle ids), turn App Nap off for them on/off (default off)
- `lowPowerFloor`, `endFloor`, thermal rules on/off
- hotspot SSID (password entered once, stored in Keychain), `nudgeThreshold`
- tmux targets, `tmuxNudgePressesEnter` (default off)
- launch at login (`SMAppService.mainApp`). macOS ties the login item to
  the bundle's signature and location, and `install.sh` ad-hoc signs a
  fresh bundle on every run, so an upgrade can drop the registration.
  config.json keeps `launchAtLoginInstall`, the code directory hash,
  bundle path and executable file identity (inode and birth time) of the
  install whose registration macOS last accepted. install.sh deletes the
  bundle and copies the executable in fresh, so even an unchanged or
  unsigned build reinstalled at the same path reads as a new install. At
  launch, with the flag on and `SMAppService.mainApp.status` neither
  enabled nor waiting for approval, that record decides: a different
  install means the reinstall lost the registration and the app registers
  again; the same install means the user removed the item in System
  Settings, and the app turns the flag off rather than put it back; no
  record (a config from before the field) means this is the first launch
  of a build that keeps one, itself a reinstall, so the app registers once
  and records the install. A user who removed the item while Insomnia's
  switch stayed on gets it back that once.
  Every outcome is logged. The Settings switch shows what macOS has on
  file (enabled or waiting for approval), not the flag; a registration
  waiting for approval shows a note with a button that opens System
  Settings > General > Login Items, and turning the switch off withdraws
  it; a register or unregister that throws shows its error under the
  switch. The flag and the install are persisted only when macOS accepted
  the change. The status is re-read when the Settings window appears and
  whenever the app becomes active, so an approval or removal made in
  System Settings shows without a relaunch. With the flag off nothing is
  registered or unregistered at launch.

### 11. Menu bar UI: inline time entry

Reference: the attached screenshot (coffee icon, then three rounded pill
fields "Hours", "Minutes", "Seconds", each with a small "?" badge, sitting
directly in the menu bar). Insomnia copies that interaction and the feel.

**Idle state.** A single coffee-cup status item. Nothing else in the bar.

**Entering a time.** Click the icon and the status item *expands in place*
along the menu bar: three pill fields spring out to the right of the icon,
one after another with a short stagger.

```
☕  ( Days ? ) ( Hours ? ) ( Minutes ? )
```

- Days · Hours · Minutes rather than the reference's Hours · Minutes · Seconds.
  Seconds are meaningless for keeping a laptop awake and days are needed.
  (Flip this in one line if you want the reference exactly.)
- Each pill is a numeric field. Placeholder text is the unit name; typing
  replaces it with the number and the pill grows to fit. Tab and Shift-Tab
  move between pills, Enter starts the session, Esc collapses.
- The "?" badge on each pill is a help affordance: hover shows a tooltip
  ("Up to 30 days" etc.). It is not an input.
- The current interface uses inline entry, not the preset-popover proposal
  from the original design. Empty-field Enter starts the default preset.

**Running state.** On Enter the pills collapse and morph into a compact
second-resolution countdown next to the icon. Clicking the cup or countdown
opens inline duration entry for an extension. Hold the end control to end the
session. The right-click menu contains status lines (lid, watts, Wi-Fi, frozen
apps, Docker), browser relaunch actions, Settings, and Quit.

Battery watts are read from `AppleSmartBattery` (`InstantAmperage` ×
`Voltage`) on demand when status is requested. Never continuously polled.

**Motion and feel.** This is a hard requirement, not polish.

- Everything animates with springs, except the fold that closes the pills
  (a fixed-duration ease, so the slots can leave the moment the last pill
  is gone), the pupil shrinking away as the lid drops (a 0.4 s ease-out,
  no bounce) and the Reduce Motion crossfades.
  Baseline: `.spring(response: 0.35, dampingFraction: 0.72)`; pill focus
  bounce and chip taps use a snappier `.spring(response: 0.25,
  dampingFraction: 0.6)` with a slight scale overshoot (1.0 → 1.06 → 1.0).
- The status item's width is never animated: `NSStatusItem.length` is
  written once per layout change (`StatusWidthWriter`), to the width the
  SwiftUI layout of a custom `NSStatusItem` view reports once per open and
  once per close, as every Apple item does. (Every length write makes
  Control Center re-lay out the menu bar and blocks the app's next render
  commit for 8–130 ms, so any per-frame width animation stutters; see the
  menu bar smoothness design spec, revision 4.) Layout-changing state (the
  phase, the pill slots, the error label) is set outside any animation
  transaction, so the layout is computed once per state; the hosting view
  is laid out at that width, anchored at the leading edge, and the item's
  window reveals or clips it. Only scale, offset and opacity animate inside.
- Each pill is a fixed slot sized by its placeholder at the typed weight and
  padding, so typing a digit never changes the layout.
- Pills appear with a staggered scale-and-fade (about 40 ms between pills)
  inside their slots, which are all in the layout from the first frame.
- On Esc and on Enter the pills fold toward the eye: each one slides left
  by the slots before it, shrinks to 0.6 from its leading edge and fades,
  on one 0.32 s ease curve, farthest pill first, 40 ms apart, sliding under
  its neighbour. The slots leave in one relayout 0.36 s after the last
  pill's step, and the width is written then, never across a visible pill.
  On Enter the eye starts to open at once and the countdown scales in from
  the leading edge after the slots have left, showing the time the session
  will read once the manager confirms it and ticking at 1 Hz meanwhile;
  the hold-to-end ring follows the confirmation. A click on the eye during
  an Esc fold brings the pills back; during an Enter fold the pending start
  owns the bar and the click does nothing until the manager answers.
  Transitions carry their own animation,
  so they run whatever transaction the layout change lands in.
- The eye's blink is a slower spring (response 0.95, damping fraction 0.9
  opening; 0.8 / 0.95 closing) so the lid lift and the lash hand-over are
  seen; the pupil scales in from 0.6 on its own bouncier spring 0.2 s later
  and eases out to 0.6 on close, clipped to the lens.
- Typing happens in a non-activating key panel: the app in front stays
  frontmost; only key status moves to the pills while typing, as with
  Spotlight, and it returns when the pills close.
- Number changes in the countdown use `.contentTransition(.numericText())`.
- Focus ring is a soft glow that breathes in, not a hard outline.
- Respect Reduce Motion: springs become short crossfades (0.15 s; the
  blink 0.3 s), the fold is opacity only in place (0.2 s), the stagger is
  zero.
- Rendering matches the reference: dark rounded pills with a subtle
  material, system font, SF Symbols icon, no custom images.

Reference for taste: Apple's own Dynamic Island and Control Center
transitions. If it feels like a web dropdown, it is wrong.

## Event sources (complete list)

| input | mechanism | cost between events |
|---|---|---|
| lid | IOKit interest notification | none |
| battery % | IOPS run loop source | none |
| battery unreadable | re-read every 30 s | one wake per 30 s, only while a session runs and the battery is unreadable |
| thermal | `ProcessInfo` notification | none |
| network path | `NWPathMonitor` | none |
| session deadline | one in-app timer plus independent launchd recovery | recovery checks may wake periodically |
| countdown redraw | 1 Hz timer, stopped while lid closed | one wake per second while active and visible |
| hotspot retry | only during an outage | none otherwise |

## Repository layout

```
Insomnia/
  Package.swift
  Sources/Insomnia/
    InsomniaApp.swift
    Model/
      Config.swift
      RuntimeState.swift
      Session.swift
    Store/
      Paths.swift
      Store.swift
    Core/
      AppServices.swift
      FloorRules.swift
      LaunchdBackstop.swift
      LidActions.swift
      Log.swift
      ProcessControl.swift
      SessionManager.swift
      SessionMath.swift
      Shell.swift
      SleepGuard.swift
    System/
      AppNap.swift
      AudioControl.swift
      BrowserThrottle.swift
      DisplayPower.swift
      DockerRule.swift
      Freezer.swift
      HotspotJoiner.swift
      LidObserver.swift
      LidSimulation.swift
      LocationPermission.swift
      NetworkFailover.swift
      Notifier.swift
      PowerMonitor.swift
      ShellTimeout.swift
      TmuxNudge.swift
    UI/
      DurationInput.swift
      HoldToEndButton.swift
      HotspotSecretStore.swift
      LiveStatusSource.swift
      MenuBarModel.swift
      Motion.swift
      PillView.swift
      ReminderScheduler.swift
      StatusMenu.swift
      SettingsView.swift
      StatusItemController.swift
      StatusRootView.swift
      StatusSource.swift
  Tests/InsomniaTests/
    BrowserThrottleTests.swift
    ConfigTests.swift
    DisplayPowerTests.swift
    DurationInputTests.swift
    FailoverMachineTests.swift
    FloorRulesTests.swift
    FreezerTests.swift
    HardwarePortsParserTests.swift
    IntegrationWiringTests.swift
    LaunchdBackstopTests.swift
    LidActionsTests.swift
    PmsetParsingTests.swift
    ReconcileLidGatingTests.swift
    ReconcileTests.swift
    SessionMathTests.swift
    StoreTests.swift
    TestSupport.swift
    UIStatusTests.swift
  scripts/
    install.sh             build, bundle, codesign, sudoers, launchd, login item
    uninstall.sh           reverse all of the above, restore sleep
    backstop.sh            standalone restore from JSON
    simulate-lid.sh        file trigger for the lid-close action path (debug and
                           INSOMNIA_LID_SIMULATION=1 builds only)
  docs/spec.md
  README.md                setup, hotspot setting, Chrome note
```

## Install

```
git clone https://github.com/kgarg2468/Insomnia.git && cd Insomnia
./scripts/install.sh      # asks for sudo once, for the sudoers file
```

Then set the hotspot in Settings, pick a freeze list, and start a session.

## Manual test plan

Run under supervision on a ventilated surface using disposable work before
claiming hardware validation. The checklist below is a test plan, not evidence
that any case passed; record results in the release validation record.

1. **First launch.** Confirm the status item is visible to the right of the
   notch on first launch.
2. **Stays awake.** Start 30m session, close lid, wait 5 minutes, ping the Mac
   from the phone or check the heartbeat log. Open lid: session still running,
   sleep still disabled until end.
3. **Restores.** End now → `pmset -g` shows no `SleepDisabled`. Quit → same.
   Timer expiry → same, plus notification.
4. **Backstop.** Force-quit a supervised disposable session, then verify
   deadline recovery and retry after an injected restore failure. Separately
   test reboot/login with valid, expired, and dirty journals; the polling
   agent honors a valid future deadline rather than unconditionally ending
   every session at login. Saved audio requires the app to reopen.
5. **Freeze.** Slack and WhatsApp on list, close lid, `ps -o stat` shows `T`
   for their whole trees. Open lid → running, reconnected, no relaunch.
6. **Docker rule.** No containers → paused on close. One container → untouched.
7. **Mute.** Volume 60%, close lid → muted. Open → 60%, unmuted.
8. **Chrome occlusion.** Lid closed, Playwright attached to headed Chrome:
   read `document.visibilityState` and measure `setInterval` drift. Repeat with
   both flags. Decide whether feature 5's browser section stays.
9. **Handoff and Location.** Save a hotspot for the first time and confirm the
   Location permission prompt appears. After granting, confirm the status menu
   shows the SSID. Turn off the router or walk away, watch `handoffs.log`, and
   confirm the hotspot join works within ~10 s and a Claude Code turn in flight
   completes.
10. **Nudge.** Mark a disposable pane (`tmux set-option -p -t <target>
   @insomnia-nudge on`). Gap forced above threshold → that pane receives
   "continue" and no Enter; an unmarked listed pane receives nothing;
   with "Press Enter after continue" on, the line is submitted.
   Notification posted.
11. **Floors.** Set `lowPowerFloor` above current charge → Low Power Mode on.
    Plug in charger → off. Set `endFloor` above current charge → session ends.
12. **Thermal.** Exercise injected thermal events first; verify responses to
    `serious`, `critical`, and recovery. Do not intentionally overheat the Mac.
13. **Darken.** Brightness 70%, keyboard backlight on, close lid → both go to
    0 (check `state.json` has `savedDisplayBrightness` and
    `savedKeyboardBrightness`). Open → both back, journal entries gone. Repeat
    with the lid open using `scripts/simulate-lid.sh closed` then `open`
    during a session; the log shows `lid SIMULATED closed (file trigger)`.
    That needs a build with the watcher compiled in (installed with
    `INSOMNIA_LID_SIMULATION=1 ./scripts/install.sh`; it logs "Lid
    simulation build" at launch). A normal install ignores the trigger:
    the watcher is compiled out so a file written by any other program
    running as the user cannot replay the lid actions. CI proves that on
    the binaries: `scripts/check-lid-simulation-gate.sh` builds the release
    both ways and checks the watcher class and its log lines are absent
    from the plain binary and present with the define. A binary nm or
    strings cannot read fails the check rather than counting as absent.
    Quit while closed → both restored. Force-quit while closed, reopen the app
    → restored at reconcile, and `backstop.sh` alone leaves both keys in place.
14. **App Nap.** With the setting on and Terminal on the agent list, `defaults
    delete com.apple.Terminal NSAppSleepDisabled`, start a session → `defaults
    read` shows 1 and `state.json` has an `appNapOverrides` entry without
    `previous`. End → the key is gone, entry gone. Repeat with the key set to
    0 → put back to 0. Force-quit during a session → `backstop.sh` alone puts
    it back. Set the key to 1 by hand, empty `appNapOverrides`, run
    `uninstall.sh` → it prints the `defaults delete` command and continues.

## Open decisions (defaults chosen, change if you disagree)

- `pmset -a` (all power sources) rather than `-b` for `disablesleep`, so
  behaviour is identical whether or not a charger is attached.
- Default `lowPowerFloor` 40%, `endFloor` 10%, `nudgeThreshold` 90 s.
- Turning App Nap off for agent apps is opt-in and the previous value is put
  back at session end. Values older builds wrote without a record are listed
  by uninstall, never deleted by it.
