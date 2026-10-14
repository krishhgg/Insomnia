import AppKit
import XCTest
@testable import Insomnia

/// A start from the popover, from the click to the helper's answer.
///
/// The bug this pins: the status item used to switch to the running layout
/// the moment a start was asked for, before the manager had confirmed
/// anything. When the recovery agent then took seconds to refuse, the user
/// sat on an open eye and a countdown with no session behind them. The
/// start has a phase of its own, the running controls only appear for a
/// confirmed session, and a refusal is said in the popover, with the typed
/// value still in its fields.
final class UIStartupTests: XCTestCase {
    /// A refused start leaves the popover up. Tests that end there must
    /// not leave it up for the next test.
    override func tearDown() {
        MainActor.assumeIsolated {
            for window in NSApp.windows where window.className.contains("Popover") && window.isVisible {
                window.orderOut(nil)
            }
        }
        super.tearDown()
    }

    @MainActor
    private struct Rig {
        let h: Harness
        let manager: SessionManager
        let controller: StatusItemController

        init() {
            _ = NSApplication.shared
            h = Harness()
            manager = h.makeManager()
            // The manager's fake clock, so the projected countdown reads the
            // same minute however late a test reads it.
            let clock = h.clock
            controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, clock: { clock.now })
        }

        var model: MenuBarModel { controller.model }

        /// Open the popover and type "1" into Days.
        func openAndTypeOneDay() {
            controller.openPopover()
            model.texts[.days] = "1"
            XCTAssertEqual(model.input.total, 86400)
        }

        /// A second host over the controller's model, so what the item would
        /// draw can be measured without a live menu bar.
        func measuredWidth() -> CGFloat {
            let root = StatusRootView(model: model, manager: manager, onWidthChange: { _ in })
            return StatusItemController.makeHostingView(root).fittingSize.width
        }

        func idleWidth() -> CGFloat {
            let root = StatusRootView(model: MenuBarModel(), manager: manager, onWidthChange: { _ in })
            return StatusItemController.makeHostingView(root).fittingSize.width
        }
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

    // MARK: Success

    @MainActor
    func testStartShowsStartingWithoutRunningControlsUntilTheManagerConfirms() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.openAndTypeOneDay()
        let idleWidth = rig.idleWidth()

        rig.controller.commit()
        await gate.waitUntilStarted()

        // Pending, readable, and nothing that only a live session may show.
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertFalse(rig.model.phase.showsRunningControls)
        // The countdown the session will read is projected the moment the
        // start is asked for; the live one replaces it on confirmation.
        XCTAssertEqual(rig.model.pendingCountdown, "1d")
        XCTAssertEqual(MenuBarModel.startingText, "Starting\u{2026}")
        XCTAssertNil(rig.model.startError)
        // The typed value survives the wait, in case the start is refused.
        XCTAssertEqual(rig.model.input.total, 86400)
        XCTAssertTrue(rig.model.popoverShown, "the popover stays up until the answer")
        // The pending start opens the eye in place; the item keeps its width.
        XCTAssertEqual(rig.measuredWidth(), idleWidth)

