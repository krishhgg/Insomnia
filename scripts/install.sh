#!/bin/bash
# Build Insomnia, assemble ~/Applications/Insomnia.app with backstop.sh sealed
# inside it, install the LaunchAgent that verifies the bundle and runs that
# script, and write the sudoers rule. Idempotent; asks for sudo once (for
# /etc/sudoers.d/insomnia), before anything of a previous install is touched.
# The bundle and the LaunchAgent are replaced together, in one locked step
# (the agent pins one build, so the two must match at every moment), and a
# run that stops after that step began puts the previous bundle back. Not
# atomic beyond that: a failure after the sudoers step says exactly what was
# replaced so far.
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
KILL=/bin/kill
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
CODESIGN=/usr/bin/codesign
SWIFT=/usr/bin/swift
LOCKF=/usr/bin/lockf
MV=/bin/mv
RM=/bin/rm
RMDIR=/bin/rmdir
MKTEMP=/usr/bin/mktemp
MKDIR=/bin/mkdir
CP=/bin/cp
CHMOD=/bin/chmod
LOCK_TIMEOUT_SECONDS=10
# The limit for one call to sudo, pgrep, launchctl or codesign made while this
# run holds the recovery lock (and for the sudoers check before it); see
# bounded() below.
CALL_TIMEOUT_SECONDS=30

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Insomnia.app"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
LOG_DIR="$HOME/Library/Logs/Insomnia"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.insomnia.backstop"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
SUDOERS=/etc/sudoers.d/insomnia
UID_NUM="$(id -u)"
# Where the new bundle is assembled and signed (step 3) and where the previous
# one waits during the swap (step 6). Both inside $APP_DIR, so the swap is two
# renames on one filesystem. The staging directory's name carries the PID of
# the run that made it, so a later run can tell a dead run's leftover from
# the directory of an install that is still running (step 5).
PREVIOUS_APP="$APP_DIR/.Insomnia.app.previous"
STAGE=""
NEW_APP=""
TMP_SUDOERS=""
CANDIDATE=""
CANDIDATE_DIR=""
WORK=""

step() { printf '\n==> %s\n' "$*"; }
# A command for the user to paste, each word quoted for the shell, so a space,
# quote or $ in a path stays part of that path.
command_line() { local line; line="$(printf '%q ' "$@")"; printf '%s' "${line% }"; }

