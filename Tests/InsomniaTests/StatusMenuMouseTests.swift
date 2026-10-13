import AppKit
import XCTest
@testable import Insomnia

final class StatusMenuMouseTests: XCTestCase {
    @MainActor
    func testRightClickOpensOnlyTheMenuAndConsumesItsEntireGesture() throws {
        let fixture = MenuMouseFixture()
        defer { fixture.close() }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseDragged, .rightMouseUp] {
            XCTAssertNil(fixture.host.filterMenuMouse(try fixture.event(type)))
        }
        XCTAssertEqual(fixture.menuOpenCount, 1)
        XCTAssertFalse(fixture.manager.isActive)
        XCTAssertNil(fixture.manager.session)
        XCTAssertEqual(fixture.model.phase, .idle)
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.rightMouseUp)))
    }

    @MainActor
    func testControlClickConsumesReleaseEvenAfterControlIsReleased() throws {
        let fixture = MenuMouseFixture()
        defer { fixture.close() }
        XCTAssertNil(fixture.host.filterMenuMouse(try fixture.event(.leftMouseDown, flags: .control)))
        XCTAssertNil(fixture.host.filterMenuMouse(try fixture.event(.leftMouseDragged)))
        XCTAssertNil(fixture.host.filterMenuMouse(try fixture.event(.leftMouseUp)))
        XCTAssertEqual(fixture.menuOpenCount, 1)
        XCTAssertFalse(fixture.manager.isActive)
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.leftMouseDown)))
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.leftMouseUp)))
    }

    @MainActor
    func testPrimaryClicksAndCommandDragRemainAvailableToTheNativeControls() throws {
        let fixture = MenuMouseFixture()
        defer { fixture.close() }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(type)))
            XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(type, flags: .command)))
        }
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.rightMouseDown, flags: .command)))
        XCTAssertEqual(fixture.menuOpenCount, 0)
    }

    @MainActor
    func testMenusInOtherWindowsAndOutsideTheStatusItemAreUnaffected() throws {
        let fixture = MenuMouseFixture()
        defer { fixture.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.rightMouseDown, window: other)))
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.rightMouseDown, point: NSPoint(x: 250, y: 25))))
        XCTAssertEqual(fixture.menuOpenCount, 0)
    }

    @MainActor
    func testRemovingTheHostClearsItsPendingMenuGesture() throws {
        let fixture = MenuMouseFixture()
        defer { fixture.close() }
        XCTAssertNil(fixture.host.filterMenuMouse(try fixture.event(.rightMouseDown)))
        fixture.host.removeFromSuperview()
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.rightMouseUp)))
        XCTAssertNotNil(fixture.host.filterMenuMouse(try fixture.event(.rightMouseDown)))
        XCTAssertEqual(fixture.menuOpenCount, 1)
    }
}

@MainActor
private final class MenuMouseFixture {
    let harness: Harness
    let manager: SessionManager
    let model = MenuBarModel()
    let host: StatusHostingView
    let window: NSWindow
    var menuOpenCount = 0

    init() {
        _ = NSApplication.shared
        harness = Harness()
        manager = harness.makeManager()
        host = StatusItemController.makeHostingView(StatusRootView(
            model: model, manager: manager, onTapIcon: {}, onTapPill: { _ in },
            onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in }
        ))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.onRightMouseDown = { [weak self] in self?.menuOpenCount += 1 }
    }

    func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], point: NSPoint = NSPoint(x: 15, y: 25), window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: (window ?? self.window).windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
    }

    func close() {
        host.removeFromSuperview()
        window.close()
        harness.home.destroy()
    }
}
