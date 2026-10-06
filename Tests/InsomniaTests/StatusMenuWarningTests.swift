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

    /// The reasons relaunches stopped short, one line per browser, follow
    /// the browser lines and come before the session error. They are shown
    /// with no throttled browser left too: a browser that quit and did not
    /// open again is in no browser line.
    func testTheRelaunchProblemsFollowTheBrowserLines() throws {
        let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")
        let problem = "Arc did not quit within 10 s, so nothing was relaunched."
        let other = "Chrome quit but could not be relaunched: boom. Open it yourself."
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, machine: nil, actions: nil, throttledBrowsers: [arc], relaunchProblems: [problem, other], error: "restore failed")
        let throttle = try XCTUnwrap(StatusLines.throttleWarning(["Arc"]))
        XCTAssertEqual(items.map(\.title).filter { $0.contains("Arc") || $0.contains("Chrome") || $0.contains("restore") }, [
            throttle,
            "Relaunch Arc unthrottled",
            "\u{26A0} \(problem)",
            "\u{26A0} \(other)",
            "\u{26A0} restore failed",
        ])

        let closed = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], relaunchProblems: [problem], error: nil)
        XCTAssertEqual(closed.filter { $0.kind == .warning }.map(\.title), ["\u{26A0} \(problem)"])
    }
}
