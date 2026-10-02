import XCTest
@testable import Insomnia

final class DurationInputTests: XCTestCase {
    // MARK: total / validation

    func testEmptyHasNoTotalAndIsInvalid() {
        let d = DurationInput()
        XCTAssertTrue(d.isEmpty)
        XCTAssertNil(d.total)
        XCTAssertFalse(d.isValid)
    }

    func testAllZeroIsInvalid() {
        let d = DurationInput(days: 0, hours: 0, minutes: 0)
        XCTAssertFalse(d.isEmpty)
        XCTAssertNil(d.total)
        XCTAssertFalse(d.isValid)
    }

    func testTotalSumsFields() {
        XCTAssertEqual(DurationInput(days: 1, hours: 2, minutes: 3).total, 86_400 + 7_200 + 180)
        XCTAssertEqual(DurationInput(hours: 2).total, 7_200)
        XCTAssertEqual(DurationInput(minutes: 30).total, 1_800)
        XCTAssertTrue(DurationInput(minutes: 1).isValid)
    }

    func testCeilings() {
        XCTAssertTrue(DurationInput(days: 30).isValid)
        XCTAssertFalse(DurationInput(days: 31).isValid)
        XCTAssertNil(DurationInput(days: 31).total)
        XCTAssertTrue(DurationInput(hours: 23).isValid)
        XCTAssertFalse(DurationInput(hours: 24).isValid)
        XCTAssertTrue(DurationInput(minutes: 59).isValid)
        XCTAssertFalse(DurationInput(minutes: 60).isValid)
        XCTAssertFalse(DurationInput(hours: 60).isValid(.hours))
        XCTAssertTrue(DurationInput().isValid(.hours))
    }

    // MARK: from(seconds:)

    func testFromSecondsFillsOnlyNonZeroFields() {
        XCTAssertEqual(DurationInput.from(seconds: 30 * 60), DurationInput(minutes: 30))
        XCTAssertEqual(DurationInput.from(seconds: 3600), DurationInput(hours: 1))
        XCTAssertEqual(DurationInput.from(seconds: 12 * 3600), DurationInput(hours: 12))
        XCTAssertEqual(DurationInput.from(seconds: 24 * 3600), DurationInput(days: 1))
        XCTAssertEqual(DurationInput.from(seconds: 3 * 86_400), DurationInput(days: 3))
        XCTAssertEqual(DurationInput.from(seconds: 86_400 + 5_400), DurationInput(days: 1, hours: 1, minutes: 30))
    }

    func testFromSecondsFloorsAndClamps() {
        XCTAssertEqual(DurationInput.from(seconds: 90), DurationInput(minutes: 1))
        XCTAssertEqual(DurationInput.from(seconds: 0), DurationInput())
        XCTAssertEqual(DurationInput.from(seconds: -5), DurationInput())
        XCTAssertEqual(DurationInput.from(seconds: 45 * 86_400), DurationInput(days: 30))
    }

    func testPresetRoundTrips() {
        for p in Config.defaultPresets {
            XCTAssertEqual(DurationInput.from(seconds: p).total, p, "preset \(p)")
        }
    }

    // MARK: digit append

    func testAppendBuildsTwoDigitValues() {
        var d = DurationInput()
        XCTAssertTrue(d.append(digit: 1, to: .hours))
        XCTAssertEqual(d.hours, 1)
        XCTAssertTrue(d.append(digit: 2, to: .hours))
        XCTAssertEqual(d.hours, 12)
        XCTAssertFalse(d.append(digit: 3, to: .hours), "third digit is rejected")
        XCTAssertEqual(d.hours, 12)
        XCTAssertEqual(d.text(for: .hours), "12")
        XCTAssertNil(d.text(for: .days))
    }

    func testAppendRejectsValuesOverCeiling() {
        var d = DurationInput(hours: 2)
        XCTAssertFalse(d.append(digit: 4, to: .hours), "24 hours is out of range")
        XCTAssertEqual(d.hours, 2)
        XCTAssertTrue(d.append(digit: 3, to: .hours))
        XCTAssertEqual(d.hours, 23)

        var m = DurationInput(minutes: 5)
        XCTAssertTrue(m.append(digit: 9, to: .minutes))
        XCTAssertEqual(m.minutes, 59)
        var m6 = DurationInput(minutes: 6)
        XCTAssertFalse(m6.append(digit: 0, to: .minutes))

        var days = DurationInput(days: 3)
        XCTAssertTrue(days.append(digit: 0, to: .days))
        XCTAssertEqual(days.days, 30)
        var d31 = DurationInput(days: 3)
        XCTAssertFalse(d31.append(digit: 1, to: .days))
    }

    func testAppendZeroHandling() {
        var d = DurationInput()
        XCTAssertTrue(d.append(digit: 0, to: .minutes))
        XCTAssertEqual(d.minutes, 0)
        XCTAssertFalse(d.append(digit: 0, to: .minutes), "no leading double zero")
        XCTAssertTrue(d.append(digit: 7, to: .minutes))
        XCTAssertEqual(d.minutes, 7, "0 then 7 reads as 7")
    }

