import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

/// Real mouse events, delivered in-process to the SwiftUI status view, so
/// the press-and-hold ring is exercised without a menu bar or the
/// Accessibility permission.
///
/// macOS 27 delivers a status item click as an instant down and up, both
/// located at the middle of the item's window whatever the pointer is over
/// and however long the button stays down. `press` reproduces that: the
/// events carry the window's centre and the up follows the down at once,
/// while the pointer's real position and the button's real state are given
/// separately, as the live app reads them (`NSEvent.mouseLocation`,
/// `NSEvent.pressedMouseButtons`).
final class HoldToEndEventTests: XCTestCase {
    private final class Hits {
        var icon = 0, countdown = 0, hold = 0
        var summary: String { "icon=\(icon) countdown=\(countdown) hold=\(hold)" }
    }

    /// What the hardware is doing, read by the host through its injected closures.
    private final class Hardware {
        var pointerX: CGFloat = 0
        var buttonDown = false
    }

    @MainActor
    private struct Rig {
        let window: NSWindow
        let host: StatusHostingView
        let hits: Hits
        let hardware: Hardware
        var size: CGSize { host.frame.size }
        /// Window coordinates of the three targets, from the laid-out running item.
        var icon: CGFloat { 14 }
        var countdown: CGFloat { 50 }
        var cross: CGFloat { size.width - 16 }
    }

