#!/bin/bash
# Build Insomnia, assemble ~/Applications/Insomnia.app, install the backstop
# script + LaunchAgent, and write the sudoers rule. Idempotent; asks for sudo
# once (for /etc/sudoers.d/insomnia) before a running Insomnia is asked to
# quit and before anything of a previous install is touched. Not atomic:
# every stop after that says exactly what was replaced so far.
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
OSASCRIPT=/usr/bin/osascript
LAUNCHCTL=/bin/launchctl
SUDO=/usr/bin/sudo
PLUTIL=/usr/bin/plutil
CODESIGN=/usr/bin/codesign
SWIFT=/usr/bin/swift
LOCKF=/usr/bin/lockf
INSTALL=/usr/bin/install
RM=/bin/rm
RMDIR=/bin/rmdir
MKDIR=/bin/mkdir
CP=/bin/cp
MV=/bin/mv
MKTEMP=/usr/bin/mktemp
CAT=/bin/cat
# sudo is given visudo and install by full path. Given a bare name, it would
# search the caller's PATH and run whatever it finds there as root.
VISUDO=/usr/sbin/visudo
LOCK_TIMEOUT_SECONDS=10
# How long the runs of an older backstop.sh get to exit (step 4).
RETIRE_WAIT_SECONDS=30

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

step() { printf '\n==> %s\n' "$*"; }

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

# 2. Password, then quit -----------------------------------------------------
#    Order: say whether a session will end, ask for the password (`sudo -v`),
#    then quit the running app. A cancelled or failed password stops before
#    the app is asked to quit, so it changes nothing and a running session
#    keeps going. An app that refuses to quit stops the install with
#    nothing changed. Nothing is written before step 3 holds the recovery
#    lock.

# Whether session.json holds a deadline still in the future, read the way
# backstop.sh reads it. A file whose deadline cannot be read counts as a
# running session: it may be one.
session_running() {
  local f="$APP_SUPPORT/session.json" ends ends_epoch
  [[ -f "$f" ]] || return 1
  ends="$("$PLUTIL" -extract endsAt raw -o - "$f" 2>/dev/null || true)"
  ends_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ends" +%s 2>/dev/null || true)"
  [[ -z "$ends_epoch" ]] || (( ends_epoch > $(date -u +%s) ))
}
if session_running; then
  echo "A session is running and the upgrade will end it."
  # Asked only when there is a terminal to answer on; a run without one
  # goes ahead after the line above.
  if [[ -t 0 ]]; then
    answer=""
    read -r -p "Continue? [y/N] " answer || true
    case "$answer" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Nothing was changed; the session keeps running." >&2; exit 1 ;;
    esac
  fi
fi

step "Authenticating (requires your password once)"
if ! "$SUDO" -v; then
  echo "sudo did not authenticate. Nothing was changed; Insomnia was not asked to quit, so a running session keeps going." >&2
  exit 1
fi

QUIT_DONE=0
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
    echo "Let it finish or quit it from its menu, then rerun. Nothing was changed." >&2
    exit 1
  fi
  QUIT_DONE=1
fi

# What a stop before anything is installed adds: whether the app was quit.
unchanged_note() {
  if (( QUIT_DONE )); then
    echo "Insomnia was quit, which ended any session; nothing else was changed. Open \"$APP\" to keep using the installed build, or rerun." >&2
  else
    echo "Nothing was changed." >&2
  fi
}

# The quit can take up to QUIT_WAIT_SECONDS. If sudo's cached credential
# expired meanwhile, ask once more. `sudo -v` also restarts the credential's
# timeout, so the sudoers step after the waits below can use it.
if ! "$SUDO" -n -v 2>/dev/null; then
  echo "The sudo credential expired while Insomnia was quitting; asking again."
  if ! "$SUDO" -v; then
    echo "sudo did not authenticate; nothing was installed." >&2
    unchanged_note
    exit 1
  fi
fi

