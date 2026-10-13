# Auto — keep working until registered agent work finishes

Auto implements point 1 of [issue #57](https://github.com/krishhgg/Insomnia/issues/57).
It is **not** Always On, remote wake, or automatic discovery of every process
with an agent-like name. Only explicitly registered productive jobs count.

## Use it

1. Build/install Insomnia as described in [install.md](install.md). Actual
   lid-close prevention requires the existing installer’s narrow sudoers rule
   and verified launchd recovery agent; a bare `swift build` cannot grant that.
2. Either click (or Control-click) toggles the Liquid Glass quick menu:
   click to open, click again to close, without changing the mode. Auto starts **enabled after clean launch recovery**,
   unless a previous timed session resumes. Choose **Enable Auto** to resume
   after a manual/safety pause; end a timed session first. The menu and native Settings use the UI from
   [PR #63](https://github.com/krishhgg/Insomnia/pull/63) at `e3840ca`;
   there is no inline Auto / Timer selector.
3. Run a finite terminal agent job from this checkout:

   ```bash
   ./scripts/agent-run.sh --name 'Codex: issue 57' -- codex exec 'Investigate issue 57'
   ./scripts/agent-run.sh --name 'Claude: tests' -- claude -p 'Review the failing tests'
   ```

   The wrapper defaults to `.build/debug/Insomnia`. Set `INSOMNIA_BIN` to a
   built/installed executable to use another build. A packaged wrapper is at
   `Insomnia.app/Contents/Resources/agent-run.sh` and locates its sibling app
   executable. Normal agent authentication, permissions and sandbox choices
   remain yours: the wrapper does not bypass them.
4. Auto shows **only the eye** in the menu bar—no adjacent text or rolling
   lease countdown. While armed, it rests **open for three seconds**, briefly closes,
   then reopens using the same full spring transitions as the normal eye,
   with a brief closed beat rather than cutting the animation short.
   Reduce Motion keeps it steadily open. Enabling/disabling Auto plays the
   same soft on/off sounds as timers; job transitions and menu opening are silent.
   This animation signals armed Auto, **not** a confirmed sleep hold: hover
   or open quick actions to read **Auto: idle**, **Auto: working**,
   **Auto: checking**, **Auto: paused** or **Restoring sleep**. The quick
   menu names current jobs; **Status details** includes owner PIDs and short
   activity IDs. Auto shows work status instead of a misleading rolling timer. **Before closing
   the lid, wait for Auto to show the job and sleep held:** registration is
   asynchronous (normally a two-second scan plus power-command latency), not
   an acknowledgment that the sleep guard is already installed. Completion or
   failure of the command removes that job; the last job finishing releases
   Insomnia’s hold, normally within the next two-second scan. Auto stays
   armed for another job, but holds nothing while idle.

The wrapper follows **actual command exit**, not CPU use, output silence,
window visibility, or terminal foreground status. Multiple jobs are independent.
Use it for `codex exec` and Claude Code’s `-p`/print mode, **not** an interactive
`codex`/`claude` shell or a server that waits forever for another prompt.
Likewise, do not wrap a shell that exits after launching detached agent work:
register the actual work owner through the API instead. The wrapper preserves
stdin, stdout/stderr, arguments and the command’s exit status. It does not
manage or restart the command; cancelling/disconnecting the wrapper may leave
its command running, but does not promise to keep that orphan awake.

References for the non-interactive CLI modes:
[Codex exec](https://developers.openai.com/codex/noninteractive),
[Claude Code print mode](https://code.claude.com/docs/en/headless).

## Explicit local activity API

Interactive agents and custom runners should register **one active turn/job**,
not a whole idle session. Use the same executable and `INSOMNIA_HOME` as the
menu-bar app:

```bash
BIN='/path/to/Insomnia.app/Contents/MacOS/Insomnia'
JOB="$("$BIN" --agent begin 'Claude: refactor turn' "$OWNER_PID")"
"$BIN" --agent heartbeat "$JOB"
"$BIN" --agent finish "$JOB"
```

`begin` returns a UUID; `heartbeat` and `finish` return exit status 0 on
success. Invalid input, expired work and I/O failures return status 2 with
an error on stderr, without launching the GUI. Quote `"$BIN"` in real shell
scripts, including inside command substitutions.
`OWNER_PID` must be a live process responsible for the work, **not** the
short-lived CLI/helper issuing `begin`. The identity includes microsecond
start time and boot UUID, so PID reuse or a reboot cannot revive the job.

Integration contract:

- Register on turn start. Heartbeat every **15 seconds** while that turn is
  genuinely outstanding (API waits, tool execution, retries and quiet compute
  all count). An incidental shell command going idle is not completion.
- Finish only after authoritative completion, cancellation, error, or a state
  requiring new human input. Finish is idempotent and serialized with
  heartbeats; a racing heartbeat cannot resurrect completed work.
- If independent subagents outlive their parent turn, give them independent
  activity IDs and lifetimes. Do not finish the parent while it still owns
  outstanding work without registering those children.
- Always finish in a finally/exit handler, including failure paths. If a
  transport/runner is gone or can no longer attest that work is outstanding,
  stop heartbeating. Do not use an unattended heartbeat daemon for an idle
  interactive client.
- A **90-second lease** tolerates brief gaps. Missing heartbeats, an exited or
  changed owner, and an unverifiable owner all cease keeping the Mac awake.
  A lease that expires cannot be renewed. Explicitly begin a *new* job only
  for newly authorized work, not to evade a stuck-job timeout.
- Every job has a non-renewable **8-hour safety ceiling**. Both monotonic uptime
  and wall-clock timestamps are checked; rolling the wall clock backward does
  not defeat the ceiling or heartbeat timeout. This is a fixed failure bound,
  not a manual user timer or a promise to detect lack of semantic progress.

The API writes owner-only, atomic JSON under `agent-jobs/` in Insomnia’s support
folder (or `$INSOMNIA_HOME/agent-jobs`). UUIDs act as local capability tokens;
this is a same-user API, not an authenticated network endpoint. Files are read
with no symlink following, bounded size and owner/mode checks. Invalid entries
never hold sleep. Directory scans are bounded to 256 entries and fail closed
with a warning if overloaded. Expired files are kept for diagnostics; finish
their UUIDs when an integration recovers. The app does not silently delete
unknown evidence or infer agent work from unrelated background processes.

## Safety and recovery

- Auto holds sleep **before** lid close while productive work is registered;
  waiting for a lid-close notification would risk losing the race to sleep.
  The hold also prevents idle sleep with the lid open. Opening the lid does
  not imply completion. With no registered work, ordinary macOS sleep policy
  applies immediately; Insomnia does not force sleep or release other apps’
  assertions/settings.
- Auto uses the existing journaled `pmset disablesleep` guard, **not a new
  unprivileged IOKit assertion**. It arms recovery before changing power,
  reverses lid actions at end, and reports restoration failures just like a
  timed session. Read [recovery.md](recovery.md) for those limits.
- Each Auto session’s persisted end time is at most 90 seconds ahead and no
  later than the latest valid job lease. Heartbeats renew that short deadline,
  not the eight-hour ceiling. If the app crashes/hangs, the existing minute
  polling backstop attempts restoration after that deadline: normally within
  **150 seconds plus command/recovery latency** of the last renewal. Recovery
  failures, corrupted journals and stuck privileged commands still require
  manual attention; this is not an unconditional hardware safety guarantee.
- Relaunch restores an old Auto session rather than reapplying its hold.
  Only after clean recovery does the launch default enable Auto and scan
  fresh, verified activity. Unresolved/unreadable recovery and a resumed
  timed session leave it off. Within the current run, manual End, lease-deadline
  expiry, power/thermal ends and start/recovery failures pause Auto until
  explicitly enabled again. Quit always disarms before restoring.
- On **battery**, Auto ends below the configured end floor or **10%**, whichever
  is higher; two unreadable battery readings also end it. On **AC**, battery
  floors do not apply. Serious heat requests Low Power Mode, and critical heat
  ends Auto on **either power source**. These Auto safety floors cannot be
  disabled through the timed-session settings. Configured stronger battery
  thresholds and the existing lid/Low Power Mode options still apply.
- Auto does not take over a timed session, and its leases cannot be manually
  extended. Left-click, right-click or Control-click the eye/countdown opens
  quick actions without changing the hold. **Disable Auto** and timer
  start/end actions are explicit menu controls. A timed preset
  explicitly disarms *idle* Auto and starts a timer; presets are disabled
  while Auto work is active or being armed. Starts and mode changes are also
  blocked while arming/restoration is pending. Auto never opens duration
  extension fields or schedules short-lease timer reminders. Start failures
  and restoration warnings remain visible in the open quick menu.
- Keep the agent’s host/terminal out of the manual freeze list. The standard
  automatic freeze exclusions protect common terminals, but a custom runner
  is not automatically classified as an agent host by this API.
- **Only use a stable, ventilated surface. Never close an awake Mac in a bag.**
  Software cannot reliably detect that situation, nor guarantee that the app
  or recovery agent will survive. Actual lid behavior remains dependent on
  supported macOS/hardware; no physical lid/thermal validation was done for
  this feature. No wake-on-network, phone-access or Always On guarantees are
  added here.

## Development checks

```bash
swift build -Xswiftc -warnings-as-errors
./scripts/check-agent-auto.sh  # isolated, injected-power checks; CLT supported
swift test --filter Agent      # XCTest requires a usable full Xcode toolchain
swift test --filter MenuBarAutoTests
swift test                     # complete suite, full Xcode and tmux recommended
```

If Command Line Tools is selected but Xcode is installed, first complete
Xcode's first-launch/license prompts yourself, then use a per-command
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for XCTest; no global
toolchain change is needed.

### Local XCTest validation (2026-10-11)

On macOS 26.1 with Xcode 26.3 / Swift 6.2.4, the Auto changes in this pull request
on the PR #63 UI passed the complete `swift test` suite: 1,307 tests executed,
13 skipped and no failures. The 13 skipped cases require live tmux, which is not
installed. The standalone Auto smoke harness, release build with warnings as
errors and release lid-simulation gate also passed. No physical
power/lid/thermal validation is claimed by these tests.

XCTest exposed and now covers missing packaged-wrapper fixtures and safe
monitor cleanup on macOS 26.1, avoiding the isolated-deinit runtime crash in
the PR's status host and Settings window. The local app must still be
installed/restarted separately; tests never update the running app.

The standalone smoke harness links the actual debug app objects and uses
fake power/backstop/process effects. It checks job lifetime, disconnects,
clock changes, hostile file types, multi-job completion, short deadline
renewal, enforced battery safety, lifecycle ends, suspended-start cancellation,
restart recovery and the real terminal wrapper’s success/failure cleanup.
It also drives the real menu-bar controller with desktop input capture off:
PR quick-menu layout, idle/checking/working/paused visibility, stable hosted
widths, eye and menu actions, Timer isolation, duplicate requests and explicit
cancellation during suspended starts, refused starts and delegated restoration
failures. Optional rendered PNG evidence can be
captured with `INSOMNIA_UI_SNAPSHOT_DIR=/tmp/insomnia-ui ./scripts/check-agent-auto.sh`.
The XCTest cases also cover failed starts and restoration failures.
It does not replace XCTest, supervised physical lid validation, or recovery
failure review.
