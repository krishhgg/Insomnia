import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

/// Right clicks and Control-clicks on the idle eye, delivered as real mouse
/// events to the SwiftUI status view, with one-click start on.
///
/// #63 made the eye a SwiftUI Button, which a right click or a Control-click
/// also pressed, so opening the menu toggled the session; b180afad fixed
/// that with a monitor that took the whole menu gesture first. The eye here
/// takes its click with `onTapGesture`. A Control-click fired it: SwiftUI
/// saw the press although the host's `mouseDown` sent it to the menu, and
/// tapped on the release. On macOS 27 a right click fired it too. With
/// one-click start on, that tap starts a session, so the host's monitor
/// now takes the whole right click and Control-click. These pin that the
/// menu gestures only open the menu, on macOS 26 and on 27, where the same
/// monitor also moves relayed clicks. The keys of an Option-click, which the same
/// monitor keeps for the tap, are tested here too.
final class MenuClickEventTests: XCTestCase {
    private final class Counts {
        var taps = 0
        var menus = 0
        var holds = 0
        /// Whether the left button is down, as the host and the eye read it.
        var leftDown = false
        /// The modifier keys held now, as the host and the controller read them.
        var held: NSEvent.ModifierFlags = []
    }

    /// Records the mouse button events the window dispatches. An event the
    /// host's monitor takes out of dispatch never reaches the window, so
    /// nothing in it sees the event, SwiftUI's taps included.
    private final class RecordingWindow: NSWindow {
        var mouseEvents: [NSEvent.EventType] = []

        override func sendEvent(_ event: NSEvent) {
            let buttons: [NSEvent.EventType] = [
                .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            ]
            if buttons.contains(event.type) { mouseEvents.append(event.type) }
            super.sendEvent(event)
        }
    }

    @MainActor
    private struct Rig {
        let h: Harness
        let manager: SessionManager
        let controller: StatusItemController
        let window: RecordingWindow
        let host: StatusHostingView
        let counts: Counts

        /// The eye. The window is the idle item's size; the host can be
        /// wider, since it only grows while the pills open, as in the menu
        /// bar, where the item's window cuts it off.
        var middle: NSPoint { NSPoint(x: window.frame.width / 2, y: window.frame.height / 2) }

        func tearDown() {
            window.orderOut(nil)
            controller.collapse(returnFocus: false)
            for panel in NSApp.windows.compactMap({ $0 as? KeyCatcherPanel }) where panel.isVisible {
                panel.orderOut(nil)
            }
            h.home.destroy()
        }
    }

    @MainActor
    private func makeRig(
        osMajorVersion: Int, mode: Config.MenuBarMode = .pills, eyeTapsReachController: Bool = true
    ) async -> Rig {
        _ = NSApplication.shared
        let h = Harness()
        let manager = h.makeManager()
        manager.config.oneClickStart = true
        manager.config.menuBarMode = mode
        let controller = StatusItemController(
            manager: manager, status: PlaceholderStatus(), showSettings: {}, appFocus: UIStatusTests.quietFocus
        )
        let counts = Counts()
        // The item's own view over the controller's model, in a window the
        // test can send events to; the eye's tap goes to the controller as
        // it does in the menu bar.
        let root = StatusRootView(
            model: controller.model, manager: manager,
            onTapIcon: {
                counts.taps += 1
                if eyeTapsReachController { controller.iconTapped(modifiers: []) }
            },
            onTapPill: { _ in }, onTapCountdown: {}, onHoldEnd: { counts.holds += 1 }, onWidthChange: { _ in },
            buttonIsDown: { counts.leftDown }, pointerLocation: { .zero }
        )
        let host = StatusItemController.makeHostingView(root)
        host.osMajorVersion = osMajorVersion
        host.onRightMouseDown = { _ in counts.menus += 1 }
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.pointerInWindow = { _ in NSPoint(x: size.width / 2, y: size.height / 2) }
        host.buttonIsDown = { counts.leftDown }
        host.heldModifiers = { counts.held }
        let window = await makeWindow(host, size: size)
        return Rig(h: h, manager: manager, controller: controller, window: window, host: host, counts: counts)
    }

