import Security
import XCTest
@testable import Insomnia

// MARK: - Fakes

/// Joiner double scripted per SSID: joins, finds nothing, or throws. An
/// optional gate holds a join until the test opens it; `onJoin` runs at
/// the start of each join.
final class ScriptedJoiner: HotspotJoining, @unchecked Sendable {
    enum Outcome: Sendable {
        case joins
        case notFound
        case fails
    }

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "association refused" }
    }

    private let lock = NSLock()
    private var _calls: [RecordingHotspotJoiner.Call] = []
    private var _outcomes: [String: Outcome]
    var calls: [RecordingHotspotJoiner.Call] { lock.withLock { _calls } }
    var joined: [String] { calls.map(\.ssid) }
    var gate: AsyncGate?
    var onJoin: (@Sendable (String) async -> Void)?

    init(_ outcomes: [String: Outcome] = [:]) {
        _outcomes = outcomes
    }

    func set(_ ssid: String, _ outcome: Outcome) {
        lock.withLock { _outcomes[ssid] = outcome }
    }

    func join(ssid: String, password: String, interfaceName: String) async throws -> Bool {
        lock.withLock { _calls.append(.init(ssid: ssid, password: password, interfaceName: interfaceName)) }
        await onJoin?(ssid)
        if let gate { await gate.wait() }
        switch lock.withLock({ _outcomes[ssid] ?? .notFound }) {
        case .joins: return true
        case .notFound: return false
        case .fails: throw Failure()
        }
    }

    private var _leaves = 0
    /// How often the Mac was taken off its network; `onLeave` runs each time.
    var leaves: Int { lock.withLock { _leaves } }
    var onLeave: (@Sendable () -> Void)?

    func leave(interfaceName: String) async throws {
        lock.withLock { _leaves += 1 }
        onLeave?()
    }
}

/// Scanner double: the current SSID and what each scan finds are set by
/// the test, and every call is recorded. Never touches CoreWLAN.
final class FakeHotspotScanner: HotspotScanning, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _current: String?
    private var _signal: [String: Int] = [:]
    private var _scans: [[String]] = []
    private var _fails = false
    private var _currentReads = 0
    var current: String? {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }
    /// RSSI by SSID that every scan finds.
    var signal: [String: Int] {
        get { lock.withLock { _signal } }
        set { lock.withLock { _signal = newValue } }
    }
    var fails: Bool {
        get { lock.withLock { _fails } }
        set { lock.withLock { _fails = newValue } }
    }
    /// The SSIDs each scan was asked about, in order.
    var scans: [[String]] { lock.withLock { _scans } }
    var currentReads: Int { lock.withLock { _currentReads } }

    func currentSSID(interfaceName: String) async -> String? {
        lock.withLock {
            _currentReads += 1
            return _current
        }
    }

    func signal(of ssids: [String], interfaceName: String) async throws -> [String: Int] {
        try lock.withLock {
            _scans.append(ssids)
            if _fails { throw Failure() }
            return _signal.filter { ssids.contains($0.key) }
        }
    }

    /// RSSI by SSID of the saved Wi-Fi networks every scan finds.
    var saved: [String: Int] {
        get { lock.withLock { _saved } }
        set { lock.withLock { _saved = newValue } }
    }
    private var _saved: [String: Int] = [:]
    private var _savedScans = 0
    /// How many scans for saved networks ran.
    var savedScans: Int { lock.withLock { _savedScans } }

    func savedSignal(excluding hotspots: [String], interfaceName: String) async throws -> [String: Int] {
        try lock.withLock {
            _savedScans += 1
            if _fails { throw Failure() }
            return _saved.filter { ssid, _ in !hotspots.contains { HotspotSSID.matches($0, ssid) } }
        }
    }

    func nearbySSIDs() async throws -> [String] {
        lock.withLock { _signal.keys.sorted() }
    }

    func cachedNearbySSIDs() async -> [String] { [] }
}

// MARK: - Config

final class HotspotPriorityConfigTests: XCTestCase {
    func testThePriorityListIsOffAndEmptyByDefault() throws {
        let fresh = Config()
        XCTAssertFalse(fresh.hotspotPriorityEnabled)
        XCTAssertEqual(fresh.priorityHotspots, [])
        XCTAssertTrue(fresh.hotspotSwitchUp)
        XCTAssertTrue(fresh.hotspotReturnToWiFi)
        XCTAssertFalse(fresh.aggressiveHotspotJoin)

        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"hotspotSSID":"Phone"}"#.utf8))
        XCTAssertFalse(old.hotspotPriorityEnabled, "a config.json from before the list keeps the single hotspot")
        XCTAssertEqual(old.priorityHotspots, [])
        XCTAssertTrue(old.hotspotSwitchUp)
        XCTAssertTrue(old.hotspotReturnToWiFi)
        XCTAssertFalse(old.aggressiveHotspotJoin, "a config.json from before the toggle waits for macOS")
        XCTAssertEqual(old.hotspotsToJoin, ["Phone"])
    }

    func testTheListRoundTrips() throws {
        var c = Config()
        c.hotspotPriorityEnabled = true
        c.priorityHotspots = ["Phone", "Tablet A", "Tablet B"]
        c.hotspotSwitchUp = false
        c.hotspotReturnToWiFi = false
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testTheHotspotsToJoinFollowTheToggle() {
        var c = Config()
        c.hotspotSSID = " Phone "
        c.priorityHotspots = ["Tablet A", " ", "Phone", "Tablet A ", "Tablet B"]
        XCTAssertEqual(c.hotspotsToJoin, ["Phone"], "off: the single hotspot")

        c.hotspotPriorityEnabled = true
        XCTAssertEqual(c.hotspotsToJoin, ["Tablet A", "Phone", "Tablet B"], "on: the list, trimmed, without blanks or repeats")

        c.priorityHotspots = []
        XCTAssertEqual(c.hotspotsToJoin, [], "on with an empty list: nothing, not the single hotspot")

        c.hotspotPriorityEnabled = false
        c.hotspotSSID = "  "
        XCTAssertEqual(c.hotspotsToJoin, [])
    }

    func testTurningTheListOnStartsItWithTheSingleHotspotOnce() {
        var c = Config()
        c.hotspotSSID = " Phone "
        c.setHotspotPriority(true)
        XCTAssertEqual(c.priorityHotspots, ["Phone"])
        XCTAssertEqual(c.hotspotsToJoin, ["Phone"])

        c.addPriorityHotspot("Tablet")
        c.setHotspotPriority(false)
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet"], "turning it off keeps the list")
        c.hotspotSSID = "Other Phone"
        c.setHotspotPriority(true)
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet"], "a list with hotspots on it is not replaced")

        var empty = Config()
        empty.setHotspotPriority(true)
        XCTAssertEqual(empty.priorityHotspots, [], "no single hotspot, nothing to start with")
    }

    func testAddingRemovingAndMoving() {
        var c = Config()
        c.addPriorityHotspot(" Phone ")
        c.addPriorityHotspot("Tablet A")
        c.addPriorityHotspot("Phone")
        c.addPriorityHotspot("  ")
        c.addPriorityHotspot("Tablet B")
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet A", "Tablet B"])

        c.movePriorityHotspot("Tablet B", by: -1)
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet B", "Tablet A"])
        c.movePriorityHotspot("Tablet B", by: -5)
        XCTAssertEqual(c.priorityHotspots, ["Tablet B", "Phone", "Tablet A"], "stops at the top")
        c.movePriorityHotspot("Tablet B", by: 9)
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet A", "Tablet B"], "stops at the bottom")
        c.movePriorityHotspot("Nobody", by: 1)
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet A", "Tablet B"])

        c.removePriorityHotspot(" Tablet A")
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet B"])

        c.addPriorityHotspot("Sam's iPad")
        c.addPriorityHotspot("Sam\u{2019}s iPad")
        XCTAssertEqual(c.priorityHotspots, ["Phone", "Tablet B", "Sam's iPad"], "one device, whichever apostrophe")
    }

    /// A hand-edited list with blanks and repeats moves as Settings shows
    /// it, not by the raw positions.
    func testAnEditCleansAHandEditedList() {
        var c = Config()
        c.priorityHotspots = ["Phone", "", "Phone ", "Tablet"]
        c.movePriorityHotspot("Tablet", by: -1)
        XCTAssertEqual(c.priorityHotspots, ["Tablet", "Phone"])
    }

    func testAnSSIDIsNamedByEitherSetting() {
        var c = Config()
        c.hotspotSSID = "Phone"
        c.priorityHotspots = ["Tablet "]
        XCTAssertTrue(c.namesHotspot(" Phone"))
        XCTAssertTrue(c.namesHotspot("Tablet"), "the list names it even while it is off")
        XCTAssertFalse(c.namesHotspot("Other"))
        XCTAssertFalse(c.namesHotspot(" "))
    }
}

