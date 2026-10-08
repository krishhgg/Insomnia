#!/bin/bash
# Reverse install.sh. Quits the app, takes the recovery lock, runs the current
# backstop with --force under that same lock (from a source checkout: the
# checkout's copy when the installed app declares the interface version it
# speaks, else the app's own: the one sealed in the bundle, else the writable
# copy older installs left in Application Support; from anywhere else, such
# as a release zip: the sealed copy only), verifies for itself that the
# journal is clean, and only then removes the LaunchAgent, the sudoers rule,
# the app bundle (backstop.sh included), and the journal. Keeps config.json
# and the logs unless --purge. Everything after the quit happens while this
# process holds APP_SUPPORT/.recovery.lock, so neither a queued periodic
# backstop nor a relaunched app can republish the journal while it is being
# removed.
#
# If anything Insomnia changed is still journaled, nothing is removed: the
# LaunchAgent keeps retrying every minute, the sudoers rule keeps pmset
# undoable, and state.json keeps the evidence. The message says what to do.
# A brightness the app kept because its private-call guard refused the
# restore on this macOS does not stop the uninstall, since nothing here can
# restore it; state.json is kept, even with --purge, so a later Insomnia
# that can make the call restores it at launch. The app's records about that
# entry and about a restore under its Low Power Mode (displayRestoredUnderLowPower,
# keptDisplayUnderLowPower, keptDisplayUnderLowPowerBoot, keptDisplayReadLit)
# are never undone here and stay or go with state.json; backstop.sh of this
# version gives the record of the kept entry this boot, in a journal it
# publishes before it switches Low Power Mode off. One of the wrong type, a
# number the app cannot decode, a key found twice in one object anywhere in
# the file, or text the check cannot follow makes the journal malformed:
# the same text check as backstop.sh (record_text_problems), which reads
# every object and array, with the escapes in keys decoded, as the app does.
#
# Deletion is by exact owned file, never by directory tree: --purge removes
# the files Insomnia writes (see Paths.swift), the session.json copies the
# app or backstop.sh moved aside and the config.json copies the app moved
# aside (session.json.unreadable-<stamp> and config.json.unreadable-<stamp>,
# only that exact shape), and then rmdir's its own directories only if they
# are empty.
# Only regular files are removed; anything else at one of those paths is
# left with a message. The lock file is never unlinked, so --purge leaves
# APP_SUPPORT/.recovery.lock (and therefore APP_SUPPORT). The bundle trees
# removed are the installed app and install.sh's own leftovers beside it,
# matched by the exact names install.sh gives them, and the agent plist goes
# with the candidate plists install.sh and the app stage it from.
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

