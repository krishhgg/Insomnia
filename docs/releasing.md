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
   below), then install it with `./install.sh --app ./Insomnia.app` on a Mac
   you can afford to reinstall on. Record the result in
   `docs/release-validation.md`.

A manual run (Actions, Release, Run workflow) builds and packages the current
branch and uploads the zip and `SHA256SUMS` as a workflow artifact. It does
not attest or publish anything, so it is the way to try the pipeline.

## Signing and notarization

Signing is decided by which repository secrets exist. All are optional.

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

Without the signing secrets the bundle is ad-hoc signed. The release is then
marked a prerelease and its notes say it is experimental: macOS blocks the
first launch of a downloaded ad-hoc app until the user allows it in System
Settings. A Developer ID build without notarization is also a prerelease,
because Gatekeeper blocks it too.

Once a Developer ID is in use, put its Team ID in `EXPECTED_TEAM_ID` in
`scripts/install.sh`. From then on `install.sh --app` refuses a Developer ID
bundle from any other team. While it is empty, the team is printed and not
checked.

The app needs no entitlements under the hardened runtime today: it spawns
helpers (`sudo`, `pmset`, `tmux`, `docker`), uses CoreWLAN with the location
usage strings in `Info.plist`, and reads the login keychain. If a later change
needs one, `build-app.sh` is where the entitlements file would be passed.

## Verifying a download

```bash
shasum -a 256 -c SHA256SUMS
gh attestation verify Insomnia-<version>-macos.zip -R krishhgg/Insomnia
```

The first line checks the zip against the checksum published with it. The
second asks GitHub for the attestation signed when the workflow ran and
checks that this zip is its subject and that the workflow belongs to this
repository. Together they show the bytes are what the Release workflow built
from the tagged commit. They do not show the code is safe; the README's
warnings apply to every build.

`install.sh --app` then runs `codesign --verify --strict --deep` on the
bundle, checks the bundle identifier and version, and for a Developer ID
signature runs `spctl --assess --type execute` and compares the team, all
before the password prompt.

## What is not automated

- Nobody signs for the maintainer: a release with the secrets missing is an
  ad-hoc prerelease, by design.
- The workflow does not install anything anywhere. The release validation
  record is still written by hand after a real install.
- Rotating the certificate or the API key means replacing the secrets; old
  releases keep their signatures.