// MARK: - Switch-up machine

final class SwitchUpMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let list = ["Phone", "Tablet A", "Tablet B"]

    func testNothingToScanForOffTheListOrOnTheTop() {
        var m = SwitchUpMachine()
        XCTAssertEqual(m.candidates(current: nil, hotspots: list, at: t0), [], "on no network, or the name is hidden")
        XCTAssertEqual(m.candidates(current: "Home", hotspots: list, at: t0), [], "a network off the list is left alone")
        XCTAssertEqual(m.candidates(current: "Phone", hotspots: list, at: t0), [], "already on the top hotspot")
        XCTAssertEqual(m.candidates(current: "Tablet B", hotspots: list, at: t0), ["Phone", "Tablet A"], "everything above, highest first")
        XCTAssertEqual(m.candidates(current: "Tablet A", hotspots: list, at: t0), ["Phone"])
    }

    func testAMoveNeedsTwoStrongScansInARow() {
        var m = SwitchUpMachine()
        let above = m.candidates(current: "Tablet B", hotspots: list, at: t0)
        XCTAssertNil(m.scanned(["Phone": -50], candidates: above), "one scan is not enough")
        XCTAssertNil(m.scanned([:], candidates: above), "a miss starts the count again")
        XCTAssertNil(m.scanned(["Phone": -50], candidates: above))
        XCTAssertNil(m.scanned(["Phone": -80], candidates: above), "a weak signal does not count")
        XCTAssertNil(m.scanned(["Phone": SightingCounter.minimumRSSI], candidates: above))
        XCTAssertEqual(m.scanned(["Phone": -60], candidates: above), "Phone")
    }

    func testTheHighestHotspotSeenEnoughWins() {
        var m = SwitchUpMachine()
        let above = m.candidates(current: "Tablet B", hotspots: list, at: t0)
        XCTAssertNil(m.scanned(["Tablet A": -40, "Phone": -50], candidates: above))
        XCTAssertEqual(m.scanned(["Tablet A": -40, "Phone": -50], candidates: above), "Phone", "both seen twice: the higher one")

        var later = SwitchUpMachine()
        let again = later.candidates(current: "Tablet B", hotspots: list, at: t0)
        XCTAssertNil(later.scanned(["Tablet A": -40], candidates: again))
        XCTAssertEqual(later.scanned(["Tablet A": -40, "Phone": -50], candidates: again), "Tablet A", "the phone has one sighting; the tablet above this one has two")
    }

    func testTheCountStartsAgainOnAnotherHotspot() {
        var m = SwitchUpMachine()
        var above = m.candidates(current: "Tablet B", hotspots: list, at: t0)
        XCTAssertNil(m.scanned(["Phone": -50], candidates: above))
        above = m.candidates(current: "Tablet A", hotspots: list, at: t0)
        XCTAssertEqual(m.sightings, [:], "the Mac moved: the old count is about another network")
        XCTAssertNil(m.scanned(["Phone": -50], candidates: above))
        m.forget()
        above = m.candidates(current: "Tablet A", hotspots: list, at: t0)
        XCTAssertNil(m.scanned(["Phone": -50], candidates: above), "forgotten after an outage")
    }

    func testAMoveCoolsDownWhetherOrNotItWorked() {
        var m = SwitchUpMachine()
        m.moving(at: t0)
        XCTAssertEqual(m.candidates(current: "Tablet B", hotspots: list, at: t0.addingTimeInterval(SightingCounter.cooldown - 1)), [])
        XCTAssertEqual(m.candidates(current: "Tablet B", hotspots: list, at: t0.addingTimeInterval(SightingCounter.cooldown)), ["Phone", "Tablet A"])
    }
}

final class HandBackMachineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Only the hotspot Insomnia joined is left; one picked by hand, or by
    /// macOS, is not. The name matches whichever apostrophe.
    func testOnlyTheHotspotInsomniaJoinedIsLeft() {
        var m = HandBackMachine()
        XCTAssertFalse(m.due(current: nil, joined: "Phone", at: t0), "on no network")
        XCTAssertFalse(m.due(current: "Phone", joined: nil, at: t0), "joined by hand")
        XCTAssertFalse(m.due(current: "Tablet A", joined: "Phone", at: t0), "joined by macOS")
        XCTAssertTrue(m.due(current: "Phone", joined: "Phone", at: t0))
        XCTAssertTrue(m.due(current: "Sam's iPhone", joined: "Sam\u{2019}s iPhone", at: t0))
    }

    func testAHandBackNeedsTwoStrongScansInARow() {
        var m = HandBackMachine()
        XCTAssertTrue(m.due(current: "Phone", joined: "Phone", at: t0))
        XCTAssertNil(m.scanned(["Home": -50]), "one scan is not enough")
        XCTAssertNil(m.scanned([:]), "a miss starts the count again")
        XCTAssertNil(m.scanned(["Home": -50]))
        XCTAssertNil(m.scanned(["Home": -80]), "a weak signal does not count")
        XCTAssertNil(m.scanned(["Home": SightingCounter.minimumRSSI]))
        XCTAssertEqual(m.scanned(["Home": -60]), "Home")
    }

    func testTheStrongestNetworkSeenEnoughWins() {
        var m = HandBackMachine()
        _ = m.due(current: "Phone", joined: "Phone", at: t0)
        XCTAssertNil(m.scanned(["Home": -60, "Office": -45]))
        XCTAssertEqual(m.scanned(["Home": -60, "Office": -45]), "Office")

        var later = HandBackMachine()
        _ = later.due(current: "Phone", joined: "Phone", at: t0)
        XCTAssertNil(later.scanned(["Home": -60]))
        XCTAssertEqual(later.scanned(["Home": -60, "Office": -45]), "Home", "the stronger one has one sighting")
    }

    func testTheCountStartsAgainOnAnotherHotspot() {
        var m = HandBackMachine()
        _ = m.due(current: "Tablet A", joined: "Tablet A", at: t0)
        XCTAssertNil(m.scanned(["Home": -50]))
        _ = m.due(current: "Phone", joined: "Phone", at: t0)
        XCTAssertEqual(m.sightings, [:])
        XCTAssertNil(m.scanned(["Home": -50]))
    }

    func testAHandBackCoolsDownWhetherOrNotItWorked() {
        var m = HandBackMachine()
        m.handingBack(at: t0)
        XCTAssertFalse(m.due(current: "Phone", joined: "Phone", at: t0.addingTimeInterval(SightingCounter.cooldown - 1)))
        XCTAssertTrue(m.due(current: "Phone", joined: "Phone", at: t0.addingTimeInterval(SightingCounter.cooldown)))
    }
}

// MARK: - Failover across the list

@MainActor
final class HotspotPriorityFailoverTests: XCTestCase {
    var home: TempHome!

    override func setUp() async throws { home = TempHome() }
    override func tearDown() async throws { home.destroy() }

    private struct Rig {
        let driver: NetworkFailover
        let joiner: ScriptedJoiner
        let scanner: FakeHotspotScanner
        let waker: FakeHotspotWaker
        let notifier: RecordingNotifier
        let keychain: FakeKeychainStore
        let clock: FakeClock
        let config: Locked<Config>
    }

