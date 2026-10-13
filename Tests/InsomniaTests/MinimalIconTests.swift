import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

final class MinimalIconTests: XCTestCase {
    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint = CGPoint(x: 10, y: 10),
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    @MainActor
    func testNativeHitViewClicksOnMouseUpAndAcceptsInactiveWindowClick() {
        _ = NSApplication.shared
        var now = 10.0
        var clicks = 0
        var pressed = false
        let view = MinimalIconMouseView(clock: { now })
        view.update(isEnabled: true, sessionActive: false, onTap: { clicks += 1 },
                    onHold: { XCTFail("A click must not end") }, onPressedChange: { pressed = $0 })
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertFalse(view.isAccessibilityElement())
        XCTAssertTrue(view.hitTest(CGPoint(x: 10, y: 10)) === view)
        view.mouseDown(with: mouse(.leftMouseDown))
        XCTAssertTrue(pressed)
        XCTAssertEqual(clicks, 0)
        now += 0.2
        view.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertFalse(pressed)
        XCTAssertEqual(clicks, 1)
    }

    @MainActor
    func testNativeHoldTaskEndsOnceBeforeRelease() async {
        _ = NSApplication.shared
        var ends = 0
        let ended = expectation(description: "The hold ends the timer before mouse-up")
        ended.assertForOverFulfill = true
        let view = MinimalIconMouseView(holdDuration: 0.01)
        view.update(isEnabled: true, sessionActive: true,
                    onTap: { XCTFail("The release after a hold must not add time") },
                    onHold: {
                        ends += 1
                        ended.fulfill()
                    }, onPressedChange: { _ in })
        view.mouseDown(with: mouse(.leftMouseDown))
        // The hold task begins its delay only once the main actor schedules it.
        // Wait for delivery, rather than racing that task with a fixed sleep.
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(ends, 1)
        view.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertEqual(ends, 1)
    }