    @MainActor
    private func makeWindow(_ host: StatusHostingView, size: NSSize) async -> RecordingWindow {
        // Off screen: the window only needs to exist to deliver events.
        let window = RecordingWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.5))
        return window
    }

    /// Sends `down` and, unless it is nil, `up`. A nil `up` is a release
    /// the open menu's own tracking took, as it does in the menu bar.
    @MainActor
    private func click(_ down: NSEvent.EventType, _ up: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags = [], _ rig: Rig) async {
        for (number, type) in [down, up].compactMap({ $0 }).enumerated() {
            let event = NSEvent.mouseEvent(
                with: type, location: rig.middle, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                context: nil, eventNumber: number + 1, clickCount: 1, pressure: type == down ? 1 : 0
            )!
            NSApp.sendEvent(event)
        }
        try? await Task.sleep(for: .seconds(0.2))
    }

    @MainActor
    func testRightClickAndControlClickOnlyOpenTheMenu() async {
        for os in [26, 27] {
            let rig = await makeRig(osMajorVersion: os)
            await click(.rightMouseDown, nil, rig)
            await send(.rightMouseDragged, at: rig.middle, rig)
            await click(.rightMouseUp, nil, rig)
            await click(.leftMouseDown, .leftMouseUp, modifiers: .control, rig)
            // A Control-click whose release the menu took, then a release
            // that reaches the window later, as when a click closes the menu.
            await click(.leftMouseDown, nil, modifiers: .control, rig)
            await click(.leftMouseUp, nil, rig)
            XCTAssertEqual(rig.counts.menus, 3, "macOS \(os)")
            XCTAssertEqual(rig.counts.taps, 0, "macOS \(os)")
            XCTAssertEqual(rig.window.mouseEvents, [], "macOS \(os): no part of a menu gesture reaches SwiftUI")
            await settleQueuedRequests()
            XCTAssertEqual(rig.controller.model.phase, .idle, "macOS \(os)")
            XCTAssertEqual(rig.h.backstop.arms, 0, "macOS \(os)")
            XCTAssertFalse(rig.manager.isActive, "macOS \(os)")

            // The same delivery does reach the eye: a plain click after a
            // menu whose release went to its tracking starts a session.
            await click(.leftMouseDown, nil, modifiers: .control, rig)
            await click(.leftMouseDown, .leftMouseUp, rig)
            XCTAssertEqual(rig.counts.taps, 1, "macOS \(os)")
            XCTAssertEqual(rig.counts.menus, 4, "macOS \(os)")
            XCTAssertEqual(rig.window.mouseEvents, [.leftMouseDown, .leftMouseUp], "macOS \(os)")
            let started = await eventually { rig.manager.isActive }
            XCTAssertTrue(started, "macOS \(os)")
            await rig.manager.end(reason: .user)
            rig.tearDown()
        }
    }

    /// On macOS 27 a left press on the item holds its early mouse-up back
    /// and sends it when the button really comes up, for the hold to end.
    /// A right click made with the left button still down opens the menu,
    /// whose tracking takes the right release. The left button coming up
    /// while the menu is open still sends its release, and a right release
    /// that comes later goes nowhere.
    @MainActor
    func testARightClickLeavesTheLeftButtonsHeldReleaseAlone() async {
        let rig = await makeRig(osMajorVersion: 27)
        var leftDown = true
        rig.host.buttonIsDown = { leftDown }
        await click(.leftMouseDown, .leftMouseUp, rig)
        XCTAssertEqual(rig.window.mouseEvents, [.leftMouseDown], "The early release is held back")
        await click(.rightMouseDown, nil, rig)
        XCTAssertEqual(rig.counts.menus, 1)
        leftDown = false
        let released = await eventually { rig.window.mouseEvents == [.leftMouseDown, .leftMouseUp] }
        XCTAssertTrue(released, "\(rig.window.mouseEvents.map(\.rawValue))")
        await click(.rightMouseUp, nil, rig)
        XCTAssertEqual(rig.window.mouseEvents, [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(rig.counts.menus, 1)
        XCTAssertEqual(rig.counts.taps, 1, "The left click is the eye's")
        let started = await eventually { rig.manager.isActive }
        XCTAssertTrue(started)
        await rig.manager.end(reason: .user)
        rig.tearDown()
    }

    /// Minimal's eye tracks its press in a native view, which ended the
    /// press when a right press reached it. The host's monitor takes that
    /// press first, so it ends the press itself. A left press held through
    /// a right click and the menu must neither end the session at the
    /// hold's end nor, released early, start one.
    @MainActor
    func testARightClickEndsMinimalsPressOnTheEye() async {
        for os in [26, 27] {
            // Held past the hold's 0.6 s during a session.
            var rig = await makeRig(osMajorVersion: os, mode: .minimal)
            await rig.manager.start(duration: 3600)
            try? await Task.sleep(for: .seconds(0.3))
            rig.counts.leftDown = true
            await click(.leftMouseDown, os >= 27 ? .leftMouseUp : nil, rig)
            await click(.rightMouseDown, nil, rig)
            try? await Task.sleep(for: .seconds(1))
            rig.counts.leftDown = false
            if os < 27 { await click(.leftMouseUp, nil, rig) }
            try? await Task.sleep(for: .seconds(0.2))
            XCTAssertEqual(rig.counts.menus, 1, "macOS \(os), held")
            XCTAssertEqual(rig.counts.holds, 0, "macOS \(os), held")
            XCTAssertEqual(rig.counts.taps, 0, "macOS \(os), held")
            XCTAssertTrue(rig.manager.isActive, "macOS \(os), held")
            await rig.manager.end(reason: .user)
            rig.tearDown()

            // Released well before the hold's end, with no session.
            rig = await makeRig(osMajorVersion: os, mode: .minimal)
            rig.counts.leftDown = true
            post(.leftMouseDown, rig)
            if os >= 27 { post(.leftMouseUp, rig) }
            post(.rightMouseDown, rig)
            rig.counts.leftDown = false
            if os < 27 { post(.leftMouseUp, rig) }
            try? await Task.sleep(for: .seconds(1))
            await settleQueuedRequests()
            XCTAssertEqual(rig.counts.menus, 1, "macOS \(os), released")
            XCTAssertEqual(rig.counts.taps, 0, "macOS \(os), released")
            XCTAssertEqual(rig.h.backstop.arms, 0, "macOS \(os), released")
            XCTAssertFalse(rig.manager.isActive, "macOS \(os), released")
            rig.tearDown()
        }
    }

    /// Popover style takes no click on the host: it lets each through to the
    /// status bar button under it. A right click and a Control-click reach
    /// that button too, and toggle the popover. The monitor neither opens
    /// the menu nor takes the click.
    @MainActor
    func testInPopoverStyleARightClickGoesOnToTheButton() async {
        for os in [26, 27] {
            let rig = await makeRig(osMajorVersion: os)
            rig.host.passesClicksThrough = true
            await click(.rightMouseDown, .rightMouseUp, rig)
            XCTAssertEqual(rig.counts.menus, 0, "macOS \(os)")
            XCTAssertEqual(rig.window.mouseEvents, [.rightMouseDown, .rightMouseUp], "macOS \(os)")
            rig.tearDown()
        }
    }

    /// The controller's own status view, moved from its status item into a
    /// window the test can send events to, so the eye's tap reaches the
    /// controller as it does in the menu bar. The keys held now are
    /// `counts.held`, none unless a test sets them.
    @MainActor
    private func makeControllerRig(_ mode: Config.MenuBarMode, osMajorVersion: Int) async -> Rig {
        _ = NSApplication.shared
        let h = Harness()
        let manager = h.makeManager()
        manager.config.oneClickStart = true
        manager.config.menuBarMode = mode
        let counts = Counts()
        let controller = StatusItemController(
            manager: manager, status: PlaceholderStatus(), showSettings: {},
            appFocus: UIStatusTests.quietFocus, heldModifiers: { counts.held }
        )
        let host = controller.nativeStatusItem.button!.subviews.compactMap { $0 as? StatusHostingView }.first!
        host.removeFromSuperview()
        host.osMajorVersion = osMajorVersion
        host.onRightMouseDown = { _ in counts.menus += 1 }
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.pointerInWindow = { _ in NSPoint(x: size.width / 2, y: size.height / 2) }
        host.buttonIsDown = { counts.leftDown }
        let window = await makeWindow(host, size: size)
        return Rig(h: h, manager: manager, controller: controller, window: window, host: host, counts: counts)
    }

    /// The eye's tap comes on the release, and a person can let go of
    /// Option as they let go of the button. A macOS 26.6.2 VM run posted
    /// Option on both mouse events and released it 0.5 ms after the
    /// mouse-up: Pills and Compact read only the keys held when the tap
    /// ran, found none and started a session. Here Option is on the press
    /// alone, then on the release alone, with no key held: the controls
    /// open and nothing starts. An Option press that never became a tap
    /// (dragged off the item and released there) does not count for the
    /// next click: a plain click then starts the default length.
    @MainActor
    func testAnOptionClickOpensTheControlsThoughOptionIsUpWhenTheTapRuns() async {
        for mode in [Config.MenuBarMode.pills, .compact] {
            for os in [26, 27] {
                let rig = await makeControllerRig(mode, osMajorVersion: os)
                let label = "\(mode), macOS \(os)"
                var controlsOpen: Bool { self.controlsOpen(mode, rig) }
                for (press, release) in [(NSEvent.ModifierFlags.option, NSEvent.ModifierFlags()), ([], .option)] {
                    await click(.leftMouseDown, nil, modifiers: press, rig)
                    await click(.leftMouseUp, nil, modifiers: release, rig)
                    XCTAssertTrue(controlsOpen, "\(label), press \(press.rawValue), release \(release.rawValue)")
                    rig.controller.collapse(returnFocus: false)
                    rig.controller.closeCompactDropdown(returnFocus: false)
                    let closed = await eventually { !controlsOpen && rig.controller.model.phase == .idle }
                    XCTAssertTrue(closed, label)
                }
                await settleQueuedRequests()
                XCTAssertEqual(rig.h.backstop.arms, 0, label)
                XCTAssertFalse(rig.manager.isActive, label)

                let away = NSPoint(x: rig.middle.x + 300, y: rig.middle.y)
                await click(.leftMouseDown, nil, modifiers: .option, rig)
                await send(.leftMouseDragged, at: away, rig)
                await send(.leftMouseUp, at: away, rig)
                XCTAssertFalse(controlsOpen, "\(label): the press dragged away is no tap")
                XCTAssertEqual(rig.controller.model.phase, .idle, label)
                await click(.leftMouseDown, .leftMouseUp, rig)
                let started = await eventually { rig.manager.isActive }
                XCTAssertTrue(started, label)
                await rig.manager.end(reason: .user)
                rig.tearDown()
            }
        }
    }

    /// Sends one event at the eye and returns at once, for a release that
    /// has to come before the hold's 0.6 s, or before SwiftUI gives up on
    /// a tap: a press held 0.6 s or more makes no tap, 0.3 s still does.
    /// `age` is how long ago the event happened.
    @MainActor
    private func post(
        _ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], age: TimeInterval = 0, _ rig: Rig
    ) {
        let event = NSEvent.mouseEvent(
            with: type, location: rig.middle, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime - age, windowNumber: rig.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1
        )!
        NSApp.sendEvent(event)
    }

    /// A right click made while the left button is still down on the eye
    /// keeps that left click's keys, since its release can still come.
    /// Option on the press, a right press, then the left release with no
    /// Option on it or among the keys held: the controls open and nothing
    /// starts, in Pills and Compact. On macOS 27 the left release is held
    /// back until the button comes up, after the right press. The events
    /// go out back to back: with a pause after each, the press lasted long
    /// enough on hosted CI that SwiftUI made no tap at all.
    @MainActor
    func testARightClickKeepsTheKeysOfALeftClickStillUnderway() async {
        for mode in [Config.MenuBarMode.pills, .compact] {
            for os in [26, 27] {
                let rig = await makeControllerRig(mode, osMajorVersion: os)
                let label = "\(mode), macOS \(os)"
                rig.counts.leftDown = true
                post(.leftMouseDown, modifiers: .option, rig)
                if os >= 27 { post(.leftMouseUp, rig) }
                post(.rightMouseDown, rig)
                rig.counts.leftDown = false
                if os < 27 { post(.leftMouseUp, rig) }
                let opened = await eventually { self.controlsOpen(mode, rig) }
                XCTAssertTrue(opened, label)
                XCTAssertEqual(rig.counts.menus, 1, label)
                await settleQueuedRequests()
                XCTAssertEqual(rig.h.backstop.arms, 0, label)
                XCTAssertFalse(rig.manager.isActive, label)
                rig.controller.closeCompactDropdown(returnFocus: false)
                rig.tearDown()
            }
        }
    }

    /// On macOS 27 a click on the status item reaches the app with no
    /// modifier flags, its press and release together as the button goes
    /// down. A 27.0.1 VM logged flags 0 on both with Option held, then let
    /// go of Option 0.2 ms after the mouse-up: the release, held back until
    /// the button came up, found no keys held, and the tap started the
    /// default length. The keys held at the press count: the controls open
    /// and nothing starts, in Pills and Compact. On macOS 26 the same click
    /// with Option on the events' flags opens them too.
    @MainActor
    func testAnOptionClickWhoseEventsCarryNoFlagsCountsTheKeysHeldAtThePress() async {
        for mode in [Config.MenuBarMode.pills, .compact] {
            for os in [26, 27] {
                let rig = await makeControllerRig(mode, osMajorVersion: os)
                let label = "\(mode), macOS \(os)"
                rig.counts.leftDown = true
                rig.counts.held = .option
                post(.leftMouseDown, modifiers: os >= 27 ? [] : .option, rig)
                if os >= 27 { post(.leftMouseUp, rig) }
                rig.counts.leftDown = false
                if os < 27 { post(.leftMouseUp, modifiers: .option, rig) }
                rig.counts.held = []
                let opened = await eventually { self.controlsOpen(mode, rig) }
                XCTAssertTrue(opened, label)
                await settleQueuedRequests()
                XCTAssertEqual(rig.h.backstop.arms, 0, label)
                XCTAssertFalse(rig.manager.isActive, label)
                rig.controller.closeCompactDropdown(returnFocus: false)
                rig.tearDown()
            }
        }
    }

    /// On macOS 27 the keys held as a press is handled are all it has. A
    /// press handled late, after a stall, reads the keys of a later moment,
    /// when Option and the button can be up: the click opens the controls
    /// and starts nothing, as an Option-click does. The same click handled
    /// at once starts the default length. On macOS 26 the events carry
    /// their keys, so a late plain click starts it too.
    @MainActor
    func testAClickHandledLateOnMacOS27StartsNothing() async {
        for mode in [Config.MenuBarMode.pills, .compact] {
            for os in [26, 27] {
                let rig = await makeControllerRig(mode, osMajorVersion: os)
                let label = "\(mode), macOS \(os)"
                post(.leftMouseDown, age: 0.2, rig)
                post(.leftMouseUp, age: 0.2, rig)
                if os >= 27 {
                    let opened = await eventually { self.controlsOpen(mode, rig) }
                    XCTAssertTrue(opened, label)
                    await settleQueuedRequests()
                    XCTAssertEqual(rig.h.backstop.arms, 0, label)
                    XCTAssertFalse(rig.manager.isActive, label)
                    rig.controller.collapse(returnFocus: false)
                    rig.controller.closeCompactDropdown(returnFocus: false)
                    let closed = await eventually { !self.controlsOpen(mode, rig) && rig.controller.model.phase == .idle }
                    XCTAssertTrue(closed, label)
                    post(.leftMouseDown, rig)
                    post(.leftMouseUp, rig)
                }
                let started = await eventually { rig.manager.isActive }
                XCTAssertTrue(started, label)
                XCTAssertFalse(controlsOpen(mode, rig), label)
                await rig.manager.end(reason: .user)
                rig.tearDown()
            }
        }
    }

    /// The eye's tap reads the keys the monitor kept for the click it
    /// answers, whenever it runs before the next press, and never the keys
    /// of another click. Here SwiftUI runs the tap inside the release's
    /// dispatch, and a test cannot make it run later, so this reads the
    /// host's keys as the tap does (`takeClickModifiers`) at the moments a
    /// later tap would: after the release's dispatch, and after the next
    /// press.
    @MainActor
    func testTheKeysKeptForTheTapAreThoseOfTheLastReleasedClick() async {
        for os in [26, 27] {
            let rig = await makeRig(osMajorVersion: os, eyeTapsReachController: false)
            let label = "macOS \(os)"
            await click(.leftMouseDown, nil, modifiers: .option, rig)
            await click(.leftMouseUp, nil, rig)
            XCTAssertEqual(rig.host.takeClickModifiers(), .option, "\(label): after the release")
            XCTAssertEqual(rig.host.takeClickModifiers(), [], "\(label): read once")

            // A plain click, then an Option press: none of that press's keys.
            await click(.leftMouseDown, .leftMouseUp, rig)
            await click(.leftMouseDown, nil, modifiers: .option, rig)
            XCTAssertEqual(rig.host.takeClickModifiers(), [], "\(label): after an Option press")
            await click(.leftMouseUp, nil, rig)
            XCTAssertEqual(rig.host.takeClickModifiers(), .option, label)

            // An Option click, then a plain press: none of the click's keys.
            await click(.leftMouseDown, nil, modifiers: .option, rig)
            await click(.leftMouseUp, nil, rig)
            await click(.leftMouseDown, nil, rig)
            XCTAssertEqual(rig.host.takeClickModifiers(), [], "\(label): after a plain press")
            await click(.leftMouseUp, nil, rig)
            XCTAssertEqual(rig.host.takeClickModifiers(), [], label)
            XCTAssertEqual(rig.counts.taps, 5, label)
            rig.tearDown()
        }
    }

    /// VoiceOver's press on the eye has no mouse click, so it reads none of
    /// the keys the host kept from a click. Option clicks that made no tap
    /// come first: one dragged off the item and released there, which keeps
    /// no keys, and one released on the item beside the eye, which keeps
    /// Option for a tap that never comes. VoiceOver's press then starts the
    /// default length, in Pills and Compact. A test cannot press the eye as
    /// VoiceOver does (SwiftUI gives an in-process query no accessibility
    /// elements), so this calls the closure the eye's accessibility action
    /// calls.
    @MainActor
    func testVoiceOversPressReadsNoKeysFromAnEarlierClick() async {
        for mode in [Config.MenuBarMode.pills, .compact] {
            for os in [26, 27] {
                let rig = await makeControllerRig(mode, osMajorVersion: os)
                let label = "\(mode), macOS \(os)"
                let away = NSPoint(x: rig.middle.x + 300, y: rig.middle.y)
                await click(.leftMouseDown, nil, modifiers: .option, rig)
                await send(.leftMouseDragged, at: away, rig)
                await send(.leftMouseUp, at: away, rig)
                XCTAssertEqual(rig.host.takeClickModifiers(), [], "\(label): released off the item")

                let beside = NSPoint(x: 1, y: 1)
                await click(.leftMouseDown, nil, modifiers: .option, rig)
                await send(.leftMouseDragged, at: beside, rig)
                await send(.leftMouseUp, at: beside, rig)
                XCTAssertFalse(controlsOpen(mode, rig), "\(label): released beside the eye")
                XCTAssertEqual(rig.controller.model.phase, .idle, label)

                rig.host.rootView.onActivateIcon?()
                let started = await eventually { rig.manager.isActive }
                XCTAssertTrue(started, label)
                XCTAssertFalse(controlsOpen(mode, rig), label)
                await rig.manager.end(reason: .user)
                rig.tearDown()
            }
        }
    }

    @MainActor
    private func controlsOpen(_ mode: Config.MenuBarMode, _ rig: Rig) -> Bool {
        mode == .pills ? rig.controller.model.phase.isEntering : rig.controller.compactModel.isPresented
    }

    @MainActor
    private func send(_ type: NSEvent.EventType, at point: NSPoint, _ rig: Rig) async {
        let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1
        )!
        NSApp.sendEvent(event)
        try? await Task.sleep(for: .seconds(0.2))
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
}
