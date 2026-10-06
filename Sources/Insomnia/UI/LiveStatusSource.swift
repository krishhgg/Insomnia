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
    var throttledBrowsers: [ThrottledBrowser] { services.status.throttledBrowsers }
    var relaunchProblems: [String] {
        services.status.relaunchProblems.sorted { $0.key < $1.key }.map(\.value)
    }
    var hotspotPasswordReport: HotspotPasswordReport? { services.status.hotspotPasswordReport }
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

    func relaunchUnthrottled(_ browser: ThrottledBrowser) {
        Task { @MainActor [services] in
            await services.relaunchUnthrottled(browser)
        }
    }
}
