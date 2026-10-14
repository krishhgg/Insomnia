import XCTest
@testable import Insomnia

/// The number boxes that replaced the Settings steppers.
final class NumberBoxTests: XCTestCase {
    func testTheBoxKeepsDigitsOnlyUpToTheRangesLength() {
        XCTAssertEqual(NumberBox.digits("4a5%", max: 3), "45")
        XCTAssertEqual(NumberBox.digits("12345", max: 3), "123")
        XCTAssertEqual(NumberBox.digits("-5", max: 3), "5")
        XCTAssertEqual(NumberBox.digits("٣", max: 3), "")
    }

    func testATypedNumberIsPulledIntoTheRange() {
        XCTAssertEqual(NumberBox.parse("40", in: 0...100), 40)
        XCTAssertEqual(NumberBox.parse("250", in: 0...100), 100)
        XCTAssertEqual(NumberBox.parse("5", in: 10...900), 10)
        XCTAssertEqual(NumberBox.parse("007", in: 0...100), 7)
    }

    /// A number past the top keeps its scale: 100 in a 0...95 box is
    /// pulled to 95, not cut to 10, and 1000 in 10...900 to 900, not 100.
    func testANumberPastTheTopIsPulledInNotCut() {
        func committed(_ typed: String, _ range: ClosedRange<Int>) -> Int? {
            NumberBox.parse(NumberBox.digits(typed, max: NumberBox.maxDigits(for: range)), in: range)
        }
        XCTAssertEqual(committed("100", 0...95), 95)
        XCTAssertEqual(committed("1000", 10...900), 900)
        XCTAssertEqual(committed("45", 0...95), 45)
    }

    func testAnEmptyBoxSetsNothing() {
        XCTAssertNil(NumberBox.parse("", in: 0...100))
        XCTAssertNil(NumberBox.parse("%", in: 0...100))
    }
}
