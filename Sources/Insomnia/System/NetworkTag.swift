import CryptoKit
import Foundation

/// How insomnia.log names a Wi-Fi network the failover lands on or hands
/// back to: a keyed hash of its name, never the name. The key is random,
/// made once per install and kept in Application Support, so a tag tells
/// lines about one network from lines about another and nothing more.
/// Without the key no list of known network names maps a tag back to its
/// name, and the same network has another tag on another Mac.
struct NetworkTag: Sendable {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// "network 3f9a1c07": the first 4 bytes of the HMAC-SHA256 of the
    /// name, folded, so both apostrophes give the same tag.
    func callAsFunction(_ ssid: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(HotspotSSID.folded(ssid).utf8), using: key)
        return "network " + code.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private struct Record: Codable {
        let key: Data
    }

    /// The install's key from `paths.networkTagKeyFile`, made and written
    /// there on first use. One that cannot be written still serves this
    /// launch: its tags then match only each other.
    static func load(_ paths: Paths) -> NetworkTag {
        let store = Store(paths: paths)
        do {
            if let record = try store.read(Record.self, from: paths.networkTagKeyFile), record.key.count == 32 {
                return NetworkTag(key: SymmetricKey(data: record.key))
            }
        } catch {
            Log.error("network-tag-key.json: \(error.localizedDescription); making a new key")
        }
        let key = SymmetricKey(size: .bits256)
        do {
            try store.write(Record(key: key.withUnsafeBytes { Data($0) }), to: paths.networkTagKeyFile)
        } catch {
            Log.error("network-tag-key.json: \(error.localizedDescription); the key lasts this launch only")
        }
        return NetworkTag(key: key)
    }
}
