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
# state.json, decide, undo, publish the new journal atomically, release. If
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
# Decision, driven only by what the journal says was changed:
#   - session.json valid (endsAt in the future) and no --force: the session
#     is live only while Insomnia is running and the machine is within the
#     floors the app enforces itself (FloorRules.swift). Three checks, any
#     of which ends the session exactly as --force would, with a log line
#     naming the reason:
#       app alive  -> the app holds an flock(2) on APP_SUPPORT/.app.alive for
#                     its whole lifetime (AppAliveLock.swift). Taking that
#                     lock here without waiting means no app holds it: it
#                     crashed, was force-quit, or has not started yet.
#       battery    -> pmset -g batt: an internal battery is present, the Mac
#                     draws from 'Battery Power', and the percentage is below
#                     the end floor (strict, so 0 disables it). The floor
#                     and the thermal rule are what the app takes from
#                     config.json: the installed app binary decodes the file
#                     with the app's own decoder, or, when it cannot answer,
#                     this script reads the file where it can tell exactly
#                     what that decoder makes of it (read_cutoffs). When the
#                     file is missing, cannot be read, or the app rejects
#                     it, the cutoffs the app recorded for the session in
#                     state.json (sessionCutoffs) apply, read by the same
#                     binary, or here when it cannot answer; the defaults,
#                     10% and on, when the journal records none; and the
#                     strictest, 95% and on, when config.json is there but
#                     cannot be read either way and the journal records
#                     none. A journal the app would not
#                     load stops the run first, the session kept (below).
#                     A battery present but unreadable,
#                     or a failing pmset, ends too (fail closed). No battery
#                     in pmset: ioreg shows whether an AppleSmartBattery
#                     service exists, as the app checks. None is a desktop,
#                     with no battery rule; one without a charger reported
#                     ends.
#       thermal    -> notifyutil -g com.apple.system.thermalpressurelevel at
#                     3 (trapping) or above, with thermalRules on (default).
#                     Unreadable: a warning, not an end on that alone.
#     All three pass: exit 0, nothing logged.
#   - A valid session this run ends (a check above, or --force) is over
#     from that decision, once the journal loads as the app loads it (a
#     journal that does not stops the run first, the session kept, as for
#     state.json below): session.json is removed before anything is undone,
#     so an undo that cannot finish (saved brightness only the app restores,
#     a failing or hung pmset) does not leave a session a relaunched app
#     would resume (the one gap is below). What is left stays in state.json
#     for the next run and the app.
#     A session.json that cannot be removed (an immutable file) is recorded
#     as ended in ended-session.json, a copy of its bytes. When that file
#     cannot be written either (an unrelated record there that cannot be
#     replaced), the record goes in state.json instead: endedSession, the
#     same bytes in base64. When state.json cannot be written either, the
#     copy goes in a new file, ended-session.json.<8 letters or digits>
#     (mktemp), beside them, or in the log folder when their folder takes
#     no new file. When neither folder takes a new file, the record goes in
#     the recovery lock file, which exists already: a tag and the same
#     base64, written in place, so the file keeps its inode and stays the
#     lock (record_end_in_lock). Each record is written and read back before
#     anything is undone. While one matches the file, the app restores that
#     session instead of resuming it, and every run ends it again without
#     the checks and retries the removal. A lock file that cannot be read,
#     or that holds session.json's record cut short as a writer leaves it,
#     counts as the end of that session; other content that is not a whole
#     record ends nothing. If no record can be written (neither folder takes
#     a new file, and the lock file is not a regular file this user owns,
#     or refuses the write too, as on a full disk), sleep is still restored
#     but its journal entry stays, and the run exits 1. Before it resumes a
#     session the app writes session.json's bytes back over it and writes
#     the journal, so it resumes none while session.json cannot be replaced
#     or state.json cannot be written. Once both take writes again
#     (session.json made removable as well), an app launched before the
#     next run, with pmset reporting SleepDisabled 1, resumes it: nothing
#     left on disk then tells that session from one a crash left.
#   - state.json missing or clean: nothing is undone and nothing privileged
#     runs; an expired session.json is removed. Exit 0. Entries in
#     savedAudioOutputs alone count as clean (see below).
#   - state.json dirty: undo each journaled entry from the journal alone:
#       sleepDisabledByUs   -> sudo -n pmset -a disablesleep 0
#       lowPowerSetByUs     -> sudo -n pmset -b lowpowermode 0
#       frozenProcesses     -> SIGCONT, but only to a pid verified to be the
#                              process the app froze. Entries that record
#                              startedAtMicros are handed to the installed
#                              app binary (INSOMNIA_BIN --resume-frozen
#                              <seconds>) in one call with a time limit, one
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
#                              retry. Their types are checked, on the
#                              journal as the app reads it (check_journal).
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
#     A flag is cleared only after its undo succeeded. Unknown keys survive
#     where plutil reads state.json as the app reads it; otherwise the
#     journal is read, and republished, from the view check_journal
#     describes, which keeps what the app's own save keeps.
#     endedSession (see above) is a record, not something to undo: it never
#     makes the journal dirty, and only the app removes it. So is
#     sessionCutoffs (see read_cutoffs), which this script never changes.
#     Exit 0 only when the journal is clean afterwards; otherwise exit 1 so
#     the failure is visible and the next periodic run retries.
#   - state.json unreadable, not a JSON object, with a known key of the
#     wrong type, or with text the app does not decode or whose meaning to
#     the app is not known here (check_journal, record_text_problems):
#     nothing is touched, exit 1. That includes a valid session.json: it is
#     neither removed nor recorded as ended, since the app neither ends,
#     resumes nor starts a session on such a journal, and the first run
#     after a repair ends it.
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
# Honours INSOMNIA_HOME with the same layout as the app (see Paths.swift).
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
NOTIFYUTIL=/usr/bin/notifyutil
IOREG=/usr/sbin/ioreg
CMP=/usr/bin/cmp
CHMOD=/bin/chmod
DEFAULTS=/usr/bin/defaults
DATE=/bin/date
MKDIR=/bin/mkdir
RM=/bin/rm
MV=/bin/mv
CP=/bin/cp
MKTEMP=/usr/bin/mktemp
BASE64=/usr/bin/base64
STAT=/usr/bin/stat
CAT=/bin/cat
GREP=/usr/bin/grep
SED=/usr/bin/sed
HEAD=/usr/bin/head
TAIL=/usr/bin/tail
TR=/usr/bin/tr
ICONV=/usr/bin/iconv
ID=/usr/bin/id
# sleep is the one tool taken by name: it only paces the polls in
# wait_for_status and wait_for_job and the reads in read_lock_record, and
# reads nothing itself. The tests that make every poll slow put their own
# sleep first in PATH.
# The installed app binary, for the microsecond identity check of
# frozenProcesses entries (see above) and for reading config.json's cutoffs
# (read_cutoffs), and the bundle's Info.plist, which must declare
# InsomniaResumeFrozenVersion RESUME_FROZEN_VERSION, or
# InsomniaAgentCutoffsVersion AGENT_CUTOFFS_VERSION, before the binary is
# run in that mode: an older build has no such mode and would open the menu
# bar app instead. Fixed paths like the tools, never PATH. install.sh puts
# the bundle here, copying the binary before Info.plist.
INSOMNIA_BIN="${HOME:-}/Applications/Insomnia.app/Contents/MacOS/Insomnia"
INSOMNIA_INFO="${HOME:-}/Applications/Insomnia.app/Contents/Info.plist"
RESUME_FROZEN_VERSION=1
AGENT_CUTOFFS_VERSION=3
LOCK_TIMEOUT_SECONDS=10
# The end record kept in the recovery lock file (read_lock_record): this
# tag, a space, session.json's bytes in base64, and a newline. A file larger
# than LOCK_RECORD_MAX_BYTES holds no whole record.
LOCK_RECORD_TAG=ended-session-v1
LOCK_RECORD_MAX_BYTES=1048576
# How many times read_lock_record reads the lock file before it counts as
# one that cannot be read, and the pause between reads (Store.swift has the
# same two values).
LOCK_READ_ATTEMPTS=3
LOCK_READ_RETRY_SECONDS=0.1
# The end record appended to insomnia.log (log_record_line): this tag, a
# space, the number of bytes in session.json, a space, those bytes in base64,
# and a newline. A session.json longer than LOG_RECORD_MAX_BYTES is never
# recorded there, and a log larger than LOG_SCAN_MAX_BYTES is not searched
# for a record (LogEndRecord.swift has the same three values).
LOG_RECORD_TAG=insomnia-ended-session-v1
LOG_RECORD_MAX_BYTES=65536
LOG_SCAN_MAX_BYTES=67108864
# How long a line waits for another writer's lock on insomnia.log (log,
# record_end_in_log). The app holds it for one line, or for one rotation.
LOG_LOCK_TIMEOUT_SECONDS=5
# com.apple.system.thermalpressurelevel at or above this ends a session. On
# macOS the levels are 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping
# (libkern/OSThermalNotification.h); ProcessInfo reports .critical from
# trapping up, which is where the app's FloorRules end the session.
THERMAL_CRITICAL_LEVEL=3
# Longest a single undo command (sudo pmset, defaults) may run before it is
# sent SIGTERM, and how long it then gets to exit before this run fails closed.
COMMAND_TIMEOUT_SECONDS=30
KILL_GRACE_SECONDS=3
# Longest record_text_problems reads one file (state.json, or config.json
# for config_cutoffs) before it says what the app makes of it is not known
# here. A journal the app writes takes a fraction of a second.
TEXT_READ_SECONDS=30

force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -h|--help) echo "usage: $0 [--force]"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  APP_SUPPORT="$INSOMNIA_HOME"
  LOG_DIR="$INSOMNIA_HOME/Logs"
else
  APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
  LOG_DIR="$HOME/Library/Logs/Insomnia"
fi
SESSION="$APP_SUPPORT/session.json"
ENDED="$APP_SUPPORT/ended-session.json"
STATE="$APP_SUPPORT/state.json"
CONFIG="$APP_SUPPORT/config.json"
LOCK="$APP_SUPPORT/.recovery.lock"
ALIVE="$APP_SUPPORT/.app.alive"
LOG="$LOG_DIR/insomnia.log"

# Whether the file at $1 ends in a line cut short: it is a regular file, not
# empty, and its last byte is not a newline, or that byte cannot be read.
# Every writer of the log then puts a newline before its own line, under
# the lock below, so the line cut short stays a line of its own: it may be
# the record of a session's end whose newline alone is missing, which
# counts as the end only while nothing follows it on its line
# (end_recorded_in_log), or a line a write left partway, which a record
# must not join. The app's writers read the same way
# (OwnerOnly.endsMidLine). The trailing x keeps the newline that command
# substitution would drop.
ends_mid_line() { # file
  [[ -f "$1" && -s "$1" ]] || return 1
  local last
  last="$("$TAIL" -c 1 "$1" 2>/dev/null; printf x)"
  [[ "$last" != $'\nx' ]]
}

# Device and inode of a path (lstat), and of an open descriptor: stat
# with no operand reads its standard input with fstat(2). /dev/fd/N is no
# substitute, as stat reports devfs's device for it.
devino() { "$STAT" -f %d:%i "$1" 2>/dev/null; }
fd_devino() { "$STAT" -f %d:%i <&"$1" 2>/dev/null; }
# Whether descriptor $1 is open on the file the path $2 names, following a
# symlink as opening the path did.
fd_names() { # fd path
  local held
  held="$(fd_devino "$1")"
  [[ -n "$held" && "$held" == "$("$STAT" -L -f %d:%i "$2" 2>/dev/null)" ]]
}

# Every writer of insomnia.log holds flock(2) on the file from its look at
# the last byte (ends_mid_line) to the end of its write: this function,
# record_end_in_log, the LaunchAgent's own line and the app
# (OwnerOnly.lockLog), which also renames the file under it when it
# rotates the log. So no line joins another, a write cut short and then
# continued included. lockf takes the lock on the descriptor the line goes
# out through, waiting at most LOG_LOCK_TIMEOUT_SECONDS, and closing that
# descriptor lets it go. Once held, a descriptor on a file the path no
# longer names (the app rotated it meanwhile) is let go and the path
# opened again, up to three times. A line that gets no lock, or no file
# the path still names, goes to standard error instead.
log() { # level message
  # mkdir -p of a directory that is there does nothing.
  [[ -d "$LOG_DIR" ]] || "$MKDIR" -p "$LOG_DIR"
  # Append only to a regular file, or create one. open(2) on a FIFO with no
  # reader blocks, and most lines are written while this run holds the
  # recovery lock. A line with nowhere to go is dropped.
  if [[ -e "$LOG" && ! -f "$LOG" ]]; then return 0; fi
  local stamp first state line_lock_rc
  stamp="$("$DATE" -u +%Y-%m-%dT%H:%M:%SZ)"
  for _ in 1 2 3; do
    # shellcheck disable=SC2094  # the log is appended to on 8 and checked by its path, under the lock, on purpose
    {
      line_lock_rc=0
      "$LOCKF" -s -t "$LOG_LOCK_TIMEOUT_SECONDS" 8 || line_lock_rc=$?
      state="not locked within ${LOG_LOCK_TIMEOUT_SECONDS}s (lockf exit $line_lock_rc)"
      if (( line_lock_rc == 0 )); then
        state="renamed while this line waited for its lock"
        if fd_names 8 "$LOG"; then
          first=""
          if ends_mid_line "$LOG"; then first=$'\n'; fi
          state=written
          printf '%s%s [%s] backstop: %s\n' "$first" "$stamp" "$1" "$2" >&8 || state=failed
        fi
      fi
    } 8>>"$LOG" || return 1
    [[ "$state" == renamed* ]] || break
  done
  case "$state" in
    written) return 0 ;;
    failed) return 1 ;;
  esac
  printf '%s [%s] backstop: %s (not in %s: %s)\n' "$stamp" "$1" "$2" "$LOG" "$state" >&2 || true
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

# --- Helpers -----------------------------------------------------------------

