#!/bin/bash
# Reverse install.sh. Quits the app, takes the recovery lock, runs the current
# backstop with --force under that same lock (the checkout's copy, else the
# one sealed in the installed bundle, else the writable copy older installs
# left in Application Support), verifies for itself that the journal is
# clean, and only then removes the LaunchAgent, the sudoers rule, the app
# bundle (backstop.sh included), and the journal. Keeps config.json and the
# logs unless --purge. Everything after the quit happens while this process holds
# APP_SUPPORT/.recovery.lock, so neither a queued periodic backstop nor a
# relaunched app can republish the journal while it is being removed.
#
# If anything Insomnia changed is still journaled, nothing is removed: the
# LaunchAgent keeps retrying every minute, the sudoers rule keeps pmset
# undoable, and state.json keeps the evidence. The message says what to do.
#
# Deletion is by exact owned file, never by directory tree: --purge removes
# the files Insomnia writes (see Paths.swift) and then rmdir's its own
# directories only if they are empty. The lock file is never unlinked, so
# --purge leaves APP_SUPPORT/.recovery.lock (and therefore APP_SUPPORT).
#
# Honours INSOMNIA_HOME with the same layout as the app (see Paths.swift).
set -euo pipefail

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -h|--help) echo "usage: $0 [--purge]"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fixed tool paths: never taken from PATH or the environment. Tests patch
# these lines in a private copy of the script.
PGREP=/usr/bin/pgrep
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
LOCKF=/usr/bin/lockf
LOCK_TIMEOUT_SECONDS=10
# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=10
APP="$HOME/Applications/Insomnia.app"
SUDOERS=/etc/sudoers.d/insomnia

if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  APP_SUPPORT="$INSOMNIA_HOME"
  LOG_DIR="$INSOMNIA_HOME/Logs"
  LAUNCH_AGENTS="$INSOMNIA_HOME/LaunchAgents"
  OWN_LAUNCH_AGENTS_DIR=1
else
  APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
  LOG_DIR="$HOME/Library/Logs/Insomnia"
  LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
  OWN_LAUNCH_AGENTS_DIR=0
fi
LABEL="com.insomnia.backstop"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
SESSION="$APP_SUPPORT/session.json"
STATE="$APP_SUPPORT/state.json"
LOCK="$APP_SUPPORT/.recovery.lock"
UID_NUM="$(id -u)"

step() { printf '\n==> %s\n' "$*"; }

