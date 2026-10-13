#!/bin/bash
# Command-Line-Tools-only smoke checks. Does not replace the XCTest suite.
# Nothing is installed; power commands and process signals are injected.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
/usr/bin/swift build -Xswiftc -warnings-as-errors
BIN="$(/usr/bin/swift build --show-bin-path)"
TEMP="$(/usr/bin/mktemp -d /tmp/insomnia-auto-check.XXXXXX)"
trap '/bin/rm -rf "$TEMP"' EXIT
OBJECTS=()
while IFS= read -r object; do OBJECTS+=("$object"); done < <(/usr/bin/find "$BIN/Insomnia.build" -name '*.o' ! -name 'main.swift.o')
/usr/bin/swiftc -parse-as-library -swift-version 6 -target "$(/usr/bin/uname -m)-apple-macosx26.0" \
  -I "$BIN/Modules" "$ROOT/scripts/check-agent-auto.swift" "${OBJECTS[@]}" -o "$TEMP/check"
INSOMNIA_HOME="$TEMP/home" "$TEMP/check"
# Exercise the real CLI and wrapper in a DIFFERENT isolated support folder.
export INSOMNIA_HOME="$TEMP/cli-home"
export INSOMNIA_BIN="$BIN/Insomnia"
"$ROOT/scripts/agent-run.sh" --name "successful batch job" -- /bin/sh -c 'exit 0'
set +e
"$ROOT/scripts/agent-run.sh" --name "failed batch job" -- /bin/sh -c 'exit 17'
STATUS=$?
set -e
[[ "$STATUS" == 17 ]] || { echo "wrapper lost command exit status: $STATUS" >&2; exit 1; }
if /usr/bin/find "$INSOMNIA_HOME" -path '*/agent-jobs/*.json' | /usr/bin/grep -q .; then
  echo 'wrapper left registered work after command exit' >&2; exit 1
fi
printf 'PASS terminal wrapper: success/failure cleanup and preserved exit status\n'
