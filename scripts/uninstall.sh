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
# What root's shell reads access control lists with (r_acl_reader): no
# module, only its own fgetattrlist call, read only, never a change.
PERL=/usr/bin/perl
# What root's shell asks whether an access control list entry is root's own
# (r_root): read only, never a change.
DSMEMBERUTIL=/usr/bin/dsmemberutil
# The most bytes read_fd3 takes from one call's output (or the notes): a
# longer one reads as not read back.
READ_MAX_BYTES=1048576
# How long bounded() waits for a call's output once its status has come: the
# supervisor reads it back in that time, or it counts as not read back.
READ_GRACE_SECONDS=5
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
# Longest backstop.sh may run in step 3 before it is sent SIGTERM (see
# run_backstop).
BACKSTOP_TIMEOUT_SECONDS=300
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
trap '"$RM" -f "$WORK"/call.* "$WORK"/notes.* "$WORK"/*.json 2>/dev/null; "$RMDIR" "$WORK" 2>/dev/null || true' EXIT

# Run one external call with a time limit. Its exit status is returned, or
# 124 when it did not finish within CALL_TIMEOUT_SECONDS and was stopped, or
# 125 when no status came back in time (sudo still running after its
# SIGTERM, any other call not ended two seconds after its SIGKILL, or a
# process left in the own group of a BOUNDED_OWN_GROUP call; pid in
# BOUNDED_PID), which no caller takes for a call that changed nothing, or
# 126 when no file for its output could be made. Its output is read back
# once, inside the supervisor after the call has been reaped, and comes down
# a pipe with the pid and the status: into READ_TEXT and READ_HEAD, with
# read_fd3's status in BOUNDED_READ, and into BOUNDED_OUTPUT (the text before
# any NUL byte, trailing newline removed; empty when not read back). The same
# helper as install.sh's, which says more. supervise() enforces the limit
# itself, even if this run is killed while it waits: SIGTERM once the limit
# has passed on bash's SECONDS clock, SIGKILL one to two seconds later, never
# SIGKILL for sudo. The supervisor and the call keep fd 9 (the recovery lock)
# until the call has exited, so a launchctl bootout made under the lock
# cannot unload an agent the app confirms after this run is gone, and a sudo
# that ignores SIGTERM keeps the lock until it ends. BOUNDED_LIMIT and
# BOUNDED_TERM_ONLY give one call another limit, or SIGTERM only, and
# BOUNDED_OWN_GROUP a process group of its own that no signal sent to this
# run's group reaches (see run_backstop).
BOUNDED_OUTPUT=""
BOUNDED_READ=2
BOUNDED_PID=""
BOUNDED_LIMIT=""
BOUNDED_TERM_ONLY=""
BOUNDED_OWN_GROUP=""
bounded() { # command args...
  local limit="${BOUNDED_LIMIT:-$CALL_TIMEOUT_SECONDS}" term_only=0 deadline pid="" rc=""
  if [[ "$1" == "$SUDO" || -n "${BOUNDED_TERM_ONLY:-}" ]]; then term_only=1; fi
  BOUNDED_OUTPUT=""
  BOUNDED_READ=2
  BOUNDED_PID=""
  READ_TEXT=""
  READ_HEAD=""
  # The supervisor's limit (at most a second over), then at least two
  # seconds for the call to stop on SIGTERM, and for any other call two more
  # for its SIGKILL and its reap.
  deadline=$(( SECONDS + limit + 3 + 2 * (1 - term_only) ))
  exec 5< <(
    exec 2>/dev/null
    if [[ -n "${BOUNDED_OWN_GROUP:-}" ]]; then set -m; fi
    supervise "$limit" "$term_only" "$@" </dev/null &
    set +m
  )
  if pipe_field "$deadline" && [[ "$FIELD" =~ ^[0-9]*$ ]]; then
    pid="$FIELD"
    if pipe_field "$deadline" && [[ "$FIELD" =~ ^[0-9]{1,3}$ ]] && (( 10#$FIELD <= 255 )); then rc=$(( 10#$FIELD )); fi
  fi
  if [[ -z "$rc" ]]; then
    # The pid is for messages only: nothing here signals it.
    exec 5<&-
    BOUNDED_PID="$pid"
    return 125
  fi
  BOUNDED_READ=0
  take_output "$(( SECONDS + READ_GRACE_SECONDS ))" || BOUNDED_READ=$?
  exec 5<&-
  BOUNDED_OUTPUT="${READ_HEAD%$'\n'}"
  return "$rc"
}
# Whether no process is left in process group $1, by kill with signal 0,
# which sends nothing. A group that still has a process this account may not
# signal (one running as root) is not gone. perl, at its fixed path, tells
# "no such group" apart from "not permitted"; when it cannot run, the group
# is not gone either.
group_gone() { # process group id
  # shellcheck disable=SC2016  # $ARGV and $! are perl's
  "$PERL" -e 'kill(0, -$ARGV[0]) and exit 1; exit($!{ESRCH} ? 0 : 1)' -- "$1" 2>/dev/null
}
# The supervising process of one bounded() call; it runs in the background,
# its standard output the pipe bounded() reads. Down that pipe it sends, as
# fields that each end in a NUL byte, the call's pid once the call has
# started (empty, then 126, when no file for its output could be made, and
# the call is not made), the call's status once it has been reaped, and
# then the call's output (send_output). No pid or status file is written,
# and the output file has no name while the call runs (see pin_output), so
# nothing put at a name can hold the supervisor, the lock it keeps, or
# bounded(). bounded() stops reading at its deadline and closes the pipe; a
# send after that fails (SIGPIPE is ignored here) and does not end the
# supervisor, which goes on until it has reaped the call.
# The call is its only job, so `kill %1` signals the call, and the shell
# skips a job it has already reaped: a reused pid is never signalled. Bash
# records that job under the process group the supervisor was started in,
# and when that is a group of its own (BOUNDED_OWN_GROUP), `kill %1` would
# signal the whole group, the call's own children too. Turning job control
# on and off again before the call starts clears that record, so `kill %1`
# always signals the call alone. The status is sent only once bash no longer
# lists the call as running, so a wait that returned early is made again.
# Like backstop.sh's supervisor, it ignores SIGTERM and SIGHUP, so a signal
# sent to this run's whole process group (a closed terminal, or launchd once
# a job's main process has gone) does not end it while its call runs. sudo
# closes its copy of fd 9, so the supervisor may be the only holder of the
# recovery lock until the call has exited. The call gets back the SIGTERM,
# SIGHUP and SIGPIPE actions this script started with, so it still stops on
# the SIGTERM at its limit, and on one sent to the group when it shares this
# run's group. It gets none of the descriptors the supervisor reads from or
# writes to but its output. errexit is off here: a failed write must not end
# the supervisor while its call runs.
# A call with BOUNDED_OWN_GROUP (the backstop) starts through perl, which
# makes it the leader of a new process group, with its pid as the group's
# id, before it runs the command. Bash's record of the job is unchanged, so
# `kill %1` still signals the call alone. What the call starts stays in that
# group unless it leaves it, and a process that sudo started may have closed
# its copy of fd 9. So once the call has been reaped, the supervisor checks
# the group, for up to about a second while what is left of it exits. When
# a process is still in it after that, the supervisor sends no status, which
# bounded() reports as 125, closes the pipe, and keeps fd 9 (and with it the
# recovery lock) until the group is empty, checking every half second. It
# never signals the group. The group's id cannot go to another process while
# the group has a process in it; once it is empty, another process can take
# that pid and lead a group with it before the next check, and the
# supervisor then waits for that group too.
supervise() { # limit term-only command args...
  local limit="$1" term_only="$2" base cpid rc=0 status deadline polls=0
  shift 2
  set +e
  trap '' TERM HUP PIPE
  base="$("$MKTEMP" "$WORK/call.XXXXXX" 2>/dev/null)"
  if [[ -z "$base" ]] || ! pin_output "$base"; then
    printf '%s\0' "" 126 2 "" "" end
    [[ -z "$base" ]] || "$RM" -f "$base" 2>/dev/null
    return
  fi
  set -m
  set +m
  if [[ -n "${BOUNDED_OWN_GROUP:-}" ]]; then
    # shellcheck disable=SC2016  # $ARGV is perl's
    ( trap - TERM HUP PIPE; exec "$PERL" -e 'setpgrp(0, 0) or exit 127; exec { $ARGV[0] } @ARGV; exit 127' -- "$@" ) </dev/null >&4 2>&4 3<&- 4>&- 6<&- 7<&- &
  else
    ( trap - TERM HUP PIPE; exec "$@" ) </dev/null >&4 2>&4 3<&- 4>&- 6<&- 7<&- &
  fi
  cpid=$!
  exec 4>&-
  printf '%s\0' "$cpid"
  deadline=$(( SECONDS + limit ))
  while kill -0 "$cpid" 2>/dev/null && (( SECONDS <= deadline )); do
    if (( polls < 50 )); then sleep 0.002; else sleep 0.05; fi
    polls=$((polls + 1))
  done
  # Past the limit, and the shell has not reaped the call: it is still there.
  if (( SECONDS > deadline )) && [[ -n "$(jobs -rp)" ]]; then
    kill -TERM %1 2>/dev/null || true
    if (( ! term_only )); then
      deadline=$(( SECONDS + 1 ))
      while [[ -n "$(jobs -rp)" ]] && (( SECONDS <= deadline )); do
        sleep 0.01
      done
      if [[ -n "$(jobs -rp)" ]]; then kill -KILL %1 2>/dev/null || true; fi
    fi
    rc=124
  fi
  status=0
  wait "$cpid" 2>/dev/null || status=$?
  while [[ -n "$(jobs -rp)" ]]; do
    status=0
    wait "$cpid" 2>/dev/null || status=$?
  done
  (( rc == 124 )) || rc=$status
  if [[ -n "${BOUNDED_OWN_GROUP:-}" ]]; then
    polls=0
    until group_gone "$cpid"; do
      if (( polls >= 10 )); then
        exec 1>&-
        until group_gone "$cpid"; do sleep 0.5; done
        return
      fi
      sleep 0.1
      polls=$((polls + 1))
    done
  fi
  printf '%s\0' "$rc" || return
  send_output
}
# backstop.sh, run as one bounded call with its own limit,
# BACKSTOP_TIMEOUT_SECONDS, and SIGTERM only, never SIGKILL: on SIGTERM it
# removes its private files and ends, while each sudo pmset or app binary
# call it started keeps the recovery lock through its own supervisor until
# that call has exited. It shares this run's lock through fd 9, which the
# supervisor here keeps until the backstop has exited, even if this run is
# killed first. The supervisor runs in a process group of its own, and the
# backstop in another, which it leads (BOUNDED_OWN_GROUP, see supervise), so
# a signal sent to this run's group (a closed terminal, or launchd once this
# run has gone) reaches nothing the backstop started, and the SIGTERM at the
# limit goes to the backstop process alone. So a backstop from an older
# build, whose supervisor for sudo pmset does not ignore SIGTERM and SIGHUP,
# still keeps the lock in that supervisor until its sudo has ended and been
# reaped. One from before the recovery lock ran sudo pmset in the
# foreground with no supervisor: once the SIGTERM at the limit has ended
# it, its sudo, which closed its fd 9, runs on in the backstop's group, and
# the supervisor here keeps the lock until that group is empty. The
# InsomniaResumeFrozenVersion read before the lock, and the identity of the
# file it came from, go down in its environment (see read_info_version).
# Returns the backstop's status, or 124 when it was stopped at its limit,
# 125 when it was still running three seconds after its SIGTERM or, once it
# had ended, a process it started was still in its group (pid in
# BOUNDED_PID; the lock stays held until they have ended), 126 when it was
# not started, with the reason in BACKSTOP_NOT_STARTED. What it printed is
# printed once it ends, unless it is 125. Without an executable $PERL the
# backstop is not started: perl both starts it in its own group and tells
# the supervisor when that group is empty, and a supervisor that can never
# tell would keep the lock for good. A perl that runs but cannot answer
# leaves the group unknown, and the supervisor keeps the lock.
run_backstop() { # backstop.sh
  local rc=0 BOUNDED_LIMIT="$BACKSTOP_TIMEOUT_SECONDS" BOUNDED_TERM_ONLY=1 BOUNDED_OWN_GROUP=1
  local INSOMNIA_INFO_PATH="$INFO_PLIST" INSOMNIA_INFO_EVIDENCE="$INFO_EVIDENCE" INSOMNIA_INFO_VERSION="$INFO_VERSION"
  export INSOMNIA_INFO_PATH INSOMNIA_INFO_EVIDENCE INSOMNIA_INFO_VERSION
  if [[ ! -x "$PERL" ]]; then
    BACKSTOP_NOT_STARTED="$PERL, which starts it in a process group of its own and tells when that group is empty, is missing"
    return 126
  fi
  BACKSTOP_NOT_STARTED="no file for its output could be made in $WORK"
  bounded /bin/bash "$1" --force || rc=$?
  if [[ -n "$BOUNDED_OUTPUT" ]]; then printf '%s\n' "$BOUNDED_OUTPUT"; fi
  return "$rc"
}

# Fail closed on paths that are not the exact things install.sh created.
case "$APP_SUPPORT" in /*) ;; *) echo "refusing: app support path is not absolute: $APP_SUPPORT" >&2; exit 1 ;; esac
[[ "$(basename "$APP")" == "Insomnia.app" ]] || { echo "refusing: $APP is not an Insomnia.app bundle path" >&2; exit 1; }

# Reads made under the recovery lock (the journal, config.json) are bounded
# calls, so none can keep the lock waiting, and each has an explicit result:
# 0 with the value; 1 when plutil said in so many words that the key path
# holds no value or only null (or, for -convert, that the file does not
# parse, which every caller reports as a problem); 2 when it failed any
# other way, did not answer in time, or its output could not be read back
# whole. A 2 is noted (see notes_reset), and every caller passes it on, so
# the check that made the read returns 2 and its caller treats the 2, or a
# note, as a check that did not complete: never a clean journal, and never
# an absent value. Once a read has failed, the rest return 2 at once: they
# would most likely wait the same way.
# What a bounded call printed is read back inside its supervisor, never by
# its caller. The supervisor (supervise in install.sh and uninstall.sh;
# read_unit and supervise_command in backstop.sh) makes the file
# for the call's output with mktemp, opens it twice, on fd 4 for the call to
# write and on fd 3 to read back from its start, and removes its name before
# the call starts (pin_output). From then on the file has no name, so no
# other process can open it, write it, or put a FIFO or another file in its
# place: only the call, what it starts and the supervisor reach it, through
# those descriptors. (A process of this account that opens the name in the
# few milliseconds between mktemp and the removal keeps what it opened; a
# FIFO or a file it puts there instead fails the checks.) Once the call has
# been reaped, the supervisor reads fd 3 to its end (read_fd3) and sends the
# result down the pipe its caller reads (send_output), and the caller waits
# for it no longer than its own deadline (take_output). The pid and the
# status come down the same pipe. So the caller opens no file of the call's
# and reads none, and a read that stalls holds the supervisor, which keeps
# the recovery lock while it lives, while the caller counts the output as
# not read back.
# The app binary in backstop.sh has to be a child of the backstop shell
# itself, which makes and pins its two files; only the read back runs in a
# process of its own there (see run_app_bounded).

# Opens the file mktemp has just made, $1, on fd 4 and on fd 3, each
# read-write, so a FIFO put at the name cannot hold the open; checks that
# both are one empty regular file; and removes the name. 1 when any of that
# fails. (macOS gives /dev/fd/N the device of /dev, not of the file, so the
# two descriptors can be compared with each other but not with the name.)
pin_output() { # file
  [[ -f "$1" && ! -L "$1" ]] || return 1
  exec 4<>"$1" 3<>"$1" || return 1
  [[ -f /dev/fd/4 && ! -s /dev/fd/4 && /dev/fd/3 -ef /dev/fd/4 ]] || return 1
  "$RM" -f "$1" || return 1
  [[ ! -e "$1" && ! -L "$1" ]]
} 2>/dev/null
# Reads fd 3 from where it stands to its end into READ_TEXT byte for byte,
# without $(...), which drops NUL bytes and trailing newlines. fd 3 must be a
# regular file, and at most READ_MAX_BYTES are taken from it, so a file that
# keeps growing cannot hold the read. One more read after its end must find
# nothing: a byte there was written while the file was read, by something the
# call left running, and the text could stop anywhere.
# Returns 0 when all of it was read; 1 when it has a NUL byte, which no shell
# variable can hold (READ_TEXT is then the text without them and trailing
# newlines, and READ_HEAD the text before the first); 2 when it is not a
# regular file, is longer than READ_MAX_BYTES, could not be read (bash leaves
# the variable of a read that failed unset, and sets it at the end of the
# file), or grew while it was read. READ_HEAD is READ_TEXT otherwise.
read_fd3() { # -> READ_TEXT, READ_HEAD
  local LC_ALL=C part text="" head="" nul=0 left=$(( READ_MAX_BYTES + 1 ))
  READ_TEXT=""
  READ_HEAD=""
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
  unset -v part
  if IFS= read -r -d '' -n 1 -u 3 part; then return 2; fi
  [[ -n "${part+set}" && -z "$part" ]] || return 2
  if (( nul )); then
    READ_HEAD="$head"
    READ_TEXT="${text%"${text##*[!$'\n']}"}"
    return 1
  fi
  READ_TEXT="$text"
  READ_HEAD="$text"
  return 0
} 2>/dev/null
# Sends what read_fd3 reads to standard output, the pipe to the caller, as
# four fields that each end in a NUL byte: read_fd3's status, READ_TEXT,
# READ_HEAD when it differs from READ_TEXT (a NUL byte; empty otherwise, so
# no text goes twice), and "end".
send_output() {
  local status=0
  read_fd3 || status=$?
  (( status == 1 )) || READ_HEAD=""
  printf '%s\0' "$status" "$READ_TEXT" "$READ_HEAD" end
}
# The next field from fd 5, the pipe from a supervisor, in FIELD: 1 when no
# whole field came by the deadline, a time on bash's SECONDS clock (the wait
# lasts until the clock has gone past it), or the pipe ended first.
FIELD=""
pipe_field() { # deadline
  local seconds=$(( $1 - SECONDS + 1 ))
  FIELD=""
  (( seconds > 0 )) || return 1
  IFS= read -r -d '' -t "$seconds" -u 5 FIELD
} 2>/dev/null
# The four fields send_output sends, from fd 5, in READ_TEXT and READ_HEAD,
# waiting no later than the deadline: their status (see read_fd3), or 2 when
# they did not all come, in that form, by then. It then waits, no later than
# the deadline either, for the end of the pipe, which comes once the sender
# has exited (or closed it), so a sender that has sent all it had is gone,
# with the lock it kept, before the caller goes on.
take_output() { # deadline
  local status text head
  READ_TEXT=""
  READ_HEAD=""
  pipe_field "$1" && [[ "$FIELD" =~ ^[012]$ ]] || return 2
  status="$FIELD"
  pipe_field "$1" || return 2
  text="$FIELD"
  pipe_field "$1" || return 2
  head="$FIELD"
  pipe_field "$1" && [[ "$FIELD" == end ]] || return 2
  pipe_field "$1" || true
  (( status == 1 )) || head="$text"
  READ_TEXT="$text"
  READ_HEAD="$head"
  return "$status"
}
# Notes of reads that failed. A read made inside $(...) has to reach this
# shell, so the notes go to a file: notes_reset makes one with
# mktemp in WORK, opens it and removes its name as pin_output does, and keeps
# it on fd 7, which note writes to, and on fd 6, which notes_read reads from.
# Each $(...) writes through the same fd 7. noted is true once a note is
# there, and also when no file for them could be made: every read then
# counts as failed. notes_read reads them in a process of its own, as a
# supervisor reads a call's output (send_output), and waits for them no
# longer than READ_GRACE_SECONDS. It reads on from where the last one
# stopped, so once after each notes_reset. A note whose write fails is lost.
NOTES_BROKEN=1
notes_reset() {
  local file
  NOTES_BROKEN=1
  exec 6<&- 7<&-
  file="$("$MKTEMP" "$WORK/notes.XXXXXX" 2>/dev/null)" || file=""
  if [[ -n "$file" ]] && pin_output "$file"; then
    exec 7>&4 6<&3
    NOTES_BROKEN=0
  elif [[ -n "$file" ]]; then
    "$RM" -f "$file" 2>/dev/null || true
  fi
  exec 3<&- 4>&-
  return 0
}
noted() {
  (( NOTES_BROKEN )) || [[ -s /dev/fd/7 ]]
}
note() { # line
  printf '%s\n' "$1" >&7 || true
} 2>/dev/null
notes_read() { # -> READ_TEXT
  local rc=0
  READ_TEXT=""
  READ_HEAD=""
  if (( NOTES_BROKEN )); then
    READ_TEXT="no file for the notes of failed reads could be made in $WORK"
    return 0
  fi
  exec 5< <(exec 3<&6 </dev/null 2>/dev/null; send_output)
  take_output "$(( SECONDS + READ_GRACE_SECONDS ))" || rc=$?
  exec 5<&-
  (( rc != 2 )) || return 2
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
  ! noted || return 2
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
  note "'plutil $1 $2' on ${file##*/} $why"
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
# Reads file $1 whole into WHOLE_TEXT (and WHOLE_HEAD, see read_fd3) with
# one bounded cat, so a FIFO or a stalled disk cannot keep the lock waiting:
# 0, 1 when it has a NUL byte, or 2 when the read failed or did not answer
# (noted; see notes_reset).
read_whole() { # file -> WHOLE_TEXT, WHOLE_HEAD
  local rc=0 why
  WHOLE_TEXT=""
  WHOLE_HEAD=""
  ! noted || return 2
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
  note "'cat' on ${1##*/} $why"
  return 2
}
# Copies the regular file $1 to $2, in WORK, with one bounded cp, so the
# checks read a private copy that cannot block or change under them. This
# shell makes the copy first, empty, so it has this run's mode, which lets
# its owner read it; cp writes into it and keeps that mode. cp -X copies no
# extended attributes or ACL: a journal its owner can read only through an
# ACL entry (mode 0200, say) would otherwise make cp fail or leave a copy
# its mode keeps unreadable. The empty copy is opened read-write, which
# does not wait as a write-only open of a FIFO would, should one be put at
# the name once it has been removed, and must then be a regular file.
# Returns cp's status as bounded() gives it: cp's own, or 124, 125 or 126
# when cp did not answer in time, sent no status, or could not start (see
# bounded; backstop.sh's gives no 125); or 1 when the empty copy could not
# be made. Every caller takes any status but 0 as a file not read.
snapshot() { # file copy
  local rc=0
  "$RM" -f "$2"
  { : 1<>"$2"; } 2>/dev/null || return 1
  [[ -f "$2" && ! -L "$2" ]] || return 1
  bounded "$CP" -X "$1" "$2" || rc=$?
  return "$rc"
}
notes_reset
# How a bounded call's exit status reads in a message.
call_result() { # status
  if (( $1 == 124 )); then
    printf 'did not answer within %ss' "$CALL_TIMEOUT_SECONDS"
  elif (( $1 == 125 )); then
    printf 'did not answer within %ss, and whether it has ended is not known' "$CALL_TIMEOUT_SECONDS"
  else
    printf 'exited %s' "$1"
  fi
}
# The same for a bounded call whose output was read: when it exited 0, what
# was wrong with that output (BOUNDED_READ, from read_fd3).
read_result() { # status
  if (( $1 != 0 )); then
    call_result "$1"
  elif (( BOUNDED_READ == 1 )); then
    printf 'exited 0, but printed a NUL byte'
  else
    printf 'exited 0, but what it printed could not be read back in full'
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

# Shape check, same rules as backstop.sh: a JSON object whose known keys have
# the types RuntimeState.swift writes; null counts as absent. Each read has
# an explicit status: a read that failed or did not answer returns 2 at
# once, after any lines already printed, and the caller counts the check as
# not done (see plutil_read).
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

# Whether key $2 of $1 is true: 0 when it is, 1 when it is anything else or
# has no value, 2 when the read failed.
is_refused() { # file key
  local rc=0
  value_at "$1" "$2" || rc=$?
  (( rc != 2 )) || return 2
  (( rc == 0 )) && [[ "$VALUE" == true ]]
}

# Brightness the app kept after its private-call guard refused the restore
# on this macOS, one line per device with the saved level. Not a problem
# for uninstall: no step here can restore it. Read from the private copy of
# state.json that journal_problems checked. Returns 2 when a read failed, or
# when that copy is gone while state.json is there; the caller then keeps
# state.json, since whether it holds such a level is unknown.
refused_brightness() {
  if [[ ! -f "$STATE_COPY" ]]; then
    [[ -e "$STATE" || -L "$STATE" ]] || return 0
    note "the copy of state.json that the journal check read is gone"
    return 2
  fi
  refused_level savedDisplayBrightness displayRestoreRefused "display brightness" || return 2
  refused_level savedKeyboardBrightness keyboardRestoreRefused "keyboard backlight" || return 2
  return 0
}
refused_level() { # level-key refused-key what
  local rc=0
  is_refused "$STATE_COPY" "$2" || rc=$?
  (( rc != 1 )) || return 0
  (( rc == 0 )) || return 2
  value_at "$STATE_COPY" "$1" || rc=$?
  (( rc != 1 )) || return 0
  (( rc == 0 )) || return 2
  echo "$3 $VALUE"
}
# The line for a saved level the app has not restored, unless its restore
# was refused (refused_brightness lists those); 2 when a read failed.
unrestored_level() { # level-key refused-key what
  local rc=0
  value_at "$STATE_COPY" "$1" || rc=$?
  (( rc != 1 )) || return 0
  (( rc == 0 )) || return 2
  is_refused "$STATE_COPY" "$2" || rc=$?
  (( rc != 2 )) || return 2
  (( rc == 0 )) || echo "saved $3 is not restored; only the app can do that"
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
# plutil's own trailing newline cut; 2 when the read failed.
epoch_at() { # file keypath
  local v rc=0
  v="$(extract "$1" "$2" && echo .)" || rc=$?
  (( rc != 2 )) || return 2
  v="${v%.}"
  epoch_of "${v%$'\n'}"
}
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

# Independent check of the journal: prints one line per unresolved item.
# Trusts nothing about the backstop that just ran (it may be an older copy).
# It runs under the recovery lock, so each file is read once, by a bounded
# cp into WORK, and every check reads that copy: a FIFO, a stalled disk or
# a file swapped meanwhile cannot keep the lock waiting or show one check
# another file. Returns 2 when a read failed or did not answer (noted; see
# notes_reset), after the lines it printed so far: the caller counts that
# as a check that did not complete, never as a clean journal.
SESSION_COPY="$WORK/session.json"
STATE_COPY="$WORK/state.json"
journal_problems() {
  local key value shape i rc
  if [[ -e "$SESSION" ]]; then
    shape=""
    rc=0
    # Only a regular file is copied: open(2) on a FIFO with no writer
    # blocks. One put there after this test blocks the bounded cp, which
    # then does not answer in time.
    if [[ ! -f "$SESSION" ]]; then
      echo "session.json is still present and cannot be read: it is not a regular file, so it was not opened"
    else
      snapshot "$SESSION" "$SESSION_COPY" || rc=$?
      if (( rc == 124 || rc == 125 )); then
        echo "session.json is still present and could not be read within ${CALL_TIMEOUT_SECONDS}s"
      elif (( rc != 0 )); then
        echo "session.json is still present and cannot be read (permissions or I/O)"
      else
        shape="$(session_shape_problems "$SESSION_COPY")" || rc=$?
        if [[ -n "$shape" ]]; then
          echo "session.json is still present and is not a session: ${shape%%$'\n'*}"
        else
          echo "session.json is still present"
        fi
        (( rc == 0 )) || return 2
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
  if (( rc == 124 || rc == 125 )); then
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
    return 2
  fi
  rc=0
  shape="$(journal_shape_problems "$STATE_COPY")" || rc=$?
  if [[ -n "$shape" ]]; then
    echo "state.json is malformed (unexpected shape):"
    echo "$shape"
  fi
  (( rc == 0 )) || return 2
  [[ -z "$shape" ]] || return 0
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen; do
    rc=0
    is_refused "$STATE_COPY" "$key" || rc=$?
    (( rc != 2 )) || return 2
    (( rc != 0 )) || echo "$key is still true"
  done
  rc=0
  value_at "$STATE_COPY" frozenProcesses json || rc=$?
  (( rc != 2 )) || return 2
  if [[ -n "$VALUE" && "$VALUE" != "[]" ]]; then
    echo "frozen processes are still journaled: $VALUE"
  fi
  rc=0
  value_at "$STATE_COPY" frozenPids json || rc=$?
  (( rc != 2 )) || return 2
  if [[ -n "$VALUE" && "$VALUE" != "[]" ]]; then
    echo "legacy frozen pids (no identity; the backstop never signals or clears these, only the app does): $VALUE"
  fi
  rc=0
  value_at "$STATE_COPY" savedOutputVolume || rc=$?
  if (( rc == 1 )); then
    rc=0
    value_at "$STATE_COPY" savedMuted || rc=$?
  fi
  (( rc != 2 )) || return 2
  (( rc != 0 )) || echo "saved audio settings (volume/mute) are not restored; only the app can do that"
  i=0
  while :; do
    rc=0
    value_at "$STATE_COPY" "savedAudioOutputs.$i" json || rc=$?
    (( rc != 2 )) || return 2
    (( rc == 0 )) || break
    value_at "$STATE_COPY" "savedAudioOutputs.$i.name" || rc=$?
    if (( rc == 1 )); then
      rc=0
      value_at "$STATE_COPY" "savedAudioOutputs.$i.deviceUID" || rc=$?
    fi
    (( rc != 2 )) || return 2
    echo "$VALUE is still muted from a lid close; only the app can restore its volume, once the device is connected"
    i=$((i + 1))
  done
  unrestored_level savedDisplayBrightness displayRestoreRefused "display brightness" || return 2
  unrestored_level savedKeyboardBrightness keyboardRestoreRefused "keyboard backlight" || return 2
  rc=0
  value_at "$STATE_COPY" appNapOverrides json || rc=$?
  (( rc != 2 )) || return 2
  if [[ -n "$VALUE" && "$VALUE" != "[]" ]]; then
    echo "App Nap settings (NSAppSleepDisabled) are not put back: $VALUE"
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
    # The list ends where extract says there is no value (1); any other
    # status, or a note, is a read that did not complete.
    notes_reset
    while :; do
      rc=0
      id="$(extract "$CONFIG" "agentList.$i")" || rc=$?
      (( rc == 0 )) || break
      i=$((i + 1))
      ids="$ids$id"$'\n'
    done
    if (( rc != 1 )) || noted; then
      value="the read stopped with status $rc"
      if noted; then
        value="its note could not be read back"
        if notes_read && [[ -n "$READ_TEXT" ]]; then value="${READ_TEXT%%$'\n'*}"; fi
      fi
      echo "could not read all of the agent list in $CONFIG ($value), so agent apps listed only there may not have been checked"
    fi
  fi
  ids="$(printf '%s' "$ids" | awk '!seen[$0]++')"
  while IFS= read -r id; do
    [[ -n "$id" && "$id" != -* ]] || continue
    if [[ -n "$stuck" ]]; then skipped=$((skipped + 1)); continue; fi
    rc=0
    bounded "$DEFAULTS" read "$id" NSAppSleepDisabled || rc=$?
    value="$BOUNDED_OUTPUT"
    if (( rc == 124 || rc == 125 )); then
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
    if (( BOUNDED_READ != 0 )); then
      unreadable=$((unreadable + 1))
      printf 'could not read NSAppSleepDisabled for %s; check it yourself with: defaults read %q NSAppSleepDisabled\n' "$id" "$id"
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
  local pid_lines=$'^[0-9]+(\n[0-9]+)*$'
  APP_FOUND=(); UNVERIFIED=(); OTHER_ACCOUNT=(); UNKNOWN_OWNER=(); OTHER_FOUND=(); BLOCKING=(); PGREP_PROBLEM=""
  # pgrep exits 1 when no process has the name. Any other failure, or no
  # answer in time, counts as "running": fail closed.
  rc=0
  bounded "$PGREP" -x Insomnia || rc=$?
  pids="$BOUNDED_OUTPUT"
  if (( rc != 0 && rc != 1 )); then
    PGREP_PROBLEM="pgrep $(call_result "$rc")"
  elif (( BOUNDED_READ != 0 )); then
    PGREP_PROBLEM="pgrep exited $rc, but its output could not be read back"
  elif (( rc == 0 )) && [[ ! "$pids" =~ $pid_lines ]]; then
    PGREP_PROBLEM="pgrep exited 0, but did not print one process ID per line"
  elif (( rc == 1 )) && [[ -n "$pids" ]]; then
    PGREP_PROBLEM="pgrep exited 1, but printed something"
  fi
  if [[ -n "$PGREP_PROBLEM" ]]; then
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
    elif (( BOUNDED_READ != 0 )); then
      owner_why="ps -o uid= exited 0, but its output could not be read back"
    elif [[ -z "$owner" ]]; then
      owner_why="ps -o uid= printed nothing"
    elif [[ ! "$owner" =~ ^[0-9]+$ ]]; then
      owner_why="ps -o uid= printed '$owner', not a user ID"
    fi
    rc=0
    bounded "$PS" -o comm= -p "$pid" || rc=$?
    exe=""
    (( rc == 0 && BOUNDED_READ == 0 )) && exe="$BOUNDED_OUTPUT"
    id=""
    desc="${exe:-executable path unknown}"   # what the messages say; gains the reason when unverified
    if [[ "$exe" == /*/Contents/MacOS/* ]]; then
      bundle="${exe%/Contents/MacOS/*}"
      id="$(known_id "$pid" "$bundle")"
      rc=0
      if [[ -z "$id" ]] && (( PLIST_READS == 1 )); then
        bounded "$PLUTIL" -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" || rc=$?
        if (( rc == 0 && BOUNDED_READ == 0 )); then id="${BOUNDED_OUTPUT%%$'\n'*}"; fi
        if [[ -n "$id" ]]; then KNOWN_IDS+=("$pid|$bundle|$id"); fi
      fi
      if [[ -z "$id" ]]; then
        if (( PLIST_READS == 0 )); then
          desc="$exe; first seen under the recovery lock, where no Info.plist is read"
        elif (( rc == 124 || rc == 125 )); then
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

# The functions from here to r_recheck run only as root, in the shell
# sudoers_replace (install.sh) or sudoers_remove (uninstall.sh) starts.
# They are the same in install.sh and uninstall.sh (a test keeps them in
# step). Each one that finds a problem says why on stderr and exits that
# shell with the status it is given (r_die); none returns a problem to a
# caller that could miss it.
r_die() { # status message
  echo "$2" >&2
  exit "$1"
}
# Puts what `stat -f '%d:%i %Hp %Mp %Lp %u %l %z %.9Fc'` says about the
# name given (the name itself, not what a link points to; with -L, what it
# points to; with no name, standard input, as in `r_stat 7 <&8`) in ST, and
# the fields checked one by one in ST_ID (device:inode), ST_T (file type),
# ST_S (setuid, setgid, sticky), ST_P (permissions), ST_U (owner's uid),
# ST_L (links) and ST_Z (size); the change time is only ever compared as
# part of ST. The answer is trusted only when stat
# exits 0 and prints exactly one line of those eight fields and nothing
# else; anything else (a failure, even after an answer, an empty, partial,
# longer or malformed answer, a warning) exits with status $1.
r_stat() { # status [-L] [name]
  local s="$1" rc=0 re='^([0-9]+:[0-9]+) ([0-9]{1,2}) ([0-7]) ([0-7]{1,3}) ([0-9]+) ([0-9]+) ([0-9]+) [0-9]+\.[0-9]{9}$'
  shift
  ST="$("$STAT" -f '%d:%i %Hp %Mp %Lp %u %l %z %.9Fc' "$@" 2>&1 && echo .)" || rc=$?
  # Only an answer stat finished (the "." echo adds after its last newline)
  # loses the ".": one without a newline at its end keeps it and fails.
  ST="${ST%$'\n.'}"
  if (( rc != 0 )) || ! [[ "$ST" =~ $re ]]; then
    r_die "$s" "stat ${*:-of a descriptor} exited $rc, or its answer is not the one line asked for: $ST"
  fi
  ST_ID="${BASH_REMATCH[1]}" ST_T="${BASH_REMATCH[2]}" ST_S="${BASH_REMATCH[3]}" ST_P="${BASH_REMATCH[4]}"
  ST_U="${BASH_REMATCH[5]}" ST_L="${BASH_REMATCH[6]}" ST_Z="${BASH_REMATCH[7]}"
}
# Exits with status $1 unless the file the last r_stat read, named $2, is
# a regular file of root's (ROOT_UID) with one link, no setuid, setgid or
# sticky bit and no write permission for group or others; with $3, exactly
# that mode.
r_file() { # status name [mode]
  [[ "$ST_T" == 10 ]] || r_die "$1" "$2 is not a regular file (stat: $ST_T $ST_S $ST_P $ST_U $ST_L)"
  [[ "$ST_U" == "$ROOT_UID" ]] || r_die "$1" "$2 belongs to uid $ST_U, not root"
  [[ "$ST_L" == 1 ]] || r_die "$1" "$2 has $ST_L links, not 1"
  if [[ "$ST_S" != 0 ]] || (( (8#$ST_P & 8#022) != 0 )); then
    r_die "$1" "$2 has mode $ST_S$ST_P, so someone other than root may change it"
  fi
  [[ -z "${3:-}" || "$ST_P" == "$3" ]] || r_die "$1" "$2 has mode $ST_P, not $3"
}
# Succeeds only when dsmemberutil shows that the UUID $1 is root's own user
# record: the UUID it gives for the user ID ROOT_UID (0) is exactly $1, and
# the ID it gives for $1 is that user ID ("uid: 0", not a group's "gid:").
# Each answer must be exactly that one line, from a dsmemberutil that exits
# 0. A name, a group (wheel, admin, everyone), another user, or an answer
# that is missing, longer or malformed is not shown to be root.
r_root() { # uuid
  local out
  out="$("$DSMEMBERUTIL" getuuid -u "$ROOT_UID" 2>&1 && echo .)" && [[ "$out" == "$1"$'\n.' ]] \
    && out="$("$DSMEMBERUTIL" getid -X "$1" 2>&1 && echo .)" && [[ "$out" == "uid: $ROOT_UID"$'\n.' ]]
}
# The program r_acl runs with /usr/bin/perl, which loads no module. For
# each pair of arguments, what r_stat said about a name ("<ST_T> <ST_ID>")
# and the name, it opens the name for reading without following a link or
# waiting (O_NOFOLLOW, O_NONBLOCK; a folder only as a folder,
# O_DIRECTORY), and asks the kernel, with fgetattrlist (syscall 228), for
# the device, type, file ID and access control list of that open file in
# one answer, reported at its full size. Nothing is changed. parse checks
# the whole answer: the call's status; a size that fits the buffer; the
# type and the device and file ID r_stat gave, so the list read is the
# named file's; the list's place and length; the header's magic and its
# empty owner and group; an entry count of at most 128 that accounts for
# every byte of the list, so no entry is left past the count; the list's
# flags; and each entry's kind and flags, which must be values sys/kauth.h
# defines. An entry that allows (kind 1) a right other than reading (read
# data or list, execute or search, read attributes, extended attributes or
# security, synchronize, generic read or execute) is printed as "<pair>
# <UUID> <flags> <rights>" for r_acl to judge; deny, audit and alarm
# entries grant nothing. Any problem prints why and exits non-zero. Last it
# prints "checked <pairs>".
# shellcheck disable=SC2016  # the $ names in this program are perl's, not this shell's
r_acl_reader() {
  printf %s 'sub uuid{sprintf("%08X-%04X-%04X-%04X-%04X%08X",unpack("N n n n n N",$_[0]))}
sub parse{my($b,$size,$rc,$want)=@_;
$rc eq "0" or return "fgetattrlist failed ($rc)";
length($b)==$size or return "the answer is not in the buffer read";
my($len,$dev,$type,$at,$n,$id)=unpack("L l L l L Q",$b);
$len>=28&&$len<=$size or return "an answer of $len bytes, with $size read";
my($t,$i)=split(/ /,$want,2);
$type==({4,2,10,1}->{$t}//0)&&$i eq "$dev:$id" or return "type $type, file $dev:$id, not $want";
$at==16&&$len==28+$n or return "a list of $n bytes at $at in an answer of $len";
$n or return "";
$n>=44 or return "a list of $n bytes";
my($magic,$who,$count,$flags)=unpack("L a32 L L",substr($b,28,44));
$magic==0x12cc16d&&$who eq "\0"x32 or return sprintf("a list header %#x",$magic);
$count==0xffffffff&&$n==44 and return "";
$count<=128&&$n==44+24*$count or return "$count entries in a list of $n bytes";
$flags&~0x3ffff and return sprintf("list flags %#x",$flags);
my @r;
for my $k(0..$count-1){my($u,$f,$r)=unpack("a16 L L",substr($b,72+24*$k,24));
$f&~0x7ff||($f&15)<1||($f&15)>4 and return sprintf("entry %d has flags %#x",$k,$f);
($f&15)==1&&$r&~0x1500a8a and push(@r,sprintf("%s %#x %#x",uuid($u),$f,$r))}
("",@r)}
@ARGV%2==0&&@ARGV or die "no files named\n";
for(my $k=0;$k<@ARGV;$k+=2){my($want,$p)=@ARGV[$k,$k+1];
sysopen(my $h,$p,4|256|($want=~/^4 /?1048576:0)) or die "$p could not be opened: $!\n";
my $b="\0"x4096;
my $l=pack("S S L5",5,0,0x240000a,0,0,0,0);
my $rc=syscall(228,fileno($h),$l,$b,4096,4);
my($e,@r)=parse($b,4096,$rc==-1?"-1: $!":$rc,$want);
$e eq "" or die "$p: $e\n";
print($k/2+1," $_\n")for@r}
print("checked ",@ARGV/2,"\n")'
}
# Exits with status $1, saying why on stderr, unless r_acl_reader shows
# that no access control list on the files and folders named after it lets
# anyone but root change them. Each name follows what r_stat said about it
# ("$ST_T $ST_ID"), so each list read is that file's. An entry that allows
# more than reading passes only when r_root shows its UUID is root's own
# user record, whatever its inheritance flags: a folder's inheritable
# entries reach the files made in it. Deny entries pass. So does an answer
# only when it is read in full: perl fails (even after printing), prints a
# line not parsed here, or does not end with "checked" and the number of
# names, and the run stops. Nothing is ever repaired.
r_acl() { # status type-and-id name...
  local s="$1" out rc=0 line i=1 end=0 names=() k u w
  local re='^([1-9][0-9]*) ([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}) (0x[0-9a-f]+ 0x[0-9a-f]+)$'
  shift
  while (( i < $# )); do names+=("${@:i+1:1}"); i=$(( i + 2 )); done
  out="$("$PERL" -e "$(r_acl_reader)" -- "$@" 2>&1 && echo .)" || rc=$?
  if (( rc != 0 )); then
    r_die "$s" "the access control lists of ${names[*]} could not be read (perl exited $rc: $out)"
  fi
  # An answer without a newline at its end keeps the "." and fails below.
  out="${out%$'\n.'}"
  while IFS= read -r line; do
    if (( end == 0 )) && [[ "$line" == "checked ${#names[@]}" ]]; then
      end=1
    elif (( end == 0 )) && [[ "$line" =~ $re ]] && (( BASH_REMATCH[1] <= ${#names[@]} )); then
      k="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}" w="${BASH_REMATCH[3]}"
      r_root "$u" || r_die "$s" "${names[k-1]} has an access control list entry that allows more than reading ($u allow $w)"
    else
      end=2
    fi
  done <<< "$out"
  (( end == 1 )) || r_die "$s" "the access control lists of ${names[*]} could not be read in full (perl: $out)"
}
# Exits 7 unless every folder from the one that holds $SUDOERS_LOCK up to /
# is a folder of root's that group and others cannot write, with no access
# control list that lets anyone but root change it (r_acl).
r_dirs() {
  local d="$SUDOERS_LOCK" dirs=()
  while [[ "$d" == /?* ]]; do
    d="${d%/*}"
    r_stat 7 "${d:-/}"
    if [[ "$ST_T" != 4 || ( "$ST_U" != 0 && "$ST_U" != "$ROOT_UID" ) ]] || (( (8#$ST_P & 8#022) != 0 )); then
      r_die 7 "${d:-/}, a folder above $SUDOERS_LOCK, is not a folder of root's that only root can write (stat: $ST_T $ST_P $ST_U)"
    fi
    dirs+=("$ST_T $ST_ID" "${d:-/}")
  done
  r_acl 7 "${dirs[@]}"
}
# Takes $SUDOERS_LOCK on fd 8 for the rest of the root shell, once it is
# shown that only root can have made or changed it. An existing file must
# be a regular file of root's with mode 0600 and one link (r_file), and
# every folder from its own up to / a folder of root's that group and
# others cannot write (r_dirs), none with an access control list that lets
# anyone but root change it. Both are checked before the file is opened, so
# a FIFO (whose open would wait) or a link is never opened. The file is
# created, mode 0600, only where nothing is (noclobber: no link is followed
# and nothing is truncated), and its own list is checked before it is
# opened. Nothing is ever repaired, replaced or removed. Once the lock is
# taken, the descriptor and the path must still be the same file, unchanged
# down to its change time (kept in LOCK_ID for r_recheck), and the rule $1
# must be in the same folder. Exits 7 when a check fails, 3 when the lock
# is not free within LOCK_TIMEOUT_SECONDS.
r_guard() { # rule
  local id
  if [[ -e "$SUDOERS_LOCK" || -L "$SUDOERS_LOCK" ]]; then
    r_stat 7 "$SUDOERS_LOCK"
    r_file 7 "$SUDOERS_LOCK" 600
  fi
  r_dirs
  ( set -C; : > "$SUDOERS_LOCK" ) 2>/dev/null || true
  r_stat 7 "$SUDOERS_LOCK"
  r_file 7 "$SUDOERS_LOCK" 600
  r_acl 7 "$ST_T $ST_ID" "$SUDOERS_LOCK"
  exec 8<"$SUDOERS_LOCK" || exit 7
  "$LOCKF" -t "$LOCK_TIMEOUT_SECONDS" 8 2>/dev/null || exit 3
  r_stat 7 <&8
  LOCK_ID="$ST"
  r_stat 7 "$SUDOERS_LOCK"
  [[ "$ST" == "$LOCK_ID" ]] || r_die 7 "$SUDOERS_LOCK is no longer the file this run opened and locked"
  r_file 7 "$SUDOERS_LOCK" 600
  r_stat 7 -L "${1%/*}"
  id="$ST_ID"
  r_stat 7 "${SUDOERS_LOCK%/*}"
  [[ "$ST_ID" == "$id" ]] || r_die 7 "$1 is not in the folder that holds $SUDOERS_LOCK"
}
# Opens the rule $1 on fd 6, once r_file (any mode without group or other
# write) and r_acl find nothing wrong with it, checks the descriptor the
# same way, and reads the rule from its start through it, checking cat's
# exit status. Leaves what stat said about the descriptor in R_META, the
# file's identity in R_ID and its bytes in R_RAW, with a "." after them so
# $(...) keeps a trailing newline. Exits 4 unless the path still names the
# opened file; 8 when cat fails, or the descriptor's stat after the read is
# not the one before it, or the bytes read are not as many as the file's
# size (a NUL byte, which the shell drops, or a change while they were
# read).
r_read() { # rule
  local LC_ALL=C rc=0
  r_stat 4 "$1"
  r_file 4 "$1"
  r_acl 4 "$ST_T $ST_ID" "$1"
  exec 6<"$1" || exit 4
  r_stat 4 <&6
  r_file 4 "$1"
  R_META="$ST" R_ID="$ST_ID"
  r_stat 4 "$1"
  [[ "$ST_ID" == "$R_ID" ]] || r_die 4 "$1 was replaced while it was opened"
  R_RAW="$("$CAT" <&6 && echo .)" || rc=$?
  (( rc == 0 )) || r_die 8 "$1 could not be read (cat exited $rc)"
  r_stat 8 <&6
  [[ "$ST" == "$R_META" && "${#R_RAW}" == "$(( ST_Z + 1 ))" ]] || r_die 8 "$1 holds a NUL byte, or changed while it was read"
}
# Reads the rule $1 (r_read) and keeps that descriptor on fd 7 until the
# root shell exits, so no other file can take the inode while P_META names
# it. Exits 4 unless the text read, trailing newlines aside, is exactly $2,
# the text the caller read and judged before sudo ran. Leaves what stat
# said about the descriptor in P_META, the bytes as read in P_RAW, and the
# text in P_TEXT.
r_pin() { # rule text
  local LC_ALL=C
  r_read "$1"
  exec 7<&6 || exit 4
  P_META="$R_META" P_RAW="$R_RAW"
  P_TEXT="${R_RAW%.}"
  P_TEXT="${P_TEXT%"${P_TEXT##*[!$'\n']}"}"
  [[ "$P_TEXT" == "$2" ]] || r_die 4 "$1 is not the text this run read"
}
# The last checks before the rename or removal, after every other one: the
# folders again (r_dirs, exit 7), the lock still the file this shell
# locked, unchanged, with no access control list that lets anyone but root
# change it (exit 7), and then the rule. With "absent", nothing may be at
# $2 (exit 4). With "same", the rule is read again from its start through a
# new descriptor (r_read, exits 4 and 8), and must be the file root pinned,
# unchanged down to its change time, holding exactly the bytes root read
# then (exit 4).
r_recheck() { # absent|same rule
  r_dirs
  r_stat 7 "$SUDOERS_LOCK"
  [[ "$ST" == "$LOCK_ID" ]] || r_die 7 "$SUDOERS_LOCK is no longer the file this run opened and locked"
  r_acl 7 "$ST_T $ST_ID" "$SUDOERS_LOCK"
  if [[ "$1" == absent ]]; then
    [[ ! -e "$2" && ! -L "$2" ]] || r_die 4 "$2 is there now"
    return 0
  fi
  r_read "$2"
  [[ "$R_ID" == "${P_META%% *}" ]] || r_die 4 "$2 was replaced after root read it"
  [[ "$R_META" == "$P_META" && "$R_RAW" == "$P_RAW" ]] || r_die 4 "$2 changed after root read it"
}

# Removes the rule at $SUDOERS only if it is still exactly the text this run
# read and judged to be its own (passed to root as an argument): another
# account's install.sh may replace it between the read and the removal. The
# compare and the removal are one call to sudo, run as root while it holds
# $SUDOERS_LOCK (r_guard), the lock install.sh takes for its compare and
# write. Root reads the rule through a descriptor it opened and checked
# (r_pin), and judges that text again with sudoers_not_ours. Last,
# r_recheck checks the folders, the lock and
# the access control lists again and reads the rule again through a new
# descriptor; the removal follows only when the path still names the file
# root opened and holds the bytes root read first. The lock keeps out only
# the runs that take it, as install.sh says, and the moments between that
# reread and the removal stay open to a writer that takes no lock. Exit
# status: 0 removed; 3 the lock was not free within LOCK_TIMEOUT_SECONDS; 4
# the rule changed since it was read, or is not a regular file of root's
# with one link that only root can change (an access control list that
# lets anyone but root change it, or one not read in full, counts), or a
# stat of it failed or gave an answer not in the form asked for; 5 rm
# reported that the removal failed; 7 the lock file, or a folder above it,
# is not one only root can change, or its access control list or a stat of
# it could not be read in full; 8 the rule as root read it could not be
# read in full (cat failed, or the stat after the read failed), holds a NUL
# byte, changed while it was read, or is not this account's. 1 is sudo's
# own (no valid timestamp, say)
# or a shell error before the removal. In all of these the rule was not
# removed, though the lock file may have been created. Any other status (the
# root shell, or its rm, was killed by a signal), or a call that did not
# finish in time, leaves it unknown whether the removal happened.
r_remove() { # rule text
  umask 077
  r_guard "$1"
  r_pin "$1" "$2"
  [[ -z "$(sudoers_not_ours "$P_TEXT")" ]] || exit 8
  r_recheck same "$1"
  # An rm killed by a signal may have removed the rule already, so its
  # status goes on as it is, an unknown result, not as a failed removal.
  "$RM" -f "$1" || { rc=$?; (( rc > 128 )) && exit "$rc"; exit 5; }
  exit 0
}
# The functions named, as `declare -f` prints them, with the spaces that
# start each line cut, for the text a root shell runs: sudo logs that text
# and ps shows it, and the indentation is more than a tenth of the shell
# functions' text. bash prints $'\n' as a newline inside single quotes, so a quoted
# string may run across lines (r_acl_reader's program does); none of these
# functions has one whose next line starts with a space, which the cut
# would change. A test checks that bash reads the cut text back to the same
# functions. The same in install.sh and uninstall.sh.
root_functions() { # name...
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line#"${line%%[! ]*}"}"
  done <<< "$(declare -f "$@")"
}
# Runs r_remove as root, in one sudo call, bounded like every
# other call made under the recovery lock: `sudo -n` never prompts (the
# password was asked before the lock, with `sudo -v`), and a sudo still
# running past the limit returns 125 and keeps the lock until it ends. The
# shell's script is this script's fixed tool paths, the account's name, and
# the text of the functions root runs (root_functions); sudo resets the
# environment, so nothing root runs comes from PATH.
sudoers_remove() { # text
  bounded "$SUDO" -n "$ROOT_BASH" -c "set -u
$(printf '%s=%q\n' SUDOERS_LOCK "$SUDOERS_LOCK" ROOT_UID "$ROOT_UID" ACCOUNT "$ACCOUNT" \
    LOCK_TIMEOUT_SECONDS "$LOCK_TIMEOUT_SECONDS" LOCKF "$LOCKF" STAT "$STAT" CAT "$CAT" PERL "$PERL" \
    DSMEMBERUTIL "$DSMEMBERUTIL" RM "$RM")
$(root_functions r_die r_stat r_file r_root r_acl_reader r_acl r_dirs r_guard r_read r_pin r_recheck \
    sudoers_not_ours r_remove)
r_remove \"\$@\"" insomnia-sudoers-remove "$SUDOERS" "$1"
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
# A copy identified as this app is asked to quit only after the rule is
# judged, which for a rule only root can read takes the password. So a
# process beside it that cannot be told apart from this app, or whose owner
# cannot be read, is waited for first, on its own: the processes are listed
# again, once a second for up to QUIT_WAIT_SECONDS, while such a process is
# listed. The identified copy is not waited for; it has not been asked to
# quit. A pgrep problem, or a copy in another account, on any of these looks
# ends the wait, and stop_for_other_accounts stops the run; so does an owner
# still unknown at the end. stop_for_unverified stops it when a process
# still cannot be told apart from this app.
await_unidentified() {
  local i
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    [[ -z "$PGREP_PROBLEM" ]] || return 0
    (( ${#OTHER_ACCOUNT[@]} == 0 )) || return 0
    (( ${#UNKNOWN_OWNER[@]} + ${#UNVERIFIED[@]} > 0 )) || return 0
    sleep 1
    find_insomnia
  done
  return 0
}
stop_for_unverified() {
  (( ${#UNVERIFIED[@]} > 0 )) || return 0
  echo "Cannot tell whether ${#UNVERIFIED[@]} process(es) named Insomnia are this app, and they were still running after ${QUIT_WAIT_SECONDS}s: $(list "${UNVERIFIED[@]}")." >&2
  echo "Nothing was asked to quit, and no password was asked for. Quit them, or wait for them to exit, then rerun. Nothing was removed." >&2
  exit 1
}
# install.sh's judgment of the rule, text for text (a test keeps the two in
# step): why the rule's text $1 has a line for someone other than $USER, or
# nothing. A line is this account's only when it starts with its name or
# with # and its user ID, and no comma after that carries on the user list.
# stop_for_rule_of_others gives USER this account's name.
sudoers_for_others() { # file content
  local line name rest
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      "") continue ;;
      "#include"* | "#"[[:digit:]]* | "#-"[[:digit:]]* | "#-") ;;
      "#"*) continue ;;
    esac
    name="${line%%[[:space:]]*}"
    rest="${line#"$name"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    if [[ ( "$name" == "$USER" || "$name" == "#$UID_NUM" ) && "$rest" != ,* ]]; then
      continue
    fi
    if [[ "$rest" != ,* ]]; then
      case "$name" in
        Defaults* | *_Alias) ;;
        "#"*) if [[ "$name" =~ ^#(0|[1-9][[:digit:]]*)$ ]]; then echo "grants user ID ${name#?}"; return 0; fi ;;
        *) if [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ && ! "$name" =~ ^[[:upper:]][[:upper:][:digit:]_]*$ ]]; then echo "grants $name"; return 0; fi ;;
      esac
    fi
    echo "has a line that is not for $USER: $line"
    return 0
  done <<< "$1"
  return 0
}
# Stops the run when the rule's text $1 has a line for anyone but this
# account (sudoers_for_others): a grant to another account, whose recovery
# agent may need it to undo a session even after its app crashed, or a line
# that cannot be shown to be this account's. This script would keep such a
# rule, and it stops before it changes anything else, so the app, the agent
# and the journal stay with it until that is settled.
stop_for_rule_of_others() { # file content
  local why USER="$ACCOUNT"
  why="$(sudoers_for_others "$1")"
  [[ -n "$why" ]] || return 0
  if [[ "$why" == grants\ * ]]; then
    echo "$SUDOERS $why, not $ACCOUNT. Another account installed Insomnia, and its recovery agent needs that rule to undo a session, even one whose app crashed." >&2
    echo "Uninstall Insomnia in that account first. If that account no longer exists, remove the rule with 'sudo rm $SUDOERS', then rerun. Nothing was removed." >&2
  else
    echo "$SUDOERS $why, so it may serve another account." >&2
    echo "Check it, remove it with 'sudo rm $SUDOERS' if nothing needs it, then rerun. Nothing was removed." >&2
  fi
  exit 1
}
# Asks for the password, once, before the recovery lock. Each sudo call made
# under the lock (step 5) is `sudo -n` and bounded, so none waits at a
# prompt while the lock is held; step 5 reads the rule again there before it
# removes it. sudo's timestamp lasts a few minutes (five by default); if it
# runs out before step 5, that step keeps the rule and the app.
ask_password() {
  if ! "$SUDO" -v; then
    echo "sudo did not authenticate, so $SUDOERS could not be removed later. Nothing was removed." >&2
    exit 1
  fi
}
# Judges the rule before anything is changed: before the app is asked to
# quit, the recovery lock, the backstop and the LaunchAgent. A rule this
# account can read is read with a bounded cat and judged without sudo
# (RULE_JUDGED=1); the password is asked only after the app has quit, so an
# app that refuses to quit stops the run before any password prompt. When
# the rule is there but only root can read it (the rule install.sh writes
# is root's, mode 0440), or its folder cannot be searched without root, the
# password is asked here, before the quit, and the rule is read with a
# bounded `sudo -n cat` and judged right after. A read that fails, does not
# answer, or cannot be read back in full or holds a NUL byte stops the run
# as well: whether the rule serves another account is then unknown.
check_rule_first() {
  local rc=0
  if [[ -e "$SUDOERS" && -r "$SUDOERS" ]]; then
    bounded "$CAT" "$SUDOERS" || rc=$?
    if (( rc != 0 || BOUNDED_READ != 0 )); then
      # What a cat that exited 0 printed is the rule, not an error.
      (( rc != 0 )) || BOUNDED_OUTPUT=""
      echo "Could not read $SUDOERS ('cat' $(read_result "$rc")${BOUNDED_OUTPUT:+: $BOUNDED_OUTPUT}), so whether it serves another account is not known. Nothing was removed." >&2
      exit 1
    fi
    stop_for_rule_of_others "$BOUNDED_OUTPUT"
    RULE_JUDGED=1
    return 0
  fi
  [[ -e "$SUDOERS" || ! -x "${SUDOERS%/*}" ]] || return 0
  ask_password
  if [[ ! -e "$SUDOERS" ]]; then
    # The folder cannot be searched without root, so only sudo can tell.
    bounded "$SUDO" -n "$TEST" -e "$SUDOERS" || rc=$?
    if (( rc == 1 && BOUNDED_READ == 0 )) && [[ -z "$BOUNDED_OUTPUT" ]]; then
      return 0
    elif (( rc == 125 )); then
      echo "'sudo -n test -e $SUDOERS' did not answer within ${CALL_TIMEOUT_SECONDS}s, so whether the rule is there is not known. $(sudo_alive_note). Nothing was removed." >&2
      exit 1
    elif (( rc != 0 || BOUNDED_READ != 0 )) || [[ -n "$BOUNDED_OUTPUT" ]]; then
      echo "'sudo -n test -e $SUDOERS' $(read_result "$rc")${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}, so whether the rule is there is not known. Nothing was removed." >&2
      exit 1
    fi
  fi
  rc=0
  bounded "$SUDO" -n "$CAT" "$SUDOERS" || rc=$?
  if (( rc == 125 )); then
    echo "'sudo -n cat $SUDOERS' did not answer within ${CALL_TIMEOUT_SECONDS}s, so whether it serves another account is not known. $(sudo_alive_note). Nothing was removed." >&2
    exit 1
  elif (( rc != 0 || BOUNDED_READ != 0 )); then
    # What a cat that exited 0 printed is the rule, not an error.
    (( rc != 0 )) || BOUNDED_OUTPUT=""
    echo "Could not read $SUDOERS through sudo ('sudo -n cat' $(read_result "$rc")${BOUNDED_OUTPUT:+: $BOUNDED_OUTPUT}), so whether it serves another account is not known. Nothing was removed." >&2
    exit 1
  fi
  stop_for_rule_of_others "$BOUNDED_OUTPUT"
}

# Waits up to QUIT_WAIT_SECONDS for every process app_running lists to exit,
# and stops the run when one is still there.
await_exit() {
  local i
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    app_running || break
    sleep 1
  done
  if app_running; then
    echo "Insomnia is still running (it may be refusing to quit until its own recovery finishes, or a process named Insomnia could not be identified): $(list "${BLOCKING[@]}")." >&2
    echo "Let it finish or quit it from its menu, quit any process listed as unverified, then rerun. Nothing was removed." >&2
    exit 1
  fi
}

# 1. Check, then quit the app --------------------------------------------------
# First, before anything is changed: a copy in another account stops the run
# at once, and so does a process whose owner ps cannot give once
# QUIT_WAIT_SECONDS have passed (await_known_owners), before anything is
# asked to quit and before the first sudo. This app counts, and so does a
# process named Insomnia that cannot be told apart from it (find_insomnia);
# one proven to be another app is reported and left alone. With no copy
# identified as this app there is nothing to ask to quit, so what is listed
# is waited for here. With one, a process beside it that cannot be told
# apart from this app is waited for here on its own (await_unidentified).
# Either way such a process stops the run before the first sudo whichever
# rule is there. Then the installed app's version is read and the rule
# judged (check_rule_first), and only then is the app asked to quit. A
# process that first shows up after these looks is still waited for after
# the quit (await_exit), and blocks the removal, but by then the password
# may have been asked for.
step "Checking for Insomnia in this and other accounts"
app_was_running=0
if app_running; then
  app_was_running=1
  await_known_owners
  report_others
  stop_for_other_accounts
  report_unverified
  if (( ${#APP_FOUND[@]} == 0 )); then
    await_exit
    app_was_running=0
  elif (( ${#UNVERIFIED[@]} > 0 )); then
    await_unidentified
    stop_for_other_accounts
    stop_for_unverified
  fi
else
  report_others
fi

# The InsomniaResumeFrozenVersion the installed app's Info.plist declares,
# read here, before the recovery lock, with bounded calls, together with
# the file's identity (device, inode, change time with nanoseconds, size)
# before and after the read: no Info.plist is read under the lock. From a
# source checkout the value chooses which backstop.sh speaks the installed
# app's --resume-frozen interface (step 3), which uses it only when a
# bounded stat under the lock, which reads no contents, shows the same file
# unchanged; there a read that fails, does not answer or sees the file
# change stops the run here, before anything is removed and before any
# backstop runs. Every backstop.sh step 3 runs also gets the value and the
# identity in its environment (run_backstop). One that hands frozen entries
# to the app binary uses the value only when its own stat under the lock
# shows the same file unchanged, and keeps those entries while it is
# unknown; step 4 then stops before anything is removed.
CHECKOUT_BACKSTOP=""
if in_checkout && [[ -f "$SCRIPT_DIR/backstop.sh" ]]; then
  CHECKOUT_BACKSTOP="$SCRIPT_DIR/backstop.sh"
fi
INFO_PLIST="$APP/Contents/Info.plist"
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
if ! read_info_version "$INFO_PLIST"; then
  if [[ -n "$CHECKOUT_BACKSTOP" ]]; then
    echo "Could not read InsomniaResumeFrozenVersion from $INFO_PLIST: $INFO_PROBLEM. Which backstop.sh speaks the installed app's interface is unknown, so none was run. Nothing was removed; rerun once it reads." >&2
    exit 1
  fi
  echo "note: could not read InsomniaResumeFrozenVersion from $INFO_PLIST before the recovery lock: $INFO_PROBLEM. If the journal holds a frozen process that only the app binary can resume, it stays frozen and journaled, and step 4 then stops before anything is removed." >&2
fi

step "Checking $SUDOERS"
RULE_JUDGED=0
check_rule_first

# Ask politely and wait. The app refuses to quit while it has unresolved
# recovery work, and that refusal must stand: no pkill, no force. The quit
# goes only to a copy identified as this app in this account. An unverified
# process is waited for, but its presence alone never asks the real app to
# quit.
step "Quitting Insomnia"
if (( app_was_running )); then
  if (( ${#APP_FOUND[@]} > 0 )); then
    echo "Insomnia is running ($(list "${APP_FOUND[@]}")); asking it to quit."
    "$OSASCRIPT" -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
  await_exit
fi
# A rule judged from a read without sudo still needs the password for step 5.
(( RULE_JUDGED == 0 )) || ask_password

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
# unchanged (see read_info_version).
if [[ -n "$CHECKOUT_BACKSTOP" ]]; then
  if ! info_identity "$INFO_PLIST"; then
    echo "Checking $INFO_PLIST under the recovery lock failed ($INFO_PROBLEM), so whether the InsomniaResumeFrozenVersion read before the lock still applies is unknown, and no backstop.sh was run. Nothing was removed; rerun." >&2
    exit 1
  elif [[ "$INFO_ID" != "$INFO_EVIDENCE" ]]; then
    echo "$INFO_PLIST changed after this run read its InsomniaResumeFrozenVersion (an install may have replaced the app meanwhile). No Info.plist is read under the recovery lock, so which backstop.sh speaks the installed app's interface is unknown, and none was run. Nothing was removed; rerun." >&2
    exit 1
  fi
fi
if [[ -n "$CHECKOUT_BACKSTOP" ]] && { [[ "$INFO_VERSION" == "$RESUME_FROZEN_VERSION" ]] || { [[ ! -f "$APP/Contents/Resources/backstop.sh" ]] && [[ ! -f "$APP_SUPPORT/backstop.sh" ]]; }; }; then
  BACKSTOP="$CHECKOUT_BACKSTOP"
elif [[ -f "$APP/Contents/Resources/backstop.sh" ]]; then
  verify_rc=0
  bounded "$CODESIGN" --verify --strict "$APP" || verify_rc=$?
  if (( verify_rc == 124 || verify_rc == 125 )); then
    echo "'codesign --verify --strict $APP' $(call_result "$verify_rc"), so the backstop.sh sealed in it was not run." >&2
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
run_backstop "$BACKSTOP" || recovery_rc=$?
case "$recovery_rc" in
  125)
    echo "$BACKSTOP (pid ${BOUNDED_PID:-?}) or a process it started is still running. Either the backstop did not finish within ${BACKSTOP_TIMEOUT_SECONDS}s and had not ended three seconds after its SIGTERM, or it ended and left that process running. Nothing is killed, because it may be running sudo pmset, and the recovery lock stays held until all of them have ended. Nothing was removed; rerun once they have ended." >&2
    exit 1 ;;
  124) echo "$BACKSTOP did not finish within ${BACKSTOP_TIMEOUT_SECONDS}s and was stopped with SIGTERM; what it undid before then stays undone, and the journal shows what is left." >&2 ;;
  126) echo "$BACKSTOP could not be started: $BACKSTOP_NOT_STARTED." >&2 ;;
esac

# 4. Verify independently ------------------------------------------------------
# The checks run in $(...), which this shell waits for, not in a process
# substitution: so nothing the check starts outlives it with the lock. Their
# result does not rest on set -e, which bash turns off on the left of ||:
# each read returns an explicit status, a read that failed or did not answer
# makes the check return 2 with a note (see notes_reset), and the check
# prints "." last, so output cut short shows. Any of these counts as a
# problem, never as a clean journal.
step "Verifying the recovery journal"
problems=()
notes_reset
check_rc=0
check_text="$(journal_problems; rc=$?; echo .; exit "$rc")" || check_rc=$?
if [[ "$check_text" != *. ]]; then
  problems+=("the journal check ended before it printed all of its result, so the journal was not fully checked")
fi
text_lines "${check_text%.}"
problems+=(${TEXT_LINES[@]+"${TEXT_LINES[@]}"})
check_noted=0
if noted; then
  if notes_read; then
    text_lines "$READ_TEXT"
    for line in ${TEXT_LINES[@]+"${TEXT_LINES[@]}"}; do
      problems+=("the journal could not be fully checked: $line")
      check_noted=1
    done
  fi
  if (( ! check_noted )); then
    problems+=("the journal could not be fully checked, and the note saying why could not be read back")
    check_noted=1
  fi
fi
if (( check_rc != 0 && ! check_noted )); then
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
notes_reset
kept_rc=0
kept_text="$(refused_brightness; rc=$?; echo .; exit "$rc")" || kept_rc=$?
text_lines "${kept_text%.}"
kept_brightness=(${TEXT_LINES[@]+"${TEXT_LINES[@]}"})
kept_unknown=""
if noted; then
  kept_unknown="the note saying why could not be read back"
  if notes_read && [[ -n "$READ_TEXT" ]]; then kept_unknown="${READ_TEXT%%$'\n'*}"; fi
elif (( kept_rc != 0 )); then
  kept_unknown="the check stopped with status $kept_rc"
elif [[ "$kept_text" != *. ]]; then
  kept_unknown="the check ended before it printed all of its result"
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
# A bootout that has not ended (125) is work of this run whose outcome is
# not known, and its supervisor keeps the recovery lock until it ends, so
# nothing is removed beside it.
if (( bootout_rc == 125 )); then
  echo "'launchctl bootout' $(call_result 125) (pid ${BOUNDED_PID:-?}). It keeps the recovery lock until it ends. Nothing was removed; rerun once it has ended." >&2
  exit 1
fi
# `launchctl print` exits 113 only when the service is not loaded; 0 means
# still loaded and anything else means launchd could not be asked. 124 from
# either call means it did not answer within CALL_TIMEOUT_SECONDS, and 125
# from print that no status came back (see bounded).
print_rc=0
bounded "$LAUNCHCTL" print "gui/$UID_NUM/$LABEL" || print_rc=$?
if (( print_rc != 113 )); then
  if (( print_rc == 0 )); then
    echo "launchctl bootout exited $bootout_rc and $LABEL is still loaded in gui/$UID_NUM." >&2
  elif (( print_rc == 124 || print_rc == 125 )); then
    echo "launchctl bootout exited $bootout_rc and 'launchctl print' $(call_result "$print_rc"); cannot tell whether $LABEL is still loaded." >&2
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
  elif (( test_rc != 1 || BOUNDED_READ != 0 )) || [[ -n "$BOUNDED_OUTPUT" ]]; then
    sudoers_uncertain "'sudo -n test -e $SUDOERS' $(read_result "$test_rc")${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}, so whether the rule is there is not known."
  fi
fi
if (( sudoers_present )); then
  # Root-only, so it is read through sudo.
  read_rc=0
  bounded "$SUDO" -n "$CAT" "$SUDOERS" || read_rc=$?
  if (( read_rc == 125 )); then
    sudoers_uncertain "'sudo -n cat $SUDOERS' did not answer within ${CALL_TIMEOUT_SECONDS}s, so the rule was not removed. $(sudo_alive_note). It keeps the recovery lock until it ends."
  elif (( read_rc != 0 || BOUNDED_READ != 0 )); then
    # What a cat that exited 0 printed is the rule, not an error.
    (( read_rc != 0 )) || BOUNDED_OUTPUT=""
    echo "Could not read $SUDOERS through sudo ('sudo -n cat' $(read_result "$read_rc")${BOUNDED_OUTPUT:+: $BOUNDED_OUTPUT}), so it was kept. The LaunchAgent is already removed; the app at $APP is not." >&2
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
      4) echo "Kept $SUDOERS: it changed after this uninstall read it, or could not be shown to be a regular file of root's with one link that only root can change (${BOUNDED_OUTPUT:-no detail}). Another install.sh or uninstall.sh, perhaps in another account, may have written or removed it meanwhile, and a rule written then may be another account's." >&2 ;;
      5) echo "Kept $SUDOERS: removing it failed (${BOUNDED_OUTPUT:-no detail})." >&2 ;;
      7) echo "Kept $SUDOERS: the lock file $SUDOERS_LOCK, or a folder above it, could not be shown to be one only root can change (${BOUNDED_OUTPUT:-no detail}), so the lock that keeps two runs from changing the rule at once cannot be trusted. Nothing there was repaired: check it yourself (the lock file must be a regular file of root's with mode 0600 and one link)." >&2 ;;
      8) echo "Kept $SUDOERS: read again as root, it could not be read in full, holds a NUL byte, changed while it was read, or is not the rule install.sh writes for $ACCOUNT${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}." >&2 ;;
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
