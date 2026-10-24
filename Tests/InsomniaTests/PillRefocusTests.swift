import AppKit
import XCTest
@testable import Insomnia

/// On macOS 27 a press on the status item takes key status from the catcher
/// panel while the button is still down. The pills wait the press out, and
/// the app focus goes back to stays the one the user was in.
final class PillRefocusTests: XCTestCase {
    private let grace = RefocusWait.grace
    /// Clear of floating point rounding at the edge of the grace.
    private let margin = 0.001

    func testThePillsWaitWhileTheButtonIsDownAndCloseAfterTheGrace() {
        var wait = RefocusWait()
        XCTAssertEqual(wait.step(buttonDown: true, catcherIsKey: false, now: 0), .wait)
        XCTAssertEqual(wait.step(buttonDown: true, catcherIsKey: false, now: 5), .wait, "a long press is waited out")
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 5), .wait)
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 5 + grace - margin), .wait)
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 5 + grace + margin), .collapse)
    }

    func testAPillThatTakesFocusBackStopsTheWait() {
        var wait = RefocusWait()
        XCTAssertEqual(wait.step(buttonDown: true, catcherIsKey: false, now: 0), .wait)
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 0.1), .wait)
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: true, now: 0.12), .refocused)
    }

    /// A second press inside the grace of the first release, held past where
    /// that grace would end, must not close the pills under it.
    func testASecondPressRestartsTheGrace() {
        var wait = RefocusWait()
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 0), .wait)
        XCTAssertEqual(wait.step(buttonDown: true, catcherIsKey: false, now: grace / 2), .wait)
        XCTAssertEqual(wait.step(buttonDown: true, catcherIsKey: false, now: grace + margin), .wait, "the first grace is over")
        XCTAssertEqual(wait.step(buttonDown: true, catcherIsKey: false, now: 1), .wait)
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 1), .wait)
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 1 + grace - margin), .wait)
        XCTAssertEqual(wait.step(buttonDown: false, catcherIsKey: false, now: 1 + grace + margin), .collapse)
    }

    @MainActor
    func testTheReturnTargetIsTheAppInFrontWhenThePillsFirstTookFocus() {
        _ = NSApplication.shared
        let others = NSWorkspace.shared.runningApplications.filter { $0 != .current }
        guard others.count >= 2 else { return XCTFail("needs two other running apps, found \(others.count)") }
        let editor = others[0]
        let finder = others[1]

        let panel = KeyCatcherPanel()
        panel.rememberReturnTarget(front: editor)
        panel.rememberReturnTarget(front: finder)
        XCTAssertEqual(panel.previousApplication, editor, "a pill click's refocus keeps the first app")

        let fromInsomnia = KeyCatcherPanel()
        fromInsomnia.rememberReturnTarget(front: .current)
        fromInsomnia.rememberReturnTarget(front: finder)
        XCTAssertNil(fromInsomnia.previousApplication, "opened from Insomnia, there is no app to return to")
    }
}
