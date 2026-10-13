import AppKit
import XCTest
@testable import Insomnia

/// Presentation changes must not remove and reinsert the item that macOS
/// and menu bar managers use to remember Insomnia's placement.
final class PersistentStatusItemTests: XCTestCase {
    @MainActor
    private struct Rig {
        let h: Harness
        let manager: SessionManager
        let controller: StatusItemController

        init(mode: Config.MenuBarMode = .standard) {
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

        func changeMode(_ mode: Config.MenuBarMode) {
            manager.config.menuBarMode = mode
            controller.synchronizePresentation()
        }

        func cleanUp() {
            controller.closeCompactDropdown()
            for panel in NSApp.windows.compactMap({ $0 as? KeyCatcherPanel }) where panel.isVisible {
                panel.orderOut(nil)
            }
            h.home.destroy()
        }
    }

    @MainActor
    private func statusWindows() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter {
            String(describing: type(of: $0)).contains("StatusBarWindow")
        }.map(ObjectIdentifier.init))
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor
    func testEveryModeRetainsTheSameVisibleItemButtonAndNativeWindow() throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        let item = rig.controller.nativeStatusItem
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)
        let originalWindows = statusWindows()

        for _ in 0..<3 {
            for mode in [Config.MenuBarMode.compact, .minimal, .standard] {
                rig.changeMode(mode)
                XCTAssertTrue(rig.controller.nativeStatusItem === item)
                XCTAssertTrue(item.button === button)
                XCTAssertTrue(button.window === window)
                XCTAssertTrue(item.isVisible, "Switching presentation must never hide the item")
                XCTAssertEqual(item.autosaveName, StatusItemController.autosaveName)
                XCTAssertEqual(statusWindows(), originalWindows, "A mode switch must not insert another item")
            }
        }
    }

    @MainActor
    func testLaunchingInCompactKeepsTheSavedPreferenceAndAnImmediatelyVisibleItem() throws {
        let rig = Rig(mode: .compact)
        defer { rig.cleanUp() }
        let item = rig.controller.nativeStatusItem
        XCTAssertTrue(item.isVisible)
        XCTAssertNotNil(item.button?.window)
        XCTAssertTrue(rig.manager.config.compactMode)
        XCTAssertFalse(rig.controller.compactModel.isPresented)

        rig.changeMode(.minimal)
        rig.changeMode(.compact)
        XCTAssertTrue(rig.manager.config.compactMode)
        XCTAssertTrue(rig.controller.nativeStatusItem === item)
        XCTAssertTrue(item.isVisible)
    }

    @MainActor
    func testCompactClicksToggleTheArrowlessPanelAndRetainItsInputDraft() throws {
        let rig = Rig(mode: .compact)
        defer { rig.cleanUp() }
        let item = rig.controller.nativeStatusItem
        let originalWindows = statusWindows()

        rig.controller.iconTapped()
        let dropdown = try XCTUnwrap(rig.controller.compactDropdown)
        XCTAssertTrue(dropdown.isShown)
        XCTAssertTrue(rig.controller.compactModel.isPresented)
        XCTAssertTrue(dropdown.window.canBecomeKey)
        XCTAssertFalse(dropdown.window.canBecomeMain)
        XCTAssertFalse(dropdown.window.styleMask.contains(.titled))
        XCTAssertTrue(dropdown.window.hasShadow)
        rig.controller.compactModel.entry.input.minutes = 17
        rig.controller.compactModel.entry.focused = .minutes

        rig.controller.iconTapped()
        XCTAssertFalse(dropdown.isShown)
        XCTAssertFalse(rig.controller.compactModel.isPresented)
        XCTAssertEqual(rig.controller.compactModel.entry.input.minutes, 17)

        rig.controller.iconTapped()
        XCTAssertTrue(dropdown.isShown)
        XCTAssertTrue(rig.controller.compactModel.isPresented)
        XCTAssertEqual(rig.controller.compactModel.entry.input.minutes, 17)
        XCTAssertEqual(rig.controller.compactModel.entry.focused, .minutes)
        XCTAssertTrue(rig.controller.nativeStatusItem === item)
        XCTAssertEqual(statusWindows(), originalWindows)
    }

    @MainActor
    func testSwitchingAwayDismissesThePanelWithoutLosingTheCompactDraft() throws {
        let rig = Rig(mode: .compact)
        defer { rig.cleanUp() }
        rig.controller.iconTapped()
        let dropdown = try XCTUnwrap(rig.controller.compactDropdown)
        rig.controller.compactModel.entry.input.hours = 2
        rig.controller.compactModel.isEditing = true

        rig.changeMode(.minimal)
        XCTAssertFalse(dropdown.isShown)
        XCTAssertFalse(rig.controller.compactModel.isPresented)
        XCTAssertEqual(rig.controller.compactModel.entry.input.hours, 2)
        rig.changeMode(.standard)
        rig.changeMode(.compact)
        rig.controller.iconTapped()
        XCTAssertTrue(dropdown.isShown)
        XCTAssertEqual(rig.controller.compactModel.entry.input.hours, 2)
    }

    @MainActor
    func testPendingStartSurvivesEveryModeOnTheSameItemWithoutDuplicateSessionWork() async throws {
        let rig = Rig()
        defer { rig.cleanUp() }
        let item = rig.controller.nativeStatusItem
        let button = try XCTUnwrap(item.button)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.expand(mode: .start)
        rig.controller.model.input.minutes = 10
        rig.controller.commit()
        await gate.waitUntilStarted()

        for mode in [Config.MenuBarMode.compact, .minimal, .standard, .compact] {
            rig.changeMode(mode)
            XCTAssertEqual(rig.controller.model.phase, .starting)
            XCTAssertTrue(rig.controller.nativeStatusItem === item)
            XCTAssertTrue(item.button === button)
            XCTAssertTrue(item.isVisible)
            XCTAssertEqual(rig.controller.model.input.total, 600)
        }
        XCTAssertEqual(rig.controller.compactModel.entry.input.total, 600)
        rig.controller.iconTapped()
        XCTAssertTrue(rig.controller.compactDropdown?.isShown == true)
        await gate.open()
        let confirmed = await eventually { rig.manager.isActive && !rig.controller.compactModel.isBusy }
        XCTAssertTrue(confirmed)
        XCTAssertEqual(rig.manager.session?.endsAt, rig.h.clock.now.addingTimeInterval(600))
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertEqual(rig.h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        XCTAssertTrue(rig.controller.nativeStatusItem === item)
        await rig.manager.end(reason: .user)
    }
}
