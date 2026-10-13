# Menu bar and settings

Right-click or Control-click the eye or countdown for quick actions. The 30m, 1h, 2h, 4h, 6h and 8h
buttons start a session or add time. Left-click toggles the
configured default duration, initially four hours. Settings > General manages
presets and the default. The status item contains only the eye and timer;
left-click either to end the session. There is no separate X button.
The AppKit host consumes the complete right-click or Control-click gesture
before SwiftUI sees it, including drag and release events. Opening the menu
does not start or end a session.

Quick actions use a 260-point panel with a three-column preset grid. The
content owns its short entrance animation. Eye opening uses a 0.28-second
spring; hover feedback settles in 0.06 seconds and settings disclosures in
0.1 seconds. Reduce Motion retains short fades.

Successful manual activation plays a soft rising boop; a fully restored
manual end plays a lower bleep. Opening the menu, adding time and failed
actions stay silent. Both 0.14-second cues are generated locally and cached
as native NSSound objects. Playback does not change system audio settings.

Settings uses a native macOS preferences toolbar with General, Lid actions
and Advanced panes. Command-1, Command-2 and Command-3 switch panes; Command-,
opens the same retained window. The selected pane supplies the window title
and preferred size. The minimize and zoom buttons are dimmed, while manual
resizing and scrolling accommodate expanded controls.

Grouped forms, switch controls, disclosure triangles, typography and accent
colors come from the system. There is no custom sidebar, selected glass tile,
large page heading or frosted background over the content. Disclosure labels
remain clickable across the row. Duration management, paused apps and battery
controls start expanded. Preset, app and terminal lists use bordered fields
with separators and bounded scrolling, so every saved item remains reachable.
App identifiers appear beneath resolved names. Entry rows have explicit labels
and format examples; hotspot fields use a wider, aligned column. The panes
allow more initial height for the expanded controls.
Section headings pair system headline typography with SF Symbols. App lists
use cached installed-app icons, with a system fallback for missing apps.
Disclosure labels retain their native accessibility name without overriding
the labels of text fields and buttons inside them. AppKit applies the pane
size after SwiftUI replaces the form, preventing the first pane switch from
shrinking the window to its minimum height.
This follows [Apple's Settings guidance](https://developer.apple.com/design/human-interface-guidelines/settings)
and lets [standard components adopt Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).
Reduce Motion uses opacity transitions for the eye and countdown.

The visible timer shows hours and minutes, rounding up to the next minute,
so a four-hour session starts at `4:00`. The deadline remains second-precise.
The eye owns its drawing state and opening transaction independently of
status-item layout changes. Content actions and disclosure labels use native hand-cursor regions;
these regions do not intercept clicks and are removed with their views.

AppKit still owns the status item and settings window. SwiftUI draws their
content; the existing SessionManager, configuration store, journal and
recovery services own lifecycle and persistence. The countdown is isolated
from the eye and controls. Password reads and app scans run only when their
settings are visible; resolved app names are cached. No performance benchmark
or percentage speedup is claimed. No dependencies were added.

## Preview

Run `./scripts/preview-app.sh` with an Xcode toolchain that supports Swift 6.2.
The separate debug bundle opens as a regular Mac app for native inspection.
It uses temporary data and fixture power, process,
backstop, login-item and password services. Its timer does not prevent sleep.
Production release builds exclude this preview mode.

The sealed recovery script locates the binary and Info.plist beside itself
when it runs inside an app bundle. This supports moving the signed app to
`/Applications` without consulting another installed copy. The standard
install and uninstall scripts still target the per-user Applications folder.

Optional flags:

- `--ui-preview-menu`: show the same quick menu in a regular window.
- `--ui-preview-light`: force light appearance in the preview.
- `--ui-preview-compact`: use the pane's preferred size without restoring a saved frame.
- `--ui-preview-popover`: open the actual status-item popover after launch.
- `--ui-preview-active`: start a fixture session before opening that popover.

Quit the existing preview before rebuilding. Current native Settings captures:

| Pane | Dark | Light |
| --- | --- | --- |
| General | [Dark](assets/ui/settings-general-dark.png) | [Light](assets/ui/settings-general-light.png) |
| Lid actions | [Dark](assets/ui/settings-lid-dark.png) | [Light](assets/ui/settings-lid-light.png) |
| Advanced | [Dark](assets/ui/settings-advanced-dark.png) | [Light](assets/ui/settings-advanced-light.png) |

[Dark menu](assets/ui/menu-dark.png),
[dark settings](assets/ui/settings-dark.png) and
[light settings](assets/ui/settings-light.png) are native captures from the
initial UI revision. Their timer and gesture hints predate the current
hours-and-minutes display and click mapping. The title-bar sharing indicator
belongs to macOS.

## Validation limits

Native checks of the initial UI revision covered quick start, extension,
ending, settings navigation, disclosures, app selection and preset editing
in the fixture environment. The native preferences toolbar, keyboard pane
navigation and native disclosure rendering were checked in the regular
fixture preview. Current checks covered full-row disclosure labels,
Command-Comma reopening, the first pane switch, duration entry and removal,
bounded-list scrolling and hotspot text entry. All three panes were captured
in light and dark appearance with fixture data. The latest revision passed
151 focused tests, including bundled recovery after app relocation, and the
release build with warnings as errors. The signed build was installed and
launched from `/Applications/Insomnia.app`; its loaded recovery agent was
verified against the new bundle path and signature. The preview was then
removed. Live sound playback and status-item gestures still need
a supervised check.
Actual Command-drag and saved-position persistence need a manual macOS check.
Gesture forwarding has unit coverage. Real power and lid-close behavior were
not exercised by the preview. The menu hides debug build notices but retains
recovery warnings; simulation builds still identify themselves in logs.
