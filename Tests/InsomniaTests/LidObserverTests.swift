import XCTest
@testable import Insomnia

/// The debounce and `whenSettled`, driven with a fake registry read and a
/// short debounce. `start()` is never called, so nothing registers with
/// IOKit; `handleInterest()` stands in for the kernel's message. No test
/// takes elapsed time as proof that a callback ran: a delivery is polled
/// for, and "nothing was delivered" is checked only once a later timer of
/// the same interval has fired (`pastTheDebounce`).
@MainActor
final class LidObserverTests: XCTestCase {
    private let debounce: TimeInterval = 0.05
    private var reading: Bool? = false
    private var events: [String] = []

    private func makeObserver() -> LidObserver {
        let observer = LidObserver(read: { [unowned self] in self.reading }, debounce: debounce)
        observer.onChange = { [unowned self] closed in self.events.append("change \(closed)") }
        return observer
    }

    private func waiter(_ name: String = "settled") -> (Bool) -> Void {
        { [unowned self] delivered in self.events.append("\(name) \(delivered)") }
    }

    /// Polls until `condition` holds, for at most 5 s.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    /// Returns once a timer of the observer's interval, scheduled now, has
    /// fired and hopped to the main actor. A debounce timer the observer
    /// scheduled earlier fires first and its hop queues first, so whatever
    /// it was going to deliver has been delivered by then. Bounded by the
    /// expectation's timeout.
    private func pastTheDebounce() async {
        let fired = expectation(description: "a timer of the debounce interval fired")
        let timer = Timer(timeInterval: debounce, repeats: false) { _ in
            Task { @MainActor in fired.fulfill() }
        }
        RunLoop.main.add(timer, forMode: .common)
        await fulfillment(of: [fired], timeout: 5)
    }

    func testWaiterRunsAtOnceWithNoChangePending() {
        let observer = makeObserver()

        observer.whenSettled(waiter())

        XCTAssertEqual(events, ["settled false"])
    }

    func testWaiterRunsAfterTheDeliveryOfAPendingChange() async {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()

        observer.whenSettled(waiter())

        XCTAssertEqual(events, [], "ran before the debounce settled the change")
        await waitUntil("the change was never delivered") { events.count >= 2 }
        XCTAssertEqual(events, ["change true", "settled true"])
    }

    func testWaiterRunsWhenThePendingChangeFlapsBack() async {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()
        observer.whenSettled(waiter())

        reading = false
        observer.handleInterest()

        XCTAssertEqual(events, ["settled false"])
        await pastTheDebounce()
        XCTAssertEqual(events, ["settled false"], "a dropped change was delivered")
    }

    /// No message for the return trip: the debounce finds the lid back
    /// where it was and drops the change.
    func testWaiterRunsWhenTheChangeHasFlappedByTheDeadline() async {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()
        observer.whenSettled(waiter())

        reading = false
        await waitUntil("the debounce never settled") { !events.isEmpty }

        XCTAssertEqual(events, ["settled false"])
    }

    func testNewerWaiterReplacesTheOlder() async {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()

        observer.whenSettled(waiter("first"))
        observer.whenSettled(waiter("second"))
        await waitUntil("the change was never delivered") { events.count >= 2 }

        XCTAssertEqual(events, ["change true", "second true"])
    }

    /// A change after the stop, as after a restart, must not run a
    /// waiter left from before it.
    func testStopDropsTheWaiter() async {
        let observer = makeObserver()
        reading = true
        observer.handleInterest()
        observer.whenSettled(waiter())

        observer.stop()
        await pastTheDebounce()
        XCTAssertEqual(events, [])
        observer.handleInterest()
        await waitUntil("the change after the stop was never delivered") { !events.isEmpty }

        XCTAssertEqual(events, ["change true"])
    }
}
