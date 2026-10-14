import AppKit
import SwiftUI
import IOKit.ps
import XCTest
@testable import Insomnia

final class UIStatusTests: XCTestCase {
    /// Tests that open the popover must not leave it up for the next test.
    override func tearDown() {
        MainActor.assumeIsolated {
            for window in NSApp.windows where window.className.contains("Popover") && window.isVisible {
                window.orderOut(nil)
            }
        }
        super.tearDown()
    }

    @MainActor
    func testStatusHostUsesIntrinsicSizingAndHasAnIdleFittingSize() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let root = StatusRootView(model: MenuBarModel(), manager: harness.makeManager(), onWidthChange: { _ in })

        let host = StatusItemController.makeHostingView(root)

        XCTAssertTrue(host.sizingOptions.contains(.intrinsicContentSize))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The bar's host draws over the status bar button and must never take
    /// a click: the button under it toggles the popover.
    @MainActor
    func testTheBarHostLetsClicksThroughToTheButton() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let host = StatusItemController.makeHostingView(StatusRootView(model: MenuBarModel(), manager: harness.makeManager(), onWidthChange: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 22)
        XCTAssertNil(host.hitTest(NSPoint(x: 10, y: 10)))
    }

    /// The bar is the eye alone, idle or running: no countdown ever sits
    /// beside it, and typing in the popover's fields never reaches it.
    @MainActor
    func testTheBarIsTheEyeAloneAndKeepsOneWidthWhileASessionRuns() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        let model = MenuBarModel()
        func width() -> CGFloat {
            StatusItemController.makeHostingView(StatusRootView(model: model, manager: manager, onWidthChange: { _ in })).fittingSize.width
        }
        let idle = width()
        XCTAssertEqual(idle, 22, accuracy: 0.5, "the item hugs the eye, like the system's own icons")
        model.texts = [.days: "12", .hours: "3", .minutes: "45"]
        model.popoverShown = true
        XCTAssertEqual(width(), idle, accuracy: 0.001, "the fields live in the popover, not the bar")

        await manager.start(duration: 2 * 3600 + 31 * 60)
        model.phase = .running
        XCTAssertEqual(manager.remainingText, "2h 31m")
        XCTAssertEqual(width(), idle, accuracy: 0.001, "a running session changes the eye, not the width")

