# Review context for Insomnia

Plain markdown that Greptile reads alongside `.greptile/config.json`. The
checkable rules live in that file; this one explains how the app and its
recovery script split the work, and lists designs that are deliberate so
they are not flagged again.

## How recovery works

The app writes two JSON files under `~/Library/Application Support/Insomnia`
(or `INSOMNIA_HOME`): `session.json`, whose `endsAt` is the only thing that
keeps sleep disabled, and `state.json` (`RuntimeState`), the journal of
everything Insomnia changed and must undo. Every change is journaled before
it is made and undone from the journal, never from memory. A session starts
by writing both files, arming the launchd backstop, and only then running
`pmset -a disablesleep 1` through the macOS administrator password prompt
(`AdministratorPrompt.swift`); it never starts without the backstop. Only an
explicit Start shows that prompt. The sudoers rule covers turning sleep back
on and Low Power Mode, never turning sleep off.

The app undoes the journal itself at session end, Quit, lid open, and at
every launch (reconcile). `scripts/backstop.sh`, installed by `install.sh`
and run by a per-user LaunchAgent at load and every 60 s with macOS
`/bin/bash 3.2`, undoes it when the app cannot: once `session.json` is
missing or expired it runs `sudo -n pmset -a disablesleep 0` and
`-b lowpowermode 0` for the journaled flags and sends SIGCONT only to a
journaled pid that still exists, is stopped, started in this boot session at
the journaled second, and belongs to this user. It keeps, and never
restores, `savedOutputVolume`, `savedMuted`, `savedDisplayBrightness`,
`savedKeyboardBrightness` and `displayRestoredUnderLowPower`: CoreAudio and
the private brightness frameworks need the app. Legacy `frozenPids` entries
are never signaled or cleared by the shell. A flag is cleared only after
its undo succeeded; a journal that is unreadable or has a known key of the
wrong type is left untouched and the run exits 1.

The app and the script serialize on one `flock(2)` lock,
`.recovery.lock`, which is never unlinked so both lock the same inode
(`RecoveryLock.swift`; `lockf` on fd 9 in the scripts). `uninstall.sh`
takes the lock, runs the backstop with `--force` under it, and refuses to
remove the recovery machinery while anything is still journaled. Battery
and thermal floors run only while the app is alive; the backstop does not
provide them.

## Deliberate designs, do not flag

Each entry names where the behavior lives, what it does, and why it stays.
Flag a change that breaks one of these; do not flag the behavior itself.

- `SessionManager.swift`, `scheduleReassert` and the clean end path. The
  2 s second write of a lid-open brightness restore is not cancelled when
  the session ends: `scheduleReassert(nil, nil)` returns early and leaves a
  scheduled task alive. powerd re-applies its own remembered brightness a
  moment after the wake, and a session ending inside that window does not
  change that; the write after Insomnia's own Low Power Mode ends also needs
  the task to survive the empty undo. A new lid close journals fresh values
  before it darkens, and the task checks the journal before it writes.
  Raised on PR #15 and withdrawn.
- `SessionManager.swift`, `settleDisplayAfterLowPower`. The display write
  after Insomnia's own Low Power Mode ends is best effort: a failed write is
  logged and `displayRestoredUnderLowPower` is dropped, not retried, because
  the only later place to retry is a restore where the mode is no longer
  ours, by which time the panel has been the user's for an unknown time.
  The brightness keys fix it. Raised on PR #15 and withdrawn; spec section 4.
