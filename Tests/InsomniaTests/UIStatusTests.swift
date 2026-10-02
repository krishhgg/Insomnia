import AppKit
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
        XCTAssertNil(s.instantWatts())
        s.refreshInstant()
        s.refreshOnDemand()
        s.relaunchUnthrottled("Chrome")
    }

    func testMachineLine() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: true, watts: 4.12, wifiSSID: "iPhone", batteryPercent: nil, isCharging: false),
            "Lid: closed \u{00B7} 4.1 W \u{00B7} Wi-Fi: iPhone"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: nil, batteryPercent: nil, isCharging: false),
            "Lid: open"
        )
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: "", batteryPercent: 82, isCharging: true),
            "Lid: open \u{00B7} 82% charging"
        )
    }

    func testActionsLine() {
        XCTAssertNil(StatusLines.actions(frozenCount: 0, dockerPaused: false, lastGap: nil))
        XCTAssertEqual(StatusLines.actions(frozenCount: 3, dockerPaused: true, lastGap: nil), "3 apps frozen \u{00B7} Docker paused")
        XCTAssertEqual(StatusLines.actions(frozenCount: 1, dockerPaused: false, lastGap: 12.4), "1 app frozen \u{00B7} last gap 12s")
        XCTAssertEqual(StatusLines.actions(frozenCount: 0, dockerPaused: true, lastGap: 0), "Docker paused")
    }

    func testThrottleWarning() {
        XCTAssertNil(StatusLines.throttleWarning([]))
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome"]), "\u{26A0} Chrome is throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc"]), "\u{26A0} Chrome and Arc are throttled")
        XCTAssertEqual(StatusLines.throttleWarning(["Chrome", "Arc", "Chromium"]), "\u{26A0} Chrome, Arc, and Chromium are throttled")
    }

    func testMenuListsStatusThenSettingsAndQuit() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: "Lid: closed \u{00B7} 82%",
            actions: "3 apps frozen",
            throttledBrowsers: ["Chrome"],
            error: nil
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Sleep held per journal \u{2014} not verified live", kind: .info),
            StatusMenu.Item(title: "Lid: closed \u{00B7} 82%", kind: .info),
            StatusMenu.Item(title: "3 apps frozen", kind: .info),
            StatusMenu.Item(title: "\u{26A0} Chrome is throttled", kind: .warning),
            StatusMenu.Item(title: "Relaunch Chrome unthrottled", kind: .relaunchBrowser("Chrome")),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
    }

    func testIdleMenuIsJustSettingsAndQuitWithNoLeadingSeparator() {
        let items = StatusMenu.items(
            sessionActive: false,
            sleepHeld: false,
            machine: nil,
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
            actions: nil,
            throttledBrowsers: [],
            error: "sudo: a password is required"
        )
        XCTAssertEqual(items.first, StatusMenu.Item(title: "\u{26A0} sudo: a password is required", kind: .warning))
        XCTAssertEqual(items.map(\.kind), [.warning, .separator, .settings, .quit])
    }

    /// Greptile caught this as a regression: replacing the popover with a
    /// menu left the throttle warning with no way to act on it.
    func testEveryThrottledBrowserGetsItsOwnRelaunchItem() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: nil,
            actions: nil,
            throttledBrowsers: ["Chrome", "Arc"],
            error: nil
        )
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser("Chrome") }.count, 1)
        XCTAssertEqual(items.filter { $0.kind == .relaunchBrowser("Arc") }.count, 1)
        XCTAssertEqual(
            items.map(\.kind),
            [.info, .warning, .relaunchBrowser("Chrome"), .relaunchBrowser("Arc"), .separator, .settings, .quit]
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
        try? await Task.sleep(for: .milliseconds(Int(Motion.retractSettleDuration * 1000) + 100))
        XCTAssertFalse(controller.model.slotsPresent)
        XCTAssertFalse(controller.model.pillsCollapsing, "the fold ends with the slots")
        XCTAssertEqual(controller.model.phase, .idle)
        try? await Task.sleep(for: .milliseconds(100))
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
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.widthTarget, lab.widthWithoutSlots(phase: .starting), "the width snaps once, after the slots left")
        XCTAssertEqual(lab.probe.applied.count, written + 1)
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
        XCTAssertEqual(lab.probe.applied.count, written + 1, "one write, after the slots left")
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
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
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
        // Partial seconds round up, so the first whole second can still read
        // 2:00:00; the second one cannot.
        let deadline = Date().addingTimeInterval(2.5)
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
        XCTAssertEqual(manager.countdownText, "2:00:00")
    }

    /// The digits are read by a local key monitor, which only sees events sent
    /// to a window this app owns. The catcher panel is that window, and the
    /// whole fix rests on it being able to take key without taking a click,
    /// and without activating this app: the app in front stays frontmost and
    /// only key status moves to the pills while they are up.
    @MainActor
    func testTheKeyCatcherPanelTakesKeyStatusWithoutTakingClicksOrActivating() {
        _ = NSApplication.shared
        let panel = KeyCatcherPanel()

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
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
}
