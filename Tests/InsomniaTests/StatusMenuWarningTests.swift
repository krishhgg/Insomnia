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

    /// The hotspot password line, the session error and the foreign-sleep
    /// line can all be up at once. Each keeps its own line, in that order.
    func testHotspotErrorAndForeignSleepLinesKeepTheirOrder() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            hotspotWarning: HotspotPasswordProblem.unreadable.menuLine,
            error: "sudo: a password is required",
            foreignSleep: SessionManager.foreignSleepLine
        )
        XCTAssertEqual(items.map(\.kind), [.warning, .warning, .warning, .separator, .settings, .quit])
        XCTAssertEqual(items.prefix(3).map(\.title), [
            HotspotPasswordProblem.unreadable.menuLine,
            "\u{26A0} sudo: a password is required",
            "\u{26A0} \(SessionManager.foreignSleepLine)",
        ])
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
}
