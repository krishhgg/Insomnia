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
    /// Saves for the current SSID, read when the save began (one typed
    /// while it waited on the keychain is not it), and returns that SSID
    /// and the loaded account it removed.
    @discardableResult func save(_ password: String) async throws -> HotspotPasswordChange
    /// Clears the current SSID's password and the loaded account's, and
    /// returns both.
    @discardableResult func delete() async throws -> HotspotPasswordChange
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
    func save(_ password: String) async throws -> HotspotPasswordChange {
        let ssid = currentSSID()
        let previous = selectedSSID.flatMap { $0 == ssid ? nil : $0 }
        let keychain = self.keychain
        try await queue.run {
            try keychain.set(service: KeychainStore.service, account: ssid, value: password)
            if let previous {
                try keychain.delete(service: KeychainStore.service, account: previous)
            }
        }
        selectedSSID = ssid
        return HotspotPasswordChange(ssid: ssid, removed: previous)
    }

    @discardableResult
    func delete() async throws -> HotspotPasswordChange {
        let current = currentSSID()
        let previous = selectedSSID.flatMap { $0 == current ? nil : $0 }
        let keychain = self.keychain
        try await queue.run {
            try keychain.delete(service: KeychainStore.service, account: current)
            if let previous {
                try keychain.delete(service: KeychainStore.service, account: previous)
            }
        }
        selectedSSID = current
        return HotspotPasswordChange(ssid: current, removed: previous)
    }

    private func read(_ ssid: String) async throws -> String? {
        let keychain = self.keychain
        return try await queue.run { try keychain.get(service: KeychainStore.service, account: ssid) }
    }

    private func currentSSID() -> String {
        HotspotSSID.normalized(ssidProvider())
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
    func save(_ password: String) async throws -> HotspotPasswordChange {
        self.password = password
        return HotspotPasswordChange(ssid: "")
    }

    @discardableResult
    func delete() async throws -> HotspotPasswordChange {
        password = nil
        return HotspotPasswordChange(ssid: "")
    }
}
