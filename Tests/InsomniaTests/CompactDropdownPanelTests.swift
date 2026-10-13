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
}
