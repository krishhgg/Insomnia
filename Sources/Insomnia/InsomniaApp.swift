import AppKit
import SwiftUI

/// Menu bar app. The status item is an `NSStatusItem` hosting SwiftUI, and
/// the settings window is an `NSWindow` this app opens itself (see
/// `SettingsWindow`), so there is no SwiftUI scene with any content in it.
/// `App` still requires one, hence the empty `Settings`. main.swift starts
/// this app unless the command line asks for a one-shot mode first.
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
    let releases = ReleaseChecker()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var displaySleep: DisplaySleepObserver?
    private var timeChange: TimeChangeObserver?
    private let sessionCommands = SessionCommandWatcher()
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so the first notification already shows
        // while Insomnia is frontmost.
        ForegroundNotifications.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched, version \(AppBuild.current.label)")
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
        let settings = SettingsWindow { [manager, secrets, locationPermission, loginItem, releases] in
            SettingsView(
                manager: manager,
                secrets: secrets,
                locationPermission: locationPermission,
                loginItem: loginItem,
                releases: releases
            )
        }
        settingsWindow = settings
        statusItem = StatusItemController(manager: manager, status: status) { [weak settings] in
            settings?.show()
        }
        displaySleep = DisplaySleepObserver { [manager] asleep in manager.displaysAsleepChanged(asleep) }
        timeChange = TimeChangeObserver { [manager] in manager.refreshCountdown() }
        sessionCommands.onRequest = { [manager] request in
            Task { await manager.serve(request) }
        }
        Task {
            await manager.reconcile()
            // `Insomnia --session` from a script or an agent, once reconcile
            // has adopted or cleared what it found, so no request is
            // answered against a session that is about to resume.
            sessionCommands.start(paths: manager.paths)
        }
    }

    /// Quitting always ends the session (spec 1). Terminate is deferred until
    /// the end has run. A second quit while that is pending is refused rather
    /// than allowed through: `.terminateNow` there would exit mid-cleanup.
    /// If the end could not run (recovery lock busy, journal unreadable),
    /// left the journal dirty with no agent to retry, or could not remove
    /// session.json, the app stays so its own retry can finish the job;
    /// quitting then would abandon a live session. It also stays while a
    /// `sudo pmset` that ignored SIGTERM is alive. The recovery lock would
    /// outlive a quit (the command holds it through its own descriptor),
    /// but the end the command holds up would not: the app is what retries
    /// it, and confirms an undo the command finishes, the moment it exits.
    /// It stays while a closed lid's sleep is owed: only the app asks for it.
    /// That lasts until macOS grants it or has refused it
    /// `SessionManager.closedLidSleepRefusalLimit` times.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            let outcome = await manager.end(reason: .quit)
            if manager.letsQuitGo(after: outcome) {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                let why = outcome.letsQuitGo
                    ? "a closed lid's sleep is owed and only Insomnia asks for it"
                    : "recovery still pending (\(outcome))"
                Log.error("quit deferred: \(why); staying to retry")
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