    /// Three hotspots on the list, each with a saved password, and the
    /// priority list on.
    private func rig(_ hotspots: [String] = ["Phone", "Tablet A", "Tablet B"]) throws -> Rig {
        let keychain = FakeKeychainStore()
        for ssid in hotspots {
            try keychain.set(service: KeychainStore.service, account: ssid, value: "pw-\(ssid)")
        }
        var c = Config()
        c.hotspotPriorityEnabled = true
        c.priorityHotspots = hotspots
        let config = Locked(c)
        let joiner = ScriptedJoiner()
        let scanner = FakeHotspotScanner()
        let waker = FakeHotspotWaker()
        let notifier = RecordingNotifier()
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let driver = NetworkFailover(
            paths: home.paths,
            keychain: keychain,
            hotspotJoiner: joiner,
            scanner: scanner,
            waker: waker,
            notifier: notifier,
            wifiInterface: "en0",
            clock: { clock.now }
        ) { config.value }
        driver.wokenJoinWait = .zero
        return Rig(driver: driver, joiner: joiner, scanner: scanner, waker: waker, notifier: notifier, keychain: keychain, clock: clock, config: config)
    }

    /// No device is near over Bluetooth, so every hotspot is tried in the
    /// order of the list, each with its own password, until one joins. No
    /// Wi-Fi scan comes first: one did, and the joins after it failed with
    /// "Resource busy".
    func testHotspotsAreTriedInOrderUntilOneJoins() async throws {
        let r = try rig()
        r.joiner.set("Tablet A", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.joiner.calls, [
            .init(ssid: "Phone", password: "pw-Phone", interfaceName: "en0"),
            .init(ssid: "Tablet A", password: "pw-Tablet A", interfaceName: "en0"),
        ])
        XCTAssertEqual(r.scanner.scans, [], "no scan before the joins")
        XCTAssertEqual(r.waker.woken, [])
        XCTAssertNil(r.driver.passwordReport)
    }

    /// The field run: the hotspots were off the air. The tablet left in
    /// the car is near over Bluetooth, so it is woken, ahead of the
    /// hotspots that are gone, and joined with what it hands over.
    func testANearbyDeviceIsWokenAndJoinedWithWhatItHandsOver() async throws {
        let r = try rig()
        r.waker.near = ["Tablet B"]
        r.waker.answers = ["Tablet B": HotspotCredentials(ssid: "Tablet B", password: "handed over")]
        r.joiner.set("Tablet B", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.waker.woken, ["Tablet B"])
        XCTAssertEqual(r.joiner.calls, [.init(ssid: "Tablet B", password: "handed over", interfaceName: "en0")])
    }

    /// Several near: the list's order decides, and only the first is woken.
    func testThePriorityOrderDecidesAmongNearbyDevices() async throws {
        let r = try rig()
        r.waker.near = ["Tablet B", "Tablet A"]
        r.waker.answers = [
            "Tablet A": HotspotCredentials(ssid: "Tablet A", password: "a"),
            "Tablet B": HotspotCredentials(ssid: "Tablet B", password: "b"),
        ]
        r.joiner.set("Tablet A", .joins)
        r.joiner.set("Tablet B", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.waker.woken, ["Tablet A"])
        XCTAssertEqual(r.joiner.joined, ["Tablet A"])
    }

    /// A woken hotspot takes a few seconds to come on the air: the scan
    /// that misses it is tried again.
    func testAWokenHotspotIsLookedForAgainWhileItComesUp() async throws {
        let r = try rig()
        r.waker.near = ["Phone"]
        r.waker.answers = ["Phone": HotspotCredentials(ssid: "Phone", password: "handed over")]
        let joiner = r.joiner
        r.joiner.onJoin = { ssid in if joiner.calls.count == 2 { joiner.set(ssid, .joins) } }

        await r.driver.joinHotspot()

        XCTAssertEqual(r.joiner.joined, ["Phone", "Phone"])
    }

    /// A woken hotspot never found goes to the next on the list, after
    /// `wokenJoinTries` looks.
    func testAWokenHotspotNeverFoundMovesOn() async throws {
        let r = try rig()
        r.waker.near = ["Phone"]
        r.waker.answers = ["Phone": HotspotCredentials(ssid: "Phone", password: "handed over")]
        r.joiner.set("Tablet A", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.joiner.joined, ["Phone", "Phone", "Phone", "Tablet A"])
    }

    /// A device near that does not answer the wake is joined with its
    /// saved password, as before.
    func testADeviceThatDoesNotWakeIsJoinedWithItsSavedPassword() async throws {
        let r = try rig()
        r.waker.near = ["Tablet A"]
        r.joiner.set("Tablet A", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.waker.woken, ["Tablet A"])
        XCTAssertEqual(r.joiner.calls, [.init(ssid: "Tablet A", password: "pw-Tablet A", interfaceName: "en0")])
    }

    /// The field run's iPad: listed with the straight apostrophe, named
    /// with the curly one. It is still found near, woken, and joined by
    /// the name it hands over.
    func testAListedNameMatchesItsDeviceWhicheverApostrophe() async throws {
        let r = try rig(["Owner's Tablet"])
        r.waker.near = ["Owner\u{2019}s Tablet"]
        r.waker.answers = ["Owner\u{2019}s Tablet": HotspotCredentials(ssid: "Owner\u{2019}s Tablet", password: "handed over")]
        r.joiner.set("Owner\u{2019}s Tablet", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.waker.woken, ["Owner's Tablet"])
        XCTAssertEqual(r.joiner.joined, ["Owner\u{2019}s Tablet"])
    }

    func testApostrophesFold() {
        XCTAssertTrue(HotspotSSID.matches("Owner's Tablet", "Owner\u{2019}s Tablet"))
        XCTAssertTrue(HotspotSSID.matches(" Owner\u{2018}s Tablet", "Owner's Tablet"))
        XCTAssertFalse(HotspotSSID.matches("Owners Tablet", "Owner's Tablet"))
        XCTAssertEqual(HotspotSSID.otherApostrophe("Owner's Tablet"), "Owner\u{2019}s Tablet")
        XCTAssertEqual(HotspotSSID.otherApostrophe("Owner\u{2019}s Tablet"), "Owner's Tablet")
        XCTAssertNil(HotspotSSID.otherApostrophe("NotePad"))
    }

    /// A join that throws (a refused association) moves on to the next
    /// hotspot rather than ending the attempt.
    func testARefusedJoinMovesOnToTheNextHotspot() async throws {
        let r = try rig()
        r.joiner.set("Phone", .fails)
        r.joiner.set("Tablet A", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.joiner.joined, ["Phone", "Tablet A"])
    }

