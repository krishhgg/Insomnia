#!/bin/bash
# Build Insomnia, assemble ~/Applications/Insomnia.app, install the backstop
# script + LaunchAgent, and write the sudoers rule. Idempotent; shows the
# sudoers rule, asks once, then asks for sudo once (for
# /etc/sudoers.d/insomnia), before anything of a previous install is
# touched. Not atomic: a failure after the sudoers step says exactly what
# was replaced so far.
#
# --yes: install the rule shown without asking (for a run with no terminal).
# sudo still has to authenticate, and with no terminal it cannot ask, so
# the credentials must already be cached (`sudo -v` first, in the same
# shell) or the account must have a passwordless rule; this is checked
# before anything is written.
set -euo pipefail

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h|--help)
      echo "usage: $0 [--yes]"
      echo "  --yes  install the sudoers rule shown without asking. With no terminal, sudo must"
      echo "         already be authenticated: run 'sudo -v' first in the same shell."
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Installation always uses the standard per-user layout. A relocated
# INSOMNIA_HOME would make the backstop run here act on one tree while the
# app is installed against another, so refuse rather than guess.
if [[ -n "${INSOMNIA_HOME:-}" ]]; then
  echo "INSOMNIA_HOME is set ($INSOMNIA_HOME). install.sh only supports the standard layout under ~/Library;" >&2
  echo "unset INSOMNIA_HOME and rerun. Nothing was changed." >&2
  exit 1
fi

# Who this install is for. The sudoers rule names the account that is about
# to type its password, taken from the password database (id -un), never
# from $USER: any caller can set that to anything, including more sudoers
# syntax, and visudo only checks syntax. The name must be plain (letters,
# digits, underscore, dot, dash) so the rule can only ever be the lines
# built in step 2, and $HOME must be that account's home directory, since
# every other path written below is derived from it. Root is refused: under
# sudo the account and $HOME are root's, and the app and the rule would
# land in the wrong account. These two tool paths are fixed like the ones
# below and patched the same way in tests.
ID=/usr/bin/id
DSCL=/usr/bin/dscl
if [[ "$("$ID" -u)" == 0 ]]; then
  echo "install.sh must not run as root (do not use sudo with it). Run it as the user who will use Insomnia;" >&2
  echo "it asks for your password itself, once, for the sudoers rule. Nothing was changed." >&2
  exit 1
fi
ACCOUNT="$("$ID" -un)"
if [[ ! "$ACCOUNT" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
  echo "the account name '$ACCOUNT' (from id -un) has characters outside A-Z a-z 0-9 _ . - and cannot be written" >&2
  echo "into a sudoers rule safely. Nothing was changed." >&2
  exit 1
fi
if ! dscl_out="$("$DSCL" /Search -read "/Users/$ACCOUNT" NFSHomeDirectory 2>&1)"; then
  echo "could not look up the home directory of $ACCOUNT (dscl /Search -read /Users/$ACCOUNT NFSHomeDirectory failed: ${dscl_out:-no output}). Nothing was changed." >&2
  exit 1
fi
ACCOUNT_HOME="$(sed -n 's/^NFSHomeDirectory: //p' <<< "$dscl_out")"
# The same directory, not the same string: HOME may name it through a
# symlink (/var is one) or with a trailing slash.
canonical_dir() { # prints the real path of a directory; nothing if it is not one
  [[ -n "$1" && -d "$1" ]] || return 0
  (cd -P -- "$1" 2>/dev/null && pwd -P) || true
}
HOME_REAL="$(canonical_dir "${HOME:-}")"
ACCOUNT_HOME_REAL="$(canonical_dir "$ACCOUNT_HOME")"
if [[ -z "$ACCOUNT_HOME" || -z "$HOME_REAL" || "$HOME_REAL" != "$ACCOUNT_HOME_REAL" ]]; then
  echo "HOME is '${HOME:-}' but the home directory of $ACCOUNT is '${ACCOUNT_HOME:-unknown}'. The installer writes under HOME" >&2
  echo "and grants $ACCOUNT, so both must belong to the same account. Nothing was changed." >&2
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

# 2. sudoers -----------------------------------------------------------------
#    The password prompt comes first: until the rule is installed and proven
#    effective, the running app is not asked to quit and neither the bundle,
#    the installed backstop.sh nor the LaunchAgent are touched.
#
#    The commands the rule grants, and nothing else. The whole rule is built
#    from this list and $ACCOUNT: shown to the user, written to a temp file,
#    compared byte for byte with what was meant, checked by visudo,
#    installed, read back through sudo and compared again. So the file on
#    disk can only ever be these lines, whatever the environment held.
SUDOERS_COMMANDS=(
  "/usr/bin/pmset -a disablesleep 1"
  "/usr/bin/pmset -a disablesleep 0"
  "/usr/bin/pmset -b lowpowermode 1"
  "/usr/bin/pmset -b lowpowermode 0"
)
sudoers_rule() { # prints the exact file content
  local c
  echo "# Installed by Insomnia install.sh. Exactly ${#SUDOERS_COMMANDS[@]} commands, nothing else."
  for c in "${SUDOERS_COMMANDS[@]}"; do
    echo "$ACCOUNT ALL=(root) NOPASSWD: $c"
  done
}

step "Sudoers rule for $SUDOERS"
cat <<INTRO
Insomnia's recovery agent needs these ${#SUDOERS_COMMANDS[@]} pmset commands to run without a
password, so it can restore sleep when the app is not running. This rule
will be written to $SUDOERS. It applies to everything running as
$ACCOUNT, not only to Insomnia:

INTRO
sudoers_rule | sed 's/^/    /'
echo
if (( ASSUME_YES == 0 )); then
  if [[ ! -t 0 ]]; then
    echo "No terminal to confirm the rule on. Rerun from a terminal, or with --yes to install the rule shown above without asking (sudo must then be authenticated already: run 'sudo -v' first). Nothing was changed." >&2
    exit 1
  fi
  answer=""
  read -r -p "Install this rule? It asks for your password once. [y/N] " answer || true
  case "$answer" in
    y|Y|yes|Yes|YES) ;;
    *) echo "Not installed. Nothing was changed."; exit 1 ;;
  esac
