import Foundation

/// Where the hotspot password lives. The system layer ships the Keychain
/// implementation (`insomnia-hotspot` in the login keychain); the settings
/// window only ever talks to this protocol. A save may wait on a keychain
/// dialog until the user answers it, so every call is async and the
/// keychain work runs off the main actor.
@MainActor
protocol HotspotSecretStore: AnyObject, Sendable {
    /// The password for the current SSID, which becomes the account a
    /// later save moves the password from.
    func load() async throws -> String?
    /// The same read without changing that account: a check, not a load
    /// into the field.
    func peek() async throws -> String?
    /// Saves for the current SSID and returns that SSID, read when the
    /// save began: one typed while it waited on the keychain is not it.
    @discardableResult func save(_ password: String) async throws -> String
    /// Clears the current SSID's password and returns that SSID.
    @discardableResult func delete() async throws -> String
}

/// Login-keychain implementation. The SSID provider keeps the Keychain
/// account aligned with config.json, and a save after an SSID change removes
/// the previous account only after the replacement has been written. The
/// SSID is read on the main actor; the keychain calls run on
/// `KeychainQueue`, behind or ahead of the failover's reads.
@MainActor
final class KeychainHotspotSecretStore: HotspotSecretStore {
    private let keychain: any KeychainStoring
    private let queue: KeychainQueue
    private let ssidProvider: @MainActor () -> String
    private var selectedSSID: String?

    init(
        keychain: any KeychainStoring = KeychainStore(),
        queue: KeychainQueue = .shared,
        ssid: @escaping @MainActor () -> String
    ) {
        self.keychain = keychain
        self.queue = queue
        ssidProvider = ssid
    }

    func load() async throws -> String? {
        let ssid = currentSSID()
        selectedSSID = ssid
        return try await read(ssid)
    }

    func peek() async throws -> String? {
        try await read(currentSSID())
    }

    @discardableResult
    func save(_ password: String) async throws -> String {
        let ssid = currentSSID()
        let previous = selectedSSID
        let keychain = self.keychain
        try await queue.run {
            try keychain.set(service: KeychainStore.service, account: ssid, value: password)
            if let previous, previous != ssid {
                try keychain.delete(service: KeychainStore.service, account: previous)
            }
        }
        selectedSSID = ssid
        return ssid
    }

    @discardableResult
    func delete() async throws -> String {
        let current = currentSSID()
        let previous = selectedSSID
        let keychain = self.keychain
        try await queue.run {
            try keychain.delete(service: KeychainStore.service, account: current)
            if let previous, previous != current {
                try keychain.delete(service: KeychainStore.service, account: previous)
            }
        }
        selectedSSID = current
        return current
    }

    private func read(_ ssid: String) async throws -> String? {
        let keychain = self.keychain
        return try await queue.run { try keychain.get(service: KeychainStore.service, account: ssid) }
    }

    private func currentSSID() -> String {
        ssidProvider().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Test store that forgets the password when the process exits.
@MainActor
final class InMemoryHotspotSecretStore: HotspotSecretStore {
    private var password: String?

    init() {}

    func load() async throws -> String? { password }
    func peek() async throws -> String? { password }
    @discardableResult
    func save(_ password: String) async throws -> String {
        self.password = password
        return ""
    }

    @discardableResult
    func delete() async throws -> String {
        password = nil
        return ""
    }
}
