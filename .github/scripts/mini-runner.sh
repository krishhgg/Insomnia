#!/bin/bash
# Runs the jobs of .github/workflows/mac-mini.yml on the owner's Mac mini,
# one job per throwaway VM. Each pass of the loop:
#   1. asks GitHub for a just-in-time runner, which takes one job and then
#      unregisters itself;
#   2. clones the VM that mini-base.sh made and boots it on Softnet;
#   3. starts the runner in the clone and waits for it to exit;
#   4. stops and deletes the clone, so no job sees another job's files, and
#      removes the runner's registration if it is still there.
# One runner always waits for a job, so a job starts within seconds, and
# the waiting VM takes one of the two VMs macOS allows. A LaunchAgent on the
# mini keeps this running; docs/mac-mini-ci.md has the setup. Run one loop
# at a time: each pass deletes every clone and runner the loop names.
set -u

REPO=${INSOMNIA_MINI_REPO:-krishhgg/Insomnia}
TART=${TART:-$HOME/.local/bin/tart}
BASE=${INSOMNIA_MINI_BASE:-insomnia-ci-base}
LOG_DIR=${INSOMNIA_MINI_LOGS:-$HOME/Library/Logs/insomnia-mini}
# The token that registers runners: a fine-grained token for this one
# repository with Administration read and write, in the login keychain.
KEYCHAIN_SERVICE=insomnia-mini-runner
LABEL=insomnia-mini
# From the moment the runner takes a job. The job's own timeout is 60
# minutes; this is the backstop if the runner hangs past it.
JOB_LIMIT=${INSOMNIA_MINI_JOB_LIMIT:-4500}
# Clones and runners this loop made, and only those.
NAME_PATTERN='^mini-[0-9]{8}-[0-9]{6}$'

# Softnet lets the VM reach the internet and the host's gateway address,
# and nothing else on the mini's networks. Its default already leaves out
# private ranges; the tailnet's range is named as well, so it stays out
# whatever Softnet counts as private. Without Softnet the VM would share the
# mini's network, tailnet included, so the loop refuses to start.
if ! command -v softnet >/dev/null 2>&1; then
  echo "softnet is not on PATH; see docs/mac-mini-ci.md" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# curl with the token, for GitHub's REST API for this repository: method,
# path, then more curl arguments. The token goes to curl through its config
# on stdin, never in an argument list that ps shows.
github_curl() {
  local token method=$1 path=$2
  shift 2
  token=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a github -w) || {
    log "no token in the keychain under $KEYCHAIN_SERVICE"
    return 1
  }
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS --retry 2 --max-time 60 --config - -X "$method" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "$@" "https://api.github.com/repos/$REPO/$path"
}

# Removes a runner's registration. GitHub answers 404 for one that is
# already gone, as a just-in-time runner is after its job.
unregister() {
  local status
  status=$(github_curl DELETE "actions/runners/$1" -o /dev/null -w '%{http_code}') || status=
  case $status in
    204 | 404) return 0 ;;
  esac
  log "could not remove runner $1 (HTTP ${status:-error}); the next pass tries again"
  return 1
}

# Registrations an interrupted pass left: the runner's VM is gone, but its
# registration stays until it is removed. Runs only when no clone exists,
# so none of these can be running a job. All pages are read before any
# removal, since a removal moves the later entries up a page.
unregister_leftovers() {
  local runners count id ids='' page=1
  while [ "$page" -le 50 ]; do
    runners=$(github_curl GET "actions/runners?per_page=100&page=$page" -f) || {
      log "could not list runners"
      return 1
    }
    ids="$ids $(printf '%s' "$runners" | /usr/bin/jq -r --arg p "$NAME_PATTERN" \
      '.runners[] | select(.name | test($p)) | .id')"
    count=$(printf '%s' "$runners" | /usr/bin/jq '.runners | length')
    # A short page is the last; so is one jq could not read.
    [ "${count:-0}" -ge 100 ] 2>/dev/null || break
    page=$((page + 1))
  done
  for id in $ids; do
    log "removing runner $id, left from an earlier pass"
    unregister "$id"
  done
}

# Waits up to 30 s for the given processes to exit, then ends them. They
# are the tart processes of one clone.
reap() {
  local pid
  for _ in $(seq 30); do
    kill -0 "$@" 2>/dev/null || return 0
    sleep 1
  done
  for pid in "$@"; do
    kill -TERM "$pid" 2>/dev/null && log "ending tart process $pid"
  done
  sleep 10
  for pid in "$@"; do
    kill -KILL "$pid" 2>/dev/null
  done
  return 0
}

# A clone's tart processes, found by their command line, for a clone that
# an earlier run of this script started. The process name must be tart, so
# another program that names the clone in its arguments is left alone.
tart_pids() {
  local pid
  for pid in $(pgrep -U "$(id -u)" -f "tart (run|exec) .*$1"); do
    case $(ps -o comm= -p "$pid") in
      */tart | tart) echo "$pid" ;;
    esac
  done
}

