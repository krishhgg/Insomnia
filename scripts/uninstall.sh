#!/bin/bash
# Reverse install.sh. Quits the app, asks for the password (sudo -v) before
# it takes any lock, takes the recovery lock, runs the current
# backstop with --force under that same lock (from a source checkout: the
# checkout's copy when the installed app declares the interface version it
# speaks, else the app's own: the one sealed in the bundle, else the writable
# copy older installs left in Application Support; from anywhere else, such
# as a release zip: the sealed copy only), verifies for itself that the
# journal is clean, takes the standard folder's recovery lock (the one
# install.sh holds), checks under the receipt's lock that no start of
# another Insomnia folder of this user claims this user's receipt in
# /private/var/db/com.kgarg.insomnia, and only then, keeping those locks,
# removes the LaunchAgent, the sudoers rule, the receipt and its release
# file (the folder too, once empty), the app bundle (backstop.sh included),
# and the journal. A claim, a locked receipt, one it cannot read or that
# fails its checks, and a receipt or release file without the other stop it
# with nothing removed. While sleep is off or Low Power Mode is on for
# battery, or either cannot be read, another folder may still owe a restore
# the rule makes: the rule, the receipt and the bundle then stay, only this
# folder's LaunchAgent and journal go, and the run ends with status 1. The
# same happens while the recovery agent launchd has loaded under the label
# every folder shares is another folder's (launchctl print names the file
# it was loaded from): that agent stays loaded. One whose file cannot be
# told stops the run with nothing removed. The receipt's lock is kept until
# the rule, the receipt and the bundle are gone, or to the end of the run
# when they stay, so no start of another folder claims the receipt, and
# loads its agent, between the checks and the bootout.
# Every command it runs as root goes through `sudo -n` with the same time
# limit as its other calls (see as_root). Keeps config.json
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
# sudo is given rm and rmdir by full path. Given a bare name, it would search
# the caller's PATH and run whatever it finds there as root.
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
# perl makes the private copies of the files this run reads (copy_private),
# through env -i, so nothing in the environment (PERL5OPT, PERL5LIB) reaches
# it.
ENV=/usr/bin/env
PERL=/usr/bin/perl
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
# Longest the private copy of one file this run reads (session.json,
# state.json, config.json, an Info.plist) may take; see copy_private.
READ_TIMEOUT_SECONDS=10
# How long to wait for the app to exit after asking it to quit.
QUIT_WAIT_SECONDS=10
# Longest one external call made by this script itself (pgrep, defaults,
# launchctl, codesign) may run before it is stopped with SIGTERM, then
# SIGKILL. A call made under the recovery lock keeps the lock until it has
# exited or been stopped, even if this run is killed first (see bounded()).
# backstop.sh bounds its own commands. The commands of step 5 that run as
# root are bounded too (as_root); sudo only ever gets SIGTERM.
CALL_TIMEOUT_SECONDS=30
APP="$HOME/Applications/Insomnia.app"
SUDOERS=/etc/sudoers.d/insomnia
# The standard Insomnia folder, the only one install.sh installs from. Its
# recovery lock guards the files every folder of this user shares (see
# lock_standard). Tests patch this line in a private copy.
STANDARD_HOME="$HOME/Library/Application Support/Insomnia"
# Read without sudo, before step 5, to tell whether a restore the rule runs
# may still be owed (see read_owed_power).
PMSET=/usr/bin/pmset
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

# Scratch space for bounded(), the private copies of the files this run
# reads (read.*) and the readers' error output: this run's own directory,
# emptied on exit.
WORK="$("$MKTEMP" -d "${TMPDIR:-/tmp}/insomnia-uninstall.XXXXXX")"
READS="$WORK"
COPY_IN_MEMORY=0
# On every exit, a stop, a failed command under errexit or SIGTERM, SIGHUP
# or SIGINT (bash runs this trap for each): first load the LaunchAgent
# again if this run booted it out and it is still out (restore_agent),
# while this run's descriptors still hold the locks, then empty WORK.
on_exit() {
  if (( ${agent_out:-0} )); then restore_agent || true; fi
  "$RM" -f "$WORK"/call.* "$WORK"/read.* "$WORK"/plutil.err 2>/dev/null; "$RMDIR" "$WORK" 2>/dev/null || true
}
trap on_exit EXIT