    func testAppendRejectsNonDigits() {
        var d = DurationInput()
        XCTAssertFalse(d.append(digit: 10, to: .hours))
        XCTAssertFalse(d.append(digit: -1, to: .hours))
        XCTAssertTrue(d.isEmpty)
    }

    func testCanAcceptDigit() {
        XCTAssertTrue(DurationInput().canAcceptDigit(in: .hours))
        XCTAssertTrue(DurationInput(hours: 1).canAcceptDigit(in: .hours))
        XCTAssertFalse(DurationInput(hours: 12).canAcceptDigit(in: .hours))
        XCTAssertFalse(DurationInput(hours: 3).canAcceptDigit(in: .hours), "30+ hours impossible")
        XCTAssertFalse(DurationInput(minutes: 6).canAcceptDigit(in: .minutes))
        XCTAssertTrue(DurationInput(days: 3).canAcceptDigit(in: .days))
        XCTAssertFalse(DurationInput(days: 4).canAcceptDigit(in: .days))
    }

    // MARK: backspace

    func testBackspaceRemovesLastDigitThenEmpties() {
        var d = DurationInput(hours: 12)
        XCTAssertTrue(d.backspace(.hours))
        XCTAssertEqual(d.hours, 1)
        XCTAssertTrue(d.backspace(.hours))
        XCTAssertNil(d.hours)
        XCTAssertFalse(d.backspace(.hours), "already empty")
        XCTAssertNil(d.hours)
    }

    func testBackspaceOnZeroEmpties() {
        var d = DurationInput(minutes: 0)
        XCTAssertTrue(d.backspace(.minutes))
        XCTAssertNil(d.minutes)
    }

    func testClear() {
        var d = DurationInput(days: 1, hours: 2, minutes: 3)
        d.clear(.hours)
        XCTAssertEqual(d, DurationInput(days: 1, minutes: 3))
        d.clearAll()
        XCTAssertTrue(d.isEmpty)
    }

    // MARK: fields

    func testFieldOrderWraps() {
        XCTAssertEqual(DurationInput.Field.days.next, .hours)
        XCTAssertEqual(DurationInput.Field.hours.next, .minutes)
        XCTAssertEqual(DurationInput.Field.minutes.next, .days)
        XCTAssertEqual(DurationInput.Field.days.previous, .minutes)
        XCTAssertEqual(DurationInput.Field.hours.previous, .days)
    }

    func testFieldStrings() {
        XCTAssertEqual(DurationInput.Field.days.placeholder, "Days")
        XCTAssertEqual(DurationInput.Field.days.help, "Up to 30 days")
        XCTAssertEqual(DurationInput.Field.hours.help, "0\u{2013}23")
        XCTAssertEqual(DurationInput.Field.minutes.help, "0\u{2013}59")
    }

    // MARK: DurationParser (settings presets)

    func testParserUnits() {
        XCTAssertEqual(DurationParser.seconds(from: "30m"), 1_800)
        XCTAssertEqual(DurationParser.seconds(from: "2h"), 7_200)
        XCTAssertEqual(DurationParser.seconds(from: "3d"), 3 * 86_400)
        XCTAssertEqual(DurationParser.seconds(from: "1h30m"), 5_400)
        XCTAssertEqual(DurationParser.seconds(from: " 1d 2h 3m "), 86_400 + 7_200 + 180)
        XCTAssertEqual(DurationParser.seconds(from: "45"), 45 * 60, "bare numbers are minutes")
        XCTAssertEqual(DurationParser.seconds(from: "2H"), 7_200)
    }

    func testParserRejectsGarbage() {
        XCTAssertNil(DurationParser.seconds(from: ""))
        XCTAssertNil(DurationParser.seconds(from: "abc"))
        XCTAssertNil(DurationParser.seconds(from: "0m"))
        XCTAssertNil(DurationParser.seconds(from: "0"))
        XCTAssertNil(DurationParser.seconds(from: "2x"))
        XCTAssertNil(DurationParser.seconds(from: "h"))
        XCTAssertNil(DurationParser.seconds(from: "2h5"))
    }

    func testParserRejectsOverflowInsteadOfTrapping() {
        let huge = String(Int.max)
        XCTAssertNil(DurationParser.seconds(from: huge))          // bare minutes × 60
        XCTAssertNil(DurationParser.seconds(from: huge + "d"))    // unit multiply
        XCTAssertNil(DurationParser.seconds(from: "9223372036854775d 1d")) // addition
        XCTAssertNil(DurationParser.seconds(from: "99999999999999999999h")) // Int(...) fails
        XCTAssertEqual(DurationParser.seconds(from: "1d 2h"), 93_600)
    }
}
