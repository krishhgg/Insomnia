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
| `~/Library/Application Support/Insomnia/` | Configuration, the session/recovery journals, and lock files |
| `~/Library/LaunchAgents/com.insomnia.backstop.plist` | Per-user recovery agent: verifies the app's code signature, then runs the sealed `backstop.sh` |
| `~/Library/Logs/Insomnia/` | `insomnia.log` and `handoffs.log`, each capped at 1 MiB with one older copy kept as `.1`, unless you replace it with a symlink; `insomnia.log` can pass the cap for a while (see [Configuration and privacy](extras.md#configuration-and-privacy)). A session end record lands here only when the Application Support folder takes no new file, or, as a line in `insomnia.log`, when the recovery lock file takes no write either (see [How recovery works](recovery.md)) |
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

An upgrade asks the running app to quit and stops if it refuses. The new
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
Each call it makes to `sudo`, `pgrep`, `launchctl` or `codesign` while it
holds the lock has a 30 s limit, which a supervising process enforces even
if the installer is killed meanwhile. The call keeps the lock until it has
exited or been stopped, so no `launchctl bootout` it started is still
running once the lock is released. A call that does not answer in time gets SIGTERM, then SIGKILL
one to two seconds later, and the install stops, so the lock is released and the app
and the agent's backstop can take it again to undo a session. `sudo` only
ever gets SIGTERM: one that ignores it keeps the lock until it ends, and the
installer prints its pid.

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
rule. If recovery is incomplete or the app refuses to quit, it stops; resolve
the reported problem and retry. With the app it removes what an interrupted
install left beside it: `~/Applications/.Insomnia.app.previous`, and
`.Insomnia.app.staging.*` directories of installs that are no longer running.
Nothing else in `~/Applications` is touched. Purge removes owned files, not arbitrary
directory contents. A small shared lock file is retained to keep concurrent
recovery operations coordinated.
