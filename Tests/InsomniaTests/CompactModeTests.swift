import AppKit
import SwiftUI
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
                onDismiss: { controller.closeCompactDropdown() }
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

    /// Compact's pills open on the default field from Settings, like the
    /// Pills style's: on a first opening, after a session ends, after a
    /// start or an extension goes through, and when the countdown is
    /// clicked to add time. A draft with digits keeps its own focus.
    @MainActor
    func testCompactEntryOpensOnTheDefaultField() async {
        let rig = Rig()
        defer {
            rig.controller.closeCompactDropdown()
            rig.h.home.destroy()
        }
        rig.manager.config.defaultFocusField = .minutes
        rig.controller.iconTapped()
        XCTAssertTrue(rig.compact.isPresented)
        XCTAssertEqual(rig.compact.entry.focused, .minutes)

        // A draft keeps its focus across closing and reopening, whatever
        // the setting says by then.
        rig.compact.entry.focused = .days
        rig.compact.entry.input.days = 1
        rig.controller.iconTapped()
        XCTAssertFalse(rig.compact.isPresented)
        rig.manager.config.defaultFocusField = .hours
        rig.controller.iconTapped()
        XCTAssertEqual(rig.compact.entry.focused, .days)

        // A start that goes through clears the draft and its focus.
        rig.manager.config.defaultFocusField = .minutes
        rig.controller.compactSubmit()
        let started = await waitUntil { rig.manager.isActive && !rig.compact.isBusy }
        XCTAssertTrue(started)
        XCTAssertTrue(rig.compact.entry.input.isEmpty)
        XCTAssertEqual(rig.compact.entry.focused, .minutes)

        // Clicking the countdown to add time opens on the field set now.
        rig.manager.config.defaultFocusField = .days
        rig.compact.beginEditing(defaultField: rig.manager.config.defaultFocusField)
        XCTAssertTrue(rig.compact.isEditing)
        XCTAssertEqual(rig.compact.entry.focused, .days)

        // An extension that goes through.
        rig.manager.config.defaultFocusField = .hours
        rig.compact.entry.input.minutes = 30
        rig.controller.compactSubmit()
        let extended = await waitUntil { !rig.compact.isBusy && !rig.compact.isEditing }
        XCTAssertTrue(extended)
        XCTAssertEqual(rig.compact.entry.focused, .hours)

        // An end.
        rig.manager.config.defaultFocusField = .minutes
        rig.compact.beginEditing(defaultField: .days)
        rig.controller.compactEnd()
        let ended = await waitUntil { !rig.compact.isBusy && !rig.manager.isActive }
        XCTAssertTrue(ended)
        XCTAssertEqual(rig.compact.entry.focused, .minutes)
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

    /// The manager clears the session before it restores sleep, and an end
    /// from the Pills' hold or menu leaves the panel's `isBusy` alone. A
    /// switch to Compact in that wait showed live pills whose Return did
    /// nothing. The panel now shows its ending row, with the countdown off
    /// and no keys taken, until any end has restored sleep, then the pills.
    @MainActor
    func testThePanelShowsEveryEndAsEndingUntilSleepIsRestored() async {
        let ends: [(name: String, startsCompact: Bool, end: @MainActor (Rig) -> Void)] = [
            ("the Pills' hold", false, { $0.controller.holdToEnd() }),
            ("the Pills' menu", false, { $0.controller.performMenuAction(.endSession) }),
            ("the panel's ring", true, { $0.controller.compactEnd() }),
        ]
        for end in ends {
            let rig = Rig(compact: end.startsCompact)
            defer { rig.h.home.destroy() }
            await rig.manager.start(duration: 3600)
            let restore = AsyncGate()
            rig.h.guardFake.restoreGate = restore

            end.end(rig)
            rig.changeMode(true)
            XCTAssertTrue(rig.manager.isActive, end.name)
            XCTAssertTrue(rig.compact.isWaiting(phase: rig.model.phase),
                          "\(end.name): the countdown must not open the pills while the end runs")

            await restore.waitUntilStarted()
            XCTAssertFalse(rig.manager.isActive, end.name)
            XCTAssertFalse(rig.compact.showsInputs(sessionActive: false, phase: rig.model.phase), end.name)
            let endingHost = hostedView(rig)
            let endingWidth = endingHost.fittingSize.width
            rig.compact.setPresented(true)
            XCTAssertFalse(press(rig, "4"), "\(end.name): no digit while sleep is restored")
            XCTAssertFalse(press(rig, "\r", code: 36, onSubmit: { XCTFail("\(end.name): Return must not submit") }))
            XCTAssertTrue(rig.compact.entry.input.isEmpty, end.name)

            await restore.open()
            let ended = await waitUntil { !rig.model.isEnding && !rig.compact.isBusy }
            XCTAssertTrue(ended, end.name)
            XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"], end.name)
            XCTAssertTrue(rig.compact.showsInputs(sessionActive: rig.manager.isActive, phase: rig.model.phase), end.name)
            let pillsHost = hostedView(rig)
            XCTAssertGreaterThan(pillsHost.fittingSize.width, endingWidth,
                                 "\(end.name): the panel showed the pills while the end ran")
            rig.compact.setPresented(true)
            var submitted = false
            XCTAssertTrue(press(rig, "4"), end.name)
            XCTAssertFalse(rig.compact.entry.input.isEmpty, end.name)
            XCTAssertTrue(press(rig, "\r", code: 36, onSubmit: { submitted = true }), end.name)
            XCTAssertTrue(submitted, end.name)
            withExtendedLifetime((endingHost, pillsHost)) {}
        }
    }

    /// The timer, a floor and `--session end` end the session in the
    /// manager and never set the controller's end flag. A switch to Compact
    /// while sleep was restored showed live pills. The panel now follows the
    /// manager's own end, and its pills come back, and start a session, once
    /// the restore is done.
    @MainActor
    func testThePanelShowsAnEndTheManagerStartedUntilSleepIsRestored() async {
        let rig = Rig(compact: false)
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let restore = AsyncGate()
        rig.h.guardFake.restoreGate = restore

        let end = Task { await rig.manager.end(reason: .timer) }
        await restore.waitUntilStarted()
        rig.changeMode(true)
        XCTAssertFalse(rig.manager.isActive)
        let seen = await waitUntil { rig.compact.isEnding }
        XCTAssertTrue(seen, "the panel did not see the timer's end")
        let ending = assertShowsEnding(rig, ringEnabled: false, "the timer")

        await restore.open()
        let outcome = await end.value
        XCTAssertEqual(outcome, .restored)
        let ended = await waitUntil { !rig.compact.isEnding }
        XCTAssertTrue(ended)
        XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        let pills = await assertPillsStartASession(rig, widerThan: ending.width, "the timer")
        withExtendedLifetime((ending.host, pills)) {}
    }

    /// A restore command that outlives its timeout leaves the end to a retry
    /// when the command exits, after the session has cleared. Both of the
    /// controller's ends dropped their flag as soon as the manager returned,
    /// so the panel showed pills whose start the manager refused for the end
    /// still owed. It now shows Ending… until the retried end finishes.
    @MainActor
    func testThePanelShowsAnEndLeftToItsRetryUntilTheRetryFinishes() async {
        let ends: [(name: String, startsCompact: Bool, end: @MainActor (Rig) async -> Void)] = [
            ("the Pills' hold", false, { $0.controller.holdToEnd() }),
            ("the panel's ring", true, { $0.controller.compactEnd() }),
            ("the timer", true, { _ = await $0.manager.end(reason: .timer) }),
        ]
        for end in ends {
            let rig = Rig(compact: end.startsCompact)
            defer { rig.h.home.destroy() }
            await rig.manager.start(duration: 3600)
            rig.h.guardFake.stillRunning = ["disablesleep 0"]

            await end.end(rig)
            rig.changeMode(true)
            let stopped = await waitUntil {
                rig.manager.unfinishedCommand != nil && !rig.model.isEnding && !rig.compact.isBusy
            }
            XCTAssertTrue(stopped, end.name)
            XCTAssertFalse(rig.manager.isActive, end.name)
            XCTAssertNotNil(rig.manager.pendingEnd, end.name)
            let ending = assertShowsEnding(rig, ringEnabled: false, end.name)

            rig.h.guardFake.stillRunning = []
            rig.h.guardFake.exitStuckCommands()
            let retried = await waitUntil { rig.manager.pendingEnd == nil && !rig.compact.isEnding }
            XCTAssertTrue(retried, "\(end.name): the panel never left Ending… after the command exited")
            XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"], end.name)
            XCTAssertFalse(rig.h.guardFake.sleepDisabled, end.name)
            let pills = await assertPillsStartASession(rig, widerThan: ending.width, end.name)
            withExtendedLifetime((ending.host, pills)) {}
        }
    }

    /// An end that changed nothing leaves the session active: a busy lock
    /// (retried in 30 s) or an unreadable state.json (waits for a person).
    /// The panel shows Ending… with its countdown disabled, since time added
    /// then would be ended by the retry or refused, and keeps the ring
    /// enabled to ask for the end again, whoever asked first.
    @MainActor
    func testThePanelKeepsTheRingForAnEndThatChangedNothing() async throws {
        for unreadable in [false, true] {
            for fromTimer in [false, true] {
                let name = "\(unreadable ? "unreadable journal" : "busy lock"), \(fromTimer ? "the timer" : "the panel's ring")"
                let rig = Rig()
                defer { rig.h.home.destroy() }
                await rig.manager.start(duration: 3600)
                var held: RecoveryLockHandle?
                if unreadable {
                    try Data(#"{"sleepDisabledByUs": tru"#.utf8).write(to: rig.h.home.paths.stateFile)
                } else {
                    held = try XCTUnwrap(try RecoveryLock(url: rig.h.home.paths.recoveryLock).tryAcquire())
                }

                if fromTimer {
                    _ = await rig.manager.end(reason: .timer)
                } else {
                    rig.controller.compactEnd()
                }
                let refused = await waitUntil { rig.manager.endIsWaiting && !rig.compact.isBusy }
                XCTAssertTrue(refused, name)
                XCTAssertTrue(rig.manager.isActive, name)
                let settled = await waitUntil { rig.compact.endCanBeRetried }
                XCTAssertTrue(settled, "\(name): the ring cannot ask for the end again")
                let ending = assertShowsEnding(rig, ringEnabled: true, name)

                held?.release()
                if unreadable {
                    var repaired = RuntimeState()
                    repaired.sleepDisabledByUs = true
                    try rig.h.store.saveState(repaired)
                }
                rig.controller.compactEnd()
                let ended = await waitUntil {
                    !rig.manager.isActive && rig.manager.pendingEnd == nil && !rig.compact.isBusy && !rig.compact.isEnding
                }
                XCTAssertTrue(ended, "\(name): the ring did not end the session")
                XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"], name)
                let pills = await assertPillsStartASession(rig, widerThan: ending.width, name)
                withExtendedLifetime((ending.host, pills)) {}
            }
        }
    }

    /// The panel shows its ending row: the countdown cannot be clicked, no
    /// pills show, and neither a key nor a start or an extension gets in.
    /// The ring is enabled only for an end that waits to be asked again.
    /// The caller keeps the host until it is done pressing keys.
    @MainActor
    private func assertShowsEnding(_ rig: Rig, ringEnabled: Bool, _ name: String) -> (width: CGFloat, host: NSView) {
        XCTAssertTrue(rig.compact.isEnding, "\(name): the panel does not show the end")
        XCTAssertTrue(rig.compact.isWaiting(phase: rig.model.phase), "\(name): the countdown can be clicked to add time")
        XCTAssertFalse(rig.compact.showsInputs(sessionActive: rig.manager.isActive, phase: rig.model.phase), name)
        XCTAssertEqual(rig.compact.endIsEnabled, ringEnabled, "\(name): the ring")
        let host = hostedView(rig)
        let width = host.fittingSize.width
        rig.compact.setPresented(true)
        XCTAssertFalse(press(rig, "4"), "\(name): a digit was taken during the end")
        XCTAssertFalse(press(rig, "\r", code: 36, onSubmit: { XCTFail("\(name): Return must not submit") }))
        XCTAssertTrue(rig.compact.entry.input.isEmpty, name)
        rig.compact.entry.input.minutes = 5
        rig.controller.compactSubmit()
        XCTAssertFalse(rig.compact.isBusy, "\(name): a start or an extension went in during the end")
        rig.compact.entry.input = DurationInput()
        return (width, host)
    }

    /// The pills are back after the end, wider than the ending row, and a
    /// typed length and Return start a session. The caller keeps the host.
    @MainActor
    private func assertPillsStartASession(_ rig: Rig, widerThan endingWidth: CGFloat, _ name: String) async -> NSView {
        XCTAssertTrue(rig.compact.showsInputs(sessionActive: rig.manager.isActive, phase: rig.model.phase), name)
        XCTAssertTrue(rig.compact.endIsEnabled, name)
        let host = hostedView(rig)
        XCTAssertGreaterThan(host.fittingSize.width, endingWidth, "\(name): the panel did not show the pills after the end")
        rig.compact.setPresented(true)
        XCTAssertTrue(press(rig, "4"), name)
        XCTAssertTrue(press(rig, "\r", code: 36, onSubmit: { rig.controller.compactSubmit() }), name)
        let started = await waitUntil { rig.manager.isActive && !rig.compact.isBusy }
        XCTAssertTrue(started, "\(name): a typed length and Return did not start a session")
        return host
    }

    /// The caller keeps the host until it is done pressing keys. A hosted
    /// key responder that goes away reports the panel as closed.
    @MainActor
    private func hostedView(_ rig: Rig) -> NSHostingView<some View> {
        NSHostingView(rootView: rig.view.transaction { $0.disablesAnimations = true })
    }

    @MainActor
    private func press(_ rig: Rig, _ characters: String, code: UInt16 = 0, onSubmit: () -> Void = {}) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        )!
        return rig.compact.handleKey(
            event, sessionActive: rig.manager.isActive, phase: rig.model.phase,
            reduceMotion: true, onSubmit: onSubmit, onDismiss: {}
        )
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