        model.phase = .starting
        XCTAssertEqual(width(), idle, accuracy: 0.001, "nor does a pending start")
    }

    /// The eye opens (and takes the accent) the moment a start is asked
    /// for, stays open while sleep is held, and closes otherwise.
    @MainActor
    func testTheEyeOpensForAPendingStartOrALiveSession() {
        XCTAssertFalse(StatusRootView.eyeOpen(isRunning: false, phase: .idle))
        XCTAssertTrue(StatusRootView.eyeOpen(isRunning: false, phase: .starting))
        XCTAssertTrue(StatusRootView.eyeOpen(isRunning: true, phase: .running))
        XCTAssertTrue(StatusRootView.eyeOpen(isRunning: true, phase: .idle), "a session started outside the UI still opens it")
        XCTAssertFalse(StatusRootView.eyeOpen(isRunning: false, phase: .running), "a phase lagging an ended session does not")
    }

    /// The projection's short form is the same minute-resolution text the
    /// manager's live one will read, so the swap does not jump.
    @MainActor
    func testTheShortProjectionMatchesTheLiveMinuteText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let month: TimeInterval = 30 * 24 * 3600
        let projection = MenuBarModel.projectedStart(now: now, duration: 2 * 3600 + 31 * 60, maxDuration: month)
        XCTAssertEqual(projection.shortCountdown(at: now), "2h 31m")
        XCTAssertEqual(projection.shortCountdown(at: now.addingTimeInterval(1)), "2h 30m")
        XCTAssertEqual(MenuBarModel.projectedStart(now: now, duration: 45 * 60, maxDuration: month).shortCountdown(at: now), "45m")
        XCTAssertEqual(MenuBarModel.projectedStart(now: now, duration: 86400, maxDuration: month).shortCountdown(at: now), "1d")
    }

    // MARK: Popover header

    @MainActor
    func testThePopoverHeaderSaysWhatIsHappeningInOneLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 0))!
        XCTAssertEqual(
            StatusPopoverView.headerText(phase: .idle, session: nil, remaining: "", now: now, calendar: calendar),
            "Not keeping your Mac awake"
        )
        XCTAssertEqual(
            StatusPopoverView.headerText(phase: .starting, session: nil, remaining: "", now: now, calendar: calendar),
            MenuBarModel.startingText
        )
        let today = Session(startedAt: now, endsAt: now.addingTimeInterval(2 * 3600 + 31 * 60))
        let line = StatusPopoverView.headerText(phase: .running, session: today, remaining: "2h 31m", now: now, calendar: calendar)
        XCTAssertTrue(line.hasPrefix("Awake until "), line)
        XCTAssertTrue(line.hasSuffix(", 2h 31m left"), line)
        XCTAssertTrue(line.contains(today.endsAt.formatted(.dateTime.hour().minute())), line)
        // A deadline on another day names the day too.
        let tomorrow = Session(startedAt: now, endsAt: now.addingTimeInterval(26 * 3600))
        let later = StatusPopoverView.headerText(phase: .running, session: tomorrow, remaining: "1d 2h", now: now, calendar: calendar)
        XCTAssertTrue(later.contains(tomorrow.endsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())), later)
    }

    // MARK: Status rows

    func testMachineRows() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: true, watts: 4.12, wifi: WiFiStatusName.Display(text: "iPhone", help: nil), batteryPercent: nil, isCharging: false),
            [
                StatusMenu.Item(title: "Lid closed", kind: .info, symbol: "laptopcomputer"),
                StatusMenu.Item(title: "4.1 W", kind: .info, symbol: "bolt"),
                StatusMenu.Item(title: "iPhone", kind: .info, symbol: "wifi"),
            ]
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifi: nil, batteryPercent: nil, isCharging: false),
            [StatusMenu.Item(title: "Lid open", kind: .info, symbol: "laptopcomputer")]
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: 51.4, wifi: nil, batteryPercent: 54, isCharging: true).map(\.title),
            ["Lid open", "54% \u{00B7} Charging 51 W"]
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifi: nil, batteryPercent: 82, isCharging: false).last,
            StatusMenu.Item(title: "82%", kind: .info, symbol: "battery.75percent")
        )
        // Plugged in at the charge limit: no "0.0 W", just on the adapter.
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: 0.0, wifi: nil, batteryPercent: 80, isCharging: true).last,
            StatusMenu.Item(title: "80% \u{00B7} On power adapter", kind: .info, symbol: "powerplug")
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: -0.3, wifi: nil, batteryPercent: 80, isCharging: true).last?.title,
            "80% \u{00B7} On power adapter"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: 0.2, wifi: nil, batteryPercent: 80, isCharging: false).last?.title,
            "80%", "on battery a tiny draw is just left out"
        )
        // Plugged in but draining: the adapter and the draw, never "Charging".
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: -5.62, wifi: nil, batteryPercent: 62, isCharging: true).last,
            StatusMenu.Item(title: "62% \u{00B7} On power adapter \u{00B7} 5.6 W", kind: .info, symbol: "powerplug")
        )
        // Discharging: no minus sign, the draw as it is.
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: -5.62, wifi: nil, batteryPercent: 48, isCharging: false).last?.title,
            "48% \u{00B7} 5.6 W"
        )
        // Location not allowed: "On", with the reason as the tooltip.
        let hidden = StatusLines.machine(lidClosed: false, watts: nil, wifi: WiFiStatusName.display(ssid: nil, locationAuthorized: false), batteryPercent: nil, isCharging: false)
        XCTAssertEqual(hidden.last, StatusMenu.Item(title: "On", kind: .info, symbol: "wifi", help: WiFiStatusName.hiddenHelp))
    }

    /// The battery's time, as the battery menu and Activity Monitor give
    /// it: left on battery, to full while charging, a word while the system
    /// is still estimating, and nothing on the adapter at rest.
    func testPowerRowShowsTheTimeRemaining() {
        func title(_ watts: Double?, _ percent: Int?, charging: Bool, _ time: BatteryTimeRemaining?) -> String? {
            StatusLines.machine(lidClosed: false, watts: watts, wifi: nil, batteryPercent: percent, isCharging: charging, timeRemaining: time).dropFirst().first?.title
        }
        XCTAssertEqual(title(-5.6, 48, charging: false, .untilEmpty(minutes: 152)), "48% \u{00B7} 5.6 W \u{00B7} 2:32 left")
        XCTAssertEqual(title(-12.3, 48, charging: false, .untilEmpty(minutes: 45)), "48% \u{00B7} 12 W \u{00B7} 0:45 left")
        XCTAssertEqual(title(-5.6, 48, charging: false, .calculating), "48% \u{00B7} 5.6 W \u{00B7} Calculating\u{2026}")
        XCTAssertEqual(title(27, 54, charging: true, .untilFull(minutes: 70)), "54% \u{00B7} Charging 27 W \u{00B7} 1:10 to full")
        XCTAssertEqual(title(27, 54, charging: true, .calculating), "54% \u{00B7} Charging 27 W \u{00B7} Calculating\u{2026}")
        XCTAssertEqual(title(0.1, 80, charging: true, .calculating), "80% \u{00B7} On power adapter", "no time at rest on the adapter")
        XCTAssertEqual(title(nil, 82, charging: false, .untilEmpty(minutes: 600)), "82% \u{00B7} 10:00 left")
        // A time for the other direction (stale across a plug change) is not shown.
        XCTAssertEqual(title(27, 54, charging: true, .untilEmpty(minutes: 100)), "54% \u{00B7} Charging 27 W")
    }

    /// The power source list's minutes become a time remaining: -1 while
    /// the system is estimating, 0 where there is no time to give.
    func testTimeRemainingFromThePowerSourceList() {
        func battery(_ state: String, charging: Bool, empty: Int, full: Int) -> [[String: Any]] {
            [[kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSPowerSourceStateKey: state, kIOPSIsChargingKey: charging,
              kIOPSTimeToEmptyKey: empty, kIOPSTimeToFullChargeKey: full]]
        }
        XCTAssertEqual(PowerMonitor.timeRemaining(sources: battery(kIOPSBatteryPowerValue, charging: false, empty: 152, full: 0)), .untilEmpty(minutes: 152))
        XCTAssertEqual(PowerMonitor.timeRemaining(sources: battery(kIOPSBatteryPowerValue, charging: false, empty: -1, full: 0)), .calculating)
        XCTAssertEqual(PowerMonitor.timeRemaining(sources: battery(kIOPSACPowerValue, charging: true, empty: 0, full: 70)), .untilFull(minutes: 70))
        XCTAssertEqual(PowerMonitor.timeRemaining(sources: battery(kIOPSACPowerValue, charging: true, empty: 0, full: -1)), .calculating)
        XCTAssertNil(PowerMonitor.timeRemaining(sources: battery(kIOPSACPowerValue, charging: false, empty: 0, full: 0)), "held or full")
        XCTAssertNil(PowerMonitor.timeRemaining(sources: []), "no battery")
    }

    func testActionRowsAppearOnlyWhenTheyApply() {
        XCTAssertEqual(StatusLines.actions(frozenCount: 0, dockerPaused: false, lastGap: nil), [])
        XCTAssertEqual(StatusLines.actions(frozenCount: 3, dockerPaused: true, lastGap: nil), [
            StatusMenu.Item(title: "3 apps frozen", kind: .info, symbol: "snowflake"),
            StatusMenu.Item(title: "Docker paused", kind: .info, symbol: "shippingbox"),
        ])
        XCTAssertEqual(StatusLines.actions(frozenCount: 1, dockerPaused: false, lastGap: 12.4).map(\.title), ["1 app frozen", "Last network gap 12s"])
        XCTAssertEqual(StatusLines.actions(frozenCount: 0, dockerPaused: true, lastGap: 0).map(\.title), ["Docker paused"])
    }

    func testThrottleWarning() {
        XCTAssertNil(StatusLines.throttleWarning([]))
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome"]), "Chrome is throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc"]), "Chrome and Arc are throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc", "Chromium"]), "Chrome, Arc, and Chromium are throttled")
    }

    /// Facts first (sleep held, the machine, what is held), then warnings,
    /// each relaunch button on the throttle warning's row. Settings and
    /// Quit are the footer, not rows.
    func testRowsListFactsThenWarningsWithTheirButtons() {
        let machine = StatusLines.machine(lidClosed: true, watts: nil, wifi: nil, batteryPercent: 82, isCharging: false)
        let actions = StatusLines.actions(frozenCount: 3, dockerPaused: false, lastGap: nil)
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: machine,
            actions: actions,
            throttledBrowsers: [Self.chrome],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Sleep held per journal \u{2014} not verified live", kind: .info, symbol: "moon.zzz"),
            StatusMenu.Item(title: "Lid closed", kind: .info, symbol: "laptopcomputer"),
            StatusMenu.Item(title: "82%", kind: .info, symbol: "battery.75percent"),
            StatusMenu.Item(title: "3 apps frozen", kind: .info, symbol: "snowflake"),
            StatusMenu.Item(title: "Chrome is throttled", kind: .warning),
            StatusMenu.Item(title: "Relaunch Chrome unthrottled", kind: .relaunchBrowser(Self.chrome)),
        ])
        let rows = StatusMenu.rows(items)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.last, StatusMenu.Row(item: items[4], actions: [items[5]]))
    }

    func testIdleRowsAreEmpty() {
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "")
        XCTAssertEqual(items, [])
        XCTAssertEqual(StatusMenu.rows(items), [])
    }

    func testRowsShowTheLastErrorAsAWarning() {
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "sudo: a password is required")
        XCTAssertEqual(items, [StatusMenu.Item(title: "sudo: a password is required", kind: .warning)])
    }

    /// A hotspot join skipped for want of a password is a warning row,
    /// between the browser row and the session error, so the failure is
    /// never silent.
    func testRowsShowTheHotspotPasswordProblemAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            throttledBrowsers: [Self.chrome],
            hotspotWarning: HotspotPasswordProblem.unreadable.menuLine,
            error: "sudo: a password is required"
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser(Self.chrome), .warning, .warning]
        )
        XCTAssertEqual(items[3], StatusMenu.Item(
            title: "Hotspot password unreadable by this build: enter it again in Settings",
            kind: .warning
        ))
        XCTAssertEqual(
            StatusMenu.items(sessionActive: false, sleepHeld: false, throttledBrowsers: [], hotspotWarning: nil, error: nil),
            []
        )
    }

    /// Greptile caught this as a regression once: a throttle warning with
    /// no way to act on it. Every throttled browser keeps its own button.
    func testEveryThrottledBrowserGetsItsOwnRelaunchButton() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            throttledBrowsers: [Self.chrome, Self.arc],
            error: nil
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser(Self.chrome), .relaunchBrowser(Self.arc)]
        )
        XCTAssertEqual(StatusMenu.rows(items).last?.actions.map(\.kind), [.relaunchBrowser(Self.chrome), .relaunchBrowser(Self.arc)])
    }

    // MARK: Popover

    /// One popover, toggled by the item: the first click opens it on fresh
    /// status and empty fields, the next closes it.
    @MainActor
    func testClickingTheItemTogglesOnePopover() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = CountingStatusSource()
        let controller = StatusItemController(manager: h.makeManager(), status: source, showSettings: {})
        controller.model.texts = [.hours: "3"]
        XCTAssertNil(controller.popover, "built on first open")

        controller.togglePopover()
        XCTAssertTrue(controller.model.popoverShown)
        XCTAssertEqual(controller.model.texts, [:], "a fresh open starts with empty fields")
        XCTAssertEqual(source.instant, 1, "the lid, the battery and the watts are read on open")
        XCTAssertEqual(source.onDemand, 1, "the scans are kicked off on open")
        let popover = controller.popover
        XCTAssertNotNil(popover)
        XCTAssertEqual(popover?.behavior, .applicationDefined, "the controller closes it, on a click outside or Esc")
        XCTAssertTrue(popover?.contentViewController is NSHostingController<StatusPopoverView>)

        controller.togglePopover()
        XCTAssertFalse(controller.model.popoverShown)
        controller.togglePopover()
        XCTAssertTrue(controller.model.popoverShown)
        XCTAssertTrue(controller.popover === popover, "the same popover every time")
        XCTAssertEqual(source.instant, 2)
        controller.closePopover()
        XCTAssertFalse(controller.model.popoverShown)
    }

    /// A controller whose popover hangs from a plain on-screen window: a
    /// status item in a test process may never be on screen, and a popover
    /// asked to hang from it then never shows.
    @MainActor
    private func anchoredController(_ h: Harness) -> (StatusItemController, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 120, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})
        controller.popoverAnchor = window.contentView
        return (controller, window)
    }

    /// Every click flips the popover at once, however fast they come: the
    /// popover on screen matches the model after each one, with no waiting.
    /// The bug this pins: the popover animated closed for about half a
    /// second, a show during that was put off, and a transient popover also
    /// closed itself on the item's own click, so fast clicks were swallowed
    /// and the popover fell out of step with them.
    @MainActor
    func testFastClicksEachFlipThePopoverAtOnce() {
        let h = Harness()
        defer { h.home.destroy() }
        let (controller, window) = anchoredController(h)
        defer { window.orderOut(nil) }
        for click in 1...21 {
            controller.togglePopover()
            let open = click % 2 == 1
            XCTAssertEqual(controller.model.popoverShown, open, "click \(click)")
            XCTAssertEqual(controller.popover?.isShown, open, "click \(click): on screen")
        }
        let popover = try! XCTUnwrap(controller.popover)
        XCTAssertEqual(popover.behavior, .applicationDefined, "closed by the controller only")
        XCTAssertFalse(popover.animates, "never animates closed")
        controller.closePopover()
        XCTAssertFalse(popover.isShown)
    }

    /// On current macOS a click on the item first reaches the app as a
    /// click outside it (a global mouse-down, the app resigning active),
    /// then as the item's action. The first must not close the popover, or
    /// the action reopens it and the click does nothing visible; a click
    /// anywhere else closes it.
    @MainActor
    func testOnlyAClickAwayFromTheItemClosesThePopover() {
        let h = Harness()
        defer { h.home.destroy() }
        let (controller, window) = anchoredController(h)
        defer { window.orderOut(nil) }
        controller.openPopover()
        controller.dismissUnlessOnItem(at: NSPoint(x: window.frame.midX, y: window.frame.midY))
        XCTAssertTrue(controller.model.popoverShown, "on the item: left to its action")
        controller.togglePopover()
        XCTAssertFalse(controller.model.popoverShown, "the item's action closes it")
        XCTAssertEqual(controller.popover?.isShown, false)

        controller.togglePopover()
        controller.dismissUnlessOnItem(at: NSPoint(x: window.frame.minX - 40, y: window.frame.midY))
        XCTAssertFalse(controller.model.popoverShown, "a click elsewhere closes it")
        XCTAssertEqual(controller.popover?.isShown, false)
    }

    /// A click in another of the app's windows (Settings) closes the
    /// popover; a click in the popover, or on the item (whose action
    /// toggles), does not.
    @MainActor
    func testAClickInAnotherWindowClosesThePopover() {
        let h = Harness()
        defer { h.home.destroy() }
        let (controller, window) = anchoredController(h)
        defer { window.orderOut(nil) }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        controller.openPopover()
        let popoverWindow = controller.popover?.contentViewController?.view.window
        XCTAssertNotNil(popoverWindow)
        controller.clickedInApp(window: popoverWindow)
        XCTAssertTrue(controller.model.popoverShown, "its own controls")
        controller.clickedInApp(window: window)
        XCTAssertTrue(controller.model.popoverShown, "the item: its action toggles")
        controller.clickedInApp(window: other)
        XCTAssertFalse(controller.model.popoverShown)
        XCTAssertEqual(controller.popover?.isShown, false)
    }

    /// The popover is a fixed width: a long warning wraps and makes it
    /// taller, never wider.
    @MainActor
    func testThePopoverIsAFixedWidthAndLongTextWraps() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = RecordingStatusSource()
        let controller = StatusItemController(manager: h.makeManager(), status: source, showSettings: {})
        func size() -> NSSize {
            NSHostingView(rootView: controller.makePopoverView()).fittingSize
        }
        let short = size()
        XCTAssertEqual(short.width, StatusPopoverView.width, accuracy: 0.5)

        source.relaunchProblems = [String(repeating: "Chrome quit but could not be relaunched, open it yourself. ", count: 8)]
        source.throttledBrowsers = [Self.chrome, Self.arc]
        let long = size()
        XCTAssertEqual(long.width, StatusPopoverView.width, accuracy: 0.5, "never wider")
        XCTAssertGreaterThan(long.height, short.height + 40, "the warning wraps onto more lines")
    }

    /// Enough warnings to pass the cap: the part above the footer stops at
    /// the cap and scrolls, so Settings and Quit stay on screen.
    @MainActor
    func testATallPopoverScrollsAboveTheFooter() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = RecordingStatusSource()
        let controller = StatusItemController(manager: h.makeManager(), status: source, showSettings: {})
        func size(cap: CGFloat) -> NSSize {
            var view = controller.makePopoverView()
            view.maxScrollHeight = cap
            return NSHostingView(rootView: view).fittingSize
        }
        let short = size(cap: 10_000)
        XCTAssertEqual(size(cap: 2_000).height, short.height, accuracy: 0.5, "under the cap the popover hugs its content")

        source.relaunchProblems = (1...12).map { "Browser \($0) quit but could not be relaunched, open it yourself and check its windows." }
        source.throttledBrowsers = [Self.chrome, Self.arc]
        let tall = size(cap: 10_000)
        let capped = size(cap: 400)
        XCTAssertGreaterThan(tall.height, 700)
        XCTAssertGreaterThan(capped.height, 400, "the footer sits below the cap")
        XCTAssertLessThan(capped.height, 400 + 100, "and nothing else does")
        XCTAssertEqual(capped.width, StatusPopoverView.width, accuracy: 0.5)

        XCTAssertEqual(StatusPopoverView.maxScrollHeight(screenHeight: 900), 790)
        XCTAssertEqual(StatusPopoverView.maxScrollHeight(screenHeight: 200), StatusPopoverView.minScrollHeight)
        XCTAssertEqual(StatusPopoverView.maxScrollHeight(screenHeight: nil), 640)
    }

    /// Eight presets do not fit one 300 pt row. The chips wrap onto more
    /// rows (the popover grows taller) rather than shrinking to "3…", and
    /// the popover stays its fixed width.
    @MainActor
    func testPresetChipsWrapInsteadOfTruncating() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        func size() -> NSSize { NSHostingView(rootView: controller.makePopoverView()).fittingSize }
        manager.config.presets = [1800, 3600]
        let two = size()
        manager.config.presets = [1800, 3600, 7200, 4 * 3600, 8 * 3600, 12 * 3600, 86400, 3 * 86400]
        let eight = size()
        XCTAssertEqual(eight.width, StatusPopoverView.width, accuracy: 0.5)
        XCTAssertGreaterThan(eight.height, two.height + 10, "the chips take a second row")
        // Every label fits its cell's minimum width at the chip's size.
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        for seconds in manager.config.presets + StatusPopoverView.extendChoices {
            let label = "+" + chipLabel(for: seconds)
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThan(width + 16, StatusPopoverView.chipMinWidth + 1, label)
        }
    }

    /// The popover opens on the time buttons alone; Custom puts the fields
    /// out, and they go away again when the popover next opens.
    @MainActor
    func testThePopoverOpensOnTheTimeButtonsAndCustomShowsTheFields() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.presets = [1800, 3600, 7200, 4 * 3600]
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        func size() -> NSSize { NSHostingView(rootView: controller.makePopoverView()).fittingSize }
        controller.openPopover()
        XCTAssertFalse(controller.model.customShown, "the buttons by default")
        let buttons = size()
        controller.model.customShown = true
        XCTAssertGreaterThan(size().height, buttons.height + 15, "the fields row comes out")
        controller.model.texts = [.hours: "3"]
        controller.closePopover()
        controller.openPopover()
        XCTAssertFalse(controller.model.customShown, "put away on the next open")
        XCTAssertEqual(controller.model.texts, [:])
        controller.closePopover()
    }

    /// Four presets and Custom share one row; more wrap onto a second.
    @MainActor
    func testFourPresetsAndCustomFitOneRow() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        func size() -> NSSize { NSHostingView(rootView: controller.makePopoverView()).fittingSize }
        manager.config.presets = [1800]
        let one = size()
        manager.config.presets = [1800, 3600, 7200, 4 * 3600]
        let four = size()
        XCTAssertEqual(four.height, one.height, accuracy: 0.5, "one row")
        XCTAssertEqual(four.width, StatusPopoverView.width, accuracy: 0.5)
    }

    /// Start, Extend, Settings and Quit keep their label on one line however
    /// little room they are offered: "Extend" never breaks into "Ex-tend".
    @MainActor
    func testButtonLabelsStayOnOneLine() {
        _ = NSApplication.shared
        for title in ["Start", "Extend"] {
            func height(_ width: CGFloat?) -> CGFloat {
                let button = Button(title) {}.buttonStyle(PopoverButtonStyle(kind: .prominent))
                return NSHostingView(rootView: button.frame(width: width)).fittingSize.height
            }
            XCTAssertEqual(height(20), height(nil), accuracy: 0.5, title)
        }
    }

    /// Opening the popover activates the app, which would bring a Settings
    /// window left behind other apps back with it. Every window of ours
    /// under another app's window is put back under the window just above
    /// it; one already on top is left alone.
    func testOpeningThePopoverLeavesCoveredWindowsWhereTheyWere() {
        let me: pid_t = 1, other: pid_t = 2
        // Front to back: another app, our Settings, another app, our second window.
        let stack: [(number: Int, pid: pid_t)] = [(10, other), (20, me), (30, other), (40, me)]
        XCTAssertEqual(StatusItemController.coveredWindows(stack: stack, ours: [20, 40]), [20: 10, 40: 30])
        // Our window in front of everything: nothing to keep down.
        XCTAssertEqual(StatusItemController.coveredWindows(stack: [(20, me), (10, other)], ours: [20]), [:])
        // Two of ours stacked under another app: each goes back under the one above it.
        XCTAssertEqual(StatusItemController.coveredWindows(stack: [(10, other), (20, me), (21, me)], ours: [20, 21]), [20: 10, 21: 20])
        XCTAssertEqual(StatusItemController.coveredWindows(stack: [], ours: [20]), [:])
    }

    /// Settings closes the popover before the window comes up.
    @MainActor
    func testSettingsClosesThePopoverAndOpensTheWindow() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let opened = Locked(0)
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: { opened.value += 1 })
        controller.openPopover()
        controller.openSettings()
        XCTAssertFalse(controller.model.popoverShown)
        XCTAssertEqual(opened.value, 1)
    }

    // MARK: Commit

    /// The fields are read through `DurationInput`: blank is empty, a value
    /// over its ceiling or anything that is not a whole number is invalid.
    @MainActor
    func testTheFieldsAreValidatedByDurationInput() {
        let model = MenuBarModel()
        XCTAssertTrue(model.input.isEmpty)
        model.texts = [.hours: "2", .minutes: " 30 "]
        XCTAssertEqual(model.input.total, 2 * 3600 + 30 * 60)
        model.texts = [.hours: "24"]
        XCTAssertFalse(model.input.isValid(.hours))
        XCTAssertNil(model.input.total)
        model.texts = [.minutes: "1.5"]
        XCTAssertFalse(model.input.isValid(.minutes))
        model.texts = [.days: "-1"]
        XCTAssertFalse(model.input.isValid(.days))
        model.texts = [.days: "", .hours: "  "]
        XCTAssertTrue(model.input.isEmpty)
    }

    /// Something typed that is not a duration shakes the fields; it never
    /// falls back to the default preset the way empty fields do.
    @MainActor
    func testAnInvalidValueShakesAndStartsNothing() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        controller.model.texts = [.hours: "99"]
        controller.commit()
        XCTAssertEqual(controller.model.rejectBounce, 1)
        XCTAssertEqual(controller.model.phase, .idle)
        controller.model.texts = [.minutes: "0"]
        controller.commit()
        XCTAssertEqual(controller.model.rejectBounce, 2, "zero is not a duration either")
        await settleQueuedRequests()
        XCTAssertFalse(manager.isActive)
    }

    /// A preset chip starts that long at once; an extend chip adds to the
    /// live session. Neither does anything in the wrong state.
    @MainActor
    func testChipsStartAndExtendAtOnce() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        controller.extendBy(3600)
        await settleQueuedRequests()
        XCTAssertFalse(manager.isActive, "nothing to extend")

        controller.startPreset(3600)
        XCTAssertEqual(controller.model.phase, .starting)
        let started = await waitUntil { controller.model.phase == .running }
        XCTAssertTrue(started)
        XCTAssertEqual(manager.countdownText, "1:00:00")

        controller.startPreset(7200)
        await settleQueuedRequests()
        XCTAssertEqual(manager.countdownText, "1:00:00", "a preset never restarts a live session")

        controller.extendBy(StatusPopoverView.extendChoices[0])
        let extended = await waitUntil { manager.countdownText == "1:30:00" }
        XCTAssertTrue(extended)
    }

    /// A successful start spends the typed value and puts the fields away,
    /// but leaves the popover open on the running session: the user closes
    /// it.
    @MainActor
    func testASuccessfulStartLeavesThePopoverOpen() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})
        controller.openPopover()
        controller.model.customShown = true
        controller.model.texts = [.minutes: "45"]
        controller.commit()
        let running = await waitUntil { controller.model.phase == .running && controller.model.texts.isEmpty }
        XCTAssertTrue(running)
        XCTAssertTrue(controller.model.popoverShown)
        XCTAssertFalse(controller.model.customShown)
        controller.closePopover()
    }

    /// An extend leaves the fields editable while it runs. A new time
    /// typed before it finishes stays in them, and Custom stays out.
    @MainActor
    func testAnExtendKeepsATimeTypedWhileItRuns() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        await manager.start(duration: 3600)
        let running = await waitUntil { controller.model.phase == .running }
        XCTAssertTrue(running)
        controller.openPopover()
        controller.model.customShown = true
        controller.model.texts = [.minutes: "30"]
        controller.commit()
        controller.model.texts = [.hours: "2"]
        let extended = await waitUntil { manager.countdownText == "1:30:00" }
        XCTAssertTrue(extended)
        await settleQueuedRequests()
        XCTAssertEqual(controller.model.texts, [.hours: "2"])
        XCTAssertTrue(controller.model.customShown)
        controller.closePopover()
    }

    @MainActor
    func testManagerChangesMoveThePhase() {
        XCTAssertEqual(StatusItemController.phase(forActive: true, phase: .idle), .running)
        XCTAssertEqual(StatusItemController.phase(forActive: true, phase: .starting), .running)
        XCTAssertEqual(StatusItemController.phase(forActive: false, phase: .running), .idle)
        // Nothing to do when the phase already matches the manager, and a
        // start that stays inactive is the controller's to report.
        XCTAssertNil(StatusItemController.phase(forActive: true, phase: .running))
        XCTAssertNil(StatusItemController.phase(forActive: false, phase: .idle))
        XCTAssertNil(StatusItemController.phase(forActive: false, phase: .starting))
    }

    // MARK: Width

    /// Records every length write the controller makes, so a test can pin
    /// when the bar moves.
    @MainActor
    private final class WidthProbe {
        private(set) var applied: [CGFloat] = []

        func make(apply: @escaping (CGFloat) -> Void) -> StatusWidthWriter {
            StatusWidthWriter { [weak self] width in
                self?.applied.append(width)
                apply(width)
            }
        }
    }

    /// The status item's width is written once when a session starts and
    /// once when it ends. Opening the popover, typing into it and closing it
    /// never move the bar.
    @MainActor
    func testTheWidthIsWrittenOnceAndNeverChangesForASessionOrThePopover() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let probe = WidthProbe()
        let controller = StatusItemController(
            manager: manager,
            status: PlaceholderStatus(),
            showSettings: {},
            makeWidthWriter: { apply in probe.make(apply: apply) }
        )
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "installing the host sets the idle width")
        XCTAssertGreaterThanOrEqual(controller.hostWidth, StatusRootView.width, "the host is laid out at the idle width, not left at zero")
        XCTAssertEqual(controller.hostWidth, controller.widthTarget)
        let idle = controller.widthTarget

        controller.openPopover()
        controller.model.texts = [.days: "12", .hours: "23", .minutes: "59"]
        try? await Task.sleep(for: .milliseconds(100))
        controller.closePopover()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "the popover never moves the bar")

        await manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "a session start never relays out the bar")
        XCTAssertEqual(controller.widthTarget, idle)

        controller.openPopover()
        controller.closePopover()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, 1)

        await manager.end(reason: .user)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "nor does its end")
        XCTAssertEqual(controller.widthTarget, idle)
        XCTAssertEqual(probe.applied.count, 1, "one write, at install")
    }

    /// While the recovery agent and pmset run, the projected countdown ticks
    /// like the live one will, and the tick stops the moment the session is
    /// confirmed and the live text takes over.
    @MainActor
    func testTheProjectedCountdownTicksWhileStartingAndStopsOnConfirmation() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        // The controller reads the manager's fake clock. The tick still runs
        // on the real run loop, but every tick between two clock moves reads
        // the same second, so a runner that delays or bunches ticks cannot
        // skip a value.
        let clock = h.clock
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, clock: { clock.now })
        let gate = AsyncGate()
        h.backstop.armGate = gate
        controller.model.texts = [.hours: "2"]

        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertEqual(controller.model.pendingProjection?.shape, .hours)
        XCTAssertEqual(controller.model.pendingCountdown, "2h")
        XCTAssertTrue(controller.pendingTickArmed)
        // Only a tick can move the text, and it moves to what the clock reads.
        clock.advance(1)
        let deadline = Date().addingTimeInterval(5)
        while controller.model.pendingCountdown == "2h", Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.model.pendingCountdown, "1h 59m")
        XCTAssertEqual(controller.model.phase, .starting)

        await gate.open()
        let confirmBy = Date().addingTimeInterval(2)
        while controller.model.phase != .running, Date() < confirmBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertFalse(controller.pendingTickArmed)
        XCTAssertNil(controller.model.pendingProjection)
        XCTAssertNil(controller.model.pendingCountdown)
        // The live text takes over at the minute the projection had reached.
        XCTAssertEqual(manager.remainingText, "1h 59m")
    }

    /// Spin the main actor until `condition` holds or `timeout` elapses.
    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static let chrome = ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")
    private static let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")

    // MARK: Unchanged from the inline pills

    /// The countdown a start will read is projected from the same session
    /// arithmetic the manager uses, in the shape that session will keep.
    @MainActor
    func testProjectedStartCountdownMatchesTheSessionShape() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let month: TimeInterval = 30 * 24 * 3600
        XCTAssertEqual(MenuBarModel.projectedStartCountdown(now: now, duration: 90 * 60, maxDuration: month), "1:30:00")
        let twoDays = MenuBarModel.projectedStartCountdown(now: now, duration: 2 * 86400, maxDuration: month)
        XCTAssertEqual(twoDays, SessionMath.formatCountdown(remaining: 2 * 86400, shape: .days))
        XCTAssertTrue(twoDays.hasPrefix("2d "))
        // The projection ticks: eight seconds into the wait it reads eight
        // seconds less, in the shape it was projected in.
        let projection = MenuBarModel.projectedStart(now: now, duration: 90 * 60, maxDuration: month)
        XCTAssertEqual(projection.shape, .hours)
        XCTAssertEqual(projection.endsAt, now.addingTimeInterval(90 * 60))
        XCTAssertEqual(projection.countdown(at: now), "1:30:00")
        XCTAssertEqual(projection.countdown(at: now.addingTimeInterval(8)), "1:29:52")
        XCTAssertEqual(projection.countdown(at: now.addingTimeInterval(2 * 3600)), "0:00:00")
        // A short start reads in the minutes shape, and the clamp applies.
        XCTAssertEqual(MenuBarModel.projectedStartCountdown(now: now, duration: 30 * 60, maxDuration: month), "30:00")
        XCTAssertEqual(MenuBarModel.projectedStartCountdown(now: now, duration: 5 * 3600, maxDuration: 3600), "1:00:00")
    }

    @MainActor
    func testTickAnimationIsShorterThanBaseAndHoldIsSubSecond() {
        XCTAssertEqual(Motion.holdDuration, 0.6, accuracy: 0.0001)
        XCTAssertLessThan(Motion.holdDuration, 1)
        XCTAssertEqual(Motion.tick(reduceMotion: true), Motion.reduced)
        XCTAssertNotEqual(Motion.tick(reduceMotion: false), Motion.base)
    }

    /// The blink was over in a handful of frames and barely read. It has to
    /// be slower than the baseline spring so the lid lift and the lash
    /// hand-over are seen, and slower than the Reduce Motion crossfade too.
    @MainActor
    func testTheBlinkIsSlowerThanTheBaseSpring() {
        XCTAssertGreaterThan(Motion.blinkResponse, Motion.baseResponse)
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), .spring(response: 0.95, dampingFraction: 0.9))
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: false), .spring(response: 0.8, dampingFraction: 0.95))
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), Motion.blink)
        XCTAssertNotEqual(Motion.blink, Motion.base)
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: true), .easeInOut(duration: 0.3))
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: true), .easeInOut(duration: 0.3))
        XCTAssertGreaterThan(Motion.reducedBlinkDuration, 0.15)
    }

    func testCountdownShapeIsDerivedFromSessionSpan() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(30 * 60)).countdownShape, .minutes)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600)).countdownShape, .hours)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(4 * 3600)).countdownShape, .hours)
        XCTAssertEqual(Session(startedAt: t0, endsAt: t0.addingTimeInterval(2 * 86400)).countdownShape, .days)
        // The shape rides on the persisted span, so it comes back identical after a reload.
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(4 * 3600))
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(Session.self, from: data).countdownShape, .hours)
    }

    @MainActor
    func testCountdownTextTicksInHoursShapeAndPausesWithLid() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 4 * 3600)
        XCTAssertEqual(m.countdownText, "4:00:00")
        XCTAssertEqual(m.remainingText, "4h")

        h.clock.advance(3 * 3600 + 55 * 60 + 53)
        m.refreshCountdown()
        XCTAssertEqual(m.countdownText, "0:04:07")
        XCTAssertEqual(m.remainingText, "4m")

        m.pauseCountdown()
        h.clock.advance(60)
        XCTAssertEqual(m.countdownText, "0:04:07")
        m.resumeCountdown()
        XCTAssertEqual(m.countdownText, "0:03:07")

        await m.end(reason: .user)
        XCTAssertEqual(m.countdownText, "")
    }

    @MainActor
    func testCountdownTextUsesMinutesShapeForShortSession() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 30 * 60)
        XCTAssertEqual(m.countdownText, "30:00")
        h.clock.advance(29 * 60 + 51)
        m.refreshCountdown()
        XCTAssertEqual(m.countdownText, "00:09")
    }

    func testSleepHeldLine() {
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep held per journal \u{2014} not verified live", isWarning: false)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: true, sleepHeld: false),
            SleepHeldLine.Line(text: "Sleep is not held \u{2014} this session is not keeping the Mac awake", isWarning: true)
        )
        XCTAssertEqual(
            SleepHeldLine.line(sessionActive: false, sleepHeld: true),
            SleepHeldLine.Line(text: "Sleep still held with no session", isWarning: true)
        )
        XCTAssertNil(SleepHeldLine.line(sessionActive: false, sleepHeld: false))
    }

    @MainActor
    func testPlaceholderReportsNothing() {
        let s = PlaceholderStatus()
        XCTAssertFalse(s.lidClosed)
        XCTAssertNil(s.batteryPercent)
        XCTAssertFalse(s.isCharging)
        XCTAssertNil(s.wifiSSID)
        XCTAssertNil(s.lastGap)
        XCTAssertEqual(s.frozenCount, 0)
        XCTAssertFalse(s.dockerPaused)
        XCTAssertTrue(s.throttledBrowsers.isEmpty)
        XCTAssertNil(s.hotspotPasswordReport)
        XCTAssertNil(s.instantWatts())
        s.refreshInstant()
        s.refreshOnDemand()
        s.relaunchUnthrottled(ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome"))
    }

    /// Each problem has a menu line, a sentence for the notification, and a
    /// Settings notice except for a missing item, where the empty field is
    /// the notice.
    func testHotspotPasswordProblemCopy() {
        XCTAssertEqual(HotspotPasswordProblem.missing.menuLine, "Hotspot password not saved: enter it in Settings")
        XCTAssertNil(HotspotPasswordProblem.missing.settingsNotice)
        XCTAssertTrue(HotspotPasswordProblem.unreadable.settingsNotice?.contains("Enter it again and save") ?? false)
        XCTAssertTrue(HotspotPasswordProblem.unreadable.explanation.hasSuffix("Enter it again in Settings."))
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").menuLine, "Hotspot password unreadable: keychain: boom")
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").settingsNotice, "The saved password can't be read: keychain: boom")
        XCTAssertEqual(KeychainError(status: errSecAuthFailed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInteractionNotAllowed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInvalidOwnerEdit).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecParam).problem, .error("keychain: One or more parameters passed to a function were not valid."))
    }

    /// The relaunch item asks first, since the browser is quit and its
    /// windows come back only through its own session restore. Cancel
    /// hands nothing on; confirming hands on the bundle id and name the
    /// item carried, even when a scan emptied the list during the alert.
    @MainActor
    func testRelaunchAsksBeforeQuittingAndCancelDoesNothing() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = RecordingStatusSource()
        source.throttledBrowsers = [Self.chrome, Self.arc]
        let asked = Locked<[String]>([])
        let answer = Locked(false)
        let controller = StatusItemController(
            manager: h.makeManager(),
            status: source,
            showSettings: {},
            confirmRelaunch: { name in
                asked.value.append(name)
                source.throttledBrowsers = []
                return answer.value
            }
        )

        controller.relaunchBrowser(Self.chrome)
        XCTAssertEqual(asked.value, ["Chrome"])
        XCTAssertEqual(source.relaunched, [])

        answer.value = true
        controller.relaunchBrowser(Self.arc)
        XCTAssertEqual(asked.value, ["Chrome", "Arc"])
        XCTAssertEqual(source.relaunched, [Self.arc])
    }

    /// The prompt names the browser, says the windows depend on the
    /// browser's own startup setting, and gives the 10 s rule.
    func testRelaunchPromptCopy() {
        let prompt = RelaunchPrompt(browser: "Chrome")
        XCTAssertEqual(prompt.title, "Quit and relaunch Chrome?")
        XCTAssertEqual(
            prompt.message,
            "Insomnia quits Chrome and opens it again with the two flags that stop it throttling hidden windows. Your windows and tabs come back only if Chrome is set to reopen them on startup. If Chrome has not quit after 10 s, nothing is relaunched."
        )
        XCTAssertEqual(RelaunchPrompt.confirmTitle, "Quit and relaunch")
        XCTAssertEqual(RelaunchPrompt.cancelTitle, "Cancel")
    }

    @MainActor
    func testBareEnterStartsTheDefaultPresetButNeverExtends() {
        let preset: TimeInterval = 4 * 3600
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .start, typed: nil, defaultPreset: preset),
            .run(preset)
        )
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .start, typed: 1800, defaultPreset: preset),
            .run(1800)
        )
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .extend, typed: nil, defaultPreset: preset),
            .reject
        )
        XCTAssertEqual(
            MenuBarModel.commitAction(mode: .start, typed: nil, defaultPreset: 0),
            .reject
        )
    }}

/// A status source that records relaunch requests and reports nothing else.
@MainActor
@Observable
final class RecordingStatusSource: StatusSource {
    var lidClosed = false
    var batteryPercent: Int? = nil
    var isCharging = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount = 0
    var dockerPaused = false
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String] = []
    var hotspotPasswordReport: HotspotPasswordReport? = nil
    private(set) var relaunched: [ThrottledBrowser] = []

    func refreshOnDemand() {}
    func refreshInstant() {}
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) { relaunched.append(browser) }
}

/// A status source that counts the refreshes the popover asks for.
@MainActor
@Observable
final class CountingStatusSource: StatusSource {
    var lidClosed = false
    var batteryPercent: Int? = nil
    var isCharging = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount = 0
    var dockerPaused = false
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String] = []
    var hotspotPasswordReport: HotspotPasswordReport? = nil
    private(set) var instant = 0
    private(set) var onDemand = 0

    func refreshOnDemand() { onDemand += 1 }
    func refreshInstant() { instant += 1 }
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) {}
}
