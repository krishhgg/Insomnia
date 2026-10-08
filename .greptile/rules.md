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
the journaled second, and belongs to this user. Entries that record
`startedAtMicros` it never signals itself: it hands them to the installed
app binary (`Insomnia --resume-frozen <seconds>`), which checks each to the
microsecond and signals it, and keeps them on any unexpected answer. It runs
the binary only when the bundle's `Info.plist` declares
`InsomniaResumeFrozenVersion` equal to its `RESUME_FROZEN_VERSION`, and the
binary keeps the recovery lock on fd 9 until it ends itself after
`<seconds>`. With `--own-bundle`, which `install.sh` passes to the copy in the
bundle it staged, the binary and `Info.plist` are the ones beside that copy,
so the pre-swap recovery never runs the older installed build. It keeps, and
never restores, `savedOutputVolume`, `savedMuted`, `savedAudioOutputs`,
`savedDisplayBrightness`, `savedKeyboardBrightness` and
`displayRestoredUnderLowPower`: CoreAudio and the private brightness
frameworks need the app. The app's records `keptDisplayUnderLowPower`,
`keptDisplayUnderLowPowerBoot` and `keptDisplayReadLit` are kept too.
Before the backstop's `lowpowermode 0`, when the journal has
`keptDisplayUnderLowPower` with another boot or none, it writes its own
`kern.bootsessionuuid` (empty if unreadable) to
`keptDisplayUnderLowPowerBoot` and publishes that journal on its own, so
the app doubts that entry's readings in that boot even if the journal of
the undo never lands. If that publish fails, the mode is left on and its
entry kept for retry. Both scripts check the records' types and read the
three keys from the file's text too (`record_text_problems`, the same in
both), as the app's decoder reads it: keys of the top-level object only,
with their `\u` escapes decoded, every value stepped over whole, so a
string or nested value holds no record. Each number must be null or a
JSON number that a Swift Float holds and that does not round to 0 from a
nonzero value (plutil turns 1e-400 into 0.0). One of the keys found twice
at the top level, a key with an escape JSON does not have, and a top
level the reader cannot follow (JSON5 keys, comments, NUL bytes as in
UTF-16) are refused. Any of
these makes the journal malformed, so nothing is undone and uninstall
removes nothing. `savedAudioOutputs` entries alone leave the
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
in the same boot, relaunches included, leaves the entry for a launch after a
restart. A claim on the mode written before the Mac last started (its record
of the kept entry names another boot) is read before the switch-off for the
log only: on, off or unreadable, the switch-off is the mode's end in this
boot, since a mode read off may have gone off a moment before, so the
entry waits for a launch after the next restart. A reading above 0 of the
kept entry is journaled (`keptDisplayReadLit`), and a later 0 is then not
overwritten with the saved value, in that run or any later one. No 0 read
after it is taken as a level set since either, however late, since macOS may
still hold the panel at a closing lid's 0: the entry stays flagged, with the
display sample held, until the panel reads above 0. A close with no sample
leaves the entry flagged. If state.json refuses `keptDisplayReadLit`, an
end returns
`.incomplete(agentArmed: false)` and Quit waits until it lands. Legacy
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
  brightness, `displayRestoredUnderLowPower` and the records
  `keptDisplayUnderLowPower`, `keptDisplayUnderLowPowerBoot` and
  `keptDisplayReadLit` are kept for the app, not restored by the shell,
  except that a backstop run gives `keptDisplayUnderLowPowerBoot` its own
  boot, in a journal it publishes before its `lowpowermode 0`, and leaves
  the mode on if it cannot. The records are read from the file's text as
  well as through plutil (`record_text_problems`), at the top level only.
  Legacy `frozenPids` are never signaled or cleared there, even when the
  pid is gone (spec section 8).
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
  later is reported with its pid and its marker is deleted under the
  marker's lock. Once that succeeds its root command can no longer run
  pmset, so the start waits for its answer window (`expires`, at most 15
  s by then) to end, is settled from the receipt and releases the
  recovery lock; the prompt is watched outside the
  transaction, and the menu line offers `kill <pid>` until osascript exits
  and goes once the prompt has. Only while the root command holds the
  marker's lock (anywhere from its nonce check to its exit, a sudo query
  that never returns included) or the marker cannot be deleted does the
  start keep the recovery lock, `session.json` and the journal entry until
  the prompt exits, with no time limit, the same rule as a stuck `sudo -n
  pmset`. The 120 s is the app's wait before SIGTERM, not a bound on the
  root command; docs must not call a hung query bounded by it.
