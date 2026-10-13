import AppKit
import XCTest
@testable import Insomnia

@MainActor
final class QuickMenuToggleTests: XCTestCase {
    func testEyeClickClosesInsteadOfReopeningAfterTransientDismissal() throws {
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            let f = ToggleFixture(); defer { f.harness.home.destroy() }
            f.controller.makeStatusRootView().onTapIcon()
            let menu = try XCTUnwrap(f.state.popovers.last)
            XCTAssertTrue(menu.isShown)
            f.state.event = try f.event(type, anchor: menu.anchor)
            // AppKit may ask to dismiss an outside-clicked transient popover
            // BEFORE the status item's handler receives the same mouse down.
            menu.requestAutomaticClose()
            f.controller.makeStatusRootView().onTapIcon()
            XCTAssertEqual(f.state.popovers.count, 1, "the same click must not build a replacement menu")
            XCTAssertFalse(f.state.popovers.last?.isShown ?? true)
            XCTAssertFalse(f.controller.manager.isActive)
            XCTAssertTrue(f.state.cues.isEmpty)
        }
    }

    func testRepeatedClicksToggleAndForcedCloseDoesNotConsultDelegate() throws {
        let f = ToggleFixture(); defer { f.harness.home.destroy() }
        let root = f.controller.makeStatusRootView()
        for _ in 0..<5 {
            root.onTapIcon()
            let menu = try XCTUnwrap(f.state.popovers.last)
            XCTAssertTrue(menu.isShown)
            f.state.event = try f.event(.leftMouseDown, anchor: menu.anchor)
            root.onTapIcon()
            XCTAssertFalse(menu.isShown)
            f.state.event = nil
        }
        XCTAssertEqual(f.state.popovers.count, 5)
        XCTAssertTrue(f.state.cues.isEmpty)
    }

    func testOutsideClicksEscapeAndCommandDragStillDismissNormally() throws {
        let f = ToggleFixture(); defer { f.harness.home.destroy() }
        let root = f.controller.makeStatusRootView()
        root.onTapIcon()
        let first = try XCTUnwrap(f.state.popovers.last)
        f.state.event = try f.event(.leftMouseDown, anchor: first.anchor, outside: true)
        first.requestAutomaticClose()
        XCTAssertFalse(first.isShown)
        f.state.event = nil // Escape/key-driven or focus-driven dismissal.
        root.onTapIcon()
        let second = try XCTUnwrap(f.state.popovers.last)
        second.requestAutomaticClose()
        XCTAssertFalse(second.isShown)
        root.onTapIcon()
        let third = try XCTUnwrap(f.state.popovers.last)
        f.state.event = try f.event(.leftMouseDown, anchor: third.anchor, modifiers: .command)
        third.requestAutomaticClose()
        XCTAssertFalse(third.isShown)
    }

    func testStaleOpeningEventDoesNotBlockLaterOutsideDismissal() throws {
        let f = ToggleFixture(); defer { f.harness.home.destroy() }
        let root = f.controller.makeStatusRootView()
        root.onTapIcon()
        let first = try XCTUnwrap(f.state.popovers.last)
        root.onTapIcon()
        f.state.event = try f.event(.leftMouseDown, anchor: first.anchor)
        root.onTapIcon()
        let second = try XCTUnwrap(f.state.popovers.last)
        // A focus/global-outside dismissal can see the last event instead
        // of a fresh one. The already-handled opening click is not a toggle.
        second.requestAutomaticClose()
        XCTAssertFalse(second.isShown)
    }

    func testLateCloseFromAnOldPopoverCannotClearTheCurrentMenu() throws {
        let f = ToggleFixture(); defer { f.harness.home.destroy() }
        let root = f.controller.makeStatusRootView()
        root.onTapIcon()
        let first = try XCTUnwrap(f.state.popovers.last)
        root.onTapIcon()
        root.onTapIcon()
        let second = try XCTUnwrap(f.state.popovers.last)
        first.close()
        root.onTapIcon()
        XCTAssertFalse(second.isShown)
        XCTAssertEqual(f.state.popovers.count, 2)
    }
}

@MainActor
private final class ToggleFixture {
    final class State {
        var popovers: [FixturePopover] = []
        var event: NSEvent?
        var cues: [SessionSoundCue] = []
    }
    let harness = Harness()
    let state: State
    let controller: StatusItemController

    init() {
        _ = NSApplication.shared
        let state = State()
        self.state = state
        controller = StatusItemController(manager: harness.makeManager(), status: PlaceholderStatus(), showSettings: {},
            playSessionSound: { state.cues.append($0) }, captureEvents: false,
            makeQuickPopover: {
                let menu = FixturePopover()
                state.popovers.append(menu)
                return menu
            }, currentMenuEvent: { state.event })
    }

    func event(_ type: NSEvent.EventType, anchor: NSView?, outside: Bool = false,
               modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let view = try XCTUnwrap(anchor)
        let window = try XCTUnwrap(view.window)
        let point = NSPoint(x: outside ? view.bounds.maxX + 100 : view.bounds.midX, y: view.bounds.midY)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

/// Exercise the real controller/delegate without presenting desktop UI.
@MainActor
private final class FixturePopover: NSPopover {
    private var fixtureShown = false
    weak var anchor: NSView?
    override var isShown: Bool { fixtureShown }
    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        anchor = positioningView
        fixtureShown = true
    }
    override func close() {
        fixtureShown = false
        delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
    }
    func requestAutomaticClose() {
        if delegate?.popoverShouldClose?(self) ?? true { close() }
    }
}
