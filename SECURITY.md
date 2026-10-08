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
lock and after the nonce and deadline checks, the root command asks sudo
whether the session's end will be able to turn sleep back on without a
password, and writes nothing until it has the answer. Root drops to the
user who pressed Start (`sudo -n -u "#<uid>"`: sudo never asks root for a
password, and macOS's default `root ALL = (ALL) ALL` permits it), empties
the environment with `/usr/bin/env -i LC_ALL=C`, and runs that user's
`/usr/bin/sudo` three times, with stdin from /dev/null:

- `sudo -V` must show sudo 1.9.15 or later with the sudoers policy plugin
  and no plugins but sudoers' own I/O and audit plugins. The listing below
  is read in the format those versions print.
- `sudo -k -n -l` must list the user's rules without a password and show
  no Runas or command-specific Defaults (`Defaults>user`,
  `Defaults!command`): those apply when the restore runs but not to a
  listing, so they could make the restore differ from what the listing
  shows.
- `sudo -k -n -ll /usr/bin/pmset -a disablesleep 0` must print exactly the
  rule install.sh writes, in six lines: `Sudoers entry:` naming
  /etc/sudoers.d/insomnia (as /private/etc or /etc), `RunAsUsers: root`,
  `Options: !authenticate` (NOPASSWD and no other tag), the restore as the
  only command, and `Matched:` the restore. Given a command, sudo prints
  the rule that decides it, the last one that matches, so a later rule
  that asks for a password, denies the command, or runs it as anyone else
  is the one shown, and it refuses.

`-k` ignores a credential cached by a recent sudo, and `-n` fails instead
of prompting. None of the three runs a command, and none is `sudo -l` alone,
`sudo -v`, an exit status read alone, or a search for NOPASSWD: the admin
group's `(ALL) ALL` lists commands the user may run with a password, and a
listing passes without one whenever any of the user's entries is
passwordless. A query that fails, prints anything else, is cut short, or
asks for a password (a `listpw` setting that wants one) exits 5. The clock
is then compared with the session's end (exit 4), the command reads `pmset
-g` (exit 6 on a SleepDisabled 1 or a failed read; it reads nothing only
when the journal claimed the 1 before this start), compares the clock again
right before the write (exit 4), and only then runs `pmset -a disablesleep
1`, its only write, which the start journaled before the dialog. A session
end reached during any of these calls, at its very second or later, stops
the write. If pmset fails, the command exits 1 and the start is undone like
an end. The command ignores SIGPIPE, so a refusal keeps its own status when
the dialog's output is already gone. Exits 3 to 6, and lockf's 69 and 75,
leave nothing changed by the command, and roll the start back with nothing
to undo: no session, the journal and session.json as they were, no pmset,
and for exit 5 a message to rerun the installer. That happens without the
rule (an uninstall that stopped part way, a hand-deleted file), on a Mac
whose sudoers lacks root's default entry, and with any sudo or sudoers
setting the check cannot read, even one under which the restore would
run. No query has its own time limit: one that hangs is bounded by the
dialog's 120 s limit, after which the start waits for the command to exit
and undoes it, and a session end that passed meanwhile stops the write.
The user has typed the password by the time a refusal is reported.

What this design does not close. pmset has no compare-and-set and one
SleepDisabled value with no owner, so no read is atomic with the write
after it, and a 1 another tool writes over a 1 already in effect leaves no
trace. A SleepDisabled 1 another tool sets in the instant between the root
command's read and its `disablesleep 1` (the time pmset takes to start)
cannot be told from Insomnia's, and the session's end sets it to 0. One set
during the session is set to 0 by the session's end. One set while a
dialog is up that then fails in a way that may have left `disablesleep 1`
in place (a wrong password, a timeout, a pmset failure, an exit status lost
to a signal or a crash) is set to 0 by that start's undo. One set while a
dialog is up when Insomnia quits or crashes before the answer is taken for
Insomnia's own, because the journal already holds the start's entry, and
the session's end or the backstop sets it to 0. While the journal claims a
1 from an earlier session, another tool's 1 is taken for it, and a refused
start leaves that 1 in place with its restore still owed. sudo answers for
the moment it is asked: a rule removed later, a log sudo cannot write when
the restore runs, or other groups for the user when the app or backstop.sh
runs sudo than when root switched to that user, can still make a later
restore fail, and backstop.sh then keeps the journal entry and retries. A
sudo outside 1.9.15 to 1.9.x, or with other plugins, refuses every Start,
and so do Defaults bound to a user or a command, `listpw` set to always,
and a later rule for the restore, even a passwordless one. Closing these
needs a sleep assertion owned by a process, or a pmset that compares
before it sets, which this design does not have.

The installer runs no pmset: right after writing the rule it confirms that `sudo -k -n -l` lists the
three commands without a password, which catches a rule sudo does not read
but is not proof that the restore runs, because the listing passes once any
of the user's rules is passwordless. At every Start the root command's
`sudo -k -n -ll` reads the rule that decides the restore. A file that
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
the app, and invoke the three pmset commands of the sudoers rule directly.

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
