import AppKit
import XCTest
@testable import Insomnia

/// Exercise AppKit's real first-responder path. Calling the model's key
/// handler directly would not catch a missing or stale requestFocus callback.
@MainActor
final class CompactResponderIntegrationTests: XCTestCase {
    func testOpenDismissAndReopenRestoresNativeKeyDeliveryAndSubmitsTheRetainedDraft() async throws {
        _ = NSApplication.shared
        let h = Harness()
        let manager = h.makeManager()
        manager.config.menuBarMode = .compact
        let clock = h.clock
        let controller = StatusItemController(
            manager: manager, status: PlaceholderStatus(), showSettings: {},
            clock: { clock.now }
        )
        defer {
            controller.closeCompactDropdown()
            h.home.destroy()
        }

        controller.iconTapped()
        let dropdown = try XCTUnwrap(controller.compactDropdown)
        let window = dropdown.window
        try await requireInputResponder(in: window, after: "Opening")
        let initialReceiver = try XCTUnwrap(window.firstResponder as? DurationInputKeyResponder.Receiver)
        XCTAssertTrue(dropdown.isShown)
        XCTAssertTrue(controller.compactModel.isPresented)

        // Enter one hour and two minutes using the same window dispatch as
        // physical key events, without supplying or replacing its responder.
        try send("1", code: 18, to: window)
        try send("\t", code: 48, to: window)
        try send("2", code: 19, to: window)
        XCTAssertEqual(controller.compactModel.entry.input, DurationInput(hours: 1, minutes: 2))
        XCTAssertEqual(controller.compactModel.entry.focused, .minutes)

        try send("\u{1b}", code: 53, to: window)
        let dismissed = await eventually {
            // Wait for the hidden SwiftUI hierarchy to apply its inactive
            // state and release the responder. Reopening before that update
            // could coalesce false/true and never exercise focus reacquisition.
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return !dropdown.isShown && !window.isVisible && !window.isKeyWindow &&
                !initialReceiver.acceptsFirstResponder &&
                !(window.firstResponder is DurationInputKeyResponder.Receiver)
        }
        XCTAssertTrue(dismissed, "Escape must dismiss the panel and release its native input responder")
        XCTAssertFalse(controller.compactModel.isPresented)
        XCTAssertEqual(controller.compactModel.entry.input, DurationInput(hours: 1, minutes: 2))
        XCTAssertFalse(manager.isActive)

        controller.iconTapped()
        XCTAssertTrue(controller.compactDropdown?.window === window)
        try await requireInputResponder(in: window, after: "Reopening")
        XCTAssertTrue(controller.compactModel.isPresented)
        XCTAssertEqual(controller.compactModel.entry.input, DurationInput(hours: 1, minutes: 2))
        XCTAssertEqual(controller.compactModel.entry.focused, .minutes)

        // Reopening restores native focus to the retained Minutes pill, so
        // another digit extends its draft and Return starts that exact time.
        try send("5", code: 23, to: window)
        XCTAssertEqual(controller.compactModel.entry.input, DurationInput(hours: 1, minutes: 25))
        try send("\r", code: 36, to: window)
        XCTAssertEqual(controller.model.phase, .starting)
        let started = await eventually { manager.isActive && !controller.compactModel.isBusy }
        XCTAssertTrue(started, "Return must submit through the controller and session manager")
        XCTAssertEqual(manager.session?.endsAt, h.clock.now.addingTimeInterval(5100))
        XCTAssertEqual(try h.store.loadSession(), manager.session)
        XCTAssertTrue(try h.store.loadState()?.sleepDisabledByUs == true)
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)

        await manager.end(reason: .user)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), .clean)
    }

    private func requireInputResponder(in window: NSWindow, after action: String) async throws {
        let ready = await eventually {
            // Render the attached SwiftUI hierarchy while awaiting its own
            // deferred focus request. Never call makeFirstResponder here.
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return window.isVisible && window.isKeyWindow &&
                window.firstResponder is DurationInputKeyResponder.Receiver
        }
        XCTAssertTrue(ready, "\(action) the panel must install its duration receiver as first responder")
        let receiver = try XCTUnwrap(window.firstResponder as? DurationInputKeyResponder.Receiver)
        XCTAssertTrue(receiver.window === window)
        XCTAssertTrue(receiver.acceptsFirstResponder)
    }

    private func send(_ characters: String, code: UInt16, to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ))
        window.sendEvent(event)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
