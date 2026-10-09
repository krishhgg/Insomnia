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
- `build-app.sh` assembles a minimal `Insomnia.app` bundle (`LSUIElement =
  true`, no Dock icon) with `backstop.sh` sealed under `Contents/Resources`
  and signs it ad-hoc.
  `install.sh` installs that build, or a prebuilt bundle passed with
  `--app` after verifying its integrity (only with
  `--allow-unverified-origin`, since it cannot verify where a bundle came
  from), to `~/Applications`. The Release workflow
  packages the same bundle (`docs/releasing.md`), built for arm64 only;
  `install.sh --app` stops unless `sysctl -n hw.optional.arm64` reads 1
  (true on Apple Silicon, also under Rosetta). `install.sh` and
  `uninstall.sh` take sibling scripts (`build-app.sh`, `backstop.sh`) only
  from a source checkout's `scripts/` folder, with `Package.swift` one level
  up, and never from the folder above their own: the release zip carries
  both scripts at its top level, unpacked wherever the user chose, such as
  `/tmp`, where another account may have created that folder first and
  added files to it. Anywhere else, `install.sh` without `--app` stops and
  runs no `build-app.sh` it finds, and `uninstall.sh` runs only the verified
  bundle's sealed `backstop.sh`, or stops when the bundle has none. The
  staged copy of the bundle loses group and other write permission and
  every ACL before it is verified and installed (neither is part of the
  signature); extended attributes, the quarantine flag among them, stay.

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
  savedAudioOutputs:  [{deviceUID, name?, volume, muted, saveID?}]  // each output device a lid close muted, with what it had; saveID is a UUID drawn for each save; empty when mute is off or every device is restored
  savedOutputVolume:  Float?  // legacy: an earlier build's entry, restored on the default output; never written now
  savedMuted:         Bool?   // legacy, the same
  savedDisplayBrightness:  Float?  // nil when darkening is off or lid is open
  savedKeyboardBrightness: Float?  // nil when there is no backlight, too
  displayRestoreRefused:   Bool    // written only when true: the guard refused this restore; see section 4
  keyboardRestoreRefused:  Bool    // the same for the keyboard backlight
  displayRestoredUnderLowPower: Float?  // restored on open under our Low Power Mode; written again when it ends
  keptDisplayUnderLowPower:     Float?   // the kept (refused) display entry our Low Power Mode was on over; see section 4
  keptDisplayUnderLowPowerBoot: String?  // kern.bootsessionuuid of the boot that record was written in, or that backstop.sh switches the mode off in (published before it does)
  keptDisplayReadLit:           Float?   // the kept display entry, read above 0 with the lid open and the panel awake; see section 4
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
- Session start: check that the `backstop.sh` sealed in the bundle the
  agent runs declares `# insomnia-backstop-version: 5` or later
  (`BackstopVersion.swift`; 2 is the first that deletes `pending-start`, 3
  the first that settles a journaled `sleepOffAttempt` from its receipt, 4
  the first that reads the receipt under its lock as the 82-byte line with
  the predecessor and the start's `expires`, and gives the start's claim
  back, 5 the first that journals a settlement's decision
  (`sleepOffAttempt.settled`) before it gives the claim back, and finishes
  a settled record it finds)
  and refuse with nothing written, asking for `scripts/install.sh` again,
  if not. Then read `pmset -g`
  (`SleepGuarding.checkSleepSettingForStart`, which runs nothing through
  sudo). A `SleepDisabled 1` the journal does not claim is left alone, as
  after a cancelled dialog: run nothing and refuse, giving
  `sudo pmset -a disablesleep 0`, since the session's end would turn it
  back on. An unreadable `pmset -g` refuses too. When the journal already
  has `sleepDisabledByUs` (a failed restore is owed anyway) there is
  nothing to read. Then take the receipt's lock
  (`SleepOffReceipts.lock`; one that stays busy for 10 s refuses with
  nothing written) and claim the receipt (`claimable`: the release file
  must show the receipt's current nonce `free`, which becomes the start's
  predecessor; another folder's claim, a missing or unsafe receipt and an
  unreadable release file refuse with nothing written). Journal
  `sleepDisabledByUs` with `sleepOffAttempt`, write the claim (`<nonce>
  held`) and let the receipt's lock go. Then write session.json, arm the
  launchd backstop, write a fresh random nonce to `pending-start`, journal
  the marker's identity and `expires`, and only then run `pmset -a
  disablesleep 1` through the macOS administrator password dialog
  (`osascript` running a fixed `do shell script ... with administrator
  privileges` literal; 120 s limit, SIGTERM only at the deadline).
  `expires` is the session's `endsAt`, or 130 s after the marker is
  written if that is sooner (`AdministratorPrompt.answerWindow`: the
  dialog's 120 s, the 3 s grace after SIGTERM and 7 s for osascript to
  start), in whole seconds since 1970, rounded down. The marker path, the
  nonce, `expires`, the user's uid, whether the journal already claimed a
  `SleepDisabled 1` before this start (`1` or `0`), the predecessor and
  the receipt's `device:inode` are the script's only inputs, passed as
  positional parameters. The root command runs under `lockf` on the
  marker and keeps that lock from the nonce check until pmset exits
  (section 8). A uid that is not a positive number exits 5 before
  anything runs. Then comes the receipt (`SleepOffReceipts`, section 8).
  The uid must be plain digits. The command opens
  `/private/var/db/com.kgarg.insomnia/<uid>` read-only on descriptor 8
  and takes an exclusive flock(2) on it with `/usr/bin/lockf -s -t 10 8`
  (exit 75 after 10 s). Its shell and every tool it starts, pmset
  included, inherit the descriptor, so the lock lasts until all of them
  have exited. `stat -f '%u %Lp %l %z %HT'` plus `ls -lde` of the receipt
  and of every folder above it up to / must show a regular file with one
  link and 82 bytes under folders, each owned by root, with no group or
  other write bit and no ACL entry that allows anything, and descriptor 8
  and the path must both be the journaled `device:inode`. Anything else,
  an open that fails included, exits 7 with nothing written. Then the
  marker must still hold the nonce (exit 3) and `/bin/date +%s` must be
  below `expires` (exit 4). Before it writes anything, the command checks
  whether the end can turn sleep back on with no password. As root it first exits 5 when
  `/private/etc/sudo.conf` exists in any form: Apple's sudo loads plugins
  only from that compiled-in path, and an approval plugin there can print
  nothing in `sudo -V` and refuse only a command that runs. It also exits
  5 when `/private/etc/pam.d/sudo` cannot be read or has any uncommented
  session line but macOS's single `session required pam_permit.so`,
  since sudo opens a PAM session only to run a command. Root then runs
  `/usr/bin/sudo -n -u "#<uid>" /usr/bin/env -i LC_ALL=C /usr/bin/sudo
  ...` three times, with stdin from /dev/null; sudo never asks root for a
  password, and macOS's default `root ALL = (ALL) ALL` lets root run it
  as the user. The answers are read as sudo 1.9.17p2 prints them, the
  sudo in macOS 26.2 (Apple's sudo-114.100.11), the only source read for
  what a listing shares with running a command. `sudo -V` must show
  exactly `Sudo version 1.9.17p2`, the sudoers policy plugin 1.9.17p2,
  grammar version 50, and after them nothing but the sudoers I/O and
  audit plugins' own lines. `sudo -k -n -l` must list without a
  password, show no Runas or command-specific Defaults (they apply when
  the restore runs but not to a listing), and show only Defaults entries
  from a list of settings that cannot stop a NOPASSWD rule from running:
  env_reset, env_keep, env_check, env_delete, log_allowed, log_denied,
  and settings sudo reads only when it asks for a password (lecture,
  lecture_file, passprompt, badpass_message, passwd_timeout,
  passwd_tries, timestamp_timeout, timestamp_type, tty_tickets,
  pwfeedback, insults). Any other entry, such as `log_output`, exits 5
  and the message names it; so does a Defaults line with a backslash or
  a tab. `sudo -k -n -ll
  /usr/bin/pmset -a disablesleep 0` must print exactly six lines: the
  entry from /etc/sudoers.d/insomnia (`/private/etc/...` or `/etc/...`),
  `RunAsUsers: root`, `Options: !authenticate`, `Commands:`, the restore
  after a tab, and `Matched:` the restore. For a command, sudo prints the
  rule that decides it, the last match, so a later rule that asks for a
  password, denies, or runs as another user shows there instead and
  refuses. `-k` ignores a cached credential and `-n` fails instead of
  prompting. None of the three runs a command; a generic `sudo -l`,
  `sudo -v`, a listing's exit status alone, or a search for NOPASSWD is
  never taken as proof. Any failed file check or query, any other
  version, plugin, Defaults entry or output, output cut short, and a
  `listpw` that wants a password exit 5 with nothing changed
  (`AdministratorPromptError.restoreNeedsPassword`, whose message names
  the check and says `scripts/install.sh` fixes only a missing rule).
  Then `/bin/date +%s` is compared with `expires` again (exit 4). Both
  nonces must be different uppercase UUIDs and the nonce not the all-zero
  one (exit 7), and the receipt must still begin with the predecessor
  (`head -c 36` on descriptor 8; exit 8: another start or a recovery came
  first). The command then reads `pmset -g` itself, as root and under
  both locks, because another tool may have turned sleep off while the
  password was typed: a `SleepDisabled 1` (read the way
  `PmsetSleepGuard.parseSleepDisabled` reads it) or a read that fails
  exits 6 with nothing changed. Only when the journal claimed the 1
  before this start is nothing read, as at Start. Then it writes `<nonce>
  <predecessor> writing` into the receipt in place: `/usr/bin/perl`, run
  under `env -i`, opens the path with `O_WRONLY|O_NOFOLLOW` (no create, no
  truncate), checks by fstat that the descriptor is the locked file,
  writes the 82 bytes with one write(2) that must write them all, calls
  `fcntl(F_FULLFSYNC)`, closes the file, opens it again read-only with
  `O_NOFOLLOW` and reads the line back. Any failure, a missing perl
  included, writes `<nonce> <predecessor> refused` the same way and exits
  7. Then the command reads `pmset -g` again, under the same rule and only
  when it read it before: a `SleepDisabled 1` set while the line was
  written, or a read that fails, writes `refused` the same way and exits
  6, and that 1 stays. This second read narrows the time in which another
  tool's 1 can be taken for Insomnia's; it is not an owner token. The
  clock is compared once more: at or after `expires` the command
  writes `refused` and exits 4. Only then does root run `/usr/bin/pmset
  -a disablesleep 1` (the change the start journaled before the dialog),
  the command's only power write; if it fails, the command exits 1. Root
  reads the marker and never writes it, and writes nothing in the user's
  folders. The command ignores SIGPIPE, so a refusal keeps its status
  when the dialog's output is gone. No query or read has a timer of its
  own: the dialog's 120 s is how long the app waits before SIGTERM to
  osascript, which does not stop the root command, and a query that never
  returns keeps the marker's and the receipt's locks, so the start keeps
  the recovery lock and waits for it with no limit (below). The clock
  checks stop the write when it returns at or after `expires`. The user
  has typed the password before any refusal.

  The receipt exists before any Start: install.sh makes the folder
  (0755) and the file (0600, 82 bytes, the all-zero nonce twice and
  `refused`), root's, through `sudo -n` by those fixed paths, after
  checking by lstat that every folder from `/private/var/db` up is root's
  with no group or other write bit and no allowing ACL, then adds the
  file's one access control entry, `user:<name> allow read`, with `sudo -n
  chmod +a`. Only root and the user can open it, so no other account can
  take its lock. It checks again once they exist. A receipt an earlier
  build made (root's, one link, 82 bytes, no group or other write, no
  entry or only that one) is repaired in place by `sudo -n chmod`, bytes
  and inode kept, only while the release file shows no claim (none, or a
  nonce and `free`); a claim, or a release file that is not a regular
  file, cannot be read or holds anything else, stops the install before
  any change. One the user can open (any mode but 0600) is locked first,
  the release file is read under that lock, and before each chmod the
  receipt must still be the locked file with the same line. One the user
  cannot open (0600, no entry) is refused by every reader until it has
  the entry, so nothing claims or writes it meanwhile; it gets the entry
  first and is locked and checked with the release file after. The entry
  goes on before the mode. The readers of earlier builds of this change
  refuse a repaired receipt, and stay installed when the install stops
  later or rolls back to the bundle it was replacing. A folder or receipt
  already there in
  another form stops the install with nothing about it changed (no chown
  of something it did not make), the 45-byte receipt of earlier builds of
  this change included; a receipt already as it makes it is kept. Every
  reader accepts only mode 0600 and that one entry (allow, read alone, the
  user's uid, not inherited, no flags): the app through acl(3), the
  scripts and the root command through `ls -le` and `id -u`, which cannot
  see the rights and flags ls does not print for a file or an entry it
  cannot read. The two are not equivalent: a receipt with such a right or
  flag passes the scripts and the root command, and the app refuses it.
  The app also refuses the receipt when an acl(3) call on the list fails
  or gives an answer acl(3) does not document
  (`SleepOffReceipts.accessEntries`). Beside
  it, under the receipt's lock, install.sh writes `<uid>.released`
  through `sudo -n install`: the user's own file, 0600, 42 bytes, the
  receipt's nonce and `free`. A `held` claim on an existing receipt is
  kept. Every Insomnia folder of the user (`INSOMNIA_HOME`) shares both
  files. Start refuses with nothing written, asking for install.sh again,
  while `SleepOffReceipts.live.identity()` fails (missing, or not as
  above), and journals that identity ("device:inode") in the attempt.

  Not closed (the round 14 P1 is narrowed, not removed). pmset has no
  compare-and-set and one `SleepDisabled` value with no owner, so no read
  proves anything a moment later and a 1 written over a 1 leaves no
  trace. A `SleepDisabled 1` another tool sets between the root command's
  second read and its `disablesleep 1` (the last clock check and the time
  pmset takes to start) is taken for Insomnia's own and set to 0 by the
  end. One set while the `writing` line is written stops the command at
  the second read and stays, except when its `refused` line cannot be
  written and the exit 6 never reaches the app (a signal, the time limit,
  a crash), or reaches it but the app cannot journal its rollback before
  it quits or crashes or backstop.sh or uninstall.sh settles the start:
  the receipt then still shows `writing`, and that settlement sets that 1
  to 0. While the app that got the exit 6 runs, its own settlements of
  that start keep the exit 6 as their verdict. One set after the second
  read is set to 0 by that
  start's undo when the start then fails, even when the command stopped
  before its write. One set while a dialog is up is also set to 0 once
  `expires` has passed when the receipt shows nothing (missing, replaced,
  unreadable, a changed folder). A receipt that stays locked decides
  nothing at any time, and the sleep undo waits for it (section 8). A
  settlement that cannot be journaled keeps the attempt and runs the
  restore only when the receipt showed something else than a never-write
  or an earlier restore is owed.
  The receipt is flushed with `F_FULLFSYNC`, which Apple's fcntl(2)
  describes as a request some drives ignore: on such a drive a power loss
  can bring it back older while pmset's 1 survives, and that 1 is then
  reported as someone else's. A process running as the user can rewrite
  state.json, the attempt included, and the release file, or swap the
  marker while a command holds it. A settled start's nonce written into a
  new marker turns nothing off: a start whose receipt still holds the
  predecessor is settled before `expires` only when its dialog ended on
  its own, and every command for it refuses from `expires` on
  (SECURITY.md). While the journal claims a 1, another
  tool's 1 cannot be told from it, and a refused start leaves it with its
  restore still owed. sudo answers for the moment it is asked: a rule
  removed later, a sudo.conf or PAM file changed later, or other groups
  for the user when the app or the backstop runs sudo can still make a
  restore fail, and the backstop keeps the entry and retries. Any sudo
  but 1.9.17p2, a sudo.conf, PAM session lines other than macOS's own,
  Defaults bound to a Runas user or a command, Defaults for the user, the
  host or everyone outside the list, `listpw=always` and a later rule for
  the restore, even a passwordless one, refuse every Start, and rerunning
  install.sh changes none of them.

  A session never starts unless the backstop is armed, and a start is
  refused while a `pending-start` from an earlier start cannot be
  removed or an earlier start's `sleepOffAttempt` is still journaled. The
  start journals `sleepDisabledByUs` together with `sleepOffAttempt`
  (nonce, `owedBefore`, receipt identity, predecessor, `deadline` =
  `endsAt` in whole seconds, `expires`) before its claim and
  session.json, then writes the marker and journals its identity
  (`marker`) and `expires` before the dialog. If the dialog is cancelled,
  osascript cannot be launched, or the root command refuses (its exit 3
  to 8, or lockf's 69 or 75, which osascript ends its error line
  with: `AdministratorPromptError.restoreNeedsPassword` and `.refused`),
  the command left no change of its own for an undo to reverse: put
  session.json and the journal back exactly as they were read, give the
  claim back, run no pmset (a `SleepDisabled` set by another tool, even
  while the dialog was up, stays), and surface the error. If the password
  is wrong, the dialog times out, pmset fails, or the command ends with
  any other status, the start deletes `pending-start` under its lock and
  reads the receipt under the receipt's lock
  (`SleepOffReceipts.verdict`). No command for this start turned sleep
  off (`neverWrote`) only when the receipt passes the checks, is the file
  it journaled, and holds this start's nonce with `refused`, another
  start's line that names the same predecessor, or the predecessor itself
  once no command can still write: the dialog ended on its own
  (`AdministratorPromptError.dialogOver`: a cancel, a launch failure, a
  wrong password, a refusal or another osascript failure, but not a
  timeout, a signal or `stillRunning`) or `expires` has passed. It then
  rolls back as for a refusal, with no pmset. This start's `writing` and
  a later start's line that names another predecessor (`mayHaveWritten`)
  remove the attempt and undo from the journal like an end, delete the
  session file and surface the error. So does a receipt that is missing,
  replaced, unreadable or unsafe once `expires` has passed. Before then it
  decides nothing (`undecided`), and neither does the predecessor after a
  dialog that may still be answered, nor, at any time, a receipt that
  stays locked or whose lock fails. When `expires` is at most 15 s away
  the start waits for it and reads the receipt again; otherwise it keeps
  the attempt and its claim, refuses Starts, holds the sleep undo whatever
  an earlier session owes (a command for the start may still be in pmset)
  while the rest of the end runs, and the next transaction after `expires`
  that can lock the receipt settles it (section 8). The start
  deletes `pending-start` on every outcome before it lets go of the
  recovery lock. A successful start deletes the marker, then journals the
  attempt as settled, gives the claim back and removes the attempt. The
  wait is bounded only for the
  dialog: if its process has not finished 3 s after the SIGTERM, Insomnia
  kills nothing and deletes the marker under its lock. Once that
  succeeds the dialog's command can no longer pass its nonce check, so
  the start is settled from the receipt as above (with the short wait for
  `expires`) and the recovery lock released; the process is watched on
  its own, and the menu line names its pid until osascript exits and goes
  when the whole prompt has. While the dialog's root command holds the
  marker's lock (anywhere from its nonce check to its exit, a hung sudo
  query included), or the marker cannot be deleted, Insomnia instead
  keeps session.json, the journal entry and the recovery lock until the
  prompt exits, with no time limit, and settles from the receipt then;
  starts, ends and the agent wait behind it, the same rule as a `sudo
  pmset` that will not stop. Either way a notification and the menu line
  name the pid while osascript runs.
  The journal and backstop always exist before sleep is disabled, so a
  crash while the dialog is up leaves recovery the journal entry and the
  attempt to settle (section 8). Only an explicit
  Start reaches the dialog; there is no auto-start, URL scheme or scheduled
  start, and launch at login only reconciles.
- Session end (timer, End now, Quit, battery floor, thermal critical):
  `sudo pmset -a disablesleep 0`, undo every RuntimeState entry, delete
  session, notify.
- Quitting Insomnia always ends the session. There is no "keep awake after quit".

### 2. Sleep guard and root access

- `install.sh` writes `/etc/sudoers.d/insomnia` allowing the user to run,
  without a password, exactly:
  - `/usr/bin/pmset -a disablesleep 0`
  - `/usr/bin/pmset -b lowpowermode 1`
  - `/usr/bin/pmset -b lowpowermode 0`
- `/usr/bin/pmset -a disablesleep 1` is deliberately absent. With a
  passwordless line, any process running as the user could keep the Mac
  awake, unjournaled, with Insomnia not running. Turning sleep off goes
  through the administrator password dialog instead
  (`AdministratorPrompt.swift`).
- Turning sleep back on and the Low Power Mode floor stay passwordless so the
  app, `backstop.sh` and `uninstall.sh` can recover unattended: ending a
  stuck or crashed session must never need a password.
- `install.sh` also makes `/private/var/db/com.kgarg.insomnia` and the
  user's receipt in it, root's, and the user's own `<uid>.released`
  beside it, under the same sudo (section 1 and the receipt invariant in
  section 8). `uninstall.sh` removes both, then the folder once it is
  empty, after the same checks, only under the receipt's lock and only
  while the release file shows the receipt's own nonce `free`. It stops
  before removing anything at a folder or file that is not as install.sh
  makes it or cannot be read, and at one of the two files without the
  other. It asks for the password once with `sudo -v`, stops there when
  `sudo -n -v` shows sudo kept no credential, and runs every root command
  through `sudo -n` with its 30 s call limit under the recovery lock and
  the receipt's lock. A call that fails, stops on SIGTERM at the limit or
  is still running stops it there, and a sudo still running keeps both
  locks until it exits. install.sh refuses, changing nothing, at a folder
  or file that is not as it makes it, apart from the repair of an earlier
  receipt (section 1). No passwordless line covers the receipt.
- `install.sh` never writes `disablesleep 1`, on any path. When
  `session.json` holds a future deadline it first says the upgrade will end
  the session and, in a terminal, asks to continue. It asks for the password
  (`sudo -v`) before anything else, so a cancelled or failed password
  changes nothing and a running session keeps going. Then it asks a running
  app to quit and stops with nothing changed, the sudoers file included, if
  the app is still running after 15 s, and asks for the password once more
  if sudo's cached credential expired during the quit. It assembles the
  new bundle with `backstop.sh` sealed inside, then takes the recovery
  lock, checks that the app was not opened again meanwhile, and writes the
  three-line rule with `sudo -n` (`visudo -cf`, then `install`). It then
  checks that `sudo -k -n -l` lists the three commands without a password
  and stops if not. That catches a rule sudo does not read, but a listing
  is not proof that the restore runs: it passes once any of the user's
  rules is passwordless. The root command's `sudo -k -n -ll` at every
  Start (section 1) reads the rule that decides the restore. The installer runs no pmset. Only after the listing
  does it replace the bundle. A build older than this rule
  starts sessions with `sudo -n pmset -a disablesleep 1`, so any stop between
  the rule and the new bundle leaves that build unable to start a session;
  the installer says so and prints the rerun command. A successful install
  writes the file once.
- Nothing else runs as root.

### 3. Lid observer

- IOKit interest notification on `IOPMrootDomain` for `AppleClamshellState`.
  Insomnia sleeps in its run loop; the kernel wakes it on change. Zero cost
  between events.
- 2-second debounce to ignore flapping.
- Lid close and open each run a fixed, reversible action list (below).
- Lid events do nothing when no session is active.
- Each lid event is numbered as it arrives, before its actions queue behind
  earlier ones. An open makes every earlier close stale. A close still
  queued does nothing when its turn comes. A close waiting on a Docker probe
  stops waiting at once, leaves Docker running, takes Docker's entries out
  of the journal and signals nothing more, so the open's undo runs without
  waiting for `docker ps`. The probe's late answer is logged and not used.

### 4. Lid-close actions (battery)

All actions are recorded in RuntimeState and reversed on lid open, session end,
Quit, or reconcile.

| action | on close | on open |
|---|---|---|
| Display (optional, default on) | save brightness, set it to 0, request display sleep (best effort) | wake the display, restore the saved brightness |
| Keyboard backlight (optional, same toggle) | save brightness, set it to 0 | restore the saved brightness |
| Freeze scope | `SIGSTOP` every process whose responsible app is in the freeze scope (rules below) | `SIGCONT` the recorded pids only |
| Docker rule (default off) | if Docker Desktop is running and `docker ps -q` is empty, journal its tree, ask `docker ps -q` once more right before the SIGSTOP and freeze it only on a second clean empty answer; busy, a failed probe, a timeout, a lid open or a session end at either point leaves it running | resume |
| Mute (optional, default on) | journal the default output's UID, name, volume and mute state as its own entry, unless that device already has one, then mute that device; another device's entry never stops it | restore each entry on its own device, never on another output, and clear only that entry; a device the user unmuted meanwhile is left as it is; a device that is not connected keeps its entry (see below) |
| Low Power Mode | on (optional, default on) | off unless a battery or thermal floor still wants it |
| Countdown redraw | stop timer | restart timer |

The display and keyboard rows go through private frameworks with no ABI
contract: the DisplayServices C functions and CoreBrightness's
`KeyboardBrightnessClient`. Two guards run once per launch, before the
first call. The DisplayServices functions are called only on a macOS major
version they were measured on (26, `DisplayPower.measuredDisplayServicesMajors`);
a C symbol carries no type information, so on any other major the display
is left alone until someone measures again. The `KeyboardBrightnessClient`
methods are read through the Objective-C runtime and compared with the type
encodings measured on macOS 26 (`DisplayPower.measuredKeyboardClientEncodings`,
stack offsets removed); a missing required method or a changed encoding
refuses the keyboard backlight before anything is instantiated. A refused
device is skipped at lid close with a log line, nothing is journaled for
it, and Settings shows the reason under the darken toggle. With nothing
journaled for either device the close does not request display sleep,
since lid open and reconcile wake the display only for a journaled
brightness, as section 4 describes.

A brightness journaled before an update that the guard now refuses is not
written on open or reconcile, and it is not dropped either: an entry is
cleared only after its undo. It stays in the journal with
`displayRestoreRefused` or `keyboardRestoreRefused` set. One error names
each such device with its saved level, says it could not be restored on
this macOS build, and says to set the level with the brightness keys or
Control Center; Settings also shows each saved level under the darken
toggle. That error goes into one report with every other failure of the
same undo, such as a failed resume, audio restore or write on the other
device, since it comes up at every lid open. A flagged entry is not dirty
for backstop.sh or uninstall.sh, nor for the app while the guard refuses
its device. Nothing on that build can restore it, and counting it would
post "Restore incomplete" at every end and launch, fail the backstop every
minute, and stop uninstall for good. It also does not hold back a new
session or Quit. The app tries again at every lid open during a session,
at every end, and at every launch, with or without a session. On a build
or macOS where the guard allows the call, it reads the device first. Only
a reading taken with the lid known to be open, and that macOS is not
holding down, counts. A closed lid leaves the device at 0 or turned off,
and a write would light what the close keeps dark, so an end or a launch
under a closed lid reads nothing and leaves the entry waiting. A display
asleep reads its idle-dim value, and a keyboard backlight suppressed after
the wake, or idle-dimmed, reads 0 at any level. Such a reading decides
nothing, and neither does a read that fails or a keyboard that reads as
absent. The entry then stays as it is. The app reads it again every 3 s,
20 times, and then every minute for as long as it waits and the app runs,
since outside a session nothing else acts on a lid open. While the lid is
not known to be open it reads nothing, and the 3 s reads start again once
it is. A busy recovery lock skips one read, not the rest. An end does not
count a waiting entry as not restored, since nothing failed. The close
left the device at 0, so a reading above 0 is a level set since, as the
error asked: the darkening is already undone, and the entry is cleared
without a write rather than overwrite that level. A display reading above
0 taken while Insomnia's own Low Power Mode is on is the mode's rescaled
value and not that level, and once the mode is off the panel comes back
over a time nobody has measured. So no display reading above 0 taken
under the mode, or after it in the same boot of the Mac, decides the
entry: it would become the sample a later close journals. A relaunch is
no sign that the panel is back, so the journal records the entry as one
the mode was on over (`keptDisplayUnderLowPower`, with the boot session),
and a relaunch reads it with the same doubt. The entry waits for a launch
after a restart; until then it stays flagged, the panel is read again
every minute, and a lid close leaves it lit and only asks it to sleep
(below). That a restart ends the mode's rescale is assumed, not measured.
The record is about that entry alone: settled, replaced or unflagged, it
is dropped, one with no boot session holds until the next restart, and a
journal written before the record existed carries no doubt. While the
journal still claims the mode (`lowPowerSetByUs`), the record keeps the
boot it was written in, so a launch after a restart can tell that the
claim is from before it. Such a claim says nothing about the mode in this
boot, and neither does a read of the mode. Before its `lowpowermode 0` the
app reads the mode (`pmset -g custom`, the battery setting the claim is
about) for the log only. On, the switch-off ends the mode in this boot.
Off, the user or another tool may have switched it off a moment before,
with the panel still on its way back. Either way, and when the mode cannot
be read, the switch-off counts as the mode's end in this boot: the record
is written for this boot and the entry waits for the next restart, as
above. That holds for every route that switches such a claim off: an end,
a launch, the menu or a floor, and the check after a power command. It
also holds when state.json refuses the clear, in this process and in a
relaunch in the same boot. The cost falls on a mode that went off long
before the launch, which no reading tells apart: until a launch after the
next restart the entry stays in state.json, the display is not sampled,
and a close leaves it lit and only asks it to sleep. The level the user
set is never written over. A claim with no record, a
record with no boot or an empty one, or a launch that cannot read its own
boot is taken as this boot's, so the entry waits, at the cost of one more
restart. backstop.sh, before its own `lowpowermode 0`, gives a record of
another boot, or with none, its own boot (empty if it cannot read it),
after a restart or not, and publishes that journal on its own first: the
mode may have been on in that boot until then, before Insomnia launched in
it. A launch in that boot then reads the entry with the same doubt and
waits for the next restart, even when the mode was already off before the
agent's switch-off. The record has that boot before the mode goes off, so
a command that fails, or a journal of the undo that cannot be published
after it, leaves the claim next to a record of this boot, which a launch
reads as its own mode on in this boot, with the same doubt. If the journal
with the boot cannot be published, the agent leaves the mode on and keeps
its entry for the retry: switched off next to a record of an earlier boot,
the panel on its way back could be taken for the user's level. A journal
with no record has nothing to give a boot, so one written before the
record existed still carries no doubt. A display still at 0 under or after the
mode gets the saved value, written once more after the mode as for any
restore under it, unless a reading of that entry above 0, with the lid
known open and the panel awake, showed the darkening undone. That reading
is journaled (`keptDisplayReadLit`), so it holds through relaunches and
restarts, which do not darken the panel again. A 0 read after it may be a
level the user set, or one macOS still holds the panel at: auto-brightness
can pull the panel down to 0 under a closing lid, and the panel can still
read that 0 once the lid is open again, for a time nobody has measured. No
reading of 0 tells the two apart, however late it comes, so the saved
value is not written and the entry is not cleared. It stays flagged, the
display sample stays held, and the app reads the panel again every 3 s,
20 times, then every minute, through relaunches and restarts, until it
reads above 0. A 0 the user set stays as set until then. A reading above
0 with no doubt above left is the level set since, and the entry is
cleared without a write. A lid close with a sample of 0, or 0 as the value
owed after the mode, journals that 0 in place of the kept value. A current
read of 0 at the close is no such level, since it may be the closing
lid's. The close leaves the entry flagged and the panel as it is, and only
asks it to sleep. A reading at a lid close, under the closing lid or of a panel
asleep, shows no such thing, and neither does a reading of an earlier
entry: the record goes with its entry, as the record of the mode does. If
state.json refuses the record, this process holds it and the next write
records it. An end does not let Quit go before then: "Restore incomplete"
says Insomnia retries in 30 s and not to quit until state.json can be
written, and Quit waits, as for a failed restore whose flag is owed. A
crash, a forced quit or a lost disk before the record lands loses it, and
the next launch writes the saved value over a 0, as before any reading.
If state.json cannot
take that clear, the entry still counts as done in this process. The clear
is owed: it goes into the journal ahead of any later write, and at the
start of every lid close, lid open, end and launch, so none of them works
from the old entry. A lid close then journals the level the device reads,
not the old saved one. The app also retries the clear at the same pace,
and reads and writes nothing for it, so a level the user lowers to 0
meanwhile stays at 0. Quit waits for that clear: a launch after the quit
would read the entry again, and would write the saved value over a 0 the
user set since. "Restore incomplete" says Insomnia retries in 30 s and not
to quit until state.json can be written, and Start is refused until the
end goes through. A crash, a forced quit or a lost disk before the clear
lands leaves the entry to the next launch, which reads the device again.
A device still at 0 there gets the saved value and both keys are cleared. A failed write there clears the
flag, and the entry is retried like any failed restore. If the flag cannot
be cleared either, the disk still shows a flagged entry, which backstop.sh
and uninstall.sh pass over, so the app keeps the end itself. "Restore
incomplete" says Insomnia retries in 30 s, the app retries the write and
the owed flag together, and Quit waits until one of them lands. A write
that lands while state.json still refuses the clear settles the entry in
this process, with only the clear owed, and Quit waits for that clear as
above. A launch or
re-read with no session whose write fails is ended as for a dirty journal,
so the agent is armed for it, or the app keeps it while the flag is still
owed. A write whose clear is owed is done all the same: the second write
2 s later still goes out, and a display written under Insomnia's Low Power
Mode still owes its write after the mode, as the clear would have
journaled. A lid close that can read the device clears the flag too: it
keeps the earlier saved value while the device reads 0, and saves the new
level when it reads above 0. For the display that level must be trusted:
the last sample, the value owed after the mode, or a current read taken
with the panel awake and Insomnia's Low Power Mode not on at any point in
the run, nor over the entry since the Mac last started. Without one, the close leaves the entry flagged and the panel as
it is. A rescaled, dimmed or asleep read is not the user's level, and the
saved value may not be either, since the user may have set one by hand.
A panel darkened to 0 would read at the open as the darkening never
undone and get the saved value, so the close only asks the display to
sleep, which macOS ignores while any process holds a display assertion;
the panel then stays lit under the closed lid until the open, which reads
the entry again as above. A close whose journal write fails
darkens nothing and asks the display to sleep only for an entry this
process has not settled. Uninstall goes ahead past a flagged entry, prints
the saved level, and keeps state.json, even with `--purge`, so a later
install that can make the call restores it.

The guards narrow the risk of calling a private function whose shape
changed; they do not replace the hardware rows in
docs/release-validation.md.
An output device that is not connected when its entry is restored keeps the
entry, and the restore of everything else goes on. Each restore decides
again whether a device is connected: only a device CoreAudio reports as not
connected on that try counts as away. An away device does not hold up the
end of a session: End and Quit restore sleep and the rest, the end
notification names each device that is still muted, and the menu shows a
line for each with a "Stop waiting for <device>" item, which drops that
entry and leaves the device as it is. The item drops nothing if, when it
runs, the device reads as connected or the entry is a later lid close's
save rather than the one the menu showed. Each save has an ID of its own
(`saveID`, drawn by the lid close that writes the entry), and the item
compares it with the journal on disk under the lock, so a later save with
the same values, written by this or another copy of the app, is not
dropped. An entry written before entries had an ID has none and is
compared by its values. While Insomnia runs, a device that
connects again gets its volume back at once (a CoreAudio device-list
listener), or at the next lid open if a session is running with the lid
closed. Each device change reads the journal on disk under the lock, so a
copy of the app with nothing saved in memory also restores a save another
copy wrote. Before the launch reconcile has taken a session over, a session.json
that has not expired, or cannot be read, counts as a running session for
this. A later launch restores every connected device at reconcile.

A restore that fails on a connected device, or a cleared entry that cannot
be written, is reported and the entry stays. It makes the end incomplete,
as any failed restore does. The recovery agent keeps these entries but
cannot restore CoreAudio settings, so the incomplete-restore notification
says Insomnia tries again itself. That retry runs in process after 30 s,
reads the journal again and checks the lid again. A device change that
could not run at all (the recovery lock was busy, a `sudo pmset` left
running still held it, or state.json did not decode) is retried the same
way. The retry stops after 10 tries in a row; the next device change, lid
open, end or launch tries again. The menu line that a refused device change
or a failed restore put up goes once a later restore leaves nothing to
retry, unless a newer failure has taken its place.

A session that starts, or that reconcile resumes at launch, while the lid
reads closed starts with the countdown redraw stopped: the lid observer
reports changes only, so no close event arrives for it. The next lid open
restarts the redraw.
Freeze scope rules:

- Two scopes. The explicit freeze list: apps the user picks by bundle id from
  a list of currently running apps; always frozen. The automatic scope
  (`freezeAllApps`, default off, also for a config.json without the key):
  every running app with a regular activation policy (a Dock app) and a
  bundle id, so that only agents keep running while the lid is closed.
  Menu-bar (accessory) and background apps are never picked up
  automatically; they can be put on the explicit list by hand. With the
  toggle off the explicit list is the whole scope.
- Hard denylist that can never be frozen, from either scope: `com.apple.*`,
  Insomnia itself, Docker Desktop (handled by the Docker rule), and any bundle
  id in the agent list (below).
- Built-in protected set (`FreezePlanner.builtInProtected`, checked through
  `isBuiltInProtected`): editors and agent hosts (VS Code and Insiders,
  VSCodium, Cursor, Windsurf, Zed, Antigravity and Antigravity IDE, Android
  Studio, Sublime Text, Nova, Claude, ChatGPT/Codex, Conductor, T3 Code),
  every JetBrains IDE by the `com.jetbrains.` prefix
  (`builtInProtectedPrefixes`), terminals (Warp, Ghostty, iTerm, Alacritty,
  kitty, WezTerm, Tabby, Hyper), browsers (Arc, Chrome, Chromium, Edge, Brave,
  Vivaldi, Opera, Firefox with its Developer and Nightly editions, Zen),
  Tailscale, LM Studio, Ollama, Docker Desktop's Electron front end,
  1Password, Bitwarden, Postgres.app and OrbStack, and meeting, recording
  and dictation apps (`meetingApps`): Zoom, Microsoft Teams (new and
  classic), Webex, the older Webex Meetings app with its meeting window and
  plugin agent, Wispr Flow, Granola, Otter, OBS and Loom. Their helper apps
  are matched by prefix: each of those ids followed by a dot, plus `us.zoom.`
  and `com.cisco.webex.` (`meetingAppPrefixes`). Helpers an app starts are
  its child processes and are left out with it. FaceTime is
  `com.apple.FaceTime`, already on the hard denylist. Every id is verified
  against an installed copy, the Homebrew cask metadata or the page named in
  the comment next to it. The automatic scope leaves them alone even when they
  are not on the agent list. Code level and not persisted: an existing
  config.json already carries its own agent list, so new agent-list defaults
  never reach it. An explicit freeze-list entry overrides this set; the hard
  denylist does not.
- Order: the explicit list first, in its own order, then the automatic
  candidates by app name, de-duplicated. One info log line names the
  automatic candidates on each close.
- Each app's pids are journaled before the SIGSTOP, without identity; if
  that write fails the app is left running and the status menu shows the
  failure. Recovery never signals an entry without identity. After the
  SIGSTOP one write gives the pids the kernel stopped their identity (start
  time to the microsecond, boot session) and drops the pids it would not
  stop, so a process somebody else had stopped is never claimed. If that
  write fails, the app sends SIGCONT to each pid it just stopped whose
  identity still matches, stopped yet or not (SIGCONT also cancels a stop
  that is still pending), then removes that app's entries and any Docker
  flag the freeze set, keeping only pids it could not resume. The status
  menu shows the failure and counts only those pids as frozen, even while
  the disk refuses the removal; the next journal write that succeeds
  carries it. If the app dies before the confirming write, the stopped
  pids stay journaled without identity and are reported for a person to
  check.
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
is best effort. It is made only when a display or keyboard brightness is
journaled, because the wake that undoes it on open, or on reconcile after
a relaunch, runs only for such an entry. Display brightness 0 does not
switch the keyboard backlight off; it is set separately. Both values are journaled before they are changed
and restored on open, session end, Quit, or reconcile with the lid open; the
backstop keeps the entries and only the app restores them (private
frameworks). An end that could not restore one says so in its
incomplete-restore notification, without promising the recovery agent's
retry: a later session's end or the next launch tries again. What is journaled is the user's value, not whatever the device
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
restore. The hold follows the journal on disk: after a `lowpowermode 0`
that exited 0 with the ownership clear refused, the panel may still be on
its way back from the mode, so the display sample, by then the level
written after the mode, stays held until the clear lands, while the
keyboard is still sampled. Each device's sample is also held while the journal has a saved
brightness for it, since the device then reads the 0 a close left or a
level not yet decided. Each level the app writes from the journal, or
finds set since in place of a kept value, becomes that device's sample,
so a close soon after a restore that came late, from the re-read of a
kept value or after the mode, journals the restored level and not a 0
sampled before it. The keyboard journals the current
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
it writes nothing. If state.json refuses to clear the mode's ownership
after `lowpowermode 0` exits 0, the mode is off all the same: the clear is
owed, as for a kept brightness, the write after the mode goes at once, and
a later switch-off from the ownership still on disk compares nothing. If
state.json refuses to clear the owed write itself, written or dropped,
that clear is owed too, so no later journal write brings the value back. The
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
  browsers, VPN and local model runtimes, plus password managers, local
  databases and OrbStack, are protected from the automatic lid-close scope
  even on an install whose config.json predates these defaults and never
  lists them. Only the agent list can also turn App Nap off; only an
  explicit freeze-list entry overrides the built-in protection.
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
  uninstall makes under the recovery lock (`pgrep`, `launchctl`,
  `codesign`); a read that does not answer ends the check with the command
  to run by hand, and uninstall goes on. A call past its limit gets SIGTERM,
  then SIGKILL one to two seconds later. Each call keeps the lock until it has exited
  or been stopped, and a supervising process enforces the limit even if
  uninstall is killed while it waits, so its `launchctl bootout` is not
  still running when the app takes the lock and loads its agent.
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
  - The item asks for confirmation first (the browser is quit; its windows
    return only through its own session restore). The item carries the
    browser's bundle id and name from when the menu was built, and
    confirming hands those on, so a browser scan that replaces the list
    while the alert is up cannot change or drop the browser; one that has
    quit by then is reported as not running. The profile arguments are
    read before the quit, and unreadable arguments (including empty `ps`
    output) stop the relaunch before anything is quit. So does a main
    process that exits during the read, checked by `NSRunningApplication`
    and by the kernel's start time for the pid, since `ps` reads by pid and
    the pid may have gone to another process. A start time that cannot be
    read counts the same way: nothing confirms the pid is still the
    browser, so the arguments are not read and nothing is quit. The quit
    goes to the `NSRunningApplication` objects found before the read, never
    to a fresh lookup of their pids. After the quit request Insomnia waits up
    to 10 s, then reads the running list again: any instance still there
    means nothing is launched, and the notification says the browser may
    still quit later and then has to be opened by hand.
    After `open` returns 0 the running list is polled for up to 5 s; a
    browser not running by then is reported too. A session that ends during
    that wait cancels it at once and nothing is reported, since the user
    ended the session. The 10 s quit wait does not stop on a cancel, so a
    relaunch whose session ended during it reports nothing either when the
    wait is over. Only the newest relaunch of a browser reports, so one
    that a newer relaunch of the same browser overtook reports nothing
    either. Every other outcome short of a relaunch is a "Browser not
    relaunched" notification naming the browser, and the same text stays
    in the menu as a warning line, one per browser, until that browser's
    next relaunch or the next session start, because notifications can be
    off for Insomnia.
    Insomnia is the notification center's delegate and asks for banners
    while it is frontmost, as it is right after the confirmation; without
    that, macOS drops a notification from the frontmost app. The process
    side (`BrowserProcessControlling`) is injected so the tests quit
    nothing.
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
- The Keychain item is created with an access list naming only the saving
  build (`SecAccessCreate` with the running code as the sole trusted
  application; under ad-hoc signing that is the build's cdhash). Reads run
  with the process-wide Keychain prompt switch off
  (`SecKeychainSetUserInteractionAllowed`, put back after each call), since
  the per-query no-UI keys only govern the data protection keychain. An item
  the build may not read fails with `errSecAuthFailed` (another build's item,
  or a locked keychain; the file-based keychain cannot tell them apart), and
  a missing item with `errSecItemNotFound`. Either skips the join and sets
  a `HotspotPasswordReport`, the `HotspotPasswordProblem` and the SSID it
  was read for: a warning line in the right-click menu and a notice under
  the password field in Settings, both only while that SSID is the one
  configured, and one notification per outage and hotspot (re-armed on
  recovery, on stop and when the password is saved). Settings checks the
  notice again whenever the configured SSID changes. A save in
  Settings writes to the keychain that holds the item reads find, which
  need not be the default keychain (a new item goes to the default
  keychain). A locked keychain
  hides this build's items as well as another build's, so a save that
  finds the item unreadable first checks the keychain's lock state
  (`SecKeychainGetStatus`) and, if it is locked, unlocks it (the prompt)
  and starts over. An item the build can read already names it, so only
  the value changes, in place (`SecItemUpdate`). An item it still cannot
  read is another build's and needs a new access list, and the file-based
  keychain changes that only by replacing the item (an in-place update of
  `kSecAttrAccess` did not return when tried on a throwaway keychain): the
  new password is put beside the old item, in the same keychain, under
  service `insomnia-hotspot.replacing`; the old item is deleted; the new
  one is renamed to `insomnia-hotspot`. Reads use only `insomnia-hotspot`
  and never fall back to a `.replacing` item: which save left it, and
  whether that save finished, is not known, and one in another keychain
  on the search list can hold an older password. Until the delete, the
  password reads as unreadable, as before the save; after the rename, as
  the new one. A save that stops in between (a failed rename, a crash)
  leaves it reading as missing, and the user enters it again. A
  `.replacing` item the build can read, left by such a save, has its value
  changed in place by the next save; one it cannot read with the keychain
  unlocked is another build's and is deleted, then added again. A refused
  delete of the old item removes the `.replacing` item and keeps the old
  one. Clearing the password deletes both. Deleting another build's item, and unlocking the keychain
  for a save, need the prompt, which is allowed only there.
  `kSecAttrAccessible` is not set: the file-based keychain drops it, and
  the data protection keychain needs an access-group entitlement.
- Every keychain call the app makes, the failover's reads and the saves
  and clears in Settings, runs on one serial dispatch queue
  (`KeychainQueue`), never on the main actor. A save can wait on a
  keychain prompt for as long as the user leaves it open, and the battery
  floor, the deadline timer and End keep running meanwhile; one queue also
  keeps two calls from setting the process-wide prompt switch at once. The
  Save button reads "Saving…" until the keychain answers, then "Saved"
  only while the SSID and password fields hold what the save stored: the
  save uses the SSID that was in the field when it began, so an SSID typed
  during the wait has no password yet. A failed save's notice stays under
  the field even when the failover's report changed during the wait; the
  recheck that change started reads the keychain behind the save, and its
  answer is dropped. So is the answer of a load still running when a save
  or clear begins, so it cannot refill a field the user just cleared. A
  load fills the field only if the field was empty when it began and
  nobody has edited it since, not even by typing and deleting it again. A
  recheck that begins meanwhile (the report changed, or the SSID was
  edited) sets the notice instead of the load, but does not stop the fill.
- Work that waits on `KeychainQueue` checks again, once the wait is over,
  everything it acts on, and drops its answer if any of it changed. A
  load or recheck in Settings whose SSID was edited meanwhile is dropped,
  since its answer is about the old SSID's item, and the SSID configured
  now is read instead, so the field is not left empty with no notice.
  That read is a peek: the SSID a later save moves the password from
  stays the one the window loaded, as after any SSID edit. A save writes
  the item for the SSID configured when it began and removes the item of
  the SSID the window loaded, if that SSID was edited since, and returns
  both. It clears the failover's report and re-arms its notification
  unless the report is about the SSID configured when it answers and the
  save touched neither of that SSID's items. A save that stored for an
  SSID edited away meanwhile then checks the notice for the SSID
  configured now. A failover join whose read waited behind a
  save does nothing if the session has ended, Wi-Fi has come back, or the
  configured SSID has changed: no join and no warning, so the
  notification stays armed. After a recovery or stop it schedules no
  retry either; after an SSID change the retry stays, and the next tick
  reads the SSID configured then. Inside a save, the unlock prompt is
  followed by a fresh read of the item and its keychain.
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
  Like `insomnia.log`, the file is owner-only (0600) and is renamed to
  `handoffs.log.1` once it passes 1 MiB (`OwnerOnly.swift`). A log the user
  replaced with a symlink is never rotated, so the cap does not hold for it:
  the file it points to is the user's to manage.
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
- A password dialog turns sleep off only for the start that showed it,
  only while that start still holds the recovery lock, and only before
  that session's `endsAt`. The start writes a
  fresh nonce to `pending-start` before the dialog and deletes it before it
  releases the lock. Every other holder of the lock (any app transaction,
  reconcile at launch, `backstop.sh`, `uninstall.sh`) deletes it first,
  before it reads or clears the journal. The root command runs as `lockf
  -k -n <marker> /bin/sh -c ...`: it holds the marker's flock from before
  its nonce check until pmset exits, and every deleter takes that lock
  before it unlinks the file. A lock belongs to a file, and the unlink goes
  by path, so a deleter unlinks only while the path still names the file it
  locked (device and inode of the locked descriptor against `stat` of the
  path; the scripts open the marker on fd 8 and lock that descriptor). The
  marker therefore goes either before the
  check, which then fails, or after pmset, while the journal entry still
  covers it, so a dialog answered after its start was abandoned (crash or
  force-quit under the dialog, rollback, a newer start) cannot leave sleep
  off once the journal entry is gone. No dialog is shown unless the
  `backstop.sh` sealed in the bundle declares a version that deletes the
  marker.
- Root's receipt shows whether a start turned sleep off
  (`SleepOffReceipts`). `/private/var/db/com.kgarg.insomnia/<uid>` holds
  82 bytes, `<nonce> <predecessor> writing|refused` and a newline, and it
  and every folder up to / are root's with no group or other write bit
  and no allowing ACL, so nothing running as the user can write or
  replace any of them. Every Insomnia folder of the user shares it. The
  production reader trusts uid 0 alone; tests add their own uid only
  through `SleepOffReceipts(folder:owners:user:)` and patched copies of
  the scripts, never through anything a build reads at run time. The
  receipt is also the lock for every party that acts on a start. The root
  command takes an exclusive flock(2) on it (`lockf -s -t 10` on its open
  descriptor) before any other check and holds it until it and its pmset
  have exited. The app, `backstop.sh`, `install.sh` and `uninstall.sh`
  take the same lock through a read-only descriptor before a start claims
  the receipt, before they read it to settle a start, before install.sh
  writes the release file and before uninstall.sh removes it. A lock that
  stays busy or fails decides nothing. Beside the receipt,
  `<uid>.released` (the user's, 0600) holds `<nonce> free|held`. A start
  claims the receipt under its lock only while that file shows the
  receipt's nonce `free`, writes its own nonce `held`, and gives the claim
  back (the receipt's nonce, `free`) only once its settlement is
  journaled, so no start of another Insomnia folder can replace the line
  the claimed start's settlement reads. A claim nobody gives back (a
  folder deleted while its start is journaled, a damaged release file)
  refuses every Start of the user until the files are removed and
  install.sh runs again. The file is the user's, so it never shows that a
  start did not turn sleep off: a false line can only let a later start's
  line in, which names this start's nonce as its predecessor and shows
  nothing, or refuse every Start. The root command writes `<nonce>
  <predecessor> writing` (perl, `F_FULLFSYNC`, read back) only while the
  receipt begins with the predecessor, after its first read finds no
  `SleepDisabled 1` and before its second read, its last clock check and
  pmset, and `refused` when the second read, that check or the write
  fails. A start journals
  `sleepOffAttempt` (nonce, `owedBefore`, the receipt's identity, the
  predecessor, `deadline`, `expires`, and the marker's identity once
  written) with `sleepDisabledByUs` before its claim and before the
  dialog can run anything. Every reader reads the receipt only under its
  lock and after the marker is gone under the marker's lock: the start
  itself after a failure its status cannot vouch for, and the next holder
  of the recovery lock (the app's first transaction after a relaunch,
  `backstop.sh`, `uninstall.sh`) for an attempt still journaled, before
  it reads the session. Which marker file went decides nothing. The
  verdict is "never wrote" when the attempt has no marker (no dialog), or
  when the receipt passes every check, is the journaled file, and holds
  this start's nonce with `refused`, another start's line with the same
  predecessor, or the predecessor itself once the dialog ended on its own
  or `expires` has passed. This start's `writing` or a later start's line
  with another predecessor is "may have written", and so is a missing,
  replaced, unreadable or unsafe receipt once `expires` has passed. Before
  `expires` such a receipt, and the predecessor after a dialog that may
  still be answered, are "undecided", and so is a receipt that stays
  locked or whose lock fails, at any time. "May have written" undoes the
  start like an end, and a settlement keeps `sleepDisabledByUs`. "Never
  wrote" rolls the start back with no pmset, and a settlement puts
  `sleepDisabledByUs` back to `owedBefore`, so an earlier session's owed
  restore is never cleared. "Undecided" keeps the attempt and its claim:
  new Starts are refused in every Insomnia folder of the user, an
  unexpired session of that start is ended rather than resumed, and no
  pmset runs for sleep, whatever an earlier session owes, since `expires`
  only proves that no command for the start begins later (while the wall
  clock does not go back), not that one already past its last check has
  exited. The rest of the undo (Low Power Mode, processes, audio) runs. A
  receipt that stays locked is retried for as long as the lock is held,
  with no limit, so a root command that never exits leaves sleep as it is.
  A settlement removes session.json when its `endsAt` in whole
  seconds is the attempt's `deadline`, whatever the verdict: that session
  never began, so it is never resumed because a `SleepDisabled 1` someone
  else set reads as still off. Then, with the claim still held, it
  journals the decision: the attempt marked `settled`, and
  `sleepDisabledByUs` as above. Then it gives the claim back, then the
  journal drops the attempt (`finishSettlement`, `finish_settlement`). A
  record already `settled` is finished that way from its decision and
  never read against the receipt again, since a later start's line may
  follow once its claim is back. A step that fails before the decision is
  journaled (session.json not removed, the journal not published) keeps
  the attempt unsettled with the claim, so the next run reads the same
  line. One that fails after it (the claim not given back, the settled
  record not removed, the receipt's lock busy) keeps the settled record,
  which holds nothing back: the undo follows its decision, Starts stay
  refused, and every run tries again. A start that went through keeps its
  session; a relaunch resumes it (reconcile, step 2), and the menu says
  the start is still recorded and why. A crash leaves one of those
  journals. The messages say whether session.json was removed and whether
  the decision was journaled. When the receipt showed "never wrote" and no
  earlier restore is owed, or decided nothing, no pmset runs for sleep
  while the attempt waits: the app refuses
  Start and retries at every transaction, `backstop.sh` logs that sleep
  is left as it is, keeps the journal dirty and exits 1, and
  `uninstall.sh` stops with nothing else removed. Otherwise the app and
  `backstop.sh` run the restore and keep the attempt; `uninstall.sh` runs
  no pmset while an attempt stays unsettled or a settled one cannot be
  finished. A marker deleted with no attempt
  journaled (an older build's, or one a finished start could not delete)
  takes session.json with it when no session is in memory
  (`dropSessionOfUnrecordedMarker`, `drop_unrecorded_session`). If that
  removal fails, the app ends that session instead of resuming it, and
  `backstop.sh` undoes the journal as `--force` would and exits 1. Only
  install.sh, uninstall.sh and an authenticated Start's root command
  write the receipt. Each start rewrites it in place, so no record
  accumulates, and a new start's nonce is random and never the all-zero
  one.
- A transaction holds the recovery lock while a command it started may
  still change something. A stuck dialog whose marker this transaction
  deleted under the marker's lock can no longer change anything while the
  marker is not written again under this user and the clock is not set
  back, so it does not hold the lock. That holds only for the file the start wrote:
  `savePendingStart` returns its device and inode, and a marker found
  replaced (a copy could have been swapped in after the root command
  locked the original) or missing (it went without the lock) is not
  counted as voided, so the transaction waits for the dialog to exit.
  Deleters that did not write the marker (a transaction after a relaunch,
  `backstop.sh`, `uninstall.sh`) have no identity to compare, so a copy
  swapped in before their open while the root command holds the original
  would be deleted in its place. Only a process running as the user can
  make that swap, and it can already clear `sleepDisabledByUs` in
  `state.json` directly. The settlement still waits for the receipt's
  lock, which that command holds until its pmset exits, and then reads
  its line.
- `sleepDisabledByUs` is cleared only by a transaction that removed
  `pending-start` before it restored sleep. A marker that cannot be locked
  within its timeout or cannot be deleted leaves recovery incomplete: sleep
  is still restored, the entry stays, the app reports it (log, "Restore
  incomplete" notification, menu line) and refuses new starts, the agent
  exits 1, and every later run retries. A journal write that fails after
  sleep was restored is reported the same way, and the entry it could not
  clear is retried.
- Every change Insomnia makes is in RuntimeState before it is made, and is
  undone from RuntimeState, never from memory.

Reconcile runs at every Insomnia launch. Its transaction first deletes
`pending-start` under its lock and settles a `sleepOffAttempt` still
journaled (or finishes one already settled), or drops session.json beside
a marker no attempt accounts
for (the receipt invariant above). A session.json that is still there
and unexpired while an attempt stays journaled, or whose removal beside
such a marker failed, is ended (`performEnd(.startFailed)`), never
resumed, with one exception: a settled attempt whose claim could not be
given back or record removed, beside that start's own session with the
sleep entry still journaled, resumes the session in step 2 (`isSession`,
below). Then:

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
   a session either; `backstop.sh` checks the same keys and types. Nor is
   one whose extensions do not add up: an extension or their running sum
   that is not finite, or a first end (`endsAt` less their sum) outside
   the dates the store reads (`SessionMath.firstEnd`, checked by
   `Store.loadSession`). The app moves it aside the same way and restores
   the journal; no session it wrote has such a history. `backstop.sh` does
   not add the extensions and honors its end until the app has moved it
   (`uninstall.sh` ends any session either way). The app
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
   new path. If either rename fails the file stays and a start is refused
   while it is there. Every end then restores the journal and tries the
   rename again; while it fails the end is not finished, so quit is refused
   and the end is retried. The launch that kept the file runs that end
   itself when the journal holds any entry, saved output volumes alone
   included. A file that could not be read would be resumed
   if it became readable in place, and every later launch and the agent
   read either kind again. The messages say to remove it or move it out of
   the folder. `backstop.sh` tries the rename again on every run.
   An unreadable journal still refuses every transaction and leaves both
   files in place.
2. Session valid → establish the independent recovery agent, then read
   `pmset -g`. `SleepDisabled 1`: journal ownership if missing and resume
   observers; the guard is never re-applied, since that needs the
   administrator password and a relaunch has nobody at the keyboard.
   `SleepDisabled 0` (something turned sleep back on while Insomnia was not
   running): end the session with a notification, no prompt. If the lid is
   open, restore recorded lid-close actions. Arming, read or restoration
   errors must remain visible. Beside a settled attempt (above), only that
   start's own session gets here: it began at least `minimumDuration`
   before the attempt's `deadline`, and its first end falls in the second
   the deadline names, or, for each extension with a fraction of a second
   (one cut short at the maximum), up to a second earlier, since each save
   drops the end's fraction but keeps the extension's. The comparison uses
   Doubles only, so no value on disk can trap a conversion. Anything else
   beside that record ends, including an earlier session a failed start
   put back as it was before its claim could not be given back: an
   unwaived cost. The menu keeps the line that the start is still recorded
   (`recordedStartText`) while the session goes on, and Starts stay
   refused until a run gives the claim back and removes the record.
3. `pmset -g` reports `SleepDisabled 1` with no session and no journal
   entry → leave it. Step 1 has already undone a disable Insomnia journaled,
   so this one was set by something else (a hand-run `pmset`, another tool)
   and is not Insomnia's to undo. Log it, show it on the menu's warning line,
   and notify once per launch with `sudo pmset -a disablesleep 0`. Start is
   refused while it stays (section 2). A bit still journaled as ours after
   a failed restore is retried from the journal, not from this check.
   Nothing clears `SleepDisabled` without a journal entry, in the app or in
   the agent.

A reconcile refused for a busy lock or an unreadable journal changes
nothing and runs again after the retry delay until it goes through, unless
a start has made a session active or an end has been requested since. The
lock can stay busy for as long as a `sudo pmset` an earlier run left
running, and without the retry a session still live on disk would hold
sleep with no battery floor until its deadline. If `unfinished-command.json`
was on disk, that command has exited by the time the reconcile holds the
lock, so a session it resumes is checked against Low Power Mode as after a
command the app itself left running (below). The check stays owed when a
later attempt is refused for an unreadable journal, although that refusal
removes the record. A start that makes a session active before the retry
runs the check for that session instead. An end restores the mode from the
journal and owes no check.

Backstop, independent of the app:

- The agent reads the saved deadline; recurring recovery checks avoid replacing
  the loaded job for every extension and allow retries after a failure.
- The agent runs only the `backstop.sh` sealed in the signed bundle. Its
  command line verifies the bundle against the code requirement pinned in the
  plist (`codesign --verify --strict -R=...`; for an ad-hoc build, that
  build's cdhash) and execs the script when that passes; otherwise it logs
  one line and exits without running anything. No executable lives in a
  writable directory. The plist is a per-user file like any LaunchAgent; at
  the next arm the app rewrites a plist that does not match, and reloads a
  loaded job whose command line or run interval (the `arguments` and `run
  interval` that `launchctl print` lists) differs from the plist's.
- What the app pins is the requirement of the code it is running
  (SecCodeCopySelf), read after SecCodeCheckValidity confirmed the bundle on
  disk is that code, and the bundle must pass the agent's own check against
  it at every arm. Otherwise arm() fails with the reason: a loaded agent
  whose bundle no longer verifies is never reported as armed, and a bundle
  re-signed under the running app is never re-pinned. A `swift run` build
  outside any bundle pins the installed bundle from disk.
- install.sh replaces the bundle and the agent in one locked step: the new
  bundle is staged next to the app and swapped in only after `launchctl
  print` confirms the previous job is unloaded, then the new job is loaded.
  So any job loaded after the swap is this run's and pins the new bundle.
  When the new job cannot be loaded or its plist cannot be published,
  install.sh unloads any job that may be loaded, confirms that with print,
  and puts the previous bundle back; if the unload is not confirmed, the
  new bundle stays, because that job pins it. Every bundle rename is checked
  (`mv`, refused when the destination exists): when one of the swap or its
  undo fails, the previous bundle goes back and its job is loaded again as
  after a failed load, and when the previous bundle cannot go back, no
  bundle is deleted, no job is loaded against an empty app path, and the
  message prints the `mv` and `launchctl bootstrap` that restore the pair.
  The same holds for the renames of the repair below. A rerun after an interrupted
  or failed swap keeps the bundle the plist on disk pins. It runs its
  forced recovery first, with the loaded job and the bundles as the earlier
  run left them, and stops there if recovery fails. Only then does it
  unload and confirm any loaded job, move a bundle and load the plist on
  disk again; it stops when print does not confirm the unload or that
  reload. A loaded job is never left pinning a bundle that was moved away,
  and no step after a failed bootstrap counts on a loaded job. Before
  recovery the run only puts a set-aside bundle back when nothing is at the
  app's path, and removes staging directories whose owning install is gone
  (matched by the exact name install.sh gives them). The sudoers rule is
  written and listed under the lock before any of this (section 2), so an
  uninstall.sh that took the lock first and removed the rule cannot leave
  the new app without it. Under the lock every `sudo`, `pgrep`, `launchctl`
  and `codesign --verify` call has a 30 s limit. A supervising process enforces it, even if the
  installer is killed while it waits, and the call keeps fd 9, so the lock
  is held until the call has exited or been stopped: no `launchctl bootout`
  or `bootstrap` it started is still running once the lock is released. A call past the
  limit gets SIGTERM, then SIGKILL one to two seconds later; `sudo` only ever gets
  SIGTERM, and one that ignores it keeps the lock until it ends. The run
  names no pid for it: by the time anyone acted on one, it could name
  another process. A `sudo` call or `pgrep` that does not answer stops the
  run, which releases the lock so the app and the agent can recover. A `launchctl print` that does not answer counts as unknown, never
  as unloaded. A `codesign --verify` that does not answer leaves it unknown
  which bundle the plist on disk pins, so the run stops and moves neither
  bundle. uninstall.sh runs the
  bundle's sealed backstop.sh only after `codesign --verify --strict`
  passes on the bundle (a bounded call, like its other calls under the
  lock). Once recovery is confirmed and print confirms the agent unloaded,
  it removes the bundle and install.sh's leftovers beside it, by their exact
  names: `.Insomnia.app.previous`, and `.Insomnia.app.staging.<pid>.<six
  letters and digits>` directories whose run `kill -0` reports gone (a live
  run's stays). Symlinks and other names are left. With the agent plist go
  the candidate plists install.sh and the app stage it from
  (`com.insomnia.backstop.candidate-*` in `.com.insomnia.backstop.staging`
  and, from older builds, in the LaunchAgents directory).
- App and script transactions must coordinate through a shared lock. Failure
  to acquire it must not permit an unprotected journal write or side effect.
- A `sudo pmset` is sent SIGTERM at its timeout (20 s in the app, 30 s in the
  agent), never SIGKILL: a killed sudo can orphan a root pmset that still
  changes power state later, outside any transaction. One still running 3 s
  after SIGTERM stops the transaction where it is, in the app as in the
  agent's `run_bounded`: nothing else is undone, the journal keeps every
  entry it had, and the recovery lock stays held until the command exits.
  In the app the command holds the lock itself, with a descriptor on the
  lock file as its stdin, so a crash or force quit of the app does not
  free the lock while the command runs; the agent's supervising subshell
  keeps it the same way. That subshell, not the script that started it,
  enforces the limit and is the only process that signals the command. It
  measures the limit and the grace on bash's `SECONDS` clock, so slow polls
  on a loaded machine do not stretch them, and it sends SIGTERM by jobspec,
  which reaches the command or, once the command has been reaped, nothing:
  never a process that reused its pid. The pid the script logs is never
  signaled. The subshell ignores SIGTERM and SIGHUP, so neither the end of
  the agent's run nor launchd's signal to what is left of the job's process
  group frees the lock while the command runs; a SIGKILL to the subshell
  would. The app runs no `sudo pmset` outside a
  transaction. Every one goes through `PmsetSleepGuard.sudoPmset`,
  including a check that runs a sudoers command only to see whether it
  passes. It reports the pid with the `sudo kill` command, in a menu line
  of its own that the exit removes, and refuses to quit or start a
  session until then. It also records the command in
  `unfinished-command.json`, with the start time and boot session read
  from the process table when the command was left running. The exit
  removes the record, and so does the next transaction that takes the
  lock. A transaction refused for a busy lock names the recorded command.
  It gives the pid and `sudo kill` only while the live pid still has that
  start time and boot session, and the first such refusal for a pid also
  notifies; otherwise it says the command has exited, or that the pid
  cannot be confirmed, and names no process to stop. An end, lid close or
  lid open refused meanwhile is recorded at the refusal. An undo
  (`disablesleep 0`, `lowpowermode 0`) that exits 0 is confirmed: its
  entry is cleared under the lock before the lock is released, and a
  display write owed for the end of the mode is done then. If the journal
  cannot be read or written then, the entry stays, the undo runs again,
  and the menu says so. For `lowpowermode 0` with a journal that cannot be
  written, the clear is also owed, so the app takes the mode as off and
  does the display write at once. With a journal that cannot be read and
  a display write owed after the mode, by the journal last read, the clear
  is owed the same way and the write waits for the first transaction that
  reads the journal again; it is made only if that journal, with the owed
  edits, still owes the same value with the mode not Insomnia's. The
  unreadable file is not written. Any other exit confirms nothing. When the command
  exits the app retries a pending end.
  Otherwise it reads Low Power Mode under the lock. A mode that reads on
  stays journaled as Insomnia's. A mode that reads off is switched off
  once more with the app's own `lowpowermode 0`, and the ownership is
  cleared only when that exits 0. A claim from before the Mac last started
  that it clears this way counts as the mode's end in this boot, as for
  any switch-off (section 4). A display write owed for the end of the
  mode is kept through the check and done then: with the mode already off,
  powerd's rescale of the panel cannot be told apart from a user's change,
  so the panel is compared with the owed value only before a switch-off,
  while the mode is still on. Then the app replays
  a refused lid event for the state of the latest lid event, after any
  change still in the 2 s lid debounce has settled, and runs the floor
  rules again. A check that cannot take the lock, read the journal or the
  mode, switch the mode off, or write the journal runs again after the
  retry delay while the session lasts. After a `lowpowermode 0` that
  exited 0, the ownership clear the journal refused is owed: the retried
  check's transaction writes it first, and the check then has nothing to
  switch off.
- Successful restores may clear their entries; failures must stay journaled.
  A journal write that fails to clear the entry of a successful restore is
  shown in the menu as well as logged, and the restore is retried. The
  line goes once a later write clears that entry, unless a newer error
  has replaced it.
  Process recovery must verify identity and avoid resuming a process that
  Insomnia did not stop. The entries that record `startedAtMicros` go to
  the installed app binary in one call (`Insomnia --resume-frozen
  <seconds>`, with one line `<pid> <startedAt> <startedAtMicros>
  <bootSession>` per entry on standard input, which has no size limit,
  answered before AppKit starts),
  so the comparison is to the microsecond and each entry's signal follows
  its own lookup in one process. The binary prints one line per entry in
  input order, `<pid> <word>`, and exits 0 when every word is `resumed` or
  `gone`, 1 otherwise. A missing or malformed `<seconds>` (1 to 300), any
  further argument, empty input or a malformed line is a usage error (exit
  64) that checks nothing. The script runs the binary only when the bundle's
  `Info.plist` declares `InsomniaResumeFrozenVersion` equal to the version
  the script speaks, because an older build would start the menu bar app
  instead; otherwise it keeps those entries. `install.sh` runs the staged
  bundle's backstop with `--own-bundle`, which takes the binary and
  `Info.plist` beside that copy instead of the installed app's, so an
  upgrade from a build without the interface still resumes these entries
  before the swap. It runs it with the same
  30-second limit as a power command, then SIGTERM, then SIGKILL, and with
  the lock descriptor: the binary keeps the recovery lock while it can
  still send a signal, even if the script dies first, and ends itself with
  SIGALRM after `<seconds>` (the script's limit plus the SIGTERM grace), so
  the lock is freed without anyone waiting for it. The script starts the
  binary as its own background job and is the only process that signals
  it, by jobspec, so a signal never reaches a pid bash has already reaped. It checks the whole answer:
  one line per entry with that entry's pid and a known word and nothing
  else, and an exit status that agrees with the words. `resumed` and `gone`
  clear an entry, the other words keep it, and a missing binary, a timeout
  or any other answer keeps every entry of the call. Entries without
  microseconds keep the shell's one-second `ps` comparison. Old PID-only
  entries need conservative handling.
- The shell does not restore CoreAudio settings. Saved audio must remain in
  the journal for the app to restore. Legacy `savedOutputVolume` /
  `savedMuted` count as unresolved, so the run exits 1 and says to open
  Insomnia. `savedAudioOutputs` entries are checked for shape and kept, but
  on their own they leave the journal clean: an entry can wait days for its
  device, the app's menu shows it, and an error every minute would only
  fill the log. The backstop logs them once, when it removes a session or
  undoes something else. Uninstall must preserve recovery tools
  and state when restoration is incomplete, including saved audio. It runs
  the checkout's backstop only when the installed app declares the
  `InsomniaResumeFrozenVersion` that backstop speaks; otherwise it runs the
  backstop installed with that app, when there is one: the copy sealed in
  its bundle, once `codesign --verify --strict` passes, else the writable
  copy older installs left in Application Support. With no installed copy
  it runs the checkout's backstop anyway, which keeps the entries that
  need the binary without running it, so uninstall stops before removing
  anything.
- The shell does not restore display or keyboard brightness either; both stay
  in the journal for the app. One flagged `displayRestoreRefused` or
  `keyboardRestoreRefused` is kept but does not make the journal dirty, so
  it neither fails the run nor stops uninstall, which keeps state.json for
  it (section 4).
- The shell puts `appNapOverrides` back with `defaults write <id>
  NSAppSleepDisabled -bool <previous>` or `defaults delete` when the key was
  absent. A delete that fails counts as done only when `defaults read` then
  says the key does not exist; a read that succeeds or fails any other way
  keeps the entry.
- The agent is a recovery mechanism, not a guarantee of crash/reboot behavior
  or a replacement for battery/thermal observers. These scenarios require
  the separate hardware validation record.

### 9. Notifications

`UNUserNotificationCenter`: session ended (with reason), session not started
(the password dialog was cancelled or failed, or a `pending-start` that
cannot be removed refused the start), password prompt still running
(osascript's pid, while it runs), session ended because sleep was
turned back on while Insomnia was not running, extend reminder 5 minutes
before end, battery floor reached, battery unreadable twice in a row, thermal
action taken, network gap recovered (with nudge summary), sleep restored by
backstop, sleep disabled by something other than Insomnia (reconcile step 3,
once per launch), lid-close settings changed by the one-time update
(section 10, once).

### 10. Settings

JSON at `~/Library/Application Support/Insomnia/config.json`, edited through a
small settings window. Like `session.json`, `state.json` and the recovery
lock it is created mode 0600 in a 0700 directory, and a looser file from an
older build is tightened when the app reads it:

- presets, default preset
- freeze list (bundle ids), freeze every other app on/off (default off),
  Docker rule on/off, mute on lid close on/off (default on). Under the mute
  toggle: on Mac laptops with Apple silicon or a T2 chip, closing the lid
  disconnects the built-in microphone in hardware, so recording with the lid
  closed needs AirPods or an external mic.
- one-time lid-close update. A config.json without `lidCloseDefaultsApplied`
  was saved by an earlier build. At launch it gets `freezeAllApps` off and
  `muteOnLidClose` on, the mark set, and is written back. When either value
  changed, the launch reconcile posts one "Lid-close settings changed"
  notification naming each change and where to change it back (Settings,
  Lid-close actions). It posts before taking the recovery lock, so a busy
  lock or an unreadable journal does not hold it back, and after the app
  installs its notification delegate. The app keeps the change in `lidCloseDefaultsNotice` so Settings
  shows the same line at the top of Lid-close actions until dismissed. The
  mark stays set, so a setting the user turns back is never changed again. A
  missing `muteOnLidClose` in a config without the mark reads as off, as the
  earlier builds read it. A fresh install writes a config.json with the mark
  and the new defaults and shows no notice.
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
      SleepOffReceipts.swift
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
    build-app.sh           build, bundle (backstop.sh sealed inside), codesign
    install.sh             build-app.sh or a verified --app bundle, sudoers, launchd
    uninstall.sh           reverse all of the above, restore sleep
    backstop.sh            standalone restore from JSON
    simulate-lid.sh        file trigger for the lid-close action path (debug and
                           INSOMNIA_LID_SIMULATION=1 builds only)
  docs/spec.md
  README.md                setup, hotspot setting, Chrome note
```

