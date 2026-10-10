#!/bin/bash
# Package an already-built app without recompiling it.
set -euo pipefail
if [[ $# != 2 ]]; then
  echo "usage: $0 /path/to/Insomnia.app /path/to/output.zip" >&2
  exit 1
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="${script_dir%/*}"
app_path="$1"
output_dir="$(cd "$(dirname "$2")" && pwd)"
output_path="$output_dir/$(basename "$2")"
if [[ -e "$output_path" || -L "$output_path" ]]; then
  echo "Output already exists: $output_path" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app_path"
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Unexpected app version' >&2; exit 1; }
stage_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/insomnia-desktop.XXXXXX")"
trap '/bin/rm -rf "$stage_dir"' EXIT
package_dir="$stage_dir/Insomnia-Desktop-$version-macos"
/bin/mkdir "$package_dir"
/usr/bin/ditto "$app_path" "$package_dir/Insomnia.app"
/bin/cp "$script_dir/install-desktop.sh" "$package_dir/install.sh"
/bin/cp "$script_dir/uninstall.sh" "$package_dir/uninstall.sh"
/bin/cp "$repo_dir/desktop/Install.command" "$repo_dir/desktop/default-settings.json" "$repo_dir/desktop/README.md" "$repo_dir/LICENSE" "$package_dir/"
/bin/chmod 755 "$package_dir/Install.command" "$package_dir/install.sh" "$package_dir/uninstall.sh"
/usr/bin/codesign --verify --deep --strict "$package_dir/Insomnia.app"
/usr/bin/codesign -d --verbose=4 "$package_dir/Insomnia.app" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p' > "$package_dir/EXPECTED-CDHASH"
[[ -s "$package_dir/EXPECTED-CDHASH" ]] || { echo 'Missing code-directory hash' >&2; exit 1; }
(
  cd "$package_dir"
  /usr/bin/find . -type f ! -name SHA256SUMS -print0 | /usr/bin/sort -z | /usr/bin/xargs -0 /usr/bin/shasum -a 256 > SHA256SUMS
  /usr/bin/shasum -a 256 -c SHA256SUMS
)
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$package_dir" "$output_path"
printf 'Created %s\n' "$output_path"
