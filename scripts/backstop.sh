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
#                     endFloor in config.json (default 10, strict, so 0
#                     disables it; read and clamped to 0...95 as the app
#                     reads it). A battery present but unreadable, or a
#                     failing pmset, ends too (fail closed). No battery in
#                     pmset: ioreg shows whether an AppleSmartBattery service
#                     exists, as the app checks. None is a desktop, with no
#                     battery rule; one without a charger reported ends.
#       thermal    -> notifyutil -g com.apple.system.thermalpressurelevel at
#                     3 (trapping) or above, with thermalRules on (default).
#                     Unreadable: a warning, not an end on that alone.
#     All three pass: exit 0, nothing logged.
#   - A valid session this run ends (a check above, or --force) is over
#     from that decision: session.json is removed before anything is undone,
#     so an undo that cannot finish (saved brightness only the app restores,
#     a failing or hung pmset) never leaves a session a relaunched app would
#     resume. What is left stays in state.json for the next run and the app.
#     A session.json that cannot be removed (an immutable file) is recorded
#     as ended in ended-session.json, a copy of its bytes. While the two
#     match, the app restores that session instead of resuming it, and every
#     run ends it again without the checks and retries the removal. If the
#     record cannot be written either, sleep is still restored but its
#     journal entry stays, and the run exits 1.
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
#     wrong type: nothing is touched, exit 1.
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
# com.apple.system.thermalpressurelevel at or above this ends a session. On
# macOS the levels are 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping
# (libkern/OSThermalNotification.h); ProcessInfo reports .critical from
# trapping up, which is where the app's FloorRules end the session.
THERMAL_CRITICAL_LEVEL=3
# Longest a single undo command (sudo pmset, defaults) may run before it is
# sent SIGTERM, and how long it then gets to exit before this run fails closed.
COMMAND_TIMEOUT_SECONDS=30
KILL_GRACE_SECONDS=3

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

