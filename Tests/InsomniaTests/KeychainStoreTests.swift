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
    private typealias Unlock = @convention(c) (SecKeychain?, UInt32, UnsafeRawPointer?, UInt8) -> OSStatus
    private static let password = "throwaway"

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
            let password = Self.password
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

    /// Unlocks with the keychain's password; no prompt.
    func unlock() throws {
        let unlock: Unlock = try Self.symbol("SecKeychainUnlock")
        let status = Self.password.withCString { pw in
            unlock(keychain, UInt32(Self.password.utf8.count), pw, 1)
        }
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

extension LegacyKeychain.PromptSwitch {
    /// The process's real switch, except that allowing prompts fails. A
    /// store against a real keychain file uses it, so a path that would
    /// prompt (a save on a locked keychain, a delete of another build's
    /// item) fails instead of reaching the screen. It reports prompts as
    /// forbidden, so that is what the store puts back; tests restore the
    /// real setting themselves.
    static func refusingPrompts() throws -> LegacyKeychain.PromptSwitch {
        let system = try LegacyKeychain.PromptSwitch.system()
        return LegacyKeychain.PromptSwitch(
            read: { (errSecSuccess, false) },
            write: { allowed in allowed ? errSecInteractionNotAllowed : system.write(false) }
        )
    }
}

/// The real store against throwaway keychain files, with a prompt switch
/// that refuses prompts: no call here can raise a keychain dialog. The
/// prompted paths themselves (the unlock and the delete of another build's
/// item on a save) are covered by `KeychainStoreReplaceTests` through the
/// model.
final class KeychainStoreTests: XCTestCase {
    private typealias ItemCopyAccess = @convention(c) (SecKeychainItem, UnsafeMutablePointer<Unmanaged<SecAccess>?>) -> OSStatus
    private typealias AccessCopyACLList = @convention(c) (SecAccess, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> OSStatus
    private typealias ACLCopyContents = @convention(c) (
        SecACL, UnsafeMutablePointer<Unmanaged<CFArray>?>, UnsafeMutablePointer<Unmanaged<CFString>?>, UnsafeMutablePointer<UInt16>
    ) -> OSStatus
    private typealias TrustedApplicationCopyData = @convention(c) (SecTrustedApplication, UnsafeMutablePointer<Unmanaged<CFData>?>) -> OSStatus

    private var throwaway: ThrowawayKeychain!
    private var other: ThrowawayKeychain?
    private var store: KeychainStore!
    private var promptsBefore: Bool?
    private let service = "insomnia-hotspot-test"
    private var replacement: String { KeychainStore.replacementService(for: service) }

    override func setUpWithError() throws {
        promptsBefore = try LegacyKeychain.promptsAllowed()
        throwaway = try ThrowawayKeychain()
        store = KeychainStore(keychain: throwaway.keychain, prompts: try .refusingPrompts())
    }

    override func tearDown() {
        throwaway?.destroy()
        other?.destroy()
        throwaway = nil
        other = nil
        store = nil
        if let promptsBefore {
            _ = try? LegacyKeychain.PromptSwitch.system().write(promptsBefore)
        }
    }

    func testRoundTripMissingAndDelete() throws {
        XCTAssertNil(try store.get(service: service, account: "Phone"))
        try store.set(service: service, account: "Phone", value: "first")
        XCTAssertEqual(try store.get(service: service, account: "Phone"), "first")
        try store.delete(service: service, account: "Phone")
        XCTAssertNil(try store.get(service: service, account: "Phone"))
        XCTAssertNoThrow(try store.delete(service: service, account: "Phone"), "deleting a missing item is not an error")
    }

    /// A second save changes the value in place: one item, still trusting
    /// only this process.
    func testASaveOfThisBuildsItemUpdatesItInPlace() throws {
        try store.set(service: service, account: "Phone", value: "first")
        try store.set(service: service, account: "Phone", value: "second")
        XCTAssertEqual(try store.get(service: service, account: "Phone"), "second")
        XCTAssertEqual(try items(account: "Phone").count, 1)
        XCTAssertEqual(try accessLists(account: "Phone").filter { !($0.applications ?? []).isEmpty }.count, 1)
    }

    /// The item reads find lives in one keychain and new items go to
    /// another (the app's case when the item is not in the default
    /// keychain): a save changes the item where it is and adds nothing to
    /// the other keychain.
    func testASaveWritesTheKeychainThatHoldsTheItem() throws {
        let other = try ThrowawayKeychain()
        self.other = other
        try store.set(service: service, account: "Phone", value: "first")
        let split = KeychainStore(searchList: [throwaway.keychain], newItems: other.keychain, prompts: try .refusingPrompts())

        try split.set(service: service, account: "Phone", value: "second")

        XCTAssertEqual(try store.get(service: service, account: "Phone"), "second")
        XCTAssertEqual(try items(account: "Phone").count, 1)
        XCTAssertEqual(try items(account: "Phone", in: other.keychain).count, 0)
    }

    /// An item this build cannot open is replaced in its own keychain: the
    /// new password is added beside it, the old one deleted (an item that
    /// trusts nobody deletes without a prompt) and the new one renamed.
    func testASaveReplacesAnItemThisBuildCannotOpenInItsOwnKeychain() throws {
        let other = try ThrowawayKeychain()
        self.other = other
        try addItem(account: "Phone", value: "theirs", trusting: [])
        let split = KeychainStore(searchList: [throwaway.keychain], newItems: other.keychain, prompts: try .refusingPrompts())

        try split.set(service: service, account: "Phone", value: "mine")

        XCTAssertEqual(try store.get(service: service, account: "Phone"), "mine")
        XCTAssertEqual(try items(account: "Phone").count, 1)
        XCTAssertEqual(try items(account: "Phone", service: replacement).count, 0)
        XCTAssertEqual(try items(account: "Phone", in: other.keychain).count, 0)
        XCTAssertEqual(try items(account: "Phone").first?[kSecAttrLabel as String] as? String, service)
        let me = try trustedApplicationData(LegacyKeychain.thisApplication())
        let trusting = try accessLists(account: "Phone").compactMap(\.applications).filter { !$0.isEmpty }
        XCTAssertEqual(try trusting.map { try $0.map(trustedApplicationData) }, [[me]])
    }

    /// A save on a locked keychain needs the unlock prompt; refused, it
    /// fails and the old password is still there once unlocked.
    func testASaveThatCannotUnlockLeavesTheOldPassword() throws {
        try store.set(service: service, account: "Phone", value: "old")
        try throwaway.lock()

        XCTAssertThrowsError(try store.set(service: service, account: "Phone", value: "new")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecInteractionNotAllowed, "it stopped at the refused unlock prompt")
        }

        try throwaway.unlock()
        XCTAssertEqual(try store.get(service: service, account: "Phone"), "old")
        XCTAssertEqual(try items(account: "Phone", service: replacement).count, 0)
    }

    /// The old build's item (here one trusting nobody) and this build's
    /// replacement from a save that stopped short are both there. Reads
    /// ignore the replacement. The save changes its value, deletes the old
    /// item and renames the replacement: one item, trusting this process.
    func testASaveWithAReplacementLeftBehindFinishesTheReplace() throws {
        try addItem(account: "Phone", value: "theirs", trusting: [])
        try store.set(service: replacement, account: "Phone", value: "mid")
        XCTAssertThrowsError(try store.get(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.problem, .unreadable)
        }

        try store.set(service: service, account: "Phone", value: "mine")

        XCTAssertEqual(try store.get(service: service, account: "Phone"), "mine")
        XCTAssertEqual(try items(account: "Phone").count, 1)
        XCTAssertEqual(try items(account: "Phone", service: replacement).count, 0)
        let me = try trustedApplicationData(LegacyKeychain.thisApplication())
        let trusting = try accessLists(account: "Phone").compactMap(\.applications).filter { !$0.isEmpty }
        XCTAssertEqual(try trusting.map { try $0.map(trustedApplicationData) }, [[me]])
    }

    /// Two keychains on the search list, each with a readable
    /// replacement: in the first one left from some other save, in the
    /// second the one a save just wrote. Reads return neither. With no
    /// item the password reads as missing; with another build's item
    /// beside the new replacement, as unreadable. Never as the stale one.
    func testReadsNeverReturnAReplacementFromAnyKeychain() throws {
        let other = try ThrowawayKeychain()
        self.other = other
        try KeychainStore(keychain: other.keychain, prompts: try .refusingPrompts())
            .set(service: replacement, account: "Phone", value: "stale")
        try store.set(service: replacement, account: "Phone", value: "fresh")
        let both = KeychainStore(searchList: [other.keychain, throwaway.keychain], newItems: throwaway.keychain, prompts: try .refusingPrompts())

        XCTAssertNil(try both.get(service: service, account: "Phone"))
        try addItem(account: "Phone", value: "theirs", trusting: [])
        XCTAssertThrowsError(try both.get(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.problem, .unreadable)
        }
    }

    /// The lock check only reads the keychain's status.
    func testTheLockStateIsReadWithoutAPrompt() throws {
        XCTAssertFalse(try LegacyKeychain.isLocked(throwaway.keychain))
        try throwaway.lock()
        XCTAssertTrue(try LegacyKeychain.isLocked(throwaway.keychain))
        try throwaway.unlock()
        XCTAssertFalse(try LegacyKeychain.isLocked(throwaway.keychain))
    }

    /// A replacement left by a save that stopped before the rename is not
    /// what reads return: the password reads as missing. Clearing the
    /// password removes it.
    func testReadsIgnoreAReplacementLeftBehindAndClearsRemoveIt() throws {
        try store.set(service: replacement, account: "Phone", value: "new")

        XCTAssertNil(try store.get(service: service, account: "Phone"))
        try store.delete(service: service, account: "Phone")
        XCTAssertNil(try store.get(service: service, account: "Phone"))
        XCTAssertEqual(try items(account: "Phone", service: replacement).count, 0)
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
    /// The store's own calls go through the same `withPrompts`, with the
    /// switch it was given (see `KeychainStoreReplaceTests`).
    func testPromptSettingIsRestoredAfterEveryCall() throws {
        let before = try LegacyKeychain.promptsAllowed()
        XCTAssertFalse(try LegacyKeychain.withPrompts(false) { try LegacyKeychain.promptsAllowed() })
        XCTAssertEqual(try LegacyKeychain.promptsAllowed(), before)
    }

    // MARK: Helpers

    private func query(account: String, service: String? = nil, in keychain: SecKeychain? = nil) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service ?? self.service,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [keychain ?? throwaway.keychain],
        ]
    }

    private func items(account: String, service: String? = nil, in keychain: SecKeychain? = nil) throws -> [[String: Any]] {
        var q = query(account: account, service: service, in: keychain)
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

/// A prompt switch that only remembers its setting, for stores over
/// `KeychainModel`. The process's real switch is never touched.
final class VirtualPromptSwitch: Sendable {
    private let state = Locked(false)

    var allowed: Bool { state.value }

    var promptSwitch: LegacyKeychain.PromptSwitch {
        LegacyKeychain.PromptSwitch(
            read: { [state] in (errSecSuccess, state.value) },
            write: { [state] in state.value = $0; return errSecSuccess }
        )
    }
}

/// A keychain in memory behind the SecItem seam, answering the way a
/// throwaway file keychain did when measured with prompts forbidden: an
/// item another build saved reads as errSecAuthFailed, can be found by
/// reference, has its value overwritten silently, and deletes as
/// errSecInvalidOwnerEdit; a locked keychain finds items but refuses their
/// values and every change. With prompts allowed the user answers the
/// prompt with `promptAnswer`, and a yes unlocks. Each call is recorded
/// with the item's service and the prompt setting. Nothing here touches a
/// keychain.
final class KeychainModel: KeychainItemCalls, @unchecked Sendable {
    struct Item: Equatable {
        var value: String
        /// Whether this build is on the access list.
        var ours: Bool
    }

    enum Kind: String {
        case read, find, add, update, rename, delete
        /// The keychain-wide calls; recorded with an empty service.
        case lockCheck, unlock
    }

    struct Call: Equatable, CustomStringConvertible {
        let kind: Kind
        let service: String
        let promptsAllowed: Bool

        init(_ kind: Kind, _ service: String, prompts: Bool) {
            self.kind = kind
            self.service = service
            promptsAllowed = prompts
        }

        var description: String { "\(kind)(\(service), prompts: \(promptsAllowed))" }
    }

    let prompts = VirtualPromptSwitch()
    private let lock = NSLock()
    private var _items: [String: Item]
    private var _locked: Bool
    private var _calls: [Call] = []
    private var _added: [[String: Any]] = []
    private var failures: [Kind: [OSStatus]] = [:]
    /// Call number (0-based, every kind counted) that fails, and how.
    private var failingCall: (index: Int, status: OSStatus)?
    /// The keychain locks itself again just before this read.
    private var relockBeforeRead: String?
    /// Changes (adds, updates, deletes) that still take effect; nil is no
    /// limit. Once spent, every change fails with errSecIO and changes
    /// nothing, which leaves the keychain as a crash would.
    private var _changesLeft: Int?
    var promptAnswer: OSStatus = errSecSuccess

    /// `items` by service; every test uses one account.
    init(_ items: [String: Item] = [:], locked: Bool = false) {
        _items = items
        _locked = locked
    }

    var items: [String: Item] { lock.withLock { _items } }
    var calls: [Call] { lock.withLock { _calls } }
    /// The attribute dictionaries handed to `add`.
    var added: [[String: Any]] { lock.withLock { _added } }
    var locked: Bool { lock.withLock { _locked } }

    var changesLeft: Int? {
        get { lock.withLock { _changesLeft } }
        set { lock.withLock { _changesLeft = newValue } }
    }

    /// The next call of `kind` fails with `status` and changes nothing.
    func fail(_ kind: Kind, with status: OSStatus) {
        lock.withLock { failures[kind, default: []].append(status) }
    }

    /// Call number `index` (0-based, every kind counted) fails with
    /// `status` and changes nothing.
    func fail(callAt index: Int, with status: OSStatus) {
        lock.withLock { failingCall = (index, status) }
    }

    /// The keychain locks again, as its auto-lock would, just before the
    /// next read of `service`.
    func relock(beforeReadOf service: String) {
        lock.withLock { relockBeforeRead = service }
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        let q = query as NSDictionary as! [String: Any]
        let service = q[kSecAttrService as String] as! String
        let byReference = q[kSecReturnRef as String] != nil
        return record(byReference ? .find : .read, service) { item in
            guard let item else { return errSecItemNotFound }
            if byReference {
                result.pointee = "item reference" as CFString
                return errSecSuccess
            }
            guard !_locked, item.ours else { return errSecAuthFailed }
            result.pointee = Data(item.value.utf8) as CFData
            return errSecSuccess
        }
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        let a = attributes as NSDictionary as! [String: Any]
        let service = a[kSecAttrService as String] as! String
        lock.withLock { _added.append(a) }
        return change(.add, service) { item in
            guard item == nil else { return errSecDuplicateItem }
            let value = String(decoding: a[kSecValueData as String] as! Data, as: UTF8.self)
            _items[service] = Item(value: value, ours: a[kSecAttrAccess as String] != nil)
            return errSecSuccess
        }
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let service = (query as NSDictionary)[kSecAttrService as String] as! String
        let changes = attributes as NSDictionary as! [String: Any]
        if let renamed = changes[kSecAttrService as String] as? String {
            return change(.rename, service) { item in
                guard let item else { return errSecItemNotFound }
                guard item.ours else { return errSecInvalidOwnerEdit }
                guard _items[renamed] == nil else { return errSecDuplicateItem }
                _items[service] = nil
                _items[renamed] = item
                return errSecSuccess
            }
        }
        return change(.update, service) { item in
            guard item != nil else { return errSecItemNotFound }
            _items[service]?.value = String(decoding: changes[kSecValueData as String] as! Data, as: UTF8.self)
            return errSecSuccess
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        let service = (query as NSDictionary)[kSecAttrService as String] as! String
        return change(.delete, service) { item in
            guard let item else { return errSecItemNotFound }
            guard item.ours || _calls.last!.promptsAllowed else { return errSecInvalidOwnerEdit }
            _items[service] = nil
            return errSecSuccess
        }
    }

    func keychain(of item: CFTypeRef) -> (OSStatus, SecKeychain?) {
        (errSecSuccess, nil)
    }

    func isLocked(_ keychain: SecKeychain?) -> (OSStatus, Bool) {
        var locked = false
        let status = record(.lockCheck, "") { _ in
            locked = _locked
            return errSecSuccess
        }
        return (status, locked)
    }

    /// Unlocking needs the prompt, and the user's answer is `promptAnswer`.
    func unlock(_ keychain: SecKeychain?) -> OSStatus {
        record(.unlock, "") { _ in
            guard _locked else { return errSecSuccess }
            guard _calls.last!.promptsAllowed else { return errSecInteractionNotAllowed }
            guard promptAnswer == errSecSuccess else { return promptAnswer }
            _locked = false
            return errSecSuccess
        }
    }

    /// A change, which a locked keychain refuses without a prompt.
    private func change(_ kind: Kind, _ service: String, _ body: (Item?) -> OSStatus) -> OSStatus {
        record(kind, service) { item in
            if let left = _changesLeft {
                guard left > 0 else { return errSecIO }
                _changesLeft = left - 1
            }
            if _locked, item != nil || kind == .add {
                guard _calls.last!.promptsAllowed else { return errSecInteractionNotAllowed }
                guard promptAnswer == errSecSuccess else { return promptAnswer }
                _locked = false
            } else if kind == .delete, let item, !item.ours, _calls.last!.promptsAllowed {
                guard promptAnswer == errSecSuccess else { return promptAnswer }
            }
            return body(item)
        }
    }

    private func record(_ kind: Kind, _ service: String, _ body: (Item?) -> OSStatus) -> OSStatus {
        let prompts = prompts.allowed
        return lock.withLock {
            _calls.append(Call(kind, service, prompts: prompts))
            if kind == .read, service == relockBeforeRead {
                relockBeforeRead = nil
                _locked = true
            }
            if let failing = failingCall, failing.index == _calls.count - 1 {
                return failing.status
            }
            if var queued = failures[kind], !queued.isEmpty {
                let status = queued.removeFirst()
                failures[kind] = queued
                return status
            }
            return body(_items[service])
        }
    }
}

/// `KeychainStore` over `KeychainModel`. The paths that need a prompt in
/// real life (another build's item, a locked keychain) are covered here by
/// the call order, the prompt setting at each call and what the keychain
/// holds afterwards, never by a prompt.
final class KeychainStoreReplaceTests: XCTestCase {
    private let service = "insomnia-hotspot-test"
    private var replacement: String { KeychainStore.replacementService(for: service) }

    private func store(_ keychain: KeychainModel) -> KeychainStore {
        KeychainStore(calls: keychain, prompts: keychain.prompts.promptSwitch)
    }

    func testANewPasswordIsAddedWithoutAPrompt() throws {
        let keychain = KeychainModel()

        try store(keychain).set(service: service, account: "Phone", value: "pw")

        XCTAssertEqual(keychain.calls, [
            .init(.read, service, prompts: false),
            .init(.add, service, prompts: false),
            .init(.delete, replacement, prompts: false),
        ])
        XCTAssertEqual(keychain.items, [service: .init(value: "pw", ours: true)])
        XCTAssertNotNil(keychain.added.first?[kSecAttrAccess as String], "the add carries the access list")
        XCTAssertEqual(keychain.added.first?[kSecAttrLabel as String] as? String, service)
    }

    /// This build's own item already names this build, so only the value
    /// changes, in place: no delete, no add, no prompt. A replacement left
    /// by an interrupted save goes.
    func testThisBuildsItemIsUpdatedInPlace() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: true), replacement: .init(value: "stale", ours: true)])

        try store(keychain).set(service: service, account: "Phone", value: "new")

        XCTAssertEqual(keychain.calls, [
            .init(.read, service, prompts: false),
            .init(.find, service, prompts: false),
            .init(.update, service, prompts: false),
            .init(.delete, replacement, prompts: false),
        ])
        XCTAssertEqual(keychain.items, [service: .init(value: "new", ours: true)])
    }

    func testAFailedInPlaceUpdateLeavesTheOldPassword() {
        let keychain = KeychainModel([service: .init(value: "old", ours: true)])
        keychain.fail(.update, with: errSecParam)

        XCTAssertThrowsError(try store(keychain).set(service: service, account: "Phone", value: "new")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecParam)
        }

        XCTAssertEqual(keychain.items, [service: .init(value: "old", ours: true)])
    }

    /// The reinstall case. The new password is written beside the old
    /// build's item first; only then is the old item deleted, with the
    /// prompt (the user's Save), and the new one renamed into its place.
    func testReplacingAnotherBuildsItemKeepsItUntilTheNewOneIsWritten() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false)])

        try store(keychain).set(service: service, account: "Phone", value: "new")

        XCTAssertEqual(keychain.calls, [
            .init(.read, service, prompts: false),
            .init(.find, service, prompts: false),
            .init(.lockCheck, "", prompts: false),
            .init(.read, replacement, prompts: false),
            .init(.add, replacement, prompts: false),
            .init(.delete, service, prompts: false),
            .init(.delete, service, prompts: true),
            .init(.rename, replacement, prompts: false),
        ])
        XCTAssertEqual(keychain.items, [service: .init(value: "new", ours: true)])
        XCTAssertEqual(keychain.added.first?[kSecAttrLabel as String] as? String, service, "the label is the real service from the start")
        XCTAssertFalse(keychain.prompts.allowed)
    }

    /// A replacement the keychain refuses deletes nothing.
    func testAFailedAddOfTheReplacementLeavesTheOldPassword() {
        let keychain = KeychainModel([service: .init(value: "old", ours: false)])
        keychain.fail(.add, with: errSecParam)

        XCTAssertThrowsError(try store(keychain).set(service: service, account: "Phone", value: "new")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecParam)
        }

        XCTAssertEqual(keychain.items, [service: .init(value: "old", ours: false)])
        XCTAssertFalse(keychain.calls.contains { $0.kind == .delete && $0.service == service })
    }

    /// The user declines the delete prompt: the old item stays and the new
    /// one is removed again, so nothing is left half-saved.
    func testADeclinedDeleteKeepsTheOldPasswordAndDropsTheNewOne() {
        let keychain = KeychainModel([service: .init(value: "old", ours: false)])
        keychain.promptAnswer = errSecUserCanceled

        XCTAssertThrowsError(try store(keychain).set(service: service, account: "Phone", value: "new")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecUserCanceled)
        }

        XCTAssertEqual(keychain.items, [service: .init(value: "old", ours: false)])
        XCTAssertEqual(keychain.calls.last, .init(.delete, replacement, prompts: false))
    }

    /// A rename that fails leaves only the replacement, which reads
    /// ignore: the save reports the failure, and the password reads as
    /// missing until the next save puts an item under its own name.
    func testAFailedRenameReadsAsMissingUntilTheNextSave() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false)])
        keychain.fail(.rename, with: errSecParam)

        XCTAssertThrowsError(try store(keychain).set(service: service, account: "Phone", value: "new"))
        XCTAssertEqual(keychain.items, [replacement: .init(value: "new", ours: true)])
        XCTAssertNil(try store(keychain).get(service: service, account: "Phone"))

        try store(keychain).set(service: service, account: "Phone", value: "newer")
        XCTAssertEqual(keychain.items, [service: .init(value: "newer", ours: true)])
    }

    /// A save cut off after any change (a crash, a power loss): reads
    /// find the old item, unreadable as before, then nothing (the old item
    /// deleted, the new one not yet renamed), then the new password. They
    /// never return the replacement. A retry saves.
    func testASaveCutOffAtAnyPointNeverReadsTheReplacement() throws {
        var seen: Set<String> = []
        for changes in 0...5 {
            let keychain = KeychainModel([service: .init(value: "old", ours: false)])
            keychain.changesLeft = changes
            seen.insert(try assertReadsOnlyTheItem(keychain, "cut off after \(changes) changes"))
        }
        XCTAssertEqual(seen, ["old", "missing", "new"])
    }

    /// While the old build's item and the replacement are both there,
    /// reads find the old item, unreadable, and look no further.
    func testReadsIgnoreAReplacementBesideAnItemThisBuildCannotOpen() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false), replacement: .init(value: "new", ours: true)])

        XCTAssertThrowsError(try store(keychain).get(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.problem, .unreadable)
        }
        XCTAssertEqual(keychain.calls, [.init(.read, service, prompts: false)])
    }

    /// A replacement alone, this build's or another's, reads as missing:
    /// the user enters the password again.
    func testAReplacementAloneReadsAsMissing() throws {
        for ours in [true, false] {
            let keychain = KeychainModel([replacement: .init(value: "left", ours: ours)])

            XCTAssertNil(try store(keychain).get(service: service, account: "Phone"))
            XCTAssertEqual(keychain.calls, [.init(.read, service, prompts: false)])
        }
    }

    /// A locked keychain gets the unlock prompt on a save, which is the
    /// user's click, and never on a read. Unlocked, this build's item
    /// reads again, so its value changes in place.
    func testALockedKeychainIsUnlockedForASaveButNotForARead() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: true)], locked: true)

        XCTAssertThrowsError(try store(keychain).get(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.problem, .unreadable)
        }
        XCTAssertFalse(keychain.calls.contains { $0.promptsAllowed })
        XCTAssertTrue(keychain.locked)

        try store(keychain).set(service: service, account: "Phone", value: "new")

        XCTAssertEqual(keychain.calls.filter(\.promptsAllowed), [.init(.unlock, "", prompts: true)])
        XCTAssertFalse(keychain.calls.contains { $0.kind == .delete && $0.service == service }, "this build's item is not replaced")
        XCTAssertEqual(keychain.items, [service: .init(value: "new", ours: true)])
    }

    /// The user declines the unlock prompt: nothing changes.
    func testADeclinedUnlockChangesNothing() {
        let items: [String: KeychainModel.Item] = [service: .init(value: "old", ours: false), replacement: .init(value: "mid", ours: true)]
        let keychain = KeychainModel(items, locked: true)
        keychain.promptAnswer = errSecUserCanceled

        XCTAssertThrowsError(try store(keychain).set(service: service, account: "Phone", value: "new")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecUserCanceled)
        }

        XCTAssertEqual(keychain.items, items)
        XCTAssertEqual(keychain.calls.map(\.kind), [.read, .find, .lockCheck, .unlock])
    }

    // MARK: A save that finds an earlier save's replacement

    /// An earlier save stopped after writing the replacement, so the old
    /// build's item and this build's replacement are both there. The next
    /// save reuses the replacement: its value changes in place.
    func testAReplacementThisBuildCanReadIsUpdatedInPlaceNotDeleted() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false), replacement: .init(value: "mid", ours: true)])

        try store(keychain).set(service: service, account: "Phone", value: "new")

        XCTAssertEqual(keychain.calls, [
            .init(.read, service, prompts: false),
            .init(.find, service, prompts: false),
            .init(.lockCheck, "", prompts: false),
            .init(.read, replacement, prompts: false),
            .init(.update, replacement, prompts: false),
            .init(.delete, service, prompts: false),
            .init(.delete, service, prompts: true),
            .init(.rename, replacement, prompts: false),
        ])
        XCTAssertEqual(keychain.items, [service: .init(value: "new", ours: true)])
    }

    /// The same save failing at each of its calls in turn, and cut off
    /// after each number of changes: reads never return the replacement's
    /// earlier value, and a retry then saves.
    func testASaveStartingWithBothItemsNeverReadsTheReplacement() throws {
        let start: [String: KeychainModel.Item] = [service: .init(value: "old", ours: false), replacement: .init(value: "mid", ours: true)]
        let clean = KeychainModel(start)
        try store(clean).set(service: service, account: "Phone", value: "new")
        let steps = clean.calls.count

        for failing in 0..<steps {
            let keychain = KeychainModel(start)
            keychain.fail(callAt: failing, with: errSecIO)
            try assertReadsOnlyTheItem(keychain, "failing call \(failing) (\(clean.calls[failing]))")
        }
        for changes in 0...steps {
            let keychain = KeychainModel(start)
            keychain.changesLeft = changes
            try assertReadsOnlyTheItem(keychain, "cut off after \(changes) changes")
        }
    }

    /// The user declines the delete prompt for the old item: the old item
    /// stays, and the replacement, which reads would never use, goes.
    func testADeclinedDeleteWithAReadableReplacementRemovesIt() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false), replacement: .init(value: "mid", ours: true)])
        keychain.promptAnswer = errSecUserCanceled

        XCTAssertThrowsError(try store(keychain).set(service: service, account: "Phone", value: "new")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecUserCanceled)
        }

        XCTAssertEqual(keychain.items, [service: .init(value: "old", ours: false)])
        XCTAssertEqual(keychain.calls.last, .init(.delete, replacement, prompts: false))
        XCTAssertThrowsError(try store(keychain).get(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.problem, .unreadable)
        }
    }

    /// Locked, the replacement reads as unreadable like the old item. The
    /// save unlocks first and only then decides, so this build's
    /// replacement is changed in place rather than taken for another
    /// build's and deleted.
    func testALockedKeychainIsUnlockedBeforeTheReplacementIsJudged() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false), replacement: .init(value: "mid", ours: true)], locked: true)

        try store(keychain).set(service: service, account: "Phone", value: "new")

        XCTAssertEqual(keychain.calls.filter(\.promptsAllowed), [.init(.unlock, "", prompts: true), .init(.delete, service, prompts: true)])
        XCTAssertFalse(keychain.calls.contains { $0.kind == .delete && $0.service == replacement })
        XCTAssertEqual(keychain.items, [service: .init(value: "new", ours: true)])
    }

    /// A replacement still unreadable with the keychain unlocked is another
    /// build's: it holds nothing this build can return, so it is deleted
    /// (with the prompt) and added again.
    func testAnotherBuildsReplacementIsDeletedAndAddedAgain() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false), replacement: .init(value: "theirs", ours: false)])

        try store(keychain).set(service: service, account: "Phone", value: "new")

        XCTAssertEqual(Array(keychain.calls.dropFirst(3)), [
            .init(.read, replacement, prompts: false),
            .init(.lockCheck, "", prompts: false),
            .init(.delete, replacement, prompts: false),
            .init(.delete, replacement, prompts: true),
            .init(.add, replacement, prompts: false),
            .init(.delete, service, prompts: false),
            .init(.delete, service, prompts: true),
            .init(.rename, replacement, prompts: false),
        ])
        XCTAssertEqual(keychain.items, [service: .init(value: "new", ours: true)])
    }

    /// The keychain locks again between the check and the read of the
    /// replacement, so this build's replacement reads as unreadable. The
    /// save stops there rather than delete it, which would ask to unlock
    /// the keychain a second time, and changes nothing.
    func testAKeychainThatLocksAgainMidSaveKeepsTheReplacement() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false), replacement: .init(value: "mid", ours: true)])
        keychain.relock(beforeReadOf: replacement)
        keychain.fail(.add, with: errSecIO)

        XCTAssertThrowsError(try store(keychain).set(service: service, account: "Phone", value: "new")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecInteractionNotAllowed)
        }

        XCTAssertEqual(keychain.items[replacement], .init(value: "mid", ours: true))
        XCTAssertFalse(keychain.calls.contains { $0.kind == .delete })
    }

    /// Saves "new" into `keychain`, set up to fail or stop partway, then
    /// reads. Reads return the item itself and nothing else: the old
    /// build's item as unreadable while it is there, no password once it
    /// is deleted and the replacement not yet renamed, and "new" after the
    /// rename. A retry then saves. Returns which of the three it found.
    @discardableResult
    private func assertReadsOnlyTheItem(_ keychain: KeychainModel, _ when: String) throws -> String {
        _ = try? store(keychain).set(service: service, account: "Phone", value: "new")
        keychain.changesLeft = nil
        let read = Result { try store(keychain).get(service: service, account: "Phone") }
        let found: String
        switch keychain.items[service] {
        case KeychainModel.Item(value: "old", ours: false)?:
            found = "old"
            XCTAssertThrowsError(try read.get(), "\(when): \(keychain.items)") { error in
                XCTAssertEqual((error as? KeychainError)?.problem, .unreadable, when)
            }
        case nil:
            found = "missing"
            XCTAssertNil(try read.get(), "\(when): \(keychain.items)")
        case let item?:
            found = "new"
            XCTAssertEqual(item, .init(value: "new", ours: true), when)
            XCTAssertEqual(try read.get(), "new", "\(when): \(keychain.items)")
        }

        try store(keychain).set(service: service, account: "Phone", value: "newer")
        XCTAssertEqual(keychain.items, [service: .init(value: "newer", ours: true)], "the retry after \(when)")
        return found
    }

    func testClearingRemovesTheReplacementToo() throws {
        let keychain = KeychainModel([service: .init(value: "old", ours: false), replacement: .init(value: "new", ours: true)])

        try store(keychain).delete(service: service, account: "Phone")

        XCTAssertEqual(keychain.calls, [
            .init(.delete, service, prompts: false),
            .init(.delete, service, prompts: true),
            .init(.delete, replacement, prompts: false),
        ])
        XCTAssertEqual(keychain.items, [:])
    }

    /// A delete that fails for any other reason is an error, not a prompt.
    func testADeleteRefusedForAnotherReasonIsAnError() {
        let keychain = KeychainModel([service: .init(value: "pw", ours: true)])
        keychain.fail(.delete, with: errSecParam)

        XCTAssertThrowsError(try store(keychain).delete(service: service, account: "Phone")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecParam)
        }

        XCTAssertEqual(keychain.calls, [.init(.delete, service, prompts: false)])
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
