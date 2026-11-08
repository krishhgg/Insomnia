import AppKit
import XCTest
@testable import Insomnia

/// "Show the countdown in the menu bar" (`Config.showMenuBarCountdown`).
/// Off, the status item is the eye alone, open while a session runs and
/// closed when none does; the time left moves to the right-click menu, and
/// its End session stands in for the hold-to-end ring.
final class MenuBarCountdownOptionTests: XCTestCase {
    // MARK: Config

    /// On by default, and for a config.json written before the key existed;
    /// an explicit false is honoured and survives a round trip.
    func testTheCountdownSettingDecodesTolerantlyAndDefaultsOn() throws {
        XCTAssertTrue(Config().showMenuBarCountdown)
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"tmuxTargets": ["agents:0.0"]}"#.utf8))
        XCTAssertTrue(legacy.showMenuBarCountdown)
        let off = try Store.makeDecoder().decode(Config.self, from: Data(#"{"showMenuBarCountdown": false}"#.utf8))
        XCTAssertFalse(off.showMenuBarCountdown)
        let data = try Store.makeEncoder().encode(off)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), off)
    }

    // MARK: Menu items

    /// The time left heads the status block and End session sits above
    /// Settings…, after the separator.
    func testTheTimeLeftHeadsTheMenuAndEndSessionSitsAboveSettings() {
        let items = StatusMenu.items(
            sessionActive: true,
            sleepHeld: true,
            machine: "Lid: open \u{00B7} 82%",
            actions: nil,
            throttledBrowsers: [],
            error: nil,
            remaining: "2h 14m"
        )
        XCTAssertEqual(items, [
            StatusMenu.Item(title: "Time left: 2h 14m", kind: .info),
            StatusMenu.Item(title: "Sleep held per journal \u{2014} not verified live", kind: .info),
            StatusMenu.Item(title: "Lid: open \u{00B7} 82%", kind: .info),
            StatusMenu.Item(title: "", kind: .separator),
            StatusMenu.Item(title: StatusMenu.endSessionTitle, kind: .endSession),
            StatusMenu.Item(title: StatusMenu.settingsTitle, kind: .settings),
            StatusMenu.Item(title: StatusMenu.quitTitle, kind: .quit),
        ])
    }

    /// End session is a live item wired to its own selector, with no key
    /// equivalent, so no stray keystroke ends a session. Builds the NSMenu
    /// only; nothing is shown.
    @MainActor
    func testEndSessionIsALiveItemWithoutAKeyEquivalent() throws {
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, machine: nil, actions: nil, throttledBrowsers: [], error: nil)
        let menu = StatusMenu.menu(
            items,
            target: nil,
            endSession: #selector(NSObject.copy),
            settings: #selector(NSObject.description),
            quit: #selector(NSObject.description),
            relaunchBrowser: #selector(NSObject.description),
            stopWaitingForOutput: #selector(NSObject.description)
        )
        let entry = try XCTUnwrap(menu.items.first { $0.title == StatusMenu.endSessionTitle })
        XCTAssertTrue(entry.isEnabled)
        XCTAssertEqual(entry.action, #selector(NSObject.copy))
        XCTAssertEqual(entry.keyEquivalent, "")
    }

    /// Built the way the status item builds it: the time left appears only
    /// while a session runs with the countdown off; End session appears
    /// whenever a session runs.
    @MainActor
    func testTheMenuCarriesTheTimeLeftOnlyWhileASessionRunsWithTheCountdownOff() async {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let status = PlaceholderStatus()
        func extras() -> [StatusMenu.Item] {
            StatusItemController.menuItems(manager: manager, status: status)
                .filter { $0.kind == .endSession || $0.title.hasPrefix("Time left") }
        }

        manager.config.showMenuBarCountdown = false
        XCTAssertEqual(extras(), [], "no session: nothing to count down or end")

        await manager.start(duration: 3600)
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(extras(), [
            StatusMenu.Item(title: "Time left: 1h", kind: .info),
            StatusMenu.Item(title: StatusMenu.endSessionTitle, kind: .endSession),
        ])

        manager.config.showMenuBarCountdown = true
        XCTAssertEqual(extras(), [
            StatusMenu.Item(title: StatusMenu.endSessionTitle, kind: .endSession),
        ], "the countdown is in the bar; End session stays in the menu")
    }

    /// With the countdown off, VoiceOver reads the time left on the eye, or
    /// the end time when the bar is set to it: nothing ticks then, so a time
    /// left would go stale.
    func testTheEyeReadsTheEndTimeWhenTheBarIsSetToIt() {
        func value(shows: Bool = false, running: Bool = true, style: CountdownStyle) -> String {
            StatusRootView.eyeAccessibilityValue(showsCountdown: shows, running: running, style: style, remaining: "2h 14m", endTime: "6:30 PM")
        }
        XCTAssertEqual(value(style: .remaining), "Time left: 2h 14m")
        XCTAssertEqual(value(style: .endTime), "Ends at 6:30 PM")
        XCTAssertEqual(value(shows: true, style: .endTime), "", "the bar shows it")
        XCTAssertEqual(value(running: false, style: .endTime), "")
        XCTAssertEqual(
            StatusRootView.eyeAccessibilityValue(showsCountdown: false, running: true, style: .endTime, remaining: "2h 14m", endTime: ""),
            "Time left: 2h 14m"
        )
    }

    // MARK: Status item

    /// With the countdown off the item is as wide as the bare mark while a
    /// session starts and while it runs; turning it back on lays the
    /// countdown out again.
    @MainActor
    func testWithTheCountdownOffTheItemIsTheEyeAloneWhileASessionRuns() async {
        _ = NSApplication.shared
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let clock = h.clock
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, clock: { clock.now })
        func measuredWidth() -> CGFloat {
            let root = StatusRootView(
                model: controller.model,
                manager: manager,
                onTapIcon: {},
                onTapPill: { _ in },
                onTapCountdown: {},
                onHoldEnd: {},
                onWidthChange: { _ in }
            )
            return StatusItemController.makeHostingView(root).fittingSize.width
        }
        let idleWidth = measuredWidth()
        manager.config.showMenuBarCountdown = false

        controller.model.phase = .starting
        controller.model.pendingCountdown = "1:00:00"
        XCTAssertEqual(measuredWidth(), idleWidth, "a pending start shows no projected countdown")
        controller.model.pendingCountdown = nil

        await manager.start(duration: 3600)
        let deadline = Date().addingTimeInterval(2)
        while controller.model.phase != .running, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.model.phase, .running)
        XCTAssertEqual(measuredWidth(), idleWidth, "no countdown and no end ring")

        manager.config.showMenuBarCountdown = true
        XCTAssertGreaterThan(measuredWidth(), idleWidth)
    }
}
