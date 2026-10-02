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

The bundle is the one `scripts/build-app.sh` makes: the release binary,
`Resources/Info.plist`, the icon, and `backstop.sh` sealed under
`Contents/Resources` before signing. `install.sh` builds the same bundle
for a source install, so a downloaded app and a source-built app differ
only in the signature.

## Cutting a release

1. Set `CFBundleShortVersionString` in `Resources/Info.plist` to the new
   version (and bump `CFBundleVersion`). Commit on main.
2. Tag that commit `v<version>`, the same digits, and push the tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

   The workflow refuses a tag whose digits differ from the plist.
3. Watch the run. It runs `swift test`, builds and signs the bundle, packages
   it, attests the zip and creates the GitHub Release with notes that include
   the checksum and the verify commands.
4. Download the zip from the release and check it the way a user would (see
   below), then install it with the command in the release notes
   (`./install.sh --app ./Insomnia.app`, with `--allow-unverified-origin`
   while `EXPECTED_TEAM_ID` is empty) on a Mac you can afford to reinstall
   on. Record the result in `docs/release-validation.md`.

A manual run (Actions, Release, Run workflow) builds and packages the current
branch and uploads the zip and `SHA256SUMS` as a workflow artifact. It does
not attest or publish anything, so it is the way to try the pipeline.

## Signing and notarization

Signing is decided by the repository secrets. Either all six exist or none:
the first step of the workflow fails the run when the signing secrets exist
without the notary secrets or the reverse, or when a set is incomplete. A
Developer ID build that is not notarized is blocked by Gatekeeper and refused
by `install.sh --app`, so it is never published.

| Secret | What it is |
| --- | --- |
| `INSOMNIA_SIGN_P12_BASE64` | The Developer ID Application certificate with its private key, exported from Keychain Access as a `.p12`, then `base64 -i cert.p12` |
| `INSOMNIA_SIGN_P12_PASSWORD` | The password chosen at export |
| `INSOMNIA_SIGN_IDENTITY` | The identity's name as `security find-identity -v -p codesigning` prints it, for example `Developer ID Application: Name (TEAMID)` |
| `INSOMNIA_NOTARY_KEY_BASE64` | An App Store Connect API key (`.p8`) with the Developer role, `base64 -i AuthKey_XXXX.p8` |
| `INSOMNIA_NOTARY_KEY_ID` | That key's ID |
| `INSOMNIA_NOTARY_ISSUER_ID` | The issuer ID shown with the key |

With the three signing secrets, `build-app.sh` signs with that identity, the
hardened runtime and a secure timestamp. The certificate is imported into a
keychain created for the run and deleted at the end; it never enters the
login keychain. With the three notary secrets as well, the workflow submits
the app with `notarytool --wait`, staples the ticket and checks `spctl`.

Without the secrets the bundle is ad-hoc signed. The release is then marked
a prerelease and its notes say it is experimental: macOS blocks the first
launch of a downloaded ad-hoc app until the user allows it in System
Settings.

Once a Developer ID is in use, put its Team ID in `EXPECTED_TEAM_ID` in
`scripts/install.sh`. From then on `install.sh --app` treats a Developer ID
bundle from that team, with Gatekeeper's verdict, as verified in origin,
installs it without any flag, and refuses one from any other team. The
workflow fails a release signed by a team other than `EXPECTED_TEAM_ID`,
since the `install.sh` in its own zip would refuse it. While it is empty,
nothing establishes origin for the installer: it installs a bundle only with
`--allow-unverified-origin`, the workflow prints a warning, and the release
notes carry that flag in the install command.

The app needs no entitlements under the hardened runtime today: it spawns
helpers (`sudo`, `pmset`, `tmux`, `docker`), uses CoreWLAN with the location
usage strings in `Info.plist`, and reads the login keychain. If a later change
needs one, `build-app.sh` is where the entitlements file would be passed.

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
directory and checks that copy: it runs `codesign --verify --strict --deep`,
checks the bundle identifier and version, and for a Developer ID signature
runs `spctl --assess --type execute` and compares the team, all before the
password prompt. It installs that copy, not the path it was given, so a
bundle replaced at that path while the prompt waits is never installed. The
copy it puts in `~/Applications` is checked once more against the
requirement the recovery agent pins.

What is verified while `EXPECTED_TEAM_ID` is empty and releases are ad-hoc
signed: the checksum shows the zip was not altered after `SHA256SUMS` was
written; the attestation shows this repository's Release workflow built this
exact zip from the tag; `install.sh --app` shows the bundle inside is intact
(signature and resource seal), has the expected identifier and a version,
and carries the sealed backstop. What is not: `install.sh` cannot tell an
ad-hoc bundle from this repository apart from one anyone else signed with
the same identifier, so it refuses to install without
`--allow-unverified-origin`, the flag that says you ran the two commands
above yourself. Once `EXPECTED_TEAM_ID` is set and releases are Developer ID
signed and notarized, `install.sh --app` verifies origin on its own and the
flag is not needed.

## What is not automated

- Nobody signs for the maintainer: a release with the secrets missing is an
  ad-hoc prerelease, by design.
- The workflow does not install anything anywhere. The release validation
  record is still written by hand after a real install.
- Rotating the certificate or the API key means replacing the secrets; old
  releases keep their signatures.
