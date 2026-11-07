# Screen-awake deadline checks at b5bb1543

Tested on November 7, 2026, from 22:35 to 22:51 UTC, on a macOS 27.0.1 VM on the maintainer's Mac mini. The timeout, extension, frozen recovery, toggle-off, kill, and Quit checks passed. The normal menu end check is inconclusive because the input attempts opened duration inputs rather than ending the session.

Commit `b5bb15437b26ec9da15e9e04d9a75157f0b95250`, branch `land/pr-160`, PR #167 landing contributor PR #160. macOS build `26A434`, Apple silicon, Insomnia `0.1.0`, bundle version `1`.

The supplied archive has SHA-256 `e04e3bbfd4ead2446dfdf655fe0659800aa7c305a113c5bc063012d0a80eb4c0`. The VM verified it before extraction outside the temporary directory. The head's own installer installed the supplied ad-hoc signed bundle with `--allow-unverified-origin`. Installed CDHash `c06ae20cac86f677d96f42b8d3cb6f167918faf3` matches the manifest. The previous installed build was `0.1.0`, bundle version `1`, CDHash `602acf9aa689105e02a2c211e4dd98c876b3097f`. See [installer capture](captures/setup-install.txt).

The VM had no original config.json. The test config omitted `keepScreenAwake` to check its default and set presets to 120, 300, and 600 seconds, a 300-second default, and the Minutes input field. The toggle was changed through Settings. Sessions and the extension were entered through the menu bar. The VM was fenced before installation. No downloads occurred in the VM. The checkout remained unchanged. Nothing was posted or pushed.

Mini free space was 2.8 GiB at the start, 2.8 GiB after installation, 2.6 GiB after the final session, and 2.7 GiB after cleanup. It remained above the 1.5 GiB stop threshold.

| Check | Result | Observation |
|---|---|---|
| 1. Default toggle off | Pass | Active 300-second session, SleepDisabled 1, no Insomnia display assertion. Ended through Quit. |
| 2. Toggle on and countdown | Pass | One named assertion, 292 seconds at 22:42:45 UTC and 232 seconds at 22:43:45 UTC, exactly matching the deadline. |
| 3. Extend one step | Pass | A 60-second extension kept the same assertion ID and moved the deadline by 60 seconds. Timeout was within one second of time remaining. No timeout-move failure line. |
| 4a. Frozen process past deadline | Pass | At deadline plus 30 seconds, the process still existed in state T and its display assertion was gone. |
| 4b. Resume and settle | Pass | After 30 seconds, the session had ended, SleepDisabled was 0, the assertion was absent, and the log and menu had no release error. |
| 5a. Normal menu end | Inconclusive | Two recorded holds on the visible end control opened duration inputs. No user-end event occurred, so assertion removal for this path was not verified. |
| 5b. Turn the toggle off mid-session | Pass | Assertion disappeared while session.json remained and SleepDisabled stayed 1. |
| 5c. Kill and reopen | Pass | The assertion disappeared after kill -9. Relaunch recovered the unexpired session with a new assertion. Quit then ended it and restored SleepDisabled 0. |
| 6. Longest configured preset | Pass | The 600-second preset had a 592-second timeout with 592 seconds remaining. Quit removed it and restored sleep. |

The full command outputs are in `captures/`. The following blocks preserve the complete Insomnia assertion lines and their timeout lines.

Check 1, toggle off, [full capture](captures/check1-toggle-off.txt). No Insomnia assertion appears in the owning-process list.

```text
2026-11-07 22:36:56 +0000 
Assertion status system-wide:
   BackgroundTask                 0
   ApplePushServiceTask           0
   UserIsActive                   1
   PreventUserIdleDisplaySleep    0
   SoftwareUpdateTask             0
   PreventSystemSleep             0
   PreventSystemSleepSecurityIndicator 0
   ExternalMedia                  0
   PreventUserIdleSystemSleep     1
   NetworkClientActive            0
Listed by owning process:
   pid 106(powerd): [0x0000000400018002] 00:10:24 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"  
   pid 106(powerd): [0x0000000400098003] 00:10:24 UserIsActive named: "com.apple.powerd.ws.initialize"  
   pid 182(WindowServer): [0x0000000600098007] 00:00:08 UserIsActive named: "com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:2871 process:System Events"  
Kernel Assertions: 0x4=USB
   id=501  level=255 0x4=USB creat=07.11.26, 22:31 description=com.apple.usb.externaldevice.10900000 owner=Virtual USB Keyboard
   id=502  level=255 0x4=USB creat=07.11.26, 22:32 description=com.apple.usb.externaldevice.10a00000 owner=Virtual USB Digitizer
```