# The folder this script is in. backstop.sh is taken from there only when it
# is the scripts/ folder of a source checkout, with Package.swift one level
# up (in_checkout). A release zip's folder is not, and the zip has no
# backstop.sh, so one found beside its uninstall.sh was added after the zip
# was unpacked, for example by another account that created the folder in
# /tmp beforehand. Never the folder above either: a zip unpacked at
# /tmp/Insomnia-<version> would make that /tmp, where any account can create
# scripts/backstop.sh.
# Its parent without dirname, since the fixed tool paths come below.
script_parent="${BASH_SOURCE[0]}"
case "$script_parent" in */*) script_parent="${script_parent%/*}" ;; *) script_parent=. ;; esac
[[ -n "$script_parent" ]] || script_parent=/
SCRIPT_DIR="$(CDPATH="" cd -- "$script_parent" && pwd)"
in_checkout() { [[ "${SCRIPT_DIR##*/}" == scripts && -f "${SCRIPT_DIR%/*}/Package.swift" ]]; }

# Fixed tool paths: never taken from PATH or the environment. Tests patch
# these lines in a private copy of the script.
PGREP=/usr/bin/pgrep
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
CODESIGN=/usr/bin/codesign
LOCKF=/usr/bin/lockf
DEFAULTS=/usr/bin/defaults
KILL=/bin/kill
DATE=/bin/date
MKDIR=/bin/mkdir
RM=/bin/rm
RMDIR=/bin/rmdir
MKTEMP=/usr/bin/mktemp
STAT=/usr/bin/stat
CAT=/bin/cat
HEAD=/usr/bin/head
TR=/usr/bin/tr
AWK=/usr/bin/awk
ID=/usr/bin/id
# sleep is the one tool taken by name: it only paces the polls in bounded()
# and the quit wait and reads nothing, and the tests that make every poll
# slow put their own sleep first in PATH.
LOCK_TIMEOUT_SECONDS=10
# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=10
# Longest one external call made by this script itself (pgrep, defaults,
# launchctl, codesign) may run before it is stopped with SIGTERM, then
# SIGKILL. A call made under the recovery lock keeps the lock until it has
# exited or been stopped, even if this run is killed first (see bounded()).
# backstop.sh bounds its own commands; the two sudo calls
# prompt for a password and are left to sudo's own prompt timeout.
CALL_TIMEOUT_SECONDS=30
APP="$HOME/Applications/Insomnia.app"
SUDOERS=/etc/sudoers.d/insomnia
# The --resume-frozen interface version this checkout's backstop.sh speaks
# (see step 3).
RESUME_FROZEN_VERSION=1

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
# The record backstop.sh writes for a session it ended but could not remove
# (record_end there). The backstop run below removes it with session.json, or
# as stale. One still there when files are removed could not be removed: it
# ends nothing by then, but it is a copy of that session's times, so it is
# removed with session.json, and remove_owned names it if that fails. When
# that record cannot be written either, the end is recorded in state.json
# (endedSession); that key is not something to undo and goes with the file.
# When neither can be written, the same record goes to a new file,
# ended-session.json. and eight letters or digits, beside them or in
# $LOG_DIR (collect_end_records_aside below), removed the same way by both
# modes, before --purge removes $LOG_DIR. When no new file can be created
# either, it goes in the recovery lock file, which both modes empty in
# place and keep (clear_lock_record).
ENDED="$APP_SUPPORT/ended-session.json"
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
UID_NUM="$("$ID" -u)"

step() { printf '\n==> %s\n' "$*"; }

# Scratch space for bounded(): this run's own directory, emptied on exit.
WORK="$("$MKTEMP" -d "${TMPDIR:-/tmp}/insomnia-uninstall.XXXXXX")"
trap '"$RM" -f "$WORK"/call.* 2>/dev/null; "$RMDIR" "$WORK" 2>/dev/null || true' EXIT

# Run one external call with a time limit. Its combined output is left in
# BOUNDED_OUTPUT (trailing newline removed) and its exit status returned, or
# 124 when it did not finish within CALL_TIMEOUT_SECONDS and was stopped, or
# 125 when it is sudo and still running (pid in BOUNDED_PID; this script
# bounds no sudo call). The same helper as install.sh's, which says more.
# supervise() enforces the limit itself, even if this run is killed while it
# waits: SIGTERM once the limit has passed on bash's SECONDS clock, SIGKILL
# one to two seconds later, never SIGKILL for sudo. The supervisor and the call keep fd 9 (the recovery lock) until the
# call has exited, so a launchctl bootout made under the lock cannot unload
# an agent the app confirms after this run is gone.
BOUNDED_OUTPUT=""
BOUNDED_PID=""
# shellcheck disable=SC2034  # BOUNDED_PID is for sudo, and this script bounds none
bounded() { # command args...
  local base supervisor rc deadline
  base="$("$MKTEMP" "$WORK/call.XXXXXX")"
  BOUNDED_OUTPUT=""
  BOUNDED_PID=""
  supervise "$base" "$@" </dev/null >/dev/null 2>&1 &
  supervisor=$!
  if [[ "$1" == "$SUDO" ]]; then
    # The supervisor's limit (at most a second over), then at least two
    # seconds for sudo to stop on SIGTERM.
    deadline=$(( SECONDS + CALL_TIMEOUT_SECONDS + 3 ))
    while [[ ! -s "$base.rc" ]] && (( SECONDS <= deadline )); do
      sleep 0.01
    done
    if [[ ! -s "$base.rc" ]]; then
      BOUNDED_PID="$("$CAT" "$base.pid" 2>/dev/null || true)"
      return 125
    fi
  fi
  # Any other call gets SIGKILL at most two seconds after its SIGTERM, so
  # this wait ends.
  wait "$supervisor" 2>/dev/null || true
  rc=124
  if [[ -s "$base.rc" ]]; then read -r rc < "$base.rc"; fi
  IFS= read -r -d '' BOUNDED_OUTPUT < "$base.out" || true
  BOUNDED_OUTPUT="${BOUNDED_OUTPUT%$'\n'}"
  return "$rc"
}
# The supervising process of one bounded() call; it runs in the background.
# The call is its only job, so `kill %1` signals the call, and the shell
# skips a job it has already reaped: a reused pid is never signalled. The
# status file is written once the call has been reaped.
supervise() { # base command args...
  local base="$1" cpid rc=0 deadline
  shift
  "$@" </dev/null >"$base.out" 2>&1 &
  cpid=$!
  echo "$cpid" > "$base.pid"
  deadline=$(( SECONDS + CALL_TIMEOUT_SECONDS ))
  while kill -0 "$cpid" 2>/dev/null && (( SECONDS <= deadline )); do
    sleep 0.01
  done
  # Past the limit, and the shell has not reaped the call: it is still there.
  if (( SECONDS > deadline )) && [[ -n "$(jobs -rp)" ]]; then
    kill -TERM %1 2>/dev/null || true
    if [[ "$1" != "$SUDO" ]]; then
      deadline=$(( SECONDS + 1 ))
      while [[ -n "$(jobs -rp)" ]] && (( SECONDS <= deadline )); do
        sleep 0.01
      done
      if [[ -n "$(jobs -rp)" ]]; then kill -KILL %1 2>/dev/null || true; fi
    fi
    wait "$cpid" 2>/dev/null || true
    echo 124 > "$base.rc"
    return
  fi
  wait "$cpid" || rc=$?
  echo "$rc" > "$base.rc"
}

# Fail closed on paths that are not the exact things install.sh created.
case "$APP_SUPPORT" in /*) ;; *) echo "refusing: app support path is not absolute: $APP_SUPPORT" >&2; exit 1 ;; esac
[[ "${APP##*/}" == "Insomnia.app" ]] || { echo "refusing: $APP is not an Insomnia.app bundle path" >&2; exit 1; }

extract() { # file keypath (raw scalar; non-zero if missing)
  "$PLUTIL" -extract "$2" raw -o - "$1" 2>/dev/null
}
extract_json() { # file keypath
  "$PLUTIL" -extract "$2" json -o - "$1" 2>/dev/null
}
type_of() { # file keypath -> bool|integer|float|string|array|dictionary|(any); empty if absent
  "$PLUTIL" -type "$2" -o - "$1" 2>/dev/null || true
}

