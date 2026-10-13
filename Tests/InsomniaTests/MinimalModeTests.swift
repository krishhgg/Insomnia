import AppKit
import XCTest
@testable import Insomnia

/// Minimal mode changes the control surface, not the session transaction.
/// Gates hold fake integrations at their asynchronous boundaries; no test
/// changes real power settings or uses the installed recovery agent.
final class MinimalModeTests: XCTestCase {
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

        init(mode: Config.MenuBarMode = .minimal) {
            _ = NSApplication.shared
            h = Harness()
            manager = h.makeManager()
            manager.config.menuBarMode = mode
            let clock = h.clock
            controller = StatusItemController(
                manager: manager, status: PlaceholderStatus(), showSettings: {},
                clock: { clock.now }
            )
        }

        var model: MenuBarModel { controller.model }
        var compact: CompactMenuModel { controller.compactModel }

        func changeMode(_ mode: Config.MenuBarMode) {
            manager.config.menuBarMode = mode
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

        func assertMinimalFootprint(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(measuredWidth(), 32, accuracy: 0.001, file: file, line: line)
            XCTAssertFalse(model.slotsPresent, file: file, line: line)
            XCTAssertFalse(model.focusVisible, file: file, line: line)
            XCTAssertFalse(compact.isPresented, file: file, line: line)
            XCTAssertFalse(NSApp.windows.contains { ($0 as? KeyCatcherPanel)?.isVisible == true }, file: file, line: line)
        }
    }

    @MainActor
    private func eventually(
        _ message: String = "The controller did not settle",
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    @MainActor
    func testClickStartsAndAddsTheSameConfiguredDurationWithoutOpeningInputs() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.manager.config.defaultPreset = 1800
        rig.assertMinimalFootprint()
        XCTAssertNil(rig.model.minimalProgress)

        rig.controller.iconTapped()
        await eventually { rig.manager.isActive && !rig.model.minimalBusy }
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(1800))
        rig.assertMinimalFootprint()

