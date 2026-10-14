import XCTest
@testable import Insomnia

/// Pure `StatusMenu.items` / `StatusMenu.rows` checks that need no status
/// item. The popover's other row tests live in UIStatusTests beside the
/// status item tests; these are kept apart so they can run anywhere.
@MainActor
final class StatusMenuWarningTests: XCTestCase {
    /// A restore that failed and a SleepDisabled bit someone else set can
    /// come out of the same reconcile. Each gets its own warning row, the
    /// error first.
    func testForeignSleepLineIsShownBesideTheLastError() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            throttledBrowsers: [],
            error: "could not clear low power mode: sudo: a password is required",
            foreignSleep: SessionManager.foreignSleepLine
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "could not clear low power mode: sudo: a password is required", kind: .warning),
            StatusMenu.Item(title: SessionManager.foreignSleepLine, kind: .warning),
        ])
    }

    func testForeignSleepLineAloneIsAWarning() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            throttledBrowsers: [],
            error: nil,
            foreignSleep: SessionManager.foreignSleepLine
        )
        XCTAssertEqual(items, [StatusMenu.Item(title: SessionManager.foreignSleepLine, kind: .warning)])
    }

    /// The hotspot password line, the session error and the foreign-sleep
    /// line can all be up at once. Each keeps its own row, in that order,
    /// and none carries a typed warning sign: the row draws the triangle.
    func testHotspotErrorAndForeignSleepLinesKeepTheirOrder() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            throttledBrowsers: [],
            hotspotWarning: HotspotPasswordProblem.unreadable.menuLine,
            error: "sudo: a password is required",
            foreignSleep: SessionManager.foreignSleepLine
        )
        XCTAssertEqual(items.map(\.kind), [.warning, .warning, .warning])
        XCTAssertEqual(items.map(\.title), [
            HotspotPasswordProblem.unreadable.menuLine,
            "sudo: a password is required",
            SessionManager.foreignSleepLine,
        ])
        XCTAssertFalse(items.contains { $0.title.contains("\u{26A0}") })
    }

    func testBlankForeignSleepLineIsDropped() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            throttledBrowsers: [],
            error: nil,
            foreignSleep: " "
        )
        XCTAssertEqual(items, [])
    }

    /// The sudo pmset left running has its own row, above an unrelated
    /// error, so its exit can remove it and leave the error in place.
    func testCommandLineIsShownAboveTheLastError() {
        let command = "`/usr/bin/sudo -n /usr/bin/pmset lowpowermode 1` (pid 4242) did not stop on SIGTERM; Insomnia holds the recovery lock and will not quit until it exits (sudo kill 4242 to stop it by hand)"
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            throttledBrowsers: [],
            error: "could not remove session.json: permission denied",
            commandRunning: command
        )
        XCTAssertEqual(items.map(\.title), [command, "could not remove session.json: permission denied"])
        XCTAssertEqual(items.map(\.kind), [.warning, .warning])

        let afterExit = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            throttledBrowsers: [],
            error: "could not remove session.json: permission denied",
            commandRunning: nil
        )
        XCTAssertEqual(afterExit, [StatusMenu.Item(title: "could not remove session.json: permission denied", kind: .warning)])
    }

    /// The relaunch button holds the browser itself, not just its name, so
    /// the click hands on the bundle id the row was built with; it is drawn
    /// on the throttle warning's row.
    func testTheRelaunchButtonCarriesTheBundleIDAndNameOnTheWarningRow() throws {
        let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, throttledBrowsers: [arc], error: nil)
        let rows = StatusMenu.rows(items)
        let throttle = try XCTUnwrap(StatusLines.throttleWarning(["Arc"]))
        let row = try XCTUnwrap(rows.first { $0.item.title == throttle })
        XCTAssertEqual(row.item.kind, .warning)
        XCTAssertEqual(row.actions, [StatusMenu.Item(title: "Relaunch Arc unthrottled", kind: .relaunchBrowser(arc))])
        XCTAssertFalse(rows.contains { $0.item.kind.isAction }, "no action is a row of its own")
    }

    /// Each output device still muted from a lid close gets a warning row
    /// with a button that carries the save the row showed, its save ID
    /// included, so the click drops that save and no later one.
    func testEachWaitingOutputHasARowWithAStopWaitingButton() {
        let headset = SavedAudioOutput(deviceUID: "usb-headset", name: "USB Headset", volume: 0.3, muted: false, saveID: "save-2")
        let unnamed = SavedAudioOutput(deviceUID: "70-8C-F2:output", name: nil, volume: 0.5, muted: false, saveID: nil)
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: nil, outputsWaiting: [headset, unnamed])
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "USB Headset is still muted from a lid close; Insomnia restores it when it reconnects", kind: .warning),
            StatusMenu.Item(title: "Stop waiting for USB Headset", kind: .stopWaitingForOutput(headset)),
            StatusMenu.Item(title: "70-8C-F2:output is still muted from a lid close; Insomnia restores it when it reconnects", kind: .warning),
            StatusMenu.Item(title: "Stop waiting for 70-8C-F2:output", kind: .stopWaitingForOutput(unnamed)),
        ])
        XCTAssertEqual(StatusMenu.rows(items), [
            StatusMenu.Row(item: items[0], actions: [items[1]]),
            StatusMenu.Row(item: items[2], actions: [items[3]]),
        ])
    }

    /// The reasons relaunches stopped short, one row per browser, follow
    /// the browser row and come before the session error. They are shown
    /// with no throttled browser left too: a browser that quit and did not
    /// open again is in no browser row.
    func testTheRelaunchProblemsFollowTheBrowserLines() throws {
        let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")
        let problem = "Arc did not quit within 10 s, so nothing was relaunched."
        let other = "Chrome quit but could not be relaunched: boom. Open it yourself."
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, throttledBrowsers: [arc], relaunchProblems: [problem, other], error: "restore failed")
        let throttle = try XCTUnwrap(StatusLines.throttleWarning(["Arc"]))
        XCTAssertEqual(items.map(\.title).filter { $0.contains("Arc") || $0.contains("Chrome") || $0.contains("restore") }, [
            throttle,
            "Relaunch Arc unthrottled",
            problem,
            other,
            "restore failed",
        ])

        let closed = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], relaunchProblems: [problem], error: nil)
        XCTAssertEqual(closed, [StatusMenu.Item(title: problem, kind: .warning)])
    }

    /// An action with nothing before it still gets drawn, as a row of its own.
    func testAnActionWithNoRowBeforeItIsARowOfItsOwn() {
        let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")
        let lone = StatusMenu.Item(title: "Relaunch Arc unthrottled", kind: .relaunchBrowser(arc))
        XCTAssertEqual(StatusMenu.rows([lone]), [StatusMenu.Row(item: lone, actions: [])])
        XCTAssertEqual(StatusMenu.rows([]), [])
    }
    /// A refused start is said once: under the fields. The manager's
    /// lastError is the same text, so its warning row is left out while
    /// that start error shows, and comes back when it does not.
    func testTheStartErrorShownUnderTheFieldsIsNotRepeatedAsARow() {
        let error = "could not arm backstop: backstop.sh is not sealed in the app bundle at /x/Insomnia.app/Contents/Resources/backstop.sh; run scripts/install.sh"
        XCTAssertEqual(StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: error, shownStartError: error), [])
        XCTAssertEqual(StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: error, shownStartError: nil), [
            StatusMenu.Item(title: error, kind: .warning),
        ])
        // A different error is its own row even while a start error shows.
        XCTAssertEqual(
            StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "restore failed", shownStartError: error).map(\.title),
            ["restore failed"]
        )
    }

    /// Raw errors with paths read as one short line; the original is kept
    /// for the tooltip and the expanded row, and is not changed.
    func testKnownErrorsReadAsAShortHumanLine() {
        let sealed = "could not arm backstop: backstop.sh is not sealed in the app bundle at /Users/me/Applications/Insomnia.app/Contents/Resources/backstop.sh; run scripts/install.sh"
        XCTAssertEqual(ErrorSummary.summarize(sealed), ErrorSummary.Summary(
            short: "Couldn\u{2019}t arm the recovery backstop. Reinstall with scripts/install.sh.",
            full: sealed
        ))
        XCTAssertEqual(
            ErrorSummary.summarize("could not clear low power mode: sudo: a password is required").short,
            "Couldn\u{2019}t turn Low Power Mode back off. sudo asked for a password."
        )
        XCTAssertEqual(ErrorSummary.summarize("could not confirm backstop: fake launchd refused").short, "Couldn\u{2019}t confirm the recovery backstop.")
        // The longer of two matching prefixes wins.
        XCTAssertEqual(
            ErrorSummary.summarize("start refused, nothing changed: session.json could not be read").short,
            "Couldn\u{2019}t start: the saved session can\u{2019}t be read."
        )
    }

    /// Anything else keeps its first sentence, cut to about two lines; the
    /// full text only rides along when something was left out.
    func testUnknownErrorsKeepTheirFirstSentence() {
        XCTAssertEqual(ErrorSummary.summarize("Chrome is throttled"), ErrorSummary.Summary(short: "Chrome is throttled", full: nil))
        let two = "Arc did not quit within 10 s. Nothing was relaunched."
        XCTAssertEqual(ErrorSummary.summarize(two), ErrorSummary.Summary(short: "Arc did not quit within 10 s.", full: two))
        let long = String(repeating: "word ", count: 60)
        let summary = ErrorSummary.summarize(long)
        XCTAssertLessThanOrEqual(summary.short.count, ErrorSummary.maxLength)
        XCTAssertTrue(summary.short.hasSuffix("\u{2026}"))
        XCTAssertEqual(summary.full, long.trimmingCharacters(in: .whitespaces))
    }
}