# 3. Recovery lock -----------------------------------------------------------
#    Everything from here on is one transaction under the recovery lock (the
#    same flock(2) file the app and backstop use): the new backstop.sh, the
#    wait for older runs of it, the sudoers rule, the bundle, the recovery
#    run and the LaunchAgent replacement. A freshly started app cannot dirty
#    the journal between the clean check and the bootout of the old job,
#    and cannot show a password dialog while an older backstop.sh may still
#    run. The backstop inherits fd 9 and shares the lock instead of waiting
#    on it. The lock file is never unlinked or replaced, so every party
#    keeps locking the same inode.
"$MKDIR" -p "$APP_SUPPORT" "$LOG_DIR" "$LAUNCH_AGENTS"
step "Taking the recovery lock"
LOCK="$APP_SUPPORT/.recovery.lock"
exec 9<>"$LOCK"
lock_rc=0
"$LOCKF" -t "$LOCK_TIMEOUT_SECONDS" 9 2>/dev/null || lock_rc=$?
if (( lock_rc != 0 )); then
  echo "The recovery lock $LOCK is held by another process (the app or a running backstop). Wait a minute and rerun." >&2
  unchanged_note
  exit 75
fi
# The app may have been opened again during the password prompt or the
# wait for the lock. Nothing of it is replaced while it runs.
if "$PGREP" -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia started again; quit it and rerun." >&2
  unchanged_note
  exit 1
fi

# 4. Backstop script ---------------------------------------------------------
#    Installed before the bundle that relies on it. The app shows the
#    password dialog only when the installed backstop.sh declares a version
#    that deletes pending-start under its lock (BackstopVersion.swift), so
#    a stop anywhere in this script never leaves a new app with an older
#    backstop it would trust. `install -S` writes a temporary file and
#    renames it over the old one: a run of the previous script keeps
#    reading the file it opened instead of a mix of old and new text.
step "Installing backstop.sh to $APP_SUPPORT"
"$INSTALL" -S -m 0755 "$ROOT/scripts/backstop.sh" "$APP_SUPPORT/backstop.sh"

# What a stop between here and the sudoers rule says. The installed app
# keeps the rule it was installed with.
backstop_only_note() {
  echo "Only the new $APP_SUPPORT/backstop.sh was installed; $SUDOERS, the app and the LaunchAgent were not touched." >&2
  if (( QUIT_DONE )); then
    echo "Insomnia was quit, which ended any session. Open \"$APP\" to keep using the installed build, or rerun." >&2
  fi
}

# Every run of the previous backstop.sh has to be over before the new app
# can exist: one already waiting on the recovery lock would run its older
# code as soon as this script lets go, and an older script restores sleep
# after a crash but leaves pending-start, so a password dialog left open
# could still turn sleep off with nothing journaled. Each such run gives up
# on the lock held here within its own 10 s timeout (launchd starts one at
# a time), so this waits for every run of the installed path to exit, a
# run started since the copy above included. Such a run waits on the lock
# this script holds, so the lock cannot tell when it is over; its process
# can. A run is a process whose arguments are exactly what starts one:
# /bin/bash and the installed path from launchd (this script's plist and
# LaunchdBackstop.swift), plus `--force` from install.sh and uninstall.sh.
# A process that only names the path (an editor, a tail) is not a run.
backstop_runs() { # -> pids running $APP_SUPPORT/backstop.sh; fails if pgrep fails
  local out rc=0 pid args
  out="$("$PGREP" -lf 'backstop\.sh' 2>/dev/null)" || rc=$?
  (( rc <= 1 )) || return 1
  while read -r pid args; do
    case "$args" in
      "/bin/bash $APP_SUPPORT/backstop.sh" | "/bin/bash $APP_SUPPORT/backstop.sh --force") printf '%s ' "$pid" ;;
    esac
  done <<<"$out"
}
# A stop here comes before the sudoers rule, so it never leaves the new
# rule beside the old app.
for (( waited = 0; ; waited++ )); do
  runs="$(backstop_runs)" || runs="unknown (pgrep failed) "
  [[ -n "$runs" ]] || break
  if (( waited >= RETIRE_WAIT_SECONDS )); then
    echo "backstop.sh is still running after ${RETIRE_WAIT_SECONDS}s (pid ${runs% }); a run that started before this install may still act on its older code. Wait a minute and rerun." >&2
    backstop_only_note
    exit 1
  fi
  sleep 1
