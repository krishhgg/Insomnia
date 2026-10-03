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

    /// The SSID changes while a save waits, and the failover has reported
    /// the hotspot's password missing. The save stored for the old SSID,
    /// so the report about the hotspot configured now stays in the menu.
    /// The same save answering with the SSID unchanged clears it.
    func testASaveForAnSSIDEditedAwayLeavesTheFailoversReport() async throws {
        let services = AppServices(
            paths: h.home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .authorizedAlways)
        )
        services.status.hotspotPasswordProblem = .missing
        let keychain = BlockingKeychain()
        let ssid = Locked("Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        let saving = Task { await SettingsView.storePassword("pw", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        ssid.value = "Other Phone"
        keychain.release()
        let outcome = await saving.value
        SettingsView.passwordStored(outcome, configuredSSID: ssid.value, services: services)

        XCTAssertEqual(services.status.hotspotPasswordProblem, .missing)
        XCTAssertFalse(keychain.gaveUp)
        SettingsView.passwordStored(outcome, configuredSSID: "Phone", services: services)
        XCTAssertNil(services.status.hotspotPasswordProblem)
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
        let recheck = field.startRead(ssid: "Phone")
        field.finishSave(refused)

        XCTAssertEqual(field.finishRead(recheck, ssid: "Phone", notice: nil), .dropped)
        XCTAssertEqual(field.notice, refused.notice)
    }

    /// Settings is still loading the saved password when the user clears
    /// the field and presses Return. The load read the keychain before
    /// the clear, so its answer is dropped and does not refill the field.
    func testALoadStartedBeforeAClearDoesNotRefillTheField() {
        var field = HotspotPasswordField()
        let load = field.startRead(ssid: "Phone")
        XCTAssertTrue(field.startSave())

        XCTAssertEqual(field.finishRead(load, ssid: "Phone", notice: nil), .dropped, "the view fills the field only when this is .used")
        field.finishSave(.stored(.init(ssid: "Phone", password: "")))
        XCTAssertNil(field.notice)
    }

    /// A recheck that begins after the save answered is newer, and its
    /// notice replaces the save's.
    func testARecheckAfterTheSaveStillUpdatesTheNotice() {
        var field = HotspotPasswordField()
        _ = field.startSave()
        field.finishSave(refused)
        let recheck = field.startRead(ssid: "Phone")

        XCTAssertEqual(field.finishRead(recheck, ssid: "Phone", notice: HotspotPasswordProblem.unreadable.settingsNotice), .used)
        XCTAssertEqual(field.notice, HotspotPasswordProblem.unreadable.settingsNotice)
    }

    /// The SSID is edited while a load or recheck waits behind a save. Its
    /// answer is about the old SSID's item, so it is dropped: the notice
    /// stays, and the read for the new SSID begins, so the field is not
    /// left empty for an SSID that has a password. Spaces around the SSID
    /// do not count as an edit.
    func testAReadForAnSSIDEditedAwayIsDroppedAndTheNewSSIDIsRead() {
        var field = HotspotPasswordField()
        let load = field.startRead(ssid: "Phone")
        guard case let .readAgain(next) = field.finishRead(load, ssid: "Other Phone", notice: "about Phone") else {
            return XCTFail("an answer for an SSID edited away was used, or dropped with no new read")
        }
        XCTAssertNil(field.notice)
        XCTAssertEqual(next.ssid, "Other Phone")
        XCTAssertEqual(field.finishRead(load, ssid: "Other Phone", notice: "about Phone"), .dropped, "the old read is superseded")
        XCTAssertEqual(field.finishRead(next, ssid: "Other Phone", notice: "about Other Phone"), .used)
        XCTAssertEqual(field.notice, "about Other Phone")

        let recheck = field.startRead(ssid: "Phone")
        XCTAssertEqual(field.finishRead(recheck, ssid: " Phone\n", notice: "about Phone"), .used)
        XCTAssertEqual(field.notice, "about Phone")

        let beforeSave = field.startRead(ssid: "Phone")
        XCTAssertTrue(field.startSave())
        XCTAssertEqual(field.finishRead(beforeSave, ssid: "Other Phone", notice: nil), .dropped, "a save began: no new read either")
    }

    /// The SSID is edited while the window loads the password. The load's
    /// answer, the old SSID's password, is dropped, and the new SSID's
    /// password fills the field. The second read is a peek: a save after
    /// it still moves the password from the SSID the window loaded, so
    /// that SSID's item does not stay behind.
    @MainActor
    func testALoadForAnSSIDEditedAwayShowsTheNewSSIDsPassword() async throws {
        let edit = SSIDEdits(["Other Phone"])
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old", "\(KeychainStore.service)/Other Phone": "new"])
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { edit.readAndEdit() }
        var field = HotspotPasswordField()

        let password = await SettingsView.readForField(
            field.startRead(ssid: edit.configured),
            first: { await SettingsView.loadedPassword(store.load) },
            secrets: store,
            finish: { field.finishRead($0, ssid: edit.configured, notice: $1) }
        )

        XCTAssertEqual(password, "new")
        XCTAssertEqual(edit.reads, ["Phone", "Other Phone"])
        keychain.release()
        try await store.save("new")
        XCTAssertFalse(keychain.gaveUp)
        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Phone"), "the second read changed the account a save moves from")
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Other Phone"), "new")
    }

    /// The SSID is edited during the load and edited back during the read
    /// that followed. The field gets the password of the SSID configured
    /// in the end.
    @MainActor
    func testAnSSIDEditedBackDuringTheSecondReadIsReadAgain() async {
        let edit = SSIDEdits(["Other Phone", "Phone"])
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old", "\(KeychainStore.service)/Other Phone": "new"])
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { edit.readAndEdit() }
        var field = HotspotPasswordField()

        let password = await SettingsView.readForField(
            field.startRead(ssid: edit.configured),
            first: { await SettingsView.loadedPassword(store.load) },
            secrets: store,
            finish: { field.finishRead($0, ssid: edit.configured, notice: $1) }
        )

        XCTAssertEqual(password, "old")
        XCTAssertEqual(edit.reads, ["Phone", "Other Phone", "Phone"])
    }

    /// The failover reported the old SSID's password unreadable, and the
    /// SSID was edited before the recheck answered. The report is about
    /// the old SSID, so the notice comes from a read of the new one.
    @MainActor
    func testARecheckForAnSSIDEditedAwayTakesItsNoticeFromTheNewSSID() async {
        let edit = SSIDEdits([])
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Other Phone": "new"])
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { edit.readAndEdit() }
        var field = HotspotPasswordField()

        _ = await SettingsView.readForField(
            field.startRead(ssid: edit.configured),
            first: {
                edit.configured = "Other Phone"
                return ("", await SettingsView.hotspotNotice(reported: .unreadable, reread: store.peek))
            },
            secrets: store,
            finish: { field.finishRead($0, ssid: edit.configured, notice: $1) }
        )

        XCTAssertNil(field.notice)
        XCTAssertEqual(edit.reads, ["Other Phone"])
    }

    /// Only a save or clear that stored for the SSID configured now counts
    /// as a new password for the failover.
    func testOnlyAStoreForTheConfiguredSSIDCountsAsANewPassword() {
        XCTAssertTrue(stored.isStored(for: "Phone"))
        XCTAssertTrue(stored.isStored(for: " Phone\n"))
        XCTAssertFalse(stored.isStored(for: "Other Phone"))
        XCTAssertFalse(stored.isStored(for: ""))
        XCTAssertFalse(refused.isStored(for: "Phone"))
    }

    /// Of two reads, only the newer one sets the notice, and a successful
    /// save clears it.
    func testOnlyTheNewestReadSetsTheNoticeAndASaveClearsIt() {
        var field = HotspotPasswordField()
        let first = field.startRead(ssid: "Phone")
        let second = field.startRead(ssid: "Phone")
        XCTAssertEqual(field.finishRead(second, ssid: "Phone", notice: "second"), .used)
        XCTAssertEqual(field.finishRead(first, ssid: "Phone", notice: "first"), .dropped)
        XCTAssertEqual(field.notice, "second")

        _ = field.startSave()
        field.finishSave(stored)
        XCTAssertNil(field.notice)
    }
}

