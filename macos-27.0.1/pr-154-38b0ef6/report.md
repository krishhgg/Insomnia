# PR 154 recovery validation with SIP disabled

The external recovery agent installed correctly, kept its loaded job across repeated session starts, recovered an abandoned session after a restart, and refused an edited sealed script. Login Items still displayed `sh` with a generic executable icon. The Insomnia name and icon are not supplied by the external fallback selected on this machine.

## Setup

The test ran in a macOS 27.0.1 VM on the maintainer's Mac mini. All times below are UTC on 2026-11-07. The owner's MacBook received no UI input, screenshots, app launches, or changes to its Insomnia installation or configuration.

| Item | Recorded value |
| --- | --- |
| Repository and pull request | `krishhgg/Insomnia`, PR 154 |
| Branch | `integration/recovery-launcher` |
| Commit | `38b0ef6b37fe706bd3d9d8a1d0c8754a5f4fd852` |
| Operating system | macOS 27.0.1, build `26A434`, arm64 |
| SIP before and after restart | `System Integrity Protection status: disabled.` |
| App version | `0.1.0`, bundle version `1` |
| Signing | Ad-hoc; TeamIdentifier not set |
| Supplied archive | `Insomnia-pr154-38b0ef6b.zip` |
| Supplied and measured archive SHA-256 | `ed64a4f94a89285fe0b31c98219b3e5be601dfa8e922f39ab94a2cce6453a86e` |
| Supplied, installed, and final restored CDHash | `602acf9aa689105e02a2c211e4dd98c876b3097f` |
| Previous installed app | `~/Applications/Insomnia.app`, version `0.1.0`, bundle version `1` |
| Previous installed CDHash | `10e7c10d4a8d46bda875b8555bb173406ffa368f` |
| Previous recovery agent | External `/bin/sh` verifier, 60-second interval, 883 runs, last exit 0 |
| Previous journal and power state | Clean, no session, SleepDisabled 0, app absent |
| Mini free space at start | 3.1 GiB |
| Mini free space at end | 2.8 GiB |

The head's recovery-agent section in `docs/install.md`, backstop specification in `docs/spec.md`, additions to `docs/releasing.md` relative to `origin/integration/wave1-base`, and the plist-writing section of `scripts/install.sh` were read before installation. The source checkout stayed unchanged. The bundle and the head's archived `scripts/` were staged without downloads in the VM, the archive checksum was checked there, and `ditto` unpacked it outside `/tmp`. Both installations used the head's `scripts/install.sh --app <unpacked>/Insomnia.app --allow-unverified-origin`.

The VM was exclusively claimed and fenced before installation, and fenced again after restart. Disk checks after staging, installation, sessions, restart, and reinstallation stayed between 2.8 and 3.1 GiB, above the brief's 1.5 GiB stop threshold. No VM was cloned, created, or deleted. Nothing was posted to GitHub or pushed.

## Checks

| Check | Result | Evidence |
| --- | --- | --- |
| 1. SIP-disabled installation and periodic recovery | Pass. External `/bin/sh` verifier; no AssociatedBundleIdentifiers or SpawnConstraint. RunAtLoad and StartInterval 60. Initial idle runs reached exit 0 with a clean journal and no app process. | [Installer and plist](captures/06-install.txt), [first completed run](captures/07-installed-idle-and-row.txt), [second idle run](captures/10-arm-before.txt) |
| 2. Login Items before upgrade, after upgrade, and after restart | Observed fallback limitation. All three showed `sh`, a generic black executable icon, `Not running in background`, and an enabled switch. No Insomnia name, app icon, or unidentified-developer subtitle appeared. | [Before](pictures/login-before.png), [installed](pictures/login-installed.png), [restarted](pictures/login-restarted.png), [attribution record](captures/16-restart-picture-and-attribution.txt) |
| 3. Session arm and second arm on the same build | Pass for job continuity. Runs were 2 before arm, 2 after first arm, 3 during second arm, and 3 after that run completed. The job path, coalition IDs, properties, plist checksum, external command and interval stayed the same. No second background-item notification was returned in the captured system log. | [Before](captures/10-arm-before.txt), [first](captures/11-first-arm.txt), [second](captures/12-second-arm.txt), [completed](captures/13-second-arm-complete.txt) |
| 4. Abandoned session recovery after restart | Pass. The deadline was 22:28:18. The agent restored sleep at 22:28:45 without the app. A further scheduled run completed with exit 0. SleepDisabled 0, clean journal, session.json absent. | [Abandon and restart](captures/14-abandon-and-restart.txt), [before deadline](captures/15-after-restart-before-deadline.txt), [recovery](captures/18-first-recovery-interval.txt), [confirmation](captures/19-recovery-confirmed.txt) |
| 5. Edited sealed script and reinstall | Pass. One comment was appended to the installed backstop.sh. Kickstart produced exit 1 and a strict-signature refusal, with zero backstop body log lines after the edit. Reinstalling the pristine bundle restored exit 0 and the matching CDHash. | [Refusal](captures/20-tamper-refusal.txt), [reinstall](captures/21-reinstall-after-tamper.txt), [final signature](captures/23-final-evidence.txt) |
| 6. Five warm launches with a clean journal | Pass. Each exact ProgramArguments array from the plist ran by hand under `/usr/bin/time -p` and exited 0. Elapsed times were 0.14, 0.12, 0.12, 0.12, and 0.13 seconds. | [Timings](captures/22-five-warm-runs.txt), [timing script](scripts/warm-cost.py) |

