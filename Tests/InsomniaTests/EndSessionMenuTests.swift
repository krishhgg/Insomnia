import AppKit
import XCTest
@testable import Insomnia

/// Dispatch the actual NSMenuItem selector, then inspect session and journal
/// cleanup. System integrations are injected; no real power setting is changed.
@MainActor
final class EndSessionMenuTests: XCTestCase {
    private func controller(_ h: Harness, _ manager: SessionManager) -> StatusItemController {
        _ = NSApplication.shared
        let clock = h.clock
        return StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, clock: { clock.now })
    }

    private func menu(_ controller: StatusItemController) -> NSMenu {
        StatusMenu.menu(
            StatusItemController.menuItems(manager: controller.manager, status: controller.status),
            target: controller,
            endSession: #selector(StatusItemController.menuEndSession),
            settings: #selector(NSObject.description),
            quit: #selector(NSObject.description),
            relaunchBrowser: #selector(NSObject.description),
            stopWaitingForOutput: #selector(NSObject.description)
        )
    }

    @discardableResult
    private func selectEnd(_ menu: NSMenu) throws -> NSMenuItem {
        let entry = try XCTUnwrap(menu.items.first { $0.title == StatusMenu.endSessionTitle })
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(entry.keyEquivalent, "", "Ending must not gain an accidental keyboard shortcut")
        let action = try XCTUnwrap(entry.action)
        XCTAssertTrue(NSApp.sendAction(action, to: entry.target, from: entry))
        return entry
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func hasCompletedEnd(_ h: Harness, _ manager: SessionManager, _ control: StatusItemController) -> Bool {
        // The session and UI become idle before asynchronous restoration finishes.
        // Require the journal on disk and the in-flight extension UI to be clean.
        guard !manager.isActive, control.model.phase == .idle,
              control.model.pendingCountdown == nil,
              let state = try? h.store.loadState() else { return false }
        return !state.isDirty
    }

    func testMenuClickEndsAndRestoresTheSessionWithoutQuitting() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let control = controller(h, manager)
        await manager.start(duration: 3600)
        let lowPowerSet = await manager.setLowPower(true)
        XCTAssertTrue(lowPowerSet)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertTrue(h.guardFake.lowPowerOn)

        try selectEnd(menu(control))
        let ended = await waitUntil { hasCompletedEnd(h, manager, control) }
        XCTAssertTrue(ended)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(try XCTUnwrap(h.store.loadState()).isDirty)
        XCTAssertFalse(menu(control).items.contains { $0.title == StatusMenu.endSessionTitle })

        // The controller and app remain usable: ending was not Quit.
        await manager.start(duration: 1800)
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(menu(control).items.contains { $0.title == StatusMenu.endSessionTitle })
        await manager.end(reason: .user)
    }

    func testIdleAndPendingStartHaveNoEndMenuItem() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let control = controller(h, manager)
        XCTAssertFalse(menu(control).items.contains { $0.title == StatusMenu.endSessionTitle })
        let gate = AsyncGate()
        h.backstop.armGate = gate
        let start = Task { await manager.start(duration: 3600) }
        await gate.waitUntilStarted()
        XCTAssertFalse(menu(control).items.contains { $0.title == StatusMenu.endSessionTitle })
        control.menuEndSession()
        await settleQueuedRequests()
        await gate.open()
        await start.value
        XCTAssertTrue(manager.isActive, "A stale End action must not cancel an unconfirmed start")
        await manager.end(reason: .user)
    }

    func testStaleMenuAfterTimerEndDoesNothing() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let control = controller(h, manager)
        await manager.start(duration: 3600)
        let staleMenu = menu(control)
        await manager.end(reason: .timer)
        let calls = h.guardFake.calls
        try selectEnd(staleMenu)
        await settleQueuedRequests()
        XCTAssertEqual(h.guardFake.calls, calls)
        XCTAssertFalse(manager.state.isDirty)
        XCTAssertNil(try h.store.loadSession())
    }

    func testMenuEndWhileExtensionWaitsLeavesNoSessionOrExtensionUI() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let control = controller(h, manager)
        await manager.start(duration: 3600)
        let ready = await waitUntil { control.model.phase == .running }
        XCTAssertTrue(ready)
        let gate = AsyncGate()
        h.backstop.armGate = gate
        control.expand(mode: .extend)
        XCTAssertTrue(control.model.input.append(digit: 1, to: .hours))
        control.commit()
        await gate.waitUntilStarted()
        let restoreGate = AsyncGate()
        h.guardFake.restoreGate = restoreGate
        try selectEnd(menu(control))
        await settleQueuedRequests()
        await gate.open()
        await restoreGate.waitUntilStarted()
        let idle = await waitUntil { !manager.isActive && control.model.phase == .idle }
        XCTAssertTrue(idle, "The UI can become idle while restoration is still suspended")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual((try? h.store.loadState())?.isDirty, true)
        XCTAssertFalse(hasCompletedEnd(h, manager, control))
        await restoreGate.open()
        let ended = await waitUntil { hasCompletedEnd(h, manager, control) }
        XCTAssertTrue(ended)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(try XCTUnwrap(h.store.loadState()).isDirty)
        XCTAssertNil(control.model.pendingCountdown)
        XCTAssertNil(control.model.startError)
    }

    func testFailedMenuRestorationRetainsJournalAndShowsTheError() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let control = controller(h, manager)
        await manager.start(duration: 3600)
        h.guardFake.throwOn = ["disablesleep 0"]
        try selectEnd(menu(control))
        let failed = await waitUntil { !manager.isActive && manager.lastError != nil }
        XCTAssertTrue(failed)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertTrue(try XCTUnwrap(h.store.loadState()).sleepDisabledByUs)
        let error = try XCTUnwrap(manager.lastError)
        XCTAssertTrue(StatusItemController.menuItems(manager: manager, status: control.status).contains {
            $0.kind == .warning && $0.title.contains(error)
        })
        h.guardFake.throwOn = []
        await manager.end(reason: .user)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(try XCTUnwrap(h.store.loadState()).isDirty)
    }
}
