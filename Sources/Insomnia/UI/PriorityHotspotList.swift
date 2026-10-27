import SwiftUI

/// The priority list's state apart from the view: the add row, the one
/// save at a time, and what the last keychain check found for each
/// hotspot, so the rules can be tested without a window.
///
/// A listed hotspot's SSID never changes: to rename one, remove it and add
/// the new name. So no answer from the keychain is ever about a name that
/// was edited while it waited, which is what the single hotspot field has
/// to guard against (`HotspotPasswordField`).
struct PriorityHotspotEditor: Equatable {
    /// The add row's name field.
    var ssid = ""
    /// The add row's password field.
    var password = ""
    /// A save is waiting on the keychain, which may be showing a dialog.
    private(set) var saving = false
    /// Why the last save or removal failed; under the add row.
    private(set) var notice: String?
    /// What the newest check found wrong with each listed hotspot's saved
    /// password. A hotspot it read fine is absent.
    private(set) var problems: [String: HotspotPasswordProblem] = [:]
    /// Bumped by every check, so only the newest one's answer is used.
    private var check = 0

    /// "Update password" when the name is already on the list, whichever
    /// apostrophe: a save then replaces that hotspot's password and leaves
    /// the list alone.
    func buttonTitle(listed: [String]) -> String {
        if saving { return "Saving\u{2026}" }
        return HotspotSSID.any(of: listed, matches: ssid) ? "Update password" : "Add"
    }

    /// A name is enough to add a hotspot: an iPhone or iPad hands its
    /// password over when woken. A listed one needs a password to update.
    func canSave(listed: [String]) -> Bool {
        let name = HotspotSSID.normalized(ssid)
        guard !saving, !name.isEmpty else { return false }
        return !password.isEmpty || !HotspotSSID.any(of: listed, matches: name)
    }

    /// A save begins: returns the name and password it stores, read now,
    /// or nil while another save waits or there is nothing to save. An
    /// empty password adds the name alone. A name already listed, typed
    /// with the other apostrophe, is saved under the list's spelling: the
    /// join reads the password under that one.
    mutating func startSave(listed: [String]) -> (ssid: String, password: String)? {
        guard canSave(listed: listed) else { return nil }
        saving = true
        let name = HotspotSSID.normalized(ssid)
        return (listed.first { HotspotSSID.matches($0, name) } ?? name, password)
    }

    /// The save of `password` for `ssid` answered; `error` is why it
    /// failed. A stored password ends that hotspot's problem, and the
    /// fields empty if they still hold what was saved: text typed while
    /// the save waited is the user's next entry and stays.
    mutating func finishSave(ssid: String, password: String, error: String?) {
        saving = false
        if let error {
            notice = "Could not save the password for \"\(ssid)\": \(error)"
            return
        }
        notice = nil
        problems[ssid] = nil
        if HotspotSSID.matches(self.ssid, ssid), self.password == password {
            self.ssid = ""
            self.password = ""
        }
    }

    mutating func removalFailed(ssid: String, error: String) {
        notice = "\"\(ssid)\" is off the list, but its saved password could not be deleted: \(error)"
    }

    /// A check of every listed hotspot's password begins; pass what this
    /// returns to `finishCheck`.
    mutating func startCheck() -> Int {
        check += 1
        return check
    }

    /// A check answered. A newer check, begun after a save or a change to
    /// the list, has the newer answer, so an older one is dropped.
    mutating func finishCheck(_ token: Int, problems: [String: HotspotPasswordProblem]) {
        guard token == check else { return }
        self.problems = problems
    }

    /// The line under a listed hotspot. A problem the failover reported
    /// about it shows first: it is what the last join found.
    func notice(for ssid: String, reported: HotspotPasswordReport?) -> String? {
        if let problem = reported?.problem(for: ssid) { return problem.listNotice }
        return problems[ssid]?.listNotice
    }

    /// One prompt-free read of each hotspot's password. An unreadable one
    /// is a problem; a missing one is not, since a woken device hands its
    /// password over.
    @MainActor
    static func problems(of ssids: [String], peek: @MainActor (String) async throws -> String?) async -> [String: HotspotPasswordProblem] {
        var found: [String: HotspotPasswordProblem] = [:]
        for ssid in ssids {
            do {
                _ = try await peek(ssid)
            } catch {
                found[ssid] = HotspotPasswordProblem(error)
            }
        }
        return found
    }
}

