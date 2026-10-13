# Insomnia Desktop 0.1.1

A native desktop edition of [krishhgg/Insomnia](https://github.com/krishhgg/Insomnia), based on upstream commit `b5f7cf08ad9072a666c21192d7c980b7d7ef19d4`. This package contains the exact app binary installed and checked on the development laptop, plus a portable installer. MIT licensed; see LICENSE.

## Install on another Mac

Requires an Apple Silicon Mac running macOS 26 or later. No Xcode or developer tools are needed for this prebuilt package. Use an administrator account that is allowed to install the power permissions on that Mac.

1. Download the desktop ZIP and its published SHA256SUMS. Verify the ZIP in Terminal with `shasum -a 256 -c SHA256SUMS` from the download folder.
2. Unzip it. Double-click **Install.command** in the extracted folder. If macOS blocks it, review and allow it through System Settings > Privacy & Security, then retry. The installer does not remove quarantine or disable Gatekeeper.
3. Enter your Mac administrator password in Terminal when requested. The password is not displayed while typing.
4. Open **Insomnia**, review its settings, and test a short session before leaving work running.

Terminal alternative, from the extracted folder: `bash ./Install.command`.

The installer checks package file hashes, the app signature and the expected code-directory hash. It installs `~/Applications/Insomnia.app`, a recovery LaunchAgent and the upstream narrow power-command permissions. Those permissions allow your user account to run four `pmset` commands without a password: sleep on/off for all power sources, and Low Power Mode on/off on battery. Review `install.sh` before installing. An existing verified rule is reused.

This build is ad-hoc signed, not Developer ID signed or notarized. It was built locally; there is no GitHub Actions attestation. The published checksum identifies the download and the signature checks detect changed app contents; neither certifies its publisher. This is a custom fork edition, not an upstream release.

Fresh settings match the desktop setup: app freezing off, mute on lid close, Low Power Mode on lid close, thermal rules on, battery thresholds 40%/10%, launch at login on, and a four-hour default duration. Existing settings are preserved. Login-item approval may be requested by macOS. No device-specific installation identity, logs, network credentials or active session is included. Optional hotspot credentials must be configured separately on each Mac.

## Use

Overview starts, extends and ends timed awake sessions, with live battery, lid and network-route status. The sidebar groups Lid & audio, Protected apps, Battery & power, Network and General settings. Settings save automatically; failed saves are shown with a retry control. Closing the window leaves Insomnia running. Quit requests recovery before exit.

Upstream's experimental status applies. The release build, signature and UI checks for start, extend, end, power-flag restoration and settings persistence passed on macOS 27.0.1. Physical lid-close behavior and unattended operation were not tested. The automated Swift tests could not run because the installed Command Line Tools lack XCTest. On macOS 27, upstream's version guard disables automatic display darkening; use the brightness controls manually. Keep the Mac on a ventilated desk. An available network route does not guarantee internet, VPN connectivity or AI completion.

To uninstall, run `./uninstall.sh` in this folder. It checks recovery before removing the app, agent and power rule. See the upstream README for recovery limits.
