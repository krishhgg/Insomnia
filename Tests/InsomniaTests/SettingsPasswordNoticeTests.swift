import Security
import XCTest
@testable import Insomnia

/// The notice under the Settings password field, as pure functions: no
/// window, no status item, no keychain.
@MainActor
final class SettingsPasswordNoticeTests: XCTestCase {
    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    /// Stopping the session clears the failover's report. The password is
    /// still unreadable, so the notice must stay.
    func testAReportClearedBySessionEndKeepsTheNoticeWhileThePasswordIsUnreadable() async {
        let notice = await SettingsView.hotspotNotice(reported: nil) { throw KeychainError(status: errSecAuthFailed) }

        XCTAssertEqual(notice, HotspotPasswordProblem.unreadable.settingsNotice)
        XCTAssertNotNil(notice)
    }

    func testAReportClearedAfterTheFixClearsTheNotice() async {
        let readable = await SettingsView.hotspotNotice(reported: nil) { "pw" }
        let missing = await SettingsView.hotspotNotice(reported: nil) { nil }
        XCTAssertNil(readable)
        XCTAssertNil(missing, "no saved password is not a problem here")
    }

    /// A report is shown as it is, without reading the keychain again.
    func testAReportedProblemIsShownWithoutAReread() async {
        var reread = false

        let notice = await SettingsView.hotspotNotice(reported: .unreadable) { reread = true; return "pw" }

        XCTAssertEqual(notice, HotspotPasswordProblem.unreadable.settingsNotice)
        XCTAssertFalse(reread)
    }

    func testLoadingFillsTheFieldOrSaysWhyItCannot() async {
        let loaded = await SettingsView.loadedPassword { "pw" }
        XCTAssertEqual(loaded.password, "pw")
        XCTAssertNil(loaded.notice)

        let unreadable = await SettingsView.loadedPassword { throw KeychainError(status: errSecInteractionNotAllowed) }
        XCTAssertEqual(unreadable.password, "")
        XCTAssertEqual(unreadable.notice, HotspotPasswordProblem.unreadable.settingsNotice)

        let other = await SettingsView.loadedPassword { throw Boom() }
        XCTAssertEqual(other.password, "")
        XCTAssertEqual(other.notice, HotspotPasswordProblem.error("boom").settingsNotice)
    }
}

/// A save in Settings can wait on a keychain dialog for as long as the user
/// leaves it open. These hold one open (`BlockingKeychain`) and check that
/// the main actor's safety work runs meanwhile. No real keychain is used.
@MainActor
final class SettingsPasswordSaveTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    /// The battery floor ends the session while the save waits.
    func testTheEndFloorRunsWhileASaveWaitsOnTheKeychain() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let keychain = BlockingKeychain()
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { "Phone" }
        let saving = Task { await SettingsView.storePassword("pw", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        let floor = FloorRuleDriver(manager: m, notifier: h.notifier)
        await floor.run(battery: .percent(8), isCharging: false, thermal: .nominal, lidClosed: false)

        XCTAssertFalse(m.isActive, "the end floor ended the session")
        XCTAssertTrue(keychain.isWaiting, "while the save was still waiting")
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        keychain.release()
        let failure = await saving.value
        XCTAssertNil(failure)
        XCTAssertFalse(keychain.gaveUp)
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "pw")
    }

    /// End from the menu, and a clear rather than a save.
    func testEndRunsWhileAClearWaitsOnTheKeychain() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let keychain = BlockingKeychain()
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { "Phone" }
        let saving = Task { await SettingsView.storePassword("pw", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)
        let queue = KeychainQueue()
        let clearing = KeychainHotspotSecretStore(keychain: keychain, queue: queue) { "Phone" }

        _ = await m.end(reason: .user)
        let cleared = await SettingsView.storePassword("", in: clearing)

        XCTAssertFalse(m.isActive)
        XCTAssertNil(cleared)
        XCTAssertTrue(keychain.isWaiting, "End and the clear ran while the save was still waiting")
        keychain.release()
        _ = await saving.value
        XCTAssertFalse(keychain.gaveUp)
    }

    /// A failed save says so under the field.
    func testAFailedSaveReturnsTheNotice() async {
        final class Refusing: KeychainStoring, @unchecked Sendable {
            func get(service: String, account: String) throws -> String? { nil }
            func set(service: String, account: String, value: String) throws { throw KeychainError(status: errSecUserCanceled) }
            func delete(service: String, account: String) throws {}
        }
        let store = KeychainHotspotSecretStore(keychain: Refusing(), queue: KeychainQueue()) { "Phone" }

        let notice = await SettingsView.storePassword("pw", in: store)

        XCTAssertEqual(notice, "Could not save the hotspot password: \(KeychainError(status: errSecUserCanceled).localizedDescription)")
    }
}
