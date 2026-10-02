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
LOCK_TIMEOUT_SECONDS=10

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

step() { printf '\n==> %s\n' "$*"; }
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

cleanup() {
  if [[ -n "$TMP_SUDOERS" ]]; then rm -f "$TMP_SUDOERS"; fi
  if [[ -n "$CANDIDATE" ]]; then rm -f "$CANDIDATE"; fi
  if [[ -n "$CANDIDATE_DIR" ]]; then rmdir "$CANDIDATE_DIR" 2>/dev/null || true; fi
  if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi
}
trap cleanup EXIT

# 1. Build -------------------------------------------------------------------
step "Building (release)"
cd "$ROOT"
"$SWIFT" build -c release
BIN="$("$SWIFT" build -c release --show-bin-path)/Insomnia"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

# 2. sudoers -----------------------------------------------------------------
#    The password prompt comes first: until the rule is installed and proven
#    effective, the running app is not asked to quit and neither the bundle
#    (backstop.sh included) nor the LaunchAgent are touched.
step "Writing $SUDOERS (requires your password once)"
TMP_SUDOERS="$(mktemp)"
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
# `sudo -l <command>` checks the rule without running pmset (nothing on the
# machine changes). The backstop cannot undo anything without it, so stop here.
if "$SUDO" -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  echo "sudoers rule verified"
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
mkdir -p "$APP_DIR"
STAGE="$(mktemp -d "$APP_DIR/.Insomnia.app.staging.$$.XXXXXX")"
NEW_APP="$STAGE/Insomnia.app"
mkdir -p "$NEW_APP/Contents/MacOS"
cp "$BIN" "$NEW_APP/Contents/MacOS/Insomnia"
cp "$ROOT/Resources/Info.plist" "$NEW_APP/Contents/Info.plist"
mkdir -p "$NEW_APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$NEW_APP/Contents/Resources/AppIcon.icns"
# backstop.sh goes into the bundle before it is signed, so the signature's
# resource seal covers it. The LaunchAgent below verifies the whole bundle
# against the requirement read after signing and only then runs this copy;
# an edited script fails that check. No executable is left in a writable
# directory.
BACKSTOP="$NEW_APP/Contents/Resources/backstop.sh"
cp "$ROOT/scripts/backstop.sh" "$BACKSTOP"
chmod 755 "$BACKSTOP"
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
mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$LAUNCH_AGENTS"

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
if "$PGREP" -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia started again; quit it and rerun. The app at $APP and the LaunchAgent were not touched." >&2
  exit 1
fi

# Leftovers of earlier runs are handled only here, under the lock. Step 6
# runs under it too, so no other install is between setting the previous
# bundle aside and resolving the swap now: a bundle at $PREVIOUS_APP belongs
# to a run that was stopped, and no live run needs it to roll back.
if [[ -d "$PREVIOUS_APP" ]]; then
  # The requirement the plist on disk pins; launchd loads that file at the
  # next login. Empty when there is no plist or it cannot be read.
  pinned="$("$PLUTIL" -extract ProgramArguments.4 raw -o - "$PLIST" 2>/dev/null || true)"
  if [[ ! -e "$APP" ]]; then
    # Stopped between the two renames: nothing at $APP.
    mv "$PREVIOUS_APP" "$APP"
    echo "restored $APP, which an interrupted run had set aside"
  elif [[ -n "$pinned" ]] \
      && ! "$CODESIGN" --verify --strict "-R=$pinned" "$APP" >/dev/null 2>&1 \
      && "$CODESIGN" --verify --strict "-R=$pinned" "$PREVIOUS_APP" >/dev/null 2>&1; then
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
      "$LAUNCHCTL" bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
      cleared="$(loaded_state)"
      if [[ "$cleared" != no ]]; then
        cat >&2 <<FAIL

Install stopped: an interrupted run left its build at $APP and the previous app
at $PREVIOUS_APP, and $PLIST pins the previous one.
A job with label $LABEL may still be loaded from that run, and unloading it was
not confirmed (launchctl print: $cleared). That job pins the build at $APP, so
neither bundle was moved. Installed so far: $SUDOERS.
The next login loads $PLIST, which does not match the app at $APP. Before you
log out, unload the job and rerun this script:
  launchctl bootout gui/$UID_NUM/$LABEL
FAIL
        exit 1
      fi
    fi
    mv "$APP" "$STAGE/Interrupted.app"
    mv "$PREVIOUS_APP" "$APP"
    echo "restored $APP, which an interrupted run had set aside; $PLIST pins it"
    if [[ "$held" != no ]]; then
      # The job just unloaded may have been the one retrying recovery; the
      # previous plist takes over until this run replaces it.
      reload_rc=0
      "$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 || reload_rc=$?
      if (( reload_rc == 0 )) && [[ "$(loaded_state)" == yes ]]; then
        echo "unloaded the job the interrupted run left and loaded $PLIST again (launchctl print confirms)"
      else
        echo "unloaded the job the interrupted run left; loading $PLIST again was not confirmed ('launchctl bootstrap' exited $reload_rc)"
      fi
    fi
  else
    # $APP is what the plist pins (the interrupted run got as far as
    # publishing it), or nothing pins either: the set-aside copy is spare.
    rm -rf "$PREVIOUS_APP"
    echo "removed the bundle an interrupted run had set aside; $APP stays"
  fi
