import CoreWLAN
import Foundation

protocol HotspotJoining: Sendable {
    /// Returns false when the SSID-filtered scan finds no matching network.
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool
    /// Leaves the network the interface is on, so macOS's auto-join picks
    /// the next one: the only way back to a saved network whose password
    /// Insomnia does not have (CoreWLAN refuses a join without it).
    func leave(interfaceName: String) async throws
}

extension CWWiFiClient {
    static func interface(named name: String) throws -> CWInterface {
        guard let interface = shared().interface(withName: name) else { throw HotspotJoinError.missingInterface(name) }
        return interface
    }
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
    /// How often a call macOS answers "Resource busy" is tried, and how
    /// long to wait between tries.
    static let busyTries = 3
    static let busyWait: Duration = .seconds(2)

    @concurrent
    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        let interface = try CWWiFiClient.interface(named: interfaceName)
        // A scan must name the network byte for byte, so a name typed with
        // the straight apostrophe misses an iOS hotspot, which uses the
        // curly one: the other spelling is scanned for too.
        for name in [ssid] + [HotspotSSID.otherApostrophe(ssid)].compactMap({ $0 }) {
            // macOS may require Location Services permission for SSID
            // visibility. Keep this scan SSID-filtered: association works
            // with the returned CWNetwork even when its `ssid` is redacted.
            let networks = try await Self.retryingBusy {
                try interface.scanForNetworks(withSSID: name.data(using: .utf8))
            }
            guard let network = networks.first else { continue }
            if name != ssid { Log.info("hotspot \(ssid) found as \(name), its apostrophe swapped") }
            try await Self.retryingBusy { try interface.associate(to: network, password: password) }
            return true
        }
        return false
    }

    @concurrent
    func leave(interfaceName: String) async throws {
        let interface = try CWWiFiClient.interface(named: interfaceName)
        interface.disassociate()
    }

    /// Seen on macOS 27 with the lid closed and the Mac on no network:
    /// joins that came right after a scan failed at once with POSIX EBUSY
    /// ("Resource busy"). Such a call is tried again after a wait.
    static func retryingBusy<T>(_ call: () throws -> T) async throws -> T {
        var tries = 1
        while true {
            do {
                return try call()
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EBUSY) && tries < busyTries {
                Log.info("CoreWLAN busy (try \(tries) of \(busyTries)); trying again")
                tries += 1
                try await Task.sleep(for: busyWait)
            }
        }
    }
}

/// What the hotspot priority list needs to see without joining anything:
/// the network the Mac is on, which listed hotspots a scan finds and how
/// strong they are, and the names nearby for Settings to offer. A scan
/// takes the radio off channel for a moment, so the driver asks only
/// when it has a use for the answer.
protocol HotspotScanning: Sendable {
    /// The SSID the interface is associated with; nil when it is not, or
    /// when macOS hides the name (no Location permission).
    func currentSSID(interfaceName: String) async -> String?
    /// The signal strength (RSSI, dBm) of each of `ssids` a scan finds
    /// now, keyed by the name as given, matched whichever apostrophe. A
    /// hotspot the scan misses is absent.
    func signal(of ssids: [String], interfaceName: String) async throws -> [String: Int]
    /// The signal strength of each saved Wi-Fi network (one macOS knows
    /// and rejoins by itself) a scan finds now, except `hotspots`, matched
    /// whichever apostrophe. Empty while macOS hides the names.
    func savedSignal(excluding hotspots: [String], interfaceName: String) async throws -> [String: Int]
    /// Every network name an unfiltered scan finds, sorted, for Settings.
    /// Empty while macOS hides the names (no Location permission).
    func nearbySSIDs() async throws -> [String]
    /// The names macOS's own most recent scan found, the list it keeps for
    /// the Wi-Fi menu, sorted: read at once, with no scan, but as old as
    /// that scan. Empty while macOS hides the names.
    func cachedNearbySSIDs() async -> [String]
}

struct CoreWLANHotspotScanner: HotspotScanning {
    @concurrent
    func currentSSID(interfaceName: String) async -> String? {
        CWWiFiClient.shared().interface(withName: interfaceName)?.ssid()
    }

    @concurrent
    func signal(of ssids: [String], interfaceName: String) async throws -> [String: Int] {
        let interface = try CWWiFiClient.interface(named: interfaceName)
        // One unfiltered scan covers every hotspot while macOS shows the
        // names. When it hides them, SSID-filtered scans, one per hotspot,
        // still find each network, as they do for the join.
        let all = try interface.scanForNetworks(withSSID: nil)
        if all.isEmpty || all.contains(where: { $0.ssid != nil }) {
            var found: [String: Int] = [:]
            for (name, rssi) in Self.strongest(all, where: { HotspotSSID.any(of: ssids, matches: $0) }) {
                let asked = ssids.first { HotspotSSID.matches($0, name) }!
                found[asked] = max(found[asked] ?? Int.min, rssi)
            }
            return found
        }
        var found: [String: Int] = [:]
        for ssid in ssids {
            for name in [ssid] + [HotspotSSID.otherApostrophe(ssid)].compactMap({ $0 }) {
                let networks = try interface.scanForNetworks(withSSID: name.data(using: .utf8))
                if let best = networks.map(\.rssiValue).max() {
                    found[ssid] = max(found[ssid] ?? Int.min, best)
                }
            }
        }
        return found
    }

    @concurrent
    func savedSignal(excluding hotspots: [String], interfaceName: String) async throws -> [String: Int] {
        let interface = try CWWiFiClient.interface(named: interfaceName)
        let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
        let saved = Set(profiles.compactMap(\.ssid))
        guard !saved.isEmpty else { return [:] }
        return Self.strongest(try interface.scanForNetworks(withSSID: nil)) {
            saved.contains($0) && !HotspotSSID.any(of: hotspots, matches: $0)
        }
    }

    /// The strongest signal of each named network in `networks` that
    /// `keep` takes.
    private static func strongest(_ networks: Set<CWNetwork>, where keep: (String) -> Bool) -> [String: Int] {
        var found: [String: Int] = [:]
        for network in networks {
            guard let ssid = network.ssid, keep(ssid) else { continue }
            found[ssid] = max(found[ssid] ?? Int.min, network.rssiValue)
        }
        return found
    }

    @concurrent
    func nearbySSIDs() async throws -> [String] {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw HotspotJoinError.missingInterface("default")
        }
        return Self.names(of: try interface.scanForNetworks(withSSID: nil))
    }

    @concurrent
    func cachedNearbySSIDs() async -> [String] {
        Self.names(of: CWWiFiClient.shared().interface()?.cachedScanResults() ?? [])
    }

    private static func names(of networks: Set<CWNetwork>) -> [String] {
        let names = Set(networks.compactMap(\.ssid).filter { !$0.isEmpty })
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
