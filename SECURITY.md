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
file's own lock first, so the file never goes while that command is past its
check. A dialog answered after its start was abandoned (the app died, recovery
ran, the start rolled back, a newer start began) runs nothing. The app shows
the dialog only when the installed `backstop.sh` declares, in its
`# insomnia-backstop-version:` line, a version that deletes `pending-start`,
and the installer installs that script before the app, so recovery after a
crash under the dialog never depends on an older script. A file that
cannot be deleted (its command is still running, an immutable flag, an ACL)
does not stop sleep from being turned back on, but the journal keeps the sleep
entry, the app and the agent report it and retry, and new sessions are refused
until it is gone. The rule stays in place after a failed install (the README says what
was installed). The installer never writes a passwordless `disablesleep 1`
line, on any path, including failed upgrades. It asks for the password before
it quits a running Insomnia, so a cancelled password changes nothing, and it
quits the app before it writes the rule, stopping with nothing changed if the
app will not quit. If it stops after the rule is written but before the app is replaced, an
older build left installed cannot start a session until the installer is
rerun; it fails closed and the installer prints the rerun command. The
uninstaller removes the file. The app is not sandboxed; local logs can contain
SSIDs, process metadata, and tmux target names. The lines the app writes to
`insomnia.log` also reach the unified log with the body marked private, so
programs reading `log show` see `<private>` instead of those names unless
private data logging is enabled on the Mac. Hotspot passwords are stored in
the login Keychain. Location Services access is requested only when a hotspot
is saved or a session starts with one configured; it is used to read Wi-Fi
network names and the app never requests location updates. With the App Nap setting on (off by
default), the app writes `NSAppSleepDisabled` into the preferences of each app
on the agent list, after recording the previous value in its journal, and puts
it back at session end.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
