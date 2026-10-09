#!/bin/bash
# Insomnia backstop: restore the machine from the JSON journal alone.
# Runs from launchd (RunAtLoad + StartInterval 60, installed by install.sh)
# and from install.sh / uninstall.sh. Needs no Insomnia process and no Swift.
#
# Where it lives: install.sh copies this file into the app bundle at
# Insomnia.app/Contents/Resources/backstop.sh before signing the bundle, so
# the signature's resource seal covers it. The LaunchAgent's command line
# runs `codesign --verify --strict` on the bundle against the requirement
# pinned in the plist (for an ad-hoc build, the cdhash of that build) and
# execs this file only when that passes; an edited copy makes the check fail
# and the agent logs one line and runs nothing. Nothing executable is kept in
# Application Support (installs before this layout ran a writable copy from
# there; install.sh removes it once the new agent is loaded).
#
# Every run is one transaction under APP_SUPPORT/.recovery.lock, an flock(2)
# exclusive lock on the same file the app locks: read session.json and
# state.json, decide, undo, publish the new journal atomically, release.
# Both files are read from private copies made under the lock (see
# copy_private), each read's status is checked, and a read that fails is
# never taken for a key that is absent: the run then undoes nothing more and
# exits 1. If
# the lock is not free within LOCK_TIMEOUT_SECONDS the run does nothing and
# exits 75; launchd retries a minute later. The lock file is never unlinked
# or replaced here, so every party locks the same inode.
#
# Locking detail: the script opens the lock file on fd 9 and locks that fd
# with `lockf <fd>`. If a caller (uninstall.sh) already holds the lock and
# passes its handle down as fd 9, locking fd 9 again shares the caller's lock
# instead of deadlocking against it; fd 9 is accepted only if its inode is
# the lock file's inode.
#
# First thing under the lock, every run deletes APP_SUPPORT/pending-start.
# The app holds the lock for as long as a Start waits on its password
# dialog, so a marker found here belongs to a start that was abandoned (the
# app died under its dialog). The root command behind that dialog turns
# sleep off only while the marker holds its nonce, so answering the dialog
# after this point changes nothing. That command also holds a lockf lock on
# the marker from before its nonce check until pmset exits, and the marker
# is deleted only under the same lock, and only while its path still names
# the locked file: it goes before the check, or after pmset, whose effect
# the journal entry still covers. A marker that cannot
# be locked within PENDING_LOCK_TIMEOUT_SECONDS or cannot be deleted means
# that dialog could still turn sleep off later: sleep is still restored,
# but sleepDisabledByUs stays journaled and the run exits 1, so the next run
# retries.
#
# Then, whether or not the marker went, the run settles a start the
# journal still records (sleepOffAttempt, see settle_attempt): the
# root-owned receipt install.sh made in RECEIPTS, read under its own lock,
# shows whether the command behind that start's dialog turned sleep off.
# This happens before the session is read, so a session whose start never
# finished is never left to be resumed. A start that cannot be settled yet
# stays journaled, its session is ended rather than resumed, and the run
# exits 1. A marker that no journaled start accounts for takes session.json
# with it (drop_unrecorded_session), for the same reason.
#
# Decision, driven only by what the journal says was changed:
#   - session.json valid (endsAt in the future) and no --force: exit 0
#     (1 while pending-start is still present).
#   - state.json missing or clean: nothing is undone and nothing privileged
#     runs; an expired session.json is removed. Exit 0. Entries in
#     savedAudioOutputs alone count as clean (see below).
#   - state.json dirty: undo each journaled entry from the journal alone:
#       sleepDisabledByUs   -> sudo -n pmset -a disablesleep 0 (the entry is
#                              cleared only if pending-start is gone and no
#                              start is still journaled; no pmset at all
#                              while settle_attempt holds it back)
#       lowPowerSetByUs     -> sudo -n pmset -b lowpowermode 0
#       frozenProcesses     -> SIGCONT, but only to a pid verified to be the
#                              process the app froze. Entries that record
#                              startedAtMicros are handed to the installed
#                              app binary, or with --own-bundle to the one
#                              beside this copy (INSOMNIA_BIN --resume-frozen
#                              <seconds>), in one call with a time limit, one
#                              line per entry on its standard input. For
#                              each entry in turn it does one kernel lookup
#                              (start time to the microsecond, boot session,
#                              stopped state) immediately followed by that
#                              entry's SIGCONT; this script never signals
#                              such an entry itself. The binary runs only
#                              when the bundle's Info.plist declares the
#                              interface version this script speaks
#                              (InsomniaResumeFrozenVersion), and it keeps
#                              the lock on fd 9 until it exits, which it does
#                              by itself after <seconds>. When the binary is
#                              missing, does not declare that version, cannot
#                              run, times out, or answers anything but one
#                              documented line per entry, those entries are
#                              kept and not signaled. An entry
#                              without startedAtMicros (an older build) is
#                              checked here instead: it must exist, be
#                              stopped, have started in this boot session at
#                              the journaled second (ps -o lstart) and belong
#                              to this user. A pid observed gone, running, or
#                              not matching is cleared without a signal. A pid
#                              that cannot be observed (ps fails or prints
#                              something unparseable) is kept. In both paths
#                              an entry from another boot session is cleared
#                              without a lookup.
#       frozenPids (legacy)  -> never signaled and never cleared here, even if
#                              the pid is gone: nothing proves the stopped
#                              process is ours. Only the app resolves them.
#       savedOutputVolume / savedMuted -> CoreAudio; only the app can restore
#                              these. Kept for the app's reconcile.
#       savedAudioOutputs   -> CoreAudio volume and mute of each output
#                              device a lid close muted, by device UID; only
#                              the app can restore these, and only while the
#                              device is connected. Kept for the app, and on
#                              their own they leave the journal clean: an
#                              entry can wait days for its device, the app's
#                              menu shows it, and an error every minute here
#                              would only fill the log. They are logged once
#                              when this run removes a session or undoes
#                              something else.
#       savedDisplayBrightness / savedKeyboardBrightness -> display brightness
#                              and keyboard backlight the app set to 0 on lid
#                              close; only the app can restore these (private
#                              frameworks). Kept for the app's reconcile.
#                              With displayRestoreRefused / keyboardRestore-
#                              Refused true, the app's private-call guard
#                              refused that restore on this macOS: kept, and
#                              not dirty, since no run here or of that app
#                              build can restore it.
#       displayRestoredUnderLowPower, keptDisplayUnderLowPower,
#       keptDisplayUnderLowPowerBoot, keptDisplayReadLit -> the app's own
#                              records about a display restore under its Low
#                              Power Mode and about a kept display entry.
#                              Nothing to undo and not dirty: never read for
#                              an undo here, and kept as they are for the
#                              app, with one change. Before this run
#                              switches Low Power Mode off, a record of the
#                              kept entry gets this boot's
#                              kern.bootsessionuuid (empty if it cannot be
#                              read) as keptDisplayUnderLowPowerBoot, in a
#                              journal published first, so the app takes no
#                              reading of that entry in this boot as the
#                              user's level while the panel comes back from
#                              the mode, even if the journal written after
#                              the undo is lost. If that journal cannot be
#                              published, the mode is left on and kept for
#                              retry. Their types are checked, and the three
#                              keys about the kept entry are also read from
#                              the file's text as the app reads it
#                              (record_text_problems): at the top level, with
#                              escapes in keys decoded. A number the app
#                              cannot decode, one of these keys found twice
#                              there, or text the check cannot follow makes
#                              the journal malformed.
#       appNapOverrides     -> NSAppSleepDisabled the app set to YES in an
#                              agent app's preferences, with the value it had
#                              before: defaults write <bundleId>
#                              NSAppSleepDisabled -bool <previous>, or
#                              defaults delete <bundleId> NSAppSleepDisabled
#                              when the key was absent. A delete that fails
#                              counts as done only when defaults read then
#                              says the key does not exist; a read that
#                              fails any other way proves nothing and the
#                              entry stays.
#     A flag is cleared only after its undo succeeded. Unknown keys survive.
#     Exit 0 only when the journal is clean afterwards; otherwise exit 1 so
#     the failure is visible and the next periodic run retries.
#   - state.json unreadable, not a JSON object, or with a known key of the
#     wrong type: nothing is touched, exit 1. So also when its JSON or text
#     could not be read again after the first check passed, or a later read
#     of one of its keys fails: nothing more is undone, and no entry is
#     cleared or published on a read that failed.
#   - session.json present but not a session: readable, but not the shape
#     the app's Session decoder accepts (session_shape_problems). It is
#     treated as expired. Once the journal is clean (already, or after the
#     undo above succeeded) the file is renamed to
#     session.json.unreadable-<UTC stamp>, never deleted or overwritten, so
#     the next run sees no session. While the journal stays dirty it stays.
#   - session.json present but not readable at all (permissions, I/O), or
#     not a regular file (a FIFO or device is never opened: open(2) could
#     block while this run holds the lock): its end time is unknown, and
#     sleep is never held without a deadline that can be enforced, so it is
#     treated as expired and the journal is undone as above. The file is
#     never opened, read or removed: it may have been a valid session. Once
#     the journal is clean it is renamed aside like a malformed one, so its
#     bytes stay as evidence and no later run, of this script or the app,
#     can read it back as a session that was already treated as ended. A
#     state.json that is not a regular file is malformed.
#
# Limitation: for an entry without startedAtMicros the shell compares process
# start time to the second only. For every entry a lookup and a signal are
# still two operations, in the app binary as here; the binary does each
# entry's lookup right before that entry's signal, never all lookups first.
#
# --force: treat the session as expired even if endsAt is in the future
# (used by install.sh / uninstall.sh to end a stale session deliberately).
#
# --own-bundle: run --resume-frozen with the app binary and Info.plist of the
# bundle this copy is sealed in (Contents/MacOS/Insomnia and
# Contents/Info.plist, beside Contents/Resources/backstop.sh), never the
# installed app's. install.sh passes it to the copy in the bundle it has just
# staged and verified with codesign, and runs that copy's recovery before the
# bundle replaces the installed one. The installed build may predate
# --resume-frozen and would open the menu bar app instead; the staged binary
# is the build this copy was sealed with. The path this copy was run by
# (BASH_SOURCE, not the environment) must be absolute and end in
# .app/Contents/Resources/backstop.sh, or the run refuses with exit 2 before
# it takes the lock or reads the journal. That shape check does not verify
# the bundle: the caller must run a copy it has verified. The Info.plist
# check and every other rule above still apply to that binary.
#
# Honours INSOMNIA_HOME with the same layout as the app (see Paths.swift).
#
# The line below says which recovery contract this copy implements. The app
# reads it from the installed script before every password dialog and
# refuses Start when it is missing or lower than it needs
# (BackstopVersion.swift). 2: pending-start is deleted under its lock, as
# described above. 3: a start the journal still records is settled from its
# receipt once its marker is gone (settle_attempt). 4: the receipt is read
# under its lock, as the 82-byte line with the predecessor, against the
# start's expires, whatever happened to the marker; the start's claim on
# the receipt is given back; and no pmset runs for a start held back. 5: a
# settlement publishes its decision (sleepOffAttempt.settled) before it gives
# the claim back, and a settled record is finished rather than refused.
# Raise it when the app comes to rely on something new here.
# insomnia-backstop-version: 5
set -euo pipefail
export LC_ALL=C TZ=UTC
# Everything this run creates (log lines, the lock file, the published
# journal, the directories) is owner-only, like the files the app writes.
umask 077

# Fixed tool paths: never taken from PATH or the environment. Tests patch
# these lines in a private copy of the script.
PMSET=/usr/bin/pmset
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
LOCKF=/usr/bin/lockf
PS=/bin/ps
KILL=/bin/kill
SYSCTL=/usr/sbin/sysctl
CHMOD=/bin/chmod
DEFAULTS=/usr/bin/defaults
DATE=/bin/date
MKDIR=/bin/mkdir
RM=/bin/rm
MV=/bin/mv
CP=/bin/cp
CMP=/usr/bin/cmp
STAT=/usr/bin/stat
MKTEMP=/usr/bin/mktemp
LS=/bin/ls
CAT=/bin/cat
HEAD=/usr/bin/head
TR=/usr/bin/tr
ID=/usr/bin/id
GREP=/usr/bin/grep
# perl makes the private copies of the files this run reads (copy_private),
# through env -i, so nothing in the environment (PERL5OPT, PERL5LIB) reaches
# it.
ENV=/usr/bin/env
PERL=/usr/bin/perl
# The folder of the root-owned receipts (SleepOffReceipts.swift), and the
# one owner besides root it may have: none, as uid 0 is root. Tests patch
# both lines in a private copy, for a folder in their temporary directory.
RECEIPTS=/private/var/db/com.kgarg.insomnia
RECEIPT_OWNER=0
# The installed app binary, for the microsecond identity check of
# frozenProcesses entries (see above), and the bundle's Info.plist, which
# must declare InsomniaResumeFrozenVersion RESUME_FROZEN_VERSION before the
# binary is run: an older build has no such mode and would open the menu bar
# app instead. Fixed paths like the tools, never PATH. install.sh puts the
# bundle here, copying the binary before Info.plist. --own-bundle replaces
# both with the paths beside this copy (see above).
INSOMNIA_BIN="${HOME:-}/Applications/Insomnia.app/Contents/MacOS/Insomnia"
INSOMNIA_INFO="${HOME:-}/Applications/Insomnia.app/Contents/Info.plist"
RESUME_FROZEN_VERSION=1
LOCK_TIMEOUT_SECONDS=10
# How long to wait for the root command behind a password dialog to let go
# of the pending-start marker (pmset takes well under a second).
PENDING_LOCK_TIMEOUT_SECONDS=10
# How long to wait for the receipt's lock (see settle_attempt): the root
# command holds it from its checks until pmset exits.
RECEIPT_LOCK_TIMEOUT_SECONDS=10
# Longest the private copy of one file this run reads (session.json,
# state.json, an Info.plist) may take; see copy_private.
READ_TIMEOUT_SECONDS=10
# Longest a single undo command (sudo pmset, defaults) may run before it is
# sent SIGTERM, and how long it then gets to exit before this run fails closed.
COMMAND_TIMEOUT_SECONDS=30
KILL_GRACE_SECONDS=3

force=0
own_bundle=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --own-bundle) own_bundle=1 ;;
    -h|--help) echo "usage: $0 [--force] [--own-bundle]"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
