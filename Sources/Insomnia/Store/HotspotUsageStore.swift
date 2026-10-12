import CryptoKit
import Foundation

struct HotspotUsageRecord: Codable, Equatable, Sendable {
    var periodStarted: Date
    var ledger: HotspotUsageLedger
}

struct HotspotUsageFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var records: [String: HotspotUsageRecord] = [:]

    /// Keep raw network names out of this file and notification/log messages.
    static func key(for ssid: String) -> String {
        SHA256.hash(data: Data(ssid.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol HotspotUsageStoring {
    func load() throws -> HotspotUsageFile?
    func save(_ file: HotspotUsageFile) throws
}

struct HotspotUsageStore: HotspotUsageStoring {
    let store: Store
    static let maximumBytes = 1_048_576

    enum Failure: Error { case invalidFile }

    func load() throws -> HotspotUsageFile? {
        let path = store.paths.hotspotUsageFile
        // Store.read refuses non-regular files before opening them.
        if let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber,
           size.intValue > Self.maximumBytes { throw Failure.invalidFile }
        guard let file = try store.read(HotspotUsageFile.self, from: path) else { return nil }
        guard file.version == 1, file.records.keys.allSatisfy({ key in
            key.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }), file.records.values.allSatisfy({ $0.periodStarted.timeIntervalSince1970.isFinite && $0.periodStarted.timeIntervalSince1970 >= 0 }) else {
            throw Failure.invalidFile
        }
        return file
    }

    func save(_ file: HotspotUsageFile) throws {
        guard try Store.makeEncoder().encode(file).count <= Self.maximumBytes else { throw Failure.invalidFile }
        try store.write(file, to: store.paths.hotspotUsageFile)
    }
}
