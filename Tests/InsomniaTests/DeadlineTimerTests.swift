import XCTest
@testable import Insomnia

/// The deadline timer is one-shot and runs on the real run loop, while the
/// manager reads its own clock. macOS steps the wall clock back by a few
/// milliseconds now and then, so the timer can run just before the clock
/// reads the deadline. The session must still end.
@MainActor
final class DeadlineTimerTests: XCTestCase {
    /// The real clock, optionally held 0.1 s short of a deadline until
    /// released. It counts the reads it answers held after the real time
    /// has passed the deadline.
    private final class HeldClock: @unchecked Sendable {
        private let lock = NSLock()
        private var deadline: Date?
        private var lateReads = 0

        func hold(shortOf deadline: Date) { lock.withLock { self.deadline = deadline } }
        func release() { lock.withLock { deadline = nil } }
        var heldReadsPastTheDeadline: Int { lock.withLock { lateReads } }
        func now() -> Date {
            lock.withLock {
                let real = Date()
                guard let deadline else { return real }
                if real >= deadline { lateReads += 1 }
                return min(real, deadline.addingTimeInterval(-0.1))
            }
        }
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
    /// clock stays 0.1 s short of the deadline until the timer has fired and
    /// tried again, so the first fire always finds time left and only a
    /// retry can end the session. The held case launches with the lid
    /// closed, so the 1 Hz countdown never starts and only the deadline
    /// timer reads the clock after the reconcile.
    ///
    /// session.json keeps whole seconds, so the deadline is the next whole
    /// second at least half a second away. Both cases hold the clock while
    /// the launch loads the session, so a runner slow enough to reach the
    /// deadline first cannot make the launch find it expired. The plain
    /// case lets go as soon as the reconcile returns.
    private func assertTheSessionEnds(held: Bool) async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let endsAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 1.5).rounded(.down))
        let clock = HeldClock()
        clock.hold(shortOf: endsAt)
        if held { h.clamshell.closed = true }
        try h.store.saveSession(Session(startedAt: endsAt.addingTimeInterval(-60), endsAt: endsAt))
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        try h.store.saveState(journal)
        h.guardFake.sleepDisabled = true

        let m = h.makeManager(clock: { clock.now() })
        await m.reconcile()
        XCTAssertTrue(m.isActive, "the session is live before its deadline (held: \(held))")
        if !held { clock.release() }

        if held {
            // Two held reads past the deadline after the reconcile are a
            // fire and a retry, which the timer makes only after it ran and
            // found time left. Counting from here leaves out the reconcile's
            // own reads if a slow setup reached the deadline. Waiting for
            // them, not for a fixed time, keeps a late first fire on a busy
            // runner from ending the session after the release.
            let before = clock.heldReadsPastTheDeadline
            let retried = await waitUntil(max(endsAt.timeIntervalSinceNow, 0) + 10) { clock.heldReadsPastTheDeadline >= before + 2 }
            XCTAssertTrue(retried, "the timer ran while the clock was behind it and tried again")
            XCTAssertTrue(m.isActive, "the timer found time left, so the session goes on")
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
