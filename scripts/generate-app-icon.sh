#!/bin/bash
# Regenerate Resources/AppIcon-1024.png, Resources/AppIcon.icns and
# docs/assets/eye-open.svg from the drawing the app carries
# (Sources/Insomnia/UI/AppIconArtwork.swift over EyeLensGeometry.swift,
# EyeMarkGeometry.swift and BrandPalette.swift), via
# scripts/generate-app-icon.swift. Deterministic: the same sources produce
# the same bytes. All three are replaced together or, if any step fails,
# not at all. Needs Xcode's swiftc and iconutil.
#
#   scripts/generate-app-icon.sh [PREVIEW_DIR]
#
# With PREVIEW_DIR, the individual iconset PNGs are also copied there for
# inspection.
set -euo pipefail

SWIFTC=/usr/bin/swiftc
ICONUTIL=/usr/bin/iconutil

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_DIR="${1:-}"

PNG="$ROOT/Resources/AppIcon-1024.png"
ICNS="$ROOT/Resources/AppIcon.icns"
SVG="$ROOT/docs/assets/eye-open.svg"
# Suffix of the copies staged beside each asset before the swap.
STAGED=".staged.$$"

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
  rm -f "$PNG$STAGED" "$ICNS$STAGED" "$SVG$STAGED"
}
trap cleanup EXIT

"$SWIFTC" -O -parse-as-library \
  "$ROOT/Sources/Insomnia/UI/EyeLensGeometry.swift" \
  "$ROOT/Sources/Insomnia/UI/EyeMarkGeometry.swift" \
  "$ROOT/Sources/Insomnia/UI/BrandPalette.swift" \
  "$ROOT/Sources/Insomnia/UI/AppIconArtwork.swift" \
  "$ROOT/scripts/generate-app-icon.swift" \
  -o "$WORK/generate-app-icon"

# Every output is generated into $WORK first, so a failed render or
# iconutil run leaves the three assets as they were.
"$WORK/generate-app-icon" \
  --png "$WORK/AppIcon-1024.png" \
  --iconset "$WORK/AppIcon.iconset" \
  --svg "$WORK/eye-open.svg"
"$ICONUTIL" -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"

# Then each is copied beside the asset it replaces, so an unwritable
# Resources or docs/assets folder fails here, with every asset untouched.
# The renames that follow stay within one folder each and replace the
# assets only once all three copies exist.
cp "$WORK/AppIcon-1024.png" "$PNG$STAGED"
cp "$WORK/AppIcon.icns" "$ICNS$STAGED"
cp "$WORK/eye-open.svg" "$SVG$STAGED"
mv -f "$PNG$STAGED" "$PNG"
mv -f "$ICNS$STAGED" "$ICNS"
mv -f "$SVG$STAGED" "$SVG"

if [[ -n "$PREVIEW_DIR" ]]; then
  mkdir -p "$PREVIEW_DIR"
  cp "$WORK/AppIcon.iconset"/*.png "$PREVIEW_DIR/"
fi

echo "wrote $PNG, $ICNS and $SVG"