/// What the Nearby popover lists, apart from the view. It never waits
/// on a scan to show something: macOS's own last scan and sharingd's
/// cached devices list at once, and the fresh scan adds to them.
struct NearbyHotspotPicks: Equatable {
    /// The phones and tablets sharingd lists, as of its latest update.
    private(set) var devices: [NearbyHotspotDevice] = []
    /// Network names from the cache and the fresh scan, sorted.
    private(set) var names: [String] = []
    /// The fresh Wi-Fi scan is running.
    private(set) var scanning = false
    private(set) var failure: String?

    /// The names to list under "Wi-Fi networks": a device already listed
    /// is not repeated.
    var networks: [String] {
        names.filter { name in !devices.contains { $0.name == name } }
    }

    /// A scan begins; false while one is running, whose answer still comes.
    mutating func startScan() -> Bool {
        guard !scanning else { return false }
        scanning = true
        failure = nil
        return true
    }

    /// macOS's own last scan: it replaces what an earlier opening listed.
    mutating func cached(_ found: [String]) {
        names = Self.sorted(found)
    }

    /// The fresh scan adds to the cached names rather than replace them,
    /// so a name the user may be about to pick does not vanish.
    mutating func scanned(_ found: [String]) {
        names = Self.sorted(names + found)
        scanning = false
    }

    mutating func scanFailed(_ error: String) {
        failure = "The Wi-Fi scan failed: \(error)"
        scanning = false
    }

    mutating func devicesFound(_ list: [NearbyHotspotDevice]) {
        devices = list
    }

    /// The line under the lists: why the scan failed, or why nothing is
    /// listed once it is done.
    func notice(locationAllowed: Bool) -> String? {
        if let failure { return failure }
        guard !scanning, names.isEmpty, devices.isEmpty else { return nil }
        return locationAllowed
            ? "Nothing found. Turn on Personal Hotspot on the device and scan again."
            : "macOS hides network names until Location is allowed for Insomnia."
    }

