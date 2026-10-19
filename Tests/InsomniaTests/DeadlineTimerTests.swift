import XCTest
@testable import Insomnia

/// The deadline timer is one-shot and runs on the real run loop, while the
/// manager reads its own clock. macOS steps the wall clock back by a few
/// milliseconds now and then, so the timer can run just before the clock
/// reads the deadline. The session must still end.
@MainActor
final class DeadlineTimerTests: XCTestCase {
    /// The real clock, optionally held 0.1 s short of a time until released.
    private final class HeldClock: @unchecked Sendable {
        private let lock = NSLock()
        private var heldAt: Date?

        func hold(at date: Date) { lock.withLock { heldAt = date } }
        func release() { lock.withLock { heldAt = nil } }
        func now() -> Date { lock.withLock { min(Date(), heldAt ?? .distantFuture) } }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A live session loaded the way a launch loads it. With `held`, the
    /// clock stays 0.1 s short of the deadline until the timer has fired
    /// (its tolerance is 1 s), so the first fire always finds time left and
    /// only a retry can end the session.
    ///
    /// session.json keeps whole seconds, so the deadline is the next whole
    /// second at least half a second away.
    private func assertTheSessionEnds(held: Bool) async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let endsAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 1.5).rounded(.down))
        let clock = HeldClock()
        if held { clock.hold(at: endsAt.addingTimeInterval(-0.1)) }
        try h.store.saveSession(Session(startedAt: endsAt.addingTimeInterval(-60), endsAt: endsAt))
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        try h.store.saveState(journal)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager(clock: { clock.now() })
        await m.reconcile()
        XCTAssertTrue(m.isActive, "the session is live before its deadline (held: \(held))")

        if held {
            _ = await waitUntil(endsAt.timeIntervalSinceNow + 1.3) { false }
            XCTAssertTrue(m.isActive, "the timer fired and found time left, so the session goes on")
            clock.release()
        }

        // The end clears `session` first and restores sleep after, so wait
        // for its last step, the notification.
        let ended = await waitUntil(5) { h.notifier.posts.contains { $0.title == "Session ended" } }
        XCTAssertTrue(ended, "the timer ended the session (held: \(held))")
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled, "sleep is back (held: \(held))")
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        XCTAssertNil(try h.store.loadSession(), "session.json is gone (held: \(held))")
    }

    func testTheTimerEndsTheSessionWhenTheClockAgreesWithIt() async throws {
        try await assertTheSessionEnds(held: false)
    }

    func testTheTimerEndsTheSessionWhenItRunsBeforeTheClockReachesTheDeadline() async throws {
        try await assertTheSessionEnds(held: true)
    }
}