    @MainActor
    func testNativeDraggingAwayAndBackCancelsPress() {
        _ = NSApplication.shared
        var now = 10.0
        let view = MinimalIconMouseView(clock: { now })
        view.update(isEnabled: true, sessionActive: true,
                    onTap: { XCTFail("A cancelled drag must not click") },
                    onHold: { XCTFail("A cancelled drag must not end") }, onPressedChange: { _ in })
        view.mouseDown(with: mouse(.leftMouseDown))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 30, y: 10)))
        view.mouseDragged(with: mouse(.leftMouseDragged))
        now += 1
        view.mouseUp(with: mouse(.leftMouseUp))
    }

    @MainActor
    func testNativeDisabledStateAndRemovalCancelArmedHold() async throws {
        _ = NSApplication.shared
        for removal in [false, true] {
            let view = MinimalIconMouseView(holdDuration: 0.01)
            let tap = { XCTFail("A cancelled hold must not click") }
            let hold = { XCTFail("A cancelled hold must not end") }
            view.update(isEnabled: true, sessionActive: true, onTap: tap, onHold: hold, onPressedChange: { _ in })
            view.mouseDown(with: mouse(.leftMouseDown))
            if removal {
                view.stopTracking()
            } else {
                view.update(isEnabled: false, sessionActive: true, onTap: tap, onHold: hold, onPressedChange: { _ in })
                view.update(isEnabled: true, sessionActive: true, onTap: tap, onHold: hold, onPressedChange: { _ in })
            }
            try await Task.sleep(for: .milliseconds(30))
            view.mouseUp(with: mouse(.leftMouseUp))
        }
    }

    @MainActor
    func testNativeSecondaryClicksForwardToStatusResponder() {
        final class Receiver: NSResponder {
            var controlClicks = 0
            var rightClicks = 0
            override func mouseDown(with event: NSEvent) { controlClicks += 1 }
            override func rightMouseDown(with event: NSEvent) { rightClicks += 1 }
        }
        _ = NSApplication.shared
        let receiver = Receiver()
        let view = MinimalIconMouseView()
        view.nextResponder = receiver
        view.update(isEnabled: true, sessionActive: true,
                    onTap: { XCTFail("Secondary clicks must not add time") },
                    onHold: { XCTFail("Secondary clicks must not end") }, onPressedChange: { _ in })
        view.rightMouseDown(with: mouse(.rightMouseDown))
        view.mouseDown(with: mouse(.leftMouseDown, flags: .control))
        view.mouseUp(with: mouse(.leftMouseUp, flags: .control))
        XCTAssertEqual(receiver.rightClicks, 1)
        XCTAssertEqual(receiver.controlClicks, 1)
    }

    @MainActor
    func testSecondaryClicksReachActualStatusHostingResponderThroughSwiftUI() async throws {
        _ = NSApplication.shared
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        manager.config.menuBarMode = .minimal
        let model = MenuBarModel()
        let host = StatusItemController.makeHostingView(StatusRootView(
            model: model, manager: manager,
            onTapIcon: { XCTFail("A secondary click must not start or extend") },
            onTapPill: { _ in XCTFail("Minimal mode has no duration pills") },
            onTapCountdown: {},
            onHoldEnd: { XCTFail("A secondary click must not end the timer") },
            onWidthChange: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.level = .statusBar
        window.contentView = host
        defer { window.contentView = nil }
        var opened = 0
        var receivedEvents: [NSEvent.EventType] = []
        host.onRightMouseDown = { event in
            receivedEvents.append(event.type)
            opened += 1
        }

        func mouseArea(in view: NSView) -> MinimalIconMouseView? {
            if let area = view as? MinimalIconMouseView { return area }
            for child in view.subviews {
                if let area = mouseArea(in: child) { return area }
            }
            return nil
        }

        // Exercise both content branches using the actual representable
        // created by SwiftUI, including every intermediate responder.
        let values: [Double?] = [nil, 0.5]
        for progress in values {
            model.minimalProgress = progress
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            for _ in 0..<10 where mouseArea(in: host) == nil {
                await Task.yield()
                host.layoutSubtreeIfNeeded()
            }
            let area = try XCTUnwrap(mouseArea(in: host))
            let point = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1
                ))
            }
            let before = opened
            area.rightMouseDown(with: try event(.rightMouseDown))
            XCTAssertEqual(opened, before + 1, "Right-click must cross the real hosting responder chain")
            area.mouseDown(with: try event(.leftMouseDown, flags: .control))
            area.mouseUp(with: try event(.leftMouseUp, flags: .control))
            XCTAssertEqual(opened, before + 2, "Control-click must reach the same Settings menu")
            XCTAssertEqual(Array(receivedEvents.suffix(2)), [.rightMouseDown, .leftMouseDown],
                           "The context menu needs the original secondary-click event")
        }
    }

    func testShortPressClicksOnlyOnRelease() {
        for active in [false, true] {
            var press = MinimalIconPress()
            press.begin(at: 10, sessionActive: active)
            XCTAssertTrue(press.isPressed)
            XCTAssertEqual(press.release(at: 10.2, sessionActive: active, holdDuration: 0.6), .tap)
            XCTAssertEqual(press.release(at: 10.3, sessionActive: active, holdDuration: 0.6), .none)
        }
    }

    func testHoldEndsExactlyOnceWithoutAddingTimeOnRelease() {
        var press = MinimalIconPress()
        press.begin(at: 10, sessionActive: true)
        XCTAssertEqual(press.holdElapsed(sessionActive: true), .end)
        XCTAssertEqual(press.holdElapsed(sessionActive: true), .none)
        XCTAssertEqual(press.release(at: 11, sessionActive: true, holdDuration: 0.6), .none)
    }

    func testIdleHoldDoesNotStartSession() {
        var press = MinimalIconPress()
        press.begin(at: 10, sessionActive: false)
        XCTAssertEqual(press.holdElapsed(sessionActive: false), .none)
        XCTAssertEqual(press.release(at: 11, sessionActive: false, holdDuration: 0.6), .none)
        press.begin(at: 12, sessionActive: false)
        XCTAssertEqual(press.release(at: 12.2, sessionActive: false, holdDuration: 0.6), .tap,
                       "A new short press remains available after the idle hold")
    }

    func testDelayedHoldTaskCannotTurnLongPressIntoClick() {
        for active in [false, true] {
            var press = MinimalIconPress()
            press.begin(at: 10, sessionActive: active)
            XCTAssertEqual(press.release(at: 11, sessionActive: active, holdDuration: 0.6), active ? .end : .none)
            XCTAssertEqual(press.holdElapsed(sessionActive: active), .none)
        }
    }

    func testDraggingAwayAndBackCannotRearmClickOrHold() {
        var press = MinimalIconPress()
        press.begin(at: 10, sessionActive: true)
        press.move(to: CGPoint(x: 25, y: 10), translation: CGSize(width: 15, height: 0))
        press.move(to: CGPoint(x: 10, y: 10), translation: .zero)
        press.begin(at: 10.3, sessionActive: true)
        XCTAssertTrue(press.isCancelled)
        XCTAssertEqual(press.holdElapsed(sessionActive: true), .none)
        XCTAssertEqual(press.release(at: 11, sessionActive: true, holdDuration: 0.6), .none)
    }

    func testLeavingHitAreaCancelsEvenWithSmallTranslation() {
        var press = MinimalIconPress()
        press.begin(at: 10, sessionActive: true)
        press.move(to: CGPoint(x: -1, y: 10), translation: CGSize(width: -2, height: 0))
        XCTAssertEqual(press.release(at: 10.2, sessionActive: true, holdDuration: 0.6), .none)
    }

    func testDisabledOrChangedSessionCannotUseStalePress() {
        var press = MinimalIconPress()
        press.begin(at: 10, sessionActive: true)
        press.cancel()
        XCTAssertEqual(press.holdElapsed(sessionActive: true), .none)
        XCTAssertEqual(press.release(at: 10.2, sessionActive: true, holdDuration: 0.6), .none)

        press.begin(at: 11, sessionActive: false)
        XCTAssertEqual(press.holdElapsed(sessionActive: true), .none,
                       "A session that began after mouse-down must not be ended by an idle hold")
        XCTAssertEqual(press.release(at: 12, sessionActive: true, holdDuration: 0.6), .none)

        press.begin(at: 13, sessionActive: true)
        XCTAssertEqual(press.holdElapsed(sessionActive: false), .none)

        press = MinimalIconPress()
        press.begin(at: 14, sessionActive: true)
        XCTAssertEqual(press.release(at: 14.2, sessionActive: false, holdDuration: 0.6), .none,
                       "Expiration between mouse-down and mouse-up must not restart the timer")
    }

    @MainActor
    func testIconKeepsTwentyPointLayoutForEveryNativeProgressValue() {
        _ = NSApplication.shared
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        let model = MenuBarModel()
        let values: [Double?] = [nil, 0, 0.5, 1]
        for progress in values {
            model.minimalProgress = progress
            for reduceMotion in [false, true] {
                let host = NSHostingView(rootView: MinimalStatusIcon(
                    model: model, manager: manager, reduceMotion: reduceMotion,
                    onTap: {}, onHold: {}
                ).transaction { $0.disablesAnimations = true })
                XCTAssertEqual(host.fittingSize.width, 20, accuracy: 0.01)
                XCTAssertEqual(host.fittingSize.height, 20, accuracy: 0.01)
            }
        }
    }
}
