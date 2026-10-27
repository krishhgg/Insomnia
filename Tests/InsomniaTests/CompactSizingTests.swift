import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

/// Measure the actual compact content without opening a window or using
/// system integrations. Native window animation is checked separately.
final class CompactSizingTests: XCTestCase {
    @MainActor
    private struct Rig {
        let harness: Harness
        let manager: SessionManager
        let menuBar = MenuBarModel()
        let compact = CompactMenuModel()

        init() {
            _ = NSApplication.shared
            harness = Harness()
            manager = harness.makeManager()
            manager.config.compactMode = true
        }

        func measuredSize(file: StaticString = #filePath, line: UInt = #line) -> NSSize {
            let content = CompactMenuView(
                model: compact, menuBar: menuBar, manager: manager,
                onSubmit: {}, onEnd: {}, onDismiss: {}
            )
            .transaction { $0.disablesAnimations = true }
            let host = NSHostingView(rootView: content)
            let size = host.fittingSize
            XCTAssertGreaterThan(size.width, 0, file: file, line: line)
            XCTAssertGreaterThan(size.height, 0, file: file, line: line)
            return size
        }

        func startTimer() async {
            await manager.start(duration: 3600)
            menuBar.phase = .running
            XCTAssertTrue(manager.isActive)
        }
    }

    @MainActor
    func testTimerFitsMoreNarrowlyThanDurationEntry() async {
        let rig = Rig()
        defer { rig.harness.home.destroy() }
        let inputs = rig.measuredSize()

        await rig.startTimer()
        let timer = rig.measuredSize()

        XCTAssertLessThan(timer.width, inputs.width,
                          "Hidden duration controls must not reserve the timer's width")
        XCTAssertEqual(timer.height, inputs.height, accuracy: 1,
                       "Switching a single row should retain its comfortable vertical padding")
    }

    @MainActor
    func testEditingExpandsAndEscapeRestoresTimerWithoutDiscardingDraft() async {
        let rig = Rig()
        defer { rig.harness.home.destroy() }
        await rig.startTimer()
        let timer = rig.measuredSize()
        let draft = DurationInput(hours: 2, minutes: 15)
        rig.compact.entry.input = draft
        rig.compact.isEditing = true
        let editing = rig.measuredSize()
        XCTAssertGreaterThan(editing.width, timer.width)

        rig.compact.setPresented(true)
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )!
        XCTAssertTrue(rig.compact.handleKey(
            escape, sessionActive: rig.manager.isActive, phase: rig.menuBar.phase,
            reduceMotion: true, onSubmit: { XCTFail("Escape must not submit") },
            onDismiss: { XCTFail("Escape while editing should return to the timer") }
        ))

        let restoredTimer = rig.measuredSize()
        XCTAssertLessThan(restoredTimer.width, editing.width)
        XCTAssertEqual(restoredTimer.width, timer.width, accuracy: 1)
        XCTAssertEqual(rig.compact.entry.input, draft)
        XCTAssertFalse(rig.compact.isEditing)
    }

    @MainActor
    func testEndingSessionRestoresDurationEntrySize() async {
        let rig = Rig()
        defer { rig.harness.home.destroy() }
        let inputs = rig.measuredSize()
        await rig.startTimer()
        let timer = rig.measuredSize()

        await rig.manager.end(reason: .user)
        rig.menuBar.phase = .idle
        XCTAssertFalse(rig.manager.isActive)
        let restoredInputs = rig.measuredSize()

        XCTAssertGreaterThan(restoredInputs.width, timer.width)
        XCTAssertEqual(restoredInputs.width, inputs.width, accuracy: 1)
        XCTAssertEqual(restoredInputs.height, inputs.height, accuracy: 1)
    }

    @MainActor
    func testWrappedErrorAddsHeightAndClearingRestoresTimerSize() async {
        let rig = Rig()
        defer { rig.harness.home.destroy() }
        await rig.startTimer()
        let timer = rig.measuredSize()

        rig.compact.error = "The session could not be updated because a required operation failed. Your existing timer is still running."
        let withError = rig.measuredSize()
        XCTAssertGreaterThan(withError.height, timer.height,
                             "An error should wrap and grow the content instead of being clipped")
        XCTAssertGreaterThanOrEqual(withError.width, timer.width)

        rig.compact.error = nil
        let cleared = rig.measuredSize()
        XCTAssertEqual(cleared.width, timer.width, accuracy: 1)
        XCTAssertEqual(cleared.height, timer.height, accuracy: 1)
    }
}
