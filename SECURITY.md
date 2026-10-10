# Security

Insomnia is experimental software. There is no security-response SLA. Report
suspected vulnerabilities against the current main branch
or a release tag, including the affected revision and a minimal,
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
from noticing that Insomnia has quit. Only that check is lost: the backstop
still ends the session at its deadline, below the battery end floor, or at
critical thermal pressure. While the lock is held, the backstop reads the end
floor and the thermal rule by passing `config.json` to the installed app's
binary (`Insomnia --agent-cutoffs`), the one in the bundle whose signature the
agent checks before each run, and while that file is missing or rejected, the
values the app recorded for the session in `state.json`
(`Insomnia --agent-session-cutoffs`). When that binary is gone or replaced by
another version during the run, or gives no answer in its form in time, the
backstop reads `config.json` itself where its own reader can tell what the
app's decoder makes of it (not for a file over 8 MiB, one the reader does
not finish within 30 s, or one on which Foundation stops the app), and
otherwise the values recorded in `state.json`, once the journal passes its
check. A recorded value the app does not write counts
as none, as the app reads it. With no record, it enforces the app's defaults
(a 10% end floor, thermal rules on) while `config.json` is missing or
rejected, and the strictest values (95%, on) while the file is there but
cannot be read either way; both are open stopgaps (spec section 6). A
journal the app would not load, or one whose meaning to the app the check
cannot tell (an Int64 on which Foundation stops the app, text it does not
finish reading within 30 s, the two `\u0000` cases in spec section 6), stops
the run with the session and the journal kept. An edited journal replaces
`state.json` only when it loads as the app loads it and keeps every `Float`
the app decodes bit for bit. The app is not
sandboxed; local logs can contain SSIDs, process metadata, and tmux target names.
The lines the app writes to `insomnia.log` also reach the unified log with the
body marked private, so programs reading `log show` see `<private>` instead of
those names unless private data logging is enabled on the Mac. The files
Insomnia creates (logs, journal, session, config, recovery lock, session end
records) are mode 0600
and its directories 0700; the backstop runs with `umask 077`. Insomnia sets
only these modes and leaves any access control list (ACL) on these files as it
is, so an ACL someone added can still give another account access. Logs are capped at
1 MiB with one older copy kept. `insomnia.log` is rotated only while the app
holds the recovery lock, because it can hold the record of a session's end (a
line with session.json's bytes in base64), so it can grow past 1 MiB until
then. Insomnia's writers of `insomnia.log` (the app, the backstop and its
LaunchAgent) hold flock(2) on the file while they write, so no line of
theirs lands inside such a record. Any process running as that user can
hold that lock too: the app's lines then wait in memory (64 KiB),
the backstop's go to standard error, and no record of a session's end is
written there. A process that appends without the lock can still break a
record that was already read back. A log the user replaced with a symlink is not
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
a team id. Releases are ad-hoc signed, so both limits stay.

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

Release zips are built by the Release workflow from the tagged commit and
published with a `SHA256SUMS` file and a GitHub build provenance attestation.
Verify both before installing (`shasum -a 256 -c SHA256SUMS`,
`gh attestation verify <zip> -R krishhgg/Insomnia --signer-workflow
krishhgg/Insomnia/.github/workflows/release.yml --source-ref
refs/tags/v<version>`); `install.sh --app` then checks the signature,
identifier and version of a private copy of the bundle before asking for a
password, installs that copy, and refuses
it unless `--allow-unverified-origin` is given, because it cannot verify where
a bundle came from, whatever its signature names. The attestation shows which workflow run produced
the bytes, not that the code is free of defects. Releases are ad-hoc signed and
not notarized ([docs/releasing.md](docs/releasing.md)), so macOS blocks their
first launch.

Passing automated checks or a secret scan does not establish the absence of
vulnerabilities. Do not probe recovery by disrupting someone else's processes,
power settings, network, or data.
