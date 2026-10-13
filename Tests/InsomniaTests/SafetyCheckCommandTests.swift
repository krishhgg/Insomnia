import XCTest
@testable import Insomnia

final class SafetyCheckCommandTests: XCTestCase {
    private func decision(
        _ battery: BatteryStatus = .percent(80), charging: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal, lid: Bool? = true, config: Config = Config()
    ) -> String {
        SafetyCheckCommand.decision(
            battery: battery, isCharging: charging, thermal: thermal,
            lidClosed: lid, config: config
        )
    }

    func testBatteryAndThermalCutoffsUseTheSameRulesAsTheApp() {
        XCTAssertEqual(decision(), "continue")
        XCTAssertEqual(decision(.percent(9)), "end batteryFloor")
        XCTAssertEqual(decision(.percent(9), charging: true), "continue")
        XCTAssertEqual(decision(thermal: .serious), "end thermalSeriousClosedLid")
        XCTAssertEqual(decision(thermal: .serious, lid: false), "continue")
        XCTAssertEqual(decision(thermal: .critical), "end thermalCritical")
    }

    func testConfiguredFloorsAndThermalOptOutAreHonored() {
        var config = Config()
        config.endFloor = 20
        XCTAssertEqual(decision(.percent(19), config: config), "end batteryFloor")
        config.endClosedLidWhenHot = false
        XCTAssertEqual(decision(thermal: .serious, config: config), "continue")
        config.thermalRules = false
        XCTAssertEqual(decision(thermal: .critical, config: config), "continue")
    }

    func testUnknownLidIsNotTreatedAsOpenOnALaptop() {
        XCTAssertEqual(decision(lid: nil), "end lid-unreadable")
        XCTAssertEqual(decision(.unreadable(misses: 2), lid: nil), "end lid-unreadable")
        XCTAssertEqual(decision(.none, lid: nil), "continue", "desktops have no lid")
        XCTAssertEqual(decision(.none, lid: true), "end batteryUnreadable", "a closed lid proves this is a laptop")
    }

    func testMissingBatteryReadIsRetriedBeforeEnding() {
        for recovered in [false, true] {
            var reads = 0
            let result = SafetyCheckCommand.run(
                ["--check-safety", "5"],
                readBattery: {
                    reads += 1
                    return reads == 2 && recovered ? (.percent(80), false) : (.unreadable(misses: 1), false)
                },
                readLid: { true }, readThermal: { .nominal }, readConfig: { Config() }, endAfter: { _ in }
            )
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(result?.line, recovered ? "continue" : "end batteryUnreadable")
        }
    }

    func testDisappearingBatteryAfterAMissIsNotADesktop() {
        var reads = 0
        let result = SafetyCheckCommand.run(
            ["--check-safety", "5"],
            readBattery: {
                reads += 1
                return (reads == 1 ? .unreadable(misses: 1) : .none, false)
            },
            readLid: { true }, readThermal: { .nominal }, readConfig: { Config() }, endAfter: { _ in }
        )
        XCTAssertEqual(result?.line, "end batteryUnreadable")
    }

    func testLifetimeIsArmedBeforeAnyReadsAndNoMutationIsRequested() {
        var order: [String] = []
        let result = SafetyCheckCommand.run(
            ["--check-safety", "5"],
            readBattery: { order.append("battery"); return (.percent(80), false) },
            readLid: { order.append("lid"); return false },
            readThermal: { order.append("thermal"); return .nominal },
            readConfig: { order.append("config"); return nil },
            endAfter: { order.append("alarm \($0)") }
        )
        XCTAssertEqual(order.first, "alarm 5")
        XCTAssertEqual(Set(order), ["alarm 5", "config", "battery", "lid", "thermal"])
        XCTAssertEqual(result, SafetyCheckCommand.Output(line: "continue", status: 0))
    }

    func testUnreadableConfigEndsInsteadOfUsingDefaults() {
        struct Unreadable: Error {}
        let result = SafetyCheckCommand.run(
            ["--check-safety", "5"],
            readConfig: { throw Unreadable() }, endAfter: { _ in }
        )
        XCTAssertEqual(result?.line, "end configuration-unreadable")
    }

