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

The installer grants the user account passwordless access to four exact pmset
commands listed in the README. This grant is not exclusive to the Insomnia app:
other processes running as that user can invoke them too. The app is not
sandboxed; local logs can contain SSIDs, process metadata, and tmux target names.
The files Insomnia creates (logs, journal, session, config, recovery lock) are
mode 0600 and its directories 0700; the backstop runs with `umask 077`. Logs
are capped at 1 MiB with one older copy kept. Hotspot passwords are stored in
the login Keychain.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