fi
# With no terminal sudo cannot ask for a password either. `sudo -n -v` only
# refreshes cached credentials, or fails when a password would be needed.
if [[ ! -t 0 ]] && ! "$SUDO" -n -v 2>/dev/null; then
  echo "sudo needs a password and there is no terminal to ask on. Run 'sudo -v' first in this shell (its credentials stay cached for a few minutes), or rerun from a terminal. Nothing was changed." >&2
  exit 1
fi

step "Writing $SUDOERS (requires your password once)"
TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT
sudoers_rule > "$TMP_SUDOERS"
# The temp file must hold exactly the rule shown (a short write, or
# something else writing to the path, would otherwise reach visudo).
if ! cmp -s "$TMP_SUDOERS" <(sudoers_rule); then
  echo "the sudoers file written to $TMP_SUDOERS is not the rule shown above; not installed. Nothing was changed." >&2
  exit 1
fi
if "$SUDO" visudo -cf "$TMP_SUDOERS" >/dev/null; then
  "$SUDO" install -m 0440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS"
else
  echo "sudoers file failed validation (or sudo did not authenticate); not installed. Nothing was changed." >&2
  exit 1
fi
# What is on disk must be the rule shown, byte for byte. It is root-only,
# so it is read back through sudo. A difference means the install step did
# not write what it was given, and that file is not trusted as policy.
if ! "$SUDO" cat "$SUDOERS" | cmp -s - <(sudoers_rule); then
  echo "$SUDOERS does not match the rule shown above after installation (or could not be read back)." >&2
  echo "Remove it with 'sudo rm $SUDOERS', check what happened, then rerun. The app, backstop.sh and LaunchAgent were not touched." >&2
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
if "$PGREP" -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia is running; quitting it first (this ends any session)."
  "$OSASCRIPT" -e 'tell application id "com.kgarg.insomnia" to quit' >/dev/null 2>&1 || true
  for (( i = 0; i < QUIT_WAIT_SECONDS; i++ )); do
    "$PGREP" -x Insomnia >/dev/null 2>&1 || break
    sleep 1
  done
  if "$PGREP" -x Insomnia >/dev/null 2>&1; then
    echo "Insomnia is still running after ${QUIT_WAIT_SECONDS}s (it may be refusing to quit until its own recovery finishes)." >&2
    echo "Let it finish or quit it from its menu, then rerun. $SUDOERS is installed; the app, backstop.sh and LaunchAgent were not touched." >&2
    exit 1
  fi
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
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
if "$PGREP" -x Insomnia >/dev/null 2>&1; then
  echo "Insomnia started again; quit it and rerun. The LaunchAgent was not touched." >&2
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
