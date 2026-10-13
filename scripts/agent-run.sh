#!/bin/bash
# Register ONE finite agent job. Never wrap an idle interactive agent shell:
# use turn hooks with --agent begin/heartbeat/finish for interactive clients.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${INSOMNIA_BIN:-$ROOT/.build/debug/Insomnia}"
# A packaged script lives in Contents/Resources beside ../MacOS/Insomnia.
if [[ ! -x "$BIN" && -x "$ROOT/MacOS/Insomnia" ]]; then BIN="$ROOT/MacOS/Insomnia"; fi
usage() { echo "usage: $0 --name JOB_NAME -- COMMAND [ARG ...]" >&2; }
[[ $# -ge 4 && "$1" == --name && "$3" == -- ]] || { usage; exit 2; }
NAME="$2"
shift 3
[[ -x "$BIN" ]] || { echo "Build Insomnia first or set INSOMNIA_BIN to its executable" >&2; exit 2; }
JOB="$("$BIN" --agent begin "$NAME" "$$")"
HEARTBEAT_PID=""
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  "$BIN" --agent finish "$JOB" || echo "Activity cleanup failed; the lease will expire" >&2
  # This is our own unreaped child: its PID cannot be reused before wait.
  if [[ -n "$HEARTBEAT_PID" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
(
  while /bin/sleep 15; do
    "$BIN" --agent heartbeat "$JOB" || { echo "Auto activity expired; work may continue but sleep is no longer prevented" >&2; exit 0; }
  done
) &
HEARTBEAT_PID=$!
# Keep the wrapper alive until actual command exit; output silence/CPU idle
# and hidden windows do not end the job. Preserve the command's exit status.
"$@" <&0 &
COMMAND_PID=$!
set +e
wait "$COMMAND_PID"
STATUS=$?
set -e
exit "$STATUS"
