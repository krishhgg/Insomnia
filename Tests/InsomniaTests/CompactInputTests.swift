import AppKit
import XCTest
@testable import Insomnia

/// The compact dropdown must edit the same pills as the inline presentation,
/// including focus traversal, bounded digit entry and main's bounce feedback.
final class CompactInputTests: XCTestCase {
    @MainActor
    func testReopeningNativeWindowRestoresFocusWithoutResettingDraft() {
        let compact = CompactMenuModel()
        compact.entry.input = DurationInput(days: 1, minutes: 15)
        compact.entry.focused = .minutes
        compact.setPresented(true)
        let firstFocus = compact.focusRequest
        let firstPresentation = compact.presentationID
        XCTAssertTrue(compact.entry.focusVisible)
        compact.setPresented(true)
        XCTAssertEqual(compact.focusRequest, firstFocus, "Repeated window notifications must not steal focus")
        XCTAssertEqual(compact.presentationID, firstPresentation)
        compact.setPresented(false)
        XCTAssertFalse(compact.entry.focusVisible)
        compact.setPresented(true)
        XCTAssertGreaterThan(compact.focusRequest, firstFocus)
        XCTAssertGreaterThan(compact.presentationID, firstPresentation, "Reopening must discard the old window-size measurement")
        XCTAssertEqual(compact.entry.input, DurationInput(days: 1, minutes: 15))
        XCTAssertEqual(compact.entry.focused, .minutes)
    }

