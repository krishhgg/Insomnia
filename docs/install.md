# Install, upgrade and uninstall

The [README](../README.md#install) has the short version. This page has every
step and what each one checks. A coding agent can follow
[skills/install-insomnia](../skills/install-insomnia/SKILL.md), which uses the
steps on this page.

Requires **macOS 26 or later on an Apple Silicon Mac**.

## Channels

Insomnia is published on two channels on the
[releases page](https://github.com/krishhgg/Insomnia/releases):

- Stable: the release GitHub marks Latest, tagged `v<version>`. Use this one
  unless you want to try changes that are not in a stable release yet.
- Nightly: prereleases tagged `nightly-<date>-<commit>`, built automatically
  from `main` once a day when it has new commits. Newest code, experimental,
  and possibly broken. A nightly is never marked Latest.

## v0.1.0 is different

Each release's notes give the exact commands for that release. One release
differs from the steps below: `v0.1.0`, the first stable release, was packaged
by hand from the maintainer's installed app, not by the Release workflow. It
has no attestation, and its zip installs with
`./scripts/install.sh --app ./Insomnia.app`. If the release you picked is
`v0.1.0` (its zip is `Insomnia-0.1.0-macos-arm64.zip`), follow the install
steps in its release notes instead of steps 2 and 3.

The rest of this page describes releases built by the Release workflow and
builds of the current source, not `v0.1.0`. The `README.md` in the `v0.1.0`
zip describes what that release installs, how its recovery works and its
limits. In particular, the installer's version check, the recovery script
sealed inside the app and the code requirement the recovery agent pins,
described below, are not in `v0.1.0`.

## Install a release yourself

You need `gh`, the [GitHub CLI](https://cli.github.com).

1. Download the zip and `SHA256SUMS` of the release you chose into an empty
   folder, from the releases page or with `gh`. For the stable release, the
   one marked Latest:

   ```bash
   gh release download --repo krishhgg/Insomnia --pattern '*.zip' --pattern SHA256SUMS
   ```

   For the newest nightly, paste this whole block. It reads every page of
   the release list and picks the most recently published nightly. It
   downloads nothing, and returns an error, when it cannot read the list,
   when no nightly has been published yet, or when the tag it picked is not
   in the `nightly-<YYYYMMDD>-<12-character commit>` form. It never falls
   back to the stable release.

   ```bash
   insomnia_nightly() {
     local list tag
     list="$(gh api --paginate 'repos/krishhgg/Insomnia/releases?per_page=100' \
       --jq '.[] | select(.prerelease and (.draft | not) and (.tag_name | startswith("nightly-")))
         | "\(.published_at) \(.tag_name)"')" ||
       { echo "Could not read the release list. Nothing was downloaded." >&2; return 1; }
     tag="$(printf '%s\n' "$list" | sort | tail -n 1)"
     tag="${tag#* }"
     if [ -z "$tag" ]; then
       echo "No nightly has been published yet. Nothing was downloaded." >&2
       echo "Wait for the next daily build, or build from source." >&2
       return 1
     fi
     if ! printf '%s\n' "$tag" | grep -Eqx 'nightly-[0-9]{8}-[0-9a-f]{12}'; then
       printf 'Unexpected nightly tag: %s. Nothing was downloaded.\n' "$tag" >&2
       return 1
     fi
     gh release download "$tag" --repo krishhgg/Insomnia --pattern '*.zip' --pattern SHA256SUMS
   }
   insomnia_nightly
   ```

   If the releases page has no release yet, build from source (below).
2. Verify the download. `<zip>` is the zip's file name. `<ref>` is
   `refs/tags/v<version>` for a stable release or `refs/heads/main` for a
   nightly. `<commit>` is the full 40-character commit the release was built
   from: its release notes name it after "Built from" and carry this command
   filled in. A nightly's tag ends with the first 12 characters of it.

   ```bash
   shasum -a 256 -c SHA256SUMS
   gh attestation verify <zip> -R krishhgg/Insomnia \
     --signer-workflow krishhgg/Insomnia/.github/workflows/release.yml \
     --source-ref <ref> --source-digest <commit>
   ```

   The first command checks the zip against the `SHA256SUMS` downloaded with
   it. The second checks that this repository's Release workflow built this
   exact zip from that commit for that ref, so a nightly cannot pass for a
   stable release. Every nightly is built for `refs/heads/main`, so only
   `--source-digest` keeps another nightly's zip from passing: do not leave
   it out, and do not shorten the commit to the 12 characters in the tag.

3. Unzip and run the installer that comes in the zip:

   ```bash
   ditto -x -k <zip> .
   cd <the zip's name without .zip>
   ./install.sh --allow-unverified-origin --app ./Insomnia.app
   open "$HOME/Applications/Insomnia.app"
   ```

   Releases are ad-hoc signed and not notarized. The installer can check that
   the bundle is intact but not who made it, so it refuses to install without
   `--allow-unverified-origin`, which says you ran the two commands in step 2.
   macOS blocks the first launch of a downloaded copy until you allow it in
   System Settings > Privacy & Security.

The installer checks the bundle's signature, identifier and version before it
asks for anything (the `v0.1.0` installer checks the signature and
identifier, not the version). It then installs the app and a background recovery agent,
and asks for administrator access to install a narrowly scoped sudoers rule. It grants
**your user account**, not just Insomnia, passwordless access to four
power-setting commands. Review that permission before installing.

Release zips are built for arm64 only, and their `install.sh --app` stops on
an Intel Mac. On Intel, building from source (below) is the only option, and
it is untested there.

## Build from source

Requires **Xcode with Swift 6.2 or later**. Clone the latest stable tag, or a
nightly tag for the newest code, rather than `main`. If the releases page has
no release yet, leave out `--branch v<version>` to build `main`:

```bash
git clone --branch v<version> --depth 1 https://github.com/krishhgg/Insomnia.git
cd Insomnia
./scripts/install.sh
open "$HOME/Applications/Insomnia.app"
```

`scripts/install.sh` builds the same bundle the release workflow builds
(`scripts/build-app.sh`), ad-hoc signed, and installs it the same way. It
builds only when it runs from a checkout's `scripts` folder, with
`Package.swift` one level up, and then runs the `build-app.sh` beside it. The
`install.sh` from a release zip stops and asks for `--app` instead, even when
a `build-app.sh` was added to its folder after unpacking. A checkout of
`v0.1.0` has the installer of that release; its README describes it.
[docs/releasing.md](releasing.md) describes the release pipeline.

## What gets installed

This describes releases built by the Release workflow and builds of the
current source. `v0.1.0` installs an older layout. Its app has no
`backstop.sh` inside it: its installer copies `backstop.sh` into
`~/Library/Application Support/Insomnia/`, and its recovery agent runs that
copy with `/bin/bash` without checking any code signature. The sealed script,
the pinned code requirement and the refusal of an edited or re-signed bundle
described below do not apply to it, and neither does the upgrade procedure.
Its sudoers rule grants the same four commands. The `README.md` in its zip
describes what it installs and its limits.

| Location | Purpose |
| --- | --- |
| `~/Applications/Insomnia.app` | The menu bar app, with `backstop.sh` sealed inside it at `Contents/Resources` |
| `~/Library/Application Support/Insomnia/` | Configuration and the session/recovery journals |
| `~/Library/LaunchAgents/com.insomnia.backstop.plist` | Per-user recovery agent: verifies the app's code signature, then runs the sealed `backstop.sh` |
| `~/Library/Logs/Insomnia/` | `insomnia.log` and `handoffs.log`, each capped at 1 MiB with one older copy kept as `.1`, unless you replace it with a symlink |
| `/etc/sudoers.d/insomnia` | Permission for the four commands below |

```text
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -b lowpowermode 1
/usr/bin/pmset -b lowpowermode 0
```

The grant is available to other processes running as your user. Insomnia is not
sandboxed. The app, scripts, and journals are local; hotspot passwords use the
login Keychain, not the configuration file.

The rule is one file for the whole Mac and grants one account. The installer
reads it first and stops, changing nothing, when it has a line for another
account. A rule your account can read is read without sudo, with a 30 s
limit, and judged before the password prompt. One only root can read (the
rule the installer writes is root's, mode 0440) is read with `sudo -n cat`
right after the one password prompt (`sudo -v`). A rule that cannot be read
in full stops the install too. It then writes the rule in one `sudo
/bin/bash -c` call.
That root shell takes a lock file in the rule's own folder,
`/etc/sudoers.d/.insomnia-sudoers.lock` (sudo skips a name with a dot).
Before opening it, root checks that every folder above it is root's and
writable only by root, that the file, if it is there, is a regular file of
root's with mode 0600 and one link, and that no access control list (ACL)
on those folders or on the file allows more than reading. After locking it,
root checks that the descriptor and the path are still that same file. The
lock file is created only where nothing is, and is never repaired, replaced
or removed: one that fails a check stops the run and is left for you to look
at. Root then checks the rule the same way, opens it, and checks that its
exact text is the text the run read and judged (passed to root as an
argument, not read again from a file). It has `visudo` check a new copy
beside it. Just before it puts that copy in place, root checks the folders,
the lock file and their ACLs again and reads the rule a second time through
a new descriptor. It renames the copy over the rule only when that read
completes, finds no NUL byte, and gives the same bytes from the same file.
Where no rule was, it gives the copy the rule's name with `/bin/link`,
which fails when anything has that name, and then removes the copy's own
name; if that removal fails, the install goes on and names the copy to
remove with `sudo rm`, since both scripts refuse a rule with two names. The
uninstaller checks the rule the same way, under the same lock,
then renames it to a name with a dot beside it, which sudo does not read,
and reads it there once more. It removes it only when it is still the same
file with the same bytes; otherwise it links the file back under the rule's
name. So when two accounts run these scripts at once, neither overwrites or
removes a rule the other wrote after its read: the run that finds the rule
changed stops, and asks you to rerun it.

The ACL check reads each list with `/usr/bin/perl`, which loads no module
and makes one `fgetattrlist` system call on a descriptor it opens itself
(never following a link). The same answer gives the file's type, device and
file ID, which must match root's `stat` of that path just before, so the
list judged is the list of the file root checked. The answer must be whole:
its length, the list's size and its entry count must agree, and every entry
must be an allow, deny, audit or alarm entry with only flags the check
knows. Each entry names its principal by UUID. An allow entry with any
right beyond `read` (`list` on a folder), `execute` (`search`), `readattr`,
`readextattr`, `readsecurity`, `synchronize`, generic read or generic
execute (inheritance flags aside) stops the run unless `dsmemberutil` shows
that its UUID is root's own user record: the UUID it gives for user ID 0 is
that UUID, and the ID it gives for that UUID is `uid: 0`. An entry for a
group (`wheel`, `admin`, `everyone`), for another user, or one a management
profile added under its own UUID stops the run, even though it may be
harmless. An entry that only denies passes. A file perl cannot open, a call
that fails, an answer for another file or one the check cannot account for
byte for byte, perl output other than its one form ending in the count of
files checked, and a `dsmemberutil` answer that is not exactly that one
line, stop the run too. Neither script removes or changes an ACL: the
message names the path and the entry, and you decide whether to remove it
before you rerun. On the Mac these scripts were tested on, `/`, `/private`,
`/private/etc` and `/private/etc/sudoers.d` carry none. The call and the
layout of its answer are macOS's own (system call 228, `fgetattrlist`); a
Mac without `/usr/bin/perl`, or one whose kernel answers in another layout,
stops every install and uninstall at that check, before the rule changes.

The lock keeps out only the runs that take it. Installers and uninstallers
of earlier releases take no lock, or an older one, and neither does an
administrator's own `sudo`. Against those, an upgrade's second read narrows
the gap but does not close it: a writer that takes no lock can still change
the rule between that read and the rename, and no check of the file's
identity or bytes can see that. A fresh install's link never overwrites a
rule made meanwhile. The uninstaller's last read comes after its rename, so
a change made before the rename is put back; what stays open there is a
write through a descriptor opened before the rename that lands after that
read, which is removed with the rule. A changed rule is out of sudo's
reading from the rename until it is linked back, and stays under the dotted
name when something has taken the rule's name meanwhile (the message names
the file). A root shell killed outright after the rename or the link leaves a
dotted name sudo does not read: the rule itself, or a second name for it,
which both scripts refuse (one link) until you remove it. A rule that
changed between root's reads, or that root cannot read in full, is kept,
and the run asks you to rerun it, so a writer that keeps changing the rule
keeps every run from changing it. A root call that is killed or does not answer in time leaves it
unknown whether the rule changed, and the script says so instead of claiming
nothing changed. The root shell needs sudo to allow `/bin/bash`, as it does
for an administrator by default; an account whose sudo policy allows only
listed commands cannot install this way.

The recovery agent runs at login and every 60 seconds. Its command line pins
the installed bundle's code requirement (for an ad-hoc build, the cdhash of
that build) and runs `codesign --verify --strict` against it before executing
the `backstop.sh` sealed inside the bundle. An edited bundle or script fails
that check: the agent writes one line to `insomnia.log` and runs nothing until
you reinstall. So no other account can edit it, the installer removes group
and other write permission and every ACL from the bundle it installs. The
signature covers neither, so the bundle still verifies, and extended
attributes such as a download's quarantine flag are kept. No executable is
kept in a writable support directory. The plist in `~/Library/LaunchAgents`
is still a per-user file that any program running as you can edit, like
every LaunchAgent; the app rewrites it at the next session start when it does
not match, which is a repair, not a tamper check.

What the app pins is the requirement of the code it is itself running, read
through the Security framework after checking that the bundle on disk is still
that code and still passes the agent's check. A bundle whose sealed script was
edited, or that was re-signed under the running app, is refused rather than
pinned: the app does not start a session, or reports the end as incomplete,
and names the reason, until you reinstall. With ad-hoc signatures this guards
against accidental edits and against the app relaying a tampered bundle into
the agent, not against a process running as you: that process can edit the
plist, load its own agent, quit the app and launch a replacement, and run the
four `pmset` commands itself.

## Upgrades

An upgrade asks the running app to quit and stops if it refuses. A process
is matched by its executable path (the installed bundle) or by its bundle id,
not by its name, so the Insomnia API client (`com.insomnia.app`), whose
executable is also named Insomnia, is reported and left alone. A process named
Insomnia with any other bundle id, or one that cannot be read, counts as this
app and blocks the upgrade until it exits; it is never asked to quit. Once
the installer holds the recovery lock, its process check reads no
Info.plist: a process it first sees then counts as unverified and blocks. A
copy running in another account, or a process there that cannot be told
apart from one, stops the install before the sudoers rule is replaced, since
that copy may need the rule; it is named and never asked to quit. So does a
process whose owner `ps -o uid=` cannot tell (it fails, does not answer, or
prints no user ID): the installer looks once more and, if the owner is still
unknown, stops before its first `sudo` call, the password prompt included.
Only a process positively identified as the API client is ignored. A
`pgrep` that fails or does not answer stops it there too. A refusal names
the pid and executable path it found. The new
bundle is built in a staging directory next to the app and moved into place in
the same step that replaces the recovery agent. That step starts only after
`launchctl print` confirms the previous agent is unloaded; otherwise nothing is
replaced. If the new agent cannot be loaded, or its plist cannot be saved, the
installer unloads it, waits for `launchctl print` to confirm that, and puts the
previous bundle back, so the loaded agent always matches the installed app. A
bundle that cannot be moved during that step is handled the same way: the
previous bundle goes back and its agent is loaded again. If the previous bundle
itself cannot be moved back, nothing is deleted: it stays at
`~/Applications/.Insomnia.app.previous`, the installer prints the two commands
that put it back and load its agent, and until then the agent finds no app, so
run them or rerun the installer before you log out. If
the unload is not confirmed, the new bundle stays with the agent that pins it
and the installer asks you to rerun it. After that, or after an install killed
in the middle of that step, the next run keeps whichever bundle the agent's
plist on disk pins. It does that only after its own recovery step succeeds:
while recovery is unresolved, an agent the earlier run left loaded may be the
one retrying it, so the installer stops without unloading that agent or
moving either bundle. Once recovery succeeds, it unloads that agent, moves the
bundle back and loads the plist on disk again, and it stops if `launchctl
print` does not confirm the unload or the reload. Unresolved recovery prevents
replacing either; follow the reported instructions before retrying. The
installer checks the sudoers rule again once it holds the recovery lock, and
stops if the rule is gone, as after an `uninstall.sh` that took the lock first.
Before the lock, its other steps that touch the disk or ask the system have
a 30 s limit too: its private folders, the copy and the signature checks of
the new bundle, the copy of the new rule, the support folders, and the open
and lock of the lock file. A read that does not answer is stopped as below.
A copy, folder or lock step that does not finish is never signalled: the
install stops there, says what it had installed so far, leaves its private
folders in place, and asks you to rerun it once that step has ended. The
quit request has the same limit, and the wait for the app to exit follows
it as before. The source build and the password prompt have no limit, and
neither does root's change of the sudoers rule, a `sudo` that may prompt
too: only its wait for the rule's lock is limited, to 10 s.
Each call it makes to `sudo`, `pgrep`, `ps`, `plutil`, `launchctl` or
`codesign` while it holds the lock has a 30 s limit, which a supervising
process enforces even if the installer is killed meanwhile. The call keeps
the lock until it has exited or been stopped, so no `launchctl bootout` it
started is still running once the lock is released. A call that does not
answer in time gets SIGTERM, then SIGKILL one to two seconds later, and the
install stops. Once that call has ended the lock is free, and the app and
the agent's backstop can take it again to undo a session. A read that fails or does not answer is
never taken as a clean answer. `sudo` only ever gets SIGTERM: one that
ignores it keeps the lock until it ends, and the installer prints its pid.
The `backstop.sh` the installer runs under the lock to end a stale session
has a 300 s limit of its own. At the limit it gets SIGTERM only, never
SIGKILL, since it may be running `sudo pmset`. Each `sudo pmset` or app
binary call it started keeps the lock through its own supervisor until that
call has exited, even if the backstop or the installer is killed first. A
`sudo pmset` also has a keeper, a second process that holds the lock until
its supervisor says the call has been reaped or, if a SIGKILL ended the
supervisor, until no process has the call's pid, so a SIGKILL to the
supervisor alone does not free the lock either. The backstop's own call
has a keeper too, which also waits until nothing is left in the
backstop's process group. A signal that ends both does. When launchd runs the backstop, both are in the job's process group,
which launchd signals once the backstop has exited; which signal it sends
was not measured. The
backstop leads a process group of its own, which everything it starts stays
in unless it leaves it, so closing the Terminal window does not reach them:
the backstop runs to its end or its limit with the lock held, and the
SIGTERM at the limit goes to the backstop process alone. A backstop still
running three seconds after its SIGTERM keeps the lock until it ends, and
so does a process it started that is still in its group once it has ended.
The installer then stops, prints the backstop's pid and replaces nothing.
Without `/usr/bin/perl` the installer stops at its sudoers step, whose
access control list check needs perl, before it reaches the backstop. The
backstop step would refuse too, since perl starts that group and checks
whether it is empty.
The backstop reads no Info.plist under the lock. The installer reads
`InsomniaResumeFrozenVersion` and the file's identity before it takes the
lock (from the bundle an interrupted install set aside, when that bundle is
the one that goes back), and the backstop uses the version only while a
`stat` under the lock shows the same file unchanged. Otherwise it keeps any
frozen process that only the app binary can resume, and the install stops
after it. Each of the backstop's reads of the journal has a 30 s limit, and
one that fails, is cut short or does not answer stops its run with the
journal kept.

## Uninstall

From your checkout:

```bash
./scripts/uninstall.sh
# Also remove Insomnia-owned configuration and logs:
./scripts/uninstall.sh --purge
```

From the unpacked release zip, run `./uninstall.sh` (or `./uninstall.sh
--purge`) in its folder (`Insomnia-<version>-macos`, or the nightly name). A
checkout's uninstaller (in `scripts`, with `Package.swift` one level up) runs
the `backstop.sh` beside it. Anywhere else, such as the zip's folder, the
uninstaller runs only the copy sealed in the installed app, after `codesign
--verify --strict` passes on the app, and stops without removing anything
when there is none. The zip has no `backstop.sh`, so one added beside its
uninstaller is not run. Neither looks in the folder above its own.

The `v0.1.0` zip is different: run `./scripts/uninstall.sh` in its unpacked
`Insomnia-0.1.0-macos-arm64` folder, as its release notes say. That older
uninstaller runs the `scripts/backstop.sh` in the same folder.

The uninstaller requests cleanup before removing the app, agent, and sudoers
rule. If recovery is incomplete or the app refuses to quit, it stops and names
the pid and executable path of the copy still running; resolve the reported
problem and retry. The Insomnia API client (`com.insomnia.app`) is reported and
left alone. A process named Insomnia with any other bundle id, or whose bundle
id cannot be read, or whose Info.plist does not answer within the
uninstaller's time limit for a call, blocks the uninstall until it exits.
A `pgrep` that fails or does not answer stops the uninstall before anything
is removed, and so does a copy running in another account, which is never
asked to quit. So does a process whose owner `ps -o uid=` cannot tell, or
whose identity cannot be read, once a second look still finds it: the
uninstaller then stops before its first `sudo` call. That holds when this
app's own copy runs beside such a process too: the uninstaller looks for
that process alone again, once a second for up to 10 s, before it judges
the rule or asks the app to quit, and does not wait for its own copy,
which has not been asked to quit yet. A process that first shows up after
those looks is still waited for after the quit and blocks the removal, but
by then the password may have been asked for. Only a process positively
identified as the API client is ignored.

Before it takes the recovery lock, the uninstaller reads the installed app's
`InsomniaResumeFrozenVersion` with the same time limit, and the Info.plist's
identity (device, inode, change time, size) before and after the read. From
a checkout, a read that fails or does not answer, or a file that changed,
stops it before any `backstop.sh` runs or anything is removed. From the zip
it goes on: the sealed backstop then keeps any frozen process that only the
app binary can resume, and the uninstall stops before removing anything. It
asks for your password (`sudo -v`) before the lock as well, so every `sudo`
call under the lock is `sudo -n` with the 30 s limit. Its private folder,
the `id` reads of your account, the support folder, and the open and lock
of the lock file have the 30 s limit too, and one that does not finish
stops the uninstall with nothing removed. A folder or lock step is never
signalled; rerun the uninstaller once it has ended. The quit request has
the same limit, and the wait for the app to exit follows it as before. Once it holds the
lock, no Info.plist is read: its own process check counts a process it
first sees then as unverified and blocks, and the `backstop.sh` it runs gets
the version and the identity in its environment and uses the version only
while a `stat` under the lock (which reads no contents) shows the same file
unchanged. That backstop run has a 300 s limit and gets SIGTERM only
at the limit: a backstop still running three seconds after its SIGTERM
keeps the lock until it ends, and so does a process it started that is
still in its process group once it has ended. The uninstaller then stops,
names the backstop's pid and removes nothing. The backstop leads a process
group of its own, which everything it starts stays in unless it leaves it,
so closing the Terminal window does not reach them: the backstop runs to
its end or its limit with the lock held, and the SIGTERM at the limit goes
to the backstop process alone. So a `sudo pmset` started by a backstop from
this build or an earlier one keeps the lock until that sudo has ended, even
after the uninstaller or the backstop is gone. That includes the oldest
copies in Application Support, which take no lock and run `sudo pmset` in
the foreground: once the SIGTERM at the limit has ended such a copy, the
uninstaller's supervisor keeps the lock until nothing is left in its group,
and so does that supervisor's keeper if a SIGKILL ends the supervisor first.
A process that leaves the group (with `setsid`, say) is not waited for.
Without `/usr/bin/perl`, which starts that group and checks whether it is
empty, the uninstaller runs no backstop, says so, and goes on to its own
journal check. A
backstop sealed in a bundle from an earlier release does
not know these variables. It reads the Info.plist and the journal itself,
with no limit on each read, though the 300 s limit on its run still applies.
A journal check whose read fails, is cut short, prints a NUL byte or does not
answer counts as a problem, never as a clean journal, and stops the
uninstall before anything is removed. A session.json still there after the
backstop stops it too, whether or not it can be read. If the later read for
a brightness Insomnia kept fails, the journal is kept.

The sudoers rule is one file for the whole Mac and names the account whose
install wrote it. Before it asks the app to quit, the uninstaller reads the
rule and stops, removing nothing, when it has a line for another account,
since that account's agent may need it to undo a session. A rule your
account can read is read without sudo, with the 30 s limit, and judged
before the password prompt; one only root can read is read with `sudo -n
cat` right after it. So for a rule your account can read, the password is
asked after the app has quit. For the usual rule, which only root can read,
it is asked before the app is asked to quit, and an app that then refuses
to quit stops the uninstall after the prompt. A rule that cannot be read in
full stops the uninstall as well. Under the recovery lock it reads the rule through sudo again and
removes it only when it is exactly the rule the installer writes for your
account; otherwise it keeps the file and says why. It removes the rule only if root, under the
lock the installer takes for its write, finds the text it read, and then,
just before it renames the rule out of sudo's reading, finds the folders,
the lock file and every ACL still as they must be and reads the same bytes
from the same file again, and then once more under the new name.
If the rule changed meanwhile, root cannot read it in full, an ACL allows
more than reading, or another run holds that lock for 10 s, the uninstaller
keeps the rule and the app, and asks you to rerun it. If the rule is out of
sudo's reading but removing it under its dotted name fails, the uninstaller
names that file, which grants nothing, and goes on. If the
root call that removes it fails in an unknown way or does not answer, the
uninstaller keeps the app and the recovery journal too, since whether the
rule is gone is not known; a `sudo` that ignores SIGTERM keeps the recovery
lock until it ends, and the uninstaller prints its pid. With the app it removes what an interrupted
install left beside it: `~/Applications/.Insomnia.app.previous`, and
`.Insomnia.app.staging.*` directories of installs that are no longer running.
Nothing else in `~/Applications` is touched. Purge removes owned files, not arbitrary
directory contents. A small shared lock file is retained to keep concurrent
recovery operations coordinated.