# Fail closed on paths that are not the exact things install.sh created.
case "$APP_SUPPORT" in /*) ;; *) echo "refusing: app support path is not absolute: $APP_SUPPORT" >&2; exit 1 ;; esac
[[ "$(basename "$APP")" == "Insomnia.app" ]] || { echo "refusing: $APP is not an Insomnia.app bundle path" >&2; exit 1; }

extract() { # file keypath (raw scalar; non-zero if missing)
  "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null
}
extract_json() { # file keypath
  "$PLUTIL" -extract "$2" json -o - "$1" 2>/dev/null
}
type_of() { # file keypath -> bool|integer|float|string|array|dictionary|(any); empty if absent
  "$PLUTIL" -type "$2" -o - "$1" 2>/dev/null || true
}

# Shape check, same rules as backstop.sh: a JSON object whose known keys have
# the types RuntimeState.swift writes; null counts as absent.
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

# Independent check of the journal: prints one line per unresolved item.
# Trusts nothing about the backstop that just ran (it may be an older copy).
journal_problems() {
  local key value shape
  if [[ -e "$SESSION" ]]; then
    echo "session.json is still present"
  fi
  [[ -e "$STATE" ]] || return 0
  if ! "$PLUTIL" -convert json -o /dev/null "$STATE" >/dev/null 2>&1; then
    echo "state.json is unreadable or malformed"
    return 0
  fi
  shape="$(journal_shape_problems "$STATE")"
  if [[ -n "$shape" ]]; then
    echo "state.json is malformed (unexpected shape):"
    echo "$shape"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen; do
    if [[ "$(extract "$STATE" "$key" || true)" == "true" ]]; then
      echo "$key is still true"
    fi
  done
  value="$(extract_json "$STATE" frozenProcesses || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "frozen processes are still journaled: $value"
  fi
  value="$(extract_json "$STATE" frozenPids || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "legacy frozen pids (no identity; the backstop never signals or clears these, only the app does): $value"
  fi
  if extract "$STATE" savedOutputVolume >/dev/null || extract "$STATE" savedMuted >/dev/null; then
    echo "saved audio settings (volume/mute) are not restored; only the app can do that"
  fi
  if extract "$STATE" savedDisplayBrightness >/dev/null; then
    echo "saved display brightness is not restored; only the app can do that"
  fi
  if extract "$STATE" savedKeyboardBrightness >/dev/null; then
    echo "saved keyboard backlight is not restored; only the app can do that"
  fi
}

abort_incomplete() { # backstop exit status, problem lines...
  local rc="$1"; shift
  cat >&2 <<MSG

Uninstall stopped BEFORE removing anything: Insomnia's changes are not fully
undone (backstop exit status $rc). Still journaled in $STATE:
MSG
  local p
  for p in "$@"; do printf '  - %s\n' "$p" >&2; done
  cat >&2 <<MSG

Nothing was removed on purpose: the LaunchAgent keeps retrying every minute,
the sudoers rule keeps pmset undoable, and the journal keeps the evidence.

What to do, then rerun this script:
  - Saved audio (volume/mute), display brightness or keyboard backlight:
    open Insomnia.app; it restores them from the journal at launch. If the
    display is dark, press the brightness-up key first.
  - pmset failures (sleep / Low Power Mode): check $SUDOERS
    (rerun scripts/install.sh to reinstall it), or run
    'sudo pmset -a disablesleep 0' / 'sudo pmset -b lowpowermode 0' yourself.
  - Frozen or legacy pids: open Insomnia.app to resolve them, or inspect each
    with 'ps -o pid,stat,lstart,command -p <pid>' and 'kill -CONT <pid>' it
    yourself if it is a process you recognise.
  - Unreadable journal or session file: open Insomnia.app, or repair the file.
  - Log: $LOG_DIR/insomnia.log
MSG
  exit 1
}

app_running() {
  "$PGREP" -x Insomnia >/dev/null 2>&1
}

# 1. Quit the app --------------------------------------------------------------
# Ask politely and wait. The app refuses to quit while it has unresolved
# recovery work, and that refusal must stand: no pkill, no force.
step "Quitting Insomnia"
if app_running; then
  "$OSASCRIPT" -e 'tell application id "com.kgarg.insomnia" to quit' >/dev/null 2>&1 || true
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    app_running || break
    sleep 1
  done
  if app_running; then
    echo "Insomnia is still running (it may be refusing to quit until its own recovery finishes)." >&2
    echo "Let it finish or quit it from its menu, then rerun. Nothing was removed." >&2
    exit 1
  fi
fi

# 2. Take the recovery lock and keep it to the end ---------------------------
step "Taking the recovery lock"
mkdir -p "$APP_SUPPORT"
exec 9<>"$LOCK"
lock_rc=0
"$LOCKF" -t "$LOCK_TIMEOUT_SECONDS" 9 2>/dev/null || lock_rc=$?
if (( lock_rc != 0 )); then
  echo "The recovery lock $LOCK is held by another process (a running backstop or the app)." >&2
  echo "Wait a minute and rerun. Nothing was removed." >&2
  exit 75
fi
if app_running; then
  echo "Insomnia started again; quit it and rerun. Nothing was removed." >&2
  exit 1
fi

# 3. Undo everything via the current backstop ---------------------------------
# The backstop inherits fd 9 and shares this lock instead of waiting on it.
# Newest first: the checkout's script, then the copy install.sh sealed into
# the bundle, then the writable copy installs before that layout left in
# $APP_SUPPORT.
step "Restoring the machine via backstop --force"
if [[ -f "$ROOT/scripts/backstop.sh" ]]; then
  BACKSTOP="$ROOT/scripts/backstop.sh"
elif [[ -f "$APP/Contents/Resources/backstop.sh" ]]; then
  BACKSTOP="$APP/Contents/Resources/backstop.sh"
elif [[ -f "$APP_SUPPORT/backstop.sh" ]]; then
  BACKSTOP="$APP_SUPPORT/backstop.sh"
else
  echo "no backstop.sh found in $ROOT/scripts, $APP/Contents/Resources or $APP_SUPPORT; nothing was removed" >&2
  exit 1
fi
echo "using $BACKSTOP"
recovery_rc=0
/bin/bash "$BACKSTOP" --force || recovery_rc=$?

# 4. Verify independently ------------------------------------------------------
step "Verifying the recovery journal"
problems=()
while IFS= read -r line; do
  [[ -n "$line" ]] && problems+=("$line")
done < <(journal_problems)
if (( recovery_rc != 0 )) && (( ${#problems[@]} == 0 )); then
  problems+=("backstop exited $recovery_rc; see $LOG_DIR/insomnia.log")
fi
if (( ${#problems[@]} > 0 )); then
  abort_incomplete "$recovery_rc" "${problems[@]}"
fi
echo "journal clean"
if app_running; then
  echo "Insomnia started again; quit it and rerun. Nothing was removed." >&2
  exit 1
fi

# 5. Remove, still under the lock -------------------------------------------
# bootout first: it stops a running instance of the agent and drops queued
# runs, so nothing is left to reopen the journal once the files go. Then
# prove the job is really gone; if launchd still lists it, stop here with
# every recovery file intact.
step "Removing LaunchAgent"
bootout_rc=0
"$LAUNCHCTL" bootout "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 || bootout_rc=$?
# `launchctl print` exits 113 only when the service is not loaded; 0 means
# still loaded and anything else means launchd could not be asked.
print_rc=0
"$LAUNCHCTL" print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || print_rc=$?
if (( print_rc != 113 )); then
  if (( print_rc == 0 )); then
    echo "launchctl bootout exited $bootout_rc and $LABEL is still loaded in gui/$UID_NUM." >&2
  else
    echo "launchctl bootout exited $bootout_rc and 'launchctl print' exited $print_rc; cannot tell whether $LABEL is still loaded." >&2
  fi
  echo "Nothing was removed. Run 'launchctl bootout gui/$UID_NUM $PLIST' yourself, then rerun." >&2
  exit 1
fi
rm -f "$PLIST"

step "Removing $SUDOERS (requires your password)"
if [[ -e "$SUDOERS" ]] || "$SUDO" test -e "$SUDOERS"; then
  "$SUDO" rm -f "$SUDOERS"
fi

step "Removing app bundle"
rm -rf "$APP"

# $APP_SUPPORT/backstop.sh below is the writable copy of older installs; the
# current one went with the bundle.
if (( PURGE == 1 )); then
  step "Purging Insomnia's files in $APP_SUPPORT and $LOG_DIR"
  rm -f "$SESSION" "$STATE" "$APP_SUPPORT/config.json" "$APP_SUPPORT/backstop.sh" \
        "$LOG_DIR/insomnia.log" "$LOG_DIR/handoffs.log"
  # The lock file itself is kept, even on purge: this process still holds
  # it, and anything that opened it a moment ago (a queued agent run, an app
  # launched after the check above) waits on this inode. Unlinking it would
  # let the next opener create a second lock nobody else sees. A leftover
  # empty lock file and its directory are the accepted cost.
  rmdir "$LOG_DIR" 2>/dev/null || true
  (( OWN_LAUNCH_AGENTS_DIR == 1 )) && { rmdir "$LAUNCH_AGENTS" 2>/dev/null || true; }
  echo "Kept $LOCK (the recovery lock is never unlinked; delete $APP_SUPPORT by hand if you want it gone)."
  [[ -d "$LOG_DIR" ]] && echo "Kept $LOG_DIR: it still holds files Insomnia did not create."
else
  rm -f "$APP_SUPPORT/backstop.sh" "$SESSION" "$STATE"
  echo "Kept $APP_SUPPORT/config.json and $LOG_DIR (use --purge to remove)."
fi

echo "Done."
