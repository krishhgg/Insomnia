import IOKit.pwr_mgt
import XCTest
@testable import Insomnia

/// Records every create, renew and release; `failCreate` makes the next
/// creates throw, `failRenew` the next renews and `failRelease` the next
/// releases report a refusal.
final class FakeDisplayAssertions: DisplayAssertionHolding, @unchecked Sendable {
    private let lock = NSLock()
    private var _created: [String] = []
    private var _timeouts: [TimeInterval] = []
    private var _renewed: [IOPMAssertionID: [TimeInterval]] = [:]
    private var _released: [IOPMAssertionID] = []
    private var _next: IOPMAssertionID = 40
    var failCreate = false
    var failRenew = false
    var failRelease = false

    var created: [String] { lock.withLock { _created } }
    /// The timeout of each create, in order.
    var timeouts: [TimeInterval] { lock.withLock { _timeouts } }
    /// The timeouts each id was renewed to, in order.
    var renewed: [IOPMAssertionID: [TimeInterval]] { lock.withLock { _renewed } }
    var released: [IOPMAssertionID] { lock.withLock { _released } }
    private var _refused: [IOPMAssertionID] = []
    /// Releases that were refused, in order.
    var refused: [IOPMAssertionID] { lock.withLock { _refused } }

    func create(name: String, timeout: TimeInterval) throws -> IOPMAssertionID {
        if failCreate { throw ScreenAwakeError(status: kIOReturnNotPermitted) }
        return lock.withLock {
            _created.append(name)
            _timeouts.append(timeout)
            _next += 1
            return _next
        }
    }

    func renew(_ id: IOPMAssertionID, timeout: TimeInterval) -> Bool {
        if failRenew { return false }
        lock.withLock { _renewed[id, default: []].append(timeout) }
        return true
    }

    func release(_ id: IOPMAssertionID) -> Bool {
        lock.withLock {
            if failRelease {
                _refused.append(id)
                return false
            }
            _released.append(id)
            return true
        }
    }
}

