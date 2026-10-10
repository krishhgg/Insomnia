# Releasing

How a downloadable Insomnia build is made, what signs it, and how to verify
one. The Release workflow (`.github/workflows/release.yml`) does the work;
this page is the checklist around it.

## Channels

| | Stable | Nightly |
| --- | --- | --- |
| Made by | pushing a tag `v<version>` | the daily schedule (07:17 UTC), or a manual run with the nightly input, on `main` |
| Tag | `v<version>`, pushed by the maintainer | `nightly-<YYYYMMDD>-<first 12 hex digits of the commit>`, created by the workflow |
| Zip | `Insomnia-<version>-macos.zip` | `Insomnia-<version>-nightly-<YYYYMMDD>-<commit>-macos.zip` |
| Title | `Insomnia <version> (stable)` | `Insomnia nightly <YYYY-MM-DD> (<commit>)` |
| GitHub marks | Latest, not a prerelease | Pre-release, never Latest |
| Attestation source ref | `refs/tags/v<version>` | `refs/heads/main` |

Both channels run the same tests, build, package, checksum and attestation
steps; they differ only in how the run starts, the names and the release
flags. Nobody chooses a nightly: it is whatever `main` held when the run
started.

`v0.1.0` is an exception to this table. It was packaged by hand from the
app installed on the maintainer's Mac and published as the first stable
release; no workflow built it. Its zip is `Insomnia-0.1.0-macos-arm64.zip`
with `scripts/install.sh`, `scripts/uninstall.sh` and `scripts/backstop.sh`
from the `v0.1.0` tag, it has no attestation, and its release notes give its
own checksum and install commands. Version 0.1.0 belongs to that release,
so the next stable release needs a new version in `Resources/Info.plist`.

## What a release contains

`Insomnia-<version>-macos.zip` (or the nightly name above) holds one folder
with `Insomnia.app`, `install.sh` and `uninstall.sh`. `SHA256SUMS` lists the
zip's SHA-256. Both files are attached to the GitHub Release, and the zip
carries a GitHub build provenance attestation that names the repository, the
ref, the commit and the workflow run that produced it.

The binary is arm64 only, because the build job runs on an Apple Silicon
runner and no universal build is made. A release therefore runs on Apple
Silicon Macs only: the release notes and the README say so, and
`install.sh --app` stops on a Mac where `sysctl -n hw.optional.arm64` does not
read 1.

The bundle is the one `scripts/build-app.sh` makes: the release binary,
`Resources/Info.plist`, the icon, and `backstop.sh` sealed under
`Contents/Resources` before signing. `install.sh` runs the same script for
a source install, so a downloaded app and a source-built app have the same
bundle layout and are both ad-hoc signed. Their contents can still differ,
because a source build may use another checkout, toolchain or architecture,
or `INSOMNIA_LID_SIMULATION=1`. The workflow sets `INSOMNIA_LID_SIMULATION`
empty, so a release never carries the `simulate-lid.sh` watcher.

The two scripts sit at the zip's top level, so the folder above theirs is
wherever the user unpacked it. They never take scripts from the folder
above their own (`ReleaseWorkflowTests` checks the ones the Package step
copies), and they take sibling scripts only from a source checkout's
`scripts/` folder with `Package.swift` one level up. The zip's folder is not
one, so its `install.sh` needs `--app`, and its `uninstall.sh` runs only the
`backstop.sh` sealed in the installed app, after verifying the app. A
`build-app.sh` or `backstop.sh` added to the unpacked folder is not run.

## Cutting a stable release

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the new
   version (and bump `CFBundleVersion`). Commit on main. `0.1.0` is taken
   (see Channels).
2. Tag that commit `v<version>`, the same digits, and push the tag:

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

   The workflow refuses a tag whose digits differ from the plist.
3. Watch the run. It runs `swift test`, builds and ad-hoc signs the bundle,
   packages it, attests the zip and creates the GitHub Release, marked
   Latest, with notes that include the checksum and the verify commands.
   `gh release create` fails if the tag already has a release, so a rerun
   never replaces published assets.
4. Download the zip from the release and check it the way a user would (see
   below), then install it with the command in the release notes
   (`./install.sh --allow-unverified-origin --app ./Insomnia.app`) on a Mac
   you can afford to reinstall on. Record the result in
   `docs/release-validation.md`.

