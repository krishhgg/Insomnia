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
#   - session.json valid (endsAt in the future) and no --force: exit 0.
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
#                              (InsomniaResumeFrozenVersion), read before
#                              the lock (see "Version evidence"), and it keeps
#                              the lock on fd 9 until it exits, which it does
#                              by itself after <seconds>. When the binary is
#                              missing, does not declare that version, cannot
#                              run, times out, or answers anything but one
#                              documented line per entry, or when the version
#                              is unknown, those entries are kept and not
#                              signaled. An entry
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
#     wrong type: nothing is touched, exit 1. A read of the journal's copy
#     that fails or does not answer in time (see "Reads") stops the run the
#     same way, at whatever point it happens: what was undone before it
#     stays undone and its flag stays set, so the next run sees it again.
#   - session.json present but not a session: readable, but not the shape
#     the app's Session decoder accepts (session_shape_problems). It is
#     treated as expired. Once the journal is clean (already, or after the
#     undo above succeeded) the file is renamed to
#     session.json.unreadable-<UTC stamp>, never deleted or overwritten, so
#     the next run sees no session. While the journal stays dirty it stays.
#   - session.json present but not readable at all (permissions, I/O, no
#     answer within READ_TIMEOUT_SECONDS, or no room for the private copy),
#     or not a regular file (a FIFO or device is never opened: open(2) could
#     block while this run holds the lock): its end time is unknown, and
#     sleep is never held without a deadline that can be enforced, so it is
#     treated as expired and the journal is undone as above. The file is
#     never opened, read or removed: it may have been a valid session. Once
#     the journal is clean it is renamed aside like a malformed one, so its
#     bytes stay as evidence and no later run, of this script or the app,
#     can read it back as a session that was already treated as ended. A
#     state.json that is not a regular file is malformed.
#
# Reads: every read of a file (plutil, cp, cat, stat) and every ps call
# runs as a child with fd 9 closed and its output in a private directory
# made with mktemp in TMPDIR, and has READ_TIMEOUT_SECONDS to answer. A
# child still running then gets SIGTERM, then SIGKILL; none of them is
# privileged. Each status is checked, never left to set -e, which is off in
# command substitutions and on the left of || and &&. sysctl and date read
# only the kernel and run directly; defaults read runs like the undo
# commands (run_bounded). The journal and session.json are copied once (cp
# -X onto a file this run created, so the copy is readable even when the
# original is readable only through an ACL), and every later read is of the
# copy. The journal published at the end is built from that copy. A run
# killed with SIGKILL leaves its private directory behind in TMPDIR. Not
# bounded here: the stat of fd 9 and of the lock file that decides whether
# to share a caller's lock (a child with fd 9 closed cannot stat fd 9).
# install.sh and uninstall.sh bound the whole run instead (run_backstop).
#
# Version evidence: the run reads InsomniaResumeFrozenVersion and the
# identity of INSOMNIA_INFO (device, inode, change time, size) before it
# takes the lock, and checks the identity again under the lock just before
# the binary would run. A caller that already holds the lock and passes it
# down as fd 9 (install.sh, uninstall.sh) did the first read itself, before
# it took the lock, and passes the result in INSOMNIA_INFO_PATH,
# INSOMNIA_INFO_EVIDENCE and INSOMNIA_INFO_VERSION. Missing, changed or
# unreadable evidence makes the version unknown, and entries that need the
# binary are kept.
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
CHMOD=/bin/chmod
DEFAULTS=/usr/bin/defaults
DATE=/bin/date
MKDIR=/bin/mkdir
RM=/bin/rm
MV=/bin/mv
CP=/bin/cp
MKTEMP=/usr/bin/mktemp
CAT=/bin/cat
# The most bytes work_read takes from one file (a call's output, status or
# pid, a note): a longer file reads as not read back.
READ_MAX_BYTES=1048576
STAT=/usr/bin/stat
# The installed app binary, for the microsecond identity check of
# frozenProcesses entries (see above), and the bundle's Info.plist, which
# must declare InsomniaResumeFrozenVersion RESUME_FROZEN_VERSION before the
# binary is run: an older build has no such mode and would open the menu bar
# app instead. Fixed paths like the tools, never PATH. install.sh puts the
# bundle here, copying the binary before Info.plist.
INSOMNIA_BIN="${HOME:-}/Applications/Insomnia.app/Contents/MacOS/Insomnia"
INSOMNIA_INFO="${HOME:-}/Applications/Insomnia.app/Contents/Info.plist"
RESUME_FROZEN_VERSION=1
LOCK_TIMEOUT_SECONDS=10
# Longest a single undo command (sudo pmset, defaults) may run before it is
# sent SIGTERM, and how long it then gets to exit before this run fails closed.
COMMAND_TIMEOUT_SECONDS=30
KILL_GRACE_SECONDS=3
# Longest a single read (plutil, cat, cp, stat, ps) may run before it is
# stopped and counts as failed; see bounded.
READ_TIMEOUT_SECONDS=30

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
STATE="$APP_SUPPORT/state.json"
LOCK="$APP_SUPPORT/.recovery.lock"
LOG="$LOG_DIR/insomnia.log"

# A log path that is not a regular file is not opened: an append to a FIFO
# with no reader would block, and this run may hold the recovery lock.
log() { # level message
  "$MKDIR" -p "$LOG_DIR"
  [[ ! -e "$LOG" || -f "$LOG" ]] || return 0
  printf '%s [%s] backstop: %s\n' "$("$DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"
}

# --- Reads -------------------------------------------------------------------
# Every read made under the recovery lock is a bounded call (below), so a
# FIFO put where a file was, a stalled disk or a tool that hangs cannot keep
# the lock waiting, and every read has an explicit result. session.json and
# state.json are read once each, by a bounded cp into WORK, and every check
# reads that private copy. The app's Info.plist is not read under the lock
# (see read_info_version).

# Whether pid $1 is a running job of this shell, by bash's own job list.
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
# Sends signal $1 to the current job (%+), but only while that job is pid
# $2; see run_app_bounded.
signal_job() { # signal pid
  [[ "$(jobs -p %+)" == "$2" ]] || return 1
  kill -"$1" %+
}