if (( own_bundle )); then
  own_path="${BASH_SOURCE[0]}"
  if [[ "$own_path" != /*.app/Contents/Resources/backstop.sh ]]; then
    echo "--own-bundle: $own_path is not an absolute path ending in .app/Contents/Resources/backstop.sh; nothing was done" >&2
    exit 2
  fi
  INSOMNIA_BIN="${own_path%/Resources/backstop.sh}/MacOS/Insomnia"
  INSOMNIA_INFO="${own_path%/Resources/backstop.sh}/Info.plist"
fi

if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  APP_SUPPORT="$INSOMNIA_HOME"
  LOG_DIR="$INSOMNIA_HOME/Logs"
else
  APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
  LOG_DIR="$HOME/Library/Logs/Insomnia"
fi
SESSION="$APP_SUPPORT/session.json"
STATE="$APP_SUPPORT/state.json"
PENDING="$APP_SUPPORT/pending-start"
LOCK="$APP_SUPPORT/.recovery.lock"
LOG="$LOG_DIR/insomnia.log"

# Logging is best effort. A log line explains a decision; it never makes
# one. A date, mkdir or append that fails (a full disk, a log made
# read-only) sends the line to standard error instead (launchd discards
# it: the plist names no StandardErrorPath), and the run goes on to the
# restore it already decided on. Under set -e a failed append here would
# otherwise end the run before pmset. The journal and the result of each
# read and root command still decide what happens and how the run ends.
log() { # level message
  local stamp line
  stamp="$("$DATE" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || stamp="(date failed)"
  line="$stamp [$1] backstop: $2"
  { "$MKDIR" -p "$LOG_DIR" && printf '%s\n' "$line" >> "$LOG"; } 2>/dev/null \
    || printf '%s (not written to %s)\n' "$line" "$LOG" >&2 \
    || true
}

# --- Lock --------------------------------------------------------------------
"$MKDIR" -p "$APP_SUPPORT"
# An upgrade over an older build: tighten what it left loose (0644 files,
# 0755 directories), since this run may write to them before the upgraded
# app has opened them. umask only covers what this run creates. go-rwx
# only takes group and other access away and never adds a permission, so a
# file its owner cannot read stays unreadable. A symlink is left alone, as
# the app leaves it, and so is an access control list: removing entries
# changes what recovery can read, such as a 0200 journal its owner reads
# through an allow entry, or a session a deny entry keeps unreadable, which
# recovery treats as ended. A chmod that fails is logged as an error and
# recovery goes on: a loose mode is no reason to leave the machine changed.
tighten() { # path...
  local p err
  for p in "$@"; do
    if [[ -e "$p" && ! -L "$p" ]]; then
      if ! err="$("$CHMOD" go-rwx "$p" 2>&1)"; then
        log error "could not make $p owner-only: ${err:-chmod failed}" || true
      fi
    fi
  done
}
tighten "$APP_SUPPORT" "$LOG_DIR" "$LOG" "$LOCK" "$STATE" "$SESSION"
inode() { "$STAT" -f %i "$1" 2>/dev/null; }
lock_shared=0
if [[ -e /dev/fd/9 && -e "$LOCK" && -n "$(inode "$LOCK")" && "$(inode /dev/fd/9)" == "$(inode "$LOCK")" ]]; then
  lock_shared=1 # fd 9 is the caller's handle on the lock file; share its lock.
else
  exec 9<>"$LOCK"
fi
lock_rc=0
"$LOCKF" -t "$LOCK_TIMEOUT_SECONDS" 9 2>/dev/null || lock_rc=$?
if (( lock_rc != 0 )); then
  log error "recovery lock $LOCK still held after ${LOCK_TIMEOUT_SECONDS}s (lockf exit $lock_rc); nothing changed, will retry"
  exit 75
fi
# From here on this process holds the lock until it exits (fd 9 closes).

# Deletes pending-start under its own lock, as Store.removePendingStart
# does. The marker is opened on fd 8 and locked through it: lockf given a
# descriptor locks this shell's open file, and the lock lasts until fd 8
# closes. Then the path must still name the locked file (stat of fd 8
# against stat -L of the path), because lockf locks a file and rm goes by
# path: a file put in the marker's place after the open is not covered by
# the lock, so it is left alone. Only a regular file is opened; open(2) on
# a FIFO with no writer blocks, and this runs under the recovery lock. A
# link to nothing is removed: the root command cannot open it either.
# Sets marker_rc: 0 deleted or gone, 75 still locked after
# PENDING_LOCK_TIMEOUT_SECONDS, 3 replaced after the open, 4 not a regular
# file, anything else from the open or rm. Sets removed_marker to the
# device:inode of the file it locked and deleted, for settle_attempt.
removed_marker=""
delete_pending_marker() {
  local locked
  marker_rc=0
  if [[ -L "$PENDING" && ! -e "$PENDING" ]]; then
    "$RM" -f "$PENDING" 2>/dev/null || marker_rc=$?
    return 0
  fi
  [[ -e "$PENDING" ]] || return 0
  if [[ ! -f "$PENDING" ]]; then
    marker_rc=4
    return 0
  fi
  { exec 8<"$PENDING"; } 2>/dev/null || { marker_rc=$?; return 0; }
  "$LOCKF" -s -t "$PENDING_LOCK_TIMEOUT_SECONDS" 8 2>/dev/null || marker_rc=$?
  if (( marker_rc == 0 )); then
    locked="$("$STAT" -f '%d:%i' <&8 2>/dev/null)" || locked=""
    if [[ -n "$locked" && "$locked" == "$("$STAT" -L -f '%d:%i' "$PENDING" 2>/dev/null)" ]]; then
      if "$RM" -f "$PENDING" 2>/dev/null; then removed_marker="$locked"; else marker_rc=$?; fi
    else
      marker_rc=3
    fi
  fi
  exec 8<&-
}

# A pending-start marker under the lock belongs to an abandoned start: void
# the password dialog it was written for, under the marker's own lock (see
# the header).
marker_stuck=0
if [[ -e "$PENDING" || -L "$PENDING" ]]; then
  delete_pending_marker
  if [[ -e "$PENDING" || -L "$PENDING" ]]; then
    marker_stuck=1
    case "$marker_rc" in
      75) why="still locked after ${PENDING_LOCK_TIMEOUT_SECONDS}s by the command a password dialog started as root" ;;
      3) why="was replaced after it was opened, so its lock does not cover the file now at that path" ;;
      4) why="is not a regular file, so it was not opened" ;;
      *) why="could not be deleted (exit $marker_rc)" ;;
    esac
    log error "$PENDING $why; a password dialog left from an abandoned start could still turn sleep off, so sleepDisabledByUs stays journaled until a later run deletes it"
  else
    log info "deleted $PENDING; a command a password dialog left from an abandoned start runs stops at its marker check from now on, unless this user writes the marker again or the clock is set back"
  fi
fi
# This run's private folder for its copies of the files it reads (see
# copy_private), made below. Every exit from then on goes through leave,
# which removes the folder first. A run that ends some other way (killed,
# or stopped by the shell itself) leaves it; the next run that takes the
# lock on its own handle removes it. Without the folder, or when a copy in
# it cannot be written, the copies are kept in memory (COPY_IN_MEMORY), so
# a full disk does not stop a recorded restore.
READS=""
COPY_IN_MEMORY=1
leave() { # status
  if [[ -n "$READS" ]]; then "$RM" -rf "$READS" 2>/dev/null || true; fi
  exit "$1"
}
# Every exit 0 from here on goes through this: a marker still present is a
# failure whatever else the run found, so it is retried and the caller sees
# it.
exit_unless_marker_stuck() { # what the run found
  if (( marker_stuck )); then
    log error "$1, but $PENDING is still present; will retry on the next run"
    leave 1
  fi
  if [[ -n "${settle_failed:-}" ]]; then
    log error "$1, but $settle_failed; will retry on the next run"
    leave 1
  fi
  leave 0
}

# --- Helpers -----------------------------------------------------------------

# Logs each non-empty line of $2 at level $1, with $3 before it. Not a
# here-string: bash 3.2 writes one to a temporary file, which a full disk
# refuses.
log_lines() { # level text prefix
  local rest="$2" line
  while [[ -n "$rest" ]]; do
    line="${rest%%$'\n'*}"
    if [[ "$rest" == *$'\n'* ]]; then rest="${rest#*$'\n'}"; else rest=""; fi
    if [[ -n "$line" ]]; then log "$1" "$3$line"; fi
  done
}

# Copies the live file $1 to $READS/$2, for every later read of it in this
# run: session.json, state.json and the app's Info.plist are never read in
# place. perl, run with an empty environment, opens the file without
# blocking and without following a symbolic link, refuses anything but a
# regular file (open(2) on a FIFO with no writer would block under the
# lock, and a device is never read) and one larger than 8 MiB, reads it to
# the end, checks that it holds as many bytes as its size, that its
# identity (file_id: device, inode, size, and modification and change times
# to a fraction of a microsecond) did not move during the read and that the
# path still names it, not through a link, and writes the bytes to a new
# mode-600 file. SIGALRM ends it after READ_TIMEOUT_SECONDS; a read the
# kernel cannot interrupt (a stalled disk), or a perl stopped by SIGSTOP,
# holds it longer. Returns 0 with copy_path and copy_id (that identity); 3
# when the file could not be opened or read (permissions, I/O); 4 when it is
# a symbolic link or not a regular file; 2 for anything else: it is larger
# than 8 MiB, it changed while it was read, the time ran out, or the copy
# could not be written. Its reason is in copy_why.
# With no READS folder, or when the new file cannot be written (a full
# disk) and COPY_IN_MEMORY is 1, perl makes the same checks and prints the
# bytes instead. They are kept in the shell variable mem_<name>, and
# copy_path is mem:<name>, which plutil_on, json_object,
# record_text_problems, session_shape_problems and same_as_read read from
# memory. Nothing in that mode creates a file. A shell variable cannot hold
# a NUL byte, so a file with one is then 2.
# shellcheck disable=SC2016  # the $ below are perl's, not this shell's
COPY_PERL='use strict; use Fcntl qw(:DEFAULT :mode); use Time::HiRes ();
$SIG{ALRM} = "DEFAULT"; alarm shift @ARGV;
my ($src, $dst) = @ARGV;
my $max = 8 * 1024 * 1024;
sub fail { print "$_[1]\n"; exit $_[0] }
sub id { join(":", @_[0,1,7], map { sprintf "%.9f", $_ } @_[9,10]) }
sysopen(my $in, $src, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
  or fail $!{ELOOP} ? (4, "a symbolic link, which is not followed") : (3, "$!");
my @a = Time::HiRes::stat($in) or fail 3, "$!";
S_ISREG($a[2]) or fail 4, "not a regular file";
$a[7] <= $max or fail 2, "it is larger than 8 MiB";
my ($data, $n) = ("", 0);
while ($n = sysread($in, $data, 65536, length $data)) {
  length($data) <= $max or fail 2, "it grew past 8 MiB while it was read";
}
defined $n or fail 3, "$!";
my @b = Time::HiRes::stat($in) or fail 3, "$!";
my @c = Time::HiRes::lstat($src);
id(@a) eq id(@b) && @c && id(@b) eq id(@c) && length($data) == $b[7]
  or fail 2, "it changed while it was read";
my $id = id(@b);
if ($dst eq "-") {
  index($data, "\0") < 0 or fail 2, "it holds a NUL byte, which a copy kept in memory cannot hold";
  print "$id\n$data." or exit 2;
  exit 0;
}
sysopen(my $out, $dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or fail 5, "$dst: $!";
for (my $off = 0; $off < length $data; ) {
  my $w = syswrite($out, $data, length($data) - $off, $off);
  defined $w && $w > 0 or fail 5, "$dst: $!";
  $off += $w;
}
close($out) or fail 5, "$dst: $!";
print "$id\n";'
copy_private() { # live-file name
  local out rc=0 mem=0 data=""
  copy_path="$READS/$2"; copy_id=""; copy_why=""
  if [[ -z "$READS" ]]; then
    mem=1
  else
    "$RM" -f "$copy_path" 2>/dev/null || { copy_why="its earlier copy $copy_path could not be removed"; return 2; }
    out="$("$ENV" -i "$PERL" -e "$COPY_PERL" "$READ_TIMEOUT_SECONDS" "$1" "$copy_path" 2>/dev/null)" || rc=$?
    # A copy that could not be written (a full disk) is made again in
    # memory.
    if (( rc == 5 && ${COPY_IN_MEMORY:-0} == 1 )); then
      "$RM" -f "$copy_path" 2>/dev/null || true
      mem=1; rc=0
    fi
  fi
  if (( mem )); then
    copy_path="mem:${2//[^A-Za-z0-9_]/_}"
    printf -v "mem_${copy_path#mem:}" '%s' ""
    out="$("$ENV" -i "$PERL" -e "$COPY_PERL" "$READ_TIMEOUT_SECONDS" "$1" - 2>/dev/null)" || rc=$?
    # The identity, a newline, the bytes and a "." that keeps their
    # trailing newlines from the command substitution.
    if (( rc == 0 )); then
      if [[ "$out" == *$'\n'*. ]]; then
        data="${out#*$'\n'}"; data="${data%.}"
        out="${out%%$'\n'*}"
      else
        out=""
      fi
    fi
  fi
  if (( rc == 0 )) && [[ "$out" =~ ^[0-9]+:[0-9]+:[0-9]+:-?[0-9]+\.[0-9]{9}:-?[0-9]+\.[0-9]{9}$ ]]; then
    copy_id="$out"
    if (( mem )); then printf -v "mem_${copy_path#mem:}" '%s' "$data"; fi
    return 0
  fi
  copy_why="${out%%$'\n'*}"
  case "$rc" in
    3|4) ;;
    142) copy_why="it was still being read after ${READ_TIMEOUT_SECONDS}s"; rc=2 ;;
    0) copy_why="the copy did not report what it copied"; rc=2 ;;
    *) copy_why="${copy_why:-the copy exited $rc}"; rc=2 ;;
  esac
  copy_why="${copy_why:-the copy exited $rc}"
  return "$rc"
}
# The identity copy_private gives a file (copy_id), of the file at $1 now,
# not following a link: its device, inode and size, and its modification
# and change times with the fraction perl's Time::HiRes gives them (the
# nanoseconds the system keeps, rounded to a double, a fraction of a
# microsecond). Prints nothing when there is no such file.
# shellcheck disable=SC2016  # the $ below are perl's, not this shell's
ID_PERL='use strict; use Time::HiRes ();
my @s = Time::HiRes::lstat($ARGV[0]) or exit 1;
print join(":", @s[0,1,7], map { sprintf "%.9f", $_ } @s[9,10]), "\n";'
file_id() { # path
  "$ENV" -i "$PERL" -e "$ID_PERL" "$1" 2>/dev/null
}
# Runs plutil with these arguments on the file given last, or, for a copy
# kept in memory (mem:<name>, see copy_private), on those bytes through its
# standard input. Returns plutil's status.
plutil_on() { # plutil-arguments... file
  local f="${!#}" v
  if [[ "$f" != mem:* ]]; then
    "$PLUTIL" "$@" || return
    return 0
  fi
  v="mem_${f#mem:}"
  printf '%s' "${!v}" | "$PLUTIL" "${@:1:$#-1}" - && return 0
  return "${PIPESTATUS[1]}"
}
# True when file $1 holds the same bytes as this run's copy $2, a file or
# one kept in memory.
same_as_read() { # file copy
  if [[ "$2" == mem:* ]]; then
    local v="mem_${2#mem:}"
    printf '%s' "${!v}" | "$CMP" -s - "$1"
  else
    "$CMP" -s "$1" "$2"
  fi
}
# state.json's private copy (state_copy) and the identity of the file it was
# made from (state_id), for state_unchanged. state_copy_rc and
# state_copy_why keep copy_private's status and reason.
state_copy=""
state_id=""
state_copy_why=""
copy_state() {
  local rc=0
  state_copy=""; state_id=""
  copy_private "$STATE" state.json || rc=$?
  state_copy_rc="$rc"; state_copy_why="$copy_why"
  if (( rc == 0 )); then state_copy="$copy_path"; state_id="$copy_id"; fi
  return "$rc"
}
# True while state.json is still the file state_copy was made from.
state_unchanged() {
  local now
  now="$(file_id "$STATE")" || return 1
  [[ -n "$state_id" && "$now" == "$state_id" ]]
}

# Reads through plutil, always of a private copy. type_at sets t to the
# type name at the key path (bool, integer, float, string, array,
# dictionary, or "(any)" for null) and read_at sets read_value to what
# -extract prints there (raw or json), apart from the one newline plutil
# adds, so a stored trailing newline is kept. Both return 0 with the value;
# 1 when the key path is absent, which plutil reports as "No value at that
# key path", and read_at also for a null, as for the app's decodeIfPresent;
# and 2 for any other failure, with read_why saying which read failed and
# how. What that key holds is then unknown, never absent: no caller acts on
# it. A plutil that words the absence differently makes every absent key
# unknown, and the run then undoes nothing and exits 1.
plutil_run() { # plutil-arguments... file
  local out all split
  plutil_rc=""; plutil_err=""
  if [[ -n "$READS" ]]; then
    # A message file that cannot be made or read is quiet here: the run
    # below then keeps the message in memory.
    out="$(exec 2>/dev/null; plutil_on "$@" 2>"$READS/plutil.err"; echo ".$?")"
    plutil_rc="${out##*.}"
    if [[ "$plutil_rc" != 0 ]]; then
      { IFS= read -r plutil_err < "$READS/plutil.err"; } 2>/dev/null || true
    fi
  fi
  # With no folder, or a failure whose message could not be kept in one (a
  # full disk), plutil runs again and its message is kept in memory: it
  # goes to the outer capture first, then a line no message holds, then
  # what plutil printed and its status.
  if [[ -z "$READS" ]] || [[ "$plutil_rc" != 0 && -z "$plutil_err" ]]; then
    split="--plutil-$$-$RANDOM--"
    all="$( { out="$(plutil_on "$@" 2>&4; echo ".$?")"; printf '\n%s\n%s' "$split" "$out"; } 4>&1 )"
    out="${all#*$'\n'"$split"$'\n'}"
    plutil_err="${all%%$'\n'"$split"$'\n'*}"
    plutil_err="${plutil_err%%$'\n'*}"
    plutil_rc="${out##*.}"
  fi
  out="${out%.*}"
  plutil_out="${out%$'\n'}"
}
absent_reply() { # keypath
  [[ "$plutil_rc" == 1 && "$plutil_err" == *"No value at that key path or invalid key path: $1" ]]
}
type_at() { # file keypath
  t=""
  plutil_run -type "$2" -o - "$1"
  if [[ "$plutil_rc" == 0 ]]; then t="$plutil_out"; return 0; fi
  absent_reply "$2" && return 1
  read_why="$2: plutil -type exited ${plutil_rc:-?} (${plutil_err:-no message})"
  return 2
}
# For the shape checks: type_at with t empty when the key is absent, and a
# failure only when the read failed.
ty() { # file keypath
  type_at "$@" || (( $? == 1 ))
}
read_at() { # file keypath raw|json
  local rc err
  read_value=""
  plutil_run -extract "$2" "$3" -o - "$1"
  if [[ "$plutil_rc" == 0 ]]; then read_value="$plutil_out"; return 0; fi
  absent_reply "$2" && return 1
  rc="$plutil_rc"; err="$plutil_err"
  # A null cannot be extracted; its type is "(any)".
  if [[ "$rc" == 1 ]]; then
    plutil_run -type "$2" -o - "$1"
    [[ "$plutil_rc" == 0 && "$plutil_out" == "(any)" ]] && return 1
  fi
  read_why="$2: plutil -extract exited ${rc:-?} (${err:-no message})"
  return 2
}
# The number of elements of the array at key path $2 into count: 0 when it
# is absent or null. Returns 2 when a read failed.
count_at() { # file keypath
  count=0
  while :; do
    type_at "$1" "$2.$count" || { (( $? == 1 )) && return 0; return 2; }
    count=$((count + 1))
  done
}
# True when plutil converts $1 whole to JSON and both that JSON and the
# file itself (or the copy in memory) start with "{". Each step's status
# counts: a conversion or a read that fails is not a JSON object.
json_object() { # file
  local c v
  c="$(plutil_on -convert json -o - "$1" 2>/dev/null)" || return 1
  [[ "${c:0:1}" == "{" ]] || return 1
  if [[ "$1" == mem:* ]]; then
    v="mem_${1#mem:}"; c="${!v}"
  else
    c="$("$HEAD" -c 1 "$1")" || return 1
  fi
  [[ "${c:0:1}" == "{" ]]
}
# Runs journal_shape_problems or session_shape_problems on file $2. Sets
# shape_lines to what it prints and returns its status: 0, or 2 when a read
# failed, with read_why saying which. Not `problems`: uninstall.sh's step 4
# keeps its list in an array of that name, and a string assigned to it
# would become that array's first element.
shape_of() { # journal|session file
  local out rc=0
  case "$1" in
    journal) out="$(journal_shape_problems "$2" || { rc=$?; echo "${read_why:-a read failed}"; exit "$rc"; })" || rc=$? ;;
    *) out="$(session_shape_problems "$2" || { rc=$?; echo "${read_why:-a read failed}"; exit "$rc"; })" || rc=$? ;;
  esac
  shape_lines="$out"
  if (( rc != 0 )); then
    read_why="${out##*$'\n'}"
    shape_lines=""
    return 2
  fi
  return 0
}
# A read of the journal's copy that this run cannot do without. Sets
# read_value, empty for a key that is absent or null, and found to 1 when
# it is neither. A read that fails ends the run here: nothing more is undone
# and the journal is kept as it was.
state_read() { # keypath raw|json
  local rc=0
  found=0
  read_at "$state_copy" "$1" "$2" || rc=$?
  if (( rc == 2 )); then
    log error "$STATE: $read_why; nothing more undone this run, the journal is kept as it was, and the next run tries again"
    leave 1
  fi
  if (( rc == 0 )); then found=1; fi
  return 0
}
# The number of elements of the journal's array $1 into count, as
# state_read: a read that fails ends the run.
state_count() { # keypath
  local rc=0
  count_at "$state_copy" "$1" || rc=$?
  if (( rc != 0 )); then
    log error "$STATE: $read_why; nothing more undone this run, the journal is kept as it was, and the next run tries again"
    leave 1
  fi
  return 0
}
is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

# True once file $1 is non-empty; waits at least $2 seconds for it unless it
# appears first. The limit is read from bash's SECONDS clock, which counts
# whole seconds of wall-clock time, so the wait ends at the first check after
# the clock has gone past the limit: more than $2 seconds after the call, up
# to one second later than that, plus the poll in progress at that moment. A
# slow poll on a loaded machine (each sleep is a fork) adds its own length
# once, where counting polls stretched the limit by every one of them. The
# file is checked once more after the limit, so a status written during the
# last poll still counts. A wall-clock change during the wait (the clock set
# back or forward) lengthens or shortens it by that much. The first 20 polls
# sleep 0.01 s, so a command that ends at once, as most undo commands do, is
# seen within milliseconds, as install.sh and uninstall.sh see theirs; later
# ones sleep 0.1 s, so a long wait forks a tenth as many sleeps.
wait_for_status() { # file seconds
  local deadline=$(( SECONDS + $2 )) polls=0
  while [[ ! -s "$1" ]] && (( SECONDS <= deadline )); do
    if (( polls < 20 )); then sleep 0.01; else sleep 0.1; fi
    polls=$((polls + 1))
  done
  [[ -s "$1" ]]
}

# Run one undo command (sudo -n pmset ..., defaults ...) inside the locked
# transaction with a time limit. supervise_command (below) starts it in the
# background, enforces the limit and writes one status line; this run waits
# for that line and never signals the command itself. Returns the command's
# exit status; 124 when it did not finish within COMMAND_TIMEOUT_SECONDS and
# ended within KILL_GRACE_SECONDS of the SIGTERM it then got; 125, with
# command_alive=1, when it was still running after that, or when no status
# came in time.
# A command still running after SIGTERM is never SIGKILLed: killing sudo
# would orphan a root pmset that could change power state later, outside any
# transaction. Its supervisor keeps waiting and so keeps the lock, and the
# pid is logged for manual intervention. The caller must then end the
# transaction (stop_transaction): no later undo command may run beside a live
# one, and the journal stays as it was. Every later app start and backstop
# run is refused as "lock held" until that command ends. A missing status
# ends the transaction the same way: nothing here can tell whether the
# command still runs, and stopping is the safe side.
# Each call gets its own status files (.backstop.<this run's pid>.<call>.pid
# and .rc), so a status can never be read as another command's. The .pid file
# is for the log only. Nothing signals the pid read from it: by the time it
# is read the supervisor may have reaped the command, and the number may
# belong to another process. A call that ended removes its files; a call that
# returned 125 leaves them to its live supervisor. The first call of a run
# that took the lock on its own handle removes what earlier runs left: their
# supervisors kept the lock while they lived, so all of them have ended. A
# run that shares its caller's lock (fd 9) skips that: an earlier run under
# the same lock may still have a supervisor waiting for its command.
# The supervisor's stdio is detached so a caller capturing this script's
# output gets EOF when the script exits, not when the command does.
bounded_calls=0
command_alive=0
bounded_output=""   # file for the next bounded command's output; empty: discarded
run_bounded() { # command args...
  local base status="" rc cpid="" supervisor answer_within
  bounded_calls=$((bounded_calls + 1))
  base="$APP_SUPPORT/.backstop.$$.$bounded_calls"
  if (( bounded_calls == 1 && ! lock_shared )); then
    "$RM" -f "$APP_SUPPORT"/.backstop.*.pid "$APP_SUPPORT"/.backstop.*.rc
  fi
  supervise_command "$base" "$@" </dev/null >/dev/null 2>&1 &
  supervisor=$!
  # Each of the supervisor's two waits can end up to a second after its
  # limit, plus the poll in progress then (see wait_for_status), and the
  # supervisor takes a moment to start and to write its status. Four seconds
  # cover that with polls at most 0.1 s apart. A supervisor slower than
  # that gets the 125 below, the safe side.
  answer_within=$(( COMMAND_TIMEOUT_SECONDS + KILL_GRACE_SECONDS + 4 ))
  if wait_for_status "$base.rc" "$answer_within"; then
    read -r status < "$base.rc" || true
  fi
  # A regular file only: a FIFO there could block this run under the lock.
  if [[ -f "$base.pid" ]]; then
    read -r cpid < "$base.pid" || true
    [[ "$cpid" =~ ^[0-9]+$ ]] || cpid=""
  fi
  case "$status" in
    "exit "*) rc="${status#exit }" ;;
    term)
      log error "'$*' did not finish within ${COMMAND_TIMEOUT_SECONDS}s; terminated with SIGTERM (pid ${cpid:-?})"
      rc=124 ;;
    alive)
      log error "'$*' (pid ${cpid:-?}) did not finish within ${COMMAND_TIMEOUT_SECONDS}s and did not stop on SIGTERM. It is not killed, because that could leave a root pmset running outside the transaction. It keeps the recovery lock until it ends, so Insomnia cannot start and recovery cannot run until then; stop it by hand (sudo kill ${cpid:-<pid>}, after 'ps -p ${cpid:-<pid>}' shows that pid is still this command) and the next run will retry"
      command_alive=1
      return 125 ;;
    *)
      log error "'$*' (pid ${cpid:-?}): its supervisor reported no result within ${answer_within}s, so the command may still be running. Nothing is signaled from here; while the supervisor waits for the command it keeps the recovery lock. The journal is kept and the next run will retry"
      command_alive=1
      return 125 ;;
  esac
  wait "$supervisor" 2>/dev/null || true
  "$RM" -f "$base.pid" "$base.rc"
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}

# The supervisor of one run_bounded call; it runs in the background and is
# the only process that signals the command. It keeps fd 9 (the recovery
# lock) until its command has exited and been reaped. sudo drops extra
# descriptors before running pmset, so pmset itself never holds the lock:
# the supervisor does, until sudo reports that the command finished. Both
# limits are measured here (see wait_for_job), so they hold even if this run
# is killed while it waits.
# The supervisor ignores SIGTERM and SIGHUP, so neither the end of this run,
# killed or not, nor either signal sent to its whole process group frees the
# lock while the command runs. launchd signals what is left of a job's
# process group once the job's main process has exited, unless the job sets
# AbandonProcessGroup, which this agent does not. SIGINT and SIGQUIT are
# ignored already, as in every background job of a script. SIGKILL cannot be
# ignored: a supervisor killed with it frees the lock even if its command is
# still running. The command gets back the SIGTERM and SIGHUP actions this
# script started with (the defaults, under launchd), so it still stops on
# SIGTERM.
# The command is the supervisor's only job, so it stays in the supervisor's
# job list until the supervisor has reaped it, and signal_job (see
# run_app_bounded) sends SIGTERM by jobspec: to the command or, once bash has
# reaped it, to nothing, never to a process that reused its pid. At the limit
# the command gets SIGTERM (sudo relays it to pmset and waits for it), then
# KILL_GRACE_SECONDS; it never gets SIGKILL. <base>.rc gets one line:
# "exit <status>" when the command ended within the limit, "term" when it
# ended within the grace, "alive" when it was still running then. After
# "alive" the supervisor goes on waiting and logs the command's exit.
# errexit is off here: a failed write must not end the supervisor while its
# command still runs.
supervise_command() { # base command args...
  local base="$1" cpid rc
  shift
  set +e
  trap '' TERM HUP
  ( trap - TERM HUP; exec "$@" ) </dev/null >"${bounded_output:-/dev/null}" 2>&1 &
  cpid=$!
  echo "$cpid" > "$base.pid"
  if wait_for_job "$cpid" "$COMMAND_TIMEOUT_SECONDS"; then
    wait "$cpid"
    echo "exit $?" > "$base.rc"
    return
  fi
  signal_job TERM "$cpid"
  if wait_for_job "$cpid" "$KILL_GRACE_SECONDS"; then
    wait "$cpid"
    echo term > "$base.rc"
    return
  fi
  echo alive > "$base.rc"
  wait "$cpid"
  rc=$?
  log info "'$*' (pid $cpid), left running after SIGTERM, has exited (wait status $rc); its supervisor now lets go of the recovery lock, and the next run will retry"
}

# Run the app binary's --resume-frozen check (see resume_via_app) with the
# same time limit, standard input from app_answer_dir/in and standard output
# to app_answer_dir/out. This shell starts the binary as its own background
# job and is the only process that signals it; no supervisor stands between
# them. Bash reaps a finished child on its own (in its SIGCHLD handler), so a
# signal sent by pid could reach whatever process gets that pid next. Each
# signal therefore names the job (%+) once signal_job has checked that %+ is
# this pid: bash's kill looks the job up with SIGCHLD blocked and signals it
# only if bash has not reaped it yet, and a child that has not been reaped
# keeps its pid, as a zombie at worst. The exit status is read with wait only
# after the job has left bash's running list. Unlike a power command this is
# our own unprivileged binary, so when SIGTERM does not end it within
# KILL_GRACE_SECONDS it gets SIGKILL: from then on it runs no more of its own
# code and so cannot send another signal.
# The binary inherits fd 9, so the recovery lock stays held for as long as it
# runs, also after this shell is gone: a run killed mid-call leaves no helper
# that could resume a process a later session froze while the lock was free.
# The binary ends itself after its lifetime argument (resume_via_app passes
# COMMAND_TIMEOUT_SECONDS + KILL_GRACE_SECONDS), so such a helper frees the
# lock on its own. Returns the binary's exit status, or 124 when it did not
# finish in time. The function's stderr is /dev/null because bash reports a
# job that a signal ended ("Terminated: 15") on its own stderr; the log says
# what happened instead.
app_answer_dir=""
job_running() { # pid
  local p
  for p in $(jobs -rp); do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}
# True once job pid $1 has left bash's running list; waits at least $2
# seconds for that unless it happens first, on the SECONDS clock like
# wait_for_status (and within the same bounds, with the same polls), and
# checks once more after the limit.
wait_for_job() { # pid seconds
  local deadline=$(( SECONDS + $2 )) polls=0
  while job_running "$1" && (( SECONDS <= deadline )); do
    if (( polls < 20 )); then sleep 0.01; else sleep 0.1; fi
    polls=$((polls + 1))
  done
  ! job_running "$1"
}
signal_job() { # signal pid
  [[ "$(jobs -p %+)" == "$2" ]] || return 1
  kill -"$1" %+
}
run_app_bounded() { # command args...
  local cpid rc=0
  "$@" <"$app_answer_dir/in" >"$app_answer_dir/out" &
  cpid=$!
  if wait_for_job "$cpid" "$COMMAND_TIMEOUT_SECONDS"; then
    wait "$cpid" || rc=$?
    return "$rc"
  fi
  signal_job TERM "$cpid" || true
  if wait_for_job "$cpid" "$KILL_GRACE_SECONDS"; then
    wait "$cpid" || rc=$?
    log error "'$1 --resume-frozen' (pid $cpid) did not answer within ${COMMAND_TIMEOUT_SECONDS}s; sent SIGTERM, and it ended (wait status $rc)"
    return 124
  fi
  signal_job KILL "$cpid" || true
  if wait_for_job "$cpid" "$KILL_GRACE_SECONDS"; then
    wait "$cpid" || rc=$?
    log error "'$1 --resume-frozen' (pid $cpid) did not answer within ${COMMAND_TIMEOUT_SECONDS}s and was still running ${KILL_GRACE_SECONDS}s after SIGTERM; sent SIGKILL, and it ended (wait status $rc)"
  else
    log error "'$1 --resume-frozen' (pid $cpid) did not answer within ${COMMAND_TIMEOUT_SECONDS}s and has not exited ${KILL_GRACE_SECONDS}s after SIGKILL; it runs no further code, and it keeps the recovery lock until the kernel ends it"
  fi
  return 124
} 2>/dev/null

# End this run right after a timed-out undo command that is still alive:
# nothing else is undone, the journal and session stay exactly as read, and
# the lock stays with the live command's supervisor.
stop_transaction() { # what
  log error "recovery stopped after '$1' (still running); no further undo this run, journal and session kept unchanged until it ends"
  leave 1
}

# Prints one line per way the app's records about a kept display entry would
# not decode, or nothing. Read from the text of state.json $1 itself, not
# through plutil, which turns a number too small for a Double, such as
# 1e-400, into 0.0, reads 1., .5, +1 and other JSON5 forms the app refuses,
# and keeps the last of two copies of a key where the app's JSONDecoder keeps
# the first. The text is read the way the app reads it. Only keys of the
# top-level object count, with their \u escapes decoded, so
# "keptDisplayReadL\u0069t" is that key. Every value is stepped over whole: a
# string to its closing quote, an object or array to its closing bracket. So
# a saved audio name or UID, or a nested object, that holds such a key, a \u
# escape or a bad number holds no record. Each of the two numbers must be
# null or a JSON number a Swift Float holds: not above about 3.4028236e38, and
# either 0 in every digit or not so small that it rounds to 0 (below about
# 7.0065e-46). The range is read from the decimal exponent and the first 9
# significant digits, a little stricter than the app (from 3.40282356e38 and
# up to 7.01e-46), where no brightness lies. A string, object or array there
# is left to the type check. Also refused: one of the three keys found more
# than once at the top level, since plutil checks and republishes the last
# copy; a key with an escape JSON does not have, such as \x41, which plutil
# reads as A; and a top level this reader cannot follow, such as a key
# without quotes, a comment, a byte order mark other than UTF-8's, or a NUL
# byte. UTF-16 and UTF-32, which the app also reads, have NUL bytes, and the
# shell drops them from the text, which would turn such a file into other
# characters. Text outside ASCII cannot spell the keys, even under the
# decoder's Unicode equivalence, so a file with neither "keptDisplay" nor a
# backslash in it has none of them and is not read further. Any of these
# makes the journal malformed, as for a wrong type, and nothing is undone.
# A read that fails, of the text or of the file's size, returns 2 with
# nothing printed for it: its records are unknown, not absent, and the
# caller must not count the journal as clean.
record_text_problems() { # file
  local LC_ALL=C
  local text rest raw key c token depth str plain scalar number esc hex lost size v
  local n_low=0 n_lit=0 n_boot=0 digits sig exp e10 lead
  str='^"([^"\\]|\\.)*"'
  plain='^[^]["{}]+'
  scalar='^[^],}[:space:]]+'
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  esc='^u00(4[1-9A-Fa-f]|5[0-9Aa]|6[1-9A-Fa-f]|7[0-9Aa])'
  hex='^u[0-9A-Fa-f]{4}'
  lost="the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked"
  # cat's status follows its output, so a read that fails part way is
  # seen, and so is every newline at the end.
  if [[ "$1" == mem:* ]]; then
    v="mem_${1#mem:}"; text="${!v}"
  else
    text="$("$CAT" "$1"; echo ".$?")"
    [[ "${text##*.}" == 0 ]] || return 2
    text="${text%.*}"
  fi
  [[ "$text" == *keptDisplay* || "$text" == *\\* ]] || return 0
  # The shell drops NUL bytes from the text, so a file with one is longer
  # than the text read from it. A copy in memory has none: copy_private
  # refuses a file with one.
  if [[ "$1" != mem:* ]]; then
    size="$("$STAT" -f %z "$1")" || return 2
    if (( ${#text} != size )); then
      echo "$lost"
      return 0
    fi
  fi
  rest="${text#$'\xef\xbb\xbf'}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ "${rest:0:1}" == "{" ]] || { echo "$lost"; return 0; }
  rest="${rest:1}"
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    # An empty object, or a comma before the end, which the app accepts.
    [[ "${rest:0:1}" == "}" ]] && break
    [[ "$rest" =~ $str ]] || { echo "$lost"; return 0; }
    raw="${BASH_REMATCH[0]}"
    rest="${rest:${#raw}}"
    raw="${raw:1:${#raw}-2}"
    # The key as the app reads it. Of the escapes JSON has, only a \u of a
    # letter can be part of one of the three keys; the others stand for no
    # letter.
    key=""
    while [[ "$raw" == *\\* ]]; do
      key+="${raw%%\\*}"
      raw="${raw#*\\}"
      if [[ "$raw" =~ $esc ]]; then
        printf -v c '%b' "\\x${BASH_REMATCH[1]}"
        key+="$c"
        raw="${raw:5}"
      elif [[ "$raw" =~ $hex ]]; then
        key+="?"
        raw="${raw:5}"
      else
        case "${raw:0:1}" in
          '"'|\\|/|b|f|n|r|t) key+="?"; raw="${raw:1}" ;;
          *) echo "a key in state.json has an escape JSON does not have, so its records about a kept display entry cannot be checked"; return 0 ;;
        esac
      fi
    done
    key+="$raw"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    [[ "${rest:0:1}" == : ]] || { echo "$lost"; return 0; }
    rest="${rest:1}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    token=""
    case "${rest:0:1}" in
      '"')
        [[ "$rest" =~ $str ]] || { echo "$lost"; return 0; }
        rest="${rest:${#BASH_REMATCH[0]}}"
        ;;
      '{'|'[')
        depth=0
        while :; do
          case "${rest:0:1}" in
            '{'|'[') depth=$((depth + 1)); rest="${rest:1}" ;;
            '}'|']') depth=$((depth - 1)); rest="${rest:1}"; (( depth > 0 )) || break ;;
            '"')
              [[ "$rest" =~ $str ]] || { echo "$lost"; return 0; }
              rest="${rest:${#BASH_REMATCH[0]}}"
              ;;
            '') echo "$lost"; return 0 ;;
            *)
              [[ "$rest" =~ $plain ]] || { echo "$lost"; return 0; }
              rest="${rest:${#BASH_REMATCH[0]}}"
              ;;
          esac
        done
        ;;
      *)
        [[ "$rest" =~ $scalar ]] || { echo "$lost"; return 0; }
        token="${BASH_REMATCH[0]}"
        rest="${rest:${#token}}"
        ;;
    esac
    case "$key" in
      keptDisplayUnderLowPower) n_low=$((n_low + 1)) ;;
      keptDisplayReadLit) n_lit=$((n_lit + 1)) ;;
      # The boot is a string, whose type plutil checks.
      keptDisplayUnderLowPowerBoot) n_boot=$((n_boot + 1)); token="" ;;
      *) token="" ;;
    esac
    if [[ -n "$token" && "$token" != null ]]; then
      if [[ "$token" =~ $number ]]; then
        digits="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
        sig="${digits#"${digits%%[1-9]*}"}"
        if [[ -n "$sig" ]]; then
          exp="${BASH_REMATCH[6]#"${BASH_REMATCH[6]%%[1-9]*}"}"
          if (( ${#exp} > 18 )); then
            e10=1000000000000000000
          else
            e10=$((10#0$exp))
          fi
          [[ "${BASH_REMATCH[5]}" == - ]] && e10=$((-e10))
          e10=$((e10 + ${#BASH_REMATCH[1]} - 1 - (${#digits} - ${#sig})))
          lead="${sig}00000000"
          lead=$((10#${lead:0:9}))
          if (( e10 < -46 || (e10 == -46 && lead < 701000000) )); then
            echo "$key is ${token:0:40}, too small a number for the app to read"
          elif (( e10 > 38 || (e10 == 38 && lead > 340282355) )); then
            echo "$key is ${token:0:40}, too large a number for the app to read"
          fi
        fi
      else
        echo "$key is written as ${token:0:40}, which the app does not read as a number"
      fi
    fi
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "${rest:0:1}" in
      ,) rest="${rest:1}" ;;
      '}') break ;;
      *) echo "$lost"; return 0 ;;
    esac
  done
  (( n_low > 1 )) && echo "keptDisplayUnderLowPower is in the top level of state.json $n_low times; the app reads the first and plutil the last"
  (( n_lit > 1 )) && echo "keptDisplayReadLit is in the top level of state.json $n_lit times; the app reads the first and plutil the last"
  (( n_boot > 1 )) && echo "keptDisplayUnderLowPowerBoot is in the top level of state.json $n_boot times; the app reads the first and plutil the last"
  return 0
}

# Prints one line per way the journal does not have the shape the app writes
# (RuntimeState.swift). Present keys must have the right type; a JSON null is
# the same as an absent optional (Swift decodeIfPresent). Returns 2 when a
# read of the file failed, the conversion, its text for the kept display
# records or the type of a key, with read_why saying which: its shape is
# then unknown, not malformed.
journal_shape_problems() { # file
  local f="$1" key t i n json
  json="$(plutil_on -convert json -o - "$f" 2>/dev/null)" || { read_why="state.json could not be converted to JSON again (plutil -convert json failed)"; return 2; }
  if [[ "${json:0:1}" != "{" ]]; then
    echo "state.json is not a JSON object"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen savedMuted displayRestoreRefused keyboardRestoreRefused; do
    ty "$f" "$key" || return 2
    [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "$key is a $t, not a bool"
  done
  for key in savedOutputVolume savedDisplayBrightness savedKeyboardBrightness displayRestoredUnderLowPower; do
    ty "$f" "$key" || return 2
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  # The app's records about a kept display entry: kept for the app, never
  # read for an undo here. Each must still decode, or the app cannot read
  # the journal at all.
  for key in keptDisplayUnderLowPower keptDisplayReadLit; do
    ty "$f" "$key" || return 2
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  ty "$f" keptDisplayUnderLowPowerBoot || return 2
  [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "keptDisplayUnderLowPowerBoot is a $t, not a string"
  record_text_problems "$f" || { read_why="its text could not be read for the kept display records"; return 2; }
  ty "$f" frozenProcesses || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenProcesses is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "frozenProcesses.$i" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "frozenProcesses[$i] is not an object"
        else
          ty "$f" "frozenProcesses.$i.pid" || return 2
          [[ "$t" == integer ]] || echo "frozenProcesses[$i].pid is not an integer"
          for n in startedAt startedAtMicros; do
            ty "$f" "frozenProcesses.$i.$n" || return 2
            [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "frozenProcesses[$i].$n is a $t, not an integer"
          done
          ty "$f" "frozenProcesses.$i.bootSession" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "frozenProcesses[$i].bootSession is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" frozenPids || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenPids is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "frozenPids.$i" || return 2
        [[ -n "$t" ]] || break
        [[ "$t" == integer ]] || echo "frozenPids[$i] is not an integer"
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" savedAudioOutputs || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "savedAudioOutputs is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "savedAudioOutputs.$i" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "savedAudioOutputs[$i] is not an object"
        else
          ty "$f" "savedAudioOutputs.$i.deviceUID" || return 2
          [[ "$t" == string ]] || echo "savedAudioOutputs[$i].deviceUID is not a string"
          ty "$f" "savedAudioOutputs.$i.volume" || return 2
          [[ "$t" == float || "$t" == integer ]] || echo "savedAudioOutputs[$i].volume is not a number"
          ty "$f" "savedAudioOutputs.$i.muted" || return 2
          [[ "$t" == bool ]] || echo "savedAudioOutputs[$i].muted is not a bool"
          ty "$f" "savedAudioOutputs.$i.name" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].name is a $t, not a string"
          ty "$f" "savedAudioOutputs.$i.saveID" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].saveID is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" appNapOverrides || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "appNapOverrides is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "appNapOverrides.$i" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "appNapOverrides[$i] is not an object"
        else
          ty "$f" "appNapOverrides.$i.bundleId" || return 2
          [[ "$t" == string ]] || echo "appNapOverrides[$i].bundleId is not a string"
          ty "$f" "appNapOverrides.$i.previous" || return 2
          [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "appNapOverrides[$i].previous is a $t, not a bool"
        fi
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" sleepOffAttempt || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != dictionary ]]; then
      echo "sleepOffAttempt is a $t, not an object"
    else
      ty "$f" sleepOffAttempt.nonce || return 2
      [[ "$t" == string ]] || echo "sleepOffAttempt.nonce is not a string"
      ty "$f" sleepOffAttempt.owedBefore || return 2
      [[ "$t" == bool ]] || echo "sleepOffAttempt.owedBefore is not a bool"
      ty "$f" sleepOffAttempt.receipt || return 2
      [[ "$t" == string ]] || echo "sleepOffAttempt.receipt is not a string"
      ty "$f" sleepOffAttempt.predecessor || return 2
      [[ "$t" == string ]] || echo "sleepOffAttempt.predecessor is not a string"
      ty "$f" sleepOffAttempt.deadline || return 2
      [[ "$t" == integer ]] || echo "sleepOffAttempt.deadline is not an integer"
      ty "$f" sleepOffAttempt.expires || return 2
      [[ "$t" == integer ]] || echo "sleepOffAttempt.expires is not an integer"
      ty "$f" sleepOffAttempt.marker || return 2
      [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "sleepOffAttempt.marker is a $t, not a string"
      ty "$f" sleepOffAttempt.settled || return 2
      [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "sleepOffAttempt.settled is a $t, not a bool"
      ty "$f" sleepOffAttempt.resumes || return 2
      if [[ "$t" == dictionary ]]; then
        ty "$f" sleepOffAttempt.resumes.startedAt || return 2
        [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "sleepOffAttempt.resumes.startedAt is a $t, not an integer"
        ty "$f" sleepOffAttempt.resumes.firstEnd || return 2
        [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "sleepOffAttempt.resumes.firstEnd is a $t, not an integer"
      elif [[ -n "$t" && "$t" != "(any)" ]]; then
        echo "sleepOffAttempt.resumes is a $t, not an object"
      fi
    fi
  fi
  return 0
}

# Seconds since the epoch, into epoch, for a date in the one form
# session.json may hold; epoch is empty for anything else. Store.parseDate
# in the app reads exactly this form: 2027-01-15T08:00:00Z, which is what
# Store.swift writes, or the same with an offset such as +02:00 or -05:30
# in place of Z. Whole seconds, a date and time that exist, years 1970 to
# 9999, offsets up to 23:59. `date -j -f` refuses a month outside 1 to 12,
# a day above 31, an hour above 23, a minute above 59 and a second above
# 60, so those are refused here before it runs; it rolls an impossible day
# or second over, so the result is formatted back and must match. Returns
# 2 when date fails on a string it accepts, or prints no number: the date
# is then unknown, not malformed.
epoch_of() { # string
  local form='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|([+-])([0-9]{2}):([0-9]{2}))$'
  local clock offset=0 e back
  epoch=""
  [[ "$1" =~ $form ]] || return 0
  (( 10#${BASH_REMATCH[1]} >= 1970 )) || return 0
  (( 10#${BASH_REMATCH[2]} >= 1 && 10#${BASH_REMATCH[2]} <= 12 && 10#${BASH_REMATCH[3]} <= 31 \
     && 10#${BASH_REMATCH[4]} <= 23 && 10#${BASH_REMATCH[5]} <= 59 && 10#${BASH_REMATCH[6]} <= 60 )) || return 0
  if [[ "${BASH_REMATCH[7]}" != Z ]]; then
    (( 10#${BASH_REMATCH[9]} <= 23 && 10#${BASH_REMATCH[10]} <= 59 )) || return 0
    offset=$(( 10#${BASH_REMATCH[9]} * 3600 + 10#${BASH_REMATCH[10]} * 60 ))
    if [[ "${BASH_REMATCH[8]}" == - ]]; then offset=$(( -offset )); fi
  fi
  clock="${1:0:19}"
  e="$("$DATE" -j -u -f '%Y-%m-%dT%H:%M:%S' "$clock" +%s 2>/dev/null)" || return 2
  [[ "$e" =~ ^[0-9]+$ ]] || return 2
  back="$("$DATE" -u -r "$e" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" || return 2
  if [[ "$back" == "$clock" ]]; then epoch=$(( e - offset )); fi
  return 0
}

# epoch_of the string at a keypath, read exactly as the app's decoder sees
# it: read_at keeps a stored trailing newline and cuts only plutil's own,
# so "...Z\n" in the file is refused here as it is in the app. An absent
# key leaves epoch empty; a read that fails returns 2.
epoch_at() { # file keypath
  local rc=0
  epoch=""
  read_at "$1" "$2" raw || rc=$?
  (( rc != 2 )) || return 2
  (( rc == 0 )) || return 0
  epoch_of "$read_value" || { read_why="$2: date could not read $read_value"; return 2; }
}

# Prints one line per way session.json does not have the shape the app's
# Session decoder needs (Session.swift): a JSON object whose startedAt and
# endsAt are dates as Store.swift writes them and whose extensions is an
# array of numbers. All three are required; extra keys are ignored, as in
# Swift. The app refuses a file with any of these problems, so the shell
# does not act on its endsAt either. Returns 2, with read_why, when a read
# of the file failed: its shape is then unknown, not malformed.
session_shape_problems() { # file
  local f="$1" key t i c v
  # plutil also reads XML and binary property lists, which the app's
  # JSONDecoder refuses, so the file itself must start with "{" too. head
  # ends after one byte, and tr may then end on SIGPIPE (141); any other
  # status of either is a read that failed.
  if [[ "$f" == mem:* ]]; then
    v="mem_${f#mem:}"
    c="$(printf '%s' "${!v}" | LC_ALL=C "$TR" -d ' \t\r\n' 2>/dev/null | "$HEAD" -c 1; echo ".${PIPESTATUS[1]}.${PIPESTATUS[2]}")"
  else
    c="$(LC_ALL=C "$TR" -d ' \t\r\n' < "$f" 2>/dev/null | "$HEAD" -c 1; echo ".${PIPESTATUS[0]}.${PIPESTATUS[1]}")"
  fi
  if [[ "${c##*.}" != 0 ]] || [[ "${c%.*}" != *.0 && "${c%.*}" != *.141 ]]; then
    read_why="its first character could not be read"
    return 2
  fi
  c="${c%.*}"; c="${c%.*}"
  # Then plutil's conversion of the whole file. Only its own verdict on the
  # bytes, exit 1 with "Property List error", makes the file malformed; any
  # other failure is a read that failed, and the shape is unknown.
  if [[ "$c" == "{" ]]; then
    plutil_run -convert json -o - "$f"
    if [[ "$plutil_rc" == 0 ]]; then
      c="${plutil_out:0:1}"
    elif [[ "$plutil_rc" == 1 && "$plutil_err" == *": Property List error: "* ]]; then
      c=""
    else
      read_why="plutil -convert json exited ${plutil_rc:-?} (${plutil_err:-no message})"
      return 2
    fi
  fi
  if [[ "$c" != "{" ]]; then
    echo "session.json is not a JSON object"
    return 0
  fi
  for key in startedAt endsAt; do
    ty "$f" "$key" || return 2
    if [[ -z "$t" ]]; then
      echo "$key is missing"
    elif [[ "$t" != string ]]; then
      echo "$key is a JSON $t, not a date string"
    else
      epoch_at "$f" "$key" || return 2
      [[ -n "$epoch" ]] || echo "$key is not a date in the form 2027-01-15T08:00:00Z or 2027-01-15T10:00:00+02:00"
    fi
  done
  ty "$f" extensions || return 2
  if [[ -z "$t" ]]; then
    echo "extensions is missing"
  elif [[ "$t" != array ]]; then
    echo "extensions is a JSON $t, not an array"
  else
    i=0
    while :; do
      ty "$f" "extensions.$i" || return 2
      [[ -n "$t" ]] || break
      [[ "$t" == integer || "$t" == float ]] || echo "extensions[$i] is a JSON $t, not a number"
      i=$((i + 1))
    done
  fi
  return 0
}

# --- Settle an unfinished start ----------------------------------------------
# A start journals sleepOffAttempt (RuntimeState.swift) together with
# sleepDisabledByUs before its password dialog can run anything, and
# removes it once it has finished or rolled back. One still here belongs to
# a start that never finished, or whose settlement could not finish: the
# app died under it, or could not write. The root-owned receipt shows
# whether the command behind its dialog turned sleep off
# (SleepOffReceipts.swift), read under the receipt's own lock, which that
# command holds from before its checks until pmset exits. This run reads
# it exactly as the app does (attempt_verdict), whatever happened to the
# marker above:
#   - "never": the attempt has no marker (no dialog was shown); or the
#     receipt holds this start's nonce with "refused"; or another start's
#     line that names the same predecessor; or, once the start's expires
#     has passed (its command refuses from then on, while the wall clock
#     does not go back), the predecessor itself. Its command never turned
#     sleep off, and never will.
#   - "may": the receipt holds this start's "writing", a later start's
#     line, or, once expires has passed, anything else: a receipt that is
#     missing, replaced, unsafe or damaged.
#   - "undecided": the receipt stays locked or cannot be locked, or expires
#     has not passed and the receipt shows nothing yet: the dialog may
#     still be answered.
# Decided, the start never finished, so its session never began:
# session.json goes when its end is the attempt's deadline, so that session
# is never resumed (a SleepDisabled 1 someone else set would read as still
# off). Then the journal records the decision while the claim is still
# held (copy, edit, verify, rename, as below): sleepOffAttempt.settled, and
# sleepDisabledByUs as it was before the start (owedBefore) after "never",
# which keeps a restore an earlier session still owes, or set after "may",
# so the undo below runs. Only then does the start's claim on the receipt
# go back (the release file, see give_back_claim) and the journal drop
# sleepOffAttempt (finish_settlement). While the claim is held no start
# from another Insomnia folder can add a line to the receipt, so a crash or
# a failure before the decision is published leaves a receipt that still
# shows the same thing; after it, the decision itself is kept, and a
# settled record is only finished, never read against the receipt again.
#
# Anything that keeps the start unsettled (undecided, a lock, removal or
# journal write that fails) keeps the record, the sleep entry and the
# claim. The session is then ended rather than resumed, as --force would,
# and the run exits 1. The undo below follows attempt_hold: no pmset runs
# for the sleep entry while it says why (the receipt stays locked or the
# dialog can still be answered, so a command for that start may still act,
# whatever the time and whatever an earlier session owes; or the receipt
# shows "never" and no earlier restore is owed); otherwise sleep is
# restored and the entry stays with the record. A settled record that
# cannot be finished holds nothing back and keeps the entry for nothing;
# the run exits 1 so the next one finishes it. Skipped for a journal that
# is missing, not a regular file or malformed, which the rest of the run
# handles.

# Prints why the receipt or a folder above it fails the checks, or nothing.
# Every check matches SleepOffReceipts.swift and the root command
# (AdministratorPrompt.swift): the receipt, its folder and each folder above
# up to /, by lstat, must be root's (or RECEIPT_OWNER's), with no write
# permission for group or others; the receipt a regular file with one link,
# 82 bytes and mode 600, the rest folders. No folder may have an access
# control entry that allows anything, and the receipt must have exactly the
# one install.sh adds (receipt_access_problem).
receipt_unsafe() {
  local f="$RECEIPTS/$UID" p="$RECEIPTS" listing
  local folders=()
  while [[ -n "$p" ]]; do folders+=("$p"); p="${p%/*}"; done
  folders+=(/)
  listing="$("$STAT" -f '%u %Lp %l %z %HT' "$f" "${folders[@]}" 2>/dev/null)" || listing=""
  if ! printf '%s\n' "$listing" | /usr/bin/awk -v o="$RECEIPT_OWNER" -v n="$(( ${#folders[@]} + 1 ))" 'NR == 1 { k = NF == 6 && $5 == "Regular" && $6 == "File" && $3 == 1 && $4 == 82 && $2 == 600 }; NR > 1 { k = k && NF == 5 && $5 == "Directory" }; { k = k && ($1 == 0 || $1 == o) && $2 !~ /[2367].?$/ }; END { exit !(k && NR == n) }'; then
    echo "$f is missing, is not the 82-byte file install.sh made, mode 600, or someone other than root can change it or a folder above it"
    return 0
  fi
  listing="$("$LS" -lde "${folders[@]}" 2>/dev/null)" || listing=""
  if [[ -z "$listing" ]] || ! printf '%s\n' "$listing" | /usr/bin/awk '$1 ~ /^[0-9]+:$/ && / allow / { f = 1 }; END { exit f }'; then
    echo "a folder above $f has an access control entry that allows changes, or could not be listed"
    return 0
  fi
  receipt_access_problem "$f" "$UID"
}

# Prints why the access control list of the receipt $1 is not the one
# install.sh adds, or nothing. `ls -le` must show exactly one entry,
# ` 0: user:<name> allow read`, and `id -u <name>` must be $2: so only
# root and that user can open the receipt and hold its lock. ls(1) prints
# `inherited` after the name of an inherited entry, every right after
# `allow` or `deny`, and a UUID in place of `user:<name>` for an account the
# directory cannot name (file_cmds ls/print.c), so each of those fails. It
# never prints synchronize, prints the rights and flags only folders use
# only for a folder, and skips an entry it cannot read, so those pass here;
# the app's check reads every entry, right and flag. As
# SleepOffReceipts.swift and the root command.
receipt_access_problem() { # receipt uid
  local listing name
  listing="$("$LS" -le "$1" 2>/dev/null)" || listing=""
  name="$(printf '%s\n' "$listing" | /usr/bin/awk 'NR == 1 { k = /^-/ }; NR == 2 && k && /^ 0: user:[^ :]+ allow read$/ { n = substr($2, 6) }; END { if (NR == 2) print n }')"
  if [[ -z "$name" ]] || [[ "$("$ID" -u -- "$name" 2>/dev/null)" != "$2" ]]; then
    echo "$1 does not have exactly one access control entry, the one that lets uid $2 read it and nothing else, or its list could not be read"
  fi
}

# Opens the receipt read-only on fd 7 and locks it as the root command does
# (SleepOffReceipts.lock): the checks, the open, fd 7's identity against the
# path's, then `lockf <fd>`, whose lock lasts until fd 7 closes, then the
# checks again and the path must still name the locked file. Sets
# receipt_locked to that file's device:inode; otherwise receipt_lock_why,
# and receipt_lock_busy=1 when lockf found it locked for the whole
# RECEIPT_LOCK_TIMEOUT_SECONDS or failed, which decides nothing whenever it
# happens. fd 7 stays open only while locked; unlock_receipt closes it.
receipt_locked=""
lock_receipt() {
  local f="$RECEIPTS/$UID" why rc=0 opened
  receipt_locked=""; receipt_lock_why=""; receipt_lock_busy=0; receipt_read=0
  why="$(receipt_unsafe)"
  if [[ -n "$why" ]]; then receipt_lock_why="$why"; return 0; fi
  if ! { exec 7<"$f"; } 2>/dev/null; then
    receipt_lock_why="$f could not be opened"
    return 0
  fi
  opened="$("$STAT" -f '%d:%i' <&7 2>/dev/null)" || opened=""
  if [[ -z "$opened" || "$opened" != "$("$STAT" -f '%d:%i' "$f" 2>/dev/null)" ]]; then
    exec 7<&-
    receipt_lock_why="$f changed while it was opened"
    return 0
  fi
  "$LOCKF" -s -t "$RECEIPT_LOCK_TIMEOUT_SECONDS" 7 2>/dev/null || rc=$?
  if (( rc != 0 )); then
    exec 7<&-
    receipt_lock_busy=1
    if (( rc == 75 )); then
      receipt_lock_why="$f stayed locked for ${RECEIPT_LOCK_TIMEOUT_SECONDS} s: the command behind a password dialog may be running, or another Insomnia folder of this user, or something else running as this user, is holding it"
    else
      receipt_lock_why="$f could not be locked (lockf exit $rc)"
    fi
    return 0
  fi
  why="$(receipt_unsafe)"
  if [[ -n "$why" || "$opened" != "$("$STAT" -f '%d:%i' "$f" 2>/dev/null)" ]]; then
    exec 7<&-
    receipt_lock_why="$f was replaced while it was locked"
    return 0
  fi
  receipt_locked="$opened"
}
unlock_receipt() {
  if [[ -n "$receipt_locked" ]]; then exec 7<&-; fi
  receipt_locked=""
}

# The receipt's line, read through the locked fd 7
# (SleepOffReceipts.record): sets receipt_nonce, receipt_pred and
# receipt_word, or receipt_read_why. The read moves fd 7's offset, so it is
# read once per lock (receipt_read) and kept here.
read_receipt() {
  local size content line
  receipt_nonce=""; receipt_pred=""; receipt_word=""; receipt_read_why=""; receipt_read=1
  size="$("$STAT" -f '%l %z' <&7 2>/dev/null)" || size=""
  if [[ "$size" != "1 82" ]]; then
    receipt_read_why="$RECEIPTS/$UID is not the 82-byte file install.sh made"
    return 0
  fi
  content="$("$HEAD" -c 83 <&7 2>/dev/null; echo ".$?")"
  if [[ "${content##*.}" != 0 ]]; then
    receipt_read_why="$RECEIPTS/$UID could not be read (head exit ${content##*.})"
    return 0
  fi
  content="${content%.*}"
  line="${content%$'\n'}"
  if (( ${#content} != 82 )) || [[ "$line" == "$content" ]] \
     || ! [[ "$line" =~ ^([0-9A-F-]{36})\ ([0-9A-F-]{36})\ (writing|refused)$ ]]; then
    receipt_read_why="$RECEIPTS/$UID does not hold two nonces and writing or refused"
    return 0
  fi
  receipt_nonce="${BASH_REMATCH[1]}"
  receipt_pred="${BASH_REMATCH[2]}"
  receipt_word="${BASH_REMATCH[3]}"
}

# The release file's line (SleepOffReceipts.readRelease): sets
# release_nonce and release_word, or release_why. It is the user's own
# file, so it never shows that a start did not turn sleep off: it only
# keeps a start from another Insomnia folder from replacing the receipt's
# line while a start is not settled.
read_release() {
  local rf="$RECEIPTS/$UID.released" content line
  release_nonce=""; release_word=""; release_why=""
  if [[ -L "$rf" || ! -f "$rf" || "$("$STAT" -f %z "$rf" 2>/dev/null)" != 42 ]]; then
    release_why="$rf is not the 42-byte file install.sh made. Run install.sh again"
    return 0
  fi
  content="$("$HEAD" -c 43 "$rf" 2>/dev/null; echo ".$?")"
  if [[ "${content##*.}" != 0 ]]; then
    release_why="$rf could not be read (head exit ${content##*.})"
    return 0
  fi
  content="${content%.*}"
  line="${content%$'\n'}"
  if (( ${#content} != 42 )) || [[ "$line" == "$content" ]] \
     || ! [[ "$line" =~ ^([0-9A-F-]{36})\ (free|held)$ ]]; then
    release_why="$rf does not hold a nonce and free or held. Run install.sh again"
    return 0
  fi
  release_nonce="${BASH_REMATCH[1]}"
  release_word="${BASH_REMATCH[2]}"
}

# Writes "$1 $2" over the release file in place, then reads it back
# (SleepOffReceipts.writeRelease). Only a regular 42-byte file is opened;
# only root can create a file in RECEIPTS, so the open never creates one.
# Unlike the app, the shell has no fsync(2): a crash right after can lose
# the write (see the costs in SECURITY.md).
write_release() { # nonce free|held
  local rf="$RECEIPTS/$UID.released"
  [[ ! -L "$rf" && -f "$rf" && "$("$STAT" -f %z "$rf" 2>/dev/null)" == 42 ]] || return 1
  { printf '%s %s\n' "$1" "$2" 1<>"$rf"; } 2>/dev/null || return 1
  read_release
  [[ -z "$release_why" && "$release_nonce" == "$1" && "$release_word" == "$2" ]]
}

# Under the receipt's lock, gives back the claim of the start with nonce $1
# (SleepOffReceipts.release): when the release file shows "$1 held", writes
# the receipt's nonce there, free. Sets gave_back=1 when it wrote. Returns
# non-zero, with claim_why, when the release file or the receipt's line
# cannot be read, or the write fails.
give_back_claim() { # nonce
  gave_back=0; claim_why=""
  read_release
  if [[ -n "$release_why" ]]; then claim_why="$release_why"; return 1; fi
  [[ "$release_word" == held && "$release_nonce" == "$1" ]] || return 0
  (( receipt_read )) || read_receipt
  if [[ -z "$receipt_nonce" ]]; then claim_why="$receipt_read_why"; return 1; fi
  if ! write_release "$receipt_nonce" free; then claim_why="$RECEIPTS/$UID.released could not be written"; return 1; fi
  gave_back=1
}

# What the receipt shows about the journaled start (SleepOffReceipts
# verdict, with no dialog known to be over): sets verdict to never, may or
# undecided and verdict_why, from lock_receipt's outcome and the clock.
attempt_verdict() { # nonce predecessor identity expires now has-marker
  local f="$RECEIPTS/$UID" over=0 until
  verdict=may; verdict_why=""
  if [[ "$6" != 1 ]]; then verdict=never; return 0; fi
  (( $5 >= $4 )) && over=1
  until="until $("$DATE" -u -r "$4" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$4")"
  if (( receipt_lock_busy )); then
    verdict=undecided; verdict_why="$receipt_lock_why"
    return 0
  fi
  if [[ -z "$receipt_locked" ]]; then
    verdict_why="$receipt_lock_why"
  elif [[ "$receipt_locked" != "$3" ]]; then
    verdict_why="$f is not the file it was when the start began"
  else
    read_receipt
    if [[ -n "$receipt_read_why" ]]; then
      verdict_why="$receipt_read_why"
    elif [[ "$receipt_nonce" == "$1" ]]; then
      if [[ "$receipt_word" == refused ]]; then verdict=never; else verdict_why="$f holds that start's writing line: its command was about to turn sleep off and may have"; fi
      return 0
    elif [[ "$receipt_nonce" == "$2" ]]; then
      if (( over )); then verdict=never; else verdict=undecided; verdict_why="the password dialog of that start can still be answered $until"; fi
      return 0
    elif [[ "$receipt_pred" == "$2" ]]; then
      verdict=never
      return 0
    else
      verdict_why="$f holds a later start's line, which no longer shows what the command for this start did"
      return 0
    fi
  fi
  if (( ! over )); then
    verdict=undecided; verdict_why="$verdict_why; a command for that start could still write $until"
  fi
}

# Keeps the start journaled and unsettled, with the reason, as the app's
# keepAttempt does: attempt_hold says why no pmset may run for the sleep
# entry, or is empty. Undecided always holds it: a pmset its command
# already started may still turn sleep off after the undo, and expires only
# stops commands that have not begun. "never" holds it unless an earlier
# restore is owed. The session is ended rather than resumed.
attempt_kept=0
attempt_hold=""
keep_attempt() { # verdict owedBefore why
  attempt_kept=1
  settle_failed="$3"
  case "$1" in
    never) [[ "$2" == true ]] || attempt_hold="the receipt shows that the command behind that start's dialog never turned sleep off and no earlier restore is owed, but $3" ;;
    undecided) attempt_hold="$3" ;;
  esac
  force=1
}

# Renames the edited copy $1 over state.json, once plutil reads it whole as
# a JSON object and state.json is still the file this run copied, then
# copies the new journal again for the reads that follow. Returns 0; 1 with
# nothing published and the edited copy removed, publish_why saying why; 2
# when it was published but could not be copied again, read_why saying
# why. state_copy is then empty, so no later edit starts from an old copy.
publish_state() { # edited-copy
  publish_why=""
  if ! json_object "$1"; then
    publish_why="the edited copy is not a JSON object"
  elif ! state_unchanged; then
    publish_why="$STATE changed since this run read it"
  elif ! "$MV" -f "$1" "$STATE"; then
    publish_why="the edited copy could not be renamed over it"
  else
    copy_state && return 0
    state_copy_rc=2
    read_why="$STATE was published, but could not be read again ($copy_why)"
    return 2
  fi
  "$RM" -f "$1"
  return 1
}

# Publishes $STATE with the edits given (remove:KEYPATH or
# true:KEYPATH / false:KEYPATH), as one copy, edit, verify and rename
# (publish_state, whose status it returns). Returns 1, with nothing
# published and no copy left, when any step fails.
# Every publish copies the live journal with cp, as main does, so its
# extended attributes go with it (cp(1) copies an access control list only
# with -p, which main does not pass either), and then requires the copy to
# hold the bytes this run read (same_as_read): a journal that changed
# since, or a cp that copied something else, is not published. A 0200
# journal its owner reads only through an allow entry keeps that entry: cp
# cannot read its extended attributes, so its publish fails, as on main.
edit_state() { # edit...
  local tmp="$APP_SUPPORT/.state.json.settle.$$" e ok=1
  [[ -n "$state_copy" ]] && "$CP" "$STATE" "$tmp" && same_as_read "$tmp" "$state_copy" || ok=0
  for e in "$@"; do
    (( ok == 1 )) || break
    case "$e" in
      remove:*) "$PLUTIL" -remove "${e#remove:}" "$tmp" >/dev/null 2>&1 || ok=0 ;;
      true:*|false:*) "$PLUTIL" -replace "${e#*:}" -bool "${e%%:*}" "$tmp" >/dev/null 2>&1 || ok=0 ;;
      *) ok=0 ;;
    esac
  done
  if (( ok == 0 )); then
    "$RM" -f "$tmp"
    return 1
  fi
  publish_state "$tmp"
}

# Finishes a settlement whose decision is in the journal
# (sleepOffAttempt.settled), under the receipt's lock, which the caller
# holds and this lets go: gives the start's claim back and publishes the
# journal without sleepOffAttempt. A failure leaves the settled record,
# which holds nothing back, and the run exits 1 so the next one finishes
# it.
finish_settlement() { # nonce what-was-removed
  if ! give_back_claim "$1"; then
    unlock_receipt
    settle_failed="an unfinished start is settled, but its claim on the receipt could not be given back ($claim_why)$2"
    log error "$settle_failed"
    return 0
  fi
  local rc=0
  edit_state remove:sleepOffAttempt || rc=$?
  if (( rc == 1 )); then
    unlock_receipt
    settle_failed="an unfinished start is settled, but its settled record could not be removed from $STATE$2"
    log error "$settle_failed"
    return 0
  fi
  unlock_receipt
  log info "the settlement is finished: $( (( gave_back )) && echo "the start's claim on the receipt was given back" || echo "the start held no claim on the receipt") and its record removed"
}

# A marker this run deleted that no journaled start accounts for was left
# by a build from before sleepOffAttempt, or by a start that finished or
# rolled back but could not delete it. Whether a command behind its dialog
# turned sleep off is unknown, so session.json beside it is never resumed:
# it goes, and a sleep entry still journaled is undone below like any other.
# A session that had started and lost its marker only to a failed delete
# ends early, which is the safe side. If session.json cannot be removed,
# this run undoes the journal as --force would and exits 1.
drop_unrecorded_session() {
  [[ -n "$removed_marker" && -f "$SESSION" ]] || return 0
  if "$RM" -f "$SESSION"; then
    log info "removed $SESSION: it was beside a pending-start marker that no journaled start accounts for, so it is never resumed"
  else
    settle_failed="$SESSION, beside a pending-start marker that no journaled start accounts for, could not be removed"
    log error "could not remove $SESSION beside a pending-start marker that no journaled start accounts for; undoing the journal as --force would"
    force=1
  fi
}

# The journal is copied here once (copy_state, whose status is kept in
# state_copy_rc) and read from that copy from then on; only a publish of
# this run copies it again. A journal that cannot be copied is not settled
# here: the journal read below reports it, and the run ends there.
state_copy_rc=""
settle_attempt() {
  local nonce owed receipt pred deadline expires now has_marker=0 owes removed="" rc=0 matched=0 session_why=""
  if [[ ! -f "$STATE" ]]; then
    drop_unrecorded_session
    return 0
  fi
  copy_state || true
  if (( state_copy_rc != 0 )) || ! plutil_on -convert json -o /dev/null "$state_copy" >/dev/null 2>&1; then
    drop_unrecorded_session
    return 0
  fi
  type_at "$state_copy" sleepOffAttempt || rc=$?
  if (( rc == 2 )); then
    drop_unrecorded_session
    log error "$STATE: $read_why, so whether it journals an unfinished start is unknown; nothing undone, evidence kept"
    leave 1
  fi
  if [[ "$t" != dictionary ]]; then
    drop_unrecorded_session
    return 0
  fi
  # A journal that could not be read whole is handled as below: nothing
  # undone and exit 1, here before the start's record is read.
  rc=0; shape_of journal "$state_copy" || rc=$?
  if (( rc != 0 )); then
    log error "$STATE could not be read whole (its JSON, or its text for the kept display records), so the unfinished start it journals was not settled; nothing undone, evidence kept: $read_why. Check that it is a regular file this user can read"
    leave 1
  fi
  [[ -z "$shape_lines" ]] || return 0
  state_read sleepOffAttempt.nonce raw; nonce="$read_value"
  state_read sleepOffAttempt.settled raw
  if [[ "$read_value" == true ]]; then
    # An earlier settlement published its decision but did not finish.
    # Only the decision counts: the receipt is not read against it again.
    lock_receipt
    if [[ -z "$receipt_locked" ]]; then
      settle_failed="an unfinished start is settled, but the receipt could not be locked to give its claim back ($receipt_lock_why)"
      log error "$settle_failed"
      return 0
    fi
    log info "finishing the settlement of an earlier start, which the journal records as settled"
    finish_settlement "$nonce" ""
    return 0
  fi
  state_read sleepOffAttempt.owedBefore raw; owed="$read_value"
  state_read sleepOffAttempt.receipt raw; receipt="$read_value"
  state_read sleepOffAttempt.predecessor raw; pred="$read_value"
  state_read sleepOffAttempt.deadline raw; deadline="$read_value"
  state_read sleepOffAttempt.expires raw; expires="$read_value"
  rc=0; type_at "$state_copy" sleepOffAttempt.marker || rc=$?
  if (( rc == 2 )); then
    log error "$STATE: $read_why; nothing undone, evidence kept, and the next run tries again"
    leave 1
  fi
  [[ "$t" == string ]] && has_marker=1
  lock_receipt
  # A clock that cannot be read leaves the start unexpired: undecided
  # unless the receipt shows something else.
  now="$("$DATE" -u +%s 2>/dev/null)" || now=0
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  attempt_verdict "$nonce" "$pred" "$receipt" "$expires" "$now" "$has_marker"
  if [[ "$verdict" == undecided ]]; then
    unlock_receipt
    keep_attempt "$verdict" "$owed" "an unfinished start is not settled yet: $verdict_why"
    log info "$settle_failed; it stays journaled, the session is ended rather than resumed, and sleep is left as it is"
    return 0
  fi
  if [[ -z "$receipt_locked" ]]; then
    keep_attempt "$verdict" "$owed" "an unfinished start could not be settled: the receipt could not be locked to give its claim back ($receipt_lock_why). Nothing was removed"
    log error "$settle_failed"
    return 0
  fi
  if [[ "$verdict" == never ]]; then
    owes="$owed"
    log info "settling an unfinished start: its receipt shows the command behind its dialog never turned sleep off; sleepDisabledByUs goes back to $owed"
  else
    owes=true
    log info "settling an unfinished start as one that may have turned sleep off ($verdict_why); sleepDisabledByUs stays set"
  fi
  # Only a session.json this run can read as a session is matched; one it
  # cannot open, or that is not a regular file, is treated as expired below,
  # and the app never resumes it. One whose read fails some other way is
  # unknown: nothing is removed, and the run ends here.
  if [[ -f "$SESSION" ]]; then
    rc=0; copy_private "$SESSION" session.json || rc=$?
    if (( rc == 2 )); then
      session_why="$copy_why"
    elif (( rc == 0 )); then
      rc=0; shape_of session "$copy_path" || rc=$?
      if (( rc == 0 )) && [[ -z "$shape_lines" ]]; then
        epoch_at "$copy_path" endsAt || rc=$?
        if (( rc == 0 )) && [[ -n "$epoch" && "$epoch" == "$deadline" ]]; then matched=1; fi
      fi
      if (( rc != 0 )); then session_why="$read_why"; fi
    fi
  fi
  if [[ -n "$session_why" ]]; then
    unlock_receipt
    log error "$SESSION could not be read ($session_why), so the unfinished start was not settled; nothing undone, evidence kept"
    leave 1
  fi
  if (( matched )); then
    if ! "$RM" -f "$SESSION"; then
      unlock_receipt
      keep_attempt "$verdict" "$owed" "an unfinished start could not be settled: $SESSION could not be removed. Nothing was removed"
      log error "$settle_failed"
      return 0
    fi
    removed="; $SESSION of that start was removed"
    log info "removed $SESSION: its start never finished, so it is never resumed"
  fi
  # The decision, published while the claim is still held. Published but
  # not read again (2) counts as published: the record that holds it back
  # is gone from the journal only once finish_settlement removes it.
  rc=0; edit_state true:sleepOffAttempt.settled "$owes:sleepDisabledByUs" || rc=$?
  if (( rc == 1 )); then
    unlock_receipt
    keep_attempt "$verdict" "$owed" "an unfinished start could not be settled: the settled journal could not be published to $STATE$removed"
    log error "$settle_failed"
    return 0
  fi
  finish_settlement "$nonce" "$removed"
}
# This run's private folder for its copies (see copy_private). A folder
# left by an earlier run that ended without leave is removed first, unless
# this run shares its caller's lock. Without one (a full disk), the copies
# are kept in memory and read with the same checks.
if (( ! lock_shared )); then "$RM" -rf "$APP_SUPPORT"/.backstop-read.* 2>/dev/null || true; fi
if ! READS="$("$MKTEMP" -d "$APP_SUPPORT/.backstop-read.XXXXXX" 2>/dev/null)"; then
  READS=""
  log warn "could not create a private folder in $APP_SUPPORT for this run's copies of session.json and state.json; this run keeps its copies in memory" || true
fi
settle_failed=""
settle_attempt

# --- Read the session --------------------------------------------------------
# session_state: none | valid | expired | malformed | unreadable
session_state=none
ends_at=""
unreadable_why=""
session_problems=""
if [[ -e "$SESSION" ]]; then
  # Only a regular file is opened: open(2) on a FIFO with no writer, or on
  # some devices, blocks, and this run holds the recovery lock.
  # It is read from a private copy (copy_private). A read that fails other
  # than for permissions or I/O, or a date that cannot be worked out, ends
  # the run: whether the session is still on is unknown.
  session_rc=4
  if [[ -f "$SESSION" ]]; then session_rc=0; copy_private "$SESSION" session.json || session_rc=$?; fi
  if (( session_rc == 4 )); then
    session_state=unreadable
    unreadable_why="it is not a regular file, so it is not opened"
  elif (( session_rc == 3 )); then
    session_state=unreadable
    unreadable_why="permissions or I/O"
  elif (( session_rc != 0 )); then
    log error "$SESSION could not be read ($copy_why); nothing undone, evidence kept, will retry"
    leave 1
  else
    session_copy="$copy_path"
    session_rc=0; shape_of session "$session_copy" || session_rc=$?
    if (( session_rc != 0 )); then
      log error "$SESSION could not be read ($read_why); nothing undone, evidence kept, will retry"
      leave 1
    fi
    session_problems="$shape_lines"
    if [[ -n "$session_problems" ]]; then
      session_state=malformed
    else
      epoch_at "$session_copy" endsAt || session_rc=$?
      ends_at="$read_value"
      if (( session_rc != 0 )) || [[ -z "$epoch" ]]; then
        log error "$SESSION: its endsAt could not be read again (${read_why:-no date}); nothing undone, evidence kept, will retry"
        leave 1
      fi
      now="$("$DATE" -u +%s 2>/dev/null)" || now=""
      if ! [[ "$now" =~ ^[0-9]+$ ]]; then
        log error "the clock could not be read (date -u +%s printed '$now'), so whether $SESSION has ended is unknown; nothing undone, evidence kept, will retry"
        leave 1
      fi
      if (( epoch > now )); then
        session_state=valid
      else
        session_state=expired
      fi
    fi
  fi
fi

if [[ "$session_state" == valid ]] && (( force == 0 )); then
  exit_unless_marker_stuck "session.json is valid until $ends_at"
fi

# --- Read the journal --------------------------------------------------------
# journal_state: missing | malformed | unreadable | clean | dirty
# The copy settle_attempt made is read, or the one its publish made. A
# state.json that settle_attempt did not copy, because it was not a regular
# file then, is copied now only if it still is not one.
journal_why=""
if [[ -z "$state_copy_rc" && -f "$STATE" ]]; then
  journal_state=unreadable
  journal_why="it became a regular file while this run read it"
elif [[ -z "$state_copy_rc" ]] && [[ ! -e "$STATE" ]]; then
  journal_state=missing
elif [[ -z "$state_copy_rc" ]] || (( state_copy_rc == 4 )); then
  # Never opened, for the same reason as session.json above.
  journal_state=malformed
  shape_problems="not a regular file"
elif (( state_copy_rc == 3 )); then
  journal_state=malformed
  shape_problems="not valid JSON (it could not be read: $state_copy_why)"
elif (( state_copy_rc != 0 )); then
  journal_state=unreadable
  journal_why="$state_copy_why"
elif ! plutil_on -convert json -o /dev/null "$state_copy" >/dev/null 2>&1; then
  journal_state=malformed
  shape_problems="not valid JSON"
elif ! shape_of journal "$state_copy"; then
  journal_state=unreadable
  journal_why="$read_why"
elif [[ -n "$shape_lines" ]]; then
  journal_state=malformed
  shape_problems="$shape_lines"
else
  journal_state=clean
fi

if [[ "$journal_state" == unreadable ]]; then
  log error "$STATE could not be read whole (its JSON, or its text for the kept display records); nothing undone, evidence kept: $journal_why. Check that it is a regular file this user can read, then rerun"
  leave 1
fi

if [[ "$journal_state" == malformed ]]; then
  log_lines error "$shape_problems" "$STATE: "
  log error "$STATE is unreadable or malformed; nothing undone, evidence kept. Open Insomnia or repair the file, then rerun"
  leave 1
fi

sleep_held=false; low_power=false; docker_frozen=false; has_audio=0
has_display=0; has_keyboard=0; refused_display=0; refused_keyboard=0
frozen_count=0; legacy_count=0; app_nap_count=0; output_count=0
if [[ "$journal_state" == clean ]]; then
  # Every read below is of the copy; one that fails ends the run
  # (state_read), so a key is only ever taken as absent when plutil says so.
  state_read sleepDisabledByUs raw; [[ "$read_value" == true ]] && sleep_held=true
  state_read lowPowerSetByUs raw; [[ "$read_value" == true ]] && low_power=true
  state_read dockerFrozen raw; [[ "$read_value" == true ]] && docker_frozen=true
  state_read savedOutputVolume raw; (( found )) && has_audio=1
  state_read savedMuted raw; (( found )) && has_audio=1
  state_read savedDisplayBrightness raw
  if (( found )); then
    state_read displayRestoreRefused raw
    if [[ "$read_value" == true ]]; then refused_display=1; else has_display=1; fi
  fi
  state_read savedKeyboardBrightness raw
  if (( found )); then
    state_read keyboardRestoreRefused raw
    if [[ "$read_value" == true ]]; then refused_keyboard=1; else has_keyboard=1; fi
  fi
  state_count frozenProcesses; frozen_count="$count"
  state_count frozenPids; legacy_count="$count"
  state_count appNapOverrides; app_nap_count="$count"
  # Kept for the app and not counted as dirty; see the header.
  state_count savedAudioOutputs; output_count="$count"
  if [[ "$sleep_held" == true || "$low_power" == true || "$docker_frozen" == true ]] \
     || (( has_audio == 1 || has_display == 1 || has_keyboard == 1 || frozen_count > 0 || legacy_count > 0 || app_nap_count > 0 )); then
    journal_state=dirty
  fi
fi

# Brightness the app kept after its private-call guard refused the
# restore: it stays in the journal for a build that can make the call, and
# is not dirty, since neither this script nor that app build can restore it.
refused_note=""
if (( refused_display == 1 || refused_keyboard == 1 )); then
  refused=()
  (( refused_display == 1 )) && refused+=("saved display brightness")
  (( refused_keyboard == 1 )) && refused+=("saved keyboard backlight")
  refused_note="$(IFS=,; echo "${refused[*]}") kept: the app's private-call guard refused that restore on this macOS, so nothing here or in that app build can restore it; set the level with the brightness keys"
fi

# session.json that is not a session, or cannot be read. Its bytes are
# kept beside it under a name the app writes too and `uninstall.sh --purge`
# removes; the next run then sees no session. A rename never opens the
# file, so a FIFO or a file without read permission moves the same way.
# Called only once the journal is clean, so nothing recorded is lost with
# it. Never overwrites: a taken name gets -1, -2, ... and `mv -n` declines
# rather than replace a file that appeared meanwhile (it exits 0 then,
# hence the check of both paths afterwards).
quarantine_session() {
  local base dest n what
  log_lines warn "$session_problems" "$SESSION: "
  what="session.json unreadable"
  [[ "$session_state" == unreadable ]] && what="session.json cannot be read ($unreadable_why)"
  base="$SESSION.unreadable-$("$DATE" -u +%Y%m%dT%H%M%SZ)"
  dest="$base"; n=0
  while [[ -e "$dest" || -L "$dest" ]]; do n=$((n + 1)); dest="$base-$n"; done
  if "$MV" -n "$SESSION" "$dest" 2>/dev/null && [[ ! -e "$SESSION" && ! -L "$SESSION" ]] && [[ -e "$dest" || -L "$dest" ]]; then
    log warn "$what; moved to $dest and treated as no session"
    return 0
  fi
  if [[ "$session_state" == unreadable ]]; then
    log error "$what and could not be moved to $dest; kept in place, and the next run tries again. Remove it or move it out of $APP_SUPPORT: if it became readable there, the app would resume it: $SESSION"
  else
    log error "$what and could not be moved to $dest; kept in place"
  fi
  return 1
}

case "$session_state" in
  none)       session_note="no session" ;;
  valid)      session_note="forced end of session (endsAt=$ends_at)" ;;
  expired)    session_note="session expired (endsAt=$ends_at)" ;;
  malformed)  session_note="session.json unreadable" ;;
  unreadable) session_note="session.json cannot be read ($unreadable_why), so its end time is unknown; treated as expired" ;;
esac

outputs_note="saved audio for $output_count output device(s), kept for the app, which restores each once it is connected"

if [[ "$journal_state" != dirty ]]; then
  # Nothing journaled: nothing to undo, and nothing privileged runs.
  if [[ "$session_state" != none ]] && (( output_count > 0 )); then
    log info "journal clean apart from $outputs_note"
  fi
  if [[ "$session_state" == unreadable ]]; then
    log info "$session_note; nothing journaled to undo"
  fi
  if [[ "$session_state" == malformed || "$session_state" == unreadable ]]; then
    [[ -n "$refused_note" ]] && log info "$refused_note"
    quarantine_session || leave 1
  elif [[ "$session_state" != none ]]; then
    if [[ "$journal_state" == missing ]]; then
      log warn "$session_note; no journal on disk, nothing recorded to undo"
    else
      log info "$session_note; journal already clean"
    fi
    [[ -n "$refused_note" ]] && log info "$refused_note"
    "$RM" -f "$SESSION"
  fi
  exit_unless_marker_stuck "journal is clean"
fi

# --- Undo --------------------------------------------------------------------
log info "$session_note; restoring from journal"

failures=()   # what is still journaled after this run
changed=0     # whether the journal needs republishing

new_sleep="$sleep_held"
if [[ "$sleep_held" == true && -n "$attempt_hold" ]]; then
  # The start the journal still records: no pmset may run for it yet (see
  # settle_attempt). Its failure is reported below.
  log info "sleepDisabledByUs stays journaled, and sleep is left as it is: $attempt_hold"
elif [[ "$sleep_held" == true ]]; then
  if run_bounded "$SUDO" -n "$PMSET" -a disablesleep 0; then
    log info "pmset -a disablesleep 0 ok"
    if (( marker_stuck )); then
      log error "sleep restored, but sleepDisabledByUs stays journaled while $PENDING is present"
    elif (( attempt_kept )); then
      log error "sleep restored, but sleepDisabledByUs stays journaled with the start the journal still records"
    else
      new_sleep=false; changed=1
    fi
  else
    if (( command_alive )); then stop_transaction "pmset -a disablesleep 0"; fi
    log error "pmset -a disablesleep 0 failed (sudoers rule missing? run install.sh); keeping journal entry for retry"
    failures+=("sleep is still disabled: pmset -a disablesleep 0 failed")
  fi
fi

# The app's record of a kept display entry the mode was over
# (keptDisplayUnderLowPower). The mode may have been on in this boot until
# now, and the panel comes back from it over a time nobody has measured, so
# the record is given this boot before the mode goes off, in a journal
# published on its own. The app then takes no reading of that entry in this
# boot as the user's level, as when it switches the mode off itself. That
# holds also when the journal written after the undo below never lands: the
# file then still says lowPowerSetByUs, next to a record from this boot,
# which the app reads as its own mode on in this boot. A boot that cannot be
# read is written empty, which the app reads as this boot's too, and a
# record that already has this boot is left as it is. Returns non-zero when
# the record could not be published; the caller then leaves the mode on,
# since switched off with the old boot on disk, the app could take the panel
# on its way back for the level the user set. A journal with no record, or a
# null one, gets none. Returns 2, with read_why, when a read of the record
# failed or the published journal could not be read again: the caller then
# leaves the mode on and ends the run.
prepare_low_power_off() {
  local boot tmp ok=1 rc=0
  type_at "$state_copy" keptDisplayUnderLowPower || rc=$?
  (( rc != 2 )) || return 2
  [[ "$t" == float || "$t" == integer ]] || return 0
  boot="$("$SYSCTL" -n kern.bootsessionuuid 2>/dev/null)" || boot=""
  rc=0; read_at "$state_copy" keptDisplayUnderLowPowerBoot raw || rc=$?
  (( rc != 2 )) || return 2
  [[ "$read_value" == "$boot" ]] && return 0
  tmp="$APP_SUPPORT/.state.json.backstop-boot.$$"
  "$CP" "$STATE" "$tmp" && same_as_read "$tmp" "$state_copy" || ok=0
  if (( ok == 1 )); then
    "$PLUTIL" -replace keptDisplayUnderLowPowerBoot -string "$boot" "$tmp" >/dev/null 2>&1 || ok=0
  fi
  if (( ok == 0 )); then
    "$RM" -f "$tmp"
    return 1
  fi
  rc=0; publish_state "$tmp" || rc=$?
  (( rc != 1 )) || return 1
  log info "kept display entry's record given this boot (${boot:-unreadable, written empty}) before Low Power Mode is switched off"
  return "$rc"
}

new_low="$low_power"
if [[ "$low_power" == true ]]; then
  low_rc=0; prepare_low_power_off || low_rc=$?
  if (( low_rc == 2 )); then
    log error "$STATE: $read_why; Low Power Mode left on and nothing more undone this run, the journal is kept, and the next run tries again"
    leave 1
  fi
  if (( low_rc == 1 )); then
    log error "could not publish this boot for the kept display entry's record to $STATE; Low Power Mode left on, keeping journal entry for retry"
    failures+=("Low Power Mode is still set: state.json could not take this boot for the kept display entry's record, so the mode was not switched off")
  elif run_bounded "$SUDO" -n "$PMSET" -b lowpowermode 0; then
    log info "pmset -b lowpowermode 0 ok"
    new_low=false; changed=1
  else
    if (( command_alive )); then stop_transaction "pmset -b lowpowermode 0"; fi
    log error "pmset -b lowpowermode 0 failed; keeping journal entry for retry"
    failures+=("Low Power Mode is still set: pmset -b lowpowermode 0 failed")
  fi
fi

# Frozen processes. Each entry is kept verbatim (unknown fields included)
# unless it is observed gone, running, or mismatched, or successfully resumed.
# kept[i] marks entry i as kept; the kept entries are republished in journal
# order whatever order they were settled in.
kept=()
keep_entry() { # index
  kept[$1]=1
}
# Observe one pid. Sets observation to one of:
#   gone      ps exited 1 and printed nothing (the only absence signal ps gives)
#   seen      p_epoch, p_stat, p_uid are filled in
#   unknown   ps failed some other way or printed something unparseable
observe() { # pid
  local out rc=0
  observation=unknown; p_epoch=""; p_stat=""; p_uid=""
  out="$("$PS" -o lstart=,stat=,uid= -p "$1" 2>&1)" || rc=$?
  if (( rc == 1 )) && [[ -z "$out" ]]; then
    observation=gone
    return 0
  fi
  (( rc == 0 )) || return 0
  local w mon day time year stat uid
  # The words of the first line, as read would split them. Not a
  # here-string: see log_lines.
  out="${out%%$'\n'*}"
  set -f
  # shellcheck disable=SC2086  # split into words on purpose
  set -- $out
  set +f
  w="${1:-}"; mon="${2:-}"; day="${3:-}"; time="${4:-}"; year="${5:-}"; stat="${6:-}"; uid="${7:-}"
  [[ -n "$w" && -n "$mon" && -n "$day" && -n "$time" && -n "$year" && -n "$stat" && -n "$uid" ]] || return 0
  p_epoch="$("$DATE" -j -u -f '%a %b %d %H:%M:%S %Y' "$w $mon $day $time $year" +%s 2>/dev/null || true)"
  [[ -n "$p_epoch" ]] && [[ "$uid" =~ ^[0-9]+$ ]] || return 0
  p_stat="$stat"; p_uid="$uid"
  observation=seen
}
# Entries that record microseconds, collected in journal order during the
# loop below and handed to the app binary together after it: app_index holds
# each entry's index, app_pid its pid, app_args its four fields.
app_index=()
app_pid=()
app_args=()
# Ask the app binary about every collected entry in one bounded call (see
# the frozenProcesses rule in the header). It answers one line per entry, in
# input order, "<pid> <word>", and exits 0 when every word is resumed or
# gone and 1 otherwise. The answer is checked whole: exactly one line per
# entry, each with that entry's pid, one space and a known word and nothing
# else, and an exit status that agrees with the words. Anything else, a
# timeout included, keeps every entry of the call unsignaled by this run. The
# binary may have resumed some of them before it went wrong; the next run
# finds those running and clears them.
resume_via_app() {
  local n=${#app_pid[@]} k rc=0 valid=1 settled=1 expected=0 size line word excerpt="" p answer declared info_rc=0 info_why=""
  local -a words
  words=()
  if [[ ! -x "$INSOMNIA_BIN" ]]; then
    for (( k = 0; k < n; k++ )); do
      log error "pid ${app_pid[k]} needs the app binary for its microsecond identity check, but $INSOMNIA_BIN is missing or not executable; kept, not signaled"
      failures+=("pid ${app_pid[k]} was not resumed: app binary missing at $INSOMNIA_BIN")
      keep_entry "${app_index[k]}"
    done
    return 0
  fi
  # A regular file only, read from a private copy (copy_private): a FIFO
  # there could block this run under the lock. A read that fails keeps
  # every entry, as an interface the bundle does not declare does.
  declared=""
  if [[ -f "$INSOMNIA_INFO" ]]; then
    copy_private "$INSOMNIA_INFO" Info.plist || info_rc=$?
    if (( info_rc == 0 )); then
      read_at "$copy_path" InsomniaResumeFrozenVersion raw || info_rc=$?
      if (( info_rc == 0 )); then declared="$read_value"; elif (( info_rc == 2 )); then info_why="$read_why"; fi
    else
      info_why="$copy_why"
    fi
  fi
  if [[ -n "$info_why" ]]; then
    for (( k = 0; k < n; k++ )); do
      log error "pid ${app_pid[k]} needs the app binary for its microsecond identity check, but $INSOMNIA_INFO could not be read ($info_why); the binary was not run; kept, not signaled"
      failures+=("pid ${app_pid[k]} was not resumed: $INSOMNIA_INFO could not be read")
      keep_entry "${app_index[k]}"
    done
    return 0
  fi
  if [[ "$declared" != "$RESUME_FROZEN_VERSION" ]]; then
    for (( k = 0; k < n; k++ )); do
      log error "pid ${app_pid[k]} needs the app binary for its microsecond identity check, but $INSOMNIA_INFO declares InsomniaResumeFrozenVersion '${declared}', not $RESUME_FROZEN_VERSION (an older or newer build); the binary was not run; kept, not signaled"
      failures+=("pid ${app_pid[k]} was not resumed: $INSOMNIA_INFO does not declare --resume-frozen version $RESUME_FROZEN_VERSION")
      keep_entry "${app_index[k]}"
    done
    return 0
  fi
  # A private directory with a fresh name for the binary's input and answer,
  # after removing any left by an earlier run that was itself killed
  # mid-call. One line per entry on standard input: there is no limit on its
  # size, unlike the binary's argument list.
  "$RM" -rf "$APP_SUPPORT"/.backstop-resume.*
  if ! app_answer_dir="$("$MKTEMP" -d "$APP_SUPPORT/.backstop-resume.XXXXXX" 2>/dev/null)"; then
    app_answer_dir=""
    log error "could not create a private directory in $APP_SUPPORT for the app binary's input and answer"
    rc=125
  elif ! printf '%s %s %s %s\n' "${app_args[@]}" > "$app_answer_dir/in" 2>/dev/null; then
    log error "could not write the app binary's input in $app_answer_dir"
    rc=125
  else
    run_app_bounded "$INSOMNIA_BIN" --resume-frozen "$((COMMAND_TIMEOUT_SECONDS + KILL_GRACE_SECONDS))" || rc=$?
  fi
  if (( rc == 125 )) || [[ ! -f "$app_answer_dir/out" ]]; then
    valid=0
  else
    answer="$app_answer_dir/out"
    size="$("$STAT" -f %z "$answer" 2>/dev/null)" || size=""
    excerpt="$("$HEAD" -c 200 "$answer" | "$TR" -c '[:print:]' ' ')" || excerpt="(could not be read)"
    # A valid line is at most 24 bytes ("<10-digit pid> unverifiable\n").
    if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size > n * 32 )); then
      valid=0
    else
      k=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        if (( k >= n )) || [[ "$line" != "${app_pid[k]} "* ]]; then valid=0; break; fi
        word="${line#"${app_pid[k]} "}"
        case "$word" in
          resumed|gone) ;;
          failed|unobserved|unverifiable) settled=0 ;;
          *) valid=0; break ;;
        esac
        words+=("$word")
        k=$((k + 1))
      done < "$answer"
      (( k == n )) || valid=0
    fi
  fi
  if [[ -n "$app_answer_dir" ]]; then "$RM" -rf "$app_answer_dir"; fi
  (( settled )) || expected=1
  (( rc == expected )) || valid=0
  if (( valid == 0 )); then
    log error "unexpected answer from $INSOMNIA_BIN for pid(s) ${app_pid[*]} (exit $rc, output '$excerpt'); all kept, not signaled"
    for (( k = 0; k < n; k++ )); do
      failures+=("pid ${app_pid[k]} was not resumed: unexpected answer from the app binary")
      keep_entry "${app_index[k]}"
    done
    return 0
  fi
  for (( k = 0; k < n; k++ )); do
    p="${app_pid[k]}"
    case "${words[k]}" in
      resumed)
        log info "SIGCONT sent to pid $p by the app binary after a microsecond identity check"
        changed=1 ;;
      gone)
        log info "pid $p is gone, running, or not the process we froze (app binary: gone); cleared without signal"
        changed=1 ;;
      failed)
        log error "SIGCONT to pid $p failed (app binary: failed); keeping journal entry for retry"
        failures+=("pid $p is still stopped: SIGCONT failed")
        keep_entry "${app_index[k]}" ;;
      *)
        log error "pid $p could not be verified (app binary: ${words[k]}); kept, not signaled"
        failures+=("pid $p could not be verified and was not resumed")
        keep_entry "${app_index[k]}" ;;
    esac
  done
}
if (( frozen_count > 0 )); then
  boot_now="$("$SYSCTL" -n kern.bootsessionuuid 2>/dev/null)" || boot_now=""
  uid_now="$UID"
  i=0
  while (( i < frozen_count )); do
    state_read "frozenProcesses.$i.pid" raw; pid="$read_value"
    state_read "frozenProcesses.$i.startedAt" raw; started="$read_value"
    state_read "frozenProcesses.$i.startedAtMicros" raw; micros="$read_value"
    state_read "frozenProcesses.$i.bootSession" raw; boot="$read_value"
    if ! is_positive_int "$pid"; then
      log error "frozen entry $i has no valid pid (${pid:-?}); kept, not signaled"
      failures+=("frozen entry $i has an invalid pid")
      keep_entry "$i"
    elif [[ -z "$started" || -z "$boot" ]]; then
      log error "pid $pid was journaled without identity; not signaled, kept for the app to resolve"
      failures+=("pid $pid has no recorded identity and was not resumed")
      keep_entry "$i"
    elif [[ -z "$boot_now" ]]; then
      log error "cannot read kern.bootsessionuuid; pid $pid not verified, kept"
      failures+=("pid $pid could not be verified (boot session unknown)")
      keep_entry "$i"
    elif [[ "$boot" != "$boot_now" ]]; then
      log info "pid $pid belongs to a previous boot; cleared without signal"
      changed=1
    elif [[ -n "$micros" ]]; then
      # The binary accepts a pid that fits in 32 bits, a non-negative start
      # second and microseconds below one million; anything else would make
      # it reject the whole call, so such an entry is kept here instead.
      if [[ "$micros" =~ ^[0-9]{1,6}$ && "$started" =~ ^[0-9]{1,18}$ ]] && (( ${#pid} <= 10 && 10#$pid <= 2147483647 )); then
        app_index+=("$i")
        app_pid+=("$pid")
        app_args+=("$pid" "$started" "$micros" "$boot")
      else
        log error "pid $pid has an invalid startedAt ($started) or startedAtMicros ($micros); kept, not signaled"
        failures+=("pid $pid has an invalid identity and was not resumed")
        keep_entry "$i"
      fi
    else
      observe "$pid"
      case "$observation" in
        gone)
          log info "pid $pid is gone; cleared without signal"
          changed=1 ;;
        unknown)
          log error "pid $pid could not be observed (ps failed or unparseable); kept, not signaled"
          failures+=("pid $pid could not be observed and was not resumed")
          keep_entry "$i" ;;
        seen)
          if [[ "$p_epoch" != "$started" || "$p_uid" != "$uid_now" ]]; then
            log info "pid $pid is not the process we froze (start $p_epoch vs $started, uid $p_uid); cleared without signal"
            changed=1
          elif [[ "$p_stat" != T* ]]; then
            log info "pid $pid is running (stat $p_stat); cleared without signal"
            changed=1
          elif "$KILL" -CONT "$pid" 2>/dev/null; then
            log info "SIGCONT sent to pid $pid"
            changed=1
          else
            log error "SIGCONT to pid $pid failed; keeping journal entry for retry"
            failures+=("pid $pid is still stopped: SIGCONT failed")
            keep_entry "$i"
          fi ;;
      esac
    fi
    i=$((i + 1))
  done
  if (( ${#app_pid[@]} > 0 )); then
    resume_via_app
  fi
fi

kept_frozen=""
kept_frozen_count=0
for (( i = 0; i < frozen_count; i++ )); do
  [[ -n "${kept[i]:-}" ]] || continue
  state_read "frozenProcesses.$i" json; entry="$read_value"
  if [[ -z "$entry" ]]; then
    log error "could not read frozen entry $i back from $STATE; previous journal kept, will retry"
    leave 1
  fi
  if [[ -n "$kept_frozen" ]]; then kept_frozen="$kept_frozen,$entry"; else kept_frozen="$entry"; fi
  kept_frozen_count=$((kept_frozen_count + 1))
done

if (( legacy_count > 0 )); then
  # Only for the messages: a read that fails names the count instead.
  legacy_json="($legacy_count entries)"
  if read_at "$state_copy" frozenPids json; then legacy_json="$read_value"; fi
  log error "legacy frozenPids $legacy_json have no identity; not signaled and not cleared here, the app must resolve them"
  failures+=("legacy frozenPids $legacy_json were not resumed (identity unknown; only the app resolves these)")
fi

new_docker="$docker_frozen"
if [[ "$docker_frozen" == true ]] && (( kept_frozen_count == 0 && legacy_count == 0 )); then
  new_docker=false; changed=1
fi

# App Nap. The app set NSAppSleepDisabled to YES in each listed agent app's
# preferences and journaled what the key was before. Put that back with the
# tool a person would use. Each entry is kept verbatim (unknown fields
# included) unless its restore succeeded.
kept_app_nap=""
kept_app_nap_count=0
keep_app_nap_entry() { # index
  local entry
  state_read "appNapOverrides.$1" json; entry="$read_value"
  if [[ -z "$entry" ]]; then
    log error "could not read App Nap entry $1 back from $STATE; previous journal kept, will retry"
    leave 1
  fi
  if [[ -n "$kept_app_nap" ]]; then kept_app_nap="$kept_app_nap,$entry"; else kept_app_nap="$entry"; fi
  kept_app_nap_count=$((kept_app_nap_count + 1))
}
if (( app_nap_count > 0 )); then
  i=0
  while (( i < app_nap_count )); do
    state_read "appNapOverrides.$i.bundleId" raw; bundle="$read_value"
    state_read "appNapOverrides.$i.previous" raw; previous="$read_value"
    if [[ -z "$bundle" || "$bundle" == -* ]]; then
      log error "App Nap entry $i has no usable bundle id (${bundle:-?}); kept, nothing written"
      failures+=("App Nap entry $i has no usable bundle id")
      keep_app_nap_entry "$i"
    elif [[ "$previous" == true || "$previous" == false ]]; then
      if run_bounded "$DEFAULTS" write "$bundle" NSAppSleepDisabled -bool "$previous"; then
        log info "defaults write $bundle NSAppSleepDisabled -bool $previous ok"
        changed=1
      else
        if (( command_alive )); then stop_transaction "defaults write $bundle NSAppSleepDisabled"; fi
        log error "defaults write $bundle NSAppSleepDisabled -bool $previous failed; keeping journal entry for retry"
        failures+=("App Nap is still off for $bundle: defaults write failed")
        keep_app_nap_entry "$i"
      fi
    else
      # The key was absent before, so it goes. `defaults delete` fails when
      # the key is already gone, which is the wanted state. A failed delete
      # clears the entry only when `defaults read` then says in so many
      # words that the key does not exist. A read that succeeds means the
      # key is still set; one that fails any other way (cfprefsd not
      # answering, a timeout) proves nothing, so the entry stays for the
      # next run.
      if run_bounded "$DEFAULTS" delete "$bundle" NSAppSleepDisabled; then
        log info "defaults delete $bundle NSAppSleepDisabled ok"
        changed=1
      else
        if (( command_alive )); then stop_transaction "defaults delete $bundle NSAppSleepDisabled"; fi
        probe="$APP_SUPPORT/.backstop.$$.read"
        bounded_output="$probe"
        read_rc=0
        run_bounded "$DEFAULTS" read "$bundle" NSAppSleepDisabled || read_rc=$?
        bounded_output=""
        if (( command_alive )); then "$RM" -f "$probe"; stop_transaction "defaults read $bundle NSAppSleepDisabled"; fi
        if (( read_rc == 0 )); then
          log error "defaults delete $bundle NSAppSleepDisabled failed and the key is still set; keeping journal entry for retry"
          failures+=("App Nap is still off for $bundle: defaults delete failed")
          keep_app_nap_entry "$i"
        elif "$GREP" -q "does not exist" "$probe" 2>/dev/null; then
          log info "defaults delete $bundle NSAppSleepDisabled: the key is already absent"
          changed=1
        else
          log error "defaults delete $bundle NSAppSleepDisabled failed and defaults read could not tell whether the key is still set (exit $read_rc); keeping journal entry for retry"
          failures+=("App Nap may still be off for $bundle: defaults delete failed and the key could not be read")
          keep_app_nap_entry "$i"
        fi
        "$RM" -f "$probe"
      fi
    fi
    i=$((i + 1))
  done
fi

# Display brightness and keyboard backlight are set through private
# frameworks the shell has no access to; the keys stay for the app's reconcile.
if (( has_audio == 1 || has_display == 1 || has_keyboard == 1 )); then
  pending=()
  (( has_audio == 1 )) && pending+=("saved audio (volume/mute)")
  (( has_display == 1 )) && pending+=("saved display brightness")
  (( has_keyboard == 1 )) && pending+=("saved keyboard backlight")
  log error "$(IFS=,; echo "${pending[*]}") can only be restored by the app; kept. Open Insomnia"
  failures+=("saved audio, display brightness or keyboard backlight settings need the app: open Insomnia to restore them")
fi
[[ -n "$refused_note" ]] && log info "$refused_note"

# --- Publish -----------------------------------------------------------------
# Edit a copy of the live journal that holds the bytes this run read (see
# edit_state), verify it, then rename it over state.json (publish_state) so
# readers only ever see a complete journal. Keys we do not own survive
# untouched. A publish that fails (a full disk among other causes) keeps
# the journal as it was, so the next run undoes what it records again.
if (( changed == 1 )); then
  tmp="$APP_SUPPORT/.state.json.backstop.$$"
  publish_ok=1
  publish_why=""
  if ! "$CP" "$STATE" "$tmp"; then
    publish_ok=0; publish_why="it could not be copied"
  elif ! same_as_read "$tmp" "$state_copy"; then
    publish_ok=0; publish_why="its copy does not hold the bytes this run read: it changed since, or cp copied something else"
  fi
  if (( publish_ok == 1 )) && [[ "$new_sleep" != "$sleep_held" ]]; then
    "$PLUTIL" -replace sleepDisabledByUs -bool "$new_sleep" "$tmp" >/dev/null 2>&1 || publish_ok=0
  fi
  if (( publish_ok == 1 )) && [[ "$new_low" != "$low_power" ]]; then
    "$PLUTIL" -replace lowPowerSetByUs -bool "$new_low" "$tmp" >/dev/null 2>&1 || publish_ok=0
  fi
  if (( publish_ok == 1 )) && [[ "$new_docker" != "$docker_frozen" ]]; then
    "$PLUTIL" -replace dockerFrozen -bool "$new_docker" "$tmp" >/dev/null 2>&1 || publish_ok=0
  fi
  if (( publish_ok == 1 && frozen_count > 0 )); then
    "$PLUTIL" -replace frozenProcesses -json "[$kept_frozen]" "$tmp" >/dev/null 2>&1 || publish_ok=0
  fi
  if (( publish_ok == 1 && app_nap_count > 0 )); then
    "$PLUTIL" -replace appNapOverrides -json "[$kept_app_nap]" "$tmp" >/dev/null 2>&1 || publish_ok=0
  fi
  # plutil keeps JSON files as JSON; publish_state makes sure the result is
  # still one. Published but not read again (2) is published: nothing reads
  # the journal after this.
  if (( publish_ok == 1 )); then
    publish_rc=0; publish_state "$tmp" || publish_rc=$?
    if (( publish_rc == 1 )); then publish_ok=0; fi
  else
    "$RM" -f "$tmp"
  fi
  if (( publish_ok == 0 )); then
    log error "could not publish the updated journal to $STATE${publish_why:+ ($publish_why)}; previous journal kept, will retry"
    leave 1
  fi
fi

# --- Report ------------------------------------------------------------------
if (( marker_stuck )); then
  failures+=("$PENDING is still present, so a password dialog left from an abandoned start could still turn sleep off")
fi
if [[ -n "$settle_failed" ]]; then
  failures+=("$settle_failed")
fi
if (( ${#failures[@]} > 0 )); then
  for f in "${failures[@]}"; do log error "still journaled: $f"; done
  log error "journal kept dirty (${#failures[@]} item(s)); will retry on the next run"
  leave 1
fi

if (( output_count > 0 )); then
  log info "journal cleared apart from $outputs_note"
else
  log info "journal cleared"
fi
case "$session_state" in
  malformed|unreadable) quarantine_session || leave 1 ;;
  *)                    "$RM" -f "$SESSION" ;;
esac
leave 0
