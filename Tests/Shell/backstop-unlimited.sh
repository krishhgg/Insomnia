#!/bin/bash
# Recovery-helper seam only: private copies, fixture journals, mocked effects.
# Run on macOS with /bin/bash (3.2); never calls real power or signal tools.
set -euo pipefail
export LC_ALL=C TZ=UTC
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAB="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/insomnia-helper.XXXXXX")"
trap '/bin/rm -rf "$LAB"' EXIT
export LAB
/bin/mkdir -p "$LAB/tools"

# All effectful fixed paths are replaced before any helper is run. Unknown
# operations fail, rather than falling through to real commands.
cat > "$LAB/tools/effect" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$LAB/calls"
[[ "${FAIL_UNDO:-0}" == 0 ]] || exit 1
case "$*" in
  '-n '*'/pmset -a disablesleep 0') printf 'off\n' > "$LAB/sleep" ;;
  '-n '*'/pmset -b lowpowermode 0') printf 'off\n' > "$LAB/lowpower" ;;
  *) exit 99 ;;
esac
SH
cat > "$LAB/tools/ps" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >> "$LAB/observations"
if [[ "${PS_FAIL:-0}" != 0 ]]; then printf 'ps unavailable\n' >&2; exit 2; fi
[[ -s "$LAB/process" ]] || exit 1
/bin/cat "$LAB/process"
SH
cat > "$LAB/tools/sysctl" <<'SH'
#!/bin/bash
[[ "$*" == '-n kern.bootsessionuuid' ]] || exit 99
printf 'fixture-boot\n'
SH
cat > "$LAB/tools/refuse" <<'SH'
#!/bin/bash
printf 'Unexpected effect: %s\n' "$*" >&2
exit 99
SH
/bin/chmod +x "$LAB/tools/"*
/usr/bin/perl -pe '
  s{^SUDO=.*$}{SUDO="$ENV{LAB}/tools/effect"};
  s{^PMSET=.*$}{PMSET="$ENV{LAB}/tools/pmset"};
  s{^PS=.*$}{PS="$ENV{LAB}/tools/ps"};
  s{^SYSCTL=.*$}{SYSCTL="$ENV{LAB}/tools/sysctl"};
  s{^(KILL|DEFAULTS)=.*$}{$1="$ENV{LAB}/tools/refuse"};
  s{^INSOMNIA_BIN=.*$}{INSOMNIA_BIN="$ENV{LAB}/Insomnia.app/Contents/MacOS/Insomnia"};
  s{^INSOMNIA_INFO=.*$}{INSOMNIA_INFO="$ENV{LAB}/Insomnia.app/Contents/Info.plist"};
  s{^LOCK_TIMEOUT_SECONDS=.*$}{LOCK_TIMEOUT_SECONDS=0};
' "$ROOT/scripts/backstop.sh" > "$LAB/backstop.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reset() {
  /bin/rm -rf "${LAB:?}/home"
  /bin/mkdir -p "$LAB/home"
  : > "$LAB/calls"; : > "$LAB/observations"; : > "$LAB/process"
  printf 'on\n' > "$LAB/sleep"; printf 'on\n' > "$LAB/lowpower"
  printf '%s\n' '{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"extra":{"keep":1}}' > "$LAB/home/state.json"
}
run() {
  RC=0
  INSOMNIA_HOME="$LAB/home" /bin/bash "$LAB/backstop.sh" "$@" > "$LAB/out" 2> "$LAB/err" || RC=$?
}
assert_held() {
  [[ "$RC" == 0 && ! -s "$LAB/calls" && -f "$LAB/home/session.json" ]] || fail "live owner was not preserved (exit $RC)"
  [[ "$(<"$LAB/sleep")" == on ]] || fail 'live session changed power'
  [[ "$(/usr/bin/plutil -extract sleepDisabledByUs raw -o - "$LAB/home/state.json")" == true ]] || fail 'live journal changed'
}
unlimited() {
  printf '%s\n' '{"mode":"unlimited","startedAt":"2026-01-01T00:00:00Z","extensions":[],"ownerPID":4242}' > "$LAB/home/session.json"
}

# Tracer bullet: an owning app remains alive, without an endsAt deadline.
reset
unlimited
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_held
printf 'PASS: unlimited live owner preserves session and journal\n'

reset
unlimited
printf 'Thu Jan  1 00:00:01 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
[[ "$RC" == 0 && "$(<"$LAB/sleep")" == off && ! -f "$LAB/home/session.json" ]] || fail 'later app PID held an owner without kernel identity'
printf 'PASS: later app PID cannot own an earlier unlimited session\n'

