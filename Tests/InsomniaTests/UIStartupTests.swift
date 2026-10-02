import AppKit
import XCTest
@testable import Insomnia

/// Enter on the start pills, from the keystroke to the helper's answer.
///
/// The bug this pins: the status item used to switch to the running layout
/// (countdown text plus the hold-to-end ring) the moment Enter was pressed,
/// before the manager had confirmed anything. When the recovery agent then
/// took seconds to refuse, the user sat on an eye, a blank countdown and an
/// inert end ring with no session behind them. The start now has a phase of
/// its own, and the running controls only appear for a confirmed session.
final class UIStartupTests: XCTestCase {
    /// A refused start reopens the pills, and with them the key-catcher
    /// panel. Tests that end there must not leave it up for the next test.
    override func tearDown() {
        MainActor.assumeIsolated {
            for panel in NSApp.windows.compactMap({ $0 as? KeyCatcherPanel }) where panel.isVisible {
                panel.orderOut(nil)
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
            controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        }

        var model: MenuBarModel { controller.model }

        /// Open the start pills and type "1" into the days pill.
        func openAndTypeOneDay() {
            controller.expand(mode: .start)
            controller.focus(.days)
            XCTAssertTrue(model.input.append(digit: 1, to: .days))
            XCTAssertEqual(model.input.total, 86400)
        }

        /// A second host over the controller's model, so what the item would
        /// draw can be measured without a live menu bar.
        func measuredWidth() -> CGFloat {
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
    func testEnterShowsStartingWithoutRunningControlsUntilTheManagerConfirms() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.openAndTypeOneDay()
        let idleWidth: CGFloat = {
            let m = MenuBarModel()
            let root = StatusRootView(model: m, manager: rig.manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in })
            return StatusItemController.makeHostingView(root).fittingSize.width
        }()

        rig.controller.commit()
        await gate.waitUntilStarted()

        // Pending, readable, and nothing that only a live session may show.
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertFalse(rig.model.phase.showsRunningControls)
        // The countdown the session will read is projected the moment Enter
        // is pressed; the live one replaces it on confirmation.
        XCTAssertEqual(rig.model.pendingCountdown, "1d 0:00:00")
        XCTAssertEqual(MenuBarModel.startingText, "Starting\u{2026}")
        XCTAssertNil(rig.model.startError)
        // The typed value survives the wait, in case the start is refused.
        XCTAssertEqual(rig.model.input.total, 86400)
        // The host lays out the pending text, so the item is wider than the bare mark.
        XCTAssertGreaterThan(rig.measuredWidth(), idleWidth)

        await gate.open()
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertTrue(rig.model.phase.showsRunningControls)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertNil(rig.model.startError)
        XCTAssertEqual(rig.manager.countdownText, "1d 0:00:00")
        XCTAssertEqual(rig.h.backstop.arms, 1)
    }

    /// Bare Enter (default preset) goes through the same pending phase.
    @MainActor
    func testBareEnterAlsoWaitsInStartingBeforeRunning() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.expand(mode: .start)

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
    func testImmediateHelperFailureReopensThePillsWithTheValueAndAConciseError() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.openAndTypeOneDay()

        rig.controller.commit()
        let ok = await waitUntil { rig.model.phase.isEntering }
        XCTAssertTrue(ok)

        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .entering(.start))
        // Straight back, no stagger: an immediate refusal must not replay the
        // open animation on top of a morph that has barely begun.
        XCTAssertEqual(rig.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertTrue(rig.model.focusVisible)
        XCTAssertEqual(rig.model.input.text(for: .days), "1")
        XCTAssertEqual(rig.model.input.total, 86400)
        XCTAssertNil(rig.model.pendingCountdown)
        // Concise in the item; the manager keeps the full message for the menu.
        XCTAssertEqual(rig.model.startError, MenuBarModel.startFailedText)
        XCTAssertEqual(rig.manager.lastError, "could not arm backstop: fake launchd refused")
        XCTAssertLessThan(MenuBarModel.startFailedText.count, 24)
    }

