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
# number the app cannot decode, a key the app reads found twice in one
# object it reads, or text the check cannot follow makes the journal
# malformed: the same text check as backstop.sh (record_text_problems),
# which follows every object and array and checks what the app decodes,
# with the escapes in its keys decoded, as the app does. Where plutil would
# read the text otherwise than the app, the checks after it read the view
# of the journal that check writes, which holds what the app reads
# (journal_view).
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
# scripts/backstop.sh. Found without PATH or CDPATH: the folder part of
# this script's own path, cut off by parameter expansion rather than a
# dirname taken from PATH, and entered by cd with CDPATH empty, so neither
# a dirname nor a CDPATH folder chosen by the environment can name another
# folder, whose backstop.sh would then be run.
script_dir() {
  local dir="${BASH_SOURCE[0]}"
  case "$dir" in
    */*) dir="${dir%/*}" ;;
    *) dir=. ;;
  esac
  CDPATH='' cd -- "${dir:-/}" && pwd
}
SCRIPT_DIR="$(script_dir)"
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
CMP=/usr/bin/cmp
HEAD=/usr/bin/head
TR=/usr/bin/tr
ICONV=/usr/bin/iconv
AWK=/usr/bin/awk
ID=/usr/bin/id
# Two tools are taken by name, and neither reads state or chooses code.
# sleep only paces the polls in bounded() and the quit wait, and the tests
# that make every poll slow put their own sleep first in PATH. cat reads a
# sudo call's pid in bounded(), which is install.sh's word for word; this
# script never runs bounded() for sudo, so that cat never runs here.
LOCK_TIMEOUT_SECONDS=10
# Longest record_text_problems reads state.json before it says what the app
# makes of it is not known here, as in backstop.sh.
TEXT_READ_SECONDS=30
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
# place and keep (clear_lock_record), and after that as a line appended to
# $LOG_DIR/insomnia.log (record_end_in_log), which --purge removes only once
# session.json is gone and the line ends nothing.
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

# Shape check, same rules as backstop.sh: a JSON object whose known keys have
# the types RuntimeState.swift writes; null counts as absent.
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
  # sessionCutoffs is not checked, as in backstop.sh: the app reads a value
  # it does not write as none, and nothing here uses it.
  # The app's records about a kept display entry: never read for an undo
  # here, and they stay or go with state.json. Each must still decode, or
  # the app cannot read the journal at all.
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
          # app reads it, and the journal read here (journal_view) holds
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

is_refused() { # key
  [[ "$(extract "$JOURNAL" "$1" || true)" == "true" ]]
}

# Brightness the app kept after its private-call guard refused the restore
# on this macOS, one line per device with the saved level. Not a problem
# for uninstall: no step here can restore it.
refused_brightness() {
  local value
  [[ -f "$STATE" ]] || return 0
  if is_refused displayRestoreRefused && value="$(extract "$JOURNAL" savedDisplayBrightness)"; then
    echo "display brightness $value"
  fi
  if is_refused keyboardRestoreRefused && value="$(extract "$JOURNAL" savedKeyboardBrightness)"; then
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

# The journal as the app reads it, as in backstop.sh (check_journal): sets
# journal_text to what record_text_problems prints for state.json, and
# JOURNAL, which every read of the journal below uses, to state.json itself
# or, when plutil would read the text otherwise than the app ("view: "
# lines) or cannot parse it, to the view record_text_problems wrote in
# WORK. Run in this process, before journal_problems and refused_brightness,
# which run in subshells.
JOURNAL="$STATE"
journal_text=""
journal_view() {
  JOURNAL="$STATE"
  journal_text=""
  "$RM" -f "$WORK/call.state-view" 2>/dev/null || true
  [[ -f "$STATE" ]] || return 0
  journal_text="$(record_text_problems "$STATE" state "$WORK/call.state-view")"
  if [[ $'\n'"$journal_text" == *$'\n'"view: "* ]] || ! "$PLUTIL" -convert json -o /dev/null "$STATE" >/dev/null 2>&1; then
    [[ ! -f "$WORK/call.state-view" ]] || JOURNAL="$WORK/call.state-view"
  fi
}

# Independent check of the journal: prints one line per unresolved item.
# Trusts nothing about the backstop that just ran (it may be an older copy).
# Reads the journal journal_view chose.
journal_problems() {
  local key value shape i line
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
  # A line from record_text_problems other than "view: " and "record: ":
  # a value the app does not decode, or text whose meaning to the app is
  # not known here.
  shape=""
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == "view: "* || "$line" == "record: "* ]] || shape+="$line"$'\n'
  done <<< "$journal_text"
  shape="${shape%$'\n'}"
  if [[ -z "$shape" ]]; then
    if ! "$PLUTIL" -convert json -o /dev/null "$JOURNAL" >/dev/null 2>&1; then
      echo "state.json is unreadable or malformed"
      return 0
    fi
    shape="$(journal_shape_problems "$JOURNAL")"
  fi
  if [[ -n "$shape" ]]; then
    echo "state.json is malformed (unexpected shape):"
    echo "$shape"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen; do
    if [[ "$(extract "$JOURNAL" "$key" || true)" == "true" ]]; then
      echo "$key is still true"
    fi
  done
  value="$(extract_json "$JOURNAL" frozenProcesses || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "frozen processes are still journaled: $value"
  fi
  value="$(extract_json "$JOURNAL" frozenPids || true)"
  if [[ -n "$value" && "$value" != "[]" ]]; then
    echo "legacy frozen pids (no identity; the backstop never signals or clears these, only the app does): $value"
  fi
  if extract "$JOURNAL" savedOutputVolume >/dev/null || extract "$JOURNAL" savedMuted >/dev/null; then
    echo "saved audio settings (volume/mute) are not restored; only the app can do that"
  fi
  i=0
  while extract_json "$JOURNAL" "savedAudioOutputs.$i" >/dev/null; do
    value="$(extract "$JOURNAL" "savedAudioOutputs.$i.name" || extract "$JOURNAL" "savedAudioOutputs.$i.deviceUID" || true)"
    echo "$value is still muted from a lid close; only the app can restore its volume, once the device is connected"
    i=$((i + 1))
  done
  if extract "$JOURNAL" savedDisplayBrightness >/dev/null && ! is_refused displayRestoreRefused; then
    echo "saved display brightness is not restored; only the app can do that"
  fi
  if extract "$JOURNAL" savedKeyboardBrightness >/dev/null && ! is_refused keyboardRestoreRefused; then
    echo "saved keyboard backlight is not restored; only the app can do that"
  fi
  value="$(extract_json "$JOURNAL" appNapOverrides || true)"
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
  # shellcheck disable=SC2016  # the $0 below is awk's, not this shell's
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
journal_view
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
        "$LOG_DIR/handoffs.log" "$LOG_DIR/handoffs.log.1"
  # insomnia.log and insomnia.log.1 may hold the record of the end of the
  # session in session.json (record_end_in_log in backstop.sh). Once
  # session.json is gone that record ends nothing; a session.json still
  # there (one remove_owned could not remove) keeps both, as it keeps the
  # lock file's record.
  if [[ -e "$SESSION" || -L "$SESSION" ]]; then
    echo "Kept $LOG_DIR/insomnia.log and $LOG_DIR/insomnia.log.1: $SESSION is still there, and they may record its end."
  else
    remove_owned "$LOG_DIR/insomnia.log" "$LOG_DIR/insomnia.log.1"
  fi
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