## Install

```
git clone https://github.com/krishhgg/Insomnia.git && cd Insomnia
./scripts/install.sh      # asks for sudo once, for the sudoers file and the receipt
```

Then set the hotspot in Settings, pick a freeze list, and start a session.
Each start asks for the administrator password (that is the `disablesleep 1`
the sudoers file does not cover).

## Manual test plan

Run under supervision on a ventilated surface using disposable work before
claiming hardware validation. The checklist below is a test plan, not evidence
that any case passed; record results in the release validation record.

1. **First launch.** Confirm the status item is visible to the right of the
   notch on first launch.
2. **Stays awake.** Start 30m session; the administrator password dialog
   appears and names what it does. Close lid, wait 5 minutes, ping the Mac
   from the phone or check the heartbeat log. Open lid: session still running,
   sleep still disabled until end. Separately: Enter, then Cancel in the
   dialog → no session, `pmset -g` unchanged (no `SleepDisabled`),
   session.json and the journal are clean, and the "Session not started"
   notification says Insomnia undid anything it changed. With
   `SleepDisabled 1` set by hand first, Enter shows no dialog, changes
   nothing and gives the command that turns sleep back on. With `sudo pmset -a disablesleep 1` run in a
   terminal while the dialog is up, the password then starts no session
   (status 6) and `SleepDisabled 1` stays.
