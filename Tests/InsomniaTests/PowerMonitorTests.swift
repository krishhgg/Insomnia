import IOKit.ps
import XCTest
@testable import Insomnia

/// `PowerMonitor` with power source descriptions built by hand and an
/// injected reader. Nothing here changes power state.
@MainActor
final class PowerMonitorTests: XCTestCase {
    private func battery(current: Int? = 50, max: Int? = 100, state: String = kIOPSBatteryPowerValue, charging: Bool = false) -> [String: Any] {
        var d: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSPowerSourceStateKey: state,
            kIOPSIsChargingKey: charging,
        ]
        if let current { d[kIOPSCurrentCapacityKey] = current }
        if let max { d[kIOPSMaxCapacityKey] = max }
        return d
    }

    // MARK: classify: no battery vs. battery present but unreadable

    func testReadableBatteryIsAPercent() {
        let r = PowerMonitor.classify(sources: [battery(current: 42, max: 100)], hasBatteryService: { XCTFail("service checked with an entry present"); return true })
        XCTAssertEqual(r.battery, .percent(42))
        XCTAssertFalse(r.charging)
        XCTAssertTrue(PowerMonitor.classify(sources: [battery(state: kIOPSACPowerValue)], hasBatteryService: { true }).charging)
        XCTAssertTrue(PowerMonitor.classify(sources: [battery(charging: true)], hasBatteryService: { true }).charging)
    }

    func testEmptyListIsNoBatteryOnADesktop() {
        let r = PowerMonitor.classify(sources: [], hasBatteryService: { false })
        XCTAssertEqual(r.battery, .none)
        XCTAssertFalse(r.charging)
    }

    func testEmptyListWithABatteryServiceIsUnreadable() {
        XCTAssertEqual(PowerMonitor.classify(sources: [], hasBatteryService: { true }).battery, .unreadable(misses: 1))
    }

    func testUnavailableListFollowsTheBatteryService() {
        XCTAssertEqual(PowerMonitor.classify(sources: nil, hasBatteryService: { true }).battery, .unreadable(misses: 1))
        XCTAssertEqual(PowerMonitor.classify(sources: nil, hasBatteryService: { false }).battery, .none)
    }

    /// An entry without a usable capacity is unreadable even though the
    /// power source state is known; charging still comes from the entry.
    func testEntryWithoutCapacityIsUnreadableButKeepsCharging() {
        let noCurrent = PowerMonitor.classify(sources: [battery(current: nil, state: kIOPSACPowerValue)], hasBatteryService: { false })
        XCTAssertEqual(noCurrent.battery, .unreadable(misses: 1))
        XCTAssertTrue(noCurrent.charging)
        XCTAssertEqual(PowerMonitor.classify(sources: [battery(max: 0)], hasBatteryService: { false }).battery, .unreadable(misses: 1))
    }

    func testOtherPowerSourcesAreIgnored() {
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 90, kIOPSMaxCapacityKey: 100]
        XCTAssertEqual(PowerMonitor.classify(sources: [ups], hasBatteryService: { false }).battery, .none)
        XCTAssertEqual(PowerMonitor.classify(sources: [ups, battery(current: 70)], hasBatteryService: { false }).battery, .percent(70))
    }

    // MARK: consecutive misses and the recheck

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var _next: (battery: BatteryStatus, charging: Bool) = (.unreadable(misses: 1), false)
        private var _count = 0
        var next: (battery: BatteryStatus, charging: Bool) {
            get { lock.withLock { _next } }
            set { lock.withLock { _next = newValue } }
        }
        var count: Int { lock.withLock { _count } }
        func read() -> (battery: BatteryStatus, charging: Bool) {
            lock.withLock { _count += 1; return _next }
        }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    /// A miss after a miss counts up, so the floor rules see the second one;
    /// the count is capped so a battery that stays unreadable is not a
    /// change on every re-read. A readable read resets it.
    func testMissesCountUpAndReset() {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .seconds(3600))
        XCTAssertEqual(monitor.battery, .none)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        XCTAssertNil(monitor.percent)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2))
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2))
        reads.next = (.percent(55), true)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .percent(55))
        XCTAssertEqual(monitor.percent, 55)
        XCTAssertTrue(monitor.isCharging)
        reads.next = (.unreadable(misses: 1), false)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1), "misses carried over a readable read")
    }

    /// IOKit sends no event for a read that keeps failing. While started
    /// and unreadable, the monitor re-reads on its own and reports the
    /// second miss as a change; once readable again it stops re-reading.
    func testUnreadableBatteryIsRecheckedWhileStarted() async {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .milliseconds(50))
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        XCTAssertEqual(reads.count, 1)

        await waitUntil("second miss never reported") { monitor.battery == .unreadable(misses: 2) }
        XCTAssertEqual(changes, 1)

        reads.next = (.percent(80), false)
        await waitUntil("recovery never seen") { monitor.battery == .percent(80) }
        XCTAssertEqual(changes, 2)
        let after = reads.count
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.count, after, "still re-reading a readable battery")
    }

    func testStopCancelsTheRecheck() async {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .milliseconds(50))
        monitor.start()
        monitor.stop()
        let after = reads.count
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.count, after, "re-read after stop")
        // Not started: a refresh counts a miss but schedules nothing.
        monitor.refreshBattery()
        let again = reads.count
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.count, again)
    }
}
