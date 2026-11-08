#!/bin/bash
# Makes the VM that mini-runner.sh clones for every Mac mini job: Cirrus
# Labs' macOS 27 image with Xcode 27, plus the GitHub Actions runner and
# tmux. Run it on the Mac mini, as the user that runs mini-runner.sh, once
# and again to move to a new image or runner version. docs/mac-mini-ci.md
# has the steps around it.
#
# The base VM gets no credentials of any kind. The runner is registered per
# job by mini-runner.sh, with a one-job token, inside a clone.
set -eu

TART=${TART:-$HOME/.local/bin/tart}
IMAGE=${INSOMNIA_MINI_IMAGE:-ghcr.io/cirruslabs/macos-golden-gate-xcode:27}
BASE=${INSOMNIA_MINI_BASE:-insomnia-ci-base}
RUNNER_VERSION=2.338.0
# sha256 of actions-runner-osx-arm64-2.338.0.tar.gz, as the release lists it.
RUNNER_SHA256=df4cebda25c86a886ed204e49fee63f5c2e7cec5f447b5c98440a826bbdf9df2
# The mini has 12 cores and 16 GB, and macOS runs at most two VMs. This
# leaves room for one lab VM next to a job.
CPUS=8
MEMORY_MB=8192

# Built under another name and renamed when finished, so mini-runner.sh
# never clones a half-made base VM.
WORK=$BASE-unfinished

if "$TART" list --quiet | grep -qx "$BASE"; then
  echo "$BASE exists; to remake it, run: $TART delete $BASE" >&2
  exit 1
fi
# Left by a run that failed part way.
"$TART" delete "$WORK" >/dev/null 2>&1 || true

"$TART" pull "$IMAGE"
"$TART" clone "$IMAGE" "$WORK"
"$TART" set "$WORK" --cpu "$CPUS" --memory "$MEMORY_MB"
"$TART" run --no-graphics "$WORK" >/dev/null 2>&1 &
run_pid=$!

# Ends the VM's tart run within about 30 s, however it is stuck.
end_run() {
  "$TART" stop "$WORK" --timeout 10 >/dev/null 2>&1 &
  for _ in $(seq 25); do
    kill -0 "$run_pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -TERM "$run_pid" 2>/dev/null || true
  sleep 3
  kill -KILL "$run_pid" 2>/dev/null || true
}
finished=
trap 'if [ -z "$finished" ]; then end_run; "$TART" delete "$WORK" >/dev/null 2>&1 || true; echo "deleted the unfinished $WORK" >&2; fi' EXIT

# The guest agent answers once macOS has booted and logged in.
ready=
for _ in $(seq 60); do
  if "$TART" exec "$WORK" true 2>/dev/null; then
    ready=1
    break
  fi
  sleep 5
done
if [ -z "$ready" ]; then
  echo "$WORK did not answer within 5 minutes" >&2
  exit 1
fi

# Inside the VM, as the image's admin user. The quoted heredoc reaches the
# guest's bash unexpanded; the two values come in as arguments.
"$TART" exec -i "$WORK" /bin/bash -s -- "$RUNNER_VERSION" "$RUNNER_SHA256" <<'GUEST'
set -eu
version=$1
sha=$2
cd "$HOME"
rm -rf actions-runner
curl -sSfL --retry 3 -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v$version/actions-runner-osx-arm64-$version.tar.gz"
echo "$sha  runner.tar.gz" | shasum -a 256 -c -
mkdir actions-runner
tar -xzf runner.tar.gz -C actions-runner
rm runner.tar.gz

# CI installs tmux in its job; here the job runs as the same user, but the
# image is made once, so a job does not wait on Homebrew.
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1 \
  /opt/homebrew/bin/brew install tmux

# A second fence inside the VM, under Softnet's on the host: no private or
# tailnet addresses, DNS allowed. Code that runs as admin can lift this one
# with sudo; it cannot lift Softnet's. The rules go at the end of
# /etc/pf.conf, because macOS loads that file at startup, replacing any
# rules loaded before it; the LaunchDaemon then turns pf on, which macOS
# leaves off.
sudo tee -a /etc/pf.conf >/dev/null <<'RULES'

# Insomnia CI: no private or tailnet addresses; DNS allowed.
pass out quick proto { udp tcp } to any port 53
block drop out quick to { 100.64.0.0/10, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 }
RULES
sudo /sbin/pfctl -n -f /etc/pf.conf
sudo tee /Library/LaunchDaemons/org.insomnia.ci-pf.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.insomnia.ci-pf</string>
  <key>ProgramArguments</key>
  <array><string>/sbin/pfctl</string><string>-E</string><string>-f</string><string>/etc/pf.conf</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

sw_vers
xcodebuild -version
/opt/homebrew/bin/tmux -V
./actions-runner/bin/Runner.Listener --version
# Everything above on disk before the host asks for a shutdown.
sync
GUEST

# Shut down from inside, so every write reaches the disk image. tart stop
# asks macOS to shut down, macOS answers with a dialog, and after the
# timeout tart turns the VM off: writes still in the guest's cache are
# lost. A base VM made that way had the runner but not tmux or pf.
"$TART" exec "$WORK" /bin/bash -c 'sync; sudo /sbin/shutdown -h now' >/dev/null 2>&1 &
shutdown_pid=$!
for _ in $(seq 60); do
  kill -0 "$run_pid" 2>/dev/null || break
  sleep 2
done
kill "$shutdown_pid" 2>/dev/null || true
if kill -0 "$run_pid" 2>/dev/null; then
  echo "$WORK did not shut down within 2 minutes" >&2
  exit 1
fi
# tart run exits 0 when the guest shuts down. Anything else is a crash, and
# the disk image may lack the guest's last writes.
if ! wait "$run_pid"; then
  echo "tart run for $WORK failed; not using it" >&2
  exit 1
fi

"$TART" rename "$WORK" "$BASE"
finished=1
echo "made $BASE from $IMAGE with runner $RUNNER_VERSION"