    @MainActor
    func testDelayedHelperFailureLeavesStartingThenReopensThePills() async {
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
        let ok = await waitUntil { rig.model.phase.isEntering }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.model.phase, .entering(.start))
        XCTAssertEqual(rig.model.visiblePills, DurationInput.Field.allCases.count)
        XCTAssertEqual(rig.model.input.total, 86400)
        XCTAssertEqual(rig.model.startError, MenuBarModel.startFailedText)
        XCTAssertFalse(rig.manager.isActive)
        // The pills with the error are wider than the pills alone were.
        let withError = rig.measuredWidth()
        rig.model.startError = nil
        XCTAssertGreaterThan(withError, rig.measuredWidth())
    }

    @MainActor
    func testFailureThenRetrySucceedsAndClearsTheError() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.openAndTypeOneDay()
        rig.controller.commit()
        var ok = await waitUntil { rig.model.phase.isEntering }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.model.startError, MenuBarModel.startFailedText)

        rig.h.backstop.failArm = false
        rig.controller.commit()
        // The label leaves with the retry, not only on success; its text
        // keeps the label's room in the layout until the slots leave.
        XCTAssertFalse(rig.model.startErrorShown)
        XCTAssertNotNil(rig.model.startError)
        ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertTrue(rig.manager.isActive)
        // The session can land before the fold ends; the text goes with the slots.
        ok = await waitUntil { rig.model.startError == nil }
        XCTAssertTrue(ok)
        XCTAssertFalse(rig.model.slotsPresent)
        XCTAssertEqual(rig.manager.countdownText, "1d 0:00:00")
    }

    /// Typing after a refusal dismisses the error; so does closing the pills.
    @MainActor
    func testTheStartErrorClearsOnTheNextOpen() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.openAndTypeOneDay()
        rig.controller.commit()
        var ok = await waitUntil { rig.model.phase.isEntering }
        XCTAssertTrue(ok)
        XCTAssertNotNil(rig.model.startError)

        rig.controller.collapse()
        ok = await waitUntil { rig.model.phase == .idle }
        XCTAssertTrue(ok)
        XCTAssertNil(rig.model.startError)
        rig.controller.expand(mode: .start)
        XCTAssertNil(rig.model.startError)
        rig.controller.collapse()
    }

    // MARK: Pending interactions

    @MainActor
    func testRepeatEnterAndClicksWhilePendingAreIgnored() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.openAndTypeOneDay()
        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .starting)
        let bounces = rig.model.rejectBounce

        // Enter again, the mark, the countdown spot, the end ring: none of
        // them may start a second session or leave the pending phase.
        rig.controller.commit()
        rig.controller.iconTapped()
        rig.controller.customExtend()
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

    /// Two extends in a row, the second typed over the countdown while the
    /// first is still waiting on the helper. The manager answers them in
    /// order, so the first one's completion lands while the second is still
    /// pending; it must not clear what the second is showing.
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
        rig.controller.expand(mode: .extend)
        XCTAssertTrue(rig.model.input.append(digit: 1, to: .hours))
        rig.controller.commit()
        await first.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertNotNil(rig.model.pendingCountdown)

        // Second extend, through the countdown click. It queues behind the
        // first in the manager and is held at a gate of its own.
        let second = AsyncGate()
        rig.h.backstop.armGate = second
        rig.controller.customExtend()
        XCTAssertEqual(rig.model.phase, .entering(.extend))
        XCTAssertTrue(rig.model.input.append(digit: 2, to: .hours))
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

    /// The countdown and the end ring are for a confirmed session only, and
    /// `.running` on its own does not prove one: the phase can lag the
    /// manager by a hop when a session ends. In that window the item must
    /// not offer an end ring and a countdown for a session that is gone.
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

        // A confirmed session lays the controls out.
        await rig.manager.start(duration: 3600)
        let ok = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(ok)
        XCTAssertGreaterThan(rig.measuredWidth(), idleWidth)
    }

    // MARK: Pure transitions

    @MainActor
    func testManagerChangesMoveStartingToRunningAndLeaveAFailedStartToTheController() {
        XCTAssertEqual(StatusItemController.phase(forActive: true, phase: .starting), .running)
        XCTAssertNil(StatusItemController.phase(forActive: false, phase: .starting))
        XCTAssertFalse(MenuBarModel.Phase.starting.isEntering)
        XCTAssertFalse(MenuBarModel.Phase.starting.showsRunningControls)
        XCTAssertFalse(MenuBarModel.Phase.idle.showsRunningControls)
        XCTAssertFalse(MenuBarModel.Phase.entering(.start).showsRunningControls)
        XCTAssertTrue(MenuBarModel.Phase.running.showsRunningControls)
    }

    /// Extending keeps the old behaviour: the session is live, so the
    /// countdown and the end ring stay up while the extend is in flight.
    @MainActor
    func testExtendStaysOnTheRunningControlsWhileInFlight() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        var ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.expand(mode: .extend)
        XCTAssertTrue(rig.model.input.append(digit: 1, to: .hours))

        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertNotNil(rig.model.pendingCountdown)

        await gate.open()
        ok = await waitUntil { rig.model.pendingCountdown == nil }
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertEqual(rig.manager.countdownText, "2:00:00")
    }

    /// The user ends the session while an extend is still waiting on the
    /// helper. The manager abandons the extend and ends; the item goes idle
    /// and stays there: no "couldn't start" pills for an extend that was
    /// never a start, nothing reopened over the ended session.
    @MainActor
    func testEndingTheSessionWhileAnExtendIsPendingLeavesTheItemIdleWithoutAnError() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        var ok = await waitUntil { rig.model.phase == .running }
        XCTAssertTrue(ok)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.expand(mode: .extend)
        XCTAssertTrue(rig.model.input.append(digit: 1, to: .hours))
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
        // Give a misrouted completion every chance to reopen something.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertEqual(rig.model.visiblePills, 0)
        XCTAssertNil(rig.model.startError)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertFalse(NSApp.windows.contains { ($0 as? KeyCatcherPanel)?.isVisible == true })
        XCTAssertEqual(rig.manager.countdownText, "")
    }

    /// The helper refuses an extend. The manager keeps the session and its
    /// old deadline, and the item keeps showing them: no pills come back and
    /// no start error appears, because nothing about the session changed.
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
        rig.controller.expand(mode: .extend)
        XCTAssertTrue(rig.model.input.append(digit: 1, to: .hours))
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
        XCTAssertEqual(rig.model.visiblePills, 0)
        XCTAssertFalse(NSApp.windows.contains { ($0 as? KeyCatcherPanel)?.isVisible == true })
    }
}