# Run one external call with a time limit. Its combined output is left in
# BOUNDED_OUTPUT (trailing newline removed) and its exit status returned, or
# 124 when it did not finish within CALL_TIMEOUT_SECONDS and was stopped, or
# 125 when it is sudo and still running. BOUNDED_WHOLE is 1 only when that
# output was read whole; a caller that decides from the output treats 0 as
# unknown. The same helper as install.sh's, which says more.
# supervise() enforces the limit itself, even if this run is killed while it
# waits or its process group gets SIGTERM or SIGHUP: SIGTERM once the limit has passed on bash's SECONDS clock, SIGKILL
# one to two seconds later, never SIGKILL for sudo. The supervisor and the call keep fd 9 (the recovery lock) until the
# call has exited, so a launchctl bootout made under the lock cannot unload
# an agent the app confirms after this run is gone.
BOUNDED_OUTPUT=""
BOUNDED_WHOLE=0
bounded() { # command args...
  local base supervisor rc deadline file="" size opened=0 read_rc=0
  base="$("$MKTEMP" "$WORK/call.XXXXXX")"
  BOUNDED_OUTPUT=""
  BOUNDED_WHOLE=0
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
      return 125
    fi
  fi
  # Any other call gets SIGKILL at most two seconds after its SIGTERM, so
  # this wait ends.
  wait "$supervisor" 2>/dev/null || true
  rc=124
  if [[ -s "$base.rc" ]]; then read -r rc < "$base.rc" || rc=124; fi
  [[ "$rc" =~ ^[0-9]{1,3}$ ]] && (( 10#$rc <= 255 )) || rc=124
  file="$("$STAT" -f '%d:%i %z' "$base.out" 2>/dev/null)" || file=""
  { opened=1; IFS= read -r -d '' BOUNDED_OUTPUT || read_rc=$?; } 2>/dev/null < "$base.out" || true
  if (( opened && read_rc == 1 )) && [[ "$file" =~ ^[0-9]+:[0-9]+\ ([0-9]+)$ ]]; then
    size="${BASH_REMATCH[1]}"
    bounded_bytes
    if [[ "$("$STAT" -f '%d:%i %z' "$base.out" 2>/dev/null)" == "$file" ]] && (( BOUNDED_BYTES == 10#$size )); then
      BOUNDED_WHOLE=1
    fi
  fi
  BOUNDED_OUTPUT="${BOUNDED_OUTPUT%$'\n'}"
  return "$rc"
}
# BOUNDED_BYTES: the bytes in BOUNDED_OUTPUT, not its characters.
bounded_bytes() { local LC_ALL=C; BOUNDED_BYTES=${#BOUNDED_OUTPUT}; }
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

# Copies the live file $1 to $READS/$2, for every later read of it in this
# run: session.json, state.json, config.json and the app's Info.plist are
# never read in place. The same as backstop.sh's (a test keeps the two in
# step). perl, run with an empty environment, opens the file without
# blocking and without following a symbolic link, refuses anything but a
# regular file (open(2) on a FIFO with no writer would block under the
# lock, and a device is never read) and one larger than 8 MiB, reads it to
# the end, checks that it holds as many bytes as its size, that its
# identity (file_id: device, inode, size, and modification and change times
# to a fraction of a microsecond) did not move during the read and that the
# path still names it, not through a link, and writes the bytes to a new
# mode-600 file. SIGALRM ends it after READ_TIMEOUT_SECONDS; a read the
# kernel cannot interrupt (a stalled disk), or a perl stopped by SIGSTOP,
# holds it longer. Returns 0 with copy_path and copy_id (that identity); 3
# when the file could not be opened or read (permissions, I/O); 4 when it is
# a symbolic link or not a regular file; 2 for anything else: it is larger
# than 8 MiB, it changed while it was read, the time ran out, or the copy
# could not be written. Its reason is in copy_why.
# backstop.sh keeps a copy it cannot write in memory (COPY_IN_MEMORY=1).
# This script sets COPY_IN_MEMORY to 0 and always has its READS folder, so
# here such a copy is 2 and the uninstall stops before removing anything.
# shellcheck disable=SC2016  # the $ below are perl's, not this shell's
COPY_PERL='use strict; use Fcntl qw(:DEFAULT :mode); use Time::HiRes ();
$SIG{ALRM} = "DEFAULT"; alarm shift @ARGV;
my ($src, $dst) = @ARGV;
my $max = 8 * 1024 * 1024;
sub fail { print "$_[1]\n"; exit $_[0] }
sub id { join(":", @_[0,1,7], map { sprintf "%.9f", $_ } @_[9,10]) }
sysopen(my $in, $src, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
  or fail $!{ELOOP} ? (4, "a symbolic link, which is not followed") : (3, "$!");
my @a = Time::HiRes::stat($in) or fail 3, "$!";
S_ISREG($a[2]) or fail 4, "not a regular file";
$a[7] <= $max or fail 2, "it is larger than 8 MiB";
my ($data, $n) = ("", 0);
while ($n = sysread($in, $data, 65536, length $data)) {
  length($data) <= $max or fail 2, "it grew past 8 MiB while it was read";
}
defined $n or fail 3, "$!";
my @b = Time::HiRes::stat($in) or fail 3, "$!";
my @c = Time::HiRes::lstat($src);
id(@a) eq id(@b) && @c && id(@b) eq id(@c) && length($data) == $b[7]
  or fail 2, "it changed while it was read";
my $id = id(@b);
if ($dst eq "-") {
  index($data, "\0") < 0 or fail 2, "it holds a NUL byte, which a copy kept in memory cannot hold";
  print "$id\n$data." or exit 2;
  exit 0;
}
sysopen(my $out, $dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or fail 5, "$dst: $!";
for (my $off = 0; $off < length $data; ) {
  my $w = syswrite($out, $data, length($data) - $off, $off);
  defined $w && $w > 0 or fail 5, "$dst: $!";
  $off += $w;
}
close($out) or fail 5, "$dst: $!";
print "$id\n";'
copy_private() { # live-file name
  local out rc=0 mem=0 data=""
  copy_path="$READS/$2"; copy_id=""; copy_why=""
  if [[ -z "$READS" ]]; then
    mem=1
  else
    "$RM" -f "$copy_path" 2>/dev/null || { copy_why="its earlier copy $copy_path could not be removed"; return 2; }
    out="$("$ENV" -i "$PERL" -e "$COPY_PERL" "$READ_TIMEOUT_SECONDS" "$1" "$copy_path" 2>/dev/null)" || rc=$?
    # A copy that could not be written (a full disk) is made again in
    # memory.
    if (( rc == 5 && ${COPY_IN_MEMORY:-0} == 1 )); then
      "$RM" -f "$copy_path" 2>/dev/null || true
      mem=1; rc=0
    fi
  fi
  if (( mem )); then
    copy_path="mem:${2//[^A-Za-z0-9_]/_}"
    printf -v "mem_${copy_path#mem:}" '%s' ""
    out="$("$ENV" -i "$PERL" -e "$COPY_PERL" "$READ_TIMEOUT_SECONDS" "$1" - 2>/dev/null)" || rc=$?
    # The identity, a newline, the bytes and a "." that keeps their
    # trailing newlines from the command substitution.
    if (( rc == 0 )); then
      if [[ "$out" == *$'\n'*. ]]; then
        data="${out#*$'\n'}"; data="${data%.}"
        out="${out%%$'\n'*}"
      else
        out=""
      fi
    fi
  fi
  if (( rc == 0 )) && [[ "$out" =~ ^[0-9]+:[0-9]+:[0-9]+:-?[0-9]+\.[0-9]{9}:-?[0-9]+\.[0-9]{9}$ ]]; then
    copy_id="$out"
    if (( mem )); then printf -v "mem_${copy_path#mem:}" '%s' "$data"; fi
    return 0
  fi
  copy_why="${out%%$'\n'*}"
  case "$rc" in
    3|4) ;;
    142) copy_why="it was still being read after ${READ_TIMEOUT_SECONDS}s"; rc=2 ;;
    0) copy_why="the copy did not report what it copied"; rc=2 ;;
    *) copy_why="${copy_why:-the copy exited $rc}"; rc=2 ;;
  esac
  copy_why="${copy_why:-the copy exited $rc}"
  return "$rc"
}
# The identity copy_private gives a file (copy_id), of the file at $1 now,
# not following a link: its device, inode and size, and its modification
# and change times with the fraction perl's Time::HiRes gives them (the
# nanoseconds the system keeps, rounded to a double, a fraction of a
# microsecond). Prints nothing when there is no such file.
# shellcheck disable=SC2016  # the $ below are perl's, not this shell's
ID_PERL='use strict; use Time::HiRes ();
my @s = Time::HiRes::lstat($ARGV[0]) or exit 1;
print join(":", @s[0,1,7], map { sprintf "%.9f", $_ } @s[9,10]), "\n";'
file_id() { # path
  "$ENV" -i "$PERL" -e "$ID_PERL" "$1" 2>/dev/null
}
# Runs plutil with these arguments on the file given last, or, for a copy
# kept in memory (mem:<name>, see copy_private), on those bytes through its
# standard input. Returns plutil's status.
plutil_on() { # plutil-arguments... file
  local f="${!#}" v
  if [[ "$f" != mem:* ]]; then
    "$PLUTIL" "$@" || return
    return 0
  fi
  v="mem_${f#mem:}"
  printf '%s' "${!v}" | "$PLUTIL" "${@:1:$#-1}" - && return 0
  return "${PIPESTATUS[1]}"
}
# True when file $1 holds the same bytes as this run's copy $2, a file or
# one kept in memory.
same_as_read() { # file copy
  if [[ "$2" == mem:* ]]; then
    local v="mem_${2#mem:}"
    printf '%s' "${!v}" | "$CMP" -s - "$1"
  else
    "$CMP" -s "$1" "$2"
  fi
}
# Reads through plutil, always of a private copy. type_at sets t to the
# type name at the key path (bool, integer, float, string, array,
# dictionary, or "(any)" for null) and read_at sets read_value to what
# -extract prints there (raw or json), apart from the one newline plutil
# adds, so a stored trailing newline is kept. Both return 0 with the value;
# 1 when the key path is absent, which plutil reports as "No value at that
# key path", and read_at also for a null, as for the app's decodeIfPresent;
# and 2 for any other failure, with read_why saying which read failed and
# how. What that key holds is then unknown, never absent: no caller acts on
# it. A plutil that words the absence differently makes every absent key
# unknown, and the uninstall then stops before removing anything. The same
# as backstop.sh's.
plutil_run() { # plutil-arguments... file
  local out all split
  plutil_rc=""; plutil_err=""
  if [[ -n "$READS" ]]; then
    # A message file that cannot be made or read is quiet here: the run
    # below then keeps the message in memory.
    out="$(exec 2>/dev/null; plutil_on "$@" 2>"$READS/plutil.err"; echo ".$?")"
    plutil_rc="${out##*.}"
    if [[ "$plutil_rc" != 0 ]]; then
      { IFS= read -r plutil_err < "$READS/plutil.err"; } 2>/dev/null || true
    fi
  fi
  # With no folder, or a failure whose message could not be kept in one (a
  # full disk), plutil runs again and its message is kept in memory: it
  # goes to the outer capture first, then a line no message holds, then
  # what plutil printed and its status.
  if [[ -z "$READS" ]] || [[ "$plutil_rc" != 0 && -z "$plutil_err" ]]; then
    split="--plutil-$$-$RANDOM--"
    all="$( { out="$(plutil_on "$@" 2>&4; echo ".$?")"; printf '\n%s\n%s' "$split" "$out"; } 4>&1 )"
    out="${all#*$'\n'"$split"$'\n'}"
    plutil_err="${all%%$'\n'"$split"$'\n'*}"
    plutil_err="${plutil_err%%$'\n'*}"
    plutil_rc="${out##*.}"
  fi
  out="${out%.*}"
  plutil_out="${out%$'\n'}"
}
absent_reply() { # keypath
  [[ "$plutil_rc" == 1 && "$plutil_err" == *"No value at that key path or invalid key path: $1" ]]
}
type_at() { # file keypath
  t=""
  plutil_run -type "$2" -o - "$1"
  if [[ "$plutil_rc" == 0 ]]; then t="$plutil_out"; return 0; fi
  absent_reply "$2" && return 1
  read_why="$2: plutil -type exited ${plutil_rc:-?} (${plutil_err:-no message})"
  return 2
}
# For the shape checks: type_at with t empty when the key is absent, and a
# failure only when the read failed.
ty() { # file keypath
  type_at "$@" || (( $? == 1 ))
}
# Round 36: a session.json whose id (Session.id) is a string other than
# the one the start journaled (sleepOffAttempt.session, a string too) is
# not that start's session, whatever its end. With either one missing or
# not a string, the end alone decides, as in the app
# (SessionManager.isSession). Sets id_differs to 1 or 0. Returns 2, with
# read_why, when a read failed.
session_id_differs() { # session-copy journal-copy
  local ours
  id_differs=0
  type_at "$1" id || { (( $? == 1 )) && return 0; return 2; }
  [[ "$t" == string ]] || return 0
  read_at "$1" id raw || return 2
  ours="$read_value"
  type_at "$2" sleepOffAttempt.session || { (( $? == 1 )) && return 0; return 2; }
  [[ "$t" == string ]] || return 0
  read_at "$2" sleepOffAttempt.session raw || return 2
  [[ "$ours" == "$read_value" ]] || id_differs=1
}
read_at() { # file keypath raw|json
  local rc err
  read_value=""
  plutil_run -extract "$2" "$3" -o - "$1"
  if [[ "$plutil_rc" == 0 ]]; then read_value="$plutil_out"; return 0; fi
  absent_reply "$2" && return 1
  rc="$plutil_rc"; err="$plutil_err"
  # A null cannot be extracted; its type is "(any)".
  if [[ "$rc" == 1 ]]; then
    plutil_run -type "$2" -o - "$1"
    [[ "$plutil_rc" == 0 && "$plutil_out" == "(any)" ]] && return 1
  fi
  read_why="$2: plutil -extract exited ${rc:-?} (${err:-no message})"
  return 2
}
# The number of elements of the array at key path $2 into count: 0 when it
# is absent or null. Returns 2 when a read failed.
count_at() { # file keypath
  count=0
  while :; do
    type_at "$1" "$2.$count" || { (( $? == 1 )) && return 0; return 2; }
    count=$((count + 1))
  done
}
# True when plutil converts $1 whole to JSON and both that JSON and the
# file itself start with "{". Each step's status counts: a conversion or a
# read that fails is not a JSON object.
json_object() { # file
  local c v
  c="$(plutil_on -convert json -o - "$1" 2>/dev/null)" || return 1
  [[ "${c:0:1}" == "{" ]] || return 1
  if [[ "$1" == mem:* ]]; then
    v="mem_${1#mem:}"; c="${!v}"
  else
    c="$("$HEAD" -c 1 "$1")" || return 1
  fi
  [[ "${c:0:1}" == "{" ]]
}
# Runs journal_shape_problems or session_shape_problems on file $2. Sets
# shape_lines to what it prints and returns its status: 0, or 2 when a read
# failed, with read_why saying which. Not `problems`: uninstall.sh's step 4
# keeps its list in an array of that name, and a string assigned to it
# would become that array's first element.
shape_of() { # journal|session file
  local out rc=0
  case "$1" in
    journal) out="$(journal_shape_problems "$2" || { rc=$?; echo "${read_why:-a read failed}"; exit "$rc"; })" || rc=$? ;;
    *) out="$(session_shape_problems "$2" || { rc=$?; echo "${read_why:-a read failed}"; exit "$rc"; })" || rc=$? ;;
  esac
  shape_lines="$out"
  if (( rc != 0 )); then
    read_why="${out##*$'\n'}"
    shape_lines=""
    return 2
  fi
  return 0
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
# A read that fails, of the text or of the file's size, returns 2 with
# nothing printed for it: its records are unknown, not absent, and the
# caller must not count the journal as clean.
record_text_problems() { # file
  local LC_ALL=C
  local text rest raw key c token depth str plain scalar number esc hex lost size v
  local n_low=0 n_lit=0 n_boot=0 digits sig exp e10 lead
  str='^"([^"\\]|\\.)*"'
  plain='^[^]["{}]+'
  scalar='^[^],}[:space:]]+'
  number='^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE]([-+]?)([0-9]+))?$'
  esc='^u00(4[1-9A-Fa-f]|5[0-9Aa]|6[1-9A-Fa-f]|7[0-9Aa])'
  hex='^u[0-9A-Fa-f]{4}'
  lost="the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked"
  # cat's status follows its output, so a read that fails part way is
  # seen, and so is every newline at the end.
  if [[ "$1" == mem:* ]]; then
    v="mem_${1#mem:}"; text="${!v}"
  else
    text="$("$CAT" "$1"; echo ".$?")"
    [[ "${text##*.}" == 0 ]] || return 2
    text="${text%.*}"
  fi
  [[ "$text" == *keptDisplay* || "$text" == *\\* ]] || return 0
  # The shell drops NUL bytes from the text, so a file with one is longer
  # than the text read from it. A copy in memory has none: copy_private
  # refuses a file with one.
  if [[ "$1" != mem:* ]]; then
    size="$("$STAT" -f %z "$1")" || return 2
    if (( ${#text} != size )); then
      echo "$lost"
      return 0
    fi
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

# Prints one line per way the journal does not have the shape the app writes
# (RuntimeState.swift). Present keys must have the right type; a JSON null is
# the same as an absent optional (Swift decodeIfPresent). Returns 2 when a
# read of the file failed, the conversion, its text for the kept display
# records or the type of a key, with read_why saying which: its shape is
# then unknown, not malformed.
journal_shape_problems() { # file
  local f="$1" key t i n json
  json="$(plutil_on -convert json -o - "$f" 2>/dev/null)" || { read_why="state.json could not be converted to JSON again (plutil -convert json failed)"; return 2; }
  if [[ "${json:0:1}" != "{" ]]; then
    echo "state.json is not a JSON object"
    return 0
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen savedMuted displayRestoreRefused keyboardRestoreRefused; do
    ty "$f" "$key" || return 2
    [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "$key is a $t, not a bool"
  done
  for key in savedOutputVolume savedDisplayBrightness savedKeyboardBrightness displayRestoredUnderLowPower; do
    ty "$f" "$key" || return 2
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  # The app's records about a kept display entry: kept for the app, never
  # read for an undo here. Each must still decode, or the app cannot read
  # the journal at all.
  for key in keptDisplayUnderLowPower keptDisplayReadLit; do
    ty "$f" "$key" || return 2
    [[ -z "$t" || "$t" == float || "$t" == integer || "$t" == "(any)" ]] || echo "$key is a $t, not a number"
  done
  ty "$f" keptDisplayUnderLowPowerBoot || return 2
  [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "keptDisplayUnderLowPowerBoot is a $t, not a string"
  record_text_problems "$f" || { read_why="its text could not be read for the kept display records"; return 2; }
  ty "$f" frozenProcesses || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenProcesses is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "frozenProcesses.$i" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "frozenProcesses[$i] is not an object"
        else
          ty "$f" "frozenProcesses.$i.pid" || return 2
          [[ "$t" == integer ]] || echo "frozenProcesses[$i].pid is not an integer"
          for n in startedAt startedAtMicros; do
            ty "$f" "frozenProcesses.$i.$n" || return 2
            [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "frozenProcesses[$i].$n is a $t, not an integer"
          done
          ty "$f" "frozenProcesses.$i.bootSession" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "frozenProcesses[$i].bootSession is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" frozenPids || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "frozenPids is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "frozenPids.$i" || return 2
        [[ -n "$t" ]] || break
        [[ "$t" == integer ]] || echo "frozenPids[$i] is not an integer"
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" savedAudioOutputs || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "savedAudioOutputs is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "savedAudioOutputs.$i" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "savedAudioOutputs[$i] is not an object"
        else
          ty "$f" "savedAudioOutputs.$i.deviceUID" || return 2
          [[ "$t" == string ]] || echo "savedAudioOutputs[$i].deviceUID is not a string"
          ty "$f" "savedAudioOutputs.$i.volume" || return 2
          [[ "$t" == float || "$t" == integer ]] || echo "savedAudioOutputs[$i].volume is not a number"
          ty "$f" "savedAudioOutputs.$i.muted" || return 2
          [[ "$t" == bool ]] || echo "savedAudioOutputs[$i].muted is not a bool"
          ty "$f" "savedAudioOutputs.$i.name" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].name is a $t, not a string"
          ty "$f" "savedAudioOutputs.$i.saveID" || return 2
          [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "savedAudioOutputs[$i].saveID is a $t, not a string"
        fi
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" appNapOverrides || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != array ]]; then
      echo "appNapOverrides is a $t, not an array"
    else
      i=0
      while :; do
        ty "$f" "appNapOverrides.$i" || return 2
        [[ -n "$t" ]] || break
        if [[ "$t" != dictionary ]]; then
          echo "appNapOverrides[$i] is not an object"
        else
          ty "$f" "appNapOverrides.$i.bundleId" || return 2
          [[ "$t" == string ]] || echo "appNapOverrides[$i].bundleId is not a string"
          ty "$f" "appNapOverrides.$i.previous" || return 2
          [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "appNapOverrides[$i].previous is a $t, not a bool"
        fi
        i=$((i + 1))
      done
    fi
  fi
  ty "$f" sleepOffAttempt || return 2
  if [[ -n "$t" && "$t" != "(any)" ]]; then
    if [[ "$t" != dictionary ]]; then
      echo "sleepOffAttempt is a $t, not an object"
    else
      ty "$f" sleepOffAttempt.nonce || return 2
      [[ "$t" == string ]] || echo "sleepOffAttempt.nonce is not a string"
      ty "$f" sleepOffAttempt.owedBefore || return 2
      [[ "$t" == bool ]] || echo "sleepOffAttempt.owedBefore is not a bool"
      ty "$f" sleepOffAttempt.receipt || return 2
      [[ "$t" == string ]] || echo "sleepOffAttempt.receipt is not a string"
      ty "$f" sleepOffAttempt.predecessor || return 2
      [[ "$t" == string ]] || echo "sleepOffAttempt.predecessor is not a string"
      ty "$f" sleepOffAttempt.deadline || return 2
      [[ "$t" == integer ]] || echo "sleepOffAttempt.deadline is not an integer"
      ty "$f" sleepOffAttempt.expires || return 2
      [[ "$t" == integer ]] || echo "sleepOffAttempt.expires is not an integer"
      ty "$f" sleepOffAttempt.marker || return 2
      [[ -z "$t" || "$t" == string || "$t" == "(any)" ]] || echo "sleepOffAttempt.marker is a $t, not a string"
      ty "$f" sleepOffAttempt.settled || return 2
      [[ -z "$t" || "$t" == bool || "$t" == "(any)" ]] || echo "sleepOffAttempt.settled is a $t, not a bool"
      ty "$f" sleepOffAttempt.resumes || return 2
      if [[ "$t" == dictionary ]]; then
        ty "$f" sleepOffAttempt.resumes.startedAt || return 2
        [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "sleepOffAttempt.resumes.startedAt is a $t, not an integer"
        ty "$f" sleepOffAttempt.resumes.firstEnd || return 2
        [[ -z "$t" || "$t" == integer || "$t" == "(any)" ]] || echo "sleepOffAttempt.resumes.firstEnd is a $t, not an integer"
      elif [[ -n "$t" && "$t" != "(any)" ]]; then
        echo "sleepOffAttempt.resumes is a $t, not an object"
      fi
    fi
  fi
  return 0
}

# Brightness the app kept after its private-call guard refused the restore
# on this macOS, one line per device with the saved level. Not a problem
# for uninstall: no step here can restore it. Read from the copy
# journal_problems checked. Returns 2, with read_why, when a read failed:
# what it printed is then not the whole list.
refused_brightness() {
  [[ -n "$SNAP" ]] || return 0
  kept_level displayRestoreRefused savedDisplayBrightness "display brightness" || return 2
  kept_level keyboardRestoreRefused savedKeyboardBrightness "keyboard backlight" || return 2
  return 0
}
# Prints "<what> <level>" when the copy's flag $1 is true and it has a
# level at $2. Returns 2 when a read failed.
kept_level() { # flag level what
  local rc=0
  read_at "$SNAP" "$1" raw || rc=$?
  (( rc != 2 )) || return 2
  [[ "$rc" == 0 && "$read_value" == true ]] || return 0
  rc=0
  read_at "$SNAP" "$2" raw || rc=$?
  (( rc != 2 )) || return 2
  if (( rc == 0 )); then echo "$3 $read_value"; fi
  return 0
}

# Same rules as backstop.sh (a test keeps the readers in step).
# Seconds since the epoch, into epoch, for a date in the one form
# session.json may hold; epoch is empty for anything else. Store.parseDate
# in the app reads exactly this form: 2027-01-15T08:00:00Z, which is what
# Store.swift writes, or the same with an offset such as +02:00 or -05:30
# in place of Z. Whole seconds, a date and time that exist, years 1970 to
# 9999, offsets up to 23:59. `date -j -f` refuses a month outside 1 to 12,
# a day above 31, an hour above 23, a minute above 59 and a second above
# 60, so those are refused here before it runs; it rolls an impossible day
# or second over, so the result is formatted back and must match. Returns
# 2 when date fails on a string it accepts, or prints no number: the date
# is then unknown, not malformed.
epoch_of() { # string
  local form='^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(Z|([+-])([0-9]{2}):([0-9]{2}))$'
  local clock offset=0 e back
  epoch=""
  [[ "$1" =~ $form ]] || return 0
  (( 10#${BASH_REMATCH[1]} >= 1970 )) || return 0
  (( 10#${BASH_REMATCH[2]} >= 1 && 10#${BASH_REMATCH[2]} <= 12 && 10#${BASH_REMATCH[3]} <= 31 \
     && 10#${BASH_REMATCH[4]} <= 23 && 10#${BASH_REMATCH[5]} <= 59 && 10#${BASH_REMATCH[6]} <= 60 )) || return 0
  if [[ "${BASH_REMATCH[7]}" != Z ]]; then
    (( 10#${BASH_REMATCH[9]} <= 23 && 10#${BASH_REMATCH[10]} <= 59 )) || return 0
    offset=$(( 10#${BASH_REMATCH[9]} * 3600 + 10#${BASH_REMATCH[10]} * 60 ))
    if [[ "${BASH_REMATCH[8]}" == - ]]; then offset=$(( -offset )); fi
  fi
  clock="${1:0:19}"
  e="$("$DATE" -j -u -f '%Y-%m-%dT%H:%M:%S' "$clock" +%s 2>/dev/null)" || return 2
  [[ "$e" =~ ^[0-9]+$ ]] || return 2
  back="$("$DATE" -u -r "$e" +%Y-%m-%dT%H:%M:%S 2>/dev/null)" || return 2
  if [[ "$back" == "$clock" ]]; then epoch=$(( e - offset )); fi
  return 0
}

# epoch_of the string at a keypath, read exactly as the app's decoder sees
# it: read_at keeps a stored trailing newline and cuts only plutil's own,
# so "...Z\n" in the file is refused here as it is in the app. An absent
# key leaves epoch empty; a read that fails returns 2.
epoch_at() { # file keypath
  local rc=0
  epoch=""
  read_at "$1" "$2" raw || rc=$?
  (( rc != 2 )) || return 2
  (( rc == 0 )) || return 0
  epoch_of "$read_value" || { read_why="$2: date could not read $read_value"; return 2; }
}

# Prints one line per way session.json does not have the shape the app's
# Session decoder needs (Session.swift): a JSON object whose startedAt and
# endsAt are dates as Store.swift writes them and whose extensions is an
# array of numbers. All three are required; extra keys are ignored, as in
# Swift. The app refuses a file with any of these problems, so the shell
# does not act on its endsAt either. Returns 2, with read_why, when a read
# of the file failed: its shape is then unknown, not malformed.
session_shape_problems() { # file
  local f="$1" key t i c v
  # plutil also reads XML and binary property lists, which the app's
  # JSONDecoder refuses, so the file itself must start with "{" too. head
  # ends after one byte, and tr may then end on SIGPIPE (141); any other
  # status of either is a read that failed.
  if [[ "$f" == mem:* ]]; then
    v="mem_${f#mem:}"
    c="$(printf '%s' "${!v}" | LC_ALL=C "$TR" -d ' \t\r\n' 2>/dev/null | "$HEAD" -c 1; echo ".${PIPESTATUS[1]}.${PIPESTATUS[2]}")"
  else
    c="$(LC_ALL=C "$TR" -d ' \t\r\n' < "$f" 2>/dev/null | "$HEAD" -c 1; echo ".${PIPESTATUS[0]}.${PIPESTATUS[1]}")"
  fi
  if [[ "${c##*.}" != 0 ]] || [[ "${c%.*}" != *.0 && "${c%.*}" != *.141 ]]; then
    read_why="its first character could not be read"
    return 2
  fi
  c="${c%.*}"; c="${c%.*}"
  # Then plutil's conversion of the whole file. Only its own verdict on the
  # bytes, exit 1 with "Property List error", makes the file malformed; any
  # other failure is a read that failed, and the shape is unknown.
  if [[ "$c" == "{" ]]; then
    plutil_run -convert json -o - "$f"
    if [[ "$plutil_rc" == 0 ]]; then
      c="${plutil_out:0:1}"
    elif [[ "$plutil_rc" == 1 && "$plutil_err" == *": Property List error: "* ]]; then
      c=""
    else
      read_why="plutil -convert json exited ${plutil_rc:-?} (${plutil_err:-no message})"
      return 2
    fi
  fi
  if [[ "$c" != "{" ]]; then
    echo "session.json is not a JSON object"
    return 0
  fi
  for key in startedAt endsAt; do
    ty "$f" "$key" || return 2
    if [[ -z "$t" ]]; then
      echo "$key is missing"
    elif [[ "$t" != string ]]; then
      echo "$key is a JSON $t, not a date string"
    else
      epoch_at "$f" "$key" || return 2
      [[ -n "$epoch" ]] || echo "$key is not a date in the form 2027-01-15T08:00:00Z or 2027-01-15T10:00:00+02:00"
    fi
  done
  ty "$f" extensions || return 2
  if [[ -z "$t" ]]; then
    echo "extensions is missing"
  elif [[ "$t" != array ]]; then
    echo "extensions is a JSON $t, not an array"
  else
    i=0
    while :; do
      ty "$f" "extensions.$i" || return 2
      [[ -n "$t" ]] || break
      [[ "$t" == integer || "$t" == float ]] || echo "extensions[$i] is a JSON $t, not a number"
      i=$((i + 1))
    done
  fi
  return 0
}

# Independent check of the journal: prints one line per unresolved item.
# Trusts nothing about the backstop that just ran (it may be an older copy).
# session.json and state.json are read through private copies
# (copy_private): a FIFO put in place of either is never opened in a way
# that blocks while this run holds the recovery lock. Every read of the
# journal sees the same bytes, SNAP, and step 5 removes state.json only
# while it still has them. Returns 2, after the lines found so far and a
# last line saying which read failed, when a read failed: what it printed
# is then not the whole answer.
SNAP=""
journal_problems() {
  local key i rc=0 audio
  if [[ -e "$SESSION" ]]; then
    # Only a regular file is opened: open(2) on a FIFO with no writer
    # blocks, and this check runs while the recovery lock is held.
    if [[ ! -f "$SESSION" ]]; then
      echo "session.json is still present and cannot be read: it is not a regular file, so it was not opened"
    else
      copy_private "$SESSION" read.session.json || rc=$?
      case "$rc" in
        0)
          if ! shape_of session "$copy_path"; then
            echo "session.json is still present and could not be read whole ($read_why)"
          elif [[ -n "$shape_lines" ]]; then
            echo "session.json is still present and is not a session: ${shape_lines%%$'\n'*}"
          else
            echo "session.json is still present"
          fi
          ;;
        3) echo "session.json is still present and cannot be read (permissions or I/O)" ;;
        4) echo "session.json is still present and cannot be read: it is not a regular file" ;;
        *) echo "session.json is still present and could not be read whole ($copy_why)" ;;
      esac
    fi
  fi
  if [[ -e "$PENDING" || -L "$PENDING" ]]; then
    echo "pending-start is still present, so a password dialog left from an abandoned start could still turn sleep off"
  fi
  [[ -e "$STATE" ]] || return 0
  if [[ ! -f "$STATE" ]]; then
    echo "state.json is not a regular file, so it was not opened"
    return 0
  fi
  rc=0
  copy_private "$STATE" read.state.json || rc=$?
  if (( rc == 4 )); then
    echo "state.json is not a regular file, so it was not read"
    return 0
  elif (( rc != 0 )); then
    echo "state.json could not be copied to be read: $copy_why"
    return 2
  fi
  SNAP="$copy_path"
  if ! "$PLUTIL" -convert json -o /dev/null "$SNAP" >/dev/null 2>&1; then
    echo "state.json is unreadable or malformed"
    return 0
  fi
  if ! shape_of journal "$SNAP"; then
    echo "state.json could not be read whole, so whether it has the shape the app writes is unknown ($read_why)"
    return 2
  fi
  if [[ -n "$shape_lines" ]]; then
    echo "state.json is malformed (unexpected shape):"
    echo "$shape_lines"
    return 0
  fi
  snap_type sleepOffAttempt || return 2
  if [[ "$t" == dictionary ]]; then
    echo "a start that never finished is still journaled (sleepOffAttempt), so whether it turned sleep off is not settled"
  fi
  for key in sleepDisabledByUs lowPowerSetByUs dockerFrozen; do
    snap_read "$key" raw || return 2
    if [[ "$read_value" == true ]]; then
      echo "$key is still true"
    fi
  done
  snap_read frozenProcesses json || return 2
  if [[ -n "$read_value" && "$read_value" != "[]" ]]; then
    echo "frozen processes are still journaled: $read_value"
  fi
  snap_read frozenPids json || return 2
  if [[ -n "$read_value" && "$read_value" != "[]" ]]; then
    echo "legacy frozen pids (no identity; the backstop never signals or clears these, only the app does): $read_value"
  fi
  snap_read savedOutputVolume raw || return 2
  audio="$found"
  if (( ! audio )); then
    snap_read savedMuted raw || return 2
    audio="$found"
  fi
  if (( audio )); then
    echo "saved audio settings (volume/mute) are not restored; only the app can do that"
  fi
  i=0
  while :; do
    snap_read "savedAudioOutputs.$i" json || return 2
    (( found )) || break
    snap_read "savedAudioOutputs.$i.name" raw || return 2
    if (( ! found )); then
      snap_read "savedAudioOutputs.$i.deviceUID" raw || return 2
    fi
    echo "$read_value is still muted from a lid close; only the app can restore its volume, once the device is connected"
    i=$((i + 1))
  done
  snap_read savedDisplayBrightness raw || return 2
  if (( found )); then
    snap_read displayRestoreRefused raw || return 2
    if [[ "$read_value" != true ]]; then
      echo "saved display brightness is not restored; only the app can do that"
    fi
  fi
  snap_read savedKeyboardBrightness raw || return 2
  if (( found )); then
    snap_read keyboardRestoreRefused raw || return 2
    if [[ "$read_value" != true ]]; then
      echo "saved keyboard backlight is not restored; only the app can do that"
    fi
  fi
  snap_read appNapOverrides json || return 2
  if [[ -n "$read_value" && "$read_value" != "[]" ]]; then
    echo "App Nap settings (NSAppSleepDisabled) are not put back: $read_value"
  fi
  return 0
}
# Reads of SNAP for journal_problems: type_at and read_at, with found set
# to 1 for a value that is neither absent nor null. A read that fails
# prints a line saying which and returns 2.
snap_type() { # keypath
  local rc=0
  type_at "$SNAP" "$1" || rc=$?
  if (( rc == 2 )); then echo "state.json could not be read whole ($read_why)"; return 2; fi
  return 0
}
snap_read() { # keypath raw|json
  local rc=0
  found=0
  read_at "$SNAP" "$1" "$2" || rc=$?
  if (( rc == 2 )); then echo "state.json could not be read whole ($read_why)"; return 2; fi
  if (( rc == 0 )); then found=1; fi
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
    rc=0
    copy_private "$CONFIG" read.config.json || rc=$?
    if (( rc != 0 )); then
      echo "could not read the agent list in $CONFIG ($copy_why); only the shipped list is checked"
    else
      while :; do
        rc=0
        read_at "$copy_path" "agentList.$i" raw || rc=$?
        if (( rc == 2 )); then
          echo "could not read the agent list in $CONFIG whole ($read_why); only the $i entries before that one are checked with the shipped list"
          break
        fi
        (( rc == 0 )) || break
        i=$((i + 1))
        ids="$ids$read_value"$'\n'
      done
    fi
  fi
  while IFS= read -r id; do
    [[ -n "$id" && "$id" != -* ]] || continue
    if [[ -n "$stuck" ]]; then skipped=$((skipped + 1)); continue; fi
    rc=0
    bounded "$DEFAULTS" read "$id" NSAppSleepDisabled || rc=$?
    value="$BOUNDED_OUTPUT"
    # Output not read whole is only a prefix: neither its value nor its
    # "does not exist" can be trusted.
    if (( rc != 124 && ! BOUNDED_WHOLE )); then
      unreadable=$((unreadable + 1))
      printf 'could not read the whole answer of defaults read for %s; check it yourself with: defaults read %q NSAppSleepDisabled\n' "$id" "$id"
      continue
    fi
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
# still journals is unknown, and nothing is removed for it. The lines say
# which read failed.
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
# step 4 read: a journal that appeared or changed since then, or that
# cannot be read again to compare, is left and counted. Both sides of the
# comparison are private copies, so cmp never opens what stands at the
# live path.
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
    copy_private "$STATE" read.final.json || rc=$?
    if (( rc == 4 )); then
      rc=0
    elif (( rc != 0 )); then
      echo "Left $STATE: it could not be read again to compare with what the journal check read ($copy_why), so it was not checked." >&2
      remove_failures=$((remove_failures + 1))
      return 0
    else
      "$CMP" -s "$copy_path" "$SNAP" || rc=$?
      if (( rc != 0 )); then
        echo "Left $STATE: it is not the file the journal check read (cmp exit $rc), so it was not checked." >&2
        remove_failures=$((remove_failures + 1))
        return 0
      fi
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

# The password, asked before any lock is taken. sudo -v waits for it as long
# as the person at the keyboard takes, and nothing here waits on a prompt
# while it holds the recovery lock, the standard folder's lock or the
# receipt's lock, which the app, an install, another Insomnia folder of this
# user and the root command behind a password dialog may need. It runs
# nothing as root. Step 5 checks under the locks that sudo still keeps the
# credential (as_root -v) and stops before removing anything when it does
# not. The cost: the password is asked even when a check below then stops
# the uninstall.
step "Asking for your password, for $SUDOERS and the receipt"
if ! "$SUDO" -v; then
  echo "Uninstall stopped BEFORE removing anything: sudo -v did not authenticate. Rerun this script." >&2
  exit 1
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
#   - "undecided": the receipt stays locked or cannot be locked, or the
#     file the start journaled cannot be opened, so its lock cannot be
#     seen; or expires has not passed and the receipt shows nothing yet:
#     the dialog may still be answered.
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
# (SleepOffReceipts.lock), exactly as backstop.sh's lock_receipt: only the
# lstat type before the lock, every other check under it. Sets
# receipt_locked, or receipt_lock_why and, for a receipt that stayed locked
# or a lockf that failed, receipt_lock_busy=1, and for a regular file that
# could not be opened, receipt_unopened. unlock_receipt closes fd 7.
receipt_locked=""
lock_receipt() {
  local f="$RECEIPTS/$UID_NUM" why rc=0 found opened
  receipt_locked=""; receipt_lock_why=""; receipt_lock_busy=0; receipt_read=0; receipt_unopened=""
  found="$("$STAT" -f '%HT %d:%i' "$f" 2>/dev/null)" || found=""
  if [[ "$found" != "Regular File "?* ]]; then
    receipt_lock_why="$f is missing, is not the 82-byte file install.sh made, mode 600, or someone other than root can change it or a folder above it"
    return 0
  fi
  found="${found##* }"
  if ! { exec 7<"$f"; } 2>/dev/null; then
    receipt_unopened="$found"
    receipt_lock_why="$f could not be opened to be locked"
    return 0
  fi
  opened="$("$STAT" -f '%d:%i' <&7 2>/dev/null)" || opened=""
  if [[ -z "$opened" || "$opened" != "$found" ]]; then
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
  if [[ "$opened" == "$("$STAT" -f '%d:%i' "$f" 2>/dev/null)" ]]; then
    why="$(receipt_unsafe)"
    if [[ -n "$why" ]]; then
      exec 7<&-
      receipt_lock_why="$why"
      return 0
    fi
  fi
  if [[ "$opened" != "$("$STAT" -f '%d:%i' "$f" 2>/dev/null)" ]]; then
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
  content="$("$HEAD" -c 83 <&7 2>/dev/null; echo ".$?")"
  if [[ "${content##*.}" != 0 ]]; then
    receipt_read_why="$RECEIPTS/$UID_NUM could not be read (head exit ${content##*.})"
    return 0
  fi
  content="${content%.*}"
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
  content="$("$HEAD" -c 43 "$rf" 2>/dev/null; echo ".$?")"
  if [[ "${content##*.}" != 0 ]]; then
    release_why="$rf could not be read (head exit ${content##*.})"
    return 0
  fi
  content="${content%.*}"
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
  if [[ -n "$receipt_unopened" && "$receipt_unopened" == "$3" ]]; then
    verdict=undecided; verdict_why="$receipt_lock_why; a command for that start may hold its lock"
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

# state.json's private copy for the settlement (settle_copy) and the
# identity of the file it was made from (settle_id, see file_id): every
# read and edit of the settlement starts from that copy, and an edit is
# published only while state.json is still that file, and holds the same
# bytes (same_as_read). A change that keeps the size, the inode and both
# times to a fraction of a microsecond is seen only by that byte check.
settle_copy=""
settle_id=""
copy_settle() {
  local rc=0
  settle_copy=""; settle_id=""
  copy_private "$STATE" read.settle.json || rc=$?
  if (( rc == 0 )); then settle_copy="$copy_path"; settle_id="$copy_id"; fi
  return "$rc"
}
settle_unchanged() {
  local now
  now="$(file_id "$STATE")" || return 1
  [[ -n "$settle_id" && "$now" == "$settle_id" ]]
}
# A read of settle_copy the settlement cannot do without: read_at, raw,
# into read_value (empty for a key that is absent or null). One that fails
# stops the uninstall.
settle_read() { # keypath
  local rc=0
  read_at "$settle_copy" "$1" raw || rc=$?
  (( rc != 2 )) || settle_unknown "$read_why"
  return 0
}

# Publishes $STATE with the edits given (remove:KEYPATH or
# true:KEYPATH / false:KEYPATH), as one copy, edit, verify and rename, once
# plutil reads the edited copy whole as a JSON object and state.json is
# still the file settle_copy was made from; then copies the new journal
# again for the edit that follows. The copy is of the live journal, as
# backstop.sh's, so its extended attributes go with it (see backstop.sh's
# edit_state), and it must hold the bytes settle_copy holds (same_as_read).
# Returns 0; 1 with nothing published and no copy left when any step fails;
# 2 when it was published but could not be copied again (copy_why),
# settle_copy then empty.
edit_state() { # edit...
  local tmp="$APP_SUPPORT/.state.json.uninstall.$$" e ok=1
  [[ -n "$settle_copy" ]] && "$CP" "$STATE" "$tmp" && same_as_read "$tmp" "$settle_copy" || ok=0
  for e in "$@"; do
    (( ok == 1 )) || break
    case "$e" in
      remove:*) "$PLUTIL" -remove "${e#remove:}" "$tmp" >/dev/null 2>&1 || ok=0 ;;
      true:*|false:*) "$PLUTIL" -replace "${e#*:}" -bool "${e%%:*}" "$tmp" >/dev/null 2>&1 || ok=0 ;;
      *) ok=0 ;;
    esac
  done
  if (( ok == 1 )) && json_object "$tmp" && settle_unchanged && "$MV" -f "$tmp" "$STATE"; then
    copy_settle && return 0
    return 2
  fi
  "$RM" -f "$tmp"
  return 1
}

# Under the receipt's lock: gives a settled start's claim back and drops
# its record, or stops the uninstall saying what was done.
finish_settlement() { # nonce what-was-done
  local rc=0
  give_back_claim "$1" || settle_stop "it is settled, but its claim on the receipt could not be given back ($claim_why)" "$2"
  # Published but not copied again (2) is done: nothing reads it after.
  edit_state remove:sleepOffAttempt || rc=$?
  (( rc != 1 )) || settle_stop "it is settled, but its settled record could not be removed from $STATE" "$2"
  unlock_receipt
  echo "the settlement is finished: $( (( gave_back )) && echo "the start's claim on the receipt was given back" || echo "the start held no claim on the receipt") and its record removed"
}

# Stops the uninstall before anything runs when a read of the journal for
# the settlement failed: whether a start is still journaled, or what it
# records, is unknown.
settle_unknown() { # why
  unlock_receipt
  echo "Uninstall stopped BEFORE removing anything: $STATE could not be read whole (${1:-a read failed}), so whether it journals a start that never finished, and what that start records, is unknown." >&2
  echo "Nothing was removed and no pmset ran. Check that $STATE is a regular file you can read, then rerun." >&2
  exit 1
}

settle_attempt() {
  local nonce owed receipt pred deadline expires now has_marker=0 owes removed="" rc=0 matched=0 session_id=""
  [[ -f "$STATE" ]] || return 0
  # The journal is copied once (copy_settle) and read from that copy; only
  # a publish copies it again. One that is not a regular file is left to
  # the journal check below, which reports it.
  copy_settle || rc=$?
  (( rc != 4 )) || return 0
  (( rc == 0 )) || settle_unknown "$copy_why"
  # A journal plutil cannot convert whole is left to the journal check
  # below, which stops the uninstall on it as unreadable or malformed
  # before anything is removed. Every read after this one that fails stops
  # it here.
  "$PLUTIL" -convert json -o /dev/null "$settle_copy" >/dev/null 2>&1 || return 0
  type_at "$settle_copy" sleepOffAttempt || rc=$?
  (( rc != 2 )) || settle_unknown "$read_why"
  [[ "$t" == dictionary ]] || return 0
  rc=0; shape_of journal "$settle_copy" || rc=$?
  (( rc == 0 )) || settle_unknown "$read_why"
  [[ -z "$shape_lines" ]] || return 0
  settle_read sleepOffAttempt.nonce; nonce="$read_value"
  settle_read sleepOffAttempt.settled
  if [[ "$read_value" == true ]]; then
    lock_receipt
    [[ -n "$receipt_locked" ]] || settle_stop "it is settled, but the receipt could not be locked to give its claim back ($receipt_lock_why)"
    echo "finishing the settlement of an earlier start, which the journal records as settled"
    finish_settlement "$nonce" ""
    return 0
  fi
  settle_read sleepOffAttempt.owedBefore; owed="$read_value"
  settle_read sleepOffAttempt.receipt; receipt="$read_value"
  settle_read sleepOffAttempt.predecessor; pred="$read_value"
  settle_read sleepOffAttempt.deadline; deadline="$read_value"
  settle_read sleepOffAttempt.expires; expires="$read_value"
  rc=0; type_at "$settle_copy" sleepOffAttempt.marker || rc=$?
  (( rc != 2 )) || settle_unknown "$read_why"
  [[ "$t" == string ]] && has_marker=1
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
  # Only a session.json this run can read as a session is matched, through
  # a private copy; one it cannot open, or that is not a regular file, is
  # treated as expired by the backstop, and the app never resumes it. One
  # whose read fails some other way is unknown: the uninstall stops with
  # nothing removed. The matched file goes only while it is still the file
  # that was copied.
  if [[ -f "$SESSION" ]]; then
    rc=0; copy_private "$SESSION" read.settle-session.json || rc=$?
    if (( rc == 2 )); then
      settle_stop "$SESSION could not be read ($copy_why), so whether it is that start's session is unknown"
    elif (( rc == 0 )); then
      session_id="$copy_id"
      shape_of session "$copy_path" || rc=$?
      if (( rc == 0 )) && [[ -z "$shape_lines" ]]; then
        epoch_at "$copy_path" endsAt || rc=$?
        if (( rc == 0 )) && [[ -n "$epoch" && "$epoch" == "$deadline" ]]; then matched=1; fi
        if (( rc == 0 && matched )); then
          session_id_differs "$copy_path" "$settle_copy" || rc=$?
          if (( id_differs )); then echo "kept $SESSION: its end is the start's deadline, but its id is not the session the start journaled"; fi
          (( ! id_differs )) || matched=0
        fi
      fi
      (( rc == 0 )) || settle_stop "$SESSION could not be read ($read_why), so whether it is that start's session is unknown"
    fi
  fi
  if (( matched )); then
    [[ "$(file_id "$SESSION")" == "$session_id" ]] \
      || settle_stop "$SESSION of that start changed after it was read"
    "$RM" -f "$SESSION" || settle_stop "$SESSION of that start could not be removed"
    removed="$SESSION was removed"
    echo "removed $SESSION: its start never finished"
  fi
  # The decision, published while the claim is still held. Published but
  # not copied again (2) is published: the uninstall stops, saying so.
  rc=0; edit_state true:sleepOffAttempt.settled "$owes:sleepDisabledByUs" || rc=$?
  (( rc != 1 )) || settle_stop "the settled journal could not be published to $STATE" "$removed"
  if [[ -n "$removed" ]]; then removed="$removed, and the decision"; else removed="The decision"; fi
  (( rc == 0 )) || settle_stop "it is settled, but $STATE could not be read again to finish the settlement ($copy_why)" "$removed was journaled in $STATE as settled"
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
# A version that cannot be read is taken as not declared: the app's own
# backstop.sh runs, as for an app that does not declare it.
installed_version=""
if [[ -f "$APP/Contents/Info.plist" ]]; then
  version_rc=0
  copy_private "$APP/Contents/Info.plist" read.info.plist || version_rc=$?
  if (( version_rc == 0 )); then
    read_at "$copy_path" InsomniaResumeFrozenVersion raw || version_rc=$?
    if (( version_rc == 0 )); then installed_version="$read_value"; fi
    if (( version_rc == 2 )); then copy_why="$read_why"; fi
  fi
  if (( version_rc >= 2 )); then
    echo "could not read InsomniaResumeFrozenVersion from $APP/Contents/Info.plist ($copy_why); taking it as not declared" >&2
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
if (( journal_rc != 0 )); then
  abort_unknown "$recovery_rc" ${problems[@]+"${problems[@]}"}
fi
if (( recovery_rc != 0 )) && (( ${#problems[@]} == 0 )); then
  problems+=("backstop exited $recovery_rc; see $LOG_DIR/insomnia.log")
fi
if (( ${#problems[@]} > 0 )); then
  abort_incomplete "$recovery_rc" "${problems[@]}"
fi
kept_brightness=()
read_why="its list of kept brightness could not be read back"
refused_brightness > "$WORK/read.kept" || journal_rc=$?
{ while IFS= read -r line; do
  if [[ -n "$line" ]]; then kept_brightness+=("$line"); fi
done; } < "$WORK/read.kept" || journal_rc=2
if (( journal_rc != 0 )); then
  abort_unknown "$recovery_rc" "state.json could not be read whole ($read_why)"
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
#     show is then unknown;
#   - while one of the two files is there without the other. A receipt
#     that fails its own checks cannot be locked, and the app and the root
#     command refuse it, so no start can claim it now, but a start may have
#     claimed it before it failed them. And a receipt without its release
#     file, or the other way round, comes from an install or a recovery
#     that did not finish. Neither shows that no start needs the rule.
#     One case is known: an uninstall of this folder that stopped between
#     its two removals (see PROGRESS below) left the release file, free,
#     and nothing has written to it since. A start claims and gives back
#     only by writing to it, and only through the receipt, which is gone.
# Only a folder with neither file of this user in it, or no folder at all,
# shows nothing to settle here.
# The receipt's lock covers the receipt it was taken on, not a new one made
# at its path after that one is removed, and none at all while there is no
# receipt. install.sh makes the receipt and writes the release file, the
# rule and the bundle, and it runs only in the standard folder, under that
# folder's recovery lock, from before the rule until it ends. So before the
# check, this run also takes the standard folder's recovery lock
# (lock_standard, fd 6) and keeps it to the end: no install can make a
# receipt, write the release file, the rule or the bundle, or swap the
# bundle while this run checks and removes them, in any of the cases above,
# a finishing rerun included. In the standard folder that lock is fd 9.
# What it does not cover: the rule is shared by every account on this Mac,
# and another account's install or uninstall holds its own standard lock.
# The lock order every holder keeps: a folder's recovery lock (fd 9), then
# the standard folder's (fd 6), then the receipt's (fd 7). install.sh and
# an app or backstop of the standard folder take the standard lock as
# their recovery lock and the receipt's after it; another folder's app or
# backstop never takes the standard lock; and the root command behind a
# password dialog holds only the receipt's. So no two of them can wait on
# each other.
# A free release file shows that no start claims the receipt. It does not
# show that every start of another folder was restored: a start gives its
# claim back once it has started, and the restore comes at its end. Every
# restore the rule makes is `pmset -a disablesleep 0` or `pmset -b
# lowpowermode 0`, so while sleep is off or Low Power Mode is on for
# battery (read_owed_power), or either cannot be read, another folder may
# still owe one. Then this run keeps the rule, the receipt, its release
# file and the bundle, removes only this folder's own files, and says so.
# It does the same while another folder's recovery agent is loaded
# (loaded_agent), which runs the bundle's backstop.sh and needs the rule,
# and leaves that agent loaded. Either way it keeps the receipt's lock to
# the end, as when it removes them: a start claims the receipt under that
# lock before it loads its agent, so none can load one between the check
# and the bootout.
RECEIPT="$RECEIPTS/$UID_NUM"
RELEASED="$RECEIPT.released"
# This folder's record that its uninstall is removing the receipt and its
# release file: the release file's identity and line as release_state prints
# them, written under the receipt's lock and flushed to the disk after the
# checks and before the LaunchAgent goes, so a record that cannot be written
# stops the uninstall with nothing removed. A rerun that finds the release
# file without the receipt finishes the removal only when the record names
# that file as it is now: the same device and inode, the same change time to
# the nanosecond (every write to the file changes it, and a start claims and
# gives back by writing), and the same line, free. Anything else, a record
# of another file, an older state of this one, a claim, or no record at all,
# stays refused as unknown. Another folder's record is in that folder and is
# never read here.
PROGRESS="$APP_SUPPORT/.uninstall-receipt-removal"
# Sets release_now to "<device>:<inode>:<change time> <nonce> <word>" when
# the release file is a regular file with one link, this user's own, mode
# 600 and 42 bytes, holding a nonce and free or held, and stat gives the
# same identity and change time before and after its line is read.
# Returns 1 otherwise, with release_why.
release_state() {
  local before after
  release_now=""
  before="$("$STAT" -f '%d:%i:%Fc %l %u %Lp %z %HT' "$RELEASED" 2>/dev/null)" || before=""
  if [[ -L "$RELEASED" || "${before#* }" != "1 $UID_NUM 600 42 Regular File" ]]; then
    release_why="$RELEASED is not a regular file with one link, this user's own, mode 600 and 42 bytes"
    return 1
  fi
  read_release
  [[ -z "$release_why" ]] || return 1
  after="$("$STAT" -f '%d:%i:%Fc %l %u %Lp %z %HT' "$RELEASED" 2>/dev/null)" || after=""
  if [[ "$after" != "$before" ]]; then
    release_why="$RELEASED changed while it was read"
    return 1
  fi
  release_now="${before%% *} $release_nonce $release_word"
}
# Sets progress_seen to PROGRESS's record when the whole file is one, as
# record_removal writes it: a regular file, not a link, with one link, this
# user's own, mode 600 and at most 200 bytes, copied whole (copy_private)
# from the file stat named, and holding one line and nothing else: ended by
# a newline, with no other newline and no byte the shell would drop, that
# reads "<device>:<inode>:<change time> <nonce> free". Returns 1 otherwise:
# no file, a read that failed, a line without its newline, a second line,
# anything else in it. A rerun then refuses the lone release file.
progress_line() {
  local meta data id size
  progress_seen=""
  [[ -f "$PROGRESS" && ! -L "$PROGRESS" ]] || return 1
  meta="$("$STAT" -f '%d:%i %l %u %Lp %z %HT' "$PROGRESS" 2>/dev/null)" || return 1
  [[ "$meta" =~ ^([0-9]+:[0-9]+)\ 1\ ([0-9]+)\ 600\ ([0-9]+)\ Regular\ File$ ]] || return 1
  id="${BASH_REMATCH[1]}"; size="${BASH_REMATCH[3]}"
  [[ "${BASH_REMATCH[2]}" == "$UID_NUM" ]] && (( size <= 200 )) || return 1
  copy_private "$PROGRESS" read.progress || return 1
  [[ "$copy_id" == "$id:$size:"* ]] || return 1
  data="$("$CAT" "$copy_path" 2>/dev/null; echo ".$?")"
  [[ "${data##*.}" == 0 ]] || return 1
  data="${data%.*}"
  [[ "$data" == *$'\n' ]] || return 1
  data="${data%$'\n'}"
  [[ "$data" != *$'\n'* && "$data" =~ ^[0-9]+:[0-9]+:[0-9]+\.[0-9]+\ [0-9A-F-]{36}\ free$ ]] || return 1
  # The line is ASCII, so its length is its bytes: a NUL the shell dropped
  # leaves it short of the file.
  (( ${#data} + 1 == size )) || return 1
  progress_seen="$data"
}
# Writes $2 to the file $1 for good: perl, run with an empty environment,
# makes a new file beside it (O_EXCL, O_NOFOLLOW, mode 600), writes the
# bytes whole, flushes them to the disk (F_FULLFSYNC), renames the file
# over $1 and then flushes the folder the same way. Exits 1 with the step
# that failed, and leaves no new file behind, when one does. A flush shows
# that the kernel handed the bytes to the disk; it cannot show that a
# drive's own cache kept them through a power cut.
# shellcheck disable=SC2016  # the $ below are perl's, not this shell's
DURABLE_PERL='use strict; use Fcntl;
my ($path, $bytes) = @ARGV;
sub fail { print "$_[0]: $!\n"; exit 1 }
my ($dir) = $path =~ m{\A(.*)/[^/]+\z}s or fail "no folder in $path";
my $tmp = "$path.new.$$";
sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or fail "open $tmp";
my $ok = 1;
for (my $off = 0; $ok && $off < length $bytes; ) {
  my $w = syswrite($fh, $bytes, length($bytes) - $off, $off);
  if (defined $w && $w > 0) { $off += $w } else { $ok = 0 }
}
$ok = $ok && fcntl($fh, 51, 0);
$ok = close($fh) && $ok;
if (!$ok || !rename($tmp, $path)) { my $e = $!; unlink $tmp; $! = $e; fail "write $tmp"; }
sysopen(my $dh, $dir, O_RDONLY) or fail "open $dir";
fcntl($dh, 51, 0) or fail "flush $dir";
exit 0;'
# Writes PROGRESS for the release file as it is now (release_state) with
# DURABLE_PERL and reads it back whole (progress_line). Returns 1, with
# progress_why, when it cannot; the caller then stops before removing
# anything.
record_removal() {
  local out
  progress_why=""
  if ! release_state; then progress_why="$release_why"; return 1; fi
  if ! out="$("$ENV" -i "$PERL" -e "$DURABLE_PERL" "$PROGRESS" "$release_now"$'\n' 2>/dev/null)"; then
    progress_why="$PROGRESS could not be written and flushed to the disk (${out:-perl failed})"
    return 1
  fi
  if ! progress_line || [[ "$progress_seen" != "$release_now" ]]; then
    progress_why="$PROGRESS was written but does not read back as the record"
    return 1
  fi
}
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
  if [[ ! -e "$RECEIPT" && ! -e "$RELEASED" ]]; then return 0; fi
  if [[ ! -e "$RELEASED" ]]; then
    shared_why="$RECEIPT is there without its release file $RELEASED, so it does not show that no start claims the receipt"
    return 0
  fi
  if [[ ! -e "$RECEIPT" ]]; then
    if release_state && [[ "$release_word" == free ]] && progress_line && [[ "$progress_seen" == "$release_now" ]]; then
      shared_seen="finishing $release_now"
      release_seen="$release_nonce $release_word"
      return 0
    fi
    shared_why="$RELEASED is there without the receipt $RECEIPT, and no record of this folder's uninstall ($PROGRESS) names it as it is now, so what the receipt showed, and whether a start still needs the rule, is unknown"
    return 0
  fi
  lock_receipt
  if [[ -z "$receipt_locked" ]]; then
    shared_why="$receipt_lock_why"
    return 0
  fi
  read_receipt
  if [[ -n "$receipt_read_why" ]]; then
    shared_why="$receipt_read_why"
    unlock_receipt
    return 0
  fi
  shared_seen="locked $receipt_locked $receipt_nonce $receipt_pred $receipt_word"
  read_release
  if [[ -n "$release_why" ]]; then
    shared_why="$release_why"
  elif [[ "$release_word" == held ]]; then
    shared_why="$RELEASED shows that a start ($release_nonce) claims the receipt and is not settled yet"
  elif [[ "$release_nonce" != "$receipt_nonce" ]]; then
    shared_why="$RELEASED holds $release_nonce free, not the receipt's own nonce, so it does not show that no start claims the receipt"
  fi
  release_seen="$release_nonce $release_word"
  [[ -z "$shared_why" ]] || unlock_receipt
}
# Succeeds while the receipt, the release file and their folder are as
# check_shared saw them; otherwise sets shared_why. A receipt locked there
# must still be the locked file, pass the checks and hold the same line,
# read whole.
shared_unchanged() {
  local now=none line
  shared_why=""
  if [[ "$shared_seen" == locked* ]]; then
    if [[ "$receipt_locked" != "$("$STAT" -f '%d:%i' "$RECEIPT" 2>/dev/null)" || -n "$(receipt_unsafe)" ]]; then
      shared_why="$RECEIPT was replaced, or stopped passing the checks, while it was locked"
      return 1
    fi
    # By path, which names the locked file: fd 7 was read to its end.
    line="$("$HEAD" -c 83 "$RECEIPT" 2>/dev/null; echo ".$?")"
    if [[ "${line##*.}" != 0 ]]; then
      shared_why="$RECEIPT could not be read again (head exit ${line##*.})"
      return 1
    fi
    line="${line%.*}"
    now="locked $receipt_locked ${line%$'\n'}"
  elif [[ "$shared_seen" == finishing* && ! -e "$RECEIPT" && ! -L "$RECEIPT" ]]; then
    now="finishing ?"
    if release_state; then now="finishing $release_now"; fi
  elif [[ -e "$RECEIPT" || -L "$RECEIPT" || -e "$RELEASED" || -L "$RELEASED" ]]; then
    now=appeared
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
    if [[ -n "$release_why" ]]; then
      shared_why="$release_why"
      return 1
    fi
    if [[ "$release_nonce $release_word" != "$release_seen" ]]; then
      shared_why="$RELEASED changed after it was checked"
      return 1
    fi
  elif [[ -n "$release_seen" ]]; then
    shared_why="$RELEASED went away after it was checked"
    return 1
  fi
}
# Takes the standard folder's recovery lock on fd 6 (see the lock order
# above) and keeps it to the end. bounded() passes it to every supervisor,
# so a command left running keeps it too, after this run is gone. The
# folder and the lock file are made when they are missing, as install.sh
# makes them: whichever opens the path first creates the file, and both
# then lock that one file. When fd 9 is that same file (this is the
# standard folder, or this folder's lock is a link to its lock), fd 6 is
# closed: a second lock of one file through another descriptor would wait
# on this run's own. Sets standard_lock, or returns 1 with standard_why and
# standard_rc (75 when it stayed locked).
STANDARD_LOCK="$STANDARD_HOME/.recovery.lock"
lock_standard() {
  local own ours rc=0
  standard_lock=""; standard_why=""; standard_rc=1
  if ! "$MKDIR" -p "$STANDARD_HOME" 2>/dev/null || ! { exec 6<>"$STANDARD_LOCK"; } 2>/dev/null; then
    standard_why="$STANDARD_LOCK could not be opened"
    return 1
  fi
  ours="$("$STAT" -f '%d:%i' <&6 2>/dev/null)" || ours=""
  own="$("$STAT" -f '%d:%i' <&9 2>/dev/null)" || own=""
  if [[ -z "$ours" || -z "$own" ]]; then
    exec 6<&-
    standard_why="$STANDARD_LOCK or $LOCK could not be identified"
    return 1
  fi
  if [[ "$ours" == "$own" ]]; then
    exec 6<&-
    standard_lock="fd 9"
    return 0
  fi
  "$LOCKF" -t "$LOCK_TIMEOUT_SECONDS" 6 2>/dev/null || rc=$?
  if (( rc != 0 )); then
    exec 6<&-
    if (( rc == 75 )); then
      standard_rc=75
      standard_why="$STANDARD_LOCK stayed locked for ${LOCK_TIMEOUT_SECONDS} s: install.sh, the uninstall of another Insomnia folder of this user, or the app or backstop of the standard folder is running"
    else
      standard_why="$STANDARD_LOCK could not be locked (lockf exit $rc)"
    fi
    return 1
  fi
  # install.sh opens the lock by its path, so the path must still name the
  # file locked here.
  if [[ "$("$STAT" -L -f '%d:%i' "$STANDARD_LOCK" 2>/dev/null)" != "$ours" ]]; then
    exec 6<&-
    standard_why="$STANDARD_LOCK was replaced while it was locked"
    return 1
  fi
  standard_lock="$ours"
}
# Sets pmset_found to 1 and pmset_value to the second field of the first
# line of $1 (pmset's output) whose first field is $3, looking only in the
# part headed by the line $2 when $2 is not empty, as the app's parsers do
# (SleepGuard.swift). pmset_found is 0 when there is no such line. No here
# string: bash would write it to a temporary file first.
pmset_field() { # output section key
  local rest="$1"$'\n' line key in=1
  pmset_found=0; pmset_value=""
  [[ -z "$2" ]] || in=0
  while [[ -n "$rest" ]]; do
    line="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [[ -n "$2" && "$line" == *: ]]; then
      if [[ "$line" == "$2" ]]; then in=1; else in=0; fi
      continue
    fi
    (( in )) || continue
    key="${line%%[[:blank:]]*}"
    [[ "$key" == "$3" && "$line" != "$key" ]] || continue
    line="${line#"$key"}"
    line="${line#"${line%%[![:blank:]]*}"}"
    pmset_found=1; pmset_value="${line%%[[:blank:]]*}"
    return 0
  done
}
# Why a pmset read gave nothing to go on, from its bounded() status.
pmset_failed() { # what status
  if (( $2 == 124 )); then
    echo "'$1' did not answer within ${CALL_TIMEOUT_SECONDS}s"
  else
    echo "'$1' exited $2"
  fi
}
# Whether another Insomnia folder of this user may still owe a restore the
# rule runs (see above). Reads, without sudo and within the call limit,
# SleepDisabled in `pmset -g` and lowpowermode in the Battery Power part of
# `pmset -g custom`, the settings the app reads. Sets owed_why to what was
# found, or to nothing when sleep is not off and Low Power Mode is off for
# battery, or this Mac has no battery setting for it. A value other than 0
# or 1, or a read that fails, is unknown and counts as owed. This folder's
# journal is clean (step 4), so neither is this folder's to restore. It may
# be the user's own setting or another tool's: this cannot tell them apart.
read_owed_power() {
  local rc=0
  owed_why=""
  bounded "$PMSET" -g || rc=$?
  if (( rc != 0 )); then
    owed_why="$(pmset_failed "pmset -g" "$rc"), so whether sleep is off is unknown"
    return 0
  elif (( ! BOUNDED_WHOLE )); then
    owed_why="the output of 'pmset -g' could not be read whole, so whether sleep is off is unknown"
    return 0
  fi
  pmset_field "$BOUNDED_OUTPUT" "" SleepDisabled
  if (( pmset_found )) && [[ "$pmset_value" == 1 ]]; then
    owed_why="sleep is off (pmset -g reports SleepDisabled 1)"
    return 0
  elif (( pmset_found )) && [[ "$pmset_value" != 0 ]]; then
    owed_why="pmset -g reports SleepDisabled ${pmset_value:-with no value}, neither 0 nor 1, so whether sleep is off is unknown"
    return 0
  fi
  rc=0
  bounded "$PMSET" -g custom || rc=$?
  if (( rc != 0 )); then
    owed_why="$(pmset_failed "pmset -g custom" "$rc"), so whether Low Power Mode is on for battery is unknown"
    return 0
  elif (( ! BOUNDED_WHOLE )); then
    owed_why="the output of 'pmset -g custom' could not be read whole, so whether Low Power Mode is on for battery is unknown"
    return 0
  fi
  pmset_field "$BOUNDED_OUTPUT" "Battery Power:" lowpowermode
  if (( pmset_found )) && [[ "$pmset_value" == 1 ]]; then
    owed_why="Low Power Mode is on for battery (pmset -g custom reports lowpowermode 1 under Battery Power)"
  elif (( pmset_found )) && [[ "$pmset_value" != 0 ]]; then
    owed_why="pmset -g custom reports lowpowermode ${pmset_value:-with no value} under Battery Power, neither 0 nor 1, so whether Low Power Mode is on is unknown"
  fi
}
# Device and inode of $1, following links, read with bounded() so a stat
# that hangs (a folder on a server that stopped answering) cannot hold the
# locks. Sets path_id, or own_why and returns 1 when stat exits 1 (there is
# no such file, or it cannot be reached), 2 when it fails some other way,
# does not answer or prints something else.
path_identity() { # path
  local rc=0
  path_id=""
  bounded "$STAT" -L -f '%d:%i' "$1" || rc=$?
  if (( rc == 0 && BOUNDED_WHOLE )) && [[ "$BOUNDED_OUTPUT" =~ ^[0-9]+:[0-9]+$ ]]; then
    path_id="$BOUNDED_OUTPUT"
    return 0
  fi
  own_why="$(pmset_failed "stat -L $1" "$rc")"
  if (( rc == 1 )); then return 1; fi
  if (( rc == 0 && ! BOUNDED_WHOLE )); then
    own_why="the output of 'stat -L $1' could not be read whole"
  elif (( rc == 0 )); then
    own_why="$own_why without a device and inode"
  fi
  return 2
}
# Whether $1, the file launchd says the agent was loaded from, is this
# folder's: its plist, or a candidate with the label's candidate prefix in
# its staging directory or, for older builds, beside the plist (the names
# remove_plists removes). A candidate is renamed over the plist after the
# load, so the file itself may be gone. The folder it was in is this
# folder's $LAUNCH_AGENTS by path, or else when it has the same name and
# both it and the folder above it are this folder's by device and inode:
# a link to the whole folder (or /var for /private/var) is still this
# folder, while a LaunchAgents folder that only leads here from another
# folder is that folder's, with its own journal and lock
# (LaunchdBackstop.isOwnAgentFile reads the path the same way). Returns 0
# for this folder's, 1 for another's (also when its folder cannot be
# reached: this folder can be), and 2 with own_why when one of the folders
# could not be identified.
own_agent_file() { # path
  local dir="${1%/*}" mine="$LAUNCH_AGENTS" here rc step
  own_why=""
  case "${1##*/}" in
    "$LABEL.plist") ;;
    "$LABEL.candidate-"*)
      if [[ "${dir##*/}" == ".$LABEL.staging" ]]; then dir="${dir%/*}"; fi ;;
    *) return 1 ;;
  esac
  [[ "$dir" != "$mine" ]] || return 0
  [[ "${dir##*/}" == "${mine##*/}" ]] || return 1
  # The LaunchAgents folders, then the folders above them.
  for step in 1 2; do
    if (( step == 2 )); then
      mine="${mine%/*}"; dir="${dir%/*}"
      [[ -n "$mine" && -n "$dir" ]] || return 1
    fi
    path_identity "$mine" || return 2
    here="$path_id"
    rc=0; path_identity "$dir" || rc=$?
    (( rc != 2 )) || return 2
    if (( rc != 0 )) || [[ "$path_id" != "$here" ]]; then return 1; fi
  done
}
# Whose recovery agent launchd has loaded. Every Insomnia folder of this
# user loads its agent under the one label, so launchd holds one such job
# for the user, from whichever folder loaded it last, and `launchctl print`
# names the file it was loaded from on its `path =` line (one tab in, like
# every top-level key it prints; see LaunchdBackstop.loadedPath). Sets
# agent_seen to none (print exited 113: nothing is loaded under the label),
# own (loaded from a file of this folder, own_agent_file), other (from any
# other file: another folder's agent, which this run leaves loaded) or
# unknown (print failed or did not answer, or it names no such file, more
# than one, or one that is not an absolute path, or its folders could not
# be compared with this one), agent_path to the file, and agent_why to why
# it is unknown.
loaded_agent() {
  local rc=0 rest line prefix=$'\tpath = ' count=0 path=""
  agent_seen=unknown; agent_path=""; agent_why=""
  bounded "$LAUNCHCTL" print "gui/$UID_NUM/$LABEL" || rc=$?
  case "$rc" in
    113) agent_seen=none; return 0 ;;
    0) ;;
    124) agent_why="'launchctl print gui/$UID_NUM/$LABEL' did not answer within ${CALL_TIMEOUT_SECONDS}s"; return 0 ;;
    *) agent_why="'launchctl print gui/$UID_NUM/$LABEL' exited $rc"; return 0 ;;
  esac
  if (( ! BOUNDED_WHOLE )); then
    agent_why="the output of 'launchctl print gui/$UID_NUM/$LABEL' could not be read whole"
    return 0
  fi
  rest="$BOUNDED_OUTPUT"$'\n'
  while [[ -n "$rest" ]]; do
    line="${rest%%$'\n'*}"; rest="${rest#*$'\n'}"
    if [[ "$line" == "$prefix"* ]]; then
      path="${line#"$prefix"}"
      count=$(( count + 1 ))
    fi
  done
  if (( count != 1 )) || [[ "$path" != /* ]]; then
    agent_why="'launchctl print gui/$UID_NUM/$LABEL' lists the job but not one absolute path it was loaded from"
    return 0
  fi
  agent_path="$path"
  rc=0; own_agent_file "$path" || rc=$?
  case "$rc" in
    0) agent_seen=own ;;
    1) agent_seen=other ;;
    *) agent_path=""; agent_why="the folders of $path could not be compared with this one ($own_why)" ;;
  esac
}
# Stops the run when loaded_agent could not tell whose agent is loaded:
# booting it out could unload another folder's, and leaving it could leave
# this folder's. Nothing was removed yet.
stop_unknown_agent() {
  "$CAT" >&2 <<MSG

Uninstall stopped BEFORE removing anything: $agent_why, so whether the recovery agent loaded as $LABEL is this folder's or another Insomnia folder's is unknown.
The LaunchAgent, $SUDOERS, $APP, the receipt and the journal were kept.
Rerun this script once 'launchctl print gui/$UID_NUM/$LABEL' answers.
MSG
  exit 1
}
# Another folder's agent is loaded: it stays loaded, and the rule, the
# receipt and the bundle it runs stay with it (keep_shared).
agent_kept=0
keep_for_other_agent() {
  keep_shared=1
  if (( ! agent_kept )); then
    kept_why="${kept_why:+$kept_why, and }the recovery agent loaded as $LABEL is another Insomnia folder's ($agent_path)"
  fi
  agent_kept=1
  echo "kept for another Insomnia folder of this user: the recovery agent loaded as $LABEL comes from $agent_path, not from $LAUNCH_AGENTS; it stays loaded, and $SUDOERS, the receipt and $APP, which it runs, stay"
}

step "Checking the receipt every Insomnia folder of this user shares"
if ! lock_standard; then
  echo "Uninstall stopped BEFORE removing anything: $standard_why. Rerun this script once it is done." >&2
  exit "$standard_rc"
fi
if [[ "$standard_lock" == "fd 9" ]]; then
  echo "this folder's recovery lock is the one install.sh takes"
else
  echo "took $STANDARD_LOCK, the lock install.sh takes, until the end"
fi
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
  finishing*) echo "$RECEIPT is gone and $RELEASED is as this folder's uninstall left it when it began removing them ($PROGRESS); step 5 finishes the removal" ;;
  *) echo "no start claims $RECEIPT; it stays locked until the rule, the receipt and the bundle are gone" ;;
esac
# keep_shared=1: the rule, the receipt, its release file and the bundle
# stay, and step 5 removes only this folder's own files; kept_why says
# why. The receipt stays locked through both checks below, and then until
# the bundle is gone, or to the end of the run when the shared files stay.
keep_shared=0
kept_why=""
read_owed_power
if [[ -n "$owed_why" ]]; then
  keep_shared=1
  kept_why="$owed_why"
  echo "kept for another Insomnia folder of this user: $owed_why, so a restore the sudoers rule runs may still be owed; $SUDOERS, the receipt and $APP stay"
else
  echo "sleep is not off and Low Power Mode is not on for battery, so neither is owed a restore now; the App Nap, audio and brightness entries in the journal of another Insomnia folder of this user cannot be seen from here"
fi
loaded_agent
case "$agent_seen" in
  none) echo "no recovery agent is loaded as $LABEL" ;;
  own) echo "the recovery agent loaded as $LABEL is this folder's ($agent_path)" ;;
  other) keep_for_other_agent ;;
  *) stop_unknown_agent ;;
esac

# 5. Remove, still under the lock -------------------------------------------
# Every command step 5 runs as root goes through as_root: `sudo -n`, run by
# bounded() with the same time limit as every other call here, so sudo
# never prompts while this run holds the locks and never runs unsupervised.
# `sudo -v` asked for the password before the locks were taken; the calls
# here use the credential it cached.
# A call that fails, stops on SIGTERM at its limit, or is still running
# after it stops the uninstall there: what it did is not known, so nothing
# after it is removed. A sudo still running is never killed from here (no
# pid is kept for it: by the time anyone acted on one, it could name
# another process). Its supervisor holds this run's copies of fd 6, fd 7
# and fd 9, so the standard lock, the receipt's lock and the recovery lock
# stay held until it has exited and been reaped, after this run is gone.
# Loading the LaunchAgent again after a stop waits for it (restore_agent).
# root_running is 1 from just before the call starts until bounded()
# returns its status, which its supervisor writes once the call has been
# reaped; it stays 1 after a 125.
root_running=0
as_root() { # command args...
  local rc=0
  root_why=""
  root_running=1
  bounded "$SUDO" -n "$@" || rc=$?
  (( rc == 125 )) || root_running=0
  case "$rc" in
    0) return 0 ;;
    124) root_why="'sudo -n $*' did not answer within ${CALL_TIMEOUT_SECONDS}s and stopped on SIGTERM, so what it did is unknown" ;;
    125) root_why="'sudo -n $*' did not answer within ${CALL_TIMEOUT_SECONDS}s and is still running; it is not stopped from here, and the recovery lock, the standard folder's lock and the receipt's lock stay held until it ends" ;;
    *) root_why="'sudo -n $*' exited $rc${BOUNDED_OUTPUT:+ (${BOUNDED_OUTPUT%%$'\n'*})}" ;;
  esac
  return "$rc"
}
# After the LaunchAgent was booted out (agent_out), a stop loads it again
# from its plist, which stays in place until the shared files are gone,
# so this folder's recovery runs as it did before the uninstall. It runs
# once: from the stop, or from on_exit after any other exit. This run
# still holds the recovery lock, the standard folder's lock (the agent
# lock every load of the label takes) and the receipt's lock, so no app,
# install.sh or uninstall.sh of this build loads or unloads the label
# meanwhile (an older app does not take that lock; see "Removing
# LaunchAgent").
# A command run as root that may still be running (root_running: it was
# still running at its limit, or a signal ended this run while it waited
# for one) is waited for first and never stopped: nothing new starts
# beside it. Stopping that wait leaves the agent unloaded until someone
# loads it, or, for the standard folder, whose plist is in
# ~/Library/LaunchAgents, until the next login.
# launchd refuses a bootstrap while any job holds the label, so one still
# loaded, this folder's or another's, stays as it is. After a failed
# bootstrap a print tells which.
agent_out=0
restore_agent() {
  local rc=0 how
  (( agent_out )) || return 0
  agent_out=0
  if (( root_running )); then
    echo "A command this run started as root is still running; it is not stopped from here. The LaunchAgent is loaded again once it has ended. If this wait is stopped first, load it yourself after that: launchctl bootstrap gui/$UID_NUM $PLIST" >&2
    # Every background child of this run is a bounded() supervisor, and
    # each exits once its call has been reaped.
    wait 2>/dev/null || true
    root_running=0
    echo "That command has ended." >&2
  fi
  if [[ ! -f "$PLIST" ]]; then
    echo "The LaunchAgent could not be loaded again: $PLIST is gone." >&2
    return 0
  fi
  bounded "$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$PLIST" || rc=$?
  if (( rc == 0 )); then
    echo "The LaunchAgent was loaded again from $PLIST." >&2
    return 0
  fi
  if (( rc == 124 )); then how="did not answer within ${CALL_TIMEOUT_SECONDS}s"; else how="exited $rc"; fi
  loaded_agent
  case "$agent_seen" in
    own) echo "launchctl bootstrap $how, and the LaunchAgent is loaded from $agent_path." >&2 ;;
    other) echo "The LaunchAgent was not loaded again (launchctl bootstrap $how): the recovery agent of another Insomnia folder is loaded as $LABEL ($agent_path), and it was left loaded." >&2 ;;
    none) echo "The LaunchAgent could not be loaded again (launchctl bootstrap $how); load it yourself: launchctl bootstrap gui/$UID_NUM $PLIST" >&2 ;;
    *) echo "The LaunchAgent could not be loaded again (launchctl bootstrap $how), and $agent_why. If $LABEL is not loaded, load it yourself: launchctl bootstrap gui/$UID_NUM $PLIST" >&2 ;;
  esac
}
# The rule is one file for every account on this Mac, while the receipts,
# the locks and the bundles are each account's own. other_accounts sets
# rule_why when $RECEIPTS holds another account's receipt or release file
# (that account installed Insomnia, and its recovery agent may need the
# rule), an entry install.sh does not make, or cannot be listed whole; the
# rule then stays, and this account's own files are still removed. The
# listing cannot keep another account's install.sh from writing the rule
# or a receipt just after it: no lock spans accounts.
# shellcheck disable=SC2016  # the $ below are perl's, not this shell's
LIST_PERL='use strict;
opendir(my $d, $ARGV[0]) or exit 2;
my @names;
while (1) { $! = 0; my $e = readdir($d); if (!defined $e) { exit 3 if $!; last; } push @names, $e; }
closedir($d) or exit 3;
print map { "$_\n" } sort @names;'
rule_why=""
other_accounts() {
  local rc=0 name uids="" odd=0
  rule_why=""
  [[ -e "$RECEIPTS" || -L "$RECEIPTS" ]] || return 0
  bounded "$ENV" -i "$PERL" -e "$LIST_PERL" "$RECEIPTS" || rc=$?
  if (( rc != 0 || ! BOUNDED_WHOLE )); then
    rule_why="$RECEIPTS could not be listed whole (perl exit $rc), so whether another account on this Mac has a receipt in it is unknown"
    return 0
  fi
  while IFS= read -r name; do
    case "$name" in
      .|..|"$UID_NUM"|"$UID_NUM.released") continue ;;
    esac
    if [[ "$name" =~ ^([0-9]+)(\.released)?$ ]]; then
      [[ " $uids " == *" ${BASH_REMATCH[1]} "* ]] || uids="${uids:+$uids }${BASH_REMATCH[1]}"
    else
      odd=$((odd + 1))
    fi
  done <<< "$BOUNDED_OUTPUT"
  if [[ -n "$uids" ]]; then
    rule_why="$RECEIPTS holds the receipt of another account on this Mac (uid $uids)"
  fi
  if (( odd > 0 )); then
    rule_why="${rule_why:+$rule_why, and }$RECEIPTS holds names install.sh does not make ($odd), so whether another account uses the rule is unknown"
  fi
}
# Stops the uninstall after the rule went or was kept: what was kept, and
# why.
removal_recorded=0
rule_step="removing $SUDOERS"
stop_after_rule() { # why
  "$CAT" >&2 <<MSG

Uninstall stopped after $rule_step: $1.
$APP, the journal and whatever is left of the receipt were kept. Rerun this
script once nothing above is still running.
MSG
  if (( removal_recorded )); then
    echo "$PROGRESS records the receipt's removal: a rerun finishes it while $RELEASED stays as it is now." >&2
  fi
  restore_agent
  exit 1
}

if (( ! keep_shared )); then
  # The calls below need the credential `sudo -v` cached. One that sudo
  # does not keep (timestamp_timeout 0), or that expired while the checks
  # above ran, stops the uninstall here, before anything is removed.
  if ! as_root -v; then
    echo "Uninstall stopped BEFORE removing anything: $root_why, so sudo did not keep the credential the commands below need. Rerun this script." >&2
    exit 1
  fi
  # The record of the receipt's removal, written and flushed now, under the
  # receipt's lock, so a disk that cannot take it stops the uninstall before
  # anything is removed rather than between the receipt and its release
  # file. A finishing rerun's record is already there.
  if [[ "$shared_seen" == locked* ]]; then
    record_removal || { echo "Uninstall stopped BEFORE removing anything: $progress_why, so a stop between the removals of $RECEIPT and $RELEASED could not be finished by a rerun." >&2; exit 1; }
    removal_recorded=1
  fi
fi

# bootout first: it stops a running instance of the agent and drops queued
# runs, so nothing is left to reopen the journal once the files go. Then
# prove the job is really gone; if launchd still lists it, stop here with
# every recovery file intact. The label is the same for every Insomnia
# folder, and a bootout unloads whichever folder's agent holds it, so this
# run boots it out only when it is this folder's, asked again just before.
# This run holds the standard folder's recovery lock, the agent lock that
# every load and unload of the label by this build's app, install.sh and
# uninstall.sh takes first (LaunchdBackstop), so no other folder's agent is
# loaded between this print and the bootout. An app of a build before
# round 36 does not take it: launchctl cannot unload a job only if it
# still comes from a given file, so an agent such an app loads in between
# is unloaded instead, and that app loads it again at its next
# transaction.
step "Removing LaunchAgent"
loaded_agent
case "$agent_seen" in
  none) echo "$LABEL is not loaded" ;;
  other)
    if (( ! keep_shared )); then
      "$CAT" >&2 <<MSG

Uninstall stopped BEFORE removing anything: the recovery agent of another Insomnia folder was loaded as $LABEL ($agent_path) after the check above, and it was left loaded.
The LaunchAgent, $SUDOERS, $APP, the receipt and the journal were kept. Rerun this script.
MSG
      exit 1
    fi
    keep_for_other_agent ;;
  own)
    bootout_rc=0
    bounded "$LAUNCHCTL" bootout "gui/$UID_NUM" "$PLIST" || bootout_rc=$?
    # loaded_agent's print exits 113 only when the service is not loaded;
    # 0 means still loaded and anything else means launchd could not be
    # asked. 124 from either call means it did not answer within
    # CALL_TIMEOUT_SECONDS.
    # Not loaded after the bootout, whatever the bootout returned (a
    # bootout can unload the job and still fail or time out): this
    # folder's job was loaded at the print before it, under the agent
    # lock, and is out now, so a stop from here on loads it again
    # (restore_agent).
    loaded_agent
    case "$agent_seen" in
      none)
        agent_out=1
        echo "$LABEL is not loaded" ;;
      own)
        echo "launchctl bootout exited $bootout_rc and $LABEL is still loaded in gui/$UID_NUM." >&2
        echo "Nothing was removed. Run 'launchctl bootout gui/$UID_NUM $PLIST' yourself, then rerun." >&2
        exit 1 ;;
      other)
        # This folder's agent went; another folder's was loaded after it.
        # Its journal is clean (step 4), so it has nothing to restore, and
        # it cannot be loaded beside the other one.
        if (( ! keep_shared )); then
          echo "launchctl bootout exited $bootout_rc, and then the recovery agent of another Insomnia folder was loaded as $LABEL ($agent_path); it was left loaded." >&2
          echo "Nothing was removed. This folder's agent is not loaded again beside it. Rerun this script." >&2
          exit 1
        fi
        keep_for_other_agent ;;
      *)
        # The bootout may have unloaded it: restore_agent loads it again
        # from the plist, which launchd refuses if a job still holds the
        # label.
        echo "launchctl bootout exited $bootout_rc and $agent_why; cannot tell whether $LABEL is still loaded." >&2
        echo "Nothing was removed. Rerun this script once 'launchctl print gui/$UID_NUM/$LABEL' answers." >&2
        agent_out=1
        restore_agent
        exit 1 ;;
    esac ;;
  *) stop_unknown_agent ;;
esac
# The plist and the candidate plists install.sh and the app write before a
# load and rename into place after it: in the staging directory beside the
# plist, and in $LAUNCH_AGENTS itself for older builds. Only files with the
# label's candidate prefix, the same ones both of them sweep; the staging
# directory goes only once empty. Removed once the shared files are gone,
# just before the bundle, or now when they stay: until then a stop loads
# the agent again from the plist (restore_agent).
remove_plists() {
  local candidate
  "$RM" -f "$PLIST"
  agent_out=0
  CANDIDATE_DIR="$LAUNCH_AGENTS/.$LABEL.staging"
  for candidate in "$CANDIDATE_DIR/$LABEL.candidate-"* "$LAUNCH_AGENTS/$LABEL.candidate-"*; do
    if [[ -f "$candidate" && ! -L "$candidate" ]]; then "$RM" -f "$candidate"; fi
  done
  if [[ -d "$CANDIDATE_DIR" && ! -L "$CANDIDATE_DIR" ]]; then "$RMDIR" "$CANDIDATE_DIR" 2>/dev/null || true; fi
  echo "removed $PLIST"
}

if (( keep_shared )); then
  remove_plists
else
  # The receipt, the release file and their folder must still be as the
  # check before step 5 saw them, under the receipt's lock it still holds.
  step "Removing $SUDOERS"
  if ! shared_unchanged; then
    "$CAT" >&2 <<MSG

Uninstall stopped after booting out the LaunchAgent: $shared_why.
$SUDOERS, $APP, the receipt and the journal were kept. Rerun this script.
MSG
    restore_agent
    exit 1
  fi
  other_accounts
  if [[ -n "$rule_why" ]]; then
    rule_step="keeping $SUDOERS for another account"
    echo "kept $SUDOERS: $rule_why, and that account's recovery agent may need the rule"
  else
    # rm -f as root, whether or not this user can see the file:
    # /etc/sudoers.d is root's alone.
    if ! as_root "$RM" -f "$SUDOERS"; then
      "$CAT" >&2 <<MSG

Uninstall stopped after booting out the LaunchAgent: $root_why.
$SUDOERS may still be there. $APP, the receipt and the journal were kept.
Rerun this script once nothing above is still running.
MSG
      restore_agent
      exit 1
    fi
    echo "$SUDOERS is gone"
  fi

  # The receipt and its release file, which no start claims (see the check
  # before step 5), and their folder once empty: other accounts on this Mac
  # keep theirs. Root removes them only while the folder and every folder
  # above it are root's alone, so no folder on the path given to rm can be
  # changed by anyone else, and while the receipt is the file it locked.
  # The standard folder's lock keeps install.sh from making a new receipt
  # or release file at these paths meanwhile. Another Insomnia folder of
  # this user then needs install.sh again before its next start.
  step "Removing the receipt $RECEIPT"
  if [[ "$shared_seen" == none ]]; then
    echo "no $RECEIPTS"
  else
    shared_unchanged || stop_after_rule "$shared_why"
    for receipt_file in "$RECEIPT" "$RELEASED"; do
      [[ -f "$receipt_file" ]] || continue
      as_root "$RM" -f "$receipt_file" || stop_after_rule "$root_why"
      echo "removed $receipt_file"
    done
    # rmdir fails on a folder that still holds another account's receipt,
    # which is kept; one that does not answer stops the uninstall.
    rmdir_rc=0
    as_root "$RMDIR" "$RECEIPTS" || rmdir_rc=$?
    if (( rmdir_rc == 0 )); then
      echo "removed $RECEIPTS"
    elif (( rmdir_rc == 124 || rmdir_rc == 125 )); then
      stop_after_rule "$root_why"
    else
      echo "kept $RECEIPTS: it still holds another account's receipt, or could not be removed"
    fi
  fi
  # Both files are gone, so a record of their removal names nothing.
  if [[ -e "$PROGRESS" || -L "$PROGRESS" ]]; then
    if "$RM" -f "$PROGRESS" 2>/dev/null; then
      echo "removed $PROGRESS"
    else
      echo "warning: could not remove $PROGRESS; it names a release file that is gone, so no rerun acts on it" >&2
    fi
  fi

  step "Removing app bundle"
  remove_plists
  "$RM" -rf "$APP"
  # install.sh's leftovers beside the bundle, by the exact names it gives them.
  # An upgrade sets the previous bundle aside at .Insomnia.app.previous during
  # its swap and assembles the new one in .Insomnia.app.staging.<pid>.<six
  # letters and digits> (mktemp). The swap runs under the standard folder's
  # recovery lock, which this script holds, so a set-aside bundle belongs to
  # a run that was stopped. A staging directory whose run is still alive
  # belongs to an install that has not reached the lock yet, and stays.
  # kill -0 only asks whether the process exists; it sends no signal.
  # Symlinks and any other name are left.
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
fi

# $APP_SUPPORT/backstop.sh below is the writable copy of older installs; the
# current one is sealed in the bundle.
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
fi
if [[ -n "$rule_why" ]]; then
  "$CAT" >&2 <<MSG

$SUDOERS was kept: $rule_why. It is one file for every account on this Mac.
Once no account uses Insomnia any more, remove it yourself: sudo rm -f $SUDOERS
MSG
fi
if (( keep_shared )); then
  "$CAT" >&2 <<MSG

Done with this folder, but $SUDOERS, the receipt and its release file in
$RECEIPTS, and $APP were kept: $kept_why.
MSG
  if [[ -n "$owed_why" ]]; then
    "$CAT" >&2 <<MSG
Another Insomnia folder of this user may still owe that restore, and its
app or recovery agent needs them to make it. Rerun this script once it is
done to remove them. If the setting is your own or another tool's and no
Insomnia folder of yours has a session, switch it back (sleep: sudo pmset
-a disablesleep 0; Low Power Mode: System Settings > Battery), rerun this
script, and set it again afterwards.
MSG
  fi
  if (( agent_kept )); then
    "$CAT" >&2 <<MSG
That agent runs the backstop.sh sealed in $APP, which needs the rule to
turn sleep back on, so it was left loaded. Uninstall that Insomnia folder
first (uninstall.sh with INSOMNIA_HOME set as that folder's app had it, or
unset for the standard folder), then rerun this script. If that folder is
gone, unload its agent yourself (launchctl bootout gui/$UID_NUM/$LABEL)
and rerun.
MSG
  fi
  exit 1
fi
(( remove_failures == 0 )) || exit 1
echo "Done."