done
# The app may have been opened again during the wait.
if "$PGREP" -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia was opened again during the install; quit it and rerun." >&2
  backstop_only_note
  exit 1
fi

# 5. Sudoers -----------------------------------------------------------------
#    Written under the lock and after the wait above, on the credential
#    step 2 refreshed, so every earlier stop leaves the installed app with
#    the rule it was installed with. Three commands, and none of them can
#    keep the Mac awake: turning sleep back on and the battery Low Power
#    Mode floor stay passwordless so the app, backstop.sh and uninstall.sh
#    can recover unattended. Turning sleep off (`pmset -a disablesleep 1`)
#    has no line here, on any path; the app asks for the administrator
#    password each time a session starts. The file is always rewritten, so
#    a reinstall over an older four-line rule drops that line. An older
#    build still installed cannot start a session under the new rule, so a
#    stop between the rule and the new bundle says so and gives the rerun
#    command.
step "Writing $SUDOERS"
TMP_SUDOERS="$("$MKTEMP")"
# Set from the moment the new rule is installed until the new bundle is
# signed in place. Any stop in between prints rule_ahead_note on exit.
RULE_AHEAD_OF_BUNDLE=0
rule_ahead_note() {
  cat >&2 <<NOTE

$SUDOERS already holds the new three-line rule, but the app at $APP was not
replaced. An Insomnia build older than this installer cannot start a session
with that rule. Finish the install by rerunning:
  $ROOT/scripts/install.sh
NOTE
}
trap 'rc=$?; "$RM" -f "$TMP_SUDOERS"; if (( rc != 0 && RULE_AHEAD_OF_BUNDLE )); then rule_ahead_note; fi' EXIT
"$CAT" > "$TMP_SUDOERS" <<SUDO
# Installed by Insomnia install.sh. Exactly three commands, nothing else.
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
SUDO
if "$SUDO" "$VISUDO" -cf "$TMP_SUDOERS" >/dev/null && "$SUDO" "$INSTALL" -m 0440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS"; then
  RULE_AHEAD_OF_BUNDLE=1
else
  echo "The sudoers file failed validation (or sudo did not authenticate); it was not installed." >&2
  backstop_only_note
  exit 1
fi
# `sudo -l <command>` checks the rule without running pmset (nothing on the
# machine changes). The backstop cannot undo anything without it, so stop here.
if "$SUDO" -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  echo "sudoers rule verified"
else
  echo "'sudo -n pmset' is still not permitted; check $SUDOERS. The app and the LaunchAgent were not touched." >&2
  exit 1
fi

# 6. Bundle ------------------------------------------------------------------
# An app opened since the look after the wait would keep running the old
# build under the new rule, which no longer lets it start a session, so
# look once more right before the bundle goes. The rule is already
# written, so this stop gives the rerun command.
if "$PGREP" -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia was opened again during the install; quit it and rerun. The app was not replaced." >&2
  exit 1
fi
step "Assembling $APP"
"$RM" -rf "$APP"
"$MKDIR" -p "$APP/Contents/MacOS"
"$CP" "$BIN" "$APP/Contents/MacOS/Insomnia"
"$CP" "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$MKDIR" -p "$APP/Contents/Resources"
"$CP" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null
"$CODESIGN" --force --sign - --deep "$APP"
# shellcheck disable=SC2034  # read by the EXIT trap set in step 5
RULE_AHEAD_OF_BUNDLE=0
echo "signed $("$CODESIGN" -dv "$APP" 2>&1 | grep -i identifier || true)"