- `AdministratorPrompt.swift`, `SessionManager.swift`, `backstop.sh`,
  `uninstall.sh`. A prompt can outlive its start (the app crashes or is
  force-quit under the dialog, the start is settled after a stuck prompt).
  Its root command therefore runs under `lockf -k -n` on `pending-start`
  and runs `pmset -a disablesleep 1` only while the file holds that start's
  nonce and `/bin/date +%s` is below `expires` (the session's end or 130
  s after the marker, `AdministratorPrompt.answerWindow`, whichever is
  first), passed as `$3`; a
  `$3` that `[` cannot compare refuses too. The start deletes the file before it releases the recovery lock;
  every other lock holder deletes it before it touches the journal, and
  every deleter (Store.removePendingStart, backstop.sh, uninstall.sh)
  takes the file's own lock first and deletes only while the path still
  names the locked file (device and inode of the locked descriptor against
  the path; the scripts lock the marker through fd 8 to have one), so the
  file never goes between the nonce check and the end of pmset. Voiding a
  stuck prompt also needs the locked file to be the one that start wrote. The file is written with no newline
  and compared, never run. A marker that cannot be written rolls the start
  back with no prompt. One that cannot be locked in time or deleted keeps
  `sleepDisabledByUs` journaled after sleep is restored (the app and the
  backstop both gate the clearing on it), is reported, refuses new starts,
  and makes `uninstall.sh` refuse to remove anything. A cancelled dialog or
  an osascript that never launched ran nothing as root: the start restores
  the journal and session.json exactly and runs no pmset.
- `BackstopVersion.swift`, `backstop.sh`. Start reads the
  `# insomnia-backstop-version:` line of the `backstop.sh` sealed in the
  bundle the agent runs and shows no dialog below version 4 (2 is the
  first that deletes `pending-start`, 3 the first that settles a
  journaled `sleepOffAttempt` from its receipt, 4 the first that reads
  the receipt under its lock as the 82-byte line with the predecessor and
  the start's `expires`, and gives the start's claim back); the user is
  told to run `install.sh` again.
  Bump the version line and `BackstopVersion.required` together whenever
  the app starts relying on new backstop behavior.