@MainActor
final class ScreenAwakeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var deadline: Date { now.addingTimeInterval(3600) }

    func testHoldsOnceAndReleasesThatAssertion() {
        let fake = FakeDisplayAssertions()
        let awake = ScreenAwake(assertions: fake)

        awake.hold(until: deadline, now: now)
        awake.hold(until: deadline, now: now)

        XCTAssertTrue(awake.isHeld)
        XCTAssertEqual(fake.created, [ScreenAwake.assertionName], "a repeated on holds one assertion")

        awake.release()
        awake.release()

        XCTAssertFalse(awake.isHeld)
        XCTAssertEqual(fake.released, [41], "the release names the assertion created, once")
    }

    func testReleaseWithNothingHeldDoesNothing() {
        let fake = FakeDisplayAssertions()
        let awake = ScreenAwake(assertions: fake)

        awake.release()

        XCTAssertEqual(fake.created, [])
        XCTAssertEqual(fake.released, [])
    }

    /// A refused release keeps the id and reports the mismatch; the next off
    /// releases that same id, and only then is the hold gone.
    func testAFailedReleaseKeepsTheIdForTheNextTry() {
        let home = TempHome()
        defer { home.destroy() }
        let fake = FakeDisplayAssertions()
        let awake = ScreenAwake(assertions: fake)
        awake.hold(until: deadline, now: now)
        fake.failRelease = true

        XCTAssertFalse(awake.release())

        XCTAssertTrue(awake.isHeld, "a refused release still holds the display")
        XCTAssertEqual(fake.refused, [41])
        let log = (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertFalse(log.contains("released, idle display sleep"), "success logged for a refused release: \(log)")

        fake.failRelease = false
        XCTAssertTrue(awake.release())

        XCTAssertFalse(awake.isHeld)
        XCTAssertEqual(fake.released, [41], "the retry releases the id that was refused")
        XCTAssertEqual(fake.created, [ScreenAwake.assertionName], "no second assertion was created")
    }

    /// A refused create holds nothing and is tried again on the next on.
    func testAFailedCreateHoldsNothingAndTheNextOnRetries() {
        let home = TempHome()
        defer { home.destroy() }
        let fake = FakeDisplayAssertions()
        fake.failCreate = true
        let awake = ScreenAwake(assertions: fake)

        awake.hold(until: deadline, now: now)

        XCTAssertFalse(awake.isHeld)
        let log = (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("the display can still sleep and lock the screen"), log)

        awake.release()
        XCTAssertEqual(fake.released, [], "nothing held, nothing released")

        fake.failCreate = false
        awake.hold(until: deadline, now: now)
        XCTAssertTrue(awake.isHeld)
        XCTAssertEqual(fake.created, [ScreenAwake.assertionName])
    }

    /// The hold times out at the deadline it was given, and moves with it.
    /// Holding to the same deadline again changes nothing.
    func testTheHoldTimesOutAtTheDeadlineAndMovesWithIt() {
        let fake = FakeDisplayAssertions()
        let awake = ScreenAwake(assertions: fake)

        awake.hold(until: deadline, now: now)
        XCTAssertEqual(fake.timeouts, [3600])
        awake.hold(until: deadline, now: now.addingTimeInterval(60))
        XCTAssertEqual(fake.renewed, [:], "the same deadline renews nothing")

        let later = deadline.addingTimeInterval(1800)
        XCTAssertTrue(awake.hold(until: later, now: now.addingTimeInterval(600)))

        XCTAssertEqual(fake.created.count, 1, "an extension keeps the one assertion")
        XCTAssertEqual(fake.renewed, [41: [4800]])
        XCTAssertEqual(awake.heldUntil, later)
    }

    /// A refused renew keeps the old timeout, says so, and is tried again.
    func testAFailedRenewKeepsTheOldDeadlineForTheNextTry() {
        let home = TempHome()
        defer { home.destroy() }
        let fake = FakeDisplayAssertions()
        let awake = ScreenAwake(assertions: fake)
        awake.hold(until: deadline, now: now)
        let later = deadline.addingTimeInterval(1800)
        fake.failRenew = true

        XCTAssertFalse(awake.hold(until: later, now: now))

        XCTAssertEqual(awake.heldUntil, deadline)
        let log = (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("could not move the hold's timeout"), log)

        fake.failRenew = false
        XCTAssertTrue(awake.hold(until: later, now: now))
        XCTAssertEqual(fake.renewed, [41: [5400]])
        XCTAssertEqual(awake.heldUntil, later)
    }

    /// IOKit takes whole seconds, and 0 would mean no timeout.
    func testTheTimeoutIsWholeSecondsRoundedUpAndAtLeastOne() {
        XCTAssertEqual(IOPMDisplayAssertions.seconds(3599.2), 3600)
        XCTAssertEqual(IOPMDisplayAssertions.seconds(3600), 3600)
        XCTAssertEqual(IOPMDisplayAssertions.seconds(0.2), 1)
        XCTAssertEqual(IOPMDisplayAssertions.seconds(0), 1)
        XCTAssertEqual(IOPMDisplayAssertions.seconds(-30), 1, "a deadline already past")
    }
}

/// The session owns the hold (`SessionManager.syncScreenAwake`): taken when a
/// session starts or resumes with the toggle on, dropped the moment an end
/// is requested, before the recovery lock or the journal can refuse it.
@MainActor
final class SessionScreenAwakeTests: XCTestCase {
    var h: Harness!
    var fake: FakeDisplayAssertions!

    override func setUp() async throws {
        h = Harness()
        fake = FakeDisplayAssertions()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    private func make(keepScreenAwake: Bool = true, assertions: FakeDisplayAssertions? = nil) -> SessionManager {
        let m = h.makeManager(displayAssertions: assertions ?? fake)
        m.config.keepScreenAwake = keepScreenAwake
        return m
    }

    func testASessionHoldsTheDisplayFromStartToEnd() async {
        let m = make()
        XCTAssertFalse(m.screenAwakeHeld, "nothing is held without a session")

        await m.start(duration: 3600)
        XCTAssertTrue(m.screenAwakeHeld)
        XCTAssertEqual(fake.created, [ScreenAwake.assertionName])
        XCTAssertEqual(fake.timeouts, [3600], "macOS turns the hold off at the deadline if the app no longer ends it")

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .restored)
        XCTAssertFalse(m.screenAwakeHeld)
        XCTAssertEqual(fake.released, [41])
    }

    func testWithTheToggleOffASessionHoldsNothing() async {
        let m = make(keepScreenAwake: false)

        await m.start(duration: 3600)

        XCTAssertFalse(m.screenAwakeHeld)
        XCTAssertEqual(fake.created, [])
    }

    /// Settings turns the toggle on and off during a running session.
    func testTheToggleAppliesToARunningSession() async {
        let m = make(keepScreenAwake: false)
        await m.start(duration: 3600)

        m.config.keepScreenAwake = true
        m.syncScreenAwake()
        XCTAssertTrue(m.screenAwakeHeld)

        m.config.keepScreenAwake = false
        m.syncScreenAwake()
        XCTAssertFalse(m.screenAwakeHeld)
        XCTAssertEqual(fake.released, [41])
    }

