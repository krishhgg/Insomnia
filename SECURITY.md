# Security

Insomnia is experimental software. There is no security-response SLA. Binary
releases are experimental prereleases until they are signed with a Developer ID
and notarized. Report suspected vulnerabilities against the current main branch
or a release tag, including the affected revision and a minimal,
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
Hotspot passwords are stored in the login Keychain.

The recovery LaunchAgent runs only the `backstop.sh` sealed inside the signed
app bundle, after `codesign --verify --strict` passes against the code
requirement pinned in its plist (the build's cdhash for an ad-hoc signature).
An edited bundle or script is refused and logged. The plist itself lives in
`~/Library/LaunchAgents` and, like every per-user LaunchAgent, can be edited
by any program running as that user.

Release zips are built by the Release workflow from the tagged commit and
published with a `SHA256SUMS` file and a GitHub build provenance attestation.
Verify both before installing (`shasum -a 256 -c SHA256SUMS`,
`gh attestation verify <zip> -R krishhgg/Insomnia`); `install.sh --app` then
checks the bundle's signature, identifier and version before asking for a
password. The attestation shows which workflow run produced the bytes, not
that the code is free of defects. Until Developer ID signing and notarization
are set up (see [docs/releasing.md](docs/releasing.md)), releases are ad-hoc
signed and macOS blocks their first launch.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