/// The configured SSID for `KeychainHotspotSecretStore`, which asks for
/// it once per keychain read. Each ask records the SSID and then applies
/// the next edit, as if the user typed it while the read waited.
@MainActor
private final class SSIDEdits {
    var configured = "Phone"
    private(set) var reads: [String] = []
    private var edits: [String]

    init(_ edits: [String]) { self.edits = edits }

    func readAndEdit() -> String {
        let read = configured
        reads.append(read)
        if !edits.isEmpty { configured = edits.removeFirst() }
        return read
    }
}

/// The fake the blocked-save tests rely on. Its wait ends on `release()`.
/// A call on the main thread, where nothing could release it, does not
/// wait, and the watchdog ends a wait nobody released; both set `gaveUp`.
final class BlockingKeychainTests: XCTestCase {
    func testAWaitEndsOnRelease() async throws {
        let keychain = BlockingKeychain()
        let saving = Task.detached { try keychain.set(service: "s", account: "a", value: "pw") }
        await fulfillment(of: [keychain.entered], timeout: 5)

        XCTAssertTrue(keychain.isWaiting)
        XCTAssertNil(try keychain.get(service: "s", account: "a"))
        keychain.release()
        try await saving.value

        XCTAssertFalse(keychain.isWaiting)
        XCTAssertFalse(keychain.gaveUp)
        XCTAssertFalse(keychain.calledOnMainThread)
        XCTAssertEqual(try keychain.get(service: "s", account: "a"), "pw")
    }

    /// The watchdog is short here only so that a fake that did wait on
    /// the main thread fails this test at once instead of after it.
    @MainActor
    func testACallOnTheMainThreadDoesNotWait() throws {
        let keychain = BlockingKeychain(blocking: .delete, watchdog: .milliseconds(1), items: ["s/a": "pw"])

        try keychain.delete(service: "s", account: "a")

        XCTAssertTrue(keychain.calledOnMainThread)
        XCTAssertTrue(keychain.gaveUp)
        XCTAssertFalse(keychain.isWaiting)
        XCTAssertNil(try keychain.get(service: "s", account: "a"))
    }

    func testTheWatchdogEndsAWaitNobodyReleased() async throws {
        let keychain = BlockingKeychain(watchdog: .milliseconds(50))

        try await Task.detached { try keychain.set(service: "s", account: "a", value: "pw") }.value

        XCTAssertTrue(keychain.gaveUp)
        XCTAssertFalse(keychain.calledOnMainThread)
    }
}