        await gate.open()
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertTrue(rig.model.phase.showsRunningControls)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertNil(rig.model.startError)
        XCTAssertEqual(rig.manager.countdownText, "1d 0:00:00")
        XCTAssertEqual(rig.manager.remainingText, "1d")
        XCTAssertEqual(rig.h.backstop.arms, 1)
        let spent = await waitUntil { rig.model.texts.isEmpty }
        XCTAssertTrue(spent, "a confirmed start spends the typed value")
        XCTAssertTrue(rig.model.popoverShown, "the popover stays open on the session; the user closes it")
        XCTAssertFalse(rig.model.customShown, "the fields are put away")
        rig.controller.closePopover()
    }

    /// A start that lands after the popover was closed and opened again
    /// leaves the new popover alone: that one is the user's.
    @MainActor
    func testAStartLandingAfterAReopenLeavesThePopoverOpen() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.openAndTypeOneDay()
        rig.controller.commit()
        await gate.waitUntilStarted()
        rig.controller.closePopover()
        rig.controller.openPopover()
        await gate.open()
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(rig.model.popoverShown, "the reopened popover stays")
        rig.controller.closePopover()
    }

    /// The manager records sleep as held before the session lands, so a
    /// start in flight looks like a hold with no session. That is the start
    /// on its way: the popover must not warn "Sleep still held with no
    /// session" over it. A hold genuinely left behind still warns.
    @MainActor
    func testAStartInFlightDoesNotWarnThatSleepIsHeldWithNoSession() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.openPopover()
        rig.controller.startPreset(3600)
        await gate.waitUntilStarted()
        XCTAssertTrue(rig.manager.state.sleepDisabledByUs, "journaled before the session lands")
        XCTAssertFalse(rig.manager.isActive)
        let warning = "Sleep still held with no session"
        func titles(starting: Bool) -> [String] {
            StatusItemController.statusItems(manager: rig.manager, status: PlaceholderStatus(), starting: starting).map(\.title)
        }
        XCTAssertFalse(titles(starting: rig.model.phase == .starting).contains(warning))
        XCTAssertTrue(titles(starting: false).contains(warning), "with no start in flight it is a real orphaned hold")
        await gate.open()
        let ok = await waitUntil { rig.manager.isActive }
        XCTAssertTrue(ok)
        rig.controller.closePopover()
    }

    /// Bare Enter (default preset) goes through the same pending phase.
    @MainActor
    func testBareEnterAlsoWaitsInStartingBeforeRunning() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.openPopover()

        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .starting)

        await gate.open()
        let ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.manager.countdownText, "4:00:00")
    }

    // MARK: Failure

    @MainActor
    func testImmediateHelperFailureKeepsTheValueAndSaysWhyInThePopover() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.openAndTypeOneDay()

        rig.controller.commit()
        let ok = await waitUntil { rig.model.startError != nil }
        XCTAssertTrue(ok)

        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertEqual(rig.model.texts[.days], "1")
        XCTAssertEqual(rig.model.input.total, 86400)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertFalse(rig.controller.pendingTickArmed)
        // The popover has room for the manager's own words.
        XCTAssertEqual(rig.model.startError, "could not arm backstop: fake launchd refused")
        XCTAssertEqual(rig.manager.lastError, rig.model.startError)
        XCTAssertTrue(rig.model.popoverShown, "the popover stays up to say so")
        XCTAssertEqual(rig.measuredWidth(), rig.idleWidth(), "the bar is back to the eye alone")
    }

    /// A refusal with no reason from the manager still says something.
    @MainActor
    func testAStartErrorWithNoReasonFallsBackToAShortLine() {
        XCTAssertEqual(StatusItemController.startErrorText(nil), MenuBarModel.startFailedText)
        XCTAssertEqual(StatusItemController.startErrorText(" "), MenuBarModel.startFailedText)
        XCTAssertEqual(StatusItemController.startErrorText("sudo: a password is required"), "sudo: a password is required")
    }

    @MainActor
    func testDelayedHelperFailureLeavesStartingThenReportsIt() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.openAndTypeOneDay()

        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertNil(rig.model.startError)

        await gate.open()
        let ok = await waitUntil { rig.model.startError != nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertEqual(rig.model.input.total, 86400)
        XCTAssertFalse(rig.manager.isActive)
    }

    @MainActor
    func testFailureThenRetrySucceedsAndClearsTheError() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.openAndTypeOneDay()
        rig.controller.commit()
        var ok = await waitUntil { rig.model.startError != nil }
        XCTAssertTrue(ok)

        rig.h.backstop.failArm = false
        rig.controller.commit()
        // The error goes with the retry, not only with its success.
        XCTAssertNil(rig.model.startError)
        ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertTrue(rig.manager.isActive)
        XCTAssertNil(rig.model.startError)
        XCTAssertEqual(rig.manager.countdownText, "1d 0:00:00")
    }

    /// Closing the popover over a refusal and opening it again brings the
    /// refused value and the reason back; a session coming up clears both.
    @MainActor
    func testAStartErrorSurvivesAReopenAndClearsWhenASessionStarts() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.openAndTypeOneDay()
        rig.controller.commit()
        var ok = await waitUntil { rig.model.startError != nil }
        XCTAssertTrue(ok)

        rig.controller.closePopover()
        rig.controller.openPopover()
        XCTAssertNotNil(rig.model.startError)
        XCTAssertEqual(rig.model.texts[.days], "1")
        XCTAssertTrue(rig.model.customShown, "the fields are out to show the refused value")

        rig.h.backstop.failArm = false
        await rig.manager.start(duration: 3600)
        ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertNil(rig.model.startError)
        rig.controller.closePopover()
    }

    // MARK: Pending interactions

    @MainActor
    func testRepeatStartsAndClicksWhilePendingAreIgnored() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.openAndTypeOneDay()
        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .starting)
        let bounces = rig.model.rejectBounce

        // Enter again, a preset chip, an extend chip, the end ring: none of
        // them may start a second session or leave the pending phase.
        rig.controller.commit()
        rig.controller.startPreset(3600)
        rig.controller.extendBy(3600)
        rig.controller.holdToEnd()
        await settleQueuedRequests()
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertEqual(rig.model.rejectBounce, bounces)
        XCTAssertFalse(rig.manager.isActive)

        await gate.open()
        let ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertEqual(rig.h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
    }

    /// Two extends in a row, the second asked for while the first is still
    /// waiting on the helper. The manager answers them in order, so the
    /// first one's completion lands while the second is still pending; it
    /// must not clear what the second is showing.
    @MainActor
    func testAnOlderExtendCompletionDoesNotClearTheNewerPendingProjection() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        var ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)

        // First extend, held at the helper.
        let first = AsyncGate()
        rig.h.backstop.armGate = first
        rig.controller.openPopover()
        rig.model.texts[.hours] = "1"
        rig.controller.commit()
        await first.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertEqual(rig.model.pendingCountdown, "2h")

        // Second extend, typed while the first waits. It queues behind the
        // first in the manager and is held at a gate of its own.
        let second = AsyncGate()
        rig.h.backstop.armGate = second
        rig.model.texts[.hours] = "2"
        rig.controller.commit()
        await settleQueuedRequests()
        XCTAssertEqual(rig.model.phase, .running)
        let projection = rig.model.pendingCountdown
        XCTAssertNotNil(projection)

        // The first completes and the second reaches the helper. The
        // projection on screen belongs to the second, which is still pending.
        await first.open()
        await second.waitUntilStarted()
        await settleQueuedRequests()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.manager.countdownText, "2:00:00")
        XCTAssertEqual(rig.model.pendingCountdown, projection)
        XCTAssertEqual(rig.model.phase, .running)

        await second.open()
        ok = await waitUntil { rig.model.pendingCountdown == nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.manager.countdownText, "4:00:00")
        XCTAssertEqual(rig.model.phase, .running)
    }

    // MARK: Running controls

    /// `.running` on its own does not prove a session: the phase can lag
    /// the manager by a hop when a session ends. Neither state widens the
    /// bar; the eye opens in place.
    @MainActor
    func testRunningControlsNeedBothTheRunningPhaseAndALiveSession() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        XCTAssertEqual(rig.model.phase, .idle)
        let idleWidth = rig.measuredWidth()

        // Running phase with no session behind it: the bare mark, nothing else.
        rig.model.phase = .running
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertTrue(rig.model.phase.showsRunningControls)
        XCTAssertEqual(rig.measuredWidth(), idleWidth)

        // A confirmed session opens the eye in place; still no countdown.
        await rig.manager.start(duration: 3600)
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.measuredWidth(), idleWidth)
    }

    // MARK: Pure transitions

    @MainActor
    func testOnlyARunningPhaseShowsRunningControls() {
        XCTAssertFalse(MenuBarModel.Phase.starting.showsRunningControls)
        XCTAssertFalse(MenuBarModel.Phase.idle.showsRunningControls)
        XCTAssertTrue(MenuBarModel.Phase.running.showsRunningControls)
    }

    /// Extending keeps the session's controls: the session is live, so the
    /// countdown stays up while the extend is in flight.
    @MainActor
    func testExtendStaysOnTheRunningControlsWhileInFlight() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        var ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.openPopover()
        XCTAssertEqual(rig.controller.mode, .extend)
        rig.model.texts[.hours] = "1"

        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertNotNil(rig.model.pendingCountdown)

        await gate.open()
        ok = await waitUntil { rig.model.pendingCountdown == nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertEqual(rig.manager.countdownText, "2:00:00")
        ok = await waitUntil { rig.model.texts.isEmpty }
        XCTAssertTrue(ok, "a confirmed extend spends the typed value")
        XCTAssertTrue(rig.model.popoverShown, "and leaves the popover open")
        rig.controller.closePopover()
    }

    /// Bare Enter while extending shakes: there is no default extension.
    @MainActor
    func testBareEnterWhileRunningShakesInsteadOfExtending() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        rig.controller.openPopover()
        rig.controller.commit()
        XCTAssertEqual(rig.model.rejectBounce, 1)
        await settleQueuedRequests()
        XCTAssertEqual(rig.manager.countdownText, "1:00:00")
        rig.controller.closePopover()
    }

    /// The user ends the session while an extend is still waiting on the
    /// helper. The manager abandons the extend and ends; the item goes idle
    /// and stays there, with no start error for an extend that was never
    /// a start.
    @MainActor
    func testEndingTheSessionWhileAnExtendIsPendingLeavesTheItemIdleWithoutAnError() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        var ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.openPopover()
        rig.model.texts[.hours] = "1"
        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .running)

        // Hold-to-end while the extend waits: the end queues behind it and
        // invalidates it.
        rig.controller.holdToEnd()
        await settleQueuedRequests()
        await gate.open()
        ok = await waitUntil { !rig.manager.isActive && rig.model.phase == .idle }
        XCTAssertTrue(ok)
        // Give a misrouted completion every chance to report something.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertNil(rig.model.startError)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertEqual(rig.manager.countdownText, "")
        XCTAssertEqual(rig.manager.remainingText, "")
        rig.controller.closePopover()
    }

    /// The helper refuses an extend. The manager keeps the session and its
    /// old deadline, and the item keeps showing them: no start error,
    /// because nothing about the session changed; the manager's error is a
    /// warning row in the popover, which stays up to show it.
    @MainActor
    func testAHelperRefusedExtendKeepsTheLiveSessionAndItsOldDeadlineOnScreen() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        var ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        let endsAt = rig.manager.session?.endsAt
        XCTAssertNotNil(endsAt)

        rig.h.backstop.failArm = true
        rig.controller.openPopover()
        rig.model.texts[.hours] = "1"
        rig.controller.commit()
        XCTAssertNotNil(rig.model.pendingCountdown)
        ok = await waitUntil { rig.model.pendingCountdown == nil }
        XCTAssertTrue(ok)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(rig.manager.isActive)
        XCTAssertEqual(rig.manager.session?.endsAt, endsAt)
        XCTAssertEqual(rig.manager.countdownText, "1:00:00")
        XCTAssertEqual(rig.manager.lastError, "could not confirm backstop: fake launchd refused")
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertNil(rig.model.startError)
        XCTAssertTrue(rig.model.popoverShown)
        XCTAssertTrue(
            StatusItemController.statusItems(manager: rig.manager, status: PlaceholderStatus())
                .contains(StatusMenu.Item(title: "could not confirm backstop: fake launchd refused", kind: .warning))
        )
        rig.controller.closePopover()
    }
}