    /// The top hotspot's password is unreadable and the next one has none:
    /// both are skipped, the third joins. Only the unreadable one is a
    /// problem: the list needs no saved password, since a woken device
    /// hands its own over. It is reported and notified once per outage
    /// under its own name, and the retries notify nothing new.
    func testAnUnreadablePasswordIsReportedAndAMissingOneSkippedQuietly() async throws {
        let r = try rig()
        r.keychain.unreadable = ["\(KeychainStore.service)/Phone"]
        try r.keychain.delete(service: KeychainStore.service, account: "Tablet A")
        r.joiner.set("Tablet B", .joins)
        let published = Locked<[HotspotPasswordReport?]>([])
        r.driver.onPasswordReport = { published.value.append($0) }

        await r.driver.simulate(satisfied: false)
        for _ in 0..<2 {
            r.clock.advance(30)
            await r.driver.fireTimer().value
        }

        XCTAssertEqual(r.joiner.joined, ["Tablet B", "Tablet B"])
        XCTAssertEqual(r.driver.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .unreadable))
        XCTAssertEqual(published.value, [HotspotPasswordReport(ssid: "Phone", problem: .unreadable)])
        XCTAssertEqual(r.notifier.posts.map(\.title), ["Hotspot \"Phone\" not joined"])
        XCTAssertEqual(r.notifier.posts.map(\.body), [HotspotPasswordProblem.unreadable.explanation])
        r.driver.stop()
    }

    /// Once the top hotspot's password reads again, its report goes; a
    /// report about another hotspot the pass did not reach stays.
    func testAReadablePasswordEndsOnlyItsOwnReport() async throws {
        let r = try rig()
        r.keychain.unreadable = ["\(KeychainStore.service)/Tablet A"]
        r.joiner.set("Tablet B", .joins)
        await r.driver.joinHotspot()
        XCTAssertEqual(r.driver.passwordReport, HotspotPasswordReport(ssid: "Tablet A", problem: .unreadable))

        r.joiner.set("Phone", .joins)
        await r.driver.joinHotspot()
        XCTAssertEqual(r.driver.passwordReport, HotspotPasswordReport(ssid: "Tablet A", problem: .unreadable), "the pass stopped at the phone and never read the tablet")

        r.keychain.unreadable = []
        r.joiner.set("Phone", .notFound)
        r.joiner.set("Tablet A", .joins)
        await r.driver.joinHotspot()
        XCTAssertNil(r.driver.passwordReport)
    }

    /// A hotspot removed in Settings while an earlier one was being
    /// joined is not tried; the rest of the list still is.
    func testAHotspotRemovedDuringThePassIsSkipped() async throws {
        let r = try rig()
        let config = r.config
        r.joiner.onJoin = { ssid in
            guard ssid == "Phone" else { return }
            await MainActor.run { config.value.removePriorityHotspot("Tablet A") }
        }
        r.joiner.set("Tablet B", .joins)

        await r.driver.joinHotspot()

        XCTAssertEqual(r.joiner.joined, ["Phone", "Tablet B"])
    }

    /// Wi-Fi comes back while the first hotspot's join runs (macOS joined
    /// something itself): the next hotspot is not joined over it.
    func testRecoveryDuringAJoinEndsThePass() async throws {
        let r = try rig()
        let driver = r.driver
        r.joiner.onJoin = { ssid in
            guard ssid == "Phone" else { return }
            await Task { @MainActor in await driver.simulate(satisfied: true) }.value
        }
        await driver.simulate(satisfied: false)
        r.clock.advance(30)
        await driver.fireTimer().value

        XCTAssertEqual(r.joiner.joined, ["Phone"])
        XCTAssertNil(driver.retryTimer)
        driver.stop()
    }

    /// With the list off, one hotspot: no scan before the join, and the
    /// notification keeps its wording without a name.
    func testTheSingleHotspotJoinsWithoutAScan() async throws {
        let r = try rig()
        r.config.value.hotspotPriorityEnabled = false
        r.config.value.hotspotSSID = "Phone"
        try r.keychain.delete(service: KeychainStore.service, account: "Phone")

        await r.driver.joinHotspot()

        XCTAssertEqual(r.scanner.scans, [])
        XCTAssertEqual(r.notifier.posts.map(\.title), ["Hotspot not joined"])
        XCTAssertEqual(r.driver.passwordReport, HotspotPasswordReport(ssid: "Phone", problem: .missing))
    }

    /// The list on with one hotspot behaves like the single hotspot.
    func testAListOfOneNeedsNoScan() async throws {
        let r = try rig(["Phone"])
        r.joiner.set("Phone", .joins)
        await r.driver.joinHotspot()
        XCTAssertEqual(r.scanner.scans, [])
        XCTAssertEqual(r.joiner.joined, ["Phone"])
    }

    // MARK: Switching up

    /// Off by default: no read of the current network, no scan.
    func testNoSwitchUpCheckWithTheListOffOrTheMoveOff() async throws {
        let r = try rig()
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]

        r.config.value.hotspotSwitchUp = false
        r.config.value.hotspotReturnToWiFi = false
        await r.driver.checkHotspots().value
        r.config.value.hotspotSwitchUp = true
        r.config.value.hotspotReturnToWiFi = true
        r.config.value.hotspotPriorityEnabled = false
        await r.driver.checkHotspots().value

        XCTAssertEqual(r.scanner.currentReads, 0)
        XCTAssertEqual(r.scanner.scans, [])
        XCTAssertEqual(r.joiner.calls, [])
    }

    /// On the top hotspot, or on a network off the list, a check reads the
    /// current SSID and scans nothing.
    func testNoScanOnTheTopHotspotOrOffTheList() async throws {
        let r = try rig()
        for current in ["Phone", "Home Wi-Fi", nil] as [String?] {
            r.scanner.current = current
            await r.driver.checkHotspots().value
        }
        XCTAssertEqual(r.scanner.currentReads, 3)
        XCTAssertEqual(r.scanner.scans, [])
    }

    /// You walk back to the car with the phone while the Mac is on the
    /// tablet: the second check that finds the phone moves the Mac to it,
    /// and the next check inside the cooldown scans nothing.
    func testTheMacMovesUpOnceTheHigherHotspotIsSeenTwice() async throws {
        let r = try rig()
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -55]
        r.joiner.set("Phone", .joins)

        await r.driver.checkHotspots().value
        XCTAssertEqual(r.joiner.calls, [], "one sighting is not enough")
        r.clock.advance(NetworkFailover.hotspotCheckInterval)
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.joiner.calls, [.init(ssid: "Phone", password: "pw-Phone", interfaceName: "en0")])
        XCTAssertEqual(r.scanner.scans, [["Phone", "Tablet A"], ["Phone", "Tablet A"]])

        r.scanner.current = "Tablet B"
        r.clock.advance(NetworkFailover.hotspotCheckInterval)
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.scanner.scans.count, 2, "cooling down: no scan")
        XCTAssertFalse(r.driver.changingNetwork)
    }

    /// During an outage the failover owns the radio: no switch-up check.
    func testNoSwitchUpDuringAnOutage() async throws {
        let r = try rig()
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]
        await r.driver.simulate(satisfied: false)
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.scanner.scans, [])
        XCTAssertEqual(r.joiner.calls, [])
        r.driver.stop()
    }

    /// The higher hotspot's password cannot be read: no join, so the Mac
    /// stays online where it is.
    func testNoMoveWithoutTheHigherHotspotsPassword() async throws {
        let r = try rig()
        try r.keychain.delete(service: KeychainStore.service, account: "Phone")
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.joiner.calls, [])
    }

    /// The move's association is refused and leaves the Mac on no
    /// network: it goes straight back to the hotspot it was on.
    func testARefusedMoveRejoinsTheHotspotItLeft() async throws {
        let r = try rig()
        let scanner = r.scanner
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]
        r.joiner.set("Phone", .fails)
        r.joiner.set("Tablet B", .joins)
        r.joiner.onJoin = { ssid in if ssid == "Phone" { scanner.current = nil } }

        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value

        XCTAssertEqual(r.joiner.calls, [
            .init(ssid: "Phone", password: "pw-Phone", interfaceName: "en0"),
            .init(ssid: "Tablet B", password: "pw-Tablet B", interfaceName: "en0"),
        ])
    }

    /// A refused move that left the Mac where it was rejoins nothing.
    func testARefusedMoveThatStayedOnlineRejoinsNothing() async throws {
        let r = try rig()
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]
        r.joiner.set("Phone", .fails)

        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value

        XCTAssertEqual(r.joiner.joined, ["Phone"])
    }

    /// While a move joins, a failover tick does not start a second join.
    func testAFailoverJoinWaitsForAMove() async throws {
        let r = try rig()
        let gate = AsyncGate()
        r.joiner.gate = gate
        r.joiner.set("Phone", .joins)
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]

        await r.driver.checkHotspots().value
        let moving = r.driver.checkHotspots()
        await gate.waitUntilStarted()
        XCTAssertTrue(r.driver.changingNetwork)
        await r.driver.joinHotspot()
        XCTAssertEqual(r.joiner.joined, ["Phone"], "no second join while the move runs")

        await gate.open()
        await moving.value
        XCTAssertFalse(r.driver.changingNetwork)
    }

    /// The switch-up timer exists only while the driver runs with the list
    /// and switch-up on, so a session without them gets no extra wake.
    /// The path monitor only observes; the joiner and scanner are fakes.
    func testTheSwitchUpTimerRunsOnlyWithTheFeatureOn() async throws {
        let r = try rig()
        r.config.value.hotspotPriorityEnabled = false
        await r.driver.start()
        XCTAssertNil(r.driver.hotspotCheckTimer, "the list is off")

        r.config.value.hotspotPriorityEnabled = true
        r.driver.syncHotspotChecks()
        XCTAssertNotNil(r.driver.hotspotCheckTimer)
        r.config.value.hotspotSwitchUp = false
        r.driver.syncHotspotChecks()
        XCTAssertNotNil(r.driver.hotspotCheckTimer, "the hand-back still checks")
        r.config.value.hotspotReturnToWiFi = false
        r.driver.syncHotspotChecks()
        XCTAssertNil(r.driver.hotspotCheckTimer, "switch-up and the hand-back are off")
        r.config.value.hotspotReturnToWiFi = true
        r.driver.syncHotspotChecks()
        XCTAssertNotNil(r.driver.hotspotCheckTimer)

        r.driver.stop()
        XCTAssertNil(r.driver.hotspotCheckTimer)
        r.driver.syncHotspotChecks()
        XCTAssertNil(r.driver.hotspotCheckTimer, "a stopped driver starts no timer")
    }

    /// stop() ends the session: the switch-up state goes with it.
    func testStopResetsTheSwitchUp() async throws {
        let r = try rig()
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.driver.switchUp.sightings, ["Phone": 1])
        r.driver.stop()
        XCTAssertEqual(r.driver.switchUp, SwitchUpMachine())
        XCTAssertNil(r.driver.hotspotCheckTimer)
    }

    // MARK: Handing back to saved Wi-Fi

    /// The failover joins `ssid`, so it is the hotspot Insomnia joined.
    private func joined(_ r: Rig, _ ssid: String) async {
        r.joiner.set(ssid, .joins)
        await r.driver.joinHotspot()
        r.scanner.current = ssid
        XCTAssertEqual(r.driver.joinedHotspot, ssid)
    }

    /// You get home with the Mac on the phone: the second check that finds
    /// the home network leaves the hotspot, and joins nothing, since
    /// macOS rejoins the saved network itself.
    func testTheMacLeavesItsHotspotOnceASavedNetworkIsSeenTwice() async throws {
        let r = try rig()
        await joined(r, "Phone")
        let joins = r.joiner.calls.count
        r.scanner.saved = ["Home": -55]

        await r.driver.checkHotspots().value
        XCTAssertEqual(r.joiner.leaves, 0, "one sighting is not enough")
        r.clock.advance(NetworkFailover.hotspotCheckInterval)
        await r.driver.checkHotspots().value

        XCTAssertEqual(r.joiner.leaves, 1)
        XCTAssertEqual(r.joiner.calls.count, joins, "no join: macOS rejoins Home")
        XCTAssertNil(r.driver.joinedHotspot)
        XCTAssertEqual(r.driver.handingBack?.network, "Home")
        XCTAssertFalse(r.driver.changingNetwork)
    }

    /// A hotspot joined by hand, or by macOS, is left alone: no scan.
    func testAHotspotInsomniaDidNotJoinIsLeftAlone() async throws {
        let r = try rig()
        r.scanner.current = "Phone"
        r.scanner.saved = ["Home": -40]
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.scanner.savedScans, 0)
        XCTAssertEqual(r.joiner.leaves, 0)
    }

    /// Off: no scan for saved networks, though switch-up still runs.
    func testNoHandBackWithItOff() async throws {
        let r = try rig()
        await joined(r, "Phone")
        r.config.value.hotspotReturnToWiFi = false
        r.scanner.saved = ["Home": -40]
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.scanner.savedScans, 0)
        XCTAssertEqual(r.joiner.leaves, 0)
    }

    /// The listed hotspots are never a saved network to go back to.
    func testAListedHotspotIsNotASavedNetwork() async throws {
        let r = try rig()
        await joined(r, "Tablet A")
        r.scanner.saved = ["Phone": -40]
        r.config.value.hotspotSwitchUp = false
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.scanner.savedScans, 2)
        XCTAssertEqual(r.joiner.leaves, 0)
    }

    /// On a lower hotspot with home and a higher hotspot both in range,
    /// the Mac goes home rather than up the list.
    func testASavedNetworkBeatsAHigherHotspot() async throws {
        let r = try rig()
        r.joiner.set("Phone", .notFound)
        await joined(r, "Tablet A")
        let joins = r.joiner.calls.count
        r.scanner.signal = ["Phone": -40]
        r.scanner.saved = ["Home": -50]

        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value

        XCTAssertEqual(r.joiner.leaves, 1)
        XCTAssertEqual(r.joiner.calls.count, joins, "no move to the phone")
    }

    /// After a hand-back the failover gives macOS its time to rejoin the
    /// saved network, then joins a hotspot if the Mac is still offline.
    func testTheFailoverWaitsForMacOSAfterAHandBack() async throws {
        let r = try rig()
        await joined(r, "Phone")
        r.scanner.saved = ["Home": -50]
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.joiner.leaves, 1)
        let joins = r.joiner.calls.count

        r.clock.advance(HandBackMachine.grace - 1)
        await r.driver.joinHotspot()
        XCTAssertEqual(r.joiner.calls.count, joins, "held while macOS rejoins")

        r.clock.advance(1)
        await r.driver.joinHotspot()
        XCTAssertEqual(r.joiner.calls.count, joins + 1, "macOS did not rejoin: the failover takes over")
        XCTAssertNil(r.driver.handingBack)
        XCTAssertEqual(r.driver.joinedHotspot, "Phone")
    }

    /// The outage of a hand-back ends on the saved network: nothing of the
    /// hand-back is left. Ended on the hotspot again, it is still
    /// Insomnia's, for another try after the cooldown.
    func testTheRecoveryAfterAHandBackSaysWhereTheMacLanded() async throws {
        for landed in ["Home", "Phone"] {
            let r = try rig()
            await joined(r, "Phone")
            r.scanner.saved = ["Home": -50]
            r.joiner.onLeave = { [scanner = r.scanner] in scanner.current = nil }
            await r.driver.checkHotspots().value
            await r.driver.checkHotspots().value
            await r.driver.simulate(satisfied: false)
            r.scanner.current = landed
            await r.driver.simulate(satisfied: true)

            XCTAssertNil(r.driver.handingBack)
            XCTAssertEqual(r.driver.joinedHotspot, landed == "Phone" ? "Phone" : nil)
            r.clock.advance(NetworkFailover.hotspotCheckInterval)
            let scans = r.scanner.savedScans
            await r.driver.checkHotspots().value
            XCTAssertEqual(r.scanner.savedScans, scans, "home: nothing to leave; the phone: cooling down")
            r.driver.stop()
        }
    }

    func testStopResetsTheHandBack() async throws {
        let r = try rig()
        await joined(r, "Phone")
        r.scanner.saved = ["Home": -50]
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        r.driver.stop()
        XCTAssertEqual(r.driver.handBack, HandBackMachine())
        XCTAssertNil(r.driver.handingBack)
    }

    /// The field miss of 2026-10-19: Insomnia joined the phone, then was
    /// reinstalled. The next session, in a new process, still knows it
    /// joined the phone, so it hands back to home Wi-Fi.
    func testTheJoinedHotspotOutlivesTheSessionAndTheApp() async throws {
        let r = try rig()
        await joined(r, "Phone")
        r.driver.stop()
        XCTAssertEqual(r.driver.joinedHotspot, "Phone", "the session ended; the Mac is still on the phone")

        let next = NetworkFailover(paths: home.paths, keychain: r.keychain, hotspotJoiner: r.joiner, scanner: r.scanner, waker: r.waker, notifier: r.notifier, wifiInterface: "en0", clock: { r.clock.now }) { r.config.value }
        XCTAssertEqual(next.joinedHotspot, "Phone")
        r.scanner.saved = ["Home": -50]
        await next.checkHotspots().value
        await next.checkHotspots().value
        XCTAssertEqual(r.joiner.leaves, 1)
        XCTAssertNil(NetworkFailover(paths: home.paths, notifier: r.notifier) { r.config.value }.joinedHotspot, "the hand-back clears the file")
    }

    /// Seen on a network that is not a listed hotspot, the Mac has left
    /// the one Insomnia joined: a later manual join of it is left alone.
    func testTheJoinedHotspotIsForgottenOnAnotherNetwork() async throws {
        let r = try rig()
        await joined(r, "Phone")
        r.scanner.current = "Home"
        await r.driver.checkHotspots().value
        XCTAssertNil(r.driver.joinedHotspot)

        r.scanner.current = "Tablet A"
        await joined(r, "Phone")
        r.scanner.current = "Tablet A"
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.driver.joinedHotspot, "Phone", "on another listed hotspot: kept")
    }

    // MARK: Passwords handed over

    /// A device woken once this session is joined later with what it
    /// handed over, with no saved password and no Bluetooth.
    func testAHandedOverPasswordServesTheSessionWithoutTheKeychain() async throws {
        let r = try rig(["Phone"])
        try r.keychain.delete(service: KeychainStore.service, account: "Phone")
        r.waker.near = ["Phone"]
        r.waker.answers = ["Phone": HotspotCredentials(ssid: "Phone", password: "handed")]
        r.joiner.set("Phone", .joins)
        await r.driver.joinHotspot()

        r.waker.near = []
        await r.driver.joinHotspot()

        XCTAssertEqual(r.joiner.calls.map(\.password), ["handed", "handed"])
        XCTAssertNil(r.driver.passwordReport)
        XCTAssertEqual(r.notifier.posts.count, 0)

        r.driver.stop()
        await r.driver.joinHotspot()
        XCTAssertEqual(r.joiner.calls.count, 2, "stop() forgets what was handed over")
    }

    /// A move up the list wakes the higher device for its password: no
    /// saved password needed.
    func testAMoveWakesTheHigherDevice() async throws {
        let r = try rig()
        try r.keychain.delete(service: KeychainStore.service, account: "Phone")
        r.waker.near = ["Phone"]
        r.waker.answers = ["Phone": HotspotCredentials(ssid: "Phone", password: "handed")]
        r.scanner.current = "Tablet B"
        r.scanner.signal = ["Phone": -40]
        r.joiner.set("Phone", .joins)

        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value

        XCTAssertEqual(r.waker.woken, ["Phone"])
        XCTAssertEqual(r.joiner.calls, [.init(ssid: "Phone", password: "handed", interfaceName: "en0")])
        XCTAssertEqual(r.driver.joinedHotspot, "Phone")
    }

    /// A device that handed over its name with the curly apostrophe is
    /// still the list's lower hotspot, typed with the straight one: the
    /// Mac moves up from it.
    func testTheMoveUpMatchesEitherApostrophe() async throws {
        let r = try rig(["Phone", "Sam's iPad"])
        r.scanner.current = "Sam\u{2019}s iPad"
        r.scanner.signal = ["Phone": -40]
        r.joiner.set("Phone", .joins)

        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value

        XCTAssertEqual(r.joiner.calls.map(\.ssid), ["Phone"])
    }

    /// A saved network macOS did not rejoin after a hand-back is not
    /// handed back to again this session; the next session tries again.
    func testASavedNetworkMacOSDidNotRejoinIsLeftAloneAfterwards() async throws {
        let r = try rig()
        await joined(r, "Phone")
        r.scanner.saved = ["Home": -50]
        await r.driver.checkHotspots().value
        await r.driver.checkHotspots().value
        XCTAssertEqual(r.joiner.leaves, 1)

        r.clock.advance(HandBackMachine.grace)
        await r.driver.joinHotspot()
        XCTAssertEqual(r.driver.refusedHandBacks, ["Home"])
        XCTAssertEqual(r.driver.joinedHotspot, "Phone")

        r.clock.advance(SightingCounter.cooldown)
        for _ in 0..<3 { await r.driver.checkHotspots().value }
        XCTAssertEqual(r.joiner.leaves, 1, "no second hand-back to Home")

        r.driver.stop()
        XCTAssertEqual(r.driver.refusedHandBacks, [])
    }

    /// The record of the hotspot Insomnia joined outlives the session; a
    /// new one that starts on another network forgets it, so its first
    /// outage waits for macOS.
    func testASessionStartingOffTheJoinedHotspotForgetsIt() async throws {
        let r = try rig()
        await joined(r, "Phone")
        r.driver.stop()
        r.scanner.current = "Home"

        await r.driver.start()
        XCTAssertNil(r.driver.joinedHotspot)
        r.driver.stop()
    }

    // MARK: Waiting for macOS

    private func firstJoin(_ r: Rig) async -> TimeInterval? {
        let start = r.clock.now
        await r.driver.simulate(satisfied: false)
        return r.driver.machine.nextAttemptAt?.timeIntervalSince(start)
    }

    /// The home blips of 2026-10-20: off a hotspot Insomnia joined, macOS
    /// gets its time to rejoin before a hotspot is woken.
    func testAnOutageOffInsomniasHotspotWaitsForMacOS() async throws {
        let r = try rig()
        let first = await firstJoin(r)
        XCTAssertEqual(first, FailoverMachine.patientDelay)

        r.clock.advance(FailoverMachine.initialDelay)
        await r.driver.fireTimer().value
        XCTAssertEqual(r.waker.woken, [], "nothing woken while macOS may rejoin")
        XCTAssertEqual(r.joiner.calls, [])
        r.driver.stop()
    }

    /// The hotspot Insomnia joined dropping, or the aggressive join, gets
    /// the next hotspot after 5 s: macOS has nothing of its own to rejoin.
    func testAnOutageOnInsomniasHotspotOrTheAggressiveJoinStartsAtOnce() async throws {
        let r = try rig()
        await joined(r, "Phone")
        let afterHotspot = await firstJoin(r)
        XCTAssertEqual(afterHotspot, FailoverMachine.initialDelay)
        r.driver.stop()

        let aggressive = try rig()
        aggressive.config.value.aggressiveHotspotJoin = true
        let afterWiFi = await firstJoin(aggressive)
        XCTAssertEqual(afterWiFi, FailoverMachine.initialDelay)
        aggressive.driver.stop()
    }

    /// An outage that ends on another network logs that network by its
    /// tag, never its name, and the Mac has left the hotspot Insomnia
    /// joined: the next outage waits for macOS again.
    func testTheRecoveryLogsATagAndForgetsTheHotspotLeft() async throws {
        let r = try rig()
        await joined(r, "Phone")
        let name = "Home-\(UUID().uuidString)"
        await r.driver.simulate(satisfied: false)
        r.scanner.current = name
        await r.driver.simulate(satisfied: true)

        XCTAssertNil(r.driver.joinedHotspot)
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertFalse(log.contains(name), "the network's name reached insomnia.log")
        XCTAssertTrue(log.contains("back online on \(NetworkTag.load(home.paths)(name))"), log)
        let next = await firstJoin(r)
        XCTAssertEqual(next, FailoverMachine.patientDelay)
        r.driver.stop()
    }

    /// Back on a listed hotspot, the line says which one on the list.
    func testTheRecoveryOnAListedHotspotSaysItsPlace() async throws {
        let r = try rig()
        await joined(r, "Tablet A")
        await r.driver.simulate(satisfied: false)
        await r.driver.simulate(satisfied: true)

        XCTAssertEqual(r.driver.joinedHotspot, "Tablet A")
        let log = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("back online on \(NetworkTag.load(home.paths)("Tablet A")), hotspot 2 of 3"), log)
        r.driver.stop()
    }
}