    @MainActor
    private func makeRig(_ harness: Harness, osMajorVersion: Int = 27) async -> Rig {
        _ = NSApplication.shared
        let hits = Hits()
        let hardware = Hardware()
        let manager = harness.makeManager()
        let model = MenuBarModel()
        await manager.start(duration: 3600)
        model.phase = .running
        let root = StatusRootView(
            model: model, manager: manager,
            onTapIcon: { hits.icon += 1 }, onTapPill: { _ in },
            onTapCountdown: { hits.countdown += 1 }, onHoldEnd: { hits.hold += 1 },
            onWidthChange: { _ in },
            buttonIsDown: { hardware.buttonDown },
            pointerLocation: { CGPoint(x: hardware.pointerX, y: 0) }
        )
        let host = StatusItemController.makeHostingView(root)
        host.osMajorVersion = osMajorVersion
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.pointerInWindow = { _ in NSPoint(x: hardware.pointerX, y: size.height / 2) }
        host.buttonIsDown = { hardware.buttonDown }
        // Off screen: the window only needs to exist to deliver events.
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.5))
        return Rig(window: window, host: host, hits: hits, hardware: hardware)
    }

    @MainActor
    private func deliver(_ type: NSEvent.EventType, _ rig: Rig, number: Int, at point: NSPoint? = nil) {
        let centre = NSPoint(x: rig.size.width / 2, y: rig.size.height / 2)
        let event = NSEvent.mouseEvent(
            with: type, location: point ?? centre, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
            context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
        NSApp.sendEvent(event)
    }

    /// Put the button down over `x`; the system reports the click at once.
    @MainActor
    private func pressDown(over x: CGFloat, _ rig: Rig) {
        rig.hardware.pointerX = x
        rig.hardware.buttonDown = true
        deliver(.leftMouseDown, rig, number: 1)
        deliver(.leftMouseUp, rig, number: 2)
    }

    @MainActor
    private func letGo(_ rig: Rig) async {
        rig.hardware.buttonDown = false
        try? await Task.sleep(for: .seconds(0.15))
    }

    @MainActor
    private func press(over x: CGFloat, for seconds: TimeInterval, _ rig: Rig) async {
        pressDown(over: x, rig)
        try? await Task.sleep(for: .seconds(seconds))
        await letGo(rig)
    }

    @MainActor
    func testHoldingTheCrossEndsTheSessionWhateverTheSystemReports() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness)
        defer { rig.window.orderOut(nil) }
        pressDown(over: rig.cross, rig)
        try? await Task.sleep(for: .seconds(0.4))
        XCTAssertEqual(rig.hits.hold, 0, "the ring has not closed yet")
        try? await Task.sleep(for: .seconds(0.5))
        XCTAssertEqual(rig.hits.hold, 1, "the session ends while the button is still down")
        await letGo(rig)
        XCTAssertEqual(rig.hits.summary, "icon=0 countdown=0 hold=1")
    }

    @MainActor
    func testAShortPressOnTheCrossDoesNothingAndDoesNotOpenThePills() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness)
        defer { rig.window.orderOut(nil) }
        await press(over: rig.cross, for: 0.1, rig)
        XCTAssertEqual(rig.hits.summary, "icon=0 countdown=0 hold=0")
    }

    @MainActor
    func testSlidingOffTheCrossWhileHoldingCancelsTheHold() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness)
        defer { rig.window.orderOut(nil) }
        pressDown(over: rig.cross, rig)
        try? await Task.sleep(for: .seconds(0.2))
        rig.hardware.pointerX = rig.icon
        try? await Task.sleep(for: .seconds(0.9))
        await letGo(rig)
        XCTAssertEqual(rig.hits.hold, 0)
    }

    @MainActor
    func testTheCountdownAndTheEyeStillTakeTheirOwnClicks() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness)
        defer { rig.window.orderOut(nil) }
        await press(over: rig.countdown, for: 0.1, rig)
        XCTAssertEqual(rig.hits.summary, "icon=0 countdown=1 hold=0")
        await press(over: rig.icon, for: 0.1, rig)
        XCTAssertEqual(rig.hits.summary, "icon=1 countdown=1 hold=0")
    }

    /// An event that is not at the item's middle is accurate (macOS 26). If
    /// the pointer has moved since it was queued, it must not be moved with it.
    @MainActor
    func testAnAccurateEventIsNotMovedToWhereThePointerIsNow() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness)
        defer { rig.window.orderOut(nil) }
        let y = rig.size.height / 2
        rig.hardware.buttonDown = true
        rig.hardware.pointerX = rig.icon
        deliver(.leftMouseDown, rig, number: 1, at: NSPoint(x: rig.cross, y: y))
        try? await Task.sleep(for: .seconds(0.9))
        rig.hardware.buttonDown = false
        deliver(.leftMouseUp, rig, number: 2, at: NSPoint(x: rig.cross, y: y))
        try? await Task.sleep(for: .seconds(0.1))
        XCTAssertEqual(rig.hits.summary, "icon=0 countdown=0 hold=1", "the press stayed on the cross")
    }

    /// macOS 26 reports every click where it happened, so an event at the
    /// item's middle is a real one. It must not follow the pointer, which has
    /// moved on to the ring while the click waited in the queue.
    @MainActor
    func testOnMacOS26AClickAtTheMiddleIsNotMovedToWhereThePointerIs() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let rig = await makeRig(harness, osMajorVersion: 26)
        defer { rig.window.orderOut(nil) }
        rig.hardware.pointerX = rig.cross
        deliver(.leftMouseDown, rig, number: 1)
        deliver(.leftMouseUp, rig, number: 2)
        try? await Task.sleep(for: .seconds(0.2))
        XCTAssertEqual(rig.hits.summary, "icon=0 countdown=1 hold=0", "the click stayed in the middle")
    }

    /// Press a bare hold-to-end button, let `midway` change the hardware 0.3 s
    /// in, and return how many times the ring ended the session. No release
    /// and no drag event is ever delivered: the ring's own timer is the only
    /// thing that can notice the change.
    @MainActor
    private func holdBareButton(
        isPressed: @escaping () -> Bool, pointer: @escaping () -> CGPoint, midway: () -> Void
    ) async -> Int {
        _ = NSApplication.shared
        var holds = 0
        let button = HoldToEndButton(reduceMotion: true, action: { holds += 1 }, isPressed: isPressed, pointer: pointer)
        let host = NSHostingView(rootView: button)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.3))
        let centre = NSPoint(x: size.width / 2, y: size.height / 2)
        NSApp.sendEvent(NSEvent.mouseEvent(
            with: .leftMouseDown, location: centre, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!)
        // The ring closes 0.6 s after the press: leave room on both sides for
        // a slow runner.
        try? await Task.sleep(for: .seconds(0.2))
        midway()
        try? await Task.sleep(for: .seconds(0.6))
        return holds
    }

    /// The ring fires on its own timer; the release is only noticed on the
    /// next poll. A release in between must not end the session.
    @MainActor
    func testReleasingBeforeTheRingClosesDoesNotEndTheSessionEvenIfNoReleaseArrived() async {
        for (stillDown, expectedHolds) in [(false, 0), (true, 1)] {
            var down = true
            let holds = await holdBareButton(isPressed: { down }, pointer: { .zero }, midway: { down = stillDown })
            XCTAssertEqual(holds, expectedHolds, "button still down at the deadline: \(stillDown)")
        }
    }

    /// The drags that cancel a hold come from a poll. A slide off the ring
    /// after the last poll has not been reported when the ring closes, so the
    /// ring has to look at the pointer itself.
    @MainActor
    func testSlidingOffBeforeTheRingClosesDoesNotEndTheSessionEvenIfNoDragArrived() async {
        for (slideTo, expectedHolds) in [(CGFloat(8), 1), (CGFloat(20), 0)] {
            var pointerX: CGFloat = 100
            let holds = await holdBareButton(
                isPressed: { true }, pointer: { CGPoint(x: pointerX, y: 50) }, midway: { pointerX += slideTo }
            )
            XCTAssertEqual(holds, expectedHolds, "pointer moved \(slideTo) pt (the cancel distance is 12)")
        }
    }
}
