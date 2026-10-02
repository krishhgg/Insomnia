#!/bin/bash
# Insomnia backstop: restore the machine from the JSON journal alone.
# Runs from launchd (RunAtLoad + StartInterval 60, installed by install.sh)
# and from install.sh / uninstall.sh. Needs no Insomnia process and no Swift.
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
#                     disables it). A battery present but unreadable, or a
#                     failing pmset, ends too (fail closed). No battery: no
#                     battery rule.
#       thermal    -> notifyutil -g com.apple.system.thermalpressurelevel at
#                     3 (trapping) or above, with thermalRules on (default).
#                     Unreadable: a warning, not an end on that alone.
#     All three pass: exit 0, nothing logged.
#   - state.json missing or clean: nothing is undone and nothing privileged
#     runs; an expired session.json is removed. Exit 0.
#   - state.json dirty: undo each journaled entry from the journal alone:
#       sleepDisabledByUs   -> sudo -n pmset -a disablesleep 0
#       lowPowerSetByUs     -> sudo -n pmset -b lowpowermode 0
#       frozenProcesses     -> SIGCONT, but only to a pid that is observed to
#                              exist, be stopped, have started in this boot
#                              session at the journaled second (ps -o lstart)
#                              and belong to this user. A pid observed gone,
#                              running, or not matching is cleared without a
#                              signal. A pid that cannot be observed (ps
#                              fails or prints something unparseable) is kept.
#       frozenPids (legacy)  -> never signaled and never cleared here, even if
#                              the pid is gone: nothing proves the stopped
#                              process is ours. Only the app resolves them.
#       savedOutputVolume / savedMuted -> CoreAudio; only the app can restore
#                              these. Kept for the app's reconcile.
#       savedDisplayBrightness / savedKeyboardBrightness -> display brightness
#                              and keyboard backlight the app set to 0 on lid
#                              close; only the app can restore these (private
#                              frameworks). Kept for the app's reconcile.
#     A flag is cleared only after its undo succeeded. Unknown keys survive.
#     Exit 0 only when the journal is clean afterwards; otherwise exit 1 so
#     the failure is visible and the next periodic run retries.
#   - state.json unreadable, not a JSON object, or with a known key of the
#     wrong type: nothing is touched, exit 1.
#
# Limitation: the shell compares process start time to the second and the
# boot session; only the app also compares the microseconds.
#
# --force: treat the session as expired even if endsAt is in the future
# (used by install.sh / uninstall.sh to end a stale session deliberately).
#
# Honours INSOMNIA_HOME with the same layout as the app (see Paths.swift).
set -euo pipefail
export LC_ALL=C TZ=UTC

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
LOCK_TIMEOUT_SECONDS=10
# com.apple.system.thermalpressurelevel at or above this ends a session. On
# macOS the levels are 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping
# (libkern/OSThermalNotification.h); ProcessInfo reports .critical from
# trapping up, which is where the app's FloorRules end the session.
THERMAL_CRITICAL_LEVEL=3
# Longest a single undo command (sudo pmset) may run before it is sent
# SIGTERM, and how long it then gets to exit before this run fails closed.
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
STATE="$APP_SUPPORT/state.json"
CONFIG="$APP_SUPPORT/config.json"
LOCK="$APP_SUPPORT/.recovery.lock"
ALIVE="$APP_SUPPORT/.app.alive"
LOG="$LOG_DIR/insomnia.log"

log() { # level message
  mkdir -p "$LOG_DIR"
  printf '%s [%s] backstop: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG"
}

# --- Lock --------------------------------------------------------------------
mkdir -p "$APP_SUPPORT"
inode() { stat -f %i "$1" 2>/dev/null; }
if [[ -e /dev/fd/9 && -e "$LOCK" && -n "$(inode "$LOCK")" && "$(inode /dev/fd/9)" == "$(inode "$LOCK")" ]]; then
  : # fd 9 is the caller's handle on the lock file; share its lock.
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

# True once the supervisor has written the command's exit status.
wait_for_status() { # rcfile seconds
  local i
  for (( i = 0; i < $2 * 10; i++ )); do
    [[ -s "$1" ]] && return 0
    sleep 0.1
  done
  [[ -s "$1" ]]
}