    @MainActor
    private func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        )!
    }

    @MainActor
    func testCompactAndInlinePillsApplyTheSameEditingSequence() {
        _ = NSApplication.shared
        let harness = Harness()
        let controller = StatusItemController(manager: harness.makeManager(), status: PlaceholderStatus(), showSettings: {})
        controller.expand(mode: .start)
        let compact = CompactMenuModel()
        compact.isPresented = true
        defer {
            controller.collapse()
            harness.home.destroy()
        }

        func send(_ event: NSEvent, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(controller.handleKey(event), file: file, line: line)
            XCTAssertTrue(compact.handleKey(
                event, sessionActive: false, phase: .idle, reduceMotion: true,
                onSubmit: { XCTFail("An editing key must not submit", file: file, line: line) },
                onDismiss: { XCTFail("An editing key must not dismiss", file: file, line: line) }
            ), file: file, line: line)
            XCTAssertEqual(compact.entry.input, controller.model.input, file: file, line: line)
            XCTAssertEqual(compact.entry.focused, controller.model.focused, file: file, line: line)
            XCTAssertEqual(compact.entry.rejectBounce, controller.model.rejectBounce, file: file, line: line)
            XCTAssertEqual(compact.entry.focusBounce, controller.model.focusBounce, file: file, line: line)
        }

        send(key("2"))
        send(key("3"))
        XCTAssertEqual(compact.entry.input.hours, 23)
        XCTAssertEqual(compact.entry.focused, .minutes)
        send(key("5"))
        send(key("9"))
        send(key("9"))
        XCTAssertEqual(compact.entry.input.minutes, 59)
        XCTAssertEqual(compact.entry.rejectBounce, 1)

        send(key("h"))
        send(key("\t", code: 48, flags: .shift))
        XCTAssertEqual(compact.entry.focused, .days)
        send(key("3"))
        send(key("1"))
        XCTAssertEqual(compact.entry.input.days, 3)
        XCTAssertEqual(compact.entry.rejectBounce, 2)
        send(key("0"))
        XCTAssertEqual(compact.entry.input.days, 30)
        XCTAssertEqual(compact.entry.focused, .hours)

        send(key("", code: 123))
        send(key("\u{8}", code: 51))
        XCTAssertEqual(compact.entry.input.days, 3)
        send(key("\u{8}", code: 51))
        XCTAssertNil(compact.entry.input.days)
        send(key("", code: 124))
        send(key("", code: 117))
        send(key("", code: 117))
        send(key("", code: 117))
        XCTAssertEqual(compact.entry.focused, .days, "Deleting an empty Hours pill selects Days")
        send(key("\t", code: 48))
        send(key("m"))
        send(key("d"))
        send(key("x"))
        send(key("!"))
        send(key(" "))
        XCTAssertEqual(compact.entry.rejectBounce, 2, "Navigation and stray keys must not count as rejected input")
    }

    @MainActor
    func testHiddenOrUnavailableInputsNeverConsumeOrMutateKeys() {
        let compact = CompactMenuModel()
        compact.entry.input = DurationInput(hours: 2)
        compact.entry.focused = .days
        compact.error = "Keep this failure visible"
        let cases: [(presented: Bool, busy: Bool, active: Bool, editing: Bool, phase: MenuBarModel.Phase)] = [
            (false, false, false, false, .idle),
            (true, true, false, false, .idle),
            (true, false, false, false, .starting),
            (true, false, true, false, .running),
        ]
        for state in cases {
            compact.isPresented = state.presented
            compact.isBusy = state.busy
            compact.isEditing = state.editing
            for event in [key("4"), key("\t", code: 48), key("\r", code: 36), key("", code: 53)] {
                XCTAssertFalse(compact.handleKey(
                    event, sessionActive: state.active, phase: state.phase, reduceMotion: true,
                    onSubmit: { XCTFail("Unavailable input must not submit") },
                    onDismiss: { XCTFail("Unavailable input must not dismiss through the input responder") }
                ))
                XCTAssertEqual(compact.entry.input, DurationInput(hours: 2))
                XCTAssertEqual(compact.entry.focused, .days)
                XCTAssertEqual(compact.entry.rejectBounce, 0)
                XCTAssertEqual(compact.error, "Keep this failure visible")
                XCTAssertEqual(compact.isEditing, state.editing)
            }
        }
    }

    @MainActor
    func testCommandControlAndOptionShortcutsAreNotDurationInput() {
        let compact = CompactMenuModel()
        compact.isPresented = true
        compact.entry.input = DurationInput(minutes: 5)
        let modifiers: [NSEvent.ModifierFlags] = [.command, .control, .option]
        for modifier in modifiers {
            for event in [key("2", flags: modifier), key("\r", code: 36, flags: modifier), key("\t", code: 48, flags: modifier)] {
                XCTAssertFalse(compact.handleKey(
                    event, sessionActive: false, phase: .idle, reduceMotion: true,
                    onSubmit: { XCTFail("A modified shortcut must not submit") },
                    onDismiss: { XCTFail("A modified shortcut must not dismiss") }
                ))
                XCTAssertEqual(compact.entry.input, DurationInput(minutes: 5))
                XCTAssertEqual(compact.entry.focused, .hours)
                XCTAssertEqual(compact.entry.rejectBounce, 0)
            }
        }
    }

    @MainActor
    func testEscapeLeavesExtensionEntryWithoutDiscardingItsValues() {
        let compact = CompactMenuModel()
        compact.isPresented = true
        compact.isEditing = true
        compact.entry.input = DurationInput(hours: 1, minutes: 30)
        compact.entry.focused = .minutes
        XCTAssertTrue(compact.handleKey(
            key("", code: 53), sessionActive: true, phase: .running, reduceMotion: true,
            onSubmit: { XCTFail("Escape must not submit") },
            onDismiss: { XCTFail("Escape from extension entry returns to the countdown") }
        ))
        XCTAssertFalse(compact.isEditing)
        XCTAssertEqual(compact.entry.input, DurationInput(hours: 1, minutes: 30))
        XCTAssertEqual(compact.entry.focused, .minutes)
        XCTAssertTrue(compact.isPresented)
    }

    @MainActor
    func testEscapeDismissesIdleEntryWithoutDiscardingItsValues() {
        let compact = CompactMenuModel()
        compact.isPresented = true
        compact.entry.input = DurationInput(days: 1)
        var dismissals = 0
        XCTAssertTrue(compact.handleKey(
            key("", code: 53), sessionActive: false, phase: .idle, reduceMotion: true,
            onSubmit: { XCTFail("Escape must not submit") },
            onDismiss: { dismissals += 1 }
        ))
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(compact.entry.input, DurationInput(days: 1))
    }

    @MainActor
    func testBothEnterKeysSubmitWithoutChangingTheDuration() {
        let compact = CompactMenuModel()
        compact.isPresented = true
        compact.entry.input = DurationInput(hours: 2)
        var submissions = 0
        let enterCodes: [UInt16] = [36, 76]
        for code in enterCodes {
            XCTAssertTrue(compact.handleKey(
                key("\r", code: code), sessionActive: false, phase: .idle, reduceMotion: true,
                onSubmit: { submissions += 1 },
                onDismiss: { XCTFail("Enter must not dismiss") }
            ))
            XCTAssertEqual(compact.entry.input, DurationInput(hours: 2))
        }
        XCTAssertEqual(submissions, 2)
    }

    @MainActor
    func testEmptyAndExplicitZeroKeepDefaultModeCommitSemantics() {
        let compact = CompactMenuModel()
        for input in [DurationInput(), DurationInput(days: 0, hours: 0, minutes: 0)] {
            compact.entry.input = input
            // Pills treats an empty or zero-only entry as its preset;
            // the same entry cannot extend an existing session by zero.
            XCTAssertEqual(MenuBarModel.commitAction(mode: .start, typed: compact.entry.input.total, defaultPreset: 1800), .run(1800))
            XCTAssertEqual(MenuBarModel.commitAction(mode: .extend, typed: compact.entry.input.total, defaultPreset: 1800), .reject)
        }
        compact.entry.input = DurationInput(minutes: 5)
        XCTAssertEqual(MenuBarModel.commitAction(mode: .start, typed: compact.entry.input.total, defaultPreset: 1800), .run(300))
        XCTAssertEqual(MenuBarModel.commitAction(mode: .extend, typed: compact.entry.input.total, defaultPreset: 1800), .run(300))
    }
}
