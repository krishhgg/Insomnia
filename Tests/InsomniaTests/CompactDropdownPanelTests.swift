import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

@MainActor
final class CompactDropdownPanelTests: XCTestCase {
    func testPanelAlignsWithItsButtonAndKeepsLeftAndTopEdgesDuringResize() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: 900, y: 900, width: 24, height: 24)
        let inputs = CompactDropdownController.frame(
            size: NSSize(width: 220, height: 44), anchor: anchor, visibleFrame: screen
        )
        let timer = CompactDropdownController.frame(
            size: NSSize(width: 110, height: 44), anchor: anchor, visibleFrame: screen
        )
        let error = CompactDropdownController.frame(
            size: NSSize(width: 220, height: 94), anchor: anchor, visibleFrame: screen
        )
        XCTAssertEqual(inputs.minX, anchor.minX)
        XCTAssertEqual(timer.minX, inputs.minX)
        XCTAssertEqual(error.minX, inputs.minX)
        XCTAssertEqual(inputs.maxY, anchor.minY - 2)
        XCTAssertEqual(timer.maxY, inputs.maxY)
        XCTAssertEqual(error.maxY, inputs.maxY)
    }

    func testPanelClampsToBothEdgesOnDisplayWithNegativeOrigin() {
        let screen = NSRect(x: -1920, y: -200, width: 1920, height: 1000)
        for x: CGFloat in [-1918, -8] {
            let result = CompactDropdownController.frame(
                size: NSSize(width: 240, height: 44),
                anchor: NSRect(x: x, y: 800, width: 20, height: 24), visibleFrame: screen
            )
            XCTAssertGreaterThanOrEqual(result.minX, screen.minX + 6)
            XCTAssertLessThanOrEqual(result.maxX, screen.maxX - 6)
            XCTAssertEqual(result.maxY, 798)
        }
    }

    func testOversizedContentStaysWithinDisplayBounds() {
        let screen = NSRect(x: 1200, y: 0, width: 800, height: 500)
        let frame = CompactDropdownController.frame(
            size: NSSize(width: 1000, height: 1000),
            anchor: NSRect(x: 1950, y: 500, width: 24, height: 24), visibleFrame: screen
        )
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.width, screen.width - 12)
        XCTAssertEqual(frame.height, screen.height - 12)
    }

    func testOutsideClickExcludesTheIconSoToggleCannotReopenThePanel() {
        let panel = NSRect(x: 900, y: 700, width: 220, height: 44)
        let anchor = NSRect(x: 996, y: 748, width: 28, height: 24)
        XCTAssertFalse(CompactDropdownController.shouldDismiss(
            at: NSPoint(x: 920, y: 720), panel: panel, anchor: anchor
        ))
        XCTAssertFalse(CompactDropdownController.shouldDismiss(
            at: NSPoint(x: 1010, y: 760), panel: panel, anchor: anchor
        ))
        XCTAssertTrue(CompactDropdownController.shouldDismiss(
            at: NSPoint(x: 850, y: 760), panel: panel, anchor: anchor
        ))
        XCTAssertTrue(CompactDropdownController.shouldDismiss(
            at: NSPoint(x: 1010, y: 760), panel: panel, anchor: nil
        ))
    }

    func testContainerUsesNativeMaterialAndDoesNotOwnAnotherStatusItem() throws {
        _ = NSApplication.shared
        var dismissals = 0
        let controller = CompactDropdownController(content: AnyView(Text("Timer"))) { dismissals += 1 }
        XCTAssertFalse(controller.isShown)
        XCTAssertFalse(controller.window.isVisible)
        XCTAssertTrue(controller.window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(controller.window.styleMask.contains(.titled))
        XCTAssertTrue(controller.window.canBecomeKey)
        XCTAssertFalse(controller.window.canBecomeMain)
        XCTAssertTrue(controller.window.hasShadow)
        let material = try XCTUnwrap(controller.window.contentView as? NSVisualEffectView)
        XCTAssertEqual(material.material, .popover)
        XCTAssertEqual(material.blendingMode, .behindWindow)
        controller.close()
        XCTAssertEqual(dismissals, 0, "Closing an already hidden panel must not change presentation state")
    }

    /// A key panel in an app that is not active can leave the digits going
    /// to the app in front, which #143 found for the Pills. The panel
    /// activates Insomnia when it opens and gives focus back to the app the
    /// user was in when it closes, unless focus has gone somewhere else.
    func testThePanelTakesFocusAndGivesItBackToTheAppTheUserWasIn() throws {
        _ = NSApplication.shared
        let editor = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current })
        let recorder = FocusRecorder(front: editor)
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 40, height: 24),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
        anchorWindow.contentView = anchor
        let controller = CompactDropdownController(content: AnyView(Text("Timer")), focus: recorder.focus) {}
        defer { controller.close(returnFocus: false) }

        // Escape or a second click on the eye.
        controller.show(relativeTo: anchor)
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(recorder.activations, 1, "opening activates Insomnia")
        XCTAssertEqual(controller.previousApplication, editor)
        controller.close()
        XCTAssertEqual(recorder.yields, [editor], "closing gives focus back")

        // Opened while Insomnia was in front: there is no app to return to.
        recorder.front = .current
        controller.show(relativeTo: anchor)
        XCTAssertNil(controller.previousApplication)
        controller.close()
        XCTAssertEqual(recorder.yields, [editor])
        recorder.front = editor

        // A window of this app took key, such as Settings: focus stays there.
        controller.show(relativeTo: anchor)
        recorder.keyWindow = true
        controller.close()
        XCTAssertEqual(recorder.yields, [editor])
        recorder.keyWindow = false

        // Another app is already in front: nothing to give back.
        controller.show(relativeTo: anchor)
        recorder.active = false
        controller.close()
        XCTAssertEqual(recorder.yields, [editor])
        recorder.active = true

        // Switching apps closes the panel and does not take focus back.
        controller.show(relativeTo: anchor)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: controller.window))
        XCTAssertFalse(controller.isShown)
        controller.returnFocus()
        XCTAssertEqual(recorder.yields, [editor])

        // The right-click menu closes the panel without moving focus, and
        // returns it after the menu if nothing else took it.
        controller.show(relativeTo: anchor)
        controller.close(returnFocus: false)
        XCTAssertEqual(recorder.yields, [editor])
        controller.returnFocus()
        XCTAssertEqual(recorder.yields, [editor, editor])
        XCTAssertEqual(recorder.activations, 6)
    }
}

/// Stands in for the app activation calls, so a test run never changes the
/// app in front on the Mac.
@MainActor
private final class FocusRecorder {
    var front: NSRunningApplication?
    var active = true
    var keyWindow = false
    private(set) var activations = 0
    private(set) var yields: [NSRunningApplication] = []

    init(front: NSRunningApplication?) { self.front = front }

    var focus: CompactDropdownController.AppFocus {
        CompactDropdownController.AppFocus(
            frontmost: { [unowned self] in front },
            isActive: { [unowned self] in active },
            hasKeyWindow: { [unowned self] in keyWindow },
            activate: { [unowned self] in activations += 1 },
            yield: { [unowned self] app in yields.append(app) }
        )
    }
}
