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

## Chrome, Chromium and Arc throttling

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
opens it. The backstop's `chmod` calls, its `mkdir` of the folder and the
`mktemp` of its private folder in `TMPDIR` have a 30 s limit: one that does
not finish stops that run before it takes the recovery lock, and the next
run tries again. A `mktemp` that ends after that may leave an empty
`insomnia-backstop.*` folder in `TMPDIR`. Insomnia sets only these modes and
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

`INSOMNIA_HOME` relocates app support files, logs, and LaunchAgents for testing.
It is **not an installation sandbox**: installation/removal also involves the
app bundle and sudoers rule. The installer refuses a relocated home. See
[Paths.swift](../Sources/Insomnia/Store/Paths.swift) for the layout.
