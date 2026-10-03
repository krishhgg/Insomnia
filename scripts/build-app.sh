#!/bin/bash
# Build Insomnia and assemble a signed Insomnia.app. install.sh runs this for
# source installs, and .github/workflows/release.yml runs it for the
# downloadable package, so both produce the same bundle.
#
# Usage: scripts/build-app.sh --output DIR
#   Writes DIR/Insomnia.app, replacing a bundle already at that path. DIR is
#   created if needed. Prints the bundle path last.
#
# Signing is chosen by the environment:
#   INSOMNIA_SIGN_IDENTITY  set to the name of a "Developer ID Application"
#                           identity in an unlocked keychain: the bundle is
#                           signed with it, with the hardened runtime and a
#                           secure timestamp, which is what notarization
#                           needs. Unset or empty: ad-hoc signature
#                           (`codesign --sign -`), which only identifies this
#                           build (its cdhash) and which Gatekeeper blocks
#                           when the bundle was downloaded.
# The bundle has no nested code, so there is no --deep; backstop.sh under
# Contents/Resources is sealed as a resource either way.
set -euo pipefail

# Fixed tool paths: never taken from PATH. Tests patch these lines in a
# private copy of the script.
SWIFT=/usr/bin/swift
CODESIGN=/usr/bin/codesign
PLUTIL=/usr/bin/plutil

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { echo "usage: $0 --output DIR" >&2; }
OUTPUT=""
while (( $# )); do
  case "$1" in
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$OUTPUT" ]] || { usage; exit 2; }
# Resolved now, before the build changes into the checkout: a relative
# --output means relative to the caller's directory, not to the checkout.
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# 1. Build -------------------------------------------------------------------
step "Building (release)"
cd "$ROOT"
# INSOMNIA_LID_SIMULATION=1 compiles the scripts/simulate-lid.sh file trigger
# (LidSimulation.swift) into this release build, for release validation on
# a machine whose lid stays open (install.sh passes it through from its own
# environment). A normal build has no watcher: nothing reads the trigger
# file. Such a build says so in the log at launch, in the status menu and in
# Settings. The release workflow never sets it.
BUILD_FLAGS=()
if [[ "${INSOMNIA_LID_SIMULATION:-}" == 1 ]]; then
  BUILD_FLAGS+=(-Xswiftc -DINSOMNIA_LID_SIMULATION)
  echo "lid simulation compiled in (INSOMNIA_LID_SIMULATION=1): scripts/simulate-lid.sh will drive the lid actions during sessions"
fi
# ${arr[@]+"${arr[@]}"}: an empty array expands to nothing under set -u on
# the bash 3.2 that ships with macOS.
"$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN="$("$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)/Insomnia"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

# 2. Bundle ------------------------------------------------------------------
APP="$OUTPUT/Insomnia.app"
step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Insomnia"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# backstop.sh goes into the bundle before it is signed, so the signature's
# resource seal covers it. The LaunchAgent install.sh writes verifies the
# bundle and only then runs this copy; an edited script fails that check.
cp "$ROOT/scripts/backstop.sh" "$APP/Contents/Resources/backstop.sh"
chmod 755 "$APP/Contents/Resources/backstop.sh"
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null

# 3. Sign --------------------------------------------------------------------
IDENTITY="${INSOMNIA_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]]; then
  step "Signing with \"$IDENTITY\" (hardened runtime, timestamped)"
  "$CODESIGN" --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
else
  step "Signing ad-hoc (no INSOMNIA_SIGN_IDENTITY; this build is identified only by its cdhash)"
  "$CODESIGN" --force --sign - "$APP"
fi
"$CODESIGN" --verify --strict "$APP"
"$CODESIGN" -dvv "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|CDHash)=' || true
echo "$APP"
