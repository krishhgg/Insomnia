import AppKit
import XCTest
@testable import Insomnia

/// The countdown redraw stops while every display sleeps, as it does for a
/// closed lid, and a wake redraws at once.
@MainActor
final class DisplaySleepTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    func testDisplaySleepStopsTheRedrawAndAWakeRedrawsAtOnce() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertEqual(m.countdownText, "1:00:00")

        m.displaysAsleepChanged(true)
        XCTAssertFalse(m.countdownTimerArmed)
        h.clock.advance(90)
        XCTAssertEqual(m.countdownText, "1:00:00")

        m.displaysAsleepChanged(false)
        XCTAssertTrue(m.countdownTimerArmed)
        XCTAssertEqual(m.countdownText, "0:58:30")
    }

    /// The end time has no redraw: a wake arms none. Switching to the time
    /// left while the displays sleep waits for their wake to arm one.
    func testWithTheEndTimeAWakeArmsNothingAndASwitchWaitsForTheWake() async throws {
        let m = h.makeManager()
        m.config.countdownStyle = .endTime
        await m.start(duration: 3600)
        XCTAssertFalse(m.countdownTimerArmed)
        m.displaysAsleepChanged(true)
        m.displaysAsleepChanged(false)
        XCTAssertFalse(m.countdownTimerArmed)

        m.displaysAsleepChanged(true)
        m.config.countdownStyle = .remaining
        m.countdownStyleChanged()
        XCTAssertFalse(m.countdownTimerArmed, "the displays still sleep")
        m.displaysAsleepChanged(false)
        XCTAssertTrue(m.countdownTimerArmed)
    }

    func testAWakeWithTheLidClosedLeavesTheRedrawStopped() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        m.pauseCountdown()
        m.displaysAsleepChanged(true)

        m.displaysAsleepChanged(false)
        XCTAssertFalse(m.countdownTimerArmed)

        m.resumeCountdown()
        XCTAssertTrue(m.countdownTimerArmed)
    }

    /// Opening the lid wakes the displays: the redraw does not wait for
    /// their wake to arrive.
    func testALidOpenWhileTheDisplaysSleepRedrawsAtOnce() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        m.pauseCountdown()
        m.displaysAsleepChanged(true)

        m.resumeCountdown()
        XCTAssertTrue(m.countdownTimerArmed)

        m.displaysAsleepChanged(false)
        XCTAssertTrue(m.countdownTimerArmed)
    }

    func testASessionStartedWhileTheDisplaysSleepRedrawsFromTheWake() async throws {
        let m = h.makeManager()
        m.displaysAsleepChanged(true)
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        XCTAssertEqual(m.countdownText, "1:00:00")
        XCTAssertFalse(m.countdownTimerArmed)

        m.displaysAsleepChanged(false)
        XCTAssertTrue(m.countdownTimerArmed)
    }

    func testAWakeWithNoSessionArmsNothing() async throws {
        let m = h.makeManager()
        m.displaysAsleepChanged(true)
        m.displaysAsleepChanged(false)
        XCTAssertFalse(m.countdownTimerArmed)
        XCTAssertEqual(m.countdownText, "")
    }

    /// A relaunch while the displays sleep resumes the session without its
    /// redraw: the observer's first report comes before the reconcile.
    func testASessionResumedWhileTheDisplaysSleepRedrawsFromTheWake() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        let m = h.makeManager()
        let observer = DisplaySleepObserver(center: NotificationCenter(), asleepNow: { true }) { m.displaysAsleepChanged($0) }
        await m.reconcile()
        XCTAssertNotNil(m.session)
        XCTAssertFalse(m.countdownTimerArmed)

        m.displaysAsleepChanged(false)
        XCTAssertTrue(m.countdownTimerArmed)
        withExtendedLifetime(observer) {}
    }

    func testTheObserverReportsTheStateAtLaunchThenWorkspaceSleepAndWake() {
        final class Seen { var values: [Bool] = [] }
        for asleep in [false, true] {
            let center = NotificationCenter()
            let seen = Seen()
            let observer = DisplaySleepObserver(center: center, asleepNow: { asleep }) { seen.values.append($0) }
            center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            XCTAssertEqual(seen.values, [asleep, true, false])
            withExtendedLifetime(observer) {}
        }
    }
}
