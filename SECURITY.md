# Security

Insomnia is experimental source-built software. There is no security-response
SLA or supported binary release series yet. Report suspected vulnerabilities
against the current main branch, including the affected revision and a minimal,
non-destructive reproduction.

Do not publish passwords, Keychain data, personal logs, or weaponized exploit
details in a public issue. If GitHub shows a **Report a vulnerability** action
on this repository's Security page, use that private channel. Otherwise open a
public issue containing only a request for a private security contact, without
the sensitive details, and wait for the maintainer to arrange one.

The installer grants the user account passwordless access to three exact pmset
commands listed in the README: turn sleep back on (`pmset -a disablesleep 0`)
and switch battery Low Power Mode on or off (`pmset -b lowpowermode 1` and
`0`). This grant is not exclusive to the Insomnia app: other processes running
as that user can invoke them too. None of them can keep the Mac awake. Turning
sleep off (`pmset -a disablesleep 1`) has no passwordless line; the app runs it
through the standard macOS administrator dialog, with a fixed command string,
each time the user starts a session, and never on relaunch or from the recovery
agent. That command turns sleep off only while the start that asked still
holds its random nonce in `pending-start`, and only before the session's end,
which it receives as an argument and compares with the clock as root; it
holds a `lockf` lock on that file from before the checks until pmset exits.
The start deletes the file when it finishes, and the app at launch, the recovery agent and uninstall delete it
under the recovery lock before they undo anything; every one of them takes the
file's own lock first, and deletes it only while its path still names the
file it locked, so the file never goes while that command is past its
check. A start that gave up on a stuck dialog counts it as voided only if
the file it locked is the one it wrote. The app after a relaunch, the
recovery agent and uninstall cannot make that last check, since they did
not write the file: a process running as you that puts a copy in its place
while the command runs could get it deleted early. Such a process could
already clear the journal entry in `state.json` directly. A dialog answered after its start was abandoned (the app died, recovery
ran, the start rolled back, a newer start began) runs nothing. The app shows
the dialog only when the `backstop.sh` sealed in its bundle, the copy the
recovery agent runs, declares in its `# insomnia-backstop-version:` line a
version that deletes `pending-start`, so recovery after a crash under the
dialog never depends on an older script.

Before the dialog the app runs nothing through sudo. It reads `pmset -g`,
and a SleepDisabled 1 the journal does not claim is left alone: Start is
refused with nothing run and gives the command that turns sleep back on. An
unreadable `pmset -g` refuses too. After the password, under the marker's
lock and after the nonce and deadline checks, the root command proves that
the session's end can turn sleep back on without a password by running that
restore: `sudo -n -u "#<uid>" /usr/bin/sudo -k -n /usr/bin/pmset -a
disablesleep 0`. Root drops to the user who pressed Start (sudo never asks
root for a password, and macOS's default `root ALL = (ALL) ALL` permits
it), and the user's sudo runs
the exact restore with `-k`, which ignores a credential cached by a recent
sudo, and `-n`, which fails instead of prompting. So only a sudoers rule
that lets that user run that exact command without a password passes.
`sudo -l` is not used: it lists commands the admin group may run with its
password, and lists without one whenever the account has any passwordless
entry. Only when the restore exits 0 does the root command run `pmset -a
disablesleep 1`. Otherwise it exits 5 having run no pmset, and the start is
rolled back with nothing to undo: no session, the journal and session.json
as they were, and a message to rerun the installer. That happens without
the rule (an uninstall that stopped part way, a hand-deleted file) and on a
Mac whose sudoers lacks root's default entry. The user has typed the
password by the time a missing rule is reported.

pmset has no compare-and-set, so the read before the dialog is not atomic
with anything after it. A SleepDisabled 1 another tool sets after that read
is not seen: the session's end sets it to 0, and if the tool sets it while
the dialog is up, the root command's
check sets it to 0 for a moment before it sets 1. The check never makes a
change the end or a rollback would not make. The installer runs no pmset:
right after writing the rule it confirms that `sudo -k -n -l` lists the
three commands without a password, which catches a rule sudo does not read
but is not proof that the restore runs, because the listing passes once any
of the user's rules is passwordless. The root command's check covers the
rest at every Start. A file that
cannot be deleted (its command is still running, an immutable flag, an ACL)
does not stop sleep from being turned back on, but the journal keeps the sleep
entry, the app and the agent report it and retry, and new sessions are refused
until it is gone. The rule stays in place after a failed install (the README says what
was installed). The installer never writes a passwordless `disablesleep 1`
line, on any path, including failed upgrades. It asks for the password before
it quits a running Insomnia, so a cancelled password changes nothing, and it
quits the app before it writes the rule, stopping with nothing changed if the
app will not quit. It writes the rule under the recovery lock, after the
app has quit. If it stops after the rule is written but before the app is replaced, an
older build left installed cannot start a session until the installer is
rerun; it fails closed and the installer prints the rerun command. The
uninstaller removes the file.

The app is not sandboxed; local logs can contain SSIDs, process metadata, and
tmux target names. The lines the app writes to `insomnia.log` also reach the unified log with the
body marked private, so programs reading `log show` see `<private>` instead of
those names unless private data logging is enabled on the Mac. The files
Insomnia creates (logs, journal, session, config, recovery lock) are mode 0600
and its directories 0700; the backstop runs with `umask 077`. Insomnia sets
only these modes and leaves any access control list (ACL) on these files as it
is, so an ACL someone added can still give another account access. Logs are capped at
1 MiB with one older copy kept. A log the user replaced with a symlink is not
rotated: the file it points to is the user's to manage. Location
Services access is requested only when a hotspot is saved or a session starts
with one configured; it is used to read Wi-Fi network names and the app never
requests location updates. With the App Nap setting on (off by default), the
app writes `NSAppSleepDisabled` into the preferences of each app on the agent
list, after recording the previous value in its journal, and puts it back at
session end.

The hotspot password is a generic-password item in the login Keychain
(service `insomnia-hotspot`). Its access list names only the Insomnia build
that saved it, so any other program asking for it gets the system Keychain
prompt, which you can refuse. Insomnia itself reads the item with prompts
switched off: an item it may not read is reported in the menu and in Settings
instead of being prompted for or silently ignored. Two limits remain. Ad-hoc
signing gives every install a new code identity, so the access list pins one
build and the password must be entered again after a reinstall; a stable
signing identity (Developer ID) would let the access list name every build
signed with it. And the item lives in the file-based login Keychain, which
ignores the data-protection accessibility classes (this device only, when
unlocked); using that Keychain needs an access-group entitlement, which needs
a team id. Both wait on a signed release.

The recovery LaunchAgent runs only the `backstop.sh` sealed inside the signed
app bundle, after `codesign --verify --strict` passes against the code
requirement pinned in its plist (the build's cdhash for an ad-hoc signature).
An edited bundle or script is refused and logged. The app pins the code it is
running (its own designated requirement, after confirming that the bundle on
disk is still that code and passes the agent's check), so a bundle edited or
re-signed under the running app is refused, not re-pinned. The plist itself
lives in `~/Library/LaunchAgents` and, like every per-user LaunchAgent, can be
edited by any program running as that user. With ad-hoc signatures these
checks are integrity against accidents and against the app relaying a
tampered bundle; they are not a boundary against a process running as the
same user, which can edit the plist, load its own agent, replace and relaunch
the app, and invoke the four pmset commands directly.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