## Installation and session evidence

The installer printed:

```text
LaunchAgent will require: cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
LaunchAgent com.insomnia.backstop loaded (launchctl print confirms); ~/Library/LaunchAgents/com.insomnia.backstop.plist published
```

It emits no separate message naming the SIP fallback. The path selection is established by the disabled SIP status and the actual plist and loaded-job output:

```text
program = /bin/sh
run interval = 60 seconds
last exit code = 0
```

The plist's ProgramArguments start `/bin/sh -c`, run `/usr/bin/codesign --verify --strict` against the pinned cdhash, and execute `/bin/bash` with the sealed `Contents/Resources/backstop.sh` only on success. AssociatedBundleIdentifiers and SpawnConstraint are absent. After restart, macOS reported its own managed LWCR for the Apple shell, with signing identifier `com.apple.sh`. That is not an explicit app-cdhash SpawnConstraint in the installed plist.

Both `start 600` requests succeeded, and each was ended with `--session end`. SleepDisabled read 1 during each session and 0 after ending it. Across both arms the plist SHA-256 stayed:

```text
0fe5965ca252580c621eb15ad10341ddc3a451b9a811bbd81de2cad3fd010147
```

The loaded job retained its candidate path and coalition IDs 6284 and 6285. Its properties stayed:

```text
properties = runatload | inferred program | system service | tle system
```

The second-arm capture caught the scheduled third run in progress, with PID 1255 and immediate reason `interval`. The follow-up capture recorded that same run count with last exit 0 and no PID. These observations support that arm did not bootout and bootstrap the job.

## Restart recovery

At 22:26:18 a 120-second session was requested. After the sleep-guard readback completed, the app was killed with SIGKILL at 22:26:23. Before restarting, SleepDisabled was 1, state.json recorded `sleepDisabledByUs: true`, and session.json saved `startedAt: 2026-11-07T22:26:18Z` and `endsAt: 2026-11-07T22:28:18Z`.

The VM returned normally and was fenced again at 22:26:46. No manual start was needed. The changed boot-session UUID confirmed the restart. At 22:27:15, before the deadline, the app was absent, both journal files survived, SleepDisabled remained 1, and the recovery agent had completed its login run with exit 0.

At the first scheduled run after the deadline:

```text
2026-11-07T22:28:45Z [info] backstop: session expired (endsAt=2026-11-07T22:28:18Z); restoring from journal
2026-11-07T22:28:45Z [info] backstop: pmset -a disablesleep 0 ok
2026-11-07T22:28:45Z [info] backstop: journal cleared
```

At 22:28:57, the app was still absent, SleepDisabled was 0, session.json was gone, and the agent showed 3 runs and last exit 0. At 22:29:59, after the second scheduled run following the deadline, it showed 4 runs and last exit 0. The journal was:

```json
{"savedAudioOutputs":[],"appNapOverrides":[],"sleepDisabledByUs":false,"dockerFrozen":false,"lowPowerSetByUs":false,"frozenProcesses":[]}
```

No app launch appears in the excerpt after the pre-restart app launch at 22:24:59. Independent process checks throughout the recovery also found no Insomnia process.

## Findings

