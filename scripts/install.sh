#!/bin/bash
# Install Insomnia: put Insomnia.app (with backstop.sh sealed inside it) in
# ~/Applications, install the LaunchAgent that verifies the bundle and runs
# that script, and write the sudoers rule. Idempotent; asks for sudo once (for
# /etc/sudoers.d/insomnia), before anything of a previous install is touched.
# The bundle and the LaunchAgent are replaced together, in one locked step
# (the agent pins one build, so the two must match at every moment), and a
# run that stops after that step began puts the previous bundle back. Not
# atomic beyond that: a failure after the sudoers step says exactly what was
# replaced so far.
#
# Where the bundle comes from:
#   ./scripts/install.sh                      builds it from this checkout
#                                             (scripts/build-app.sh, ad-hoc
#                                             signed); only from a checkout's
#                                             scripts/ folder (in_checkout)
#   ./install.sh --app /path/to/Insomnia.app  installs a prebuilt bundle, such
#                                             as the one in a release zip
#                                             (arm64 only, so this stops on a
#                                             Mac without Apple Silicon), after
#                                             checking its signature, bundle
#                                             identifier and version. Those
#                                             show the bundle is intact, not
#                                             who made it, so it is refused
#                                             unless --allow-unverified-origin
#                                             is given as well: releases are
#                                             ad-hoc signed and not notarized,
#                                             and the checksum and attestation
#                                             the user checks are what tie a
#                                             zip to this repository. Nothing
#                                             of this checkout is needed then;
#                                             the zip carries this script.
# Either way the bundle is checked before the password prompt, so a bad build
# or download changes nothing.
set -euo pipefail

# Installation always uses the standard per-user layout. A relocated
# INSOMNIA_HOME would make the backstop run here act on one tree while the
# app is installed against another, so refuse rather than guess.
if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  echo "INSOMNIA_HOME is set ($INSOMNIA_HOME). install.sh only supports the standard layout under ~/Library;" >&2
  echo "unset INSOMNIA_HOME and rerun. Nothing was changed." >&2
  exit 1
fi

# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=15

# Fixed tool paths: never taken from PATH. Tests patch these lines in a
# private copy of the script so no real tool ever runs.
PGREP=/usr/bin/pgrep
PS=/bin/ps
KILL=/bin/kill
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
CODESIGN=/usr/bin/codesign
DITTO=/usr/bin/ditto
CHMOD=/bin/chmod
SYSCTL=/usr/sbin/sysctl
LOCKF=/usr/bin/lockf
MV=/bin/mv
RM=/bin/rm
RMDIR=/bin/rmdir
MKTEMP=/usr/bin/mktemp
MKDIR=/bin/mkdir
TEST=/bin/test
CAT=/bin/cat
STAT=/usr/bin/stat
LS=/bin/ls
# What root's shell asks whether an access control list entry is root's own
# (r_root): read only, never a change.
DSMEMBERUTIL=/usr/bin/dsmemberutil
# The most bytes work_read takes from one file (a call's output, status or
# pid, a note): a longer file reads as not read back.
READ_MAX_BYTES=1048576
CHOWN=/usr/sbin/chown
VISUDO=/usr/sbin/visudo
# The shell sudoers_replace runs as root.
ROOT_BASH=/bin/bash
LOCK_TIMEOUT_SECONDS=10
# The limit for one call to sudo, pgrep, ps, plutil, launchctl or codesign
# made while this run holds the recovery lock (and for the sudoers check and
# the process checks before it); see bounded() below.
CALL_TIMEOUT_SECONDS=30
# Longest backstop.sh may run in step 5 before it is sent SIGTERM (see
# run_backstop).
BACKSTOP_TIMEOUT_SECONDS=300

# What a prebuilt bundle (--app) must be, and the bundle id that makes a
# running process this app (find_insomnia).
BUNDLE_ID=com.kgarg.insomnia
# The Insomnia API client, whose executable is also named Insomnia. Its
# bundle id is the only one that proves a process is not this app.
CLIENT_BUNDLE_ID=com.insomnia.app

# The folder this script is in. build-app.sh and backstop.sh are taken from
# there, and only when it is the scripts/ folder of a source checkout, with
# Package.swift one level up (in_checkout). A release zip's folder is not: it
# holds Insomnia.app, install.sh and uninstall.sh, so a build-app.sh found
# beside this script there was added after the zip was unpacked, for example
# by another account that created the folder in /tmp beforehand. Never the
# folder above either: a zip unpacked at /tmp/Insomnia-<version> would make
# that /tmp, where any account can create scripts/build-app.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
in_checkout() { [[ "${SCRIPT_DIR##*/}" == scripts && -f "${SCRIPT_DIR%/*}/Package.swift" ]]; }
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Insomnia.app"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
LOG_DIR="$HOME/Library/Logs/Insomnia"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.insomnia.backstop"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
SUDOERS=/etc/sudoers.d/insomnia
# Held, as root, by install.sh and uninstall.sh around each compare and
# write of $SUDOERS (sudoers_replace). It sits beside the rule, in the folder
# sudo reads rules from: that folder and every folder above it belong to
# root and only root can write them, which r_guard checks before
# it opens the file. sudo skips a name there that contains a dot
# (sudoers(5), @includedir), so this file is never read as a rule. It is
# created once, root's with mode 0600, and never removed, so every run locks
# the same inode. A path with no symbolic link in it (/etc is one).
SUDOERS_LOCK=/private/etc/sudoers.d/.insomnia-sudoers.lock
# The owner the guard, the rule and the folders above them must have: root.
# Tests patch this line to the test account, the only way to run the root
# transaction without root.
ROOT_UID=0
UID_NUM="$(id -u)"
# Where the new bundle is assembled and signed (step 3) and where the previous
# one waits during the swap (step 6). Both inside $APP_DIR, so the swap is two
# renames on one filesystem. The staging directory's name carries the PID of
# the run that made it, so a later run can tell a dead run's leftover from
# the directory of an install that is still running (step 5).
PREVIOUS_APP="$APP_DIR/.Insomnia.app.previous"
STAGE=""
NEW_APP=""
# Where build-app.sh writes a source build before it is staged.
BUILD_DIR=""
TMP_SUDOERS=""
CANDIDATE=""
CANDIDATE_DIR=""
WORK=""

step() { printf '\n==> %s\n' "$*"; }
usage() { echo "usage: $0 [--app /path/to/Insomnia.app [--allow-unverified-origin]]" >&2; }
# A command for the user to paste, each word quoted for the shell, so a space,
# quote or $ in a path stays part of that path.
command_line() { local line; line="$(printf '%q ' "$@")"; printf '%s' "${line% }"; }

