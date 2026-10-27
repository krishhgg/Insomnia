import XCTest
@testable import Insomnia
import Security

/// The popover's hotspot failover row: `HotspotSetupStatus` worded as a
/// status row, placed under the power row.
@MainActor
final class HotspotFailoverRowTests: XCTestCase {
    private func reading(_ ssid: String = "Phone", saved: Bool = true, notice: String? = nil) -> HotspotPasswordCheck.Reading {
        .init(ssid: ssid, saved: saved, notice: notice)
    }

    func testNoHotspotNameReadsOffWithoutAKeychainCheck() {
        let item = HotspotFailoverRow.item(ssid: "  ", password: nil, locationAuthorized: false)
        XCTAssertEqual(item?.title, "Hotspot failover off")
        XCTAssertEqual(item?.symbol, HotspotFailoverRow.symbol)
        XCTAssertEqual(item?.kind, .info)
    }

    func testAHotspotNotCheckedYetHasNoRow() {
        XCTAssertNil(HotspotFailoverRow.item(ssid: "Phone", password: nil, locationAuthorized: true))
    }

    func testEachSetupStateHasItsLine() {
        let ready = HotspotFailoverRow.item(ssid: "Phone", password: reading(), locationAuthorized: true)
        XCTAssertEqual(ready?.title, "Hotspot failover ready")
        XCTAssertEqual(ready?.help, "On. If Wi-Fi drops during a session, Insomnia joins \u{201C}Phone\u{201D}.")

        let noPassword = HotspotFailoverRow.item(ssid: "Phone", password: reading(saved: false), locationAuthorized: true)
        XCTAssertEqual(noPassword?.title, "Hotspot failover needs the password")
        XCTAssertEqual(noPassword?.help, "Save the password for \u{201C}Phone\u{201D} in Settings.")

        let noLocation = HotspotFailoverRow.item(ssid: "Phone", password: reading(), locationAuthorized: false)
        XCTAssertEqual(noLocation?.title, "Hotspot failover needs Location access")
    }

    /// A password this build can't read counts as missing, and the
    /// tooltip says why, as Settings does.
    func testAnUnreadablePasswordNeedsThePasswordAndSaysWhy() {
        let notice = HotspotPasswordProblem.unreadable.settingsNotice
        let item = HotspotFailoverRow.item(ssid: "Phone", password: reading(saved: false, notice: notice), locationAuthorized: true)
        XCTAssertEqual(item?.title, "Hotspot failover needs the password")
        XCTAssertEqual(item?.help, notice)
    }

    func testTheCheckReadsWithoutAPromptAndOnlyAnswersForItsSSID() async {
        let check = HotspotPasswordCheck()
        await check.refresh(ssid: " Phone ", peek: { "secret" })
        XCTAssertEqual(check.reading(for: "Phone"), reading())
        XCTAssertNil(check.reading(for: "Other"))

        await check.refresh(ssid: "Phone", peek: { nil })
        XCTAssertEqual(check.reading(for: "Phone"), reading(saved: false))

        await check.refresh(ssid: "Phone", peek: { throw KeychainError(status: errSecAuthFailed) })
        XCTAssertEqual(check.reading(for: "Phone"), reading(saved: false, notice: HotspotPasswordProblem.unreadable.settingsNotice))
    }

    func testTheRowSitsUnderThePowerRow() {
        let rows = StatusLines.machine(
            lidClosed: false,
            watts: 5,
            wifi: WiFiStatusName.Display(text: "Home", help: nil),
            batteryPercent: 60,
            isCharging: false,
            failover: HotspotFailoverRow.item(ssid: "", password: nil, locationAuthorized: true)
        )
        XCTAssertEqual(rows.map(\.symbol), ["laptopcomputer", "battery.75percent", HotspotFailoverRow.symbol, "wifi"])
    }

    /// The popover shows the row only with a check to read, and leaves it
    /// out while a warning about the hotspot password already says what
    /// is wrong.
    func testThePopoverRowFollowsTheCheckAndGivesWayToTheWarning() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.hotspotSSID = "Phone"
        let status = RecordingStatusSource()
        let check = HotspotPasswordCheck()
        await check.refresh(ssid: "Phone", peek: { nil })
        func failoverRows(_ check: HotspotPasswordCheck?) -> [String] {
            StatusItemController.statusItems(manager: manager, status: status, hotspotPassword: check)
                .filter { $0.symbol == HotspotFailoverRow.symbol }
                .map(\.title)
        }

        XCTAssertEqual(failoverRows(nil), [])
        XCTAssertEqual(failoverRows(check), ["Hotspot failover needs the password"])
        status.hotspotPasswordReport = HotspotPasswordReport(ssid: "Phone", problem: .missing)
        XCTAssertEqual(failoverRows(check), [])
    }

    func testHotspotStatusSaysOffUntilANameIsSet() {
        let off = HotspotSetupStatus.of(ssid: "  ", passwordEntered: true, passwordNotice: nil, locationAuthorized: true)
        XCTAssertEqual(off.level, .off)
        XCTAssertTrue(off.text.hasPrefix("Off."), off.text)
    }

    func testHotspotStatusNamesWhatIsMissing() {
        let noPassword = HotspotSetupStatus.of(ssid: " Phone ", passwordEntered: false, passwordNotice: nil, locationAuthorized: true)
        XCTAssertEqual(noPassword.level, .incomplete)
        XCTAssertEqual(noPassword.text, "Needs the password for \u{201C}Phone\u{201D}.")

        let unreadable = HotspotSetupStatus.of(ssid: "Phone", passwordEntered: false, passwordNotice: "enter it again", locationAuthorized: true)
        XCTAssertEqual(unreadable.level, .incomplete)

        let noLocation = HotspotSetupStatus.of(ssid: "Phone", passwordEntered: true, passwordNotice: nil, locationAuthorized: false)
        XCTAssertEqual(noLocation.text, "Needs Location access to find \u{201C}Phone\u{201D}.")
    }

    func testHotspotStatusIsOnWithANamePasswordAndLocation() {
        let ready = HotspotSetupStatus.of(ssid: "Phone", passwordEntered: true, passwordNotice: nil, locationAuthorized: true)
        XCTAssertEqual(ready.level, .ready)
        XCTAssertTrue(ready.text.hasPrefix("On."), ready.text)
    }
}
