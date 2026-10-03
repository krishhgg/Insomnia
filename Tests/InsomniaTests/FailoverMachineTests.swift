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
        let nudge = TmuxNudge { target, _ in
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

    /// Whether Enter follows `continue` is read from the config at nudge
    /// time and handed to the runner; the default is no Enter.
    func testNudgePassesTheEnterSettingFromConfig() async throws {
        for pressEnter in [false, true] {
            let seen = Locked<[Bool]>([])
            let nudge = TmuxNudge { _, enter in
                seen.value.append(enter)
                return true
            }
            var config = Config()
            config.tmuxTargets = ["agents:0.0"]
            config.tmuxNudgePressesEnter = pressEnter
            let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
            let n = NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: nudge, notifier: RecordingNotifier(), clock: { clock.now }) { config }

            await n.simulate(satisfied: false)
            clock.advance(130)
            await n.simulate(satisfied: true)

            XCTAssertEqual(seen.value, [pressEnter])
        }
    }

    func testRecoveryBelowThresholdLogsOnly() async throws {
        let nudged = Locked<[String]>([])
        let nudge = TmuxNudge { target, _ in
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
        let nudge = TmuxNudge { target, _ in
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
        XCTAssertNil(n.passwordReport?.problem)
    }

    /// A join whose keychain read waits behind a save in Settings (stuck
    /// on a keychain dialog) does not hold up stop(), and once the session
    /// has ended the read's answer neither joins nor reports anything.
    func testAJoinWaitingBehindABlockedSaveDoesNothingAfterTheSessionEnds() async throws {
        let queue = KeychainQueue()
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old"])
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: queue) { "Phone" }
        let saving = Task { await SettingsView.storePassword("new", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let joining = expectation(description: "the join started")
        joining.assertForOverFulfill = false
        var config = Config()
        config.hotspotSSID = "Phone"
        let n = NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            keychainQueue: queue,
            hotspotJoiner: joiner,
            notifier: notifier,
            wifiInterface: "en0",
            clock: { clock.now }
        ) {
            joining.fulfill()
            return config
        }
        await n.simulate(satisfied: false)
        clock.advance(30)
        let tick = n.fireTimer()
        await fulfillment(of: [joining], timeout: 5)

        n.stop()
        XCTAssertTrue(keychain.isWaiting, "stop() ran while the save was still waiting")
        keychain.release()
        _ = await saving.value
        await tick.value

        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(notifier.posts.map(\.title), [])
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertFalse(keychain.gaveUp)
    }

    /// Wi-Fi recovers while a join's keychain read waits behind a save in
    /// Settings. Once the save is answered the read finds the password,
    /// but the outage is over: nothing joins, so the recovered connection
    /// is not moved to the hotspot, and the retry the tick queued after
    /// the join is not scheduled.
    func testAJoinWaitingBehindABlockedSaveDoesNothingAfterWiFiRecovers() async throws {
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old"])
        let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Phone")

        await blocked.driver.simulate(satisfied: true)
        XCTAssertTrue(keychain.isWaiting, "Wi-Fi recovered while the save was still waiting")
        keychain.release()
        _ = await blocked.saving.value
        await blocked.tick.value

        XCTAssertEqual(blocked.joiner.calls, [])
        XCTAssertNil(blocked.driver.retryTimer, "a retry was scheduled after the outage ended")
        XCTAssertEqual(blocked.notifier.posts.map(\.title), [])
        XCTAssertNil(blocked.driver.passwordReport?.problem)
        XCTAssertEqual(blocked.driver.lastGap, 30)
        XCTAssertFalse(keychain.gaveUp)
        blocked.driver.stop()
    }

    /// The same wait, but the read then fails: there is no password for
    /// the hotspot. The outage is over, so nothing is reported, and the
    /// notification is still there for the next outage.
    func testAReadThatFailsAfterWiFiRecoveredLeavesTheNoticeForTheNextOutage() async throws {
        let keychain = BlockingKeychain()
        let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Other Phone")

        await blocked.driver.simulate(satisfied: true)
        keychain.release()
        _ = await blocked.saving.value
        await blocked.tick.value

        XCTAssertEqual(blocked.notifier.posts.map(\.title), [])
        XCTAssertNil(blocked.driver.passwordReport?.problem)
        XCTAssertNil(blocked.driver.retryTimer)

        await blocked.driver.simulate(satisfied: false)
        blocked.clock.advance(30)
        await blocked.driver.fireTimer().value

        XCTAssertEqual(blocked.notifier.posts.map(\.title), ["Hotspot not joined"])
        XCTAssertEqual(blocked.notifier.posts.map(\.body), [HotspotPasswordProblem.missing.explanation])
        XCTAssertEqual(blocked.driver.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .missing))
        XCTAssertEqual(blocked.joiner.calls, [])
        blocked.driver.stop()
    }

    /// Settings changes the hotspot while a join's keychain read waits
    /// behind a save. The read finds the old hotspot's password, but that
    /// is not the hotspot to join any more: nothing joins or reports. The
    /// retry the tick queued still comes, and joins the hotspot
    /// configured then.
    func testAJoinWhoseHotspotChangedDuringTheReadDoesNotJoinTheOldOne() async throws {
        let keychain = BlockingKeychain(items: ["\(KeychainStore.service)/Phone": "old"])
        let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Other Phone")

        blocked.hotspot.value = "Other Phone"
        keychain.release()
        _ = await blocked.saving.value
        await blocked.tick.value

        XCTAssertEqual(blocked.joiner.calls, [])
        XCTAssertEqual(blocked.notifier.posts.map(\.title), [])
        XCTAssertNil(blocked.driver.passwordReport?.problem)
        XCTAssertNotNil(blocked.driver.retryTimer, "the retry is still scheduled")

        blocked.clock.advance(30)
        await blocked.driver.fireTimer().value
        XCTAssertEqual(blocked.joiner.calls, [.init(ssid: "Other Phone", password: "new", interfaceName: "en0")])
        XCTAssertFalse(keychain.gaveUp)
        blocked.driver.stop()
    }

    /// The same, but the read finds no password for the old hotspot. The
    /// warning is about a hotspot no longer configured, so it is neither
    /// shown nor notified, and the one notification of this outage is
    /// still there when the next tick finds the new hotspot has no
    /// password either. Clearing the SSID drops the answer the same way.
    func testAWarningAboutTheOldHotspotIsDroppedWhenTheSSIDChanged() async throws {
        for changed in ["Third Phone", " "] {
            let keychain = BlockingKeychain()
            let blocked = try await outageWithAJoinBehindABlockedSave(keychain: keychain, savingFor: "Other Phone")

            blocked.hotspot.value = changed
            keychain.release()
            _ = await blocked.saving.value
            await blocked.tick.value

            XCTAssertEqual(blocked.notifier.posts.map(\.title), [], "SSID changed to \"\(changed)\"")
            XCTAssertNil(blocked.driver.passwordReport?.problem, "SSID changed to \"\(changed)\"")
            XCTAssertNotNil(blocked.driver.retryTimer, "SSID changed to \"\(changed)\"")

            blocked.clock.advance(30)
            await blocked.driver.fireTimer().value
            if HotspotSSID.normalized(changed).isEmpty {
                XCTAssertEqual(blocked.notifier.posts.map(\.title), [], "no hotspot is configured")
                XCTAssertNil(blocked.driver.passwordReport?.problem)
            } else {
                XCTAssertEqual(blocked.notifier.posts.map(\.body), [HotspotPasswordProblem.missing.explanation])
                XCTAssertEqual(blocked.driver.passwordReport, HotspotPasswordReport(ssid: "Third Phone", problem: .missing))
            }
            XCTAssertEqual(blocked.joiner.calls, [])
            XCTAssertFalse(keychain.gaveUp)
            blocked.driver.stop()
        }
    }

    private struct BlockedJoin {
        let driver: NetworkFailover
        let saving: Task<HotspotStoreOutcome, Never>
        let tick: Task<Void, Never>
        let joiner: RecordingHotspotJoiner
        let notifier: RecordingNotifier
        let clock: FakeClock
        /// The configured hotspot SSID, "Phone" until a test changes it.
        let hotspot: Locked<String>
    }

    /// A save for `ssid` blocked inside `keychain`, then an outage on
    /// hotspot "Phone" whose first join has started and queued its read
    /// behind that save.
    private func outageWithAJoinBehindABlockedSave(keychain: BlockingKeychain, savingFor ssid: String) async throws -> BlockedJoin {
        let queue = KeychainQueue()
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: queue) { ssid }
        let saving = Task { await SettingsView.storePassword("new", in: store) }
        await fulfillment(of: [keychain.entered], timeout: 5)

        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let joining = expectation(description: "the join started")
        joining.assertForOverFulfill = false
        let hotspot = Locked("Phone")
        let n = NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            keychainQueue: queue,
            hotspotJoiner: joiner,
            notifier: notifier,
            wifiInterface: "en0",
            clock: { clock.now }
        ) {
            joining.fulfill()
            var config = Config()
            config.hotspotSSID = hotspot.value
            return config
        }
        await n.simulate(satisfied: false)
        clock.advance(30)
        let tick = n.fireTimer()
        await fulfillment(of: [joining], timeout: 5)
        return BlockedJoin(driver: n, saving: saving, tick: tick, joiner: joiner, notifier: notifier, clock: clock, hotspot: hotspot)
    }

    private func driver(
        keychain: FakeKeychainStore,
        joiner: RecordingHotspotJoiner,
        notifier: RecordingNotifier,
        clock: FakeClock,
        hotspot: Locked<String> = Locked("Phone")
    ) -> NetworkFailover {
        NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            hotspotJoiner: joiner,
            notifier: notifier,
            wifiInterface: "en0",
            clock: { clock.now }
        ) {
            var config = Config()
            config.hotspotSSID = hotspot.value
            return config
        }
    }

    /// A join with no saved password is not a silent skip: the problem is
    /// published for the menu and notified once, not on every retry.
    func testMissingPasswordIsSurfacedOnceAndNoJoinIsAttempted() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: clock)
        let published = Locked<[HotspotPasswordProblem?]>([])
        n.onPasswordReport = { published.value.append($0?.problem) }

        await n.simulate(satisfied: false)
        for _ in 0..<3 {
            clock.advance(30)
            await n.fireTimer().value
        }

        XCTAssertEqual(joiner.calls, [])
        XCTAssertEqual(n.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .missing))
        XCTAssertEqual(published.value, [.missing])
        XCTAssertEqual(notifier.posts.map(\.title), ["Hotspot not joined"])
        XCTAssertEqual(notifier.posts.map(\.body), ["No hotspot password is saved. Enter it in Settings."])
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
        XCTAssertEqual(n.passwordReport?.problem, .unreadable)
        XCTAssertEqual(n.passwordReport?.problem.menuLine, "\u{26A0} Hotspot password unreadable by this build: enter it again in Settings")
        XCTAssertEqual(notifier.posts.map(\.body), [HotspotPasswordProblem.unreadable.explanation])
        XCTAssertTrue(HotspotPasswordProblem.unreadable.explanation.contains("Enter it again in Settings"))
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
        n.onPasswordReport = { published.value.append($0?.problem) }

        await n.joinHotspot()
        XCTAssertEqual(n.passwordReport?.problem, .missing)
        n.passwordChanged(.init(ssid: "Phone"), configuredSSID: "Phone")
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertEqual(published.value, [.missing, nil])

        try keychain.set(service: KeychainStore.service, account: "Phone", value: "pw")
        await n.joinHotspot()
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertEqual(joiner.calls.map(\.password), ["pw"])

        try keychain.delete(service: KeychainStore.service, account: "Phone")
        await n.joinHotspot()
        XCTAssertEqual(n.passwordReport?.problem, .missing)
        XCTAssertEqual(notifier.posts.count, 2, "the problem returned after a save, so it is notified again")
    }

    /// The user configures another hotspot during the outage. Its problem
    /// is reported for it, and notified once for it too: the notification
    /// about the first hotspot did not tell the user about this one.
    /// Going back to the first hotspot in the same outage notifies
    /// nothing new.
    func testAHotspotConfiguredDuringTheOutageIsNotifiedForItself() async throws {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Other Phone", value: "old build's secret")
        keychain.unreadable = ["\(KeychainStore.service)/Other Phone"]
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let hotspot = Locked("Phone")
        let n = driver(keychain: keychain, joiner: RecordingHotspotJoiner(), notifier: notifier, clock: clock, hotspot: hotspot)
        func tick() async {
            clock.advance(30)
            await n.fireTimer().value
        }

        await n.simulate(satisfied: false)
        await tick()
        hotspot.value = "Other Phone"
        await tick()
        await tick()

        XCTAssertEqual(n.passwordReport, HotspotPasswordReport(ssid: "Other Phone", problem: .unreadable))
        XCTAssertEqual(notifier.posts.map(\.body), [HotspotPasswordProblem.missing.explanation, HotspotPasswordProblem.unreadable.explanation])

        hotspot.value = "Phone"
        await tick()
        XCTAssertEqual(n.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .missing))
        XCTAssertEqual(notifier.posts.count, 2)
        n.stop()
    }

    /// A save in Settings for another SSID, one edited away while it
    /// waited, leaves the report about the hotspot configured now, and
    /// its notification, if the save did not remove that hotspot's item
    /// either. Any other save clears the report and re-arms the
    /// notification: one that removed the configured hotspot's item (the
    /// account the window loaded), one for the configured hotspot, and one
    /// whose report is about an SSID no longer configured.
    func testASaveClearsEveryReportButOneAboutTheConfiguredHotspotItDidNotStore() async throws {
        let notifier = RecordingNotifier()
        let n = driver(keychain: FakeKeychainStore(), joiner: RecordingHotspotJoiner(), notifier: notifier, clock: FakeClock(Date()))
        let phone = HotspotPasswordReport(ssid: "Phone", problem: .missing)

        await n.joinHotspot()
        n.passwordChanged(.init(ssid: "Other Phone"), configuredSSID: "Phone")
        XCTAssertEqual(n.passwordReport, phone)
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 1, "the report stood, and so did its notification")

        n.passwordChanged(.init(ssid: "Other Phone", removed: "Phone"), configuredSSID: "Phone")
        XCTAssertNil(n.passwordReport, "the save removed the reported hotspot's item")
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 2, "what the next read finds is notified afresh")

        n.passwordChanged(.init(ssid: "Phone"), configuredSSID: " Phone ")
        XCTAssertNil(n.passwordReport)
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 3)

        n.passwordChanged(.init(ssid: "Phone"), configuredSSID: "Other Phone")
        XCTAssertNil(n.passwordReport, "the save wrote the reported hotspot's item")
        await n.joinHotspot()
        n.passwordChanged(.init(ssid: "Other Phone"), configuredSSID: "Other Phone")
        XCTAssertNil(n.passwordReport, "the save may have moved the reported hotspot's item")
    }

    /// stop() ends the session: the problem goes (and with it the menu
    /// line), and the once-per-outage guard does not outlive the session.
    func testStopClearsTheProblemAndRearmsTheNotification() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: FakeClock(Date()))
        let published = Locked<[HotspotPasswordProblem?]>([])
        n.onPasswordReport = { published.value.append($0?.problem) }

        await n.joinHotspot()
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 1)
        n.stop()
        XCTAssertNil(n.passwordReport?.problem)
        XCTAssertEqual(published.value, [.missing, nil])
        await n.joinHotspot()
        XCTAssertEqual(notifier.posts.count, 2)
    }

    /// A second outage in the same session is notified again: recovery
    /// re-arms the once-per-outage guard.
    func testANewOutageAfterRecoveryIsNotifiedAgain() async throws {
        let joiner = RecordingHotspotJoiner()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let n = driver(keychain: FakeKeychainStore(), joiner: joiner, notifier: notifier, clock: clock)
        func skipped() -> Int { notifier.posts.filter { $0.title == "Hotspot not joined" }.count }

        await n.simulate(satisfied: false)
        for _ in 0..<2 {
            clock.advance(30)
            await n.fireTimer().value
        }
        XCTAssertEqual(skipped(), 1)

        clock.advance(30)
        await n.simulate(satisfied: true)
        XCTAssertEqual(skipped(), 1, "recovery itself reports nothing about the password")

        await n.simulate(satisfied: false)
        clock.advance(30)
        await n.fireTimer().value
        XCTAssertEqual(skipped(), 2)
        XCTAssertEqual(joiner.calls, [])
    }
}
