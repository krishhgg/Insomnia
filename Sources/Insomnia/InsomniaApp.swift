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
    /// Held from launch to exit (see AppAliveLock): backstop.sh ends a valid
    /// session once it can take this lock, because the app is then gone.
    let aliveLock: AppAliveLock
    let loginItem = LoginItem()
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var terminating = false

    override init() {
        let manager = SessionManager.live()
        self.manager = manager
        aliveLock = AppAliveLock(url: manager.paths.appAliveFile)
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
        Task {
            await takeAliveLock()
            await manager.reconcile()
        }
    }

    /// backstop.sh counts a session as over once it can take the alive lock
    /// without waiting. Taken before reconcile, so the first backstop run
    /// after launch already sees this process, and never released: the
    /// kernel drops it when the process exits, however that happens. The
    /// 2 s wait covers a backstop probe holding it for a moment; a hold that
    /// outlasts it is another Insomnia, whose lock the backstop sees. This
    /// instance then keeps trying for as long as it runs, so that when the
    /// other one exits this one is counted as alive within 2 s, not never:
    /// otherwise a session started here would be ended by the backstop's
    /// next run as "Insomnia is not running".
    private func takeAliveLock() async {
        do {
            if try await aliveLock.acquire(timeout: 2) {
                Log.info("alive lock held")
                return
            }
            Log.error("alive lock \(aliveLock.path) is held by another process (another Insomnia?); until it is free the backstop does not count this instance as running and ends any session it starts; retrying every 2 s")
        } catch {
            Log.error("could not take the alive lock: \(error.localizedDescription); until it is held the backstop ends any session within a minute; retrying every 2 s")
        }
        Task { [aliveLock] in
            await aliveLock.acquireEventually(pollEvery: .seconds(2))
            if aliveLock.isHeld { Log.info("alive lock held after waiting") }
        }
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
