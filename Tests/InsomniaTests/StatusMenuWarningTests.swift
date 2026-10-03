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

    /// The sudo pmset left running has its own line, above an unrelated
    /// error, so its exit can remove it and leave the error in place.
    func testCommandLineIsShownAboveTheLastError() {
        let command = "`/usr/bin/sudo -n /usr/bin/pmset lowpowermode 1` (pid 4242) did not stop on SIGTERM; Insomnia holds the recovery lock and will not quit until it exits (sudo kill 4242 to stop it by hand)"
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: "could not remove session.json: permission denied",
            commandRunning: command
        )
        XCTAssertEqual(items.map(\.kind), [.warning, .warning, .separator, .settings, .quit])
        XCTAssertEqual(items[0].title, "\u{26A0} \(command)")
        XCTAssertEqual(items[1].title, "\u{26A0} could not remove session.json: permission denied")

        let afterExit = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            actions: nil,
            throttledBrowsers: [],
            error: "could not remove session.json: permission denied",
            commandRunning: nil
        )
        XCTAssertEqual(afterExit.map(\.kind), [.warning, .separator, .settings, .quit])
        XCTAssertEqual(afterExit[0].title, "\u{26A0} could not remove session.json: permission denied")
    }
}