Login Items attribution remains `sh` on the supported SIP-disabled fallback. Reopening System Settings after installation and checking again after restart gave the same row and generic icon. The background-task record identifies `8.com.insomnia.backstop`, Name `sh`, Executable Path `/bin/sh`, and the installed backstop plist. The visible row said `Not running in background`; the job's recorded periodic exits show that its short runs were still occurring. This is a fallback appearance limitation, consistent with the head deliberately retaining the external verifier when SIP is disabled. It does not demonstrate the Insomnia branding promised for the native path.

The sealed-resource protection worked as required:

```text
2026-11-07T22:30:17Z [error] backstop agent: ~/Applications/Insomnia.app does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: ~/Applications/Insomnia.app: a sealed resource is missing or invalid
backstop body lines after edit: 0
```

The kickstarted job's last exit code was 1. The verifier's `&& exec` structure and the refusal record support that the script body was not executed. Reinstallation's next RunAtLoad completed with exit 0; all five subsequent manual invocations also exited 0. No recovery correctness failure was observed in this run.

## Launch cost

The journal was clean and session.json absent. The existing verifier and script had already run repeatedly, so these are warm measurements. The timing script reads the installed plist rather than reconstructing its quoting.

| Warm run | Elapsed seconds | User seconds | System seconds | Exit |
| --- | --- | --- | --- | --- |
| 1 | 0.14 | 0.04 | 0.07 | 0 |
| 2 | 0.12 | 0.03 | 0.06 | 0 |
| 3 | 0.12 | 0.03 | 0.06 | 0 |
| 4 | 0.12 | 0.03 | 0.06 | 0 |
| 5 | 0.13 | 0.03 | 0.06 | 0 |

The mean elapsed time was 0.126 seconds and the median was 0.12 seconds. No native-command comparison was attempted.

## Limits and test adjustments

- SIP-enabled native execution was not tested. SpawnConstraint enforcement, `OS_REASON_CODESIGNING` for a replaced executable, restoring an older executable under a native plist, and native Login Items attribution still need a real Mac with SIP enabled. SIP was not changed.
- No continuous notification recording was made. The captured background-task log window returned no second background-item notification. App notification authorization was denied in this VM, as shown in the log. The unchanged job and plist are stronger evidence for no re-registration than the absence of a visible notification alone.
- The head does not implement top-level `--help`. Following the brief's requested invocation opened the app instead of printing help. It was quit before the session checks. `Insomnia --session --help` printed `usage: Insomnia --session start <seconds> | extend <seconds> | end | status` and exited 64. This was a test-setup adjustment, not attributed as a recovery-agent regression.
- The first System Settings query ran before its window existed. The retry after waiting for the window succeeded. All three retained pictures were opened and inspected; each contains only the recovery-agent row. No background-task database reset was performed.
- VM results do not establish real hardware behavior for battery, lid, Wi-Fi, thermal, or physical sleep transitions. The tested sleep result is the reported SleepDisabled setting and journal recovery.
- Home directories are replaced with `~`; account and inherited socket details are redacted from captures. Other fields, including launchctl properties, arguments, PIDs, run counts, exit statuses, and LWCR, are preserved. Files under `private/` are orchestration records and are not review attachments.

## Final state

The head bundle remains installed at `~/Applications/Insomnia.app`, passes strict verification, and has the supplied CDHash. The matching external recovery job remains loaded with last exit 0. There is no session or app process, the journal is clean, and SleepDisabled is 0. Test configuration was moved aside and removed with the VM work folder, so the next launch uses defaults. No test temporary files remained in `/tmp` or the installer's temporary location. The VM work folder and mini staging folder were deleted, the claim was released, and the VM was left running. The mini had 3.1 GiB free at the start and 2.8 GiB at the end.

The [run log](run.log), [log excerpts](insomnia.log-excerpts.txt), [captures](captures/), and [test scripts](scripts/) accompany this report. The three inspected pictures are [before installation](pictures/login-before.png), [after installation](pictures/login-installed.png), and [after restart](pictures/login-restarted.png).

## Plist captures

The previous installation:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.insomnia.backstop</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2&gt;&amp;1)" &amp;&amp; exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" &gt;&gt; "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1</string>
		<string>sh</string>
		<string>cdhash H"10e7c10d4a8d46bda875b8555bb173406ffa368f"</string>
		<string>~/Applications/Insomnia.app</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>60</integer>
</dict>
</plist>
```

The head installation, also confirmed after restoring the pristine bundle:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.insomnia.backstop</string>

	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2&gt;&amp;1)" &amp;&amp; exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" &gt;&gt; "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1</string>
		<string>sh</string>
		<string>cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"</string>
		<string>~/Applications/Insomnia.app</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>60</integer>
</dict>
</plist>
```

