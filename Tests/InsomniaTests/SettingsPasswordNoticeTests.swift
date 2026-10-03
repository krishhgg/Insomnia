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
        let outcome = await saving.value
        XCTAssertEqual(outcome, .stored(.init(ssid: "Phone", password: "pw")))
        XCTAssertFalse(keychain.gaveUp)
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "pw")
    }

    /// End from the menu while a clear waits on the keychain: the delete
    /// of another build's item can wait on a dialog the same way.
    func testEndRunsWhileAClearWaitsOnTheKeychain() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let keychain = BlockingKeychain(blocking: .delete, items: ["\(KeychainStore.service)/Phone": "old"])
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { "Phone" }
        let clearing = Task { await SettingsView.storePassword("", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        _ = await m.end(reason: .user)

        XCTAssertFalse(m.isActive, "End ended the session")
        XCTAssertTrue(keychain.isWaiting, "while the clear was still waiting")
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        keychain.release()
        let outcome = await clearing.value
        XCTAssertEqual(outcome, .stored(.init(ssid: "Phone", password: "")))
        XCTAssertFalse(keychain.gaveUp)
        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Phone"))
    }

    /// The SSID changes while the save waits on the keychain. The save
    /// stores under the SSID it began with and says so, and the button
    /// does not read "Saved" for the SSID now in the field.
    func testAnSSIDTypedWhileTheSaveWaitsIsNotShownAsSaved() async throws {
        let keychain = BlockingKeychain()
        let ssid = Locked("Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        var field = HotspotPasswordField()
        XCTAssertTrue(field.startSave())
        let saving = Task { await SettingsView.storePassword("pw", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        ssid.value = "Other Phone"
        XCTAssertEqual(field.buttonTitle(ssid: ssid.value, password: "pw"), "Saving\u{2026}")
        keychain.release()
        let outcome = await saving.value
        field.finishSave(outcome)

        XCTAssertEqual(outcome, .stored(.init(ssid: "Phone", password: "pw")))
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "pw")
        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Other Phone"))
        XCTAssertEqual(field.buttonTitle(ssid: ssid.value, password: "pw"), "Save")
        XCTAssertEqual(field.buttonTitle(ssid: "Phone", password: "pw"), "Saved")
    }

    /// A failed save says so under the field.
    func testAFailedSaveReturnsTheNotice() async {
        final class Refusing: KeychainStoring, @unchecked Sendable {
            func get(service: String, account: String) throws -> String? { nil }
            func set(service: String, account: String, value: String) throws { throw KeychainError(status: errSecUserCanceled) }
            func delete(service: String, account: String) throws {}
        }
        let store = KeychainHotspotSecretStore(keychain: Refusing(), queue: KeychainQueue()) { "Phone" }

        let outcome = await SettingsView.storePassword("pw", in: store)

        XCTAssertEqual(outcome, .failed(notice: "Could not save the hotspot password: \(KeychainError(status: errSecUserCanceled).localizedDescription)"))
    }
}

/// The field's rules without a window: what the button reads, and which
/// keychain answer sets the notice.
final class HotspotPasswordFieldTests: XCTestCase {
    private let stored = HotspotStoreOutcome.stored(.init(ssid: "Phone", password: "pw"))
    private let refused = HotspotStoreOutcome.failed(notice: "Could not save the hotspot password: User canceled the operation.")

    /// "Saved" only while both fields hold what was stored; an edit to
    /// either, before or after the save answered, reads "Save" again.
    func testSavedOnlyWhileTheFieldsHoldWhatWasStored() {
        var field = HotspotPasswordField()
        XCTAssertEqual(field.buttonTitle(ssid: "Phone", password: "pw"), "Save")
        XCTAssertTrue(field.startSave())
        XCTAssertFalse(field.startSave(), "one save at a time")
        XCTAssertEqual(field.buttonTitle(ssid: "Phone", password: "pw"), "Saving\u{2026}")
        field.finishSave(stored)

        XCTAssertEqual(field.buttonTitle(ssid: "Phone", password: "pw"), "Saved")
        XCTAssertEqual(field.buttonTitle(ssid: " Phone ", password: "pw"), "Saved", "the store trims the SSID too")
        XCTAssertEqual(field.buttonTitle(ssid: "Other Phone", password: "pw"), "Save")
        XCTAssertEqual(field.buttonTitle(ssid: "Phone", password: "pw2"), "Save")
    }

    /// A failed save may have left the old password or the new one, so
    /// nothing reads "Saved" after it, not even what an earlier save
    /// stored.
    func testAFailedSaveForgetsWhatWasStored() {
        var field = HotspotPasswordField()
        _ = field.startSave()
        field.finishSave(stored)
        _ = field.startSave()
        field.finishSave(refused)

        XCTAssertEqual(field.buttonTitle(ssid: "Phone", password: "pw"), "Save")
        XCTAssertEqual(field.notice, refused.notice)
    }

    /// The failover's report changes while the save waits on a dialog,
    /// and the recheck it starts reads the keychain behind the save. The
    /// save's failure is what stays under the field.
    func testARecheckStartedDuringASaveDoesNotHideItsFailure() {
        var field = HotspotPasswordField()
        _ = field.startSave()
        let recheck = field.startRead()
        field.finishSave(refused)

        XCTAssertFalse(field.finishRead(recheck, notice: nil))
        XCTAssertEqual(field.notice, refused.notice)
    }

    /// Settings is still loading the saved password when the user clears
    /// the field and presses Return. The load read the keychain before
    /// the clear, so its answer is dropped and does not refill the field.
    func testALoadStartedBeforeAClearDoesNotRefillTheField() {
        var field = HotspotPasswordField()
        let load = field.startRead()
        XCTAssertTrue(field.startSave())

        XCTAssertFalse(field.finishRead(load, notice: nil), "the view fills the field only when this is true")
        field.finishSave(.stored(.init(ssid: "Phone", password: "")))
        XCTAssertNil(field.notice)
    }

    /// A recheck that begins after the save answered is newer, and its
    /// notice replaces the save's.
    func testARecheckAfterTheSaveStillUpdatesTheNotice() {
        var field = HotspotPasswordField()
        _ = field.startSave()
        field.finishSave(refused)
        let recheck = field.startRead()

        XCTAssertTrue(field.finishRead(recheck, notice: HotspotPasswordProblem.unreadable.settingsNotice))
        XCTAssertEqual(field.notice, HotspotPasswordProblem.unreadable.settingsNotice)
    }

    /// Of two reads, only the newer one sets the notice, and a successful
    /// save clears it.
    func testOnlyTheNewestReadSetsTheNoticeAndASaveClearsIt() {
        var field = HotspotPasswordField()
        let first = field.startRead()
        let second = field.startRead()
        XCTAssertTrue(field.finishRead(second, notice: "second"))
        XCTAssertFalse(field.finishRead(first, notice: "first"))
        XCTAssertEqual(field.notice, "second")

        _ = field.startSave()
        field.finishSave(stored)
        XCTAssertNil(field.notice)
    }
}
