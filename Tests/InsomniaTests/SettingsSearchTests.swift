import XCTest
@testable import Insomnia

/// The Settings sidebar search and the hotspot status line.
final class SettingsSearchTests: XCTestCase {
    private func ids(_ query: String) -> [String] {
        SettingsSearch.results(for: query).map(\.id)
    }

    /// Pane names are sentence case, as the repository's writing rules ask.
    func testPaneNamesAreSentenceCase() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["General", "Sessions", "Lid close", "Agent apps", "Battery & thermal", "Network"])
    }

    func testAnEmptyQueryFindsNothing() {
        XCTAssertEqual(ids(""), [])
        XCTAssertEqual(ids("   "), [])
    }

    func testWordsMatchTheStartOfAWordIgnoringCaseAndHyphens() {
        XCTAssertEqual(ids("freez"), ["freezeList", "freezeAll", "agentList"])
        XCTAssertTrue(ids("wifi").contains("hotspot"))
        XCTAssertTrue(ids("WI-FI").contains("hotspot"))
        XCTAssertEqual(ids("eeze"), [])
    }

    func testEveryWordHasToMatch() {
        XCTAssertEqual(ids("low power lid"), ["lowPowerOnLidClose"])
        XCTAssertEqual(ids("battery end"), ["endFloor"])
    }

    func testKeywordsAndPaneTitlesFindSettings() {
        XCTAssertEqual(ids("microphone"), ["mute"])
        XCTAssertEqual(ids("keychain"), ["hotspotPassword"])
        XCTAssertEqual(Set(ids("thermal")), ["thermal", "lowPowerFloor", "endFloor"])
    }

    func testEveryEntryHasAUniqueIdAndAppearsInPaneOrder() {
        let all = SettingsSearch.entries
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        let order = all.map { SettingsPane.allCases.firstIndex(of: $0.pane)! }
        XCTAssertEqual(order, order.sorted())
    }

    /// Every entry names an anchor the pane really has, so a result never
    /// jumps to nothing.
    func testEveryEntryIsAnAnchorInSettingsView() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Insomnia/UI/SettingsView.swift"), encoding: .utf8)
        for entry in SettingsSearch.entries {
            XCTAssertTrue(source.contains("anchored(\"\(entry.id)\")"), entry.id)
        }
    }

    /// Text moved into an ⓘ popover is still found by the search.
    func testWordsOnlyInAnInfoPopoverFindTheirSetting() {
        XCTAssertEqual(ids("tailscale"), ["freezeList", "agentList"])
        XCTAssertEqual(ids("reinstall"), ["hotspotPassword"])
        XCTAssertEqual(ids("brightness-up"), ["darken"])
        XCTAssertEqual(ids("any gap"), ["nudge"])
    }

    /// Every ⓘ in Settings names an entry that has text for it, so no
    /// popover opens empty and its words are searchable.
    func testEveryInfoButtonHasHelpOnItsEntry() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Insomnia/UI/SettingsView.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"(?:InfoButton\(for|info): "([^"]+)""#)
        let ids = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        }
        XCTAssertFalse(ids.isEmpty)
        for id in ids {
            let help = try XCTUnwrap(SettingsSearch.entry(id)?.help, id)
            XCTAssertFalse(help.text.isEmpty, id)
            XCTAssertLessThanOrEqual(help.summary.count, 75, id)
        }
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
