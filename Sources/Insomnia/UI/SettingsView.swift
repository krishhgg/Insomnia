import AppKit
import SwiftUI

/// The settings window (spec 10): one page grouped by what happens, with
/// Edit Apps and the hotspot in sheets. Every change is saved to
/// config.json as it is made.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    /// Launch at login as macOS reports it, not as config.json remembers it.
    let loginItem: LoginItem
    /// The "Check for updates" button's one request and its report.
    let releases: ReleaseChecker

    @State private var editingApps = false
    @State private var editingHotspot = false

    var body: some View {
        Form {
            lidSection
            agentSection
            powerSection
            networkSection
            appSection
        }
        .formStyle(.grouped)
        // One width, so a long notice wraps instead of widening the window.
        // No height: on a screen shorter than the form, SettingsWindow's
        // window fits the screen and the form scrolls.
        .frame(width: 490)
        // The user may have approved or removed the login item in System
        // Settings since launch (LoginItem also re-reads whenever the app
        // becomes active, for a window left open).
        .onAppear { loginItem.refresh() }
        .sheet(isPresented: $editingApps) { AppsSheet(manager: manager) }
        .sheet(isPresented: $editingHotspot) {
            HotspotSheet(manager: manager, secrets: secrets, locationPermission: locationPermission)
        }
    }

    /// Under the mute toggle and in the README. Apple Platform Security,
    /// "Hardware microphone disconnect".
    nonisolated static let microphoneNote =
        "On Mac laptops with Apple silicon or a T2 chip, closing the lid disconnects the "
        + "built-in microphone in hardware. Recording a meeting with the lid closed needs "
        + "AirPods or an external mic."

    private var lidSection: some View {
        Section("When the lid closes") {
            // The one-time lid-close update, for a user who has
            // notifications turned off. Stays until dismissed.
            if let notice = manager.config.lidCloseDefaultsNotice {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.settingsLine)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { manager.dismissLidCloseNotice() }
                }
            }
            Toggle(
                "Turn off the display and keyboard backlight",
                isOn: manager.binding(\.darkenDisplayOnLidClose))
            ForEach(manager.darkenRefusals, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle(isOn: manager.binding(\.muteOnLidClose)) {
                Text("Mute audio")
                Text(Self.microphoneNote)
            }
            Toggle("Turn on Low Power Mode", isOn: manager.binding(\.lowPowerOnLidClose))
                // A floor input: apply it now if the lid is already closed.
                .onChange(of: manager.config.lowPowerOnLidClose) {
                    manager.services?.reevaluateFloors()
                }
        }
    }

    private var agentSection: some View {
        Section("Apps") {
            LabeledContent {
            } label: {
                Text("Keep running")
                Text(RunningApps.summary(of: manager.config.apps(with: .keepRunning)))
            }
            LabeledContent {
            } label: {
                Text("Freeze when lid closes")
                Text(RunningApps.summary(of: manager.config.apps(with: .freeze)))
            }
            HStack {
                Spacer()
                Button("Edit Apps\u{2026}") { editingApps = true }
            }
        }
    }

    private var powerSection: some View {
        Section("Battery") {
            Picker("Turn on Low Power Mode below", selection: lowPowerFloor) {
                floorLevels(through: 100, keeping: manager.config.lowPowerFloor)
            }
            Picker("End the session below", selection: endFloor) {
                floorLevels(through: Config.maxEndFloor, keeping: manager.config.endFloor)
            }
            Toggle(isOn: manager.binding(\.thermalRules)) {
                Text("Protect against overheating")
                Text(
                    "Turns on Low Power Mode when the Mac runs hot, and ends the session "
                        + "if it gets critically hot.")
            }
        }
    }

    /// The floor menus go through the Config setters, which move the other
    /// floor when the two would cross.
    private var lowPowerFloor: Binding<Int> {
        Binding(
            get: { manager.config.lowPowerFloor },
            set: { level in manager.updateConfig { $0.setLowPowerFloor(level) } })
    }

    private var endFloor: Binding<Int> {
        Binding(
            get: { manager.config.endFloor },
            set: { level in manager.updateConfig { $0.setEndFloor(level) } })
    }

    private func floorLevels(through max: Int, keeping current: Int) -> some View {
        ForEach(Config.floorChoices(through: max, keeping: current), id: \.self) { level in
            Text(level == 0 ? "Never" : "\(level)%").tag(level)
        }
    }

    private var networkSection: some View {
        Section("If Wi-Fi drops") {
            LabeledContent {
                Button(hotspotName.isEmpty ? "Set Up\u{2026}" : "Edit\u{2026}") {
                    editingHotspot = true
                }
            } label: {
                Text("Join an iPhone hotspot")
                Text(hotspotSummary)
            }
            // What the failover last found wrong with the saved password.
            if let notice = manager.services?.status.hotspotPasswordReport?
                .problem(for: hotspotName)?.settingsNotice
            {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var hotspotName: String { HotspotSSID.normalized(manager.config.hotspotSSID) }

    /// The hotspot set up, or "Not set up", and how many tmux panes an
    /// outage nudges.
    private var hotspotSummary: String {
        let panes = manager.config.tmuxTargets.count
        let nudges = panes == 0 ? "" : ", nudges \(panes) tmux \(panes == 1 ? "pane" : "panes")"
        return (hotspotName.isEmpty ? "Not set up" : hotspotName) + nudges
    }

    private var appSection: some View {
        Section("General") {
            Picker("Default session length", selection: manager.binding(\.defaultPreset)) {
                ForEach(lengths, id: \.self) { length in
                    Text(Self.lengthLabel(length)).tag(length)
                }
            }
            Picker("Default field", selection: manager.binding(\.defaultFocusField)) {
                ForEach(DurationInput.Field.allCases, id: \.self) { field in
                    Text(field.placeholder).tag(field)
                }
            }
            .help("The pill that is focused when the pills open")
            Toggle("Open at login", isOn: launchAtLogin)
            loginItemNote
            LabeledContent("Version") {
                Text(AppBuild.current.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            releaseCheck
            if LidSimulationBuild.isCompiledIn {
                Text(LidSimulationBuild.marker)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// The presets, plus a default that is no longer one of them.
    private var lengths: [TimeInterval] {
        Set(manager.config.presets + [manager.config.defaultPreset]).sorted()
    }

    /// "30 minutes", "4 hours", "3 days", in the user's locale; tests pass
    /// an English one.
    static func lengthLabel(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent)
        -> String
    {
        Duration.seconds(seconds)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .wide).locale(locale))
    }

    /// The update check: one request to GitHub's releases list per click,
    /// and the report under the buttons. It opens the releases page and
    /// installs nothing; the installer run again is the upgrade.
    @ViewBuilder
    private var releaseCheck: some View {
        HStack {
            Button(releases.state == .checking ? "Checking" : "Check for updates") { releases.check() }
                .disabled(releases.state == .checking)
            Button("Open releases page") { NSWorkspace.shared.open(GitHubReleaseFetcher.releasesPage) }
        }
        switch releases.state {
        case .idle:
            Text("Asks GitHub when you click, and installs nothing. To upgrade, run the installer again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .checking:
            EmptyView()
        case let .checked(report):
            Text(report.summary)
                .font(.caption)
                .foregroundStyle(report.standing == .newerStableAvailable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        case let .failed(reason):
            Text("Could not check: \(reason)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// The switch shows what macOS has on file (`LoginItem.isRegistered`:
    /// enabled or waiting for approval), so a registration that an upgrade
    /// dropped reads as off even while config.json still says on, and a
    /// pending one can be withdrawn by turning the switch off; the note
    /// below explains the state.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isRegistered },
            set: { on in
                // Persist only what macOS accepted; a refused change leaves
                // the flag as it was and its error on screen.
                manager.updateConfig { config in _ = loginItem.set(on, config: &config) }
            }
        )
    }

    /// One line under the switch: the last error, a pending approval with
    /// the button that opens Login Items, or a flag macOS no longer honours.
    @ViewBuilder
    private var loginItemNote: some View {
        if let error = loginItem.error {
            Text("Login item: \(error)").font(.caption).foregroundStyle(.red)
        } else if loginItem.needsApproval {
            HStack {
                Text(
                    "Waiting for approval in System Settings > General > Login Items. "
                        + "Turn the switch off to withdraw it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { loginItem.openLoginItems() }
            }
        } else if manager.config.launchAtLogin, !loginItem.isRegistered {
            Text(
                "Login item: macOS reports it \(loginItem.status.description). "
                    + "Turn the switch on to register it again.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
