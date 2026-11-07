PR #148 passes all three freeze/resume cases with real Cua Spaces 0.22.0 in the tested pre-sign-in state. No helper registered as a separate Foreground app under another bundle id was observed. The head left all 10 Cua-associated processes running during automatic freeze-all. Main froze Cua's main PID. An explicit freeze-list entry on the head also froze its main PID. The stand-in froze and resumed in every case.

The run used a macOS 27.0.1 VM on the maintainer's Mac mini, build 26A434, on 2026-11-07 UTC. All app interactions occurred inside that VM. The MacBook only built the control app and utilities. Nothing was posted or pushed.

The head was `dad6f5376f168e2ac8ffc8c6791e74091560aeaa`, branch `integration/cua-freeze-scope`. The main control was `b8e7e20d617f008179583918599669fc1c13a731`. Both Insomnia bundles were version 0.1.0, build 1, with lid simulation compiled in. Each install used that commit's own `scripts/install.sh --app ... --allow-unverified-origin`, without setting `INSOMNIA_LID_SIMULATION` during installation. Every completed install printed the expected CDHash, and the launch log contained the Lid simulation build line.

| Artifact | Version or commit | SHA-256 | CDHash |
|---|---|---|---|
| Cua Spaces universal DMG | 0.22.0, build 0.22.0.144 | `2b47c77d5041f4839ebe51e25fcbf768bd2edb10adc96dc108e6a0d521c35e3e` | `7807b6a67fd4e369e075e9354f5569a795a10619` |
| Insomnia head ZIP | `dad6f537` | `66f0f817d26f6be4a0d7be9af78516d66da9d95d651d80dba84c1d47b15bd347` | `e5f3a2706bfc324fa773c698ad2604b379069d9c` |
| Insomnia main ZIP | `b8e7e20d` | `420f10a679c20e744be3624b791e8c739dbb558b377a1bfd161a62c282220e7e` | `10e7c10d4a8d46bda875b8555bb173406ffa368f` |

