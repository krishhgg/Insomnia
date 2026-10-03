import AppKit
import SwiftUI

/// Menu bar app. The status item is an `NSStatusItem` hosting SwiftUI, and
/// the settings window is an `NSWindow` this app opens itself (see
/// `SettingsWindow`), so there is no SwiftUI scene with any content in it.
/// `App` still requires one, hence the empty `Settings`.
@main
struct InsomniaApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: SessionManager
    let status: any StatusSource
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    let loginItem = LoginItem()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var terminating = false

    override init() {
        let manager = SessionManager.live()
        self.manager = manager
        secrets = KeychainHotspotSecretStore(keychain: KeychainStore()) {
            manager.config.hotspotSSID
        }
        if let services = manager.services {
            status = LiveStatusSource(services: services)
            locationPermission = services.locationPermission
        } else {
            Log.error("live SessionManager has no AppServices; using placeholder status")
            status = PlaceholderStatus()
            locationPermission = LocationPermission()
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched")
        if LidSimulationBuild.isCompiledIn {
            Log.info(LidSimulationBuild.marker)
        }
        // The login item is tied to the bundle's signature, which install.sh
        // renews on every run: register again if the flag is on, macOS no
        // longer reports the item and the install changed; follow the user
        // if they removed the item for the install macOS had on file.
        var config = manager.config
        if loginItem.healAtLaunch(config: &config) {
            manager.config = config
            do {
                try manager.store.saveConfig(config)
            } catch {
                Log.error("could not save config after the launch at login check: \(error.localizedDescription)")
            }
        }
        let settings = SettingsWindow { [manager, secrets, locationPermission, loginItem] in
            AnyView(
                SettingsView(
                    manager: manager,
                    secrets: secrets,
                    locationPermission: locationPermission,
                    loginItem: loginItem
                )
            )
        }
        settingsWindow = settings
        statusItem = StatusItemController(manager: manager, status: status) { [weak settings] in
            settings?.show()
        }
        Task { await manager.reconcile() }
    }

    /// Quitting always ends the session (spec 1). Terminate is deferred until
    /// the end has run. A second quit while that is pending is refused rather
    /// than allowed through: `.terminateNow` there would exit mid-cleanup.
    /// If the end could not run (recovery lock busy, journal unreadable),
    /// left the journal dirty with no agent to retry, or could not remove
    /// session.json, the app stays so its own retry can finish the job;
    /// quitting then would abandon a live session.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            let outcome = await manager.end(reason: .quit)
            switch outcome {
            case .restored, .incomplete(agentArmed: true):
                sender.reply(toApplicationShouldTerminate: true)
            case .locked, .incomplete(agentArmed: false), .sessionRetained, .journalUnreadable:
                Log.error("quit deferred: recovery still pending (\(outcome)); staying to retry")
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