A manual run (Actions, Release, Run workflow) with the nightly box left
unticked builds and packages the chosen branch and uploads the zip and
`SHA256SUMS` as a workflow artifact. It does not attest or publish anything,
so it is the way to try the pipeline.

## Nightly prereleases

The schedule runs the workflow on `main` once a day. A first job, with
read-only access, lists the repository's `nightly-*` tags and releases:

- If a nightly tag already names the head of `main` and has a release,
  nothing is built. A day without new commits publishes nothing.
- If such a tag exists without a release, the run fails and builds nothing,
  until `main` moves on. That happens only when an earlier run created the
  tag and then failed to create the release: rerun that run's failed jobs
  (the nightly job finds its own tag on the same commit and goes on), or
  delete the tag.
- If a nightly tag with this commit's first 12 hex digits points at another
  commit, the run fails.
- Otherwise it picks the tag `nightly-<today, UTC>-<commit>` and the run
  goes on to test, build and package that commit.

The publishing job creates the tag through the API call that fails when the
ref exists, so it never moves a tag, then creates the release with
`--prerelease --latest=false`. Scheduled and manual runs on `main` share one
concurrency group, so two runs never publish the same commit at once.

To publish a nightly now, start a manual run on `main` with the nightly box
ticked. The same checks apply, and a run on any other branch fails before
it builds.

GitHub disables scheduled workflows in a public repository after 60 days
without repository activity; the Release workflow then has to be enabled
again under Actions. The tags are not protected by a repository rule, so
someone with write access could still move or delete one by hand.

## Signing

Releases on both channels are ad-hoc signed and not notarized.
`build-app.sh` signs with `codesign --sign -`, so the workflow uses no
secrets and no keychain, and the signature identifies only that build (its
cdhash). The stable label is about the channel, not the signature: macOS
blocks the first launch of any downloaded release until the user allows it
in System Settings > Privacy & Security.

## Verifying a download

```bash
shasum -a 256 -c SHA256SUMS
gh attestation verify <zip> -R krishhgg/Insomnia \
  --signer-workflow krishhgg/Insomnia/.github/workflows/release.yml \
  --source-ref <ref> --source-digest <commit>
```

`<ref>` is `refs/tags/v<version>` for a stable release and `refs/heads/main`
for a nightly; `<commit>` is the full commit the release was built from. The
release notes carry the command filled in.

The first line checks the zip against the checksum published with it. The
second asks GitHub for the attestation signed when the workflow ran and
checks that this zip is its subject, that the signing workflow is this
repository's `release.yml` (`--signer-workflow`; with `-R` alone any workflow
of the repository would do), that it ran for that ref (`--source-ref`), so a
nightly built from `main` does not pass for a stable tag, and that it built
that commit (`--source-digest`). Together they show the bytes are what the
Release workflow built from that commit. They do not show the code is safe;
the README's warnings apply to every build. `v0.1.0` has no attestation; only
the checksum in its release notes covers it.

The `install.sh --app` in a workflow-built zip then copies the bundle into
a private temporary directory and checks that copy before the password
prompt: it runs
`codesign --verify --strict --deep` and checks the bundle identifier and
version. It installs that copy, not the path it was given, so a bundle
replaced at that path while the prompt waits is never installed. The copy it
puts in `~/Applications` is checked once more against the requirement the
recovery agent pins.

What is verified: the checksum shows the zip was not altered after
`SHA256SUMS` was written; the attestation shows this repository's Release
workflow built this exact zip from that ref and commit; `install.sh --app`
shows the bundle inside is intact (signature and resource seal), has the
expected identifier and a version, and carries the sealed backstop. What is
not: `install.sh` cannot tell a bundle from this repository apart from one
anyone else signed with the same identifier, and it does not take any
signature, ad-hoc or not, as proof of where a bundle came from. So it
refuses to install without `--allow-unverified-origin`, the flag that says
you ran the two commands above yourself. The release notes carry that flag
in the install command.

## What is not automated

The workflow does not install anything anywhere. The release validation
record is still written by hand after a real install. Nothing checks a
nightly beyond the workflow's `swift test`.
