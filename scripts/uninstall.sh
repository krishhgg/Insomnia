#!/bin/bash
# Reverse install.sh. Quits the app, takes the recovery lock, runs the current
# backstop with --force under that same lock, verifies for itself that the
# journal is clean, and only then removes the LaunchAgent, the sudoers rule,
# the app bundle, and the journal. Keeps config.json and the logs unless
# --purge. Everything after the quit happens while this process holds
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
PS=/bin/ps
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
LOCKF=/usr/bin/lockf
DEFAULTS=/usr/bin/defaults
LOCK_TIMEOUT_SECONDS=10
# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=10
# Longest one external call made by this script itself (pgrep, ps,
# defaults, launchctl) may run before it is stopped with SIGTERM, then SIGKILL. These
# are unprivileged and never touch the journal, and they run with the lock
# descriptor closed, so a call that hangs is reported and can never keep the
# recovery lock. backstop.sh bounds its own commands; the two sudo calls
# prompt for a password and are left to sudo's own prompt timeout.
CALL_TIMEOUT_SECONDS=30
APP="$HOME/Applications/Insomnia.app"
SUDOERS=/etc/sudoers.d/insomnia
BUNDLE_ID=com.kgarg.insomnia

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
CONFIG="$APP_SUPPORT/config.json"
# The agent list the app ships with (Config.defaultAgentList in
# Sources/Insomnia/Model/Config.swift; a test keeps this copy in step). An
# older build may have set NSAppSleepDisabled for any of these, even one the
# user later took off the list in config.json, so the check below covers
# both lists.
DEFAULT_AGENTS=(
  com.t3tools.t3code              # T3 Code (Nightly)
  com.t3tools.t3code.reasoning    # T3 Code (Reasoning)
  com.conductor.app               # Conductor
  com.apple.Terminal              # Terminal
  com.googlecode.iterm2           # iTerm2
  com.mitchellh.ghostty           # Ghostty
  dev.warp.Warp-Stable            # Warp
  com.google.Chrome               # Google Chrome
  org.chromium.Chromium           # Chromium
  company.thebrowser.Browser      # Arc
  com.docker.docker               # Docker Desktop
  com.microsoft.VSCode            # Visual Studio Code
  com.todesktop.230313mzl4w4u92   # Cursor
  dev.zed.Zed                     # Zed
  com.google.antigravity          # Antigravity
  com.anthropic.claudefordesktop  # Claude
  com.openai.codex                # ChatGPT (hosts Codex and computer use)
  io.tailscale.ipn.macsys         # Tailscale
  ai.elementlabs.lmstudio         # LM Studio
  com.electron.ollama             # Ollama
)
LOCK="$APP_SUPPORT/.recovery.lock"
UID_NUM="$(id -u)"

step() { printf '\n==> %s\n' "$*"; }

# Scratch space for bounded(): this run's own directory, emptied on exit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/insomnia-uninstall.XXXXXX")"
trap 'rm -f "$WORK"/call.* 2>/dev/null; rmdir "$WORK" 2>/dev/null || true' EXIT

