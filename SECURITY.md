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
other processes running as that user can invoke them too. The liveness lock
the backstop probes (`.app.alive` in Application Support) is an flock(2) any
process running as that user can hold; a process holding it stops the backstop
from noticing that Insomnia has quit, and the session deadline is then the
only cutoff. The app is not
sandboxed; local logs can contain SSIDs, process metadata, and tmux target names.
Hotspot passwords are stored in the login Keychain.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
