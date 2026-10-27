import AppKit
import XCTest
@testable import Insomnia

/// On macOS 27 a click on the status item reaches the app's global mouse
/// monitor as well, so it would collapse the open pills before a pill could
/// take the click. Only a click away from the item is a click away.
final class GlobalClickFilterTests: XCTestCase {
    private let item = NSRect(x: 982, y: 870, width: 242, height: 30)

    @MainActor
    func testAClickOnTheItemItselfIsNotAClickAway() {
        XCTAssertTrue(StatusItemController.isClickOnItem(at: NSPoint(x: 1103, y: 885), itemFrame: item))
        XCTAssertTrue(StatusItemController.isClickOnItem(at: NSPoint(x: 983, y: 871), itemFrame: item))
    }

    @MainActor
    func testAClickBesideOrBelowTheItemIsAClickAway() {
        XCTAssertFalse(StatusItemController.isClickOnItem(at: NSPoint(x: 900, y: 885), itemFrame: item), "another menu bar item")
        XCTAssertFalse(StatusItemController.isClickOnItem(at: NSPoint(x: 1103, y: 500), itemFrame: item), "the desktop")
    }

    @MainActor
    func testAnItemWithNoWindowCountsEverythingAsAClickAway() {
        XCTAssertFalse(StatusItemController.isClickOnItem(at: NSPoint(x: 1103, y: 885), itemFrame: nil))
    }
}
