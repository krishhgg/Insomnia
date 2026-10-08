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
# number the app cannot decode, one of the three keys about the kept entry
# found twice at the top level of the file, or text the check cannot follow
# makes the journal malformed: the same text check as backstop.sh
# (record_text_problems), which reads keys at the top level only, with
# their escapes decoded, as the app does.
#
# Deletion is by exact owned file, never by directory tree: --purge removes
# the files Insomnia writes (see Paths.swift), the session.json copies the
# app or backstop.sh moved aside (session.json.unreadable-<stamp>, only that
# exact shape), and then rmdir's its own directories only if they are empty.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
in_checkout() { [[ "${SCRIPT_DIR##*/}" == scripts && -f "${SCRIPT_DIR%/*}/Package.swift" ]]; }

# Fixed tool paths: never taken from PATH or the environment. Tests patch
# these lines in a private copy of the script.
PGREP=/usr/bin/pgrep
PS=/bin/ps
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
CODESIGN=/usr/bin/codesign
LOCKF=/usr/bin/lockf
DEFAULTS=/usr/bin/defaults
ID=/usr/bin/id
KILL=/bin/kill
DATE=/bin/date
MKDIR=/bin/mkdir
RM=/bin/rm
RMDIR=/bin/rmdir
MKTEMP=/usr/bin/mktemp
TEST=/bin/test
CAT=/bin/cat
CP=/bin/cp
STAT=/usr/bin/stat
# The shell sudoers_remove runs as root.
ROOT_BASH=/bin/bash
LOCK_TIMEOUT_SECONDS=10
# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=10
# Longest one external call made by this script itself (pgrep, ps, plutil,
# cp, stat, defaults, launchctl, codesign, and the sudo calls made under the
# recovery lock) may run before it is stopped with SIGTERM, then SIGKILL,
# except sudo, which only ever gets SIGTERM. A call made under the recovery
# lock keeps the lock until it has exited or been stopped, even if this run
# is killed first (see bounded()). backstop.sh bounds its own commands. The
# password is asked once, with `sudo -v` before the lock is taken, so no
# call made under the lock waits for a prompt.
CALL_TIMEOUT_SECONDS=30
APP="$HOME/Applications/Insomnia.app"
SUDOERS=/etc/sudoers.d/insomnia
# Held, as root, by install.sh and uninstall.sh around each compare and
# write of $SUDOERS (see install.sh, which says why only root can make,
# swap or hold it). Never removed, not even by --purge.
SUDOERS_LOCK=/private/etc/sudoers.d/.insomnia-sudoers.lock
# The owner the guard, the rule and the folders above them must have: root.
# Tests patch this line to the test account.
ROOT_UID=0
BUNDLE_ID=com.kgarg.insomnia
# The Insomnia API client, whose executable is also named Insomnia. Its
# bundle id is the only one that proves a process is not this app.
CLIENT_BUNDLE_ID=com.insomnia.app
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
ACCOUNT="$("$ID" -un)"

step() { printf '\n==> %s\n' "$*"; }

# Scratch space for bounded() and for the private copies of the journal the
# checks in step 4 read: this run's own directory, emptied on exit.
WORK="$("$MKTEMP" -d "${TMPDIR:-/tmp}/insomnia-uninstall.XXXXXX")"
trap '"$RM" -f "$WORK"/call.* "$WORK"/*.json "$WORK"/*.lines 2>/dev/null; "$RMDIR" "$WORK" 2>/dev/null || true' EXIT

