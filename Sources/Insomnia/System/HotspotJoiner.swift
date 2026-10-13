import CoreWLAN
import Foundation

protocol HotspotJoining: Sendable {
    /// Returns false when the SSID-filtered scan finds no network the join
    /// accepts (see `HotspotPick`).
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

/// Which scan result the hotspot join may associate to: the strongest
/// one that is WPA2 or WPA3 Personal. Only a network that knows the
/// password can finish that handshake, so a lookalike with the hotspot's
/// name but no password (open, WEP or OWE) is refused instead of joined.
enum HotspotPick {
    /// `protected[i]` and `rssi[i]` describe scan result `i`. Nil when
    /// none is protected.
    static func choose(protected: [Bool], rssi: [Int]) -> Int? {
        zip(protected, rssi).enumerated()
            .filter { $0.element.0 }
            .max { $0.element.1 < $1.element.1 }?
            .offset
    }
}

struct CoreWLANHotspotJoiner: HotspotJoining {
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        // macOS may require Location Services permission for SSID visibility.
        // Keep this scan SSID-filtered: association works with the returned
        // CWNetwork even when its `ssid` property is redacted.
        let networks = Array(try interface.scanForNetworks(withSSID: ssid.data(using: .utf8)))
        guard !networks.isEmpty else { return false }
        let protected = networks.map { n in
            [CWSecurity.wpa2Personal, .wpa3Personal, .wpa3Transition].contains { n.supportsSecurity($0) }
        }
        guard let i = HotspotPick.choose(protected: protected, rssi: networks.map(\.rssiValue)) else {
            Log.error("hotspot join refused: no network with the hotspot's name is WPA2 or WPA3 protected")
            return false
        }
        try interface.associate(to: networks[i], password: password)
        return true
    }
}
