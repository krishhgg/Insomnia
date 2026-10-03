#!/bin/bash
# Proves on the built binaries, not on the compilation condition, that the
# scripts/simulate-lid.sh watcher is compiled out of a plain release build
# and in only with -DINSOMNIA_LID_SIMULATION (what install.sh adds for
# INSOMNIA_LID_SIMULATION=1). CI runs this after its release build step,
# with the same flags, so the plain build here is that binary rather than
# a rebuild; it can be run locally the same way. It builds into .build
# only and installs nothing. The opt-in build uses its own scratch path so
# the plain release binary is left as built.
set -euo pipefail
cd "$(dirname "$0")/.."

# Tools by absolute path, as in the other scripts, never through PATH;
# LidSimulationGateScriptTests patches these lines in a private copy.
SWIFT=/usr/bin/swift
NM=/usr/bin/nm
STRINGS=/usr/bin/strings
SIM_SCRATCH=.build/lid-simulation
# The watcher class (Insomnia.LidSimulation, a class: mangled ...13LidSimulationC),
# its log lines and the build marker shown in the status menu and Settings.
SYMBOL='13LidSimulationC'
TEXTS=("lid SIMULATED" "Lid simulation build:")
# The flags of CI's "Build release" step; a warning in either build fails.
RELEASE_FLAGS=(-c release -Xswiftc -warnings-as-errors)

"$SWIFT" build "${RELEASE_FLAGS[@]}"
plain="$("$SWIFT" build "${RELEASE_FLAGS[@]}" --show-bin-path)/Insomnia"
"$SWIFT" build "${RELEASE_FLAGS[@]}" --scratch-path "$SIM_SCRATCH" -Xswiftc -DINSOMNIA_LID_SIMULATION
sim="$("$SWIFT" build "${RELEASE_FLAGS[@]}" --scratch-path "$SIM_SCRATCH" -Xswiftc -DINSOMNIA_LID_SIMULATION --show-bin-path)/Insomnia"

failed=0
# Prints how many lines of $2 contain $1, as a fixed string when $3 is
# "fixed". grep exits 1 when nothing matches, which is a count of 0; a
# grep that fails any other way stops the check instead of reading as 0.
count() { # pattern text [fixed]
  local n rc=0
  if [[ ${3:-} == fixed ]]; then
    n=$(grep -c -F -e "$1" <<<"$2") || rc=$?
  else
    n=$(grep -c -e "$1" <<<"$2") || rc=$?
  fi
  if (( rc > 1 )); then
    echo "grep failed with status $rc counting \"$1\"" >&2
    return 1
  fi
  echo "$n"
}

check() { # label binary present|absent
  local label=$1 bin=$2 expect=$3 symbols texts n text ok=1
  # Read the binary before counting. Piped straight into grep -c, an nm or
  # strings that cannot read it counts 0, which passes the "absent" check
  # for a binary nobody inspected. A read that prints nothing fails too.
  if ! symbols=$("$NM" "$bin") || [[ -z $symbols ]]; then
    echo "$label: nm could not read the binary" >&2
    exit 1
  fi
  if ! texts=$("$STRINGS" "$bin") || [[ -z $texts ]]; then
    echo "$label: strings could not read the binary" >&2
    exit 1
  fi
  n=$(count "$SYMBOL" "$symbols") || exit 1
  echo "$label: $n symbol(s) of the watcher class"
  if [[ $expect == present && $n -eq 0 ]] || [[ $expect == absent && $n -gt 0 ]]; then ok=0; fi
  for text in "${TEXTS[@]}"; do
    n=$(count "$text" "$texts" fixed) || exit 1
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