    /// The deadline's end is refused because another process holds the
    /// recovery lock. The session stays active, but the display is not held
    /// past the deadline, and the toggle does not take it back while that
    /// end is owed.
    func testADeadlineEndRefusedForABusyLockStillReleasesTheHold() async throws {
        let m = make()
        await m.start(duration: 3600)
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        defer { held.release() }

        let outcome = await m.end(reason: .timer)

        XCTAssertEqual(outcome, .locked)
        XCTAssertNotNil(m.session, "the refused end leaves the session active")
        XCTAssertFalse(m.screenAwakeHeld)
        XCTAssertEqual(fake.released, [41])
        m.syncScreenAwake()
        XCTAssertFalse(m.screenAwakeHeld, "the toggle must not hold the display again while the end is owed")
    }

    /// The same for a journal that cannot be read: the end waits for a
    /// person, and the screen locks on its own meanwhile.
    func testAnEndRefusedForAnUnreadableJournalStillReleasesTheHold() async throws {
        let m = make()
        await m.start(duration: 3600)
        try Data(#"{"sleepDisabledByUs": tru"#.utf8).write(to: h.home.paths.stateFile)

        let outcome = await m.end(reason: .timer)

        XCTAssertEqual(outcome, .journalUnreadable)
        XCTAssertNotNil(m.session)
        XCTAssertFalse(m.screenAwakeHeld)
        XCTAssertEqual(fake.released, [41])
    }

    /// macOS refuses the release at the end: the hold is kept, the menu
    /// says how to release it, and the next sync releases that same id.
    func testARefusedReleaseIsShownInTheMenuAndRetried() async {
        let m = make()
        await m.start(duration: 3600)
        fake.failRelease = true

        await m.end(reason: .user)

        XCTAssertNil(m.session)
        XCTAssertTrue(m.screenAwakeHeld, "a refused release still holds the display")
        XCTAssertTrue(m.lastError?.contains("could not release the display hold") == true, m.lastError ?? "")
        XCTAssertTrue(m.lastError?.contains("quit Insomnia") == true, m.lastError ?? "")

        fake.failRelease = false
        m.syncScreenAwake()

        XCTAssertFalse(m.screenAwakeHeld)
        XCTAssertEqual(fake.released, [41])
        XCTAssertNil(m.lastError, "the menu line goes once the release succeeds")
    }

    /// A later successful release takes down only the line its refusal put
    /// up; a newer failure of anything else stays in the menu.
    func testASuccessfulReleaseKeepsANewerUnrelatedMenuLine() async {
        let m = make()
        await m.start(duration: 3600)
        fake.failRelease = true
        await m.end(reason: .user)
        m.fail("something else failed later")

        fake.failRelease = false
        m.syncScreenAwake()

        XCTAssertFalse(m.screenAwakeHeld)
        XCTAssertEqual(m.lastError, "something else failed later")
    }

    /// An extension moves the hold's timeout to the new deadline, so the
    /// display stays on for the time added.
    func testAnExtensionMovesTheTimeoutToTheNewDeadline() async {
        let m = make()
        await m.start(duration: 3600)
        h.clock.now = h.clock.now.addingTimeInterval(600)

        await m.extend(by: 1800)

        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(4800))
        XCTAssertTrue(m.screenAwakeHeld)
        XCTAssertEqual(fake.created.count, 1)
        XCTAssertEqual(fake.renewed, [41: [4800]])
    }

    /// An end request does not leave the toggle dead for the next session.
    func testANewSessionAfterAnEndHoldsAgain() async {
        let m = make()
        await m.start(duration: 3600)
        await m.end(reason: .user)

        await m.start(duration: 3600)

        XCTAssertTrue(m.screenAwakeHeld)
        XCTAssertEqual(fake.created.count, 2)
    }

    /// A relaunch that finds the session still valid holds the display
    /// again, as the session is active again.
    func testARelaunchThatResumesTheSessionHoldsAgain() async throws {
        let first = make()
        try h.store.saveConfig(first.config)
        await first.start(duration: 3600)
        let relaunched = FakeDisplayAssertions()

        let m = h.makeManager(displayAssertions: relaunched)
        await m.reconcile()

        XCTAssertNotNil(m.session)
        XCTAssertTrue(m.screenAwakeHeld)
        XCTAssertEqual(relaunched.created, [ScreenAwake.assertionName])
    }
}