# Run one undo command (sudo -n pmset ...) inside the locked transaction with
# a time limit. A supervising subshell that keeps fd 9 (the lock) starts the
# command, waits for it and writes its exit status to a file. sudo drops
# extra descriptors before running pmset, so pmset itself never holds the
# lock: the supervisor does, until sudo reports that the command finished.
# On timeout the command gets SIGTERM (sudo relays it to pmset and waits for
# it), then KILL_GRACE_SECONDS. A command that is still running after that is
# never SIGKILLed: killing sudo would orphan a root pmset that could change
# power state later, outside any transaction. Instead the supervisor keeps
# waiting and so keeps the lock, this run returns 125 with command_alive=1,
# and the pid is logged for manual intervention. The caller must then end the
# transaction (stop_transaction): no later undo command may run beside a live
# one, and the journal stays as it was. Every later app start and backstop run
# is refused as "lock held" until that command ends.
# Each call gets its own status files, so a status can never be read as
# another command's. The supervisor's stdio is detached so a caller capturing
# this script's output gets EOF when the script exits, not when the command
# does.
bounded_calls=0
command_alive=0
run_bounded() { # command args...
  local cpid rc pidfile rcfile supervisor
  bounded_calls=$((bounded_calls + 1))
  pidfile="$APP_SUPPORT/.backstop.$$.$bounded_calls.pid"
  rcfile="$APP_SUPPORT/.backstop.$$.$bounded_calls.rc"
  if (( bounded_calls == 1 )); then
    # Status files left by an earlier run that had to fail closed. Their
    # supervisor held the lock while it lived, so they are stale by now.
    rm -f "$APP_SUPPORT"/.backstop.*.pid "$APP_SUPPORT"/.backstop.*.rc
  fi
  (
    "$@" </dev/null >/dev/null 2>&1 &
    cpid=$!
    echo "$cpid" > "$pidfile"
    rc=0
    wait "$cpid" || rc=$?
    echo "$rc" > "$rcfile"
  ) </dev/null >/dev/null 2>&1 &
  supervisor=$!
  if ! wait_for_status "$rcfile" "$COMMAND_TIMEOUT_SECONDS"; then
    cpid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$cpid" ]]; then
      kill -TERM "$cpid" 2>/dev/null || true
    fi
    if ! wait_for_status "$rcfile" "$KILL_GRACE_SECONDS"; then
      log error "'$*' (pid ${cpid:-?}) did not finish within ${COMMAND_TIMEOUT_SECONDS}s and did not stop on SIGTERM. It is not killed, because that could leave a root pmset running outside the transaction. It keeps the recovery lock until it ends, so Insomnia cannot start and recovery cannot run until then; stop it by hand (sudo kill ${cpid:-<pid>}) and the next run will retry"
      command_alive=1
      return 125
    fi
    log error "'$*' did not finish within ${COMMAND_TIMEOUT_SECONDS}s; terminated with SIGTERM (pid ${cpid:-?})"
    wait "$supervisor" 2>/dev/null || true
    rm -f "$pidfile" "$rcfile"
    return 124
  fi
  rc="$(cat "$rcfile")"
  wait "$supervisor" 2>/dev/null || true
  rm -f "$pidfile" "$rcfile"
  return "$rc"
}