# Run one external call with a time limit, so a call that stalls (a sudo
# policy or directory-service lookup, a launchd that does not answer) cannot
# keep this run waiting forever. Its combined output is left in
# BOUNDED_OUTPUT (trailing newline removed) and its exit status returned, or
# 124 when it did not finish within CALL_TIMEOUT_SECONDS and was stopped, or
# 125 when it is sudo and still running (pid in BOUNDED_PID).
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
# cannot reuse another's.
BOUNDED_OUTPUT=""
BOUNDED_PID=""
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
# How a bounded call's exit status reads in a message.
call_result() { # status
  if (( $1 == 124 )); then
    printf 'did not answer within %ss' "$CALL_TIMEOUT_SECONDS"
  else
    printf 'exited %s' "$1"
  fi
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

cleanup() {
  if [[ -n "$TMP_SUDOERS" ]]; then "$RM" -f "$TMP_SUDOERS"; fi
  if [[ -n "$CANDIDATE" ]]; then "$RM" -f "$CANDIDATE"; fi
  if [[ -n "$CANDIDATE_DIR" ]]; then "$RMDIR" "$CANDIDATE_DIR" 2>/dev/null || true; fi
  if [[ -n "$STAGE" ]]; then "$RM" -rf "$STAGE"; fi
  if [[ -n "$WORK" ]]; then
    "$RM" -f "$WORK"/call.* 2>/dev/null || true
    "$RMDIR" "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# Scratch space for bounded(): this run's own directory, emptied on exit.
WORK="$("$MKTEMP" -d "${TMPDIR:-/tmp}/insomnia-install.XXXXXX")"

# 1. Build -------------------------------------------------------------------
step "Building (release)"
cd "$ROOT"
# INSOMNIA_LID_SIMULATION=1 compiles the scripts/simulate-lid.sh file trigger
# (LidSimulation.swift) into this release build, for release validation on
# a machine whose lid stays open. A normal build has no watcher: nothing
# reads the trigger file. Such a build says so in the log at launch, in the
# status menu and in Settings.
BUILD_FLAGS=()
if [[ "${INSOMNIA_LID_SIMULATION:-}" == 1 ]]; then
  BUILD_FLAGS+=(-Xswiftc -DINSOMNIA_LID_SIMULATION)
  echo "lid simulation compiled in (INSOMNIA_LID_SIMULATION=1): scripts/simulate-lid.sh will drive the lid actions during sessions"
fi
# ${arr[@]+"${arr[@]}"}: an empty array expands to nothing under set -u on
# the bash 3.2 that ships with macOS.
"$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN="$("$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)/Insomnia"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

# 2. sudoers -----------------------------------------------------------------
#    The password prompt comes first: until the rule is installed and proven
#    effective, the running app is not asked to quit and neither the bundle
#    (backstop.sh included) nor the LaunchAgent are touched.
step "Writing $SUDOERS (requires your password once)"
TMP_SUDOERS="$("$MKTEMP")"
cat > "$TMP_SUDOERS" <<SUDO
# Installed by Insomnia install.sh. Exactly four commands, nothing else.
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
SUDO
if "$SUDO" visudo -cf "$TMP_SUDOERS" >/dev/null; then
  "$SUDO" install -m 0440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS"
else
  echo "sudoers file failed validation (or sudo did not authenticate); not installed. Nothing was changed." >&2
  exit 1
fi
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
#    Assembled and signed in a staging directory inside $APP_DIR. $APP itself
#    is replaced in step 6, in the same locked step as the LaunchAgent: the
#    agent pins one build's requirement, so the bundle at $APP and the loaded
#    agent must be a matching pair before, during and after a failed run.
step "Assembling Insomnia.app"
# Ask the app to quit and wait until it has actually exited. It refuses to
# quit while it has unresolved recovery work; that refusal stands (no pkill),
# and nothing of the old install is overwritten while it is still running.
if "$PGREP" -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia is running; quitting it first (this ends any session)."
  "$OSASCRIPT" -e 'tell application id "com.kgarg.insomnia" to quit' >/dev/null 2>&1 || true
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    "$PGREP" -x Insomnia >/dev/null 2>&1 || break
    sleep 1
  done
  if "$PGREP" -x Insomnia >/dev/null 2>&1; then
    echo "Insomnia is still running after ${QUIT_WAIT_SECONDS}s (it may be refusing to quit until its own recovery finishes)." >&2
    echo "Let it finish or quit it from its menu, then rerun. $SUDOERS is installed; the app (with backstop.sh) and the LaunchAgent were not touched." >&2
    exit 1
  fi
fi
"$MKDIR" -p "$APP_DIR"
STAGE="$("$MKTEMP" -d "$APP_DIR/.Insomnia.app.staging.$$.XXXXXX")"
NEW_APP="$STAGE/Insomnia.app"
# The bundle is built here and reaches $APP whole, in one rename under the
# recovery lock (step 5), so backstop.sh never sees this binary beside an
# older Info.plist or the reverse (it runs the binary's --resume-frozen mode
# only once Info.plist declares InsomniaResumeFrozenVersion).
"$MKDIR" -p "$NEW_APP/Contents/MacOS"
"$CP" "$BIN" "$NEW_APP/Contents/MacOS/Insomnia"
"$CP" "$ROOT/Resources/Info.plist" "$NEW_APP/Contents/Info.plist"
"$MKDIR" -p "$NEW_APP/Contents/Resources"
"$CP" "$ROOT/Resources/AppIcon.icns" "$NEW_APP/Contents/Resources/AppIcon.icns"
# backstop.sh goes into the bundle before it is signed, so the signature's
# resource seal covers it. The LaunchAgent below verifies the whole bundle
# against the requirement read after signing and only then runs this copy;
# an edited script fails that check. No executable is left in a writable
# directory.
BACKSTOP="$NEW_APP/Contents/Resources/backstop.sh"
"$CP" "$ROOT/scripts/backstop.sh" "$BACKSTOP"
"$CHMOD" 755 "$BACKSTOP"
"$PLUTIL" -lint "$NEW_APP/Contents/Info.plist" >/dev/null
"$CODESIGN" --force --sign - --deep "$NEW_APP"
echo "signed $("$CODESIGN" -dv "$NEW_APP" 2>&1 | grep -i identifier || true)"
# What the agent pins: the bundle's designated requirement, in the form
# `codesign -d -r-` prints (an implicit one carries a leading "# "). For an
# ad-hoc signature that is the cdhash of this build, so no other build and
# no edited bundle satisfies it, and it does not depend on the path, so it
# still holds once the bundle is at $APP. The app reads the same text
# through the Security framework (CodeRequirement.swift) to recognise this
# plist.
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
# From here on every sudo, pgrep, launchctl and codesign call goes through
# bounded(): one that stalls is stopped and ends this run, which lets go of
# the lock, so the app and the agent's backstop can take it again and undo a
# session. A sudo that does not stop on SIGTERM keeps the lock until it ends.
# A pgrep that cannot answer does not say the app is gone, so the run stops.
pgrep_rc=0
bounded "$PGREP" -x Insomnia || pgrep_rc=$?
if (( pgrep_rc == 0 )); then
  echo "Insomnia started again; quit it and rerun. The app at $APP and the LaunchAgent were not touched." >&2
  exit 1
elif (( pgrep_rc != 1 )); then
  echo "pgrep $(call_result "$pgrep_rc"), so whether Insomnia started again is unknown. The app at $APP and the LaunchAgent were not touched; rerun." >&2
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
# when it does not, 124 when a codesign check did not answer in time, so
# it is not known which of the two it pins.
plist_pins_previous() {
  local pinned rc
  pinned="$("$PLUTIL" -extract ProgramArguments.4 raw -o - "$PLIST" 2>/dev/null || true)"
  [[ -n "$pinned" ]] || return 1
  rc=0
  bounded "$CODESIGN" --verify --strict "-R=$pinned" "$APP" || rc=$?
  if (( rc == 0 )); then return 1; fi
  if (( rc == 124 )); then return 124; fi
  rc=0
  bounded "$CODESIGN" --verify --strict "-R=$pinned" "$PREVIOUS_APP" || rc=$?
  if (( rc == 0 || rc == 124 )); then return "$rc"; fi
  return 1
}
pins_unknown_note="'codesign --verify', which tells which of the two bundles $PLIST pins,
did not answer within ${CALL_TIMEOUT_SECONDS}s."

step "Ending any stale session and checking the recovery journal"
recovery_rc=0
/bin/bash "$BACKSTOP" --force || recovery_rc=$?

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
$pins_unknown_note"
    fi
  else
    pair_note="The app at $APP and the LaunchAgent were not replaced or unloaded,
so they still match each other; the new build was discarded."
  fi
  cat >&2 <<FAIL

Install stopped: the backstop could not fully undo a previous session
(exit status $recovery_rc). $pair_note
Installed so far: $SUDOERS.
$agent_note
Check $LOG_DIR/insomnia.log and resolve what it reports. Saved audio, display
brightness or keyboard backlight needs the app; if one is installed, open it:
  $(command_line open "$APP")
Or run the recovery by hand:
  $(command_line /bin/bash "$ROOT/scripts/backstop.sh" --force)
Then rerun this script to install the app and the LaunchAgent.
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
aside at $PREVIOUS_APP, and $pins_unknown_note
Neither bundle was moved and no LaunchAgent job was unloaded; the new build was
discarded. Installed so far: $SUDOERS. The recovery journal was clean when
checked above. Rerun this script once codesign answers.
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
"$PLUTIL" -lint "$CANDIDATE" >/dev/null

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
cat <<NEXT
Next steps:
  1. Launch:            $(command_line open "$APP")
  2. Optional:          System Settings > Wi-Fi > Ask to join hotspots: Automatically
  3. Config lives at:   $APP_SUPPORT/config.json
  4. Logs:              $LOG_DIR/insomnia.log
  5. Uninstall:         $(command_line "$ROOT/scripts/uninstall.sh")
NEXT