# Stops and deletes a clone, then checks that tart no longer lists it.
# Further arguments are the clone's tart processes, which must exit before
# the clone can be deleted; any others still running are found by name.
remove_vm() {
  local name=$1 vms pid
  local pids=()
  shift
  "$TART" stop "$name" --timeout 10 >/dev/null 2>&1
  pids=(${@+"$@"})
  while read -r pid; do
    pids+=("$pid")
  done < <(tart_pids "$name")
  if [ ${#pids[@]} -gt 0 ]; then
    reap "${pids[@]}"
  fi
  if [ $# -gt 0 ]; then
    wait "$@" 2>/dev/null
  fi
  "$TART" delete "$name" >/dev/null 2>&1
  vms=$("$TART" list --quiet) || {
    log "tart list failed after deleting $name"
    return 1
  }
  if printf '%s\n' "$vms" | grep -qx "$name"; then
    log "could not delete $name"
    return 1
  fi
}

# Deletes every clone this loop made. A crash, a reboot or a failed pass
# can leave one. No job starts until all are gone.
remove_leftovers() {
  local vms vm left=0
  vms=$("$TART" list --quiet) || {
    log "tart list failed"
    return 1
  }
  for vm in $(printf '%s\n' "$vms" | grep -E "$NAME_PATTERN"); do
    log "removing $vm, left from an earlier pass"
    remove_vm "$vm" || left=1
  done
  return "$left"
}

one_job() {
  local name response config id run_pid exec_pid runner_log started ready
  local result=0
  name="mini-$(date '+%Y%m%d-%H%M%S')"
  runner_log="$LOG_DIR/$name.log"

  response=$(github_curl POST actions/runners/generate-jitconfig -f --data \
    "{\"name\":\"$name\",\"runner_group_id\":1,\"labels\":[\"self-hosted\",\"macOS\",\"ARM64\",\"$LABEL\"],\"work_folder\":\"_work\"}") || {
    log "GitHub gave no runner config"
    return 1
  }
  # The id first: with it, a pass that stops later can still unregister.
  if ! id=$(printf '%s' "$response" | plutil -extract runner.id raw -o - -); then
    log "could not read the runner id GitHub sent"
    return 1
  fi
  if ! config=$(printf '%s' "$response" | plutil -extract encoded_jit_config raw -o - -); then
    log "could not read the runner config GitHub sent"
    unregister "$id"
    return 1
  fi

  if ! "$TART" clone "$BASE" "$name"; then
    log "could not clone $BASE"
    unregister "$id"
    return 1
  fi
  "$TART" run --no-graphics --net-softnet "--net-softnet-block=100.64.0.0/10" \
    "$name" >>"$runner_log" 2>&1 &
  run_pid=$!

  ready=
  for _ in $(seq 60); do
    if "$TART" exec "$name" true 2>/dev/null; then
      ready=1
      break
    fi
    kill -0 "$run_pid" 2>/dev/null || break
    sleep 5
  done
  if [ -z "$ready" ]; then
    log "$name did not boot"
    remove_vm "$name" "$run_pid"
    unregister "$id"
    return 1
  fi

  # The config reaches the guest on stdin, so it is not in the host's ps.
  # The single quotes are on purpose: the guest's bash expands them.
  log "$name (runner $id) is waiting for a job"
  # shellcheck disable=SC2016
  printf '%s' "$config" |
    "$TART" exec -i "$name" /bin/bash -c 'config=$(cat); cd "$HOME/actions-runner" && exec ./run.sh --jitconfig "$config"' \
      >>"$runner_log" 2>&1 &
  exec_pid=$!

  started=
  while kill -0 "$exec_pid" 2>/dev/null; do
    if [ -z "$started" ] && grep -q 'Running job' "$runner_log"; then
      started=$SECONDS
      log "$name: $(grep -m1 'Running job' "$runner_log")"
    fi
    if [ -n "$started" ] && [ $((SECONDS - started)) -gt "$JOB_LIMIT" ]; then
      log "$name ran past $JOB_LIMIT s; stopping it"
      break
    fi
    if ! kill -0 "$run_pid" 2>/dev/null; then
      log "$name stopped on its own"
      break
    fi
    sleep 10
  done
  log "$name: $(grep 'completed with result' "$runner_log" | tail -n 1)"
  remove_vm "$name" "$exec_pid" "$run_pid" || result=1
  # Also when the job ran: a runner whose VM stopped mid-job is still
  # registered.
  unregister "$id"
  return "$result"
}

while :; do
  # A failed pass waits a minute, so a missing token, a GitHub outage or a
  # clone that won't delete doesn't turn into a tight loop. While a clone
  # is left, no new job starts.
  if remove_leftovers; then
    unregister_leftovers
    one_job && continue
  fi
  sleep 60
done