## Launchctl captures

These are complete captured job blocks with the privacy substitutions described above.

### Before installation

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-91351.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"10e7c10d4a8d46bda875b8555bb173406ffa368f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 883
	last exit code = 0

	resource coalition = {
		ID = 6024
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 6025
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```

### After the first completed idle run

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-796.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 1
	last exit code = 0

	resource coalition = {
		ID = 6284
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 6285
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```

### Before the first arm

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-796.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 2
	last exit code = 0

	resource coalition = {
		ID = 6284
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 6285
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```

### After the first arm

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-796.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 2
	last exit code = 0

	resource coalition = {
		ID = 6284
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 6285
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```

### After ending the first session

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-796.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 2
	last exit code = 0

	resource coalition = {
		ID = 6284
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 6285
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```

### During the second arm

```text
gui/501/com.insomnia.backstop = {
	active count = 1
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-796.plist
	type = LaunchAgent
	state = running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 3
	pid = 1255
	immediate reason = interval
	forks = 13
	execs = 3
	initialized = 1
	trampolined = 1
	started suspended = 0
	proxy started suspended = 0
	checked allocations = 0 (queried = 1)
	checked allocations reason = no host
	checked allocations flags = 0x0
	last exit code = 0

	resource coalition = {
		ID = 6284
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 6285
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = running
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```

### After the second-arm run completed

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-796.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 3
	last exit code = 0

	resource coalition = {
		ID = 6284
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 6285
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```

### After restart, before the deadline

```text
No capture available
```

### After two intervals following the deadline

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/com.insomnia.backstop.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	LWCR = {
		"reqs" => {
			"signing-identifier" => "com.apple.sh"
			"validation-category" => 1
		}
		"vers" => 1
		"comp" => 1
		"ccat" => 0
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 4
	last exit code = 0

	resource coalition = {
		ID = 571
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 572
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | managed LWCR | has LWCR | tle system
}
```

### After refusing the edited resource

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/com.insomnia.backstop.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	LWCR = {
		"reqs" => {
			"signing-identifier" => "com.apple.sh"
			"validation-category" => 1
		}
		"vers" => 1
		"comp" => 1
		"ccat" => 0
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 5
	last exit code = 1

	resource coalition = {
		ID = 571
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 572
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | managed LWCR | has LWCR | tle system
}
```

### After restoring the pristine bundle

```text
gui/501/com.insomnia.backstop = {
	active count = 0
	path = ~/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-1292.plist
	type = LaunchAgent
	state = not running

	program = /bin/sh
	arguments = {
		/bin/sh
		-c
		r="$(/usr/bin/codesign --verify --strict "-R=$1" "$2" 2>&1)" && exec /bin/bash "$2/Contents/Resources/backstop.sh"; mkdir -p "$HOME/Library/Logs/Insomnia"; printf "%s [error] backstop agent: %s does not satisfy the pinned code requirement; backstop.sh not run. Reinstall Insomnia (scripts/install.sh). codesign: %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$(printf %s "$r" | tr "\n" " ")" >> "$HOME/Library/Logs/Insomnia/insomnia.log"; exit 1
		sh
		cdhash H"602acf9aa689105e02a2c211e4dd98c876b3097f"
		~/Applications/Insomnia.app
	}

	inherited environment = {
		<inherited socket redacted>
	}

	default environment = {
		PATH => /usr/bin:/bin:/usr/sbin:/sbin
	}

	environment = {
		OSLogRateLimit => 64
		XPC_SERVICE_NAME => com.insomnia.backstop
	}

	domain = gui/501 [100002]
	asid = 100002
	minimum runtime = 10
	exit timeout = 5
	runs = 1
	last exit code = 0

	resource coalition = {
		ID = 1020
		type = resource
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	jetsam coalition = {
		ID = 1021
		type = jetsam
		state = active
		active count = 1
		name = com.insomnia.backstop
	}

	spawn type = daemon (3)
	jetsam priority = 40
	jetsam memory limit (active) = (unlimited)
	jetsam memory limit (inactive) = (unlimited)
	jetsamproperties category = daemon
	jetsam thread limit = 32
	cpumon = default
	run interval = 60 seconds
	job state = exited
	sanitizer flags = 0x0

	properties = runatload | inferred program | system service | tle system
}
```