    private static func sorted(_ names: [String]) -> [String] {
        Set(names).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// The rows Settings shows with the priority list on: the hotspots in
/// order with their password state, the add row with a scan for nearby
/// names, and the switch-up and hand-back toggles. Every change is written straight
/// through `update` to config.json.
struct PriorityHotspotList: View {
    let manager: SessionManager
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    let scanner: any HotspotScanning
    let devices: any NearbyHotspotBrowsing
    let update: @MainActor ((inout Config) -> Void) -> Void

    @State private var editor = PriorityHotspotEditor()
    @State private var picks = NearbyHotspotPicks()
    @State private var browsing: Task<Void, Never>?
    @State private var showingNearby = false

    private var list: [String] { manager.config.priorityHotspotList }
    private var reported: HotspotPasswordReport? { manager.services?.status.hotspotPasswordReport }

    var body: some View {
        Group {
            if list.isEmpty {
                Text("No hotspots yet. Add the first one below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.element) { index, ssid in
                row(ssid, index: index)
            }
            HStack {
                TextField("Hotspot name (SSID)", text: $editor.ssid)
                    .textFieldStyle(.roundedBorder)
                Button("Nearby\u{2026}", action: scanNearby)
                    .popover(isPresented: $showingNearby, arrowEdge: .bottom) { nearbyList }
                    .onChange(of: showingNearby) {
                        if !showingNearby { browsing?.cancel() }
                    }
            }
            HStack {
                SecureField("Password (optional)", text: $editor.password)
                    .onSubmit(save)
                Button(editor.buttonTitle(listed: list), action: save)
                    .disabled(!editor.canSave(listed: list))
            }
            Text("An iPhone or iPad needs no password: Insomnia wakes it over Bluetooth and it hands its password over. Enter one for other hotspots, or as a fallback for when Bluetooth can't reach the device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notice = editor.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            Toggle("Move to a higher hotspot when it is back in range", isOn: switchUp)
                .onChange(of: manager.config.hotspotSwitchUp) { manager.services?.hotspotSettingsChanged() }
            Text("Checked every 30 s during a session while the Mac is on a lower hotspot on this list. Insomnia moves only after two scans in a row find the higher one with a good signal, and at most once every 5 minutes. Each move takes the Mac offline for a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Return to a saved Wi-Fi network when one is back in range", isOn: returnToWiFi)
                .onChange(of: manager.config.hotspotReturnToWiFi) { manager.services?.hotspotSettingsChanged() }
            Text("Any network macOS already knows, other than the hotspots above. Checked every 30 s while the Mac is on a hotspot Insomnia joined; after two scans in a row find one with a good signal, Insomnia leaves the hotspot and macOS rejoins the network (about 15 s offline). At most once every 5 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { checkPasswords() }
        // A move up or down changes no password.
        .onChange(of: Set(list)) { checkPasswords() }
    }

    private var switchUp: Binding<Bool> {
        Binding(
            get: { manager.config.hotspotSwitchUp },
            set: { on in update { $0.hotspotSwitchUp = on } }
        )
    }

    private var returnToWiFi: Binding<Bool> {
        Binding(
            get: { manager.config.hotspotReturnToWiFi },
            set: { on in update { $0.hotspotReturnToWiFi = on } }
        )
    }

    private func row(_ ssid: String, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(index + 1).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ssid)
                if let notice = editor.notice(for: ssid, reported: reported) {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                update { $0.movePriorityHotspot(ssid, by: -1) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help("Move up")
            Button {
                update { $0.movePriorityHotspot(ssid, by: 1) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == list.count - 1)
            .help("Move down")
            Button {
                remove(ssid)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !picks.devices.isEmpty {
                Text("Phones and tablets").font(.headline)
                ForEach(picks.devices, id: \.name) { device in
                    Button {
                        pick(device.name)
                    } label: {
                        HStack {
                            Text(device.name)
                            Spacer()
                            if let battery = device.battery {
                                Text("\(battery)%").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !picks.networks.isEmpty {
                Text("Wi-Fi networks").font(.headline)
                ForEach(picks.networks, id: \.self) { name in
                    Button(name) { pick(name) }
                        .buttonStyle(.borderless)
                }
            }
            if picks.scanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for more\u{2026}").foregroundStyle(.secondary)
                }
            }
            if let notice = picks.notice(locationAllowed: locationPermission.isAuthorized) {
                Text(notice)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Phones and tablets signed in to your Apple Account, or in your family, show up over Bluetooth even with their hotspot off; their hotspot uses the device name. Other hotspots show up while they broadcast.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 320)
    }

    private func pick(_ name: String) {
        editor.ssid = name
        showingNearby = false
    }

    /// Lists names to pick from, so a device name with the curly
    /// apostrophe iOS puts in it does not have to be typed exactly: the
    /// phones and tablets macOS sees over Bluetooth, and the Wi-Fi
    /// networks it knows. What macOS already knows shows at once; the
    /// browse goes on while the popover is open, up to 10 s, and the fresh
    /// scan adds what it finds when it is done.
    private func scanNearby() {
        showingNearby = true
        browsing?.cancel()
        browsing = Task { await devices.browse(for: 10) { picks.devicesFound($0) } }
        guard picks.startScan() else { return }
        locationPermission.requestWhenInUse()
        Task {
            picks.cached(await scanner.cachedNearbySSIDs())
            do {
                picks.scanned(try await scanner.nearbySSIDs())
            } catch {
                picks.scanFailed(error.localizedDescription)
            }
        }
    }

    /// Stores the password, if one was entered, and only then adds the
    /// hotspot, so the list never names a hotspot whose save failed.
    private func save() {
        guard let entry = editor.startSave(listed: list) else { return }
        locationPermission.requestWhenInUse()
        Task {
            do {
                if !entry.password.isEmpty { try await secrets.save(entry.password, for: entry.ssid) }
            } catch {
                Log.error("could not save hotspot password: \(error.localizedDescription)")
                editor.finishSave(ssid: entry.ssid, password: entry.password, error: error.localizedDescription)
                return
            }
            editor.finishSave(ssid: entry.ssid, password: entry.password, error: nil)
            update { $0.addPriorityHotspot(entry.ssid) }
            passwordChanged(HotspotPasswordChange(ssid: entry.ssid))
            checkPasswords()
        }
    }

    /// Off the list first, so the failover stops trying it, then its
    /// password, unless the single hotspot setting still names it.
    private func remove(_ ssid: String) {
        update { $0.removePriorityHotspot(ssid) }
        guard !manager.config.namesHotspot(ssid) else { return }
        Task {
            do {
                try await secrets.delete(ssid: ssid)
                passwordChanged(HotspotPasswordChange(ssid: ssid))
            } catch {
                Log.error("could not delete hotspot password: \(error.localizedDescription)")
                editor.removalFailed(ssid: ssid, error: error.localizedDescription)
            }
        }
    }

    private func passwordChanged(_ change: HotspotPasswordChange) {
        manager.services?.hotspotPasswordChanged(change, configuredSSIDs: manager.config.hotspotsToJoin)
    }

    private func checkPasswords() {
        let token = editor.startCheck()
        let ssids = list
        let secrets = self.secrets
        Task {
            let problems = await PriorityHotspotEditor.problems(of: ssids) { try await secrets.peek(ssid: $0) }
            editor.finishCheck(token, problems: problems)
        }
    }
}
