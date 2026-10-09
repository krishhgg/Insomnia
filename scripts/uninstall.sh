#!/bin/bash
# Reverse install.sh. Quits the app, takes the recovery lock, runs the current
# backstop with --force under that same lock (from a source checkout: the
# checkout's copy when the installed app declares the interface version it
# speaks, else the app's own: the one sealed in the bundle, else the writable
# copy older installs left in Application Support; from anywhere else, such
# as a release zip: the sealed copy only), verifies for itself that the
# journal is clean, checks under the receipt's lock that no start of
# another Insomnia folder of this user claims this user's receipt in
# /private/var/db/com.kgarg.insomnia, and only then, keeping that lock,
# removes the LaunchAgent, the sudoers rule, the receipt and its release
# file (the folder too, once empty), the app bundle (backstop.sh included),
# and the journal. A claim, a locked receipt or one it cannot read stops it
# with nothing removed. Keeps config.json
# and the logs unless --purge. Everything after the quit happens while this
# process holds APP_SUPPORT/.recovery.lock, so neither a queued periodic
# backstop nor a relaunched app can republish the journal while it is being
# removed.
#
# Right after the lock it deletes APP_SUPPORT/pending-start itself, because
# the backstop it runs may be an older copy that does not know the file: a
# password dialog left from an abandoned start must not turn sleep off once
# the rule that turns it back on is gone. It takes the marker's own lockf
# lock first, the lock the root command behind that dialog holds while it
# runs, and deletes it only while its path still names the locked file, so
# the marker never goes while that command is past its check. A
# marker that cannot be deleted stops the uninstall (see journal_problems).
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
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
CODESIGN=/usr/bin/codesign
LOCKF=/usr/bin/lockf
RM=/bin/rm
DEFAULTS=/usr/bin/defaults
KILL=/bin/kill
# sudo is given test, rm and rmdir by full path. Given a bare name, it would search
# the caller's PATH and run whatever it finds there as root.
TEST=/bin/test
STAT=/usr/bin/stat
DATE=/bin/date
MKDIR=/bin/mkdir
RMDIR=/bin/rmdir
MKTEMP=/usr/bin/mktemp
CP=/bin/cp
MV=/bin/mv
LS=/bin/ls
CAT=/bin/cat
HEAD=/usr/bin/head
TR=/usr/bin/tr
ID=/usr/bin/id
CMP=/usr/bin/cmp
# The folder of the root-owned receipts install.sh made
# (SleepOffReceipts.swift), and the one owner besides root it may have:
# none, as uid 0 is root. Tests patch both lines in a private copy.
RECEIPTS=/private/var/db/com.kgarg.insomnia
RECEIPT_OWNER=0
LOCK_TIMEOUT_SECONDS=10
# How long to wait for the root command behind a password dialog to let go
# of the pending-start marker.
PENDING_LOCK_TIMEOUT_SECONDS=10
# How long to wait for the receipt's lock: the root command holds it from
# its checks until pmset exits.
RECEIPT_LOCK_TIMEOUT_SECONDS=10
# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=10
# Longest one external call made by this script itself (pgrep, defaults,
# launchctl, codesign) may run before it is stopped with SIGTERM, then
# SIGKILL. A call made under the recovery lock keeps the lock until it has
# exited or been stopped, even if this run is killed first (see bounded()).
# backstop.sh bounds its own commands; the sudo calls of step 5
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
STATE="$APP_SUPPORT/state.json"
PENDING="$APP_SUPPORT/pending-start"
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

# Scratch space for bounded() and the journal reads (read.*): this run's
# own directory, emptied on exit.
WORK="$("$MKTEMP" -d "${TMPDIR:-/tmp}/insomnia-uninstall.XXXXXX")"
trap '"$RM" -f "$WORK"/call.* "$WORK"/read.* 2>/dev/null; "$RMDIR" "$WORK" 2>/dev/null || true' EXIT

# Run one external call with a time limit. Its combined output is left in
# BOUNDED_OUTPUT (trailing newline removed) and its exit status returned, or
# 124 when it did not finish within CALL_TIMEOUT_SECONDS and was stopped, or
# 125 when it is sudo and still running (pid in BOUNDED_PID; this script
# bounds no sudo call). The same helper as install.sh's, which says more.
# supervise() enforces the limit itself, even if this run is killed while it
# waits or its process group gets SIGTERM or SIGHUP: SIGTERM once the limit has passed on bash's SECONDS clock, SIGKILL
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
# The supervisor keeps fd 9 until the call has exited and been reaped, and
# the call may close its own copy (sudo does), so nothing else may end the
# supervisor first. It ignores SIGTERM and SIGHUP, which reach this run's
# whole process group when launchd stops what is left of a job or a
# terminal closes, and with errexit off a failed status write or a failed
# check does not end it either. The call gets the default actions back
# before it starts, so the SIGTERM at its limit can still stop it.
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