fi
# Staging directories of runs that are gone. One whose PID is alive belongs
# to an install that is still assembling its bundle and has not reached this
# lock yet, so it stays. kill -0 only asks whether the process exists; it
# sends no signal.
for dir in "$APP_DIR"/.Insomnia.app.staging.*; do
  [[ -d "$dir" && "$dir" != "$STAGE" ]] || continue
  owner="${dir##*/.Insomnia.app.staging.}"
  owner="${owner%%.*}"
  if [[ "$owner" =~ ^[0-9]+$ ]] && "$KILL" -0 "$owner" 2>/dev/null; then
    continue
  fi
  rm -rf "$dir"
done

step "Ending any stale session and checking the recovery journal"
recovery_rc=0
/bin/bash "$BACKSTOP" --force || recovery_rc=$?

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
#    loaded. Any failure leaves $PLIST byte for byte as it was. While
#    recovery is unresolved the previous job is not unloaded or replaced,
#    and neither is the bundle at $APP it pins.
step "Installing LaunchAgent $LABEL"
CANDIDATE_DIR="$LAUNCH_AGENTS/.$LABEL.staging"
CANDIDATE="$CANDIDATE_DIR/$LABEL.candidate-$$.plist"
mkdir -p "$CANDIDATE_DIR"
# Leftovers of earlier attempts, including an older build's candidates in
# $LAUNCH_AGENTS itself (those make launchd's login load report an error).
rm -f "$CANDIDATE_DIR/$LABEL.candidate-"* "$LAUNCH_AGENTS/$LABEL.candidate-"*

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
(exit status $recovery_rc). The app at $APP and the LaunchAgent were
not replaced or unloaded, so they still match each other; the new build
was discarded. Installed so far: $SUDOERS.
$agent_note
Check $LOG_DIR/insomnia.log and resolve what it reports (saved audio, display
brightness or keyboard backlight needs the app; if one is installed: open
"$APP"), or run the recovery by hand:
  /bin/bash "$ROOT/scripts/backstop.sh" --force
Then rerun this script to install the app and the LaunchAgent.
FAIL
  exit 1
fi

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
"$LAUNCHCTL" bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
if [[ "$before" != no ]]; then
  cleared="$(loaded_state)"
  if [[ "$cleared" != no ]]; then
    reload_hint=""
    if [[ "$cleared" != yes && -f "$PLIST" ]]; then
      reload_hint="If no job is loaded, load the previous one again:
  launchctl bootstrap gui/$UID_NUM '$PLIST'
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
had_app=0
if [[ -e "$APP" ]]; then
  mv "$APP" "$PREVIOUS_APP"
  had_app=1
fi
mv "$NEW_APP" "$APP"
bootstrap_rc=0
"$LAUNCHCTL" bootstrap "gui/$UID_NUM" "$CANDIDATE" || bootstrap_rc=$?
after="$(loaded_state)"
published=0
if (( bootstrap_rc == 0 )) && [[ "$after" == yes ]] && mv -f "$CANDIDATE" "$PLIST"; then
  published=1
fi

if (( published )); then
  echo "LaunchAgent $LABEL loaded (launchctl print confirms); $PLIST published"
  if (( had_app )); then
    rm -rf "$PREVIOUS_APP"
    echo "replaced the previous $APP"
  fi
  # Installs before this layout ran a writable copy from $APP_SUPPORT. The
  # agent just loaded runs the sealed one, so that copy goes now, not before.
  if [[ -e "$APP_SUPPORT/backstop.sh" ]]; then
    rm -f "$APP_SUPPORT/backstop.sh"
    echo "removed the previous install's $APP_SUPPORT/backstop.sh (the agent now runs the copy sealed in the bundle)"
  fi
else
  fix_note="Fix the launchctl error and rerun."
  if (( bootstrap_rc != 0 )); then
    reason="'launchctl bootstrap' exited $bootstrap_rc for the new LaunchAgent"
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
    "$LAUNCHCTL" bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
    unloaded="$(loaded_state)"
    stopped="$stopped
The new job was unloaded again (launchctl print confirms)."
  fi
  if [[ "$unloaded" != no ]]; then
    # The new job may still be loaded, and it pins the new build: putting
    # the previous app back would leave it refusing every run. The swap
    # stays and the previous bundle stays set aside, which is the state an
    # install killed mid-swap leaves; the rerun's repair above handles it.
    if (( had_app )); then
      kept_note="The previous app is kept at $PREVIOUS_APP; the rerun unloads the job
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
The new job may still be loaded: unloading it was not confirmed (launchctl print: $unloaded).
The new build stays at $APP, because that job pins it and would refuse the
previous app. $kept_note
$plist_note
$SUDOERS is installed and the recovery journal was clean when checked above.
${fix_note%.} before you log out.
FAIL
    exit 1
  fi
  # Undo the swap first, so whatever job runs next (the previous plist
  # reloaded below, or loaded at the next login) finds the build it pins.
  mv "$APP" "$NEW_APP"
  if (( had_app )); then
    mv "$PREVIOUS_APP" "$APP"
    app_note="The previous app was put back at $APP; the new build was discarded."
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
attempt. It pins the new build, which is not installed, so it refuses to run; unload it with
'launchctl bootout gui/$UID_NUM/$LABEL' or rerun this script." ;;
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
  1. Launch:            open "$APP"
  2. Optional:          System Settings > Wi-Fi > Ask to join hotspots: Automatically
  3. Config lives at:   $APP_SUPPORT/config.json
  4. Logs:              $LOG_DIR/insomnia.log
  5. Uninstall:         $ROOT/scripts/uninstall.sh
NEXT