    func testUsageErrorsDoNotReadAnythingOrStartTheApp() {
        for args in [["--check-safety"], ["--check-safety", "0"], ["--check-safety", "301"], ["--check-safety", "5", "extra"]] {
            var armed = false
            let result = SafetyCheckCommand.run(args, endAfter: { _ in armed = true })
            XCTAssertEqual(result?.status, 64)
            XCTAssertFalse(armed)
        }
        XCTAssertNil(SafetyCheckCommand.run(["--other-mode"], endAfter: { _ in XCTFail("wrong mode") }))
    }

    func testNewSessionsRequireTheCheckAndExtensionsPreserveIt() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = SessionMath.newSession(now: now, duration: 3600, maxDuration: 7200)
        XCTAssertEqual(session.safetyCheckVersion, SafetyCheckCommand.version)
        let extended = SessionMath.extended(session, by: 600, now: now, maxDuration: 7200)
        XCTAssertEqual(extended.safetyCheckVersion, session.safetyCheckVersion)
        XCTAssertEqual(try Store.makeDecoder().decode(Session.self, from: Store.makeEncoder().encode(session)), session)
        let legacy = try Store.makeDecoder().decode(Session.self, from: Data(#"{"startedAt":"2026-10-12T20:00:00Z","endsAt":"2026-10-12T21:00:00Z","extensions":[]}"#.utf8))
        XCTAssertNil(legacy.safetyCheckVersion)
    }
}

@MainActor
final class SafetyBackstopSyncTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func simulateBackstopRestoredPower() throws {
        h.guardFake.sleepDisabled = false
        try h.store.saveState(.clean)
    }

    func testSyncClearsCachedSessionAfterBackstopCutout() async throws {
        let manager = h.makeManager()
        await manager.start(duration: 3600)
        try h.store.deleteSession()
        try simulateBackstopRestoredPower()
        await manager.synchronizeWithBackstop()
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(manager.scheduledDeadline)
        XCTAssertFalse(manager.countdownTimerArmed)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertTrue(h.notifier.posts.last?.body.contains("recovery agent") ?? false)
    }

    func testExtendCannotResurrectACutoutBeforeTheSyncTimerFires() async throws {
        let manager = h.makeManager()
        await manager.start(duration: 3600)
        try h.store.deleteSession()
        try simulateBackstopRestoredPower()
        await manager.extend(by: 3600)
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    func testSyncFinishesPartialBackstopRecoveryWithSessionStillPresent() async throws {
        let manager = h.makeManager()
        await manager.start(duration: 3600)
        try simulateBackstopRestoredPower()
        await manager.synchronizeWithBackstop()
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(try h.store.loadSession())
    }

    func testSyncLeavesAHealthySessionAndItsDeadlineAlone() async throws {
        let manager = h.makeManager()
        await manager.start(duration: 3600)
        let original = manager.session
        await manager.synchronizeWithBackstop()
        XCTAssertEqual(manager.session, original)
        XCTAssertEqual(try h.store.loadSession(), original)
        XCTAssertTrue(h.guardFake.sleepDisabled)
    }

    func testExtendCannotOverwriteALatchedCutoffWithUndoStillPending() async throws {
        let manager = h.makeManager()
        await manager.start(duration: 3600)
        var saved = try XCTUnwrap(h.store.loadSession())
        saved.endsAt = Date(timeIntervalSince1970: 0)
        try h.store.saveSession(saved)
        await manager.extend(by: 3600)
        XCTAssertFalse(manager.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    func testRelaunchDoesNotReapplySleepAfterBackstopReleasedIt() async throws {
        let first = h.makeManager()
        await first.start(duration: 3600)
        // Simulate a cutoff whose session-file publish failed, with owned
        // sleep still journaled. The future deadline alone cannot revive it.
        h.guardFake.sleepDisabled = false
        let relaunched = h.makeManager()
        await relaunched.reconcile()
        XCTAssertFalse(relaunched.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
    }
}
