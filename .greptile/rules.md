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
`sudo -n pmset -a disablesleep 1`; it never starts without the backstop.

The app undoes the journal itself at session end, Quit, lid open, and at
every launch (reconcile). `scripts/backstop.sh`, installed by `install.sh`
and run by a per-user LaunchAgent at load and every 60 s with macOS
`/bin/bash 3.2`, undoes it when the app cannot: once `session.json` is
missing or expired it runs `sudo -n pmset -a disablesleep 0` and
`-b lowpowermode 0` for the journaled flags and sends SIGCONT only to a
journaled pid that still exists, is stopped, started in this boot session at
the journaled second, and belongs to this user. Entries that record
`startedAtMicros` it never signals itself: it hands them to the installed
app binary (`Insomnia --resume-frozen <seconds>`), which checks each to the
microsecond and signals it, and keeps them on any unexpected answer. It runs
the binary only when the bundle's `Info.plist` declares
`InsomniaResumeFrozenVersion` equal to its `RESUME_FROZEN_VERSION`, and the
binary keeps the recovery lock on fd 9 until it ends itself after
`<seconds>`. It keeps, and never
restores, `savedOutputVolume`, `savedMuted`, `savedAudioOutputs`,
`savedDisplayBrightness`, `savedKeyboardBrightness` and
`displayRestoredUnderLowPower`: CoreAudio and the private brightness
frameworks need the app. `savedAudioOutputs` entries alone leave the
journal clean for the backstop (an entry can wait days for its device), but
uninstall stops on them. A saved brightness flagged
`displayRestoreRefused` or `keyboardRestoreRefused` (the app's private-call
guard refused that restore on this macOS) stays journaled but is not dirty
for the backstop or uninstall, which keeps state.json for it, nor for the
app while the guard refuses that device. A build whose guard allows the call
writes the flagged value only while the device still reads 0, the level the
lid close left: a higher reading means the user already undid the darkening
by hand, so the entry is cleared without a write. Only a reading taken while
macOS is not holding the device down counts: the display awake, the keyboard
backlight neither suppressed nor dimmed. A reading taken while macOS holds it
down, or a read that fails, leaves the entry as it is for a later read. A
display reading above 0 taken under the app's own Low Power Mode, or after it
in the same run, leaves the entry for the next launch. Legacy
`frozenPids` entries are never signaled or cleared by the shell. A flag is
cleared only after its undo succeeded; a journal that is unreadable or has a
known key of the wrong type is left untouched and the run exits 1.

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
- `AppNap.swift`. Writing `NSAppSleepDisabled` into agent apps' preferences
  is opt-in and off by default. With it on, the previous value is journaled
  in `appNapOverrides` before each write and put back at session end,
  reconcile, by backstop.sh and by uninstall. A key already YES, a value
  that is not a boolean and an id `defaults` would not read as that app's
  domain are left alone and not journaled. Values written by builds before
  the journal were never recorded: uninstall lists them with the command to
  remove them and does not delete them (spec section 5).
- `backstop.sh`, `run_bounded`. A `sudo -n pmset` that is still running
  after SIGTERM plus 3 s is not killed. The run returns 125, stops the
  transaction with the journal and session exactly as read, and the
  supervising subshell keeps the lock until the command ends, so every later
  app start and backstop run is refused as "lock held" until then. Killing
  sudo would orphan a root pmset outside any transaction.
- `backstop.sh`, `run_app_bounded`. The `Insomnia --resume-frozen` call
  is killed with SIGKILL when SIGTERM plus 3 s does not end it, unlike
  `run_bounded`: it is the user's own unprivileged binary, and once SIGKILL
  is delivered it runs no more code, so it cannot signal anything later.
  The backstop shell starts the binary as its own background job, with no
  supervisor process in between, and signals it with the shell builtin
  `kill %+` after checking that `%+` is that pid. Bash reaps the child by
  itself, so a signal by pid could reach a reused pid; a jobspec signal is
  sent only while bash has not reaped the child. This is the bounded-call
  exception in the fixed-path rule, so it is not `$KILL`. The entries go on
  standard input, one line each, so no journal size can exceed the argument
  limit. A timeout, or any answer that is not exactly one `<pid> <word>`
  line per entry with a matching exit status, keeps every entry of the call.
- `backstop.sh`, `run_app_bounded`, fd 9. The binary inherits fd 9, so the
  recovery lock stays held for as long as it can send a signal, also when
  the backstop shell died first. It ends itself with SIGALRM after the
  lifetime the shell passes (`COMMAND_TIMEOUT_SECONDS +
  KILL_GRACE_SECONDS`), after resetting SIGALRM to its default action and
  unblocking it, so an orphaned binary frees the lock on its own. One that
  is still alive after SIGKILL keeps the lock until the kernel ends it.
- `backstop.sh`, `resume_via_app`, and `uninstall.sh`, step 3. The shell
  runs the binary only when `INSOMNIA_INFO` declares
  `InsomniaResumeFrozenVersion` equal to `RESUME_FROZEN_VERSION`; otherwise
  it keeps those entries without running anything, because an older build
  would start the menu bar app. `install.sh` copies the binary before
  `Info.plist`. `uninstall.sh` runs the checkout's backstop only when the
  installed app declares that version, and otherwise the
  `APP_SUPPORT/backstop.sh` installed with the app, when there is one.
  With no installed copy it runs the checkout's backstop anyway, which
  keeps those entries, so uninstall stops before removing anything.
- `backstop.sh`, kept entries. Saved audio, saved display and keyboard
  brightness, and `displayRestoredUnderLowPower` are kept for the app, not
  restored by the shell. Legacy `frozenPids` are never signaled or cleared
  there, even when the pid is gone (spec section 8).
- `ProcessControl.swift`, `LidActions.swift`, `backstop.sh`. Only pids
  Insomnia stopped are resumed, and only when the journaled identity still
  matches. Provisional entries written before the kernel confirmed the stop
  (identity nil) are never signaled and stay journaled for manual
  inspection. One exception: when the write that confirms a freeze fails,
  `LidActions.freeze` undoes the stops it sent moments earlier through
  `cancelStops`, checked against the identity it read before the SIGSTOP
  and still holds in memory. That SIGCONT goes to a matching pid even if
  it does not show as stopped yet, because a SIGSTOP can still be pending
  and generating SIGCONT discards it. That rollback then removes the
  provisional entries of the pids it resumed, that are gone, or that the
  freeze never stopped, and keeps those it could not resume; until the disk
  takes that write, the status menu leaves the removed ones out. An app
  launched while the lid is closed is left alone.
  Electron apps are stopped as a whole process tree via the responsible pid.
- `FloorRules.swift`, `LidActions.swift`. Low Power Mode is switched on at
  lid close whether or not the charger is connected, because with sleep
  disabled a closed Mac otherwise runs at full speed and heats up. One
  evaluation owns the mode across the lid, battery and thermal causes and
  switches it off only when none holds. A lid-caused change is logged, not
  announced (spec sections 4 and 6, PR #10).
- `SessionManager.swift`, `performStart`. `session.json` and
  `sleepDisabledByUs` are written and `LaunchdBackstop.arm()` has succeeded
  before `pmset -a disablesleep 1` runs. Quitting the app always ends the
  session; there is no keep-awake after quit (spec section 1).
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
- `install.sh`. Not atomic. It asks for sudo once, for the sudoers file,
  before anything of a previous install is touched, and a failure after
  that step says exactly what was installed so far.