final class NetworkTagTests: XCTestCase {
    var home: TempHome!

    override func setUp() { home = TempHome() }
    override func tearDown() { home.destroy() }

    func testATagIsShortStableAndNamesNothing() {
        let tag = NetworkTag.load(home.paths)
        let t = tag("Home Wi-Fi")
        XCTAssertNotNil(t.wholeMatch(of: /network [0-9a-f]{8}/), t)
        XCTAssertEqual(tag("Home Wi-Fi"), t)
        XCTAssertNotEqual(tag("Office"), t)
        XCTAssertEqual(tag("Sam\u{2019}s iPhone"), tag("Sam's iPhone"), "either apostrophe")
    }

    /// The key is kept, so tags match across launches, and is the
    /// install's own, so another Mac tags the same network differently.
    func testTheKeyLastsAndIsTheInstallsOwn() throws {
        XCTAssertEqual(NetworkTag.load(home.paths)("Home"), NetworkTag.load(home.paths)("Home"))
        let other = TempHome()
        defer { other.destroy() }
        XCTAssertNotEqual(NetworkTag.load(other.paths)("Home"), NetworkTag.load(home.paths)("Home"))
        let mode = try FileManager.default.attributesOfItem(atPath: home.paths.networkTagKeyFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
}

// MARK: - Reports and the menu

final class HotspotPriorityReportTests: XCTestCase {
    func testTheMenuLineNamesTheHotspotOnlyWhenThereAreSeveral() {
        var c = Config()
        c.hotspotSSID = "Phone"
        let report = HotspotPasswordReport(ssid: "Phone", problem: .unreadable)
        XCTAssertEqual(report.menuLine(for: c), HotspotPasswordProblem.unreadable.menuLine)

        c.setHotspotPriority(true)
        XCTAssertEqual(report.menuLine(for: c), HotspotPasswordProblem.unreadable.menuLine, "a list of one reads like the single hotspot")
        c.addPriorityHotspot("Tablet")
        XCTAssertEqual(report.menuLine(for: c), "\u{26A0} Password for hotspot \"Phone\" unreadable by this build: enter it again in Settings")
        XCTAssertEqual(HotspotPasswordReport(ssid: "Tablet", problem: .missing).menuLine(for: c), "\u{26A0} Password for hotspot \"Tablet\" not saved: enter it in Settings")
        XCTAssertNil(HotspotPasswordReport(ssid: "Gone", problem: .missing).menuLine(for: c), "not about a configured hotspot")
    }

    func testAReportStandsOnlyForAConfiguredHotspotTheSaveDidNotTouch() {
        let report = HotspotPasswordReport(ssid: "Phone", problem: .missing)
        XCTAssertTrue(report.stands(after: .init(ssid: "Tablet"), configuredSSIDs: ["Phone", "Tablet"]))
        XCTAssertFalse(report.stands(after: .init(ssid: "Phone"), configuredSSIDs: ["Phone", "Tablet"]))
        XCTAssertFalse(report.stands(after: .init(ssid: "Tablet"), configuredSSIDs: ["Tablet"]), "no longer configured")
        XCTAssertEqual(report.stands(after: .init(ssid: "Tablet"), configuredSSID: " Phone "), report.stands(after: .init(ssid: "Tablet"), configuredSSIDs: [" Phone "]))
    }

    func testTheListNoticeSaysWhatToDo() {
        XCTAssertTrue(HotspotPasswordProblem.missing.listNotice.contains("Enter this name and its password below"))
        XCTAssertTrue(HotspotPasswordProblem.unreadable.listNotice.contains("another build"))
        XCTAssertEqual(HotspotPasswordProblem.error("keychain: boom").listNotice, "The saved password can't be read: keychain: boom")
    }

    /// The right-click menu shows a report about a hotspot on the list,
    /// with its name, and drops it once the hotspot is removed.
    @MainActor
    func testTheMenuShowsAReportAboutAListedHotspot() {
        let h = Harness()
        defer { h.home.destroy() }
        let services = AppServices(
            paths: h.home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined)
        )
        let source = LiveStatusSource(services: services)
        let manager = h.makeManager()
        manager.config.setHotspotPriority(true)
        manager.config.addPriorityHotspot("Phone")
        manager.config.addPriorityHotspot("Tablet")
        services.status.hotspotPasswordReport = HotspotPasswordReport(ssid: "Tablet", problem: .missing)
        func warnings() -> [String] {
            StatusItemController.menuItems(manager: manager, status: source).map(\.title).filter { $0.contains("hotspot") }
        }

        XCTAssertEqual(warnings(), ["\u{26A0} Password for hotspot \"Tablet\" not saved: enter it in Settings"])
        manager.config.removePriorityHotspot("Tablet")
        XCTAssertEqual(warnings(), [])
    }
}

// MARK: - Keychain store

@MainActor
final class HotspotPriorityKeychainTests: XCTestCase {
    /// The single hotspot's SSID is edited away from one the list still
    /// names: the save keeps that hotspot's password.
    func testASaveKeepsTheItemOfAnSSIDTheListStillNames() async throws {
        let keychain = FakeKeychainStore()
        let ssid = Locked("Phone")
        let listed = Locked(["Phone"])
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue(), stillNamed: { listed.value.contains($0) }) { ssid.value }
        try await store.save("phone pw")
        _ = try await store.load()

