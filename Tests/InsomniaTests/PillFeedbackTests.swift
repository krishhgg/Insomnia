import AppKit
import XCTest
@testable import Insomnia

/// Keep main's focus and rejection animation triggers while sharing the
/// same duration input model with compact mode.
final class PillFeedbackTests: XCTestCase {
    @MainActor
    private struct Rig {
        let h: Harness
        let controller: StatusItemController

        init(mode: MenuBarModel.Mode = .start) {
            _ = NSApplication.shared
            h = Harness()
            controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})
            controller.expand(mode: mode)
        }

        var model: MenuBarModel { controller.model }

        func cleanup() {
            controller.collapse()
            h.home.destroy()
        }

        func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            )!
            return controller.handleKey(event)
        }
    }

    @MainActor
    func testSwitchingFieldsRetainsMainFocusBounceTrigger() {
        let rig = Rig()
        defer { rig.cleanup() }

        rig.controller.focus(.days)
        XCTAssertEqual(rig.model.focused, .days)
        rig.controller.focus(.hours)
        XCTAssertEqual(rig.model.focused, .hours)
        rig.controller.focus(.minutes)
        XCTAssertEqual(rig.model.focused, .minutes)
        rig.controller.focus(.days)
        XCTAssertEqual(rig.model.focused, .days)
        XCTAssertEqual(rig.model.focusBounce, 4)
        XCTAssertTrue(rig.model.focusVisible)
        XCTAssertEqual(rig.model.rejectBounce, 0)
    }

    @MainActor
    func testClickingTheCurrentFieldRetainsMainBounceTrigger() {
        let rig = Rig()
        defer { rig.cleanup() }

        rig.controller.focus(.hours)
        rig.controller.focus(.hours)

        XCTAssertEqual(rig.model.focused, .hours)
        XCTAssertEqual(rig.model.focusBounce, 2)
        XCTAssertEqual(rig.model.rejectBounce, 0)
        XCTAssertTrue(rig.model.focusVisible)
    }

    @MainActor
    func testRejectedCommitsRetainMainGlobalRejectionTrigger() {
        let rig = Rig(mode: .extend)
        defer { rig.cleanup() }
        rig.controller.focus(.hours)

        rig.controller.commit()
        XCTAssertEqual(rig.model.rejectBounce, 1)
        let rejection = rig.model.rejectBounce
        rig.controller.focus(.days)
        XCTAssertEqual(rig.model.rejectBounce, rejection, "Moving focus does not reset main's rejection counter")
        rig.controller.focus(.hours)
        XCTAssertEqual(rig.model.rejectBounce, rejection, "Selecting a field does not count as rejected input")

        rig.controller.focus(.minutes)
        rig.controller.commit()
        XCTAssertEqual(rig.model.rejectBounce, 2)
    }

    @MainActor
    func testAutoAdvanceAndRejectedDigitsRetainMainFeedback() {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.controller.focus(.hours)

        XCTAssertTrue(rig.key("2"))
        XCTAssertEqual(rig.model.focused, .hours)
        XCTAssertTrue(rig.key("3"))
        XCTAssertEqual(rig.model.input.hours, 23)
        XCTAssertEqual(rig.model.focused, .minutes)
        XCTAssertEqual(rig.model.focusBounce, 2)

        XCTAssertTrue(rig.key("5"))
        XCTAssertTrue(rig.key("9"))
        XCTAssertTrue(rig.key("9"))
        XCTAssertEqual(rig.model.input.minutes, 59)
        XCTAssertEqual(rig.model.rejectBounce, 1)
        rig.controller.focus(.hours)
        XCTAssertEqual(rig.model.rejectBounce, 1)
    }

    @MainActor
    func testBackspaceFromAnEmptyFieldSelectsThePreviousField() {
        let rig = Rig()
        defer { rig.cleanup() }
        rig.controller.focus(.minutes)

        XCTAssertTrue(rig.key("\u{8}", code: 51))
        XCTAssertEqual(rig.model.focused, .hours)
        XCTAssertTrue(rig.key("4"))
        // Four cannot be followed by another digit in Hours, so it advances.
        XCTAssertEqual(rig.model.focused, .minutes)
        rig.controller.focus(.hours)
        XCTAssertTrue(rig.key("\u{8}", code: 51))
        XCTAssertNil(rig.model.input.hours)
        XCTAssertEqual(rig.model.focused, .hours)
        XCTAssertEqual(rig.model.focusBounce, 4)
        XCTAssertEqual(rig.model.rejectBounce, 0)
    }

    @MainActor
    func testKeyboardTraversalSelectsTheDestination() {
        let rig = Rig()
        defer { rig.cleanup() }

        XCTAssertTrue(rig.key("\t", code: 48))
        XCTAssertEqual(rig.model.focused, .minutes)
        XCTAssertTrue(rig.key("\t", code: 48, flags: .shift))
        XCTAssertEqual(rig.model.focused, .hours)
        XCTAssertTrue(rig.key("", code: 123))
        XCTAssertEqual(rig.model.focused, .days)
        XCTAssertEqual(rig.model.focusBounce, 3)
        XCTAssertTrue(rig.model.focusVisible)
        XCTAssertEqual(rig.model.rejectBounce, 0)
    }
}