# Reads through plutil. A key path that is not there, and a key that holds
# null, count as absent, as for the app's decodeIfPresent: plutil reports
# the first as "No value at that key path", and gives the second the type
# "(any)". Any other failure (the file could not be opened or read, plutil
# failed) is not absence. It is added to READ_FAILURES, which the
# settlement and the journal check read before they trust what they found,
# and the read returns 2. What plutil printed is passed on byte for byte.
READ_FAILURES="$WORK/read.failures"
plutil_read() { # file keypath plutil-option...
  local f="$1" key="$2" out err="" rc=0 t
  shift 2
  out="$("$PLUTIL" "$@" -o - "$f" 2>"$WORK/read.err"; rc=$?; echo .; exit "$rc")" || rc=$?
  if (( rc == 0 )); then
    printf '%s' "${out%.}"
    return 0
  fi
  IFS= read -r -d '' err < "$WORK/read.err" || true
  err="${err%$'\n'}"
  if (( rc == 1 )) && [[ "$err" == *"No value at that key path or invalid key path: $key" ]]; then
    return 1
  fi
  if (( rc == 1 )) && [[ "$1" != -type ]] && t="$("$PLUTIL" -type "$key" -o - "$f" 2>/dev/null)" && [[ "$t" == "(any)" ]]; then
    return 1
  fi
  printf '%s\n' "$f, $key: plutil $1 exited $rc (${err:-no message})" >> "$READ_FAILURES"
  return 2
}
extract() { # file keypath (raw scalar; 1 if absent or null, 2 if the read failed)
  plutil_read "$1" "$2" -extract "$2" raw
}
extract_json() { # file keypath (1 if absent or null, 2 if the read failed)
  plutil_read "$1" "$2" -extract "$2" json
}
type_of() { # file keypath -> bool|integer|float|string|array|dictionary|(any); empty if absent or if the read failed
  plutil_read "$1" "$2" -type "$2" || true
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
# A file that cannot be opened, for either of the two reads here, returns 2
# with nothing printed for it: its records are unknown, not absent, and the
# caller must not count the journal as clean.
record_text_problems() { # file
  local LC_ALL=C
  local text rest raw key c token depth str plain scalar number esc hex lost nul=""
  local n_low=0 n_lit=0 n_boot=0 digits sig exp e10 lead
  str='^"([^"\\]|\\.)*"'
  plain='^[^]["{}]+'
  scalar='^[^],}[:space:]]+'
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  esc='^u00(4[1-9A-Fa-f]|5[0-9Aa]|6[1-9A-Fa-f]|7[0-9Aa])'
  hex='^u[0-9A-Fa-f]{4}'
  lost="the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked"
  text="$(<"$1")" || return 2
  [[ "$text" == *keptDisplay* || "$text" == *\\* ]] || return 0
  # A NUL byte ends this read with status 0, and the end of the file with
  # status 1. The group itself always ends with 0, so a failed status means
  # the file could not be opened a second time.
  { IFS= read -r -d '' c && nul=1; true; } < "$1" || return 2
  if [[ -n "$nul" ]]; then
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
# the types RuntimeState.swift writes; null counts as absent. Returns 2 when
# the file could not be converted or its text read; a failed key read is in
# READ_FAILURES, and what this printed after it may come from that failure.
journal_shape_problems() { # file
  local f="$1" key t i n json
  if ! json="$("$PLUTIL" -convert json -o - "$f" 2>/dev/null)"; then
    printf '%s\n' "$f: plutil -convert json failed" >> "$READ_FAILURES"
    return 2
  fi
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
  if ! record_text_problems "$f"; then
    printf '%s\n' "$f: its text could not be read for the kept display records" >> "$READ_FAILURES"
    return 2
  fi
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
  t="$(type_of "$f" sleepOffAttempt)"
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != dictionary ]]; then
      echo "sleepOffAttempt is a $t, not an object"
    else
      [[ "$(type_of "$f" sleepOffAttempt.nonce)" == string ]] || echo "sleepOffAttempt.nonce is not a string"
      [[ "$(type_of "$f" sleepOffAttempt.owedBefore)" == bool ]] || echo "sleepOffAttempt.owedBefore is not a bool"
      [[ "$(type_of "$f" sleepOffAttempt.receipt)" == string ]] || echo "sleepOffAttempt.receipt is not a string"
      [[ "$(type_of "$f" sleepOffAttempt.predecessor)" == string ]] || echo "sleepOffAttempt.predecessor is not a string"
      [[ "$(type_of "$f" sleepOffAttempt.deadline)" == integer ]] || echo "sleepOffAttempt.deadline is not an integer"
      [[ "$(type_of "$f" sleepOffAttempt.expires)" == integer ]] || echo "sleepOffAttempt.expires is not an integer"
      t="$(type_of "$f" sleepOffAttempt.marker)"
      [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "sleepOffAttempt.marker is a $t, not a string"
      t="$(type_of "$f" sleepOffAttempt.settled)"
      [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "sleepOffAttempt.settled is a $t, not a bool"
    fi
  fi
}

is_refused() { # key
  [[ "$(extract "$SNAP" "$1" || true)" == "true" ]]
}

# Brightness the app kept after its private-call guard refused the restore
# on this macOS, one line per device with the saved level. Not a problem
# for uninstall: no step here can restore it. Read from the copy
# journal_problems checked; a failed read is in READ_FAILURES.
refused_brightness() {
  local value
  [[ -n "$SNAP" ]] || return 0
  if is_refused displayRestoreRefused && value="$(extract "$SNAP" savedDisplayBrightness)"; then
    echo "display brightness $value"
  fi
  if is_refused keyboardRestoreRefused && value="$(extract "$SNAP" savedKeyboardBrightness)"; then
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
# state.json is read through one copy, SNAP, made with a time limit: a FIFO
# put in its place after the regular-file check below would block a plain
# read while this run holds the recovery lock. Every read sees the same
# bytes, and step 5 removes state.json only while it still has them.
# Returns 2, after the lines found so far, when a read failed: what it
# printed is then not the whole answer. A failed key read is also in
# READ_FAILURES, which the caller checks too.
SNAP=""
journal_problems() {
  local key value shape i rc=0
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
  if [[ -e "$PENDING" || -L "$PENDING" ]]; then
    echo "pending-start is still present, so a password dialog left from an abandoned start could still turn sleep off"
  fi
  : > "$READ_FAILURES"
  [[ -e "$STATE" ]] || return 0
  if [[ ! -f "$STATE" ]]; then
    echo "state.json is not a regular file, so it was not opened"
    return 0
  fi
  bounded "$CP" "$STATE" "$WORK/read.state.json" || rc=$?
  if (( rc == 124 )); then
    echo "state.json could not be copied to be read: cp did not answer within ${CALL_TIMEOUT_SECONDS}s"
    return 2
  elif (( rc != 0 )) || [[ -L "$WORK/read.state.json" || ! -f "$WORK/read.state.json" ]]; then
    echo "state.json could not be copied to be read: cp exited $rc${BOUNDED_OUTPUT:+ (${BOUNDED_OUTPUT%%$'\n'*})}"
    return 2
  fi
  SNAP="$WORK/read.state.json"
  if ! "$PLUTIL" -convert json -o /dev/null "$SNAP" >/dev/null 2>&1; then
    echo "state.json is unreadable or malformed"
    return 0
  fi
  if ! shape="$(journal_shape_problems "$SNAP")" || [[ -s "$READ_FAILURES" ]]; then
    echo "state.json could not be read whole, so whether it has the shape the app writes is unknown"
    return 2
  fi
  if [[ -n "$shape" ]]; then
    echo "state.json is malformed (unexpected shape):"
    echo "$shape"
    return 0
  fi
  if [[ "$(type_of "$SNAP" sleepOffAttempt)" == dictionary ]]; then
    echo "a start that never finished is still journaled (sleepOffAttempt), so whether it turned sleep off is not settled"
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen; do
    if [[ "$(extract "$SNAP" "$key" || true)" == "true" ]]; then
      echo "$key is still true"
    fi
  done
  value="$(extract_json "$SNAP" frozenProcesses || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "frozen processes are still journaled: $value"
  fi
  value="$(extract_json "$SNAP" frozenPids || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "legacy frozen pids (no identity; the backstop never signals or clears these, only the app does): $value"
  fi
  if extract "$SNAP" savedOutputVolume >/dev/null || extract "$SNAP" savedMuted >/dev/null; then
    echo "saved audio settings (volume/mute) are not restored; only the app can do that"
  fi
  i=0
  while extract_json "$SNAP" "savedAudioOutputs.$i" >/dev/null; do
    value="$(extract "$SNAP" "savedAudioOutputs.$i.name" || extract "$SNAP" "savedAudioOutputs.$i.deviceUID" || true)"
    echo "$value is still muted from a lid close; only the app can restore its volume, once the device is connected"
    i=$((i + 1))
  done
  if extract "$SNAP" savedDisplayBrightness >/dev/null && ! is_refused displayRestoreRefused; then
    echo "saved display brightness is not restored; only the app can do that"
  fi
  if extract "$SNAP" savedKeyboardBrightness >/dev/null && ! is_refused keyboardRestoreRefused; then
    echo "saved keyboard backlight is not restored; only the app can do that"
  fi
  value="$(extract_json "$SNAP" appNapOverrides || true)"
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

# Stops the uninstall when state.json could not be read whole: what it
# still journals is unknown, and nothing is removed for it.
abort_unknown() { # backstop exit status, lines...
  local rc="$1" p
  shift
  "$CAT" >&2 <<MSG

Uninstall stopped BEFORE removing anything: $STATE could not be read
whole, so what it still journals, including a brightness kept for a later
Insomnia, is unknown (backstop exit status $rc):
MSG
  for p in "$@"; do printf '  - %s\n' "$p" >&2; done
  "$CAT" >&2 <<MSG

The LaunchAgent, $SUDOERS, $APP, the session and the journal were kept.
Check that $STATE is a regular file you can read, then rerun.
MSG
  exit 1
}

# Removes $STATE, unless it holds a kept brightness, or it is not the file
# step 4 read: a journal that appeared or changed since then is left and
# counted.
remove_state() {
  local rc=0
  (( ${#kept_brightness[@]} == 0 )) || return 0
  [[ -e "$STATE" || -L "$STATE" ]] || return 0
  if [[ -z "$SNAP" ]]; then
    echo "Left $STATE: it appeared after the journal check, so it was not checked." >&2
    remove_failures=$((remove_failures + 1))
    return 0
  fi
  if [[ -f "$STATE" && ! -L "$STATE" ]]; then
    bounded "$CMP" -s "$STATE" "$SNAP" || rc=$?
    if (( rc != 0 )); then
      echo "Left $STATE: it is not the file the journal check read (cmp exit $rc), so it was not checked." >&2
      remove_failures=$((remove_failures + 1))
      return 0
    fi
  fi
  remove_owned "$STATE"
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
# file, anything else from the open or rm.
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
      "$RM" -f "$PENDING" 2>/dev/null || marker_rc=$?
    else
      marker_rc=3
    fi
  fi
  exec 8<&-
}

# No start is waiting on a password dialog while this process holds the
# lock, so a marker here is an abandoned start's (see the header). One that
# stays stops the uninstall in step 4 (journal_problems).
if [[ -e "$PENDING" || -L "$PENDING" ]]; then
  delete_pending_marker
fi

# A start journals sleepOffAttempt (RuntimeState.swift) together with
# sleepDisabledByUs before its password dialog can run anything, and
# removes it once it has finished or rolled back. One still here belongs to
# a start that never finished, or whose settlement could not finish. The
# root-owned receipt shows whether the command behind its dialog turned
# sleep off (SleepOffReceipts.swift), read under the receipt's own lock,
# which that command holds from before its checks until pmset exits. This
# script reads it with the same rules as the app and backstop.sh's
# settle_attempt, whatever happened to the marker:
#   - "never": the attempt has no marker (no dialog was shown); or the
#     receipt holds this start's nonce with "refused"; or another start's
#     line that names the same predecessor; or, once the start's expires
#     has passed (its command refuses from then on, while the wall clock
#     does not go back), the predecessor itself.
#   - "may": the receipt holds this start's "writing", a later start's
#     line, or, once expires has passed, anything else: a receipt that is
#     missing, replaced, unsafe or damaged.
#   - "undecided": the receipt stays locked or cannot be locked, or expires
#     has not passed and the receipt shows nothing yet: the dialog may
#     still be answered.
# Decided, session.json goes when its end is the attempt's deadline: its
# start never finished, so that session is never resumed (a SleepDisabled 1
# someone else set would read as still off). Then the journal records the
# decision while the claim is still held, as backstop.sh publishes it
# (copy, edit, verify, rename): sleepOffAttempt.settled, with
# sleepDisabledByUs as it was before the start (owedBefore) after "never",
# which keeps a restore an earlier session still owes, and set after "may",
# so the backstop below undoes it. Only then does the start's claim on the
# receipt go back (the release file) and the journal drop the attempt. A
# record already settled is only finished that way: the receipt is not read
# against it again, since once the claim went back a later start's lines
# may show something else. The backstop that runs may be an older copy that
# does not know sleepOffAttempt, so the start is settled here first.
# Undecided, or a lock, removal or journal write that fails before the
# decision is published, stops the uninstall before the backstop runs: no
# pmset runs, and the record, the sleep entry and the claim stay. A claim or
# removal that fails after it stops it too, with the decision journaled.
# The message says what was removed or written. Skipped for a journal that
# is missing, not a regular file or malformed, which step 4 reports.

# Prints why the receipt or a folder above it fails the checks, or nothing.
# Every check matches SleepOffReceipts.swift and the root command
# (AdministratorPrompt.swift): the receipt, its folder and each folder above
# up to /, by lstat, must be root's (or RECEIPT_OWNER's), with no write
# permission for group or others; the receipt a regular file with one link,
# 82 bytes and mode 600, the rest folders. No folder may have an access
# control entry that allows anything, and the receipt must have exactly the
# one install.sh adds (receipt_access_problem).
receipt_unsafe() {
  local f="$RECEIPTS/$UID_NUM" p="$RECEIPTS" listing
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
  receipt_access_problem "$f" "$UID_NUM"
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
# (SleepOffReceipts.lock), exactly as backstop.sh's lock_receipt: sets
# receipt_locked, or receipt_lock_why and, for a receipt that stayed locked
# or a lockf that failed, receipt_lock_busy=1, or for one that failed the
# checks before it was opened, receipt_lock_unsafe=1. unlock_receipt closes
# fd 7.
receipt_locked=""
lock_receipt() {
  local f="$RECEIPTS/$UID_NUM" why rc=0 opened
  receipt_locked=""; receipt_lock_why=""; receipt_lock_busy=0; receipt_lock_unsafe=0; receipt_read=0
  why="$(receipt_unsafe)"
  if [[ -n "$why" ]]; then receipt_lock_why="$why"; receipt_lock_unsafe=1; return 0; fi
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

# The receipt's line, read once per lock through fd 7 (receipt_read): sets
# receipt_nonce, receipt_pred and receipt_word, or receipt_read_why.
read_receipt() {
  local size content line
  receipt_nonce=""; receipt_pred=""; receipt_word=""; receipt_read_why=""; receipt_read=1
  size="$("$STAT" -f '%l %z' <&7 2>/dev/null)" || size=""
  if [[ "$size" != "1 82" ]]; then
    receipt_read_why="$RECEIPTS/$UID_NUM is not the 82-byte file install.sh made"
    return 0
  fi
  content="$("$HEAD" -c 83 <&7 2>/dev/null; echo .)"
  content="${content%.}"
  line="${content%$'\n'}"
  if (( ${#content} != 82 )) || [[ "$line" == "$content" ]] \
     || ! [[ "$line" =~ ^([0-9A-F-]{36})\ ([0-9A-F-]{36})\ (writing|refused)$ ]]; then
    receipt_read_why="$RECEIPTS/$UID_NUM does not hold two nonces and writing or refused"
    return 0
  fi
  receipt_nonce="${BASH_REMATCH[1]}"
  receipt_pred="${BASH_REMATCH[2]}"
  receipt_word="${BASH_REMATCH[3]}"
}

# The release file's line, as backstop.sh's read_release: sets
# release_nonce and release_word, or release_why.
read_release() {
  local rf="$RECEIPTS/$UID_NUM.released" content line
  release_nonce=""; release_word=""; release_why=""
  if [[ -L "$rf" || ! -f "$rf" || "$("$STAT" -f %z "$rf" 2>/dev/null)" != 42 ]]; then
    release_why="$rf is not the 42-byte file install.sh made. Run install.sh again"
    return 0
  fi
  content="$("$HEAD" -c 43 "$rf" 2>/dev/null; echo .)"
  content="${content%.}"
  line="${content%$'\n'}"
  if (( ${#content} != 42 )) || [[ "$line" == "$content" ]] \
     || ! [[ "$line" =~ ^([0-9A-F-]{36})\ (free|held)$ ]]; then
    release_why="$rf does not hold a nonce and free or held. Run install.sh again"
    return 0
  fi
  release_nonce="${BASH_REMATCH[1]}"
  release_word="${BASH_REMATCH[2]}"
}

# Writes "$1 $2" over the release file in place, then reads it back, as
# backstop.sh's write_release (no fsync(2) in the shell).
write_release() { # nonce free|held
  local rf="$RECEIPTS/$UID_NUM.released"
  [[ ! -L "$rf" && -f "$rf" && "$("$STAT" -f %z "$rf" 2>/dev/null)" == 42 ]] || return 1
  { printf '%s %s\n' "$1" "$2" 1<>"$rf"; } 2>/dev/null || return 1
  read_release
  [[ -z "$release_why" && "$release_nonce" == "$1" && "$release_word" == "$2" ]]
}

# Under the receipt's lock, gives back the claim of the start with nonce
# $1, as backstop.sh's give_back_claim: sets gave_back, or returns non-zero
# with claim_why.
give_back_claim() { # nonce
  gave_back=0; claim_why=""
  read_release
  if [[ -n "$release_why" ]]; then claim_why="$release_why"; return 1; fi
  [[ "$release_word" == held && "$release_nonce" == "$1" ]] || return 0
  (( receipt_read )) || read_receipt
  if [[ -z "$receipt_nonce" ]]; then claim_why="$receipt_read_why"; return 1; fi
  if ! write_release "$receipt_nonce" free; then claim_why="$RECEIPTS/$UID_NUM.released could not be written"; return 1; fi
  gave_back=1
}

# What the receipt shows about the journaled start, as backstop.sh's
# attempt_verdict: sets verdict to never, may or undecided and verdict_why.
attempt_verdict() { # nonce predecessor identity expires now has-marker
  local f="$RECEIPTS/$UID_NUM" over=0 until
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

# Prints why the folders from $1 up to / are not root's alone (the checks
# above, for folders only), or nothing. Step 5 removes the receipt as root
# only when this prints nothing for its folder.
folders_problem() { # folder
  local p="$1" listing
  local paths=()
  while [[ -n "$p" ]]; do paths+=("$p"); p="${p%/*}"; done
  paths+=(/)
  listing="$("$STAT" -f '%u %Lp %l %z %HT' "${paths[@]}" 2>/dev/null)" || listing=""
  if ! printf '%s\n' "$listing" | /usr/bin/awk -v o="$RECEIPT_OWNER" -v n="${#paths[@]}" '{ k = (NR == 1 || k) && NF == 5 && $5 == "Directory" && ($1 == 0 || $1 == o) && $2 !~ /[2367].?$/ }; END { exit !(k && NR == n) }'; then
    echo "$1 or a folder above it is not a folder, or is not root's alone"
    return 0
  fi
  listing="$("$LS" -lde "${paths[@]}" 2>/dev/null)" || listing=""
  if [[ -z "$listing" ]] || ! printf '%s\n' "$listing" | /usr/bin/awk '$1 ~ /^[0-9]+:$/ && / allow / { f = 1 }; END { exit f }'; then
    echo "$1 or a folder above it has an access control entry that allows changes, or could not be listed"
  fi
}

# Stops the uninstall with the start still journaled. No pmset has run.
settle_stop() { # why what-was-done
  unlock_receipt
  echo "The unfinished start is still journaled: $1." >&2
  if [[ -n "${2:-}" ]]; then
    echo "$2; nothing else was, and no pmset ran. Then rerun." >&2
  else
    echo "Nothing was removed and no pmset ran. Then rerun." >&2
  fi
  exit 1
}

# Publishes $STATE with the edits given (remove:KEYPATH or
# true:KEYPATH / false:KEYPATH), as one copy, edit, verify and rename.
# Returns non-zero, with nothing published and no copy left, when any step
# fails.
edit_state() { # edit...
  local tmp="$APP_SUPPORT/.state.json.uninstall.$$" e ok=1
  "$CP" "$STATE" "$tmp" || ok=0
  for e in "$@"; do
    (( ok == 1 )) || break
    case "$e" in
      remove:*) "$PLUTIL" -remove "${e#remove:}" "$tmp" >/dev/null 2>&1 || ok=0 ;;
      true:*|false:*) "$PLUTIL" -replace "${e#*:}" -bool "${e%%:*}" "$tmp" >/dev/null 2>&1 || ok=0 ;;
      *) ok=0 ;;
    esac
  done
  if (( ok == 1 )); then
    [[ "$("$PLUTIL" -convert json -o - "$tmp" 2>/dev/null | "$HEAD" -c 1)" == "{" ]] || ok=0
    [[ "$("$HEAD" -c 1 "$tmp")" == "{" ]] || ok=0
  fi
  if (( ok == 1 )) && "$MV" -f "$tmp" "$STATE"; then
    return 0
  fi
  "$RM" -f "$tmp"
  return 1
}

# Under the receipt's lock: gives a settled start's claim back and drops
# its record, or stops the uninstall saying what was done.
finish_settlement() { # nonce what-was-done
  give_back_claim "$1" || settle_stop "it is settled, but its claim on the receipt could not be given back ($claim_why)" "$2"
  edit_state remove:sleepOffAttempt || settle_stop "it is settled, but its settled record could not be removed from $STATE" "$2"
  unlock_receipt
  echo "the settlement is finished: $( (( gave_back )) && echo "the start's claim on the receipt was given back" || echo "the start held no claim on the receipt") and its record removed"
}

# Stops the uninstall before anything runs when a read of the journal for
# the settlement failed: whether a start is still journaled, or what it
# records, is unknown.
settle_unknown() {
  local first=""
  IFS= read -r first < "$READ_FAILURES" || true
  unlock_receipt
  echo "Uninstall stopped BEFORE removing anything: $STATE could not be read whole (${first:-a read failed}), so whether it journals a start that never finished, and what that start records, is unknown." >&2
  echo "Nothing was removed and no pmset ran. Check that $STATE is a regular file you can read, then rerun." >&2
  exit 1
}

settle_attempt() {
  local nonce owed receipt pred deadline expires now has_marker=0 owes removed="" shape settled
  : > "$READ_FAILURES"
  [[ -f "$STATE" ]] || return 0
  # A journal plutil cannot convert whole is left to the journal check
  # below, which stops the uninstall on it as unreadable or malformed
  # before anything is removed. Every read after this one that fails stops
  # it here.
  "$PLUTIL" -convert json -o /dev/null "$STATE" >/dev/null 2>&1 || return 0
  if [[ "$(type_of "$STATE" sleepOffAttempt)" != dictionary ]]; then
    [[ ! -s "$READ_FAILURES" ]] || settle_unknown
    return 0
  fi
  shape="$(journal_shape_problems "$STATE")" || settle_unknown
  [[ ! -s "$READ_FAILURES" ]] || settle_unknown
  [[ -z "$shape" ]] || return 0
  nonce="$(extract "$STATE" sleepOffAttempt.nonce || true)"
  settled="$(extract "$STATE" sleepOffAttempt.settled || true)"
  [[ ! -s "$READ_FAILURES" ]] || settle_unknown
  if [[ "$settled" == true ]]; then
    lock_receipt
    [[ -n "$receipt_locked" ]] || settle_stop "it is settled, but the receipt could not be locked to give its claim back ($receipt_lock_why)"
    echo "finishing the settlement of an earlier start, which the journal records as settled"
    finish_settlement "$nonce" ""
    return 0
  fi
  owed="$(extract "$STATE" sleepOffAttempt.owedBefore || true)"
  receipt="$(extract "$STATE" sleepOffAttempt.receipt || true)"
  pred="$(extract "$STATE" sleepOffAttempt.predecessor || true)"
  deadline="$(extract "$STATE" sleepOffAttempt.deadline || true)"
  expires="$(extract "$STATE" sleepOffAttempt.expires || true)"
  [[ "$(type_of "$STATE" sleepOffAttempt.marker)" == string ]] && has_marker=1
  [[ ! -s "$READ_FAILURES" ]] || settle_unknown
  lock_receipt
  now="$("$DATE" -u +%s 2>/dev/null)" || now=0
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  attempt_verdict "$nonce" "$pred" "$receipt" "$expires" "$now" "$has_marker"
  if [[ "$verdict" == undecided ]]; then
    settle_stop "it is not settled yet ($verdict_why). Wait for that to pass: a start's password dialog can be answered for about two minutes after it was shown, and a command it started holds the receipt until pmset exits"
  fi
  if [[ -z "$receipt_locked" ]]; then
    settle_stop "the receipt could not be locked to give its claim back ($receipt_lock_why)"
  fi
  if [[ "$verdict" == never ]]; then
    owes="$owed"
    echo "settling an unfinished start: its receipt shows the command behind its dialog never turned sleep off; sleepDisabledByUs goes back to $owed"
  else
    owes=true
    echo "settling an unfinished start as one that may have turned sleep off ($verdict_why); sleepDisabledByUs stays set"
  fi
  # Only a session.json this run can read as a session is matched; one it
  # cannot read is treated as expired by the backstop, and the app never
  # resumes it.
  if [[ -f "$SESSION" ]] && "$CAT" "$SESSION" >/dev/null 2>&1 && [[ -z "$(session_shape_problems "$SESSION")" ]] \
     && [[ "$(epoch_at "$SESSION" endsAt)" == "$deadline" ]]; then
    "$RM" -f "$SESSION" || settle_stop "$SESSION of that start could not be removed"
    removed="$SESSION was removed"
    echo "removed $SESSION: its start never finished"
  fi
  # The decision, published while the claim is still held.
  edit_state true:sleepOffAttempt.settled "$owes:sleepDisabledByUs" || settle_stop "the settled journal could not be published to $STATE" "$removed"
  if [[ -n "$removed" ]]; then removed="$removed, and the decision"; else removed="The decision"; fi
  finish_settlement "$nonce" "$removed was journaled in $STATE as settled"
}

settle_attempt

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
# The check's lines go through a file, so its status is kept. A read that
# failed makes what the journal holds unknown: that stops the uninstall
# whatever else was found, and nothing is removed.
problems=()
journal_rc=0
journal_problems > "$WORK/read.problems" || journal_rc=$?
{ while IFS= read -r line; do
  if [[ -n "$line" ]]; then problems+=("$line"); fi
done; } < "$WORK/read.problems" || journal_rc=2
if (( journal_rc != 0 )) || [[ -s "$READ_FAILURES" ]]; then
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then problems+=("$line"); fi
  done < "$READ_FAILURES" || true
  abort_unknown "$recovery_rc" ${problems[@]+"${problems[@]}"}
fi
if (( recovery_rc != 0 )) && (( ${#problems[@]} == 0 )); then
  problems+=("backstop exited $recovery_rc; see $LOG_DIR/insomnia.log")
fi
if (( ${#problems[@]} > 0 )); then
  abort_incomplete "$recovery_rc" "${problems[@]}"
fi
kept_brightness=()
refused_brightness > "$WORK/read.kept" || journal_rc=$?
{ while IFS= read -r line; do
  if [[ -n "$line" ]]; then kept_brightness+=("$line"); fi
done; } < "$WORK/read.kept" || journal_rc=2
if (( journal_rc != 0 )) || [[ -s "$READ_FAILURES" ]]; then
  problems=()
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then problems+=("$line"); fi
  done < "$READ_FAILURES" || true
  abort_unknown "$recovery_rc" ${problems[@]+"${problems[@]}"}
fi
echo "journal clean"
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

# The receipt, its release file, the sudoers rule and the app bundle are
# shared by every Insomnia folder of this user (INSOMNIA_HOME). Every
# folder's starts claim and settle through the receipt, every folder's
# restore runs through the rule, and every folder's LaunchAgent runs the
# backstop.sh sealed in the bundle. Step 4 found no unsettled start in this
# folder, but a start of another folder may not be settled yet, whether or
# not an app is running: its claim in the release file says so, and its
# settlement needs the receipt's line, the rule and the bundle. So before
# step 5 removes anything, the receipt is locked (lock_receipt, the lock a
# start claims it under) and both files are read under that lock. Step 5
# keeps the lock until the rule, the receipt and the bundle are gone, so no
# start can claim the receipt after this check, and a root command waiting
# for the lock then finds no receipt and refuses. The uninstall stops with
# nothing removed:
#   - while the receipt stays locked: the command behind a password dialog
#     may be running, or another folder may be settling a start;
#   - while the release file shows a claim, or a nonce other than the
#     receipt's;
#   - while either file or a folder above them cannot be read or fails the
#     checks, or the receipt changes while it is locked, since what they
#     show is then unknown.
# A receipt that fails its own checks cannot be locked, but no start can
# claim it either, since the app and the root command refuse it too. Only
# its release file is read then, and both files go when it shows no claim.
# The lock order is the one every reader keeps: the recovery lock (fd 9)
# first, then the receipt's. Another folder's app or backstop holds its
# own recovery lock, never this one, and waits for the receipt's for a
# limited time, so the two cannot wait on each other.
RECEIPT="$RECEIPTS/$UID_NUM"
RELEASED="$RECEIPT.released"
# Sets shared_why to why another Insomnia folder of this user may still
# need what step 5 removes, or to nothing. With a receipt that passes the
# checks, fd 7 stays locked (receipt_locked) when shared_why is empty.
# Records what the check saw in shared_seen and release_seen, which
# shared_unchanged compares against.
check_shared() {
  shared_why=""; shared_seen=none; release_seen=""; receipt_lock_why=""
  if [[ ! -e "$RECEIPTS" && ! -L "$RECEIPTS" ]]; then return 0; fi
  shared_why="$(folders_problem "$RECEIPTS")"
  [[ -z "$shared_why" ]] || return 0
  if [[ -L "$RECEIPT" || -L "$RELEASED" ]] || { [[ -e "$RECEIPT" ]] && [[ ! -f "$RECEIPT" ]]; } || { [[ -e "$RELEASED" ]] && [[ ! -f "$RELEASED" ]]; }; then
    shared_why="$RECEIPT or $RELEASED is not a regular file, so install.sh did not make it"
    return 0
  fi
  shared_seen=absent
  if [[ -e "$RECEIPT" ]]; then
    lock_receipt
    if [[ -n "$receipt_locked" ]]; then
      read_receipt
      if [[ -n "$receipt_read_why" ]]; then
        shared_why="$receipt_read_why"
        unlock_receipt
        return 0
      fi
      shared_seen="locked $receipt_locked $receipt_nonce $receipt_pred $receipt_word"
    elif (( receipt_lock_unsafe )); then
      shared_seen=unsafe
    else
      shared_why="$receipt_lock_why"
      return 0
    fi
  fi
  if [[ -e "$RELEASED" ]]; then
    read_release
    if [[ -n "$release_why" ]]; then
      shared_why="$release_why"
    elif [[ "$release_word" == held ]]; then
      shared_why="$RELEASED shows that a start ($release_nonce) claims the receipt and is not settled yet"
    elif [[ -n "$receipt_locked" && "$release_nonce" != "$receipt_nonce" ]]; then
      shared_why="$RELEASED holds $release_nonce free, not the receipt's own nonce, so it does not show that no start claims the receipt"
    fi
    release_seen="$release_nonce $release_word"
  fi
  [[ -z "$shared_why" ]] || unlock_receipt
}
# Succeeds while the receipt, the release file and their folder are as
# check_shared saw them; otherwise sets shared_why. A receipt locked there
# must still be the locked file, pass the checks and hold the same line.
shared_unchanged() {
  local now=none line
  shared_why=""
  if [[ "$shared_seen" == locked* ]]; then
    if [[ "$receipt_locked" != "$("$STAT" -f '%d:%i' "$RECEIPT" 2>/dev/null)" || -n "$(receipt_unsafe)" ]]; then
      shared_why="$RECEIPT was replaced, or stopped passing the checks, while it was locked"
      return 1
    fi
    # By path, which names the locked file: fd 7 was read to its end.
    line="$("$HEAD" -c 83 "$RECEIPT" 2>/dev/null; echo .)"
    now="locked $receipt_locked ${line%$'\n'.}"
  elif [[ -e "$RECEIPT" || -L "$RECEIPT" ]]; then
    if [[ -n "$(receipt_unsafe)" ]]; then now=unsafe; else now=lockable; fi
  elif [[ -e "$RECEIPTS" || -L "$RECEIPTS" ]]; then
    now=absent
  fi
  if [[ "$now" != "$shared_seen" ]]; then
    shared_why="$RECEIPTS or $RECEIPT changed after it was checked"
    return 1
  fi
  [[ "$shared_seen" != none ]] || return 0
  if [[ -n "$(folders_problem "$RECEIPTS")" ]]; then
    shared_why="$RECEIPTS or a folder above it stopped passing the checks after it was checked"
    return 1
  fi
  if [[ -e "$RELEASED" || -L "$RELEASED" ]]; then
    read_release
    if [[ -n "$release_why" || "$release_nonce $release_word" != "$release_seen" ]]; then
      shared_why="$RELEASED changed after it was checked"
      return 1
    fi
  elif [[ -n "$release_seen" ]]; then
    shared_why="$RELEASED went away after it was checked"
    return 1
  fi
}
step "Checking the receipt every Insomnia folder of this user shares"
check_shared
if [[ -n "$shared_why" ]]; then
  "$CAT" >&2 <<MSG

Uninstall stopped BEFORE removing anything: $shared_why.
Another Insomnia folder of this user may have a start that is not settled
yet, and its settlement needs the receipt, the sudoers rule that turns
sleep back on, and the app bundle whose backstop.sh its recovery agent runs.
The LaunchAgent, $SUDOERS, $APP, the receipt and the journal were kept.
Open Insomnia from that folder or let its recovery agent run, then rerun.
If no other Insomnia folder of yours has a start to settle, remove the
receipt and its release file by hand (sudo rm -f $RECEIPT $RELEASED)
once no Insomnia password dialog is open, then rerun.
MSG
  exit 1
fi
case "$shared_seen" in
  none) echo "no $RECEIPTS" ;;
  absent) echo "no receipt of this user in $RECEIPTS" ;;
  unsafe) echo "$RECEIPT cannot be locked ($receipt_lock_why), so no start can claim it, and no start claims it now" ;;
  *) echo "no start claims $RECEIPT; it stays locked until the rule, the receipt and the bundle are gone" ;;
esac

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

# The receipt, the release file and their folder must still be as the
# check before step 5 saw them, under the receipt's lock it still holds.
step "Removing $SUDOERS (requires your password)"
if ! shared_unchanged; then
  "$CAT" >&2 <<MSG

Uninstall stopped after removing the LaunchAgent: $shared_why.
$SUDOERS, $APP, the receipt and the journal were kept. Rerun this script.
MSG
  exit 1
fi
if [[ -e "$SUDOERS" ]] || "$SUDO" "$TEST" -e "$SUDOERS"; then
  "$SUDO" "$RM" -f "$SUDOERS"
fi

# The receipt and its release file, which no start claims (see the check
# before step 5), and their folder once empty: other accounts on this Mac
# keep theirs. Root removes them only while the folder and every folder
# above it are root's alone, so no folder on the path given to rm can be
# changed by anyone else, and while the receipt is the file it locked.
# Another Insomnia folder of this user then needs install.sh again before
# its next start.
step "Removing the receipt $RECEIPT"
if [[ "$shared_seen" == none ]]; then
  echo "no $RECEIPTS"
else
  if ! shared_unchanged; then
    echo "Left $RECEIPT and $RELEASED: $shared_why. Remove them by hand (sudo rm -f $RECEIPT $RELEASED) once no Insomnia folder of yours has a start to settle, or leave them for a later install." >&2
    remove_failures=$((remove_failures + 1))
  else
    for receipt_file in "$RECEIPT" "$RELEASED"; do
      [[ -f "$receipt_file" ]] || continue
      if "$SUDO" "$RM" -f "$receipt_file"; then
        echo "removed $receipt_file"
      else
        echo "Could not remove $receipt_file." >&2
        remove_failures=$((remove_failures + 1))
      fi
    done
  fi
  if "$SUDO" "$RMDIR" "$RECEIPTS" 2>/dev/null; then
    echo "removed $RECEIPTS"
  else
    echo "kept $RECEIPTS: it still holds another account's receipt, or could not be removed"
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
# The bundle was the last thing another Insomnia folder of this user could
# need; a start of one that waits for the receipt's lock finds it gone.
unlock_receipt

# $APP_SUPPORT/backstop.sh below is the writable copy of older installs; the
# current one went with the bundle.
if (( PURGE == 1 )); then
  step "Purging Insomnia's files in $APP_SUPPORT and $LOG_DIR"
  remove_owned "$SESSION" "$APP_SUPPORT/config.json" "$APP_SUPPORT/backstop.sh" \
        "$APP_SUPPORT/unfinished-command.json" \
        "$LOG_DIR/insomnia.log" "$LOG_DIR/insomnia.log.1" \
        "$LOG_DIR/handoffs.log" "$LOG_DIR/handoffs.log.1"
  remove_state
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
  remove_state
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

if (( remove_failures > 0 )); then
  echo "Done, except $remove_failures file(s) that could not be removed (named above)." >&2
  exit 1
fi
echo "Done."
