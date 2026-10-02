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
agent. The rule stays in place after a failed install (the README says what
was installed). When an upgrade stops because the previous build will not
quit, the installer puts that build's `disablesleep 1` line back and says so,
so a failed upgrade never leaves an install that cannot start a session. The
uninstaller removes the file. The app is not sandboxed;
local logs can contain SSIDs, process metadata, and tmux target names. Hotspot
passwords are stored in the login Keychain.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