        ssid.value = "Tablet"
        let change = try await store.save("tablet pw")

        XCTAssertEqual(change, HotspotPasswordChange(ssid: "Tablet"), "nothing removed")
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "phone pw")
        XCTAssertEqual(keychain.deletes, [])

        listed.value = []
        ssid.value = "Third"
        let moved = try await store.save("third pw")
        XCTAssertEqual(moved, HotspotPasswordChange(ssid: "Third", removed: "Tablet"), "an SSID nothing names is still moved")
    }

    /// The list's calls work on the named hotspot only and leave the
    /// single hotspot's loaded account alone.
    func testTheListsCallsLeaveTheLoadedAccountAlone() async throws {
        let keychain = FakeKeychainStore()
        let ssid = Locked("Old Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        try await store.save("first")
        _ = try await store.load()

        try await store.save("tablet pw", for: " Tablet ")
        let peeked = try await store.peek(ssid: "Tablet")
        XCTAssertEqual(peeked, "tablet pw")
        try await store.delete(ssid: "Tablet")
        let gone = try await store.peek(ssid: "Tablet")
        XCTAssertNil(gone)

        ssid.value = "New Phone"
        let change = try await store.save("replacement")
        XCTAssertEqual(change, HotspotPasswordChange(ssid: "New Phone", removed: "Old Phone"), "the loaded account is still the one the window loaded")
    }
}

