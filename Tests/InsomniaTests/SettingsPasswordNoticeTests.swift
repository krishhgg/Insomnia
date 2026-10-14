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
        let notice = await SettingsView.hotspotNotice(reported: nil, ssid: "Phone") { throw KeychainError(status: errSecAuthFailed) }

        XCTAssertEqual(notice, HotspotPasswordProblem.unreadable.settingsNotice)
        XCTAssertNotNil(notice)
    }

    func testAReportClearedAfterTheFixClearsTheNotice() async {
        let readable = await SettingsView.hotspotNotice(reported: nil, ssid: "Phone") { "pw" }
        let missing = await SettingsView.hotspotNotice(reported: nil, ssid: "Phone") { nil }
        XCTAssertNil(readable)
        XCTAssertNil(missing, "no saved password is not a problem here")
    }

    /// A report is shown as it is, without reading the keychain again.
    func testAReportedProblemIsShownWithoutAReread() async {
        var reread = false

        let notice = await SettingsView.hotspotNotice(reported: Self.unreadablePhone, ssid: " Phone ") { reread = true; return "pw" }

        XCTAssertEqual(notice, HotspotPasswordProblem.unreadable.settingsNotice)
        XCTAssertFalse(reread)
    }

    /// The failover reported hotspot "Phone" unreadable, and the user then
    /// configured "Other Phone", whose saved password is readable. The
    /// report is about an item no join reads now: the notice comes from a
    /// read of the new hotspot's item.
    func testAReportAboutAnSSIDEditedAwayIsNotShown() async {
        var reread = false

        let readable = await SettingsView.hotspotNotice(reported: Self.unreadablePhone, ssid: "Other Phone") { reread = true; return "pw" }
        let unreadable = await SettingsView.hotspotNotice(reported: Self.unreadablePhone, ssid: "Other Phone") { throw KeychainError(status: errSecAuthFailed) }

        XCTAssertNil(readable)
        XCTAssertTrue(reread)
        XCTAssertEqual(unreadable, HotspotPasswordProblem.unreadable.settingsNotice, "the new hotspot's own problem still shows")
    }

    private static let unreadablePhone = HotspotPasswordReport(ssid: "Phone", problem: .unreadable)

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
    /// stores under the SSID it began with and says so, and the field does
    /// not count as saved for the SSID configured now.
    func testAnSSIDTypedWhileTheSaveWaitsIsNotShownAsSaved() async throws {
        let keychain = BlockingKeychain()
        let ssid = Locked("Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        var field = HotspotPasswordField()
        field.edit("pw")
        XCTAssertTrue(field.startSave())
        let saving = Task { await SettingsView.storePassword("pw", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        ssid.value = "Other Phone"
        XCTAssertFalse(field.isSaved(ssid: ssid.value))
        keychain.release()
        let outcome = await saving.value
        let recheck = field.finishSave(outcome, ssid: ssid.value)

        XCTAssertEqual(outcome, .stored(.init(ssid: "Phone", password: "pw")))
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "pw")
        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Other Phone"))
        XCTAssertFalse(field.isSaved(ssid: ssid.value))
        XCTAssertTrue(field.isSaved(ssid: "Phone"))
        XCTAssertEqual(recheck?.ssid, "Other Phone", "the notice is read again for the SSID typed meanwhile")
    }

    /// The SSID changes while a save waits, and the failover has reported
    /// the new hotspot's password missing. The save stored for the old
    /// SSID, so the report about the hotspot configured now stays in the
    /// menu. A report about the SSID the save stored for goes.
    func testASaveForAnSSIDEditedAwayLeavesTheFailoversReport() async throws {
        let services = AppServices(
            paths: h.home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .authorizedAlways)
        )
        let otherPhone = HotspotPasswordReport(ssid: "Other Phone", problem: .missing)
        services.status.hotspotPasswordReport = otherPhone
        let keychain = BlockingKeychain()
        let ssid = Locked("Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        let saving = Task { await SettingsView.storePassword("pw", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        ssid.value = "Other Phone"
        keychain.release()
        let outcome = await saving.value
        SettingsView.passwordStored(outcome, configuredSSID: ssid.value, services: services)

        XCTAssertEqual(services.status.hotspotPasswordReport, otherPhone)
        XCTAssertFalse(keychain.gaveUp)
        services.status.hotspotPasswordReport = HotspotPasswordReport(ssid: "Phone", problem: .unreadable)
        SettingsView.passwordStored(outcome, configuredSSID: ssid.value, services: services)
        XCTAssertNil(services.status.hotspotPasswordReport, "the save wrote the reported hotspot's item")
        services.status.hotspotPasswordReport = otherPhone
        SettingsView.passwordStored(.failed(notice: "refused"), configuredSSID: "Phone", services: services)
        XCTAssertEqual(services.status.hotspotPasswordReport, otherPhone, "a failed save changed nothing")
        SettingsView.passwordStored(outcome, configuredSSID: "Phone", services: services)
        XCTAssertNil(services.status.hotspotPasswordReport)
    }

    /// Greptile's case: the window loaded "Phone", the SSID is edited to
    /// "Other Phone" and saved, then edited back to "Phone" while the
    /// save waits. The save stored for "Other Phone" and removed "Phone",
    /// the account the window loaded, so the report that "Phone" is
    /// unreadable is out of date and goes, and the notice is read again
    /// for "Phone", whose item is now missing.
    func testASaveThatRemovedTheConfiguredHotspotsItemClearsItsReport() async throws {
        let services = AppServices(
            paths: h.home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .authorizedAlways)
        )
        services.status.hotspotPasswordReport = HotspotPasswordReport(ssid: "Phone", problem: .unreadable)
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old"])
        let ssid = Locked("Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        _ = try await store.load()
        var field = HotspotPasswordField()
        ssid.value = "Other Phone"
        field.edit("pw")
        XCTAssertTrue(field.startSave())
        let saving = Task { await SettingsView.storePassword("pw", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        ssid.value = "Phone"
        keychain.release()
        let outcome = await saving.value
        let recheck = field.finishSave(outcome, ssid: ssid.value)
        SettingsView.passwordStored(outcome, configuredSSID: ssid.value, services: services)

        XCTAssertEqual(outcome, .stored(.init(ssid: "Other Phone", password: "pw", removed: "Phone")))
        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Phone"), "the save removed the loaded account")
        XCTAssertNil(services.status.hotspotPasswordReport, "the reported item is gone")
        XCTAssertEqual(recheck?.ssid, "Phone")
        let notice = await SettingsView.hotspotNotice(reported: services.status.hotspotPasswordReport, ssid: ssid.value, reread: store.peek)
        XCTAssertNil(notice, "a missing item needs no notice")
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

        let outcome = await SettingsView.storePassword("pw", in: store)

        XCTAssertEqual(outcome, .failed(notice: "Could not save the hotspot password: \(KeychainError(status: errSecUserCanceled).localizedDescription)"))
    }
}

/// The field's rules without a window: when it counts as saved, and which
/// keychain answer sets the notice.
final class HotspotPasswordFieldTests: XCTestCase {
    private let stored = HotspotStoreOutcome.stored(.init(ssid: "Phone", password: "pw"))
    private let refused = HotspotStoreOutcome.failed(notice: "Could not save the hotspot password: User canceled the operation.")

    /// Saved only while both fields hold what was stored; an edit to
    /// either, before or after the save answered, needs a save again.
    func testSavedOnlyWhileTheFieldsHoldWhatWasStored() {
        var field = HotspotPasswordField()
        field.edit("pw")
        XCTAssertFalse(field.isSaved(ssid: "Phone"))
        XCTAssertTrue(field.startSave())
        XCTAssertFalse(field.startSave(), "one save at a time")
        XCTAssertFalse(field.isSaved(ssid: "Phone"), "not while the save waits")
        XCTAssertNil(field.finishSave(stored, ssid: "Phone"))

        XCTAssertTrue(field.isSaved(ssid: "Phone"))
        XCTAssertTrue(field.isSaved(ssid: " Phone "), "the store trims the SSID too")
        XCTAssertFalse(field.isSaved(ssid: "Other Phone"))
        field.edit("pw2")
        XCTAssertFalse(field.isSaved(ssid: "Phone"))
    }

    /// What the load fills in is what the keychain holds, so Save stays
    /// off until the field or the SSID changes. An empty load (nothing
    /// saved, or an item this build cannot read) counts too.
    func testTheLoadedPasswordCountsAsSaved() {
        var field = HotspotPasswordField()
        let load = field.startLoad(ssid: "Phone")
        XCTAssertEqual(field.finishRead(load, ssid: "Phone", password: "pw", notice: nil), .used)
        XCTAssertTrue(field.isSaved(ssid: "Phone"))
        XCTAssertFalse(field.isSaved(ssid: "Other Phone"))
        field.edit("pw2")
        XCTAssertFalse(field.isSaved(ssid: "Phone"))
        field.edit("pw")
        XCTAssertTrue(field.isSaved(ssid: "Phone"), "typing the saved password back needs no save")

        var empty = HotspotPasswordField()
        let unreadable = empty.startLoad(ssid: "Phone")
        _ = empty.finishRead(unreadable, ssid: "Phone", password: "", notice: "unreadable")
        XCTAssertTrue(empty.isSaved(ssid: "Phone"))
        empty.edit("new")
        XCTAssertFalse(empty.isSaved(ssid: "Phone"))
    }

    /// A failed save may have left the old password or the new one, so
    /// nothing counts as saved after it, not even what an earlier save
    /// stored.
    func testAFailedSaveForgetsWhatWasStored() {
        var field = HotspotPasswordField()
        field.edit("pw")
        _ = field.startSave()
        field.finishSave(stored, ssid: "Phone")
        _ = field.startSave()
        field.finishSave(refused, ssid: "Phone")

        XCTAssertFalse(field.isSaved(ssid: "Phone"))
        XCTAssertEqual(field.notice, refused.notice)
    }

    /// The failover's report changes while the save waits on a dialog,
    /// and the recheck it starts reads the keychain behind the save. The
    /// save's failure is what stays under the field.
    func testARecheckStartedDuringASaveDoesNotHideItsFailure() {
        var field = HotspotPasswordField()
        _ = field.startSave()
        let recheck = field.startRead(ssid: "Phone")
        XCTAssertNil(field.finishSave(refused, ssid: "Other Phone"), "the failure stays, whatever the SSID")

        XCTAssertEqual(field.finishRead(recheck, ssid: "Phone", password: "", notice: nil), .dropped)
        XCTAssertEqual(field.notice, refused.notice)
    }

    /// Settings is still loading the saved password when the user clears
    /// the field and presses Return. The load read the keychain before
    /// the clear, so its answer is dropped and does not refill the field.
    func testALoadStartedBeforeAClearDoesNotRefillTheField() {
        var field = HotspotPasswordField()
        let load = field.startLoad(ssid: "Phone")
        XCTAssertTrue(field.startSave())

        XCTAssertEqual(field.finishRead(load, ssid: "Phone", password: "old", notice: nil), .dropped)
        XCTAssertEqual(field.password, "")
        field.finishSave(.stored(.init(ssid: "Phone", password: "")), ssid: "Phone")
        XCTAssertNil(field.notice)
    }

    /// A recheck that begins after the save answered is newer, and its
    /// notice replaces the save's.
    func testARecheckAfterTheSaveStillUpdatesTheNotice() {
        var field = HotspotPasswordField()
        _ = field.startSave()
        field.finishSave(refused, ssid: "Phone")
        let recheck = field.startRead(ssid: "Phone")

        XCTAssertEqual(field.finishRead(recheck, ssid: "Phone", password: "", notice: HotspotPasswordProblem.unreadable.settingsNotice), .used)
        XCTAssertEqual(field.notice, HotspotPasswordProblem.unreadable.settingsNotice)
    }

    /// The SSID is edited while a load or recheck waits behind a save. Its
    /// answer is about the old SSID's item, so it is dropped: the notice
    /// stays, and the read for the new SSID begins, so the field is not
    /// left empty for an SSID that has a password. Spaces around the SSID
    /// do not count as an edit.
    func testAReadForAnSSIDEditedAwayIsDroppedAndTheNewSSIDIsRead() {
        var field = HotspotPasswordField()
        let load = field.startLoad(ssid: "Phone")
        guard case let .readAgain(next) = field.finishRead(load, ssid: "Other Phone", password: "old", notice: "about Phone") else {
            return XCTFail("an answer for an SSID edited away was used, or dropped with no new read")
        }
        XCTAssertNil(field.notice)
        XCTAssertEqual(field.password, "")
        XCTAssertEqual(next.ssid, "Other Phone")
        XCTAssertEqual(field.finishRead(next, ssid: "Other Phone", password: "new", notice: "about Other Phone"), .used)
        XCTAssertEqual(field.notice, "about Other Phone")
        XCTAssertEqual(field.password, "new")

        let recheck = field.startRead(ssid: "Phone")
        guard case let .readAgain(again) = field.finishRead(recheck, ssid: "Other Phone", password: "", notice: "about Phone") else {
            return XCTFail("a recheck for an SSID edited away was used, or dropped with no new read")
        }
        XCTAssertEqual(field.finishRead(recheck, ssid: "Other Phone", password: "", notice: "about Phone"), .dropped, "the old read is superseded")
        XCTAssertEqual(field.finishRead(again, ssid: " Other Phone\n", password: "", notice: "about Other Phone again"), .used)
        XCTAssertEqual(field.notice, "about Other Phone again")

        let beforeSave = field.startRead(ssid: "Phone")
        XCTAssertTrue(field.startSave())
        XCTAssertEqual(field.finishRead(beforeSave, ssid: "Other Phone", password: "", notice: nil), .dropped, "a save began: no new read either")
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

        await SettingsView.loadForField(field.startLoad(ssid: edit.configured), secrets: store) {
            field.finishRead($0, ssid: edit.configured, password: $1.password, notice: $1.notice)
        }

        XCTAssertEqual(field.password, "new")
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

        await SettingsView.loadForField(field.startLoad(ssid: edit.configured), secrets: store) {
            field.finishRead($0, ssid: edit.configured, password: $1.password, notice: $1.notice)
        }

        XCTAssertEqual(field.password, "old")
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
        let report = HotspotPasswordReport(ssid: "Phone", problem: .unreadable)
        func recheck() async -> (password: String, notice: String?) {
            ("", await SettingsView.hotspotNotice(reported: report, ssid: edit.configured, reread: store.peek))
        }

        await SettingsView.readForField(
            field.startRead(ssid: edit.configured),
            first: {
                let answer = await recheck()
                edit.configured = "Other Phone"
                return answer
            },
            again: { await recheck() },
            finish: { field.finishRead($0, ssid: edit.configured, password: $1.password, notice: $1.notice) }
        )

        XCTAssertNil(field.notice)
        XCTAssertEqual(edit.reads, ["Other Phone"])
    }

    /// The window is still loading the saved password when the user types
    /// in the field and empties it again. The load's answer does not
    /// refill it: the user emptied it, and a Return would then save the
    /// old password instead of clearing it. Its notice still applies.
    func testALoadDoesNotFillAFieldEditedWhileItWaited() {
        var field = HotspotPasswordField()
        let load = field.startLoad(ssid: "Phone")
        field.edit("n")
        field.edit("")

        XCTAssertEqual(field.finishRead(load, ssid: "Phone", password: "old", notice: "about Phone"), .used)
        XCTAssertEqual(field.password, "")
        XCTAssertEqual(field.notice, "about Phone")

        let unchanged = field.startLoad(ssid: "Phone")
        field.edit("")
        XCTAssertEqual(field.finishRead(unchanged, ssid: "Phone", password: "old", notice: nil), .used)
        XCTAssertEqual(field.password, "old", "setting the text it already had is not an edit")
    }

    /// The user types while the load waits. The draft stays, but the load
    /// still records the saved password, so the status does not say it is
    /// missing and Save lights up for the draft.
    func testALoadRecordsTheSavedPasswordUnderAnEditedField() {
        var field = HotspotPasswordField()
        let load = field.startLoad(ssid: "Phone")
        field.edit("draft")
        XCTAssertEqual(field.finishRead(load, ssid: "Phone", password: "pw", notice: nil), .used)
        XCTAssertEqual(field.password, "draft")
        XCTAssertTrue(field.hasSavedPassword(ssid: "Phone"))
        XCTAssertFalse(field.isSaved(ssid: "Phone"))
        field.edit("pw")
        XCTAssertTrue(field.isSaved(ssid: "Phone"), "typing the saved password back needs no save")

        // A load that read before a save began records nothing: the save
        // may have replaced what it found.
        var saving = HotspotPasswordField()
        let early = saving.startLoad(ssid: "Phone")
        saving.edit("new")
        XCTAssertTrue(saving.startSave())
        _ = saving.finishRead(early, ssid: "Phone", password: "pw", notice: nil)
        XCTAssertFalse(saving.hasSavedPassword(ssid: "Phone"))
    }

    /// A field that already held text when the load began keeps it.
    func testALoadDoesNotReplaceTextTheFieldHeldWhenItBegan() {
        var field = HotspotPasswordField()
        field.edit("typed")
        let load = field.startLoad(ssid: "Phone")

        _ = field.finishRead(load, ssid: "Phone", password: "old", notice: nil)

        XCTAssertEqual(field.password, "typed")
    }

    /// The failover's report changes, or the SSID is edited, while the
    /// window loads the password: the recheck that starts is newer and
    /// sets the notice, but the load still fills the field, with the
    /// password of the SSID configured when it answers. An edit after the
    /// SSID edit, while the second read waits, still stops the fill.
    func testARecheckDoesNotStopTheLoadFillingTheField() {
        var field = HotspotPasswordField()
        let load = field.startLoad(ssid: "Phone")
        let recheck = field.startRead(ssid: "Phone")
        XCTAssertEqual(field.finishRead(recheck, ssid: "Phone", password: "", notice: "recheck"), .used)
        XCTAssertEqual(field.finishRead(load, ssid: "Phone", password: "old", notice: "load"), .used)
        XCTAssertEqual(field.password, "old")
        XCTAssertEqual(field.notice, "recheck", "the older load does not set the notice")

        var edited = HotspotPasswordField()
        let overtaken = edited.startLoad(ssid: "Phone")
        let newer = edited.startRead(ssid: "Other Phone")
        guard case let .readAgain(next) = edited.finishRead(overtaken, ssid: "Other Phone", password: "old", notice: nil) else {
            return XCTFail("the overtaken load was dropped before it could fill the field")
        }
        XCTAssertEqual(edited.finishRead(newer, ssid: "Other Phone", password: "", notice: "about Other Phone"), .used)
        XCTAssertEqual(edited.finishRead(next, ssid: "Other Phone", password: "new", notice: "stale"), .used)
        XCTAssertEqual(edited.password, "new")
        XCTAssertEqual(edited.notice, "about Other Phone")

        var typed = HotspotPasswordField()
        let first = typed.startLoad(ssid: "Phone")
        guard case let .readAgain(second) = typed.finishRead(first, ssid: "Other Phone", password: "old", notice: nil) else {
            return XCTFail("a load for an SSID edited away was not read again")
        }
        typed.edit("x")
        typed.edit("")
        XCTAssertEqual(typed.finishRead(second, ssid: "Other Phone", password: "new", notice: nil), .used)
        XCTAssertEqual(typed.password, "")
    }

    /// The SSID is edited while a save waits on the keychain. The recheck
    /// that edit started read behind the save and is dropped, and the save
    /// stored for the old SSID: the save's answer starts a recheck for the
    /// SSID configured now, so the notice is not left blank for it. A
    /// failed save keeps its failure instead.
    func testASaveForAnSSIDEditedAwayRechecksTheNewSSID() {
        var field = HotspotPasswordField()
        _ = field.startSave()
        let dropped = field.startRead(ssid: "Other Phone")
        guard let recheck = field.finishSave(stored, ssid: "Other Phone") else {
            return XCTFail("no recheck for the SSID configured now")
        }
        XCTAssertEqual(field.finishRead(dropped, ssid: "Other Phone", password: "", notice: "dropped"), .dropped)
        XCTAssertEqual(recheck.ssid, "Other Phone")
        XCTAssertEqual(field.finishRead(recheck, ssid: "Other Phone", password: "", notice: "about Other Phone"), .used)
        XCTAssertEqual(field.notice, "about Other Phone")

        _ = field.startSave()
        XCTAssertNil(field.finishSave(stored, ssid: " Phone "))
        _ = field.startSave()
        XCTAssertNil(field.finishSave(refused, ssid: "Other Phone"))
        XCTAssertEqual(field.notice, refused.notice)
    }

    /// A report applies to the hotspot it was read for, and a save leaves
    /// only a report about the configured hotspot whose item it neither
    /// stored nor removed.
    func testAReportIsAboutTheHotspotItWasReadFor() {
        let report = HotspotPasswordReport(ssid: "Phone", problem: .unreadable)
        XCTAssertEqual(report.problem(for: " Phone\n"), .unreadable)
        XCTAssertNil(report.problem(for: "Other Phone"))
        XCTAssertNil(report.problem(for: ""))

        XCTAssertTrue(report.stands(after: .init(ssid: "Other Phone"), configuredSSID: " Phone "))
        XCTAssertTrue(report.stands(after: .init(ssid: "Other Phone", removed: "Third Phone"), configuredSSID: "Phone"))
        XCTAssertFalse(report.stands(after: .init(ssid: "Other Phone", removed: "Phone"), configuredSSID: "Phone"), "the save removed its item")
        XCTAssertFalse(report.stands(after: .init(ssid: "Phone"), configuredSSID: "Phone"))
        XCTAssertFalse(report.stands(after: .init(ssid: "Phone"), configuredSSID: "Other Phone"))
        XCTAssertFalse(report.stands(after: .init(ssid: "Other Phone"), configuredSSID: "Other Phone"))
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
        XCTAssertEqual(field.finishRead(second, ssid: "Phone", password: "", notice: "second"), .used)
        XCTAssertEqual(field.finishRead(first, ssid: "Phone", password: "", notice: "first"), .dropped)
        XCTAssertEqual(field.notice, "second")

        _ = field.startSave()
        field.finishSave(stored, ssid: "Phone")
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

/// The hotspot section's one Save button: the name to config.json, then
/// the password to the keychain under that name.
@MainActor
final class HotspotSaveTests: XCTestCase {
    /// Answers at once from memory.
    private final class MemoryKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String]
        init(items: [String: String] = [:]) { self.items = items }
        var all: [String: String] { lock.withLock { items } }
        func get(service: String, account: String) throws -> String? { lock.withLock { items["\(service)/\(account)"] } }
        func set(service: String, account: String, value: String) throws { lock.withLock { items["\(service)/\(account)"] = value } }
        func delete(service: String, account: String) throws { _ = lock.withLock { items.removeValue(forKey: "\(service)/\(account)") } }
    }

    private func loaded(_ password: String, for ssid: String) -> HotspotPasswordField {
        var field = HotspotPasswordField()
        let load = field.startLoad(ssid: ssid)
        _ = field.finishRead(load, ssid: ssid, password: password, notice: nil)
        return field
    }

    func testSaveWritesOnlyWhatChanged() {
        let saved = loaded("pw", for: "Phone")
        XCTAssertNil(SettingsView.hotspotSave(ssidDraft: nil, savedSSID: "Phone", field: saved), "nothing to write")
        XCTAssertNil(SettingsView.hotspotSave(ssidDraft: "Phone", savedSSID: "Phone", field: saved), "the name typed back is no change")

        var edited = saved
        edited.edit("pw2")
        XCTAssertEqual(SettingsView.hotspotSave(ssidDraft: nil, savedSSID: "Phone", field: edited), .init(name: nil, storesPassword: true))

        XCTAssertEqual(SettingsView.hotspotSave(ssidDraft: "New Phone", savedSSID: "Phone", field: saved), .init(name: "New Phone", storesPassword: true),
                       "a new name has no password yet, so the saved one is stored under it")

        var cleared = saved
        cleared.edit("")
        XCTAssertEqual(SettingsView.hotspotSave(ssidDraft: nil, savedSSID: "Phone", field: cleared), .init(name: nil, storesPassword: true), "an empty field clears")

        var waiting = edited
        XCTAssertTrue(waiting.startSave())
        XCTAssertNil(SettingsView.hotspotSave(ssidDraft: "New Phone", savedSSID: "Phone", field: waiting), "one save at a time")
    }

    /// What a Save press reads and writes: config.json's hotspot name, the
    /// field, and the Location prompts it asked for.
    @MainActor
    private final class SaveRig {
        var config = Config()
        var field = HotspotPasswordField()
        var configWrites = 0
        var locationRequests = 0
        let keychain: MemoryKeychain
        lazy var store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { [unowned self] in self.config.hotspotSSID }

        init(ssid: String, keychain: [String: String]) {
            config.hotspotSSID = ssid
            self.keychain = MemoryKeychain(items: keychain)
        }

        /// The window opens: the field loads what the keychain holds.
        func load() async throws {
            let read = field.startLoad(ssid: config.hotspotSSID)
            let password = try await store.load() ?? ""
            _ = field.finishRead(read, ssid: config.hotspotSSID, password: password, notice: nil)
        }

        /// Save is pressed, as the view presses it.
        func save(ssidDraft: String?) -> SettingsView.HotspotSaveRun? {
            SettingsView.runHotspotSave(
                ssidDraft: ssidDraft,
                field: (get: { self.field }, set: { self.field = $0 }),
                configuredSSID: { self.config.hotspotSSID },
                writeSSID: { self.config.hotspotSSID = $0; self.configWrites += 1 },
                requestLocation: { self.locationRequests += 1 },
                secrets: store,
                services: nil
            )
        }
    }

    private static let service = KeychainStore.service

    /// A new name with the loaded password: config.json takes the name,
    /// the keychain then holds the password under it, the old name's item
    /// goes, and the field counts as saved for the new name.
    func testANewNameMovesTheSavedPasswordToIt() async throws {
        let rig = SaveRig(ssid: "Phone", keychain: ["\(Self.service)/Phone": "pw"])
        try await rig.load()

        let run = try XCTUnwrap(rig.save(ssidDraft: "New Phone"))
        XCTAssertEqual(rig.config.hotspotSSID, "New Phone", "the name is written before the password")
        XCTAssertTrue(rig.field.saving, "Save shows Saving\u{2026} while the keychain answers")
        XCTAssertNil(rig.save(ssidDraft: nil), "one save at a time")
        let recheck = try await XCTUnwrap(run.passwordSave).value

        XCTAssertNil(recheck)
        XCTAssertFalse(rig.field.saving)
        XCTAssertEqual(rig.configWrites, 1)
        XCTAssertEqual(rig.locationRequests, 1)
        XCTAssertEqual(rig.keychain.all, ["\(Self.service)/New Phone": "pw"])
        XCTAssertTrue(rig.field.isSaved(ssid: "New Phone"))
        XCTAssertNil(rig.field.notice)
        XCTAssertNil(rig.save(ssidDraft: nil), "Save goes dark again")
    }

    /// A new password under the same name: config.json is left alone and
    /// the keychain item is replaced.
    func testANewPasswordReplacesTheSavedOne() async throws {
        let rig = SaveRig(ssid: "Phone", keychain: ["\(Self.service)/Phone": "pw"])
        try await rig.load()
        rig.field.edit("pw2")

        let run = try XCTUnwrap(rig.save(ssidDraft: nil))
        _ = await run.passwordSave?.value

        XCTAssertEqual(rig.configWrites, 0)
        XCTAssertEqual(rig.keychain.all, ["\(Self.service)/Phone": "pw2"])
        XCTAssertTrue(rig.field.hasSavedPassword(ssid: "Phone"))
        XCTAssertTrue(rig.field.isSaved(ssid: "Phone"))
    }

    /// An emptied field clears the saved password, and the status then
    /// says it is missing.
    func testAnEmptiedFieldClearsTheSavedPassword() async throws {
        let rig = SaveRig(ssid: "Phone", keychain: ["\(Self.service)/Phone": "pw"])
        try await rig.load()
        rig.field.edit("")

        let run = try XCTUnwrap(rig.save(ssidDraft: nil))
        _ = await run.passwordSave?.value

        XCTAssertEqual(rig.keychain.all, [:])
        XCTAssertFalse(rig.field.hasSavedPassword(ssid: "Phone"))
        XCTAssertTrue(rig.field.isSaved(ssid: "Phone"))
    }

    /// Nothing changed: Save writes nothing and asks for nothing.
    func testSaveWithNothingChangedDoesNothing() async throws {
        let rig = SaveRig(ssid: "Phone", keychain: ["\(Self.service)/Phone": "pw"])
        try await rig.load()

        XCTAssertNil(rig.save(ssidDraft: "Phone"))
        XCTAssertEqual(rig.configWrites, 0)
        XCTAssertEqual(rig.locationRequests, 0)
        XCTAssertEqual(rig.keychain.all, ["\(Self.service)/Phone": "pw"])
    }

    /// The status reads the saved password: typing one does not turn
    /// failover on until Save stores it.
    func testATypedPasswordIsNotOnUntilSaved() {
        var field = HotspotPasswordField()
        field.edit("pw")
        XCTAssertFalse(field.hasSavedPassword(ssid: "Phone"))
        XCTAssertEqual(HotspotSetupStatus.of(ssid: "Phone", passwordEntered: field.hasSavedPassword(ssid: "Phone"), passwordNotice: nil, locationAuthorized: true).level, .incomplete)
        XCTAssertTrue(field.startSave())
        XCTAssertNil(field.finishSave(.stored(.init(ssid: "Phone", password: "pw")), ssid: "Phone"))
        XCTAssertTrue(field.hasSavedPassword(ssid: "Phone"))
        XCTAssertTrue(field.hasSavedPassword(ssid: " Phone "))
        XCTAssertFalse(field.hasSavedPassword(ssid: "Other Phone"))
        field.edit("draft")
        XCTAssertTrue(field.hasSavedPassword(ssid: "Phone"), "an unsaved edit leaves the saved password in place")
        XCTAssertFalse(loaded("", for: "Phone").hasSavedPassword(ssid: "Phone"), "an empty load is no password")
    }
}
