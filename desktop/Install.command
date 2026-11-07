#!/bin/bash
# Portable installer; package-desktop.sh supplies the app and checksum files.
set -euo pipefail
cd "$(dirname "$0")"
finish() {
  local result=$?
  if (( result != 0 )); then
    printf '\nInstallation stopped. Review the error above before retrying.\n'
  fi
  if [[ -t 0 ]]; then
    read -r -p 'Press Return to close this window. ' _ || true
  fi
  exit "$result"
}
trap finish EXIT
printf 'Insomnia Desktop setup\n\n'
/usr/bin/shasum -a 256 -c SHA256SUMS
/usr/bin/codesign --verify --deep --strict ./Insomnia.app
actual_hash="$(/usr/bin/codesign -d --verbose=4 ./Insomnia.app 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')"
expected_hash="$(/bin/cat EXPECTED-CDHASH)"
if [[ -z "$expected_hash" || "$actual_hash" != "$expected_hash" ]]; then
  echo 'The app does not match this desktop package. Nothing was installed.' >&2
  exit 1
fi
printf '\nThis is a locally built, ad-hoc signed desktop edition. It is not notarized\nand has no GitHub build attestation. See README.md for its origin and permissions.\n'
./install.sh --allow-unverified-origin --app ./Insomnia.app
config_dir="$HOME/Library/Application Support/Insomnia"
config_path="$config_dir/config.json"
if [[ ! -e "$config_path" && ! -L "$config_path" ]]; then
  /bin/mkdir -p "$config_dir"
  settings_tmp="$(/usr/bin/mktemp "$config_dir/.desktop-settings.XXXXXX")"
  /bin/chmod 600 "$settings_tmp"
  /bin/cat default-settings.json > "$settings_tmp"
  # A hard link publishes a complete file and refuses to overwrite one
  # another process created while setup was running.
  if /bin/ln "$settings_tmp" "$config_path" 2>/dev/null; then
    printf '\nFresh desktop settings installed.\n'
  else
    printf '\nA configuration already exists; keeping its settings.\n'
  fi
  /bin/rm -f "$settings_tmp"
else
  printf '\nKeeping existing Insomnia settings.\n'
fi
/usr/bin/open "$HOME/Applications/Insomnia.app"
printf '\nInstalled. Open Insomnia from Spotlight, the Dock, or your Applications folder.\n'
