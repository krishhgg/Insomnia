import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Edit Apps: one list with one rule per app (`Config.setRule`), one way to
/// add an app, then what happens to every app not on the list.
struct AppsSheet: View {
    let manager: SessionManager

    @Environment(\.dismiss) private var dismiss
    @State private var choosingApp = false
    /// Names of the apps the automatic lid-close scope would freeze right
    /// now (the freeze list excluded).
    @State private var wouldFreeze: [String] = []

    var body: some View {
        Form {
            Section {
                ForEach(installedApps, id: \.self) { row(for: $0) }
                HStack {
                    Spacer()
                    addMenu
                }
            } header: {
                Text("Apps")
            } footer: {
                Text(
                    "Apps that keep running are never frozen or slowed down during a session. "
                        + "Listed apps this Mac doesn't have are left out.")
            }
            Section {
                Picker("All other apps", selection: manager.binding(\.freezeAllApps)) {
                    Text("Keep running").tag(false)
                    Text("Freeze when lid closes").tag(true)
                }
                if manager.config.freezeAllApps {
                    Text(otherAppsNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: manager.binding(\.dockerRule)) {
                    Text("Freeze Docker Desktop when it's idle")
                    Text(
                        "Only when no containers are running. A container that starts at "
                            + "that moment is frozen too.")
                }
                Toggle(isOn: manager.binding(\.disableAppNapForAgents)) {
                    Text("Turn off App Nap for apps that keep running")
                    Text("Keeps them at full speed in the background during a session.")
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(isPresented: $choosingApp, allowedContentTypes: [.application]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let id = RunningApps.bundleID(ofAppAt: url) { add(id) }
        }
        // The preview depends on the toggle, both lists and what is running.
        .onAppear(perform: refreshWouldFreeze)
        .onChange(of: manager.config) { refreshWouldFreeze() }
        .onReceive(workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            refreshWouldFreeze()
        }
        .onReceive(workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            refreshWouldFreeze()
        }
    }

    private var workspace: NotificationCenter { NSWorkspace.shared.notificationCenter }

    /// Listed apps this Mac has, by name.
    private var installedApps: [String] {
        manager.config.listedApps.filter(RunningApps.isInstalled).sorted(by: RunningApps.byName)
    }

    private func row(for id: String) -> some View {
        LabeledContent {
            HStack {
                Picker("When the lid closes", selection: rule(for: id)) {
                    Text("Keep running").tag(AppRule.keepRunning)
                    Text("Freeze when lid closes").tag(AppRule.freeze)
                }
                .labelsHidden()
                .fixedSize()
                // Apple apps and Docker Desktop never freeze from the list
                // (`FreezePlanner.isDenied`).
                .disabled(!freezable(id))
                Button("Remove", systemImage: "minus.circle.fill") {
                    manager.updateConfig { $0.setRule(nil, for: id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove")
            }
        } label: {
            Label {
                Text(RunningApps.displayName(for: id))
            } icon: {
                Image(nsImage: RunningApps.icon(for: id))
                    .resizable()
                    .scaledToFit()
            }
        }
    }

    /// Setting a row moves the app between the agent list and the freeze
    /// list.
    private func rule(for id: String) -> Binding<AppRule> {
        Binding(
            get: { manager.config.rule(for: id) ?? .keepRunning },
            set: { rule in manager.updateConfig { $0.setRule(rule, for: id) } })
    }

    private var addMenu: some View {
        Menu("Add App") {
            let apps = RunningApps.candidates(excluding: manager.config.listedApps)
            ForEach(apps, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }
            }
            if !apps.isEmpty { Divider() }
            Button("Choose\u{2026}") { choosingApp = true }
        }
        .fixedSize()
    }

    /// The menu leaves Apple apps out; Choose… adds them (`Config.addApp`).
    private func add(_ id: String) {
        manager.updateConfig { $0.addApp(id) }
    }

    /// Whether the freeze list can freeze `id` at all: not an Apple app,
    /// Insomnia or Docker Desktop, the denylist entries a row's rule does
    /// not decide.
    private func freezable(_ id: String) -> Bool {
        var config = manager.config
        config.agentList = []
        return !FreezePlanner.isDenied(id, config: config)
    }

    private var otherAppsNote: String {
        let now = wouldFreeze.isEmpty ? "nothing else" : wouldFreeze.joined(separator: ", ")
        return "Apple apps, Docker Desktop and apps agents rely on, such as editors, terminals, "
            + "browsers and meeting apps, keep running. Would freeze now: \(now)."
    }

    /// Same planner as the lid-close action, over the apps running now.
    private func refreshWouldFreeze() {
        let selfID = Bundle.main.bundleIdentifier ?? Paths.bundleIdentifier
        wouldFreeze = FreezePlanner.automaticCandidates(
            config: manager.config, apps: Freezer.runningApps(), selfBundleId: selfID
        ).map(\.name)
    }
}