# plutil -extract <key> raw prints the scalar; returns non-zero if missing.
extract() { # file keypath
  "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null
}
extract_json() { # file keypath
  "$PLUTIL" -extract "$2" json -o - "$1" 2>/dev/null
}
# A whole number at keypath $2, as digits with an optional minus sign. In
# the journal read here (check_journal) each is written as digits: one
# written with a fraction or an exponent, such as 5105.0, is read from the
# view, which holds the number the app reads. plutil would print such a
# number with six zeros after a point (5105.000000); those are dropped all
# the same, and -0 is 0.
extract_whole() { # file keypath
  local v
  v="$(extract "$1" "$2")" || return 1
  if [[ "$v" =~ ^(-?)([0-9]+)\.0+$ ]]; then
    v="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    [[ "$v" != -0 ]] || v=0
  fi
  printf '%s\n' "$v"
}
# Type name of a keypath (bool, integer, float, string, array, dictionary,
# "(any)" for null); empty if the key is absent.
type_of() { # file keypath
  "$PLUTIL" -type "$2" -o - "$1" 2>/dev/null || true
}
# The types journal_shape_problems checks, read from one conversion of the
# file rather than one plutil -type a keypath. With -r plutil writes JSON
# one value to a line, two spaces deeper a level, a key and its value as
# "key" : value, and an empty array or object over three lines, the middle
# one empty. A value starts with what it is: { a dictionary, [ an array,
# " a string, true or false a bool, null what plutil -type calls "(any)",
# and anything else a number. plutil writes the Float 5.0 as 5, so a
# number is "number" here, as in the checks, and shape_name asks plutil
# -type for the name a line about a problem gives. shape_types_text holds,
# for each value at the top level and, in frozenProcesses, frozenPids,
# savedAudioOutputs and appNapOverrides where each is an array, for each
# entry and each value directly in an entry, a line of its keypath, a tab
# and its type. A key with anything but letters and digits in it names no
# keypath asked about (plutil splits a keypath at each dot and writes such
# a key with an escape where these have none), so it and what is under it
# are left out. Returns 1 when plutil does not read the file as a JSON
# object. On a line in no form named here shape_types_read stays 0, and
# shape_type asks plutil -type for each keypath, as before.
shape_types_text=""
shape_types_read=0
shape_types() { # file
  local line rest key t top="" n=0 entry="" first=1 last=0
  local member='^"(([^"\]|\\.)*)" : (.*)$' plain='^[A-Za-z0-9]+$'
  shape_types_text=$'\n'
  shape_types_read=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( first == 1 )); then
      first=0
      [[ "$line" == "{" ]] || return 1
      continue
    fi
    (( last == 0 )) || return 0
    case "$line" in
      ""|"        "*) ;;
      "      "[!\ ]*)
        rest="${line#      }"
        if [[ -n "$entry" && "$rest" != [\]\}]* ]]; then
          [[ "$rest" =~ $member ]] || return 0
          key="${BASH_REMATCH[1]}"
          shape_value_type "${BASH_REMATCH[3]}" || return 0
          [[ ! "$key" =~ $plain ]] || shape_types_text+="$entry.$key"$'\t'"$t"$'\n'
        fi
        ;;
      "    "[!\ ]*)
        rest="${line#    }"
        if [[ -n "$top" && "$rest" != [\]\}]* ]]; then
          shape_value_type "$rest" || return 0
          shape_types_text+="$top.$n"$'\t'"$t"$'\n'
          entry=""
          [[ "$t" != dictionary ]] || entry="$top.$n"
          n=$((n + 1))
        fi
        ;;
      "  "[!\ ]*)
        rest="${line#  }"
        top=""
        entry=""
        if [[ "$rest" != [\]\}]* ]]; then
          [[ "$rest" =~ $member ]] || return 0
          key="${BASH_REMATCH[1]}"
          shape_value_type "${BASH_REMATCH[3]}" || return 0
          if [[ "$key" =~ $plain ]]; then
            shape_types_text+="$key"$'\t'"$t"$'\n'
            case "$key" in
              frozenProcesses|frozenPids|savedAudioOutputs|appNapOverrides) [[ "$t" != array ]] || { top="$key"; n=0; } ;;
            esac
          fi
        fi
        ;;
      "}") last=1 ;;
      *) return 0 ;;
    esac
  done < <("$PLUTIL" -convert json -r -o - "$1" 2>/dev/null)
  (( first == 0 )) || return 1
  (( last == 0 )) || shape_types_read=1
  return 0
}
shape_value_type() { # value as plutil -r writes it; sets t
  case "$1" in
    "{") t=dictionary ;;
    "[") t=array ;;
    \"*) t=string ;;
    true|true,|false|false,) t=bool ;;
    null|null,) t="(any)" ;;
    -[0-9]*|[0-9]*) t=number ;;
    *) return 1 ;;
  esac
}
# Sets t to the type of keypath $2 in file $1 (shape_types), "number" for
# an integer or a float, empty when the keypath is absent.
shape_type() { # file keypath
  local re
  t=""
  if (( shape_types_read == 1 )); then
    re=$'\n'"${2//./[.]}"$'\t''([^'$'\n'']*)'
    if [[ "$shape_types_text" =~ $re ]]; then t="${BASH_REMATCH[1]}"; fi
  else
    t="$(type_of "$1" "$2")"
    if [[ "$t" == integer || "$t" == float ]]; then t=number; fi
  fi
  return 0
}
# The name plutil -type gives the type $3 of keypath $2, for a line.
shape_name() { # file keypath type
  if [[ "$3" == number ]]; then type_of "$1" "$2"; else printf '%s\n' "$3"; fi
}
is_true() { # file key
  [[ "$(extract "$1" "$2" || true)" == "true" ]]
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
# back or forward) lengthens or shortens it by that much.
wait_for_status() { # file seconds
  local deadline=$(( SECONDS + $2 ))
  while [[ ! -s "$1" ]] && (( SECONDS <= deadline )); do
    sleep 0.1
  done
  [[ -s "$1" ]]
}

# The first run_bounded or run_read call of a run (bounded_calls counts both)
# removes the status and output files earlier runs left, and only when this
# run took the lock on its own handle (see run_bounded): a run that shares
# its caller's lock may have a live supervisor from an earlier run under
# that lock, whose files must stay.
remove_stale_run_files() {
  (( bounded_calls == 1 && ! lock_shared )) || return 0
  "$RM" -f "$APP_SUPPORT"/.backstop.*.pid "$APP_SUPPORT"/.backstop.*.rc "$APP_SUPPORT"/.backstop.*.out
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
  remove_stale_run_files
  supervise_command "$base" "$@" </dev/null >/dev/null 2>&1 &
  supervisor=$!
  # Each of the supervisor's two waits can end up to a second after its
  # limit, plus the poll in progress then (see wait_for_status), and the
  # supervisor takes a moment to start and to write its status. Four seconds
  # cover that at the usual 0.1 s poll. A supervisor slower than that gets
  # the 125 below, the safe side.
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

# Run one read (pmset -g batt, ioreg, notifyutil -g, the app binary's
# --agent-cutoffs) with the undo commands' time limit and put its standard
# output in the variable named by $1. Standard input is /dev/null, or the
# file named by read_input, which the background job opens itself, so an
# open that blocks is bounded like the read. A read changes nothing, so
# unlike an undo command it has no reason to hold the recovery lock: it
# starts with fd 9 closed, so a read that hangs can only fail itself, never
# a later run or the app. This shell starts it as its own
# background job and is the only process that signals it, by jobspec once
# signal_job has checked that the job is this read (see run_app_bounded), so
# a signal never reaches a process that reused its pid; no pid is read back
# from a file. Both limits are on the SECONDS clock (wait_for_job). A read
# still running KILL_GRACE_SECONDS after SIGTERM gets SIGKILL: it runs
# unprivileged and has nothing to leave half done. Returns the read's exit
# status, or 124 when it was stopped. Its output goes through
# .backstop.<this run's pid>.<call>.out, which this call removes, and the
# first call of a run removes what earlier runs left (remove_stale_run_files).
# With read_keep at 1 the output stays in that file, exact to the byte, and
# kept_output names it (empty when the read was stopped); the variable is
# left empty and the caller removes the file.
# The function's stderr is /dev/null because bash reports a job that a signal
# ended on its own stderr; the log says what happened instead.
read_input=""   # file for the next read's standard input; empty: /dev/null
read_keep=0
kept_output=""
run_read() { # varname command args...
  local name="$1" outfile cpid rc=0 read_output=""
  shift
  bounded_calls=$((bounded_calls + 1))
  remove_stale_run_files
  outfile="$APP_SUPPORT/.backstop.$$.$bounded_calls.out"
  # A leftover at this name goes unopened first, as in record_end.
  "$RM" -f "$outfile" 2>/dev/null || true
  "$@" <"${read_input:-/dev/null}" >"$outfile" 2>/dev/null 9>&- &
  cpid=$!
  if wait_for_job "$cpid" "$COMMAND_TIMEOUT_SECONDS"; then
    wait "$cpid" || rc=$?
  else
    rc=124
    signal_job TERM "$cpid" || true
    if wait_for_job "$cpid" "$KILL_GRACE_SECONDS"; then
      wait "$cpid" || true
      log error "'$*' did not finish within ${COMMAND_TIMEOUT_SECONDS}s; terminated with SIGTERM (pid $cpid)"
    else
      signal_job KILL "$cpid" || true
      if wait_for_job "$cpid" "$KILL_GRACE_SECONDS"; then
        wait "$cpid" || true
        log error "'$*' did not finish within ${COMMAND_TIMEOUT_SECONDS}s and ignored SIGTERM; sent SIGKILL (pid $cpid). A read holds no lock, so nothing waits for it"
      else
        log error "'$*' did not finish within ${COMMAND_TIMEOUT_SECONDS}s, ignored SIGTERM and has not exited ${KILL_GRACE_SECONDS}s after SIGKILL (pid $cpid); it runs no further code and holds no lock"
      fi
    fi
  fi
  kept_output=""
  if (( rc != 124 )) && [[ -f "$outfile" ]]; then
    if (( read_keep == 1 )); then kept_output="$outfile"; else read_output="$("$CAT" "$outfile")"; fi
  fi
  printf -v "$name" '%s' "$read_output"
  [[ -n "$kept_output" ]] || "$RM" -f "$outfile"
  return "$rc"
} 2>/dev/null

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
# wait_for_status (and within the same bounds), and checks once more after
# the limit.
wait_for_job() { # pid seconds
  local deadline=$(( SECONDS + $2 ))
  while job_running "$1" && (( SECONDS <= deadline )); do
    sleep 0.1
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
# nothing else is undone, the journal stays exactly as read (a session this
# run decided to end is already gone), and the lock stays with the live
# command's supervisor.
stop_transaction() { # what
  log error "recovery stopped after '$1' (still running); no further undo this run, journal kept unchanged until it ends"
  exit 1
}

# Sets whole_value to the whole number the app's JSONDecoder reads for the
# JSON number $1 where it decodes an Int32 or an Int64 ($2: int32 or
# int64), as digits with a minus sign for a negative one, or to nothing
# where it throws. Foundation (swift-foundation 6.2, JSONDecoder's
# _slowpath_unwrapFixedWidthInteger) reads a plain integer exactly, from
# -2^31 or -2^63 up. It reads any other number as a Double (strtod), which
# must be a whole number the type holds; below 2^53 that Double is the
# value, so 5105.0 reads as 5105, 1.0000000000000001 as 1 and 1e-400 as 0,
# and 0.5 throws. From 2^53 up it reads the text again as a Decimal and
# takes its value without the fraction, so 9007199254740993.0 reads as
# 9007199254740993. There, an Int64 goes up to 9223372036854775295, as a
# Double rounds anything above to 2^63, and down to -9223372036854775807.
# whole_trap is 1 for a number on which Foundation stops the app instead
# (a precondition failure, SIGTRAP): such an Int64 whose Decimal parse
# overflows (json_decimal_reads).
# shellcheck disable=SC2071  # digit strings compared as text: they overflow $(( ))
json_whole() { # number int32|int64
  local LC_ALL=C number neg ip frac esign edig exp e10 sig core scale lim i f k c n d p q h r v carry pad
  local reads=0
  whole_value=""
  whole_trap=0
  number='^(-?)(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  [[ "$1" =~ $number ]] || return 0
  neg="${BASH_REMATCH[1]}"
  ip="${BASH_REMATCH[2]}"
  frac="${BASH_REMATCH[4]}"
  esign="${BASH_REMATCH[6]}"
  edig="${BASH_REMATCH[7]}"
  # Zeros are cut with a regular expression: a pattern cut takes time that
  # grows with the square of the length.
  [[ "$edig" =~ ^0* ]]
  exp="${edig:${#BASH_REMATCH[0]}}"
  if (( ${#exp} > 9 )); then e10=1000000000; else e10=$((10#0$exp)); fi
  [[ "$esign" != - ]] || e10=$((-e10))
  sig="$ip$frac"
  [[ "$sig" =~ ^0* ]]
  sig="${sig:${#BASH_REMATCH[0]}}"
  if [[ -z "$sig" ]]; then
    whole_value=0
    return 0
  fi
  # The value is core, sig without its trailing zeros, times ten to the
  # power scale.
  [[ "$sig" =~ 0*$ ]]
  core="${sig:0:${#sig}-${#BASH_REMATCH[0]}}"
  scale=$((e10 - ${#frac} + ${#sig} - ${#core}))
  if [[ "$2" == int32 ]]; then lim=2147483647; else lim=9223372036854775807; fi
  if [[ -z "$frac$edig" ]]; then
    [[ -z "$neg" ]] || lim="${lim%7}8"
    (( ${#ip} <= ${#lim} )) || return 0
    if (( ${#ip} == ${#lim} )) && [[ "$ip" > "$lim" ]]; then return 0; fi
    whole_value="$neg$ip"
    return 0
  fi
  if (( scale >= 0 )); then
    (( ${#core} + scale <= 19 )) || return 0
    i="$core"
    if (( scale > 0 )); then
      printf -v pad '%0*d' "$scale" 0
      i+="$pad"
    fi
    if [[ "$2" == int64 && -z "$neg" ]] && (( ${#i} == 19 )) && [[ "$i" > 9223372036854775295 ]]; then return 0; fi
    [[ "$2" != int32 || -z "$neg" ]] || lim=2147483648
    if (( ${#i} > ${#lim} )) || { (( ${#i} == ${#lim} )) && [[ "$i" > "$lim" ]]; }; then return 0; fi
    if (( ${#i} > 16 || (${#i} == 16 && 10#$i >= 9007199254740992) )); then
      json_decimal_reads || reads=$?
      (( reads != 2 )) || whole_trap=1
      (( reads == 0 )) || return 0
    fi
    whole_value="$neg$i"
    return 0
  fi
  # A fraction: i is the whole part and f the digits after the point.
  k=$((-scale))
  c=${#core}
  if (( k - c >= 324 )); then
    # Below 1e-323, which a Double reads as 0.
    whole_value=0
    return 0
  fi
  if (( c > k )); then
    i="${core:0:c-k}"
    f="${core:c-k}"
  else
    i=""
    pad=""
    (( k == c )) || printf -v pad '%0*d' "$((k - c))" 0
    f="$pad$core"
  fi
  (( ${#i} <= 19 )) || return 0
  if (( ${#i} == 19 )) && [[ "$i" > 9223372036854775807 ]]; then return 0; fi
  i=$((10#0$i))
  if (( i >= 9007199254740992 )) || { (( i == 9007199254740991 )) && [[ "${f:0:1}" > 4 ]]; }; then
    # The Double is 2^53 or more: an Int64 only, read as a Decimal.
    [[ "$2" == int64 ]] || return 0
    if [[ -z "$neg" ]] && (( i > 9223372036854775295 )); then return 0; fi
    json_decimal_reads || reads=$?
    (( reads != 2 )) || whole_trap=1
    (( reads == 0 )) || return 0
    whole_value="$neg$i"
    return 0
  fi
  if (( i >= 4503599627370496 )); then
    # From 2^52 a Double holds whole numbers only: the nearest, a tie to
    # the even one.
    n=$i
    if [[ "$f" == 5 ]]; then
      (( i % 2 == 0 )) || n=$((i + 1))
    elif [[ "${f:0:1}" > 4 ]]; then
      n=$((i + 1))
    fi
  else
    # Below 2^52 the Double is whole only when the number is nearer to the
    # whole number n than half the gap between Doubles there, 2^-q: d is
    # how far, as digits after the point. A tie at .5 is never whole. The
    # digits of d and h end in a digit other than 0, so comparing them as
    # text compares their values. h has at most 54 digits, so d needs only
    # its first 64 and a 1 for any it has beyond.
    [[ "$f" != 5 ]] || return 0
    if [[ "${f:0:1}" > 4 ]]; then
      n=$((i + 1))
      d=""
      v="${f:0:64}"
      for (( r = 0; r < k - 1 && r < 64; r++ )); do d+=$((9 - ${v:r:1})); done
      if (( k - 1 > 64 )); then d+='1'; else d+=$((10 - ${f:k-1:1})); fi
    else
      n=$i
      d="$f"
    fi
    if (( n == 0 )); then
      # Below 1/2: 0 only where a Double reads it as 0, at or below half
      # the smallest Double.
      (( k - c == 323 )) || return 0
      h=24703282292062327208828439643411068618252990130716238221279284125033775363510437593264991818081799618989828234772285886546332835517796989819938739800539093906315035659515570226392290858392449105184435931802849936536152500319370457678249219365623669863658480757001585769269903706311928279558551332927834338409351978015531246597263579574622766465272827220056374006485499977096599470454020828166226237857393450736339007967761930577506740176324673600968951340535537458516661134223766678604162159680461914467291840300530057530849048765391711386591646239524912623653881879636239373280423891018672348497668235089863388587925628302755995657524455507255189313690836254779186948667994968324049705821028513185451396213837722826145437693412532098591327667236328125
      [[ ! "$core" > "$h" ]] || return 0
      whole_value=0
      return 0
    fi
    p=0
    while (( (n >> (p + 1)) > 0 )); do p=$((p + 1)); done
    q=$((53 - p))
    if (( n > i && (n & (n - 1)) == 0 )); then q=$((q + 1)); fi
    h=5
    for (( r = 1; r < q; r++ )); do
      v=""
      carry=0
      for (( c = 0; c < ${#h}; c++ )); do
        v+=$(( (carry * 10 + ${h:c:1}) / 2 ))
        carry=$(( (carry * 10 + ${h:c:1}) % 2 ))
      done
      (( carry == 0 )) || v+='5'
      h="$v"
    done
    [[ ! "$d" > "$h" ]] || return 0
  fi
  if [[ "$2" == int32 ]] && (( n > 2147483648 || (n == 2147483648 && ${#neg} == 0) )); then return 0; fi
  whole_value="$neg$n"
  [[ "$whole_value" != -0 ]] || whole_value=0
  return 0
}

# For json_whole: whether Foundation's Decimal parse reads the number whose
# parts json_whole holds (ip, frac, sig, edig, esign) as a whole number in
# the Int64 range. It keeps the digits that fit 128 bits, each later one
# moving the exponent, which must stay inside -128...127 (2 when not:
# Foundation then stops the app). The digits kept, without their trailing
# zeros, must then fit 64 bits (1 when not: the app throws).
# shellcheck disable=SC2071  # digit strings compared as text: they overflow $(( ))
json_decimal_reads() {
  local LC_ALL=C kept K lz kf e x m
  lz=$(( ${#ip} + ${#frac} - ${#sig} ))
  kept=${#sig}
  if (( kept >= 39 )); then
    kept=38
    [[ "${sig:0:39}" > 340282366920938463463374607431768211455 ]] || kept=39
  fi
  K=$(( lz + kept ))
  if (( K < ${#ip} )); then
    x=$(( ${#ip} - K ))
    (( x <= 127 )) || return 2
  else
    kf=$(( K - ${#ip} ))
    (( kf <= ${#frac} )) || kf=${#frac}
    (( kf <= 128 )) || return 2
    x=$(( -kf ))
  fi
  [[ "$edig" =~ ^0* ]]
  e="${edig:${#BASH_REMATCH[0]}}"
  if [[ -n "$e" ]]; then
    (( ${#e} <= 3 )) && (( 10#$e <= 254 )) || return 2
    if [[ "$esign" == - ]]; then x=$(( x - 10#$e )); else x=$(( x + 10#$e )); fi
    (( x >= -128 && x <= 127 )) || return 2
  fi
  m="${sig:0:kept}"
  m="${m%"${m##*[1-9]}"}"
  (( ${#m} < 20 )) || { (( ${#m} == 20 )) && [[ ! "$m" > 18446744073709551615 ]]; } || return 1
  return 0
}

# Sets range_problem to what the app's JSONDecoder does with the JSON
# number $1 where it decodes a Float or a Double ($2: float or double):
# nothing when it reads it, "small" for a number that is not 0 and that the
# type rounds to 0, "large" for one it rounds to infinity, "zero" for a 0
# Foundation's check refuses. Exact: the number's decimal digits are
# compared with the bounds as text. A Float reads what lies strictly
# between 7.00649232162408535461864791644958065640130970938257885878534141944895541342930300743319094181060791015625e-46
# (half the smallest Float) and 340282356779733661637539395458142568448
# (the largest Float plus half a step); a Double between half the smallest
# Double (about 2.47e-324) and the largest Double plus half a step (about
# 1.7976931348623158e308). A 0 must pass Foundation's isTrueZero, which
# reads the number four bytes at a time and the last one to three bytes
# backwards: an e among those, followed by a digit other than 0, fails it,
# so 0e5 and 0.00e1 are refused and 0e99999 and 0.0e5 are read.
json_range() { # number float|double
  local LC_ALL=C number ip frac esign edig exp e10 sig m lo_sig lo_m hi_sig hi_m tail
  range_problem=""
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  [[ "$1" =~ $number ]] || return 0
  ip="${BASH_REMATCH[1]}"
  frac="${BASH_REMATCH[3]}"
  esign="${BASH_REMATCH[5]}"
  edig="${BASH_REMATCH[6]}"
  [[ "$edig" =~ ^0* ]]
  exp="${edig:${#BASH_REMATCH[0]}}"
  if (( ${#exp} > 9 )); then e10=1000000000; else e10=$((10#0$exp)); fi
  [[ "$esign" != - ]] || e10=$((-e10))
  sig="$ip$frac"
  [[ "$sig" =~ ^0* ]]
  sig="${sig:${#BASH_REMATCH[0]}}"
  if [[ -z "$sig" ]]; then
    tail="${1:${#1} - ${#1} % 4}"
    [[ "$tail" != *[eE]* || "${tail##*[eE]}" != *[1-9]* ]] || range_problem=zero
    return 0
  fi
  # The value is 0.sig times ten to the power m.
  m=$(( ${#ip} + e10 - (${#ip} + ${#frac} - ${#sig}) ))
  [[ "$sig" =~ 0*$ ]]
  sig="${sig:0:${#sig}-${#BASH_REMATCH[0]}}"
  if [[ "$2" == float ]]; then
    lo_m=-45
    lo_sig=700649232162408535461864791644958065640130970938257885878534141944895541342930300743319094181060791015625
    hi_m=39
    hi_sig=340282356779733661637539395458142568448
  else
    lo_m=-323
    lo_sig=24703282292062327208828439643411068618252990130716238221279284125033775363510437593264991818081799618989828234772285886546332835517796989819938739800539093906315035659515570226392290858392449105184435931802849936536152500319370457678249219365623669863658480757001585769269903706311928279558551332927834338409351978015531246597263579574622766465272827220056374006485499977096599470454020828166226237857393450736339007967761930577506740176324673600968951340535537458516661134223766678604162159680461914467291840300530057530849048765391711386591646239524912623653881879636239373280423891018672348497668235089863388587925628302755995657524455507255189313690836254779186948667994968324049705821028513185451396213837722826145437693412532098591327667236328125
    hi_m=309
    hi_sig=179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497792
  fi
  if ! json_magnitude_above "$sig" "$m" "$lo_sig" "$lo_m"; then
    range_problem=small
  elif ! json_magnitude_above "$hi_sig" "$hi_m" "$sig" "$m"; then
    range_problem=large
  fi
  return 0
}

# For json_range and json_float: whether 0.$1 times 10^$2 is above 0.$3
# times 10^$4, each digit string without leading or trailing zeros, so
# comparing them as text compares their values.
json_magnitude_above() { # digits exponent digits exponent
  local LC_ALL=C
  (( $2 == $4 )) || { (( $2 > $4 )); return; }
  [[ "$1" > "$3" ]]
}

# For json_float: sets product to the decimal digits of $1 times $2, a
# whole number below 2^31.
json_digits_times() { # digits factor
  local s="$1" c p carry=0 out=""
  while [[ -n "$s" ]]; do
    if (( ${#s} > 9 )); then
      c="${s:${#s}-9}"
      s="${s:0:${#s}-9}"
    else
      c="$s"
      s=""
    fi
    p=$(( 10#$c * $2 + carry ))
    carry=$(( p / 1000000000 ))
    printf -v c '%09d' $(( p % 1000000000 ))
    out="$c$out"
  done
  (( carry == 0 )) || out="$carry$out"
  [[ "$out" =~ ^0* ]]
  product="${out:${#BASH_REMATCH[0]}}"
  return 0
}

# What the app's JSONDecoder reads as a Float for the JSON number $1, which
# json_range has found the Float holds. Sets float_bits to that Float's bit
# pattern; float_text to the same Float in 9 significant digits, which
# plutil writes back as text the app reads as that Float; and float_kept to
# 1 when plutil, which edits the journal, writes $1 itself back that way, 0
# when it may not. plutil reads up to 17 significant digits through a
# Double, which it writes back in 17, so a number whose Double is halfway
# between two Floats, or within 16 Double steps of that, may come back on
# the other side of it; it reads more digits through a Decimal that keeps
# 38, so a number with more may come back as another Float; and it reads
# -0 as the whole number 0, which the app reads as +0. The Float is worked
# out exactly: printf reads the number into a long double (a Double on
# Apple silicon), whose bits past the Float's settle the rounding unless
# they are exactly halfway; then the number's digits are compared with the
# halfway point's, worked out here in decimal (json_digits_times). A number
# with more than 120 significant digits is read as its first 120 and a 1
# after them, which lies on the same side of every halfway point, as none
# has more than 113. Non-zero for anything else, which json_range does not
# pass.
json_float() { # number
  local LC_ALL=C number sign ip frac esign edig exp e10 sig m a lead bits B X u k N R p q c
  float_bits=""
  float_text=""
  float_kept=1
  number='^(-?)(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  [[ "$1" =~ $number ]] || return 1
  sign="${BASH_REMATCH[1]}"
  ip="${BASH_REMATCH[2]}"
  frac="${BASH_REMATCH[4]}"
  esign="${BASH_REMATCH[6]}"
  edig="${BASH_REMATCH[7]}"
  sig="$ip$frac"
  [[ "$sig" =~ ^0* ]]
  sig="${sig:${#BASH_REMATCH[0]}}"
  if [[ -z "$sig" ]]; then
    if [[ -n "$sign" ]]; then
      float_bits=2147483648
      float_text=-0.0
      [[ "$1" != -0 ]] || float_kept=0
    else
      float_bits=0
      float_text=0
    fi
    return 0
  fi
  [[ "$edig" =~ ^0* ]]
  exp="${edig:${#BASH_REMATCH[0]}}"
  if (( ${#exp} > 9 )); then e10=1000000000; else e10=$((10#0$exp)); fi
  [[ "$esign" != - ]] || e10=$((-e10))
  # The value is 0.sig times ten to the power m.
  m=$(( ${#ip} + e10 - (${#ip} + ${#frac} - ${#sig}) ))
  [[ "$sig" =~ 0*$ ]]
  sig="${sig:0:${#sig}-${#BASH_REMATCH[0]}}"
  (( ${#sig} <= 38 )) || float_kept=0
  (( ${#sig} <= 120 )) || sig="${sig:0:120}1"
  printf -v a '%a' "0.${sig}e$m" 2>/dev/null || return 1
  [[ "$a" =~ ^0x([0-9a-f])(\.([0-9a-f]+))?p([-+][0-9]+)$ ]] || return 1
  lead=$((16#${BASH_REMATCH[1]}))
  bits="${BASH_REMATCH[3]}"
  X=$(( 10#${BASH_REMATCH[4]#[-+]} ))
  [[ "${BASH_REMATCH[4]}" != -* ]] || X=$((-X))
  # B holds the bits of the long double, the first a 1, and it is 0.B
  # times 2 to the power X.
  B=""
  while (( lead > 0 )); do B="$((lead % 2))$B"; lead=$((lead / 2)); X=$((X + 1)); done
  while [[ -n "$bits" ]]; do
    c=$((16#${bits:0:1}))
    B+="$((c / 8))$((c / 4 % 2))$((c / 2 % 2))$((c % 2))"
    bits="${bits:1}"
  done
  B+="0000000000000000000000000000000000000000000000000000000000000000"
  # The Float is N times 2 to the power u: its step, 2^u, and k bits of B.
  u=$((X - 24))
  (( u >= -149 )) || u=-149
  k=$((X - u))
  (( k >= 0 && k <= 24 )) || return 1
  N=0
  (( k == 0 )) || N=$((2#${B:0:k}))
  R="${B:k}"
  # Within 16 Double steps of halfway: plutil may write it back as halfway.
  p="${R:0:49-k}"
  [[ ! "$p" =~ ^(10*|01*)$ ]] || float_kept=0
  if [[ "${R:0:1}" == 1 ]]; then
    if [[ "${R:1}" == *1* ]]; then
      N=$((N + 1))
    else
      # Exactly halfway in the long double: the halfway point (2N + 1)
      # times 2^(u - 1) in decimal digits, 0.q times 10^c, against the
      # number's.
      q=$((2 * N + 1))
      c=$((u - 1))
      if (( c >= 0 )); then
        while (( c > 0 )); do
          p=$(( c > 30 ? 30 : c ))
          json_digits_times "$q" $((1 << p))
          q="$product"
          c=$((c - p))
        done
        c=${#q}
      else
        p=$((-c))
        while (( p > 0 )); do
          if (( p >= 13 )); then
            json_digits_times "$q" 1220703125
            p=$((p - 13))
          else
            json_digits_times "$q" $((5 ** p))
            p=0
          fi
          q="$product"
        done
        c=$(( ${#q} + c ))
      fi
      [[ "$q" =~ 0*$ ]]
      q="${q:0:${#q}-${#BASH_REMATCH[0]}}"
      if json_magnitude_above "$sig" "$m" "$q" "$c"; then
        N=$((N + 1))
      elif ! json_magnitude_above "$q" "$c" "$sig" "$m" && (( N % 2 == 1 )); then
        N=$((N + 1))
      fi
    fi
  fi
  if (( N == 16777216 )); then
    N=8388608
    u=$((u + 1))
  fi
  (( u + 149 < 255 )) || return 1
  float_bits=$(( ((u + 149) << 23) + N ))
  [[ -z "$sign" ]] || float_bits=$((float_bits + 2147483648))
  printf -v q '%x' "$N"
  printf -v float_text '%.9g' "${sign}0x${q}p$u" 2>/dev/null || return 1
  return 0
}

# What the app's JSONDecoder makes of the text of a string or key it
# decodes, $1 being what lies between the quotes: 0 when it reads it, 1
# when it reads it and it holds \u0000, which plutil refuses, and 2 when it
# throws: a raw control character (NUL, read here as \001, included),
# bytes that are not UTF-8, an escape JSON does not have such as \x41, a
# \u not followed by four hex digits, or a lone surrogate. Regular
# expressions only, so a long string takes time in proportion to its
# length.
json_string_check() { # text between the quotes
  local LC_ALL=C hx ok nul ctl utf8
  hx='[0-9A-Fa-f]'
  # Every backslash starts an escape JSON has; a \u of a high surrogate
  # (D800 to DBFF) is followed by one of a low surrogate (DC00 to DFFF),
  # and a low surrogate comes only there.
  ok="^([^\\\\]|\\\\[\"\\\\/bfnrt]|\\\\u([0-9A-Ca-cE-Fe-f]$hx$hx$hx|[dD][0-7]$hx$hx|[dD][89aAbB]$hx$hx\\\\u[dD][c-fC-F]$hx$hx))*\$"
  nul="^([^\\\\]|\\\\[\"\\\\/bfnrt]|\\\\u$hx$hx$hx$hx)*\\\\u0000"
  ctl=$'[\002-\037]'
  utf8=$'^([^\x80-\xff]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf][\x80-\xbf]|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf][\x80-\xbf]|[\xf1-\xf3][\x80-\xbf][\x80-\xbf][\x80-\xbf]|\xf4[\x80-\x8f][\x80-\xbf][\x80-\xbf])*$'
  # \001 is tested on its own: bash 3.2 drops it from a bracket range.
  [[ "$1" != *$'\001'* && ! "$1" =~ $ctl && "$1" =~ $utf8 && "$1" =~ $ok ]] || return 2
  [[ ! "$1" =~ $nul ]] || return 1
  return 0
}

# For record_text_problems: the text $1 of a string the app reads that
# holds \u0000 (json_string_check), which plutil cannot hold, as the view
# writes it, in marked: each \u0000 as \uE000, U+E000, a character of
# Unicode's private use area, which every journal published from the view
# writes back as \u0000 (journal_candidate_ok in backstop.sh). A journal
# that also holds U+E000 itself is not read (record_text_problems).
# Non-zero without a view, and for a string longer than 1024 bytes, as a
# pattern substitution in bash takes time that grows with the square of
# the length.
json_nul_mark() { # text between the quotes
  local t c=$'\002'
  [[ -n "$view" ]] && (( ${#1} <= 1024 )) || return 1
  # Each \\ first, so that no \u0000 is read across one; the text holds no
  # control character.
  t="${1//\\\\/$c}"
  t="${t//\\u0000/\\uE000}"
  marked="${t//$c/\\\\}"
  return 0
}

# For record_text_problems: adds the view's text $1 for the value just read
# at depth d to where that value goes (puts[d]): the object or array at
# depth d (keep), the frozen process's startedAtMicros or bootSession,
# kept aside until the object ends (micros, boot), or nowhere (drop).
json_view_put() { # text
  case "${puts[d]}" in
    keep)
      (( members[d] == 0 )) || bufs[d]+=,
      bufs[d]+="${pairs[d]}$1"
      members[d]=$((members[d] + 1))
      ;;
    micros) mbufs[d]="${pairs[d]}$1" ;;
    boot) bbufs[d]="${pairs[d]}$1" ;;
  esac
  return 0
}

# For record_text_problems: after a long string or number, hands the
# whole pieces the window rest holds beyond 4096 bytes back to pieces, so
# each step after it copies a short window. rest is always the end of the
# pieces read so far.
json_window_trim() {
  local n=${#rest}
  (( n > 8192 )) || return 0
  while (( next > 0 && n - ${#pieces[next - 1]} >= 4096 )); do
    n=$((n - ${#pieces[next - 1]}))
    next=$((next - 1))
  done
  rest="${rest:0:n}"
  return 0
}

# Prints one line per way the text of state.json $1 would not decode in the
# app, or would read otherwise than plutil reads it, or nothing. With config
# as $2, the same for config.json and the app's Config decoder
# (Config.swift), which config_cutoffs in backstop.sh uses when the app's
# binary cannot answer. Read from the text itself, not through plutil,
# which keeps the last of two copies of a key where the app's JSONDecoder
# keeps the first, reads numbers through a Double or a Decimal where the
# app reads a Float or a whole number, and reads 1., .5, +1, single quotes,
# keys without quotes, comments and other JSON5 forms the app refuses. The
# text is followed the way the app's decoder reads it (swift-foundation
# 6.2): every object and array, at any depth, key by key and value by
# value. What the app decodes (RuntimeState.swift) is checked: the top
# level, the arrays under frozenProcesses, frozenPids, savedAudioOutputs
# and appNapOverrides, the objects in them, and the value under each key
# the app reads in those objects. In config.json: the top level, the arrays
# under presets, freezeList, agentList and tmuxTargets, the object under
# lidCloseDefaultsNotice, and the values the app reads in them, each of the
# type the Config decoder takes there, null too where it reads the key with
# decodeIfPresent. The rest is followed but not checked, as the app skips
# it: a key it does not read and what is under that key, and what is inside
# an object or array where the app reads no object or array. In a frozen
# process the app reads startedAtMicros only after a startedAt that is
# there and not null, and bootSession only after both (FrozenProcess). In
# an object it decodes, the app reads the first copy of a key and skips the
# others, and it matches a key after its escapes are decoded, a Kelvin sign
# (U+212A), written as such or as \u212A, as K. A number where the app
# reads a Float or a Double must not round to infinity, or to 0 unless it
# is 0, the bounds compared as exact decimal digits (json_range), and a 0
# must be written in a way Foundation's isTrueZero takes. One where it
# reads an Int32 or an Int64 must be one it reads as a whole number the
# type holds (json_whole): 5105.0, 1e3 and 1e-400 (as 0) are, 0.5 and, for
# an Int32, 2147483648 are not. The encoding is the one the app's decoder
# takes from the first four bytes; a file in UTF-16 or UTF-32, which the
# app reads but never writes, is read through iconv(1) as UTF-8.
# The lines:
#   - "view: " (state.json with $3 only): what plutil would read otherwise
#     than the app, and how the view (below) holds it: a key the app reads
#     there twice, or written with an escape; a whole number written with a
#     fraction or an exponent; UTF-16 or UTF-32; a bootSession the app
#     does not read that plutil would not read either, left out; a number where the app reads a Float that plutil would
#     write back as text the app reads as another Float (json_float); a NUL
#     byte in text the app skips, which plutil does not read, left out; a
#     string the app reads that holds \u0000, which plutil cannot hold,
#     written with U+E000 for it (json_nul_mark).
#   - "float: " (state.json with floats as $4): each Float the app decodes,
#     where it is and its bit pattern, which journal_candidate_ok in
#     backstop.sh compares with those of the journal it edited.
#   - "record: " (state.json): sessionCutoffs is a value the app reads as no
#     record (RuntimeState.decodeSessionCutoffs): an object, an array, a
#     number, a bool, or a string its decoder does not read. The journal
#     still loads; journal_cutoffs in backstop.sh counts it as foreign. A
#     string the app reads is left to the readers of the record, which
#     check its form.
#   - "value: endFloor <whole number>" and "value: thermalRules
#     <true|false>" (config.json): the values the app reads there.
#   - "rejected: " (config.json): what makes the Config decoder reject the
#     whole file: text that is not JSON it reads, a value of a type it does
#     not take there, a number the type does not hold, a string it does not
#     read, a lidCloseDefaultsNotice without one of its keys.
#   - any other line: what is not known here, in either file: an Int64 on
#     which Foundation stops the app (a precondition in its Decimal parse),
#     a size that cannot be read, a read that does not finish within
#     TEXT_READ_SECONDS. In state.json also what the app does not load
#     where it decodes the journal: the faults of "rejected: " but a value
#     of a type it does not take and a key an entry lacks, which
#     journal_shape_problems checks in the view; a string that holds
#     \u0000 where the app reads it, which plutil refuses, when there is no
#     view, when it is longer than 1024 bytes, or when the journal holds
#     U+E000 as well (json_nul_mark); and a Float that json_float does not
#     work out. A NUL byte, which the shell cannot
#     hold, is read as \001, another control character: the app takes one
#     only inside text it skips, in a string or a key.
# With $3, for state.json, and only when no other line than "view: " and
# "record: " lines is printed, the journal as the app reads it is written to
# the file $3, the view, which plutil reads the way the app reads the text:
# in each object the app decodes, the keys it reads, each once (the first
# copy) and without escapes, in the order of the text; for what it does not
# decode under such a key, an empty object or array of the same kind, or
# the value as written; whole numbers as digits; a number where the app
# reads a Float, when it is 0, as 0 (-0.0 when negative, which plutil
# keeps), when plutil would write it back as another Float, as the same
# Float in 9 digits (json_float), and when it is longer than 40 bytes or
# has an exponent of three digits or more, which plutil may not read, as
# the same value in a form it reads; a string that holds \u0000 with
# U+E000 for it (json_nul_mark); a frozen process's bootSession also
# where the app does not read it, as a string the scripts can read; nothing
# else the app skips. The view drops what the app's own save drops (keys it
# does not read, later copies, a sessionCutoffs it reads as no record).
# The text is read in pieces of 4096 bytes, and long strings and numbers
# with regular expressions only, as a pattern cut in bash takes time that
# grows with the square of the length.
record_text_problems() { # file [state|config] [view] [floats]
  local LC_ALL=C
  local doc rj broken slow piece from bom unit size big=0 large c rest raw name token want d vpath vshown kind rel cls allowed
  local str scalar number lax esc kelvin hex nul nl ws blank problem deadline next count nuls held emit refused view steps n
  local ip frac esign edig sign floats marks pua mark markesc marked nulview
  local -a lead pieces kinds paths shown keys names counts rels knowns begun timed mdecoded bdecoded
  local -a bufs members puts pairs mbufs bbufs bheld
  str='^"([^"\\]|\\[^u]|\\u[^"][^"][^"][^"])*"'
  ws=$' \t\n\r'
  blank="^[$ws]+"
  scalar="^[^],}$ws]+"
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  lax='^[-0-9][-0-9.eE+]*$'
  esc='^u00(4[1-9A-Fa-f]|5[0-9Aa]|6[1-9A-Fa-f]|7[0-9Aa])'
  kelvin='^u212[Aa]'
  hex='^u[0-9A-Fa-f]{4}'
  nul="^null([],}$ws]|$)"
  large=$'[\xf5-\xff]|\xf4[\x90-\xbf]'
  nl=$'\n'
  doc=state.json
  rj=""
  view="${3:-}"
  floats="${4:-}"
  if [[ "${2:-}" == config ]]; then
    doc=config.json
    rj="rejected: "
    view=""
    floats=""
  fi
  # A string the app reads that holds \u0000 (marks), and U+E000 in any
  # string, raw or as an escape (pua): see json_nul_mark.
  marks=0
  pua=0
  mark=$'\xee\x80\x80'
  markesc='\\u[eE]000'
  nulview="holds \\u0000, which plutil cannot hold; written in the view as U+E000 (\\uE000), which each journal published from it writes back as \\u0000"
  broken="${rj}the text of $doc is not JSON the app's decoder reads"
  slow="reading $doc here did not finish within ${TEXT_READ_SECONDS}s, so what the app makes of it is not known here"
  deadline=$((SECONDS + TEXT_READ_SECONDS))
  refused=0
  # The encoding, as the app's decoder takes it from the first four bytes
  # (lead, "" for a NUL byte): a byte order mark (00 00 FE FF for UTF-32BE;
  # FE FF 00 00, which Foundation takes for UTF-32LE's; FE FF for UTF-16BE;
  # FF FE for UTF-16LE, so UTF-32LE's real one, FF FE 00 00, starts UTF-16LE
  # text with a NUL; EF BB BF for UTF-8), which it leaves out; or else where
  # NUL bytes are: 00 00 00 x is UTF-32BE, 00 x 00 x UTF-16BE, x 00 00 00
  # UTF-32LE, x 00 x 00 UTF-16LE, and in a file of two bytes 00 x UTF-16BE
  # and x 00 UTF-16LE. Anything else is UTF-8. bom is the length of the
  # mark.
  lead=()
  {
    for n in 0 1 2 3; do
      IFS= read -r -d '' -n 1 c || break
      lead[n]="$c"
    done
  } < "$1"
  n=${#lead[@]}
  c="${lead[0]-}${lead[1]-}"
  from=UTF-8
  bom=0
  if (( n == 4 )) && [[ -z "$c" && "${lead[2]}${lead[3]}" == $'\xfe\xff' ]]; then
    from=UTF-32BE
    bom=4
  elif (( n == 4 )) && [[ "$c" == $'\xfe\xff' && -z "${lead[2]}${lead[3]}" ]]; then
    from=UTF-32LE
    bom=4
  elif [[ "$c" == $'\xfe\xff' ]]; then
    from=UTF-16BE
    bom=2
  elif [[ "$c" == $'\xff\xfe' ]]; then
    from=UTF-16LE
    bom=2
  elif (( n == 4 )); then
    case "${#lead[0]}${#lead[1]}${#lead[2]}${#lead[3]}" in
      0001) from=UTF-32BE ;;
      0101) from=UTF-16BE ;;
      1000) from=UTF-32LE ;;
      1010) from=UTF-16LE ;;
    esac
  elif (( n == 2 )); then
    case "${#lead[0]}${#lead[1]}" in
      01) from=UTF-16BE ;;
      10) from=UTF-16LE ;;
    esac
  fi
  # The text in pieces of 4096 bytes, read as they are needed. A NUL byte
  # ends a piece early and is read as \001: both are control characters the
  # app takes only inside a string it skips. The shell cannot hold a NUL.
  # Text in UTF-16 or UTF-32 is read here as iconv writes it in UTF-8, the
  # mark left out first as the app does.
  pieces=()
  piece=""
  nuls=0
  if [[ "$from" == UTF-8 ]]; then
    while IFS= read -r -d '' -n 4096 piece; do
      if (( ${#piece} < 4096 )); then piece+=$'\001'; nuls=1; fi
      pieces[${#pieces[@]}]="$piece"
      (( SECONDS <= deadline )) || { echo "$slow"; return 0; }
    done < "$1"
  else
    # The app leaves out a code unit the file ends before the end of. A
    # code point above U+10FFFF, which the app does not read, iconv writes
    # as bytes that are not UTF-8 or, from 0x80000000 up, as a ?, so UTF-32
    # must also come back the same from UTF-8.
    unit=2
    [[ "$from" != UTF-32* ]] || unit=4
    size="$("$STAT" -f %z "$1" 2> /dev/null)" || size=""
    if ! [[ "$size" =~ ^[0-9]+$ ]]; then
      echo "the size of $doc, which is $from, cannot be read, so what the app makes of it is not known here"
      return 0
    fi
    size=$(( size - bom - (size - bom) % unit ))
    if (( size > 0 )) && ! {
      for (( n = 0; n < bom; n++ )); do IFS= read -r -d '' -n 1 c; done
      "$HEAD" -c "$size" | "$ICONV" -f "$from" -t UTF-8 > /dev/null 2>&1
    } < "$1"; then
      echo "${rj}$doc is $from that iconv cannot convert, such as a lone surrogate, which the app's decoder does not read either"
      return 0
    fi
    if [[ "$from" == UTF-32* ]] && (( size > 0 )) && ! {
      for (( n = 0; n < bom; n++ )); do IFS= read -r -d '' -n 1 c; done
      "$HEAD" -c "$size" | "$ICONV" -f "$from" -t UTF-8 2> /dev/null | "$ICONV" -f UTF-8 -t "$from" 2> /dev/null |
        "$CMP" -s - <({
          for (( n = 0; n < bom; n++ )); do IFS= read -r -d '' -n 1 c; done
          "$HEAD" -c "$size"
        } < "$1")
    } < "$1"; then
      echo "${rj}$doc is $from with a code point above U+10FFFF, which the app's decoder does not read"
      return 0
    fi
    while (( size > 0 )) && IFS= read -r -d '' -n 4096 piece; do
      if (( ${#piece} < 4096 )); then piece+=$'\001'; nuls=1; fi
      pieces[${#pieces[@]}]="$piece"
      (( SECONDS <= deadline )) || { echo "$slow"; return 0; }
    done < <({
      for (( n = 0; n < bom; n++ )); do IFS= read -r -d '' -n 1 c; done
      (( size == 0 )) || "$HEAD" -c "$size" | "$ICONV" -f "$from" -t UTF-8 2> /dev/null
    } < "$1")
  fi
  [[ -z "$piece" ]] || pieces[${#pieces[@]}]="$piece"
  count=${#pieces[@]}
  if [[ "$from" != UTF-8 ]]; then
    c=""
    for piece in ${pieces[@]+"${pieces[@]}"}; do
      [[ ! "$c$piece" =~ $large ]] || big=1
      c="${piece:${#piece}-1}"
    done
    if (( big == 1 )); then
      echo "${rj}$doc is $from with a code point above U+10FFFF, which the app's decoder does not read"
      return 0
    fi
  fi
  if [[ -n "$view" && "$from" != UTF-8 ]]; then
    echo "view: $doc is $from, read here as UTF-8"
  fi
  rest=""
  next=0
  while (( ${#rest} < 4096 && next < count )); do rest+="${pieces[next]}"; next=$((next + 1)); done
  [[ "$from" != UTF-8 ]] || rest="${rest#$'\xef\xbb\xbf'}"
  # d is the depth of the object or array being read (1 is the top level,
  # and the app reads no more than 512); for each, kinds holds { or [,
  # paths where it is in the app's terms (frozenProcesses[]), shown the
  # same as a log names it (frozenProcesses[0]), keys its last key, rels 1
  # when the app decodes it, knowns the keys the app reads in it, names
  # the ones read so far, and counts the values an array has had. Where the
  # app decodes an object it reads the first copy of a key and skips the
  # others. In a frozen process, begun is 1 once a startedAt that is not
  # null was read and timed once a startedAtMicros was, and mdecoded and
  # bdecoded hold what is wrong with its startedAtMicros and bootSession,
  # printed at the end of the object only where the app reads them. want
  # is what comes next: a key, a colon, a value, or a comma or the end
  # (next). rel is 1 when the value about to be read is decoded. problem
  # is what is wrong with a value the app decodes.
  # The view (with $3, state.json only) is the journal as the app reads
  # it: bufs holds the text of each object or array the app decodes so
  # far, with members values in it; puts is where the value being read
  # goes (json_view_put) and pairs its key, as "key":. mbufs and bbufs hold
  # a frozen process's startedAtMicros and bootSession until its end, and
  # bheld how the app reads that bootSession's text (json_string_check).
  d=0
  want=value
  steps=0
  while :; do
    while (( ${#rest} < 4096 && next < count )); do rest+="${pieces[next]}"; next=$((next + 1)); done
    [[ ! "$rest" =~ $blank ]] || rest="${rest:${#BASH_REMATCH[0]}}"
    if [[ -z "$rest" ]] && (( next < count )); then continue; fi
    steps=$((steps + 1))
    if (( steps % 256 == 0 && SECONDS > deadline )); then
      echo "$slow"
      return 0
    fi
    c="${rest:0:1}"
    vpath=""
    vshown=""
    rel=0
    allowed=""
    cls=""
    if [[ "$want" == value ]] && (( d > 0 )); then
      if [[ "${kinds[d]}" == "{" ]]; then
        vpath="${paths[d]:+${paths[d]}.}${keys[d]}"
        vshown="${shown[d]:+${shown[d]}.}${keys[d]}"
        [[ "${puts[d]}" == drop ]] || rel=1
      else
        vpath="${paths[d]}[]"
        vshown="${shown[d]}[${counts[d]}]"
        rel="${rels[d]}"
      fi
      if (( rel == 1 )); then
        # allowed is what the app's Config decoder takes there, null where
        # it reads the key with decodeIfPresent.
        case "$doc:$vpath" in
          'state.json:frozenProcesses[].startedAt') [[ "$rest" =~ $nul ]] || begun[d]=1 ;;
          'state.json:frozenProcesses[].startedAtMicros') [[ "$rest" =~ $nul ]] || timed[d]=1 ;;
          config.json:presets|config.json:freezeList|config.json:agentList|config.json:tmuxTargets) allowed='|array|null|' ;;
          config.json:lidCloseDefaultsNotice) allowed='|object|null|' ;;
          config.json:defaultPreset|config.json:maxDuration|config.json:nudgeThreshold|config.json:lowPowerFloor|config.json:endFloor) allowed='|number|null|' ;;
          config.json:hotspotSSID|config.json:launchAtLoginInstall) allowed='|string|null|' ;;
          config.json:freezeAllApps|config.json:dockerRule|config.json:muteOnLidClose|config.json:darkenDisplayOnLidClose|config.json:lowPowerOnLidClose|config.json:disableAppNapForAgents|config.json:thermalRules|config.json:tmuxNudgePressesEnter|config.json:launchAtLogin|config.json:lidCloseDefaultsApplied) allowed='|bool|null|' ;;
          'config.json:presets[]') allowed='|number|' ;;
          'config.json:freezeList[]'|'config.json:agentList[]'|'config.json:tmuxTargets[]') allowed='|string|' ;;
          config.json:lidCloseDefaultsNotice.turnedOffFreezeAll|config.json:lidCloseDefaultsNotice.turnedOnMute) allowed='|bool|' ;;
        esac
      fi
    fi
    if (( d == 0 )) && [[ "$c" != "{" ]]; then
      echo "${rj}$doc is not a JSON object, which the app's decoder requires"
      return 0
    fi
    case "$c" in
      '{'|'[')
        [[ "$want" == value ]] || { echo "$broken"; return 0; }
        if (( d == 512 )); then
          echo "${rj}$doc nests objects and arrays deeper than 512, which the app's decoder does not read"
          return 0
        fi
        if [[ "$c" == "{" ]]; then cls="an object"; else cls="an array"; fi
        if (( rel == 1 )) && [[ "$doc:$vpath" == state.json:sessionCutoffs ]]; then
          echo "record: sessionCutoffs is ${cls}, which the app does not read as a record"
          puts[d]=drop
        fi
        d=$((d + 1))
        (( d > 1 )) || rel=1
        kinds[d]="$c"
        paths[d]="$vpath"
        shown[d]="$vshown"
        keys[d]=""
        names[d]="|"
        counts[d]=0
        knowns[d]=""
        rels[d]=0
        begun[d]=0
        timed[d]=0
        mdecoded[d]=""
        bdecoded[d]=""
        bufs[d]=""
        members[d]=0
        puts[d]=drop
        pairs[d]=""
        mbufs[d]=""
        bbufs[d]=""
        bheld[d]=""
        if [[ "$c" == "{" ]]; then
          want=key
          if (( rel == 1 )); then
            case "$doc:$vpath" in
              state.json:) knowns[d]='|sleepDisabledByUs|lowPowerSetByUs|frozenProcesses|frozenPids|dockerFrozen|savedAudioOutputs|savedOutputVolume|savedMuted|savedDisplayBrightness|savedKeyboardBrightness|displayRestoredUnderLowPower|displayRestoreRefused|keyboardRestoreRefused|keptDisplayUnderLowPower|keptDisplayUnderLowPowerBoot|keptDisplayReadLit|appNapOverrides|endedSession|sessionCutoffs|' ;;
              'state.json:frozenProcesses[]') knowns[d]='|pid|startedAt|startedAtMicros|bootSession|' ;;
              'state.json:savedAudioOutputs[]') knowns[d]='|deviceUID|name|volume|muted|saveID|' ;;
              'state.json:appNapOverrides[]') knowns[d]='|bundleId|previous|' ;;
              config.json:) knowns[d]='|presets|defaultPreset|maxDuration|freezeList|freezeAllApps|dockerRule|muteOnLidClose|darkenDisplayOnLidClose|lowPowerOnLidClose|agentList|disableAppNapForAgents|lowPowerFloor|endFloor|thermalRules|hotspotSSID|nudgeThreshold|tmuxTargets|tmuxNudgePressesEnter|launchAtLogin|launchAtLoginInstall|lidCloseDefaultsApplied|lidCloseDefaultsNotice|' ;;
              config.json:lidCloseDefaultsNotice) knowns[d]='|turnedOffFreezeAll|turnedOnMute|' ;;
            esac
            [[ -z "${knowns[d]}" ]] || rels[d]=1
          fi
        else
          want=value
          if (( rel == 1 )); then
            case "$doc:$vpath" in
              state.json:frozenProcesses|state.json:frozenPids|state.json:savedAudioOutputs|state.json:appNapOverrides) rels[d]=1 ;;
              config.json:presets|config.json:freezeList|config.json:agentList|config.json:tmuxTargets) rels[d]=1 ;;
            esac
          fi
          (( rels[d] == 0 )) || puts[d]=keep
        fi
        rest="${rest:1}"
        ;;
      '}'|']')
        # An empty object or array, or a comma before the end, which the
        # app accepts.
        if [[ "$c" == "}" ]]; then
          [[ "${kinds[d]}" == "{" && ( "$want" == key || "$want" == next ) ]] || { echo "$broken"; return 0; }
          if [[ "$doc:${paths[d]}" == config.json:lidCloseDefaultsNotice && "${rels[d]}" == 1 ]]; then
            for n in turnedOffFreezeAll turnedOnMute; do
              [[ "${names[d]}" == *"|$n|"* ]] || echo "${rj}lidCloseDefaultsNotice has no $n, which the app's decoder requires there"
            done
          fi
          if [[ "$doc:${paths[d]}" == 'state.json:frozenProcesses[]' && "${rels[d]}" == 1 ]]; then
            # The app reads startedAtMicros only after a startedAt, and
            # bootSession only after both; an entry without them has no
            # identity. A bootSession the app does not read is kept as a
            # string the scripts can read, for an entry an older build wrote
            # without startedAtMicros, which they compare on startedAt and
            # bootSession alone.
            if (( begun[d] == 1 )); then
              printf '%s' "${mdecoded[d]}"
              [[ -z "${mdecoded[d]}" ]] || refused=1
              if [[ -n "${mbufs[d]}" ]]; then
                (( members[d] == 0 )) || bufs[d]+=,
                bufs[d]+="${mbufs[d]}"
                members[d]=$((members[d] + 1))
              fi
            fi
            if (( begun[d] == 1 && timed[d] == 1 )); then
              printf '%s' "${bdecoded[d]}"
              [[ -z "${bdecoded[d]}" ]] || refused=1
              if [[ "${bheld[d]}" == 1 && -z "${bdecoded[d]}" ]]; then
                echo "view: ${shown[d]}.bootSession $nulview"
                marks=1
              fi
            else
              if [[ -n "${bbufs[d]}" && "${bheld[d]}" != 0 ]]; then
                [[ -z "${bheld[d]}" ]] || echo "view: ${shown[d]}.bootSession, which the app does not read there, is a string the app would not read; left out"
                bbufs[d]=""
              fi
            fi
            if [[ -n "${bbufs[d]}" ]]; then
              (( members[d] == 0 )) || bufs[d]+=,
              bufs[d]+="${bbufs[d]}"
              members[d]=$((members[d] + 1))
            fi
          fi
        else
          [[ "${kinds[d]}" == "[" && ( "$want" == value || "$want" == next ) ]] || { echo "$broken"; return 0; }
        fi
        rest="${rest:1}"
        if (( rels[d] == 1 )); then emit="${kinds[d]}${bufs[d]}$c"; elif [[ "$c" == "}" ]]; then emit="{}"; else emit="[]"; fi
        d=$((d - 1))
        if (( d == 0 )); then
          # Only whitespace may follow.
          while :; do
            [[ ! "$rest" =~ $blank ]] || rest="${rest:${#BASH_REMATCH[0]}}"
            if [[ -n "$rest" ]] || (( next >= count )); then break; fi
            rest="${pieces[next]}"
            next=$((next + 1))
          done
          if [[ -n "$rest" ]]; then
            echo "${rj}text follows the end of $doc's top-level object, which the app's decoder does not read"
            return 0
          fi
          break
        fi
        [[ -z "$view" ]] || json_view_put "$emit"
        want=next
        if [[ "${kinds[d]}" == "[" ]]; then counts[d]=$((counts[d] + 1)); fi
        ;;
      ,)
        [[ "$want" == next ]] || { echo "$broken"; return 0; }
        if [[ "${kinds[d]}" == "{" ]]; then want=key; else want=value; fi
        rest="${rest:1}"
        ;;
      :)
        [[ "$want" == colon ]] || { echo "$broken"; return 0; }
        want=value
        rest="${rest:1}"
        ;;
      '"')
        # The window doubles until it holds the whole string.
        until [[ "$rest" =~ $str ]] || (( next >= count )); do
          n=${#rest}
          while (( n > 0 && next < count )); do
            n=$((n - ${#pieces[next]}))
            rest+="${pieces[next]}"
            next=$((next + 1))
          done
        done
        [[ "$rest" =~ $str ]] || { echo "$broken"; return 0; }
        raw="${BASH_REMATCH[0]}"
        rest="${rest:${#raw}}"
        json_window_trim
        raw="${raw:1:${#raw}-2}"
        if [[ -n "$view" ]] && (( pua == 0 )) && [[ "$raw" == *"$mark"* || "$raw" =~ $markesc ]]; then pua=1; fi
        if [[ "$want" == key ]]; then
          # The key as a log names it: its first 64 bytes, with ? for each
          # one that is not a letter, a digit or _.
          keys[d]="${raw:0:64}"
          keys[d]="${keys[d]//[^A-Za-z0-9_]/?}"
          puts[d]=drop
          pairs[d]=""
          if (( rels[d] == 1 )); then
            # The app reads every key of an object it decodes.
            held=0
            json_string_check "$raw" || held=$?
            if (( held == 2 )); then
              echo "${rj}a key in ${shown[d]:-the top level of $doc} is text the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)"
              refused=1
            fi
            # The key as the app reads it. Of the escapes JSON has, only a
            # \u of a letter or of the Kelvin sign, which the app's keys
            # match as K, can be part of a key of letters alone, as every
            # key the app reads is; the others stand for no letter.
            # Such a key is at most 28 letters, each written in at most 6
            # bytes.
            name="?"
            if (( ${#raw} <= 256 )); then
              name="${raw//$'\xe2\x84\xaa'/K}"
              token="$name"
              name=""
              while [[ "$token" == *\\* ]]; do
                name+="${token%%\\*}"
                token="${token#*\\}"
                if [[ "$token" =~ $esc ]]; then
                  printf -v c '%b' "\\x${BASH_REMATCH[1]}"
                  name+="$c"
                  token="${token:5}"
                elif [[ "$token" =~ $kelvin ]]; then
                  name+=K
                  token="${token:5}"
                elif [[ "$token" =~ $hex ]]; then
                  name+="?"
                  token="${token:5}"
                else
                  name+="?"
                  token="${token:1}"
                fi
              done
              name+="$token"
            fi
            if [[ "$name" =~ ^[A-Za-z]+$ && "${knowns[d]}" == *"|$name|"* ]]; then
              keys[d]="$name"
              if [[ "${names[d]}" == *"|$name|"* ]]; then
                [[ -z "$view" ]] || echo "view: ${shown[d]:-the top level of $doc} has $name more than once; the app reads the first, and so is it read here"
              else
                names[d]+="$name|"
                puts[d]=keep
                pairs[d]="\"$name\":"
                if [[ -n "$view" && "$raw" != "$name" ]]; then
                  echo "view: ${shown[d]:-the top level of $doc} has $name written as another key the app reads as $name; read here as $name"
                fi
                case "$doc:${paths[d]}:$name" in
                  'state.json:frozenProcesses[]:startedAtMicros') puts[d]=micros ;;
                  'state.json:frozenProcesses[]:bootSession') puts[d]=boot ;;
                esac
              fi
            fi
          fi
          want='colon'
        elif [[ "$want" == value ]]; then
          cls="a string"
          if (( rel == 1 )); then
            held=0
            json_string_check "$raw" || held=$?
            emit="\"$raw\""
            problem=""
            case "$doc:$vpath:$held" in
              state.json:sessionCutoffs:0) ;;
              state.json:sessionCutoffs:*)
                echo "record: sessionCutoffs is a string the app does not read as a record"
                emit=""
                ;;
              'state.json:frozenProcesses[].bootSession:'*)
                bheld[d]="$held"
                (( held != 2 )) || problem="$vshown is a string the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)"
                if (( held == 1 )); then
                  if json_nul_mark "$raw"; then emit="\"$marked\""; else problem="$vshown holds \\u0000, which the app reads and plutil does not; not read here"; fi
                fi
                ;;
              *:2) problem="${rj}$vshown is a string the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)" ;;
              state.json:*:1)
                if json_nul_mark "$raw"; then
                  emit="\"$marked\""
                  echo "view: $vshown $nulview"
                  marks=1
                else
                  problem="$vshown holds \\u0000, which the app reads and plutil does not; not read here"
                fi
                ;;
            esac
            case "$doc:$vpath" in
              'state.json:frozenProcesses[].startedAtMicros') mdecoded[d]+="${problem}${problem:+$nl}" ;;
              'state.json:frozenProcesses[].bootSession') bdecoded[d]+="${problem}${problem:+$nl}" ;;
              *)
                if [[ -n "$problem" ]]; then
                  echo "$problem"
                  refused=1
                fi
                ;;
            esac
            [[ -z "$view" || -z "$emit" ]] || json_view_put "$emit"
          fi
          want=next
          if [[ "${kinds[d]}" == "[" ]]; then counts[d]=$((counts[d] + 1)); fi
        else
          echo "$broken"
          return 0
        fi
        ;;
      *)
        [[ "$want" == value && "$rest" =~ $scalar ]] || { echo "$broken"; return 0; }
        while (( ${#BASH_REMATCH[0]} == ${#rest} && next < count )); do
          n=${#rest}
          while (( n > 0 && next < count )); do
            n=$((n - ${#pieces[next]}))
            rest+="${pieces[next]}"
            next=$((next + 1))
          done
          [[ "$rest" =~ $scalar ]]
        done
        token="${BASH_REMATCH[0]}"
        rest="${rest:${#token}}"
        json_window_trim
        problem=""
        emit="$token"
        # The app checks a number it does not read as one with a looser
        # rule.
        if [[ "$token" != null && "$token" != true && "$token" != false && ! "$token" =~ $lax ]]; then
          token="${token:0:40}"
          echo "${rj}${vshown:-$doc} is written as ${token//[^ -~]/?}, which is not a JSON value the app's decoder reads"
          return 0
        fi
        kind=any
        if (( rel == 1 )); then
          case "$doc:$vpath" in
            state.json:keptDisplayUnderLowPower|state.json:keptDisplayReadLit|state.json:displayRestoredUnderLowPower|state.json:savedOutputVolume|state.json:savedDisplayBrightness|state.json:savedKeyboardBrightness|'state.json:savedAudioOutputs[].volume') kind=float ;;
            'state.json:frozenProcesses[].pid'|'state.json:frozenProcesses[].startedAtMicros'|'state.json:frozenPids[]') kind=int32 ;;
            'state.json:frozenProcesses[].startedAt'|config.json:lowPowerFloor|config.json:endFloor) kind=int64 ;;
            'config.json:presets[]'|config.json:defaultPreset|config.json:maxDuration|config.json:nudgeThreshold) kind=double ;;
            state.json:sessionCutoffs) kind=record ;;
          esac
        fi
        case "$token" in
          true|false) cls="a bool" ;;
          null) cls=null ;;
          *) cls="a number" ;;
        esac
        if (( rel == 0 )); then
          :
        elif [[ "$kind" == record ]]; then
          # Anything but null is a record the app does not read: none.
          if [[ "$token" != null ]]; then
            echo "record: sessionCutoffs is written as ${token:0:40}, which the app does not read as a record"
            emit=""
          fi
        elif [[ "$token" == null || "$token" == true || "$token" == false || "$kind" == any ]]; then
          :
        elif ! [[ "$token" =~ $number ]]; then
          problem="${rj}$vshown is written as ${token:0:40}, which is not a JSON number the app's decoder reads"
        elif [[ "$kind" == float || "$kind" == double ]]; then
          json_range "$token" "$kind"
          case "$range_problem" in
            small) problem="${rj}$vshown is ${token:0:40}, which the app reads as a ${kind/f/F} that is not 0 and rounds to 0, and throws" ;;
            large) problem="${rj}$vshown is ${token:0:40}, too large a number for the app's ${kind/f/F}" ;;
            zero) problem="${rj}$vshown is ${token:0:40}, a 0 written in a way the app's decoder does not read" ;;
          esac
          if [[ "$kind" == float && -z "$range_problem" ]]; then
            if ! json_float "$token"; then
              problem="$vshown is ${token:0:40}, a number whose Float is not worked out here, so what the app reads is not known here"
            elif [[ -n "$floats" ]]; then
              echo "float: $vshown $float_bits"
            fi
          fi
          if [[ "$kind" == float && -n "$view" && -z "$range_problem" && -z "$problem" ]]; then
            [[ "$token" =~ $number ]]
            # In a form plutil reads, of the same value: plutil gives up on
            # a 0 with a long exponent, and on more than 17 digits where
            # the exponent its Decimal holds would leave -128...127. A
            # number longer than 40 bytes or with an exponent of three
            # digits or more is passed on as 0.digits times a power of ten
            # from -45 to 39, which it reads. One plutil would write back
            # as text the app reads as another Float is passed on as the
            # same Float in 9 digits (json_float).
            ip="${BASH_REMATCH[1]}"
            frac="${BASH_REMATCH[3]}"
            esign="${BASH_REMATCH[5]}"
            edig="${BASH_REMATCH[6]}"
            raw="$ip$frac"
            [[ "$raw" =~ ^0* ]]
            raw="${raw:${#BASH_REMATCH[0]}}"
            sign=""
            [[ "$token" != -* ]] || sign=-
            if (( float_kept == 0 )); then
              echo "view: $vshown is written as ${token:0:40}, which plutil would write back as text the app reads as another Float; read here as $float_text"
              emit="$float_text"
            elif [[ -z "$raw" ]]; then
              emit="$float_text"
            elif (( ${#token} > 40 || ${#edig} > 2 )); then
              [[ "$edig" =~ ^0* ]]
              n="${edig:${#BASH_REMATCH[0]}}"
              if (( ${#n} > 9 )); then n=1000000000; else n=$((10#0$n)); fi
              [[ "$esign" != - ]] || n=$((-n))
              n=$(( ${#ip} + n - (${#ip} + ${#frac} - ${#raw}) ))
              [[ "$raw" =~ 0*$ ]]
              raw="${raw:0:${#raw}-${#BASH_REMATCH[0]}}"
              emit="${sign}0.${raw}e$n"
            fi
          fi
        elif [[ "$kind" == int32 || "$kind" == int64 ]]; then
          json_whole "$token" "$kind"
          if (( whole_trap == 1 )); then
            problem="$vshown is ${token:0:40}, on which the app's decoder stops the app (a Foundation precondition), so what it reads is not known here"
          elif [[ -z "$whole_value" ]]; then
            problem="${rj}$vshown is ${token:0:40}, which the app's decoder does not read as a whole number it holds there"
          else
            emit="$whole_value"
            if [[ -n "$view" && "$token" != "$whole_value" ]]; then
              echo "view: $vshown is written as ${token:0:40}, which the app reads as $whole_value; read here as $whole_value"
            fi
            if [[ "$doc:$vpath" == config.json:endFloor ]]; then echo "value: endFloor $whole_value"; fi
          fi
        fi
        if (( rel == 1 )) && [[ "$doc:$vpath" == config.json:thermalRules && ( "$token" == true || "$token" == false ) ]]; then
          echo "value: thermalRules $token"
        fi
        case "$doc:$vpath" in
          'state.json:frozenProcesses[].startedAtMicros') mdecoded[d]+="${problem}${problem:+$nl}" ;;
          'state.json:frozenProcesses[].bootSession')
            bheld[d]=""
            bdecoded[d]+="${problem}${problem:+$nl}"
            ;;
          *)
            if [[ -n "$problem" ]]; then
              echo "$problem"
              refused=1
            fi
            ;;
        esac
        [[ -z "$view" || -z "$emit" || "$rel" == 0 ]] || json_view_put "$emit"
        want=next
        if [[ "${kinds[d]}" == "[" ]]; then counts[d]=$((counts[d] + 1)); fi
        ;;
    esac
    if [[ -n "$cls" && -n "$allowed" && "$allowed" != *"|${cls##* }|"* ]]; then
      echo "${rj}$vshown is $cls, which the app's decoder does not take there"
    fi
  done
  if [[ -n "$view" ]] && (( marks == 1 && pua == 1 )); then
    echo "$doc holds \\u0000 where the app reads it, which the view writes as U+E000, and U+E000 as well, so what the app reads is not known here"
    refused=1
  fi
  if [[ -n "$view" ]] && (( refused == 0 )); then
    (( nuls == 0 )) || echo "view: $doc holds a NUL byte in text the app skips, which plutil does not read; left out"
    printf '%s\n' "$emit" > "$view"
  fi
  return 0
}

# Prints one line per way the journal does not have the shape the app writes
# (RuntimeState.swift). Present keys must have the right type; a JSON null is
# the same as an absent optional (Swift decodeIfPresent).
journal_shape_problems() { # file
  local f="$1" key t i n
  if ! shape_types "$f"; then
    echo "state.json is not a JSON object"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen savedMuted displayRestoreRefused keyboardRestoreRefused; do
    shape_type "$f" "$key"
    [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "$key is a $(shape_name "$f" "$key" "$t"), not a bool"
  done
  for key in savedOutputVolume savedDisplayBrightness savedKeyboardBrightness displayRestoredUnderLowPower; do
    shape_type "$f" "$key"
    [[ -z "$t" || "$t" == number || "$t" == "(any)" ]] || echo "$key is a $(shape_name "$f" "$key" "$t"), not a number"
  done
  shape_type "$f" endedSession
  [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "endedSession is a $(shape_name "$f" endedSession "$t"), not a string"
  # sessionCutoffs is a record and not checked here: the app reads a value
  # it does not write as none and records its own over it, so it never
  # makes the journal unusable. read_cutoffs reads it strictly where it is
  # used, through the app's binary or journal_cutoffs.
  # The app's records about a kept display entry: kept for the app, never
  # read for an undo here. Each must still decode, or the app cannot read
  # the journal at all.
  for key in keptDisplayUnderLowPower keptDisplayReadLit; do
    shape_type "$f" "$key"
    [[ -z "$t" || "$t" == number || "$t" == "(any)" ]] || echo "$key is a $(shape_name "$f" "$key" "$t"), not a number"
  done
  shape_type "$f" keptDisplayUnderLowPowerBoot
  [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "keptDisplayUnderLowPowerBoot is a $(shape_name "$f" keptDisplayUnderLowPowerBoot "$t"), not a string"
  shape_type "$f" frozenProcesses
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenProcesses is a $(shape_name "$f" frozenProcesses "$t"), not an array"
    else
      i=0
      while shape_type "$f" "frozenProcesses.$i"; [[ -n "$t" ]]; do
        if [[ "$t" != dictionary ]]; then
          echo "frozenProcesses[$i] is not an object"
        else
          # record_text_problems has read each whole number here as the
          # app reads it, and the journal read here (check_journal) holds
          # each as digits. As in FrozenProcess, startedAtMicros counts
          # only after a startedAt that is there and not null, and
          # bootSession only after both; an entry without them has no
          # identity, and the app does not read what follows.
          shape_type "$f" "frozenProcesses.$i.pid"
          [[ "$t" == number ]] || echo "frozenProcesses[$i].pid is not an integer"
          for n in startedAt startedAtMicros bootSession; do
            shape_type "$f" "frozenProcesses.$i.$n"
            [[ -n "$t" && "$t" != "(any)" ]] || break
            if [[ "$n" == bootSession ]]; then
              [[ "$t" == string ]] || echo "frozenProcesses[$i].bootSession is a $(shape_name "$f" "frozenProcesses.$i.$n" "$t"), not a string"
            else
              [[ "$t" == number ]] || echo "frozenProcesses[$i].$n is a $(shape_name "$f" "frozenProcesses.$i.$n" "$t"), not an integer"
            fi
          done
        fi
        i=$((i + 1))
      done
    fi
  fi
  shape_type "$f" frozenPids
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenPids is a $(shape_name "$f" frozenPids "$t"), not an array"
    else
      i=0
      while shape_type "$f" "frozenPids.$i"; [[ -n "$t" ]]; do
        [[ "$t" == number ]] || echo "frozenPids[$i] is not an integer"
        i=$((i + 1))
      done
    fi
  fi
  shape_type "$f" savedAudioOutputs
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "savedAudioOutputs is a $(shape_name "$f" savedAudioOutputs "$t"), not an array"
    else
      i=0
      while shape_type "$f" "savedAudioOutputs.$i"; [[ -n "$t" ]]; do
        if [[ "$t" != dictionary ]]; then
          echo "savedAudioOutputs[$i] is not an object"
        else
          shape_type "$f" "savedAudioOutputs.$i.deviceUID"
          [[ "$t" == string ]] || echo "savedAudioOutputs[$i].deviceUID is not a string"
          shape_type "$f" "savedAudioOutputs.$i.volume"
          [[ "$t" == number ]] || echo "savedAudioOutputs[$i].volume is not a number"
          shape_type "$f" "savedAudioOutputs.$i.muted"
          [[ "$t" == bool ]] || echo "savedAudioOutputs[$i].muted is not a bool"
          shape_type "$f" "savedAudioOutputs.$i.name"
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].name is a $(shape_name "$f" "savedAudioOutputs.$i.name" "$t"), not a string"
          shape_type "$f" "savedAudioOutputs.$i.saveID"
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].saveID is a $(shape_name "$f" "savedAudioOutputs.$i.saveID" "$t"), not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  shape_type "$f" appNapOverrides
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "appNapOverrides is a $(shape_name "$f" appNapOverrides "$t"), not an array"
    else
      i=0
      while shape_type "$f" "appNapOverrides.$i"; [[ -n "$t" ]]; do
        if [[ "$t" != dictionary ]]; then
          echo "appNapOverrides[$i] is not an object"
        else
          shape_type "$f" "appNapOverrides.$i.bundleId"
          [[ "$t" == string ]] || echo "appNapOverrides[$i].bundleId is not a string"
          shape_type "$f" "appNapOverrides.$i.previous"
          [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "appNapOverrides[$i].previous is a $(shape_name "$f" "appNapOverrides.$i.previous" "$t"), not a bool"
        fi
        i=$((i + 1))
      done
    fi
  fi
}

# Whether the journal loads as the app loads it (Store.loadState). Sets
# journal_state to missing, malformed (shape_problems says why) or clean.
# Run before anything uses the journal or ends a valid session, and once
# per version of the file: each write here (record_end_in_journal,
# prepare_low_power_off) has it run again.
# record_text_problems reads the text first, as the app's decoder reads
# it. A line from it other than "view: ", "record: " and "float: " makes
# the journal malformed: a value the app does not decode, or text whose
# meaning to the app is not known here (a read that did not finish, say).
# journal_floats keeps the "float: " lines, each Float the app decodes,
# which every edited copy published below must keep (journal_candidate_ok).
# journal_marks is 1 when the view writes a string the app reads that holds
# \u0000 with U+E000 for it (json_nul_mark), which journal_candidate_ok
# writes back. The journal every read below then uses, JOURNAL, is
# state.json itself, or,
# when plutil would read the text otherwise than the app ("view: " lines)
# or cannot parse it at all (text under a key the app does not read, such
# as a leading zero), the view record_text_problems wrote: the journal as
# the app reads it, in a form plutil reads the same way. The type checks
# (journal_shape_problems) run on JOURNAL. Each publish below starts from a
# copy of JOURNAL, so a journal published from the view keeps what the
# app's own save keeps (see record_text_problems) and loses the rest:
# unknown keys, later copies of a key, a sessionCutoffs the app reads as no
# record. journal_text holds the reader's lines for journal_cutoffs.
JOURNAL="$STATE"
JOURNAL_VIEW="$APP_SUPPORT/.state.json.backstop-view.$$"
journal_text=""
journal_floats=""
journal_marks=0
journal_checked=0
journal_state=""
shape_problems=""
check_journal() {
  local line problems=""
  (( journal_checked == 0 )) || return 0
  journal_checked=1
  shape_problems=""
  journal_text=""
  journal_floats=""
  journal_marks=0
  JOURNAL="$STATE"
  # A view left by an earlier run that was killed, this run's own among
  # them; one under a shared lock may belong to a run that has not ended,
  # as in remove_stale_run_files.
  if (( ! lock_shared )); then
    "$RM" -f "$APP_SUPPORT"/.state.json.backstop-view.* 2>/dev/null || true
  else
    "$RM" -f "$JOURNAL_VIEW" 2>/dev/null || true
  fi
  if [[ ! -e "$STATE" ]]; then
    journal_state=missing
    return 0
  elif [[ ! -f "$STATE" ]]; then
    # Never opened, for the same reason as session.json above.
    journal_state=malformed
    shape_problems="not a regular file"
    return 0
  fi
  journal_text="$(record_text_problems "$STATE" state "$JOURNAL_VIEW" floats)"
  while IFS= read -r line; do
    case "$line" in
      "view: "*"written in the view as U+E000"*) journal_marks=1 ;;
      ""|"view: "*|"record: "*) ;;
      "float: "*) journal_floats+="${line#float: }"$'\n' ;;
      *) problems+="$line"$'\n' ;;
    esac
  done <<< "$journal_text"
  if [[ -n "$problems" ]]; then
    "$RM" -f "$JOURNAL_VIEW" 2>/dev/null || true
    journal_state=malformed
    shape_problems="${problems%$'\n'}"
    return 0
  fi
  if [[ $'\n'"$journal_text" == *$'\n'"view: "* ]] || ! "$PLUTIL" -convert json -o /dev/null "$STATE" >/dev/null 2>&1; then
    JOURNAL="$JOURNAL_VIEW"
  else
    "$RM" -f "$JOURNAL_VIEW" 2>/dev/null || true
  fi
  # plutil has read state.json just above where JOURNAL is state.json.
  if [[ ! -f "$JOURNAL" ]]; then
    journal_state=malformed
    shape_problems="the journal as the app reads it could not be written to $JOURNAL_VIEW"
  elif [[ "$JOURNAL" != "$STATE" ]] && ! "$PLUTIL" -convert json -o /dev/null "$JOURNAL" >/dev/null 2>&1; then
    journal_state=malformed
    shape_problems="not valid JSON"
  else
    shape_problems="$(journal_shape_problems "$JOURNAL")"
    if [[ -n "$shape_problems" ]]; then journal_state=malformed; else journal_state=clean; fi
  fi
}
trap '"$RM" -f "$JOURNAL_VIEW" "$JOURNAL_VIEW.candidate" 2>/dev/null || true' EXIT

# Whether the file $1, a copy of JOURNAL that plutil edited, may be renamed
# over state.json: a JSON object, not a property list, that the app loads
# (record_text_problems finds no problem in it, journal_shape_problems none
# in it as the app reads it), with every Float the app decodes the same,
# where it is and bit for bit, as in the journal it was copied from ($2,
# that journal's "float: " lines, journal_floats). plutil writes every
# number back through a Double or a Decimal, which can turn the text of a
# level the app reads as one Float into text it reads as another
# (json_float); such a copy is not published, and the run keeps the
# journal it has. A copy of a view that writes \u0000 as U+E000
# (journal_marks) first has each U+E000, which plutil writes as such, put
# back as \u0000; the journal held no U+E000 of its own (json_nul_mark),
# and the copy must then hold none, raw or as an escape.
journal_candidate_ok() { # file floats
  local line ok=1 floats="" view="$JOURNAL_VIEW.candidate" rc=0
  [[ "$("$PLUTIL" -convert json -o - "$1" 2>/dev/null | "$HEAD" -c 1)" == "{" ]] || return 1
  [[ "$("$HEAD" -c 1 "$1")" == "{" ]] || return 1
  "$RM" -f "$view" 2>/dev/null || true
  if (( journal_marks == 1 )); then
    if ! { "$SED" "s/"$'\xee\x80\x80'"/\\\\u0000/g" "$1" > "$view" 2>/dev/null && "$MV" -f "$view" "$1" 2>/dev/null; }; then
      "$RM" -f "$view" 2>/dev/null || true
      return 1
    fi
    "$GREP" -q -e $'\xee\x80\x80' -e '\\u[eE]000' "$1" 2>/dev/null || rc=$?
    (( rc == 1 )) || return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      ""|"view: "*|"record: "*) ;;
      "float: "*) floats+="${line#float: }"$'\n' ;;
      *) ok=0 ;;
    esac
  done < <(record_text_problems "$1" state "$view" floats)
  if (( ok == 1 )) && ! same_floats "$floats" "${2:-}"; then
    log error "the edited copy of $STATE holds a level the app would read as another Float than the journal's; not published"
    ok=0
  fi
  (( ok == 1 )) && [[ -f "$view" && -z "$(journal_shape_problems "$view")" ]] || ok=0
  "$RM" -f "$view" 2>/dev/null || true
  (( ok == 1 ))
}

# Whether $1 and $2, each the "float: " lines of record_text_problems
# without the tag, one to a line and each ending in a newline, name the
# same Floats in any order: plutil writes keys in an order of its own.
same_floats() { # floats floats
  local line n=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ $'\n'"$2" == *$'\n'"$line"$'\n'* ]] || return 1
    n=$((n + 1))
  done <<< "$1"
  while IFS= read -r line; do
    [[ -z "$line" ]] || n=$((n - 1))
  done <<< "$2"
  (( n == 0 ))
}

# Stops the run at a journal the app does not load (journal_state
# malformed): nothing is undone, removed or recorded. The journal is the
# only record of what was changed, and the app neither ends, resumes nor
# starts a session on one it cannot load, so a valid session stays in
# session.json, ended by the first run after a repair; $1 is what this run
# then does not do with it.
refuse_malformed_journal() { # [what is not done with the valid session]
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && log error "$STATE: $line"
  done <<< "$shape_problems"
  log error "$STATE is unreadable or malformed; nothing undone, evidence kept. Open Insomnia or repair the file, then rerun"
  if [[ -n "${1:-}" ]]; then
    log error "$SESSION is kept as it is: $1 while $STATE does not load as the app loads it"
  fi
  exit 1
}

# Seconds since the epoch for a date in the one form session.json may hold,
# or nothing. Store.parseDate in the app reads exactly this form:
# 2027-01-15T08:00:00Z, which is what Store.swift writes, or the same with
# an offset such as +02:00 or -05:30 in place of Z. Whole seconds, a date
# and time that exist, years 1970 to 9999, offsets up to 23:59. `date -j -f`
# rolls an impossible day or second over, so the result is formatted back
# and must match.
epoch_of() { # string
  local form='^([0-9]{4})-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|([+-])([0-9]{2}):([0-9]{2}))$'
  local clock offset=0 e
  [[ "$1" =~ $form ]] || return 0
  (( 10#${BASH_REMATCH[1]} >= 1970 )) || return 0
  if [[ "${BASH_REMATCH[2]}" != Z ]]; then
    (( 10#${BASH_REMATCH[4]} <= 23 && 10#${BASH_REMATCH[5]} <= 59 )) || return 0
    offset=$(( 10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 ))
    if [[ "${BASH_REMATCH[3]}" == - ]]; then offset=$(( -offset )); fi
  fi
  clock="${1:0:19}"
  e="$("$DATE" -j -u -f '%Y-%m-%dT%H:%M:%S' "$clock" +%s 2>/dev/null)" || return 0
  if [[ "$("$DATE" -u -r "$e" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" == "$clock" ]]; then
    echo $(( e - offset ))
  fi
  return 0
}

# epoch_of the string at a keypath, read exactly as the app's decoder sees
# it. Command substitution strips every trailing newline, stored ones too,
# so a sentinel follows plutil's output and only plutil's own newline is
# cut: "...Z\n" in the file is refused here as it is in the app.
epoch_at() { # file keypath
  local v
  v="$(extract "$1" "$2"; echo .)"
  v="${v%.}"
  epoch_of "${v%$'\n'}"
}

# Prints one line per way session.json does not have the shape the app's
# Session decoder needs (Session.swift): a JSON object whose startedAt and
# endsAt are dates as Store.swift writes them and whose extensions is an
# array of numbers. All three are required; extra keys are ignored, as in
# Swift. The app refuses a file with any of these problems, so the shell
# does not act on its endsAt either.
session_shape_problems() { # file
  local f="$1" key t i
  # plutil also reads XML and binary property lists, which the app's
  # JSONDecoder refuses, so the file itself must start with "{" too.
  if [[ "$(LC_ALL=C "$TR" -d ' \t\r\n' < "$f" 2>/dev/null | "$HEAD" -c 1)" != "{" ]] \
     || [[ "$("$PLUTIL" -convert json -o - "$f" 2>/dev/null | "$HEAD" -c 1)" != "{" ]]; then
    echo "session.json is not a JSON object"
    return 0
  fi
  for key in startedAt endsAt; do
    t="$(type_of "$f" "$key")"
    if [[ -z "$t" ]]; then
      echo "$key is missing"
    elif [[ "$t" != string ]]; then
      echo "$key is a JSON $t, not a date string"
    elif [[ -z "$(epoch_at "$f" "$key")" ]]; then
      echo "$key is not a date in the form 2027-01-15T08:00:00Z or 2027-01-15T10:00:00+02:00"
    fi
  done
  t="$(type_of "$f" extensions)"
  if [[ -z "$t" ]]; then
    echo "extensions is missing"
  elif [[ "$t" != array ]]; then
    echo "extensions is a JSON $t, not an array"
  else
    i=0
    while [[ -n "$(type_of "$f" "extensions.$i")" ]]; do
      t="$(type_of "$f" "extensions.$i")"
      [[ "$t" == integer || "$t" == float ]] || echo "extensions[$i] is a JSON $t, not a number"
      i=$((i + 1))
    done
  fi
}

# --- Read the session --------------------------------------------------------
# session_state: none | valid | expired | malformed | unreadable
session_state=none
ends_at=""
unreadable_why=""
session_problems=""
if [[ -e "$SESSION" ]]; then
  # Only a regular file is opened: open(2) on a FIFO with no writer, or on
  # some devices, blocks, and this run holds the recovery lock.
  if [[ ! -f "$SESSION" ]]; then
    session_state=unreadable
    unreadable_why="it is not a regular file, so it is not opened"
  elif ! "$CAT" "$SESSION" >/dev/null 2>&1; then
    session_state=unreadable
    unreadable_why="permissions or I/O"
  else
    session_problems="$(session_shape_problems "$SESSION")"
    if [[ -n "$session_problems" ]]; then
      session_state=malformed
    else
      ends_at="$(extract "$SESSION" endsAt || true)"
      if (( $(epoch_at "$SESSION" endsAt) > $("$DATE" -u +%s) )); then
        session_state=valid
      else
        session_state=expired
      fi
    fi
  fi
fi

# Whether $ENDED records the end of the session in $SESSION: it holds that
# file's exact bytes. cmp opens both files, and open(2) on a FIFO with no
# writer blocks while this run holds the recovery lock, which would keep
# both this script and the app from ever ending the session. So only two
# regular files are compared, as session.json and state.json are only read
# as regular files. The app and record_end both write the record by
# rename, so anything else at $ENDED is not a record and matches nothing.
end_recorded() {
  [[ -f "$SESSION" && -f "$ENDED" ]] && "$CMP" -s "$SESSION" "$ENDED"
}

# Remove the record. Once its session.json is gone it ends nothing, but it
# is still a copy of that session's times, so one that cannot be removed is
# logged on every run until a person removes it. Never fails the caller.
remove_end_record() {
  "$RM" -f "$ENDED" 2>/dev/null && return 0
  log warn "could not remove $ENDED; it matches no session.json, so it ends nothing, but it stays until removed by hand (ls -lO shows its flags)"
  return 0
}

# Remove $ENDED when it is shown to match no session.json: session.json is
# gone, or cmp finds other bytes (exit 1). Anything at $ENDED that is not a
# regular file is not a record and goes too; rm unlinks a FIFO without
# opening it. A record that cmp cannot compare (exit 2: either file
# unreadable), or one beside a session.json that is not a regular file,
# stays, as remove_stale_end_records_aside keeps such a record aside: it is
# not shown to be stale, and once the file can be read again it ends the
# session it copies. While cmp cannot compare it, it matches nothing
# (end_recorded). Never fails.
remove_stale_end_record() {
  local rc=0
  [[ -e "$ENDED" || -L "$ENDED" ]] || return 0
  if [[ -f "$ENDED" && ( -e "$SESSION" || -L "$SESSION" ) ]]; then
    [[ -f "$SESSION" ]] || return 0
    "$CMP" -s "$SESSION" "$ENDED" || rc=$?
    (( rc == 1 )) || return 0
  fi
  remove_end_record
}

# session.json's bytes in base64 on one line, as Swift's
# Data.base64EncodedString() writes them, or nothing. Only a regular file
# is opened, as in end_recorded.
session_base64() {
  [[ -f "$SESSION" ]] || return 1
  "$BASE64" 2>/dev/null < "$SESSION"
}

# Whether the journal records the end of the session in $SESSION instead:
# its endedSession key holds that file's bytes in base64. The record the
# app and record_end_in_journal write when $ENDED cannot be written. Read
# as the app reads it (check_journal: the first copy of the key, after its
# escapes); a journal the app does not load records nothing, for the app
# as here.
journal_records_end() {
  local recorded current
  [[ -f "$SESSION" && -f "$STATE" ]] || return 1
  check_journal
  [[ "$journal_state" == clean ]] || return 1
  [[ "$(type_of "$JOURNAL" endedSession)" == string ]] || return 1
  recorded="$(extract "$JOURNAL" endedSession)" || return 1
  current="$(session_base64)" || return 1
  [[ -n "$current" && "$recorded" == "$current" ]]
}

# Records written under a fresh name when neither $ENDED nor the journal can
# hold the record (record_end_aside): the same copy of session.json's bytes,
# beside $ENDED, or in $LOG_DIR when $APP_SUPPORT takes no new file. Only
# these two folders are searched, and $LOG_DIR only while it is a directory,
# not a symlink, owned by this user (set_aside_dirs). In them, only a
# regular file (not a symlink) owned by this user whose name is
# ended-session.json. and eight letters or digits counts, the names mktemp
# here and the app (Store.recordSessionEndAside) create; anything else with
# such a name is never opened or removed.
is_end_record_aside() { # path
  [[ "${1##*/}" =~ ^ended-session\.json\.[A-Za-z0-9]{8}$ && -f "$1" && ! -L "$1" && -O "$1" ]]
}
aside_dirs=()
set_aside_dirs() {
  aside_dirs=("$APP_SUPPORT")
  if [[ -d "$LOG_DIR" && ! -L "$LOG_DIR" && -O "$LOG_DIR" ]]; then aside_dirs+=("$LOG_DIR"); fi
}

# Whether a record aside matches session.json; sets aside_match to it.
aside_match=""
end_recorded_aside() {
  local d f
  aside_match=""
  [[ -f "$SESSION" ]] || return 1
  set_aside_dirs
  for d in "${aside_dirs[@]}"; do
    for f in "$d"/ended-session.json.????????; do
      is_end_record_aside "$f" || continue
      if "$CMP" -s "$SESSION" "$f"; then
        aside_match="$f"
        return 0
      fi
    done
  done
  return 1
}

# Remove each record aside that matches no session.json: all of them once
# the file is gone, and one that differs from it byte for byte. One that
# cmp cannot compare (either file unreadable, session.json not a regular
# file) stays: it is not shown to be stale, and it ends nothing while cmp
# cannot match it. Never fails.
remove_stale_end_records_aside() {
  local d f rc
  set_aside_dirs
  for d in "${aside_dirs[@]}"; do
    for f in "$d"/ended-session.json.????????; do
      is_end_record_aside "$f" || continue
      rc=1
      if [[ -e "$SESSION" || -L "$SESSION" ]]; then
        [[ -f "$SESSION" ]] || continue
        rc=0
        "$CMP" -s "$SESSION" "$f" || rc=$?
      fi
      (( rc == 1 )) || continue
      "$RM" -f "$f" 2>/dev/null \
        || log warn "could not remove $f; it matches no session.json, so it ends nothing, but it stays until removed by hand (ls -lO shows its flags)"
    done
  done
  return 0
}

# The last place an end is recorded (record_end_in_lock), for when $ENDED,
# the journal and both folders refuse the record: the recovery lock file,
# which exists already, so the record needs no new file. Its contents are
# then the record and nothing else: LOCK_RECORD_TAG, a space, session.json's
# bytes in base64 on one line (as session_base64 prints them), and a
# newline. It is written in place, so the file keeps its inode and every
# party still locks the same file, and it is never unlinked. Only a regular
# file, not a symlink, owned by this user is read or written as one; the
# app reads it the same way (Store.lockEndRecord). read_lock_record sets
# lock_record_state:
#   none        the file is empty, or not such a file: no record.
#   record      a whole record; lock_record holds its base64.
#   foreign     read, and not one whole record: a write cut short, other
#               bytes, or more bytes than any record (lock_record_why says
#               which). It ends no session, unless it is the record of the
#               session in session.json cut short as a writer leaves it
#               (lock_holds_record_cut_short), which counts as that
#               session's end. remove_stale_lock_record empties content
#               that ends nothing, and a record written here replaces it.
#               lock_content holds content read whole, up to the bound.
#   unreadable  its size or bytes could not be read in LOCK_READ_ATTEMPTS
#               reads, LOCK_READ_RETRY_SECONDS apart (lock_record_why): a
#               passing error or a change caught partway must not end a
#               session the file says nothing about. It may hold a whole
#               record of the session in session.json, so it counts as that
#               session's end, the safe side, until it can be read or
#               session.json is gone (end_recorded_in_lock,
#               remove_stale_lock_record).
# Every writer holds the lock, and this run reads it under the lock, so a
# length other than the size is a NUL byte (bash drops them) and not a
# write in progress.
lock_record_state=none
lock_record=""
lock_record_why=""
lock_content=""
read_lock_record() {
  local attempt=1
  read_lock_record_once
  while [[ "$lock_record_state" == unreadable ]] && (( attempt < LOCK_READ_ATTEMPTS )); do
    sleep "$LOCK_READ_RETRY_SECONDS"
    attempt=$((attempt + 1))
    read_lock_record_once
  done
}

read_lock_record_once() {
  local size content body re="^${LOCK_RECORD_TAG} ([A-Za-z0-9+/]+={0,2})\$"
  lock_record_state=none
  lock_record=""
  lock_record_why=""
  lock_content=""
  [[ -f "$LOCK" && ! -L "$LOCK" && -O "$LOCK" ]] || return 0
  lock_record_state=unreadable
  size="$("$STAT" -f %z "$LOCK" 2>/dev/null)" || size=""
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    lock_record_why="its size could not be read"
    return 0
  fi
  if (( size == 0 )); then
    lock_record_state=none
    return 0
  fi
  # The sentinel keeps a trailing newline that command substitution strips.
  if (( size <= LOCK_RECORD_MAX_BYTES )) && ! content="$("$CAT" "$LOCK" 2>/dev/null && printf x)"; then
    lock_record_why="it could not be read"
    return 0
  fi
  lock_record_state=foreign
  if (( size > LOCK_RECORD_MAX_BYTES )); then
    lock_record_why="it holds $size bytes, more than an end record"
    return 0
  fi
  content="${content%x}"
  # LC_ALL=C: the length counts bytes. bash drops NUL bytes, so a length
  # other than the size means bytes no record has.
  if (( ${#content} != size )); then
    lock_record_why="it holds bytes other than one whole end record"
    return 0
  fi
  lock_content="$content"
  if [[ "$content" != *$'\n' ]]; then
    lock_record_why="it holds bytes other than one whole end record"
    return 0
  fi
  body="${content%$'\n'}"
  if [[ "$body" =~ $re ]] && (( ${#BASH_REMATCH[1]} % 4 == 0 )); then
    lock_record_state=record
    lock_record="${BASH_REMATCH[1]}"
    return 0
  fi
  lock_record_why="it holds bytes other than one whole end record"
  return 0
}

# Whether the lock file holds the record of session.json's bytes ($1, in
# base64) cut short as a writer leaves it when it stops partway (content
# read whole that is no record, see read_lock_record): the record's first
# bytes and nothing else (record_end_in_lock empties the file, then
# writes; a write that fails partway), or the whole record followed by
# bytes the file held before (the app writes over the old bytes before it
# cuts the file to length). A writer was recording that end, so it counts
# as one, the safe side. Other content that is no record ends nothing. The
# app reads the same way (Store.lockHoldsRecordCutShort).
lock_holds_record_cut_short() {
  local whole="$LOCK_RECORD_TAG $1"$'\n'
  [[ "$lock_record_state" == foreign && -n "$lock_content" && -n "$1" ]] || return 1
  if (( ${#lock_content} < ${#whole} )); then
    [[ "${whole:0:${#lock_content}}" == "$lock_content" ]]
  else
    (( ${#lock_content} > ${#whole} )) && [[ "${lock_content:0:${#whole}}" == "$whole" ]]
  fi
}

# Whether the recovery lock file records the end of the session in
# $SESSION: a record of exactly its bytes, that record cut short
# (lock_holds_record_cut_short), or a file that cannot be read, which may
# hold one (see read_lock_record). Other content read whole that is not a
# record ends nothing. Sets lock_match_why for the log.
lock_match_why=""
end_recorded_in_lock() {
  local current
  lock_match_why=""
  [[ -f "$SESSION" ]] || return 1
  read_lock_record
  case "$lock_record_state" in
    unreadable)
      lock_match_why="$LOCK, which $lock_record_why, so it may hold this session's end and counts as one"
      return 0 ;;
    record)
      current="$(session_base64)" || return 1
      [[ -n "$current" && "$lock_record" == "$current" ]] || return 1
      lock_match_why="$LOCK"
      return 0 ;;
    foreign)
      current="$(session_base64)" || return 1
      lock_holds_record_cut_short "$current" || return 1
      lock_match_why="$LOCK, which holds this session's end record cut short, so it counts as one"
      return 0 ;;
  esac
  return 1
}

# Whether the lock file at $LOCK is a regular file, not a symlink, owned by
# this user, and the file this run holds the lock on (fd 9): the only file
# an end record is written to or emptied from.
lock_is_held_file() {
  local held named
  [[ -f "$LOCK" && ! -L "$LOCK" && -O "$LOCK" ]] || return 1
  held="$(inode /dev/fd/9)"
  named="$(inode "$LOCK")"
  [[ -n "$held" && "$held" == "$named" ]]
}

# Empty the recovery lock file of what ends nothing: anything in it once
# session.json is gone, and, while session.json is a regular file that can
# be read, a whole record of other bytes and content read whole that is no
# record and not its record cut short (foreign, see read_lock_record and
# lock_holds_record_cut_short). A file that cannot be read stays while
# session.json is there, and so do a record and other content while
# session.json is not a regular file or cannot be read: none is shown to
# be stale. Emptied in place (the inode stays), only while $LOCK is the
# file this run holds; never unlinked. Never fails.
remove_stale_lock_record() {
  local current
  read_lock_record
  [[ "$lock_record_state" != none ]] || return 0
  if [[ -e "$SESSION" || -L "$SESSION" ]]; then
    [[ "$lock_record_state" != unreadable && -f "$SESSION" ]] || return 0
    current="$(session_base64)" || return 0
    [[ -n "$current" ]] || return 0
    if [[ "$lock_record_state" == record ]]; then
      [[ "$lock_record" != "$current" ]] || return 0
    elif lock_holds_record_cut_short "$current"; then
      return 0
    fi
  fi
  if [[ "$lock_record_state" == foreign ]]; then
    log info "emptying $LOCK: $lock_record_why, which ends no session" || true
  fi
  if lock_is_held_file && { : > "$LOCK"; } 2>/dev/null; then return 0; fi
  log warn "could not empty $LOCK of content that ends no session; it ends nothing, and the next run tries again" || true
  return 0
}

# The place after the lock file (record_end_in_log): one line appended to
# insomnia.log, which exists already, so the record needs no new file and no
# write in place. The line is LOG_RECORD_TAG, the number of bytes in
# session.json and those bytes in base64, separated by single spaces
# (LogEndRecord.swift in the app writes and reads the same line).
# log_record_line prints it for session.json as it is now, without the
# newline, or fails for a file that is not a regular file, is empty, is
# longer than LOG_RECORD_MAX_BYTES or does not read back at its size.
log_record_line() {
  local size encoded
  [[ -f "$SESSION" ]] || return 1
  size="$("$STAT" -f %z "$SESSION" 2>/dev/null)" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size > 0 && size <= LOG_RECORD_MAX_BYTES )) || return 1
  encoded="$(session_base64)" || return 1
  # Base64 of exactly $size bytes, no more and no fewer.
  (( ${#encoded} == 4 * ((size + 2) / 3) )) || return 1
  printf '%s %s %s' "$LOG_RECORD_TAG" "$size" "$encoded"
}

# Whether insomnia.log or insomnia.log.1 holds a whole line equal to
# log_record_line: the end of exactly the session in $SESSION. A line is
# ended by a newline or the end of the file, as grep reads it, so a write
# cut short, a line another write broke into, or a record of other bytes
# matches nothing. Only a regular file, not a symlink, owned by this user,
# of at most LOG_SCAN_MAX_BYTES, is read. A log that cannot be read records
# nothing here; the app's rotation keeps it (LogEndRecord.keepRecords). Sets
# log_match to the file.
log_match=""
end_recorded_in_log() {
  local line f size
  log_match=""
  line="$(log_record_line)" || return 1
  for f in "$LOG" "$LOG.1"; do
    [[ -f "$f" && ! -L "$f" && -O "$f" ]] || continue
    size="$("$STAT" -f %z "$f" 2>/dev/null)" || continue
    if ! [[ "$size" =~ ^[0-9]+$ ]] || (( size > LOG_SCAN_MAX_BYTES )); then continue; fi
    if "$GREP" -Fxq -e "$line" < "$f" 2>/dev/null; then
      log_match="$f"
      return 0
    fi
  done
  return 1
}

# --- Was this session already ended? -----------------------------------------
# A run or the app that ends a valid session but cannot remove session.json
# records the end in $ENDED, a copy of the file's exact bytes (record_end),
# or, when that cannot be written either, in the journal's endedSession
# (record_end_in_journal), or else in a new file beside them or in $LOG_DIR
# (record_end_aside), or else in the recovery lock file
# (record_end_in_lock). While a record matches, that session is over
# whatever its endsAt says: this run ends it again without the checks below
# and retries the removal. A record at $ENDED, aside or in the lock file
# that is shown to match nothing (its session.json was removed, or holds
# other bytes) is stale and goes; it could only ever match the file it
# copied. One that cannot be compared (session.json or the record cannot
# be read) stays. An endedSession that matches nothing ends nothing; it
# stays until the app removes it, which the app does before it writes a new
# session.json.
ended_before=0
ended_where=""
remove_stale_end_record
remove_stale_end_records_aside
remove_stale_lock_record
if end_recorded; then
  ended_before=1
  ended_where="$ENDED"
elif journal_records_end; then
  ended_before=1
  ended_where="$STATE (endedSession)"
elif end_recorded_aside; then
  ended_before=1
  ended_where="$aside_match"
elif end_recorded_in_lock; then
  ended_before=1
  ended_where="$lock_match_why"
  # A lock file that cannot be read only may hold the end; a record in the
  # log shows it, so the log is named then.
  if [[ "$lock_record_state" == unreadable ]] && end_recorded_in_log; then
    ended_where="$log_match"
  fi
elif end_recorded_in_log; then
  ended_before=1
  ended_where="$log_match"
fi

# --- Is a valid session still live? ------------------------------------------
# A future deadline alone does not keep sleep disabled: the app must be
# running and the machine within the floors the app would enforce itself.
# The app's own floors fire first while it is healthy; these catch a crashed,
# force-quit or stopped app. Nothing here changes the machine: the checks
# only decide whether the session counts as over, and the undo below is the
# same as for an expired one.

# The app holds an exclusive flock on $ALIVE for its whole lifetime
# (AppAliveLock.swift). The probe takes the lock without waiting and gives it
# back at once (the command runs under it and exits), so it can only succeed
# when nobody else holds it: lockf exits 75 (EX_TEMPFAIL) when the lock is
# held, the one outcome that proves an app is there. -k keeps the file, so
# the app and every later probe lock the same inode. A probe that fails some
# other way (the file cannot be created, lockf itself fails) counts as not
# alive: sleep must not stay disabled on a guess.
app_alive() {
  local rc=0
  "$LOCKF" -k -s -t 0 "$ALIVE" /usr/bin/true 2>/dev/null || rc=$?
  (( rc == 75 )) && return 0
  (( rc == 0 )) || log warn "alive lock probe on $ALIVE failed (lockf exit $rc); counting Insomnia as not running"
  return 1
}

# The end floor and thermal rule the app enforces. The app decides what its
# files mean, so this script reads config.json and the journal's
# sessionCutoffs itself only when the app's binary cannot answer for them,
# and then only where it can tell exactly what the app makes of them. It
# hands a file's bytes on standard input to one of the installed app
# binary's one-shot modes (AgentCutoffsCommand.swift), which decodes them
# with the app's own decoder and prints the cutoffs. The file is opened
# once, by the shell, for that call. Run as a read (run_read): bounded,
# with the recovery lock's fd closed, and stopped when it does not answer.
# The binary opens no file, writes nothing and takes no lock, so it answers
# while the app itself is hung. Called once per run, only for a valid
# session while the app is alive. Sets cutoff_floor (0 is off, else 1 to
# 95) and cutoff_thermal (true or false):
#   - config.json a regular file this user can read: `Insomnia
#     --agent-cutoffs <seconds>` decodes it through the whole Config decoder
#     (Store.decodeConfig: duplicate and escaped keys, numbers it rounds, an
#     error in any other field). "cutoffs <floor> <true|false>" with exit 0
#     is that floor and rule, the ones the app takes from a file that
#     decodes (Config.agentCutoffs). "rejected" with exit 65 is a file the
#     app does not use; the journal's record applies, as below.
#   - the binary cannot answer for config.json (missing or not executable,
#     a bundle whose Info.plist does not declare InsomniaAgentCutoffsVersion
#     AGENT_CUTOFFS_VERSION, since an older build has no such mode and would
#     open the menu bar app instead, a timeout, another exit status or
#     answer): config_cutoffs reads the file here, with an error logged. A
#     file it finds the app decodes gives that floor and rule, as from the
#     binary; one it finds the app rejects counts as rejected. Any other
#     leaves the journal's record, and without one the strictest (below).
#     The binary is not run again on the journal.
#   - config.json missing, a dangling symlink, not a regular file (never
#     opened: open(2) on a FIFO blocks), not readable by this user, or
#     rejected: the cutoffs the app enforces for this session, which it
#     records in state.json (sessionCutoffs) before the session starts or
#     resumes and before a change to them takes effect. No state.json, or a
#     symlink there to nothing, which the app reads as no journal
#     (Store.readData) and replaces at its next write, gives the app's
#     defaults (Config.agentDefaultCutoffs), 10% and on, what the app
#     enforces while config.json is missing and it has recorded none (as an
#     older build did). Otherwise the journal must first load as the app
#     loads it (check_journal). One that does not stops the run with the
#     session kept (refuse_malformed_journal): the app neither ends nor
#     resumes a session on it, and nothing says which cutoffs it holds.
#     Then `Insomnia --agent-session-cutoffs <seconds>` decodes the whole
#     journal with the app's decoder (Store.decodeState) and reads
#     sessionCutoffs from it. "cutoffs <floor> <true|false>" with exit 0 is
#     that floor and rule. "none" with exit 0 (no record) and "foreign" with
#     exit 65 (a value the app does not write, which the app reads as none)
#     give the app's defaults. "rejected" with exit 65, a journal the app
#     does not load, stops the run as above. When the binary cannot answer
#     for the journal, journal_cutoffs reads the record here, with an error
#     logged.
#   - config.json there and read neither by the binary nor here, and no
#     record (none, a value the app does not write, no journal or a symlink
#     to nothing): the strictest cutoffs, a 95% end floor and thermal rules
#     on, with an error logged. Nothing on disk then says which cutoffs the
#     app enforces; it may hold others from that file. On battery power
#     this ends the session below 95%. The app rewrites the record within a
#     second while it answers (publishSessionCutoffs), so this needs an app
#     that has stopped answering.
# The strictest cutoffs here, and the defaults where config.json is missing
# or rejected and nothing is recorded, are stopgaps, not a decided policy:
# docs/spec.md lists both as open.
cutoff_floor=10
cutoff_thermal=true
read_cutoffs() {
  local answer_re='^cutoffs ([0-9]|[1-8][0-9]|9[0-5]) (true|false)$'
  local fallback failed what older="" defaults=1 ask_binary=1 record="" here=0 quiet=0 rule
  cutoff_floor=10
  cutoff_thermal=true
  if [[ -f "$CONFIG" && -r "$CONFIG" ]]; then
    ask_app_cutoffs --agent-cutoffs "$CONFIG"
    if [[ -z "$cutoffs_why" ]] && (( cutoffs_rc == 0 )) && [[ "$cutoffs_answer" =~ $answer_re ]]; then
      cutoff_floor="${BASH_REMATCH[1]}"
      cutoff_thermal="${BASH_REMATCH[2]}"
      return 0
    elif [[ -z "$cutoffs_why" ]] && (( cutoffs_rc == 65 )) && [[ "$cutoffs_answer" == rejected ]]; then
      fallback="$CONFIG is rejected by the app"
    else
      failed="${cutoffs_why:-$(cutoffs_failure --agent-cutoffs)}"
      ask_binary=0
      config_cutoffs
      if [[ "$config_answer" =~ $answer_re ]]; then
        cutoff_floor="${BASH_REMATCH[1]}"
        cutoff_thermal="${BASH_REMATCH[2]}"
        rule=on
        [[ "$cutoff_thermal" == true ]] || rule=off
        log error "could not read the end floor and thermal rule in $CONFIG through the app's binary: $failed; enforcing the file's, read here as the app's decoder reads it: a ${cutoff_floor}% end floor and thermal rules $rule"
        return 0
      elif [[ "$config_answer" == rejected ]]; then
        fallback="could not read the end floor and thermal rule in $CONFIG through the app's binary: $failed; read here, the app rejects it: $config_why"
      else
        fallback="could not read the end floor and thermal rule in $CONFIG through the app's binary ($failed) or here ($config_why)"
        defaults=0
      fi
    fi
  else
    fallback="$CONFIG is missing or cannot be read"
  fi
  if [[ ! -e "$STATE" ]]; then
    record=none
    if [[ -L "$STATE" ]]; then
      what="$STATE is a symlink to nothing, which the app reads as no journal"
    else
      what="there is no $STATE"
      # Logged only when the binary could not answer for config.json.
      (( ask_binary == 0 )) || quiet=1
    fi
  else
    check_journal
    [[ "$journal_state" != malformed ]] || refuse_malformed_journal "its cutoffs are not read and it is not ended"
    if (( ask_binary == 1 )); then
      ask_app_cutoffs --agent-session-cutoffs "$STATE"
      if [[ -z "$cutoffs_why" ]] && (( cutoffs_rc == 0 )) && [[ "$cutoffs_answer" =~ $answer_re || "$cutoffs_answer" == none ]]; then
        record="$cutoffs_answer"
        quiet=1
      elif [[ -z "$cutoffs_why" ]] && (( cutoffs_rc == 65 )) && [[ "$cutoffs_answer" == rejected ]]; then
        journal_state=malformed
        shape_problems="the app's decoder does not load it ('$INSOMNIA_BIN --agent-session-cutoffs' answered rejected)"
        refuse_malformed_journal "its cutoffs are not read and it is not ended"
      elif [[ -z "$cutoffs_why" ]] && (( cutoffs_rc == 65 )) && [[ "$cutoffs_answer" == foreign ]]; then
        record=foreign
      else
        fallback="$fallback, and the app's binary could not read $STATE: ${cutoffs_why:-$(cutoffs_failure --agent-session-cutoffs)}"
      fi
    fi
    if [[ -z "$record" ]]; then
      record="$(journal_cutoffs)"
      here=1
    fi
    if [[ "$record" =~ $answer_re ]]; then
      cutoff_floor="${BASH_REMATCH[1]}"
      cutoff_thermal="${BASH_REMATCH[2]}"
      rule=on
      [[ "$cutoff_thermal" == true ]] || rule=off
      (( here == 0 )) || log error "$fallback; enforcing the cutoffs recorded for the session in $STATE, read here: a ${cutoff_floor}% end floor and thermal rules $rule"
      return 0
    elif [[ "$record" == none ]]; then
      what="$STATE records no cutoffs for the session"
      older=" (an older build started it)"
    else
      what="the cutoffs recorded for the session in $STATE are a value the app does not write, which it reads as none"
    fi
  fi
  if (( defaults == 1 )); then
    (( quiet == 1 )) || log error "$fallback; $what$older, so the app's defaults apply, a 10% end floor and thermal rules on"
    return 0
  fi
  cutoff_floor=95
  cutoff_thermal=true
  log error "$fallback, and $what; nothing on disk says which cutoffs the app enforces, so enforcing the strictest, a 95% end floor and thermal rules on"
  return 0
}

# config.json read here, for when the app's binary cannot answer for it:
# the end floor and thermal rule the app takes from it, only where this
# reader can tell exactly what the app's Config decoder makes of it. The
# file is copied once through a bounded read (run_read with read_keep), so
# one version of it is read even if the app replaces it meanwhile, and
# record_text_problems reads the copy in config mode, from its text alone:
# plutil is not used. More than CONFIG_READ_LIMIT bytes, the most the
# binary's --agent-cutoffs mode reads (AgentCutoffsCommand.maxInputBytes),
# is not read here either. A "rejected: " line is a value the Config
# decoder does not take: it rejects the whole file, and no field is read
# from it. Any other line but "value: " lines is text whose meaning to the
# app is not known here (an Int64 on which Foundation stops the app, a read
# that did not finish within TEXT_READ_SECONDS), and the file is not used.
# A file with a line of each kind counts as rejected, though the app stops
# instead where it decodes the field that stops it first. Otherwise
# endFloor is the whole number the reader found the app reads ("value:
# endFloor"), 10 when absent or null, clamped to 0 to 95 as
# Config.agentCutoffs clamps it, and thermalRules the bool it reads
# ("value: thermalRules"), true when absent or null. Sets config_answer to
# "cutoffs <floor> <true|false>", "rejected" or nothing, and config_why to
# what was found otherwise.
CONFIG_READ_LIMIT=8388608
config_answer=""
config_why=""
config_cutoffs() {
  local copy="" rc=0 size text line rejected="" other="" floor=10 rule=true
  config_answer=""
  config_why=""
  read_input="$CONFIG"
  read_keep=1
  run_read copy "$HEAD" -c "$((CONFIG_READ_LIMIT + 1))" || rc=$?
  read_input=""
  read_keep=0
  copy="$kept_output"
  if (( rc != 0 )) || [[ -z "$copy" ]]; then
    if (( rc == 124 )); then
      config_why="copying it did not finish within ${COMMAND_TIMEOUT_SECONDS}s"
    else
      config_why="copying it failed (exit $rc)"
    fi
    [[ -z "$copy" ]] || "$RM" -f "$copy"
    return 0
  fi
  size="$("$STAT" -f %z "$copy" 2>/dev/null || true)"
  if ! [[ "$size" =~ ^[0-9]+$ ]]; then
    config_why="the size of its copy cannot be read"
  elif (( size > CONFIG_READ_LIMIT )); then
    config_why="it holds more than $CONFIG_READ_LIMIT bytes, which is not read here"
  else
    text="$(record_text_problems "$copy" config)"
    while IFS= read -r line; do
      case "$line" in
        "") ;;
        "rejected: "*) [[ -n "$rejected" ]] || rejected="${line#rejected: }" ;;
        "value: endFloor "*) floor="${line#value: endFloor }" ;;
        "value: thermalRules "*) rule="${line#value: thermalRules }" ;;
        *) [[ -n "$other" ]] || other="$line" ;;
      esac
    done <<< "$text"
    if [[ "$floor" =~ ^-[0-9]+$ ]]; then
      floor=0
    elif [[ "$floor" =~ ^[0-9]+$ ]]; then
      if (( ${#floor} > 2 )); then floor=95; else floor=$((10#$floor)); fi
      if (( floor > 95 )); then floor=95; fi
    else
      floor=""
    fi
    if [[ -n "$rejected" ]]; then
      config_answer=rejected
      config_why="$rejected"
    elif [[ -n "$other" ]]; then
      config_why="$other"
    elif [[ -n "$floor" && ( "$rule" == true || "$rule" == false ) ]]; then
      config_answer="cutoffs $floor $rule"
    else
      config_why="the reader gave endFloor and thermalRules as values the app's decoder does not take"
    fi
  fi
  "$RM" -f "$copy"
}

# The journal's sessionCutoffs read here, for when the app's binary cannot
# read it: "cutoffs <floor> <true|false>", "none" for no record (the key
# absent or null) or "foreign" for a value the app does not write. Only
# for a journal check_journal found loads, and from the journal as the app
# reads it (JOURNAL): the first copy of the key, after its escapes. A value
# the app reads as no record ("record: " lines in journal_text: an object,
# an array, a number, a bool, a string its decoder does not read) is
# foreign. plutil -extract raw prints the string and a newline; the dot
# keeps any other trailing newline, which the app does not accept either.
# The test is the one AgentCutoffs(journalValue:) makes.
journal_cutoffs() {
  local t v re='^([0-9]|[1-8][0-9]|9[0-5]) (true|false)$'
  if [[ $'\n'"$journal_text" == *$'\n'"record: "* ]]; then
    echo foreign
    return 0
  fi
  t="$(type_of "$JOURNAL" sessionCutoffs)"
  if [[ -z "$t" || "$t" == "(any)" ]]; then
    echo none
    return 0
  fi
  v="$({ extract "$JOURNAL" sessionCutoffs || true; }; echo .)"
  v="${v%.}"
  v="${v%$'\n'}"
  if [[ "$t" == string && "$v" =~ $re ]]; then
    echo "cutoffs ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  else
    echo foreign
  fi
}

# Run the app binary's mode $1 (--agent-cutoffs or --agent-session-cutoffs)
# on the bytes of file $2, as a read. Sets cutoffs_answer and cutoffs_rc, or
# cutoffs_why when the binary was not run.
cutoffs_answer=""
cutoffs_rc=0
cutoffs_why=""
ask_app_cutoffs() { # flag file
  local declared=""
  cutoffs_answer=""
  cutoffs_rc=0
  cutoffs_why=""
  # A regular file only: a FIFO there could block this run under the lock.
  if [[ -f "$INSOMNIA_INFO" ]]; then
    declared="$(extract "$INSOMNIA_INFO" InsomniaAgentCutoffsVersion || true)"
  fi
  if [[ ! -x "$INSOMNIA_BIN" ]]; then
    cutoffs_why="$INSOMNIA_BIN is missing or not executable"
  elif [[ "$declared" != "$AGENT_CUTOFFS_VERSION" ]]; then
    cutoffs_why="$INSOMNIA_INFO declares InsomniaAgentCutoffsVersion '${declared}', not $AGENT_CUTOFFS_VERSION (an older or newer build); the binary was not run"
  else
    read_input="$2"
    run_read cutoffs_answer "$INSOMNIA_BIN" "$1" "$((COMMAND_TIMEOUT_SECONDS + KILL_GRACE_SECONDS))" || cutoffs_rc=$?
    read_input=""
  fi
  return 0
}

# Why the answer ask_app_cutoffs got for mode $1 is not one to use.
cutoffs_failure() { # flag
  if (( cutoffs_rc == 124 )); then
    echo "'$INSOMNIA_BIN $1' did not answer within ${COMMAND_TIMEOUT_SECONDS}s"
  else
    echo "unexpected answer from '$INSOMNIA_BIN $1' (exit $cutoffs_rc, output '$(printf '%s' "$cutoffs_answer" | "$HEAD" -c 200 | "$TR" -c '[:print:]' ' ')')"
  fi
}

# pmset -g batt prints the source ("Now drawing from 'Battery Power'" or 'AC
# Power') and one line per battery ("-InternalBattery-0 (id=...) 26%;
# discharging; 0:41 remaining present: true"). Sets battery_reason and
# returns 0 when the session must end: an internal battery is present, the
# Mac draws from it, and the percentage is below the end floor (cutoff_floor,
# from read_cutoffs; strict, so 0 disables the rule, as in FloorRules.swift,
# and nothing is read then); or
# pmset fails or hangs; or a battery is present but its source or percentage
# cannot be read (fail closed, the app's rule for an unreadable battery). No
# InternalBattery line goes to battery_without_row, which tells a desktop
# (no battery rule) from a laptop missing from the list. A pmset that fails
# cannot tell a desktop from a laptop, so with the floor on it ends.
battery_reason=""
battery_cutoff() {
  local out="" rc=0 floor percent source line
  local source_re="Now drawing from '([^']*)'" percent_re='[[:space:]]([0-9]+)%;'
  battery_reason=""
  floor="$cutoff_floor"
  (( floor > 0 )) || return 1
  run_read out "$PMSET" -g batt || rc=$?
  if (( rc == 124 )); then
    battery_reason="battery state unreadable (pmset -g batt did not finish within ${COMMAND_TIMEOUT_SECONDS}s)"
    return 0
  elif (( rc != 0 )); then
    battery_reason="battery state unreadable (pmset -g batt exit $rc)"
    return 0
  fi
  line="$("$GREP" -m 1 InternalBattery <<< "$out" || true)"
  if [[ -z "$line" ]]; then
    battery_without_row
    return
  fi
  source=""; percent=""
  [[ "$out" =~ $source_re ]] && source="${BASH_REMATCH[1]}"
  [[ "$line" =~ $percent_re ]] && percent="${BASH_REMATCH[1]}"
  if [[ -z "$percent" || ( "$source" != "Battery Power" && "$source" != "AC Power" ) ]]; then
    battery_reason="battery present but unreadable (source '${source:-?}', charge '${percent:-?}')"
    return 0
  fi
  [[ "$source" == "Battery Power" ]] || return 1
  if (( 10#$percent < floor )); then
    battery_reason="battery at ${percent}% on battery power, below the ${floor}% end floor"
    return 0
  fi
  return 1
}

# pmset listed no internal battery. That proves a desktop only when the I/O
# Registry has no AppleSmartBattery service either, which is what the app's
# PowerMonitor.classify checks: a laptop whose power source list lost its
# battery row still has the service. Its level is then unknown, and like
# the app the run ends the session unless the battery driver reports a
# charger (ExternalConnected = Yes). ioreg prints nothing, and exits 0, when
# no service matches. One that fails or hangs cannot prove a desktop, so
# the session ends then too, as for a failing pmset.
battery_without_row() {
  local reg="" rc=0
  run_read reg "$IOREG" -r -c AppleSmartBattery -d 1 || rc=$?
  if (( rc == 124 )); then
    battery_reason="no battery in pmset -g batt, and ioreg did not finish within ${COMMAND_TIMEOUT_SECONDS}s to show there is none"
    return 0
  elif (( rc != 0 )); then
    battery_reason="no battery in pmset -g batt, and ioreg exit $rc could not show there is none"
    return 0
  fi
  "$GREP" -q '^+-o ' <<< "$reg" || return 1
  "$GREP" -q '"ExternalConnected" = Yes' <<< "$reg" && return 1
  battery_reason="battery present (AppleSmartBattery) but missing from pmset -g batt, and no charger reported"
  return 0
}

# notifyutil -g prints "com.apple.system.thermalpressurelevel N" (levels at
# THERMAL_CRITICAL_LEVEL). Sets thermal_reason and returns 0 when the
# session must end. Off when read_cutoffs found thermalRules off. Unreadable
# (failed, hung, or not a level): a warning, never an end on that alone; the
# alive and battery checks stand.
thermal_reason=""
thermal_cutoff() {
  local out="" level
  thermal_reason=""
  [[ "$cutoff_thermal" == true ]] || return 1
  run_read out "$NOTIFYUTIL" -g com.apple.system.thermalpressurelevel || out=""
  level="${out##* }"
  if [[ -z "$out" || ! "$level" =~ ^[0-9]+$ ]]; then
    log warn "thermal pressure level unreadable (notifyutil printed '${out:-nothing}'); not ending the session on that alone"
    return 1
  fi
  if (( 10#$level >= THERMAL_CRITICAL_LEVEL )); then
    thermal_reason="thermal pressure level $level (critical from $THERMAL_CRITICAL_LEVEL up)"
    return 0
  fi
  return 1
}

cutoff=""
if [[ "$session_state" == valid ]] && (( force == 0 )); then
  if (( ended_before == 1 )); then
    cutoff="already ended (recorded in $ended_where) but session.json could not be removed"
  elif ! app_alive; then
    cutoff="Insomnia is not running"
  else
    read_cutoffs
    if battery_cutoff; then
      cutoff="$battery_reason"
    elif thermal_cutoff; then
      cutoff="$thermal_reason"
    else
      exit 0
    fi
  fi
  log warn "ending the session before its deadline (endsAt=$ends_at): $cutoff"
fi

# A valid session this run ends (a cutoff above, or --force) is over from
# here, whatever the undo below achieves, so session.json goes now, under the
# lock. Left in place after a partial undo (saved brightness only the app can
# restore, a failing or hung pmset), it would still read as valid: a
# relaunched Insomnia would resume it and disable sleep again, and an app
# that was stopped or hung would never see the end (it ends its side when
# session.json is gone). What the undo cannot finish stays in state.json,
# which the next run and the app's reconcile complete without a session.
#
# A session.json that cannot be removed is recorded as ended instead, in
# $ENDED, else in the journal, else in a new file beside them or in
# $LOG_DIR, else in the recovery lock file, and the app and every later run
# honour the record until the file is gone. The record is written and read
# back here, before the undo below, so no relaunch finds sleep restored and
# the session still live. If none can be written (neither folder takes a
# new file, and the lock file is not a regular file this user owns or
# refuses the write too, as a full disk does), nothing on disk says the
# session is over: sleep is still restored below, since leaving it disabled
# is worse, but its journal entry stays, so the journal reads dirty,
# uninstall.sh stops, and every run exits 1 until a person makes the file
# removable. The app resumes a session only once it has replaced
# session.json with its own bytes and written the journal itself, so a
# session.json this run could not remove, or a journal it could not write,
# keeps that session from resuming too.

# Remove session.json, then the records of its end, which mean something
# only while the file they copy is there. False when session.json stays.
remove_session() {
  "$RM" -f "$SESSION" 2>/dev/null || return 1
  remove_end_record
  remove_stale_end_records_aside
  remove_stale_lock_record
}

# Record that the session in session.json is over: a copy of its exact bytes
# in $ENDED, written beside it and renamed into place. True only when the
# record reads back identical to the file.
record_end() {
  local tmp="$ENDED.tmp.$$"
  if end_recorded; then return 0; fi
  # The name carries this run's PID, so anything already there was left by
  # an earlier process. It goes unopened: writing through a FIFO blocks.
  "$RM" -f "$tmp" 2>/dev/null || true
  if [[ -f "$SESSION" ]] && "$CAT" "$SESSION" > "$tmp" 2>/dev/null; then "$MV" -f "$tmp" "$ENDED" 2>/dev/null || true; fi
  "$RM" -f "$tmp" 2>/dev/null || true
  end_recorded
}

# Record the same end in the journal: endedSession set to session.json's
# bytes in base64, every other key kept. For a session.json whose end
# cannot be written to $ENDED (an unrelated record there that cannot be
# replaced). Published like the journal at the end of this run: a private
# copy of the journal as the app reads it (check_journal) edited, checked
# (journal_candidate_ok) and renamed over state.json. A journal that is not
# a regular file, or that the app does not load, is left alone; the run
# stops at it below. A missing one, or one with no keys, which plutil reads
# as an old-style plist and will not edit, is written whole. True only when
# the journal then records the end.
record_end_in_journal() {
  local tmp="$APP_SUPPORT/.state.json.backstop.$$" encoded json="" floats=""
  if journal_records_end; then return 0; fi
  encoded="$(session_base64)" || return 1
  [[ -n "$encoded" ]] || return 1
  if [[ -e "$STATE" ]]; then
    check_journal
    [[ "$journal_state" == clean ]] || return 1
    json="$("$PLUTIL" -convert json -o - "$JOURNAL" 2>/dev/null)" || return 1
    floats="$journal_floats"
  fi
  # As in record_end: a leftover at this PID's name goes unopened first.
  "$RM" -f "$tmp" 2>/dev/null || true
  if [[ -z "$json" || "$json" == "{}" ]]; then
    printf '{"endedSession":"%s"}' "$encoded" 2>/dev/null > "$tmp" || { "$RM" -f "$tmp" 2>/dev/null; return 1; }
  elif ! { "$CP" "$JOURNAL" "$tmp" 2>/dev/null \
        && "$PLUTIL" -replace endedSession -string "$encoded" "$tmp" >/dev/null 2>&1; }; then
    "$RM" -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! journal_candidate_ok "$tmp" "$floats" || ! "$MV" -f "$tmp" "$STATE" 2>/dev/null; then
    "$RM" -f "$tmp" 2>/dev/null || true
    return 1
  fi
  journal_checked=0
  journal_records_end
}

# Record the same end in a new file, for when neither $ENDED nor the journal
# can be written (all three files immutable, say): beside $ENDED, or, when
# that folder takes no new file, in $LOG_DIR, which is outside it. mktemp
# creates it 0600 under a name no file had; it is filled from session.json
# and kept only when it reads back identical. A record aside that already
# matches, in either folder, is used again, so a session has at most one.
record_end_aside() {
  local d f
  if end_recorded_aside; then return 0; fi
  [[ -f "$SESSION" ]] || return 1
  "$MKDIR" -p "$LOG_DIR" 2>/dev/null || true
  set_aside_dirs
  for d in "${aside_dirs[@]}"; do
    f="$("$MKTEMP" "$d/ended-session.json.XXXXXXXX" 2>/dev/null)" || continue
    if is_end_record_aside "$f" && "$CAT" "$SESSION" > "$f" 2>/dev/null && "$CMP" -s "$SESSION" "$f"; then
      aside_match="$f"
      return 0
    fi
    [[ -z "$f" ]] || "$RM" -f "$f" 2>/dev/null || true
  done
  return 1
}

# Record the same end in the recovery lock file (see read_lock_record), for
# when $ENDED, the journal and both folders refuse it: the file exists
# already and takes the record in place, keeping its inode. Written only
# while $LOCK is the regular file this run holds the lock on. Content that
# already counts as this end is never emptied: a record already there for
# these bytes is used again, and that record's first bytes
# (lock_holds_record_cut_short) are completed by appending the rest, so a
# run stopped partway leaves more of it, never less. The whole record with
# bytes after it, which only `>` could cut, and a file that cannot be read
# are left as they are; both count as the end for every reader, and the
# run goes on to the log. Anything else ends nothing for this session and
# is written over with `>`, which empties the file before it writes: a run
# stopped in between leaves an empty file or the record's first bytes,
# where the file held nothing that ended this session either. True only
# when the file then reads back as exactly that record.
record_end_in_lock() {
  local encoded whole
  encoded="$(session_base64)" || return 1
  [[ -n "$encoded" ]] || return 1
  whole="$LOCK_RECORD_TAG $encoded"$'\n'
  read_lock_record
  if [[ "$lock_record_state" == record && "$lock_record" == "$encoded" ]]; then return 0; fi
  [[ "$lock_record_state" != unreadable ]] || return 1
  (( ${#whole} <= LOCK_RECORD_MAX_BYTES )) || return 1
  lock_is_held_file || return 1
  if lock_holds_record_cut_short "$encoded"; then
    (( ${#lock_content} < ${#whole} )) || return 1
    { printf '%s' "${whole:${#lock_content}}" >> "$LOCK"; } 2>/dev/null || true
  else
    { printf '%s' "$whole" > "$LOCK"; } 2>/dev/null || true
  fi
  lock_is_held_file || return 1
  read_lock_record
  [[ "$lock_record_state" == record && "$lock_record" == "$encoded" ]]
}

# Record the same end as one line appended to insomnia.log (see
# end_recorded_in_log), for when $ENDED, the journal, both folders and the
# lock file refuse it. This run holds the recovery lock (fd 9), and the app
# rotates the log only under that lock, so the file cannot be renamed
# between the write and the read-back. Written only while $LOG is a regular
# file, not a symlink, owned by this user, through a descriptor opened for
# appending, read back through another opened for reading, both checked to
# be on the file $LOG names (device and inode) before the write and after
# the read. The descriptor written through holds the log's lock (see log)
# from before those checks until the read-back is done, waiting at most
# LOG_LOCK_TIMEOUT_SECONDS for it; a lock not taken records nothing here. A
# log that ends in a line cut short gets a newline first, in the same write
# (ends_mid_line), so the record is a line of its own. A record already in
# either log for these bytes is used again.
# True only when the read-back finds the whole line, and end_recorded_in_log
# then finds it too.
record_end_in_log() {
  local line first="" rc=1
  if end_recorded_in_log; then return 0; fi
  line="$(log_record_line)" || return 1
  [[ -f "$LOG" && ! -L "$LOG" && -O "$LOG" ]] || return 1
  # shellcheck disable=SC2094  # the log is appended to on 8 and read back on 7, on purpose
  {
    if "$LOCKF" -s -t "$LOG_LOCK_TIMEOUT_SECONDS" 8 \
        && [[ -n "$(fd_devino 8)" && "$(fd_devino 8)" == "$(fd_devino 7)" \
          && "$(fd_devino 8)" == "$(devino "$LOG")" && -f "$LOG" && ! -L "$LOG" && -O "$LOG" ]] \
        && { ! ends_mid_line "$LOG" || first=$'\n'; } \
        && { printf '%s%s\n' "$first" "$line" >&8; } 2>/dev/null \
        && "$GREP" -Fxq -e "$line" <&7 2>/dev/null \
        && [[ "$(fd_devino 7)" == "$(devino "$LOG")" ]]; then
      rc=0
    fi
  } 2>/dev/null 8>>"$LOG" 7<"$LOG" || return 1
  # And as every reader finds it, by path (a log past LOG_SCAN_MAX_BYTES is
  # not searched).
  (( rc == 0 )) && end_recorded_in_log
}

# The journal is checked first: a valid session is not ended, its file not
# removed and its end not recorded, while the journal does not load as the
# app loads it (refuse_malformed_journal).
if [[ "$session_state" == valid ]]; then
  check_journal
  [[ "$journal_state" != malformed ]] || refuse_malformed_journal "it is not ended"
fi
session_left=0      # 1 when the valid session this run ends is still on disk
keep_sleep_entry=0  # 1 when nothing on disk records that end
if [[ "$session_state" == valid ]] && ! remove_session; then
  session_left=1
  if record_end; then
    log error "could not remove $SESSION; its end is recorded in $ENDED, so Insomnia restores the session instead of resuming it. Every run retries the removal"
  elif record_end_in_journal; then
    log error "could not remove $SESSION or record its end in $ENDED; its end is recorded in $STATE (endedSession) instead, so Insomnia restores the session instead of resuming it. Every run retries the removal"
  elif record_end_aside; then
    log error "could not remove $SESSION or record its end in $ENDED or $STATE; its end is recorded in $aside_match instead, so Insomnia restores the session instead of resuming it. Every run retries the removal"
  elif record_end_in_lock; then
    log error "could not remove $SESSION or record its end in $ENDED, $STATE or a new file in $APP_SUPPORT or $LOG_DIR; its end is recorded in the recovery lock file $LOCK instead, so Insomnia restores the session instead of resuming it. Every run retries the removal"
  elif record_end_in_log; then
    log error "could not remove $SESSION or record its end in $ENDED, $STATE, a new file in $APP_SUPPORT or $LOG_DIR, or the recovery lock file $LOCK; its end is recorded in the log file $LOG instead, so Insomnia restores the session instead of resuming it. Every run retries the removal"
  else
    keep_sleep_entry=1
    log error "could not remove $SESSION or record its end in $ENDED, $STATE, a new file in $APP_SUPPORT or $LOG_DIR, the recovery lock file $LOCK, or the log file $LOG. Sleep is restored anyway, but sleepDisabledByUs stays journaled and every run exits 1 until the file can be removed (ls -lO shows its flags); Insomnia resumes no session while it cannot replace $SESSION or write $STATE, and none whose journaled sleep hold pmset no longer reports"
  fi
fi

# --- Read the journal --------------------------------------------------------
# journal_state: missing | malformed | clean | dirty
check_journal
[[ "$journal_state" != malformed ]] || refuse_malformed_journal

sleep_held=false; low_power=false; docker_frozen=false; has_audio=0
has_display=0; has_keyboard=0; refused_display=0; refused_keyboard=0
frozen_count=0; legacy_count=0; app_nap_count=0; output_count=0
if [[ "$journal_state" == clean ]]; then
  is_true "$JOURNAL" sleepDisabledByUs && sleep_held=true
  is_true "$JOURNAL" lowPowerSetByUs && low_power=true
  is_true "$JOURNAL" dockerFrozen && docker_frozen=true
  extract "$JOURNAL" savedOutputVolume >/dev/null && has_audio=1
  extract "$JOURNAL" savedMuted >/dev/null && has_audio=1
  if extract "$JOURNAL" savedDisplayBrightness >/dev/null; then
    if is_true "$JOURNAL" displayRestoreRefused; then refused_display=1; else has_display=1; fi
  fi
  if extract "$JOURNAL" savedKeyboardBrightness >/dev/null; then
    if is_true "$JOURNAL" keyboardRestoreRefused; then refused_keyboard=1; else has_keyboard=1; fi
  fi
  while extract_json "$JOURNAL" "frozenProcesses.$frozen_count" >/dev/null; do
    frozen_count=$((frozen_count + 1))
  done
  while extract "$JOURNAL" "frozenPids.$legacy_count" >/dev/null; do
    legacy_count=$((legacy_count + 1))
  done
  while extract_json "$JOURNAL" "appNapOverrides.$app_nap_count" >/dev/null; do
    app_nap_count=$((app_nap_count + 1))
  done
  # Kept for the app and not counted as dirty; see the header.
  while extract_json "$JOURNAL" "savedAudioOutputs.$output_count" >/dev/null; do
    output_count=$((output_count + 1))
  done
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
  local base dest n line what
  while IFS= read -r line; do
    [[ -n "$line" ]] && log warn "$SESSION: $line"
  done <<< "$session_problems"
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
  valid)      if [[ -n "$cutoff" ]]; then
                session_note="session ended early, $cutoff (endsAt=$ends_at)"
              else
                session_note="forced end of session (endsAt=$ends_at)"
              fi ;;
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
    quarantine_session || exit 1
    exit 0
  fi
  if [[ "$session_state" != none ]]; then
    if [[ "$journal_state" == missing ]]; then
      log warn "$session_note; no journal on disk, nothing recorded to undo"
    else
      log info "$session_note; journal already clean"
    fi
    [[ -n "$refused_note" ]] && log info "$refused_note"
    # A valid session was removed (or recorded as ended) above.
    if [[ "$session_state" == valid ]]; then exit "$session_left"; fi
    if ! remove_session; then
      log error "could not remove $SESSION; will retry on the next run"
      exit 1
    fi
  fi
  exit 0
fi

# --- Undo --------------------------------------------------------------------
log info "$session_note; restoring from journal"

failures=()   # what is still journaled after this run
changed=0     # whether the journal needs republishing

new_sleep="$sleep_held"
if [[ "$sleep_held" == true ]]; then
  if run_bounded "$SUDO" -n "$PMSET" -a disablesleep 0; then
    log info "pmset -a disablesleep 0 ok"
    if (( keep_sleep_entry == 1 )); then
      failures+=("sleepDisabledByUs is kept although sleep is restored: $SESSION could not be removed and its end could not be recorded")
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
# null one, gets none.
prepare_low_power_off() {
  local t boot recorded tmp ok=1
  t="$(type_of "$JOURNAL" keptDisplayUnderLowPower)"
  [[ "$t" == float || "$t" == integer ]] || return 0
  boot="$("$SYSCTL" -n kern.bootsessionuuid 2>/dev/null || true)"
  # A boot that holds U+E000 would be written back as \u0000 with the
  # view's (journal_candidate_ok).
  if (( journal_marks == 1 )) && [[ "$boot" == *$'\xee\x80\x80'* ]]; then return 1; fi
  recorded="$(extract "$JOURNAL" keptDisplayUnderLowPowerBoot || true)"
  [[ "$recorded" == "$boot" ]] && return 0
  tmp="$APP_SUPPORT/.state.json.backstop-boot.$$"
  "$CP" "$JOURNAL" "$tmp" || ok=0
  if (( ok == 1 )); then
    "$PLUTIL" -replace keptDisplayUnderLowPowerBoot -string "$boot" "$tmp" >/dev/null 2>&1 || ok=0
  fi
  if (( ok == 1 )); then
    journal_candidate_ok "$tmp" "$journal_floats" || ok=0
  fi
  if (( ok == 1 )); then
    "$MV" -f "$tmp" "$STATE" || ok=0
  fi
  if (( ok == 0 )); then
    "$RM" -f "$tmp"
    return 1
  fi
  # state.json now holds the journal with this boot and the same Floats
  # (journal_candidate_ok); every read below uses it as the app reads it,
  # read again (check_journal), since plutil writes some of what the app
  # reads in a way it would itself read otherwise, such as -0.
  journal_checked=0
  check_journal
  [[ "$journal_state" == clean ]] || return 1
  log info "kept display entry's record given this boot (${boot:-unreadable, written empty}) before Low Power Mode is switched off"
}

new_low="$low_power"
if [[ "$low_power" == true ]]; then
  if ! prepare_low_power_off; then
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
  local w mon day time year stat uid rest
  read -r w mon day time year stat uid rest <<< "$out"
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
  local n=${#app_pid[@]} k rc=0 valid=1 settled=1 expected=0 size line word excerpt="" p answer declared
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
  # A regular file only: a FIFO there could block this run under the lock.
  declared=""
  if [[ -f "$INSOMNIA_INFO" ]]; then
    declared="$(extract "$INSOMNIA_INFO" InsomniaResumeFrozenVersion || true)"
  fi
  if [[ "$declared" != "$RESUME_FROZEN_VERSION" ]]; then
    for (( k = 0; k < n; k++ )); do
      log error "pid ${app_pid[k]} needs the app binary for its microsecond identity check, but $INSOMNIA_INFO declares InsomniaResumeFrozenVersion '${declared}', not $RESUME_FROZEN_VERSION (an older or newer build); the binary was not run; kept, not signaled"
      failures+=("pid ${app_pid[k]} was not resumed: the installed app does not declare --resume-frozen version $RESUME_FROZEN_VERSION")
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
    size="$("$STAT" -f %z "$answer" 2>/dev/null || echo 0)"
    excerpt="$("$HEAD" -c 200 "$answer" | "$TR" -c '[:print:]' ' ')"
    # A valid line is at most 24 bytes ("<10-digit pid> unverifiable\n").
    if (( size > n * 32 )); then
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
  boot_now="$("$SYSCTL" -n kern.bootsessionuuid 2>/dev/null || true)"
  # The view writes a bootSession that holds \u0000 with U+E000 for it
  # (journal_marks); a boot that holds U+E000 could match it here where it
  # does not in the app, so it counts as unread.
  if (( journal_marks == 1 )) && [[ "$boot_now" == *$'\xee\x80\x80'* ]]; then boot_now=""; fi
  uid_now="$("$ID" -u)"
  i=0
  while (( i < frozen_count )); do
    pid="$(extract_whole "$JOURNAL" "frozenProcesses.$i.pid" || true)"
    started="$(extract_whole "$JOURNAL" "frozenProcesses.$i.startedAt" || true)"
    micros="$(extract_whole "$JOURNAL" "frozenProcesses.$i.startedAtMicros" || true)"
    boot="$(extract "$JOURNAL" "frozenProcesses.$i.bootSession" || true)"
    if ! is_positive_int "$pid"; then
      log error "frozen entry $i has no valid pid (${pid:-?}); kept, not signaled"
      failures+=("frozen entry $i has an invalid pid")
      keep_entry "$i"
    elif [[ -z "$started" || -z "$boot" ]] ||
      { [[ -z "$micros" ]] && [[ "$(type_of "$JOURNAL" "frozenProcesses.$i.bootSession")" != string ]]; }; then
      # No startedAt (a provisional entry), or no bootSession, or, in an
      # entry without startedAtMicros (an older build's), a bootSession
      # that is no string, which the app does not read there.
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
      # second that fits in 64 and microseconds below one million; anything
      # else would make it reject the whole call, so such an entry is kept
      # here instead.
      # shellcheck disable=SC2071  # 19 digits compared as text: the limit overflows $(( ))
      if [[ "$micros" =~ ^[0-9]{1,6}$ && "$started" =~ ^[0-9]{1,19}$ ]] && ! [[ ${#started} == 19 && "$started" > 9223372036854775807 ]] &&
        (( ${#pid} <= 10 && 10#$pid <= 2147483647 )); then
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
  if ! entry="$(extract_json "$JOURNAL" "frozenProcesses.$i")" || [[ -z "$entry" ]]; then
    log error "could not read frozen entry $i back from $STATE; previous journal kept, will retry"
    exit 1
  fi
  if [[ -n "$kept_frozen" ]]; then kept_frozen="$kept_frozen,$entry"; else kept_frozen="$entry"; fi
  kept_frozen_count=$((kept_frozen_count + 1))
done

if (( legacy_count > 0 )); then
  legacy_json="$(extract_json "$JOURNAL" frozenPids || true)"
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
  entry="$(extract_json "$JOURNAL" "appNapOverrides.$1")"
  if [[ -n "$kept_app_nap" ]]; then kept_app_nap="$kept_app_nap,$entry"; else kept_app_nap="$entry"; fi
  kept_app_nap_count=$((kept_app_nap_count + 1))
}
if (( app_nap_count > 0 )); then
  i=0
  while (( i < app_nap_count )); do
    bundle="$(extract "$JOURNAL" "appNapOverrides.$i.bundleId" || true)"
    previous="$(extract "$JOURNAL" "appNapOverrides.$i.previous" || true)"
    if [[ -z "$bundle" || "$bundle" == -* ]]; then
      log error "App Nap entry $i has no usable bundle id (${bundle:-?}); kept, nothing written"
      failures+=("App Nap entry $i has no usable bundle id")
      keep_app_nap_entry "$i"
    elif (( journal_marks == 1 )) && [[ "$bundle" == *$'\xee\x80\x80'* ]]; then
      # The view writes \u0000 as U+E000 (json_nul_mark): the app's bundle
      # id holds \u0000, which no command here can name.
      log error "App Nap entry $i has a bundle id that holds \\u0000; kept, nothing written"
      failures+=("App Nap entry $i has a bundle id that holds \\u0000")
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
# Edit a private copy, verify it, then rename it over state.json so readers
# only ever see a complete journal. The copy is of the journal as the app
# reads it (check_journal): state.json itself, whose keys we do not own
# survive untouched, or the view, which keeps what the app's own save keeps.
# plutil writes a Float the app reads as -0.0 as -0, which plutil itself
# reads back as the whole number 0, so a second edit would write it as 0,
# which the app reads as 0.0. Every other Float it writes it reads back as
# the same. A copy of a journal that holds a -0.0 (journal_floats, bit
# pattern 2147483648) is therefore written again as the app reads it, the
# view record_text_problems writes, which has -0.0, before each edit after
# the first.
publish_edits=0
publish_edit() { # plutil edit arguments, before the file
  local line view="$JOURNAL_VIEW.candidate"
  (( publish_ok == 1 )) || return 0
  if (( publish_edits > 0 )) && [[ $'\n'"$journal_floats" == *" 2147483648"$'\n'* ]]; then
    "$RM" -f "$view" 2>/dev/null || true
    while IFS= read -r line; do
      case "$line" in
        ""|"view: "*|"record: "*|"float: "*) ;;
        *) publish_ok=0 ;;
      esac
    done < <(record_text_problems "$tmp" state "$view" floats)
    if (( publish_ok == 0 )) || [[ ! -f "$view" ]] || ! "$MV" -f "$view" "$tmp" 2>/dev/null; then
      publish_ok=0
      "$RM" -f "$view" 2>/dev/null || true
      return 0
    fi
  fi
  "$PLUTIL" "$@" "$tmp" >/dev/null 2>&1 || publish_ok=0
  publish_edits=$((publish_edits + 1))
}
if (( changed == 1 )); then
  tmp="$APP_SUPPORT/.state.json.backstop.$$"
  publish_ok=1
  # As in record_end: a leftover at this PID's name goes unopened first.
  "$RM" -f "$tmp" 2>/dev/null || true
  "$CP" "$JOURNAL" "$tmp" || publish_ok=0
  [[ "$new_sleep" == "$sleep_held" ]] || publish_edit -replace sleepDisabledByUs -bool "$new_sleep"
  [[ "$new_low" == "$low_power" ]] || publish_edit -replace lowPowerSetByUs -bool "$new_low"
  [[ "$new_docker" == "$docker_frozen" ]] || publish_edit -replace dockerFrozen -bool "$new_docker"
  (( frozen_count == 0 )) || publish_edit -replace frozenProcesses -json "[$kept_frozen]"
  (( app_nap_count == 0 )) || publish_edit -replace appNapOverrides -json "[$kept_app_nap]"
  if (( publish_ok == 1 )); then
    # plutil keeps JSON files as JSON; make sure the result is still one,
    # and one the app loads as plutil reads it.
    journal_candidate_ok "$tmp" "$journal_floats" || publish_ok=0
  fi
  if (( publish_ok == 1 )); then
    "$MV" -f "$tmp" "$STATE" || publish_ok=0
  fi
  if (( publish_ok == 0 )); then
    "$RM" -f "$tmp"
    log error "could not publish the updated journal to $STATE; previous journal kept, will retry"
    exit 1
  fi
fi

# --- Report ------------------------------------------------------------------
if (( ${#failures[@]} > 0 )); then
  for f in "${failures[@]}"; do log error "still journaled: $f"; done
  log error "journal kept dirty (${#failures[@]} item(s)); will retry on the next run"
  exit 1
fi

# A valid session was removed (or recorded as ended) above.
if [[ "$session_state" == valid ]] && (( session_left == 1 )); then
  log error "journal cleared, but $SESSION could not be removed; will retry on the next run"
  exit 1
fi
if (( output_count > 0 )); then
  log info "journal cleared apart from $outputs_note"
else
  log info "journal cleared"
fi
case "$session_state" in
  malformed|unreadable) quarantine_session || exit 1 ;;
  valid)                ;;
  *)
    if ! remove_session; then
      log error "journal cleared, but could not remove $SESSION; will retry on the next run"
      exit 1
    fi ;;
esac
exit 0