# 7. Recovery ----------------------------------------------------------------
step "Ending any stale session and checking the recovery journal"
recovery_rc=0
/bin/bash "$APP_SUPPORT/backstop.sh" --force || recovery_rc=$?

# 8. LaunchAgent: runs the backstop at load and every 60 s. The backstop
#    enforces the saved deadline itself and is a no-op while the session on
#    disk is valid. Same pattern as the app (LaunchdBackstop.swift): the
#    trusted plist at $PLIST is only ever a plist launchd actually loaded.
#    The new one is written to a private candidate one directory below it:
#    launchctl refuses any path without a `.plist` suffix (EIO), and
#    launchd's login-time load of $LAUNCH_AGENTS does not descend into
#    subdirectories, so a leftover candidate is never picked up as a second
#    copy of the label. It is loaded from there and published with one
#    rename (same filesystem) after `launchctl print` confirms the job is
#    loaded. Any failure leaves $PLIST byte for byte as it was. While
#    recovery is unresolved the previous job is not unloaded or replaced.
step "Installing LaunchAgent $LABEL"
CANDIDATE_DIR="$LAUNCH_AGENTS/.$LABEL.staging"
CANDIDATE="$CANDIDATE_DIR/$LABEL.candidate-$$.plist"
trap '"$RM" -f "$TMP_SUDOERS" "$CANDIDATE"; "$RMDIR" "$CANDIDATE_DIR" 2>/dev/null || true' EXIT
"$MKDIR" -p "$CANDIDATE_DIR"
# Leftovers of earlier attempts, including an older build's candidates in
# $LAUNCH_AGENTS itself (those make launchd's login load report an error).
"$RM" -f "$CANDIDATE_DIR/$LABEL.candidate-"* "$LAUNCH_AGENTS/$LABEL.candidate-"*

# `launchctl print` exits 0 when a job with the label is loaded and 113 when
# none is. Anything else is unknown, not absent. Being loaded says nothing
# about which plist or schedule that job runs (it may be an older one).
loaded_state() { # -> yes | no | unknown:<rc>
  local rc=0
  "$LAUNCHCTL" print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) echo yes ;;
    113) echo no ;;
    *) echo "unknown:$rc" ;;
  esac
}
before="$(loaded_state)"

if (( recovery_rc != 0 )); then
  case "$before" in
    yes) agent_note="A LaunchAgent job with label $LABEL is loaded and was left as it was. Which plist and
schedule it runs was not verified here; check with 'launchctl print gui/$UID_NUM/$LABEL'." ;;
    no) agent_note="No LaunchAgent $LABEL is loaded, so nothing retries by itself." ;;
    *) agent_note="'launchctl print gui/$UID_NUM/$LABEL' exited ${before#unknown:}, so whether a LaunchAgent is loaded is unknown." ;;
  esac
  cat >&2 <<FAIL

Install stopped: the backstop could not fully undo a previous session
(exit status $recovery_rc). The LaunchAgent was not replaced or unloaded.
Installed so far: the app at $APP, $APP_SUPPORT/backstop.sh, and $SUDOERS.
$agent_note
Check $LOG_DIR/insomnia.log and resolve what it reports (saved audio, display
brightness or keyboard backlight needs the app: open "$APP"), or run the
recovery by hand:
  /bin/bash "$APP_SUPPORT/backstop.sh" --force
Then rerun this script to install the LaunchAgent.
FAIL
  exit 1
fi

cat > "$CANDIDATE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$APP_SUPPORT/backstop.sh</string>
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
# cannot read fails with EIO instead of unloading anything), then bootstrap
# from the candidate.
"$LAUNCHCTL" bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
bootstrap_rc=0
"$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$CANDIDATE" || bootstrap_rc=$?
after="$(loaded_state)"

