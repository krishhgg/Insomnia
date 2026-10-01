import XCTest
@testable import Insomnia

final class RecordingHotspotJoiner: HotspotJoining, @unchecked Sendable {
    struct Call: Equatable {
        let ssid: String
        let password: String
        let interfaceName: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var result = true
    var calls: [Call] { lock.withLock { _calls } }

    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        lock.withLock { _calls.append(Call(ssid: ssid, password: password, interfaceName: interfaceName)) }
        return result
    }
}

final class FailoverMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testShortBlipDoesNotJoin() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathUnsatisfied(at: t0), [.scheduleRetry(after: 5)])
        // Satisfied again after 3 s: the driver cancels the timer; the
        // machine reports the recovery and no join ever happened.
        XCTAssertEqual(m.pathSatisfied(at: t0.addingTimeInterval(3)), [.recovered(start: t0, gap: 3)])
        XCTAssertFalse(m.inOutage)
        XCTAssertEqual(m.joins, 0)
        // A stale timer firing after recovery is ignored.
        XCTAssertEqual(m.timerFired(at: t0.addingTimeInterval(5)), [])
    }

    func testTimerBeforeInitialDelayDoesNotJoin() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathUnsatisfied(at: t0), [.scheduleRetry(after: 5)])
        XCTAssertEqual(m.timerFired(at: t0.addingTimeInterval(4.999)), [])
        XCTAssertEqual(
            m.timerFired(at: t0.addingTimeInterval(5)),
            [.joinHotspot, .scheduleRetry(after: 5)]
        )
    }

    func testLongOutageJoinsThenBacksOff() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathUnsatisfied(at: t0), [.scheduleRetry(after: 5)])
        var t = t0.addingTimeInterval(5)
        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            let out = m.timerFired(at: t)
            XCTAssertEqual(out.first, .joinHotspot)
            guard case let .scheduleRetry(after)? = out.last else { return XCTFail("expected retry") }
            delays.append(after)
            t = t.addingTimeInterval(after)
        }
        XCTAssertEqual(delays, [5, 10, 20, 30, 30, 30, 30])
        XCTAssertEqual(m.joins, 7)
        let out = m.pathSatisfied(at: t)
        XCTAssertEqual(out, [.recovered(start: t0, gap: t.timeIntervalSince(t0))])
        XCTAssertEqual(m.joins, 0)
    }

    func testRepeatedUnsatisfiedDuringOutageIsIgnored() {
        var m = FailoverMachine()
        _ = m.pathUnsatisfied(at: t0)
        XCTAssertEqual(m.pathUnsatisfied(at: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(m.outageStart, t0)
    }

    func testSatisfiedWithoutOutageIsIgnored() {
        var m = FailoverMachine()
        XCTAssertEqual(m.pathSatisfied(at: t0), [])
    }

    func testRecoveryBelowThresholdNoNudge() {
        let c = Config()  // nudgeThreshold 90
        XCTAssertFalse(60 >= c.nudgeThreshold)
        XCTAssertTrue(90 >= c.nudgeThreshold)
        XCTAssertTrue(130 >= c.nudgeThreshold)
    }

    func testLogLineFormat() {
        let end = t0.addingTimeInterval(130)
        XCTAssertEqual(
            FailoverMachine.logLine(start: t0, end: end, gap: 130),
            "2027-01-15T08:02:10Z outage start=2027-01-15T08:00:00Z end=2027-01-15T08:02:10Z gap=130s"
        )
    }

    func testHumanGap() {
        XCTAssertEqual(FailoverMachine.humanGap(130), "2m 10s")
        XCTAssertEqual(FailoverMachine.humanGap(45), "45s")
        XCTAssertEqual(FailoverMachine.humanGap(3723), "1h 2m 3s")
        XCTAssertEqual(FailoverMachine.humanGap(120), "2m")
        XCTAssertEqual(FailoverMachine.humanGap(0), "0s")
    }
}

@MainActor
final class NetworkFailoverDriverTests: XCTestCase {
    var home: TempHome!

    override func setUp() async throws { home = TempHome() }
    override func tearDown() async throws { home.destroy() }

    /// Runs the machine through the real driver's recovery path via the
    /// `onRecovered`/nudge/notify plumbing by exercising a NetworkFailover
    /// whose tmux runner is a fake. The NWPathMonitor itself is not started.
    func testRecoveryAboveThresholdNudgesAndNotifies() async throws {
        let nudged = Locked<[String]>([])
        let nudge = TmuxNudge { target in
            nudged.value.append(target)
            return true
        }
        let notifier = RecordingNotifier()
        var config = Config()
        config.tmuxTargets = ["agents:0.0", "agents:0.1"]
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: nudge, notifier: notifier, clock: { clock.now }) { config }
        let gaps = Locked<[TimeInterval]>([])
        n.onRecovered = { gaps.value.append($0) }

        await n.simulate(satisfied: false)
        clock.advance(130)
        await n.simulate(satisfied: true)

        XCTAssertEqual(nudged.value, ["agents:0.0", "agents:0.1"])
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertEqual(notifier.posts[0].body, "Network was down 2m 10s. Nudged 2 tmux panes. Check GUI agents.")
        XCTAssertEqual(gaps.value, [130])
        XCTAssertEqual(n.lastGap, 130)
        let log = try String(contentsOf: home.paths.handoffsLog, encoding: .utf8)
        XCTAssertTrue(log.contains("gap=130s"), log)
    }

    func testRecoveryBelowThresholdLogsOnly() async throws {
        let nudged = Locked<[String]>([])
        let nudge = TmuxNudge { target in
            nudged.value.append(target)
            return true
        }
        let notifier = RecordingNotifier()
        var config = Config()
        config.tmuxTargets = ["agents:0.0"]
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: nudge, notifier: notifier, clock: { clock.now }) { config }

        await n.simulate(satisfied: false)
        clock.advance(20)
        await n.simulate(satisfied: true)

        XCTAssertEqual(nudged.value, [])
        XCTAssertEqual(notifier.posts.count, 0)
        XCTAssertEqual(n.lastGap, 20)
        let log = try String(contentsOf: home.paths.handoffsLog, encoding: .utf8)
        XCTAssertTrue(log.contains("gap=20s"), log)
    }

    func testRecoveryAtThresholdNudgesAndNotifies() async throws {
        let nudged = Locked<[String]>([])
        let nudge = TmuxNudge { target in
            nudged.value.append(target)
            return true
        }
        let notifier = RecordingNotifier()
        var config = Config()
        config.nudgeThreshold = 90
        config.tmuxTargets = ["agents:0.0"]
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: nudge, notifier: notifier, clock: { clock.now }) { config }

        await n.simulate(satisfied: false)
        clock.advance(90)
        await n.simulate(satisfied: true)

        XCTAssertEqual(nudged.value, ["agents:0.0"])
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func testHotspotJoinUsesInjectedJoiner() async throws {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "top secret")
        let joiner = RecordingHotspotJoiner()
        var config = Config()
        config.hotspotSSID = "Phone"
        let n = NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            hotspotJoiner: joiner,
            notifier: RecordingNotifier(),
            wifiInterface: "en0"
        ) { config }

        await n.joinHotspot()

        XCTAssertEqual(
            joiner.calls,
            [.init(ssid: "Phone", password: "top secret", interfaceName: "en0")]
        )
        XCTAssertNil(n.passwordProblem)
    }

    private func driver(
        keychain: FakeKeychainStore,
        joiner: RecordingHotspotJoiner,
        notifier: RecordingNotifier,
        clock: FakeClock
    ) -> NetworkFailover {
        var config = Config()
        config.hotspotSSID = "Phone"
        return NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            hotspotJoiner: joiner,
            notifier: notifier,
            wifiInterface: "en0",
            clock: { clock.now }
        ) { config }
    }

    /// A join with no saved password is not a silent skip: the problem is
    /// published for the menu and notified once, not on every retry.
    func testMissingPasswordIsSurfacedOnceAndNoJoinIsAttempted() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: clock)
        let published = Locked<[HotspotPasswordProblem?]>([])
        n.onPasswordProblem = { published.value.append($0) }

        await n.simulate(satisfied: false)
        for _ in 0..<3 {
            clock.advance(30)
            n.fireTimer()
            await settleQueuedRequests()
        }

        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(n.passwordProblem, .missing)
        XCTAssertEqual(published.value, [.missing])
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertEqual(notifier.posts[0].title, "Hotspot not joined")
        XCTAssertEqual(notifier.posts[0].body, "No hotspot password is saved. Enter it in Settings.")
    }

    /// The item exists but belongs to another build (the keychain refuses
    /// it with prompts forbidden): same surfacing, with the re-enter wording.
    func testUnreadablePasswordIsSurfacedWithTheReenterWording() async throws {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "old build's secret")
        keychain.unreadable = ["\(KeychainStore.service)/Phone"]
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let n = driver(keychain: keychain, joiner: joiner, notifier: notifier, clock: FakeClock(Date()))

        await n.joinHotspot()

        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(n.passwordProblem, .unreadable)
        XCTAssertEqual(n.passwordProblem?.menuLine, "\u{26A0} Hotspot password unreadable by this build: enter it again in Settings")
        XCTAssertEqual(notifier.posts.map(\.body), [HotspotPasswordProblem.unreadable.explanation])
        XCTAssertTrue(notifier.posts[0].body.contains("Enter it again in Settings"))
    }

    /// Saving in Settings clears the problem at once, and a read that then
    /// succeeds keeps it clear; a problem that comes back after a save is
    /// notified again.
    func testSavingThePasswordClearsTheProblemAndRearmsTheNotification() async throws {
        let keychain = FakeKeychainStore()
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let n = driver(keychain: keychain, joiner: joiner, notifier: notifier, clock: FakeClock(Date()))
        let published = Locked<[HotspotPasswordProblem?]>([])
        n.onPasswordProblem = { published.value.append($0) }

        await n.joinHotspot()
        XCTAssertEqual(n.passwordProblem, .missing)
        n.passwordChanged()
        XCTAssertNil(n.passwordProblem)
        XCTAssertEqual(published.value, [.missing, nil])

        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        await n.joinHotspot()
        XCTAssertNil(n.passwordProblem)
        XCTAssertEqual(joiner.calls.map(\.password), ["pw"])

        try keychain.delete(service: KeychainStore.service, account: "Phone")
        await n.joinHotspot()
        XCTAssertEqual(n.passwordProblem, .missing)
        XCTAssertEqual(notifier.posts.count, 2, "the problem returned after a save, so it is notified again")
    }

    /// A new outage after stop() notifies again; the once-per-outage guard
    /// does not outlive the driver's session.
    func testStopRearmsTheNotificationForTheNextSession() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: FakeClock(Date()))

        await n.joinHotspot()
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 1)
        n.stop()
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 2)
    }
}