# Run one external call with a time limit, so a call that stalls (a sudo
# policy or directory-service lookup, a launchd that does not answer) cannot
# keep this run waiting forever. Its exit status is returned, or 124 when it
# did not finish within CALL_TIMEOUT_SECONDS and was stopped (or its status
# could not be read back as one line of digits), or 125 when it is sudo and
# still running (pid in BOUNDED_PID). Its combined output is read back once,
# with work_read: byte for byte in READ_TEXT and READ_HEAD, work_read's
# status in BOUNDED_READ (0 read whole, 1 with a NUL byte, 2 not read back),
# and in BOUNDED_OUTPUT the text before any NUL byte without its last
# newline, empty when it was not read back. A caller that acts on the output
# checks BOUNDED_READ first. The status and the pid come back through
# work_read too, so no read made after the call can hold this run either.
#
# supervise() starts the call in the background and enforces the limit
# itself, so the limit holds even if this run is killed while it waits. Once
# the limit has passed, the call gets SIGTERM, and SIGKILL one to two seconds
# later if it is still there. sudo only ever gets SIGTERM: killing sudo would
# orphan what it runs as root. Both waits are read from bash's SECONDS clock,
# which counts whole seconds, so a call gets at least CALL_TIMEOUT_SECONDS
# and at most a second more; a slow machine, where each poll takes longer,
# does not stretch them. The supervisor and the call keep fd 9 (the recovery lock, once
# this run holds it) until the call has exited, so no call made under the
# lock outlives it: if this run is killed during a launchctl bootout, the
# bootout is stopped and reaped before the lock goes, and cannot unload an
# agent the app confirms after taking the lock. Every call but sudo is gone
# within three seconds of the limit. A sudo that ignores SIGTERM keeps the
# lock until it ends, as backstop.sh does with sudo pmset.
# Each call's files get a name from mktemp, so a call made inside $(...)
# cannot reuse another's; when mktemp fails, the call is not made and the
# status is 126. A call is checked on every 2 ms for its first fifty checks,
# so a quick one is seen to end within milliseconds, and every 50 ms after
# that; each check is one exec of sleep.
# A caller whose call needs another limit than CALL_TIMEOUT_SECONDS sets
# BOUNDED_LIMIT, and one whose command must never get SIGKILL sets
# BOUNDED_TERM_ONLY=1, both as locals of its own (see run_backstop). Such a
# call is then handled as sudo is: 125 while it is still running after its
# SIGTERM. One that sets BOUNDED_OWN_GROUP=1 as well has the supervisor and
# the call started in a process group of their own (set -m around the one
# `&`), so no signal sent to this run's process group reaches the call or
# anything it started; only the supervisor's SIGTERM at the limit does.
BOUNDED_OUTPUT=""
BOUNDED_READ=2
BOUNDED_PID=""
BOUNDED_LIMIT=""
BOUNDED_TERM_ONLY=""
BOUNDED_OWN_GROUP=""
bounded() { # command args...
  local base supervisor rc deadline limit="${BOUNDED_LIMIT:-$CALL_TIMEOUT_SECONDS}" term_only=0 polls=0
  local pid_form=$'^([0-9]+)\n?$' rc_form=$'^([0-9]{1,3})\n$'
  if [[ "$1" == "$SUDO" || -n "${BOUNDED_TERM_ONLY:-}" ]]; then term_only=1; fi
  BOUNDED_OUTPUT=""
  BOUNDED_READ=2
  BOUNDED_PID=""
  READ_TEXT=""
  READ_HEAD=""
  base="$("$MKTEMP" "$WORK/call.XXXXXX")" || return 126
  if [[ -n "${BOUNDED_OWN_GROUP:-}" ]]; then set -m; fi
  supervise "$base" "$limit" "$term_only" "$@" </dev/null >/dev/null 2>&1 &
  supervisor=$!
  set +m
  if (( term_only )); then
    # The supervisor's limit (at most a second over), then at least two
    # seconds for the call to stop on SIGTERM.
    deadline=$(( SECONDS + limit + 3 ))
    while [[ ! -s "$base.rc" ]] && (( SECONDS <= deadline )); do
      if (( polls < 50 )); then sleep 0.002; else sleep 0.05; fi
      polls=$((polls + 1))
    done
    if [[ ! -s "$base.rc" ]]; then
      # The pid is for messages only: nothing here signals it.
      if work_read "$base.pid" && [[ "$READ_TEXT" =~ $pid_form ]]; then BOUNDED_PID="${BASH_REMATCH[1]}"; fi
      READ_TEXT=""
      READ_HEAD=""
      return 125
    fi
  fi
  # Any other call gets SIGKILL at most two seconds after its SIGTERM, so
  # this wait ends.
  wait "$supervisor" 2>/dev/null || true
  rc=124
  if work_read "$base.rc" && [[ "$READ_TEXT" =~ $rc_form ]] && (( 10#${BASH_REMATCH[1]} <= 255 )); then
    rc=$(( 10#${BASH_REMATCH[1]} ))
  fi
  BOUNDED_READ=0
  work_read "$base.out" || BOUNDED_READ=$?
  BOUNDED_OUTPUT="${READ_HEAD%$'\n'}"
  return "$rc"
}
# The supervising process of one bounded() call; it runs in the background.
# The call is its only job, so `kill %1` signals the call, and the shell
# skips a job it has already reaped: a reused pid is never signalled. Bash
# records that job under the process group the supervisor was started in,
# and when that is a group of its own (BOUNDED_OWN_GROUP), `kill %1` would
# signal the whole group, the call's own children too. Turning job control
# on and off again before the call starts clears that record, so `kill %1`
# always signals the call alone. The status file is written once the call
# has been reaped.
# The call's output, its pid and the status go to files opened read-write:
# unlike a write-only open, that never waits for a reader when a FIFO stands
# at the name, so no such file can hold the supervisor, the lock it keeps,
# or bounded()'s wait for it. bounded() reads them back with work_read,
# which takes nothing but a regular file.
# Like backstop.sh's supervisor, it ignores SIGTERM and SIGHUP, so a signal
# sent to this run's whole process group (a closed terminal, or launchd once
# a job's main process has gone) does not end it while its call runs. sudo
# closes its copy of fd 9, so the supervisor may be the only holder of the
# recovery lock until the call has exited. The call gets back the SIGTERM
# and SIGHUP actions this script started with, so it still stops on the
# SIGTERM at its limit, and on one sent to the group when it shares this
# run's group. errexit is off here: a failed write must not end the
# supervisor while its call runs.
supervise() { # base limit term-only command args...
  local base="$1" limit="$2" term_only="$3" cpid rc=0 deadline polls=0
  shift 3
  set +e
  trap '' TERM HUP
  set -m
  set +m
  ( trap - TERM HUP; exec "$@" ) </dev/null 1<>"$base.out" 2>&1 &
  cpid=$!
  echo "$cpid" 1<>"$base.pid"
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
    wait "$cpid" 2>/dev/null || true
    echo 124 1<>"$base.rc"
    return
  fi
  wait "$cpid" || rc=$?
  echo "$rc" 1<>"$base.rc"
}
# How a bounded call's exit status reads in a message.
call_result() { # status
  if (( $1 == 124 )); then
    printf 'did not answer within %ss' "$CALL_TIMEOUT_SECONDS"
  else
    printf 'exited %s' "$1"
  fi
}
# The same for a bounded call whose output was read: when it exited 0, what
# was wrong with that output (BOUNDED_READ, from work_read).
read_result() { # status
  if (( $1 != 0 )); then
    call_result "$1"
  elif (( BOUNDED_READ == 1 )); then
    printf 'exited 0, but printed a NUL byte'
  else
    printf 'exited 0, but what it printed could not be read back in full'
  fi
}
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
# The InsomniaResumeFrozenVersion an installed app's Info.plist declares,
# read before the recovery lock (step 5) for the backstop, which hands
# frozen entries to the app binary only when the value is the
# --resume-frozen interface version it speaks and its own stat under the
# lock shows the same file unchanged. The same text as in uninstall.sh and
# backstop.sh, which say more.
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
# backstop.sh, run as one bounded call with its own limit,
# BACKSTOP_TIMEOUT_SECONDS, and SIGTERM only, never SIGKILL: on SIGTERM it
# removes its private files and ends, while each sudo pmset or app binary
# call it started keeps the recovery lock through its own supervisor until
# that call has exited. It shares this run's lock through fd 9, which the
# supervisor here keeps until the backstop has exited, even if this run is
# killed first. The supervisor and the backstop run in a process group of
# their own (BOUNDED_OWN_GROUP), so a signal sent to this run's group (a
# closed terminal, or launchd once this run has gone) reaches nothing the
# backstop started, and the SIGTERM at the limit goes to the backstop
# process alone. So a backstop from an older build, whose supervisor for
# sudo pmset does not ignore SIGTERM and SIGHUP, still keeps the lock in
# that supervisor until its sudo has ended and been reaped. The
# InsomniaResumeFrozenVersion read before the lock, and the identity of the
# file it came from, go down in its environment (see read_info_version).
# Returns the backstop's status, or 124 when it was stopped at its limit,
# 125 when it was still running three seconds after its SIGTERM (pid in
# BOUNDED_PID; it keeps the lock until it ends), 126 when it could not be
# started. What it printed is printed once it ends.
run_backstop() { # backstop.sh
  local rc=0 BOUNDED_LIMIT="$BACKSTOP_TIMEOUT_SECONDS" BOUNDED_TERM_ONLY=1 BOUNDED_OWN_GROUP=1
  local INSOMNIA_INFO_PATH="$INFO_PLIST" INSOMNIA_INFO_EVIDENCE="$INFO_EVIDENCE" INSOMNIA_INFO_VERSION="$INFO_VERSION"
  export INSOMNIA_INFO_PATH INSOMNIA_INFO_EVIDENCE INSOMNIA_INFO_VERSION
  bounded /bin/bash "$1" --force || rc=$?
  if [[ -n "$BOUNDED_OUTPUT" ]]; then printf '%s\n' "$BOUNDED_OUTPUT"; fi
  return "$rc"
}

# `launchctl print` exits 0 when a job with the label is loaded and 113 when
# none is. Anything else is unknown, not absent, and so is a print that did
# not answer in time (unknown:124). Being loaded says nothing about which
# plist or schedule that job runs (it may be an older one).
loaded_state() { # -> yes | no | unknown:<rc>
  local rc=0
  bounded "$LAUNCHCTL" print "gui/$UID_NUM/$LABEL" || rc=$?
  if (( rc == 124 )); then
    echo "'launchctl print gui/$UID_NUM/$LABEL' did not answer within ${CALL_TIMEOUT_SECONDS}s; whether the job is loaded is unknown (unknown:124)." >&2
  fi
  case "$rc" in
    0) echo yes ;;
    113) echo no ;;
    *) echo "unknown:$rc" ;;
  esac
}

PREBUILT=""
ALLOW_UNVERIFIED_ORIGIN=0
while (( $# )); do
  case "$1" in
    --app) [[ $# -ge 2 ]] || { usage; exit 2; }; PREBUILT="$2"; shift 2 ;;
    --allow-unverified-origin) ALLOW_UNVERIFIED_ORIGIN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
if (( ALLOW_UNVERIFIED_ORIGIN )) && [[ -z "$PREBUILT" ]]; then
  echo "--allow-unverified-origin applies to --app only; a source build has no download to vouch for." >&2
  usage
  exit 2
fi
if [[ "${INSOMNIA_LID_SIMULATION:-}" == 1 && -n "$PREBUILT" ]]; then
  echo "INSOMNIA_LID_SIMULATION=1 applies to a source build only; the bundle given with --app is already compiled. Nothing was changed." >&2
  exit 2
fi

# Moves a bundle with one rename. Every path passed here is inside $APP_DIR,
# one filesystem, so a rename that fails leaves both paths as they were.
# Refuses when something is at the destination: mv would move the bundle
# into it instead. Each caller handles a failure itself; under set -e an
# unhandled one would exit with the previous job unloaded and let cleanup
# delete the staged build.
move_bundle() { # from to
  if [[ -e "$2" || -L "$2" ]]; then
    echo "not moving $1: $2 already exists" >&2
    return 1
  fi
  "$MV" "$1" "$2"
}

# Whether sudo grants the four pmset commands of the rule without a
# password: 0 when it does, 124 when a check did not answer within
# CALL_TIMEOUT_SECONDS and stopped on SIGTERM, 125 when it did not stop and
# is still running (BOUNDED_PID), 1 otherwise. `sudo -n -l <command>` checks
# the rule without running pmset (nothing on the machine changes).
pmset_rule_check() { # pmset arguments
  local rc=0
  bounded "$SUDO" -n -l /usr/bin/pmset "$@" || rc=$?
  if (( rc == 0 || rc == 124 || rc == 125 )); then return "$rc"; fi
  return 1
}
# The part of a message about a sudo check that is still running.
sudo_alive_note() {
  printf "It was sent SIGTERM and is still running as pid %s. It is not killed, because killing sudo could leave what it runs as root behind" "${BOUNDED_PID:-?}"
}
pmset_rule_effective() {
  pmset_rule_check -a disablesleep 1 \
    && pmset_rule_check -a disablesleep 0 \
    && pmset_rule_check -b lowpowermode 1 \
    && pmset_rule_check -b lowpowermode 0
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
# rule at $SUDOERS is one file for the whole Mac, this install replaces it
# with a rule for this account, and that copy may need it to undo its own
# session. It is reported, and never asked to quit or signalled; only its
# own account can quit it. A process whose owner `ps -o uid=` does not give
# (it failed, did not answer, or printed no user ID) may be in either
# account, so it is neither: it is never asked to quit, and it stops the run
# before the first sudo (UNKNOWN_OWNER, stop_for_other_accounts) unless a
# fresh look finds it gone (await_identified). Only a process proven to be
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
# process first seen then counts as unverified and blocks.
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
  # pgrep exits 1 when no process has the name.
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
    if (( rc == 0 && BOUNDED_READ == 0 )); then exe="$BOUNDED_OUTPUT"; fi
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
# Why replacing the rule at $SUDOERS would take access away from someone
# other than $USER, or nothing when every line is a comment or is for
# $USER. Judged by the user field a line starts with, not by its commands,
# so a rule from any version of this script passes for its own account.
# A line is this account's only when that field is exactly $USER or
# #$UID_NUM (sudoers' form for a user ID) and no comma after it carries on
# the user list. Any other field counts, so the check fails closed: another
# name or user ID, %group, %#gid, +netgroup, an alias, ALL, a quoted name,
# Defaults, an include, a continued line. The new file would drop it.
# "#" starts a comment as it does for sudo: not when a digit, or "-" and a
# digit, follows (a user ID), and not in #include or #includedir.
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
# Stops the install when the rule's text $1 has a line for anyone but $USER
# (sudoers_for_others). Nothing has been changed by then.
stop_for_rule_of_others() { # file content
  local why
  why="$(sudoers_for_others "$1")"
  if [[ "$why" == grants\ * ]]; then
    echo "$SUDOERS $why, not $USER. Another account installed Insomnia, and its recovery agent needs that rule to undo a session, even one whose app crashed. This Mac has room for one rule, so this install would take it away." >&2
    echo "Uninstall Insomnia in that account first. If that account no longer exists, remove the rule with 'sudo rm $SUDOERS', then rerun. Nothing was changed." >&2
    exit 1
  elif [[ -n "$why" ]]; then
    echo "$SUDOERS $why. Replacing the file would drop that line." >&2
    echo "Check it, remove the file with 'sudo rm $SUDOERS' if nothing needs it, then rerun. Nothing was changed." >&2
    exit 1
  fi
}
# Stops the run when Insomnia runs in another account, when a process named
# Insomnia has an owner ps could not give, or when pgrep could not say
# whether it runs; nothing is sent to any process. The argument says what
# this run has changed so far.
stop_for_other_accounts() { # what was changed
  if [[ -n "$PGREP_PROBLEM" ]]; then
    echo "$PGREP_PROBLEM, so whether Insomnia runs in this or another account is unknown. Rerun once it answers. $1" >&2
    exit 1
  fi
  if (( ${#UNKNOWN_OWNER[@]} > 0 )); then
    echo "Whose process these are could not be read, so whether Insomnia runs in this or another account is unknown: $(list "${UNKNOWN_OWNER[@]}")." >&2
    echo "$SUDOERS is shared by every account on this Mac, so nothing was asked to quit. Rerun once 'ps -o uid= -p <pid>' answers for them, or once they have exited. $1" >&2
    exit 1
  fi
  (( ${#OTHER_ACCOUNT[@]} > 0 )) || return 0
  echo "Insomnia is running in another account, or a process named Insomnia there could not be told apart from it: $(list "${OTHER_ACCOUNT[@]}")." >&2
  echo "$SUDOERS is shared by every account on this Mac and that copy may need the rule in it, so it is left alone and not asked to quit." >&2
  echo "Quit Insomnia in that account, then rerun. $1" >&2
  exit 1
}
# Before the first sudo, which asks for the password: a process whose owner
# or identity could not be read may be another account's copy of this app,
# whose grant the rule written next would take away. The lookup may only
# have raced the process's exit, so the processes are listed again, once a
# second for up to QUIT_WAIT_SECONDS, while any such process is listed. One
# that is still listed then stops the run (stop_for_other_accounts,
# stop_for_unverified). A pgrep problem stops it at once.
await_identified() {
  local i
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    [[ -z "$PGREP_PROBLEM" ]] || return 0
    (( ${#UNKNOWN_OWNER[@]} + ${#UNVERIFIED[@]} > 0 )) || return 0
    sleep 1
    find_insomnia
  done
  return 0
}
stop_for_unverified() { # what was changed
  (( ${#UNVERIFIED[@]} > 0 )) || return 0
  echo "Cannot tell whether ${#UNVERIFIED[@]} process(es) named Insomnia are this app, and they were still running after ${QUIT_WAIT_SECONDS}s: $(list "${UNVERIFIED[@]}")." >&2
  echo "Nothing was asked to quit. Quit them, or wait for them to exit, then rerun. $1" >&2
  exit 1
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
# Exits with status $1, saying why on stderr, unless `ls -lden` shows that
# no access control list on the files and folders named after it lets
# anyone but root change them. -n prints each entry's principal as its
# UUID. An entry that allows anything but reading (write, append, delete,
# add_file, add_subdirectory, delete_child, writeattr, writeextattr,
# writesecurity, chown, or a right not listed here) passes only when
# r_root shows its UUID is root's own user record, whatever its
# inheritance flags: a folder's inheritable entries reach the files made in
# it. Deny entries pass. So does an answer only when it is read in full:
# ls fails (even after printing), prints a line not parsed here, numbers
# its entries with a gap (ls skips an entry it cannot read but still counts
# it), marks a list (+) and prints no entry, or leaves out a name, and the
# run stops. Nothing is ever repaired.
r_acl() { # status name...
  local s="$1" out rc=0 line name="" plus="" n=0 seen=0 a p w u
  local re='^ ([0-9]+): ([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})( inherited)? (allow|deny) ([a-z_,]+)$'
  shift
  out="$("$LS" -lden "$@" 2>&1 && echo .)" || rc=$?
  if (( rc != 0 )); then
    r_die "$s" "the access control lists of $* could not be read (ls exited $rc: $out)"
  fi
  # An answer without a newline at its end keeps the "." and fails below.
  out="${out%$'\n.'}"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[-a-z][-rwxsStT]{9}([@+]?)\  ]]; then
      if [[ "$plus" == + ]] && (( n == 0 )); then break; fi
      plus="${BASH_REMATCH[1]}" n=0 name=""
      for a in "$@"; do
        if [[ "$line" == *" $a" ]] && (( ${#a} > ${#name} )); then name="$a"; fi
      done
      [[ -n "$name" ]] || break
      seen=$(( seen + 1 ))
    elif [[ -n "$name" && "$line" =~ $re && "${BASH_REMATCH[1]}" == "$n" ]]; then
      n=$(( n + 1 ))
      [[ "${BASH_REMATCH[4]}" == allow ]] || continue
      u="${BASH_REMATCH[2]}" w=0
      for p in ${BASH_REMATCH[5]//,/ }; do
        case "$p" in
          read | execute | readattr | readextattr | readsecurity | list | search \
            | file_inherit | directory_inherit | limit_inherit | only_inherit) ;;
          *) w=1 ;;
        esac
      done
      (( w == 0 )) || r_root "$u" || r_die "$s" "$name has an access control list entry that allows more than reading ($line)"
    else
      name=""
      break
    fi
  done <<< "$out"
  if [[ -z "$name" || ( "$plus" == + && "$n" == 0 ) || "$seen" != "$#" ]]; then
    r_die "$s" "the access control lists of $* could not be read in full (ls: $out)"
  fi
}
# Exits 7 unless every folder from the one that holds $SUDOERS_LOCK up to /
# is a folder of root's that group and others cannot write, with no access
# control list that lets anyone but root change it (r_acl). Leaves the
# folders in DIRS.
r_dirs() {
  local d="$SUDOERS_LOCK"
  DIRS=()
  while [[ "$d" == /?* ]]; do
    d="${d%/*}"
    r_stat 7 "${d:-/}"
    if [[ "$ST_T" != 4 || ( "$ST_U" != 0 && "$ST_U" != "$ROOT_UID" ) ]] || (( (8#$ST_P & 8#022) != 0 )); then
      r_die 7 "${d:-/}, a folder above $SUDOERS_LOCK, is not a folder of root's that only root can write (stat: $ST_T $ST_P $ST_U)"
    fi
    DIRS+=("${d:-/}")
  done
  r_acl 7 "${DIRS[@]}"
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
  r_acl 7 "$SUDOERS_LOCK"
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
  r_acl 4 "$1"
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
  r_acl 7 "$SUDOERS_LOCK"
  if [[ "$1" == absent ]]; then
    [[ ! -e "$2" && ! -L "$2" ]] || r_die 4 "$2 is there now"
    return 0
  fi
  r_read "$2"
  [[ "$R_ID" == "${P_META%% *}" ]] || r_die 4 "$2 was replaced after root read it"
  [[ "$R_META" == "$P_META" && "$R_RAW" == "$P_RAW" ]] || r_die 4 "$2 changed after root read it"
}

# The rule this script writes for $USER: a header and the four pmset
# commands, nothing else. Root writes it from this function too.
sudoers_rule_text() {
  printf '%s\n' "# Installed by Insomnia install.sh. Exactly four commands, nothing else." \
    "$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1" \
    "$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0" \
    "$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1" \
    "$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0"
}

# $SUDOERS is one file for the whole Mac, and another account's install.sh
# or uninstall.sh may write or remove it between this run's read (step 2)
# and its write. So the write happens only if the file is still what this
# run read and judged: absent, or exactly the text it read. That text is
# handed to root as an argument, so what root compares is what was judged
# here, not a file anyone could change meanwhile. The compare and the write
# are one call to sudo, run as root while it holds $SUDOERS_LOCK
# (r_guard), the lock uninstall.sh takes for its compare and removal.
# Root reads the rule through a descriptor it opened and checked (r_pin),
# and judges that text again with sudoers_for_others.
# The new rule is written from sudoers_rule_text beside the old one (sudo
# skips a name with a dot), owned by root with mode 0440, and checked there
# with visudo. Last, r_recheck checks the folders, the lock and the
# access control lists again and reads the rule again through a new
# descriptor; the rename follows only when the path still names the file
# root opened and holds the bytes root read first. The rename puts the new
# rule over the old one: the rule is the old one or the new one, never a
# mix. The copy is removed when the root shell exits without renaming it;
# a root shell killed outright (SIGKILL) leaves it, under a dotted name sudo
# never reads.
#
# The lock keeps out only the runs that take it: install.sh and uninstall.sh
# of this version. Scripts of earlier releases take no lock, and neither does
# an administrator's own sudo. Against those, the checks above leave only the
# moments between root's last check (the reread in r_recheck) and its
# rename open; they do not close them. An identity or byte check cannot: a
# writer that takes no lock can still change the rule after the last read.
#
# Exit status: 0 replaced; 3 the lock was not free within
# LOCK_TIMEOUT_SECONDS; 4 the rule changed since it was read, or is not a
# regular file of root's with one link that only root can change (an access
# control list that lets anyone but root change it, or one not read in
# full, counts), or a stat of it failed or gave an answer not in the form
# asked for; 5 staging the new rule failed (mktemp's answer is not a name
# beside the rule counts), or mv reported that the rename failed; 6 the new
# rule failed
# visudo's check; 7 the lock file, or a folder above it, is not one only
# root can change, or its access control list or a stat of it could not be
# read in full; 8 the rule as root read it could not be read in full (cat
# failed, or the stat after the read failed), holds a NUL byte, changed
# while it was read, or has a line for someone else; 2 a bad call. 1 is
# sudo's own (a wrong password) or a shell error before the rename. In all
# of these the rule was not replaced, though the lock file may have been
# created. Any other status (the root shell, or its mv, was killed by a
# signal), or a call that never returns, leaves it unknown whether the
# rename happened.
r_replace() { # absent|same rule [text]
  local t
  STAGED=""
  trap '[[ -z "$STAGED" ]] || "$RM" -f "$STAGED"' EXIT
  umask 077
  case "$1" in absent | same) ;; *) exit 2 ;; esac
  r_guard "$2"
  if [[ "$1" == absent ]]; then
    [[ ! -e "$2" && ! -L "$2" ]] || r_die 4 "$2 is there now"
  else
    r_pin "$2" "${3-}"
    [[ -z "$(sudoers_for_others "$P_TEXT")" ]] || exit 8
  fi
  # Only a name mktemp gives beside the rule is written, or removed on exit.
  t="$("$MKTEMP" "$2.XXXXXX")" || exit 5
  [[ "${t%.*}" == "$2" && ${#t} == $(( ${#2} + 7 )) ]] || exit 5
  STAGED="$t"
  sudoers_rule_text > "$STAGED" || exit 5
  { "$CHOWN" root:wheel "$STAGED" && "$CHMOD" 0440 "$STAGED"; } || exit 5
  "$VISUDO" -cf "$STAGED" >/dev/null || exit 6
  r_recheck "$1" "$2"
  # An mv killed by a signal may have renamed already, so its status goes
  # on as it is, an unknown result, not as a failed rename.
  "$MV" -f "$STAGED" "$2" || { rc=$?; (( rc > 128 )) && exit "$rc"; exit 5; }
  STAGED=""
  exit 0
}
# The functions named, as `declare -f` prints them, with the spaces that
# start each line cut, for the text a root shell runs: sudo logs that text
# and ps shows it, and the indentation is a fifth of it. bash prints $'\n'
# as a newline inside single quotes, so a quoted string may run across
# lines; none of these functions has one whose next line starts with a
# space, which the cut would change. A test checks that bash reads the cut
# text back to the same functions. The same in install.sh and uninstall.sh.
root_functions() { # name...
  local line
  while IFS= read -r line; do
    printf '%s\n' "${line#"${line%%[! ]*}"}"
  done <<< "$(declare -f "$@")"
}
# Runs r_replace as root, in one sudo call. The shell's script
# is this script's fixed tool paths, the account's name and user ID, and the
# text of the functions root runs (root_functions); sudo resets the
# environment, so nothing root runs comes from PATH. $2 is the rule's text
# as step 2 read and judged it ("same" only).
sudoers_replace() { # absent|same [text]
  "$SUDO" "$ROOT_BASH" -c "set -u
$(printf '%s=%q\n' SUDOERS_LOCK "$SUDOERS_LOCK" ROOT_UID "$ROOT_UID" USER "$USER" UID_NUM "$UID_NUM" \
    LOCK_TIMEOUT_SECONDS "$LOCK_TIMEOUT_SECONDS" LOCKF "$LOCKF" STAT "$STAT" CAT "$CAT" LS "$LS" \
    DSMEMBERUTIL "$DSMEMBERUTIL" MKTEMP "$MKTEMP" CHOWN "$CHOWN" CHMOD "$CHMOD" VISUDO "$VISUDO" MV "$MV" RM "$RM")
$(root_functions r_die r_stat r_file r_root r_acl r_dirs r_guard r_read r_pin r_recheck \
    sudoers_for_others sudoers_rule_text r_replace)
r_replace \"\$@\"" insomnia-sudoers-replace "$1" "$SUDOERS" "${2-}"
}

cleanup() {
  if [[ -n "$TMP_SUDOERS" ]]; then "$RM" -f "$TMP_SUDOERS"; fi
  if [[ -n "$CANDIDATE" ]]; then "$RM" -f "$CANDIDATE"; fi
  if [[ -n "$CANDIDATE_DIR" ]]; then "$RMDIR" "$CANDIDATE_DIR" 2>/dev/null || true; fi
  if [[ -n "$STAGE" ]]; then "$RM" -rf "$STAGE"; fi
  if [[ -n "$BUILD_DIR" ]]; then "$RM" -rf "$BUILD_DIR"; fi
  if [[ -n "$WORK" ]]; then
    "$RM" -f "$WORK"/call.* 2>/dev/null || true
    "$RMDIR" "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# Scratch space for bounded(): this run's own directory, emptied on exit.
WORK="$("$MKTEMP" -d "${TMPDIR:-/tmp}/insomnia-install.XXXXXX")"

# 1. The bundle to install ---------------------------------------------------
#    Built or verified before the password prompt: nothing on the machine has
#    changed when this step fails.
if [[ -n "$PREBUILT" ]]; then
  step "Checking the prebuilt bundle $PREBUILT"
  # Release bundles are built for arm64 only (the Release workflow runs on
  # Apple Silicon). hw.optional.arm64 describes the hardware, so a shell
  # running under Rosetta on an Apple Silicon Mac still reads 1; an Intel
  # Mac reads 0 or has no such key.
  arm64="$("$SYSCTL" -n hw.optional.arm64 2>/dev/null || true)"
  if [[ "$arm64" != 1 ]]; then
    echo "Release bundles of Insomnia run on Apple Silicon Macs only, and this Mac is not one ('sysctl -n hw.optional.arm64' gave ${arm64:-no value}). Build and install from a source checkout instead (README, Build from source). Nothing was changed." >&2
    exit 1
  fi
  if [[ ! -d "$PREBUILT" || ! -f "$PREBUILT/Contents/Info.plist" ]]; then
    echo "$PREBUILT is not an app bundle (no Contents/Info.plist). Nothing was changed." >&2
    exit 1
  fi
  # Every check below runs on a private copy, and that copy is what step 3
  # stages and pins. $PREBUILT may sit where someone else can write (a
  # shared folder, /tmp); a bundle swapped there while the password prompt
  # waits is never copied in. BUILD_DIR is removed at exit, as for a build.
  BUILD_DIR="$("$MKTEMP" -d)"
  CHECKED_APP="$BUILD_DIR/Insomnia.app"
  if ! "$DITTO" "$PREBUILT" "$CHECKED_APP"; then
    echo "could not copy $PREBUILT to check it. Nothing was changed." >&2
    exit 1
  fi
  INFO_PLIST="$CHECKED_APP/Contents/Info.plist"
  # Signature first: nothing below is read from the bundle until it is known
  # to be intact. --strict rejects what newer codesign would, --deep covers
  # nested code should a later build add any.
  if ! "$CODESIGN" --verify --strict --deep "$CHECKED_APP"; then
    echo "$PREBUILT fails 'codesign --verify --strict --deep': the download is damaged or was modified. Nothing was changed." >&2
    echo "Check the zip against SHA256SUMS and 'gh attestation verify' (README, Install) and download it again." >&2
    exit 1
  fi
  PREBUILT_ID="$("$PLUTIL" -extract CFBundleIdentifier raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  if [[ "$PREBUILT_ID" != "$BUNDLE_ID" ]]; then
    echo "$PREBUILT has bundle identifier '${PREBUILT_ID:-<none>}', not $BUNDLE_ID. Nothing was changed." >&2
    exit 1
  fi
  PREBUILT_VERSION="$("$PLUTIL" -extract CFBundleShortVersionString raw -o - "$INFO_PLIST" 2>/dev/null || true)"
  if [[ ! "$PREBUILT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$PREBUILT has no usable CFBundleShortVersionString ('${PREBUILT_VERSION:-<none>}'). Nothing was changed." >&2
    exit 1
  fi
  if [[ ! -f "$CHECKED_APP/Contents/Resources/backstop.sh" ]]; then
    echo "$PREBUILT has no Contents/Resources/backstop.sh; the recovery agent needs the sealed copy. Nothing was changed." >&2
    exit 1
  fi
  # Origin. The checks above show the bundle is intact, not where it came
  # from. A signature shows the bundle has not changed since it was signed,
  # and anyone can sign a bundle with this identifier, so this script does
  # not read who signed it. Releases are ad-hoc signed and not notarized
  # (docs/releasing.md). What ties a zip to this repository's Release
  # workflow is the checksum and the attestation, which only the user can
  # check, so every prebuilt bundle needs --allow-unverified-origin, the flag
  # that says they did.
  if (( ALLOW_UNVERIFIED_ORIGIN )); then
    echo "WARNING: the origin of Insomnia $PREBUILT_VERSION is not verified. Its signature shows the bundle is intact, not who made it."
    echo "--allow-unverified-origin: installing it anyway. Its backstop.sh will run as you at login and every 60 s."
    echo "Continue only if you checked the zip yourself with SHA256SUMS and 'gh attestation verify' (README, Install)."
    echo "Releases are not notarized, so macOS blocks the first launch of a downloaded one until you allow it in System Settings > Privacy & Security."
  else
    cat >&2 <<REFUSE
The origin of Insomnia $PREBUILT_VERSION at $PREBUILT is not verified. Its signature shows the bundle is
intact, not who made it: anyone can sign a bundle with this identifier, and this install.sh cannot tell
where it came from. Installing it would run its backstop.sh as you at login and every 60 s. Nothing was changed.
Verify the zip yourself first ('shasum -a 256 -c SHA256SUMS' and 'gh attestation verify' with --signer-workflow,
see the README), then rerun with the flag that says so:
  $(command_line "$0" --allow-unverified-origin --app "$PREBUILT")
REFUSE
    exit 1
  fi
  SOURCE_APP="$CHECKED_APP"
else
  if ! in_checkout || [[ ! -f "$SCRIPT_DIR/build-app.sh" ]]; then
    echo "$SCRIPT_DIR is not the scripts folder of a source checkout (build-app.sh beside this script, Package.swift one level up), so there is nothing to build from. To install the bundle of a release zip, pass it with --app (README, Install). Nothing was changed." >&2
    if [[ -e "$SCRIPT_DIR/build-app.sh" ]] && ! in_checkout; then
      echo "$SCRIPT_DIR/build-app.sh was not run: a release zip has no build-app.sh, so it was added after the zip was unpacked." >&2
    fi
    exit 1
  fi
  BUILD_DIR="$("$MKTEMP" -d)"
  "$SCRIPT_DIR/build-app.sh" --output "$BUILD_DIR"
  SOURCE_APP="$BUILD_DIR/Insomnia.app"
fi

# 2. sudoers -----------------------------------------------------------------
#    The password prompt comes first: until the rule is installed and proven
#    effective, the running app is not asked to quit and neither the bundle
#    (backstop.sh included) nor the LaunchAgent are touched. A copy running
#    in another account stops the install before the first sudo
#    (find_insomnia), and so does a process named Insomnia whose owner or
#    identity cannot be read and that is still listed after
#    QUIT_WAIT_SECONDS (await_identified). So does a rule with a line for
#    another account (stop_for_rule_of_others): that account's agent needs
#    it to undo a session even after its app crashed, when no process of it
#    is left to find. A rule this account can read is judged before the
#    first sudo, the password prompt included; one only root can read (the
#    rule this script writes is root's, mode 0440) right after the prompt.
#    A rule that cannot be read in full stops the install either way. The
#    rule is written only if it is still what was read here
#    (sudoers_replace).
find_insomnia
await_identified
stop_for_other_accounts "Nothing was changed."
stop_for_unverified "Nothing was changed."
if [[ -e "$SUDOERS" && -r "$SUDOERS" ]]; then
  read_rc=0
  bounded "$CAT" "$SUDOERS" || read_rc=$?
  if (( read_rc != 0 || BOUNDED_READ != 0 )); then
    # What a cat that exited 0 printed is the rule, not an error.
    (( read_rc != 0 )) || BOUNDED_OUTPUT=""
    echo "Could not read $SUDOERS ('cat' $(read_result "$read_rc")${BOUNDED_OUTPUT:+: $BOUNDED_OUTPUT}), so whether it grants another account is not known. Nothing was changed." >&2
    exit 1
  fi
  stop_for_rule_of_others "$BOUNDED_OUTPUT"
fi
step "Writing $SUDOERS (requires your password once)"
# The password is asked here, once. The calls that read the rule after it
# are `sudo -n` and bounded, so a read that does not answer is stopped
# instead of waiting; visudo and the transaction below use the same
# authentication.
if ! "$SUDO" -v; then
  echo "sudo did not authenticate, so $SUDOERS was not written. Nothing was changed." >&2
  exit 1
fi
sudoers_expect=absent
sudoers_text=""
sudoers_present=0
if [[ -e "$SUDOERS" ]]; then
  sudoers_present=1
else
  test_rc=0
  bounded "$SUDO" -n "$TEST" -e "$SUDOERS" || test_rc=$?
  if (( test_rc == 0 )); then
    sudoers_present=1
  elif (( test_rc == 125 )); then
    echo "'sudo -n test -e $SUDOERS' did not answer within ${CALL_TIMEOUT_SECONDS}s, so whether a rule is there is not known. $(sudo_alive_note). Nothing was changed." >&2
    exit 1
  elif (( test_rc != 1 || BOUNDED_READ != 0 )) || [[ -n "$BOUNDED_OUTPUT" ]]; then
    echo "'sudo -n test -e $SUDOERS' $(read_result "$test_rc")${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}, so whether a rule is there is not known. Nothing was changed." >&2
    exit 1
  fi
fi
if (( sudoers_present )); then
  # Root-only, so it is read through sudo, the same way uninstall.sh reads it.
  # The text goes to root as it was read, trailing newlines cut, as $(...)
  # would cut them.
  read_rc=0
  bounded "$SUDO" -n "$CAT" "$SUDOERS" || read_rc=$?
  if (( read_rc == 125 )); then
    echo "'sudo -n cat $SUDOERS' did not answer within ${CALL_TIMEOUT_SECONDS}s, so it was not replaced. $(sudo_alive_note). Nothing was changed." >&2
    exit 1
  elif (( read_rc != 0 || BOUNDED_READ != 0 )); then
    # What a cat that exited 0 printed is the rule, not an error.
    (( read_rc != 0 )) || BOUNDED_OUTPUT=""
    echo "Could not read $SUDOERS through sudo, so it was not replaced. Nothing was changed." >&2
    echo "'sudo -n cat $SUDOERS' $(read_result "$read_rc")${BOUNDED_OUTPUT:+: $BOUNDED_OUTPUT}" >&2
    exit 1
  fi
  sudoers_text="${BOUNDED_OUTPUT%"${BOUNDED_OUTPUT##*[!$'\n']}"}"
  sudoers_expect=same
  stop_for_rule_of_others "$sudoers_text"
fi
TMP_SUDOERS="$("$MKTEMP")"
sudoers_rule_text > "$TMP_SUDOERS"
if ! "$SUDO" "$VISUDO" -cf "$TMP_SUDOERS" >/dev/null; then
  echo "sudoers file failed validation (or sudo did not authenticate); not installed. Nothing was changed." >&2
  exit 1
fi
replace_rc=0
sudoers_replace "$sudoers_expect" "$sudoers_text" || replace_rc=$?
case "$replace_rc" in
  0) ;;
  3)
    echo "$SUDOERS was not replaced: $SUDOERS_LOCK stayed taken for ${LOCK_TIMEOUT_SECONDS}s, so another install.sh or uninstall.sh, perhaps in another account, is changing it. Rerun in a moment. The app and the LaunchAgent were not touched." >&2
    exit 1 ;;
  4)
    echo "$SUDOERS changed after this install read it, or could not be shown to be a regular file of root's with one link that only root can change (see any line above). Another install.sh or uninstall.sh, perhaps in another account, may have written or removed it meanwhile. It was not replaced, so no rule written meanwhile was overwritten. Rerun to check it again. The app and the LaunchAgent were not touched." >&2
    exit 1 ;;
  5)
    echo "$SUDOERS was not replaced: copying the new rule beside it, or renaming the copy into place, failed (see the error above). The app and the LaunchAgent were not touched." >&2
    exit 1 ;;
  6)
    echo "The new rule failed visudo's check once copied beside $SUDOERS, so $SUDOERS was not replaced. The app and the LaunchAgent were not touched." >&2
    exit 1 ;;
  7)
    echo "$SUDOERS was not replaced: the lock file $SUDOERS_LOCK, or a folder above it, could not be shown to be one only root can change (see the line above), so the lock that keeps two runs from writing the rule at once cannot be trusted. The app and the LaunchAgent were not touched, and nothing there was repaired: check it yourself (the lock file must be a regular file of root's with mode 0600 and one link), then rerun." >&2
    exit 1 ;;
  8)
    echo "$SUDOERS was not replaced: read again as root, it could not be read in full, holds a NUL byte, changed while it was read, or has a line that is not for $USER (see any line above). Rerun to check it again. The app and the LaunchAgent were not touched." >&2
    exit 1 ;;
  1 | 2)
    echo "$SUDOERS was not replaced: the sudo call that replaces it exited $replace_rc before replacing it. The app and the LaunchAgent were not touched." >&2
    exit 1 ;;
  *)
    echo "The sudo call that replaces $SUDOERS exited $replace_rc (a signal), so whether $SUDOERS was replaced is not known. The app (with backstop.sh) and the LaunchAgent were not touched. Check it with 'sudo cat $SUDOERS', then rerun." >&2
    exit 1 ;;
esac
# The backstop cannot undo anything without the rule, so stop here. Checked
# again once this run holds the recovery lock (step 5).
rule_rc=0
pmset_rule_effective || rule_rc=$?
if (( rule_rc == 0 )); then
  echo "sudoers rule verified"
elif (( rule_rc == 124 )); then
  echo "'sudo -n -l', which checks the rule, did not answer within ${CALL_TIMEOUT_SECONDS}s, so the rule in $SUDOERS is not verified. The app (with backstop.sh) and the LaunchAgent were not touched; rerun once sudo answers." >&2
  exit 1
elif (( rule_rc == 125 )); then
  echo "'sudo -n -l', which checks the rule, did not answer within ${CALL_TIMEOUT_SECONDS}s, so the rule in $SUDOERS is not verified. $(sudo_alive_note). The app (with backstop.sh) and the LaunchAgent were not touched; rerun once it has ended (or stop it with 'sudo kill ${BOUNDED_PID:-<pid>}')." >&2
  exit 1
else
  echo "'sudo -n pmset' is still not permitted; check $SUDOERS. The app (with backstop.sh) and the LaunchAgent were not touched." >&2
  exit 1
fi

# 3. Bundle ------------------------------------------------------------------
#    Copied into a staging directory inside $APP_DIR. $APP itself is
#    replaced in step 6, in the same locked step as the LaunchAgent: the
#    agent pins one build's requirement, so the bundle at $APP and the loaded
#    agent must be a matching pair before, during and after a failed run.
step "Staging Insomnia.app"
# Ask the app to quit and wait until it has actually exited. It refuses to
# quit while it has unresolved recovery work; that refusal stands (no pkill),
# and nothing of the old install is overwritten while it is still running.
# This app counts, and so does a process named Insomnia that cannot be told
# apart from it (find_insomnia); one proven to be another app is reported
# and left alone. A copy in another account stops the install.
if app_running; then
  report_others
  stop_for_other_accounts "$SUDOERS is installed; the app (with backstop.sh) and the LaunchAgent were not touched."
  report_unverified
  # The quit goes only to a copy identified as this app in this account. An
  # unverified process is waited for, but its presence alone never asks the
  # real app to quit.
  if (( ${#APP_FOUND[@]} > 0 )); then
    echo "Insomnia is running ($(list "${APP_FOUND[@]}")); quitting it first (this ends any session)."
    "$OSASCRIPT" -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  fi
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    app_running || break
    sleep 1
  done
  if app_running; then
    echo "Insomnia is still running after ${QUIT_WAIT_SECONDS}s (it may be refusing to quit until its own recovery finishes, or a process named Insomnia could not be identified): $(list "${BLOCKING[@]}")." >&2
    echo "Let it finish or quit it from its menu, quit any process listed as unverified, then rerun. $SUDOERS is installed; the app (with backstop.sh) and the LaunchAgent were not touched." >&2
    exit 1
  fi
else
  report_others
fi
"$MKDIR" -p "$APP_DIR"
STAGE="$("$MKTEMP" -d "$APP_DIR/.Insomnia.app.staging.$$.XXXXXX")"
NEW_APP="$STAGE/Insomnia.app"
# The bundle is copied here whole and reaches $APP in one rename under the
# recovery lock (step 5), so backstop.sh never sees this binary beside an
# older Info.plist or the reverse (it runs the binary's --resume-frozen mode
# only once Info.plist declares InsomniaResumeFrozenVersion).
# ditto keeps the signature's resource seal and every attribute intact (a
# downloaded bundle keeps its quarantine flag; Gatekeeper decides at launch).
"$DITTO" "$SOURCE_APP" "$NEW_APP"
# It keeps the source's modes and ACLs as well. A zip unpacked by a tool
# that keeps group or other write bits, a build made under umask 002, or a
# bundle given an ACL would let other accounts edit the installed bundle.
# An edited backstop.sh breaks the seal, so the agent stops running any
# recovery. The signature covers neither mode bits nor ACLs: both go here
# and the bundle still verifies (the check below runs on this copy).
# Extended attributes, the quarantine flag among them, stay. chmod -R
# skips symbolic links.
if ! "$CHMOD" -R go-w "$NEW_APP" || ! "$CHMOD" -R -N "$NEW_APP"; then
  echo "could not remove group and other write permission and ACLs from the staged bundle $NEW_APP (see the error above). $SUDOERS is installed; the app at $APP and the LaunchAgent were not touched." >&2
  exit 1
fi
# backstop.sh was sealed into the bundle before signing (build-app.sh), so
# the signature's resource seal covers it. The LaunchAgent below verifies
# the whole bundle against the requirement read here and only then runs this
# copy; an edited script fails that check. No executable is left in a
# writable directory.
BACKSTOP="$NEW_APP/Contents/Resources/backstop.sh"
echo "signed $("$CODESIGN" -dv "$NEW_APP" 2>&1 | grep -i identifier || true)"
# What the agent pins: the bundle's designated requirement, in the form
# `codesign -d -r-` prints (an implicit one carries a leading "# "). For an
# ad-hoc signature, which source builds and releases have, that is the cdhash
# of this build, so no other build and no edited bundle satisfies it. A
# bundle signed with a certificate pins what its own signature declares
# instead. It does not depend on the path, so it still holds
# once the bundle is at $APP. The app reads the same text through the
# Security framework (CodeRequirement.swift) to recognise this plist.
REQUIREMENT="$("$CODESIGN" -d -r- "$NEW_APP" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p' | head -n 1)"
if [[ -z "$REQUIREMENT" ]]; then
  echo "could not read the designated requirement of the new bundle ('codesign -d -r-'); the LaunchAgent cannot pin it. $SUDOERS is installed; the app at $APP and the LaunchAgent were not touched." >&2
  exit 1
fi
# The check the agent will run every minute, run once here so a bundle the
# agent would refuse is caught now instead of at the first recovery.
if ! "$CODESIGN" --verify --strict "-R=$REQUIREMENT" "$NEW_APP"; then
  echo "the new bundle does not satisfy its own requirement ($REQUIREMENT); the LaunchAgent would never run backstop.sh. $SUDOERS is installed; the app at $APP and the LaunchAgent were not touched." >&2
  exit 1
fi
echo "LaunchAgent will require: $REQUIREMENT"

# 4. Directories -------------------------------------------------------------
step "Creating $APP_SUPPORT, $LOG_DIR and $LAUNCH_AGENTS"
"$MKDIR" -p "$APP_SUPPORT" "$LOG_DIR" "$LAUNCH_AGENTS"

# 5. Recovery and LaunchAgent replacement are one transaction under the
#    recovery lock (the same flock(2) file the app and backstop use), so a
#    freshly started app cannot dirty the journal between the clean check
#    and the bootout of the old job. The backstop inherits fd 9 and shares
#    the lock instead of waiting on it. The lock file is never unlinked or
#    replaced, so every party keeps locking the same inode.
#
# The backstop run under the lock hands frozen entries that record
# microseconds to the app binary at $APP, and no Info.plist is read under
# the lock, so the version it declares is read here (read_info_version).
# When nothing is at $APP but an interrupted run set the previous app aside,
# that bundle goes back to $APP under the lock (below), and a rename keeps
# its Info.plist's identity, so its Info.plist is the one read. A read that
# fails or does not answer leaves the version unknown: the backstop then
# keeps those entries frozen, and the install stops after it.
INFO_PLIST="$APP/Contents/Info.plist"
info_source="$INFO_PLIST"
if [[ -d "$PREVIOUS_APP" && ! -e "$APP" ]]; then
  info_source="$PREVIOUS_APP/Contents/Info.plist"
fi
if ! read_info_version "$info_source"; then
  echo "note: could not read InsomniaResumeFrozenVersion from $info_source before the recovery lock: $INFO_PROBLEM. If the journal holds a frozen process that only the app binary can resume, it stays frozen and journaled, and the install stops after the backstop runs." >&2
fi
step "Taking the recovery lock"
LOCK="$APP_SUPPORT/.recovery.lock"
exec 9<>"$LOCK"
lock_rc=0
"$LOCKF" -t "$LOCK_TIMEOUT_SECONDS" 9 2>/dev/null || lock_rc=$?
if (( lock_rc != 0 )); then
  echo "The recovery lock $LOCK is held by another process (the app or a running backstop)." >&2
  echo "Wait a minute and rerun. $SUDOERS is installed; the app at $APP and the LaunchAgent were not touched." >&2
  exit 75
fi
# From here on every sudo, pgrep, ps, plutil, launchctl and codesign call
# goes through bounded(): one that stalls is stopped and ends this run,
# which lets go of the lock, so the app and the agent's backstop can take it
# again and undo a session. A sudo that does not stop on SIGTERM keeps the lock until
# it ends. A pgrep that cannot answer does not say the app is gone, so the
# run stops. No Info.plist is read from here on (PLIST_READS=0): a process
# not identified before the lock counts as unverified.
PLIST_READS=0
if app_running; then
  if [[ -n "$PGREP_PROBLEM" ]]; then
    echo "$PGREP_PROBLEM, so whether Insomnia started again is unknown. The app at $APP and the LaunchAgent were not touched; rerun." >&2
  else
    echo "Insomnia started again ($(list "${BLOCKING[@]}")); quit it and rerun. The app at $APP and the LaunchAgent were not touched." >&2
  fi
  exit 1
fi
# The rule was verified in step 2, before this run waited for the lock. An
# uninstall.sh that took the lock first removes $SUDOERS under it, and its
# recovery leaves no journal, so the recovery below would succeed without
# the rule. Without it no session can undo pmset. Checked here, under the
# lock that uninstall.sh also needs, and this run holds the lock until the
# new pair is published.
rule_rc=0
pmset_rule_effective || rule_rc=$?
if (( rule_rc == 124 )); then
  cat >&2 <<FAIL

Install stopped: 'sudo -n -l', which checks the rule in $SUDOERS again now that
this run holds the recovery lock, did not answer within ${CALL_TIMEOUT_SECONDS}s. The check
stopped on SIGTERM and this run exits, which lets go of the lock, so the app and
the LaunchAgent's backstop can take it again and undo a session left over. The
app at $APP and the LaunchAgent were not touched; the new build was discarded.
Rerun this script once sudo answers.
FAIL
  exit 1
elif (( rule_rc == 125 )); then
  cat >&2 <<FAIL

Install stopped: 'sudo -n -l', which checks the rule in $SUDOERS again now that
this run holds the recovery lock, did not answer within ${CALL_TIMEOUT_SECONDS}s. $(sudo_alive_note).
It keeps the recovery lock until it ends, so until then the app cannot start a
session and the LaunchAgent's backstop cannot undo one. If it does not end by
itself, stop it:
  sudo kill ${BOUNDED_PID:-<pid>}
The app at $APP and the LaunchAgent were not touched; the new build was
discarded. Rerun this script once it has ended.
FAIL
  exit 1
elif (( rule_rc != 0 )); then
  cat >&2 <<FAIL

Install stopped: 'sudo -n pmset' was permitted when $SUDOERS was installed above,
but is not now that this run holds the recovery lock. Something removed or changed
the rule while this run waited (uninstall.sh removes it under the same lock), and
without it no session can undo pmset. The app at $APP and the LaunchAgent were not
touched; the new build was discarded. Rerun this script to install the rule again.
FAIL
  exit 1
fi

# Leftovers of earlier runs are handled only here, under the lock. Step 6
# runs under it too, so no other install is between setting the previous
# bundle aside and resolving the swap now: a bundle at $PREVIOUS_APP belongs
# to a run that was stopped, and no live run needs it to roll back.
#
# Until this run's recovery has succeeded, nothing that could part a loaded
# job from the build it pins is touched: while recovery is unresolved that
# job may be the one retrying it. Two things cannot: putting a set-aside
# bundle back when nothing is at $APP, and removing the staging directories
# of runs that are gone. A job only ever pins $APP, never a path inside a
# staging directory.
if [[ -d "$PREVIOUS_APP" && ! -e "$APP" ]]; then
  # Stopped between the two renames: nothing at $APP.
  if ! move_bundle "$PREVIOUS_APP" "$APP"; then
    cat >&2 <<FAIL

Install stopped: nothing is at $APP, and putting back the previous app that an
interrupted run set aside at $PREVIOUS_APP failed. It stays there; nothing else
was moved or unloaded, and the new build was discarded. Installed so far: $SUDOERS.
The LaunchAgent finds no app at $APP until it is back. Before you log out, move
it back and rerun this script:
  $(command_line mv "$PREVIOUS_APP" "$APP")
FAIL
    exit 1
  fi
  echo "restored $APP, which an interrupted run had set aside"
fi
# Staging directories of runs that are gone, matched by the exact name step 3
# gives them (mktemp's suffix is six letters and digits). One whose PID is
# alive belongs to an install that is still assembling its bundle and has
# not reached this lock yet, so it stays. kill -0 only asks whether the
# process exists; it sends no signal.
staging_re='^\.Insomnia\.app\.staging\.([0-9]+)\.[A-Za-z0-9]{6}$'
for dir in "$APP_DIR"/.Insomnia.app.staging.*; do
  [[ -d "$dir" && ! -L "$dir" && "$dir" != "$STAGE" ]] || continue
  [[ "${dir##*/}" =~ $staging_re ]] || continue
  if "$KILL" -0 "${BASH_REMATCH[1]}" 2>/dev/null; then
    continue
  fi
  "$RM" -rf "$dir"
done

# Whether the plist on disk, the one launchd loads at the next login, pins
# the bundle at $PREVIOUS_APP and not the one at $APP: 0 when it does, 1
# when it does not (no plist, or one that parses and pins no requirement),
# 124 when that is not known, with the reason in PINS_UNKNOWN: a read or a
# codesign check failed or did not answer in time, or the plist is not a
# regular file or does not parse. Every read here runs under the recovery
# lock, so each is a bounded call.
PINS_UNKNOWN=""
plist_pins_previous() {
  local pinned rc=0
  PINS_UNKNOWN=""
  [[ -e "$PLIST" || -L "$PLIST" ]] || return 1
  if [[ ! -f "$PLIST" ]]; then
    PINS_UNKNOWN="$PLIST is not a regular file, so which of the two bundles it pins is unknown."
    return 124
  fi
  bounded "$PLUTIL" -extract ProgramArguments.4 raw -o - "$PLIST" || rc=$?
  if (( rc == 1 )); then
    # No such entry, or no plist at all: only a plist that parses pins
    # nothing.
    rc=0
    bounded "$PLUTIL" -lint "$PLIST" || rc=$?
    if (( rc == 0 )); then return 1; fi
    PINS_UNKNOWN="'plutil -lint $PLIST' $(call_result "$rc"), so which of the two bundles it pins is unknown."
    return 124
  elif (( rc != 0 )); then
    PINS_UNKNOWN="'plutil -extract ProgramArguments.4', which reads the requirement $PLIST pins, $(call_result "$rc")."
    return 124
  fi
  if (( BOUNDED_READ != 0 )); then
    PINS_UNKNOWN="'plutil -extract ProgramArguments.4', which reads the requirement $PLIST pins, exited 0, but its output could not be read back."
    return 124
  fi
  pinned="$BOUNDED_OUTPUT"
  [[ -n "$pinned" ]] || return 1
  rc=0
  bounded "$CODESIGN" --verify --strict "-R=$pinned" "$APP" || rc=$?
  if (( rc == 0 )); then return 1; fi
  if (( rc == 124 )); then
    PINS_UNKNOWN="'codesign --verify', which tells which of the two bundles $PLIST pins, did not answer within ${CALL_TIMEOUT_SECONDS}s."
    return 124
  fi
  rc=0
  bounded "$CODESIGN" --verify --strict "-R=$pinned" "$PREVIOUS_APP" || rc=$?
  if (( rc == 124 )); then
    PINS_UNKNOWN="'codesign --verify', which tells which of the two bundles $PLIST pins, did not answer within ${CALL_TIMEOUT_SECONDS}s."
  fi
  if (( rc == 0 || rc == 124 )); then return "$rc"; fi
  return 1
}

step "Ending any stale session and checking the recovery journal"
recovery_rc=0
run_backstop "$BACKSTOP" || recovery_rc=$?
if (( recovery_rc == 125 )); then
  cat >&2 <<FAIL

Install stopped: the backstop did not finish within ${BACKSTOP_TIMEOUT_SECONDS}s and is still running as
pid ${BOUNDED_PID:-?} three seconds after its SIGTERM. It is not killed, because it may be
running sudo pmset, and it keeps the recovery lock until it ends. The app at $APP
and the LaunchAgent were not replaced or unloaded; the new build was discarded.
Installed so far: $SUDOERS. Rerun this script once it has ended.
FAIL
  exit 1
fi
recovery_note=""
case "$recovery_rc" in
  124) recovery_note="
It did not finish within ${BACKSTOP_TIMEOUT_SECONDS}s and was stopped with SIGTERM." ;;
  126) recovery_note="
It could not be started: no file for its output could be made in $WORK." ;;
esac

if (( recovery_rc != 0 )); then
  held="$(loaded_state)"
  case "$held" in
    yes) agent_note="A LaunchAgent job with label $LABEL is loaded and was left as it was. Which plist and
schedule it runs was not verified here; check with 'launchctl print gui/$UID_NUM/$LABEL'." ;;
    no) agent_note="No LaunchAgent $LABEL is loaded, so nothing retries by itself." ;;
    *) agent_note="'launchctl print gui/$UID_NUM/$LABEL' $(call_result "${held#unknown:}"), so whether a LaunchAgent is loaded is unknown." ;;
  esac
  if [[ -d "$PREVIOUS_APP" ]]; then
    pair_note="An interrupted install left a build at $APP and set the previous app aside at
$PREVIOUS_APP. Neither bundle was moved and no LaunchAgent job was unloaded or
replaced, so a loaded job still finds the build it pins; the new build was discarded."
    pins_rc=0
    plist_pins_previous || pins_rc=$?
    if (( pins_rc == 0 )); then
      pair_note="$pair_note
$PLIST pins the previous app, so the agent the next login loads refuses the
build at $APP. Before you log out, resolve the recovery and rerun this script,
which puts the previous app back."
    elif (( pins_rc == 124 )); then
      pair_note="$pair_note
$PINS_UNKNOWN"
    fi
  else
    pair_note="The app at $APP and the LaunchAgent were not replaced or unloaded,
so they still match each other; the new build was discarded."
  fi
  # How to run the recovery again. A checkout has backstop.sh under scripts/.
  # A zip has it only inside the bundle at $PREBUILT, and the checked private
  # copy is deleted when this script exits; the original may have changed
  # since the check, so the step is this script again, which checks a new copy.
  if [[ -n "$PREBUILT" ]]; then
    manual_step="Or rerun this script. It checks a new private
copy of the bundle and runs that copy's recovery before it replaces the app
or the LaunchAgent:
  $(command_line "$0" --allow-unverified-origin --app "$PREBUILT")"
  else
    manual_step="Or run the recovery by hand:
  $(command_line /bin/bash "$SCRIPT_DIR/backstop.sh" --force)
Then rerun this script to install the app and the LaunchAgent."
  fi
  cat >&2 <<FAIL

Install stopped: the backstop could not fully undo a previous session
(exit status $recovery_rc).$recovery_note $pair_note
Installed so far: $SUDOERS.
$agent_note
Check $LOG_DIR/insomnia.log and resolve what it reports. Saved audio, display
brightness or keyboard backlight needs the app; if one is installed, open it:
  $(command_line open "$APP")
$manual_step
FAIL
  exit 1
fi

# Recovery is resolved, so a loaded job has nothing left to retry, and the
# rest of the repair may unload it and move bundles.
if [[ -d "$PREVIOUS_APP" ]]; then
  pins_rc=0
  plist_pins_previous || pins_rc=$?
  if (( pins_rc == 124 )); then
    # Which bundle goes back is not known, so neither moves and no job is
    # unloaded: whatever job is loaded keeps the build it pins.
    cat >&2 <<FAIL

Install stopped: an interrupted run left a build at $APP and set the previous app
aside at $PREVIOUS_APP. $PINS_UNKNOWN
Neither bundle was moved and no LaunchAgent job was unloaded; the new build was
discarded. Installed so far: $SUDOERS. The recovery journal was clean when
checked above. Rerun this script once that is resolved.
FAIL
    exit 1
  fi
  if (( pins_rc == 0 )); then
    # Stopped after the second rename but before the new plist was
    # published: $PLIST still pins the previous bundle, so that one goes
    # back and the interrupted run's build is discarded with this run's
    # staging directory. That run may have left its own job loaded (it was
    # killed after its bootstrap, or its unload failed). Such a job pins the
    # build at $APP: a run loads its job only after the swap, and swaps only
    # once print confirms the previous job is gone. So any loaded job is
    # unloaded first, and if print does not confirm that, neither bundle
    # moves and the job keeps the build it pins.
    held="$(loaded_state)"
    if [[ "$held" != no ]]; then
      bounded "$LAUNCHCTL" bootout "gui/$UID_NUM/$LABEL" || true
      cleared="$(loaded_state)"
      if [[ "$cleared" != no ]]; then
        cat >&2 <<FAIL

Install stopped: an interrupted run left its build at $APP and the previous app
at $PREVIOUS_APP, and $PLIST pins the previous one.
A job with label $LABEL may still be loaded from that run, and unloading it was
not confirmed (launchctl print: $cleared). That job pins the build at $APP, so
neither bundle was moved. Installed so far: $SUDOERS. The recovery journal was
clean when checked above.
The next login loads $PLIST, which does not match the app at $APP. Before you
log out, unload the job and rerun this script:
  launchctl bootout gui/$UID_NUM/$LABEL
FAIL
        exit 1
      fi
    fi
    unloaded_note=""
    if [[ "$held" != no ]]; then
      unloaded_note="The job that run left was unloaded (launchctl print confirms), and none is loaded now.
"
    fi
    if ! move_bundle "$APP" "$STAGE/Interrupted.app"; then
      cat >&2 <<FAIL

Install stopped: an interrupted run left its build at $APP and the previous app
at $PREVIOUS_APP, which $PLIST pins, and moving that build out of $APP failed.
Neither bundle was moved; the new build was discarded. Installed so far: $SUDOERS.
${unloaded_note}The next login loads $PLIST, which does not match the app at $APP.
Before you log out, fix what kept the bundle from moving (see the error above)
and rerun this script, which puts the previous app back.
FAIL
      exit 1
    fi
    if ! move_bundle "$PREVIOUS_APP" "$APP"; then
      # Nothing is at $APP now. The previous app stays set aside, and the
      # staging directory is kept, with the interrupted run's build and this
      # run's: no bundle is deleted while none is at $APP.
      kept="$STAGE"
      STAGE=""
      cat >&2 <<FAIL

Install stopped: an interrupted run left its build at $APP and the previous app
at $PREVIOUS_APP, which $PLIST pins. That build was moved out of the way, but
moving the previous app back to $APP failed, so nothing is at $APP.
The previous app stays at $PREVIOUS_APP; the interrupted run's build and the new
build are kept in $kept. Installed so far: $SUDOERS.
${unloaded_note}The LaunchAgent finds no app at $APP until the previous one is back. Before
you log out, move it back and load its agent:
  $(command_line mv "$PREVIOUS_APP" "$APP")
  $(command_line launchctl bootstrap "gui/$UID_NUM" "$PLIST")
or rerun this script, which puts it back first.
FAIL
      exit 1
    fi
    echo "restored $APP, which an interrupted run had set aside; $PLIST pins it"
    if [[ "$held" != no ]]; then
      # A job was loaded when this run started; the previous plist takes its
      # place, so a failure in step 6 reloads that one. Unless print confirms
      # the reload, nothing below may count on a loaded job, so the run stops.
      reload_rc=0
      bounded "$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$PLIST" || reload_rc=$?
      now="$(loaded_state)"
      if (( reload_rc != 0 )) || [[ "$now" != yes ]]; then
        if (( reload_rc != 0 )); then
          reload_reason="'launchctl bootstrap' $(call_result "$reload_rc")"
        else
          reload_reason="'launchctl bootstrap' reported success, but launchctl print says $now"
        fi
        if [[ "$now" == yes ]]; then
          job_note="A job with label $LABEL is listed (launchctl print), but the bootstrap failed,
so which plist it runs is unknown. Check 'launchctl print gui/$UID_NUM/$LABEL'."
        else
          job_note="No job with label $LABEL is confirmed loaded (launchctl print: $now). If none is,
load the previous one again:
  $(command_line launchctl bootstrap "gui/$UID_NUM" "$PLIST")"
        fi
        cat >&2 <<FAIL

Install stopped: the job an interrupted run left was unloaded and the previous app
is back at $APP, which $PLIST pins, but loading $PLIST again was not
confirmed ($reload_reason).
The new build was discarded. Installed so far: $SUDOERS. The recovery journal
was clean when checked above, and the next login loads $PLIST, which matches
the app at $APP.
$job_note
Then rerun this script.
FAIL
        exit 1
      fi
      echo "unloaded the job the interrupted run left and loaded $PLIST again (launchctl print confirms)"
    fi
  else
    # $APP is what the plist pins (the interrupted run got as far as
    # publishing it), or nothing pins either: the set-aside copy is spare.
    "$RM" -rf "$PREVIOUS_APP"
    echo "removed the bundle an interrupted run had set aside; $APP stays"
  fi
fi

# 6. LaunchAgent: verifies the bundle and runs its sealed backstop at load
#    and every 60 s. The backstop enforces the saved deadline itself and is
#    a no-op while the session on disk is valid. The plist's ProgramArguments
#    are `/bin/sh -c "$AGENT_PROGRAM" sh "$REQUIREMENT" "$APP"`: the program
#    runs `codesign --verify --strict -R=<requirement>` on the bundle and
#    execs Contents/Resources/backstop.sh only when that passes; otherwise it
#    logs one line to $LOG_DIR/insomnia.log and exits 1 without running
#    anything. AGENT_PROGRAM must stay byte for byte what LaunchdBackstop.swift
#    writes (LaunchdBackstopTests compares them), or the app reloads the agent
#    at every session start. Same pattern as the app for the file itself: the
#    trusted plist at $PLIST is only ever a plist launchd actually loaded.
#    The new one is written to a private candidate one directory below it:
#    launchctl refuses any path without a `.plist` suffix (EIO), and
#    launchd's login-time load of $LAUNCH_AGENTS does not descend into
#    subdirectories, so a leftover candidate is never picked up as a second
#    copy of the label. It is loaded from there and published with one
#    rename (same filesystem) after `launchctl print` confirms the job is
#    loaded. Any failure leaves $PLIST byte for byte as it was. A run whose
#    recovery is unresolved stopped above, so the previous job and the
#    bundle at $APP it pins are only replaced once nothing is left to retry.
step "Installing LaunchAgent $LABEL"
CANDIDATE_DIR="$LAUNCH_AGENTS/.$LABEL.staging"
CANDIDATE="$CANDIDATE_DIR/$LABEL.candidate-$$.plist"
"$MKDIR" -p "$CANDIDATE_DIR"
# Leftovers of earlier attempts, including an older build's candidates in
# $LAUNCH_AGENTS itself (those make launchd's login load report an error).
"$RM" -f "$CANDIDATE_DIR/$LABEL.candidate-"* "$LAUNCH_AGENTS/$LABEL.candidate-"*

before="$(loaded_state)"

# shellcheck disable=SC2016  # the $1/$2/$HOME/$r below are for the agent's shell, not this one
AGENT_PROGRAM='r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1'
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
cat > "$CANDIDATE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>$(printf '%s' "$AGENT_PROGRAM" | xml_escape)</string>
		<string>sh</string>
		<string>$(printf '%s' "$REQUIREMENT" | xml_escape)</string>
		<string>$(printf '%s' "$APP" | xml_escape)</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>60</integer>
</dict>
</plist>
PLIST
# Under the recovery lock, so bounded like every other call here.
lint_rc=0
bounded "$PLUTIL" -lint "$CANDIDATE" || lint_rc=$?
if (( lint_rc != 0 )); then
  cat >&2 <<FAIL

Install stopped: 'plutil -lint' on the new LaunchAgent plist $(call_result "$lint_rc")${BOUNDED_OUTPUT:+ ($BOUNDED_OUTPUT)}.
The plist at $PLIST and the app at $APP were not replaced and no job was
unloaded in this step; the new build was discarded. Installed so far: $SUDOERS.
Rerun this script.
FAIL
  exit 1
fi

# bootout by service target (ignored if nothing is loaded; a path launchctl
# cannot read fails with EIO instead of unloading anything), swap the new
# bundle in, then bootstrap from the candidate. The swap waits until print
# confirms the previous job is gone, and the new job is loaded after it, so
# no agent is ever loaded against the other build's bundle, and any job
# loaded after the swap is this run's. On failure that job is unloaded
# (print confirms it) before the swap is undone and anything is reloaded.
bounded "$LAUNCHCTL" bootout "gui/$UID_NUM/$LABEL" || true
if [[ "$before" != no ]]; then
  cleared="$(loaded_state)"
  if [[ "$cleared" != no ]]; then
    reload_hint=""
    if [[ "$cleared" != yes && -f "$PLIST" ]]; then
      reload_hint="If no job is loaded, load the previous one again:
  $(command_line launchctl bootstrap "gui/$UID_NUM" "$PLIST")
"
    fi
    cat >&2 <<FAIL

Install stopped: unloading the previous LaunchAgent job was not confirmed
(launchctl print: $cleared), so the app at $APP was not replaced and the new
build was discarded. $PLIST was not modified.
$SUDOERS is installed and the recovery journal was clean when checked above.
${reload_hint}Check 'launchctl print gui/$UID_NUM/$LABEL' and rerun this script.
FAIL
    exit 1
  fi
fi
# A rename that fails is handled like a failed load: no job of this run was
# loaded, and the failure branch below puts back what moved and reloads the
# previous job.
had_app=0
set_aside=0
swapped=0
swap_reason=""
if [[ -e "$APP" ]]; then
  had_app=1
  if move_bundle "$APP" "$PREVIOUS_APP"; then
    set_aside=1
  else
    swap_reason="the previous app at $APP could not be moved aside to $PREVIOUS_APP"
  fi
fi
if [[ -z "$swap_reason" ]]; then
  if move_bundle "$NEW_APP" "$APP"; then
    swapped=1
  else
    swap_reason="the new build could not be moved from $NEW_APP to $APP"
  fi
fi
bootstrap_rc=0
# Without a swap nothing was loaded: the previous job is confirmed unloaded
# above (or none was loaded), and the new one is loaded only after the swap.
after=no
published=0
if (( swapped )); then
  bounded "$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$CANDIDATE" || bootstrap_rc=$?
  if [[ -n "$BOUNDED_OUTPUT" ]]; then printf '%s\n' "$BOUNDED_OUTPUT" >&2; fi
  after="$(loaded_state)"
  if (( bootstrap_rc == 0 )) && [[ "$after" == yes ]] && "$MV" -f "$CANDIDATE" "$PLIST"; then
    published=1
  fi
fi

if (( published )); then
  echo "LaunchAgent $LABEL loaded (launchctl print confirms); $PLIST published"
  if (( set_aside )); then
    if "$RM" -rf "$PREVIOUS_APP"; then
      echo "replaced the previous $APP"
    else
      echo "replaced the previous $APP, but its copy at $PREVIOUS_APP could not be removed; the next run of this script removes it" >&2
    fi
  fi
  # Installs before this layout ran a writable copy from $APP_SUPPORT. The
  # agent just loaded runs the sealed one, so that copy goes now, not before.
  if [[ -e "$APP_SUPPORT/backstop.sh" ]]; then
    "$RM" -f "$APP_SUPPORT/backstop.sh"
    echo "removed the previous install's $APP_SUPPORT/backstop.sh (the agent now runs the copy sealed in the bundle)"
  fi
else
  fix_note="Fix the launchctl error and rerun."
  if [[ -n "$swap_reason" ]]; then
    reason="$swap_reason (see the error above)"
    fix_note="Fix what kept the bundle from moving and rerun."
  elif (( bootstrap_rc != 0 )); then
    reason="'launchctl bootstrap' $(call_result "$bootstrap_rc") for the new LaunchAgent"
  elif [[ "$after" != yes ]]; then
    reason="'launchctl bootstrap' reported success, but the job is not confirmed loaded (launchctl print: $after)"
  else
    reason="the new LaunchAgent loaded, but its plist could not be moved to $PLIST,
where the next login loads it from"
    fix_note="Check that $LAUNCH_AGENTS is writable and rerun."
  fi
  # A job print lists, or cannot rule out, is this run's (see the swap
  # above): loaded from the candidate, or by a bootstrap that reported an
  # error anyway. It pins the new build, so it is unloaded before the
  # previous bundle goes back, and print has to confirm that.
  unloaded=no
  stopped="Install stopped: $reason."
  if [[ "$after" != no ]]; then
    bounded "$LAUNCHCTL" bootout "gui/$UID_NUM/$LABEL" || true
    unloaded="$(loaded_state)"
    stopped="$stopped
The new job was unloaded again (launchctl print confirms)."
  fi
  # Undo the swap first, so whatever job runs next (the previous plist
  # reloaded below, or loaded at the next login) finds the build it pins.
  # Unless the new job is confirmed unloaded it stays with the build it
  # pins: putting the previous app back would leave it refusing every run.
  kept_why=""
  if [[ "$unloaded" != no ]]; then
    kept_why="The new job may still be loaded: unloading it was not confirmed (launchctl print: $unloaded).
The new build stays at $APP, because that job pins it and would refuse the
previous app."
  elif (( swapped )) && ! move_bundle "$APP" "$NEW_APP"; then
    kept_why="No job of this run is loaded (launchctl print confirms), but moving the new
build out of $APP failed (see the error above), so it stays there."
  fi
  if [[ -n "$kept_why" ]]; then
    # The swap stays and the previous bundle stays set aside, which is the
    # state an install killed mid-swap leaves; the rerun's repair above
    # handles it.
    if (( set_aside )); then
      kept_note="The previous app is kept at $PREVIOUS_APP; the rerun unloads any job
and puts the previous app back if $PLIST still pins it."
    else
      kept_note="No app was installed at $APP before this run."
    fi
    if [[ -f "$PLIST" ]]; then
      plist_note="$PLIST was not modified and does not pin this build, so the agent the
next login loads would refuse to run."
    else
      plist_note="No plist exists at $PLIST, so no agent loads at the next login."
    fi
    cat >&2 <<FAIL

Install stopped: $reason.
$kept_why $kept_note
$plist_note
$SUDOERS is installed and the recovery journal was clean when checked above.
${fix_note%.} before you log out.
FAIL
    exit 1
  fi
  if (( set_aside )); then
    if ! move_bundle "$PREVIOUS_APP" "$APP"; then
      # Nothing is at $APP now. The previous app stays set aside and the
      # new build stays staged: no bundle is deleted while none is at $APP.
      # Its job is not reloaded, since it would find no app to run.
      STAGE=""
      if [[ -f "$PLIST" ]]; then
        plist_note="The plist at $PLIST was not modified."
        restore="move it back and load its agent:
  $(command_line mv "$PREVIOUS_APP" "$APP")
  $(command_line launchctl bootstrap "gui/$UID_NUM" "$PLIST")"
      else
        plist_note="No plist exists at $PLIST."
        restore="move it back:
  $(command_line mv "$PREVIOUS_APP" "$APP")"
      fi
      cat >&2 <<FAIL

$stopped
Putting the previous app back at $APP then failed (see the error above), so
nothing is at $APP. The previous app stays at $PREVIOUS_APP and the new build
at $NEW_APP; neither was deleted.
$plist_note
$SUDOERS is installed and the recovery journal was clean when checked above.
The LaunchAgent finds no app at $APP until the previous one is back. Before you
log out, $restore
or rerun this script, which puts it back first.
FAIL
      exit 1
    fi
    app_note="The previous app was put back at $APP; the new build was discarded."
  elif (( had_app )); then
    app_note="The previous app was never moved from $APP; the new build was discarded."
  else
    app_note="No app was installed at $APP before and none is now; the new build was discarded."
  fi
  # The trusted plist was never modified. Reload the previous job only when
  # it is known to have been loaded. A job being listed afterwards does not
  # say where it came from: only a reload that itself succeeded, confirmed
  # by print, is "the previous plist loaded again". Every print result is
  # reported as yes / no / unknown; unknown is never reported as absent.
  case "$before" in
    yes)
      reload_rc=0
      bounded "$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$PLIST" || reload_rc=$?
      now="$(loaded_state)"
      if (( reload_rc == 0 )) && [[ "$now" == yes ]]; then
        outcome="A job with label $LABEL is loaded again from the previous plist $PLIST
(launchctl bootstrap succeeded and launchctl print confirms; its schedule was not verified here)."
      elif [[ "$now" == yes ]]; then
        outcome="The reload of the previous plist was not confirmed ('launchctl bootstrap'
$(call_result "$reload_rc")). A job with label $LABEL is loaded (launchctl print), but which plist it runs is
unknown: it may be the job that was loaded before this attempt. Check
'launchctl print gui/$UID_NUM/$LABEL' yourself, or rerun this script."
      else
        outcome="The previous job could not be loaded again ('launchctl bootstrap'
$(call_result "$reload_rc"); launchctl print: $now); no job with label $LABEL is confirmed loaded. Run
  $(command_line launchctl bootstrap "gui/$UID_NUM" "$PLIST")
yourself, or rerun this script."
      fi ;;
    no)
      now="$(loaded_state)"
      case "$now" in
        yes) outcome="No job was loaded before; one is loaded now (launchctl print), from the failed
attempt. It pins the new build, which is not installed, so it refuses to run; unload it with
'launchctl bootout gui/$UID_NUM/$LABEL' or rerun this script." ;;
        no) outcome="No job with label $LABEL was loaded before and none is loaded now." ;;
        *) outcome="No job was loaded before; whether one is loaded now is unknown ('launchctl print'
$(call_result "${now#unknown:}")), so it is not confirmed either way. Check
'launchctl print gui/$UID_NUM/$LABEL' yourself." ;;
      esac ;;
    *)
      outcome="Whether a job was loaded before is unknown (launchctl print $(call_result "${before#unknown:}")),
so nothing was reloaded. Check 'launchctl print gui/$UID_NUM/$LABEL' and, if no job is
loaded, load the previous one yourself:
  $(command_line launchctl bootstrap "gui/$UID_NUM" "$PLIST")" ;;
  esac
  if [[ -f "$PLIST" ]]; then
    plist_note="The plist at $PLIST was not modified."
  else
    plist_note="No plist exists at $PLIST."
  fi
  cat >&2 <<FAIL

$stopped
$plist_note
$app_note
$outcome
$SUDOERS is installed and the recovery journal was clean when checked above.
$fix_note
FAIL
  exit 1
fi

# 7. Done --------------------------------------------------------------------
step "Installed"
# The uninstaller shipped beside this script: scripts/ in a checkout, the
# zip's top level in a release (which may be unpacked inside a checkout).
UNINSTALL="$SCRIPT_DIR/uninstall.sh"
cat <<NEXT
Next steps:
  1. Launch:            $(command_line open "$APP")
  2. Optional:          System Settings > Wi-Fi > Ask to join hotspots: Automatically
  3. Config lives at:   $APP_SUPPORT/config.json
  4. Logs:              $LOG_DIR/insomnia.log
  5. Uninstall:         $(command_line "$UNINSTALL")
NEXT