// MARK: - Settings editor

final class PriorityHotspotEditorTests: XCTestCase {
    func testTheButtonSaysWhatASaveDoes() {
        var e = PriorityHotspotEditor()
        e.ssid = "Tablet"
        XCTAssertEqual(e.buttonTitle(listed: ["Phone"]), "Add")
        e.ssid = " Phone "
        XCTAssertEqual(e.buttonTitle(listed: ["Phone"]), "Update password")
        e.password = "pw"
        XCTAssertNotNil(e.startSave(listed: ["Phone"]))
        XCTAssertEqual(e.buttonTitle(listed: ["Phone"]), "Saving\u{2026}")
    }

    func testOneSaveAtATimeAndANameNeeded() {
        var e = PriorityHotspotEditor()
        XCTAssertNil(e.startSave(listed: []))
        e.ssid = "  "
        e.password = "pw"
        XCTAssertNil(e.startSave(listed: []), "a blank name")
        e.ssid = " Tablet "
        let started = e.startSave(listed: [])
        XCTAssertEqual(started?.ssid, "Tablet")
        XCTAssertEqual(started?.password, "pw")
        XCTAssertNil(e.startSave(listed: []), "one save at a time")
        XCTAssertFalse(e.canSave(listed: []))
    }

    /// An iPhone or iPad hands its password over when woken, so a name
    /// alone adds it. A listed one with no new password has nothing to save.
    func testTheNameAloneAddsAHotspot() {
        var e = PriorityHotspotEditor()
        e.ssid = "Phone"
        XCTAssertTrue(e.canSave(listed: []))
        XCTAssertFalse(e.canSave(listed: ["Phone"]))
        XCTAssertEqual(e.startSave(listed: [])?.password, "")
    }

    /// A listed name typed with the other apostrophe updates that
    /// hotspot, under the list's spelling, which the join reads.
    func testAListedNameIsMatchedWhicheverApostrophe() {
        var e = PriorityHotspotEditor()
        e.ssid = "Sam\u{2019}s iPad"
        e.password = "pw"
        XCTAssertEqual(e.buttonTitle(listed: ["Sam's iPad"]), "Update password")
        let entry = e.startSave(listed: ["Sam's iPad"])
        XCTAssertEqual(entry?.ssid, "Sam's iPad")
        e.finishSave(ssid: "Sam's iPad", password: "pw", error: nil)
        XCTAssertEqual(e.ssid, "", "the fields empty after the save")
    }

    func testAStoredSaveEmptiesTheFieldsUnlessTheyChanged() {
        var e = PriorityHotspotEditor()
        e.ssid = "Tablet"
        e.password = "pw"
        _ = e.startSave(listed: [])
        e.finishSave(ssid: "Tablet", password: "pw", error: nil)
        XCTAssertEqual(e.ssid, "")
        XCTAssertEqual(e.password, "")
        XCTAssertNil(e.notice)

        e.ssid = "Phone"
        e.password = "pw"
        _ = e.startSave(listed: [])
        e.ssid = "Next"
        e.finishSave(ssid: "Phone", password: "pw", error: nil)
        XCTAssertEqual(e.ssid, "Next", "typed while the save waited: the next entry")
        XCTAssertEqual(e.password, "pw")
    }

    func testAFailedSaveSaysWhy() {
        var e = PriorityHotspotEditor()
        e.ssid = "Tablet"
        e.password = "pw"
        _ = e.startSave(listed: [])
        e.finishSave(ssid: "Tablet", password: "pw", error: "keychain: denied")
        XCTAssertEqual(e.notice, "Could not save the password for \"Tablet\": keychain: denied")
        XCTAssertEqual(e.ssid, "Tablet", "the entry stays for another try")
        XCTAssertTrue(e.canSave(listed: []))
    }