3. **Restores.** End now → `pmset -g` shows no `SleepDisabled`. Quit → same.
   Timer expiry → same, plus notification.
4. **Backstop.** Force-quit a supervised disposable session, then verify
   deadline recovery and retry after an injected restore failure. Separately
   test reboot/login with valid, expired, and dirty journals; the polling
   agent honors a valid future deadline rather than unconditionally ending
   every session at login. Saved audio requires the app to reopen.
5. **Freeze.** Slack and WhatsApp on list, close lid, `ps -o stat` shows `T`
   for their whole trees. Open lid → running, reconnected, no relaunch.
6. **Docker rule.** Rule on. No containers → paused on close; insomnia.log
   has "first check found no running container" and "second check found no
   running container". One container → untouched, log has "first check found
   containers running". A container started between the two checks →
   untouched, log has the first check finding none and "second check found
   containers running".
7. **Mute.** Volume 60%, close lid → muted. Open → 60%, unmuted. With a
   headset as the output, close the lid, unplug the headset, open the lid
   and choose End: the notification and the menu name the headset as still
   muted. Plug it back in → its volume comes back and the menu line goes.
   Repeat, but Quit with the headset unplugged, plug it in, then launch
   Insomnia → restored at launch.
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
    `INSOMNIA_LID_SIMULATION=1 ./scripts/install.sh`, which `build-app.sh`
    reads; install.sh refuses it with `--app`; it logs "Lid
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
15. **Meeting apps.** Freeze-all on, a Zoom or Teams call running on AirPods
    and Wispr Flow or Granola taking notes. Close the lid → none of their
    processes shows `T` in `ps -o stat`, the call and the notes continue,
    other Dock apps are frozen, sound is muted.
16. **Upgrade notice.** Install over a build whose config.json has
    `freezeAllApps: true` and `muteOnLidClose: false`. First launch → one
    "Lid-close settings changed" notification, the same line at the top of
    Lid-close actions in Settings, both toggles changed, config.json has
    `lidCloseDefaultsApplied: true`. Turn freeze-all back on, relaunch → no
    notice, still on. Dismiss removes the Settings line. A fresh install
    shows no notice.

## Open decisions (defaults chosen, change if you disagree)

- `pmset -a` (all power sources) rather than `-b` for `disablesleep`, so
  behaviour is identical whether or not a charger is attached.
- Default `lowPowerFloor` 40%, `endFloor` 10%, `nudgeThreshold` 90 s.
- Turning App Nap off for agent apps is opt-in and the previous value is put
  back at session end. Values older builds wrote without a record are listed
  by uninstall, never deleted by it.
