import AppKit
import XCTest
@testable import Insomnia

/// Compact mode changes presentation while retaining the session lifecycle.
/// All lifecycle operations use fake integrations and a temporary journal.
final class CompactModeTests: XCTestCase {
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

        init(compact: Bool = true) {
            _ = NSApplication.shared
            h = Harness()
            manager = h.makeManager()
            manager.config.compactMode = compact
            controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        }

        var model: MenuBarModel { controller.model }
        var compact: CompactMenuModel { controller.compactModel }
        var view: CompactMenuView {
            CompactMenuView(
                model: compact, menuBar: model, manager: manager,
                onSubmit: controller.compactSubmit, onEnd: controller.compactEnd,
                onDismiss: controller.closeCompactDropdown
            )
        }

        func changeMode(_ enabled: Bool) {
            manager.config.compactMode = enabled
            controller.synchronizePresentation()
        }

        func measuredWidth() -> CGFloat {
            let root = StatusRootView(
                model: model, manager: manager,
                onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {},
                onHoldEnd: {}, onWidthChange: { _ in }
            )
            return StatusItemController.makeHostingView(root).fittingSize.width
        }

        func openInlineOneDay() {
            controller.expand(mode: .start)
            controller.focus(.days)
            XCTAssertTrue(model.input.append(digit: 1, to: .days))
        }
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

