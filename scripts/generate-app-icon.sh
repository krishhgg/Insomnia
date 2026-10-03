#!/bin/bash
# Regenerate Resources/AppIcon-1024.png, Resources/AppIcon.icns and
# docs/assets/eye-open.svg from the drawing the app carries
# (Sources/Insomnia/UI/AppIconArtwork.swift over EyeLensGeometry.swift,
# EyeMarkGeometry.swift and BrandPalette.swift), via
# scripts/generate-app-icon.swift. Deterministic: the same sources produce
# the same bytes. Needs Xcode's swiftc and iconutil.
#
# The script replaces the three files together or not at all. It
# generates them in a temporary folder, copies each one beside its asset
# along with a backup of the asset, and only then renames the new files
# into place one by one. If a rename fails or a signal stops the script
# part way, the exit trap renames the backups back over the assets already
# replaced.
#
#   scripts/generate-app-icon.sh [PREVIEW_DIR]
#
# With PREVIEW_DIR, the individual iconset PNGs are also copied there for
# inspection.
set -euo pipefail

SWIFTC=/usr/bin/swiftc
ICONUTIL=/usr/bin/iconutil
MKTEMP=/usr/bin/mktemp
MKDIR=/bin/mkdir
CP=/bin/cp
MV=/bin/mv
RM=/bin/rm

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_DIR="${1:-}"

PNG="$ROOT/Resources/AppIcon-1024.png"
ICNS="$ROOT/Resources/AppIcon.icns"
SVG="$ROOT/docs/assets/eye-open.svg"
ASSETS=("$PNG" "$ICNS" "$SVG")
# Suffixes of the copies kept beside each asset while it is replaced: the
# new file, and the asset as it was.
STAGED=".staged.$$"
BACKUP=".backup.$$"

WORK="$("$MKTEMP" -d)"
# 1 while the staged files are being renamed over the assets, 0 before
# and after.
SWAPPING=0

# Puts back every asset whose staged copy has already been renamed over
# it. The backup goes back in its place, or, for an asset that did not
# exist before, the new file is removed. A backup that cannot be renamed
# back stays on disk, and the message names it.
restore_replaced() {
  local asset
  for asset in "${ASSETS[@]}"; do
    [[ -e "$asset$STAGED" ]] && continue
    if [[ -e "$asset$BACKUP" ]]; then
      if "$MV" -f "$asset$BACKUP" "$asset"; then
        echo "put back $asset" >&2
      else
        echo "could not put back $asset; its previous contents are in $asset$BACKUP" >&2
      fi
    elif "$RM" -f "$asset"; then
      echo "removed $asset, which did not exist before" >&2
    else
      echo "could not remove $asset, which did not exist before" >&2
    fi
  done
}

# The exit trap. It ignores HUP, INT and TERM and runs every step even when
# one fails, so a second Ctrl-C cannot cut a rollback short. A swap that
# stopped part way always exits nonzero.
cleanup() {
  local status=$? asset
  set +e
  trap '' HUP INT TERM
  if (( SWAPPING )); then
    echo "generate-app-icon: stopped part way through replacing the assets" >&2
    restore_replaced
    [[ $status -ne 0 ]] || status=1
  fi
  "$RM" -rf "$WORK"
  for asset in "${ASSETS[@]}"; do
    # A backup still beside an asset that was replaced is one
    # restore_replaced could not put back, so it stays.
    if (( SWAPPING )) && [[ ! -e "$asset$STAGED" && -e "$asset$BACKUP" ]]; then
      continue
    fi
    "$RM" -f "$asset$STAGED" "$asset$BACKUP"
  done
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$SWIFTC" -O -parse-as-library \
  "$ROOT/Sources/Insomnia/UI/EyeLensGeometry.swift" \
  "$ROOT/Sources/Insomnia/UI/EyeMarkGeometry.swift" \
  "$ROOT/Sources/Insomnia/UI/BrandPalette.swift" \
  "$ROOT/Sources/Insomnia/UI/AppIconArtwork.swift" \
  "$ROOT/scripts/generate-app-icon.swift" \
  -o "$WORK/generate-app-icon"

# The generator and iconutil write every output into $WORK first, so a
# failed render or iconutil run leaves the three assets as they were.
"$WORK/generate-app-icon" \
  --png "$WORK/AppIcon-1024.png" \
  --iconset "$WORK/AppIcon.iconset" \
  --svg "$WORK/eye-open.svg"
"$ICONUTIL" -c icns "$WORK/AppIcon.iconset" -o "$WORK/AppIcon.icns"

# Then the script copies each new file, and a backup of each asset, beside
# the asset. An unwritable Resources or docs/assets folder fails here, with
# every asset untouched. Plain cp leaves out the asset's flags, so the
# backup of a file locked in Finder is not locked.
NEW=("$WORK/AppIcon-1024.png" "$WORK/AppIcon.icns" "$WORK/eye-open.svg")
for i in "${!ASSETS[@]}"; do
  "$CP" "${NEW[$i]}" "${ASSETS[$i]}$STAGED"
  if [[ -e "${ASSETS[$i]}" ]]; then
    "$CP" "${ASSETS[$i]}" "${ASSETS[$i]}$BACKUP"
  fi
done

# The renames stay within one folder each. A failed rename, such as over
# a file locked in Finder, exits through the trap, which puts back the
# assets already replaced.
SWAPPING=1
for asset in "${ASSETS[@]}"; do
  "$MV" -f "$asset$STAGED" "$asset"
done
SWAPPING=0

if [[ -n "$PREVIEW_DIR" ]]; then
  "$MKDIR" -p "$PREVIEW_DIR"
  "$CP" "$WORK/AppIcon.iconset"/*.png "$PREVIEW_DIR/"
fi

echo "wrote $PNG, $ICNS and $SVG"