- `SessionManager.swift`, the re-assert window. A brightness change the user
  makes inside the 2 s window after a lid open is overwritten by the second
  write. Documented and accepted (PR #11, spec section 4).
- `AppServices.swift`, the display sampling hold. Display brightness sampling
  is held while `lowPowerSetByUs` is true, whether or not something else has
  since cleared the physical mode. The flag means ownership; nothing polls
  pmset during a session, and the floor driver and session end act on the
  same flag. Known and accepted on PR #15.
- `StatusWidthWriter.swift` and `StatusItemController.swift`.
  `NSStatusItem.length` is written once per layout change, never per frame,
  because every write makes Control Center re-lay out the whole menu bar and
  blocks the app's next render commit for 8 to 130 ms. A countdown whose
  leading field loses a digit (10:00:00 to 9:59:59, 10d to 9d) causes one
  more write by design; a padded fixed-width countdown is not wanted. The
  digit-boundary finding on PR #13 was withdrawn. A return to per-frame
  length writes is a regression and should be flagged.
- `AppNap.swift`. `NSAppSleepDisabled` is written into each agent app's own
  preferences domain at session start, is not journaled, and is never unset:
  it persists after session end and uninstall (spec section 5 and open
  decisions, README).
- `backstop.sh`, `run_bounded`. A `sudo -n pmset` that is still running
  after SIGTERM plus 3 s is not killed. The run returns 125, stops the
  transaction with the journal and session exactly as read, and the
  supervising subshell keeps the lock until the command ends, so every later
  app start and backstop run is refused as "lock held" until then. Killing
  sudo would orphan a root pmset outside any transaction.
- `backstop.sh`, kept entries. Saved audio, saved display and keyboard
  brightness, and `displayRestoredUnderLowPower` are kept for the app, not
  restored by the shell. Legacy `frozenPids` are never signaled or cleared
  there, even when the pid is gone (spec section 8).
- `ProcessControl.swift`, `LidActions.swift`, `backstop.sh`. Only pids
  Insomnia stopped are resumed, and only when the journaled identity still
  matches. Provisional entries written before the kernel confirmed the stop
  (identity nil) are never signaled and stay journaled for manual
  inspection. An app launched while the lid is closed is left alone.
  Electron apps are stopped as a whole process tree via the responsible pid.
- `FloorRules.swift`, `LidActions.swift`. Low Power Mode is switched on at
  lid close whether or not the charger is connected, because with sleep
  disabled a closed Mac otherwise runs at full speed and heats up. One
  evaluation owns the mode across the lid, battery and thermal causes and
  switches it off only when none holds. A lid-caused change is logged, not
  announced (spec sections 4 and 6, PR #10).
- `SessionManager.swift`, `performStart`. `session.json` and
  `sleepDisabledByUs` are written and `LaunchdBackstop.arm()` has succeeded
  before `pmset -a disablesleep 1` runs through the administrator password
  prompt. Quitting the app always ends the session; there is no keep-awake
  after quit (spec section 1).
- `install.sh`, `SleepGuard.swift`, `AdministratorPrompt.swift`. The
  sudoers rule has three NOPASSWD lines and none for `disablesleep 1`:
  turning sleep off asks for the administrator password at every Start, so
  nothing running as the user can keep the Mac awake unattended. Reconcile
  at launch reads `pmset -g` and never prompts or turns sleep off again; a
  session whose sleep was turned back on while the app was not running ends
  (`EndReason.sleepReenabled`). No install path, failure paths included,
  writes a passwordless `disablesleep 1` line (PR #32).
- `AdministratorPrompt.swift`, `SessionManager.swift`. The password prompt
  gets SIGTERM at 120 s and is never sent SIGKILL. One still running 3 s
  later is reported with its pid, and the start keeps the recovery lock,
  `session.json` and the journal entry until it exits, then rolls back. The
  same rule as a stuck `sudo -n pmset`.
- `DisplayPower.swift`, `LidActions.swift`. On lid close, brightness 0 is
  the primary mechanism; the display sleep request (`IORequestIdle`) is
  best effort and is ignored while any process holds a display assertion,
  which agents routinely do. The keyboard backlight is left alone when no
  trusted reading exists, because restoring a suppressed 0 would leave it
  off. Bluetooth stays on for Instant Hotspot (spec section 4).
- `SleepGuard.swift`, `install.sh`. `pmset -a` (all power sources) for
  `disablesleep`, `pmset -b` for `lowpowermode`, so the guard behaves the
  same with and without a charger (spec open decisions).
- `Log.swift`. Every log line is also appended as plain text to
  `insomnia.log`, a local file shared with `backstop.sh` so one file tells
  the whole story. That file may contain SSIDs, process metadata and tmux
  target names (SECURITY.md). The privacy rule applies to the unified log.
- `LidActions.swift`. Lid events do nothing when no session is active
  (spec section 3).
- `simulate-lid.sh`, `LidSimulation.swift`. The trigger file is the same
  trust boundary as `config.json`: anyone who can write the support
  directory already controls the app. A trigger left over from before the
  session started is drained and logged as stale, not delivered.
- `install.sh`. Not atomic. It asks for the password (`sudo -v`) before a
  running app is asked to quit, so a cancelled password changes nothing and
  a running session keeps going; when a session is running it says so first
  and, in a terminal, asks to continue. It then quits the app, writes the
  sudoers file on the cached credential, and only then replaces the bundle.
  A failure after the rule is written says exactly what was installed so far
  and gives the rerun command.
