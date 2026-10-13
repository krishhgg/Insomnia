import AppKit
import XCTest
@testable import Insomnia

@MainActor
final class StatusMenuGeometryTests: XCTestCase {
    func testStatusRowsFitWithoutReservingTheActionsShortcutColumn() throws {
        _ = NSApplication.shared
        let text = "Wi-Fi: on (name hidden until Location is allowed)"
        let items = [
            StatusMenu.Item(title: text, kind: .info),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ]
        let fitted = makeMenu(items)
        let native = NSMenu()
        let nativeStatus = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        nativeStatus.isEnabled = false
        nativeStatus.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
        ])
        native.addItem(nativeStatus)
        for (title, key) in [(StatusMenu.settingsTitle, ","), (StatusMenu.quitTitle, "q")] {
            let action = NSMenuItem(title: title, action: NSSelectorFromString("action"), keyEquivalent: key)
            action.keyEquivalentModifierMask = .command
            native.addItem(action)
        }
        XCTAssertLessThan(fitted.size.width, native.size.width - 20,
                          "Read-only status must not inherit the actions' empty shortcut column")
        let row = try XCTUnwrap(fitted.items[0].view as? StatusMenuLabel)
        XCTAssertEqual(row.label.stringValue, text)
        XCTAssertEqual(fitted.items[0].accessibilityLabel(), text)
        XCTAssertLessThanOrEqual(row.label.frame.maxX, row.bounds.maxX)
        XCTAssertFalse(fitted.items[0].isEnabled)
        XCTAssertNil(fitted.items[1].view)
        XCTAssertEqual(fitted.items[1].keyEquivalent, ",")
        XCTAssertEqual(fitted.items[2].keyEquivalent, "q")
        XCTAssertEqual(fitted.items[2].keyEquivalentModifierMask, .command)
    }

    func testWarningsKeepTheirCompleteTextAndSemanticColor() throws {
        _ = NSApplication.shared
        let warning = "⚠ Sleep is not held — this session is not keeping the Mac awake"
        let menu = makeMenu([StatusMenu.Item(title: warning, kind: .warning)])
        let row = try XCTUnwrap(menu.items[0].view as? StatusMenuLabel)
        XCTAssertEqual(row.label.stringValue, warning)
        XCTAssertEqual(row.label.textColor, .systemOrange)
        XCTAssertEqual(menu.items[0].accessibilityLabel(), warning)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertNil(menu.items[0].action)
    }

    private func makeMenu(_ items: [StatusMenu.Item]) -> NSMenu {
        StatusMenu.menu(items, target: nil,
                        settings: NSSelectorFromString("settings"), quit: NSSelectorFromString("quit"),
                        relaunchBrowser: NSSelectorFromString("relaunch:"),
                        stopWaitingForOutput: NSSelectorFromString("stopWaiting:"))
    }

}