# Run one external call with a time limit. Its combined output is left in
# BOUNDED_OUTPUT (trailing newline removed) and its exit status returned, or
# 124 when it did not finish within CALL_TIMEOUT_SECONDS: it is then sent
# SIGTERM, and SIGKILL a second later if it is still there. A supervising
# subshell waits for the call and writes its status to a file; both run with
# fd 9 (the recovery lock) closed, so nothing left behind by a stuck call
# holds the lock once this script exits. Called directly, not in $(...), so
# the counter that names each call's files stays unique.
bounded_calls=0
BOUNDED_OUTPUT=""
bounded() { # command args...
  local base supervisor cpid rc i
  bounded_calls=$((bounded_calls + 1))
  base="$WORK/call.$bounded_calls"
  BOUNDED_OUTPUT=""
  (
    "$@" </dev/null >"$base.out" 2>&1 &
    echo "$!" > "$base.pid"
    rc=0
    wait "$!" || rc=$?
    echo "$rc" > "$base.rc"
  ) </dev/null >/dev/null 2>&1 9>&- &
  supervisor=$!
  # Polled every 10 ms: a check makes some 30 calls, so a coarser poll
  # would add seconds to an uninstall that is otherwise instant.
  for (( i = 0; i < CALL_TIMEOUT_SECONDS * 100; i++ )); do
    if [[ -s "$base.rc" ]]; then break; fi
    sleep 0.01
  done
  if [[ ! -s "$base.rc" ]]; then
    cpid="$(cat "$base.pid" 2>/dev/null || true)"
    if [[ -n "$cpid" ]]; then kill -TERM "$cpid" 2>/dev/null || true; fi
    for (( i = 0; i < 10; i++ )); do
      if [[ -s "$base.rc" ]]; then break; fi
      sleep 0.1
    done
    if [[ ! -s "$base.rc" && -n "$cpid" ]]; then
      kill -KILL "$cpid" 2>/dev/null || true
      for (( i = 0; i < 10; i++ )); do
        if [[ -s "$base.rc" ]]; then break; fi
        sleep 0.1
      done
    fi
    # Reap the supervisor once it has written the status; one that is
    # still waiting on an unkillable call is left behind without the lock.
    if [[ -s "$base.rc" ]]; then wait "$supervisor" 2>/dev/null || true; fi
    return 124
  fi
  read -r rc < "$base.rc"
  wait "$supervisor" 2>/dev/null || true
  IFS= read -r -d '' BOUNDED_OUTPUT < "$base.out" || true
  BOUNDED_OUTPUT="${BOUNDED_OUTPUT%$'\n'}"
  return "$rc"
}

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
  value="$(extract_json "$STATE" appNapOverrides || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "App Nap settings (NSAppSleepDisabled) are not put back: $value"
  fi
}

# Agent apps whose NSAppSleepDisabled is YES with no journal entry: set by a
# build that did not record the previous value, or by the user. Nothing is
# known to put back, so nothing is changed; the exact command to undo each
# one is printed instead, shell-quoted, since the list editor takes any
# string. Checked: the shipped list plus config.json's agentList. Only a
# read that says "does not exist" counts as clear; a read that fails any
# other way is reported, not counted. Each read is bounded; one that does
# not answer in time (cfprefsd stuck) ends the check, since the rest would
# wait the same way, and uninstall goes on.
list_unrecorded_app_nap() {
  local ids="" i=0 id value rc found=0 checked=0 unreadable=0 stuck="" skipped=0
  for id in "${DEFAULT_AGENTS[@]}"; do ids="$ids$id"$'\n'; done
  if [[ -f "$CONFIG" ]]; then
    while id="$(extract "$CONFIG" "agentList.$i")"; do
      i=$((i + 1))
      ids="$ids$id"$'\n'
    done
  fi
  while IFS= read -r id; do
    [[ -n "$id" && "$id" != -* ]] || continue
    if [[ -n "$stuck" ]]; then skipped=$((skipped + 1)); continue; fi
    rc=0
    bounded "$DEFAULTS" read "$id" NSAppSleepDisabled || rc=$?
    value="$BOUNDED_OUTPUT"
    if (( rc == 124 )); then
      stuck="$id"
      unreadable=$((unreadable + 1))
      printf 'defaults read did not answer within %ss for %s; check it yourself with: defaults read %q NSAppSleepDisabled\n' "$CALL_TIMEOUT_SECONDS" "$id" "$id"
      continue
    fi
    if (( rc != 0 )); then
      if [[ "$value" == *"does not exist"* ]]; then
        checked=$((checked + 1))
      else
        unreadable=$((unreadable + 1))
        printf 'could not read NSAppSleepDisabled for %s; check it yourself with: defaults read %q NSAppSleepDisabled\n' "$id" "$id"
      fi
      continue
    fi
    checked=$((checked + 1))
    [[ "$value" == 1 ]] || continue
    if (( found == 0 )); then
      found=1
      cat <<MSG
NSAppSleepDisabled is YES for these agent apps and Insomnia has no record of
what it was before (an older build set it without recording). They are left
as they are. To turn App Nap back on for one, run:
MSG
    fi
    printf '  defaults delete %q NSAppSleepDisabled\n' "$id"
  done < <(printf '%s' "$ids" | awk '!seen[$0]++')
  if (( found == 0 )); then
    echo "none of the $checked agent apps checked has NSAppSleepDisabled set"
  fi
  if (( unreadable > 0 )); then
    echo "$unreadable could not be read; see above"
  fi
  if (( skipped > 0 )); then
    echo "stopped after $stuck did not answer; $skipped more agent apps were not checked"
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
  - App Nap (NSAppSleepDisabled): the recovery agent retries 'defaults write'
    or 'defaults delete' every minute, and Insomnia.app restores them at
    launch. If 'defaults' keeps failing, see the log.
  - Unreadable journal or session file: open Insomnia.app, or repair the file.
  - Log: $LOG_DIR/insomnia.log
MSG
  exit 1
}

