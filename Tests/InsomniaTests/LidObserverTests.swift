import XCTest
@testable import Insomnia

/// The debounce and `whenSettled`, driven with a fake registry read and a
/// short debounce. `start()` is never called, so nothing registers with
/// IOKit; `handleInterest()` stands in for the kernel's message.
@MainActor
final class LidObserverTests: XCTestCase {
    private var reading: Bool? = false
    private var events: [String] = []

    private func makeObserver() -> LidObserver {
        let observer = LidObserver(read: { [unowned self] in self.reading }, debounce: 0.05)
        observer.onChange = { [unowned self] closed in self.events.append("change \(closed)") }
        return observer
    }

    private func waiter(_ name: String = "settled") -> (Bool) -> Void {
        { [unowned self] delivered in self.events.append("\(name) \(delivered)") }
    }

    private func pastTheDebounce() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func testWaiterRunsAtOnceWithNoChangePending() {
        let observer = makeObserver()

        observer.whenSettled(waiter())

        XCTAssertEqual(events, ["settled false"])
    }

    func testWaiterRunsAfterTheDeliveryOfAPendingChange() async throws {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()

        observer.whenSettled(waiter())

        XCTAssertEqual(events, [], "ran before the debounce settled the change")
        try await pastTheDebounce()
        XCTAssertEqual(events, ["change true", "settled true"])
    }

    func testWaiterRunsWhenThePendingChangeFlapsBack() async throws {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()
        observer.whenSettled(waiter())

        reading = false
        observer.handleInterest()

        XCTAssertEqual(events, ["settled false"])
        try await pastTheDebounce()
        XCTAssertEqual(events, ["settled false"], "a dropped change was delivered")
    }

    /// No message for the return trip: the debounce finds the lid back
    /// where it was and drops the change.
    func testWaiterRunsWhenTheChangeHasFlappedByTheDeadline() async throws {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()
        observer.whenSettled(waiter())

        reading = false
        try await pastTheDebounce()

        XCTAssertEqual(events, ["settled false"])
    }

    func testNewerWaiterReplacesTheOlder() async throws {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()

        observer.whenSettled(waiter("first"))
        observer.whenSettled(waiter("second"))
        try await pastTheDebounce()

        XCTAssertEqual(events, ["change true", "second true"])
    }

    /// A change after the stop, as after a restart, must not run a
    /// waiter left from before it.
    func testStopDropsTheWaiter() async throws {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()
        observer.whenSettled(waiter())

        observer.stop()
        try await pastTheDebounce()
        XCTAssertEqual(events, [])
        observer.handleInterest()
        try await pastTheDebounce()

        XCTAssertEqual(events, ["change true"])
    }
}
