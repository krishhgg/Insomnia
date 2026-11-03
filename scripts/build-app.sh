#!/bin/bash
# Build Insomnia and assemble an ad-hoc signed Insomnia.app. install.sh runs this for
# source installs, and .github/workflows/release.yml runs it for the
# downloadable package, so both produce the same bundle.
#
# Usage: scripts/build-app.sh --output DIR
#   Writes DIR/Insomnia.app, replacing a bundle already at that path. DIR is
#   created if needed. Prints the bundle path last.
#
# The signature is always ad-hoc (`codesign --sign -`): releases are ad-hoc
# signed and not notarized (docs/releasing.md). It identifies only this build
# (its cdhash), and macOS blocks the first launch of a downloaded copy until
# the user allows it. The bundle has no nested code, so there is no --deep;
# backstop.sh under Contents/Resources is sealed as a resource.
set -euo pipefail

# Fixed tool paths: never taken from PATH. Tests patch these lines in a
# private copy of the script.
SWIFT=/usr/bin/swift
CODESIGN=/usr/bin/codesign
PLUTIL=/usr/bin/plutil
RM=/bin/rm
MKDIR=/bin/mkdir
CP=/bin/cp
CHMOD=/bin/chmod

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
"$MKDIR" -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# The Swift that wrote a .swiftinterface, from its first header line.
interface_compiler() {
  local line
  line="$(grep -m 1 '^// swift-compiler-version: ' "$1" 2>/dev/null)" || return 0
  printf '%s\n' "${line#// swift-compiler-version: }"
}

# SwiftPM's PackageDescription and PackagePlugin interfaces that an older
# Swift wrote, one path per line: a .private.swiftinterface whose writer is
# not the writer of the .swiftinterface beside it. An update of the Command
# Line Tools or Xcode that does not delete files its new version no longer
# ships leaves them there, and the compiler reads a .private.swiftinterface
# first, so Package.swift is compiled against the old API. Looked up only
# after a failed build, in the toolchain this script's swift reports.
stale_package_interfaces() {
  local resources f
  resources="$("$SWIFT" -print-target-info 2>/dev/null | sed -n 's|^ *"runtimeResourcePath": "\(.*\)",*$|\1|p')" || return 0
  [[ -n "$resources" ]] || return 0
  for f in "$resources"/pm/*/*.swiftmodule/*.private.swiftinterface; do
    [[ -f "$f" && -f "${f%.private.swiftinterface}.swiftinterface" ]] || continue
    if [[ "$(interface_compiler "$f")" != "$(interface_compiler "${f%.private.swiftinterface}.swiftinterface")" ]]; then
      printf '%s\n' "$f"
    fi
  done
}

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
build_rc=0
"$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} || build_rc=$?
if (( build_rc != 0 )); then
  stale="$(stale_package_interfaces)"
  if [[ -n "$stale" ]]; then
    listed="" remove=""
    while IFS= read -r f; do
      listed+="  $f"$'\n'"    written by $(interface_compiler "$f")"$'\n'
      remove+=" $(printf '%q' "$f")"
    done <<< "$stale"
    cat >&2 <<STALE

The build failed. The Swift toolchain it used also holds package interfaces
written by an older Swift than the ones beside them:
$listed
Swift reads a .private.swiftinterface before the .swiftinterface beside it, so
Package.swift is compiled against that older PackageDescription. An error above
such as "reference to member 'v26' cannot be resolved" or "has no member
'swiftLanguageMode'" comes from them. An update of the Command Line Tools or
Xcode that did not delete the previous version's files leaves them behind.
Delete them (or reinstall the Command Line Tools or Xcode), then rerun:
  sudo rm$remove
STALE
  fi
  exit "$build_rc"
fi
BIN="$("$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)/Insomnia"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

# 2. Bundle ------------------------------------------------------------------
APP="$OUTPUT/Insomnia.app"
step "Assembling $APP"
"$RM" -rf "$APP"
"$MKDIR" -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$CP" "$BIN" "$APP/Contents/MacOS/Insomnia"
"$CP" "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$CP" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# backstop.sh goes into the bundle before it is signed, so the signature's
# resource seal covers it. The LaunchAgent install.sh writes verifies the
# bundle and only then runs this copy; an edited script fails that check.
"$CP" "$ROOT/scripts/backstop.sh" "$APP/Contents/Resources/backstop.sh"
"$CHMOD" 755 "$APP/Contents/Resources/backstop.sh"
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null

# 3. Sign --------------------------------------------------------------------
step "Signing ad-hoc (this build is identified only by its cdhash)"
"$CODESIGN" --force --sign - "$APP"
"$CODESIGN" --verify --strict "$APP"
"$CODESIGN" -dvv "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|CDHash)=' || true
echo "$APP"
