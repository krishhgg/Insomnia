# What happens when the lid closes

The [README](../README.md#what-happens-when-the-lid-closes) lists the
defaults. This page has the details.

During a session, Insomnia turns the display and keyboard backlight off
(saving their brightness first), pauses the apps on the freeze list (and, if
you opt in, every other Dock app that is not an agent app), checks whether
Docker Desktop is idle before pausing it, and saves then mutes audio.
Reopening the lid attempts to undo those lid actions. If the lid opens
while Insomnia is still checking Docker, Docker is left running and the undo
starts right away. **The timer keeps counting down while the lid is
closed**; only its on-screen redraw pauses, also for a session started with
the lid already closed.

## Display and keyboard backlight

The display step exists because the sleep guard stops macOS from doing it:
with sleep disabled, closing the lid no longer turns the panel or the keys off
by itself. Insomnia sets both to zero and restores them when the lid opens.
Both go through private macOS frameworks. The display calls run only on a
macOS major version they were measured on (26). The keyboard calls run only
while the private keyboard class has the method signatures measured on 26,
on whatever version. If either check refuses a device, Insomnia leaves it
alone and Settings says why under the toggle. A level saved before an update
that the check now refuses stays saved for a version that can restore it, and
the menu says to set it with the brightness keys meanwhile. That version leaves
a level you set by hand alone, and decides only on a reading taken with the
display awake and the keys not dimmed. Once Insomnia's own Low Power Mode has
been on over the saved display level, it leaves that level undecided until the
Mac restarts, through relaunches of the app, and until then a lid close leaves
that display lit and only asks it to sleep. The same goes when the recovery
agent switches that mode off before Insomnia starts again, and when Insomnia
switches off a mode still claimed from before a restart. That mode may read
off then, yet it may have gone off only a moment before, so the level waits
for the next restart even when the mode has been off for days. Once it has seen
that display lit above zero, it never writes the saved level over a zero you
set by hand, also after a relaunch or a restart. It cannot tell that zero
from one auto-brightness left under a closing lid, so the saved level stays
undecided, with nothing written, until you raise the display above zero. If Insomnia cannot record that it saw the display lit, or that the
saved level is settled, Quit waits until it can.
The display comes back to the brightness sampled while the lid was open, not
the reading at the moment of closing (auto-brightness has already dimmed the
panel under the closing lid by then, and Low Power Mode rescales it), and if
Insomnia's own Low Power Mode was on while the lid was closed the value is
written once more when the mode ends. If Insomnia is not running when you open
the lid, press the brightness-up key.

## Defaults

The defaults are worth knowing:

- **Selected apps:** Slack, WhatsApp, and Discord are on the freeze list.
  Configured agent apps are excluded from this ordinary list.
- **Every other app:** "Freeze every other app while the lid is closed" is
  off, so a fresh install pauses the freeze list only. Turn it on to also pause
  every Dock app that is not an agent app, an Apple app, Docker Desktop or a
  built-in protected app (editors, terminals, browsers, AI apps, password
  managers, local databases, Tailscale, local model servers; JetBrains IDEs by
  bundle-id prefix), so only agents keep running with the lid shut. Menu-bar
  apps are never picked up automatically; add them to the freeze list if you
  want them paused. Settings shows a "Would freeze now" line listing what the
  automatic scope would pause at that moment.
- **Meeting, recording and dictation apps:** never frozen by "Freeze every
  other app", with their helper apps: Zoom, Microsoft Teams (new and classic),
  Webex (and the older Webex Meetings app), FaceTime, Wispr Flow, Granola,
  Otter, OBS and Loom. Freezing one ends the call, the recording or the
  meeting notes when the lid closes. Putting one on the freeze list by hand
  still freezes it, except FaceTime, which is an Apple app.
- **Docker rule:** off. Turn it on to pause Docker Desktop on lid close when
  no container is running. The local Desktop socket is asked once to pick
  Docker up and once more right before the pause; a busy answer, a failed
  `docker ps` or a timeout at either point leaves Docker running. A container
  that starts between the second check and the pause is still paused with
  Desktop, so leave the rule off for Docker workloads an unexpected pause
  would hurt.
- **Mute on close:** on, so sound stops when the lid closes. Lid open
  restores each output that was muted, even if another one is in use by then.
  An output that is not connected stays muted until it reconnects: Insomnia
  restores it then if it is running, or at the next launch. Ending or
  quitting a session does not wait for it. The end notification and the menu
  name it, and the menu's "Stop waiting for <device>" leaves it as it is. A
  restore that fails on a connected output is retried by Insomnia while it
  runs, and at the next launch.
- **Microphone:** on Mac laptops with Apple silicon or a T2 chip, closing the
  lid disconnects the built-in microphone in hardware. Recording a meeting
  with the lid closed needs AirPods or an external mic; Settings says the same
  next to the lid-close options.
- **Display and keyboard backlight:** on ("Turn off the display and keyboard
  backlight" in Settings). Both values are saved to the journal before they
  are changed.
- **Low Power Mode while the lid is closed:** on. With sleep disabled a closed
  Mac otherwise keeps running at full speed; the mode is switched off again
  when the lid opens, unless a battery or thermal rule still wants it.
- **Battery rules:** below 40% on battery, request Low Power Mode; below 10%,
  end the session. A battery that is present but cannot be read on two
  consecutive reads while on battery also ends the session, with a
  notification saying why: the floor cannot be applied to a level nobody can
  read. One failed read is tolerated, and the level is re-read every 30 s
  until it is readable again. A desktop has no battery and no floor. Serious
  thermal state requests Low Power Mode; critical thermal state ends the
  session. The Low Power Mode requests need the app to be running. The ends
  do not: the `launchd` backstop reads the battery and the thermal pressure
  level once a minute and ends the session itself when the app is gone, the
  charge is below the end floor on battery power or cannot be read, or the
  thermal level is critical (see [How recovery works](recovery.md)). Like the app, it
  treats a Mac as a desktop only when the I/O Registry has no battery.
  Setting the end floor to 0 turns the battery end off. Otherwise the end
  floor stays below the Low Power Mode floor. The Settings steppers move the
  other floor when the two would cross, and a hand-edited `config.json` with
  the floors out of order is corrected at launch, and logged, by raising the
  Low Power Mode floor.

## Upgrading from an earlier build

Upgrading from an earlier build changes two of these once. On the first
launch of this version, a config.json saved by an earlier build gets "Freeze
every other app" turned off and "Mute audio on lid close" turned on, and
Insomnia posts a notification naming what changed. Settings shows the same
line at the top of Lid-close actions until you dismiss it, for anyone with
notifications off. The toggles are right below it. config.json records that
the update ran (`lidCloseDefaultsApplied`), so a setting you turn back stays
the way you set it. A fresh install starts with the new defaults and no
notice.

## Testing lid actions without closing the lid

To exercise the lid actions without closing the lid, run
`scripts/simulate-lid.sh closed` and then `scripts/simulate-lid.sh open` during
a session; the app runs the same actions it would on a real lid event. Only a
build with the file watcher compiled in reads that trigger: a debug build, or
a release build installed with `INSOMNIA_LID_SIMULATION=1 ./scripts/install.sh`.
A normal install has no watcher, so no program running as your user can replay
the lid actions by writing a file. A build that has it logs "Lid simulation
build" at launch and shows the same line in the status menu and in Settings.
