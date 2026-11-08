# One-click start recheck on macOS 27

Commit `22f27560fee2d88b54685d53710a74c9ff8560aa`, branch `integration/menu-bar-oneclick`. The accepted checks passed, and the known AXPress gap reproduced. The six required zero-flag Control-click trials remain unverified because the input tooling could not deliver that combination to the app. This run does not certify the changed left-press path.

## Setup

The test VM was already running and was claimed before use. It ran macOS 27.0.1, build 26A434, at 1440 × 900, scale 1. The two earlier runs, their scripts, and the target commit's specification and release checks were read. No previous helper remained running. The previous app was quit before installation. Earlier run folders and the source checkout were unchanged. No VM was started, stopped, cloned or deleted, and the owner's MacBook UI, Insomnia install and config were untouched. Nothing was posted or pushed.

The staged ZIP matched SHA-256 `000ac4f85c82839a4787834386ee48e2cadecbe057ec7cf8ade9edb83b257e5f`. It was extracted with ditto outside /tmp. Config was moved aside before the target commit's archived `scripts/install.sh --app <bundle>/Insomnia.app --allow-unverified-origin` ran successfully. The installed CDHash was `baf2ef0b9687c057a8aa9a14a87404828e782b7c`, verified again after cleanup. The installer bytes match the target source archive. The staged ZIP was left unchanged.

Fresh launch wrote defaults. Settings enabled one-click start and set the Default session length to 10 minutes, with sounds off. The [reviewed Settings picture](pictures/setup-settings.png) and config confirm `oneClickStart=true`, `defaultPreset=600`, `sessionSounds=false` and `defaultFocusField="hours"`. Each style was asserted against config before its checks. Existing observation permissions were available. No system prompt covered an accepted input target and no permission was granted.

A no-start result required no session.json, SleepDisabled 0 and no new session-start log after at least three seconds. Pending starts also counted as starts when session.json existed or SleepDisabled was 1, before the confirmation log appeared. Each trial saved posting and delivery times and flags, the window under the pointer, Accessibility state, session and power state, and the full trial log. The read-only app observer recorded original event flags and original modifier reads without replacing values. It did not edit or re-sign the installed app and removed its loader setting before child processes launched.

## Checks and counts

| Check | Result and counts | Evidence |
|---|---|---|
| 1. Option in Pills and Compact | Pass 16/16. Immediate release 12/12, three per style per posting method. Held 500 ms 2/2. Mouse flags alone 2/2. Controls opened and nothing started. | `evidence/c1-*`; [Pills](pictures/c1-Pills-immediate-hid-1.png), [Compact](pictures/c1-Compact-immediate-hid-1.png) |
| 2. No kept keys | Pass 2/2. After Esc, a plain 90 ms click started exactly 600 seconds and opened no controls. | `evidence/c2-*` |
| 3. Popover Option and plain clicks | Pass 4/4. All three Option methods opened the popover without a start. The plain click started 600 seconds and opened nothing. | `evidence/c3-*`; [Popover](pictures/c3-Popover-option-flags.png) |
| 4. Context menus | Partial verification. The prior-style inputs passed 11/11, two right-clicks and one Control-click in each style, plus left-click dismissal in Pills and Compact. One menu opened, Esc closed it, and nothing started. Zero-flag Control clicks with Control still held were verified 0/6. | `evidence/c4-*`; [menu](pictures/c4-Pills-right-1.png); [tooling evidence](evidence/zero-flag-tooling.md) |
| 5. Popover right and Control toggles | Pass 2/2 pairs, 4/4 actions. Each first click opened and second click closed the popover, without a session. | `evidence/c5-*` |
| 6. Minimal hold | Pass 1/1. A confirmed 7200-second command-line session ended after an 800 ms eye hold. One user-end log, one sleep-restored log, no session, SleepDisabled 0. The mixed-button hold was skipped as requested. | `evidence/c6-*` |
| 7. Holds end sessions | Pass 2/2 pairs. Both one-click starts requested 600 seconds. Both 650 ms holds ended the session, with a user-end log, sleep-restored log and SleepDisabled 0. | `evidence/c7-*` |
| 8. Accessibility press | Known gap reproduced 2/2. Both idle eyes advertised AXPress and returned success when pressed, with no session, controls or menu. | `evidence/c8-*` |

There are 44 accepted result records in [results.tsv](evidence/results.tsv), including the two known-gap observations. Posting requested 90 ms clicks. For the 12 immediate trials, observed Option release arrived 0.167 to 0.502 ms after mouse-up, within the 1 ms requirement. The [timing audit](evidence/immediate-timing-audit.json) has each trial.

## Findings and limits

No new app defect was established. The zero-flag Control-click requirement could not be verified. Two ordinary zero-flag attempts in Pills and one alternate attempt posted Control-down first, then mouse down/up with flags 0, then Control-up. At mouse-down posting, Control was held. Processing that mouse event cleared the system's Control state before Insomnia received it. The app recorded `eventFlags=0`, `appHeldFlags=0` and `controlKey=0`, so these became plain clicks and started 600-second sessions. A session file and SleepDisabled 1 were counted as a start even when the session-start log had not appeared. Each surviving session was ended and sleep restoration checked.

Three later routing diagnostics preserved Control through the zero-flag mouse posts but delivered no mouse event to Insomnia. They started no session and opened no menu. All six attempts are excluded from accepted counts. Their original records remain under `rejected/zero-flag-tooling/`, with sanitized selected traces under `evidence/zero-flag-diagnostics/`. No modifier value was substituted to claim coverage. The ordinary Control-click method delivered a right-press to the app and passed, as in the earlier run. It does not establish coverage of the new left-press path.

The AXPress no-op matches the previous run in both styles. Its action list includes AXPress, the action returned code 0 and standard modifier bits were clear. The three-second observation showed no session, SleepDisabled 0 and no controls. This is the known gap, not a new finding. Physical VoiceOver behavior was not tested.

All full trial logs, including the excluded attempts, were searched for `status item: a click handled late counts as an Option-click`. None contained it. The late-click fallback was not exercised. Other accepted behavior matches the earlier run. The hold-through-right-click case was skipped because of the established macOS 27 delivery limit. Inputs were synthetic; physical mouse and trackpad behavior were not tested. This is the requested subset of release checks, not a complete release certification.

Every selected picture was opened and visually reviewed. The selected pictures show only Insomnia's item, menu, controls, popover or Settings. They contain no private identifiers, network names, notifications or other app windows. [picture-review.json](picture-review.json) records accepted hashes. Rejected takes, scripts, the source archive and scratch data are private working material.

## End state

Insomnia is quit and Settings is closed. The full final config matches first-launch defaults, including `menuBarMode="pills"`, `oneClickStart=false`, `sessionSounds=false`, `defaultFocusField="hours"` and `defaultPreset=14400`. No session remains and SleepDisabled is 0 on three independent reads. The journal retains no sleep or Low Power Mode ownership and no frozen processes. Nothing created by this run remains in /tmp. The claim was released and the VM was left running. Free disk on the maintainer's Mac mini stayed above the brief's 1.0 GiB cutoff. See the [independent final check](evidence/final-independent-check.txt) and [claim release](evidence/claim-release.txt).