Check 2, [first capture](captures/check2-timeout-first-valid.txt) at 22:42:45 UTC, deadline 22:47:37 UTC.

```text
   pid 3437(Insomnia): [0x000003cd00058114] 00:00:02 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 292 secs Action=TimeoutActionTurnOff
```

Check 2, [second capture](captures/check2-timeout-second.txt) exactly 60 seconds later.

```text
   pid 3437(Insomnia): [0x000003cd00058114] 00:01:02 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 232 secs Action=TimeoutActionTurnOff
```

Check 3, [extension capture](captures/check3-extend-one-minute.txt) at 22:43:50 UTC, new deadline 22:48:37 UTC. The deadline moved by 60 seconds. The timeout rose from 232 to 288 while five seconds elapsed between captures. The one-second difference is within whole-second rounding.

```text
   pid 3437(Insomnia): [0x000003cd00058114] 00:00:03 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 288 secs Action=TimeoutActionTurnOff
```

```text
2026-11-07T22:43:47Z [info] insomnia: session extended by 60s until 2026-11-07T22:48:37Z
2026-11-07T22:43:47Z [info] insomnia: screen awake: hold moved to the session's new deadline
```

The lock-state query `ioreg -n Root -d1 | grep CGSSessionScreenIsLocked` printed nothing at both Check 2 captures. This was an unlocked observation during the timeout samples, not a full idle-lock policy test.

Check 4, [before STOP](captures/check4-frozen-start.txt), at 22:45:00 UTC, deadline 22:46:52 UTC.

```text
   pid 3845(Insomnia): [0x0000045400058120] 00:00:02 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 112 secs Action=TimeoutActionTurnOff
```

At 22:47:22 UTC, exactly 30 seconds past the deadline, [the process still had state T and no display assertion](captures/check4-frozen-deadline-plus30.txt).

```text
  PID STAT COMM
 3845 T    ~/Applications/Insomnia.app/Contents/MacOS/Insomnia
```

```text
2026-11-07 22:47:22 +0000 
Assertion status system-wide:
   BackgroundTask                 0
   ApplePushServiceTask           0
   UserIsActive                   1
   PreventUserIdleDisplaySleep    0
   SoftwareUpdateTask             0
   PreventSystemSleep             0
   PreventSystemSleepSecurityIndicator 0
   ExternalMedia                  0
   InternalPreventDisplaySleep    1
   PreventUserIdleSystemSleep     1
   NetworkClientActive            0
Listed by owning process:
   pid 106(powerd): [0x0000000400018002] 00:20:50 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"  
   pid 106(powerd): [0x0000000400098003] 00:20:50 UserIsActive named: "com.apple.powerd.ws.initialize"  
   pid 106(powerd): [0x0000044800108115] 00:00:29 InternalPreventDisplaySleep named: "com.apple.powermanagement.delayDisplayOff"  
	Timeout will fire in 271 secs Action=TimeoutActionTurnOff
   pid 182(WindowServer): [0x0000000600098007] 00:02:29 UserIsActive named: "com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:2871 process:System Events"  
Kernel Assertions: 0x4=USB
   id=501  level=255 0x4=USB creat=07.11.26, 22:31 description=com.apple.usb.externaldevice.10900000 owner=Virtual USB Keyboard
   id=502  level=255 0x4=USB creat=07.11.26, 22:32 description=com.apple.usb.externaldevice.10a00000 owner=Virtual USB Digitizer
```

The recovery agent restored sleep while the app remained stopped. On CONT at 22:47:23 UTC, Insomnia released its expired assertion ID without error and ended the session. At 22:47:53 UTC, SleepDisabled was 0 and session.json was absent. See [resume capture](captures/check4-resume-plus30.txt) and [cropped menu](pictures/frozen-resumed-menu.png).