        rig.controller.iconTapped()
        await eventually { rig.manager.session?.extensions.count == 1 && !rig.model.minimalBusy }
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(rig.manager.session?.extensions, [1800])
        XCTAssertEqual(rig.h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        rig.assertMinimalFootprint()

        // Settings changes apply to the next click, including extensions.
        rig.manager.config.defaultPreset = 600
        rig.controller.iconTapped()
        await eventually { rig.manager.session?.extensions.count == 2 && !rig.model.minimalBusy }
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(4200))
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testClickRetainsTheManagersDurationCeiling() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.manager.config.maxDuration = 3600
        rig.manager.config.defaultPreset = 7200
        rig.controller.iconTapped()
        await eventually { rig.manager.isActive && !rig.model.minimalBusy }
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(3600))

        rig.h.clock.advance(300)
        rig.controller.iconTapped()
        await eventually { rig.manager.session?.extensions.count == 1 && !rig.model.minimalBusy }
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(rig.manager.session?.extensions, [300])
    }

    @MainActor
    func testStartingIgnoresRepeatClicksUntilTheManagerConfirms() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.manager.config.defaultPreset = 600

        rig.controller.iconTapped()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertTrue(rig.model.minimalBusy)
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertNil(rig.model.minimalProgress, "Confirmed progress stays separate from the pending visual projection")
        rig.assertMinimalFootprint()
        rig.controller.iconTapped()
        rig.controller.iconTapped()
        await settleQueuedRequests()

        await gate.open()
        await eventually { rig.manager.isActive && !rig.model.minimalBusy }
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(600))
        XCTAssertEqual(rig.manager.session?.extensions, [])
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertEqual(rig.h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        XCTAssertFalse(rig.h.guardFake.calls.contains("disablesleep 0"))
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testImmediateCancellationBeforeTheStartTaskRunsNeverStartsLater() async throws {
        for mode in [Config.MenuBarMode.compact, .minimal] {
            let rig = Rig(mode: mode)
            defer { rig.h.home.destroy() }
            submit(rig, mode: mode)
            XCTAssertEqual(rig.model.phase, .starting)
            cancel(rig, mode: mode)
            XCTAssertTrue(rig.model.isEnding)
            XCTAssertTrue(rig.model.minimalBusy)
            await eventually { !rig.model.isEnding && !rig.model.minimalBusy }
            await settleQueuedRequests()
            XCTAssertFalse(rig.manager.isActive)
            XCTAssertEqual(rig.model.phase, .idle)
            XCTAssertEqual(rig.h.backstop.arms, 0)
            XCTAssertFalse(rig.h.guardFake.calls.contains("disablesleep 1"))
            XCTAssertNil(try rig.h.store.loadSession())
            XCTAssertNil(rig.model.pendingProjection)
            XCTAssertNil(rig.model.pendingCountdown)
            XCTAssertFalse(rig.controller.pendingTickArmed)
            XCTAssertNil(rig.compact.error)
        }
    }

    @MainActor
    func testCancellationDuringBackstopStartupPreventsSleepChangesAndLateFailureUI() async throws {
        for mode in [Config.MenuBarMode.compact, .minimal] {
            let rig = Rig(mode: mode)
            defer { rig.h.home.destroy() }
            let gate = AsyncGate()
            rig.h.backstop.armGate = gate
            submit(rig, mode: mode)
            await gate.waitUntilStarted()
            cancel(rig, mode: mode)
            await settleQueuedRequests()
            XCTAssertTrue(rig.model.isEnding)
            XCTAssertTrue(rig.compact.isBusy)
            XCTAssertFalse(rig.controller.pendingTickArmed)
            submit(rig, mode: mode)
            cancel(rig, mode: mode)
            await gate.open()
            await eventually { !rig.model.isEnding && !rig.compact.isBusy }
            await settleQueuedRequests()
            XCTAssertFalse(rig.manager.isActive)
            XCTAssertFalse(rig.h.guardFake.calls.contains("disablesleep 1"))
            XCTAssertEqual(rig.h.backstop.arms, 1)
            XCTAssertNil(try rig.h.store.loadSession())
            XCTAssertEqual(try rig.h.store.loadState() ?? .clean, .clean)
            XCTAssertEqual(rig.model.phase, .idle)
            XCTAssertNil(rig.model.pendingCountdown)
            XCTAssertNil(rig.model.pendingProjection)
            XCTAssertNil(rig.compact.error)
            XCTAssertFalse(rig.model.slotsPresent)
        }
    }

    @MainActor
    func testCancellationDuringSleepChangeWaitsForRestorationAcrossModeChanges() async throws {
        for mode in [Config.MenuBarMode.compact, .minimal] {
            let rig = Rig(mode: mode)
            defer { rig.h.home.destroy() }
            let sleepGate = AsyncGate()
            let restoreGate = AsyncGate()
            rig.h.guardFake.sleepGate = sleepGate
            rig.h.guardFake.restoreGate = restoreGate
            submit(rig, mode: mode)
            await sleepGate.waitUntilStarted()
            cancel(rig, mode: mode)
            await settleQueuedRequests()
            await sleepGate.open()
            await restoreGate.waitUntilStarted()
            XCTAssertFalse(rig.manager.isActive)
            XCTAssertTrue(rig.model.isEnding)
            XCTAssertTrue(rig.model.minimalBusy)
            for destination in [Config.MenuBarMode.standard, .compact, .minimal] {
                rig.changeMode(destination)
                rig.controller.iconTapped()
                rig.controller.compactSubmit()
                rig.controller.holdToEnd()
                rig.controller.compactEnd()
            }
            await settleQueuedRequests()
            XCTAssertTrue(rig.model.isEnding)
            await restoreGate.open()
            await eventually { !rig.model.isEnding && !rig.model.minimalBusy }
            await settleQueuedRequests()
            XCTAssertFalse(rig.manager.isActive)
            XCTAssertEqual(rig.model.phase, .idle)
            XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
            XCTAssertNil(try rig.h.store.loadSession())
            XCTAssertEqual(try rig.h.store.loadState(), .clean)
            XCTAssertNil(rig.compact.error)
            rig.assertMinimalFootprint()
        }
    }

    @MainActor
    func testPendingExtensionCanBeCancelledWithoutApplyingTheAdditionalTime() async throws {
        for mode in [Config.MenuBarMode.compact, .minimal] {
            let rig = Rig(mode: mode)
            defer { rig.h.home.destroy() }
            await rig.manager.start(duration: 3600)
            let gate = AsyncGate()
            rig.h.backstop.armGate = gate
            submit(rig, mode: mode)
            await gate.waitUntilStarted()
            cancel(rig, mode: mode)
            await settleQueuedRequests()
            XCTAssertTrue(rig.model.isEnding)
            await gate.open()
            await eventually { !rig.model.isEnding && !rig.compact.isBusy }
            XCTAssertFalse(rig.manager.isActive)
            XCTAssertNil(try rig.h.store.loadSession())
            XCTAssertEqual(try rig.h.store.loadState(), .clean)
            XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
            XCTAssertNil(rig.compact.error)
        }
    }

    @MainActor
    private func submit(_ rig: Rig, mode: Config.MenuBarMode) {
        if mode == .compact {
            rig.compact.entry.input.minutes = 10
            rig.controller.compactSubmit()
        } else {
            rig.controller.iconTapped()
        }
    }

    @MainActor
    private func cancel(_ rig: Rig, mode: Config.MenuBarMode) {
        if mode == .compact {
            rig.controller.compactEnd()
        } else {
            rig.controller.holdToEnd()
        }
    }

    @MainActor
    func testRefusedStartStaysIconOnlyReportsTheErrorAndAllowsRetry() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.h.backstop.failArm = true
        rig.controller.iconTapped()
        await eventually { !rig.model.minimalBusy && rig.manager.lastError != nil }
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertNil(rig.model.minimalProgress)
        XCTAssertFalse(rig.controller.pendingTickArmed)
        XCTAssertTrue(rig.controller.menuItems().contains { $0.kind == .warning && $0.title.contains("fake launchd refused") })
        rig.assertMinimalFootprint()

        rig.h.backstop.failArm = false
        rig.controller.iconTapped()
        await eventually { rig.manager.isActive && !rig.model.minimalBusy }
        XCTAssertNil(rig.manager.lastError)
        XCTAssertNil(rig.compact.error)
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testPendingExtensionUsesTheConfirmedProgressAndIgnoresRepeatedClicks() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.manager.config.defaultPreset = 3600
        await rig.manager.start(duration: 3600)
        rig.h.clock.advance(1800)
        rig.manager.refreshCountdown()
        await eventually { rig.model.minimalProgress == 0.5 }
        let originalEnd = try XCTUnwrap(rig.manager.session?.endsAt)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.iconTapped()
        await gate.waitUntilStarted()
        XCTAssertTrue(rig.model.minimalBusy)
        XCTAssertEqual(rig.manager.session?.endsAt, originalEnd)
        XCTAssertEqual(rig.model.minimalProgress, 0.5)
        rig.controller.iconTapped()
        await settleQueuedRequests()

        await gate.open()
        await eventually { !rig.model.minimalBusy && rig.model.minimalProgress == 0.75 }
        XCTAssertEqual(rig.manager.session?.endsAt, originalEnd.addingTimeInterval(3600))
        XCTAssertEqual(rig.manager.session?.extensions, [3600])
        XCTAssertTrue(rig.manager.isActive)
        XCTAssertFalse(rig.h.guardFake.calls.contains("disablesleep 0"))
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testRefusedExtensionKeepsTheSessionAndSurfacesItsErrorInTheExistingMenu() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let original = rig.manager.session
        rig.h.backstop.failArm = true
        rig.controller.iconTapped()
        await eventually { !rig.model.minimalBusy && rig.manager.lastError != nil }
        XCTAssertEqual(rig.manager.session, original)
        XCTAssertTrue(rig.controller.menuItems().contains { $0.kind == .warning && $0.title.contains("fake launchd refused") })
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testHoldWaitsForRestoreAndDoesNotQueueANewSession() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let gate = AsyncGate()
        rig.h.guardFake.restoreGate = gate
        rig.controller.holdToEnd()
        await gate.waitUntilStarted()
        XCTAssertTrue(rig.model.minimalBusy)
        XCTAssertFalse(rig.manager.isActive, "The manager clears the session before the restore finishes")
        rig.controller.iconTapped()
        rig.controller.holdToEnd()
        rig.assertMinimalFootprint()
        await settleQueuedRequests()

        await gate.open()
        await eventually { !rig.model.minimalBusy }
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertNil(rig.model.minimalProgress)
        XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertNil(try rig.h.store.loadSession())
        XCTAssertEqual(try rig.h.store.loadState(), .clean)
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testFailedRestoreRetainsTheRecoveryWarningAndJournal() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        rig.h.guardFake.throwOn.insert("disablesleep 0")
        rig.controller.holdToEnd()
        await eventually { !rig.model.minimalBusy && rig.manager.lastError != nil }
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertTrue(try XCTUnwrap(rig.h.store.loadState()).sleepDisabledByUs)
        XCTAssertTrue(rig.controller.menuItems().contains { $0.kind == .warning && $0.title.contains("could not restore sleep") })
        XCTAssertNil(rig.model.minimalProgress)
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testChangingModeDuringRestoreCannotStartAnotherSession() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let gate = AsyncGate()
        rig.h.guardFake.restoreGate = gate
        rig.controller.holdToEnd()
        await gate.waitUntilStarted()
        rig.changeMode(.standard)
        rig.controller.iconTapped()
        rig.controller.commit()
        XCTAssertFalse(rig.model.slotsPresent)
        rig.changeMode(.compact)
        rig.compact.entry.input.hours = 1
        rig.controller.compactSubmit()
        rig.changeMode(.minimal)
        rig.controller.iconTapped()
        await settleQueuedRequests()
        XCTAssertTrue(rig.model.minimalBusy)

        await gate.open()
        await eventually { !rig.model.minimalBusy }
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testEndFromOtherPresentationsCannotBeRestartedBySwitchingToMinimal() async {
        for originalMode in [Config.MenuBarMode.standard, .compact] {
            let rig = Rig(mode: originalMode)
            defer { rig.h.home.destroy() }
            await rig.manager.start(duration: 3600)
            let gate = AsyncGate()
            rig.h.guardFake.restoreGate = gate
            if originalMode == .compact {
                rig.controller.compactEnd()
            } else {
                rig.controller.holdToEnd()
            }
            await gate.waitUntilStarted()
            rig.changeMode(.minimal)
            rig.controller.iconTapped()
            rig.controller.holdToEnd()
            await settleQueuedRequests()

            await gate.open()
            await eventually { !rig.model.minimalBusy && !rig.h.guardFake.sleepDisabled }
            await settleQueuedRequests()
            XCTAssertFalse(rig.manager.isActive, "Switching from \(originalMode) must not restart during cleanup")
            XCTAssertEqual(rig.h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
            rig.assertMinimalFootprint()
        }
    }

    @MainActor
    func testInlinePendingStartCanFinishAfterSwitchingToMinimal() async {
        let rig = Rig(mode: .standard)
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.expand(mode: .start)
        rig.model.input.hours = 2
        rig.controller.commit()
        await gate.waitUntilStarted()
        rig.changeMode(.minimal)
        rig.controller.iconTapped()
        rig.assertMinimalFootprint()

        await gate.open()
        await eventually { rig.manager.isActive && !rig.model.minimalBusy }
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(7200))
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertEqual(rig.manager.session?.extensions, [])
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testCompactPendingStartCanFailInMinimalWithoutOpeningInputsOrLosingDraft() async {
        let rig = Rig(mode: .compact)
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.compact.entry.input.minutes = 25
        rig.controller.compactSubmit()
        await gate.waitUntilStarted()
        rig.changeMode(.minimal)
        rig.assertMinimalFootprint()

        await gate.open()
        await eventually { !rig.model.minimalBusy && rig.manager.lastError != nil }
        XCTAssertFalse(rig.manager.isActive)
        rig.assertMinimalFootprint()
        rig.changeMode(.compact)
        XCTAssertEqual(rig.compact.entry.input.minutes, 25)
        XCTAssertNotNil(CompactMenuView(
            model: rig.compact, menuBar: rig.model, manager: rig.manager,
            onSubmit: {}, onEnd: {}, onDismiss: {}
        ).displayedError)
        XCTAssertFalse(rig.compact.isBusy)
    }

    @MainActor
    func testMinimalStartRefusalAfterSwitchingModeRetriesTheSubmittedPreset() async {
        for destination in [Config.MenuBarMode.standard, .compact] {
            let rig = Rig()
            defer { rig.h.home.destroy() }
            rig.manager.config.defaultPreset = 1800
            rig.model.input.hours = 2
            rig.compact.entry.input.hours = 2
            let gate = AsyncGate()
            rig.h.backstop.armGate = gate
            rig.h.backstop.failArm = true
            rig.controller.iconTapped()
            await gate.waitUntilStarted()
            rig.changeMode(destination)

            await gate.open()
            await eventually { !rig.model.minimalBusy && rig.manager.lastError != nil }
            XCTAssertFalse(rig.manager.isActive)
            if destination == .standard {
                XCTAssertEqual(rig.model.phase, .entering(.start))
                XCTAssertTrue(rig.model.slotsPresent)
                XCTAssertEqual(rig.model.input.total, 1800)
            } else {
                XCTAssertEqual(rig.compact.entry.input.total, 1800)
                XCTAssertNotNil(CompactMenuView(
                    model: rig.compact, menuBar: rig.model, manager: rig.manager,
                    onSubmit: {}, onEnd: {}, onDismiss: {}
                ).displayedError)
            }

            rig.h.backstop.failArm = false
            if destination == .standard {
                rig.controller.commit()
            } else {
                rig.controller.compactSubmit()
            }
            await eventually { rig.manager.isActive && !rig.model.minimalBusy }
            XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(1800))
            XCTAssertNil(rig.manager.lastError)
        }
    }

    @MainActor
    func testPresetBeyondTheInputRangeKeepsASafeDraftAndTheOriginalManagerRequest() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        rig.manager.config.defaultPreset = 60 * 86400
        rig.manager.config.maxDuration = 60 * 86400
        rig.controller.iconTapped()
        await eventually { rig.manager.isActive && !rig.model.minimalBusy }
        XCTAssertEqual(rig.model.input, DurationInput(days: DurationInput.maxDays))
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(60 * 86400))
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testInvalidOrUnrepresentablePresetsCannotStartOrExtendASession() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let invalid: [TimeInterval] = [
            0, -60, .nan, .infinity, -.infinity,
            Double(Int.max), Double(Int.max).nextUp, .greatestFiniteMagnitude,
        ]
        rig.model.input.minutes = 15
        for preset in invalid {
            rig.manager.config.defaultPreset = preset
            rig.controller.iconTapped()
        }
        await settleQueuedRequests()
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertFalse(rig.model.minimalBusy)
        XCTAssertEqual(rig.model.phase, .idle)
        XCTAssertEqual(rig.model.input.minutes, 15)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertTrue(rig.h.guardFake.calls.isEmpty)
        XCTAssertEqual(rig.h.backstop.arms, 0)

        await rig.manager.start(duration: 600)
        let session = rig.manager.session
        for preset in invalid {
            rig.manager.config.defaultPreset = preset
            rig.controller.iconTapped()
        }
        await settleQueuedRequests()
        XCTAssertEqual(rig.manager.session, session)
        XCTAssertFalse(rig.model.minimalBusy)
        XCTAssertEqual(rig.model.input.minutes, 15)
        XCTAssertEqual(rig.h.backstop.arms, 1)
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testSwitchingPresentationsKeepsTheLiveSessionAndUnsubmittedCompactDraft() async {
        let rig = Rig(mode: .compact)
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 3600)
        let original = rig.manager.session
        rig.compact.isEditing = true
        rig.compact.entry.input.minutes = 17

        rig.changeMode(.minimal)
        rig.assertMinimalFootprint()
        rig.changeMode(.standard)
        rig.changeMode(.minimal)
        rig.changeMode(.compact)
        XCTAssertEqual(rig.manager.session, original)
        XCTAssertEqual(rig.compact.entry.input.minutes, 17)
        XCTAssertTrue(rig.compact.isEditing)
        XCTAssertEqual(rig.h.backstop.arms, 1)
    }

    @MainActor
    func testLiveCountdownTicksDrainTheRingAndAnEndedSessionRemovesIt() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.manager.start(duration: 600)
        await eventually { rig.model.minimalProgress == 1 }
        rig.h.clock.advance(150)
        rig.manager.refreshCountdown()
        await eventually { rig.model.minimalProgress == 0.75 }
        rig.h.clock.advance(300)
        rig.manager.refreshCountdown()
        await eventually { rig.model.minimalProgress == 0.25 }
        await rig.manager.end(reason: .user)
        await eventually { rig.model.minimalProgress == nil }
        rig.assertMinimalFootprint()
    }

    @MainActor
    func testProgressUsesTheRemainingFractionOfTheConfirmedSessionAndClampsClockChanges() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let session = Session(startedAt: start, endsAt: start.addingTimeInterval(600))
        XCTAssertNil(StatusItemController.minimalProgress(session: nil, now: start))
        XCTAssertEqual(StatusItemController.minimalProgress(session: session, now: start), 1)
        XCTAssertEqual(StatusItemController.minimalProgress(session: session, now: start.addingTimeInterval(-30)), 1)
        XCTAssertEqual(StatusItemController.minimalProgress(session: session, now: start.addingTimeInterval(150)), 0.75)
        XCTAssertEqual(StatusItemController.minimalProgress(session: session, now: session.endsAt), 0)
        XCTAssertEqual(StatusItemController.minimalProgress(session: session, now: session.endsAt.addingTimeInterval(30)), 0)

        let extended = SessionMath.extended(session, by: 600, now: start.addingTimeInterval(300), maxDuration: 3600)
        XCTAssertEqual(StatusItemController.minimalProgress(session: extended, now: start.addingTimeInterval(300)), 0.75)
        let noSpan = Session(startedAt: start, endsAt: start)
        XCTAssertEqual(StatusItemController.minimalProgress(session: noSpan, now: start), 0)
    }
}
