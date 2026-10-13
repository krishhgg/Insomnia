import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

/// Compact mode must not change the original menu bar's insets or the
/// fixed duration slots shared by both presentations.
final class MenuBarSpacingTests: XCTestCase {
    @MainActor
    private func measuredRoot(_ model: MenuBarModel, manager: SessionManager) -> NSSize {
        let root = StatusRootView(
            model: model, manager: manager,
            onTapIcon: {}, onTapPill: { _ in }, onTapCountdown: {},
            onHoldEnd: {}, onWidthChange: { _ in }
        )
        return StatusItemController.makeHostingView(root).fittingSize
    }

    @MainActor
    func testIdleItemKeepsMainIconInsets() {
        _ = NSApplication.shared
        let harness = Harness()
        defer { harness.home.destroy() }
        let size = measuredRoot(MenuBarModel(), manager: harness.makeManager())
        XCTAssertEqual(size.width, 32, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(size.height, 20)
    }

    @MainActor
    func testExpandedItemKeepsMainSpacingAroundTheSharedDurationRow() {
        _ = NSApplication.shared
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        let model = MenuBarModel()
        model.phase = .entering(.start)
        model.slotsPresent = true
        model.visiblePills = 3
        let row = HStack(spacing: DurationPillsView.spacing) {
            DurationPillsView(model: model, reduceMotion: true, animateDisclosure: false, onTap: { _ in })
        }
        let rowWidth = NSHostingView(rootView: row).fittingSize.width
        let expanded = measuredRoot(model, manager: manager)
        // Main's 20-point eye, 7-point gap, and 6/8-point outside insets.
        XCTAssertEqual(expanded.width - rowWidth, 41, accuracy: 0.001)

        model.input = DurationInput(days: 30, hours: 23, minutes: 59)
        XCTAssertEqual(measuredRoot(model, manager: manager).width, expanded.width, accuracy: 0.001,
                       "Typing fills the original fixed slots without shifting the menu bar")
    }
}
