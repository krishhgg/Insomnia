# Mac mini CI

The owner's Mac mini runs `.github/workflows/mac-mini.yml`: the release
build and the whole `swift test` suite, in a macOS 27 VM with Xcode 27. Each
job gets a fresh VM, and the VM is deleted when the job ends. The suite
there includes `UIStatusTests`, `UIStartupTests` and `KeychainStoreTests`,
which contributors and the maintainer skip on their own Macs.

It adds to the GitHub-hosted jobs in `ci.yml`; it doesn't replace them. It
is not a required check. To make it one, add `Swift test (Mac mini, macOS 27
VM)` to the main ruleset and to `CI_CHECKS` in
`.github/scripts/merge-gate.sh`. The job already writes the "Tested merge"
note that `merge-gate.sh check` reads for each entry there. Wait for a week
of clean runs first. Once it is required, no pull request can merge while
the mini is off.

## How a job runs

`.github/scripts/mini-runner.sh` runs on the mini in a loop:

1. It asks GitHub for a just-in-time runner. That runner takes one job and
   then unregisters itself. The request uses a token from the mini's login
   keychain; the token never enters a VM.
2. It clones the base VM, `insomnia-ci-base`, and boots the clone on
   Softnet. A clone is a copy-on-write copy, so it takes seconds and little
   disk.
3. It starts the runner in the clone and waits for it to exit. One runner
   always waits for a job, so a job starts within seconds.
4. It stops and deletes the clone, checks that Tart no longer lists it, and
   removes the runner's registration if GitHub still has it. A job that
   runs 75 minutes from pickup is stopped too.

Each pass starts by deleting any clone and runner registration an earlier
pass left, after a crash or a reboot. It ends a leftover clone's `tart`
processes first, found by the clone's name. If a clone won't delete, no new job
starts; the loop logs it and tries again each minute. Run one loop at a
time, since each pass deletes every clone the loop names.

`.github/scripts/mini-base.sh` makes the base VM from Cirrus Labs'
`macos-golden-gate-xcode:27` image. It adds the GitHub Actions runner
(pinned version and sha256), tmux, and a packet filter. The base VM holds no
credentials.

## What a job can reach

A job runs a pull request's code. For a pull request from a fork, GitHub
gives the job a read-only token and no secrets. Three fences cover the rest:

- **Approval.** Settings > Actions > General > "Approval for running fork
  pull request workflows from contributors" is set to "Require approval for
  all external contributors". The owner reads the diff, then approves the
  run.
- **Softnet**, on the mini. With `tart run --net-softnet`, Softnet's
  documented default lets the VM reach the internet and its gateway address
  on the mini, and nothing else: no tailnet, no home network, no other VM.
  `mini-runner.sh` also blocks the
  tailnet's range, 100.64.0.0/10, by name. Without Softnet the loop refuses
  to start. On the default shared network a VM reached the MacBook's SSH and
  screen sharing ports over the tailnet (tested 2026-10-16).
- **pf in the VM.** The base VM blocks private and tailnet addresses itself.
  The job's first step fails if pf is off or the block is missing. Job code
  runs as the VM's admin user and can lift this one; it cannot lift
  Softnet's.

The gateway address is the mini itself, so a job can reach any port the mini
listens on from all interfaces. Keep the mini's SSH on keys only, and its
screen sharing off.

## Setup on the mini

Done once, as the user that runs the loop. Steps marked (sudo) need the
mini's administrator password.

1. Install Tart 2.41.1 or later in `~/Applications/tart.app` and link
   `~/.local/bin/tart` to `tart.app/Contents/MacOS/tart`.
2. Install Softnet (sudo). It needs root to create its network, so it is
   setuid root and must sit in a folder only root can write:

   ```sh
   curl -sSfL -o /tmp/softnet.tar.gz https://github.com/cirruslabs/softnet/releases/download/0.24.1/softnet.tar.gz
   echo "8ff8ff099c2b5ac1b1128e7999c4a730ac85f486c8a4cb0239eb98432859a0f7  /tmp/softnet.tar.gz" | shasum -a 256 -c -
   tar -xzf /tmp/softnet.tar.gz -C /tmp softnet
   sudo mkdir -p /usr/local/bin
   sudo install -o root -g wheel -m 4755 /tmp/softnet /usr/local/bin/softnet
   ```

3. Turn off password logins for SSH (sudo), after checking that key login
   works:

   ```sh
   printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' | sudo tee /etc/ssh/sshd_config.d/050-keys-only.conf
   ```

   macOS starts sshd for each connection, so the next login reads it.

4. Make the base VM: `.github/scripts/mini-base.sh`. It pulls about 69 GB
   and needs about 90 GB free.
5. Make a fine-grained token on GitHub: repository access "Only select
   repositories" with this repository, permission "Administration: Read and
   write" (registering a runner needs it), and an expiry. Put it in the
   keychain; the command asks for it:

   ```sh
   security add-generic-password -s insomnia-mini-runner -a github -w
   ```

6. On GitHub, set fork run approval to "Require approval for all external
   contributors" (Settings > Actions > General).
7. Start the loop from a LaunchAgent, so it restarts after a crash or a
   login. Save this as `~/Library/LaunchAgents/org.insomnia.mini-runner.plist`,
   with the path of your checkout of this repository on `main`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key><string>org.insomnia.mini-runner</string>
     <key>ProgramArguments</key>
     <array>
       <string>/bin/bash</string>
       <string>/Users/YOU/insomnia-lab/Insomnia/.github/scripts/mini-runner.sh</string>
     </array>
     <key>EnvironmentVariables</key>
     <dict>
       <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
     </dict>
     <key>RunAtLoad</key><true/>
     <key>KeepAlive</key><true/>
     <key>StandardOutPath</key><string>/Users/YOU/Library/Logs/insomnia-mini/loop.log</string>
     <key>StandardErrorPath</key><string>/Users/YOU/Library/Logs/insomnia-mini/loop.log</string>
   </dict>
   </plist>
   ```

   Then `mkdir -p ~/Library/Logs/insomnia-mini` and
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.insomnia.mini-runner.plist`.

The mini must not sleep (`pmset -g` shows `sleep 0`), and its user must stay
logged in, since a LaunchAgent runs only in a login session.

## Day to day

- **Logs.** `~/Library/Logs/insomnia-mini/loop.log` has one line per job
  step; `mini-<time>.log` next to it has the VM's and the runner's output.
  Delete old ones by hand.
- **Stop.** `launchctl bootout gui/$(id -u)/org.insomnia.mini-runner`. A
  job in progress fails on GitHub, and the next start deletes its VM.
- **New image or runner version.** Stop the loop, `tart delete
  insomnia-ci-base`, update the pins in `mini-base.sh` if needed, run it,
  and start the loop.
- **Token expiry.** When the token expires, the loop logs "GitHub gave no
  runner config" once a minute. Make a new token and replace it with the
  `security add-generic-password` command plus `-U`.
- **Two VMs at most.** macOS runs at most two VMs at a time, and the waiting
  runner's VM is one of them. Stop the loop to run two lab VMs.