The DMG came through the [official download page](https://cua.ai/download). Its SHA-256 matched the [0.22.0 release checksums](https://github.com/trycua/cua/releases/download/cua-spaces-v0.22.0/checksums.txt). Cua's bundle id was `com.trycua.spaces.macos`. `codesign -dvv` identified Developer ID Application: Cua AI, Inc., team `YCK386LBJ7`, hardened runtime, and a stapled notarization ticket. `spctl -a -vv` accepted it as Notarized Developer ID. Standard deep signature verification passed. An additional strict verification rejected the bundle's FinderInfo metadata attribute. Both results are retained in [the signature evidence](evidence/cua-signature.txt).

Cua showed its welcome window, menu bar item and a notch item with zero Spaces. No sign-in or Space creation was completed. No VM image was downloaded. Its data directory was 1.1 MiB during testing, with no file over 20 MiB. No Cua Accessibility, Screen Recording, notification, network-extension, helper-tool or password dialog was observed, and no such permission was granted. Cua automatically registered a driver login item and opened Login Items. Its background toggle was turned off at 07:26:48Z. The driver launcher and driver then exited. The background-item inventory after the denial confirmed that Cua was disallowed.

The inventory below combines the initial snapshot and the required later inventory at 07:29:23Z, more than five minutes after launch at 07:24:04Z. The kernel parent is PPID. The bundle-id and application-type columns come from `lsappinfo list`. "Not registered" means that process had no entry there. The Apple services were associated with Cua by its process coalition, rather than by a name match alone. All 10 processes present during the cases had PPID 1.

| PID | PPID | Process | Bundle id in lsappinfo | Application type | Present during cases |
|---|---|---|---|---|---|
| 87478 | 1 | CuaSpacesMac | `com.trycua.spaces.macos` | Foreground | Yes |
| 87485 | 1 | CuaSpacesMac, driver launcher | Not registered | Not registered | No, exited after background access was denied |
| 87488 | 87485 | cua-driver | Null | UIElement | No, exited after background access was denied |
| 87502 | 1 | cua daemon | Not registered | Not registered | Yes |
| 87490 | 1 | Cua Spaces Graphics and Media | `com.apple.WebKit.GPU` | UIElement | Yes |
| 87495 | 1 | Cua Spaces Web Content | `com.apple.WebKit.WebContent` | UIElement | Yes |
| 87498 | 1 | Cua Spaces Networking | `com.apple.WebKit.Networking` | UIElement | Yes |
| 87582 | 1 | ThemeWidgetControlViewService for Cua Spaces | `com.apple.appkit.xpc.ThemeWidgetControlViewService` | BackgroundOnly | Yes |
| 87483 | 1 | SetStoreUpdateService | Not registered | Not registered | Yes |
| 87583 | 1 | SetStoreUpdateService | Not registered | Not registered | Yes |
| 87522 | 1 | com.apple.audio.SandboxHelper | Not registered | Not registered | Yes |
| 87524 | 1 | MTLCompilerService | Not registered | Not registered | Yes |

No separate Foreground helper was found. The driver used a different launch-service label, `com.trycua.spaces.driver`, but it was not a Dock app. Its registered `cua-driver` child was a UIElement with a null bundle id. The host-service label `com.trycua.spaces.helper` was bundled but not registered. The on-disk `cua-spacesd`, `cua-vz`, `cua-netgw`, cursor-theme tool and Sparkle updater were not running. The broad `pgrep -fl -i lume` matched an unrelated system process argument; no Lume process was identified. Full raw `ps`, both requested `pgrep` outputs and `lsappinfo` inventories are retained privately. Shareable Cua-only extracts are [here](evidence/cua-ps-initial.tsv), [here](evidence/cua-ps-after-two-minutes.tsv) and [here](evidence/cua-lsappinfo-initial.txt).

Before the first install, the existing config was moved aside and Insomnia wrote defaults. Each case then used `freezeAllApps=true`, the freeze list shown below, and the same default agent list. Cua was not on the agent list. The only running non-Apple Dock apps in reach were Cua Spaces and Standin Other, so no other app id needed adding. Standin Other was version 1.0, ad hoc signed, with bundle id `dev.insomnia-test.standin-other`, PID 88006.

Every session requested 3600 seconds. The matching commit's `simulate-lid.sh` closed the lid. Each case sampled all 10 Cua-associated PIDs plus the stand-in every two seconds, at 2 through 50 seconds, for 25 samples. The open trigger was written at 60.020, 60.022 and 60.022 seconds respectively. No process was stopped before any close. Each open left no process in T and an empty frozen-process journal. Quit then ended each session and restored SleepDisabled to 0.

| Case | Settings "Would freeze now" | Cua PIDs in T during close | Stand-in samples in T | Resume count | Result |
|---|---|---|---|---|---|
| 1. Head, empty freeze list | Standin Other | 0 of 10, in every sample | 25 of 25 | 1 | Pass |
| 2. Main, empty freeze list | Cua Spaces, Standin Other | Main PID 87478 in 25 of 25 samples; other 9 never T | 25 of 25 | 2 | Pass |
| 3. Head, explicit `com.trycua.spaces.macos` entry | Standin Other | Main PID 87478 in 25 of 25 samples; other 9 never T | 25 of 25 | 2 | Pass |

The decisive log lines were:

```text
2026-11-07T07:31:24Z freeze-all: automatic candidates: Standin Other
2026-11-07T07:31:24Z froze Standin Other (1 pid(s), 0 skipped)
2026-11-07T07:32:24Z resumed 1 frozen pid(s); 0 gone, 0 failed, 0 unverifiable, 0 unobserved

2026-11-07T07:35:16Z freeze-all: automatic candidates: Cua Spaces, Standin Other
2026-11-07T07:35:16Z froze Cua Spaces (1 pid(s), 0 skipped)
2026-11-07T07:35:16Z froze Standin Other (1 pid(s), 0 skipped)
2026-11-07T07:36:16Z resumed 2 frozen pid(s); 0 gone, 0 failed, 0 unverifiable, 0 unobserved

2026-11-07T07:37:41Z freeze-all: automatic candidates: Standin Other
2026-11-07T07:37:41Z froze Cua Spaces (1 pid(s), 0 skipped)
2026-11-07T07:37:41Z froze Standin Other (1 pid(s), 0 skipped)
2026-11-07T07:38:41Z resumed 2 frozen pid(s); 0 gone, 0 failed, 0 unverifiable, 0 unobserved
```

These lines omit the common log-level prefix for readability. The original excerpts are [case 1](evidence/c1-insomnia.log), [case 2](evidence/c2-insomnia.log) and [case 3](evidence/c3-insomnia.log). They contain no extra denylist or "left running" line for Cua. The head excludes it before candidate logging. The complete [sample counts](evidence/case-summary.json) and per-case `ps` samples are retained alongside the excerpts.

The head's built-in protected set contains the exact Cua bundle id. Automatic candidate selection requires a regular Dock app and excludes that set. This accounts for the observed difference from main. The explicit freeze list overrides built-in automatic protection. Process grouping follows descendants, and the nine other Cua-associated processes had been launched separately with PPID 1. That explains why both main and the explicit-entry case stopped only the main PID. This run found no helper Dock app that escaped the single-id protection.

Cua installed no new loose file in user or system LaunchAgents, system LaunchDaemons, PrivilegedHelperTools or the checked binary folders. It registered its in-bundle driver agent with the background-item system. It also created `~/.cua`, `~/Library/Application Support/com.trycua.spaces.macos`, WebKit and HTTP storage for that bundle id, caches for that bundle id and `cua-driver`, and `com.trycua.spaces.macos.plist` preferences. No privileged helper was found. No password prompt appeared.

The four report pictures were opened and checked. Each contains only the named app window, without an account, user name, host name, address, network name, notification or another app's window:

- [Cua welcome window](pictures/cua-spaces-window-take1.png)
- [Case 1 Settings before close](pictures/c1-settings-before-close.png)
- [Case 2 Settings before close](pictures/c2-settings-before-close.png)
- [Case 3 Settings before close](pictures/c3-settings-before-close.png)

The requested command-line session interface does not exist in either supplied commit. The complete entry point handles only the frozen-process recovery command before starting the app. An attempted `--session end` launched an extra app instance and waited; that instance was terminated. Sessions therefore started through Insomnia's own controls with the default preset set to 3600 seconds. Synthetic holds did not end case 1, including a retry after retracting the duration inputs and a check with the existing hold utility. Its process-state and cropped UI diagnostics were saved, and the normal Quit path ended it at 07:34:34Z. Cases 2 and 3 used Quit directly. These are procedure limitations, not freeze/resume failures. A `codesign` verbosity error, an initial accessibility-read error, a settings-script setup error and one evidence-transfer timeout were corrected during setup. No application code was changed.

This run covers one launch state of Cua Spaces 0.22.0, without sign-in, granted permissions or a running Space. The driver and its launcher were inventoried while running before background access was denied, then were absent during the three closes. Their behavior during a close was therefore not sampled. Helpers created by sign-in, granted permissions, a sandbox or later app versions remain untested. Lid events were simulated; the VM has no physical lid or battery. Brightness and Low Power Mode actions logged unavailable capabilities. Audio mute and restoration logged normally. Each freeze case ran once.

Cleanup finished at 07:40:46Z. Cua was quit, its driver and host services were unregistered, the remaining daemon was stopped, and the app, DMG and listed data were removed. Standin Other was quit and removed. Main `b8e7e20d` was reinstalled with its expected CDHash, launched to write defaults, compared equal to the initial app-written defaults, and quit. The test config and all VM work files were then removed. No session, stopped process or test temporary file remained; SleepDisabled was 0. The staged files were removed, the claim was released, and the VM remained running. The mini had 6.5 GiB free at the start, 6.2 GiB after the download, 5.7 GiB during the cases, and 7.1 GiB at the end. It stayed above the 3 GiB stop threshold.

The only remaining Cua record identified was historical background-item metadata. Both the app and driver records were disabled and disallowed after unregistration. The system tool does not expose removal of one such record; its global reset would also affect pre-existing entries, so those historical records were left in place. No active Cua service, privileged helper or removable Cua file was left.

`report.md`, `run.log`, the four files in `pictures/`, `evidence/`, `scripts/` and `src/` are the shareable evidence. `private/`, `build/` and `rejected/` contain raw inventories, source archives, setup diagnostics or rejected takes and are excluded from pull-request material.