# PID reuse by a later instance of the same executable must not prolong it.
reset
unlimited
/usr/bin/plutil -insert ownerIdentity -json '{"startedAt":1767225600,"startedAtMicros":17,"bootSession":"fixture-boot"}' "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:01 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
[[ "$RC" == 0 && "$(<"$LAB/sleep")" == off && ! -f "$LAB/home/session.json" ]] || fail 'reused app PID kept interrupted unlimited alive'
printf 'PASS: reused app PID ends interrupted unlimited\n'

reset
unlimited
/usr/bin/plutil -insert ownerIdentity -string invalid "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
[[ "$RC" == 0 && "$(<"$LAB/sleep")" == off && ! -f "$LAB/home/session.json" ]] || fail 'malformed identity held session'
quarantined=("$LAB/home/"session.json.unreadable-*)
[[ -f "${quarantined[0]}" ]] || fail 'malformed identity lost evidence'
printf 'PASS: malformed identity restores and quarantines evidence\n'

assert_restored() {
  [[ "$RC" == 0 && "$(<"$LAB/sleep")" == off && "$(<"$LAB/lowpower")" == off ]] || fail "owned settings not restored (exit $RC)"
  [[ ! -f "$LAB/home/session.json" ]] || fail 'interrupted session survived cleanup'
  [[ "$(/usr/bin/plutil -extract sleepDisabledByUs raw -o - "$LAB/home/state.json")" == false ]] || fail 'restored sleep still journaled'
  [[ "$(/usr/bin/plutil -extract lowPowerSetByUs raw -o - "$LAB/home/state.json")" == false ]] || fail 'restored low power still journaled'
  [[ "$(/usr/bin/plutil -extract extra.keep raw -o - "$LAB/home/state.json")" == 1 ]] || fail 'unknown journal field lost'
}

# A live last-value identity must not hide conflicting ownership from the
# app's first-value decoder, including escaped spellings of the same key.
for field in startedAt startedAtMicros bootSession; do
  for escaped in no yes; do
    reset
    second="$field"
    if [[ "$escaped" == yes ]]; then
      case "$field" in
        startedAt|startedAtMicros) second='\'"u0073${field:1}" ;;
        bootSession) second='\'"u0062${field:1}" ;;
      esac
    fi
    case "$field" in
      startedAt)
        first=1767225599
        identity="\"$second\":1767225600,\"startedAtMicros\":17,\"bootSession\":\"fixture-boot\"" ;;
      startedAtMicros)
        first=-1
        identity="\"startedAt\":1767225600,\"$second\":17,\"bootSession\":\"fixture-boot\"" ;;
      bootSession)
        first='"old-boot"'
        identity="\"startedAt\":1767225600,\"startedAtMicros\":17,\"$second\":\"fixture-boot\"" ;;
    esac
    printf '{"mode":"unlimited","startedAt":"2026-01-01T00:00:00Z","extensions":[],"ownerPID":4242,"ownerIdentity":{"%s":%s,%s}}\n' "$field" "$first" "$identity" > "$LAB/home/session.json"
    printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
    run
    assert_restored
    quarantined=("$LAB/home/"session.json.unreadable-*)
    [[ -f "${quarantined[0]}" ]] || fail "conflicting ownerIdentity.$field lost evidence"
    /usr/bin/grep -q "ownerIdentity.$field is repeated" "$LAB/home/Logs/insomnia.log" || fail "conflicting ownerIdentity.$field was not diagnosed"
    printf 'PASS: conflicting ownerIdentity.%s (escaped: %s) restores and quarantines evidence\n' "$field" "$escaped"
  done
done

reset
unlimited
/usr/bin/plutil -insert ownerIdentity -json '{"startedAt":1767225600,"startedAtMicros":-1,"bootSession":"fixture-boot"}' "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_restored
printf 'PASS: invalid kernel identity cannot hold unlimited\n'

# Disappearance, unrelated PID reuse, another user, stopped/zombie app,
# reboot, or inability to verify the app all end unlimited operation.
for reason in gone unrelated wrong-user stopped zombie previous-boot unobservable; do
  reset
  unlimited
  case "$reason" in
    gone) ;;
    unrelated) printf 'Thu Jan  1 00:00:00 2026 S %s /bin/other\n' "$(id -u)" > "$LAB/process" ;;
    wrong-user) printf 'Thu Jan  1 00:00:00 2026 S 99999 %s\n' "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process" ;;
    stopped|zombie)
      stat=T; [[ "$reason" == zombie ]] && stat=Z
      printf 'Thu Jan  1 00:00:00 2026 %s %s %s\n' "$stat" "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process" ;;
    previous-boot)
      /usr/bin/plutil -insert ownerIdentity -json '{"startedAt":1767225600,"startedAtMicros":17,"bootSession":"old-boot"}' "$LAB/home/session.json"
      printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process" ;;
    unobservable) export PS_FAIL=1 ;;
  esac
  run
  unset PS_FAIL
  assert_restored
  # A later helper pass converges without repeating any owned undo.
  : > "$LAB/calls"
  run
  [[ "$RC" == 0 && ! -s "$LAB/calls" ]] || fail "$reason: second recovery did not converge"
  printf 'PASS: unlimited recovery after %s\n' "$reason"