# Run one read (pmset -g batt, notifyutil -g) with the undo commands' time
# limit and put its stdout in the variable named by $1. A read changes
# nothing, so unlike an undo command it has no reason to hold the recovery
# lock: its supervisor closes fd 9 before starting it, so neither holds the
# lock and a read that hangs can only fail itself, never a later run or the
# app. For the same reason a read that ignores SIGTERM gets SIGKILL: it runs
# unprivileged and has nothing to leave half done. This run never waits for
# it past that. Returns the read's exit status, or 124 when it was stopped.
run_read() { # varname command args...
  local name="$1" pidfile rcfile outfile cpid rc supervisor
  shift
  bounded_calls=$((bounded_calls + 1))
  pidfile="$APP_SUPPORT/.backstop.$$.$bounded_calls.pid"
  rcfile="$APP_SUPPORT/.backstop.$$.$bounded_calls.rc"
  outfile="$APP_SUPPORT/.backstop.$$.$bounded_calls.out"
  if (( bounded_calls == 1 )); then
    rm -f "$APP_SUPPORT"/.backstop.*.pid "$APP_SUPPORT"/.backstop.*.rc "$APP_SUPPORT"/.backstop.*.out
  fi
  (
    "$@" </dev/null >"$outfile" 2>/dev/null &
    cpid=$!
    echo "$cpid" > "$pidfile"
    rc=0
    wait "$cpid" || rc=$?
    echo "$rc" > "$rcfile"
  ) 9>&- </dev/null >/dev/null 2>&1 &
  supervisor=$!
  if wait_for_status "$rcfile" "$COMMAND_TIMEOUT_SECONDS"; then
    rc="$(cat "$rcfile")"
  else
    cpid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$cpid" ]]; then kill -TERM "$cpid" 2>/dev/null || true; fi
    if wait_for_status "$rcfile" "$KILL_GRACE_SECONDS"; then
      log error "'$*' did not finish within ${COMMAND_TIMEOUT_SECONDS}s; terminated with SIGTERM (pid ${cpid:-?})"
    else
      if [[ -n "$cpid" ]]; then kill -KILL "$cpid" 2>/dev/null || true; fi
      log error "'$*' did not finish within ${COMMAND_TIMEOUT_SECONDS}s and ignored SIGTERM; sent SIGKILL (pid ${cpid:-?}). A read holds no lock, so nothing waits for it"
      wait_for_status "$rcfile" "$KILL_GRACE_SECONDS" || true
    fi
    rc=124
  fi
  # A supervisor that wrote a status is done; one whose read survived even
  # SIGKILL is left behind without the lock.
  if [[ -s "$rcfile" ]]; then wait "$supervisor" 2>/dev/null || true; fi
  printf -v "$name" '%s' "$(cat "$outfile" 2>/dev/null)"
  rm -f "$pidfile" "$rcfile" "$outfile"
  return "$rc"
}

# End this run right after a timed-out undo command that is still alive:
# nothing else is undone, the journal and session stay exactly as read, and
# the lock stays with the live command's supervisor.
stop_transaction() { # what
  log error "recovery stopped after '$1' (still running); no further undo this run, journal and session kept unchanged until it ends"
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
}

# --- Read the session --------------------------------------------------------
# session_state: none | valid | expired | malformed
session_state=none
ends_at=""
if [[ -f "$SESSION" ]]; then
  session_state=malformed
  ends_at="$(extract "$SESSION" endsAt || true)"
  if [[ -n "$ends_at" ]]; then
    # Store.swift writes ISO 8601 UTC without fractional seconds.
    ends_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ends_at" +%s 2>/dev/null || true)"
    now_epoch="$(date -u +%s)"
    if [[ -n "$ends_epoch" ]]; then
      if (( ends_epoch > now_epoch )); then session_state=valid; else session_state=expired; fi
    fi
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
# or the value is not of the JSON type the app decodes (Int, Bool): a string
# "false" or "30" is rejected here as the app rejects it, so both enforce the
# same rule. plutil -extract raw prints a string and a number alike; the type
# comes from plutil -type.
config_int() { # key default
  local v
  v="$(extract "$CONFIG" "$1" || true)"
  if [[ "$(type_of "$CONFIG" "$1")" == integer && "$v" =~ ^[0-9]+$ ]]; then
    echo "$((10#$v))"
  else
    echo "$2"
  fi
}
config_bool() { # key default
  local v
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
# InternalBattery line is a desktop: no battery rule. A pmset that fails
# cannot tell a desktop from a laptop, so with the floor on it ends.
battery_reason=""
battery_cutoff() {
  local out="" rc=0 floor percent source line
  local source_re="Now drawing from '([^']*)'" percent_re='[[:space:]]([0-9]+)%;'
  battery_reason=""
  floor="$(config_int endFloor 10)"
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
  [[ -n "$line" ]] || return 1
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
  if ! app_alive; then
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

# --- Read the journal --------------------------------------------------------
# journal_state: missing | malformed | clean | dirty
if [[ ! -e "$STATE" ]]; then
  journal_state=missing
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
frozen_count=0; legacy_count=0
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
  if [[ "$sleep_held" == true || "$low_power" == true || "$docker_frozen" == true ]] \
     || (( has_audio == 1 || has_display == 1 || has_keyboard == 1 || frozen_count > 0 || legacy_count > 0 )); then
    journal_state=dirty
  fi
fi

case "$session_state" in
  none)      session_note="no session" ;;
  valid)     if [[ -n "$cutoff" ]]; then
               session_note="session ended early, $cutoff (endsAt=$ends_at)"
             else
               session_note="forced end of session (endsAt=$ends_at)"
             fi ;;
  expired)   session_note="session expired (endsAt=$ends_at)" ;;
  malformed) session_note="session.json unreadable" ;;
