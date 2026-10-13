import AppKit
import SwiftUI

/// The settings window (spec 10). Every change is written straight through
/// `manager.config` to config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    /// Launch at login as macOS reports it, not as config.json remembers it.
    let loginItem: LoginItem
    let navigation: SettingsNavigationModel

    @State private var newFreezeBundle = ""
    @State private var newAgentBundle = ""
    @State private var newTmuxTarget = ""
    /// The password field, saving, what was saved, and the notice under
    /// the field.
    @State private var hotspot = HotspotPasswordField()
    /// Names of the apps the automatic lid-close scope would freeze right
    /// now (the freeze list excluded); refreshed on appear and toggle.
    @State private var wouldFreeze: [String] = []
    @State private var isVisible = false
    @State private var pausedAppsExpanded = true
    @State private var powerExpanded = true
    @State private var agentsExpanded = false
    @State private var networkExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var page: SettingsPage { navigation.selection }
    private var canReadNetwork: Bool { isVisible && page == .advanced && networkExpanded }
    private var freezeScope: FreezePreviewScope {
        FreezePreviewScope(config: manager.config)
    }

    var body: some View {
        Form {
            switch page {
            case .general:
                sessionSection
                appSection
            case .lid: lidSection
            case .advanced:
                Section {
                    SettingsDisclosureGroup("Battery & temperature", systemImage: "battery.75percent", isExpanded: $powerExpanded) {
                        if powerExpanded { powerSection }
                    }
                } header: { SettingsSectionHeader(title: "Power", symbol: "bolt") }
                Section {
                    SettingsDisclosureGroup("Protected apps", systemImage: "shield", isExpanded: $agentsExpanded) {
                        if agentsExpanded { agentSection }
                    }
                } header: { SettingsSectionHeader(title: "App protection", symbol: "app.badge.checkmark") }
                Section {
                    SettingsDisclosureGroup("Network & hotspot", systemImage: "wifi", isExpanded: $networkExpanded) {
                        if networkExpanded { networkSection }
                    }
                } header: { SettingsSectionHeader(title: "Connectivity", symbol: "network") }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .controlSize(.regular)
        .id(page)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5)))
        .animation(Motion.interface(reduceMotion: reduceMotion), value: powerExpanded)
        .animation(Motion.interface(reduceMotion: reduceMotion), value: agentsExpanded)
        .animation(Motion.interface(reduceMotion: reduceMotion), value: networkExpanded)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 320)
        .onAppear {
            isVisible = true
            if canReadNetwork { loadPassword() }
            refreshWouldFreeze()
            // The user may have approved or removed the item in System
            // Settings since the launch-time check (LoginItem also re-reads
            // whenever the app becomes active, for a window left open).
            loginItem.refresh()
        }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
            if (event.object as? NSWindow)?.identifier?.rawValue == "insomnia.settings" {
                isVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
            if (event.object as? NSWindow)?.identifier?.rawValue == "insomnia.settings", !isVisible {
                isVisible = true
                refreshWouldFreeze()
                if canReadNetwork { loadPassword() }
            }
        }
        .onChange(of: page) { _, newPage in
            if canReadNetwork { loadPassword() }
            if newPage == .lid { refreshWouldFreeze() }
        }
        .onChange(of: networkExpanded) { if canReadNetwork { loadPassword() } }
        .onChange(of: pausedAppsExpanded) { refreshWouldFreeze() }
        // The failover may find the saved password unreadable while the
        // window is open, and an SSID edit makes the notice about another
        // hotspot's item: the notice follows both.
        .onChange(of: manager.services?.status.hotspotPasswordReport) {
            if canReadNetwork { recheckPassword() }
        }
        .onChange(of: HotspotSSID.normalized(manager.config.hotspotSSID)) {
            if canReadNetwork { recheckPassword() }
        }
        // The preview depends on the toggle, both lists and what is running:
        // recompute only for related config changes while this section is visible.
        .onChange(of: freezeScope) { refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshWouldFreeze() }
    }

    // MARK: Bindings

    private func bind<T: Equatable>(_ keyPath: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(
            get: { manager.config[keyPath: keyPath] },
            set: { value in
                guard manager.config[keyPath: keyPath] != value else { return }
                manager.config[keyPath: keyPath] = value
                save()
            }
        )
    }

    private func save() {
        do {
            try manager.store.saveConfig(manager.config)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
    }

    private func update(_ change: (inout Config) -> Void) {
        var c = manager.config
        change(&c)
        guard c != manager.config else { return }
        manager.config = c
        save()
    }

    /// The floor steppers go through the Config setters, which move the
    /// other floor when the two would cross.
    private var lowPowerFloor: Binding<Int> {
        Binding(get: { manager.config.lowPowerFloor }, set: { v in update { $0.setLowPowerFloor(v) } })
    }

    private var endFloor: Binding<Int> {
        Binding(get: { manager.config.endFloor }, set: { v in update { $0.setEndFloor(v) } })
    }

    // MARK: Sections

    private var sessionSection: some View {
        SettingsSessionControls(
            presets: manager.config.presets,
            defaultPreset: bind(\.defaultPreset),
            maximum: manager.config.maxDuration,
            add: { seconds in
                update {
                    if !$0.presets.contains(seconds) {
                        $0.presets.append(seconds)
                        $0.presets.sort()
                    }
                }
            },
            remove: { seconds in update { $0.presets.removeAll { $0 == seconds } } }
        )
    }

    /// Under the mute toggle and in the README. Apple Platform Security,
    /// "Hardware microphone disconnect".
    nonisolated static let microphoneNote = "On Mac laptops with Apple silicon or a T2 chip, closing the lid disconnects the built-in microphone in hardware. Recording a meeting with the lid closed needs AirPods or an external mic."

    private var lidSection: some View {
        Section {
            // The one-time lid-close update, for a user who has
            // notifications turned off. Stays until dismissed.
            if let notice = manager.config.lidCloseDefaultsNotice {
                HStack(alignment: .firstTextBaseline) {
                    Text(notice.settingsLine)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { manager.dismissLidCloseNotice() }
                        .handCursor()
                }
            }
            Toggle("Turn off the display and keyboard backlight", isOn: bind(\.darkenDisplayOnLidClose))
            ForEach(manager.darkenRefusals, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Mute audio", isOn: bind(\.muteOnLidClose))
            SettingsDisclosureGroup("Microphone compatibility") {
                Text(Self.microphoneNote).font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Use Low Power Mode", isOn: bind(\.lowPowerOnLidClose))
                .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
            SettingsDisclosureGroup("Paused apps", systemImage: "pause.circle", isExpanded: $pausedAppsExpanded) {
            if pausedAppsExpanded {
            VStack(alignment: .leading, spacing: 14) {
            bundleList(
                title: "Paused when the lid closes",
                items: manager.config.freezeList,
                newValue: $newFreezeBundle,
                add: { id in update { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                remove: { id in update { $0.freezeList.removeAll { $0 == id } } }
            )
            Toggle("Pause other apps", isOn: bind(\.freezeAllApps))
                .accessibilityLabel("Pause other apps while the lid is closed")
            Text(wouldFreezeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Pause idle Docker Desktop", isOn: bind(\.dockerRule))
                .accessibilityLabel("Pause Docker Desktop when no containers are running")
            Text("Off by default. Docker pauses only when no containers are running. A container that starts during the final check may be paused with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            }
            }
            .animation(Motion.interface(reduceMotion: reduceMotion), value: pausedAppsExpanded)
            SettingsDisclosureGroup("How lid actions work") {
                Text("Apps on the pause list stop while the lid is closed and resume when it opens. Automatic pausing excludes protected apps such as editors, terminals, browsers and meeting apps. Protected apps are never paused. Display and keyboard brightness are saved before dimming and restored on opening. If Insomnia is no longer running, use the brightness-up key.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            SettingsSectionHeader(title: "Lid-close actions", symbol: "laptopcomputer")
        } footer: {
            Text("Only during an active session. Reopening the lid attempts to restore apps, audio and brightness.")
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            bundleList(
                title: "Always protected",
                items: manager.config.agentList,
                newValue: $newAgentBundle,
                add: { id in update { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                remove: { id in update { $0.agentList.removeAll { $0 == id } } }
            )
            Divider()
            Toggle("Prevent App Nap", isOn: bind(\.disableAppNapForAgents))
                .accessibilityLabel("Prevent App Nap for protected apps")
            Text("Keeps these apps responsive during a session. Their previous preferences are restored when the session ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsDisclosureGroup("About automatic protection") {
                Text("Listed apps are never paused or throttled. Automatic pausing also protects editors, AI apps, terminals, browsers, password managers, databases, Tailscale, model servers and meeting, recording and dictation apps. Adding an unlisted app to the pause list overrides its automatic protection.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var wouldFreezeText: String {
        guard manager.config.freezeAllApps else { return "Only the apps above will pause." }
        return wouldFreeze.isEmpty ? "No other apps will pause." : "Also pauses: \(wouldFreeze.joined(separator: ", "))"
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        guard isVisible, page == .lid, pausedAppsExpanded else { return }
        guard manager.config.freezeAllApps else {
            wouldFreeze = []
            return
        }
        let selfId = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfId).map(\.name)
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(value: lowPowerFloor, in: 0...100, step: Config.floorStep) {
                HStack {
                    Text("Low Power Mode below")
                    Spacer()
                    Text("\(manager.config.lowPowerFloor)%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Low Power Mode battery threshold")
            .accessibilityValue("\(manager.config.lowPowerFloor) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: lowPowerFloor.wrappedValue = min(100, lowPowerFloor.wrappedValue + Config.floorStep)
                case .decrement: lowPowerFloor.wrappedValue = max(0, lowPowerFloor.wrappedValue - Config.floorStep)
                @unknown default: break
                }
            }
            Stepper(value: endFloor, in: 0...Config.maxEndFloor, step: Config.floorStep) {
                HStack {
                    Text("End session below")
                    Spacer()
                    Text("\(manager.config.endFloor)%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("End session battery threshold")
            .accessibilityValue("\(manager.config.endFloor) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: endFloor.wrappedValue = min(Config.maxEndFloor, endFloor.wrappedValue + Config.floorStep)
                case .decrement: endFloor.wrappedValue = max(0, endFloor.wrappedValue - Config.floorStep)
                @unknown default: break
                }
            }
            Text("Set the end threshold to 0 to disable battery-based stopping. Adjusting either threshold keeps the end threshold lower.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Thermal protection", isOn: bind(\.thermalRules))
                .accessibilityLabel("Thermal protection")
            Text("Uses Low Power Mode when hot and ends the session at critical temperature.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Network name") {
                TextField("", text: bind(\.hotspotSSID), prompt: Text("Hotspot SSID"))
                    .labelsHidden()
                    .multilineTextAlignment(.leading)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .accessibilityLabel("Hotspot SSID")
            }
            LabeledContent("Password") {
                HStack {
                    SecureField("", text: Binding(get: { hotspot.password }, set: { hotspot.edit($0) }), prompt: Text("Enter password"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePassword)
                        .accessibilityLabel("Hotspot password")
                    Button(hotspot.buttonTitle(ssid: manager.config.hotspotSSID), action: savePassword)
                        .handCursor()
                        .disabled(hotspot.password.isEmpty || hotspot.saving)
                }
                .frame(width: 300)
            }
            if let notice = hotspot.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            SettingsDisclosureGroup("Location access & password storage") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Location: \(locationPermission.statusDescription)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if locationPermission.isDenied {
                        Button("Open Location Services") {
                            locationPermission.openLocationServicesSettings()
                        }
                        .handCursor()
                    }
                }
                // macOS has no when-in-use grant for Mac apps: the grant is
                // recorded as Location Services access for Insomnia.
                Text("macOS records this grant as Location Services access for Insomnia. Insomnia uses it only to read Wi-Fi network names and never requests your location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The password is saved in your login keychain. After reinstalling Insomnia, enter it again. Location access lets macOS find Wi-Fi networks and your hotspot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            Divider()
            SettingsDisclosureGroup("Terminal reconnection", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 12) {
            Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                HStack {
                    Text("Offline delay")
                    Spacer()
                    Text("\(Int(manager.config.nudgeThreshold)) s").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Terminal reconnection delay")
            .accessibilityValue("\(Int(manager.config.nudgeThreshold)) seconds offline")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudgeSeconds.wrappedValue = min(900, nudgeSeconds.wrappedValue + 10)
                case .decrement: nudgeSeconds.wrappedValue = max(10, nudgeSeconds.wrappedValue - 10)
                @unknown default: break
                }
            }
            Text("After that long offline, Insomnia types \"continue\" into each pane listed below. Only a pane you have marked with this tmux command is nudged. Mark a dedicated pane, not one you type in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(TmuxNudge.markCommand())
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Toggle("Press Enter after continue", isOn: bind(\.tmuxNudgePressesEnter))
            Text("Enter submits whatever is already typed in that pane, including a line that was never finished. When off, \"continue\" is typed and nothing submits it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsListField(items: manager.config.tmuxTargets, emptyLabel: "No terminal panes added") { t in
                HStack {
                    Text(t).font(.system(.body, design: .monospaced))
                    Spacer()
                    SettingsRemoveButton(label: "Remove terminal pane \(t)") {
                        update { $0.tmuxTargets.removeAll { $0 == t } }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("New pane")
                TextField("", text: $newTmuxTarget, prompt: Text("session:window.pane"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(addTmuxTarget)
                    .accessibilityLabel("tmux target")
                Button("Add", action: addTmuxTarget)
                    .handCursor()
                    .disabled(newTmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            }
            }
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in update { $0.nudgeThreshold = TimeInterval(seconds) } }
        )
    }

    /// Fills the field when the window appears (`loadForField`).
    private func loadPassword() {
        let request = hotspot.startLoad(ssid: manager.config.hotspotSSID)
        Task {
            await Self.loadForField(request, secrets: secrets) {
                hotspot.finishRead($0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice)
            }
        }
    }

    /// Reads the notice again for the hotspot configured now, without a
    /// prompt and without touching the field.
    private func recheckPassword() {
        recheckPassword(hotspot.startRead(ssid: manager.config.hotspotSSID))
    }

    private func recheckPassword(_ request: HotspotPasswordField.Read) {
        Task {
            await Self.readForField(
                request,
                first: { await recheckedNotice() },
                again: { await recheckedNotice() },
                finish: { hotspot.finishRead($0, ssid: manager.config.hotspotSSID, password: $1.password, notice: $1.notice) }
            )
        }
    }

    private func recheckedNotice() async -> (password: String, notice: String?) {
        let notice = await Self.hotspotNotice(
            reported: manager.services?.status.hotspotPasswordReport,
            ssid: manager.config.hotspotSSID,
            reread: secrets.peek
        )
        return ("", notice)
    }

    /// Loads the saved password into the field, without a keychain prompt.
    /// An item this build may not read leaves the field empty and says
    /// why, so the user re-enters it; saving then replaces the item (see
    /// `KeychainStore`). The read can wait behind a save, so a field
    /// edited meanwhile is kept, even one typed in and emptied again, and
    /// a password read for an SSID edited away meanwhile is not shown: the
    /// SSID configured now is read instead. That read is a peek: the
    /// account a later save moves the password from stays the one the
    /// window loaded, as it does for any SSID edit, so the old SSID's item
    /// is still removed.
    static func loadForField(
        _ request: HotspotPasswordField.Read,
        secrets: any HotspotSecretStore,
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        await readForField(
            request,
            first: { await loadedPassword(secrets.load) },
            again: { await loadedPassword(secrets.peek) },
            finish: finish
        )
    }

    /// Runs a load or recheck for the field: `first` reads, and `finish`
    /// takes the answer. While the SSID was edited during the read,
    /// `finish` drops the answer, and `again` reads the SSID configured
    /// now, until an answer is used or dropped.
    static func readForField(
        _ request: HotspotPasswordField.Read,
        first: @MainActor () async -> (password: String, notice: String?),
        again: @MainActor () async -> (password: String, notice: String?),
        finish: @MainActor (HotspotPasswordField.Read, (password: String, notice: String?)) -> HotspotPasswordField.ReadAnswer
    ) async {
        var answer = await first()
        var request = request
        while case let .readAgain(next) = finish(request, answer) {
            request = next
            answer = await again()
        }
    }

    /// A prompt-free load: the password for the field, or an empty field
    /// and a notice saying why it cannot be shown.
    static func loadedPassword(_ load: () async throws -> String?) async -> (password: String, notice: String?) {
        do {
            return (try await load() ?? "", nil)
        } catch let error as KeychainError {
            return ("", error.problem.settingsNotice)
        } catch {
            return ("", HotspotPasswordProblem.error(error.localizedDescription).settingsNotice)
        }
    }

    /// The notice under the password field for the hotspot `ssid`
    /// configured now. A problem the failover reports about that hotspot
    /// shows as it is. A report about another SSID, one edited away since,
    /// does not apply, and a cleared report is not taken as "readable": it
    /// also clears when the session ends. Then the keychain is read again,
    /// without a prompt, and the notice says what that read finds. The
    /// field is left as the user has it, and the reread is a peek: a load
    /// would make an SSID typed since then the account a save moves the
    /// password from, and the old SSID's item would stay behind.
    static func hotspotNotice(reported: HotspotPasswordReport?, ssid: String, reread: () async throws -> String?) async -> String? {
        if let problem = reported?.problem(for: ssid) { return problem.settingsNotice }
        return await loadedPassword(reread).notice
    }

    /// Saves, or clears for an empty field. The button shows "Saving..."
    /// until the keychain answers; one save at a time.
    private func savePassword() {
        guard hotspot.startSave() else { return }
        if !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty {
            locationPermission.requestWhenInUse()
        }
        let password = hotspot.password
        Task {
            let outcome = await Self.storePassword(password, in: secrets)
            let recheck = hotspot.finishSave(outcome, ssid: manager.config.hotspotSSID)
            // The failover's report first, so the recheck reads it as the
            // save left it.
            Self.passwordStored(outcome, configuredSSID: manager.config.hotspotSSID, services: manager.services)
            if let recheck { recheckPassword(recheck) }
        }
    }

    /// A save or clear answered. The failover's report goes, and the next
    /// outage notifies afresh, unless the report is about the hotspot
    /// configured now and the save neither stored for it nor removed its
    /// item (`HotspotPasswordReport.stands`).
    static func passwordStored(_ outcome: HotspotStoreOutcome, configuredSSID: String, services: AppServices?) {
        guard case let .stored(stored) = outcome else { return }
        services?.hotspotPasswordChanged(stored.change, configuredSSID: configuredSSID)
    }

    /// Saves `password`, or clears the saved one when it is empty, and
    /// returns what was stored under which SSID and which loaded account
    /// it removed, or the notice for a failure. The store does the keychain work on `KeychainQueue`, so a
    /// save waiting on a keychain dialog waits there while the main actor
    /// (the battery floor, the deadline timer, End) carries on.
    static func storePassword(_ password: String, in secrets: any HotspotSecretStore) async -> HotspotStoreOutcome {
        do {
            let change = if password.isEmpty {
                try await secrets.delete()
            } else {
                try await secrets.save(password)
            }
            return .stored(.init(ssid: change.ssid, password: password, removed: change.removed))
        } catch {
            Log.error("could not save hotspot password: \(error.localizedDescription)")
            return .failed(notice: "Could not save the hotspot password: \(error.localizedDescription)")
        }
    }

    private func addTmuxTarget() {
        let t = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        newTmuxTarget = ""
    }

    private var appSection: some View {
        Section {
            Toggle("Launch at login", isOn: launchAtLogin)
            loginItemNote
        } header: {
            SettingsSectionHeader(title: "Startup", symbol: "power")
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
                update { config in _ = loginItem.set(on, config: &config) }
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
                Text("Waiting for approval in System Settings > General > Login Items. Turn the switch off to withdraw it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { loginItem.openLoginItems() }
                    .handCursor()
            }
        } else if manager.config.launchAtLogin, !loginItem.isRegistered {
            Text("Login item: macOS reports it \(loginItem.status.description). Turn the switch on to register it again.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Bundle id lists

    private func bundleList(
        title: String,
        items: [String],
        newValue: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        SettingsAppList(title: title, items: items, newValue: newValue, add: add, remove: remove)
    }

}