if (( bootstrap_rc == 0 )) && [[ "$after" == yes ]]; then
  if ! "$MV" -f "$CANDIDATE" "$PLIST"; then
    cat >&2 <<FAIL

Install stopped: the new LaunchAgent is loaded (launchctl print confirms) but
its plist could not be published to $PLIST, so the next login would load
whatever is there now. Fix the directory and rerun.
FAIL
    exit 1
  fi
  echo "LaunchAgent $LABEL loaded (launchctl print confirms); $PLIST published"
else
  if (( bootstrap_rc != 0 )); then
    reason="'launchctl bootstrap' exited $bootstrap_rc for the new LaunchAgent"
  else
    reason="'launchctl bootstrap' reported success, but the job is not confirmed loaded (launchctl print: $after)"
  fi
  # The trusted plist was never modified. Reload the previous job only when
  # it is known to have been loaded. A job being listed afterwards does not
  # say where it came from: only a reload that itself succeeded, confirmed
  # by print, is "the previous plist loaded again". Every print result is
  # reported as yes / no / unknown; unknown is never reported as absent.
  case "$before" in
    yes)
      reload_rc=0
      "$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 || reload_rc=$?
      now="$(loaded_state)"
      if (( reload_rc == 0 )) && [[ "$now" == yes ]]; then
        outcome="A job with label $LABEL is loaded again from the previous plist $PLIST
(launchctl bootstrap succeeded and launchctl print confirms; its schedule was not verified here)."
      elif [[ "$now" == yes ]]; then
        outcome="The reload of the previous plist was not confirmed ('launchctl bootstrap' exited
$reload_rc). A job with label $LABEL is loaded (launchctl print), but which plist it runs is
unknown: it may be the job that was loaded before this attempt. Check
'launchctl print gui/$UID_NUM/$LABEL' yourself, or rerun this script."
      else
        outcome="The previous job could not be loaded again ('launchctl bootstrap' exited
$reload_rc; launchctl print: $now); no job with label $LABEL is confirmed loaded. Run
  launchctl bootstrap gui/$UID_NUM '$PLIST'
yourself, or rerun this script."
      fi ;;
    no)
      now="$(loaded_state)"
      case "$now" in
        yes) outcome="No job was loaded before; one is loaded now (launchctl print), from the failed
attempt. Unload it with 'launchctl bootout gui/$UID_NUM/$LABEL' if you do not want it." ;;
        no) outcome="No job with label $LABEL was loaded before and none is loaded now." ;;
        *) outcome="No job was loaded before; whether one is loaded now is unknown ('launchctl print'
exited ${now#unknown:}), so it is not confirmed either way. Check
'launchctl print gui/$UID_NUM/$LABEL' yourself." ;;
      esac ;;
    *)
      outcome="Whether a job was loaded before is unknown (launchctl print exited ${before#unknown:}),
so nothing was reloaded. Check 'launchctl print gui/$UID_NUM/$LABEL' and, if needed,
'launchctl bootstrap gui/$UID_NUM $PLIST' yourself." ;;
  esac
  if [[ -f "$PLIST" ]]; then
    plist_note="The plist at $PLIST was not modified."
  else
    plist_note="No plist exists at $PLIST."
  fi
  cat >&2 <<FAIL

Install stopped: $reason.
$plist_note
$outcome
The app, $APP_SUPPORT/backstop.sh and $SUDOERS are installed and the recovery
journal was clean when checked above. Fix the launchctl error and rerun.
FAIL
  exit 1
fi

# 9. Done --------------------------------------------------------------------
step "Installed"
cat <<NEXT
Next steps:
  1. Launch:            open "$APP"
  2. Optional:          System Settings > Wi-Fi > Ask to join hotspots: Automatically
  3. Config lives at:   $APP_SUPPORT/config.json
  4. Logs:              $LOG_DIR/insomnia.log
  5. Uninstall:         $ROOT/scripts/uninstall.sh
NEXT
