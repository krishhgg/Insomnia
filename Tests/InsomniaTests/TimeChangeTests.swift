import XCTest
@testable import Insomnia

/// The end time countdown has no timer, so a time zone, clock, day or
/// locale change formats it again.
@MainActor
final class TimeChangeTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    /// An end tomorrow reads with its weekday until midnight, then without.
    func testAtMidnightTheEndTimeDropsItsWeekday() async throws {
        let m = h.makeManager()
        m.config.countdownStyle = .endTime
        let calendar = Calendar.autoupdatingCurrent
        let midnight = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: h.clock.now)))
        let endsAt = midnight.addingTimeInterval(3 * 3600)
        await m.start(duration: endsAt.timeIntervalSince(h.clock.now))
        XCTAssertEqual(m.session?.endsAt, endsAt)
        let center = NotificationCenter()
        let observer = TimeChangeObserver(center: center) { m.refreshCountdown() }
        let before = m.countdownText
        XCTAssertEqual(before, SessionMath.formatEndTime(endsAt, now: h.clock.now))

        h.clock.now = midnight.addingTimeInterval(60)
        XCTAssertEqual(m.countdownText, before, "no timer redraws it")
        center.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(m.countdownText, SessionMath.formatEndTime(endsAt, now: h.clock.now))
        XCTAssertNotEqual(m.countdownText, before)
        withExtendedLifetime(observer) {}
    }

    func testEachTimeChangeIsReported() {
        final class Seen { var count = 0 }
        let center = NotificationCenter()
        let seen = Seen()
        let observer = TimeChangeObserver(center: center) { seen.count += 1 }
        for name in TimeChangeObserver.names { center.post(name: name, object: nil) }
        XCTAssertEqual(Set(TimeChangeObserver.names).count, 4)
        XCTAssertEqual(seen.count, 4)
        withExtendedLifetime(observer) {}
    }
}
