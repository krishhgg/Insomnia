import AppKit
import XCTest
@testable import Insomnia

/// Compact mode uses the same menu model and action dispatch as the inline
/// status item. Exercise those entry points with fake systems and a temp journal.
@MainActor
final class CompactMenuIntegrationTests: XCTestCase {
    func testSharedRelaunchActionAsksAndPreservesTheSelectedBrowser() {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.compactMode = true
        let source = RecordingStatusSource()
        let browser = ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")
        source.throttledBrowsers = [browser]
        let asked = Locked<[String]>([])
        let allow = Locked(false)
        let controller = StatusItemController(
            manager: manager, status: source, showSettings: {},
            confirmRelaunch: { name in
                asked.value.append(name)
                source.throttledBrowsers = []
                return allow.value
            }
        )
        let action = StatusMenu.Item.Kind.relaunchBrowser(browser)

        controller.performMenuAction(action)
        XCTAssertEqual(asked.value, ["Chrome"])
        XCTAssertTrue(source.relaunched.isEmpty, "Cancel must not quit or relaunch the browser")

        allow.value = true
        controller.performMenuAction(action)
        XCTAssertEqual(asked.value, ["Chrome", "Chrome"])
        XCTAssertEqual(source.relaunched, [browser], "A refreshed scan must not change the menu item's browser")
    }

    func testSharedAudioActionDropsOnlyTheChosenSavedOutput() async throws {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let headset = SavedAudioOutput(deviceUID: "usb-headset", name: "USB Headset", volume: 0.3, muted: false, saveID: "headset-save")
        let display = SavedAudioOutput(deviceUID: "room-display", name: "Room Display", volume: 0.5, muted: false, saveID: "display-save")
        var state = RuntimeState.clean
        state.savedAudioOutputs = [headset, display]
        try h.store.saveState(state)
        let manager = h.makeManager()
        manager.config.compactMode = true
        await manager.reconcile()
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {})
        let action = try XCTUnwrap(controller.menuItems().first { $0.kind == .stopWaitingForOutput(headset) })
        XCTAssertEqual(manager.outputsWaitingForRestore, [headset, display])

        controller.performMenuAction(action.kind)
        for _ in 0..<200 where manager.outputsWaitingForRestore.contains(headset) {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(manager.outputsWaitingForRestore, [display])
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [display], "The other output's saved volume must remain in the journal")
        XCTAssertTrue(h.audio.applied.isEmpty, "Dropping a disconnected save does not alter a device")
        XCTAssertFalse(controller.menuItems().contains { $0.kind == .stopWaitingForOutput(headset) })
        XCTAssertTrue(controller.menuItems().contains { $0.kind == .stopWaitingForOutput(display) })
    }

    func testCompactMenuRetainsUpstreamWarningsAndRefreshesForeignSleep() async throws {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        h.guardFake.sleepDisabled = true
        let manager = h.makeManager()
        manager.config.compactMode = true
        await manager.reconcile()
        let source = RecordingStatusSource()
        source.wifiSSID = "Example Network"
        source.relaunchProblems = ["Chrome did not quit within 10 s, so nothing was relaunched."]
        let controller = StatusItemController(manager: manager, status: source, showSettings: {})
        let before = controller.menuItems()
        XCTAssertEqual(before, StatusItemController.menuItems(manager: manager, status: source))
        XCTAssertTrue(before.contains { $0.kind == .info && $0.title == "Wi-Fi: Example Network" })
        XCTAssertTrue(before.contains { $0.kind == .warning && $0.title.contains(source.relaunchProblems[0]) })
        XCTAssertTrue(before.contains { $0.kind == .warning && $0.title.contains(SessionManager.foreignSleepLine) })

        h.guardFake.sleepDisabled = false
        controller.refreshMenuStatus()
        for _ in 0..<200 where manager.foreignSleepWarning != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNil(manager.foreignSleepWarning)
        let after = controller.menuItems()
        XCTAssertFalse(after.contains { $0.title.contains(SessionManager.foreignSleepLine) })
        XCTAssertTrue(after.contains { $0.kind == .warning && $0.title.contains(source.relaunchProblems[0]) }, "Refreshing one warning must not remove a separate upstream failure")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"), "The menu refresh only reads system state")
    }
}
