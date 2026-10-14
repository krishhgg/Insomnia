import AppKit
import SwiftUI

/// The settings window (spec 10): a sidebar of panes, as System Settings
/// has, with a search field that lists matching settings and jumps to
/// them. Every change is written straight through `manager.config` to
/// config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    /// Launch at login as macOS reports it, not as config.json remembers it.
    let loginItem: LoginItem

    /// The pane showing; the window reopens on the last one used.
    @AppStorage(SettingsPane.storageKey) private var paneName = SettingsPane.general.rawValue
    @State private var query = ""
    /// The search result picked in the sidebar, while the search is on.
    @State private var pickedResult: String?
    /// The setting the pane scrolls to and briefly highlights.
    @State private var reveal: Reveal?

    /// The password field, saving, what was saved, and the notice under
    /// the field.
    @State private var hotspot = HotspotPasswordField()
    /// The hotspot name as typed, until Save writes it to config.json;
    /// nil while the field shows the saved name.
    @State private var ssidDraft: String?
    /// Names of the apps the automatic lid-close scope would freeze right
    /// now (the freeze list excluded); refreshed on appear and toggle.
    @State private var wouldFreeze: [String] = []

    /// A jump to one setting. `token` makes picking the same result again
    /// scroll again.
    struct Reveal: Equatable {
        let id: String
        let token = UUID()
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // On the split view, not the sidebar: removed from the sidebar
        // column, it makes the column ignore its width and sit at 144 pt,
        // which cuts off "Battery & thermal".
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 680, minHeight: 460)
        .onAppear {
            loadPassword()
            refreshWouldFreeze()
            // The user may have approved or removed the item in System
            // Settings since the launch-time check (LoginItem also re-reads
            // whenever the app becomes active, for a window left open).
            loginItem.refresh()
        }
        // The failover may find the saved password unreadable while the
        // window is open, and an SSID edit makes the notice about another
        // hotspot's item: the notice follows both.
        .onChange(of: manager.services?.status.hotspotPasswordReport) { recheckPassword() }
        .onChange(of: HotspotSSID.normalized(manager.config.hotspotSSID)) { recheckPassword() }
        // The preview depends on the toggle, both lists and what is running:
        // recompute on any config change and whenever an app launches or quits.
        .onChange(of: manager.config) { refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshWouldFreeze() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshWouldFreeze() }
    }

    // MARK: Navigation

    private var pane: SettingsPane {
        SettingsPane(rawValue: paneName) ?? .general
    }

    private enum SidebarItem: Hashable {
        case pane(SettingsPane)
        case result(String)
    }

    /// Without a search the sidebar selects a pane; with one it selects a
    /// result, and picking a result opens its pane and scrolls to it.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if query.isEmpty { return .pane(pane) }
                return pickedResult.map(SidebarItem.result)
            },
            set: { item in
                switch item {
                case let .pane(p):
                    paneName = p.rawValue
                case let .result(id):
                    pickedResult = id
                    if let entry = SettingsSearch.entry(id) {
                        paneName = entry.pane.rawValue
                        reveal = Reveal(id: id)
                    }
                case nil:
                    break
                }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            if query.isEmpty {
                ForEach(SettingsPane.allCases) { p in
                    paneLabel(p).tag(SidebarItem.pane(p))
                }
            } else {
                let results = SettingsSearch.results(for: query)
                ForEach(SettingsPane.allCases) { p in
                    let found = results.filter { $0.pane == p }
                    if !found.isEmpty {
                        Section {
                            ForEach(found) { entry in
                                Text(entry.title)
                                    .lineLimit(2)
                                    .tag(SidebarItem.result(entry.id))
                            }
                        } header: {
                            paneLabel(p)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !query.isEmpty, SettingsSearch.results(for: query).isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .onChange(of: query) { pickedResult = nil }
        .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 280)
    }

    private func paneLabel(_ p: SettingsPane) -> some View {
        Label {
            Text(p.title)
        } icon: {
            PaneIcon(pane: p)
        }
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            Form {
                switch pane {
                case .general: generalPane
                case .sessions: sessionPane
                case .lidClose: lidSection
                case .agents: agentSection
                case .power: powerSection
                case .network: networkSection
                }
            }
            .formStyle(.grouped)
            // A fresh form per pane, so a pane opens at its top.
            .id(pane)
            .environment(\.revealedSetting, reveal?.id)
            .task(id: reveal) {
                guard let reveal else { return }
                // Let a pane just switched to lay out before scrolling it.
                // A newer pick cancels this task; a cancelled sleep throws,
                // and the task stops there rather than clear the new pick.
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                withAnimation(.smooth) { proxy.scrollTo(reveal.id, anchor: .center) }
                do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
                if self.reveal == reveal {
                    withAnimation(.smooth) { self.reveal = nil }
                }
            }
        }
        .navigationTitle(pane.title)
    }

    /// Marks rows as the setting `id` names: the search scrolls to them and
    /// tints them for a moment.
    private func anchored<Content: View>(_ id: String, @ViewBuilder _ content: () -> Content) -> some View {
        SettingAnchor(id: id, content: content())
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

    // MARK: Panes

    @ViewBuilder
    private var generalPane: some View {
        Section {
            anchored("launchAtLogin") {
                Toggle("Launch at login", isOn: launchAtLogin)
                loginItemNote
            }
        }
        Section {
            anchored("configFile") {
                LabeledContent("Config file") {
                    Text(manager.paths.configFile.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            if LidSimulationBuild.isCompiledIn {
                Text(LidSimulationBuild.marker)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Every change here is saved to the config file at once.")
        }
    }

    @ViewBuilder
    private var sessionPane: some View {
        Section {
            anchored("presets") {
                EditableList(
                    manager.config.presets,
                    searchPrompt: "Search presets",
                    addHelp: "Add a preset",
                    emptyText: "No presets",
                    fields: { [chipLabel(for: $0)] }
                ) { p in
                    HStack {
                        Text(chipLabel(for: p))
                            .monospacedDigit()
                        Spacer()
                        if p == manager.config.defaultPreset {
                            Text("default").font(.caption).foregroundStyle(.secondary)
                        }
                        removeButton {
                            update { $0.presets.removeAll { $0 == p } }
                        }
                    }
                } adder: { done in
                    TextEntryAdder(
                        title: "Add a preset",
                        placeholder: "30m, 2h, 1h30m, 3d",
                        note: "Up to \(chipLabel(for: manager.config.maxDuration)).",
                        canAdd: { DurationParser.seconds(from: $0) != nil },
                        add: addPreset,
                        done: done
                    )
                }
            }
        } header: {
            Text("Presets")
        } footer: {
            Text("Presets are the time chips in the menu bar popover.")
        }
        Section {
            anchored("defaultPreset") {
                Picker("Default preset", selection: bind(\.defaultPreset)) {
                    ForEach(manager.config.presets, id: \.self) { p in
                        Text(chipLabel(for: p)).tag(p)
                    }
                    if !manager.config.presets.contains(manager.config.defaultPreset) {
                        Text(chipLabel(for: manager.config.defaultPreset)).tag(manager.config.defaultPreset)
                    }
                }
            }
            anchored("maxSession") {
                LabeledContent("Maximum session") {
                    Text(chipLabel(for: manager.config.maxDuration)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Adds a preset typed in the + popover, or says why it cannot.
    private func addPreset(_ text: String) -> String? {
        guard let s = DurationParser.seconds(from: text) else { return "Type a duration such as 30m, 2h or 1h30m." }
        guard s <= manager.config.maxDuration else {
            return "Presets cannot exceed \(chipLabel(for: manager.config.maxDuration))."
        }
        update {
            if !$0.presets.contains(s) {
                $0.presets.append(s)
                $0.presets.sort()
            }
        }
        return nil
    }

    /// Under the mute toggle and in the README. Apple Platform Security,
    /// "Hardware microphone disconnect".
    static let microphoneNote = "On Mac laptops with Apple silicon or a T2 chip, closing the lid disconnects the built-in microphone in hardware. Recording a meeting with the lid closed needs AirPods or an external mic."

    @ViewBuilder
    private var lidSection: some View {
        // The one-time lid-close update, for a user who has
        // notifications turned off. Stays until dismissed.
        if let notice = manager.config.lidCloseDefaultsNotice {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text(notice.settingsLine)
                    } icon: {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    }
                    .font(.callout)
                    Spacer()
                    Button("Dismiss") { manager.dismissLidCloseNotice() }
                }
            }
        }
        Section {
            anchored("darken") {
                Toggle(isOn: bind(\.darkenDisplayOnLidClose)) {
                    TitleWithInfo("Turn off the display and keyboard backlight", info: "darken")
                }
                ForEach(manager.darkenRefusals, id: \.self) { reason in
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Display")
        }
        Section {
            anchored("freezeList") {
                appList(
                    manager.config.freezeList,
                    add: { id in update { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                    remove: { id in update { $0.freezeList.removeAll { $0 == id } } }
                )
            }
            anchored("freezeAll") {
                Toggle("Freeze every other app while the lid is closed", isOn: bind(\.freezeAllApps))
                Text(wouldFreezeText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            anchored("docker") {
                Toggle(isOn: bind(\.dockerRule)) {
                    TitleWithInfo("Pause Docker Desktop when no containers are running", info: "docker")
                }
            }
        } header: {
            TitleWithInfo("Freeze while the lid is closed", info: "freezeList")
        }
        Section("Audio") {
            anchored("mute") {
                Toggle("Mute audio on lid close", isOn: bind(\.muteOnLidClose))
                Text(Self.microphoneNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        Section("Power") {
            anchored("lowPowerOnLidClose") {
                Toggle("Low Power Mode while the lid is closed", isOn: bind(\.lowPowerOnLidClose))
                    // A floor input: apply it now if the lid is already closed.
                    .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
            }
        }
    }

    @ViewBuilder
    private var agentSection: some View {
        Section {
            anchored("agentList") {
                appList(
                    manager.config.agentList,
                    add: { id in update { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                    remove: { id in update { $0.agentList.removeAll { $0 == id } } }
                )
            }
        } header: {
            TitleWithInfo("Never throttle or freeze", info: "agentList")
        }
        Section {
            anchored("appNap") {
                Toggle(isOn: bind(\.disableAppNapForAgents)) {
                    TitleWithInfo("Turn App Nap off for these apps during a session", info: "appNap")
                }
            }
        }
    }

    private var wouldFreezeText: String {
        guard manager.config.freezeAllApps else { return "Would freeze now: the freeze list only" }
        return wouldFreeze.isEmpty ? "Would freeze now: nothing else" : "Would freeze now: \(wouldFreeze.joined(separator: ", "))"
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        let selfId = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfId).map(\.name)
    }

    @ViewBuilder
    private var powerSection: some View {
        Section {
            anchored("lowPowerFloor") {
                LabeledContent("Low Power Mode below") {
                    NumberBox(value: lowPowerFloor, range: 0...100, unit: "%", label: "Low Power Mode below")
                }
            }
            anchored("endFloor") {
                LabeledContent("End session below") {
                    NumberBox(value: endFloor, range: 0...Config.maxEndFloor, unit: "%", label: "End session below")
                }
            }
        } header: {
            TitleWithInfo("Battery", info: "endFloor")
        } footer: {
            Text("Set End session below to 0% to turn it off.")
        }
        Section("Thermal") {
            anchored("thermal") {
                Toggle(isOn: bind(\.thermalRules)) {
                    Text("Thermal rules")
                    Text("Low Power Mode when the Mac is hot; the session ends when it is critical.")
                }
            }
        }
    }

    private var hotspotStatus: HotspotSetupStatus {
        .of(
            ssid: manager.config.hotspotSSID,
            passwordEntered: hotspot.hasSavedPassword(ssid: manager.config.hotspotSSID),
            passwordNotice: hotspot.notice,
            locationAuthorized: locationPermission.isAuthorized
        )
    }

    private var hotspotStatusRow: some View {
        let status = hotspotStatus
        let (symbol, tint): (String, Color) = switch status.level {
        case .off: ("circle.dashed", .secondary)
        case .incomplete: ("exclamationmark.circle.fill", .orange)
        case .ready: ("checkmark.circle.fill", .green)
        }
        return Label {
            Text(status.text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Section {
            hotspotStatusRow
            // A grouped form right-aligns the text of a field that carries
            // its own label, whatever its alignment says. With the label
            // in LabeledContent and hidden on the field, the alignment
            // holds and typed text starts at the left.
            anchored("hotspot") {
                LabeledContent("Hotspot name") {
                    TextField("Hotspot name", text: ssidField, prompt: Text("My iPhone"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit(saveHotspot)
                }
                Text("Use the name exactly as it appears in the Wi-Fi menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            anchored("hotspotPassword") {
                LabeledContent("Hotspot password") {
                    SecureField("Hotspot password", text: Binding(get: { hotspot.password }, set: { hotspot.edit($0) }), prompt: Text("Password"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .onSubmit(saveHotspot)
                }
                if let notice = hotspot.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            TitleWithInfo("Hotspot failover", info: "hotspotPassword")
        } footer: {
            HStack {
                Spacer()
                Button(hotspot.saving ? "Saving\u{2026}" : "Save", action: saveHotspot)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hotspotChanged || hotspot.saving)
            }
        }
        Section {
            anchored("location") {
                // macOS has no when-in-use grant for Mac apps: the grant is
                // recorded as Location Services access for Insomnia, as the
                // ⓘ text says.
                HStack {
                    Text("Location: \(locationPermission.statusDescription)")
                        .foregroundStyle(.secondary)
                    InfoButton(for: "location")
                    Spacer()
                    if locationPermission.isDenied {
                        Button("Open Location Services") {
                            locationPermission.openLocationServicesSettings()
                        }
                    } else if locationPermission.authorizationStatus == .notDetermined,
                              !HotspotSSID.normalized(manager.config.hotspotSSID).isEmpty {
                        Button("Allow Location\u{2026}") { locationPermission.requestWhenInUse() }
                    }
                }
            }
        } footer: {
            Text("Failover needs it to see Wi-Fi network names.")
        }
        Section {
            anchored("nudge") {
                LabeledContent {
                    NumberBox(value: nudgeSeconds, range: 10...900, unit: "seconds offline", label: "Seconds offline before the nudge")
                } label: {
                    TitleWithInfo("Type \u{201C}continue\u{201D} into tmux after", info: "nudge")
                }
                Text("Mark a dedicated pane with this command, not one you type in:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TmuxNudge.markCommand())
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            anchored("pressEnter") {
                Toggle(isOn: bind(\.tmuxNudgePressesEnter)) {
                    Text("Press Enter after continue")
                    Text("Enter also submits anything already typed in that pane.")
                }
            }
            anchored("tmuxTargets") {
                EditableList(
                    manager.config.tmuxTargets,
                    searchPrompt: "Search tmux targets",
                    addHelp: "Add a tmux target",
                    emptyText: "No tmux targets",
                    fields: { [$0] }
                ) { t in
                    HStack {
                        Text(t).font(.system(.body, design: .monospaced))
                        Spacer()
                        removeButton {
                            update { $0.tmuxTargets.removeAll { $0 == t } }
                        }
                    }
                } adder: { done in
                    TextEntryAdder(
                        title: "Add a tmux target",
                        placeholder: "session:window.pane",
                        monospaced: true,
                        note: "Only a pane marked with the command above is nudged.",
                        canAdd: { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                        add: addTmuxTarget,
                        done: done
                    )
                }
            }
        } header: {
            Text("tmux nudge")
        }
    }

    /// The name field: the draft while there is one, else the saved name.
    private var ssidField: Binding<String> {
        Binding(
            get: { ssidDraft ?? manager.config.hotspotSSID },
            set: { ssidDraft = $0 }
        )
    }

    /// Whether Save has anything to do: a name typed that differs from
    /// the saved one, or a password field that differs from what the
    /// keychain holds for the saved name.
    private var hotspotChanged: Bool {
        if let ssidDraft, ssidDraft != manager.config.hotspotSSID { return true }
        return !hotspot.isSaved(ssid: manager.config.hotspotSSID)
    }

    /// Saves the section: the name to config.json first, so the keychain
    /// store files the password under it, then the password, or a clear
    /// for an empty field, whenever the keychain does not already hold it
    /// for that name. A new name with the same password moves the
    /// password to it.
    private func saveHotspot() {
        guard let run = Self.runHotspotSave(
            ssidDraft: ssidDraft,
            field: (get: { hotspot }, set: { hotspot = $0 }),
            configuredSSID: { manager.config.hotspotSSID },
            writeSSID: { name in update { $0.hotspotSSID = name } },
            requestLocation: { locationPermission.requestWhenInUse() },
            secrets: secrets,
            services: manager.services
        ) else { return }
        ssidDraft = nil
        if let passwordSave = run.passwordSave {
            Task {
                if let recheck = await passwordSave.value { recheckPassword(recheck) }
            }
        }
    }

    /// A Save press under way: the password save, when it stores one,
    /// answering with the recheck to run for the hotspot configured then.
    struct HotspotSaveRun {
        let passwordSave: Task<HotspotPasswordField.Read?, Never>?
    }

    /// The whole Save press, which the view runs and tests run the same
    /// way: the name to config.json (`writeSSID`) first, then the password
    /// to the keychain under it, or a clear for an empty field. While the
    /// keychain answers, the field says it is saving ("Saving..." on the
    /// button; one save at a time). The answer goes to the field and then to
    /// the failover's report, so a recheck reads the report as the save
    /// left it. nil when there is nothing to save.
    static func runHotspotSave(
        ssidDraft: String?,
        field: (get: @MainActor () -> HotspotPasswordField, set: @MainActor (HotspotPasswordField) -> Void),
        configuredSSID: @escaping @MainActor () -> String,
        writeSSID: (String) -> Void,
        requestLocation: () -> Void,
        secrets: any HotspotSecretStore,
        services: AppServices?
    ) -> HotspotSaveRun? {
        guard let save = hotspotSave(ssidDraft: ssidDraft, savedSSID: configuredSSID(), field: field.get()) else { return nil }
        if let name = save.name { writeSSID(name) }
        guard save.storesPassword else { return HotspotSaveRun(passwordSave: nil) }
        var started = field.get()
        guard started.startSave() else { return HotspotSaveRun(passwordSave: nil) }
        field.set(started)
        if !HotspotSSID.normalized(configuredSSID()).isEmpty {
            requestLocation()
        }
        let password = started.password
        let set = field.set, get = field.get
        let task = Task { @MainActor in
            let outcome = await storePassword(password, in: secrets)
            var answered = get()
            let recheck = answered.finishSave(outcome, ssid: configuredSSID())
            set(answered)
            passwordStored(outcome, configuredSSID: configuredSSID(), services: services)
            return recheck
        }
        return HotspotSaveRun(passwordSave: task)
    }

    /// What one press of the hotspot section's Save writes.
    struct HotspotSave: Equatable {
        /// The name to write to config.json; nil when the field holds the
        /// saved one.
        let name: String?
        /// Whether the password field goes to the keychain (a clear when it
        /// is empty), filed under the name Save leaves configured.
        let storesPassword: Bool
    }

    /// The Save press apart from the view: the name first, so the keychain
    /// store files the password under it, then the password whenever the
    /// keychain does not already hold the field's text for that name. A
    /// new name with the saved password therefore stores it again, which
    /// moves it to the new name. nil when there is nothing to write, or
    /// while a save waits on the keychain.
    static func hotspotSave(ssidDraft: String?, savedSSID: String, field: HotspotPasswordField) -> HotspotSave? {
        guard !field.saving else { return nil }
        let name = ssidDraft.flatMap { $0 == savedSSID ? nil : $0 }
        let storesPassword = !field.isSaved(ssid: name ?? savedSSID)
        guard name != nil || storesPassword else { return nil }
        return HotspotSave(name: name, storesPassword: storesPassword)
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

    private func addTmuxTarget(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return "Type a target such as main:0.1." }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        return nil
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
            }
        } else if manager.config.launchAtLogin, !loginItem.isRegistered {
            Text("Login item: macOS reports it \(loginItem.status.description). Turn the switch on to register it again.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: App lists

    /// A list of bundle ids, each shown with its app's icon and name. The
    /// list's title is its section's header.
    private func appList(
        _ items: [String],
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        EditableList(
            items,
            searchPrompt: "Search apps",
            addHelp: "Add an app",
            emptyText: "No apps",
            fields: { [InstalledApps.displayName(for: $0), $0] }
        ) { id in
            HStack {
                AppLabel(bundleID: id)
                Spacer()
                removeButton { remove(id) }
            }
        } adder: { done in
            AppPicker(added: items, add: add, done: done)
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}
