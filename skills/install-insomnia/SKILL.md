---
name: install-insomnia
description: Install or upgrade Insomnia, the macOS menu bar app that keeps a Mac awake for a timed session, from a GitHub release or from source. Use when the user asks to install, update or reinstall Insomnia.
---

# Install Insomnia

The exact commands are in
[docs/install.md](https://github.com/krishhgg/Insomnia/blob/main/docs/install.md).
Read that page, then follow these steps. Never run `sudo` yourself and never
pass a password to it. When a step needs the administrator password, give the
user the exact command to run in Terminal and wait for them to say it finished.

1. **Check the Mac.** Insomnia needs macOS 26 or later (`sw_vers -productVersion`).
   Release zips are universal and install on Apple Silicon and Intel Macs.
   Only Apple Silicon has been tested. On an Intel Mac, tell the user that,
   and that lid close leaves the keyboard backlight alone there.
2. **Pick the channel.** Use the latest stable release unless the user asked
   for the newest nightly. If the release is `v0.1.0`, follow its release notes
   instead of docs/install.md.
3. **Download and verify.** Follow "Install a release yourself", steps 1 and
   2. Run both checks. Keep `--source-digest` and the full 40-character commit.
   If either check fails, stop and tell the user. Do not download a different
   file to get past it.
4. **Install.** Step 3 of the same section runs `install.sh`, which asks for
   the administrator password, so hand that command to the user. Before they
   run it, tell them the installer adds a sudoers rule. That rule lets their
   account run four `pmset` power commands without a password, and the page's
   "What gets installed" section lists them. `--allow-unverified-origin`
   tells the installer that both download checks passed. Never suggest it
   when they did not.
5. **First launch.** macOS blocks the first launch of a downloaded app until
   the user allows it in System Settings > Privacy & Security.
6. **Confirm.** The eye shows in the menu bar, and
   `launchctl print gui/$(id -u)/com.insomnia.backstop` finds the recovery
   agent. Ask the user to review the lid-close options in Settings before the
   first session.

An upgrade is the same steps. The installer asks the running app to quit and
stops if a session is still waiting to be undone. Then use the
maintain-insomnia skill to find out why.

To build from source, follow "Build from source" on the same page. Its
`./scripts/install.sh` also needs the password.