    @MainActor
    func testCompactItemKeepsOnlyTheEyeThroughEntryPendingRunningAndFailure() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)

        // Even a lingering inline layout must not reserve room for controls.
        rig.model.phase = .entering(.start)
        rig.model.slotsPresent = true
        rig.model.visiblePills = 3
        rig.model.startError = MenuBarModel.startFailedText
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
        rig.model.phase = .starting
        rig.model.pendingCountdown = "30d 0:00:00"
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)

        await rig.manager.start(duration: 86400)
        let running = await waitUntil { rig.manager.isActive && rig.model.phase == .running }
        XCTAssertTrue(running)
        rig.model.slotsPresent = false
        rig.model.pendingCountdown = nil
        XCTAssertFalse(rig.manager.countdownText.isEmpty)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
    }

    @MainActor
    func testEnablingCompactDuringInlineFoldCancelsItsDelayedLanding() async {
        let rig = Rig(compact: false)
        defer { rig.h.home.destroy() }
        rig.openInlineOneDay()
        let opened = await waitUntil { rig.model.visiblePills == 3 }
        XCTAssertTrue(opened)
        rig.controller.collapse()
        XCTAssertTrue(rig.model.pillsCollapsing)

        rig.changeMode(true)
        XCTAssertFalse(rig.model.slotsPresent)
        XCTAssertFalse(rig.model.focusVisible)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertFalse(rig.model.slotsPresent)
        XCTAssertFalse(rig.model.pillsCollapsing)
        XCTAssertEqual(rig.controller.widthTarget, 32, accuracy: 0.001)
        XCTAssertFalse(NSApp.windows.contains { ($0 as? KeyCatcherPanel)?.isVisible == true })
    }

    @MainActor
    func testConfigurationObservationAppliesRepeatedModeChanges() async {
        let rig = Rig(compact: false)
        defer { rig.h.home.destroy() }
        rig.openInlineOneDay()

        // No explicit synchronization: this is the Settings binding's path.
        rig.manager.config.compactMode = true
        var applied = await waitUntil { !rig.model.slotsPresent && rig.controller.widthTarget == 32 }
        XCTAssertTrue(applied)
        rig.manager.config.compactMode = false
        await settleQueuedRequests()
        rig.controller.expand(mode: .start)
        XCTAssertTrue(rig.model.slotsPresent)
        XCTAssertGreaterThan(rig.measuredWidth(), 32)

        rig.manager.config.compactMode = true
        applied = await waitUntil { !rig.model.slotsPresent && rig.controller.widthTarget == 32 }
        XCTAssertTrue(applied, "configuration observation must rearm after the first toggle")
        rig.manager.config.compactMode = false
        await settleQueuedRequests()
        rig.controller.expand(mode: .start)
        XCTAssertTrue(rig.model.slotsPresent)
        rig.controller.collapse()
    }

    @MainActor
    func testInlineStartCanConfirmAfterSwitchingToCompactWithoutStartingTwice() async {
        let rig = Rig(compact: false)
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.openInlineOneDay()
        rig.controller.commit()
        await gate.waitUntilStarted()

        rig.changeMode(true)
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertFalse(rig.model.slotsPresent)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
        await gate.open()
        let confirmed = await waitUntil { rig.manager.isActive && rig.model.phase == .running && !rig.compact.isBusy }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(rig.manager.countdownText, "1d 0:00:00")
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertEqual(rig.h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
    }

    @MainActor
    func testInlineStartRefusalAfterSwitchingToCompactKeepsDraftWithoutReopeningPills() async {
        let rig = Rig(compact: false)
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.openInlineOneDay()
        rig.controller.commit()
        await gate.waitUntilStarted()
        rig.changeMode(true)

        await gate.open()
        let refused = await waitUntil { rig.view.displayedError != nil && !rig.compact.isBusy }
        XCTAssertTrue(refused)
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.compact.entry.input.total, 86400)
        XCTAssertFalse(rig.model.slotsPresent)
        XCTAssertFalse(rig.model.focusVisible)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
        XCTAssertFalse(NSApp.windows.contains { ($0 as? KeyCatcherPanel)?.isVisible == true })
        XCTAssertFalse(rig.controller.pendingTickArmed)
    }

    @MainActor
    func testCompactSubmitWaitsForConfirmationAndIgnoresRepeatSubmit() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.compact.isEditing = true
        rig.compact.entry.input.hours = 1
        rig.controller.compactSubmit()
        await gate.waitUntilStarted()
        XCTAssertTrue(rig.compact.isBusy)
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertFalse(rig.manager.isActive)

        rig.controller.compactSubmit()
        await settleQueuedRequests()
        await gate.open()
        let confirmed = await waitUntil { rig.manager.isActive && !rig.compact.isBusy }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(rig.manager.countdownText, "1:00:00")
        XCTAssertFalse(rig.compact.isEditing)
        XCTAssertTrue(rig.compact.entry.input.isEmpty)
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertEqual(rig.h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
    }

    @MainActor
    func testCompactPendingStartSurvivesReturningToDefaultPresentation() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.compact.entry.input.hours = 2
        rig.controller.compactSubmit()
        await gate.waitUntilStarted()

        rig.changeMode(false)
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertGreaterThan(rig.measuredWidth(), 32)
        await gate.open()
        let confirmed = await waitUntil { rig.manager.isActive && rig.model.phase == .running && !rig.compact.isBusy }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(rig.manager.countdownText, "2:00:00")
        XCTAssertGreaterThan(rig.measuredWidth(), 32)
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertNil(rig.model.pendingCountdown)
    }

    @MainActor
    func testCompactStartRefusalAfterReturningToDefaultRestoresEditableInlineDuration() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.compact.entry.input.days = 1
        rig.controller.compactSubmit()
        await gate.waitUntilStarted()
        rig.changeMode(false)

        await gate.open()
        let refused = await waitUntil { rig.model.phase.isEntering && !rig.compact.isBusy }
        XCTAssertTrue(refused)
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.input.total, 86400)
        XCTAssertEqual(rig.model.startError, MenuBarModel.startFailedText)
        XCTAssertTrue(rig.model.slotsPresent)
        XCTAssertTrue(rig.model.focusVisible)
        XCTAssertGreaterThan(rig.measuredWidth(), 32)
        XCTAssertFalse(rig.controller.pendingTickArmed)
        rig.controller.collapse()
    }

    @MainActor
    func testCompactRefusedExtensionPreservesLiveSessionAndShowsTheError() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let endsAt = rig.manager.session?.endsAt
        XCTAssertNotNil(endsAt)
        rig.h.backstop.failArm = true
        rig.compact.entry.input.hours = 1

        rig.controller.compactSubmit()
        let refused = await waitUntil { !rig.compact.isBusy && rig.view.displayedError != nil }
        XCTAssertTrue(refused)
        XCTAssertTrue(rig.manager.isActive)
        XCTAssertEqual(rig.manager.session?.endsAt, endsAt)
        XCTAssertEqual(rig.manager.countdownText, "1:00:00")
        XCTAssertEqual(rig.compact.entry.input.total, 3600)
        XCTAssertTrue(rig.compact.isEditing, "a refused extension returns to its editable duration")
        XCTAssertFalse(rig.model.slotsPresent)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
    }

    @MainActor
    func testSuccessfulInlineRetryClearsThePreviousCompactFailure() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.compact.isEditing = true
        rig.compact.entry.input.hours = 1
        rig.controller.compactSubmit()
        let refused = await waitUntil { rig.view.displayedError != nil && !rig.compact.isBusy }
        XCTAssertTrue(refused)
        XCTAssertFalse(rig.manager.isActive)

        rig.changeMode(false)
        rig.h.backstop.failArm = false
        rig.openInlineOneDay()
        rig.controller.commit()
        let confirmed = await waitUntil { rig.manager.isActive && rig.model.phase == .running && !rig.compact.isBusy }
        XCTAssertTrue(confirmed)
        XCTAssertNil(rig.manager.lastError)

        rig.changeMode(true)
        XCTAssertNil(rig.view.displayedError, "a successful inline retry must clear the compact dropdown error")
        XCTAssertFalse(rig.compact.isEditing)
        XCTAssertTrue(rig.compact.entry.input.isEmpty)
        XCTAssertTrue(rig.manager.isActive)
        XCTAssertEqual(rig.manager.countdownText, "1d 0:00:00")
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
    }

    @MainActor
    func testTimerCleanupFailureReplacesAnEarlierExtensionFailure() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let originalSession = try XCTUnwrap(rig.manager.session)
        rig.h.backstop.failArm = true
        rig.compact.entry.input.minutes = 5

        rig.controller.compactSubmit()
        let refused = await waitUntil { !rig.compact.isBusy && rig.manager.lastError != nil }
        XCTAssertTrue(refused)
        let extensionError = try XCTUnwrap(rig.manager.lastError)
        XCTAssertTrue(extensionError.contains("could not confirm backstop"))
        XCTAssertEqual(rig.view.displayedError, extensionError)
        XCTAssertEqual(rig.manager.session, originalSession)
        XCTAssertEqual(try rig.h.store.loadSession(), originalSession)

        // Expiry bypasses the UI's end action, so it cannot clear a cached
        // UI error. The panel must follow the manager's new cleanup failure.
        rig.h.backstop.failArm = false
        rig.h.guardFake.throwOn.insert("disablesleep 0")
        rig.h.clock.now = originalSession.endsAt
        let outcome = await rig.manager.end(reason: .timer)
        let cleanupError = try XCTUnwrap(rig.manager.lastError)
        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertTrue(cleanupError.contains("could not restore sleep"))
        XCTAssertNotEqual(cleanupError, extensionError)
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertNil(try rig.h.store.loadSession())
        XCTAssertTrue(rig.h.guardFake.sleepDisabled)
        XCTAssertEqual(try rig.h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertEqual(rig.view.displayedError, cleanupError)

        rig.h.guardFake.throwOn.remove("disablesleep 0")
        await rig.manager.end(reason: .timer)
        await rig.manager.start(duration: 600)
        XCTAssertTrue(rig.manager.isActive)
        XCTAssertNil(rig.manager.lastError)
        XCTAssertNil(rig.view.displayedError, "A cleared manager error must not reveal an old saved copy")
        await rig.manager.end(reason: .user)
        XCTAssertEqual(try rig.h.store.loadState(), .clean)
    }

    @MainActor
    func testCompactEndWaitsForTheManagerAndReturnsToAnIdleEye() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        XCTAssertTrue(rig.manager.isActive)
        rig.compact.isEditing = true
        rig.compact.entry.input.minutes = 5

        rig.controller.compactEnd()
        let ended = await waitUntil { !rig.compact.isBusy && !rig.manager.isActive && rig.model.phase == .idle }
        XCTAssertTrue(ended)
        XCTAssertEqual(rig.manager.countdownText, "")
        XCTAssertFalse(rig.compact.isEditing)
        XCTAssertTrue(rig.compact.entry.input.isEmpty)
        XCTAssertFalse(rig.manager.state.sleepDisabledByUs)
        XCTAssertEqual(rig.measuredWidth(), 32, accuracy: 0.001)
    }

    @MainActor
    func testCompactExtensionReturnsToCountdownOnlyAfterConfirmation() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let originalEnd = rig.manager.session!.endsAt
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.compact.isEditing = true
        rig.compact.entry.input.minutes = 30
        rig.controller.compactSubmit()
        await gate.waitUntilStarted()
        XCTAssertTrue(rig.compact.isBusy)
        XCTAssertTrue(rig.compact.isEditing)
        XCTAssertEqual(rig.compact.entry.input.minutes, 30)
        await gate.open()
        let confirmed = await waitUntil { !rig.compact.isBusy }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(rig.manager.session?.endsAt, originalEnd.addingTimeInterval(1800))
        XCTAssertFalse(rig.compact.isEditing)
        XCTAssertTrue(rig.compact.entry.input.isEmpty)
    }

    @MainActor
    func testClosingCompactDropdownRetainsUnfinishedDuration() {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.compact.isPresented = true
        rig.compact.isEditing = true
        rig.compact.entry.input.minutes = 15
        rig.compact.setPresented(false)
        XCTAssertFalse(rig.compact.isPresented)
        XCTAssertTrue(rig.compact.isEditing)
        XCTAssertEqual(rig.compact.entry.input.minutes, 15)
    }

    @MainActor
    func testInlineKeyRoutingDoesNotConsumeCompactDropdownKeys() {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.model.phase = .entering(.start)
        let before = rig.model.input
        for (code, characters) in [(UInt16(18), "1"), (48, "\t"), (51, "\u{7f}"), (36, "\r")] {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            )!
            XCTAssertFalse(rig.controller.handleKey(event))
        }
        XCTAssertEqual(rig.model.input, before)
    }
}
