import CoreWLAN
import Foundation

protocol HotspotJoining: Sendable {
    /// Returns false when no SSID-filtered scan finds a matching network:
    /// one for the SSID as given, then one per other spelling of its
    /// apostrophes (`HotspotSSID.scanCandidates`).
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool
}

enum HotspotJoinError: Error, LocalizedError {
    case missingInterface(String)

    var errorDescription: String? {
        switch self {
        case let .missingInterface(name):
            return "CoreWLAN could not open Wi-Fi interface \(name)"
        }
    }
}

struct CoreWLANHotspotJoiner: HotspotJoining {
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        // macOS may require Location Services permission for SSID visibility.
        // Keep each scan SSID-filtered: association works with the returned
        // CWNetwork even when its `ssid` property is redacted.
        guard let found = try HotspotSSID.firstFound(ssid, scan: { name in
            try interface.scanForNetworks(withSSID: Data(name.utf8)).first
        }) else { return false }
        if found.name != ssid {
            Log.info("hotspot \(ssid) found as \(found.name), its apostrophe swapped")
        }
        try interface.associate(to: found.network, password: password)
        return true
    }
}