# Running copies of this app. `pgrep -x Insomnia` matches every process of
# this user named Insomnia, and the Insomnia API client's executable has
# that name too, so each pid is checked by its executable path (`ps -o
# comm=`, the full path for an app LaunchServices launched): it is this app
# when the path is the installed bundle's binary or lies in a bundle whose
# Info.plist declares $BUNDLE_ID. A process whose bundle id reads as
# something else is another app and is left alone. One whose identity
# cannot be read (no path, a path outside any bundle, an Info.plist that
# does not parse) might be this app, so it counts as this app until it
# exits: it is never signalled, but nothing is replaced or removed while
# it runs.
APP_FOUND=()     # "pid N (path)" per running copy of this app
UNVERIFIED=()    # "pid N (path; why)" per process that could not be told apart from it
OTHER_FOUND=()   # "pid N (path, bundle id X)" per process proven to be another app
BLOCKING=()      # APP_FOUND then UNVERIFIED: what must be gone before files are touched
find_insomnia() {
  local pid pids rc exe bundle id desc
  APP_FOUND=(); UNVERIFIED=(); OTHER_FOUND=(); BLOCKING=()
  # A pgrep that does not answer in time counts as "running": fail closed.
  rc=0
  bounded "$PGREP" -x -u "$UID_NUM" Insomnia || rc=$?
  pids="$BOUNDED_OUTPUT"
  if (( rc == 124 )); then
    echo "pgrep did not answer within ${CALL_TIMEOUT_SECONDS}s; treating Insomnia as running." >&2
    UNVERIFIED+=("pgrep did not answer within ${CALL_TIMEOUT_SECONDS}s")
    BLOCKING+=("pgrep did not answer within ${CALL_TIMEOUT_SECONDS}s")
    return 0
  fi
  (( rc == 0 )) || pids=""
  for pid in $pids; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    rc=0
    bounded "$PS" -o comm= -p "$pid" || rc=$?
    exe=""
    (( rc == 0 )) && exe="$BOUNDED_OUTPUT"
    id=""
    desc="${exe:-executable path unknown}"   # what the messages say; gains the reason when unverified
    if [[ "$exe" == /*/Contents/MacOS/* ]]; then
      bundle="${exe%/Contents/MacOS/*}"
      id="$("$PLUTIL" -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)"
      [[ -n "$id" ]] || desc="$exe; no bundle id readable from $bundle/Contents/Info.plist"
    elif [[ -n "$exe" ]]; then
      desc="$exe; not inside an app bundle, so no bundle id to read"
    fi
    if [[ "$exe" == "$APP/Contents/MacOS/Insomnia" || "$id" == "$BUNDLE_ID" ]]; then
      APP_FOUND+=("pid $pid ($exe)")
      BLOCKING+=("pid $pid ($exe)")
    elif [[ -n "$id" ]]; then
      OTHER_FOUND+=("pid $pid ($exe, bundle id $id)")
    else
      UNVERIFIED+=("pid $pid ($desc)")
      BLOCKING+=("pid $pid ($desc)")
    fi
  done
}
app_running() {
  find_insomnia
  (( ${#BLOCKING[@]} > 0 ))
}
# Comma-separated list, for messages. Call only with at least one argument:
# bash 3.2 (/bin/bash) treats an empty array as unbound under `set -u`.
list() { local IFS=', '; echo "$*"; }
report_others() {
  (( ${#OTHER_FOUND[@]} > 0 )) || return 0
  echo "Ignoring ${#OTHER_FOUND[@]} process(es) named Insomnia that are not this app: $(list "${OTHER_FOUND[@]}")."
}
report_unverified() {
  (( ${#UNVERIFIED[@]} > 0 )) || return 0
  echo "Cannot tell whether ${#UNVERIFIED[@]} process(es) named Insomnia are this app, so they count as it until they exit: $(list "${UNVERIFIED[@]}")."
}

# 1. Quit the app --------------------------------------------------------------
# Ask politely and wait. The app refuses to quit while it has unresolved
# recovery work, and that refusal must stand: no pkill, no force. This app
# counts, and so does a process named Insomnia that cannot be told apart
# from it (find_insomnia); one proven to be another app is reported and
# left alone.
step "Quitting Insomnia"
if app_running; then
  report_others
  report_unverified
  # The quit goes only to a copy identified as this app. An unverified
  # process is waited for, but its presence alone never asks the real app
  # to quit.
  if (( ${#APP_FOUND[@]} > 0 )); then
    echo "Insomnia is running ($(list "${APP_FOUND[@]}")); asking it to quit."
    "$OSASCRIPT" -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    app_running || break
    sleep 1
  done
  if app_running; then
    echo "Insomnia is still running (it may be refusing to quit until its own recovery finishes, or a process named Insomnia could not be identified): $(list "${BLOCKING[@]}")." >&2
    echo "Let it finish or quit it from its menu, quit any process listed as unverified, then rerun. Nothing was removed." >&2
    exit 1
  fi
else
  report_others
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
  echo "Insomnia started again ($(list "${BLOCKING[@]}")); quit it and rerun. Nothing was removed." >&2
  exit 1
fi

# 3. Undo everything via the current backstop ---------------------------------
# The backstop inherits fd 9 and shares this lock instead of waiting on it.
step "Restoring the machine via backstop --force"
if [[ -f "$ROOT/scripts/backstop.sh" ]]; then
  BACKSTOP="$ROOT/scripts/backstop.sh"
elif [[ -f "$APP_SUPPORT/backstop.sh" ]]; then
  BACKSTOP="$APP_SUPPORT/backstop.sh"
else
  echo "no backstop.sh found in $ROOT/scripts or $APP_SUPPORT; nothing was removed" >&2
  exit 1
fi
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
  echo "Insomnia started again ($(list "${BLOCKING[@]}")); quit it and rerun. Nothing was removed." >&2
  exit 1
fi

step "Checking App Nap settings of agent apps"
list_unrecorded_app_nap

# 5. Remove, still under the lock -------------------------------------------
# bootout first: it stops a running instance of the agent and drops queued
# runs, so nothing is left to reopen the journal once the files go. Then
# prove the job is really gone; if launchd still lists it, stop here with
# every recovery file intact.
step "Removing LaunchAgent"
bootout_rc=0
bounded "$LAUNCHCTL" bootout "gui/$UID_NUM" "$PLIST" || bootout_rc=$?
# `launchctl print` exits 113 only when the service is not loaded; 0 means
# still loaded and anything else means launchd could not be asked. 124 from
# either call means it did not answer within CALL_TIMEOUT_SECONDS.
print_rc=0
bounded "$LAUNCHCTL" print "gui/$UID_NUM/$LABEL" || print_rc=$?
if (( print_rc != 113 )); then
  if (( print_rc == 0 )); then
    echo "launchctl bootout exited $bootout_rc and $LABEL is still loaded in gui/$UID_NUM." >&2
  elif (( print_rc == 124 )); then
    echo "launchctl bootout exited $bootout_rc and 'launchctl print' did not answer within ${CALL_TIMEOUT_SECONDS}s; cannot tell whether $LABEL is still loaded." >&2
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
