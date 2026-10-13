import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Insomnia

@MainActor
final class MenuBarAutoTests: XCTestCase {
    @MainActor
    private struct Rig {
        let h: Harness
        let manager: SessionManager
        let auto: AgentAutoController
        let controller: StatusItemController

        init(now: Date = Date(timeIntervalSince1970: 1_800_000_000),
             playSessionSound: @escaping @MainActor (SessionSoundCue) -> Void = { _ in },
             makeQuickPopover: (@MainActor () -> NSPopover)? = nil) {
            _ = NSApplication.shared
            h = Harness(now: now)
            manager = h.makeManager()
            let clock = h.clock
            auto = AgentAutoController(manager: manager, clock: { clock.now }, pollInterval: nil)
            manager.agentAuto = auto
            controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {},
                                              clock: { clock.now }, playSessionSound: playSessionSound, captureEvents: false,
                                              makeQuickPopover: makeQuickPopover)
        }

        func job() -> AgentJob {
            AgentJob(id: UUID(), name: "UI test job", pid: 4242,
                     identity: ProcessIdentity(startedAt: 42, startedAtMicros: 12, bootSession: "test"),
                     startedAt: h.clock.now, deadline: h.clock.now.addingTimeInterval(8 * 3600), heartbeatAt: h.clock.now,
                     startedUptime: 100, heartbeatUptime: 100)
        }
    }

    @MainActor
    private final class RemovalState { var count = 0 }

    @MainActor
    private final class FreshStatusPopover: NSPopover {
        private var fixtureShown = false
        override var isShown: Bool { fixtureShown }
        override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
            fixtureShown = true
        }
    }

    func testMonitorTokenIsRemovedSynchronouslyWhenReleasedOnMain() {
        let state = RemovalState()
        do {
            let monitor = MainThreadEventMonitor(42) { value in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(value as? Int, 42)
                state.count += 1
            }
            withExtendedLifetime(monitor) {}
        }
        XCTAssertEqual(state.count, 1)
    }

    func testMonitorReleasedOffMainTransfersItsTokenToMainExactlyOnce() async {
        let state = RemovalState()
        await Task.detached {
            let monitor = MainThreadEventMonitor(42) { value in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(value as? Int, 42)
                state.count += 1
            }
            withExtendedLifetime(monitor) {}
        }.value
        let removed = await waitUntil { state.count == 1 }
        XCTAssertTrue(removed)
        XCTAssertEqual(state.count, 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testQuickMenuAutoArmsIdleWithoutStartingDefaultTimer() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.controller.toggleAuto()
        XCTAssertTrue(r.auto.enabled)
        XCTAssertFalse(r.manager.isActive)
        XCTAssertFalse(r.h.guardFake.sleepDisabled)
        XCTAssertNil(r.controller.model.pendingCountdown)
        XCTAssertFalse(r.controller.pendingTickArmed)
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model), .idle)
        await r.controller.toggleAuto()
    }

    func testOpeningQuickMenuImmediatelyScansNewAgentWork() async throws {
        let r = Rig(now: Date(), makeQuickPopover: { FreshStatusPopover() }); defer { r.h.home.destroy() }
        await r.auto.setEnabled(true)
        let activity = AgentActivity(paths: r.h.home.paths)
        let job = try activity.begin(name: "newly registered work", pid: getpid(), now: r.h.clock.now)
        defer { try? activity.finish(job.id) }
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model), .idle)

        r.controller.makeStatusRootView().onTapIcon()

        let working = await waitUntil {
            AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model) == .working
        }
        XCTAssertTrue(working, "opening quick actions did not refresh the cached Auto state")
        XCTAssertEqual(r.auto.jobs.map(\.id), [job.id])
        XCTAssertEqual(r.manager.session?.agentAuto, true)
        await r.auto.setEnabled(false)
    }

    func testIconCountdownAndAccessibilityActionsOnlyOpenQuickMenuInAnyMode() async {
        var cues: [SessionSoundCue] = []
        let r = Rig(playSessionSound: { cues.append($0) }); defer { r.h.home.destroy() }
        func clickAll() {
            let root = r.controller.makeStatusRootView()
            let bounce = r.controller.model.iconBounce
            root.onTapIcon()
            root.onTapCountdown()
            root.onOpenMenu()
            XCTAssertEqual(r.controller.model.iconBounce, bounce + 3)
        }
        clickAll()
        XCTAssertFalse(r.auto.enabled)
        XCTAssertFalse(r.manager.isActive)
        XCTAssertTrue(cues.isEmpty)
        await r.controller.toggleAuto()
        clickAll()
        XCTAssertTrue(r.auto.enabled)
        XCTAssertFalse(r.manager.isActive)
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        let deadline = r.manager.session?.endsAt
        clickAll()
        XCTAssertTrue(r.auto.enabled)
        XCTAssertEqual(r.manager.session?.endsAt, deadline)
        XCTAssertEqual(cues, [.activated])
        await r.controller.toggleAuto()
        r.controller.startPreset(1800)
        let started = await waitUntil { r.manager.isActive }
        XCTAssertTrue(started)
        let timer = r.manager.session
        clickAll()
        XCTAssertEqual(r.manager.session, timer)
        await r.manager.end(reason: .user)
    }

    func testLaunchDefaultsToIdleAutoOnceAndDoesNotRearmAfterManualDisable() async {
        var cues: [SessionSoundCue] = []
        let r = Rig(playSessionSound: { cues.append($0) }); defer { r.h.home.destroy() }
        await r.controller.reconcileAndEnableDefaultAuto()
        XCTAssertTrue(r.auto.enabled)
        XCTAssertFalse(r.manager.isActive)
        XCTAssertFalse(r.h.guardFake.sleepDisabled)
        XCTAssertEqual(cues, [.activated])
        await r.controller.toggleAuto()
        await r.controller.reconcileAndEnableDefaultAuto()
        XCTAssertFalse(r.auto.enabled)
        XCTAssertEqual(cues, [.activated, .deactivated])
    }

    func testLaunchHoldsOnlyFreshRegisteredWorkAndSoundsOnce() async throws {
        var cues: [SessionSoundCue] = []
        let r = Rig(now: Date(), playSessionSound: { cues.append($0) }); defer { r.h.home.destroy() }
        let activity = AgentActivity(paths: r.h.home.paths)
        let job = try activity.begin(name: "fresh launch work", pid: getpid(), now: r.h.clock.now)
        defer { try? activity.finish(job.id) }
        await r.controller.reconcileAndEnableDefaultAuto()
        XCTAssertTrue(r.auto.enabled)
        XCTAssertEqual(r.manager.session?.agentAuto, true)
        XCTAssertTrue(r.h.guardFake.sleepDisabled)
        XCTAssertEqual(cues, [.activated])
        try activity.finish(job.id)
        await r.auto.poll()
        XCTAssertFalse(r.manager.isActive)
        XCTAssertTrue(r.auto.enabled)
        XCTAssertEqual(cues, [.activated])
    }

    func testQuitWhileLaunchRecoveryWaitsDoesNotArmAuto() async throws {
        var cues: [SessionSoundCue] = []
        let r = Rig(playSessionSound: { cues.append($0) }); defer { r.h.home.destroy() }
        var state = RuntimeState()
        state.sleepDisabledByUs = true
        try r.h.store.saveState(state)
        r.h.guardFake.sleepDisabled = true
        let gate = AsyncGate()
        r.h.guardFake.restoreGate = gate
        let launch = Task { await r.controller.reconcileAndEnableDefaultAuto() }
        await gate.waitUntilStarted()
        XCTAssertTrue(r.controller.model.autoActionPending)
        await r.controller.toggleAuto()
        r.controller.startPreset(1800)
        let quit = await runUntilSuspended { await r.manager.end(reason: .quit) }
        await gate.open()
        await launch.value
        _ = await quit.value
        XCTAssertFalse(r.auto.enabled)
        XCTAssertFalse(r.manager.isActive)
        XCTAssertTrue(cues.isEmpty)
    }

    func testLaunchDoesNotReplaceAResumedTimer() async throws {
        let r = Rig(); defer { r.h.home.destroy() }
        try r.h.store.saveSession(Session(startedAt: r.h.clock.now, endsAt: r.h.clock.now.addingTimeInterval(3600)))
        await r.controller.reconcileAndEnableDefaultAuto()
        XCTAssertTrue(r.manager.isActive)
        XCTAssertNil(r.manager.session?.agentAuto)
        XCTAssertFalse(r.auto.enabled)
        await r.manager.end(reason: .user)
    }

    func testLaunchDoesNotArmOverFailedRecoveryOrUnreadableJournal() async throws {
        for unreadable in [false, true] {
            var cues: [SessionSoundCue] = []
            let r = Rig(playSessionSound: { cues.append($0) }); defer { r.h.home.destroy() }
            if unreadable {
                try Data("not JSON".utf8).write(to: r.h.home.paths.stateFile)
            } else {
                var state = RuntimeState()
                state.sleepDisabledByUs = true
                try r.h.store.saveState(state)
                r.h.guardFake.sleepDisabled = true
                r.h.guardFake.throwOn = ["disablesleep 0"]
            }
            await r.controller.reconcileAndEnableDefaultAuto()
            XCTAssertFalse(r.auto.enabled)
            XCTAssertFalse(r.manager.isActive)
            XCTAssertNotNil(r.manager.lastError)
            XCTAssertTrue(cues.isEmpty)
            if !unreadable {
                r.h.guardFake.throwOn = []
                await r.manager.end(reason: .user)
            }
        }
    }

    func testDefaultAutoRestoresOldHoldBeforeCheckingFreshActivity() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.auto.setEnabled(true)
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        let manager = r.h.makeManager()
        let auto = AgentAutoController(manager: manager, pollInterval: nil)
        manager.agentAuto = auto
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, captureEvents: false)
        await controller.reconcileAndEnableDefaultAuto()
        XCTAssertTrue(auto.enabled)
        XCTAssertFalse(manager.isActive, "an old Auto session is not fresh registered work")
        XCTAssertFalse(r.h.guardFake.sleepDisabled)
        XCTAssertFalse(manager.state.sleepDisabledByUs)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.h.home.paths.sessionFile.path))
    }

    func testAutoJobTransitionsDoNotRepeatTheModeSounds() async {
        var cues: [SessionSoundCue] = []
        let r = Rig(playSessionSound: { cues.append($0) }); defer { r.h.home.destroy() }
        await r.controller.toggleAuto()
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        await r.auto.poll(snapshot: AgentSnapshot(active: []))
        XCTAssertTrue(r.auto.enabled)
        XCTAssertEqual(cues, [.activated])
        await r.controller.toggleAuto()
        XCTAssertEqual(cues, [.activated, .deactivated])
    }

    func testFailedAutoRestorationDoesNotPlayOffSuccessSound() async {
        var cues: [SessionSoundCue] = []
        let r = Rig(playSessionSound: { cues.append($0) }); defer { r.h.home.destroy() }
        await r.controller.toggleAuto()
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        r.h.guardFake.throwOn = ["disablesleep 0"]
        await r.controller.toggleAuto()
        XCTAssertFalse(r.auto.enabled)
        XCTAssertTrue(r.manager.state.sleepDisabledByUs)
        XCTAssertEqual(cues, [.activated])
        r.h.guardFake.throwOn = []
        await r.manager.end(reason: .user)
    }

    func testExplicitTimerPresetDisarmsOnlyIdleAuto() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.controller.toggleAuto()
        r.controller.startPreset(1800)
        let started = await waitUntil { r.manager.isActive }
        XCTAssertTrue(started)
        XCTAssertFalse(r.auto.enabled)
        XCTAssertNil(r.manager.session?.agentAuto)
        XCTAssertEqual(r.manager.session?.endsAt.timeIntervalSince(r.h.clock.now), 1800)
        await r.manager.end(reason: .user)
    }

    func testAutoWorkCannotBeExtendedOrReplacedWithTimerPreset() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.auto.setEnabled(true)
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        let synced = await waitUntil { r.controller.model.phase == .running }
        XCTAssertTrue(synced)
        let deadline = r.manager.session?.endsAt
        r.controller.customExtend()
        r.controller.startPreset(1800)
        XCTAssertFalse(r.controller.model.slotsPresent)
        XCTAssertTrue(r.auto.enabled)
        XCTAssertEqual(r.manager.session?.endsAt, deadline)
        XCTAssertFalse(AutoMenuBarPresentation.timerControlsEnabled(manager: r.manager, model: r.controller.model))
        r.controller.toggleSession()
        let ended = await waitUntil { !r.controller.model.autoActionPending && !r.manager.isActive }
        XCTAssertTrue(ended)
        XCTAssertFalse(r.auto.enabled)
        XCTAssertFalse(r.h.guardFake.sleepDisabled)
    }

    func testRunningTimerCannotBeReplacedWithAuto() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.manager.start(duration: 3600)
        let deadline = r.manager.session?.endsAt
        await r.controller.toggleAuto()
        XCTAssertFalse(r.auto.enabled)
        XCTAssertEqual(r.manager.session?.endsAt, deadline)
        XCTAssertNil(r.manager.session?.agentAuto)
        await r.manager.end(reason: .user)
    }

    func testRepeatedQuickActionsAreBlockedAcrossSuspendedAutoStart() async throws {
        let r = Rig(now: Date()); defer { r.h.home.destroy() }
        let activity = AgentActivity(paths: r.h.home.paths)
        let job = try activity.begin(name: "pending Auto UI", pid: getpid(), now: r.h.clock.now)
        defer { try? activity.finish(job.id) }
        let gate = AsyncGate()
        r.h.backstop.armGate = gate
        let start = Task { await r.controller.toggleAuto() }
        await gate.waitUntilStarted()
        XCTAssertTrue(r.controller.model.autoActionPending)
        XCTAssertFalse(r.manager.isActive)
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model), .checking)
        await r.controller.toggleAuto()
        r.controller.toggleSession()
        r.controller.startPreset(1800)
        XCTAssertTrue(r.auto.enabled)
        XCTAssertNil(r.controller.model.pendingCountdown)
        await gate.open()
        await start.value
        XCTAssertTrue(r.manager.isActive)
        XCTAssertFalse(r.controller.model.autoActionPending)
        XCTAssertEqual(r.h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        await r.auto.setEnabled(false)
    }

    func testAutonomousStartBlocksTimerButExplicitDisableCanCancelIt() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.auto.setEnabled(true)
        let gate = AsyncGate()
        r.h.backstop.armGate = gate
        let work = r.job()
        let start = Task { await r.auto.poll(snapshot: AgentSnapshot(active: [work])) }
        await gate.waitUntilStarted()
        XCTAssertFalse(r.manager.isActive)
        XCTAssertFalse(r.controller.model.autoActionPending)
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model), .checking)
        r.controller.startPreset(1800)
        XCTAssertTrue(r.auto.enabled)
        XCTAssertNil(r.controller.model.pendingCountdown)
        let cancel = await runUntilSuspended { await r.controller.toggleAuto() }
        await gate.open()
        await start.value
        await cancel.value
        XCTAssertFalse(r.auto.enabled)
        XCTAssertFalse(r.manager.isActive)
        XCTAssertFalse(r.h.guardFake.sleepDisabled)
    }

    func testFailedAutoStartIsVisibleAndNeverClaimsIdleHold() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.auto.setEnabled(true)
        r.h.backstop.failArm = true
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        XCTAssertFalse(r.auto.enabled)
        XCTAssertFalse(r.manager.isActive)
        XCTAssertNotNil(r.manager.lastError)
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model), .paused)
    }

    func testFailedRestorationDisablesActionsAndShowsRestoringNotIdle() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.auto.setEnabled(true)
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        r.h.guardFake.throwOn = ["disablesleep 0"]
        await r.controller.toggleAuto()
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model), .restoring)
        XCTAssertFalse(AutoMenuBarPresentation.timerControlsEnabled(manager: r.manager, model: r.controller.model))
        XCTAssertFalse(AutoMenuBarPresentation.autoControlEnabled(manager: r.manager, model: r.controller.model))
        r.h.guardFake.throwOn = []
        await r.manager.end(reason: .user)
        XCTAssertFalse(r.h.guardFake.sleepDisabled)
    }

    func testLastJobRestoreFailureDelegatesRecoveryAndDisarmsAuto() async {
        let r = Rig(); defer { r.h.home.destroy() }
        await r.auto.setEnabled(true)
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        r.h.guardFake.throwOn = ["disablesleep 0"]
        await r.auto.poll(snapshot: AgentSnapshot(active: []))
        XCTAssertFalse(r.auto.enabled)
        XCTAssertEqual(r.auto.pauseReason, .recoveryUnavailable)
        XCTAssertNil(r.manager.pendingEnd)
        XCTAssertTrue(r.manager.state.sleepDisabledByUs)
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: r.controller.model), .restoring)
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        XCTAssertFalse(r.manager.isActive)
        r.h.guardFake.throwOn = []
        await r.manager.end(reason: .user)
    }

    func testJournaledTimerStartIsNotMisclassifiedAsFailedRestoration() async {
        let r = Rig(); defer { r.h.home.destroy() }
        let gate = AsyncGate()
        r.h.backstop.armGate = gate
        r.controller.startPreset(1800)
        await gate.waitUntilStarted()
        XCTAssertEqual(r.manager.startingSessionIsAuto, false)
        XCTAssertTrue(r.manager.state.sleepDisabledByUs)
        XCTAssertFalse(AutoMenuBarPresentation.isRestoring(manager: r.manager))
        await r.controller.toggleAuto()
        XCTAssertFalse(r.auto.enabled)
        await gate.open()
        let started = await waitUntil { r.manager.isActive && r.controller.model.phase == .running }
        XCTAssertTrue(started)
        await r.manager.end(reason: .user)
    }

    func testAutoIsIconOnlyForIdleCheckingWorkingAndSafetyPause() async {
        let r = Rig(); defer { r.h.home.destroy() }
        let model = MenuBarModel()
        func width() -> CGFloat {
            let root = StatusRootView(model: model, manager: r.manager, onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {}, onWidthChange: { _ in })
            return StatusItemController.makeHostingView(root).fittingSize.width
        }
        let off = width()
        await r.auto.setEnabled(true)
        let idle = width()
        XCTAssertEqual(idle, off, "Auto must not add text beside the icon")
        XCTAssertEqual(idle, 32)
        model.autoActionPending = true
        XCTAssertEqual(width(), idle)
        model.autoActionPending = false
        model.phase = .starting
        model.pendingCountdown = "0:30"
        XCTAssertEqual(width(), idle, "Auto must not expose a stale projected timer")
        model.pendingCountdown = nil
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        model.phase = .running
        XCTAssertEqual(width(), idle, "a live Auto lease must not appear as a countdown")
        await r.manager.end(reason: .thermalCritical)
        XCTAssertEqual(width(), idle)
        XCTAssertEqual(AutoMenuBarPresentation.current(manager: r.manager, model: model), .paused)
    }

    func testPRQuickMenuRetainsItsFixedPanelWidthForAutoStates() async {
        let r = Rig(); defer { r.h.home.destroy() }
        let model = MenuBarModel()
        func width() -> CGFloat {
            let menu = QuickMenuView(manager: r.manager, model: model, onPreset: { _ in }, onToggle: {},
                                     onSettings: {}, onDetails: {}, onQuit: {}, onDismiss: {}, animateEntrance: false)
            return NSHostingView(rootView: menu).fittingSize.width
        }
        XCTAssertEqual(width(), 260)
        await r.auto.setEnabled(true)
        XCTAssertEqual(width(), 260)
        await r.auto.poll(snapshot: AgentSnapshot(active: [r.job()]))
        XCTAssertEqual(width(), 260)
        await r.manager.end(reason: .thermalCritical)
        XCTAssertEqual(width(), 260)
    }
}