# Run one external call with a time limit. Its combined output is left in
# BOUNDED_OUTPUT (trailing newline removed) and in the file
# $BOUNDED_BASE.out byte for byte, and its exit status returned, or 124 when
# it did not finish within CALL_TIMEOUT_SECONDS and was stopped, or 125 when
# it is sudo and still running (pid in BOUNDED_PID). The same helper as
# install.sh's, which says more. supervise() enforces the limit itself, even
# if this run is killed while it waits: SIGTERM once the limit has passed on
# bash's SECONDS clock, SIGKILL one to two seconds later, never SIGKILL for
# sudo. The supervisor and the call keep fd 9 (the recovery lock) until the
# call has exited, so a launchctl bootout made under the lock cannot unload
# an agent the app confirms after this run is gone, and a sudo that ignores
# SIGTERM keeps the lock until it ends.
BOUNDED_OUTPUT=""
BOUNDED_PID=""
BOUNDED_BASE=""
bounded() { # command args...
  local base supervisor rc deadline
  base="$("$MKTEMP" "$WORK/call.XXXXXX")"
  BOUNDED_BASE="$base"
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
      BOUNDED_PID="$(cat "$base.pid" 2>/dev/null || true)"
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
# Like backstop.sh's supervisor, it ignores SIGTERM and SIGHUP, so a signal
# sent to this run's whole process group (a closed terminal, or launchd once
# a job's main process has gone) does not end it while its call runs. sudo
# closes its copy of fd 9, so the supervisor may be the only holder of the
# recovery lock until the call has exited. The call gets back the SIGTERM
# and SIGHUP actions this script started with, so it still stops on the
# SIGTERM at its limit or from the group. errexit is off here: a failed
# write must not end the supervisor while its call runs.
supervise() { # base command args...
  local base="$1" cpid rc=0 deadline
  shift
  set +e
  trap '' TERM HUP
  ( trap - TERM HUP; exec "$@" ) </dev/null >"$base.out" 2>&1 &
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
[[ "$(basename "$APP")" == "Insomnia.app" ]] || { echo "refusing: $APP is not an Insomnia.app bundle path" >&2; exit 1; }

# Reads made under the recovery lock (the journal, config.json) are bounded
# calls, so none can keep the lock waiting. One that fails in a way other
# than plutil's own "no such value" or "does not parse" (exit 1), or does
# not answer in time, is noted in READ_FAILURES. Its caller sees no value,
# so the caller of the whole check must treat a note there as a check that
# did not complete (it is never a clean journal). Once a read has failed,
# the rest return at once: they would most likely wait the same way. These
# notes go to a file because most reads run inside $(...).
READ_FAILURES="$WORK/read-failures.lines"
plutil_read() { # plutil arguments... file -> its output; 0 read, 1 plutil said no, 2 failed (noted)
  local rc=0 file="${!#}"
  [[ ! -s "$READ_FAILURES" ]] || return 2
  bounded "$PLUTIL" "$@" || rc=$?
  case "$rc" in
    0) "$CAT" "$BOUNDED_BASE.out"; return 0 ;;
    1) return 1 ;;
  esac
  echo "'plutil $1 $2' on ${file##*/} $(call_result "$rc")" >> "$READ_FAILURES"
  return 2
}
extract() { # file keypath (raw scalar; non-zero if missing or failed)
  plutil_read -extract "$2" raw -o - "$1"
}
extract_json() { # file keypath
  plutil_read -extract "$2" json -o - "$1"
}
type_of() { # file keypath -> bool|integer|float|string|array|dictionary|(any); empty if absent or failed
  plutil_read -type "$2" -o - "$1" || true
}
# Copies the regular file $1 to $2, in WORK, with one bounded cp, so the
# checks read a private copy that cannot block or change under them. Returns
# cp's status, or 124 when it did not answer in time.
snapshot() { # file copy
  local rc=0
  "$RM" -f "$2"
  bounded "$CP" "$1" "$2" || rc=$?
  return "$rc"
}
# How a bounded call's exit status reads in a message.
call_result() { # status
  if (( $1 == 124 )); then
    printf 'did not answer within %ss' "$CALL_TIMEOUT_SECONDS"
  else
    printf 'exited %s' "$1"
  fi
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
record_text_problems() { # file
  local LC_ALL=C
  local text rest raw key c token depth str plain scalar number esc hex lost
  local n_low=0 n_lit=0 n_boot=0 digits sig exp e10 lead
  str='^"([^"\\]|\\.)*"'
  plain='^[^]["{}]+'
  scalar='^[^],}[:space:]]+'
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  esc='^u00(4[1-9A-Fa-f]|5[0-9Aa]|6[1-9A-Fa-f]|7[0-9Aa])'
  hex='^u[0-9A-Fa-f]{4}'
  lost="the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked"
  text="$(<"$1")"
  [[ "$text" == *keptDisplay* || "$text" == *\\* ]] || return 0
  if IFS= read -r -d '' c < "$1"; then
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

# Shape check, same rules as backstop.sh: a JSON object whose known keys have
# the types RuntimeState.swift writes; null counts as absent.
journal_shape_problems() { # file
  local f="$1" key t i n json
  json="$(plutil_read -convert json -o - "$f")" || true
  [[ ! -s "$READ_FAILURES" ]] || return 0
  if [[ "${json:0:1}" != "{" ]]; then
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

is_refused() { # file key
  [[ "$(extract "$1" "$2" || true)" == "true" ]]
}

# Brightness the app kept after its private-call guard refused the restore
# on this macOS, one line per device with the saved level. Not a problem
# for uninstall: no step here can restore it. Read from the private copy of
# state.json that journal_problems checked; a read that fails is noted in
# READ_FAILURES, and the caller then keeps state.json.
refused_brightness() {
  local value
  [[ -f "$STATE_COPY" ]] || return 0
  if is_refused "$STATE_COPY" displayRestoreRefused && value="$(extract "$STATE_COPY" savedDisplayBrightness)"; then
    echo "display brightness $value"
  fi
  if is_refused "$STATE_COPY" keyboardRestoreRefused && value="$(extract "$STATE_COPY" savedKeyboardBrightness)"; then
    echo "keyboard backlight $value"
  fi
  return 0
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
  local f="$1" key t i json
  # plutil also reads XML and binary property lists, which the app's
  # JSONDecoder refuses, so the file itself must start with "{" too.
  json="$(plutil_read -convert json -o - "$f")" || true
  [[ ! -s "$READ_FAILURES" ]] || return 0
  if [[ "$(LC_ALL=C tr -d ' \t\r\n' < "$f" 2>/dev/null | head -c 1)" != "{" ]] \
     || [[ "${json:0:1}" != "{" ]]; then
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
# It runs under the recovery lock, so each file is read once, by a bounded
# cp into WORK, and every check reads that copy: a FIFO, a stalled disk or
# a file swapped meanwhile cannot keep the lock waiting or show one check
# another file. A read that fails or does not answer is noted in
# READ_FAILURES, which the caller counts as a problem.
SESSION_COPY="$WORK/session.json"
STATE_COPY="$WORK/state.json"
journal_problems() {
  local key value shape i rc
  if [[ -e "$SESSION" ]]; then
    shape=""
    rc=0
    # Only a regular file is copied: open(2) on a FIFO with no writer
    # blocks.
    if [[ ! -f "$SESSION" ]]; then
      echo "session.json is still present and cannot be read: it is not a regular file, so it was not opened"
    else
      snapshot "$SESSION" "$SESSION_COPY" || rc=$?
      if (( rc == 124 )); then
        echo "session.json is still present and could not be read within ${CALL_TIMEOUT_SECONDS}s"
      elif (( rc != 0 )); then
        echo "session.json is still present and cannot be read (permissions or I/O)"
      elif shape="$(session_shape_problems "$SESSION_COPY")" && [[ -n "$shape" ]]; then
        echo "session.json is still present and is not a session: ${shape%%$'\n'*}"
      else
        echo "session.json is still present"
      fi
    fi
  fi
  [[ -e "$STATE" ]] || return 0
  if [[ ! -f "$STATE" ]]; then
    echo "state.json is not a regular file, so it was not opened"
    return 0
  fi
  rc=0
  snapshot "$STATE" "$STATE_COPY" || rc=$?
  if (( rc == 124 )); then
    echo "state.json could not be read within ${CALL_TIMEOUT_SECONDS}s"
    return 0
  elif (( rc != 0 )); then
    echo "state.json is unreadable or malformed"
    return 0
  fi
  rc=0
  plutil_read -convert json -o /dev/null "$STATE_COPY" >/dev/null || rc=$?
  if (( rc == 1 )); then
    echo "state.json is unreadable or malformed"
    return 0
  elif (( rc != 0 )); then
    return 0
  fi
  shape="$(journal_shape_problems "$STATE_COPY")"
  if [[ -n "$shape" ]]; then
    echo "state.json is malformed (unexpected shape):"
    echo "$shape"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen; do
    if [[ "$(extract "$STATE_COPY" "$key" || true)" == "true" ]]; then
      echo "$key is still true"
    fi
  done
  value="$(extract_json "$STATE_COPY" frozenProcesses || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "frozen processes are still journaled: $value"
  fi
  value="$(extract_json "$STATE_COPY" frozenPids || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "legacy frozen pids (no identity; the backstop never signals or clears these, only the app does): $value"
  fi
  if extract "$STATE_COPY" savedOutputVolume >/dev/null || extract "$STATE_COPY" savedMuted >/dev/null; then
    echo "saved audio settings (volume/mute) are not restored; only the app can do that"
  fi
  i=0
  while extract_json "$STATE_COPY" "savedAudioOutputs.$i" >/dev/null; do
    value="$(extract "$STATE_COPY" "savedAudioOutputs.$i.name" || extract "$STATE_COPY" "savedAudioOutputs.$i.deviceUID" || true)"
    echo "$value is still muted from a lid close; only the app can restore its volume, once the device is connected"
    i=$((i + 1))
  done
  if extract "$STATE_COPY" savedDisplayBrightness >/dev/null && ! is_refused "$STATE_COPY" displayRestoreRefused; then
    echo "saved display brightness is not restored; only the app can do that"
  fi
  if extract "$STATE_COPY" savedKeyboardBrightness >/dev/null && ! is_refused "$STATE_COPY" keyboardRestoreRefused; then
    echo "saved keyboard backlight is not restored; only the app can do that"
  fi
  value="$(extract_json "$STATE_COPY" appNapOverrides || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "App Nap settings (NSAppSleepDisabled) are not put back: $value"
  fi
  return 0
}

# Agent apps whose NSAppSleepDisabled is YES with no journal entry: set by a
# build that did not record the previous value, or by the user. Nothing is
# known to put back, so nothing is changed; the exact command to undo each
# one is printed instead, shell-quoted, since the list editor takes any
# string. Checked: the shipped list plus config.json's agentList. Only a
# read that says "does not exist" counts as clear; a read that fails any
# other way is reported, not counted. Each read is bounded; one that does
# not answer in time (cfprefsd stuck) ends the check, since the rest would
# wait the same way, and uninstall goes on. So does a read of config.json's
# list that fails or does not answer; the apps listed only there are then
# named as not checked.
list_unrecorded_app_nap() {
  local ids="" i=0 id value rc found=0 checked=0 unreadable=0 stuck="" skipped=0
  for id in "${DEFAULT_AGENTS[@]}"; do ids="$ids$id"$'\n'; done
  if [[ -f "$CONFIG" ]]; then
    "$RM" -f "$READ_FAILURES"
    while id="$(extract "$CONFIG" "agentList.$i")"; do
      i=$((i + 1))
      ids="$ids$id"$'\n'
    done
    if [[ -s "$READ_FAILURES" ]]; then
      echo "could not read all of the agent list in $CONFIG ($(head -n 1 "$READ_FAILURES")), so agent apps listed only there may not have been checked"
    fi
  fi
  ids="$(printf '%s' "$ids" | awk '!seen[$0]++')"
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
  done <<< "$ids"
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

# Copies of session.json that the app or backstop.sh moved aside, taken
# straight from the glob into MOVED_ASIDE, so a path holding a newline stays
# one path. A copy is a regular file whose name has exactly the shape the
# move writes (prefix, UTC stamp, optional -n). Anything else with such a
# name (a directory, a FIFO, a symlink) goes to NOT_MOVED_ASIDE and is never
# removed, even when the app or backstop.sh renamed it there: a session.json
# that cannot be read is moved without being opened, whatever it is, and
# Insomnia did not create its contents. Other names under the prefix are
# not Insomnia's and are skipped.
collect_moved_aside_sessions() {
  local f
  MOVED_ASIDE=()
  NOT_MOVED_ASIDE=()
  for f in "$APP_SUPPORT"/session.json.unreadable-*; do
    [[ -e "$f" || -L "$f" ]] || continue
    [[ "${f##*/}" =~ ^session\.json\.unreadable-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?$ ]] || continue
    if [[ -f "$f" && ! -L "$f" ]]; then
      MOVED_ASIDE+=("$f")
    else
      NOT_MOVED_ASIDE+=("$f")
    fi
  done
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

# Running copies of this app, in this account or any other. `pgrep -x
# Insomnia` matches every process named Insomnia, and the Insomnia API
# client's executable has that name too, so each pid is checked by its
# executable path (`ps -o comm=`, the full path for an app LaunchServices
# launched): it is this app when the path is the installed bundle's binary
# or lies in a bundle whose Info.plist declares $BUNDLE_ID. A process whose
# bundle id reads as $CLIENT_BUNDLE_ID is the API client and is left alone.
# Any other bundle id proves nothing: a copy of this app with an edited
# Info.plist would still use this account's journal. Such a process, and
# one whose identity cannot be read (no path, a path outside any bundle, an
# Info.plist that does not parse), might be this app, so it counts as this
# app until it exits: it is never signalled, but nothing is replaced or
# removed while it runs. A copy in another account (`ps -o uid=`), or a
# process there that cannot be told apart from one, blocks as well: the
# rule at $SUDOERS is one file for the whole Mac, and that copy may need it
# to undo its own session. It is reported, and never asked to quit or
# signalled; only its own account can quit it. A process whose owner `ps -o
# uid=` does not give (it failed, did not answer, or printed no user ID) may
# be in either account, so it is neither: it is never asked to quit, and it
# stops the run before anything is asked to quit unless a fresh look finds
# it gone (UNKNOWN_OWNER, await_known_owners). Only a process proven to be
# the API client is ignored whatever its owner. pgrep, ps and plutil go
# through bounded(), so none of them can keep this run, or the recovery
# lock, waiting. A pgrep that fails or does not answer says nothing about
# what runs, so it blocks (PGREP_PROBLEM).
APP_FOUND=()      # "pid N (path)" per running copy of this app in this account
UNVERIFIED=()     # "pid N (path; why)" per process of this account that could not be told apart from it
OTHER_ACCOUNT=()  # "pid N (uid U, path)" per copy, or process that could not be told apart from one, in another account
UNKNOWN_OWNER=()  # "pid N (owner unknown: why; path)" per process not proven to be the API client whose owner is unknown
OTHER_FOUND=()    # "pid N (path, bundle id X)" per process proven to be the API client
BLOCKING=()       # the first four: what must be gone before files are touched
PGREP_PROBLEM=""  # "pgrep exited N" or "pgrep did not answer within Ns", when it did not list
# Bundle ids read before the recovery lock, as "pid|bundle|id", reused for
# the same process only: one that took a bundle's place since has another
# pid and is not taken for what ran there before. Once the lock is held
# (PLIST_READS=0) no Info.plist is read at all, not even a bounded read: a
# call made under the lock keeps the lock until it exits (see bounded()),
# so a process first seen then counts as unverified and blocks.
KNOWN_IDS=()
PLIST_READS=1
known_id() { # pid bundle
  local entry
  (( ${#KNOWN_IDS[@]} > 0 )) || return 0
  for entry in "${KNOWN_IDS[@]}"; do
    if [[ "${entry%|*}" == "$1|$2" ]]; then
      printf '%s\n' "${entry##*|}"
      return 0
    fi
  done
  return 0
}
find_insomnia() {
  local pid pids rc owner owner_why exe bundle id desc this
  APP_FOUND=(); UNVERIFIED=(); OTHER_ACCOUNT=(); UNKNOWN_OWNER=(); OTHER_FOUND=(); BLOCKING=(); PGREP_PROBLEM=""
  # pgrep exits 1 when no process has the name. Any other failure, or no
  # answer in time, counts as "running": fail closed.
  rc=0
  bounded "$PGREP" -x Insomnia || rc=$?
  pids="$BOUNDED_OUTPUT"
  if (( rc != 0 && rc != 1 )); then
    if (( rc == 124 )); then
      PGREP_PROBLEM="pgrep did not answer within ${CALL_TIMEOUT_SECONDS}s"
    else
      PGREP_PROBLEM="pgrep exited $rc"
    fi
    echo "$PGREP_PROBLEM; treating Insomnia as running." >&2
    UNVERIFIED+=("$PGREP_PROBLEM")
    BLOCKING+=("$PGREP_PROBLEM")
    return 0
  fi
  (( rc == 0 )) || pids=""
  for pid in $pids; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    rc=0
    bounded "$PS" -o uid= -p "$pid" || rc=$?
    owner="${BOUNDED_OUTPUT//[[:space:]]/}"
    owner_why=""
    if (( rc != 0 )); then
      owner_why="ps -o uid= $(call_result "$rc")"
    elif [[ -z "$owner" ]]; then
      owner_why="ps -o uid= printed nothing"
    elif [[ ! "$owner" =~ ^[0-9]+$ ]]; then
      owner_why="ps -o uid= printed '$owner', not a user ID"
    fi
    rc=0
    bounded "$PS" -o comm= -p "$pid" || rc=$?
    exe=""
    (( rc == 0 )) && exe="$BOUNDED_OUTPUT"
    id=""
    desc="${exe:-executable path unknown}"   # what the messages say; gains the reason when unverified
    if [[ "$exe" == /*/Contents/MacOS/* ]]; then
      bundle="${exe%/Contents/MacOS/*}"
      id="$(known_id "$pid" "$bundle")"
      rc=0
      if [[ -z "$id" ]] && (( PLIST_READS == 1 )); then
        bounded "$PLUTIL" -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" || rc=$?
        if (( rc == 0 )); then id="${BOUNDED_OUTPUT%%$'\n'*}"; fi
        if [[ -n "$id" ]]; then KNOWN_IDS+=("$pid|$bundle|$id"); fi
      fi
      if [[ -z "$id" ]]; then
        if (( PLIST_READS == 0 )); then
          desc="$exe; first seen under the recovery lock, where no Info.plist is read"
        elif (( rc == 124 )); then
          desc="$exe; $bundle/Contents/Info.plist did not answer within ${CALL_TIMEOUT_SECONDS}s"
        else
          desc="$exe; no bundle id readable from $bundle/Contents/Info.plist"
        fi
      fi
    elif [[ -n "$exe" ]]; then
      desc="$exe; not inside an app bundle, so no bundle id to read"
    fi
    if [[ "$exe" == "$APP/Contents/MacOS/Insomnia" || "$id" == "$BUNDLE_ID" ]]; then
      this=1
    elif [[ "$id" == "$CLIENT_BUNDLE_ID" ]]; then
      OTHER_FOUND+=("pid $pid ($exe, bundle id $id)")
      continue
    else
      this=0
      if [[ -n "$id" ]]; then desc="$exe; bundle id $id is neither this app's nor the Insomnia API client's"; fi
    fi
    # No user ID (ps failed, did not answer, or the process just exited)
    # proves neither account, so such a process is neither this account's
    # app nor another's: it is never asked to quit and it blocks.
    if [[ -n "$owner_why" ]]; then
      UNKNOWN_OWNER+=("pid $pid (owner unknown: $owner_why; $desc)")
      BLOCKING+=("pid $pid (owner unknown: $owner_why; $desc)")
    elif [[ "$owner" != "$UID_NUM" ]]; then
      OTHER_ACCOUNT+=("pid $pid (uid $owner, $desc)")
      BLOCKING+=("pid $pid (uid $owner, $desc)")
    elif (( this == 1 )); then
      APP_FOUND+=("pid $pid ($exe)")
      BLOCKING+=("pid $pid ($exe)")
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
# /etc/sudoers.d/insomnia is one file for the whole Mac, and each install
# writes its own account into it. When another account installed Insomnia
# after this one, the file holds that account's rule, and removing it would
# leave that account's app and agent unable to undo a session. So the file
# goes only when it is the rule install.sh writes for this account: its
# header comment and grants of Insomnia's pmset commands to $ACCOUNT, and
# nothing else but blank lines. Lines are compared exactly. Prints why the
# text is not that rule (starting "grants <name>" when it grants those
# commands to another account), or nothing when it is.
sudoers_not_ours() { # file content
  local line grants=0
  while IFS= read -r line; do
    case "$line" in
      "" | "# Installed by Insomnia install.sh."*) continue ;;
    esac
    case "${line#* }" in
      "ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1" | \
      "ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0" | \
      "ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1" | \
      "ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0")
        if [[ "${line%% *}" == "$ACCOUNT" ]]; then
          grants=$((grants + 1))
          continue
        fi
        echo "grants ${line%% *}"
        return 0 ;;
    esac
    echo "it has a line install.sh does not write: $line"
    return 0
  done <<< "$1"
  (( grants > 0 )) || echo "it grants nothing"
  return 0
}

# Why the file named $1 cannot take part in the rule's transaction, or
# nothing when it can: a regular file of root's (ROOT_UID) with one link, no
# setuid, setgid or sticky bit and no write permission for group or others;
# with $3, exactly that mode. $2 is its `stat -f '%Hp %Mp %Lp %u %l'`, which
# reads the name itself, not what a link points to. This and the two
# functions below are the same in install.sh and uninstall.sh (a test keeps
# them in step) and run only as root.
sudoers_file_problem() { # name stat [mode]
  local type special perm uid links
  read -r type special perm uid links <<< "$2"
  if [[ "${type:-}" != 10 ]]; then
    echo "$1 is not a regular file (stat: ${2:-no answer})"
  elif [[ "${uid:-}" != "$ROOT_UID" ]]; then
    echo "$1 belongs to uid ${uid:-?}, not root"
  elif [[ "${links:-}" != 1 ]]; then
    echo "$1 has ${links:-?} links, not 1"
  elif [[ "${special:-}" != 0 || ! "${perm:-}" =~ ^[0-7]+$ ]] || (( (8#$perm & 8#022) != 0 )); then
    echo "$1 has mode ${special:-?}${perm:-?}, so someone other than root may change it"
  elif [[ -n "${3:-}" && "$perm" != "$3" ]]; then
    echo "$1 has mode $perm, not $3"
  fi
  return 0
}
# Takes $SUDOERS_LOCK on fd 8 for the rest of the root shell, once it is
# shown that only root can have made or changed it. An existing file must be
# a regular file of root's with mode 0600 and one link, and every folder from
# its own up to / a folder of root's that group and others cannot write.
# Both are checked before the file is opened, so a FIFO (whose open would
# wait) or a link is never opened. The file is created, mode 0600, only where
# nothing is (noclobber: no link is followed and nothing is truncated).
# Nothing is ever repaired, replaced or removed. Once the lock is taken, the
# descriptor and the path must still be the same file, unchanged, and the
# rule $1 must be in the same folder. Exits 7 with the reason when a check
# fails, 3 when the lock is not free within LOCK_TIMEOUT_SECONDS.
sudoers_guard_take() { # rule
  local dir s type perm uid why took seen
  if [[ -e "$SUDOERS_LOCK" || -L "$SUDOERS_LOCK" ]]; then
    why="$(sudoers_file_problem "$SUDOERS_LOCK" "$("$STAT" -f '%Hp %Mp %Lp %u %l' "$SUDOERS_LOCK" 2>/dev/null)" 600)"
    if [[ -n "$why" ]]; then echo "$why" >&2; exit 7; fi
  fi
  dir="$SUDOERS_LOCK"
  while [[ "$dir" == /?* ]]; do
    dir="${dir%/*}"
    s="$("$STAT" -f '%Hp %Lp %u' "${dir:-/}" 2>/dev/null)"
    read -r type perm uid <<< "$s"
    if [[ "${type:-}" != 4 || ! "${perm:-}" =~ ^[0-7]+$ ]] \
       || [[ "${uid:-}" != 0 && "${uid:-}" != "$ROOT_UID" ]] || (( (8#$perm & 8#022) != 0 )); then
      echo "${dir:-/}, a folder above $SUDOERS_LOCK, is not a folder of root's that only root can write (stat: ${s:-no answer})" >&2
      exit 7
    fi
  done
  ( set -C; : > "$SUDOERS_LOCK" ) 2>/dev/null || true
  why="$(sudoers_file_problem "$SUDOERS_LOCK" "$("$STAT" -f '%Hp %Mp %Lp %u %l' "$SUDOERS_LOCK" 2>/dev/null)" 600)"
  if [[ -n "$why" ]]; then echo "$why" >&2; exit 7; fi
  exec 8<"$SUDOERS_LOCK" || exit 7
  "$LOCKF" -t "$LOCK_TIMEOUT_SECONDS" 8 2>/dev/null || exit 3
  took="$("$STAT" -f '%d:%i %Hp %Mp %Lp %u %l' <&8 2>/dev/null)"
  seen="$("$STAT" -f '%d:%i %Hp %Mp %Lp %u %l' "$SUDOERS_LOCK" 2>/dev/null)"
  if [[ -z "$took" || "$took" != "$seen" ]]; then
    echo "$SUDOERS_LOCK is no longer the file this run opened and locked" >&2
    exit 7
  fi
  why="$(sudoers_file_problem "$SUDOERS_LOCK" "${took#* }" 600)"
  if [[ -n "$why" ]]; then echo "$why" >&2; exit 7; fi
  if [[ "$("$STAT" -L -f '%d:%i' "${1%/*}" 2>/dev/null)" != "$("$STAT" -f '%d:%i' "${SUDOERS_LOCK%/*}" 2>/dev/null)" ]]; then
    echo "$1 is not in the folder that holds $SUDOERS_LOCK" >&2
    exit 7
  fi
}
# Opens the rule $1 on fd 7, once sudoers_file_problem finds nothing wrong
# with it (any mode without group or other write), and reads it through that
# descriptor. Exits 4 unless the path still names the opened file and the
# text read, trailing newlines aside, is exactly $2, the text the caller read
# and judged before sudo ran; 8 when the shell cannot hold the bytes exactly
# (a NUL byte, or a change while they were read). Leaves the file's identity
# in PINNED_ID and its text in PINNED_TEXT.
sudoers_pin_rule() { # rule text
  local LC_ALL=C why size
  why="$(sudoers_file_problem "$1" "$("$STAT" -f '%Hp %Mp %Lp %u %l' "$1" 2>/dev/null)")"
  if [[ -n "$why" ]]; then echo "$why" >&2; exit 4; fi
  exec 7<"$1" || exit 4
  PINNED_ID="$("$STAT" -f '%d:%i' <&7 2>/dev/null)"
  if [[ -z "$PINNED_ID" || "$PINNED_ID" != "$("$STAT" -f '%d:%i' "$1" 2>/dev/null)" ]]; then
    echo "$1 was replaced while it was opened" >&2
    exit 4
  fi
  size="$("$STAT" -f '%z' <&7 2>/dev/null)"
  PINNED_TEXT="$("$CAT" <&7 && echo .)"
  PINNED_TEXT="${PINNED_TEXT%.}"
  if [[ -z "$size" || "${#PINNED_TEXT}" != "$size" ]]; then
    echo "$1 holds a NUL byte, or changed while it was read" >&2
    exit 8
  fi
  PINNED_TEXT="${PINNED_TEXT%"${PINNED_TEXT##*[!$'\n']}"}"
  if [[ "$PINNED_TEXT" != "$2" ]]; then
    echo "$1 is not the text this run read" >&2
    exit 4
  fi
}

# Removes the rule at $SUDOERS only if it is still exactly the text this run
# read and judged to be its own (passed to root as an argument): another
# account's install.sh may replace it between the read and the removal. The
# compare and the removal are one call to sudo, run as root while it holds
# $SUDOERS_LOCK (sudoers_guard_take), the lock install.sh takes for its
# compare and write. Root reads the rule through a descriptor it opened and
# checked (sudoers_pin_rule), judges that text again with sudoers_not_ours,
# and removes the path only while it still names the file it opened. The
# lock keeps out only the runs that take it, as install.sh says. Exit
# status: 0 removed; 3 the lock was not free within LOCK_TIMEOUT_SECONDS; 4
# the rule changed since it was read, or is not a regular file of root's
# with one link that only root can change; 5 rm reported that the removal
# failed; 7 the lock file, or a folder above it, is not one only root can
# change; 8 the rule as root read it holds a NUL byte, changed while it was
# read, or is not this account's. 1 is sudo's own (no valid timestamp, say)
# or a shell error before the removal. In all of these the rule was not
# removed, though the lock file may have been created. Any other status (the
# root shell, or its rm, was killed by a signal), or a call that did not
# finish in time, leaves it unknown whether the removal happened.
sudoers_remove_as_root() { # rule text
  umask 077
  sudoers_guard_take "$1"
  sudoers_pin_rule "$1" "$2"
  [[ -z "$(sudoers_not_ours "$PINNED_TEXT")" ]] || exit 8
  if [[ "$("$STAT" -f '%d:%i' "$1" 2>/dev/null)" != "$PINNED_ID" ]]; then
    echo "$1 was replaced while it was checked" >&2
    exit 4
  fi
  # An rm killed by a signal may have removed the rule already, so its
  # status goes on as it is, an unknown result, not as a failed removal.
  "$RM" -f "$1" || { rc=$?; (( rc > 128 )) && exit "$rc"; exit 5; }
  exit 0
}
# Runs sudoers_remove_as_root as root, in one sudo call, bounded like every
# other call made under the recovery lock: `sudo -n` never prompts (the
# password was asked before the lock, with `sudo -v`), and a sudo still
# running past the limit returns 125 and keeps the lock until it ends. The
# shell's script is this script's fixed tool paths, the account's name, and
# the text of the functions root runs; sudo resets the environment, so
# nothing root runs comes from PATH.
sudoers_remove() { # text
  bounded "$SUDO" -n "$ROOT_BASH" -c "set -u
$(printf '%s=%q\n' SUDOERS_LOCK "$SUDOERS_LOCK" ROOT_UID "$ROOT_UID" ACCOUNT "$ACCOUNT" \
    LOCK_TIMEOUT_SECONDS "$LOCK_TIMEOUT_SECONDS" LOCKF "$LOCKF" STAT "$STAT" CAT "$CAT" RM "$RM")
$(declare -f sudoers_file_problem sudoers_guard_take sudoers_pin_rule sudoers_not_ours sudoers_remove_as_root)
sudoers_remove_as_root \"\$@\"" insomnia-sudoers-remove "$SUDOERS" "$1"
}
# The part of a message about a sudo call that is still running.
sudo_alive_note() {
  printf "It was sent SIGTERM and is still running as pid %s. It is not killed, because killing sudo could leave what it runs as root behind" "${BOUNDED_PID:-?}"
}
# Stops the run when the outcome of a sudo call made for the rule is not
# known. The app and the journal stay, so a recovery that still needs the
# rule (if it is there) has its app and agent's files; the LaunchAgent is
# already gone by then.
sudoers_uncertain() { # what is not known
  echo "$1" >&2
  echo "The LaunchAgent is already removed; the app at $APP and the recovery journal were kept. Check the rule with 'sudo cat $SUDOERS', then rerun this script." >&2
  exit 1
}

# Stops the run when Insomnia runs in another account, when a process named
# Insomnia has an owner ps could not give, or when pgrep could not say
# whether it runs. Nothing has been changed by then, and nothing is sent to
# any process.
stop_for_other_accounts() {
  if [[ -n "$PGREP_PROBLEM" ]]; then
    echo "$PGREP_PROBLEM, so whether Insomnia runs in this or another account is unknown. Rerun once it answers. Nothing was removed." >&2
    exit 1
  fi
  if (( ${#UNKNOWN_OWNER[@]} > 0 )); then
    echo "Whose process these are could not be read, so whether Insomnia runs in this or another account is unknown: $(list "${UNKNOWN_OWNER[@]}")." >&2
    echo "$SUDOERS is shared by every account on this Mac, so nothing was asked to quit. Rerun once 'ps -o uid= -p <pid>' answers for them, or once they have exited. Nothing was removed." >&2
    exit 1
  fi
  (( ${#OTHER_ACCOUNT[@]} > 0 )) || return 0
  echo "Insomnia is running in another account, or a process named Insomnia there could not be told apart from it: $(list "${OTHER_ACCOUNT[@]}")." >&2
  echo "$SUDOERS is shared by every account on this Mac and that copy may need it, so it is left alone and not asked to quit." >&2
  echo "Quit Insomnia in that account, then rerun. Nothing was removed." >&2
  exit 1
}
# A process whose owner could not be read may only have raced its own exit,
# so the processes are listed again, once a second for up to
# QUIT_WAIT_SECONDS, while one is listed; stop_for_other_accounts then stops
# the run if one still is. A pgrep problem stops it at once.
await_known_owners() {
  local i
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    [[ -z "$PGREP_PROBLEM" ]] || return 0
    (( ${#UNKNOWN_OWNER[@]} > 0 )) || return 0
    sleep 1
    find_insomnia
  done
  return 0
}

# 1. Quit the app --------------------------------------------------------------
# Ask politely and wait. The app refuses to quit while it has unresolved
# recovery work, and that refusal must stand: no pkill, no force. This app
# counts, and so does a process named Insomnia that cannot be told apart
# from it (find_insomnia); one proven to be another app is reported and
# left alone. A copy in another account stops the run at once, and so does
# a process whose owner ps cannot give once QUIT_WAIT_SECONDS have passed
# (await_known_owners): before anything is asked to quit, and before the
# first sudo below.
step "Quitting Insomnia"
if app_running; then
  await_known_owners
  report_others
  stop_for_other_accounts
  report_unverified
  # The quit goes only to a copy identified as this app in this account. An
  # unverified process is waited for, but its presence alone never asks the
  # real app to quit.
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

# Which backstop.sh speaks the installed app's --resume-frozen interface
# depends on the InsomniaResumeFrozenVersion its Info.plist declares (step
# 3). No Info.plist is read under the recovery lock, so it is read here,
# before the lock, with bounded calls, together with the file's identity
# (device, inode, change time with nanoseconds, size) before and after the
# read. Step 3 uses the value only when a bounded stat under the lock, which
# reads no contents, shows the same file unchanged. A read that fails, does
# not answer or sees the file change stops the run here, before anything is
# removed and before any backstop runs. Only from a source checkout does
# the value choose anything, so only there is it read.
CHECKOUT_BACKSTOP=""
if in_checkout && [[ -f "$SCRIPT_DIR/backstop.sh" ]]; then
  CHECKOUT_BACKSTOP="$SCRIPT_DIR/backstop.sh"
fi
INFO_PLIST="$APP/Contents/Info.plist"
installed_version=""
VERSION_EVIDENCE=none   # no regular file at $INFO_PLIST, which declares nothing
VERSION_PROBLEM=""
read_installed_version() {
  local rc=0 before
  [[ -f "$INFO_PLIST" ]] || return 0
  bounded "$STAT" -L -f '%d:%i:%Fc:%z' "$INFO_PLIST" || rc=$?
  if (( rc != 0 )); then VERSION_PROBLEM="'stat' $(call_result "$rc")"; return 1; fi
  before="$BOUNDED_OUTPUT"
  bounded "$PLUTIL" -extract InsomniaResumeFrozenVersion raw -o - "$INFO_PLIST" || rc=$?
  if (( rc == 0 )); then
    installed_version="$("$CAT" "$BOUNDED_BASE.out")"
  elif (( rc == 1 )); then
    # No such key, or no plist at all: only a plist that parses declares
    # no version.
    rc=0
    bounded "$PLUTIL" -lint "$INFO_PLIST" || rc=$?
    if (( rc != 0 )); then VERSION_PROBLEM="it does not parse ('plutil -lint' $(call_result "$rc"))"; return 1; fi
  else
    VERSION_PROBLEM="'plutil -extract InsomniaResumeFrozenVersion' $(call_result "$rc")"
    return 1
  fi
  rc=0
  bounded "$STAT" -L -f '%d:%i:%Fc:%z' "$INFO_PLIST" || rc=$?
  if (( rc != 0 )); then VERSION_PROBLEM="'stat' $(call_result "$rc")"; return 1; fi
  if [[ "$BOUNDED_OUTPUT" != "$before" ]]; then VERSION_PROBLEM="it changed while it was read"; return 1; fi
  VERSION_EVIDENCE="$before"
}
if [[ -n "$CHECKOUT_BACKSTOP" ]] && ! read_installed_version; then
  echo "Could not read InsomniaResumeFrozenVersion from $INFO_PLIST: $VERSION_PROBLEM. Which backstop.sh speaks the installed app's interface is unknown, so none was run. Nothing was removed; rerun once it reads." >&2
  exit 1
fi

# The password is asked here, once, before the recovery lock: each sudo call
# made under the lock (step 5) is `sudo -n` and bounded, so none waits at a
# prompt while the lock is held. It is asked only when the rule is there,
# or when its folder cannot be searched without sudo. The last process check
# above ran just before this, with nothing in between but the bounded reads
# above. sudo's timestamp lasts a few minutes (five by default); if it runs
# out before step 5, that step keeps the rule and the app.
if [[ -e "$SUDOERS" || ! -x "${SUDOERS%/*}" ]]; then
  if ! "$SUDO" -v; then
    echo "sudo did not authenticate, so $SUDOERS could not be removed later. Nothing was removed." >&2
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
# From here on no Info.plist is read (PLIST_READS=0): a process first seen
# under the lock counts as unverified and stops the run.
PLIST_READS=0
if app_running; then
  echo "Insomnia started again ($(list "${BLOCKING[@]}")); quit it and rerun. Nothing was removed." >&2
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
# The version read before the lock still applies only to the same file,
# unchanged (see read_installed_version).
if [[ -n "$CHECKOUT_BACKSTOP" ]]; then
  version_rc=0
  version_now=none
  if [[ -f "$INFO_PLIST" ]]; then
    bounded "$STAT" -L -f '%d:%i:%Fc:%z' "$INFO_PLIST" || version_rc=$?
    version_now="$BOUNDED_OUTPUT"
  fi
  if (( version_rc != 0 )); then
    echo "'stat $INFO_PLIST' $(call_result "$version_rc") under the recovery lock, so whether the InsomniaResumeFrozenVersion read before the lock still applies is unknown, and no backstop.sh was run. Nothing was removed; rerun." >&2
    exit 1
  elif [[ "$version_now" != "$VERSION_EVIDENCE" ]]; then
    echo "$INFO_PLIST changed after this run read its InsomniaResumeFrozenVersion (an install may have replaced the app meanwhile). No Info.plist is read under the recovery lock, so which backstop.sh speaks the installed app's interface is unknown, and none was run. Nothing was removed; rerun." >&2
    exit 1
  fi
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
# The checks run in a subshell this shell waits for, writing to a file in
# WORK, not in a process substitution: so nothing the check starts outlives
# it with the lock, and a check that stops early (its status) or a read that
# failed (READ_FAILURES) counts as a problem, never as a clean journal.
step "Verifying the recovery journal"
problems=()
"$RM" -f "$READ_FAILURES"
check_rc=0
( journal_problems ) > "$WORK/journal.lines" || check_rc=$?
while IFS= read -r line; do
  [[ -n "$line" ]] && problems+=("$line")
done < "$WORK/journal.lines"
if [[ -s "$READ_FAILURES" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && problems+=("the journal could not be fully checked: $line")
  done < "$READ_FAILURES"
fi
if (( check_rc != 0 )); then
  problems+=("the journal check stopped with status $check_rc, so the journal was not fully checked")
fi
if (( recovery_rc != 0 )) && (( ${#problems[@]} == 0 )); then
  problems+=("backstop exited $recovery_rc; see $LOG_DIR/insomnia.log")
fi
if (( ${#problems[@]} > 0 )); then
  abort_incomplete "$recovery_rc" "${problems[@]}"
fi
echo "journal clean"
# state.json is kept when a brightness it records cannot be restored here,
# and also when reading it again for that fails: a kept file is never the
# wrong way round.
kept_brightness=()
"$RM" -f "$READ_FAILURES"
kept_rc=0
( refused_brightness ) > "$WORK/kept.lines" || kept_rc=$?
while IFS= read -r line; do
  [[ -n "$line" ]] && kept_brightness+=("$line")
done < "$WORK/kept.lines"
kept_unknown=""
if [[ -s "$READ_FAILURES" ]]; then
  kept_unknown="$(head -n 1 "$READ_FAILURES")"
elif (( kept_rc != 0 )); then
  kept_unknown="the check stopped with status $kept_rc"
fi
if (( ${#kept_brightness[@]} > 0 )); then
  echo "Not restored, and kept in $STATE:"
  for line in "${kept_brightness[@]}"; do echo "  - $line"; done
  echo "Insomnia's private-call guard refused that restore on this macOS, so nothing here can"
  echo "make it. Set the level with the brightness keys or Control Center. The file stays so a"
  echo "later Insomnia that can make the call restores it at launch."
fi
if [[ -n "$kept_unknown" ]]; then
  echo "Reading $STATE again for a brightness Insomnia kept failed ($kept_unknown), so whether it holds one is unknown; it is kept."
fi
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

# Every sudo call here runs under the recovery lock, so each is `sudo -n`
# (the password was asked before the lock) and bounded: one that does not
# answer is sent SIGTERM, never SIGKILL, and one still running past the
# limit keeps the lock until it ends (see bounded()). Whenever whether the
# rule was removed is not known, the run stops with the app and the journal
# kept (sudoers_uncertain).
step "Removing $SUDOERS"
sudoers_present=0
if [[ -e "$SUDOERS" ]]; then
  sudoers_present=1
elif [[ ! -x "${SUDOERS%/*}" ]]; then
  # The folder cannot be searched without root, so only sudo can tell.
  test_rc=0
  bounded "$SUDO" -n "$TEST" -e "$SUDOERS" || test_rc=$?
  if (( test_rc == 0 )); then
    sudoers_present=1
  elif (( test_rc == 125 )); then
    sudoers_uncertain "'sudo -n test -e $SUDOERS' did not answer within ${CALL_TIMEOUT_SECONDS}s, so whether the rule is there is not known. $(sudo_alive_note). It keeps the recovery lock until it ends."
  elif (( test_rc != 1 )) || [[ -n "$BOUNDED_OUTPUT" ]]; then
    sudoers_uncertain "'sudo -n test -e $SUDOERS' $(call_result "$test_rc")${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}, so whether the rule is there is not known."
  fi
fi
if (( sudoers_present )); then
  # Root-only, so it is read through sudo.
  read_rc=0
  bounded "$SUDO" -n "$CAT" "$SUDOERS" || read_rc=$?
  if (( read_rc == 125 )); then
    sudoers_uncertain "'sudo -n cat $SUDOERS' did not answer within ${CALL_TIMEOUT_SECONDS}s, so the rule was not removed. $(sudo_alive_note). It keeps the recovery lock until it ends."
  elif (( read_rc != 0 )); then
    echo "Could not read $SUDOERS through sudo ('sudo -n cat' $(call_result "$read_rc")${BOUNDED_OUTPUT:+: $BOUNDED_OUTPUT}), so it was kept. The LaunchAgent is already removed; the app at $APP is not." >&2
    echo "Rerun this script, or check the file and remove it yourself with 'sudo rm $SUDOERS'." >&2
    exit 1
  fi
  # As the shell's $(...) would read it: trailing newlines cut.
  sudoers_text="${BOUNDED_OUTPUT%"${BOUNDED_OUTPUT##*[!$'\n']}"}"
  sudoers_why="$(sudoers_not_ours "$sudoers_text")"
  if [[ -z "$sudoers_why" ]]; then
    remove_rc=0
    sudoers_remove "$sudoers_text" || remove_rc=$?
    case "$remove_rc" in
      0) ;;
      3) echo "Kept $SUDOERS: $SUDOERS_LOCK stayed taken for ${LOCK_TIMEOUT_SECONDS}s, so another install.sh or uninstall.sh, perhaps in another account, is changing it." >&2 ;;
      4) echo "Kept $SUDOERS: it changed after this uninstall read it, or is not a regular file of root's with one link that only root can change (${BOUNDED_OUTPUT:-no detail}). Another install.sh or uninstall.sh, perhaps in another account, may have written or removed it meanwhile, and a rule written then may be another account's." >&2 ;;
      5) echo "Kept $SUDOERS: removing it failed (${BOUNDED_OUTPUT:-no detail})." >&2 ;;
      7) echo "Kept $SUDOERS: the lock file $SUDOERS_LOCK, or a folder above it, is not one only root can change (${BOUNDED_OUTPUT:-no detail}), so the lock that keeps two runs from changing the rule at once cannot be trusted. Nothing there was repaired: check it yourself (the lock file must be a regular file of root's with mode 0600 and one link)." >&2 ;;
      8) echo "Kept $SUDOERS: read again as root, it holds a NUL byte, changed while it was read, or is not the rule install.sh writes for $ACCOUNT${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}." >&2 ;;
      1 | 2) echo "Kept $SUDOERS: the sudo call that removes it exited $remove_rc before removing it${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}." >&2 ;;
      124) sudoers_uncertain "The sudo call that removes $SUDOERS did not answer within ${CALL_TIMEOUT_SECONDS}s and stopped on SIGTERM, so whether the rule was removed is not known." ;;
      125) sudoers_uncertain "The sudo call that removes $SUDOERS did not answer within ${CALL_TIMEOUT_SECONDS}s, so whether the rule was removed is not known. $(sudo_alive_note). It keeps the recovery lock until it ends, so until then the app cannot start a session; if it does not end by itself, stop it with 'sudo kill ${BOUNDED_PID:-<pid>}'." ;;
      *) sudoers_uncertain "The sudo call that removes $SUDOERS exited $remove_rc (a signal), so whether the rule was removed is not known." ;;
    esac
    if (( remove_rc != 0 )); then
      echo "The LaunchAgent is already removed; the app at $APP is not. Rerun this script to check the rule again." >&2
      exit 1
    fi
  elif [[ "$sudoers_why" == grants\ * ]]; then
    echo "Kept $SUDOERS: it $sudoers_why, not $ACCOUNT. Another account installed Insomnia after this one, and its app and agent need that rule to undo a session. Uninstall Insomnia in that account to remove it."
  else
    echo "Kept $SUDOERS: it is not the rule install.sh writes for $ACCOUNT ($sudoers_why). Check it, and remove it with 'sudo rm $SUDOERS' if nothing else needs it." >&2
  fi
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
APP_DIR="$(dirname "$APP")"
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
  remove_owned "$SESSION" "$APP_SUPPORT/config.json" "$APP_SUPPORT/backstop.sh" \
        "$APP_SUPPORT/unfinished-command.json" \
        "$LOG_DIR/insomnia.log" "$LOG_DIR/insomnia.log.1" \
        "$LOG_DIR/handoffs.log" "$LOG_DIR/handoffs.log.1"
  (( ${#kept_brightness[@]} > 0 )) || [[ -n "$kept_unknown" ]] || remove_owned "$STATE"
  collect_moved_aside_sessions
  if (( ${#MOVED_ASIDE[@]} > 0 )); then
    remove_owned "${MOVED_ASIDE[@]}"
  fi
  if (( ${#NOT_MOVED_ASIDE[@]} > 0 )); then
    for f in "${NOT_MOVED_ASIDE[@]}"; do
      echo "Left $f: it is named like a moved-aside session.json but is not a regular file, so purge does not remove it. Remove it yourself if you do not need it."
    done
  fi
  # The lock file itself is kept, even on purge: this process still holds
  # it, and anything that opened it a moment ago (a queued agent run, an app
  # launched after the check above) waits on this inode. Unlinking it would
  # let the next opener create a second lock nobody else sees. A leftover
  # empty lock file and its directory are the accepted cost.
  "$RMDIR" "$LOG_DIR" 2>/dev/null || true
  (( OWN_LAUNCH_AGENTS_DIR == 1 )) && { "$RMDIR" "$LAUNCH_AGENTS" 2>/dev/null || true; }
  echo "Kept $LOCK (the recovery lock is never unlinked; delete $APP_SUPPORT by hand if you want it gone)."
  [[ -d "$LOG_DIR" ]] && echo "Kept $LOG_DIR: it still holds files Insomnia did not create."
else
  # unfinished-command.json names a sudo pmset that held the recovery lock;
  # this run holds it now, so that command has exited.
  remove_owned "$APP_SUPPORT/backstop.sh" "$SESSION" "$APP_SUPPORT/unfinished-command.json"
  (( ${#kept_brightness[@]} > 0 )) || [[ -n "$kept_unknown" ]] || remove_owned "$STATE"
  echo "Kept $APP_SUPPORT/config.json and $LOG_DIR (use --purge to remove)."
  collect_moved_aside_sessions
  if (( ${#MOVED_ASIDE[@]} > 0 )); then
    echo "Kept ${#MOVED_ASIDE[@]} unreadable session.json file(s) moved aside in $APP_SUPPORT (use --purge to remove)."
  fi
  if (( ${#NOT_MOVED_ASIDE[@]} > 0 )); then
    for f in "${NOT_MOVED_ASIDE[@]}"; do
      echo "Kept $f: it is named like a moved-aside session.json but is not a regular file, so purge does not remove it either. Remove it yourself if you do not need it."
    done
  fi
fi
(( ${#kept_brightness[@]} == 0 )) || echo "Kept $STATE: it holds the brightness listed above."
[[ -z "$kept_unknown" ]] || echo "Kept $STATE: reading it again failed (see above)."

if (( remove_failures > 0 )); then
  echo "Done, except $remove_failures file(s) that could not be removed (named above)." >&2
  exit 1
fi
echo "Done."