- `AdministratorPrompt.swift`, `SleepGuard.swift`, `install.sh`. Before the
  dialog the app runs nothing through sudo:
  `SleepGuarding.checkSleepSettingForStart` only reads `pmset -g`, and a
  `SleepDisabled 1` the journal does not claim refuses Start with nothing
  run, deliberately, so a setting another tool made stays. The check that
  the end can restore without a password is in the root command, under
  the marker's lock and the receipt's, before any write, in this order: a
  uid that is a positive number (5) of plain digits (7), the receipt
  opened read-only on fd 8 and locked with `/usr/bin/lockf -s -t 10 8`
  (75 if it stays locked), checked by fixed path (7: `stat`/`ls -le` of
  `/private/var/db/com.kgarg.insomnia/<uid>` and every folder up to /
  showing a one-link 82-byte regular file under folders, all root's, no
  group or other write, no allowing ACL, and fd 8 and the path the
  device:inode the start claimed, `$7`), the nonce check (3), `expires`
  (4), no
  `/private/etc/sudo.conf` in any form (5: `sudo -V` does not list an
  approval plugin with no show_version, and sudo consults one only when
  it runs a command), `/private/etc/pam.d/sudo` with exactly one
  uncommented session line, `session required pam_permit.so` (5: sudo
  opens a PAM session only to run a command), then three queries as that
  user through `q()` = `u /usr/bin/sudo "$@"`, `u()` being `sudo -n -u
  "#$w" /usr/bin/env -i LC_ALL=C "$@" </dev/null`: `-V` (5 unless
  exactly sudo 1.9.17p2, its sudoers policy plugin, grammar 50 and only
  the sudoers I/O and audit plugins after them), `-k -n -l` (5 unless it
  lists without a password, shows no Runas or command-specific Defaults,
  and shows only Defaults entries on the list in the root command:
  env_reset, env_keep, env_check, env_delete, log_allowed, log_denied,
  and lecture, lecture_file, passprompt, badpass_message, passwd_timeout,
  passwd_tries, timestamp_timeout, timestamp_type, tty_tickets,
  pwfeedback and insults, which sudo reads only when it asks for a
  password), and `-k -n -ll /usr/bin/pmset -a disablesleep 0` (5 unless
  it prints exactly the six-line /etc/sudoers.d/insomnia entry:
  `RunAsUsers: root`, `Options: !authenticate`, the restore as the only
  command and `Matched:` the restore). Then `expires` (4), the nonce and
  predecessor uppercase UUIDs that differ, the nonce not all zeros (7),
  the receipt's first 36 bytes through fd 8 equal to the predecessor `$6`
  (8), a root read of `pmset -g` (6 on a `SleepDisabled 1` or a failed
  read; skipped only when `$5` is exactly `1`, the journal claimed the 1
  before this start), `<nonce> <predecessor> writing` written into the
  receipt in place by `/usr/bin/env -i /usr/bin/perl` (sysopen
  `O_WRONLY|O_NOFOLLOW` with no create or truncate, the same device:inode
  as fd 8, one full syswrite, `fcntl` `F_FULLFSYNC` (51), close, reopen
  and read back; `<nonce> <predecessor> refused` and 7 if any of that
  fails or perl is missing), `expires` again (`refused` and 4), and only
  then `pmset -a disablesleep 1`, the command's only power write (1 if it
  fails). Its shell and pmset keep fd 8, so the receipt stays locked
  until pmset exits. Root never writes the marker or anything in the
  user's folders. `trap '' PIPE` keeps each refusal's status when the
  dialog's stderr is gone. Exits 3, 4, 6, 7 and 8, and lockf's 69 and 75,
  are `.refused`; 5 is `restoreNeedsPassword`. All refusals leave the sleep
  setting as the command found it and roll back with no pmset, so another
  tool's setting found by a read stays. Any other status is ambiguous:
  the start deletes the marker under its lock, reads
  `SleepOffReceipts.verdict` under the receipt's lock and rolls back with
  no pmset only when the deleted file is the marker journaled in
  `sleepOffAttempt` and the verdict is `.neverWrote`: the receipt passes
  every check, is the journaled device:inode, and holds this nonce with
  `refused`, another start's line naming the same predecessor, or the
  predecessor itself once the dialog ended by itself
  (`AdministratorPromptError.dialogOver`: cancelled, launch failure,
  refusal, wrong password) or `expires` has passed. This nonce's
  `writing`, or a later line naming another predecessor, is
  `.mayHaveWritten` and undone like an end at once; a missing, replaced,
  unsafe or malformed receipt is too once `expires` has passed. Before
  then those, and at any time a receipt lock that stays busy or fails,
  are `.undecided`: the start keeps the attempt, its claim and
  `sleepDisabledByUs` and runs no pmset before `expires` unless the
  journal owed a restore before it (`owedBefore`). A dialog that did not end by itself
  (timeout, stuck prompt, interruption) and has at most 15 s left of
  `expires` waits for it before the read. The next recovery-lock holder (the app after a relaunch,
  backstop.sh, uninstall.sh) settles an attempt still journaled the same
  way once the marker is gone and before it reads the session:
  `.undecided` keeps everything; otherwise the session.json whose end is
  the attempt's deadline goes, the claim goes back, `.neverWrote` puts
  `sleepDisabledByUs` back to `owedBefore`, anything else keeps it, and a
  settlement that cannot be written keeps the attempt and the claim (with
  `.neverWrote` and no `owedBefore` no pmset runs and Starts stay
  refused; otherwise the app ends an unexpired session of it and refuses
  Start, backstop.sh undoes as `--force` and exits 1, uninstall.sh stops
  with no pmset). The release file `<uid>.released` (the user's, 0600,
  42 bytes, `<nonce> free|held`) holds the claim: a start claims only
  while it shows the receipt's nonce `free`, and another
  `INSOMNIA_HOME`'s unsettled claim refuses Start. A marker removed with no
  attempt journaled takes session.json with it when no session is in
  memory. Flag a change that writes anything (pmset, the receipt or a
  restore run as the user) before the checks pass, has root write the
  marker or any path in the user's folders, chmods or chowns a receipt
  or folder install.sh did not make, trusts a receipt owner other than
  root in a shipped build (an environment variable, file or flag that
  widens `owners` or `RECEIPT_OWNER` included), reads the receipt before
  the marker is gone under its lock, lets `.neverWrote` clear an owed
  `sleepDisabledByUs` rather than restore `owedBefore`, resumes a session
  whose attempt is still journaled, reads or claims the receipt without
  its lock or takes a busy or failed lock as clean, lets `.undecided` or
  a predecessor read before `expires` (dialog not over) settle as
  `.neverWrote`, writes the receipt without `F_FULLFSYNC` or with more
  than one write, claims while the release file shows another nonce or
  `held`, drops the sudo.conf or PAM check,
  accepts another sudo version or adds a Defaults name to the list
  without reading what that setting does when sudo runs a command,
  treats a missing, replaced or unreadable receipt, or a marker other
  than the journaled one, as showing no write, runs a query that
  executes a command,
  accepts `sudo -l` or `sudo -v` alone, a bare exit status or a NOPASSWD
  grep as the check, drops a clock check after a query or the read, reads
  sudo's output in another locale or without fixed paths, or treats exit
  1 as a refusal. Known and disclosed (round 14 P1 narrowed to one
  moment, not closed): pmset has no compare-and-set and one
  `SleepDisabled` with no owner, so a 1 another tool sets between root's
  read and its `disablesleep 1` is taken for Insomnia's and set to 0 by
  the end; one set during the session is set to 0 by the end; one set
  after root's read during a dialog that then fails ambiguously (timeout,
  stuck prompt, pmset failure, a status lost to a signal) is set to 0 by
  the undo once the command wrote `writing`, even when it stopped before
  its write; once `expires` has passed a receipt that shows nothing, and
  at any time a replaced marker or a settlement that cannot be written,
  also undo; an attempt that stays `.undecided` keeps Start refused and
  the session recorded until a later holder settles it; the receipt is
  `F_FULLFSYNC`ed, but what that and pmset's own write guarantee across
  a power loss is not measured, so older receipt content beside pmset's 1
  stays possible and that 1 is then reported as someone else's; a
  process running as the user can rewrite state.json and the attempt,
  swap the marker while a command holds it, or write a settled start's
  nonce into a new marker before a password goes into that start's old
  dialog; a start that cannot clear its attempt after success, and a
  marker found with no attempt, end that session early; and while the
  journal claims a 1 another tool's 1 is taken for it, and a refusal
  leaves it owed. The listing is about the rule when it is
  read: a rule removed later, a sudo.conf or PAM file changed later, or
  other groups at restore time can still make a restore fail, and the
  backstop retries. The check refuses every Start under any sudo but
  1.9.17p2, a sudo.conf, other PAM session lines, Defaults outside the
  list (global, user-bound or host-bound), Defaults bound to a Runas user
  or a command, `listpw=always` or a later rule for the restore,
  and install.sh changes none of these. The user types the password before a refusal is reported; a
  sudoers without root's default entry fails closed. `install.sh` runs no
  pmset: after writing the rule it checks a `sudo -k -n -l` listing, which
  is not the check.
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
  and, in a terminal, asks to continue. It then quits the app and, under the
  recovery lock, looks for a reopened app and writes the sudoers file on
  the cached credential before the recovery and the bundle swap. Every stop says what was installed so
  far; one after the rule is written gives the rerun command.
