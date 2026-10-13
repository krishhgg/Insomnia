#if DEBUG
import Foundation

/// Debug-only fixture environment. Uses the production views and session
/// state machine, with no power, process, keychain or login-item writes.
@MainActor
enum UIPreview {
    static var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "com.kgarg.insomnia.preview"
            || CommandLine.arguments.contains("--ui-preview")
    }

    static func makeManager() -> SessionManager {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-ui-preview-\(ProcessInfo.processInfo.processIdentifier)")
        setenv(Paths.environmentKey, root.path, 1)
        return SessionManager(
            paths: Paths(root: root),
            sleepGuard: PreviewSleepGuard(),
            processControl: PreviewProcessControl(),
            backstop: PreviewBackstop(),
            clamshell: { false }
        )
    }
}

private actor PreviewSleepGuard: SleepGuarding {
    private var disabled = false
    private var lowPower = false
    func setSleepDisabled(_ disabled: Bool) { self.disabled = disabled }
    func isSleepDisabled() -> Bool { disabled }
    func setLowPowerMode(_ on: Bool) { lowPower = on }
    func isLowPowerModeOn() -> Bool { lowPower }
}

private struct PreviewProcessControl: ProcessSignaling {
    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        SuspendReport(skipped: processes.map(\.pid))
    }
    func resume(_ processes: [FrozenProcess]) -> ResumeReport { ResumeReport() }
    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport { ResumeReport() }
}

private struct PreviewBackstop: BackstopScheduling {
    func arm() async throws {}
}

@MainActor
final class PreviewHotspotSecrets: HotspotSecretStore {
    private var password: String?
    func load() async throws -> String? { password }
    func peek() async throws -> String? { password }
    func save(_ password: String) async throws -> HotspotPasswordChange {
        self.password = password
        return HotspotPasswordChange(ssid: "Preview")
    }
    func delete() async throws -> HotspotPasswordChange {
        password = nil
        return HotspotPasswordChange(ssid: "Preview")
    }
}

@MainActor
final class PreviewLoginItem: LoginItemServicing {
    private(set) var status: LoginItemStatus = .notRegistered
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSystemSettingsLoginItems() {}
}
#endif