log() { # level message
  "$MKDIR" -p "$LOG_DIR"
  # Append only to a regular file, or create one. open(2) on a FIFO with no
  # reader blocks, and most lines are written while this run holds the
  # recovery lock. A line with nowhere to go is dropped.
  if [[ -e "$LOG" && ! -f "$LOG" ]]; then return 0; fi
  printf '%s [%s] backstop: %s\n' "$("$DATE" -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"
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
inode() { stat -f %i "$1" 2>/dev/null; }
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
# Type name of a keypath (bool, integer, float, string, array, dictionary,
# "(any)" for null); empty if the key is absent.
type_of() { # file keypath
  "$PLUTIL" -type "$2" -o - "$1" 2>/dev/null || true
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

# Run one read (pmset -g batt, ioreg, notifyutil -g) with the undo commands'
# time limit and put its standard output in the variable named by $1. A read
# changes nothing, so unlike an undo command it has no reason to hold the
# recovery lock: it starts with fd 9 closed, so a read that hangs can only
# fail itself, never a later run or the app. This shell starts it as its own
# background job and is the only process that signals it, by jobspec once
# signal_job has checked that the job is this read (see run_app_bounded), so
# a signal never reaches a process that reused its pid; no pid is read back
# from a file. Both limits are on the SECONDS clock (wait_for_job). A read
# still running KILL_GRACE_SECONDS after SIGTERM gets SIGKILL: it runs
# unprivileged and has nothing to leave half done. Returns the read's exit
# status, or 124 when it was stopped. Its output goes through
# .backstop.<this run's pid>.<call>.out, which this call removes, and the
# first call of a run removes what earlier runs left (remove_stale_run_files).
# The function's stderr is /dev/null because bash reports a job that a signal
# ended on its own stderr; the log says what happened instead.
run_read() { # varname command args...
  local name="$1" outfile cpid rc=0 read_output=""
  shift
  bounded_calls=$((bounded_calls + 1))
  remove_stale_run_files
  outfile="$APP_SUPPORT/.backstop.$$.$bounded_calls.out"
  # A leftover at this name goes unopened first, as in record_end.
  "$RM" -f "$outfile" 2>/dev/null || true
  "$@" </dev/null >"$outfile" 2>/dev/null 9>&- &
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
  if (( rc != 124 )) && [[ -f "$outfile" ]]; then read_output="$(cat "$outfile")"; fi
  printf -v "$name" '%s' "$read_output"
  "$RM" -f "$outfile"
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

# Prints one line per way the journal does not have the shape the app writes
# (RuntimeState.swift). Present keys must have the right type; a JSON null is
# the same as an absent optional (Swift decodeIfPresent).
journal_shape_problems() { # file
  local f="$1" key t i n
  if [[ "$("$PLUTIL" -convert json -o - "$f" 2>/dev/null | head -c 1)" != "{" ]]; then
    echo "state.json is not a JSON object"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen savedMuted; do
    t="$(type_of "$f" "$key")"
    [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "$key is a $t, not a bool"
  done
  for key in savedOutputVolume savedDisplayBrightness savedKeyboardBrightness; do
    t="$(type_of "$f" "$key")"
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  t="$(type_of "$f" frozenProcesses)"
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenProcesses is a $t, not an array"
    else
      i=0
      while [[ -n "$(type_of "$f" "frozenProcesses.$i")" ]]; do
        if [[ "$(type_of "$f" "frozenProcesses.$i")" != dictionary ]]; then
          echo "frozenProcesses[$i] is not an object"
        else
          [[ "$(type_of "$f" "frozenProcesses.$i.pid")" == integer ]] || echo "frozenProcesses[$i].pid is not an integer"
          for n in startedAt startedAtMicros; do
            t="$(type_of "$f" "frozenProcesses.$i.$n")"
            [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "frozenProcesses[$i].$n is a $t, not an integer"
          done
          t="$(type_of "$f" "frozenProcesses.$i.bootSession")"
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "frozenProcesses[$i].bootSession is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  t="$(type_of "$f" frozenPids)"
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenPids is a $t, not an array"
    else
      i=0
      while [[ -n "$(type_of "$f" "frozenPids.$i")" ]]; do
        [[ "$(type_of "$f" "frozenPids.$i")" == integer ]] || echo "frozenPids[$i] is not an integer"
        i=$((i + 1))
      done
    fi
  fi
  t="$(type_of "$f" savedAudioOutputs)"
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "savedAudioOutputs is a $t, not an array"
    else
      i=0
      while [[ -n "$(type_of "$f" "savedAudioOutputs.$i")" ]]; do
        if [[ "$(type_of "$f" "savedAudioOutputs.$i")" != dictionary ]]; then
          echo "savedAudioOutputs[$i] is not an object"
        else
          [[ "$(type_of "$f" "savedAudioOutputs.$i.deviceUID")" == string ]] || echo "savedAudioOutputs[$i].deviceUID is not a string"
          t="$(type_of "$f" "savedAudioOutputs.$i.volume")"
          [[ "$t" == float || "$t" == integer ]] || echo "savedAudioOutputs[$i].volume is not a number"
          [[ "$(type_of "$f" "savedAudioOutputs.$i.muted")" == bool ]] || echo "savedAudioOutputs[$i].muted is not a bool"
          t="$(type_of "$f" "savedAudioOutputs.$i.name")"
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].name is a $t, not a string"
          t="$(type_of "$f" "savedAudioOutputs.$i.saveID")"
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].saveID is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  t="$(type_of "$f" appNapOverrides)"
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "appNapOverrides is a $t, not an array"
    else
      i=0
      while [[ -n "$(type_of "$f" "appNapOverrides.$i")" ]]; do
        if [[ "$(type_of "$f" "appNapOverrides.$i")" != dictionary ]]; then
          echo "appNapOverrides[$i] is not an object"
        else
          [[ "$(type_of "$f" "appNapOverrides.$i.bundleId")" == string ]] || echo "appNapOverrides[$i].bundleId is not a string"
          t="$(type_of "$f" "appNapOverrides.$i.previous")"
          [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "appNapOverrides[$i].previous is a $t, not a bool"
        fi
        i=$((i + 1))
      done
    fi
  fi
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
  if [[ "$(LC_ALL=C tr -d ' \t\r\n' < "$f" 2>/dev/null | head -c 1)" != "{" ]] \
     || [[ "$("$PLUTIL" -convert json -o - "$f" 2>/dev/null | head -c 1)" != "{" ]]; then
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
  elif ! cat "$SESSION" >/dev/null 2>&1; then
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

# --- Was this session already ended? -----------------------------------------
# A run or the app that ends a valid session but cannot remove session.json
# records the end in $ENDED, a copy of the file's exact bytes (record_end).
# While the two match, that session is over whatever its endsAt says: this
# run ends it again without the checks below and retries the removal. A
# record that matches nothing (its session.json was removed or replaced) is
# stale and goes; it could only ever match the file it copied. rm unlinks
# a FIFO there without opening it.
ended_before=0
if [[ -e "$ENDED" ]]; then
  if end_recorded; then
    ended_before=1
  else
    remove_end_record
  fi
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

# A setting from config.json, or the default when the file or key is missing
# or the value is not one the app decodes (Int, Bool): a string "false" or
# "30" is rejected here as the app rejects it, so both enforce the same rule.
# plutil -extract raw prints a string and a number alike; the type comes from
# plutil -type. JSONDecoder reads any number that is exactly an integer as an
# Int (30.0, 3e1), so a float counts when it is whole. Its raw form is
# rounded to six places, so the test reads the XML form, which prints the
# shortest exact value ("30", "0.0", "30.000000100000001"). More than 18
# digits is past what the shell can compare; the default stands for it.
#
# config.json is opened only when it is a regular file, as session.json and
# state.json are: open(2) on a FIFO with no writer blocks while this run
# holds the recovery lock. Anything else reads as a missing file, as the app
# treats it (Store.readData; the app then moves it aside).
config_is_file() { [[ -f "$CONFIG" ]]; }
config_int() { # key default
  local t="" v=""
  config_is_file && t="$(type_of "$CONFIG" "$1")"
  if [[ "$t" == integer ]]; then
    v="$(extract "$CONFIG" "$1" || true)"
  elif [[ "$t" == float ]]; then
    v="$("$PLUTIL" -extract "$1" xml1 -o - "$CONFIG" 2>/dev/null | sed -n 's:.*<real>\(.*\)</real>.*:\1:p' || true)"
    [[ "$v" == 0.0 || "$v" == -0.0 ]] && v=0
  fi
  if [[ "$v" =~ ^(-?)([0-9]{1,18})$ ]]; then
    echo "${BASH_REMATCH[1]}$((10#${BASH_REMATCH[2]}))"
  else
    echo "$2"
  fi
}
config_bool() { # key default
  local v=""
  config_is_file || { echo "$2"; return; }
  v="$(extract "$CONFIG" "$1" || true)"
  if [[ "$(type_of "$CONFIG" "$1")" == bool ]]; then
    case "$v" in true|false) echo "$v"; return ;; esac
  fi
  echo "$2"
}

# pmset -g batt prints the source ("Now drawing from 'Battery Power'" or 'AC
# Power') and one line per battery ("-InternalBattery-0 (id=...) 26%;
# discharging; 0:41 remaining present: true"). Sets battery_reason and
# returns 0 when the session must end: an internal battery is present, the
# Mac draws from it, and the percentage is below endFloor (strict, so 0
# disables the rule, as in FloorRules.swift, and nothing is read then); or
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
  floor="$(config_int endFloor 10)"
  # The app clamps the end floor to 0...95 (Config.normalizeFloors), so a
  # negative one is off, as 0 is.
  (( floor > 95 )) && floor=95
  (( floor > 0 )) || return 1
  run_read out "$PMSET" -g batt || rc=$?
  if (( rc == 124 )); then
    battery_reason="battery state unreadable (pmset -g batt did not finish within ${COMMAND_TIMEOUT_SECONDS}s)"
    return 0
  elif (( rc != 0 )); then
    battery_reason="battery state unreadable (pmset -g batt exit $rc)"
    return 0
  fi
  line="$(grep -m 1 InternalBattery <<< "$out" || true)"
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
  grep -q '^+-o ' <<< "$reg" || return 1
  grep -q '"ExternalConnected" = Yes' <<< "$reg" && return 1
  battery_reason="battery present (AppleSmartBattery) but missing from pmset -g batt, and no charger reported"
  return 0
}

# notifyutil -g prints "com.apple.system.thermalpressurelevel N" (levels at
# THERMAL_CRITICAL_LEVEL). Sets thermal_reason and returns 0 when the
# session must end. Off with thermalRules false in config.json. Unreadable
# (failed, hung, or not a level): a warning, never an end on that alone; the
# alive and battery checks stand.
thermal_reason=""
thermal_cutoff() {
  local out="" level
  thermal_reason=""
  [[ "$(config_bool thermalRules true)" == true ]] || return 1
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
    cutoff="already ended (recorded in $ENDED) but session.json could not be removed"
  elif ! app_alive; then
    cutoff="Insomnia is not running"
  elif battery_cutoff; then
    cutoff="$battery_reason"
  elif thermal_cutoff; then
    cutoff="$thermal_reason"
  else
    exit 0
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
# A session.json that cannot be removed is recorded as ended instead, and
# the app and every later run honour the record until the file is gone. If
# the record cannot be written either, nothing on disk says the session is
# over: sleep is still restored below, since leaving it disabled is worse,
# but its journal entry stays, so the journal reads dirty, uninstall.sh
# stops, and every run exits 1 until a person makes the file removable.

# Remove session.json, then the record of its end, which means something
# only while the file it copies is there. False when session.json stays.
remove_session() {
  "$RM" -f "$SESSION" 2>/dev/null || return 1
  remove_end_record
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
  if [[ -f "$SESSION" ]] && cat "$SESSION" > "$tmp" 2>/dev/null; then "$MV" -f "$tmp" "$ENDED" 2>/dev/null || true; fi
  "$RM" -f "$tmp" 2>/dev/null || true
  end_recorded
}

session_left=0      # 1 when the valid session this run ends is still on disk
keep_sleep_entry=0  # 1 when nothing on disk records that end
if [[ "$session_state" == valid ]] && ! remove_session; then
  session_left=1
  if record_end; then
    log error "could not remove $SESSION; its end is recorded in $ENDED, so Insomnia restores the session instead of resuming it. Every run retries the removal"
  else
    keep_sleep_entry=1
    log error "could not remove $SESSION or record its end in $ENDED; a relaunched Insomnia could resume the session. Sleep is restored anyway, but sleepDisabledByUs stays journaled and every run exits 1 until the file can be removed (ls -lO shows its flags)"
  fi
fi

# --- Read the journal --------------------------------------------------------
# journal_state: missing | malformed | clean | dirty
if [[ ! -e "$STATE" ]]; then
  journal_state=missing
elif [[ ! -f "$STATE" ]]; then
  # Never opened, for the same reason as session.json above.
  journal_state=malformed
  shape_problems="not a regular file"
elif ! "$PLUTIL" -convert json -o /dev/null "$STATE" >/dev/null 2>&1; then
  journal_state=malformed
  shape_problems="not valid JSON"
else
  shape_problems="$(journal_shape_problems "$STATE")"
  if [[ -n "$shape_problems" ]]; then journal_state=malformed; else journal_state=clean; fi
fi

if [[ "$journal_state" == malformed ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && log error "$STATE: $line"
  done <<< "$shape_problems"
  log error "$STATE is unreadable or malformed; nothing undone, evidence kept. Open Insomnia or repair the file, then rerun"
  exit 1
fi

sleep_held=false; low_power=false; docker_frozen=false; has_audio=0
has_display=0; has_keyboard=0
frozen_count=0; legacy_count=0; app_nap_count=0; output_count=0
if [[ "$journal_state" == clean ]]; then
  is_true "$STATE" sleepDisabledByUs && sleep_held=true
  is_true "$STATE" lowPowerSetByUs && low_power=true
  is_true "$STATE" dockerFrozen && docker_frozen=true
  extract "$STATE" savedOutputVolume >/dev/null && has_audio=1
  extract "$STATE" savedMuted >/dev/null && has_audio=1
  extract "$STATE" savedDisplayBrightness >/dev/null && has_display=1
  extract "$STATE" savedKeyboardBrightness >/dev/null && has_keyboard=1
  while extract_json "$STATE" "frozenProcesses.$frozen_count" >/dev/null; do
    frozen_count=$((frozen_count + 1))
  done
  while extract "$STATE" "frozenPids.$legacy_count" >/dev/null; do
    legacy_count=$((legacy_count + 1))
  done
  while extract_json "$STATE" "appNapOverrides.$app_nap_count" >/dev/null; do
    app_nap_count=$((app_nap_count + 1))
  done
  # Kept for the app and not counted as dirty; see the header.
  while extract_json "$STATE" "savedAudioOutputs.$output_count" >/dev/null; do
    output_count=$((output_count + 1))
  done
  if [[ "$sleep_held" == true || "$low_power" == true || "$docker_frozen" == true ]] \
     || (( has_audio == 1 || has_display == 1 || has_keyboard == 1 || frozen_count > 0 || legacy_count > 0 || app_nap_count > 0 )); then
    journal_state=dirty
  fi
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
    quarantine_session || exit 1
    exit 0
  fi
  if [[ "$session_state" != none ]]; then
    if [[ "$journal_state" == missing ]]; then
      log warn "$session_note; no journal on disk, nothing recorded to undo"
    else
      log info "$session_note; journal already clean"
    fi
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

new_low="$low_power"
if [[ "$low_power" == true ]]; then
  if run_bounded "$SUDO" -n "$PMSET" -b lowpowermode 0; then
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
    size="$(stat -f %z "$answer" 2>/dev/null || echo 0)"
    excerpt="$(head -c 200 "$answer" | tr -c '[:print:]' ' ')"
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
  uid_now="$(id -u)"
  i=0
  while (( i < frozen_count )); do
    pid="$(extract "$STATE" "frozenProcesses.$i.pid" || true)"
    started="$(extract "$STATE" "frozenProcesses.$i.startedAt" || true)"
    micros="$(extract "$STATE" "frozenProcesses.$i.startedAtMicros" || true)"
    boot="$(extract "$STATE" "frozenProcesses.$i.bootSession" || true)"
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
  if ! entry="$(extract_json "$STATE" "frozenProcesses.$i")" || [[ -z "$entry" ]]; then
    log error "could not read frozen entry $i back from $STATE; previous journal kept, will retry"
    exit 1
  fi
  if [[ -n "$kept_frozen" ]]; then kept_frozen="$kept_frozen,$entry"; else kept_frozen="$entry"; fi
  kept_frozen_count=$((kept_frozen_count + 1))
done

if (( legacy_count > 0 )); then
  legacy_json="$(extract_json "$STATE" frozenPids || true)"
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
  entry="$(extract_json "$STATE" "appNapOverrides.$1")"
  if [[ -n "$kept_app_nap" ]]; then kept_app_nap="$kept_app_nap,$entry"; else kept_app_nap="$entry"; fi
  kept_app_nap_count=$((kept_app_nap_count + 1))
}
if (( app_nap_count > 0 )); then
  i=0
  while (( i < app_nap_count )); do
    bundle="$(extract "$STATE" "appNapOverrides.$i.bundleId" || true)"
    previous="$(extract "$STATE" "appNapOverrides.$i.previous" || true)"
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
        elif grep -q "does not exist" "$probe" 2>/dev/null; then
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

# --- Publish -----------------------------------------------------------------
# Edit a private copy, verify it, then rename it over state.json so readers
# only ever see a complete journal. Keys we do not own survive untouched.
if (( changed == 1 )); then
  tmp="$APP_SUPPORT/.state.json.backstop.$$"
  publish_ok=1
  # As in record_end: a leftover at this PID's name goes unopened first.
  "$RM" -f "$tmp" 2>/dev/null || true
  "$CP" "$STATE" "$tmp" || publish_ok=0
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
  if (( publish_ok == 1 )); then
    # plutil keeps JSON files as JSON; make sure the result is still one.
    [[ "$("$PLUTIL" -convert json -o - "$tmp" 2>/dev/null | head -c 1)" == "{" ]] || publish_ok=0
    [[ "$(head -c 1 "$tmp")" == "{" ]] || publish_ok=0
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
