import Foundation

/// Where the hotspot password lives. The system layer ships the Keychain
/// implementation (`insomnia-hotspot` in the login keychain); the settings
/// window only ever talks to this protocol.
protocol HotspotSecretStore: AnyObject, Sendable {
    /// The password for the current SSID, which becomes the account a
    /// later save moves the password from.
    func load() throws -> String?
    /// The same read without changing that account: a check, not a load
    /// into the field.
    func peek() throws -> String?
    func save(_ password: String) throws
    func delete() throws
}

/// Login-keychain implementation. The SSID provider keeps the Keychain
/// account aligned with config.json, and a save after an SSID change removes
/// the previous account only after the replacement has been written.
final class KeychainHotspotSecretStore: HotspotSecretStore, @unchecked Sendable {
    private let keychain: any KeychainStoring
    private let ssidProvider: () -> String
    private let lock = NSLock()
    private var selectedSSID: String?

    init(keychain: any KeychainStoring = KeychainStore(), ssid: @escaping () -> String) {
        self.keychain = keychain
        ssidProvider = ssid
    }

    func load() throws -> String? {
        let ssid = currentSSID()
        lock.withLock { selectedSSID = ssid }
        return try keychain.get(service: KeychainStore.service, account: ssid)
    }

    func peek() throws -> String? {
        try keychain.get(service: KeychainStore.service, account: currentSSID())
    }

    func save(_ password: String) throws {
        let ssid = currentSSID()
        let previous = lock.withLock { selectedSSID }
        try keychain.set(service: KeychainStore.service, account: ssid, value: password)
        if let previous, previous != ssid {
            try keychain.delete(service: KeychainStore.service, account: previous)
        }
        lock.withLock { selectedSSID = ssid }
    }

    func delete() throws {
        let current = currentSSID()
        let previous = lock.withLock { selectedSSID }
        try keychain.delete(service: KeychainStore.service, account: current)
        if let previous, previous != current {
            try keychain.delete(service: KeychainStore.service, account: previous)
        }
        lock.withLock { selectedSSID = current }
    }

    private func currentSSID() -> String {
        ssidProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Test store that forgets the password when the process exits.
final class InMemoryHotspotSecretStore: HotspotSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?

    init() {}

    func load() throws -> String? { lock.withLock { password } }
    func peek() throws -> String? { lock.withLock { password } }
    func save(_ password: String) throws { lock.withLock { self.password = password } }
    func delete() throws { lock.withLock { password = nil } }
}
