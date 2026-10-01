#!/bin/bash
# Proves on the built binaries, not on the compilation condition, that the
# scripts/simulate-lid.sh watcher is compiled out of a plain release build
# and in only with -DINSOMNIA_LID_SIMULATION (what install.sh adds for
# INSOMNIA_LID_SIMULATION=1). CI runs this after `swift build -c release`;
# it can be run locally the same way. It builds into .build only and
# installs nothing. The opt-in build uses its own scratch path so the
# plain release binary is left as built.
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT=${SWIFT:-swift}
SIM_SCRATCH=.build/lid-simulation
# The watcher class (Insomnia.LidSimulation, a class: mangled ...13LidSimulationC),
# its log lines and the build marker shown in the status menu and Settings.
SYMBOL='13LidSimulationC'
TEXTS=("lid SIMULATED" "Lid simulation build:")

"$SWIFT" build -c release
plain="$("$SWIFT" build -c release --show-bin-path)/Insomnia"
"$SWIFT" build -c release --scratch-path "$SIM_SCRATCH" -Xswiftc -DINSOMNIA_LID_SIMULATION
sim="$("$SWIFT" build -c release --scratch-path "$SIM_SCRATCH" -Xswiftc -DINSOMNIA_LID_SIMULATION --show-bin-path)/Insomnia"

failed=0
check() { # label binary present|absent
  local label=$1 bin=$2 expect=$3 n text ok=1
  n=$(nm "$bin" | grep -c "$SYMBOL" || true)
  echo "$label: $n symbol(s) of the watcher class"
  if [[ $expect == present && $n -eq 0 ]] || [[ $expect == absent && $n -gt 0 ]]; then ok=0; fi
  for text in "${TEXTS[@]}"; do
    n=$(strings "$bin" | grep -c -F "$text" || true)
    echo "$label: $n occurrence(s) of \"$text\""
    if [[ $expect == present && $n -eq 0 ]] || [[ $expect == absent && $n -gt 0 ]]; then ok=0; fi
  done
  if (( ok == 0 )); then
    echo "$label: expected the lid simulation to be $expect" >&2
    failed=1
  fi
}

check "plain release build ($plain)" "$plain" absent
check "INSOMNIA_LID_SIMULATION build ($sim)" "$sim" present
(( failed == 0 )) || exit 1
echo "lid simulation: compiled out of the plain release build, in with INSOMNIA_LID_SIMULATION"
