# Optional extras

The [README](../README.md#optional-extras) has a summary of each.

## iPhone hotspot handoff

Set **System Settings → Wi-Fi → Ask to join hotspots → Automatically**, then
enter the hotspot SSID and password in Insomnia Settings. The password is
stored in the login Keychain under service `insomnia-hotspot`. Insomnia uses
CoreWLAN to find and join that network without putting the password in process
arguments.

The Keychain item's access list names only the build of Insomnia that saved
it, and Insomnia reads it with Keychain prompts switched off, so a join during
an outage never raises a dialog. The installer signs each build ad hoc, which
gives every install a new identity: after a reinstall the saved password is
unreadable by the new build. Insomnia then skips the join, shows "Hotspot
password unreadable by this build" in the right-click menu and in Settings,
and sends one notification per outage. The warning belongs to the SSID it was
read for. Change the SSID and it goes, and Settings checks the new SSID's
saved password instead. Enter the password again in Settings and save; the
save writes the new password before it removes the old item,
and macOS may ask you to allow Insomnia to delete the old one, or to unlock
the login keychain. If that save is cut off after the old item is gone,
the password reads as missing and you enter it once more: Insomnia never
reads a half-finished save's copy. The Save button reads "Saving…" until
macOS answers, and "Saved" only while the SSID and password fields still
hold what was saved. A join that was waiting while you changed the SSID is
dropped, and the next retry uses the new SSID. A Settings read that was
waiting is dropped too, and Settings reads the new SSID's password instead.
Anything you type in the password field while Settings is still loading the
saved one stays, even if you delete it again. The rest of Insomnia,
including the battery floor and End, keeps running while the dialog is open.
A build signed with a stable identity would keep the item readable across
upgrades.

macOS requires Location Services permission to reveal network names. Insomnia
requests it on the first hotspot save, or when starting a session with a
configured hotspot, not merely on launch. If denied, use the Location row in
Settings to open **Privacy & Security → Location Services**. Mac apps have no
when-in-use grant, so System Settings records it as Location Services access
for Insomnia. Insomnia uses it only to read Wi-Fi network names through
CoreWLAN and never requests your location.

## Several hotspots in priority order

Turn on **Join several hotspots in priority order** in Settings to replace the
single hotspot with a list, highest priority first. The list starts with the
hotspot already set, and its saved password comes with it. Add each other
hotspot by name, and use the arrows to order them. An iPhone or iPad needs no
password: Insomnia wakes it over Bluetooth and it hands its password over.
Enter a password for any other hotspot, or as a fallback for a device
Bluetooth can't reach.
**Nearby…** lists names to pick from, so a device name with the curly
apostrophe iOS puts in it does not have to be typed by hand. Under "Phones and
tablets" are the devices macOS sees over Bluetooth, signed in to your Apple
Account or in your family, even with their hotspot off; a device's hotspot
uses its name. Insomnia reads that list through `SFRemoteHotspotSession` in
the private Sharing framework, the list the Wi-Fi menu shows; Settings only
browses it. On a macOS where that class is not
as measured, the section is empty. Under "Wi-Fi networks" are the names
macOS found in its own last scan, listed at once, and then those a fresh scan
adds, which can take 10 s or more; both need Location permission. Another
hotspot shows up there while it broadcasts. Each password is a login Keychain item under service `insomnia-hotspot`
with the hotspot's name as the account, the same kind of item the single
hotspot uses, with the same access list. Saving a name already on the list
replaces its password. Removing a hotspot deletes its item, unless the single
hotspot setting still names it. Turning the list off goes back to the single
hotspot and keeps the list for later.

When the Wi-Fi drops during a session, Insomnia waits 5 s, as with one
hotspot, so macOS can rejoin a network itself. An iPhone or iPad keeps its
hotspot off the air while nothing uses it, even with "Allow Others to Join"
on, so a Wi-Fi scan cannot find it. So Insomnia first asks which listed
devices macOS sees over Bluetooth, and tries those first, in list order: it
asks the device to turn its hotspot on, as the Wi-Fi menu does when you pick
it, and joins with the network name and password the device hands back,
looking for it up to 3 times while it comes on the air. The rest follow in
list order. Each is joined with the password it handed over earlier in the
session, else with its saved password. Insomnia keeps a handed-over password in
memory until the session ends and never writes it anywhere. Names match
whichever apostrophe they use. A hotspot that didn't wake and has no saved
password is skipped quietly. One whose saved password is unreadable is skipped
too. The menu names the first such one, and each gets one notification per
outage, with its name. Retries follow the same backoff: 5,
10, 20, then every 30 s.

**Move to a higher hotspot when it is back in range** is on by default with
the list. Every 30 s during a session, while the Mac is on a lower hotspot on
the list, Insomnia scans for the hotspots above it. Once two scans in a row
find one at -70 dBm or stronger, Insomnia wakes the higher device for its
password (else uses one it handed over or a saved one), then joins the
higher hotspot. The join scans for it once more before it leaves the current
network, so a hotspot that went away in the meantime costs no time offline. If
the join is refused and leaves the Mac on no network, Insomnia rejoins the
hotspot it left at once. After a move, made or not, the next one waits 5
minutes. On the top hotspot, or on a network that is not on the list, a check
reads only the current network's name and scans nothing. With the list or
the move turned off there is no check at all. Each move takes the Mac offline
for as long as the join takes, and `handoffs.log` records that gap like any
other outage.

**Return to a saved Wi-Fi network when one is back in range** is also on by
default with the list. It covers getting home with the Mac still on a hotspot.
Every 30 s during a session, while the Mac is on a hotspot Insomnia joined,
Insomnia scans for the Wi-Fi networks macOS has saved, other than the hotspots
on the list. Once two scans in a row find one at -70 dBm or stronger,
Insomnia leaves the hotspot and macOS's own auto-join rejoins the saved
network, about 15 s offline. Insomnia never has that network's password, so
it does not join it itself. For 30 s after it leaves, the failover holds its
joins while macOS rejoins. If the Mac is still offline after that, the failover
joins a hotspot as in any other outage. A saved network takes precedence over
a higher hotspot. A hotspot you or macOS joined is left alone. Insomnia remembers which hotspot it
joined in `joined-hotspot.json`, so a restart, a reinstall or a new session
still hands back. It forgets once a check finds the Mac on a network that is
not one of the listed hotspots. After a
hand-back, made or not, the next one waits 5 minutes, and a network macOS did
not rejoin is not handed back to again that session. Any saved network
counts, including a café's with a sign-in page, so turn this off if that gets
in the way.

Insomnia does not change macOS's own **Ask to join hotspots** setting. CoreWLAN
can scan for a hotspot and join it, but it has no call to wake one. macOS can
wake a nearby iPhone or iPad hotspot over Bluetooth (Instant Hotspot). So leave
that setting on Automatically: macOS gets the first seconds of an outage,
Insomnia takes over after that, and the move up the list corrects macOS if it
picked a lower hotspot.

When the Wi-Fi network that drops is one macOS joined, such as your home
network, Insomnia waits 20 s before it wakes a hotspot, so a brief blip ends
with macOS rejoining that network and no hotspot turned on. When a hotspot
Insomnia joined drops, it moves on after 5 s. Turn on **Join a hotspot as soon
as Wi-Fi drops (aggressive)** for the 5 s wait in every outage.

insomnia.log does not name the Wi-Fi networks the Mac lands on or hands back
to. Each one appears as a tag such as `network 3f9a1c07`, made with a key kept
only on this Mac (`network-tag-key.json`), so a tag tells two networks apart
but can't be traced back to a network's name. Hotspots on the list keep their
names.

## tmux nudge

After a long outage (90 seconds by default) Insomnia types `continue` into
each configured tmux target. The default target list is empty, and a listed
pane is only nudged if you have marked it yourself, with a pane option that
is read again before every send:

```bash
tmux set-option -p -t <session:window.pane> @insomnia-nudge on
```

Mark a dedicated, disposable agent pane, not one you type in, because pending
text is opaque to Insomnia. Enter is off by default, so the word is typed and
nothing submits it. Turn on "Press Enter after continue" in Settings to submit
it, knowing that Enter also submits anything already typed in that pane. The
option must be on the pane itself (`-p`). One set on the session or window
does not count. Pane options need tmux 3.0 or later. Ending a session cancels
pending automation but cannot retract keystrokes already sent.

## Chrome, Chromium, Arc and Comet throttling

Chromium browsers can throttle windows macOS considers occluded, including
when the lid is closed. Insomnia detects supported running browsers missing
`--disable-backgrounding-occluded-windows` or `--disable-renderer-backgrounding`
and offers **Relaunch [browser] unthrottled** in the right-click menu. The item
asks first, because the browser is quit and its windows and tabs come back only
if it is set to reopen them on startup. If the browser has quit by the time you
confirm, nothing is quit or launched and a notification says so. Insomnia reads the browser's profile
arguments before quitting and carries them over. If it cannot read them, cannot
read the kernel's start time that ties them to the browser, or the browser
quits on its own while they are read, it quits nothing and says so. If the
browser has not quit after 10 s, nothing is launched, and a notification says
so: a second copy beside the first would be worse than a throttled one. The
quit request stands, so a browser that closes later has to be opened again by
hand. After `open` returns, Insomnia waits up to 5 s for the browser to show up
as running and notifies if it does not. Each of these reasons also stays in the
right-click menu as a warning line, one per browser, until that browser's next
relaunch or the next session, so it is there even with notifications off. A
relaunch that ends after its session ended, or after a newer relaunch of the
same browser started, reports nothing. This is not a guarantee that every web
app will keep working while the lid is closed.

## Configuration and privacy

Configuration lives in `~/Library/Application Support/Insomnia/config.json`.
Use Settings for the app's controls; [Config.swift](../Sources/Insomnia/Model/Config.swift)
defines the full configuration and defaults. Local logs can contain SSIDs,
process metadata, and tmux targets. Check them before sharing publicly.
Lines the app writes to `insomnia.log` also go to the unified log with their
bodies marked private, so `log show` and other local programs see `<private>`
in place of the text unless private data logging is enabled on the Mac. The
backstop's lines go only to `insomnia.log`, which keeps the full text of both.
The files in Application Support/Insomnia and Logs/Insomnia (config, session,
journal, recovery lock, the record of a power command left running, the two
logs) are owner-only, mode 0600 with those two directories 0700, and one left
looser by an older build is tightened the next time the app or the backstop
opens it. Insomnia sets only these modes and
leaves any access control list (ACL) on these files and folders as it is, so
an ACL someone added, or one inherited from a parent folder, can still give
another account access (`ls -le` shows it). The LaunchAgent plist and the installed
scripts hold no private data and keep the modes the installer gives them.
`insomnia.log` and `handoffs.log` are capped at 1 MiB: a
log past the cap is renamed to `insomnia.log.1` or `handoffs.log.1`,
replacing the previous copy, and a new file starts. The cap does not apply
to a log you replace with a symlink. Insomnia writes through the link and
never rotates it, since the rename would move the link and not the file it
points to, and it logs that once. You set up the link, so trimming the file
it points to is up to you.

Insomnia makes one kind of network request, and only when you click "Check
for updates" in Settings > App: two unauthenticated GETs at api.github.com,
for the release this repository marks Latest and for the first page of its
releases list, with the installed version as their user agent and nothing
else about the Mac. It never checks on its own, opens the releases page only
on request, and never downloads or installs a build.

`INSOMNIA_HOME` relocates app support files, logs, and LaunchAgents for testing.
It is **not an installation sandbox**: installation/removal also involves the
app bundle and sudoers rule. The installer refuses a relocated home. See
[Paths.swift](../Sources/Insomnia/Store/Paths.swift) for the layout.