# Prints one line per way the text of state.json $1 would not decode in the
# app, or would read otherwise than plutil reads it, or nothing. Read from
# the text itself, not through plutil, which keeps the last of two copies
# of a key where the app's JSONDecoder keeps the first, turns a number too
# small for a Double, such as 1e-400, into 0.0, and reads 1., .5, +1,
# single quotes, keys without quotes, comments and other JSON5 forms the
# app refuses. The text is read the way the app reads it: every object and
# array, at any depth, key by key and value by value. A key's \u escapes
# are decoded, so "keptDisplayReadL\u0069t" is that key, and a Kelvin sign
# (U+212A), written as such or as \u212A, is read as K, since the app's
# keys match it as K. A string is stepped over to its closing quote, so a
# saved audio name or UID that holds a key, a bracket or a bad number holds
# none of them. Refused:
#   - a key found more than once in one object, since plutil checks and
#     republishes the last copy. Only keys of letters alone are compared;
#     every key the app reads is one.
#   - a string with an escape JSON does not have, such as \x41, which plutil
#     reads as A. In a key, nothing after it is read.
#   - a value that is not a string, object, array, JSON number, true, false
#     or null.
#   - a number where the app reads a Float (the saved and kept display,
#     keyboard and output levels, and each saved output's volume) that a
#     Swift Float cannot hold: above about 3.4028236e38, or not 0 in every
#     digit and so small that it rounds to 0 (below about 7.0065e-46). The
#     range is read from the decimal exponent and the first 9 significant
#     digits, a little stricter than the app (from 3.40282356e38 and up to
#     7.01e-46), where no level lies.
#   - a whole number where the app reads an Int32 (a frozen process's pid
#     and startedAtMicros, a legacy frozen pid) or an Int64 (its startedAt)
#     that the type cannot hold.
#   - text this reader cannot follow: a key without quotes, a comment, a
#     byte order mark other than UTF-8's, or a NUL byte. UTF-16 and UTF-32,
#     which the app reads but never writes, have NUL bytes, and the shell
#     drops them from the text, which would turn such a file into other
#     characters.
# A string, object or array where a number belongs is left to the type
# check, and so is a number such as 1.0 where a whole number belongs, which
# plutil reads as a float. The app reads some of what is refused here: a
# key twice (it takes the first), a bad escape or number under a key it
# does not read, a whole number written as 1.0. The app never writes them,
# so they are refused anyway. Any of these makes the journal malformed, as
# for a wrong type, and nothing is undone.
record_text_problems() { # file
  local LC_ALL=C
  local text rest raw name c token want d vpath vshown kind limit list seen nm n
  local str strict scalar number int esc kelvin hex lost
  local digits sig exp e10 lead
  local -a kinds paths shown keys names counts
  str='^"([^"\\]|\\.)*"'
  strict='^"([^"\\]|\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4})*"$'
  scalar='^[^],}[:space:]]+'
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  int='^-?(0|[1-9][0-9]*)$'
  esc='^u00(4[1-9A-Fa-f]|5[0-9Aa]|6[1-9A-Fa-f]|7[0-9Aa])'
  kelvin='^u212[Aa]'
  hex='^u[0-9A-Fa-f]{4}'
  lost="the text of state.json cannot be followed here, so the keys the app reads in it cannot be checked"
  text="$(<"$1")"
  if IFS= read -r -d '' c < "$1"; then
    echo "$lost"
    return 0
  fi
  rest="${text#$'\xef\xbb\xbf'}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ "${rest:0:1}" == "{" ]] || { echo "$lost"; return 0; }
  # d is the depth of the object or array being read (1 is the top level);
  # for each, kinds holds { or [, paths where it is in the app's terms
  # (frozenProcesses[]), shown the same as a log names it
  # (frozenProcesses[0]), keys its last key, names its keys of letters
  # alone, and counts the values an array has had. want is what comes
  # next: a key, a colon, a value, or a comma or the end (next).
  d=0
  want=value
  while :; do
    rest="${rest#"${rest%%[![:space:]]*}"}"
    c="${rest:0:1}"
    vpath=""
    vshown=""
    if [[ "$want" == value ]] && (( d > 0 )); then
      if [[ "${kinds[d]}" == "{" ]]; then
        vpath="${paths[d]:+${paths[d]}.}${keys[d]}"
        vshown="${shown[d]:+${shown[d]}.}${keys[d]}"
      else
        vpath="${paths[d]}[]"
        vshown="${shown[d]}[${counts[d]}]"
      fi
    fi
    case "$c" in
      '{'|'[')
        [[ "$want" == value ]] || { echo "$lost"; return 0; }
        d=$((d + 1))
        kinds[d]="$c"
        paths[d]="$vpath"
        shown[d]="$vshown"
        keys[d]=""
        names[d]="|"
        counts[d]=0
        if [[ "$c" == "{" ]]; then want=key; else want=value; fi
        rest="${rest:1}"
        ;;
      '}'|']')
        # An empty object or array, or a comma before the end, which the
        # app accepts.
        if [[ "$c" == "}" ]]; then
          [[ "${kinds[d]}" == "{" && ( "$want" == key || "$want" == next ) ]] || { echo "$lost"; return 0; }
          list="${names[d]}"
          seen="|"
          raw="${list#|}"
          while [[ -n "$raw" ]]; do
            nm="${raw%%|*}"
            raw="${raw#*|}"
            [[ "$seen" != *"|$nm|"* ]] || continue
            seen+="$nm|"
            n=0
            token="$list"
            while [[ "$token" == *"|$nm|"* ]]; do
              n=$((n + 1))
              token="|${token#*"|$nm|"}"
            done
            if (( n > 1 && d == 1 )); then
              echo "$nm is in the top level of state.json $n times; the app reads the first and plutil the last"
            elif (( n > 1 )); then
              echo "${shown[d]} has $nm $n times; the app reads the first and plutil the last"
            fi
          done
        else
          [[ "${kinds[d]}" == "[" && ( "$want" == value || "$want" == next ) ]] || { echo "$lost"; return 0; }
        fi
        rest="${rest:1}"
        d=$((d - 1))
        (( d > 0 )) || break
        want=next
        if [[ "${kinds[d]}" == "[" ]]; then counts[d]=$((counts[d] + 1)); fi
        ;;
      ,)
        [[ "$want" == next ]] || { echo "$lost"; return 0; }
        if [[ "${kinds[d]}" == "{" ]]; then want=key; else want=value; fi
        rest="${rest:1}"
        ;;
      :)
        [[ "$want" == colon ]] || { echo "$lost"; return 0; }
        want=value
        rest="${rest:1}"
        ;;
      '"')
        [[ "$rest" =~ $str ]] || { echo "$lost"; return 0; }
        raw="${BASH_REMATCH[0]}"
        rest="${rest:${#raw}}"
        if [[ "$want" == key ]]; then
          # The key as the app reads it. Of the escapes JSON has, only a \u
          # of a letter or of the Kelvin sign can be part of a key of
          # letters alone; the others stand for no letter.
          raw="${raw:1:${#raw}-2}"
          raw="${raw//$'\xe2\x84\xaa'/K}"
          name=""
          while [[ "$raw" == *\\* ]]; do
            name+="${raw%%\\*}"
            raw="${raw#*\\}"
            if [[ "$raw" =~ $esc ]]; then
              printf -v c '%b' "\\x${BASH_REMATCH[1]}"
              name+="$c"
              raw="${raw:5}"
            elif [[ "$raw" =~ $kelvin ]]; then
              name+=K
              raw="${raw:5}"
            elif [[ "$raw" =~ $hex ]]; then
              name+="?"
              raw="${raw:5}"
            else
              case "${raw:0:1}" in
                '"'|\\|/|b|f|n|r|t) name+="?"; raw="${raw:1}" ;;
                *) echo "a key in state.json has an escape JSON does not have, so the keys the app reads in it cannot be checked"; return 0 ;;
              esac
            fi
          done
          name+="$raw"
          keys[d]="$name"
          if [[ "$name" =~ ^[A-Za-z]+$ ]]; then names[d]+="$name|"; fi
          want=colon
        elif [[ "$want" == value ]]; then
          [[ "$raw" =~ $strict ]] || echo "$vshown is a string with an escape JSON does not have, which the app does not read"
          want=next
          if [[ "${kinds[d]}" == "[" ]]; then counts[d]=$((counts[d] + 1)); fi
        else
          echo "$lost"
          return 0
        fi
        ;;
      '')
        echo "$lost"
        return 0
        ;;
      *)
        [[ "$want" == value && "$rest" =~ $scalar ]] || { echo "$lost"; return 0; }
        token="${BASH_REMATCH[0]}"
        rest="${rest:${#token}}"
        case "$vpath" in
          keptDisplayUnderLowPower|keptDisplayReadLit|displayRestoredUnderLowPower|savedOutputVolume|savedDisplayBrightness|savedKeyboardBrightness|'savedAudioOutputs[].volume') kind=float ;;
          'frozenProcesses[].pid'|'frozenProcesses[].startedAtMicros'|'frozenPids[]') kind=int32 ;;
          'frozenProcesses[].startedAt') kind=int64 ;;
          *) kind=any ;;
        esac
        if [[ "$token" == null || "$token" == true || "$token" == false ]]; then
          :
        elif [[ "$token" =~ $number && "$kind" == float ]]; then
          digits="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
          sig="${digits#"${digits%%[1-9]*}"}"
          if [[ -n "$sig" ]]; then
            exp="${BASH_REMATCH[6]#"${BASH_REMATCH[6]%%[1-9]*}"}"
            if (( ${#exp} > 18 )); then
              e10=1000000000000000000
            else
              e10=$((10#0$exp))
            fi
            if [[ "${BASH_REMATCH[5]}" == - ]]; then e10=$((-e10)); fi
            e10=$((e10 + ${#BASH_REMATCH[1]} - 1 - (${#digits} - ${#sig})))
            lead="${sig}00000000"
            lead=$((10#${lead:0:9}))
            if (( e10 < -46 || (e10 == -46 && lead < 701000000) )); then
              echo "$vshown is ${token:0:40}, too small a number for the app to read"
            elif (( e10 > 38 || (e10 == 38 && lead > 340282355) )); then
              echo "$vshown is ${token:0:40}, too large a number for the app to read"
            fi
          fi
        elif [[ "$token" =~ $int && "$kind" == int* ]]; then
          digits="${token#-}"
          if [[ "$kind" == int32 ]]; then limit=2147483647; else limit=9223372036854775807; fi
          if [[ "$token" == -* ]]; then limit="${limit%7}8"; fi
          if (( ${#digits} > ${#limit} )) || { (( ${#digits} == ${#limit} )) && [[ "$digits" > "$limit" ]]; }; then
            echo "$vshown is ${token:0:40}, a whole number the app cannot read there"
          fi
        elif [[ "$token" =~ $number ]]; then
          :
        elif [[ "$kind" == float ]]; then
          echo "$vshown is written as ${token:0:40}, which the app does not read as a number"
        else
          echo "$vshown is written as ${token:0:40}, which is not a JSON value the app reads"
        fi
        want=next
        if [[ "${kinds[d]}" == "[" ]]; then counts[d]=$((counts[d] + 1)); fi
        ;;
    esac
  done
  return 0
}

# Shape check, same rules as backstop.sh: a JSON object whose known keys have
# the types RuntimeState.swift writes; null counts as absent.
journal_shape_problems() { # file
  local f="$1" key t i n
  if [[ "$("$PLUTIL" -convert json -o - "$f" 2>/dev/null | "$HEAD" -c 1)" != "{" ]]; then
    echo "state.json is not a JSON object"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen savedMuted displayRestoreRefused keyboardRestoreRefused; do
    t="$(type_of "$f" "$key")"
    [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "$key is a $t, not a bool"
  done
  for key in savedOutputVolume savedDisplayBrightness savedKeyboardBrightness displayRestoredUnderLowPower; do
    t="$(type_of "$f" "$key")"
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  t="$(type_of "$f" endedSession)"
  [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "endedSession is a $t, not a string"
  # sessionCutoffs is not checked, as in backstop.sh: the app reads a value
  # it does not write as none, and nothing here uses it.
  # The app's records about a kept display entry: never read for an undo
  # here, and they stay or go with state.json. Each must still decode, or
  # the app cannot read the journal at all.
  for key in keptDisplayUnderLowPower keptDisplayReadLit; do
    t="$(type_of "$f" "$key")"
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  t="$(type_of "$f" keptDisplayUnderLowPowerBoot)"
  [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "keptDisplayUnderLowPowerBoot is a $t, not a string"
  record_text_problems "$f"
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

is_refused() { # key
  [[ "$(extract "$STATE" "$1" || true)" == "true" ]]
}

# Brightness the app kept after its private-call guard refused the restore
# on this macOS, one line per device with the saved level. Not a problem
# for uninstall: no step here can restore it.
refused_brightness() {
  local value
  [[ -f "$STATE" ]] || return 0
  if is_refused displayRestoreRefused && value="$(extract "$STATE" savedDisplayBrightness)"; then
    echo "display brightness $value"
  fi
  if is_refused keyboardRestoreRefused && value="$(extract "$STATE" savedKeyboardBrightness)"; then
    echo "keyboard backlight $value"
  fi
}

# Same rules as backstop.sh: a date in the form Store.parseDate reads, and
# the keys and types the app's Session decoder needs.
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

# Same as backstop.sh: epoch_of the string exactly as stored, with only
# plutil's own trailing newline cut.
epoch_at() { # file keypath
  local v
  v="$(extract "$1" "$2"; echo .)"
  v="${v%.}"
  epoch_of "${v%$'\n'}"
}
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

# Independent check of the journal: prints one line per unresolved item.
# Trusts nothing about the backstop that just ran (it may be an older copy).
journal_problems() {
  local key value shape i
  if [[ -e "$SESSION" ]]; then
    shape=""
    # Only a regular file is opened: open(2) on a FIFO with no writer
    # blocks, and this check runs while the recovery lock is held.
    if [[ ! -f "$SESSION" ]]; then
      echo "session.json is still present and cannot be read: it is not a regular file, so it was not opened"
    elif ! "$CAT" "$SESSION" >/dev/null 2>&1; then
      echo "session.json is still present and cannot be read (permissions or I/O)"
    elif shape="$(session_shape_problems "$SESSION")" && [[ -n "$shape" ]]; then
      echo "session.json is still present and is not a session: ${shape%%$'\n'*}"
    else
      echo "session.json is still present"
    fi
  fi
  [[ -e "$STATE" ]] || return 0
  if [[ ! -f "$STATE" ]]; then
    echo "state.json is not a regular file, so it was not opened"
    return 0
  fi
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
  i=0
  while extract_json "$STATE" "savedAudioOutputs.$i" >/dev/null; do
    value="$(extract "$STATE" "savedAudioOutputs.$i.name" || extract "$STATE" "savedAudioOutputs.$i.deviceUID" || true)"
    echo "$value is still muted from a lid close; only the app can restore its volume, once the device is connected"
    i=$((i + 1))
  done
  if extract "$STATE" savedDisplayBrightness >/dev/null && ! is_refused displayRestoreRefused; then
    echo "saved display brightness is not restored; only the app can do that"
  fi
  if extract "$STATE" savedKeyboardBrightness >/dev/null && ! is_refused keyboardRestoreRefused; then
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
      "$CAT" <<MSG
NSAppSleepDisabled is YES for these agent apps and Insomnia has no record of
what it was before (an older build set it without recording). They are left
as they are. To turn App Nap back on for one, run:
MSG
    fi
    printf '  defaults delete %q NSAppSleepDisabled\n' "$id"
  done < <(printf '%s' "$ids" | "$AWK" '!seen[$0]++')
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

# Copies of session.json that the app or backstop.sh moved aside, or of
# config.json that the app moved aside (the argument names which), taken
# straight from the glob into MOVED_ASIDE, so a path holding a newline stays
# one path. A copy is a regular file whose name has exactly the shape the
# move writes (prefix, UTC stamp, optional -n). Anything else with such a
# name (a directory, a FIFO, a symlink) goes to NOT_MOVED_ASIDE and is never
# removed, even when the app or backstop.sh renamed it there: a file that
# cannot be read is moved without being opened, whatever it is, and
# Insomnia did not create its contents. Other names under the prefix are
# not Insomnia's and are skipped.
collect_moved_aside() { # session.json | config.json
  local f stamp
  MOVED_ASIDE=()
  NOT_MOVED_ASIDE=()
  for f in "$APP_SUPPORT/$1".unreadable-*; do
    [[ -e "$f" || -L "$f" ]] || continue
    stamp="${f##*/}"
    stamp="${stamp#"$1".unreadable-}"
    [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]] || continue
    if [[ -f "$f" && ! -L "$f" ]]; then
      MOVED_ASIDE+=("$f")
    else
      NOT_MOVED_ASIDE+=("$f")
    fi
  done
  return 0
}

# The records of a session's end that backstop.sh (record_end_aside) or the
# app wrote under a fresh name, in $APP_SUPPORT or $LOG_DIR, into
# END_RECORDS_ASIDE: every path there named ended-session.json. and exactly
# eight letters or digits, whatever it is. $LOG_DIR is searched only when it
# is a directory, not a symlink, as backstop.sh and the app search it.
# remove_owned removes the regular files among them and names the rest.
collect_end_records_aside() {
  local d f
  END_RECORDS_ASIDE=()
  for d in "$APP_SUPPORT" "$LOG_DIR"; do
    [[ "$d" == "$APP_SUPPORT" || ( -d "$d" && ! -L "$d" ) ]] || continue
    for f in "$d"/ended-session.json.????????; do
      [[ -e "$f" || -L "$f" ]] || continue
      [[ "${f##*/}" =~ ^ended-session\.json\.[A-Za-z0-9]{8}$ ]] || continue
      END_RECORDS_ASIDE+=("$f")
    done
  done
  return 0
}

# The recovery lock file may hold the record of a session's end that
# backstop.sh or the app wrote there when nothing else took it (a tag and
# session.json's bytes in base64; record_end_in_lock in backstop.sh).
# session.json is gone by the time this runs (step 4 stops while it is
# there), so such a record ends nothing; it is still a copy of that
# session's times. The file is emptied in place, never unlinked, and only
# while it is a regular file, not a symlink, owned by this user, and the
# file this run holds the lock on (fd 9). Anything else is left and named,
# and a failure counts like a file that could not be removed. A
# session.json still there (one remove_owned could not remove) keeps the
# record, which may be its end.
clear_lock_record() {
  local held named
  [[ -e "$LOCK" || -L "$LOCK" ]] || return 0
  if [[ -e "$SESSION" || -L "$SESSION" ]]; then
    echo "Left the contents of $LOCK: $SESSION is still there, and they may record its end."
    return 0
  fi
  if [[ ! -f "$LOCK" || -L "$LOCK" || ! -O "$LOCK" ]]; then
    echo "Left the contents of $LOCK: it is not a regular file this user owns."
    return 0
  fi
  [[ -s "$LOCK" ]] || return 0
  held="$("$STAT" -f %i /dev/fd/9 2>/dev/null || true)"
  named="$("$STAT" -f %i "$LOCK" 2>/dev/null || true)"
  if [[ -n "$held" && "$held" == "$named" ]] && { : > "$LOCK"; } 2>/dev/null && [[ ! -s "$LOCK" ]]; then
    echo "Emptied $LOCK of the record of a session's end; the file itself is kept."
    return 0
  fi
  echo "Could not empty $LOCK of the record of a session's end; left in place." >&2
  remove_failures=$((remove_failures + 1))
  return 0
}

# Removes files Insomnia wrote, one path per argument. Only a regular file
# is removed. Anything else at one of these paths is not something Insomnia
# wrote; it is left and named, so a stray directory never stops the run
# halfway. A removal that fails is named and counted, and the rest go on.
remove_failures=0
remove_owned() { # path...
  local f
  for f in "$@"; do
    if [[ -f "$f" && ! -L "$f" ]]; then
      if ! "$RM" -f "$f"; then
        echo "Could not remove $f; left in place." >&2
        remove_failures=$((remove_failures + 1))
      fi
    elif [[ -e "$f" || -L "$f" ]]; then
      echo "Left $f: it is not a regular file, so Insomnia did not write it."
    fi
  done
  return 0
}

abort_incomplete() { # backstop exit status, problem lines...
  local rc="$1"; shift
  "$CAT" >&2 <<MSG

Uninstall stopped BEFORE removing anything: Insomnia's changes are not fully
undone (backstop exit status $rc). Still journaled in $STATE:
MSG
  local p
  for p in "$@"; do printf '  - %s\n' "$p" >&2; done
  "$CAT" >&2 <<MSG

Nothing was removed on purpose: the LaunchAgent keeps retrying every minute,
the sudoers rule keeps pmset undoable, and the journal keeps the evidence.

What to do, then rerun this script:
  - Saved audio (volume/mute), display brightness or keyboard backlight:
    open Insomnia.app; it restores them from the journal at launch. If the
    display is dark, press the brightness-up key first.
  - An output device still muted from a lid close: connect it and open
    Insomnia.app, which restores its volume. If the device is gone for
    good, open Insomnia.app and choose "Stop waiting for <device>" in its
    menu; the device then stays as it is.
  - pmset failures (sleep / Low Power Mode): check $SUDOERS
    (rerun scripts/install.sh to reinstall it), or run
    'sudo pmset -a disablesleep 0' / 'sudo pmset -b lowpowermode 0' yourself.
  - Frozen or legacy pids: open Insomnia.app to resolve them, or inspect each
    with 'ps -o pid,stat,lstart,command -p <pid>' and 'kill -CONT <pid>' it
    yourself if it is a process you recognise.
  - App Nap (NSAppSleepDisabled): the recovery agent retries 'defaults write'
    or 'defaults delete' every minute, and Insomnia.app restores them at
    launch. If 'defaults' keeps failing, see the log.
  - Unreadable state.json: neither the app nor the recovery agent repairs or
    removes it. Repair it by hand from the log, or move it away yourself once
    you know its changes are undone.
  - session.json that does not parse: the recovery agent renames it to
    session.json.unreadable-<time> as soon as the journal is clean, and the
    app does the same at launch. It needs no action of its own.
  - session.json that cannot be read at all: its end time is unknown, so
    the app and the agent treat it as expired, undo the journal, and then
    rename it to session.json.unreadable-<time> without opening it. If it
    is still here, that rename failed (see the log): remove it or move it
    out of this folder, then rerun. Do not make it readable where it is:
    the app would then resume it.
  - Log: $LOG_DIR/insomnia.log
MSG
  exit 1
}

# A pgrep that does not answer in time counts as "running": fail closed.
app_running() {
  local rc=0
  bounded "$PGREP" -x Insomnia || rc=$?
  if (( rc == 124 )); then
    echo "pgrep did not answer within ${CALL_TIMEOUT_SECONDS}s; treating Insomnia as running." >&2
    return 0
  fi
  return "$rc"
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
"$MKDIR" -p "$APP_SUPPORT"
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

# 3. Undo everything via a backstop that matches the installed app ----------
# The backstop inherits fd 9 and shares this lock instead of waiting on it.
# From a source checkout, the checkout's backstop.sh hands frozen entries
# that record microseconds to the installed app binary, and runs that binary
# only when the bundle's Info.plist declares InsomniaResumeFrozenVersion
# RESUME_FROZEN_VERSION (the same value as in backstop.sh; a test keeps the
# two in step). So the checkout's copy runs when the app declares that
# version. An app that does not was installed together with its own
# backstop.sh, which speaks its version: the copy install.sh sealed into the
# bundle, or for installs before that layout the writable copy in
# $APP_SUPPORT that the LaunchAgent runs. That copy is used instead when it
# exists. With neither copy the checkout's backstop runs anyway: it keeps the
# entries that need the binary, and step 4 stops before removing anything.
# From anywhere else, such as a release zip's folder, the sealed copy or
# nothing: a backstop.sh beside this script there is not from the zip (see
# SCRIPT_DIR), and the writable copy is older than release zips. The sealed
# copy runs only while the bundle's signature still verifies: its resource
# seal covers the script, so this is the check the LaunchAgent runs (without
# the pinned requirement, which this script does not have), and an edited
# copy is refused the same way.
step "Restoring the machine via backstop --force"
if [[ -e "$SCRIPT_DIR/backstop.sh" ]] && ! in_checkout; then
  echo "not running $SCRIPT_DIR/backstop.sh: $SCRIPT_DIR is not the scripts folder of a source checkout, and a release zip has no backstop.sh, so it was added after the zip was unpacked." >&2
fi
CHECKOUT_BACKSTOP=""
if in_checkout && [[ -f "$SCRIPT_DIR/backstop.sh" ]]; then
  CHECKOUT_BACKSTOP="$SCRIPT_DIR/backstop.sh"
fi
installed_version=""
if [[ -f "$APP/Contents/Info.plist" ]]; then
  installed_version="$(extract "$APP/Contents/Info.plist" InsomniaResumeFrozenVersion || true)"
fi
if [[ -n "$CHECKOUT_BACKSTOP" ]] && { [[ "$installed_version" == "$RESUME_FROZEN_VERSION" ]] || { [[ ! -f "$APP/Contents/Resources/backstop.sh" ]] && [[ ! -f "$APP_SUPPORT/backstop.sh" ]]; }; }; then
  BACKSTOP="$CHECKOUT_BACKSTOP"
elif [[ -f "$APP/Contents/Resources/backstop.sh" ]]; then
  verify_rc=0
  bounded "$CODESIGN" --verify --strict "$APP" || verify_rc=$?
  if (( verify_rc == 124 )); then
    echo "'codesign --verify --strict $APP' did not answer within ${CALL_TIMEOUT_SECONDS}s, so the backstop.sh sealed in it was not run." >&2
    echo "Nothing was removed. Rerun once codesign answers, or run scripts/uninstall.sh from a checkout of the source: it runs its own backstop.sh when this app declares InsomniaResumeFrozenVersion $RESUME_FROZEN_VERSION." >&2
    exit 1
  elif (( verify_rc != 0 )); then
    echo "$APP does not pass 'codesign --verify --strict' (exit $verify_rc: ${BOUNDED_OUTPUT:-no detail}), so the backstop.sh sealed in it was not run." >&2
    echo "Nothing was removed. Reinstall and rerun, or run scripts/uninstall.sh from a checkout of the source: it runs its own backstop.sh when this app declares InsomniaResumeFrozenVersion $RESUME_FROZEN_VERSION." >&2
    exit 1
  fi
  echo "$APP verifies"
  BACKSTOP="$APP/Contents/Resources/backstop.sh"
elif in_checkout && [[ -f "$APP_SUPPORT/backstop.sh" ]]; then
  BACKSTOP="$APP_SUPPORT/backstop.sh"
elif in_checkout; then
  echo "no backstop.sh found in $SCRIPT_DIR, $APP/Contents/Resources or $APP_SUPPORT; nothing was removed" >&2
  exit 1
else
  echo "no backstop.sh sealed in $APP/Contents/Resources, and outside a source checkout this script runs no other copy; nothing was removed." >&2
  echo "Run scripts/uninstall.sh from a checkout of the source." >&2
  exit 1
fi
if [[ -n "$CHECKOUT_BACKSTOP" && "$BACKSTOP" != "$CHECKOUT_BACKSTOP" ]]; then
  echo "$APP does not declare InsomniaResumeFrozenVersion $RESUME_FROZEN_VERSION; using the backstop installed with it, $BACKSTOP"
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
kept_brightness=()
while IFS= read -r line; do
  [[ -n "$line" ]] && kept_brightness+=("$line")
done < <(refused_brightness)
if (( ${#kept_brightness[@]} > 0 )); then
  echo "Not restored, and kept in $STATE:"
  for line in "${kept_brightness[@]}"; do echo "  - $line"; done
  echo "Insomnia's private-call guard refused that restore on this macOS, so nothing here can"
  echo "make it. Set the level with the brightness keys or Control Center. The file stays so a"
  echo "later Insomnia that can make the call restores it at launch."
fi
if app_running; then
  echo "Insomnia started again; quit it and rerun. Nothing was removed." >&2
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
"$RM" -f "$PLIST"
# Candidate plists install.sh and the app write before a load and rename
# into place after it: in the staging directory beside the plist, and in
# $LAUNCH_AGENTS itself for older builds. Only files with the label's
# candidate prefix, the same ones both of them sweep; the staging directory
# goes only once empty.
CANDIDATE_DIR="$LAUNCH_AGENTS/.$LABEL.staging"
for candidate in "$CANDIDATE_DIR/$LABEL.candidate-"* "$LAUNCH_AGENTS/$LABEL.candidate-"*; do
  if [[ -f "$candidate" && ! -L "$candidate" ]]; then "$RM" -f "$candidate"; fi
done
if [[ -d "$CANDIDATE_DIR" && ! -L "$CANDIDATE_DIR" ]]; then "$RMDIR" "$CANDIDATE_DIR" 2>/dev/null || true; fi

step "Removing $SUDOERS (requires your password)"
if [[ -e "$SUDOERS" ]] || "$SUDO" test -e "$SUDOERS"; then
  "$SUDO" rm -f "$SUDOERS"
fi

step "Removing app bundle"
"$RM" -rf "$APP"
# install.sh's leftovers beside the bundle, by the exact names it gives them.
# An upgrade sets the previous bundle aside at .Insomnia.app.previous during
# its swap and assembles the new one in .Insomnia.app.staging.<pid>.<six
# letters and digits> (mktemp). The swap runs under the recovery lock, which
# this script holds, so a set-aside bundle belongs to a run that was stopped.
# A staging directory whose run is still alive belongs to an install that
# has not reached the lock yet, and stays. kill -0 only asks whether the
# process exists; it sends no signal. Symlinks and any other name are left.
APP_DIR="${APP%/*}"
[[ -n "$APP_DIR" ]] || APP_DIR=/
PREVIOUS_APP="$APP_DIR/.Insomnia.app.previous"
if [[ -d "$PREVIOUS_APP" && ! -L "$PREVIOUS_APP" ]]; then
  "$RM" -rf "$PREVIOUS_APP"
  echo "removed $PREVIOUS_APP, the previous bundle an interrupted install set aside"
fi
staging_re='^\.Insomnia\.app\.staging\.([0-9]+)\.[A-Za-z0-9]{6}$'
for dir in "$APP_DIR"/.Insomnia.app.staging.*; do
  [[ -d "$dir" && ! -L "$dir" ]] || continue
  [[ "${dir##*/}" =~ $staging_re ]] || continue
  owner="${BASH_REMATCH[1]}"
  if "$KILL" -0 "$owner" 2>/dev/null; then
    echo "kept $dir: the install.sh run that made it (pid $owner) is still running"
    continue
  fi
  "$RM" -rf "$dir"
  echo "removed $dir, left by an install.sh run that is gone"
done

# $APP_SUPPORT/backstop.sh below is the writable copy of older installs; the
# current one went with the bundle.
if (( PURGE == 1 )); then
  step "Purging Insomnia's files in $APP_SUPPORT and $LOG_DIR"
  remove_owned "$SESSION" "$ENDED" "$APP_SUPPORT/config.json" "$APP_SUPPORT/backstop.sh" \
        "$APP_SUPPORT/unfinished-command.json" \
        "$LOG_DIR/insomnia.log" "$LOG_DIR/insomnia.log.1" \
        "$LOG_DIR/handoffs.log" "$LOG_DIR/handoffs.log.1"
  (( ${#kept_brightness[@]} > 0 )) || remove_owned "$STATE"
  collect_end_records_aside
  if (( ${#END_RECORDS_ASIDE[@]} > 0 )); then
    remove_owned "${END_RECORDS_ASIDE[@]}"
  fi
  clear_lock_record
  for name in session.json config.json; do
    collect_moved_aside "$name"
    if (( ${#MOVED_ASIDE[@]} > 0 )); then
      remove_owned "${MOVED_ASIDE[@]}"
    fi
    if (( ${#NOT_MOVED_ASIDE[@]} > 0 )); then
      for f in "${NOT_MOVED_ASIDE[@]}"; do
        echo "Left $f: it is named like a moved-aside $name but is not a regular file, so purge does not remove it. Remove it yourself if you do not need it."
      done
    fi
  done
  # The lock file itself is kept, even on purge: this process still holds
  # it, and anything that opened it a moment ago (a queued agent run, an app
  # launched after the check above) waits on this inode. Unlinking it would
  # let the next opener create a second lock nobody else sees. A leftover
  # empty lock file (emptied of any end record above) and its directory are
  # the accepted cost.
  "$RMDIR" "$LOG_DIR" 2>/dev/null || true
  (( OWN_LAUNCH_AGENTS_DIR == 1 )) && { "$RMDIR" "$LAUNCH_AGENTS" 2>/dev/null || true; }
  echo "Kept $LOCK (the recovery lock is never unlinked; delete $APP_SUPPORT by hand if you want it gone)."
  [[ -d "$LOG_DIR" ]] && echo "Kept $LOG_DIR: it still holds files Insomnia did not create."
else
  # unfinished-command.json names a sudo pmset that held the recovery lock;
  # this run holds it now, so that command has exited.
  remove_owned "$APP_SUPPORT/backstop.sh" "$SESSION" "$ENDED" "$APP_SUPPORT/unfinished-command.json"
  (( ${#kept_brightness[@]} > 0 )) || remove_owned "$STATE"
  collect_end_records_aside
  if (( ${#END_RECORDS_ASIDE[@]} > 0 )); then
    remove_owned "${END_RECORDS_ASIDE[@]}"
  fi
  clear_lock_record
  echo "Kept $APP_SUPPORT/config.json and $LOG_DIR (use --purge to remove)."
  for name in session.json config.json; do
    collect_moved_aside "$name"
    if (( ${#MOVED_ASIDE[@]} > 0 )); then
      echo "Kept ${#MOVED_ASIDE[@]} unreadable $name file(s) moved aside in $APP_SUPPORT (use --purge to remove)."
    fi
    if (( ${#NOT_MOVED_ASIDE[@]} > 0 )); then
      for f in "${NOT_MOVED_ASIDE[@]}"; do
        echo "Kept $f: it is named like a moved-aside $name but is not a regular file, so purge does not remove it either. Remove it yourself if you do not need it."
      done
    fi
  done
fi
(( ${#kept_brightness[@]} == 0 )) || echo "Kept $STATE: it holds the brightness listed above."

if (( remove_failures > 0 )); then
  echo "Done, except $remove_failures file(s) that could not be removed (named above)." >&2
  exit 1
fi
echo "Done."