# Run one read (plutil, cat, cp, stat or ps) with a time limit. Its
# combined output goes to a new file in WORK, read back once the read has
# ended with work_read: into READ_TEXT and READ_HEAD, with work_read's
# status in BOUNDED_READ (2, not read back, also when the read did not end
# in time or could not start). Its exit status is returned; 124 when it did
# not finish within
# READ_TIMEOUT_SECONDS (on bash's SECONDS clock, so up to a second more), or
# 126 when no file for its output could be made. The read is a background
# job of this shell started without fd 9: a read needs no lock, and one left
# behind keeps none. It reads and changes nothing that matters, so unlike an
# undo command it has no supervisor: past the limit this shell sends it
# SIGTERM and, KILL_GRACE_SECONDS later, SIGKILL, both by jobspec (see
# run_app_bounded); a read still in the kernel KILL_GRACE_SECONDS after that
# is left behind. Most reads end within a few milliseconds, sooner than one
# sleep (a fork) takes, so the first checks are up to 400 kill -0 calls in a
# row, a few milliseconds in all, before the first sleep. The output file's
# name comes from a counter, and noclobber makes sure the file is new: in a
# $(...) subshell the counter starts again from the parent's value. The
# function's stderr is /dev/null, since bash reports a job a signal ended
# on its own stderr.
BOUNDED_READ=2
bounded_reads=0
bounded() { # command args...
  local out cpid rc=0 spins=0 polls=0 deadline
  BOUNDED_READ=2
  READ_TEXT=""
  READ_HEAD=""
  while :; do
    bounded_reads=$((bounded_reads + 1))
    out="$WORK/call.$bounded_reads.out"
    [[ -e "$out" || -L "$out" ]] && continue
    set -C
    if { : > "$out"; } 2>/dev/null; then set +C; break; fi
    set +C
    return 126
  done
  deadline=$(( SECONDS + READ_TIMEOUT_SECONDS ))
  "$@" </dev/null >"$out" 2>&1 9>&- &
  cpid=$!
  while (( spins < 400 )) && kill -0 "$cpid" 2>/dev/null; do
    spins=$((spins + 1))
  done
  while kill -0 "$cpid" 2>/dev/null && (( SECONDS <= deadline )); do
    if (( polls < 50 )); then sleep 0.002; else sleep 0.05; fi
    polls=$((polls + 1))
  done
  if job_running "$cpid"; then
    signal_job TERM "$cpid" || true
    if ! wait_for_job "$cpid" "$KILL_GRACE_SECONDS"; then
      signal_job KILL "$cpid" || true
      wait_for_job "$cpid" "$KILL_GRACE_SECONDS" || return 124
    fi
    wait "$cpid" || true
    return 124
  fi
  wait "$cpid" || rc=$?
  BOUNDED_READ=0
  work_read "$out" || BOUNDED_READ=$?
  return "$rc"
} 2>/dev/null
# How a bounded read's exit status reads in a message.
call_result() { # status
  case "$1" in
    124) printf 'did not answer within %ss' "$READ_TIMEOUT_SECONDS" ;;
    126) printf 'could not be started (no file for its output)' ;;
    *) printf 'exited %s' "$1" ;;
  esac
}

