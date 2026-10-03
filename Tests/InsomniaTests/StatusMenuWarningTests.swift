import XCTest
@testable import Insomnia

/// Pure `StatusMenu.items` checks that need no status item. The menu's
/// other model tests live in UIStatusTests beside the status item tests;
/// these are kept apart so they can run anywhere.
@MainActor
final class StatusMenuWarningTests: XCTestCase {
    /// A restore that failed and a SleepDisabled bit someone else set can
    /// come out of the same reconcile. Each gets its own warning line, the
    /// error first.
    func testForeignSleepLineIsShownBesideTheLastError() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: "could not clear low power mode: sudo: a password is required",
            foreignSleep: SessionManager.foreignSleepLine
        )
        XCTAssertEqual(items.map(\.kind), [.warning, .warning, .separator, .settings, .quit])
        XCTAssertEqual(items[0].title, "\u{26A0} could not clear low power mode: sudo: a password is required")
        XCTAssertEqual(items[1].title, "\u{26A0} \(SessionManager.foreignSleepLine)")
    }

    func testForeignSleepLineAloneIsAWarning() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: nil,
            foreignSleep: SessionManager.foreignSleepLine
        )
        XCTAssertEqual(items.map(\.kind), [.warning, .separator, .settings, .quit])
        XCTAssertEqual(items[0].title, "\u{26A0} \(SessionManager.foreignSleepLine)")
    }

    func testBlankForeignSleepLineIsDropped() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: nil,
            foreignSleep: " "
        )
        XCTAssertEqual(items.map(\.kind), [.settings, .quit])
    }

    /// The relaunch entry holds the browser itself, not just its name, so
    /// the click hands on the bundle id the menu was built with. Builds the
    /// NSMenu only; nothing is shown.
    func testTheRelaunchEntryCarriesTheBundleIDAndName() {
        let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, machine: nil, actions: nil, throttledBrowsers: [arc], error: nil)
        let menu = StatusMenu.menu(
            items,
            target: nil,
            settings: #selector(NSObject.description),
            quit: #selector(NSObject.description),
            relaunchBrowser: #selector(NSObject.description)
        )
        let entry = menu.items.first { $0.title == "Relaunch Arc unthrottled" }
        XCTAssertEqual(entry?.representedObject as? ThrottledBrowser, arc)
    }
}