done

reset
unlimited
/usr/bin/plutil -insert ownerIdentity -json '{"startedAt":1767225600,"startedAtMicros":17,"bootSession":"fixture-boot"}' "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_held
run --force
assert_restored
printf 'PASS: matching recorded identity held; force restores live unlimited\n'

# Old timed sessions retain deadlines even if their app disappears.
for mode in legacy timed; do
  reset
  printf '%s\n' '{"startedAt":"2026-01-01T00:00:00Z","endsAt":"9999-01-01T00:00:00Z","extensions":[]}' > "$LAB/home/session.json"
  [[ "$mode" == legacy ]] || /usr/bin/plutil -insert mode -string timed "$LAB/home/session.json"
  run
  assert_held
  [[ ! -s "$LAB/observations" ]] || fail 'timed recovery depended on app liveness'
  /usr/bin/plutil -replace endsAt -string '2026-01-01T00:00:00Z' "$LAB/home/session.json"
  run
  assert_restored
  printf 'PASS: %s timed deadlines remain effective\n' "$mode"
done

for malformed in legacy-no-deadline unknown-mode null-mode mode-newline owner-missing owner-string owner-overflow identity-incomplete unlimited-deadline; do
  reset
  unlimited
  case "$malformed" in
    legacy-no-deadline) /usr/bin/plutil -remove mode "$LAB/home/session.json" ;;
    unknown-mode) /usr/bin/plutil -replace mode -string future-mode "$LAB/home/session.json" ;;
    null-mode) /usr/bin/plutil -replace mode -json null "$LAB/home/session.json" ;;
    mode-newline) /usr/bin/plutil -replace mode -string $'unlimited\n' "$LAB/home/session.json" ;;
    owner-missing) /usr/bin/plutil -remove ownerPID "$LAB/home/session.json" ;;
    owner-string) /usr/bin/plutil -replace ownerPID -string 4242 "$LAB/home/session.json" ;;
    owner-overflow) /usr/bin/plutil -replace ownerPID -integer 4294971538 "$LAB/home/session.json" ;;
    identity-incomplete) /usr/bin/plutil -insert ownerIdentity -json '{"startedAt":1767225600}' "$LAB/home/session.json" ;;
    unlimited-deadline) /usr/bin/plutil -insert endsAt -string '9999-01-01T00:00:00Z' "$LAB/home/session.json" ;;
  esac
  printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
  run
  assert_restored
  quarantined=("$LAB/home/"session.json.unreadable-*)
  [[ -f "${quarantined[0]}" ]] || fail "$malformed: malformed bytes not quarantined"
  printf 'PASS: malformed %s cannot hold unlimited\n' "$malformed"
done

reset
printf '%s\n' '{"mode":"future-mode","mode":"unlimited","startedAt":"2026-01-01T00:00:00Z","extensions":[],"ownerPID":4242}' > "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_restored
quarantined=("$LAB/home/"session.json.unreadable-*)
[[ -f "${quarantined[0]}" ]] || fail 'duplicate session mode was not quarantined'
printf 'PASS: conflicting duplicate modes cannot hold unlimited\n'

# Failed undo preserves both the obligation and the interrupted session;
# the next pass retries rather than losing ownership.
reset
unlimited
export FAIL_UNDO=1
run
unset FAIL_UNDO
[[ "$RC" == 1 && -f "$LAB/home/session.json" && "$(<"$LAB/sleep")" == on ]] || fail 'failed restore lost session evidence'
[[ "$(/usr/bin/plutil -extract sleepDisabledByUs raw -o - "$LAB/home/state.json")" == true ]] || fail 'failed restore cleared obligation'
run
assert_restored
printf 'PASS: failed undo preserves obligations and retry converges\n'

# App-only obligations survive sleep recovery, ready for launch reconcile.
reset
unlimited
/usr/bin/plutil -insert savedDisplayBrightness -float 0.5 "$LAB/home/state.json"
run
[[ "$RC" == 1 && -f "$LAB/home/session.json" && "$(<"$LAB/sleep")" == off ]] || fail 'app-only obligation incorrectly discarded'
[[ "$(/usr/bin/plutil -extract savedDisplayBrightness raw -o - "$LAB/home/state.json")" =~ ^0\.50*$ ]] || fail 'saved brightness lost'
/usr/bin/plutil -remove savedDisplayBrightness "$LAB/home/state.json"
: > "$LAB/calls"
run
[[ "$RC" == 0 && ! -f "$LAB/home/session.json" && ! -s "$LAB/calls" ]] || fail 'app reconcile followed by helper repeated undo'
printf 'PASS: app-only journal entries survive and converge after reconcile\n'