# Reads under the lock, from here on, each have an explicit result, as in
# uninstall.sh: 0 with the value; 1 when plutil said in so many words that
# the key path holds no value or only null (or, for -convert, that the file
# does not parse); 2 when it failed any other way, did not answer in time,
# or its output could not be read back whole. A 2 is noted in
# READ_FAILURES, and every caller passes it on, so a check that made the
# read returns 2 and the run treats that as a read that did not complete:
# never as a clean journal or an absent value. Once a read has failed, the
# rest return 2 at once: they would most likely wait the same way. The
# notes go to a file because most reads run inside $(...). The text from
# work_read to snapshot is the same as in uninstall.sh (a test keeps the
# two in step).
# Reads a file this run made (a call's output, status or pid, a note, or
# the app binary's answer) into READ_TEXT byte for byte, without $(...),
# which drops NUL bytes and trailing newlines. Only bash itself opens and
# reads it, through one descriptor, so no program that hangs can hold the
# read. The open is read-write: a read-only open of a FIFO waits for a
# writer, and this one does not. The open descriptor must be a regular file,
# at most READ_MAX_BYTES are taken from it, so a file that keeps growing
# cannot hold the read either, and after the read the name must still lead
# to that file (the same inode), so a file swapped in meanwhile is not taken
# for it. The name is checked first, so the open creates nothing unless the
# file goes in between, which only this account could make happen: the
# folder is this run's own (mktemp -d, mode 0700) or the app's.
# Returns 0 when all of it was read; 1 when it has a NUL byte, which no shell
# variable can hold (READ_TEXT is then the text without them and trailing
# newlines, and READ_HEAD the text before the first); 2 when it is not a
# regular file, is longer than READ_MAX_BYTES, could not be opened or read
# (bash leaves the variable of a read that failed unset, and sets it at the
# end of the file), or was swapped. READ_HEAD is READ_TEXT otherwise.
work_read() { # file -> READ_TEXT, READ_HEAD
  local LC_ALL=C part text="" head="" nul=0 left=$(( READ_MAX_BYTES + 1 ))
  READ_TEXT=""
  READ_HEAD=""
  [[ -f "$1" && ! -L "$1" ]] || return 2
  {
    [[ -f /dev/fd/3 ]] || return 2
    while :; do
      unset -v part
      if IFS= read -r -d '' -n "$left" -u 3 part; then
        # A NUL byte ended this part, unless it took all that was left.
        (( ${#part} < left )) || return 2
        (( nul )) || head="$part"
        nul=1
        text="$text$part"
        left=$(( left - ${#part} - 1 ))
        (( left > 0 )) || return 2
      else
        [[ -n "${part+set}" ]] || return 2
        text="$text$part"
        break
      fi
    done
    [[ -f "$1" && ! -L "$1" ]] || return 2
    { [[ /dev/fd/3 -ef /dev/fd/4 ]]; } 4<>"$1" || return 2
  } 2>/dev/null 3<>"$1" || return 2
  if (( nul )); then
    READ_HEAD="$head"
    READ_TEXT="${text%"${text##*[!$'\n']}"}"
    return 1
  fi
  READ_TEXT="$text"
  READ_HEAD="$text"
  return 0
}
# The non-empty lines of $1 in TEXT_LINES, split in the shell itself: no
# here-string, whose temporary file can fail to be written.
TEXT_LINES=()
text_lines() { # text
  local rest="$1" line
  TEXT_LINES=()
  while [[ -n "$rest" ]]; do
    line="${rest%%$'\n'*}"
    if [[ "$rest" == *$'\n'* ]]; then rest="${rest#*$'\n'}"; else rest=""; fi
    [[ -z "$line" ]] || TEXT_LINES+=("$line")
  done
  return 0
}
plutil_read() { # plutil arguments... file -> its output; 0, 1 or 2 (see above)
  local rc=0 file="${!#}" why
  [[ ! -s "$READ_FAILURES" ]] || return 2
  bounded "$PLUTIL" "$@" || rc=$?
  if (( rc == 0 )); then
    rc=$BOUNDED_READ
    case "$rc" in
      0) printf '%s' "$READ_TEXT" || return 2; return 0 ;;
      1) why="printed a NUL byte, which this script cannot pass on" ;;
      *) why="exited 0, but its output could not be read back" ;;
    esac
  elif (( rc == 1 )) && plutil_said_none "$@"; then
    return 1
  elif (( rc == 1 )); then
    why="exited 1 ($PLUTIL_SAID)"
  else
    why="$(call_result "$rc")"
  fi
  echo "'plutil $1 $2' on ${file##*/} $why" >> "$READ_FAILURES"
  return 2
}
# Whether the exit 1 of the plutil call just made with these arguments says
# no more than that there is no value: for -extract and -type, plutil's
# exact words for a key path that holds none, or for a null read as raw; a
# null read as JSON is confirmed with -type, which shows it as "(any)". For
# -convert, any exit 1. Anything else, such as a file plutil could not open,
# is a failed read, and plutil's words are left in PLUTIL_SAID.
PLUTIL_SAID=""
plutil_said_none() { # the plutil arguments of the call just made
  local file="${!#}" said rc=0
  PLUTIL_SAID="its message could not be read back"
  [[ "$1" != -convert ]] || return 0
  (( BOUNDED_READ == 0 )) || return 1
  said="${READ_TEXT%$'\n'}"
  said="${said#"$file: "}"
  PLUTIL_SAID="$said"
  [[ "$1" == -extract || "$1" == -type ]] || return 1
  [[ "$said" != "Could not extract value, error: No value at that key path or invalid key path: $2" ]] || return 0
  [[ "$1 $3" != "-extract raw" || "$said" != "Value at $2 is a any type and cannot be extracted in raw format" ]] || return 0
  [[ "$1 $3" == "-extract json" ]] || return 1
  bounded "$PLUTIL" -type "$2" -o - "$file" || rc=$?
  (( rc == 0 && BOUNDED_READ == 0 )) || return 1
  [[ "$READ_TEXT" == "(any)"$'\n' ]]
}
extract() { # file keypath -> the value as plutil prints it raw; 0, 1 or 2
  plutil_read -extract "$2" raw -o - "$1"
}
# The type at a key path (bool, integer, float, string, array, dictionary,
# "(any)" for null), or nothing when there is no value; 2 when the read failed.
type_of() { # file keypath
  local rc=0
  plutil_read -type "$2" -o - "$1" || rc=$?
  (( rc != 2 )) || return 2
  return 0
}
# The value at a key path in VALUE, as plutil prints it raw or as JSON ($3),
# with extract's status, without a subshell for the status.
VALUE=""
value_at() { # file keypath [raw|json]
  local rc=0
  VALUE="$(plutil_read -extract "$2" "${3:-raw}" -o - "$1")" || rc=$?
  return "$rc"
}
# Reads file $1 whole into WHOLE_TEXT (and WHOLE_HEAD, see work_read) with
# one bounded cat, so a FIFO or a stalled disk cannot keep the lock waiting:
# 0, 1 when it has a NUL byte, or 2 when the read failed or did not answer
# (noted in READ_FAILURES).
read_whole() { # file -> WHOLE_TEXT, WHOLE_HEAD
  local rc=0 why
  WHOLE_TEXT=""
  WHOLE_HEAD=""
  [[ ! -s "$READ_FAILURES" ]] || return 2
  bounded "$CAT" "$1" || rc=$?
  if (( rc == 0 )); then
    rc=$BOUNDED_READ
    WHOLE_TEXT="$READ_TEXT"
    WHOLE_HEAD="$READ_HEAD"
    (( rc == 2 )) || return "$rc"
    why="exited 0, but its output could not be read back"
  else
    why="$(call_result "$rc")"
  fi
  echo "'cat' on ${1##*/} $why" >> "$READ_FAILURES"
  return 2
}
# Copies the regular file $1 to $2, in WORK, with one bounded cp, so the
# checks read a private copy that cannot block or change under them. This
# shell makes the copy first, empty, so it has this run's mode, which lets
# its owner read it; cp writes into it and keeps that mode. cp -X copies no
# extended attributes or ACL: a journal its owner can read only through an
# ACL entry (mode 0200, say) would otherwise make cp fail or leave a copy
# its mode keeps unreadable. Returns cp's status, 124 when it did not answer
# in time, or 1 when the empty copy could not be made.
snapshot() { # file copy
  local rc=0
  "$RM" -f "$2"
  { : > "$2"; } 2>/dev/null || return 1
  bounded "$CP" -X "$1" "$2" || rc=$?
  return "$rc"
}

# The first note in READ_FAILURES, or why there is none, in READ_WHY.
READ_WHY=""
first_read_failure() { # status of the check that stopped
  READ_WHY="the check stopped with status $1"
  [[ -e "$READ_FAILURES" ]] || return 0
  READ_WHY="the note saying why could not be read back"
  if work_read "$READ_FAILURES" && [[ -n "$READ_TEXT" ]]; then READ_WHY="${READ_TEXT%%$'\n'*}"; fi
  return 0
}
# A read of the journal that failed or did not answer ends the run there.
# Nothing further is undone, and state.json and session.json stay as they
# are on disk (with this boot for a kept display entry's record, if that
# journal was published already); the next run retries.
read_stopped() { # what was read, status
  first_read_failure "${2:-2}"
  log error "could not read $1 ($READ_WHY); recovery stopped here, nothing further undone this run, journal and session kept; will retry"
  exit 1
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
# This run's own folder for the output of its reads and its private copies
# of session.json and state.json (mktemp -d: a new name, mode 0700), removed
# when the run exits. One killed by SIGKILL stays in the temporary folder,
# which the system empties.
if ! WORK="$("$MKTEMP" -d "${TMPDIR:-/tmp}/insomnia-backstop.XXXXXX" 2>/dev/null)"; then
  log error "could not create a private folder for this run's reads in ${TMPDIR:-/tmp}; nothing read or undone, will retry"
  exit 1
fi
trap '"$RM" -rf "$WORK" 2>/dev/null || true' EXIT
READ_FAILURES="$WORK/read-failures.lines"
inode() { "$STAT" -f %i "$1" 2>/dev/null; }
lock_shared=0
if [[ -e /dev/fd/9 && -e "$LOCK" && -n "$(inode "$LOCK")" && "$(inode /dev/fd/9)" == "$(inode "$LOCK")" ]]; then
  lock_shared=1 # fd 9 is the caller's handle on the lock file; share its lock.
fi

# --- The installed app's --resume-frozen version -------------------------------
# resume_via_app runs the app binary only when the bundle's Info.plist
# declares InsomniaResumeFrozenVersion RESUME_FROZEN_VERSION. No Info.plist
# is read under the recovery lock: the value is read before the lock, with
# bounded calls, together with the file's identity (device, inode, change
# time with nanoseconds, size) before and after the read, and
# resume_via_app uses it only when a bounded stat under the lock, which
# reads no contents, shows the same file unchanged. A caller that holds the
# lock already and passes it down as fd 9 (install.sh, uninstall.sh) read
# both before it took the lock, and passes them in the environment:
# INSOMNIA_INFO_PATH (this run's INSOMNIA_INFO, or the values are not
# used), INSOMNIA_INFO_EVIDENCE (the identity, "none" when no regular file
# was there, which declares nothing, or "unknown") and
# INSOMNIA_INFO_VERSION. INFO_EVIDENCE is "unknown" when the read failed,
# did not answer, found a file that does not parse or saw the file change,
# or when nothing usable was passed down; INFO_PROBLEM then says why. Only
# frozen entries that record microseconds need the value; while it is
# unknown they are kept, not signaled. The reading functions are the same
# text in install.sh and uninstall.sh (a test keeps the three equal).
INFO_EVIDENCE=unknown
INFO_VERSION=""
INFO_PROBLEM=""
# The identity of an Info.plist (device, inode, change time with
# nanoseconds, size) in INFO_ID, or "none" when no regular file is there;
# 1, with INFO_PROBLEM, when stat failed, did not answer or printed
# something else. stat reads no contents.
INFO_ID=""
info_identity() { # file
  local rc=0 form='^[0-9]+:[0-9]+:[0-9]+(\.[0-9]+)?:[0-9]+$'
  INFO_ID=none
  [[ -f "$1" ]] || return 0
  bounded "$STAT" -L -f '%d:%i:%Fc:%z' "$1" || rc=$?
  if (( rc != 0 )); then
    INFO_PROBLEM="'stat' $(call_result "$rc")"
    return 1
  fi
  INFO_ID=""
  if (( BOUNDED_READ == 0 )); then INFO_ID="${READ_TEXT%$'\n'}"; fi
  if [[ ! "$INFO_ID" =~ $form ]]; then
    INFO_PROBLEM="'stat' exited 0, but its output could not be read back as the file's identity"
    return 1
  fi
  return 0
}
# InsomniaResumeFrozenVersion from an Info.plist in INFO_VERSION, and the
# file's identity before the read in INFO_EVIDENCE ("none" when no regular
# file is there, which declares nothing). 1, with INFO_PROBLEM and
# INFO_EVIDENCE left as they were, when a read failed or did not answer,
# when the file does not parse, or when its identity after the read differs.
read_info_version() { # file
  local rc=0 before
  info_identity "$1" || return 1
  before="$INFO_ID"
  INFO_VERSION=""
  if [[ "$before" != none ]]; then
    bounded "$PLUTIL" -extract InsomniaResumeFrozenVersion raw -o - "$1" || rc=$?
    if (( rc == 0 )); then
      if (( BOUNDED_READ != 0 )); then
        INFO_PROBLEM="'plutil -extract InsomniaResumeFrozenVersion' exited 0, but its output could not be read back whole"
        return 1
      fi
      # As $(...) would read it: trailing newlines cut.
      INFO_VERSION="${READ_TEXT%"${READ_TEXT##*[!$'\n']}"}"
    elif (( rc == 1 )); then
      # No such key, or no plist at all: only a plist that parses declares
      # no version.
      rc=0
      bounded "$PLUTIL" -lint "$1" || rc=$?
      if (( rc != 0 )); then
        INFO_PROBLEM="it does not parse ('plutil -lint' $(call_result "$rc"))"
        return 1
      fi
    else
      INFO_PROBLEM="'plutil -extract InsomniaResumeFrozenVersion' $(call_result "$rc")"
      return 1
    fi
    info_identity "$1" || return 1
    if [[ "$INFO_ID" != "$before" ]]; then
      INFO_PROBLEM="it changed while it was read"
      return 1
    fi
  fi
  INFO_EVIDENCE="$before"
  return 0
}
if (( lock_shared )); then
  if [[ "${INSOMNIA_INFO_PATH:-}" == "$INSOMNIA_INFO" && -n "${INSOMNIA_INFO_EVIDENCE:-}" ]]; then
    INFO_EVIDENCE="$INSOMNIA_INFO_EVIDENCE"
    INFO_VERSION="${INSOMNIA_INFO_VERSION:-}"
    INFO_PROBLEM="the program that started this run could not read it before it took the recovery lock"
  else
    INFO_PROBLEM="the program that started this run holds the recovery lock and did not pass down a version it read before it took the lock"
  fi
elif [[ -x "$INSOMNIA_BIN" ]]; then
  read_info_version "$INSOMNIA_INFO" || INFO_EVIDENCE=unknown
else
  INFO_PROBLEM="it was not read: no app binary was at $INSOMNIA_BIN before the recovery lock"
fi

if (( ! lock_shared )); then
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
  local status_form=$'^(exit [0-9]{1,3}|term|alive)\n$' pid_form=$'^([0-9]+)\n?$'
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
  # cover that at the usual 0.1 s poll. A supervisor slower than that gets
  # the 125 below, the safe side.
  answer_within=$(( COMMAND_TIMEOUT_SECONDS + KILL_GRACE_SECONDS + 4 ))
  # Both files are read with work_read, which takes a regular file only, so
  # a FIFO there cannot block this run under the lock. A status that does
  # not read back as exactly one of the lines supervise_command writes counts
  # as none.
  if wait_for_status "$base.rc" "$answer_within"; then
    if work_read "$base.rc" && [[ "$READ_TEXT" =~ $status_form ]]; then status="${BASH_REMATCH[1]}"; fi
  fi
  if work_read "$base.pid" && [[ "$READ_TEXT" =~ $pid_form ]]; then cpid="${BASH_REMATCH[1]}"; fi
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
  exit 1
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
# The file is read whole by read_whole, which each script defines with a
# time limit. A read that fails or does not answer prints nothing here and
# returns 2, which the caller passes on as a check that did not complete.
record_text_problems() { # file
  local LC_ALL=C
  local text rest raw key c token depth str plain scalar number esc hex lost rc=0
  local n_low=0 n_lit=0 n_boot=0 digits sig exp e10 lead
  str='^"([^"\\]|\\.)*"'
  plain='^[^]["{}]+'
  scalar='^[^],}[:space:]]+'
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  esc='^u00(4[1-9A-Fa-f]|5[0-9Aa]|6[1-9A-Fa-f]|7[0-9Aa])'
  hex='^u[0-9A-Fa-f]{4}'
  lost="the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked"
  read_whole "$1" || rc=$?
  (( rc != 2 )) || return 2
  text="$WHOLE_TEXT"
  [[ "$text" == *keptDisplay* || "$text" == *\\* ]] || return 0
  if (( rc == 1 )); then
    echo "$lost"
    return 0
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
# the same as an absent optional (Swift decodeIfPresent). A read that failed
# or did not answer makes it return 2 at once, after any lines already
# printed (see plutil_read). The function is the same as uninstall.sh's.
journal_shape_problems() { # file
  local f="$1" key t i n json rc=0
  json="$(plutil_read -convert json -o - "$f")" || rc=$?
  (( rc != 2 )) || return 2
  if [[ "${json:0:1}" != "{" ]]; then
    echo "state.json is not a JSON object"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen savedMuted displayRestoreRefused keyboardRestoreRefused; do
    t="$(type_of "$f" "$key")" || return 2
    [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "$key is a $t, not a bool"
  done
  for key in savedOutputVolume savedDisplayBrightness savedKeyboardBrightness displayRestoredUnderLowPower; do
    t="$(type_of "$f" "$key")" || return 2
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  # The app's records about a kept display entry: never read for an undo
  # here. Each must still decode, or the app cannot read the journal at all.
  for key in keptDisplayUnderLowPower keptDisplayReadLit; do
    t="$(type_of "$f" "$key")" || return 2
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  t="$(type_of "$f" keptDisplayUnderLowPowerBoot)" || return 2
  [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "keptDisplayUnderLowPowerBoot is a $t, not a string"
  record_text_problems "$f" || return 2
  t="$(type_of "$f" frozenProcesses)" || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenProcesses is a $t, not an array"
    else
      i=0
      while :; do
        t="$(type_of "$f" "frozenProcesses.$i")" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "frozenProcesses[$i] is not an object"
        else
          t="$(type_of "$f" "frozenProcesses.$i.pid")" || return 2
          [[ "$t" == integer ]] || echo "frozenProcesses[$i].pid is not an integer"
          for n in startedAt startedAtMicros; do
            t="$(type_of "$f" "frozenProcesses.$i.$n")" || return 2
            [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "frozenProcesses[$i].$n is a $t, not an integer"
          done
          t="$(type_of "$f" "frozenProcesses.$i.bootSession")" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "frozenProcesses[$i].bootSession is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  t="$(type_of "$f" frozenPids)" || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenPids is a $t, not an array"
    else
      i=0
      while :; do
        t="$(type_of "$f" "frozenPids.$i")" || return 2
        [[ -n "$t" ]] || break
        [[ "$t" == integer ]] || echo "frozenPids[$i] is not an integer"
        i=$((i + 1))
      done
    fi
  fi
  t="$(type_of "$f" savedAudioOutputs)" || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "savedAudioOutputs is a $t, not an array"
    else
      i=0
      while :; do
        t="$(type_of "$f" "savedAudioOutputs.$i")" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "savedAudioOutputs[$i] is not an object"
        else
          t="$(type_of "$f" "savedAudioOutputs.$i.deviceUID")" || return 2
          [[ "$t" == string ]] || echo "savedAudioOutputs[$i].deviceUID is not a string"
          t="$(type_of "$f" "savedAudioOutputs.$i.volume")" || return 2
          [[ "$t" == float || "$t" == integer ]] || echo "savedAudioOutputs[$i].volume is not a number"
          t="$(type_of "$f" "savedAudioOutputs.$i.muted")" || return 2
          [[ "$t" == bool ]] || echo "savedAudioOutputs[$i].muted is not a bool"
          t="$(type_of "$f" "savedAudioOutputs.$i.name")" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].name is a $t, not a string"
          t="$(type_of "$f" "savedAudioOutputs.$i.saveID")" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].saveID is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  t="$(type_of "$f" appNapOverrides)" || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "appNapOverrides is a $t, not an array"
    else
      i=0
      while :; do
        t="$(type_of "$f" "appNapOverrides.$i")" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "appNapOverrides[$i] is not an object"
        else
          t="$(type_of "$f" "appNapOverrides.$i.bundleId")" || return 2
          [[ "$t" == string ]] || echo "appNapOverrides[$i].bundleId is not a string"
          t="$(type_of "$f" "appNapOverrides.$i.previous")" || return 2
          [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "appNapOverrides[$i].previous is a $t, not a bool"
        fi
        i=$((i + 1))
      done
    fi
  fi
  return 0
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
# cut: "...Z\n" in the file is refused here as it is in the app. Returns 2
# when the read failed.
epoch_at() { # file keypath
  local v rc=0
  v="$(extract "$1" "$2" && echo .)" || rc=$?
  (( rc != 2 )) || return 2
  v="${v%.}"
  epoch_of "${v%$'\n'}"
}

# Prints one line per way session.json does not have the shape the app's
# Session decoder needs (Session.swift): a JSON object whose startedAt and
# endsAt are dates as Store.swift writes them and whose extensions is an
# array of numbers. All three are required; extra keys are ignored, as in
# Swift. The app refuses a file with any of these problems, so the shell
# does not act on its endsAt either. Returns 2 when a read failed, like
# journal_shape_problems, whose rules and text it shares with uninstall.sh.
session_shape_problems() { # file
  local f="$1" key t e i json rc=0 lead
  # plutil also reads XML and binary property lists, which the app's
  # JSONDecoder refuses, so the file itself must start with "{" too, after
  # any spaces, tabs and line ends (a NUL byte there is not "{" either).
  json="$(plutil_read -convert json -o - "$f")" || rc=$?
  (( rc != 2 )) || return 2
  rc=0
  read_whole "$f" || rc=$?
  (( rc != 2 )) || return 2
  lead="${WHOLE_HEAD#"${WHOLE_HEAD%%[!$' \t\r\n']*}"}"
  if [[ "${lead:0:1}" != "{" || "${json:0:1}" != "{" ]]; then
    echo "session.json is not a JSON object"
    return 0
  fi
  for key in startedAt endsAt; do
    t="$(type_of "$f" "$key")" || return 2
    if [[ -z "$t" ]]; then
      echo "$key is missing"
    elif [[ "$t" != string ]]; then
      echo "$key is a JSON $t, not a date string"
    else
      e="$(epoch_at "$f" "$key")" || return 2
      [[ -n "$e" ]] || echo "$key is not a date in the form 2027-01-15T08:00:00Z or 2027-01-15T10:00:00+02:00"
    fi
  done
  t="$(type_of "$f" extensions)" || return 2
  if [[ -z "$t" ]]; then
    echo "extensions is missing"
  elif [[ "$t" != array ]]; then
    echo "extensions is a JSON $t, not an array"
  else
    i=0
    while :; do
      t="$(type_of "$f" "extensions.$i")" || return 2
      [[ -n "$t" ]] || break
      [[ "$t" == integer || "$t" == float ]] || echo "extensions[$i] is a JSON $t, not a number"
      i=$((i + 1))
    done
  fi
  return 0
}

# --- Read the session --------------------------------------------------------
# session_state: none | valid | expired | malformed | unreadable
session_state=none
ends_at=""
ends_epoch=""
unreadable_why=""
session_problems=""
SESSION_COPY="$WORK/session.json"
if [[ -e "$SESSION" ]]; then
  # Only a regular file is opened: open(2) on a FIFO with no writer, or on
  # some devices, blocks, and this run holds the recovery lock. The copy is
  # a bounded call, so a FIFO put there after this check cannot keep the
  # lock waiting either.
  if [[ ! -f "$SESSION" ]]; then
    session_state=unreadable
    unreadable_why="it is not a regular file, so it is not opened"
  else
    read_rc=0
    snapshot "$SESSION" "$SESSION_COPY" || read_rc=$?
    if (( read_rc == 124 )); then
      session_state=unreadable
      unreadable_why="it could not be read within ${READ_TIMEOUT_SECONDS}s"
    elif (( read_rc != 0 )); then
      session_state=unreadable
      unreadable_why="permissions or I/O"
    else
      session_problems="$(session_shape_problems "$SESSION_COPY")" || read_rc=$?
      if (( read_rc == 0 )) && [[ -z "$session_problems" ]]; then
        value_at "$SESSION_COPY" endsAt || read_rc=$?
        ends_at="$VALUE"
        if (( read_rc == 0 )); then
          ends_epoch="$(epoch_at "$SESSION_COPY" endsAt)" || read_rc=$?
        fi
      fi
      if (( read_rc != 0 )); then
        # A read of the private copy failed or did not answer: the end time
        # is unknown, as for a file that cannot be read at all. The journal
        # reads below get their own chance.
        first_read_failure "$read_rc"
        session_state=unreadable
        session_problems=""
        unreadable_why="reading its copy failed: $READ_WHY"
        "$RM" -f "$READ_FAILURES"
      elif [[ -n "$session_problems" ]]; then
        session_state=malformed
      elif (( ${ends_epoch:-0} > $("$DATE" -u +%s) )); then
        session_state=valid
      else
        session_state=expired
      fi
    fi
  fi
fi

if [[ "$session_state" == valid ]] && (( force == 0 )); then
  exit 0
fi

# --- Read the journal --------------------------------------------------------
# journal_state: missing | malformed | clean | dirty
# Every check reads the private copy; every journal value used from here
# on, the ones published again included, comes from it.
STATE_COPY="$WORK/state.json"
if [[ ! -e "$STATE" ]]; then
  journal_state=missing
elif [[ ! -f "$STATE" ]]; then
  # Never opened, for the same reason as session.json above.
  journal_state=malformed
  shape_problems="not a regular file"
else
  read_rc=0
  snapshot "$STATE" "$STATE_COPY" || read_rc=$?
  if (( read_rc != 0 )); then
    journal_state=malformed
    shape_problems="it could not be read: cp $(call_result "$read_rc")"
  else
    shape_problems="$(journal_shape_problems "$STATE_COPY")" || read_rc=$?
    (( read_rc == 0 )) || read_stopped "$STATE" "$read_rc"
    if [[ -n "$shape_problems" ]]; then journal_state=malformed; else journal_state=clean; fi
  fi
fi

if [[ "$journal_state" == malformed ]]; then
  text_lines "$shape_problems"
  for line in ${TEXT_LINES[@]+"${TEXT_LINES[@]}"}; do
    log error "$STATE: $line"
  done
  log error "$STATE is unreadable or malformed; nothing undone, evidence kept. Open Insomnia or repair the file, then rerun"
  exit 1
fi

# The value at key path $1 of the journal copy in VALUE: 0 when there is
# one, 1 when there is none or only null. A read that failed or did not
# answer ends the run (read_stopped), so callers never see it as absent.
journal_value() { # keypath [raw|json]
  local rc=0
  value_at "$STATE_COPY" "$1" "${2:-raw}" || rc=$?
  (( rc != 2 )) || read_stopped "$1 in $STATE"
  return "$rc"
}
journal_true() { # key
  journal_value "$1" && [[ "$VALUE" == true ]]
}

sleep_held=false; low_power=false; docker_frozen=false; has_audio=0
has_display=0; has_keyboard=0; refused_display=0; refused_keyboard=0
frozen_count=0; legacy_count=0; app_nap_count=0; output_count=0
if [[ "$journal_state" == clean ]]; then
  journal_true sleepDisabledByUs && sleep_held=true
  journal_true lowPowerSetByUs && low_power=true
  journal_true dockerFrozen && docker_frozen=true
  journal_value savedOutputVolume && has_audio=1
  journal_value savedMuted && has_audio=1
  if journal_value savedDisplayBrightness; then
    if journal_true displayRestoreRefused; then refused_display=1; else has_display=1; fi
  fi
  if journal_value savedKeyboardBrightness; then
    if journal_true keyboardRestoreRefused; then refused_keyboard=1; else has_keyboard=1; fi
  fi
  while journal_value "frozenProcesses.$frozen_count" json; do
    frozen_count=$((frozen_count + 1))
  done
  while journal_value "frozenPids.$legacy_count"; do
    legacy_count=$((legacy_count + 1))
  done
  while journal_value "appNapOverrides.$app_nap_count" json; do
    app_nap_count=$((app_nap_count + 1))
  done
  # Kept for the app and not counted as dirty; see the header.
  while journal_value "savedAudioOutputs.$output_count" json; do
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
  text_lines "$session_problems"
  for line in ${TEXT_LINES[@]+"${TEXT_LINES[@]}"}; do
    log warn "$SESSION: $line"
  done
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
    "$RM" -f "$SESSION"
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
    new_sleep=false; changed=1
  else
    if (( command_alive )); then stop_transaction "pmset -a disablesleep 0"; fi
    log error "pmset -a disablesleep 0 failed (sudoers rule missing? run install.sh); keeping journal entry for retry"
    failures+=("sleep is still disabled: pmset -a disablesleep 0 failed")
  fi
fi

# Whether file $1, about to be published as state.json, is still a JSON
# object both as plutil reads it and as text (plutil keeps a JSON file
# JSON): 0 when it is; 1 when not, or when a read failed or did not answer
# (noted in READ_FAILURES).
still_json() { # file
  local json rc=0
  json="$(plutil_read -convert json -o - "$1")" || return 1
  [[ "${json:0:1}" == "{" ]] || return 1
  read_whole "$1" || rc=$?
  (( rc == 0 )) && [[ "${WHOLE_TEXT:0:1}" == "{" ]]
}

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
boot_published=0
boot_value=""
prepare_low_power_off() {
  local t tmp ok=1
  t="$(type_of "$STATE_COPY" keptDisplayUnderLowPower)" || read_stopped "keptDisplayUnderLowPower in $STATE"
  [[ "$t" == float || "$t" == integer ]] || return 0
  boot_value="$("$SYSCTL" -n kern.bootsessionuuid 2>/dev/null || true)"
  journal_value keptDisplayUnderLowPowerBoot || true
  [[ "$VALUE" == "$boot_value" ]] && return 0
  tmp="$APP_SUPPORT/.state.json.backstop-boot.$$"
  snapshot "$STATE_COPY" "$tmp" || ok=0
  if (( ok == 1 )); then
    bounded "$PLUTIL" -replace keptDisplayUnderLowPowerBoot -string "$boot_value" "$tmp" || ok=0
  fi
  if (( ok == 1 )); then
    still_json "$tmp" || ok=0
  fi
  if (( ok == 1 )); then
    "$MV" -f "$tmp" "$STATE" || ok=0
  fi
  if (( ok == 0 )); then
    "$RM" -f "$tmp"
    return 1
  fi
  # The journal published at the end starts from the copy read at the
  # start, so it gets the same boot.
  boot_published=1
  log info "kept display entry's record given this boot (${boot_value:-unreadable, written empty}) before Low Power Mode is switched off"
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
#   unknown   ps failed some other way, did not answer within
#             READ_TIMEOUT_SECONDS (a bounded read), or printed something
#             unparseable
observe() { # pid
  local out rc=0
  observation=unknown; p_epoch=""; p_stat=""; p_uid=""
  bounded "$PS" -o lstart=,stat=,uid= -p "$1" || rc=$?
  (( rc == 0 || rc == 1 )) || return 0
  (( BOUNDED_READ == 0 )) || return 0
  # As $(...) would read it: trailing newlines cut.
  out="${READ_TEXT%"${READ_TEXT##*[!$'\n']}"}"
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
  local n=${#app_pid[@]} k rc=0 read_rc valid=1 settled=1 expected=0 line word excerpt="" p rest declared unknown
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
  # The version read before the lock applies only to the same file,
  # unchanged (see read_info_version); no Info.plist is read here.
  declared=""
  unknown=""
  if [[ "$INFO_EVIDENCE" == unknown ]]; then
    unknown="the InsomniaResumeFrozenVersion that $INSOMNIA_INFO declares is unknown ($INFO_PROBLEM), and no Info.plist is read under the recovery lock"
  elif ! info_identity "$INSOMNIA_INFO"; then
    unknown="whether the InsomniaResumeFrozenVersion read from $INSOMNIA_INFO before the recovery lock still applies is unknown ($INFO_PROBLEM under the lock)"
  elif [[ "$INFO_ID" != "$INFO_EVIDENCE" ]]; then
    unknown="$INSOMNIA_INFO changed after its InsomniaResumeFrozenVersion was read before the recovery lock (an install may have replaced the app meanwhile)"
  else
    declared="$INFO_VERSION"
  fi
  if [[ -n "$unknown" ]]; then
    for (( k = 0; k < n; k++ )); do
      log error "pid ${app_pid[k]} needs the app binary for its microsecond identity check, but $unknown; the binary was not run; kept, not signaled"
      failures+=("pid ${app_pid[k]} was not resumed: whether the installed app declares --resume-frozen version $RESUME_FROZEN_VERSION is unknown")
      keep_entry "${app_index[k]}"
    done
    return 0
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
  # The answer is read whole by work_read (the folder is this run's own,
  # like WORK): one with a NUL byte, or one that cannot be read back whole,
  # is not valid. The excerpt for the log leaves NUL bytes out and shows
  # other bytes that do not print as spaces.
  read_rc=2
  if (( rc != 125 )) && [[ -n "$app_answer_dir" ]]; then
    read_rc=0
    work_read "$app_answer_dir/out" || read_rc=$?
  fi
  (( read_rc == 2 )) || excerpt="${READ_TEXT:0:200}"
  excerpt="${excerpt//[![:print:]]/ }"
  if (( read_rc != 0 )); then
    valid=0
  else
    # A valid line is at most 24 bytes ("<10-digit pid> unverifiable\n").
    if (( ${#READ_TEXT} > n * 32 )); then
      valid=0
    else
      k=0
      rest="$READ_TEXT"
      while [[ -n "$rest" ]]; do
        line="${rest%%$'\n'*}"
        if [[ "$rest" == *$'\n'* ]]; then rest="${rest#*$'\n'}"; else rest=""; fi
        if (( k >= n )) || [[ "$line" != "${app_pid[k]} "* ]]; then valid=0; break; fi
        word="${line#"${app_pid[k]} "}"
        case "$word" in
          resumed|gone) ;;
          failed|unobserved|unverifiable) settled=0 ;;
          *) valid=0; break ;;
        esac
        words+=("$word")
        k=$((k + 1))
      done
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
  uid_now="$(id -u)"
  i=0
  while (( i < frozen_count )); do
    journal_value "frozenProcesses.$i.pid" || true
    pid="$VALUE"
    journal_value "frozenProcesses.$i.startedAt" || true
    started="$VALUE"
    journal_value "frozenProcesses.$i.startedAtMicros" || true
    micros="$VALUE"
    journal_value "frozenProcesses.$i.bootSession" || true
    boot="$VALUE"
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
  journal_value "frozenProcesses.$i" json || true
  entry="$VALUE"
  if [[ -z "$entry" ]]; then
    log error "could not read frozen entry $i back from $STATE; previous journal kept, will retry"
    exit 1
  fi
  if [[ -n "$kept_frozen" ]]; then kept_frozen="$kept_frozen,$entry"; else kept_frozen="$entry"; fi
  kept_frozen_count=$((kept_frozen_count + 1))
done

if (( legacy_count > 0 )); then
  journal_value frozenPids json || true
  legacy_json="$VALUE"
  log error "legacy frozenPids $legacy_json have no identity; not signaled and not cleared here, the app must resolve them"
  failures+=("legacy frozenPids $legacy_json were not resumed (identity unknown; only the app resolves these)")
fi

new_docker="$docker_frozen"
if [[ "$docker_frozen" == true ]] && (( kept_frozen_count == 0 && legacy_count == 0 )); then
  new_docker=false; changed=1
fi

# Whether the output defaults wrote to $1, a file in WORK, holds the words
# $2. Output that cannot be read back holds nothing.
probe_says() { # file words
  local rc=0
  work_read "$1" || rc=$?
  (( rc != 2 )) && [[ "$READ_TEXT" == *"$2"* ]]
}

# App Nap. The app set NSAppSleepDisabled to YES in each listed agent app's
# preferences and journaled what the key was before. Put that back with the
# tool a person would use. Each entry is kept verbatim (unknown fields
# included) unless its restore succeeded.
kept_app_nap=""
kept_app_nap_count=0
keep_app_nap_entry() { # index
  local entry
  journal_value "appNapOverrides.$1" json || true
  entry="$VALUE"
  if [[ -z "$entry" ]]; then
    log error "could not read App Nap entry $1 back from $STATE; previous journal kept, will retry"
    exit 1
  fi
  if [[ -n "$kept_app_nap" ]]; then kept_app_nap="$kept_app_nap,$entry"; else kept_app_nap="$entry"; fi
  kept_app_nap_count=$((kept_app_nap_count + 1))
}
if (( app_nap_count > 0 )); then
  i=0
  while (( i < app_nap_count )); do
    journal_value "appNapOverrides.$i.bundleId" || true
    bundle="$VALUE"
    journal_value "appNapOverrides.$i.previous" || true
    previous="$VALUE"
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
        probe="$WORK/defaults-read.out"
        bounded_output="$probe"
        read_rc=0
        run_bounded "$DEFAULTS" read "$bundle" NSAppSleepDisabled || read_rc=$?
        bounded_output=""
        if (( command_alive )); then "$RM" -f "$probe"; stop_transaction "defaults read $bundle NSAppSleepDisabled"; fi
        if (( read_rc == 0 )); then
          log error "defaults delete $bundle NSAppSleepDisabled failed and the key is still set; keeping journal entry for retry"
          failures+=("App Nap is still off for $bundle: defaults delete failed")
          keep_app_nap_entry "$i"
        elif probe_says "$probe" "does not exist"; then
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
# Edit a copy of the journal as this run read it (STATE_COPY), verify it,
# then rename it over state.json so readers only ever see a complete
# journal. Keys we do not own survive untouched. Each edit and check is a
# bounded call; one that fails or does not answer keeps the previous
# journal.
if (( changed == 1 )); then
  tmp="$APP_SUPPORT/.state.json.backstop.$$"
  publish_ok=1
  snapshot "$STATE_COPY" "$tmp" || publish_ok=0
  if (( publish_ok == 1 && boot_published == 1 )); then
    bounded "$PLUTIL" -replace keptDisplayUnderLowPowerBoot -string "$boot_value" "$tmp" || publish_ok=0
  fi
  if (( publish_ok == 1 )) && [[ "$new_sleep" != "$sleep_held" ]]; then
    bounded "$PLUTIL" -replace sleepDisabledByUs -bool "$new_sleep" "$tmp" || publish_ok=0
  fi
  if (( publish_ok == 1 )) && [[ "$new_low" != "$low_power" ]]; then
    bounded "$PLUTIL" -replace lowPowerSetByUs -bool "$new_low" "$tmp" || publish_ok=0
  fi
  if (( publish_ok == 1 )) && [[ "$new_docker" != "$docker_frozen" ]]; then
    bounded "$PLUTIL" -replace dockerFrozen -bool "$new_docker" "$tmp" || publish_ok=0
  fi
  if (( publish_ok == 1 && frozen_count > 0 )); then
    bounded "$PLUTIL" -replace frozenProcesses -json "[$kept_frozen]" "$tmp" || publish_ok=0
  fi
  if (( publish_ok == 1 && app_nap_count > 0 )); then
    bounded "$PLUTIL" -replace appNapOverrides -json "[$kept_app_nap]" "$tmp" || publish_ok=0
  fi
  if (( publish_ok == 1 )); then
    still_json "$tmp" || publish_ok=0
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

if (( output_count > 0 )); then
  log info "journal cleared apart from $outputs_note"
else
  log info "journal cleared"
fi
case "$session_state" in
  malformed|unreadable) quarantine_session || exit 1 ;;
  *)                    "$RM" -f "$SESSION" ;;
esac
exit 0
