#!/bin/bash
# Build Insomnia, assemble ~/Applications/Insomnia.app, install the backstop
# script + LaunchAgent, and write the sudoers rule. Idempotent; asks for sudo
# once (for /etc/sudoers.d/insomnia), before anything of a previous install
# is touched. Not atomic: a failure after the sudoers step says exactly what
# was replaced so far.
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
BUNDLE_ID=com.kgarg.insomnia
# The Insomnia API client, whose executable is also named Insomnia. Its
# bundle id is the only one that proves a process is not this app.
CLIENT_BUNDLE_ID=com.insomnia.app
UID_NUM="$(id -u)"

step() { printf '\n==> %s\n' "$*"; }

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
# own account can quit it.
APP_FOUND=()      # "pid N (path)" per running copy of this app in this account
UNVERIFIED=()     # "pid N (path; why)" per process of this account that could not be told apart from it
OTHER_ACCOUNT=()  # "pid N (uid U, path)" per copy, or process that could not be told apart from one, in another account
OTHER_FOUND=()    # "pid N (path, bundle id X)" per process proven to be the API client
BLOCKING=()       # the first three: what must be gone before files are touched
# Bundle ids read before the recovery lock, as "pid|bundle|id", reused for
# the same process only: one that took a bundle's place since has another
# pid and is not taken for what ran there before. Once the lock is held
# (PLIST_READS=0) no Info.plist is read: one on a stalled volume would hold
# the lock, and this script has no time limit for a call. A process first
# seen then counts as unverified and blocks.
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
  local pid owner exe bundle id desc this
  APP_FOUND=(); UNVERIFIED=(); OTHER_ACCOUNT=(); OTHER_FOUND=(); BLOCKING=()
  for pid in $("$PGREP" -x Insomnia 2>/dev/null); do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    owner="$("$PS" -o uid= -p "$pid" 2>/dev/null || true)"
    owner="${owner//[[:space:]]/}"
    exe="$("$PS" -o comm= -p "$pid" 2>/dev/null || true)"
    id=""
    desc="${exe:-executable path unknown}"   # what the messages say; gains the reason when unverified
    if [[ "$exe" == /*/Contents/MacOS/* ]]; then
      bundle="${exe%/Contents/MacOS/*}"
      id="$(known_id "$pid" "$bundle")"
      if [[ -z "$id" ]] && (( PLIST_READS == 1 )); then
        id="$("$PLUTIL" -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" 2>/dev/null || true)"
        if [[ -n "$id" ]]; then KNOWN_IDS+=("$pid|$bundle|$id"); fi
      fi
      if [[ -z "$id" ]]; then
        if (( PLIST_READS == 1 )); then
          desc="$exe; no bundle id readable from $bundle/Contents/Info.plist"
        else
          desc="$exe; first seen under the recovery lock, where no Info.plist is read"
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
    # No uid (the process just exited, or ps failed) is not proof of
    # another account; such a pid is judged as one of this account's.
    if [[ -n "$owner" && "$owner" != "$UID_NUM" ]]; then
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
# Stops the run when Insomnia runs in another account; nothing is sent to
# that process. The argument says what this run has changed so far.
stop_for_other_accounts() { # what was changed
  (( ${#OTHER_ACCOUNT[@]} > 0 )) || return 0
  echo "Insomnia is running in another account, or a process named Insomnia there could not be told apart from it: $(list "${OTHER_ACCOUNT[@]}")." >&2
  echo "$SUDOERS is shared by every account on this Mac and that copy may need the rule in it, so it is left alone and not asked to quit." >&2
  echo "Quit Insomnia in that account, then rerun. $1" >&2
  exit 1
}

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
#    effective, the running app is not asked to quit and neither the bundle,
#    the installed backstop.sh nor the LaunchAgent are touched. A copy
#    running in another account stops the install before the rule is
#    replaced (find_insomnia), and so does a rule that grants another
#    account: that account's agent needs it to undo a session even after
#    its app crashed, when no process of it is left to find.
find_insomnia
stop_for_other_accounts "Nothing was changed."
step "Writing $SUDOERS (requires your password once)"
if [[ -e "$SUDOERS" ]] || "$SUDO" test -e "$SUDOERS"; then
  # Root-only, so it is read through sudo, the same way uninstall.sh reads it.
  if ! sudoers_text="$("$SUDO" cat "$SUDOERS")"; then
    echo "Could not read $SUDOERS through sudo, so it was not replaced. Nothing was changed." >&2
    exit 1
  fi
  sudoers_why="$(sudoers_for_others "$sudoers_text")"
  if [[ "$sudoers_why" == grants\ * ]]; then
    echo "$SUDOERS $sudoers_why, not $USER. Another account installed Insomnia, and its recovery agent needs that rule to undo a session, even one whose app crashed. This Mac has room for one rule, so this install would take it away." >&2
    echo "Uninstall Insomnia in that account first. If that account no longer exists, remove the rule with 'sudo rm $SUDOERS', then rerun. Nothing was changed." >&2
    exit 1
  elif [[ -n "$sudoers_why" ]]; then
    echo "$SUDOERS $sudoers_why. Replacing the file would drop that line." >&2
    echo "Check it, remove the file with 'sudo rm $SUDOERS' if nothing needs it, then rerun. Nothing was changed." >&2
    exit 1
  fi
fi
TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT
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
  echo "'sudo -n pmset' is still not permitted; check $SUDOERS. The app, backstop.sh and LaunchAgent were not touched." >&2
  exit 1
fi

# 3. Bundle ------------------------------------------------------------------
step "Assembling $APP"
# Ask the app to quit and wait until it has actually exited. It refuses to
# quit while it has unresolved recovery work; that refusal stands (no pkill),
# and nothing of the old install is overwritten while it is still running.
# This app counts, and so does a process named Insomnia that cannot be told
# apart from it (find_insomnia); one proven to be another app is reported
# and left alone. A copy in another account stops the install.
if app_running; then
  report_others
  stop_for_other_accounts "$SUDOERS is installed; the app, backstop.sh and LaunchAgent were not touched."
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
    echo "Let it finish or quit it from its menu, quit any process listed as unverified, then rerun. $SUDOERS is installed; the app, backstop.sh and LaunchAgent were not touched." >&2
    exit 1
  fi
else
  report_others
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# The binary goes in before Info.plist: backstop.sh runs the binary's
# --resume-frozen mode only once Info.plist declares it
# (InsomniaResumeFrozenVersion), so a backstop that runs mid-copy never
# starts a binary older than that declaration.
cp "$BIN" "$APP/Contents/MacOS/Insomnia"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null
"$CODESIGN" --force --sign - --deep "$APP"
echo "signed $("$CODESIGN" -dv "$APP" 2>&1 | grep -i identifier || true)"

# 4. Backstop script + dirs --------------------------------------------------
step "Installing backstop.sh to $APP_SUPPORT"
mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$LAUNCH_AGENTS"
cp "$ROOT/scripts/backstop.sh" "$APP_SUPPORT/backstop.sh"
chmod +x "$APP_SUPPORT/backstop.sh"

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
  echo "Wait a minute and rerun. The app, $APP_SUPPORT/backstop.sh and $SUDOERS are installed; the LaunchAgent was not touched." >&2
  exit 75
fi
PLIST_READS=0
if app_running; then
  echo "Insomnia started again ($(list "${BLOCKING[@]}")); quit it and rerun. The LaunchAgent was not touched." >&2
  exit 1
fi

step "Ending any stale session and checking the recovery journal"
recovery_rc=0
/bin/bash "$APP_SUPPORT/backstop.sh" --force || recovery_rc=$?

# 6. LaunchAgent: runs the backstop at load and every 60 s. The backstop
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
trap 'rm -f "$TMP_SUDOERS" "$CANDIDATE"; rmdir "$CANDIDATE_DIR" 2>/dev/null || true' EXIT
mkdir -p "$CANDIDATE_DIR"
# Leftovers of earlier attempts, including an older build's candidates in
# $LAUNCH_AGENTS itself (those make launchd's login load report an error).
rm -f "$CANDIDATE_DIR/$LABEL.candidate-"* "$LAUNCH_AGENTS/$LABEL.candidate-"*

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
  if ! mv -f "$CANDIDATE" "$PLIST"; then
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