```text
2026-11-07T22:47:18Z [info] backstop: session expired (endsAt=2026-11-07T22:46:52Z); restoring from journal
2026-11-07T22:47:18Z [info] backstop: pmset -a disablesleep 0 ok
2026-11-07T22:47:18Z [info] backstop: journal cleared
2026-11-07T22:47:23Z [info] insomnia: screen awake: released, idle display sleep and the screen lock are back
2026-11-07T22:47:23Z [info] insomnia: session end (timer)
2026-11-07T22:47:23Z [info] insomnia: notify: Session ended - Time is up. Sleep is back to normal.
 SleepDisabled        0
```

Check 5b, [live toggle-off capture](captures/check5b-toggle-off-live.txt). At 22:49:15 UTC, the fresh session had the assertion below. Turning the toggle off released it at 22:49:17 UTC. The 22:49:18 UTC capture had no Insomnia owning-process entry, while the same session still had its 22:51:07 UTC deadline and SleepDisabled remained 1.

```text
   pid 4379(Insomnia): [0x000005530005812d] 00:00:02 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 112 secs Action=TimeoutActionTurnOff
```

```text
2026-11-07 22:49:18 +0000 
Assertion status system-wide:
   BackgroundTask                 0
   ApplePushServiceTask           0
   UserIsActive                   1
   PreventUserIdleDisplaySleep    0
   SoftwareUpdateTask             0
   PreventSystemSleep             0
   PreventSystemSleepSecurityIndicator 0
   ExternalMedia                  0
   InternalPreventDisplaySleep    1
   PreventUserIdleSystemSleep     1
   NetworkClientActive            0
Listed by owning process:
   pid 106(powerd): [0x0000000400018002] 00:22:46 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"  
   pid 106(powerd): [0x0000000400098003] 00:22:46 UserIsActive named: "com.apple.powerd.ws.initialize"  
   pid 106(powerd): [0x0000044800108115] 00:00:01 InternalPreventDisplaySleep named: "com.apple.powermanagement.delayDisplayOff"  
	Timeout will fire in 299 secs Action=TimeoutActionTurnOff
   pid 182(WindowServer): [0x0000000600098007] 00:00:02 UserIsActive named: "com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:2871 process:System Events"  
Kernel Assertions: 0x4=USB
   id=501  level=255 0x4=USB creat=07.11.26, 22:31 description=com.apple.usb.externaldevice.10900000 owner=Virtual USB Keyboard
   id=502  level=255 0x4=USB creat=07.11.26, 22:32 description=com.apple.usb.externaldevice.10a00000 owner=Virtual USB Digitizer
```

Check 5c, [kill capture](captures/check5c-kill9.txt). The 22:49:56 UTC capture had the assertion below. At 22:49:58 UTC, after kill -9, the PID was absent and so was the assertion.

```text
   pid 4495(Insomnia): [0x0000057b00058138] 00:00:02 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 112 secs Action=TimeoutActionTurnOff
```

```text
2026-11-07 22:49:58 +0000 
Assertion status system-wide:
   BackgroundTask                 0
   ApplePushServiceTask           0
   UserIsActive                   1
   PreventUserIdleDisplaySleep    0
   SoftwareUpdateTask             0
   PreventSystemSleep             0
   PreventSystemSleepSecurityIndicator 0
   ExternalMedia                  0
   InternalPreventDisplaySleep    1
   PreventUserIdleSystemSleep     1
   NetworkClientActive            0
Listed by owning process:
   pid 106(powerd): [0x0000000400018002] 00:23:26 PreventUserIdleSystemSleep named: "Powerd - Prevent sleep while display is on"  
   pid 106(powerd): [0x0000000400098003] 00:23:26 UserIsActive named: "com.apple.powerd.ws.initialize"  
   pid 106(powerd): [0x0000044800108115] 00:00:02 InternalPreventDisplaySleep named: "com.apple.powermanagement.delayDisplayOff"  
	Timeout will fire in 298 secs Action=TimeoutActionTurnOff
   pid 182(WindowServer): [0x0000000600098007] 00:00:11 UserIsActive named: "com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:4519 process:click"  
Kernel Assertions: 0x4=USB
   id=501  level=255 0x4=USB creat=07.11.26, 22:31 description=com.apple.usb.externaldevice.10900000 owner=Virtual USB Keyboard
   id=502  level=255 0x4=USB creat=07.11.26, 22:32 description=com.apple.usb.externaldevice.10a00000 owner=Virtual USB Digitizer
```

