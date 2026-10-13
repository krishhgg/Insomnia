#!/bin/bash
set -euo pipefail

SWIFT="/usr/bin/swift"
CODESIGN="/usr/bin/codesign"
PLISTBUDDY="/usr/libexec/PlistBuddy"
OPEN="/usr/bin/open"
CP="/bin/cp"
MKDIR="/bin/mkdir"

# Builds a separate debug bundle. Its services are fixtures, so previewing
# the timer never changes pmset, LaunchAgents, login items or the keychain.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
BUILD_DIR="${INSOMNIA_PREVIEW_BUILD_DIR:-.build/xcode}"
"$SWIFT" build --scratch-path "$BUILD_DIR"
BIN="$("$SWIFT" build --scratch-path "$BUILD_DIR" --show-bin-path)/Insomnia"
APP="$ROOT/.build/preview/Insomnia Preview.app"
"$MKDIR" -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$CP" "$BIN" "$APP/Contents/MacOS/Insomnia"
"$CP" "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$CP" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
"$PLISTBUDDY" -c 'Set :CFBundleIdentifier com.kgarg.insomnia.preview' "$APP/Contents/Info.plist"
"$PLISTBUDDY" -c 'Set :CFBundleName Insomnia Preview' "$APP/Contents/Info.plist"
"$PLISTBUDDY" -c 'Set :CFBundleDisplayName Insomnia Preview' "$APP/Contents/Info.plist"
"$PLISTBUDDY" -c 'Set :LSUIElement false' "$APP/Contents/Info.plist"
"$CODESIGN" --force --sign - "$APP"
"$OPEN" "$APP" --args --ui-preview "$@"
printf '%s\n' "$APP"
