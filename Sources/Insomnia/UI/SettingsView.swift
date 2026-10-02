import AppKit
import ServiceManagement
import SwiftUI

/// The settings window (spec 10). Every change is written straight through
/// `manager.config` to config.json.
struct SettingsView: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission

    @State private var newPreset = ""
    @State private var presetError: String?
    @State private var newFreezeBundle = ""
    @State private var newAgentBundle = ""
    @State private var newTmuxTarget = ""
    @State private var hotspotPassword = ""
    @State private var hotspotSaved = false
    /// A save or clear is waiting on the keychain, which may be showing a
    /// dialog.
    @State private var hotspotSaving = false
    /// Bumped by every load, recheck and save, so a keychain answer that
    /// arrives after a newer request was made does not overwrite it.
    @State private var hotspotRequest = 0
    /// Why the saved password could not be loaded or saved; under the field.
    @State private var hotspotNotice: String?
    @State private var loginItemError: String?
    /// Names of the apps the automatic lid-close scope would freeze right
    /// now (the freeze list excluded); refreshed on appear and toggle.
    @State private var wouldFreeze: [String] = []

    var body: some View {
        Form {
            sessionSection
            lidSection
            agentSection
            powerSection
            networkSection
            appSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560, idealHeight: 720)
        .onAppear {
            loadPassword()
            refreshWouldFreeze()
        }
        // The failover may find the saved password unreadable while the
        // window is open; the notice follows what it reports.
        .onChange(of: manager.services?.status.hotspotPasswordProblem) { _, problem in
            hotspotRequest += 1
            let request = hotspotRequest
            Task {
                let notice = await Self.hotspotNotice(reported: problem, reread: secrets.peek)
                if request == hotspotRequest { hotspotNotice = notice }
            }
        }
        // The preview depends on the toggle, both lists and what is running:
        // recompute on any config change and whenever an app launches or quits.
        .onChange(of: manager.config) { refreshWouldFreeze() }
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

    // MARK: Sections

    private var sessionSection: some View {
        Section("Session") {
            ForEach(manager.config.presets, id: \.self) { p in
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
            }
            HStack {
                TextField("Add preset (30m, 2h, 1h30m, 3d)", text: $newPreset)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPreset)
                Button("Add", action: addPreset)
                    .disabled(DurationParser.seconds(from: newPreset) == nil)
            }
            if let presetError {
                Text(presetError).font(.caption).foregroundStyle(.red)
            }
            Picker("Default preset", selection: bind(\.defaultPreset)) {
                ForEach(manager.config.presets, id: \.self) { p in
                    Text(chipLabel(for: p)).tag(p)
                }
                if !manager.config.presets.contains(manager.config.defaultPreset) {
                    Text(chipLabel(for: manager.config.defaultPreset)).tag(manager.config.defaultPreset)
                }
            }
            LabeledContent("Maximum session") {
                Text(chipLabel(for: manager.config.maxDuration)).foregroundStyle(.secondary)
            }
        }
    }

    private func addPreset() {
        guard let s = DurationParser.seconds(from: newPreset) else { return }
        guard s <= manager.config.maxDuration else {
            presetError = "Presets cannot exceed \(chipLabel(for: manager.config.maxDuration))."
            return
        }
        presetError = nil
        update {
            if !$0.presets.contains(s) {
                $0.presets.append(s)
                $0.presets.sort()
            }
        }
        newPreset = ""
    }

    private var lidSection: some View {
        Section {
            Toggle("Turn off the display and keyboard backlight", isOn: bind(\.darkenDisplayOnLidClose))
            bundleList(
                title: "Freeze while the lid is closed",
                items: manager.config.freezeList,
                newValue: $newFreezeBundle,
                add: { id in update { if !$0.freezeList.contains(id) { $0.freezeList.append(id) } } },
                remove: { id in update { $0.freezeList.removeAll { $0 == id } } }
            )
            Toggle("Freeze every other app while the lid is closed", isOn: bind(\.freezeAllApps))
            Text(wouldFreezeText)
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Pause Docker Desktop when no containers are running", isOn: bind(\.dockerRule))
            Toggle("Mute audio on lid close", isOn: bind(\.muteOnLidClose))
            Toggle("Low Power Mode while the lid is closed", isOn: bind(\.lowPowerOnLidClose))
                // A floor input: apply it now if the lid is already closed.
                .onChange(of: manager.config.lowPowerOnLidClose) { manager.services?.reevaluateFloors() }
        } header: {
            Text("Lid-close actions")
        } footer: {
            Text("Every Dock app that is not an agent app, an Apple app, Docker Desktop or a built-in protected app (editors, AI apps, Tailscale, local model servers) is stopped with SIGSTOP and resumed when the lid opens. Apps on the list above are always frozen; agent apps never are. The display brightness and keyboard backlight are saved, set to zero and restored when the lid opens. If Insomnia is not running when you open the lid, press the brightness-up key.")
        }
    }

    private var agentSection: some View {
        Section {
            bundleList(
                title: "Never throttle or freeze",
                items: manager.config.agentList,
                newValue: $newAgentBundle,
                add: { id in update { if !$0.agentList.contains(id) { $0.agentList.append(id) } } },
                remove: { id in update { $0.agentList.removeAll { $0 == id } } }
            )
        } header: {
            Text("Agent apps")
        } footer: {
            Text("Agent apps are never frozen or throttled. Editors, AI apps, terminals, agent-driven browsers, Tailscale and local model servers are also protected from the automatic lid-close scope even when they are not listed here; adding one to the freeze list above overrides that.")
        }
    }

    private var wouldFreezeText: String {
        wouldFreeze.isEmpty ? "Would freeze now: nothing else" : "Would freeze now: \(wouldFreeze.joined(separator: ", "))"
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        let selfId = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfId).map(\.name)
    }

    private var powerSection: some View {
        Section("Battery and thermal") {
            Stepper(value: bind(\.lowPowerFloor), in: 0...100, step: 5) {
                LabeledContent("Low Power Mode below", value: "\(manager.config.lowPowerFloor)%")
            }
            Stepper(value: bind(\.endFloor), in: 0...100, step: 5) {
                LabeledContent("End session below", value: "\(manager.config.endFloor)%")
            }
            Toggle("Thermal rules (Low Power Mode when hot, end when critical)", isOn: bind(\.thermalRules))
        }
    }

    private var networkSection: some View {
        Section {
            TextField("Hotspot SSID", text: bind(\.hotspotSSID))
            HStack {
                SecureField("Hotspot password", text: $hotspotPassword)
                    .onSubmit(savePassword)
                Button(hotspotSaving ? "Saving\u{2026}" : hotspotSaved ? "Saved" : "Save", action: savePassword)
                    .disabled(hotspotPassword.isEmpty || hotspotSaving)
            }
            if let hotspotNotice {
                Text(hotspotNotice).font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Location: \(locationPermission.statusDescription)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if locationPermission.isDenied {
                        Button("Open Location Services") {
                            locationPermission.openLocationServicesSettings()
                        }
                    }
                }
                // macOS has no when-in-use grant for Mac apps: the grant is
                // recorded as Location Services access for Insomnia.
                Text("macOS records this grant as Location Services access for Insomnia. Insomnia uses it only to read Wi-Fi network names and never requests your location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper(value: nudgeSeconds, in: 10...900, step: 10) {
                LabeledContent("Nudge tmux after", value: "\(Int(manager.config.nudgeThreshold)) s offline")
            }
            ForEach(manager.config.tmuxTargets, id: \.self) { t in
                HStack {
                    Text(t).font(.system(.body, design: .monospaced))
                    Spacer()
                    removeButton {
                        update { $0.tmuxTargets.removeAll { $0 == t } }
                    }
                }
            }
            HStack {
                TextField("tmux target (session:window.pane)", text: $newTmuxTarget)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTmuxTarget)
                Button("Add", action: addTmuxTarget)
                    .disabled(newTmuxTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Network failover")
        } footer: {
            Text("The password is kept in the login keychain, readable without a prompt only by the build of Insomnia that saved it; after a reinstall, enter it again. Location permission lets macOS reveal Wi-Fi network names and find the configured hotspot.")
        }
    }

    private var nudgeSeconds: Binding<Int> {
        Binding(
            get: { Int(manager.config.nudgeThreshold) },
            set: { seconds in update { $0.nudgeThreshold = TimeInterval(seconds) } }
        )
    }

    /// Reads without a keychain prompt. An item this build may not read
    /// leaves the field empty and says why, so the user re-enters it;
    /// saving then replaces the item (see `KeychainStore`). The read can
    /// wait behind a save, so anything typed meanwhile is kept.
    private func loadPassword() {
        hotspotRequest += 1
        let request = hotspotRequest
        Task {
            let loaded = await Self.loadedPassword(secrets.load)
            guard request == hotspotRequest else { return }
            if hotspotPassword.isEmpty { hotspotPassword = loaded.password }
            hotspotNotice = loaded.notice
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

    /// The notice under the password field. A problem the failover reports
    /// shows as it is. A cleared report is not taken as "readable": it
    /// also clears when the session ends, so the keychain is read again,
    /// without a prompt, and the notice says what that read finds. The
    /// field is left as the user has it, and the reread is a peek: a load
    /// would make an SSID typed since then the account a save moves the
    /// password from, and the old SSID's item would stay behind.
    static func hotspotNotice(reported: HotspotPasswordProblem?, reread: () async throws -> String?) async -> String? {
        if let reported { return reported.settingsNotice }
        return await loadedPassword(reread).notice
    }

    /// Saves, or clears for an empty field. The button shows "Saving..."
    /// until the keychain answers; one save at a time.
    private func savePassword() {
        guard !hotspotSaving else { return }
        if !manager.config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            locationPermission.requestWhenInUse()
        }
        hotspotSaving = true
        hotspotRequest += 1
        let request = hotspotRequest
        let password = hotspotPassword
        Task {
            let failure = await Self.storePassword(password, in: secrets)
            hotspotSaving = false
            hotspotSaved = failure == nil
            if request == hotspotRequest { hotspotNotice = failure }
            if failure == nil { manager.services?.hotspotPasswordChanged() }
        }
    }

    /// Saves `password`, or clears the saved one when it is empty, and
    /// returns the notice for a failure. The store does the keychain work
    /// on `KeychainQueue`, so a save waiting on a keychain dialog waits
    /// there while the main actor (the battery floor, the deadline timer,
    /// End) carries on.
    static func storePassword(_ password: String, in secrets: any HotspotSecretStore) async -> String? {
        do {
            if password.isEmpty {
                try await secrets.delete()
            } else {
                try await secrets.save(password)
            }
            return nil
        } catch {
            Log.error("could not save hotspot password: \(error.localizedDescription)")
            return "Could not save the hotspot password: \(error.localizedDescription)"
        }
    }

    private func addTmuxTarget() {
        let t = newTmuxTarget.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        update { if !$0.tmuxTargets.contains(t) { $0.tmuxTargets.append(t) } }
        newTmuxTarget = ""
    }

    private var appSection: some View {
        Section("App") {
            Toggle("Launch at login", isOn: launchAtLogin)
            if let loginItemError {
                Text(loginItemError).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Config") {
                Text(manager.paths.configFile.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { manager.config.launchAtLogin },
            set: { on in
                do {
                    if on {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginItemError = nil
                    // Persist only what macOS actually applied.
                    update { $0.launchAtLogin = on }
                } catch {
                    loginItemError = "Login item: \(error.localizedDescription)"
                    Log.error("launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
                }
            }
        )
    }

    // MARK: Bundle id lists

    private func bundleList(
        title: String,
        items: [String],
        newValue: Binding<String>,
        add: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) -> some View {
        Group {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RunningApps.displayName(for: id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    removeButton { remove(id) }
                }
            }
            HStack {
                TextField("Bundle identifier", text: newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        add(v)
                        newValue.wrappedValue = ""
                    }
                Button("Add") {
                    let v = newValue.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard !v.isEmpty else { return }
                    add(v)
                    newValue.wrappedValue = ""
                }
                .disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Add running app…") {
                    let apps = RunningApps.candidates(excluding: items)
                    if apps.isEmpty {
                        Text("No other apps running")
                    }
                    ForEach(apps, id: \.bundleID) { app in
                        Button(app.name) { add(app.bundleID) }
                    }
                }
                .fixedSize()
            }
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

/// Running apps offered by "Add running app…": everything with a bundle id
/// that is not Apple's own.
@MainActor
enum RunningApps {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me,
                  app.activationPolicy != .prohibited,
                  !excluding.contains(id), !seen.contains(id) else { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle id, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
