import AppKit
import SwiftUI
import IOKit.ps
import XCTest
@testable import Insomnia

final class UIStatusTests: XCTestCase {
    @MainActor
    func testStatusHostUsesIntrinsicSizingAndHasAnIdleFittingSize() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let root = StatusRootView(
            model: MenuBarModel(),
            manager: harness.makeManager(),
            onTapIcon: {},
            onTapPill: { _ in },
            onTapCountdown: {},
            onHoldEnd: {},
            onWidthChange: { _ in }
        )

        let host = StatusItemController.makeHostingView(root)

        XCTAssertTrue(host.sizingOptions.contains(.intrinsicContentSize))
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The status item cannot animate its width, so the pills must never
    /// change the layout after the slots have arrived: not while they
    /// stagger in, and not on a digit, which changes the text, its weight
    /// and its padding. Each pill is a fixed slot sized by its placeholder.
    @MainActor
    func testPillSlotsKeepTheFittingWidthWhileStaggeringAndWhileTyping() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        let model = MenuBarModel()
        model.phase = .entering(.start)
        model.slotsPresent = true
        func width() -> CGFloat {
            let root = StatusRootView(
                model: model,
                manager: manager,
                onTapIcon: {},
                onTapPill: { _ in },
                onTapCountdown: {},
                onHoldEnd: {},
                onWidthChange: { _ in }
            )
            return StatusItemController.makeHostingView(root).fittingSize.width
        }
        let idle = MenuBarModel()
        let idleWidth = StatusItemController.makeHostingView(StatusRootView(
            model: idle, manager: manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in }
        )).fittingSize.width

        model.visiblePills = 0
        let hidden = width()
        XCTAssertGreaterThan(hidden, idleWidth, "the slots are in the layout from the first frame")
        model.visiblePills = DurationInput.Field.allCases.count
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "the stagger is scale and opacity only")

        model.input = DurationInput(days: 12, hours: 3, minutes: 45)
        XCTAssertEqual(model.input.text(for: .days), "12")
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "typing never widens a slot")
        model.input = DurationInput(days: DurationInput.maxDays, hours: DurationInput.maxHours, minutes: DurationInput.maxMinutes)
        XCTAssertEqual(model.input.text(for: .minutes), "59")
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "the widest values fit the slots too")
        model.focused = .minutes
        model.focusVisible = true
        XCTAssertEqual(width(), hidden, accuracy: 0.001, "the focus ring is an overlay")
    }

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
    func testHoldToEndIsSubSecond() {
        XCTAssertEqual(Motion.holdDuration, 0.6, accuracy: 0.0001)
        XCTAssertLessThan(Motion.holdDuration, 1)
    }

    /// Every frame of an animated countdown is a content change, and AppKit
    /// re-renders the whole status item on each one, about 23 ms of main
    /// thread per frame. The 0.18 s spring that used to run here held the app
    /// at about 46% of one core for the whole session, against 2.3% with no
    /// animation. The tick must stay unanimated.
    ///
    /// This pins the constant only; the test below pins the view that has to
    /// use it, since a transition re-added in the body animates the digits
    /// with this still nil.
    @MainActor
    func testTheCountdownDoesNotAnimateItsDigits() {
        XCTAssertNil(Motion.countdownTick)
    }

    /// The digits must land in one step: the frame the text changes on
    /// already reads the new value, exactly as a countdown rendered fresh
    /// with that value would. The animated content transition this PR removed
    /// (`.numericText(countsDown:)` under a 0.18 s spring) instead spends its
    /// first frames rolling from the old digits, so the changed frame does
    /// not match a fresh one. That is the regression: the cost is in AppKit
    /// re-snapshotting the status item once per animated frame, and pinning
    /// `Motion.countdownTick` to nil does not see a transition put back in
    /// the view.
    @MainActor
    func testTheRenderedCountdownChangesItsDigitsInOneStep() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.start(duration: 4 * 3600)
        XCTAssertEqual(manager.countdownText, "4:00:00")
        let model = MenuBarModel()
        model.phase = .running

        // The same view the controller installs, laid out at its own size and
        // rasterised offscreen; no window and no run loop needed.
        func makeHost() -> StatusHostingView {
            let host = StatusItemController.makeHostingView(StatusRootView(
                model: model,
                manager: manager,
                onTapIcon: {},
                onTapPill: { _ in },
                onTapCountdown: {},
                onHoldEnd: {},
                onWidthChange: { _ in }
            ))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            return host
        }
        func snapshot(_ host: StatusHostingView) -> Data {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("the countdown did not rasterise")
                return Data()
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }

        // One host across the change, so the frame after it is a frame of the
        // same view mid-transition, not a view built with the new text.
        let host = makeHost()
        let before = snapshot(host)
        h.clock.advance(1)
        manager.refreshCountdown()
        XCTAssertEqual(manager.countdownText, "3:59:59")
        // The very next frame, with no time for a spring to run.
        let after = snapshot(host)
        // And what that state looks like with no change to interpolate.
        let fresh = snapshot(makeHost())

        XCTAssertNotEqual(before, after, "the digits must change")
        XCTAssertEqual(after, fresh, "the changed frame must already read the new digits, not roll to them")
    }

    /// The same for the countdown in the Compact panel, which shows the
    /// running controls of the menu bar in a panel of its own.
    @MainActor
    func testTheCompactPanelCountdownChangesItsDigitsInOneStep() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.menuBarMode = .compact
        await manager.start(duration: 4 * 3600)
        let model = MenuBarModel()
        model.phase = .running
        let compact = CompactMenuModel()
        compact.setPresented(true)

        func makeHost() -> NSHostingView<CompactMenuView> {
            let host = NSHostingView(rootView: CompactMenuView(
                model: compact, menuBar: model, manager: manager,
                onSubmit: {}, onEnd: {}, onDismiss: {}
            ))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            return host
        }
        func snapshot(_ host: NSHostingView<CompactMenuView>) -> Data {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("the countdown did not rasterise")
                return Data()
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.representation(using: .png, properties: [:]) ?? Data()
        }

        let host = makeHost()
        let before = snapshot(host)
        h.clock.advance(1)
        manager.refreshCountdown()
        XCTAssertEqual(manager.countdownText, "3:59:59")
        let after = snapshot(host)
        let fresh = snapshot(makeHost())

        XCTAssertNotEqual(before, after, "the digits must change")
        XCTAssertEqual(after, fresh, "the changed frame must already read the new digits, not roll to them")
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

    /// The extension projection is created at Enter over a live session;
    /// it has to show at once, not wait for the manager to confirm it.
    @MainActor
    func testAPendingProjectionShowsOverTheLiveCountdown() {
        XCTAssertEqual(StatusRootView.countdownText(pending: "2:00:00", live: "1:00:00", phase: .running), "2:00:00")
        XCTAssertEqual(StatusRootView.countdownText(pending: "2:00:00", live: "", phase: .starting), "2:00:00")
        XCTAssertEqual(StatusRootView.countdownText(pending: nil, live: "1:00:00", phase: .running), "1:00:00")
        XCTAssertEqual(StatusRootView.countdownText(pending: nil, live: "", phase: .starting), MenuBarModel.startingText)
        XCTAssertEqual(StatusRootView.countdownText(pending: nil, live: "", phase: .idle), "")
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

    func testMachineLine() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: true, watts: 4.12, batteryPercent: nil, isCharging: false),
            "Lid: closed \u{00B7} 4.1 W"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, batteryPercent: nil, isCharging: false),
            "Lid: open"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, batteryPercent: 82, isCharging: true),
            "Lid: open \u{00B7} 82% charging"
        )
    }

    func testNetworkLinePreservesStatusAndOmitsUnknownNames() {
        XCTAssertEqual(StatusLines.network(wifiSSID: "iPhone"), "Wi-Fi: iPhone")
        let hiddenName = WiFiStatusName.display(ssid: nil, locationAuthorized: false)
        XCTAssertEqual(StatusLines.network(wifiSSID: hiddenName), "Wi-Fi: on (name hidden until Location is allowed)")
        XCTAssertNil(StatusLines.network(wifiSSID: nil))
        XCTAssertNil(StatusLines.network(wifiSSID: ""))
        XCTAssertNil(StatusLines.network(wifiSSID: " \n "))
    }

    func testActionsLine() {
        XCTAssertNil(StatusLines.actions(frozenCount: 0, dockerPaused: false, lastGap: nil))
        XCTAssertEqual(StatusLines.actions(frozenCount: 3, dockerPaused: true, lastGap: nil), "3 apps frozen \u{00B7} Docker paused")
        XCTAssertEqual(StatusLines.actions(frozenCount: 1, dockerPaused: false, lastGap: 12.4), "1 app frozen \u{00B7} last gap 12s")
        XCTAssertEqual(StatusLines.actions(frozenCount: 0, dockerPaused: true, lastGap: 0), "Docker paused")
    }

    /// The menu puts the warning sign in front of the shared text, which
    /// has none: the popover draws a triangle instead.
    func testThrottleWarning() {
        func line(_ names: [String]) -> String? {
            let browsers = names.map { ThrottledBrowser(bundleId: "test.\($0)", name: $0) }
            return StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: browsers, error: nil)
                .first { $0.kind == .warning }?.title
        }
        XCTAssertNil(line([]))
        XCTAssertEqual(line(["Chrome"]), "\u{26A0} Chrome is throttled")
        XCTAssertEqual(line(["Chrome", "Arc"]), "\u{26A0} Chrome and Arc are throttled")
        XCTAssertEqual(line(["Chrome", "Arc", "Chromium"]), "\u{26A0} Chrome, Arc, and Chromium are throttled")
    }

    func testRunningMenuListsStatusThenEndSessionSettingsAndQuit() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: "Lid: closed \u{00B7} 82%",
            network: "Wi-Fi: iPhone",
            actions: "3 apps frozen",
            throttledBrowsers: [Self.chrome],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Sleep held per journal \u{2014} not verified live", kind: .info),
            StatusMenu.Item(title: "Lid: closed \u{00B7} 82%", kind: .info),
            StatusMenu.Item(title: "Wi-Fi: iPhone", kind: .info),
            StatusMenu.Item(title: "3 apps frozen", kind: .info),
            StatusMenu.Item(title: "\u{26A0} Chrome is throttled", kind: .warning),
            StatusMenu.Item(title: "Relaunch Chrome unthrottled", kind: .relaunchBrowser(Self.chrome)),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.endSessionTitle, kind: .endSession),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
    }

    @MainActor
    func testScreenshotStatusUsesSeparateNativeMenuRows() throws {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: StatusLines.machine(lidClosed: false, watts: 0, batteryPercent: 100, isCharging: true),
            network: StatusLines.network(wifiSSID: WiFiStatusName.display(ssid: nil, locationAuthorized: false)),
            actions: nil,
            throttledBrowsers: [ThrottledBrowser(bundleId: "com.google.Chrome", name: "Google Chrome")],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Lid: open \u{00B7} 0.0 W \u{00B7} 100% charging", kind: .info),
            StatusMenu.Item(title: "Wi-Fi: on (name hidden until Location is allowed)", kind: .info),
            StatusMenu.Item(title: "\u{26A0} Google Chrome is throttled", kind: .warning),
            StatusMenu.Item(title: "Relaunch Google Chrome unthrottled", kind: .relaunchBrowser(ThrottledBrowser(bundleId: "com.google.Chrome", name: "Google Chrome"))),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])

        let menu = StatusMenu.menu(
            items,
            target: nil,
            endSession: NSSelectorFromString("endSession"),
            settings: NSSelectorFromString("settings"),
            quit: NSSelectorFromString("quit"),
            relaunchBrowser: NSSelectorFromString("relaunch:"),
            stopWaitingForOutput: NSSelectorFromString("stopWaiting:")
        )
        XCTAssertEqual(menu.items.map { $0.accessibilityLabel() ?? $0.title }, items.map(\.title))
        XCTAssertFalse(menu.autoenablesItems)
        for entry in menu.items.prefix(2) {
            XCTAssertFalse(entry.isEnabled)
            XCTAssertNil(entry.action)
            let row = try XCTUnwrap(entry.view as? StatusMenuLabel)
            XCTAssertEqual(row.label.stringValue, entry.accessibilityLabel())
            XCTAssertFalse(row.label.stringValue.contains("\n"))
        }
        XCTAssertEqual(menu.items[3].representedObject as? ThrottledBrowser, ThrottledBrowser(bundleId: "com.google.Chrome", name: "Google Chrome"))
        XCTAssertTrue(menu.items[3].isEnabled)
        XCTAssertTrue(menu.items[4].isSeparatorItem)
        XCTAssertEqual(menu.items[5].keyEquivalent, ",")
        XCTAssertEqual(menu.items[6].keyEquivalent, "q")

        let combined = StatusMenu.menu(
            [StatusMenu.Item(title: items[0].title + " \u{00B7} " + items[1].title, kind: .info)] + Array(items.dropFirst(2)),
            target: nil,
            endSession: NSSelectorFromString("endSession"),
            settings: NSSelectorFromString("settings"),
            quit: NSSelectorFromString("quit"),
            relaunchBrowser: NSSelectorFromString("relaunch:"),
            stopWaitingForOutput: NSSelectorFromString("stopWaiting:")
        )
        menu.update()
        combined.update()
        XCTAssertLessThan(menu.size.width, combined.size.width, "Separate status rows reduce the native menu's width")
    }

    func testMenuOmitsAbsentOrEmptyNetworkRows() {
        let networks: [String?] = [nil, "", " \n "]
        for network in networks {
            let items = StatusMenu.items(
                sessionActive: false,
                sleepHeld: false,
                machine: "Lid: open",
                network: network,
                actions: nil,
                throttledBrowsers: [],
                error: nil
            )
            XCTAssertEqual(items, [
                StatusMenu.Item(title: "Lid: open", kind: .info),
                StatusMenu.Item(title: "", kind: .separator),
                StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
                StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
            ])
        }
    }

    func testIdleMenuIsJustSettingsAndQuitWithNoLeadingSeparator() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            network: nil,
            actions: nil,
            throttledBrowsers: [],
            error: ""
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
        XCTAssertFalse(items.contains { $0.kind == .separator })
    }

    func testMenuShowsTheLastErrorAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
            network: nil,
            actions: nil,
            throttledBrowsers: [],
            error: "sudo: a password is required"
        )
        XCTAssertEqual(items.first, StatusMenu.Item(title: "\u{26A0} sudo: a password is required", kind: .warning))
        XCTAssertEqual(items.map(\.kind), [.warning, .separator, .settings, .quit])
    }

    /// A hotspot join skipped for want of a password is a warning line in
    /// the menu, between the browser items and the session error, so the
    /// failure is never silent.
    func testMenuShowsTheHotspotPasswordProblemAsAWarning() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            actions: nil,
            throttledBrowsers: [Self.chrome],
            hotspotWarning: HotspotPasswordProblem.unreadable.menuLine,
            error: "sudo: a password is required"
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser(Self.chrome), .warning, .warning, .separator, .endSession, .settings, .quit]
        )
        XCTAssertEqual(items[3], StatusMenu.Item(
            title: "\u{26A0} Hotspot password unreadable by this build: enter it again in Settings",
            kind: .warning
        ))
        XCTAssertEqual(
            StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], hotspotWarning: nil, error: nil).map(\.kind),
            [.settings, .quit]
        )
    }

    /// Each problem has a menu line, a sentence for the notification, and a
    /// Settings notice except for a missing item, where the empty field is
    /// the notice.
    func testHotspotPasswordProblemCopy() {
        XCTAssertEqual(HotspotPasswordProblem.missing.menuLine, "Hotspot password not saved: enter it in Settings")
        // The menu adds the sign the popover draws as a triangle.
        XCTAssertEqual(
            StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], hotspotWarning: HotspotPasswordProblem.missing.menuLine, error: nil).first?.title,
            "\u{26A0} Hotspot password not saved: enter it in Settings"
        )
        XCTAssertNil(HotspotPasswordProblem.missing.settingsNotice)
        XCTAssertTrue(HotspotPasswordProblem.unreadable.settingsNotice?.contains("Enter it again and save") ?? false)
        XCTAssertTrue(HotspotPasswordProblem.unreadable.explanation.hasSuffix("Enter it again in Settings."))
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").menuLine, "Hotspot password unreadable: keychain: boom")
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").settingsNotice, "The saved password can't be read: keychain: boom")
        XCTAssertEqual(KeychainError(status: errSecAuthFailed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInteractionNotAllowed).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecInvalidOwnerEdit).problem, .unreadable)
        XCTAssertEqual(KeychainError(status: errSecParam).problem, .error("keychain: \(securityMessage(errSecParam))"))
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

    private static let chrome = ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")
    private static let arc = ThrottledBrowser(bundleId: "company.thebrowser.Browser", name: "Arc")

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

    /// Greptile caught this as a regression: replacing the popover with a
    /// menu left the throttle warning with no way to act on it.
    func testEveryThrottledBrowserGetsItsOwnRelaunchItem() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            network: nil,
            actions: nil,
            throttledBrowsers: [Self.chrome, Self.arc],
            error: nil
        )
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser(Self.chrome) }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser(Self.arc) }.count, 1)
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser(Self.chrome), .relaunchBrowser(Self.arc), .separator, .endSession, .settings, .quit]
        )
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
    }

    /// The pills can be in start mode over a live session: the user reopened
    /// them while the start was still in flight. Collapsing then has to show
    /// the countdown, not pretend the Mac is free to sleep.
    @MainActor
    func testCollapsingPillsLandsOnTheCountdownWheneverASessionIsActive() {
        XCTAssertEqual(StatusItemController.collapseTarget(sessionActive: true), .running)
        XCTAssertEqual(StatusItemController.collapseTarget(sessionActive: false), .idle)
    }

    @MainActor
    func testAStartLandingUnderTheStartPillsTurnsThemIntoExtendPills() {
        XCTAssertEqual(StatusItemController.phase(forActive: true, phase: .entering(.start)), .entering(.extend))
        XCTAssertEqual(StatusItemController.phase(forActive: false, phase: .entering(.extend)), .entering(.start))
        XCTAssertEqual(StatusItemController.phase(forActive: true, phase: .idle), .running)
        XCTAssertEqual(StatusItemController.phase(forActive: false, phase: .running), .idle)
        // Nothing to do when the phase already matches the manager.
        XCTAssertNil(StatusItemController.phase(forActive: true, phase: .running))
        XCTAssertNil(StatusItemController.phase(forActive: false, phase: .idle))
    }

    // MARK: Width choreography

    /// Records every length write the controller makes, so a test can pin
    /// when the bar moves: once per open, once per close, never under a
    /// pill still visible.
    @MainActor
    private final class WidthProbe {
        private(set) var writer: StatusWidthWriter?
        private(set) var applied: [CGFloat] = []
        /// Asked at every write whether the pills are folding; a write
        /// then is the cut across moving content the design forbids.
        var isFolding: () -> Bool = { false }
        private(set) var writesWhileFolding = 0
        /// What each such write looked like, for the failure message.
        var describeState: () -> String = { "" }
        private(set) var foldingWrites: [String] = []
        /// Asked at every write whether the slots are in the layout, so a
        /// test can pin that a close is written after they leave, not
        /// between the fold ending and their removal.
        var slotsPresent: () -> Bool = { false }
        private(set) var slotsAtWrite: [Bool] = []

        func make(apply: @escaping (CGFloat) -> Void) -> StatusWidthWriter {
            let writer = StatusWidthWriter { [weak self] width in
                guard let self else { return }
                self.applied.append(width)
                self.slotsAtWrite.append(self.slotsPresent())
                if self.isFolding() {
                    self.writesWhileFolding += 1
                    self.foldingWrites.append("\(width) \(self.describeState())")
                }
                apply(width)
            }
            self.writer = writer
            return writer
        }
    }

    /// A controller over a fresh manager with a `WidthProbe` for its width.
    @MainActor
    private struct Lab {
        let h: Harness
        let manager: SessionManager
        let probe: WidthProbe
        let controller: StatusItemController

        init() {
            _ = NSApplication.shared
            h = Harness()
            manager = h.makeManager()
            let probe = WidthProbe()
            self.probe = probe
            let controller = StatusItemController(
                manager: manager,
                status: PlaceholderStatus(),
                showSettings: {},
                makeWidthWriter: { apply in probe.make(apply: apply) }
            )
            self.controller = controller
            probe.isFolding = { [weak controller] in controller?.model.pillsCollapsing ?? false }
            probe.slotsPresent = { [weak controller] in controller?.model.slotsPresent ?? false }
            probe.describeState = { [weak controller] in
                guard let m = controller?.model else { return "" }
                return "phase \(m.phase) slots \(m.slotsPresent) visible \(m.visiblePills) error \(m.startError ?? "nil") target \(controller?.widthTarget ?? 0)"
            }
        }

        func tearDown() {
            h.home.destroy()
        }

        var model: MenuBarModel { controller.model }

        /// The width the layout has for `phase` with no slots; what a close
        /// must land on.
        func widthWithoutSlots(phase: MenuBarModel.Phase) -> CGFloat {
            let m = MenuBarModel()
            m.phase = phase
            m.pendingCountdown = model.pendingCountdown
            m.pendingProjection = model.pendingProjection
            let root = StatusRootView(model: m, manager: manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in })
            return max(StatusItemController.makeHostingView(root).fittingSize.width.rounded(.up), 24)
        }

        /// Let the layout report and the pills stagger in.
        func settleOpen() async {
            try? await Task.sleep(for: .milliseconds(300))
        }

        /// Wait out a close: the fold's stagger and settle, then the
        /// layout's own report of the landed width has time to arrive.
        func settleClose() async {
            let landed = Int((Motion.staggerDelay(index: 2, count: 3, reversed: false) + Motion.retractSettle()) * 1000) + 250
            try? await Task.sleep(for: .milliseconds(landed))
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The pills take a moment to fold, and the session can end inside
    /// that window: the deadline fires between the Esc and the slots
    /// leaving. The landing is read when the slots leave, so the countdown
    /// does not come back for a session that is already over.
    @MainActor
    func testCollapseReadsTheSessionWhenTheSlotsLeaveNotWhenThePillsStartFolding() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        await lab.manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(lab.model.phase, .running)
        lab.controller.expand(mode: .extend)
        await lab.settleOpen()

        lab.controller.collapse()
        XCTAssertTrue(lab.model.pillsCollapsing)
        // The session ends while the pills are still folding.
        await lab.manager.end(reason: .user)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(lab.model.slotsPresent, "still closing")
        XCTAssertEqual(lab.model.phase, .entering(.start), "the ended session turns the extend pills into start pills")

        await lab.settleClose()
        XCTAssertFalse(lab.manager.isActive)
        XCTAssertEqual(lab.model.phase, .idle, "read at the landing: no countdown for a session that is over")
        XCTAssertEqual(lab.model.visiblePills, 0)
        XCTAssertFalse(lab.model.slotsPresent)
    }

    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Opening puts the three slots in the layout before any pill shows
    /// (one relayout, one write); closing folds the pills with their
    /// stagger over an unchanged width and the slots leave once the last
    /// has settled, never before, and the width is written once after
    /// that, on the layout's report: it must never snap across a pill
    /// still visible.
    @MainActor
    func testSlotsArriveOnOpenAndLeaveWithTheLastPill() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(controller.model.visiblePills, 0, "the content staggers in after the slots are laid out")
        await lab.settleOpen()
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget, "open: written once")
        let pillsWidth = controller.widthTarget

        controller.collapse()
        XCTAssertEqual(controller.widthTarget, pillsWidth, "the width stays while the pills fold")
        XCTAssertTrue(controller.model.slotsPresent, "the slots stay while the pills retract")
        XCTAssertTrue(controller.model.pillsCollapsing, "the pills fold towards the eye")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        let written = lab.probe.applied.count
        // The pills have all started retracting, but the last one is still
        // fading: the slots must stay until it has settled.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertTrue(controller.model.slotsPresent, "the bar must not snap under a pill that is still visible")
        XCTAssertEqual(controller.widthTarget, pillsWidth)
        XCTAssertEqual(lab.probe.applied.count, written, "no width write before the slots leave")
        // The slots leave on a timer, and the native width lands a settle
        // after the layout's report (StatusItemWidthMotion): wait for each,
        // with a bound, since a loaded runner stretches both delays.
        let left = await waitUntil { !controller.model.slotsPresent }
        XCTAssertTrue(left, "the slots leave once the last pill has settled")
        XCTAssertFalse(controller.model.pillsCollapsing, "the fold ends with the slots")
        XCTAssertEqual(controller.model.phase, .idle)
        let landed = await waitUntil { lab.probe.applied.count > written }
        XCTAssertTrue(landed, "the width is written after the slots leave")
        XCTAssertEqual(controller.widthTarget, lab.widthWithoutSlots(phase: .idle), "the width moves on the layout's report")
        XCTAssertEqual(lab.probe.applied.count, written + 1, "one write, after the slots left")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
        XCTAssertEqual(lab.probe.writesWhileFolding, 0, lab.probe.foldingWrites.joined(separator: "; "))
    }

    /// The status item's width target is meant to change once per open and
    /// once per close: the slots arrive with the phase, and the close heads
    /// for the width the layout will have once they leave, which is the
    /// width the layout then reports (so that report does not count twice).
    /// Same over a live session, where the countdown and the ring swap with
    /// the slots.
    ///
    /// What is measured is the count of distinct targets. Animations do not
    /// render in this background-only test process (an animated layout
    /// change reports its end value only), so this pins the discrete
    /// relayouts; per-frame interpolation of an animated layout width is kept
    /// out by setting the layout state outside any animation, which this
    /// cannot see.
    @MainActor
    func testTheStatusItemWidthTargetChangesOncePerOpenAndOncePerClose() async throws {
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller
        let manager = lab.manager
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "installing the host sets the idle width")
        XCTAssertGreaterThanOrEqual(controller.hostWidth, 24, "the host is laid out at the idle width, not left at zero")
        XCTAssertEqual(controller.hostWidth, controller.widthTarget, "install: the host is as wide as the first target")

        controller.expand(mode: .start)
        await lab.settleOpen()
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(controller.widthTargetChangeCount, 2, "open: one relayout")
        XCTAssertGreaterThanOrEqual(controller.hostWidth, controller.widthTarget, "open: the host grew to the pills' width")

        controller.collapse()
        await lab.settleClose()
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.widthTargetChangeCount, 3, "close: one relayout")

        await manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(controller.widthTargetChangeCount, 4, "countdown and ring: one relayout")

        controller.expand(mode: .extend)
        await lab.settleOpen()
        XCTAssertEqual(controller.widthTargetChangeCount, 5, "open over a session: one relayout")

        controller.collapse()
        await lab.settleClose()
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertEqual(controller.widthTargetChangeCount, 6, "close to the countdown: one relayout")
        XCTAssertEqual(lab.probe.applied.count, 6, "and one write each")
        XCTAssertEqual(lab.probe.writesWhileFolding, 0, lab.probe.foldingWrites.joined(separator: "; "))
        XCTAssertEqual(
            lab.probe.slotsAtWrite, [false, true, false, false, true, false],
            "opens are written with the slots in, closes only once they are out"
        )
    }

    /// The close folds the bar shut: the pills travel to the eye
    /// on a curve of known length, and the slots may only leave once the
    /// last pill's curve has run out. Under Reduce Motion the pills fade in
    /// place, a little longer than the general crossfade, with the same
    /// guarantee.
    @MainActor
    func testTheCollapseCurveIsCoveredByTheRetractSettle() {
        XCTAssertEqual(Motion.collapse(reduceMotion: false), .easeInOut(duration: 0.32))
        XCTAssertEqual(Motion.collapse(reduceMotion: true), .easeInOut(duration: 0.2))
        XCTAssertEqual(Motion.collapseScale, 0.6)
        XCTAssertGreaterThan(Motion.retractSettle(reduceMotion: false), Motion.collapseDuration)
        XCTAssertGreaterThan(Motion.retractSettle(reduceMotion: true), Motion.reducedCollapseDuration)
        XCTAssertGreaterThan(Motion.reducedCollapseDuration, 0.15)
    }

    /// Esc / click away: the pills fold shut towards the eye
    /// (`pillsCollapsing`) from the first step, the slots stay in the
    /// layout for the whole collapse, and the collapse ends in the same
    /// step that takes the slots out.
    @MainActor
    func testAOneWriteCollapseFoldsThePillsAndEndsWithTheSlots() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        XCTAssertFalse(controller.model.pillsCollapsing, "opening is the stagger, not the fold")
        await lab.settleOpen()
        XCTAssertFalse(controller.model.pillsCollapsing)
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)

        let began = Date()
        controller.collapse()
        XCTAssertTrue(controller.model.pillsCollapsing, "folding from the first step")
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertFalse(controller.model.focusVisible, "the glow goes at once")
        XCTAssertEqual(controller.model.phase, .entering(.start))

        // Every pill has started leaving; the last one's curve is running.
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertTrue(controller.model.pillsCollapsing)
        XCTAssertTrue(controller.model.slotsPresent, "the slots hold the layout for the whole collapse")

        // Poll for the slots leaving: the flag must be down in that same step.
        let lastStep = Motion.staggerDelay(index: 2, count: 3, reversed: false)
        let deadline = began.addingTimeInterval(lastStep + Motion.retractSettle() + 0.5)
        while controller.model.slotsPresent, Date() < deadline {
            XCTAssertTrue(controller.model.pillsCollapsing, "still folding while the slots are up")
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertFalse(controller.model.pillsCollapsing, "cleared with the slots")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), lastStep + Motion.collapseDuration, "not before the last pill's curve has run out")
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertEqual(controller.model.visiblePills, 0)
    }

    /// Enter: the same fold, then the projected countdown once
    /// the slots have left (it is only in the layout after them, so it can
    /// never show under the collapsing pills), then the live session.
    @MainActor
    func testAOneWriteEnterFoldsThePillsThenShowsTheCountdown() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller
        let gate = AsyncGate()
        lab.h.backstop.armGate = gate

        controller.expand(mode: .start)
        await lab.settleOpen()
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))
        let pillsWidth = controller.widthTarget
        let written = lab.probe.applied.count

        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertTrue(controller.model.pillsCollapsing, "Enter folds the pills the same way")
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertNotNil(controller.model.pendingCountdown)
        XCTAssertEqual(controller.widthTarget, pillsWidth, "the width stays while the pills fold")

        let deadline = Date().addingTimeInterval(Motion.staggerDelay(index: 2, count: 3, reversed: false) + Motion.retractSettle() + 0.5)
        while controller.model.slotsPresent, Date() < deadline {
            XCTAssertTrue(controller.model.pillsCollapsing)
            XCTAssertEqual(lab.probe.applied.count, written, "no width write while the pills fold")
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertFalse(controller.model.pillsCollapsing, "cleared with the slots")
        XCTAssertEqual(controller.model.phase, .starting, "the countdown is the projection until the manager answers")
        XCTAssertEqual(
            StatusRootView.countdownText(pending: controller.model.pendingCountdown, live: lab.manager.countdownText, phase: controller.model.phase),
            controller.model.pendingCountdown
        )
        // Removing the slots retargets the eye; its reserved native width
        // remains until that return animation finishes, then releases once.
        let widthSettle = Motion.itemResizeDuration + Motion.collapseSettleMargin
        try? await Task.sleep(for: .seconds(widthSettle + 0.1))
        XCTAssertEqual(controller.widthTarget, lab.widthWithoutSlots(phase: .starting), "the width retargets once, after the slots left")
        XCTAssertEqual(lab.probe.applied.count, written + 1)
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget, "the native reservation releases after the eye arrives")
        XCTAssertEqual(lab.probe.writesWhileFolding, 0, lab.probe.foldingWrites.joined(separator: "; "))

        await gate.open()
        let confirmBy = Date().addingTimeInterval(2)
        while controller.model.phase != .running, Date() < confirmBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertFalse(controller.model.pillsCollapsing)
    }

    /// Reopened while the pills are still folding: the fold is
    /// dropped, the slots never left, the pills stagger back in, and the
    /// dropped collapse's completion never takes the slots out.
    @MainActor
    func testReopeningDuringAOneWriteCollapseDropsTheFoldAndBringsThePillsBack() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        await lab.settleOpen()
        let pillsWidth = controller.widthTarget
        let written = lab.probe.applied.count

        controller.collapse()
        XCTAssertTrue(controller.model.pillsCollapsing)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.model.visiblePills, 0, "every pill on its way to the eye")
        XCTAssertTrue(controller.model.slotsPresent)

        controller.expand(mode: .start)
        XCTAssertFalse(controller.model.pillsCollapsing, "the fold is dropped at once")
        XCTAssertTrue(controller.model.slotsPresent, "never left")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertEqual(controller.widthTarget, pillsWidth)
        await lab.settleOpen()
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count, "staggered back in")
        XCTAssertTrue(controller.model.focusVisible)
        XCTAssertFalse(controller.model.pillsCollapsing)

        // Past when the dropped collapse would have taken the slots out.
        try? await Task.sleep(for: .milliseconds(Int(Motion.retractSettleDuration * 1000) + 100))
        XCTAssertTrue(controller.model.slotsPresent, "the dropped completion never fires")
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertEqual(lab.probe.applied.count, written, "the width never moved")
        controller.collapse()
    }

    /// A click on the eye while the pills are folding: the phase is still
    /// `.entering`, but the key catcher is gone, so there is nothing to
    /// commit and nothing more to collapse. The click reopens the pills,
    /// whether or not something was typed.
    @MainActor
    func testClickingTheEyeDuringACollapseReopensThePills() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller

        controller.expand(mode: .start)
        await lab.settleOpen()
        let pillsWidth = controller.widthTarget
        let written = lab.probe.applied.count

        // Nothing typed: without a fold in flight the click would collapse.
        controller.collapse()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.model.pillsCollapsing)
        controller.iconTapped()
        XCTAssertFalse(controller.model.pillsCollapsing, "the fold is dropped at once")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        await lab.settleOpen()
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count, "staggered back in")

        // Something typed: without a fold in flight the click would commit.
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))
        controller.collapse()
        try? await Task.sleep(for: .milliseconds(100))
        controller.iconTapped()
        XCTAssertEqual(controller.model.phase, .entering(.start), "reopened, not committed")
        XCTAssertNil(controller.model.pendingCountdown)
        XCTAssertNil(controller.model.input.total, "the reopen path starts fresh")
        await lab.settleClose()
        XCTAssertTrue(controller.model.slotsPresent, "the dropped folds never take the slots out")
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(controller.widthTarget, pillsWidth)
        XCTAssertEqual(lab.probe.applied.count, written, "the width never moved")
        controller.collapse()
    }

    /// Over a live session the same click reopens the pills in extend mode.
    @MainActor
    func testClickingTheEyeDuringACollapseOverASessionReopensTheExtendPills() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller
        await lab.manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.model.phase, .running)

        controller.expand(mode: .extend)
        await lab.settleOpen()
        controller.collapse()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.model.pillsCollapsing)
        controller.iconTapped()
        XCTAssertEqual(controller.model.phase, .entering(.extend))
        XCTAssertTrue(controller.model.slotsPresent)
        await lab.settleClose()
        XCTAssertTrue(controller.model.slotsPresent, "the dropped fold never takes the slots out")
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(controller.model.phase, .entering(.extend))
        controller.collapse()
    }

    /// The manager refuses the start while the pills are folding (the
    /// backstop is held until the fold is under way): the fold is
    /// cancelled, the pills come back at once with the value and the error
    /// label, and the cancelled fold never takes the slots out. A retry
    /// then hides the label but keeps its room until the slots leave, so
    /// the bar is written once, after them.
    @MainActor
    func testARefusedStartDuringACollapseRestoresThePillsAndDropsTheLanding() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller
        let gate = AsyncGate()
        lab.h.backstop.armGate = gate
        lab.h.backstop.failArm = true

        controller.expand(mode: .start)
        await lab.settleOpen()
        let pillsWidth = controller.widthTarget
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))

        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertTrue(controller.model.pillsCollapsing)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.model.visiblePills, 0, "every pill on its way to the eye")
        XCTAssertTrue(controller.model.slotsPresent, "mid-fold")
        await gate.open()

        let deadline = Date().addingTimeInterval(2)
        while !controller.model.phase.isEntering, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertFalse(controller.model.pillsCollapsing)
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertTrue(controller.model.focusVisible)
        XCTAssertEqual(controller.model.input.text(for: .hours), "2")
        XCTAssertEqual(controller.model.startError, MenuBarModel.startFailedText)

        await lab.settleClose()
        XCTAssertTrue(controller.model.slotsPresent, "the cancelled fold never takes the slots out")
        XCTAssertEqual(controller.model.startError, MenuBarModel.startFailedText)
        XCTAssertTrue(controller.model.startErrorShown)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        let withLabel = controller.widthTarget
        XCTAssertGreaterThan(withLabel, pillsWidth, "the layout reported the label's extra")
        XCTAssertEqual(lab.probe.applied.last, withLabel)
        XCTAssertEqual(lab.probe.writesWhileFolding, 0, lab.probe.foldingWrites.joined(separator: "; "))

        // Retry: the label hides at once, its room stays until the slots go.
        lab.h.backstop.armGate = nil
        lab.h.backstop.failArm = false
        let written = lab.probe.applied.count
        controller.commit()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertFalse(controller.model.startErrorShown, "hidden with the retry")
        XCTAssertNotNil(controller.model.startError, "but its room is kept")
        XCTAssertEqual(controller.widthTarget, withLabel, "no narrowing under the fold")
        await lab.settleClose()
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertNil(controller.model.startError, "cleared with the slots")
        // The layout reports after the slots leave, then the eye's return
        // animation releases its native reservation. Observe that write;
        // the fold's fixed wait alone cannot prove both callbacks ran.
        let widthBy = Date().addingTimeInterval(5)
        while (lab.probe.applied.count == written || lab.probe.applied.last != controller.widthTarget), Date() < widthBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(lab.probe.applied.count, written + 1, "one write, after the slots left")
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget, "the native reservation reached the reported width")
        XCTAssertEqual(lab.probe.slotsAtWrite.last, false, "the write happened after the slots left")
        XCTAssertEqual(lab.probe.writesWhileFolding, 0, lab.probe.foldingWrites.joined(separator: "; "))
        let confirmBy = Date().addingTimeInterval(2)
        while controller.model.phase != .running, Date() < confirmBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .running)
    }

    /// After a refused start the error label is in the layout. Esc folds
    /// the pills with the label still up; an eye click mid-fold reopens
    /// them, and must end the fold before it clears the label: clearing
    /// the label changes the layout, the hosting view can report at once,
    /// and that report must never be written under the fold.
    @MainActor
    func testClickingTheEyeDuringACollapseAfterARefusalEndsTheFoldBeforeTheLabelGoes() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller
        lab.h.backstop.failArm = true

        controller.expand(mode: .start)
        await lab.settleOpen()
        let pillsWidth = controller.widthTarget
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))
        controller.commit()
        let refusedBy = Date().addingTimeInterval(2)
        while !controller.model.phase.isEntering, Date() < refusedBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .entering(.start))
        await lab.settleClose()
        XCTAssertEqual(controller.model.startError, MenuBarModel.startFailedText)
        let withLabel = controller.widthTarget
        XCTAssertGreaterThan(withLabel, pillsWidth)

        // Esc, then the eye a moment into the fold.
        controller.collapse()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.model.pillsCollapsing)
        XCTAssertNotNil(controller.model.startError, "the label keeps its room through the fold")
        let written = lab.probe.applied.count
        controller.iconTapped()
        XCTAssertFalse(controller.model.pillsCollapsing, "the fold is dropped at once")
        XCTAssertNil(controller.model.startError, "the label goes with the reopen")
        XCTAssertEqual(controller.model.phase, .entering(.start))
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertEqual(lab.probe.writesWhileFolding, 0, lab.probe.foldingWrites.joined(separator: "; "))

        await lab.settleClose()
        XCTAssertTrue(controller.model.slotsPresent, "the dropped fold never takes the slots out")
        XCTAssertEqual(controller.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(controller.widthTarget, pillsWidth, "back to the pills' width without the label")
        XCTAssertLessThanOrEqual(lab.probe.applied.count - written, 1, "the label's room went in one write")
        XCTAssertEqual(lab.probe.writesWhileFolding, 0, lab.probe.foldingWrites.joined(separator: "; "))
        controller.collapse()
    }

    /// Esc or Enter before the open stagger has finished: whatever is up
    /// folds, the slots leave exactly once, and the bar ends on the idle
    /// width or the projected countdown.
    @MainActor
    func testAnEarlyEscOrEnterFoldsWhateverIsUpAndTakesTheSlotsOutOnce() async throws {
        try XCTSkipIf(Motion.reduceMotion, "needs a non-zero pill stagger")
        let lab = Lab()
        defer { lab.tearDown() }
        let controller = lab.controller

        // Esc as soon as the first pill is up, well inside the stagger.
        controller.expand(mode: .start)
        let firstPillBy = Date().addingTimeInterval(1)
        while controller.model.visiblePills == 0, Date() < firstPillBy {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertGreaterThan(controller.model.visiblePills, 0, "the stagger has begun")
        XCTAssertLessThan(controller.model.visiblePills, DurationInput.Field.allCases.count, "and has not finished")
        controller.collapse()
        XCTAssertTrue(controller.model.pillsCollapsing)
        XCTAssertEqual(controller.model.phase, .entering(.start))
        await lab.settleClose()
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertFalse(controller.model.pillsCollapsing)
        XCTAssertEqual(controller.model.phase, .idle)
        XCTAssertEqual(controller.model.visiblePills, 0)
        XCTAssertEqual(lab.probe.applied.last, controller.widthTarget)
        XCTAssertEqual(controller.widthTarget, lab.widthWithoutSlots(phase: .idle))

        // Enter at once, before the layout has even reported the slots.
        let gate = AsyncGate()
        lab.h.backstop.armGate = gate
        let changes = controller.widthTargetChangeCount
        controller.expand(mode: .start)
        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertTrue(controller.model.slotsPresent)
        XCTAssertTrue(controller.model.pillsCollapsing)
        XCTAssertNotNil(controller.model.pendingCountdown)
        await lab.settleClose()
        XCTAssertFalse(controller.model.slotsPresent, "left once")
        XCTAssertFalse(controller.model.pillsCollapsing)
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertEqual(controller.widthTarget, lab.widthWithoutSlots(phase: .starting))
        XCTAssertLessThanOrEqual(controller.widthTargetChangeCount - changes, 2, "at most the slots' report and the countdown")
        await gate.open()
        let confirmBy = Date().addingTimeInterval(2)
        while controller.model.phase != .running, Date() < confirmBy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertFalse(controller.model.slotsPresent)
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
        controller.expand(mode: .start)
        controller.focus(.hours)
        XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))

        controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(controller.model.phase, .starting)
        XCTAssertEqual(controller.model.pendingProjection?.shape, .hours)
        XCTAssertEqual(controller.model.pendingCountdown, "2:00:00")
        XCTAssertTrue(controller.pendingTickArmed)
        // Only a tick can move the text, and it moves to what the clock reads.
        clock.advance(1)
        let deadline = Date().addingTimeInterval(5)
        while controller.model.pendingCountdown == "2:00:00", Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.model.pendingCountdown, "1:59:59")
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
        // The live text takes over at the second the projection had reached.
        XCTAssertEqual(manager.countdownText, "1:59:59")
    }

    // MARK: Countdown style

    /// The end time is a fixed text for the whole session, so nothing needs to
    /// redraw the status item each second.
    @MainActor
    func testEndTimeStyleArmsNoCountdownTimerAndShowsTheEndTime() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.countdownStyle = .endTime
        await manager.start(duration: 4 * 3600)
        let endsAt = h.clock.now.addingTimeInterval(4 * 3600)
        XCTAssertFalse(manager.countdownTimerArmed)
        XCTAssertEqual(manager.countdownText, SessionMath.formatEndTime(endsAt, now: h.clock.now))
        XCTAssertFalse(manager.countdownText.isEmpty)
    }

    @MainActor
    func testRemainingStyleStillArmsTheCountdownTimer() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.start(duration: 4 * 3600)
        XCTAssertTrue(manager.countdownTimerArmed)
        XCTAssertEqual(manager.countdownText, "4:00:00")
    }

    /// Settings calls `countdownStyleChanged()` on a change, and a running
    /// session shows the new style at once; the tick goes or comes back with it.
    @MainActor
    func testChangingTheStyleReachesARunningSessionAtOnce() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.start(duration: 4 * 3600)
        XCTAssertTrue(manager.countdownTimerArmed)
        XCTAssertEqual(manager.countdownText, "4:00:00")

        manager.config.countdownStyle = .endTime
        manager.countdownStyleChanged()
        XCTAssertFalse(manager.countdownTimerArmed)
        XCTAssertEqual(manager.countdownText, SessionMath.formatEndTime(h.clock.now.addingTimeInterval(4 * 3600), now: h.clock.now))

        manager.config.countdownStyle = .remaining
        manager.countdownStyleChanged()
        XCTAssertTrue(manager.countdownTimerArmed)
        XCTAssertEqual(manager.countdownText, "4:00:00")
    }

    /// A closed lid has the tick stopped; a style change must not restart it.
    @MainActor
    func testChangingTheStyleDoesNotRestartAPausedCountdown() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.countdownStyle = .endTime
        await manager.start(duration: 4 * 3600)
        manager.pauseCountdown()

        manager.config.countdownStyle = .remaining
        manager.countdownStyleChanged()
        XCTAssertFalse(manager.countdownTimerArmed)
        XCTAssertEqual(manager.countdownText, "4:00:00")
    }

    @MainActor
    func testLidOpenArmsNoCountdownTimerWithTheEndTime() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.countdownStyle = .endTime
        await manager.start(duration: 4 * 3600)
        let endTime = manager.countdownText

        manager.pauseCountdown()
        h.clock.advance(60)
        manager.resumeCountdown()
        XCTAssertFalse(manager.countdownTimerArmed)
        XCTAssertEqual(manager.countdownText, endTime)
    }

    @MainActor
    func testEndTimeFollowsAnExtension() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.countdownStyle = .endTime
        await manager.start(duration: 3600)
        let before = manager.countdownText
        await manager.extend(by: 5 * 3600)
        XCTAssertNotEqual(manager.countdownText, before)
        XCTAssertEqual(manager.countdownText, SessionMath.formatEndTime(h.clock.now.addingTimeInterval(6 * 3600), now: h.clock.now))
    }

    /// The projection stands in for the live text until the manager confirms
    /// the session, so it must read exactly what the manager will.
    @MainActor
    func testTheProjectionReadsTheSameTextAsTheManagerInEveryStyle() async {
        for style in CountdownStyle.allCases {
            let h = Harness()
            defer { h.home.destroy() }
            let manager = h.makeManager()
            manager.config.countdownStyle = style
            let projection = MenuBarModel.projectedStart(now: h.clock.now, duration: 4 * 3600, maxDuration: manager.config.maxDuration, style: style)
            await manager.start(duration: 4 * 3600)
            XCTAssertEqual(projection.countdown(at: h.clock.now), manager.countdownText, "\(style)")
        }
    }

    /// The 1 Hz tick of the projected countdown has nothing to redraw when the
    /// text is the end time.
    @MainActor
    func testPendingTickRunsOnlyInRemainingStyle() async {
        _ = NSApplication.shared
        for style in CountdownStyle.allCases {
            let h = Harness()
            defer { h.home.destroy() }
            let manager = h.makeManager()
            manager.config.countdownStyle = style
            let clock = h.clock
            let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, clock: { clock.now })
            let gate = AsyncGate()
            h.backstop.armGate = gate
            controller.expand(mode: .start)
            controller.focus(.hours)
            XCTAssertTrue(controller.model.input.append(digit: 2, to: .hours))

            controller.commit()
            await gate.waitUntilStarted()
            XCTAssertEqual(controller.model.phase, .starting)
            XCTAssertEqual(controller.pendingTickArmed, style == .remaining, "\(style)")
            XCTAssertEqual(controller.model.pendingCountdown, MenuBarModel.projectedStart(now: clock.now, duration: 2 * 3600, maxDuration: manager.config.maxDuration, style: style).countdown(at: clock.now), "\(style)")
            await gate.open()
            let confirmBy = Date().addingTimeInterval(2)
            while controller.model.phase != .running, Date() < confirmBy {
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.model.phase, .running, "\(style)")
            await manager.end(reason: .user)
        }
    }

    /// The bar no longer shows the time left, so the right-click menu does.
    /// With the time left on the bar the menu is as it was.
    @MainActor
    func testTheMenuOffersTheTimeLeftOnlyWithTheEndTimeCountdown() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.start(duration: 2 * 3600 + 14 * 60)
        XCTAssertFalse(StatusItemController.menuItems(manager: manager, status: PlaceholderStatus()).map(\.title).contains { $0.hasPrefix("Time left") })

        manager.config.countdownStyle = .endTime
        manager.refreshCountdown()
        let titles = StatusItemController.menuItems(manager: manager, status: PlaceholderStatus()).map(\.title)
        XCTAssertTrue(titles.contains("Time left: 2h 14m"), "\(titles)")
    }

    /// The digits are read by a local key monitor, which only sees events sent
    /// to a window this app owns. The catcher panel is that window, and the
    /// panel must accept key status without taking clicks. It uses normal
    /// app activation so keys cannot remain routed to the previous app.
    @MainActor
    func testTheKeyCatcherPanelAcceptsKeysWithoutTakingClicks() {
        _ = NSApplication.shared
        let panel = KeyCatcherPanel()

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }

    /// Opening the pills has to put up the window that keyboard focus hangs
    /// off, and closing them has to take it away again.
    ///
    /// Key status itself cannot be asserted here: the test binary runs as a
    /// background-only process (`.prohibited`), which the window server never
    /// activates, so `NSApp.keyWindow` stays nil no matter what the app does.
    /// What is pinned instead is the panel's lifecycle, on top of the
    /// `canBecomeKey` contract above.
    @MainActor
    func testOpeningThePillsPutsUpTheKeyCatcherAndCollapsingTakesItDown() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})
        XCTAssertFalse(NSApp.windows.contains { $0 is KeyCatcherPanel && $0.isVisible })

        controller.expand(mode: .start)

        let panel = NSApp.windows.compactMap { $0 as? KeyCatcherPanel }.first { $0.isVisible }
        XCTAssertNotNil(panel)

        controller.collapse()

        XCTAssertFalse(panel?.isVisible ?? true)
        XCTAssertFalse(NSApp.windows.contains { $0 is KeyCatcherPanel && $0.isVisible })
    }

    @MainActor
    func testLosingKeyboardFocusClosesThePillsAndDropsTheKeyCatcher() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})
        // Off the item. On it, a lost focus waits out the press instead
        // (RefocusWait), which PillRefocusTests covers.
        controller.pointerLocation = { NSPoint(x: -10_000, y: -10_000) }
        controller.expand(mode: .start)
        let panel = NSApp.windows.compactMap { $0 as? KeyCatcherPanel }.first { $0.isVisible }
        XCTAssertNotNil(panel)

        panel?.resignKey()

        XCTAssertTrue(controller.model.pillsCollapsing)
        XCTAssertFalse(panel?.isVisible ?? true)
        XCTAssertFalse(controller.model.focusVisible)
        XCTAssertNil(panel?.onFocusLost)
    }

    /// Tests that open the popover must not leave it up for the next test.
    override func tearDown() {
        MainActor.assumeIsolated {
            for window in NSApp.windows where window.className.contains("Popover") && window.isVisible {
                window.orderOut(nil)
            }
        }
        super.tearDown()
    }

    /// In Popover style the bar's host draws over the status bar button and
    /// must never take a click: the button under it toggles the popover.
    /// In the other styles the host hit-tests as a plain hosting view of
    /// the same bar does, as on the base. On macOS 26 that view takes the
    /// click. On macOS 27 a hosting view in a test window can answer nil
    /// for itself, so there the check is only that the two agree.
    @MainActor
    func testTheBarHostLetsClicksThroughToTheButtonOnlyInPopoverStyle() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        func bar() -> StatusRootView {
            StatusRootView(model: MenuBarModel(), manager: manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in })
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 22), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = StatusItemController.makeHostingView(bar())
        let plain = NSHostingView(rootView: bar())
        plain.sizingOptions = host.sizingOptions
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 22)
        plain.frame = NSRect(x: 40, y: 0, width: 40, height: 22)
        window.contentView?.addSubview(host)
        window.contentView?.addSubview(plain)
        window.layoutIfNeeded()
        // A hit test takes a point in the superview's coordinates.
        let onHost = NSPoint(x: 10, y: 10)
        let plainTakesIt = plain.hitTest(NSPoint(x: 50, y: 10)) != nil
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 {
            XCTAssertTrue(plainTakesIt, "the bar takes its clicks in the view")
        }
        XCTAssertEqual(host.hitTest(onHost) != nil, plainTakesIt, "Pills, Compact and Minimal take their clicks as on the base")
        host.passesClicksThrough = true
        XCTAssertNil(host.hitTest(onHost))
        host.passesClicksThrough = false
        XCTAssertEqual(host.hitTest(onHost) != nil, plainTakesIt)
    }

    /// Only Popover style gives the button an action; a style change moves
    /// the clicks over at once, in both directions.
    @MainActor
    func testOnlyPopoverStyleRoutesClicksToTheButton() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        let button = try! XCTUnwrap(controller.nativeStatusItem.button)
        let host = try! XCTUnwrap(button.subviews.compactMap { $0 as? StatusHostingView }.first)
        func routed() -> Bool { button.action != nil || button.target != nil || host.passesClicksThrough }
        XCTAssertFalse(routed(), "Pills, the default, keeps the base's click handling")
        for mode in [Config.MenuBarMode.compact, .minimal] {
            manager.config.menuBarMode = mode
            controller.synchronizePresentation()
            XCTAssertFalse(routed(), "\(mode)")
        }
        manager.config.menuBarMode = .popover
        controller.synchronizePresentation()
        XCTAssertTrue(host.passesClicksThrough)
        XCTAssertTrue(button.target === controller)
        XCTAssertNotNil(button.action)
        manager.config.menuBarMode = .pills
        controller.synchronizePresentation()
        XCTAssertFalse(routed(), "leaving Popover takes the button's action away again")
    }

    /// Popover style's bar is the eye, closed while idle, and beside it a
    /// short countdown while a session runs or starts. Typing in the
    /// popover's fields never reaches it, and with the countdown turned off
    /// in Settings the bar is the eye alone at one width.
    @MainActor
    func testThePopoverBarIsTheEyeAndAShortCountdownWhileASessionRuns() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        manager.config.menuBarMode = .popover
        let model = MenuBarModel()
        func width() -> CGFloat {
            StatusItemController.makeHostingView(StatusRootView(model: model, manager: manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in })).fittingSize.width
        }
        let idle = width()
        XCTAssertEqual(idle, StatusRootView.width, accuracy: 0.5, "the item hugs the eye, like the system's own icons")
        model.texts = [.days: "12", .hours: "3", .minutes: "45"]
        model.popoverShown = true
        XCTAssertEqual(width(), idle, accuracy: 0.001, "the fields live in the popover, not the bar")

        await manager.start(duration: 2 * 3600 + 31 * 60)
        model.phase = .running
        XCTAssertEqual(manager.remainingText, "2h 31m")
        let running = width()
        XCTAssertGreaterThan(running, idle + 20, "the short countdown sits beside the eye")
        model.texts = [:]
        XCTAssertEqual(width(), running, accuracy: 0.001)
        model.phase = .starting
        model.pendingCountdown = "2h"
        XCTAssertGreaterThan(width(), idle + 10, "a pending start shows its projection")

        manager.config.showMenuBarCountdown = false
        XCTAssertEqual(width(), idle, accuracy: 0.001, "the countdown switch applies to Popover style too")
        model.phase = .running
        model.pendingCountdown = nil
        XCTAssertEqual(width(), idle, accuracy: 0.001, "and to a running session")
    }

    /// The short countdown follows the countdown style: the time left to
    /// the minute, or the end time. VoiceOver reads the session either way,
    /// and names an end time for what it is.
    @MainActor
    func testThePopoverBarCountdownFollowsTheCountdownStyle() {
        XCTAssertEqual(StatusRootView.popoverLiveCountdown(style: .remaining, remaining: "2h 14m", endTime: "17:30"), "2h 14m")
        XCTAssertEqual(StatusRootView.popoverLiveCountdown(style: .endTime, remaining: "2h 14m", endTime: "17:30"), "17:30")
        func value(running: Bool = true, starting: Bool = false, _ style: CountdownStyle, remaining: String = "2h 14m", endTime: String = "17:30") -> String {
            StatusRootView.popoverAccessibilityValue(running: running, starting: starting, style: style, remaining: remaining, endTime: endTime)
        }
        XCTAssertEqual(value(.remaining), "Awake, 2h 14m left")
        XCTAssertEqual(value(.endTime), "Awake, ends at 17:30")
        XCTAssertEqual(value(.remaining, remaining: ""), "Awake")
        XCTAssertEqual(value(running: false, starting: true, .remaining), "Starting session")
        XCTAssertEqual(value(running: false, .endTime), "Idle")
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
        // Through any end, with the session still active or already cleared.
        XCTAssertEqual(
            StatusPopoverView.headerText(phase: .running, ending: true, session: today, remaining: "2h 31m", now: now, calendar: calendar),
            MenuBarModel.endingText
        )
        XCTAssertEqual(
            StatusPopoverView.headerText(phase: .idle, ending: true, session: nil, remaining: "", now: now, calendar: calendar),
            MenuBarModel.endingText
        )
    }

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
        let hidden = StatusLines.machine(lidClosed: false, watts: nil, wifi: WiFiStatusName.row(ssid: nil, locationAuthorized: false), batteryPercent: nil, isCharging: false)
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
        // Plugged in but draining, with a time to full from the system:
        // neither "Charging" nor "to full" (2f582a26).
        XCTAssertEqual(title(-5.6, 62, charging: true, .untilFull(minutes: 70)), "62% \u{00B7} On power adapter \u{00B7} 5.6 W")
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
        XCTAssertEqual(StatusLines.actionRows(frozenCount: 0, dockerPaused: false, lastGap: nil), [])
        XCTAssertEqual(StatusLines.actionRows(frozenCount: 3, dockerPaused: true, lastGap: nil), [
            StatusMenu.Item(title: "3 apps frozen", kind: .info, symbol: "snowflake"),
            StatusMenu.Item(title: "Docker paused", kind: .info, symbol: "shippingbox"),
        ])
        XCTAssertEqual(StatusLines.actionRows(frozenCount: 1, dockerPaused: false, lastGap: 12.4).map(\.title), ["1 app frozen", "Last network gap 12s"])
        XCTAssertEqual(StatusLines.actionRows(frozenCount: 0, dockerPaused: true, lastGap: 0).map(\.title), ["Docker paused"])
    }

    func testThrottleWarningInThePopover() {
        XCTAssertNil(StatusLines.throttleWarning([]))
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome"]), "Chrome is throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc"]), "Chrome and Arc are throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc", "Chromium"]), "Chrome, Arc, and Chromium are throttled")
    }

    /// Facts first (the machine, what is held), then warnings,
    /// each relaunch button on the throttle warning's row. Settings and
    /// Quit are the footer, not rows.
    func testRowsListFactsThenWarningsWithTheirButtons() {
        let machine = StatusLines.machine(lidClosed: true, watts: nil, wifi: nil, batteryPercent: 82, isCharging: false)
        let actions = StatusLines.actionRows(frozenCount: 3, dockerPaused: false, lastGap: nil)
        let items = StatusMenu.popoverItems(
            sessionActive: true,
            sleepHeld: true,
            machine: machine,
            actions: actions,
            throttledBrowsers: [Self.chrome],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Lid closed", kind: .info, symbol: "laptopcomputer"),
            StatusMenu.Item(title: "82%", kind: .info, symbol: "battery.75percent"),
            StatusMenu.Item(title: "3 apps frozen", kind: .info, symbol: "snowflake"),
            StatusMenu.Item(title: "Chrome is throttled", kind: .warning),
            StatusMenu.Item(title: "Relaunch Chrome unthrottled", kind: .relaunchBrowser(Self.chrome)),
        ])
        let rows = StatusMenu.rows(items)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.last, StatusMenu.Row(item: items[3], actions: [items[4]]))
    }

    func testIdleRowsAreEmpty() {
        let items = StatusMenu.popoverItems(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "")
        XCTAssertEqual(items, [])
        XCTAssertEqual(StatusMenu.rows(items), [])
    }

    func testRowsShowTheLastErrorAsAWarning() {
        let items = StatusMenu.popoverItems(sessionActive: false, sleepHeld: false, throttledBrowsers: [], error: "sudo: a password is required")
        XCTAssertEqual(items, [StatusMenu.Item(title: "sudo: a password is required", kind: .warning)])
    }

    /// A hotspot join skipped for want of a password is a warning row,
    /// between the browser row and the session error, so the failure is
    /// never silent.
    func testRowsShowTheHotspotPasswordProblemAsAWarning() {
        let items = StatusMenu.popoverItems(
            sessionActive: true,
            sleepHeld: true,
            throttledBrowsers: [Self.chrome],
            hotspotWarning: HotspotPasswordProblem.unreadable.menuLine,
            error: "sudo: a password is required"
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.warning, .relaunchBrowser(Self.chrome), .warning, .warning]
        )
        XCTAssertEqual(items[2], StatusMenu.Item(
            title: "Hotspot password unreadable by this build: enter it again in Settings",
            kind: .warning
        ))
        XCTAssertEqual(
            StatusMenu.popoverItems(sessionActive: false, sleepHeld: false, throttledBrowsers: [], hotspotWarning: nil, error: nil),
            []
        )
    }

    /// Greptile caught this as a regression once: a throttle warning with
    /// no way to act on it. Every throttled browser keeps its own button.
    func testEveryThrottledBrowserGetsItsOwnRelaunchButton() {
        let items = StatusMenu.popoverItems(
            sessionActive: true,
            sleepHeld: true,
            throttledBrowsers: [Self.chrome, Self.arc],
            error: nil
        )
        XCTAssertEqual(
            items.map(\.kind),
            [.warning, .relaunchBrowser(Self.chrome), .relaunchBrowser(Self.arc)]
        )
        XCTAssertEqual(StatusMenu.rows(items).last?.actions.map(\.kind), [.relaunchBrowser(Self.chrome), .relaunchBrowser(Self.arc)])
    }

    /// The popover reads the watts when it opens and when the battery
    /// changes while it is up. Its redraws read the last reading, so typing
    /// in its fields reads IOKit not at all.
    @MainActor
    func testThePopoverReadsTheWattsOnOpenAndOnABatteryChangeOnly() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = CountingStatusSource()
        source.watts = -6.5
        let controller = StatusItemController(manager: popoverManager(h), status: source, showSettings: {})
        controller.openPopover()
        XCTAssertEqual(controller.model.popoverPower?.watts, -6.5)
        let reads = source.powerReads
        let view = controller.makePopoverView()
        _ = view.items()
        controller.model.texts[.hours] = "2"
        _ = view.items()
        XCTAssertEqual(source.powerReads, reads, "redraws read the last reading")

        source.watts = 12
        source.isCharging = true
        for _ in 0..<200 where controller.model.popoverPower?.watts != 12 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.popoverPower?.watts, 12, "a battery change reads them again")
        controller.closePopover()
        let closed = source.powerReads
        source.isCharging = false
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(source.powerReads, closed, "nothing is read while the popover is closed")
    }

    /// The watts and the time left move with no change in the percent or
    /// the charging state, so an open popover reads them again on a timer,
    /// and stops when it closes.
    @MainActor
    func testAnOpenPopoverReadsThePowerAgainWithNoBatteryChange() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = CountingStatusSource()
        source.watts = -6.5
        let controller = StatusItemController(manager: popoverManager(h), status: source, showSettings: {})
        controller.popoverPowerInterval = 0.05
        controller.openPopover()
        XCTAssertEqual(controller.model.popoverPower?.watts, -6.5)
        source.watts = -9
        for _ in 0..<200 where controller.model.popoverPower?.watts != -9 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.popoverPower?.watts, -9)
        controller.closePopover()
        let closed = source.powerReads
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(source.powerReads, closed, "nothing is read while the popover is closed")
        XCTAssertNil(controller.popoverPowerTick)
    }

    /// A controller released with the popover up stops its power timer
    /// the next time it fires.
    @MainActor
    func testAReleasedControllerStopsThePopoverPowerTimer() async throws {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = CountingStatusSource()
        weak var released: StatusItemController?
        var timer: Timer?
        do {
            let controller = StatusItemController(manager: popoverManager(h), status: source, showSettings: {})
            controller.popoverPowerInterval = 0.05
            controller.openPopover()
            timer = controller.popoverPowerTick
            released = controller
        }
        for _ in 0..<100 where released != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try XCTSkipIf(released != nil, "the controller is still held elsewhere")
        let tick = try XCTUnwrap(timer)
        for _ in 0..<100 where tick.isValid {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(tick.isValid)
    }

    /// One popover, toggled by the item: the first click opens it on fresh
    /// status and empty fields, the next closes it.
    @MainActor
    func testClickingTheItemTogglesOnePopover() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let source = CountingStatusSource()
        let controller = StatusItemController(manager: popoverManager(h), status: source, showSettings: {})
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
        let controller = StatusItemController(
            manager: popoverManager(h), status: PlaceholderStatus(), showSettings: {}, appFocus: Self.quietFocus
        )
        controller.popoverAnchor = window.contentView
        return (controller, window)
    }

    /// Reads Insomnia as already in front, so opening a popover in a test
    /// neither activates the test runner nor gives focus to another app.
    @MainActor
    static var quietFocus: CompactDropdownController.AppFocus {
        CompactDropdownController.AppFocus(
            frontmost: { nil }, isActive: { true }, hasKeyWindow: { false }, activate: {}, yield: { _ in }
        )
    }

    /// A manager in Popover style, the one style with the popover.
    @MainActor
    private func popoverManager(_ h: Harness) -> SessionManager {
        let manager = h.makeManager()
        manager.config.menuBarMode = .popover
        return manager
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
        controller.dismissUnlessOnItemOrPopover(at: NSPoint(x: window.frame.midX, y: window.frame.midY))
        XCTAssertTrue(controller.model.popoverShown, "on the item: left to its action")
        controller.togglePopover()
        XCTAssertFalse(controller.model.popoverShown, "the item's action closes it")
        XCTAssertEqual(controller.popover?.isShown, false)

        controller.togglePopover()
        controller.dismissUnlessOnItemOrPopover(at: NSPoint(x: window.frame.minX - 40, y: window.frame.midY))
        XCTAssertFalse(controller.model.popoverShown, "a click elsewhere closes it")
        XCTAssertEqual(controller.popover?.isShown, false)
    }

    /// A click in another of the app's windows (Settings) closes the
    /// popover; a click in the popover, or on the item (whose action
    /// toggles), does not. A click that comes with no window goes by its
    /// place on screen.
    @MainActor
    func testAClickInAnotherWindowClosesThePopover() throws {
        let h = Harness()
        defer { h.home.destroy() }
        let (controller, window) = anchoredController(h)
        defer { window.orderOut(nil) }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        controller.openPopover()
        let popoverWindow = try XCTUnwrap(controller.popover?.contentViewController?.view.window)
        let inPopover = NSPoint(x: popoverWindow.frame.midX, y: popoverWindow.frame.midY)
        let onItem = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let elsewhere = NSPoint(x: window.frame.minX - 40, y: window.frame.midY)
        controller.clickedInApp(window: popoverWindow, at: inPopover)
        XCTAssertTrue(controller.model.popoverShown, "its own controls")
        controller.clickedInApp(window: window, at: onItem)
        XCTAssertTrue(controller.model.popoverShown, "the item: its action toggles")
        controller.clickedInApp(window: nil, at: inPopover)
        controller.clickedInApp(window: nil, at: onItem)
        XCTAssertTrue(controller.model.popoverShown, "no window, but on the popover or the item")
        controller.clickedInApp(window: nil, at: elsewhere)
        XCTAssertFalse(controller.model.popoverShown, "no window, elsewhere")
        controller.openPopover()
        controller.clickedInApp(window: other, at: inPopover)
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
        let controller = StatusItemController(manager: popoverManager(h), status: source, showSettings: {})
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
        let controller = StatusItemController(manager: popoverManager(h), status: source, showSettings: {})
        func size(cap: CGFloat) -> NSSize {
            var view = controller.makePopoverView()
            view.maxScrollHeight = cap
            return NSHostingView(rootView: view).fittingSize
        }
        let short = size(cap: 10_000)
        XCTAssertEqual(size(cap: 2_000).height, short.height, accuracy: 0.5, "under the cap the popover hugs its content")

        source.relaunchProblems = (1...14).map { "Browser \($0) quit but could not be relaunched, open it yourself and check its windows." }
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
        let manager = popoverManager(h)
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
        let manager = popoverManager(h)
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
        let manager = popoverManager(h)
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
        let controller = StatusItemController(manager: popoverManager(h), status: PlaceholderStatus(), showSettings: { opened.value += 1 })
        controller.openPopover()
        controller.openSettingsFromPopover()
        XCTAssertFalse(controller.model.popoverShown)
        XCTAssertEqual(opened.value, 1)
    }

    /// The fields are read through `DurationInput`: blank is empty, a value
    /// over its ceiling or anything that is not a whole number is invalid.
    @MainActor
    func testTheFieldsAreValidatedByDurationInput() {
        let model = MenuBarModel()
        XCTAssertTrue(model.popoverInput.isEmpty)
        model.texts = [.hours: "2", .minutes: " 30 "]
        XCTAssertEqual(model.popoverInput.total, 2 * 3600 + 30 * 60)
        model.texts = [.hours: "24"]
        XCTAssertFalse(model.popoverInput.isValid(.hours))
        XCTAssertNil(model.popoverInput.total)
        model.texts = [.minutes: "1.5"]
        XCTAssertFalse(model.popoverInput.isValid(.minutes))
        model.texts = [.days: "-1"]
        XCTAssertFalse(model.popoverInput.isValid(.days))
        model.texts = [.days: "", .hours: "  "]
        XCTAssertTrue(model.popoverInput.isEmpty)
    }

    /// Something typed that is not a duration shakes the fields; it never
    /// falls back to the default preset the way empty fields do.
    @MainActor
    func testAnInvalidValueShakesAndStartsNothing() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = popoverManager(h)
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
        let manager = popoverManager(h)
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
        let controller = StatusItemController(manager: popoverManager(h), status: PlaceholderStatus(), showSettings: {})
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
        let manager = popoverManager(h)
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

    /// With the countdown off, the status item's width is written once, at
    /// install: a session and the popover never move the bar. With it on,
    /// it is written once when a session starts and once when it ends.
    /// Opening the popover, typing into it and closing it never move it.
    @MainActor
    func testTheWidthIsWrittenOnceAndNeverChangesForASessionOrThePopover() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = popoverManager(h)
        manager.config.showMenuBarCountdown = false
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

        // The countdown on: one write as the session starts, one as it ends.
        manager.config.showMenuBarCountdown = true
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, 1, "nothing to show while idle")
        await manager.start(duration: 3600)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.widthTargetChangeCount, 2)
        XCTAssertGreaterThan(controller.widthTarget, idle)
        controller.openPopover()
        controller.model.texts = [.hours: "2"]
        controller.closePopover()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTargetChangeCount, 2)
        await manager.end(reason: .user)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(controller.widthTargetChangeCount, 3)
        XCTAssertEqual(controller.widthTarget, idle)
        XCTAssertEqual(probe.applied.count, 3)
    }

    /// While the recovery agent and pmset run, the projected countdown ticks
    /// like the live one will, and the tick stops the moment the session is
    /// confirmed and the live text takes over.
    @MainActor
    func testTheProjectedCountdownTicksWhileStartingAndStopsOnConfirmationInThePopover() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = popoverManager(h)
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

    /// Only the two mismatches are said; a session holding sleep has the
    /// countdown and no line.
    func testSleepHeldWarning() {
        XCTAssertNil(SleepHeldLine.warning(sessionActive: true, sleepHeld: true))
        XCTAssertEqual(
            SleepHeldLine.warning(sessionActive: true, sleepHeld: false),
            "Sleep is not held, so this session is not keeping the Mac awake"
        )
        XCTAssertEqual(SleepHeldLine.warning(sessionActive: false, sleepHeld: true), "Sleep still held with no session")
        XCTAssertNil(SleepHeldLine.warning(sessionActive: false, sleepHeld: false))
    }
}

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
    /// What the watts read reports, and how many times it was read.
    var watts: Double?
    @ObservationIgnored private(set) var powerReads = 0

    func refreshOnDemand() { onDemand += 1 }
    func refreshInstant() { instant += 1 }
    func instantWatts() -> Double? {
        powerReads += 1
        return watts
    }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) {}
}
