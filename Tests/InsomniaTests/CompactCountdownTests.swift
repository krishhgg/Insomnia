import XCTest
@testable import Insomnia

final class CompactCountdownTests: XCTestCase {
    func testFourHourSessionKeepsItsFirstMinuteAndThenCountsDown() {
        XCTAssertEqual(CompactCountdown.text("4:00:00"), "4:00")
        XCTAssertEqual(CompactCountdown.text("3:59:59"), "4:00")
        XCTAssertEqual(CompactCountdown.text("3:59:00"), "3:59")
    }

    func testShortSessionsUseHoursAndMinutesRatherThanMinutesAndSeconds() {
        XCTAssertEqual(CompactCountdown.text("30:00"), "0:30")
        XCTAssertEqual(CompactCountdown.text("90:00"), "1:30")
        XCTAssertEqual(CompactCountdown.text("00:09"), "0:01")
        XCTAssertEqual(CompactCountdown.text("00:00"), "0:00")
    }

    func testDayRolloverAndPendingDurationsUseTheSameFormat() {
        XCTAssertEqual(CompactCountdown.text("1d 23:59:59"), "2d 0:00")
        XCTAssertEqual(CompactCountdown.text("1d 2:30:00"), "1d 2:30")
        XCTAssertEqual(CompactCountdown.format(14400), "4:00")
        XCTAssertEqual(CompactCountdown.format(-1), "0:00")
    }

    func testPendingLabelsAndMalformedInputRemainUnchanged() {
        for text in ["", "Starting…", "1:bad:30", "1::30", "-2:00", "999999999999999999999:00"] {
            XCTAssertEqual(CompactCountdown.text(text), text)
        }
    }

    @MainActor
    func testCursorRegionNeverInterceptsButtonInput() {
        let view = HandCursorView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)))
        view.cursorEnabled = false
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20)))
    }
}
