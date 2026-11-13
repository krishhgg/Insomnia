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
    private var reading: LidReading? = .open
    private var events: [String] = []
    /// How many times the observer has read the lid.
    private var reads = 0
    /// `reads` at each delivered change.
    private var readsAtChange: [Int] = []

    private func makeObserver() -> LidObserver {
        let observer = LidObserver(read: { [unowned self] in
            self.reads += 1
            return self.reading
        }, debounce: debounce)
        observer.onChange = { [unowned self] closed in
            self.events.append("change \(closed)")
            self.readsAtChange.append(self.reads)
        }
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

    /// Keeps the main thread busy, so that timers due meanwhile fire
    /// together once it is free.
    private func holdTheMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func testWaiterRunsAtOnceWithNoChangePending() {
        let observer = makeObserver()

        observer.whenSettled(waiter())

        XCTAssertEqual(events, ["settled false"])
    }

    func testWaiterRunsAfterTheDeliveryOfAPendingChange() async {
        let observer = makeObserver()
        reading = .closed
        observer.handleInterest()

        observer.whenSettled(waiter())

        XCTAssertEqual(events, [], "ran before the debounce settled the change")
        await waitUntil("the change was never delivered") { events.count >= 2 }
        XCTAssertEqual(events, ["change true", "settled true"])
    }

    func testWaiterRunsWhenThePendingChangeFlapsBack() async {
        let observer = makeObserver()
        reading = .closed
        observer.handleInterest()
        observer.whenSettled(waiter())

        reading = .open
        observer.handleInterest()

        XCTAssertEqual(events, ["settled false"])
        await pastTheDebounce()
        XCTAssertEqual(events, ["settled false"], "a dropped change was delivered")
    }

    /// No message for the return trip: the debounce finds the lid back
    /// where it was and drops the change.
    func testWaiterRunsWhenTheChangeHasFlappedByTheDeadline() async {
        let observer = makeObserver()
        reading = .closed
        observer.handleInterest()
        observer.whenSettled(waiter())

        reading = .open
        await waitUntil("the debounce never settled") { !events.isEmpty }

        XCTAssertEqual(events, ["settled false"])
    }

    func testNewerWaiterReplacesTheOlder() async {
        let observer = makeObserver()
        reading = .closed
        observer.handleInterest()

        observer.whenSettled(waiter("first"))
        observer.whenSettled(waiter("second"))
        await waitUntil("the change was never delivered") { events.count >= 2 }

        XCTAssertEqual(events, ["change true", "second true"])
    }

    func testAClosedLidIsAtADeskOnlyWithAnExternalDisplay() {
        XCTAssertEqual(LidObserver.reading(closed: false, externalDisplay: true), .open)
        XCTAssertEqual(LidObserver.reading(closed: true, externalDisplay: true), .closedAtDesk)
        XCTAssertEqual(LidObserver.reading(closed: true, externalDisplay: false), .closed)
        XCTAssertNil(LidObserver.reading(closed: nil, externalDisplay: true))
    }

    /// The display macOS keeps online with the lid closed and nothing
    /// plugged in is no external display.
    func testTheStandInDisplayIsNotExternal() {
        XCTAssertTrue(LidObserver.isExternal(builtIn: false, vendor: 0x1E6D))
        XCTAssertFalse(LidObserver.isExternal(builtIn: false, vendor: 0x756E_6B6E))
        XCTAssertFalse(LidObserver.isExternal(builtIn: true, vendor: 0x0610))
    }

    /// Closed with a display attached, then the display unplugged and
    /// plugged in again: closed while it is gone, open once it is back.
    func testALidClosedAtADeskClosesOnlyWhileItsDisplayIsGone() async {
        let observer = makeObserver()
        reading = .closedAtDesk
        observer.handleInterest()
        await pastTheDebounce()
        XCTAssertEqual(events, [])
        XCTAssertFalse(observer.isClosed)
        XCTAssertTrue(observer.isShut)

        reading = .closed
        observer.handleInterest()
        await waitUntil("the close was never delivered") { !events.isEmpty }
        XCTAssertEqual(events, ["change true"])
        XCTAssertTrue(observer.closedByDisplayLoss)

        reading = .closedAtDesk
        observer.handleInterest()
        await waitUntil("the open was never delivered") { events.count >= 2 }
        XCTAssertEqual(events, ["change true", "change false"])
        XCTAssertFalse(observer.closedByDisplayLoss)
    }

    /// A saved brightness only a lid open may restore keeps a lid closed by
    /// its display's unplugging closed when the display comes back.
    func testADisplayBackLeavesTheLidClosedWhileABrightnessWaits() async {
        let observer = makeObserver()
        observer.brightnessJournaled = { true }
        reading = .closedAtDesk
        observer.handleInterest()
        reading = .closed
        observer.handleInterest()
        await waitUntil("the close was never delivered") { !events.isEmpty }
        XCTAssertTrue(observer.closedByDisplayLoss)

        reading = .closedAtDesk
        observer.handleInterest()
        await pastTheDebounce()
        XCTAssertEqual(events, ["change true"], "the display's return opened a lid a brightness waits under")

        reading = .open
        observer.handleInterest()
        await waitUntil("the open was never delivered") { events.count >= 2 }
        XCTAssertEqual(events, ["change true", "change false"])
    }

    /// Closed with nothing attached, then a display plugged in: still
    /// closed, until the lid opens.
    func testALidClosedInABagStaysClosedWhenADisplayIsPluggedIn() async {
        let observer = makeObserver()
        reading = .closed
        observer.handleInterest()
        await waitUntil("the close was never delivered") { !events.isEmpty }
        XCTAssertFalse(observer.closedByDisplayLoss)

        reading = .closedAtDesk
        observer.handleInterest()
        await pastTheDebounce()
        XCTAssertEqual(events, ["change true"], "a display plugged into a closed lid opened it")
        XCTAssertTrue(observer.isClosed)

        reading = .open
        observer.handleInterest()
        await waitUntil("the open was never delivered") { events.count >= 2 }
        XCTAssertEqual(events, ["change true", "change false"])
        XCTAssertFalse(observer.isShut)
    }

    /// A display that comes back within the debounce leaves the lid open.
    func testADisplayUnpluggedForAMomentIsAFlap() async {
        let observer = makeObserver()
        reading = .closedAtDesk
        observer.handleInterest()
        reading = .closed
        observer.handleInterest()
        reading = .closedAtDesk
        observer.handleInterest()
        await pastTheDebounce()
        XCTAssertEqual(events, [])
    }

    /// A lid closed at a desk loses its display, and the debounce finds the
    /// lid open with no event for it. The lid is no longer at a desk, so
    /// closing it again is an ordinary close, and a display plugged in then
    /// leaves it closed.
    func testAnOpenLidFoundWhenTheDebounceEndsIsNoLongerAtADesk() async {
        let observer = makeObserver()
        reading = .closedAtDesk
        observer.handleInterest()
        reading = .closed
        observer.handleInterest()
        observer.whenSettled(waiter())
        reading = .open
        await waitUntil("the debounce never settled") { !events.isEmpty }
        XCTAssertEqual(events, ["settled false"])

        reading = .closed
        observer.handleInterest()
        await waitUntil("the close was never delivered") { events.count >= 2 }
        XCTAssertEqual(events, ["settled false", "change true"])
        XCTAssertFalse(observer.closedByDisplayLoss, "a lid closed after it read open lost a display")

        reading = .closedAtDesk
        observer.handleInterest()
        await pastTheDebounce()
        XCTAssertEqual(events, ["settled false", "change true"], "a display plugged into a lid closed away from a desk opened it")
        XCTAssertTrue(observer.isClosed)
    }

    func testTheSeedDecidesALidClosedAtADesk() {
        let observer = makeObserver()
        reading = .closedAtDesk
        observer.seed(closed: true)
        XCTAssertTrue(observer.isClosed)
        observer.seed(closed: false)
        XCTAssertFalse(observer.isClosed)
        reading = .closed
        observer.seed(closed: false)
        XCTAssertTrue(observer.isClosed)
    }

    /// A change after the stop, as after a restart, must not run a
    /// waiter left from before it.
    func testStopDropsTheWaiter() async {
        let observer = makeObserver()
        reading = .closed
        observer.handleInterest()
        observer.whenSettled(waiter())

        observer.stop()
        await pastTheDebounce()
        XCTAssertEqual(events, [])
        observer.handleInterest()
        await waitUntil("the change after the stop was never delivered") { !events.isEmpty }

        XCTAssertEqual(events, ["change true"])
    }

    // MARK: A display list that cannot be read

    func testAClosedLidWithAnUnreadableDisplayListReadsUnknown() {
        XCTAssertEqual(LidObserver.reading(closed: true, externalDisplay: nil), .closedDisplaysUnknown)
        XCTAssertEqual(LidObserver.reading(closed: false, externalDisplay: nil), .open)
        XCTAssertNil(LidObserver.reading(closed: nil, externalDisplay: nil))
    }

    /// A lid closed at a desk whose display list cannot be read, at the
    /// event and at every read since, is no close: no mute, freeze or lock
    /// for a Mac in use. The lid still reads shut.
    func testAClosedLidWithAnUnreadableDisplayListDeliversNothing() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedDisplaysUnknown
        observer.handleInterest()

        await waitUntil("the lid was not read again") { reads >= 3 }

        XCTAssertEqual(events, [])
        XCTAssertFalse(observer.isClosed)
        XCTAssertTrue(observer.isShut)
    }

    /// A close waiting out the debounce is dropped when the display list
    /// cannot be read at the next event.
    func testAnUnreadableDisplayListAtAnEventDropsThePendingClose() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closed
        observer.handleInterest()
        observer.whenSettled(waiter())

        reading = .closedDisplaysUnknown
        observer.handleInterest()

        XCTAssertEqual(events, ["settled false"])
        await pastTheDebounce()
        XCTAssertEqual(events, ["settled false"], "a close was delivered on an unreadable display list")
    }

    /// The same at the end of the debounce, with no event in between.
    func testAnUnreadableDisplayListAtTheEndOfTheDebounceDropsTheClose() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closed
        observer.handleInterest()
        observer.whenSettled(waiter())
        reading = .closedDisplaysUnknown

        await waitUntil("the debounce never settled") { !events.isEmpty }
        await pastTheDebounce()

        XCTAssertEqual(events, ["settled false"])
        XCTAssertFalse(observer.isClosed)
    }

    /// The list reads again with an external display connected: the lid is
    /// at a desk and stays open, and the reads stop.
    func testAnUnreadableDisplayListThatReadsAnExternalDisplayDeliversNoClose() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        await waitUntil("the lid was not read again") { reads >= 2 }
        XCTAssertEqual(events, [])

        reading = .closedAtDesk
        let readsWhenUnknown = reads
        await waitUntil("the lid was not read again") { reads > readsWhenUnknown }
        let readsOnceKnown = reads
        await pastTheDebounce()
        await pastTheDebounce()

        XCTAssertEqual(events, [])
        XCTAssertEqual(reads, readsOnceKnown, "the lid is still read again with its display list readable")
        XCTAssertFalse(observer.isClosed)
    }

    /// The list reads again with no external display: the close comes with
    /// no further event, one debounce after the read that saw it.
    func testAnUnreadableDisplayListThatReadsNoDisplayDeliversTheClose() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        await waitUntil("the lid was not read again") { reads >= 2 }
        XCTAssertEqual(events, [])

        reading = .closed
        let readsWhenUnknown = reads
        await waitUntil("the close was never delivered") { !events.isEmpty }

        XCTAssertEqual(events, ["change true"])
        XCTAssertEqual(readsAtChange, [readsWhenUnknown + 2], "the close was not delivered by the debounce after the read that saw it")
        XCTAssertFalse(observer.closedByDisplayLoss)
        await pastTheDebounce()
        XCTAssertEqual(reads, readsWhenUnknown + 2, "the lid is still read again after the close")
    }

    /// A lid closed in a bag whose display list then cannot be read opens
    /// with no event for it: the read again finds it open, the open comes
    /// one debounce later, and the reads stop.
    func testAnUnreadableDisplayListThatReadsTheLidOpenDeliversTheOpen() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closed
        observer.handleInterest()
        await waitUntil("the close was never delivered") { !events.isEmpty }
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        let readsWhenUnknown = reads
        await waitUntil("the lid was not read again") { reads > readsWhenUnknown }
        XCTAssertEqual(events, ["change true"])
        XCTAssertTrue(observer.isClosed)

        reading = .open
        await waitUntil("the open was never delivered") { events.count >= 2 }
        let readsOnceOpen = reads
        await pastTheDebounce()
        await pastTheDebounce()

        XCTAssertEqual(events, ["change true", "change false"])
        XCTAssertEqual(reads, readsOnceOpen, "the lid is still read again once it is open")
    }

    /// A read again that finds no lid at all changes nothing, and the
    /// reads go on with no event needed: the close comes once the list
    /// reads with no display.
    func testALidThatCannotBeReadWhileItsDisplayListCannotBeReadIsReadAgain() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        await waitUntil("the lid was not read again") { reads >= 2 }

        reading = nil
        let readsWhenUnavailable = reads
        await waitUntil("the lid was not read again") { reads > readsWhenUnavailable }
        XCTAssertEqual(events, [])
        XCTAssertFalse(observer.isClosed)

        reading = .closed
        await waitUntil("the close was never delivered") { !events.isEmpty }
        XCTAssertEqual(events, ["change true"])
    }

    /// A lid closed at a desk, then a display list that cannot be read,
    /// then no display: the unreadable read does not hide where the lid
    /// was, so the close is a display loss and the display's return opens
    /// the lid.
    func testALidAtADeskThatLosesItsDisplayAcrossAnUnreadableListIsADisplayLoss() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedAtDesk
        observer.handleInterest()
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        await waitUntil("the lid was not read again") { reads >= 3 }
        XCTAssertEqual(events, [])

        reading = .closed
        observer.handleInterest()
        await waitUntil("the close was never delivered") { !events.isEmpty }
        XCTAssertEqual(events, ["change true"])
        XCTAssertTrue(observer.closedByDisplayLoss)

        reading = .closedAtDesk
        observer.handleInterest()
        await waitUntil("the open was never delivered") { events.count >= 2 }
        XCTAssertEqual(events, ["change true", "change false"])
    }

    /// The display goes away and the list cannot be read before the
    /// debounce ends: the close that comes once it reads is still a
    /// display loss.
    func testADisplayLossCutShortByAnUnreadableListIsStillADisplayLoss() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedAtDesk
        observer.handleInterest()
        reading = .closed
        observer.handleInterest()
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        await waitUntil("the lid was not read again") { reads >= 4 }
        XCTAssertEqual(events, [])

        reading = .closed
        await waitUntil("the close was never delivered") { !events.isEmpty }

        XCTAssertEqual(events, ["change true"])
        XCTAssertTrue(observer.closedByDisplayLoss)
    }

    /// The seed takes such a lid as it is told, as at a desk, and reads it
    /// again until the list reads.
    func testTheSeedDecidesALidWhoseDisplayListCannotBeRead() async {
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedDisplaysUnknown
        observer.seed(closed: true)
        XCTAssertTrue(observer.isClosed)
        observer.seed(closed: false)
        XCTAssertFalse(observer.isClosed)

        reading = .closed
        await waitUntil("the close was never delivered") { !events.isEmpty }

        XCTAssertEqual(events, ["change true"])
        XCTAssertTrue(observer.closedByDisplayLoss, "a lid taken as at a desk lost no display")
    }

    func testStopEndsTheReadsOfAnUnreadableDisplayList() async {
        let observer = makeObserver()
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        await waitUntil("the lid was not read again") { reads >= 2 }

        observer.stop()
        let readsAtStop = reads
        reading = .closed
        await pastTheDebounce()
        await pastTheDebounce()

        XCTAssertEqual(reads, readsAtStop, "the lid is still read after the stop")
        XCTAssertEqual(events, [])
    }

    /// The read again has fired and its callback waits for the main actor
    /// when the observer stops and starts again under the same lid: the
    /// callback does nothing, and the restarted observer reads on its own
    /// schedule.
    func testAReadAgainQueuedBeforeAStopDoesNothingAfterARestart() async {
        let lid = CountedLid(.closedDisplaysUnknown)
        let observer = LidObserver(read: {
            lid.reads += 1
            return lid.reading
        }, debounce: debounce)
        defer { observer.stop() }
        observer.handleInterest()
        // Due just after the read again. With the main thread held past
        // both, the run loop fires the two in one pass, so the stop and the
        // restart come in after the read again queued its callback and
        // before that callback runs. The reads are counted at the restart
        // and again in a callback queued after it.
        let counted = expectation(description: "reads counted after the queued callback")
        let restart = Timer(timeInterval: debounce * 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                observer.stop()
                observer.seed(closed: false)
                lid.counts.append(lid.reads)
            }
            Task { @MainActor in
                lid.counts.append(lid.reads)
                counted.fulfill()
            }
        }
        RunLoop.main.add(restart, forMode: .common)
        holdTheMainThread(for: debounce * 3)
        await fulfillment(of: [counted], timeout: 5)

        XCTAssertEqual(lid.counts.count, 2)
        XCTAssertEqual(lid.counts.last, lid.counts.first, "a read again queued before the stop read the lid after the restart")
        let readsAtRestart = lid.reads
        await waitUntil("the restarted observer did not read the lid again") { lid.reads > readsAtRestart }
    }

    /// One line when the list cannot be read and one when it reads again,
    /// not one per read.
    func testAnUnreadableDisplayListIsLoggedWhenItStartsAndWhenItEnds() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let observer = makeObserver()
        defer { observer.stop() }
        reading = .closedDisplaysUnknown
        observer.handleInterest()
        observer.handleInterest()
        await waitUntil("the lid was not read again") { reads >= 4 }
        reading = .closedAtDesk
        observer.handleInterest()

        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "lid closed, display list unreadable").count - 1, 1, log)
        XCTAssertEqual(log.components(separatedBy: "lid display list readable again").count - 1, 1, log)
    }
}

/// A fake lid for a test whose timer callbacks cannot capture the test
/// case, which is not Sendable.
@MainActor
private final class CountedLid {
    var reading: LidReading?
    /// How many times the observer has read the lid.
    var reads = 0
    /// `reads` at the points the test counts them.
    var counts: [Int] = []

    init(_ reading: LidReading?) {
        self.reading = reading
    }
}
