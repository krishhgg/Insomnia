import Foundation
import Observation

/// Adapts the live system integration layer to the UI-facing status protocol.
@MainActor
@Observable
final class LiveStatusSource: StatusSource {
    @ObservationIgnored private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    var lidClosed: Bool { services.status.lidClosed }
    var batteryPercent: Int? { services.status.batteryPercent }
    var isCharging: Bool { services.status.isCharging }
    var wifiSSID: String? { services.status.wifiSSID }
    var lastGap: TimeInterval? { services.status.lastGap }
    var frozenCount: Int { services.status.frozenCount }
    var dockerPaused: Bool { services.status.dockerPaused }
    var throttledBrowsers: [String] { services.status.throttledBrowsers }
    var hotspotPasswordProblem: HotspotPasswordProblem? { services.status.hotspotPasswordProblem }
    var locationPermission: LocationPermission { services.locationPermission }

    func refreshOnDemand() {
        Task { @MainActor [services] in
            await services.refreshOnDemand()
        }
    }

    func refreshInstant() {
        services.refreshInstant()
    }

    func instantWatts() -> Double? {
        services.instantWatts()
    }

    func relaunchUnthrottled(_ name: String) {
        guard let bundleID = Self.bundleID(forDisplayName: name, in: services.status.browsers) else {
            Log.error("relaunch: no bundle id for browser named \(name)")
            return
        }
        Task { @MainActor [services] in
            await services.relaunchUnthrottled(bundleID)
        }
    }

    static func bundleID(forDisplayName name: String, in browsers: [BrowserStatus]) -> String? {
        browsers.first { $0.name == name }?.bundleId
    }
}
