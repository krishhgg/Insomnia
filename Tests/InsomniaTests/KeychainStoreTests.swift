import Foundation
import Security
import XCTest
@testable import Insomnia

/// A keychain file of its own under the test's temp directory. Never the
/// login keychain: SecKeychainCreate does not touch the search list, and
/// every store query here names this keychain. The create, lock and delete
/// calls are resolved by name for the same reason `LegacyKeychain` does it:
/// the SDK marks them deprecated, and the test build should stay clean.
final class ThrowawayKeychain {
    private typealias Create = @convention(c) (
        UnsafePointer<CChar>, UInt32, UnsafeRawPointer?, UInt8, UnsafeRawPointer?,
        UnsafeMutablePointer<Unmanaged<SecKeychain>?>
    ) -> OSStatus
    private typealias Delete = @convention(c) (SecKeychain?) -> OSStatus
    private typealias Lock = @convention(c) (SecKeychain?) -> OSStatus

    let keychain: SecKeychain
    let directory: URL

    /// `directory` is where the keychain file goes; a fresh temp directory
    /// by default. A setup that fails removes it again, so nothing
    /// half-made is left behind.
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        do {
            let create: Create = try Self.symbol("SecKeychainCreate")
            let password = "throwaway"
            var created: Unmanaged<SecKeychain>?
            let status = self.directory.appendingPathComponent("test.keychain-db").path.withCString { path in
                password.withCString { pw in
                    create(path, UInt32(password.utf8.count), pw, 0, nil, &created)
                }
            }
            guard status == errSecSuccess, let created else { throw KeychainError(status: status) }
            keychain = created.takeRetainedValue()
        } catch {
            try? FileManager.default.removeItem(at: self.directory)
            throw error
        }
    }

    func lock() throws {
        let lock: Lock = try Self.symbol("SecKeychainLock")
        let status = lock(keychain)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func destroy() {
        if let delete: Delete = try? Self.symbol("SecKeychainDelete") {
            _ = delete(keychain)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func symbol<T>(_ name: String) throws -> T {
        guard let handle = dlopen(nil, RTLD_LAZY), let pointer = dlsym(handle, name) else {
            throw KeychainError(status: errSecUnimplemented)
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// The real store against a throwaway keychain file. These run with
/// keychain prompts forbidden by the store itself; a test that hung here
/// would mean a prompt got through. Never call `set` or `delete` here on a
/// locked keychain or on another build's item: those paths allow a prompt
/// on purpose, and `KeychainStoreReplaceTests` covers them through the
/// scripted calls instead.
final class KeychainStoreTests: XCTestCase {
    private typealias ItemCopyAccess = @convention(c) (SecKeychainItem, UnsafeMutablePointer<Unmanaged<SecAccess>?>) -> OSStatus
    private typealias AccessCopyACLList = @convention(c) (SecAccess, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> OSStatus
    private typealias ACLCopyContents = @convention(c) (
        SecACL, UnsafeMutablePointer<Unmanaged<CFArray>?>, UnsafeMutablePointer<Unmanaged<CFString>?>, UnsafeMutablePointer<UInt16>
    ) -> OSStatus
    private typealias TrustedApplicationCopyData = @convention(c) (SecTrustedApplication, UnsafeMutablePointer<Unmanaged<CFData>?>) -> OSStatus

    private var throwaway: ThrowawayKeychain!
    private var store: KeychainStore!
    private let service = "insomnia-hotspot-test"

    override func setUpWithError() throws {
        throwaway = try ThrowawayKeychain()
        store = KeychainStore(keychain: throwaway.keychain)
    }

    override func tearDown() {
        throwaway?.destroy()
        throwaway = nil
        store = nil
    }

    func testRoundTripMissingAndDelete() throws {
        XCTAssertNil(try store.get(service: service, account: "Phone"))
        try store.set(service: service, account: "Phone", value: "first")
        XCTAssertEqual(try store.get(service: service, account: "Phone"), "first")
        try store.delete(service: service, account: "Phone")
        XCTAssertNil(try store.get(service: service, account: "Phone"))
        XCTAssertNoThrow(try store.delete(service: service, account: "Phone"), "deleting a missing item is not an error")
    }

    /// A save replaces the item rather than updating it in place, so the
    /// access list is always the saving build's; one item remains.
    func testSaveReplacesTheItem() throws {
        try store.set(service: service, account: "Phone", value: "first")
        try store.set(service: service, account: "Phone", value: "second")
        XCTAssertEqual(try store.get(service: service, account: "Phone"), "second")
        XCTAssertEqual(try items(account: "Phone").count, 1)
    }

    /// The access list names only this process, under the descriptor the
    /// keychain prompt would show another program. SecAccessCreate writes
    /// one entry trusting the list and one with an empty list (always ask)
    /// for changing the list itself; no entry may trust anyone else.
    func testAccessListNamesOnlyThisProcess() throws {
        try store.set(service: service, account: "Phone", value: "pw")
        let acls = try accessLists(account: "Phone")
        XCTAssertFalse(acls.isEmpty)
        XCTAssertTrue(acls.allSatisfy { $0.description == KeychainStore.accessDescriptor }, "\(acls)")
        let trusting = acls.filter { !($0.applications ?? []).isEmpty }
        XCTAssertEqual(trusting.count, 1, "exactly one entry trusts an application: \(acls)")
        XCTAssertEqual(trusting.first?.applications?.count, 1, "\(acls)")
        let me = try trustedApplicationData(LegacyKeychain.thisApplication())
        XCTAssertEqual(try trusting.first?.applications.map { try trustedApplicationData($0[0]) }, me, "the trusted application is this process")
    }

    /// An item whose access list does not include this process, which is
    /// what another build's item looks like, is reported as unreadable, not
    /// as missing and not through a prompt.
    func testItemAnotherBuildOwnsIsUnreadableWithoutAPrompt() throws {
        try addItem(account: "Phone", value: "theirs", trusting: [])
        XCTAssertThrowsError(try store.get(service: service, account: "Phone")) { error in
            guard let error = error as? KeychainError else { return XCTFail("\(error)") }
            XCTAssertTrue(error.isUnreadableWithoutPrompt, "\(error)")
            XCTAssertEqual(error.problem, .unreadable)
        }
    }

    /// A locked keychain is refused the same way with prompts forbidden; the
    /// problem's wording covers it.
    func testLockedKeychainIsUnreadableWithoutAPrompt() throws {
        try store.set(service: service, account: "Phone", value: "pw")
        try throwaway.lock()
        XCTAssertThrowsError(try store.get(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.problem, .unreadable)
        }
        XCTAssertNil(try store.get(service: service, account: "Nope"), "a missing item is still missing while locked")
    }

    /// A keychain that cannot be created (here the file's path is already a
    /// directory) leaves no directory behind.
    func testFailedSetupLeavesNoFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-keychain-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("test.keychain-db"),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try ThrowawayKeychain(directory: directory))

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Prompts are off only for the duration of a call and the previous
    /// setting is put back, so nothing else in the process is affected.
    func testPromptSettingIsRestoredAfterEveryCall() throws {
        let before = try LegacyKeychain.promptsAllowed()
        XCTAssertFalse(try LegacyKeychain.withPrompts(false) { try LegacyKeychain.promptsAllowed() })
        XCTAssertEqual(try LegacyKeychain.promptsAllowed(), before)
        try store.set(service: service, account: "Phone", value: "pw")
        _ = try store.get(service: service, account: "Phone")
        try store.delete(service: service, account: "Phone")
        XCTAssertEqual(try LegacyKeychain.promptsAllowed(), before)
    }

    // MARK: Helpers

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [throwaway.keychain],
        ]
    }

    private func items(account: String) throws -> [[String: Any]] {
        var q = query(account: account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = try LegacyKeychain.withPrompts(false) { SecItemCopyMatching(q as CFDictionary, &result) }
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? [[String: Any]] ?? []
    }

    private func addItem(account: String, value: String, trusting applications: [SecTrustedApplication]) throws {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecUseKeychain as String: throwaway.keychain,
            kSecAttrAccess as String: try LegacyKeychain.access(descriptor: "someone else's", trusting: applications),
        ]
        let status = try LegacyKeychain.withPrompts(false) { SecItemAdd(add as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private struct ACL: CustomStringConvertible {
        let description: String
        let applications: [SecTrustedApplication]?
    }

    /// The code requirement or path SecTrustedApplication recorded.
    private func trustedApplicationData(_ application: SecTrustedApplication) throws -> Data {
        let copy: TrustedApplicationCopyData = try symbol("SecTrustedApplicationCopyData")
        var data: Unmanaged<CFData>?
        let status = copy(application, &data)
        guard status == errSecSuccess, let data else { throw KeychainError(status: status) }
        return data.takeRetainedValue() as Data
    }

    private func accessLists(account: String) throws -> [ACL] {
        var q = query(account: account)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try LegacyKeychain.withPrompts(false) { SecItemCopyMatching(q as CFDictionary, &result) }
        guard status == errSecSuccess, let result else { throw KeychainError(status: status) }
        let item = result as! SecKeychainItem
        let copyAccess: ItemCopyAccess = try symbol("SecKeychainItemCopyAccess")
        var access: Unmanaged<SecAccess>?
        let accessStatus = copyAccess(item, &access)
        guard accessStatus == errSecSuccess, let access else { throw KeychainError(status: accessStatus) }
        let copyList: AccessCopyACLList = try symbol("SecAccessCopyACLList")
        var list: Unmanaged<CFArray>?
        let listStatus = copyList(access.takeRetainedValue(), &list)
        guard listStatus == errSecSuccess, let list else { throw KeychainError(status: listStatus) }
        let copyContents: ACLCopyContents = try symbol("SecACLCopyContents")
        var out: [ACL] = []
        for entry in (list.takeRetainedValue() as [AnyObject]) {
            var applications: Unmanaged<CFArray>?
            var description: Unmanaged<CFString>?
            var selector: UInt16 = 0
            let s = copyContents(entry as! SecACL, &applications, &description, &selector)
            guard s == errSecSuccess else { throw KeychainError(status: s) }
            out.append(ACL(
                description: (description?.takeRetainedValue() as String?) ?? "",
                applications: applications?.takeRetainedValue() as? [SecTrustedApplication]
            ))
        }
        return out
    }

    private func symbol<T>(_ name: String) throws -> T {
        guard let handle = dlopen(nil, RTLD_LAZY), let pointer = dlsym(handle, name) else {
            throw KeychainError(status: errSecUnimplemented)
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// SecItem calls that answer from a script and record the order and the
/// prompt switch (read from the real switch, which the store still
/// toggles) at each call. Nothing here touches a keychain.
final class ScriptedKeychainCalls: KeychainItemCalls, @unchecked Sendable {
    struct Call: Equatable, CustomStringConvertible {
        let name: String
        let promptsAllowed: Bool

        init(_ name: String, prompts: Bool) {
            self.name = name
            promptsAllowed = prompts
        }

        var description: String { "\(name)(prompts: \(promptsAllowed))" }
    }

    private let lock = NSLock()
    private var scripted: [String: [OSStatus]]
    private var _calls: [Call] = []
    private var _added: [[String: Any]] = []

    var calls: [Call] { lock.withLock { _calls } }
    /// The attribute dictionaries handed to `add`.
    var added: [[String: Any]] { lock.withLock { _added } }

    init(copyMatching: [OSStatus] = [], add: [OSStatus] = [], delete: [OSStatus] = []) {
        scripted = ["copyMatching": copyMatching, "add": add, "delete": delete]
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        next("copyMatching")
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        lock.withLock { _added.append((attributes as NSDictionary) as? [String: Any] ?? [:]) }
        return next("add")
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        next("delete")
    }

    private func next(_ name: String) -> OSStatus {
        let prompts = (try? LegacyKeychain.promptsAllowed()) ?? true
        return lock.withLock {
            _calls.append(Call(name, prompts: prompts))
            var statuses = scripted[name] ?? []
            guard !statuses.isEmpty else { return errSecUnimplemented }
            let status = statuses.removeFirst()
            scripted[name] = statuses
            return status
        }
    }
}

/// `KeychainStore` over scripted SecItem calls. The replace path for
/// another build's item and the unlock for a save need a prompt in real
/// life, so they are covered here by the call order and the prompt switch
/// at each call, never by a prompt.
final class KeychainStoreReplaceTests: XCTestCase {
    private let service = "insomnia-hotspot-test"

    /// The reinstall case: the add hits the old build's item, the delete
    /// needs the prompt (allowed, it is the user's Save), the add repeats
    /// with prompts off.
    func testReplacingAnotherBuildsItemDeletesItWithThePromptThenAddsWithout() throws {
        let calls = ScriptedKeychainCalls(add: [errSecDuplicateItem, errSecSuccess], delete: [errSecInvalidOwnerEdit, errSecSuccess])
        let store = KeychainStore(calls: calls)

        try store.set(service: service, account: "Phone", value: "pw")

        XCTAssertEqual(calls.calls, [
            .init("add", prompts: false),
            .init("delete", prompts: false),
            .init("delete", prompts: true),
            .init("add", prompts: false),
        ])
        XCTAssertEqual(calls.added.count, 2)
        XCTAssertTrue(calls.added.allSatisfy { $0[kSecAttrAccess as String] != nil }, "every add carries the access list")
    }

    /// This build's own item is replaced without any prompt.
    func testReplacingThisBuildsItemNeedsNoPrompt() throws {
        let calls = ScriptedKeychainCalls(add: [errSecDuplicateItem, errSecSuccess], delete: [errSecSuccess])

        try KeychainStore(calls: calls).set(service: service, account: "Phone", value: "pw")

        XCTAssertEqual(calls.calls, [.init("add", prompts: false), .init("delete", prompts: false), .init("add", prompts: false)])
    }

    /// A save the keychain refuses deletes nothing: the old password stays.
    func testAFailedAddLeavesTheOldItemAlone() {
        let calls = ScriptedKeychainCalls(add: [errSecParam])

        XCTAssertThrowsError(try KeychainStore(calls: calls).set(service: service, account: "Phone", value: "pw")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecParam)
        }

        XCTAssertEqual(calls.calls, [.init("add", prompts: false)])
    }

    /// A locked keychain gets the unlock prompt on a save, which is the
    /// user's click, and never on a read.
    func testALockedKeychainIsUnlockedForASaveButNotForARead() throws {
        let saving = ScriptedKeychainCalls(add: [errSecInteractionNotAllowed, errSecSuccess])
        try KeychainStore(calls: saving).set(service: service, account: "Phone", value: "pw")
        XCTAssertEqual(saving.calls, [.init("add", prompts: false), .init("add", prompts: true)])

        let reading = ScriptedKeychainCalls(copyMatching: [errSecAuthFailed])
        XCTAssertThrowsError(try KeychainStore(calls: reading).get(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.problem, .unreadable)
        }
        XCTAssertEqual(reading.calls, [.init("copyMatching", prompts: false)])
    }

    /// A delete that fails for any other reason is an error, not a prompt.
    func testADeleteRefusedForAnotherReasonIsAnError() {
        let calls = ScriptedKeychainCalls(delete: [errSecParam])

        XCTAssertThrowsError(try KeychainStore(calls: calls).delete(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecParam)
        }

        XCTAssertEqual(calls.calls, [.init("delete", prompts: false)])
    }
}

/// `LegacyKeychain.withPrompts` over a scripted switch. The real switch is
/// never touched here.
final class PromptSwitchTests: XCTestCase {
    func testAFailedWriteStopsTheCallBeforeItRuns() {
        let prompts = LegacyKeychain.PromptSwitch(read: { (errSecSuccess, true) }, write: { _ in errSecInteractionNotAllowed })
        var ran = false

        XCTAssertThrowsError(try LegacyKeychain.withPrompts(false, using: prompts) { ran = true }) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecInteractionNotAllowed)
        }

        XCTAssertFalse(ran, "the keychain call must not run with the prompt setting unknown")
    }

    func testAFailedReadStopsBeforeAnythingIsWritten() {
        let writes = Locked<[Bool]>([])
        let prompts = LegacyKeychain.PromptSwitch(
            read: { (errSecParam, true) },
            write: { writes.value.append($0); return errSecSuccess }
        )
        var ran = false

        XCTAssertThrowsError(try LegacyKeychain.withPrompts(false, using: prompts) { ran = true }) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecParam)
        }

        XCTAssertFalse(ran)
        XCTAssertEqual(writes.value, [])
    }

    /// The setting that was there before is the one put back, even when it
    /// was "forbidden".
    func testTheSettingIsPutBackToWhatItWas() throws {
        let writes = Locked<[Bool]>([])
        let prompts = LegacyKeychain.PromptSwitch(
            read: { (errSecSuccess, false) },
            write: { writes.value.append($0); return errSecSuccess }
        )

        let result = try LegacyKeychain.withPrompts(true, using: prompts) { writes.value }

        XCTAssertEqual(result, [true])
        XCTAssertEqual(writes.value, [true, false])
    }
}
