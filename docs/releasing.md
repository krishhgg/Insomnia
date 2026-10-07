# Releasing

How a downloadable Insomnia build is made, what signs it, and how to verify
one. The Release workflow (`.github/workflows/release.yml`) does the work;
this page is the checklist around it.

## What a release contains

`Insomnia-<version>-macos.zip` holds one folder with `Insomnia.app`,
`install.sh` and `uninstall.sh`. `SHA256SUMS` lists the zip's SHA-256. Both
files are attached to the GitHub Release, and the zip carries a GitHub build
provenance attestation that names the repository, the tag and the workflow
run that produced it.

The binary is arm64 only, because the build job runs on an Apple Silicon
runner and no universal build is made. A release therefore runs on Apple
Silicon Macs only: the release notes and the README say so, and
`install.sh --app` stops on a Mac where `sysctl -n hw.optional.arm64` does not
read 1.

The bundle is the one `scripts/build-app.sh` makes: the release binary,
`Resources/Info.plist`, the icon, and `backstop.sh` sealed under
`Contents/Resources` before signing. `install.sh` builds the same bundle
for a source install, so a downloaded app and a source-built app differ
only in the signature. The workflow sets `INSOMNIA_LID_SIMULATION` empty, so
a release never carries the `simulate-lid.sh` watcher.

The two scripts sit at the zip's top level, so the folder above theirs is
wherever the user unpacked it. They never take scripts from the folder
above their own (`ReleaseWorkflowTests` checks the ones the Package step
copies), and they take sibling scripts only from a source checkout's
`scripts/` folder with `Package.swift` one level up. The zip's folder is not
one, so its `install.sh` needs `--app`, and its `uninstall.sh` runs only the
`backstop.sh` sealed in the installed app, after verifying the app. A
`build-app.sh` or `backstop.sh` added to the unpacked folder is not run.

## Cutting a release

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the new
   version (and bump `CFBundleVersion`). Commit on main.
2. Tag that commit `v<version>`, the same digits, and push the tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

   The workflow refuses a tag whose digits differ from the plist.
3. Watch the run. It runs `swift test`, builds and ad-hoc signs the bundle,
   packages it, attests the zip and creates the GitHub Release with notes
   that include the checksum and the verify commands.
4. Download the zip from the release and check it the way a user would (see
   below), then install it with the command in the release notes
   (`./install.sh --allow-unverified-origin --app ./Insomnia.app`) on a Mac
   you can afford to reinstall on. Record the result in
   `docs/release-validation.md`.

A manual run (Actions, Release, Run workflow) builds and packages the current
branch and uploads the zip and `SHA256SUMS` as a workflow artifact. It does
not attest or publish anything, so it is the way to try the pipeline.

## Signing

Releases are ad-hoc signed and not notarized. `build-app.sh` signs with
`codesign --sign -`, so the workflow uses no secrets and no keychain, and the
signature identifies only that build (its cdhash). The release is marked a
prerelease, and macOS blocks the first launch of the downloaded app until the
user allows it in System Settings > Privacy & Security.

## Verifying a download

```bash
shasum -a 256 -c SHA256SUMS
gh attestation verify Insomnia-<version>-macos.zip -R krishhgg/Insomnia \
  --signer-workflow krishhgg/Insomnia/.github/workflows/release.yml \
  --source-ref refs/tags/v<version>
```

The first line checks the zip against the checksum published with it. The
second asks GitHub for the attestation signed when the workflow ran and
checks that this zip is its subject, that the signing workflow is this
repository's `release.yml` (`--signer-workflow`; with `-R` alone any workflow
of the repository would do) and that it ran for the tag (`--source-ref`).
Together they show the bytes are what the Release workflow built from the
tagged commit. They do not show the code is safe; the README's warnings
apply to every build.

`install.sh --app` then copies the bundle into a private temporary
directory and checks that copy before the password prompt: it runs
`codesign --verify --strict --deep` and checks the bundle identifier and
version. It installs that copy, not the path it was given, so a bundle
replaced at that path while the prompt waits is never installed. The copy it
puts in `~/Applications` is checked once more against the requirement the
recovery agent pins.

What is verified: the checksum shows the zip was not altered after
`SHA256SUMS` was written; the attestation shows this repository's Release
workflow built this exact zip from the tag; `install.sh --app` shows the
bundle inside is intact (signature and resource seal), has the expected
identifier and a version, and carries the sealed backstop. What is not:
`install.sh` cannot tell a bundle from this repository apart from one anyone
else signed with the same identifier, and it does not take any signature,
ad-hoc or not, as proof of where a bundle came from. So it refuses to install
without `--allow-unverified-origin`, the flag that says you ran the two
commands above yourself. The release notes carry that flag in the install command.

## What is not automated

The workflow does not install anything anywhere. The release validation
record is still written by hand after a real install.