    func testOnlyTheNewestCheckIsUsedAndASaveEndsItsHotspotsProblem() {
        var e = PriorityHotspotEditor()
        let old = e.startCheck()
        let new = e.startCheck()
        e.finishCheck(new, problems: ["Phone": .missing, "Tablet": .unreadable])
        e.finishCheck(old, problems: [:])
        XCTAssertEqual(e.problems, ["Phone": .missing, "Tablet": .unreadable])

        e.ssid = "Phone"
        e.password = "pw"
        _ = e.startSave(listed: [])
        e.finishSave(ssid: "Phone", password: "pw", error: nil)
        XCTAssertEqual(e.problems, ["Tablet": .unreadable])
    }

    func testTheFailoversReportShowsFirst() {
        var e = PriorityHotspotEditor()
        e.finishCheck(e.startCheck(), problems: ["Phone": .missing])
        XCTAssertEqual(e.notice(for: "Phone", reported: nil), HotspotPasswordProblem.missing.listNotice)
        XCTAssertEqual(e.notice(for: "Phone", reported: HotspotPasswordReport(ssid: "Phone", problem: .unreadable)), HotspotPasswordProblem.unreadable.listNotice)
        XCTAssertNil(e.notice(for: "Tablet", reported: HotspotPasswordReport(ssid: "Phone", problem: .unreadable)))
    }

    @MainActor
    func testACheckSortsEachHotspotsPassword() async {
        let problems = await PriorityHotspotEditor.problems(of: ["Phone", "Tablet", "Old", "Broken"]) { ssid in
            switch ssid {
            case "Phone": return "pw"
            case "Tablet": return nil
            case "Old": throw KeychainError(status: errSecAuthFailed)
            default: throw KeychainError(status: errSecIO)
            }
        }
        XCTAssertNil(problems["Phone"])
        XCTAssertNil(problems["Tablet"], "no password is fine: a woken device hands its own over")
        XCTAssertEqual(problems["Old"], .unreadable)
        if case .error = problems["Broken"] {} else { XCTFail("\(String(describing: problems["Broken"]))") }
    }
}

// MARK: - Nearby devices

@MainActor
final class NearbyHotspotDevicesTests: XCTestCase {
    /// Reads what sharingd lists, which only browses and changes nothing,
    /// but it reaches the live Bluetooth state, so it runs only when asked:
    /// INSOMNIA_LIVE_SHARING=1 swift test --filter NearbyHotspotDevicesTests
    @MainActor
    func testTheLiveBrowserListsDevicesAtOnceWhenAsked() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["INSOMNIA_LIVE_SHARING"] == "1", "set INSOMNIA_LIVE_SHARING=1 to browse")
        let started = Date()
        var first: TimeInterval?
        var devices: [NearbyHotspotDevice] = []
        await SharingHotspotBrowser().browse(for: 2) { list in
            if first == nil { first = Date().timeIntervalSince(started) }
            devices = list
        }
        // The last update may still be on its way to the main queue.
        await Task.yield()
        print("nearby hotspot devices: \(devices.count), first list after \(first.map { String(format: "%.2f s", $0) } ?? "none")")
        XCTAssertTrue(devices.allSatisfy { !$0.name.isEmpty })
    }

    @MainActor
    func testTheDoubleHandsOverItsListAtOnce() async {
        let list = [NearbyHotspotDevice(name: "Phone", battery: 80)]
        let arrived = expectation(description: "the list arrives while the browse runs")
        let browse = Task {
            await FixedNearbyHotspotDevices(list: list).browse(for: 60) { devices in
                XCTAssertEqual(devices, list)
                arrived.fulfill()
            }
        }
        await fulfillment(of: [arrived], timeout: 5)
        browse.cancel()
        await browse.value
    }

    /// Sharing keeps the completion and answers seconds later. Passing it a
    /// non-escaping block trapped the app on the road (2026-10-18).
    @MainActor
    func testTheWakeCompletionSurvivesBeingKeptAndCalledLater() async {
        let session = KeepingHotspotSession()
        let answered = expectation(description: "the kept completion answers")
        SharingHotspotWaker.enable(on: session, device: NSObject()) { first, second in
            XCTAssertEqual(first as? String, "Phone")
            XCTAssertEqual(second as? String, "secret")
            answered.fulfill()
        }
        XCTAssertNotNil(session.kept)
        DispatchQueue.main.async { session.kept?("Phone" as NSString, "secret" as NSString) }
        await fulfillment(of: [answered], timeout: 5)
    }
}

/// Stands in for SFRemoteHotspotSession: holds the completion, as Sharing does.
private final class KeepingHotspotSession: NSObject {
    var kept: (@convention(block) (AnyObject?, AnyObject?) -> Void)?

    @objc(enableHotspotForDevice:withCompletionHandler:)
    func enableHotspot(for device: NSObject, completion: @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) {
        kept = completion
    }
}

// MARK: - Nearby popover

final class NearbyHotspotPicksTests: XCTestCase {
    private let phone = NearbyHotspotDevice(name: "Phone", battery: 80)

    func testCachedNamesListBeforeTheScanIsDone() {
        var picks = NearbyHotspotPicks()
        XCTAssertTrue(picks.startScan())
        picks.cached(["Tablet B", "Cafe", "Tablet A"])
        XCTAssertTrue(picks.scanning)
        XCTAssertEqual(picks.networks, ["Cafe", "Tablet A", "Tablet B"])
        XCTAssertNil(picks.notice(locationAllowed: true), "no verdict while the scan runs")
    }

    func testTheScanAddsToTheCachedNamesAndRemovesNone() {
        var picks = NearbyHotspotPicks()
        _ = picks.startScan()
        picks.cached(["Cafe", "Tablet A"])
        picks.scanned(["Tablet A", "Tablet B"])
        XCTAssertFalse(picks.scanning)
        XCTAssertEqual(picks.networks, ["Cafe", "Tablet A", "Tablet B"])
    }

    func testANewOpeningStartsFromTheNewCache() {
        var picks = NearbyHotspotPicks()
        _ = picks.startScan()
        picks.cached(["Old"])
        picks.scanned(["Older"])
        XCTAssertTrue(picks.startScan())
        picks.cached(["New"])
        XCTAssertEqual(picks.networks, ["New"], "names from an earlier opening do not pile up")
    }

    func testOneScanAtATime() {
        var picks = NearbyHotspotPicks()
        XCTAssertTrue(picks.startScan())
        XCTAssertFalse(picks.startScan(), "a second click while the scan runs waits on the first")
        picks.scanned([])
        XCTAssertTrue(picks.startScan())
    }

    func testDevicesAreNotRepeatedAsNetworks() {
        var picks = NearbyHotspotPicks()
        _ = picks.startScan()
        picks.devicesFound([phone])
        picks.cached(["Phone", "Cafe"])
        XCTAssertEqual(picks.devices, [phone])
        XCTAssertEqual(picks.networks, ["Cafe"])
    }

    func testTheNothingFoundNoticeEndsWhenADeviceShowsUp() {
        var picks = NearbyHotspotPicks()
        _ = picks.startScan()
        picks.cached([])
        picks.scanned([])
        XCTAssertEqual(picks.notice(locationAllowed: true), "Nothing found. Turn on Personal Hotspot on the device and scan again.")
        XCTAssertEqual(picks.notice(locationAllowed: false), "macOS hides network names until Location is allowed for Insomnia.")
        picks.devicesFound([phone])
        XCTAssertNil(picks.notice(locationAllowed: false), "a device found after the scan ends the notice")
    }

    func testAFailedScanKeepsTheCachedNamesAndSaysWhy() {
        var picks = NearbyHotspotPicks()
        _ = picks.startScan()
        picks.cached(["Cafe"])
        picks.scanFailed("busy")
        XCTAssertFalse(picks.scanning)
        XCTAssertEqual(picks.networks, ["Cafe"])
        XCTAssertEqual(picks.notice(locationAllowed: true), "The Wi-Fi scan failed: busy")
        XCTAssertTrue(picks.startScan())
        XCTAssertNil(picks.notice(locationAllowed: true), "a new scan clears the old failure")
    }
}