[Relaunch capture](captures/check5c-relaunch-settle.txt). The saved session was still valid, so the app recovered it with 102 seconds left. The new assertion is expected for that active recovered session. Quit ended it, and the 22:50:09 UTC capture had no Insomnia assertion and SleepDisabled 0.

```text
   pid 4549(Insomnia): [0x0000058600058142] 00:00:02 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 102 secs Action=TimeoutActionTurnOff
```

```text
2026-11-07T22:50:03Z [info] insomnia: reconcile: session valid until 2026-11-07T22:51:48Z
2026-11-07T22:50:03Z [info] insomnia: screen awake: display sleep held off for the session
2026-11-07T22:50:06Z [info] insomnia: screen awake: released, idle display sleep and the screen lock are back
2026-11-07T22:50:06Z [info] insomnia: session end (quit)
2026-11-07T22:50:06Z [info] insomnia: sleep restored
```

Check 6, [longest-preset capture](captures/check6-longest-preset.txt), at 22:50:22 UTC, deadline 23:00:14 UTC. The 22:50:26 UTC capture after Quit has no Insomnia assertion and SleepDisabled 0.

```text
   pid 4584(Insomnia): [0x000005960005814d] 00:00:02 PreventUserIdleDisplaySleep named: "Insomnia session: keep the screen on and unlocked"  
	Timeout will fire in 592 secs Action=TimeoutActionTurnOff
```

The unresolved observation is the normal end control. A fresh two-minute session was confirmed active at 22:48:21 UTC. A 1.5-second hold at the visible control at coordinates 1244,18, followed by one retry at 1239,15 with a second event helper, opened duration inputs instead of ending the session. Both exceed the source's 0.6-second hold requirement. At 22:48:27 and 22:48:58 UTC, session.json and the assertion remained, with no `session end (user)` log. This establishes a coverage gap for normal end. It does not establish whether the cause is the app's hit testing or the event driver. Quit released the assertion successfully afterward.

Evidence for that observation:

- [Active baseline](captures/check5a-normal-end-baseline.txt) and [control before the hold](pictures/normal-end-baseline.png).
- [First attempt output](captures/check5a-normal-end-attempt1.txt) and [resulting duration inputs](pictures/normal-end-attempt1.png).
- [Retry output](captures/check5a-normal-end-attempt2.txt) and [retry duration inputs](pictures/normal-end-attempt2.png).

The timer, extension, frozen deadline, toggle-off, force-kill, and Quit paths showed no assertion failure. The test log contains no `could not move the hold's timeout`, `IOPMAssertionRelease` failure, or `could not release the display hold` line during this run. [Log excerpts](insomnia.log-excerpts.txt) include the deadline recovery and relaunch events.

Limits: this run checked display-assertion behavior in a VM. It did not test a physical lid, a physical display's sleep and lock, immediate-password policy, or all session lengths up to 30 days. The longest configured preset was ten minutes. The VM also had a separate powerd display-delay assertion, so absence of Insomnia's assertion does not prove that the display slept at that instant. Notification authorization and Wi-Fi hardware were unavailable in the VM. Early input-driver calibration and one failed menu lookup are retained in captures and explicitly excluded from successful-check baselines.

Reviewed pictures are [default off and its note](pictures/settings-default-off-complete.png), [toggle on and its note](pictures/settings-toggle-on-verified.png), [menu after frozen recovery](pictures/frozen-resumed-menu.png), and the three normal-end images above. All are cropped to Insomnia controls or Settings. Raw and incomplete takes are retained only in `rejected/` and are excluded from shareable evidence. `scripts/` contains operational test scripts and the command history, not material for a pull request.

Cleanup completed at 22:50:58 UTC. No session or Insomnia process remains, SleepDisabled is 0, and no Insomnia display assertion remains. The VM's original absence of config.json was restored. The VM work folder was deleted. The test wrote its files outside the temporary directory, and no test or installer temporary directory remained. The installed CDHash still matches the supplied build. The mini staging folder was deleted, its claim was released, and the VM was left running. See [VM cleanup capture](captures/cleanup-final-vm-state.txt) and [final free-space capture](captures/cleanup-final-mini-state.txt).
