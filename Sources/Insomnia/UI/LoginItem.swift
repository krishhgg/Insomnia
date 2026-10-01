import Foundation
import Observation
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
/// error. At launch, when config.json wants it and macOS does not report
/// it enabled, the app registers again; a registration that needs the
/// user's approval, or one that fails, is shown in Settings instead of
/// only logged.
@MainActor
@Observable
final class LoginItem {
    @ObservationIgnored private let service: any LoginItemServicing
    /// What macOS reported at the last read.
    private(set) var status: LoginItemStatus
    /// The last register or unregister failure; cleared by the next success.
    private(set) var error: String?

    init(service: any LoginItemServicing = SMAppServiceLoginItem()) {
        self.service = service
        self.status = service.status
    }

    /// The real state, which the Settings switch shows.
    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    /// Run once at launch with config.launchAtLogin. With the flag on and
    /// macOS reporting anything but enabled, registers again and logs what
    /// came of it. With the flag off nothing is touched: an item the user
    /// enabled in System Settings themselves is theirs.
    func healAtLaunch(wanted: Bool) {
        refresh()
        guard wanted else { return }
        guard !isEnabled else {
            Log.info("launch at login: enabled")
            return
        }
        Log.info("launch at login: config wants it but macOS reports it \(status.description); registering again (the signature changes on every install)")
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
            }
        } catch {
            self.error = error.localizedDescription
            refresh()
            Log.error("launch at login: register failed at launch: \(error.localizedDescription)")
        }
    }

    /// The Settings switch. Returns true when macOS accepted the change
    /// (including a registration that now waits for approval), so the
    /// caller persists the flag only then; false leaves the flag as it was
    /// and the error on `error`.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            error = nil
            refresh()
            Log.info("launch at login: \(on ? "register" : "unregister") accepted; macOS reports it \(status.description)")
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
