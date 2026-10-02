#!/bin/bash
# Regenerate Resources/AppIcon-1024.png, Resources/AppIcon.icns and
# docs/assets/eye-open.svg from the drawing the app carries
# (Sources/Insomnia/UI/AppIconArtwork.swift over EyeLensGeometry.swift,
# EyeMarkGeometry.swift and BrandPalette.swift), via
# scripts/generate-app-icon.swift. Deterministic: the same sources produce
# the same bytes. Needs Xcode's swiftc and iconutil.
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$SWIFTC" -O -parse-as-library \
  "$ROOT/Sources/Insomnia/UI/EyeLensGeometry.swift" \
  "$ROOT/Sources/Insomnia/UI/EyeMarkGeometry.swift" \
  "$ROOT/Sources/Insomnia/UI/BrandPalette.swift" \
  "$ROOT/Sources/Insomnia/UI/AppIconArtwork.swift" \
  "$ROOT/scripts/generate-app-icon.swift" \
  -o "$WORK/generate-app-icon"

"$WORK/generate-app-icon" \
  --png "$ROOT/Resources/AppIcon-1024.png" \
  --iconset "$WORK/AppIcon.iconset" \
  --svg "$ROOT/docs/assets/eye-open.svg"
"$ICONUTIL" -c icns "$WORK/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"

if [[ -n "$PREVIEW_DIR" ]]; then
  mkdir -p "$PREVIEW_DIR"
  cp "$WORK/AppIcon.iconset"/*.png "$PREVIEW_DIR/"
fi

echo "wrote $ROOT/Resources/AppIcon-1024.png, $ROOT/Resources/AppIcon.icns and $ROOT/docs/assets/eye-open.svg"