esac

if [[ "$journal_state" != dirty ]]; then
  # Nothing journaled: nothing to undo, and nothing privileged runs.
  if [[ "$session_state" == malformed ]]; then
    log error "$session_note; journal is clean but session.json is kept as evidence. Open Insomnia or remove it by hand"
    exit 1
  fi
  if [[ "$session_state" != none ]]; then
    if [[ "$journal_state" == missing ]]; then
      log warn "$session_note; no journal on disk, nothing recorded to undo"
    else
      log info "$session_note; journal already clean"
    fi
    rm -f "$SESSION"
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
kept_frozen=""
kept_frozen_count=0
keep_entry() { # index
  local entry
  entry="$(extract_json "$STATE" "frozenProcesses.$1")"
  if [[ -n "$kept_frozen" ]]; then kept_frozen="$kept_frozen,$entry"; else kept_frozen="$entry"; fi
  kept_frozen_count=$((kept_frozen_count + 1))
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
  p_epoch="$(date -j -u -f '%a %b %d %H:%M:%S %Y' "$w $mon $day $time $year" +%s 2>/dev/null || true)"
  [[ -n "$p_epoch" ]] && [[ "$uid" =~ ^[0-9]+$ ]] || return 0
  p_stat="$stat"; p_uid="$uid"
  observation=seen
}
if (( frozen_count > 0 )); then
  boot_now="$("$SYSCTL" -n kern.bootsessionuuid 2>/dev/null || true)"
  uid_now="$(id -u)"
  i=0
  while (( i < frozen_count )); do
    pid="$(extract "$STATE" "frozenProcesses.$i.pid" || true)"
    started="$(extract "$STATE" "frozenProcesses.$i.startedAt" || true)"
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
fi

if (( legacy_count > 0 )); then
  legacy_json="$(extract_json "$STATE" frozenPids || true)"
  log error "legacy frozenPids $legacy_json have no identity; not signaled and not cleared here, the app must resolve them"
  failures+=("legacy frozenPids $legacy_json were not resumed (identity unknown; only the app resolves these)")
fi

new_docker="$docker_frozen"
if [[ "$docker_frozen" == true ]] && (( kept_frozen_count == 0 && legacy_count == 0 )); then
  new_docker=false; changed=1
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
  cp "$STATE" "$tmp" || publish_ok=0
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
  if (( publish_ok == 1 )); then
    # plutil keeps JSON files as JSON; make sure the result is still one.
    [[ "$("$PLUTIL" -convert json -o - "$tmp" 2>/dev/null | head -c 1)" == "{" ]] || publish_ok=0
    [[ "$(head -c 1 "$tmp")" == "{" ]] || publish_ok=0
  fi
  if (( publish_ok == 1 )); then
    mv -f "$tmp" "$STATE" || publish_ok=0
  fi
  if (( publish_ok == 0 )); then
    rm -f "$tmp"
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

if [[ "$session_state" == malformed ]]; then
  log error "journal cleared, but session.json is unreadable and kept as evidence. Open Insomnia or remove it by hand"
  exit 1
fi
rm -f "$SESSION"
log info "journal cleared"
exit 0