# Relaunch wins the recovery lock: helper refuses while the app performs
# cleanup under that same inode, then observes the clean result on retry.
reset
unlimited
(
  exec 9<>"$LAB/home/.recovery.lock"
  /usr/bin/lockf -t 0 9
  printf 'ready\n' > "$LAB/ready"
  n=0
  until [[ -f "$LAB/release" ]] || (( n >= 500 )); do /bin/sleep 0.01; n=$((n + 1)); done
  printf '%s\n' '{"sleepDisabledByUs":false,"lowPowerSetByUs":false}' > "$LAB/home/state.json"
  /bin/rm "$LAB/home/session.json"
) &
app=$!
n=0
until [[ -f "$LAB/ready" ]] || (( n >= 500 )); do /bin/sleep 0.01; n=$((n + 1)); done
[[ -f "$LAB/ready" ]] || fail 'fixture app did not acquire lock'
run
[[ "$RC" == 75 && ! -s "$LAB/calls" && -f "$LAB/home/session.json" ]] || fail 'helper changed state while app held lock'
printf 'release\n' > "$LAB/release"
wait "$app"
run
[[ "$RC" == 0 && ! -s "$LAB/calls" && ! -f "$LAB/home/session.json" ]] || fail 'helper did not converge after app cleanup'
printf 'PASS: app/helper lock contention converges without duplicate undo\n'

# Helper wins first, then a deliberate new app session is published. The
# next helper must not undo the new owner's settings as stale recovery.
reset
unlimited
run
assert_restored
unlimited
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
printf 'on\n' > "$LAB/sleep"
printf '%s\n' '{"sleepDisabledByUs":true,"lowPowerSetByUs":false}' > "$LAB/home/state.json"
: > "$LAB/calls"
run
assert_held
printf 'PASS: helper-first cleanup does not undo a new owning app session\n'

reset
unlimited
/usr/bin/plutil -insert endsAt -json null "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_held
printf 'PASS: explicit unlimited null deadline matches decodeIfPresent\n'

reset
printf '{"mode":"future-mode","%su006dode":"unlimited","startedAt":"2026-01-01T00:00:00Z","extensions":[],"ownerPID":4242}\n' "\\" > "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_restored
printf 'PASS: escaped duplicate mode cannot bypass text validation\n'

reset
unlimited
/usr/bin/plutil -insert extra -json '{"mode":"unknown","ownerPID":0,"nested":[{"mode":"unlimited"}]}' "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_held
printf 'PASS: unknown nested session fields do not masquerade as mode\n'

reset
unlimited
printf '%s\n' '{"sleepDisabledByUs":"true"}' > "$LAB/home/state.json"
run
[[ "$RC" == 1 && ! -s "$LAB/calls" && -f "$LAB/home/session.json" ]] || fail 'malformed journal was touched during unlimited recovery'
printf 'PASS: malformed journal keeps all evidence without effects\n'

# The helper must never open a FIFO while it owns the recovery lock.
reset
/usr/bin/mkfifo "$LAB/home/session.json"
run
assert_restored
quarantined=("$LAB/home/"session.json.unreadable-*)
[[ -p "${quarantined[0]}" ]] || fail 'unreadable session FIFO was not preserved'
printf 'PASS: unreadable session FIFO is recovered without opening\n'

# A recovered timed session keeps its original start when made unlimited;
# the new app's matching identity, not that old start, proves ownership.
reset
unlimited
/usr/bin/plutil -insert ownerIdentity -json '{"startedAt":1767225601,"startedAtMicros":17,"bootSession":"fixture-boot"}' "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:01 2026 S %s %s\n' "$(id -u)" "$LAB/Insomnia.app/Contents/MacOS/Insomnia" > "$LAB/process"
run
assert_held
printf 'PASS: recovered timed session can become unlimited under its new owner\n'

reset
unlimited
owner_executable="$LAB/development build/Insomnia"
/usr/bin/plutil -insert ownerExecutable -string "$owner_executable" "$LAB/home/session.json"
/usr/bin/plutil -insert ownerIdentity -json '{"startedAt":1767225600,"startedAtMicros":17,"bootSession":"fixture-boot"}' "$LAB/home/session.json"
printf 'Thu Jan  1 00:00:00 2026 S %s %s\n' "$(id -u)" "$owner_executable" > "$LAB/process"
run
assert_held
printf 'PASS: recorded development executable with spaces remains alive\n'
