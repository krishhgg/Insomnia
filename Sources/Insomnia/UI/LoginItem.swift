import AppKit
import Foundation
import Observation
import Security
import ServiceManagement

/// What macOS reports for the app's login item (`SMAppService.Status`), as
/// a plain value so tests can drive it.
enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    /// Registered, but the user has to approve it under System Settings >
    /// General > Login Items before it takes effect.
    case requiresApproval
    /// macOS has no record of the app as a login item: a bundle outside
    /// ~/Applications or /Applications, or a binary run from `swift run`.
    case notFound
    case unknown(Int)

    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unknown(status.rawValue)
        }
    }

    /// For the log and the Settings note.
    var description: String {
        switch self {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "waiting for approval"
        case .notFound: "not found by macOS"
        case let .unknown(raw): "unknown status \(raw)"
        }
    }
}

/// The part of `SMAppService.mainApp` Insomnia uses, behind a protocol so
/// tests can drive the status and the errors.
@MainActor
protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

struct SMAppServiceLoginItem: LoginItemServicing {
    var status: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Launch at login, kept in step with what macOS reports rather than with
/// the config flag alone. macOS ties a login item to the app's signature
/// and location, and install.sh ad-hoc signs a fresh bundle on every run,
/// so a registration can stop being enabled after an upgrade without any
/// error. config.json remembers which install macOS last had on file
/// (`Config.launchAtLoginInstall`): at launch, when the flag is on, macOS
/// does not report the item registered and the install has changed, the
/// app registers again; when the install is the one macOS had on file,
/// the item went away by the user's hand in System Settings and the flag
/// is turned off instead. A registration that needs the user's approval,
/// or one that fails, is shown in Settings instead of only logged.
@MainActor
@Observable
final class LoginItem {
    @ObservationIgnored private let service: any LoginItemServicing
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    /// What identifies this install to macOS: see `liveInstall()`.
    let install: String
    /// What macOS reported at the last read.
    private(set) var status: LoginItemStatus
    /// The last register or unregister failure; cleared by the next success.
    private(set) var error: String?

    /// `activity` is the center that posts `NSApplication.didBecomeActive`;
    /// tests pass their own.
    init(
        service: any LoginItemServicing = SMAppServiceLoginItem(),
        install: String = LoginItem.liveInstall(),
        activity center: NotificationCenter = .default
    ) {
        self.service = service
        self.install = install
        self.status = service.status
        // Approving or removing the item happens in System Settings, and
        // coming back activates Insomnia: re-read then, since a Settings
        // window that stayed open gets no onAppear. AppKit posts this on
        // the main thread.
        activation = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    /// The code directory hash of the running bundle (new on every ad-hoc
    /// signing, so on every install.sh run) and its path, the two things
    /// macOS ties the login item to. The path alone when the hash cannot
    /// be read.
    static func liveInstall() -> String {
        let path = Bundle.main.bundleURL.path
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else {
            return "unsigned@\(path)"
        }
        return hash.map { String(format: "%02x", $0) }.joined() + "@" + path
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }
    /// macOS has the item on file, enabled or waiting for approval. The
    /// Settings switch shows this, so a pending registration can be
    /// withdrawn by turning it off.
    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    /// Run once at launch. Returns true when `config` changed and the
    /// caller should save it: the install macOS has on file was recorded,
    /// or the flag was turned off because the user removed the item.
    ///
    /// With the flag off nothing is touched: an item the user enabled in
    /// System Settings themselves is theirs. With the flag on and the item
    /// registered, the current install is recorded. Otherwise the recorded
    /// install decides: none on record (a config written before this was
    /// recorded) and a reinstall cannot be told from a removal, so the item
    /// is left alone and Settings shows the status; the same install, and
    /// the registration went away by the user's hand, so the flag follows;
    /// a different install, and the registration was lost to the
    /// reinstall, so the app registers again.
    @discardableResult
    func healAtLaunch(config: inout Config) -> Bool {
        refresh()
        guard config.launchAtLogin else { return false }
        if isRegistered {
            Log.info("launch at login: \(status.description)")
            guard config.launchAtLoginInstall != install else { return false }
            config.launchAtLoginInstall = install
            return true
        }
        guard let known = config.launchAtLoginInstall else {
            Log.info("launch at login: config wants it but macOS reports it \(status.description), and no install is on record to tell a reinstall from a removal in System Settings; leaving it alone")
            return false
        }
        guard known != install else {
            Log.info("launch at login: config wants it but macOS reports it \(status.description) for the install it had on file; treating that as removed in System Settings and turning the flag off")
            config.launchAtLogin = false
            config.launchAtLoginInstall = nil
            return true
        }
        Log.info("launch at login: config wants it but macOS reports it \(status.description) and the install changed; registering again (the signature changes on every install)")
        do {
            try service.register()
            error = nil
            refresh()
            switch status {
            case .enabled:
                Log.info("launch at login: registered again")
            case .requiresApproval:
                Log.info("launch at login: registered, waiting for approval in System Settings > General > Login Items")
            default:
                Log.error("launch at login: still \(status.description) after registering again")
                return false
            }
            config.launchAtLoginInstall = install
            return true
        } catch {
            self.error = error.localizedDescription
            refresh()
            Log.error("launch at login: register failed at launch: \(error.localizedDescription)")
            return false
        }
    }

    /// The Settings switch. Returns true when macOS accepted the change
    /// (including a registration that now waits for approval) and `config`
    /// carries the flag and the install macOS has on file for the caller
    /// to save; false leaves `config` as it was and the error on `error`.
    @discardableResult
    func set(_ on: Bool, config: inout Config) -> Bool {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            error = nil
            refresh()
            Log.info("launch at login: \(on ? "register" : "unregister") accepted; macOS reports it \(status.description)")
            config.launchAtLogin = on
            config.launchAtLoginInstall = isRegistered ? install : nil
            return true
        } catch {
            self.error = error.localizedDescription
            refresh()
            Log.error("launch at login \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            return false
        }
    }

    func openLoginItems() {
        service.openSystemSettingsLoginItems()
    }
}
