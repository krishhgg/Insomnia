import XCTest
@testable import Insomnia

final class FloorRulesTests: XCTestCase {
    /// nil is a machine with no battery (desktop). `hot`: serious or
    /// critical read earlier in the session, with no nominal since.
    func eval(_ percent: Int?, charging: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, hot: Bool = false, lid: Bool = false, lp: Bool = false, config: Config = Config()) -> [FloorRules.Action] {
        eval(battery: percent.map { .percent($0) } ?? .none, charging: charging, thermal: thermal, hot: hot, lid: lid, lp: lp, config: config)
    }

    func eval(battery: BatteryStatus, charging: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, hot: Bool = false, lid: Bool = false, lp: Bool = false, config: Config = Config()) -> [FloorRules.Action] {
        FloorRules.evaluate(battery: battery, isCharging: charging, thermal: thermal, hot: hot, lidClosed: lid, lowPowerSetByUs: lp, config: config)
    }

    // Row 1: battery below lowPowerFloor -> lowpowermode 1
    func testBelowLowPowerFloorEnablesLowPower() {
        XCTAssertEqual(eval(39), [.enableLowPower(.battery)])
        XCTAssertEqual(eval(40), [])
        XCTAssertEqual(eval(39, lp: true), [])
    }

    // Row 1 undo: charger connected, or session end (session end is restoreAll)
    func testChargerConnectedClearsLowPower() {
        XCTAssertEqual(eval(39, charging: true, lp: true), [.disableLowPower])
        XCTAssertEqual(eval(39, charging: true), [])
    }

    func testBackAboveFloorClearsLowPower() {
        XCTAssertEqual(eval(45, lp: true), [.disableLowPower])
    }

    // Row 2: battery below endFloor -> end session
    func testBelowEndFloorEndsSession() {
        XCTAssertEqual(eval(9), [.endSession(.batteryFloor)])
        XCTAssertEqual(eval(10), [.enableLowPower(.battery)])
        XCTAssertEqual(eval(9, lp: true), [.endSession(.batteryFloor)])
    }

    func testBelowEndFloorWhileChargingDoesNotEnd() {
        XCTAssertEqual(eval(5, charging: true), [])
    }

    // Row 3: thermal serious -> lowpowermode 1; undo when nominal/fair
    func testThermalSeriousEnablesLowPower() {
        XCTAssertEqual(eval(80, thermal: .serious), [.enableLowPower(.thermal)])
        XCTAssertEqual(eval(80, charging: true, thermal: .serious), [.enableLowPower(.thermal)])
        XCTAssertEqual(eval(80, thermal: .serious, lp: true), [])
    }

    func testThermalBackToNominalClearsLowPower() {
        XCTAssertEqual(eval(80, thermal: .nominal, lp: true), [.disableLowPower])
        // Fair with no serious before it in this session is not heat.
        XCTAssertEqual(eval(80, thermal: .fair, lp: true), [.disableLowPower])
    }

    /// A Mac back at fair after serious is still cooling down: the mode
    /// stays on, and is switched on if it is not ours yet, until nominal.
    /// Off at the first step down, the load that made the Mac serious
    /// comes back and the mode goes on and off as it heats up again.
    func testFairAfterSeriousKeepsLowPowerUntilNominal() {
        XCTAssertEqual(eval(80, thermal: .fair, hot: true, lp: true), [])
        XCTAssertEqual(eval(80, charging: true, thermal: .fair, hot: true, lp: true), [])
        XCTAssertEqual(eval(80, thermal: .fair, hot: true), [.enableLowPower(.thermal)])
        XCTAssertEqual(eval(80, thermal: .nominal, hot: true, lp: true), [.disableLowPower])
        var off = Config()
        off.thermalRules = false
        XCTAssertEqual(eval(80, thermal: .fair, hot: true, lp: true, config: off), [.disableLowPower])
    }

    /// With the hold off the thermal cause ends at fair, as it did before
    /// the hold: serious still switches the mode on.
    func testHoldOffReleasesHeatLowPowerAtFair() {
        var c = Config()
        c.thermalHoldUntilNominal = false
        XCTAssertEqual(eval(80, thermal: .serious, config: c), [.enableLowPower(.thermal)])
        XCTAssertEqual(eval(80, thermal: .fair, hot: true, lp: true, config: c), [.disableLowPower])
        XCTAssertEqual(eval(80, thermal: .fair, hot: true, config: c), [])
        // Another cause still holds the mode at fair.
        XCTAssertEqual(eval(30, thermal: .fair, hot: true, lp: true, config: c), [])
    }

    // Row 4: thermal critical -> end session
    func testThermalCriticalEndsSession() {
        XCTAssertEqual(eval(80, thermal: .critical), [.endSession(.thermalCritical)])
        XCTAssertEqual(eval(nil, thermal: .critical), [.endSession(.thermalCritical)])
    }

    func testBatteryEndFloorWinsOverThermalCritical() {
        XCTAssertEqual(eval(5, thermal: .critical), [.endSession(.batteryFloor)])
    }

    // Row 2, unreadable: a battery that is present but cannot be read on
    // two consecutive reads ends the session while on battery. One miss is
    // a transient IOKit failure and changes nothing.
    func testUnreadableBatteryEndsSessionAfterTwoMisses() {
        XCTAssertEqual(eval(battery: .unreadable(misses: 1)), [])
        XCTAssertEqual(eval(battery: .unreadable(misses: 2)), [.endSession(.batteryUnreadable)])
        XCTAssertEqual(eval(battery: .unreadable(misses: 2), lp: true), [.endSession(.batteryUnreadable)])
    }

    func testUnreadableBatteryWhileChargingDoesNotEnd() {
        XCTAssertEqual(eval(battery: .unreadable(misses: 2), charging: true), [])
        // Low Power Mode we set for the battery floor is released: no level
        // is below a floor when none is known.
        XCTAssertEqual(eval(battery: .unreadable(misses: 2), charging: true, lp: true), [.disableLowPower])
    }

    // A desktop has no battery to read; the floors never apply.
    func testNoBatteryIsNotUnreadable() {
        XCTAssertEqual(eval(nil), [])
        XCTAssertEqual(eval(battery: .none, lp: true), [.disableLowPower])
    }

    // No end floor (0) means nothing to apply, read or not.
    func testUnreadableBatteryWithEndFloorDisabledDoesNotEnd() {
        var c = Config()
        c.endFloor = 0
        XCTAssertEqual(eval(battery: .unreadable(misses: 2), config: c), [])
    }

    func testThermalCriticalWinsOverUnreadableBattery() {
        XCTAssertEqual(eval(battery: .unreadable(misses: 2), thermal: .critical), [.endSession(.thermalCritical)])
    }

    // Unreadable is not "below the floor": nothing enables Low Power Mode
    // for the battery, and a lid or thermal cause still works as before.
    func testUnreadableBatteryDoesNotEnableLowPowerByItself() {
        XCTAssertEqual(eval(battery: .unreadable(misses: 1), lid: true), [.enableLowPower(.lid)])
        XCTAssertEqual(eval(battery: .unreadable(misses: 1), thermal: .serious), [.enableLowPower(.thermal)])
    }

    func testThermalRulesOffIgnoresThermal() {
        var c = Config()
        c.thermalRules = false
        XCTAssertEqual(eval(80, thermal: .serious, config: c), [])
        XCTAssertEqual(eval(80, thermal: .critical, config: c), [])
        XCTAssertEqual(eval(80, thermal: .serious, lp: true, config: c), [.disableLowPower])
        // Battery rules still apply.
        XCTAssertEqual(eval(30, thermal: .critical, config: c), [.enableLowPower(.battery)])
    }

    func testLowPowerStaysWhileEitherCauseHolds() {
        XCTAssertEqual(eval(30, thermal: .serious, lp: true), [])
        XCTAssertEqual(eval(30, thermal: .nominal, lp: true), [])
        XCTAssertEqual(eval(80, charging: true, thermal: .serious, lp: true), [])
    }

    func testNoBatteryInfoOnlyThermalApplies() {
        XCTAssertEqual(eval(nil), [])
        XCTAssertEqual(eval(nil, thermal: .serious), [.enableLowPower(.thermal)])
    }

    func testCustomFloors() {
        var c = Config()
        c.lowPowerFloor = 60
        c.endFloor = 25
        XCTAssertEqual(eval(59, config: c), [.enableLowPower(.battery)])
        XCTAssertEqual(eval(24, config: c), [.endSession(.batteryFloor)])
    }

    // Row 5: lid closed (optional, default on) -> lowpowermode 1; undo on lid open
    func testLidClosedEnablesLowPowerWhenConfigured() {
        XCTAssertEqual(eval(80, lid: true), [.enableLowPower(.lid)])
        XCTAssertEqual(eval(nil, lid: true), [.enableLowPower(.lid)])
        XCTAssertEqual(eval(80, lid: true, lp: true), [])
    }

    func testLidClosedWithOptionOffDoesNothing() {
        var c = Config()
        c.lowPowerOnLidClose = false
        XCTAssertEqual(eval(80, lid: true, config: c), [])
        XCTAssertEqual(eval(80, lid: true, lp: true, config: c), [.disableLowPower])
        // Battery and thermal rules still apply with the lid closed.
        XCTAssertEqual(eval(30, lid: true, config: c), [.enableLowPower(.battery)])
    }

    func testLidOpenAfterLidCausedEnableClearsLowPower() {
        XCTAssertEqual(eval(80, lid: false, lp: true), [.disableLowPower])
    }

    func testLidOpenWithBatteryBelowFloorKeepsLowPower() {
        XCTAssertEqual(eval(30, lid: false, lp: true), [])
        XCTAssertEqual(eval(80, thermal: .serious, lid: false, lp: true), [])
    }

    func testLidClosedWhileChargingStillEnablesLowPower() {
        XCTAssertEqual(eval(80, charging: true, lid: true), [.enableLowPower(.lid)])
        XCTAssertEqual(eval(80, charging: true, lid: true, lp: true), [])
    }

    func testEndSessionRulesWinOverLid() {
        XCTAssertEqual(eval(5, lid: true), [.endSession(.batteryFloor)])
        XCTAssertEqual(eval(80, thermal: .critical, lid: true), [.endSession(.thermalCritical)])
    }

    /// The cause names the strongest reason: thermal, then battery, then lid.
    func testLidIsTheWeakestCause() {
        XCTAssertEqual(eval(30, lid: true), [.enableLowPower(.battery)])
        XCTAssertEqual(eval(30, thermal: .serious, lid: true), [.enableLowPower(.thermal)])
        XCTAssertEqual(eval(80, thermal: .serious, lid: true), [.enableLowPower(.thermal)])
    }

    func cause(_ percent: Int?, charging: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, hot: Bool = false, lid: Bool = false, config: Config = Config()) -> FloorRules.LowPowerCause? {
        FloorRules.lowPowerCause(percent: percent, isCharging: charging, thermal: thermal, hot: hot, lidClosed: lid, config: config)
    }

    /// The effective cause is the strongest one holding right now, whether
    /// or not Insomnia already has the mode on.
    func testLowPowerCauseNamesTheStrongestHoldingCause() {
        XCTAssertNil(cause(80))
        XCTAssertNil(cause(35, charging: true))
        XCTAssertEqual(cause(35), .battery)
        XCTAssertEqual(cause(80, thermal: .serious), .thermal)
        XCTAssertEqual(cause(80, lid: true), .lid)
        XCTAssertEqual(cause(35, lid: true), .battery)
        XCTAssertEqual(cause(35, charging: true, lid: true), .lid)
        XCTAssertEqual(cause(35, thermal: .serious, lid: true), .thermal)
        XCTAssertEqual(cause(35, thermal: .fair, hot: true, lid: true), .thermal)
        XCTAssertNil(cause(80, thermal: .fair))
        XCTAssertNil(cause(80, thermal: .nominal, hot: true))
    }

    func testLowPowerCauseHonorsTheOptions() {
        var c = Config()
        c.lowPowerOnLidClose = false
        c.thermalRules = false
        XCTAssertNil(cause(80, thermal: .serious, lid: true, config: c))
        XCTAssertNil(cause(80, thermal: .fair, hot: true, config: c))
        XCTAssertEqual(cause(35, thermal: .serious, lid: true, config: c), .battery)
    }
}

@MainActor
final class FloorRuleDriverTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    func testLowPowerIsJournaledBeforePmsetAndNotified() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        // The current mode is read before it is taken over.
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 1"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("35%") ?? false)

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 0")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
    }

    func testLowPowerFailureRollsBackJournal() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.guardFake.throwOn = ["lowpowermode 1"]
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == "Low Power Mode on" })
    }

    func testEndFloorEndsSessionWithReason() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(8), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        XCTAssertEqual(h.notifier.posts.last?.title, "Session ended")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("10%") ?? false)
    }

    func testUnreadableBatteryEndsSessionAndSaysWhy() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .unreadable(misses: 1), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(m.isActive, "one missed read ended the session")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])

        await driver.run(battery: .unreadable(misses: 2), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        XCTAssertEqual(h.notifier.posts.last?.title, "Session ended")
        let body = try XCTUnwrap(h.notifier.posts.last?.body)
        XCTAssertTrue(body.contains("could not be read"), body)
        XCTAssertTrue(body.contains("10%"), body)
    }

    func testThermalCriticalEndsSession() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        await m.setLowPower(true)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .critical, lidClosed: false)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertTrue(h.notifier.posts.last?.body.contains("critical") ?? false)
    }

    func testNoSessionDoesNothing() async throws {
        let m = h.makeManager()
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(5), isCharging: false, thermal: .critical, lidClosed: false)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertEqual(h.notifier.posts.count, 0)
    }

    func testSessionEndWhileLowPowerEnableIsSuspendedLeavesCleanState() async throws {
        let gate = AsyncGate()
        h.guardFake.lowPowerGate = gate
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        let floor = Task { await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false) }
        await gate.waitUntilStarted()

        // The end queues behind the held Low Power change; release the hold
        // first, then wait for both. Awaiting the end here would deadlock.
        let end = await runUntilSuspended { await m.end(reason: .user) }
        await gate.open()
        await floor.value
        _ = await end.value

        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertFalse(h.guardFake.lowPowerOn, "Low Power Mode left on after the session ended")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == "Low Power Mode on" })
    }

    /// Low Power Mode the user already had on is theirs: Insomnia neither
    /// journals it as its own nor switches it off when the session ends.
    func testPreexistingLowPowerModeIsNeverTakenOver() async throws {
        h.guardFake.lowPowerOn = true
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom"])
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == "Low Power Mode on" })

        await m.end(reason: .user)
        XCTAssertTrue(h.guardFake.lowPowerOn, "user's Low Power Mode was switched off at session end")
        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 0"))
    }

    /// If pmset cannot say whether the mode is on, ownership is not taken:
    /// switching it off later could undo the user's own choice.
    func testUnreadableLowPowerModeIsLeftAlone() async throws {
        h.guardFake.throwOn = ["pmset -g custom"]
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)

        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 1"))
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == "Low Power Mode on" })
    }

    /// `lowpowermode 1` applied the mode and then failed (a timeout). The
    /// flag was journaled first, so the failure path switches the mode back
    /// off and only then drops ownership.
    func testLowPowerCommandFailingAfterTakingEffectIsSwitchedBackOff() async throws {
        h.guardFake.throwAfterEffect = ["lowpowermode 1"]
        let m = h.makeManager()
        await m.start(duration: 3600)
        let changed = await m.setLowPower(true)

        XCTAssertFalse(changed)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 1", "lowpowermode 0"])
        XCTAssertFalse(h.guardFake.lowPowerOn, "Low Power Mode left on after its command failed")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
    }

    /// Same ambiguous failure, and the undo fails too: ownership stays
    /// journaled so the session end (or the agent) clears the mode later.
    func testLowPowerAmbiguousFailureKeepsOwnershipWhenTheUndoFails() async throws {
        h.guardFake.throwAfterEffect = ["lowpowermode 1"]
        h.guardFake.throwOn = ["lowpowermode 0"]
        let m = h.makeManager()
        await m.start(duration: 3600)
        let changed = await m.setLowPower(true)

        XCTAssertFalse(changed)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true, "ownership dropped while the mode may still be on")

        h.guardFake.throwOn = []
        await m.end(reason: .user)
        XCTAssertFalse(h.guardFake.lowPowerOn, "session end did not clear the mode Insomnia may have switched on")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// Lid-caused Low Power Mode is journaled like any other cause, so the
    /// session end (`restoreAll`) clears it, but it is not announced: the
    /// user just closed the lid and is not looking.
    func testLidCausedLowPowerIsJournaledAndSilent() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: true, thermal: .nominal, lidClosed: true)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "pmset -g custom", "lowpowermode 1"])
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == "Low Power Mode on" })

        await m.end(reason: .user)
        XCTAssertFalse(h.guardFake.lowPowerOn, "lid-caused Low Power Mode left on after the session ended")
        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testLidOpenClearsLidCausedLowPowerSilently() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: true)
        XCTAssertTrue(h.guardFake.lowPowerOn)

        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 0")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertFalse(h.notifier.posts.contains { $0.title.hasPrefix("Low Power Mode") })
    }

    func testLidOpenKeepsLowPowerWhileBatteryIsBelowFloor() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: true)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertEqual(h.notifier.posts.count, 0)
    }

    /// With the lid closed, a battery or thermal cause is still announced.
    func testBatteryCauseIsNotifiedEvenWithTheLidClosed() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: true)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("35%") ?? false)

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
        XCTAssertEqual(h.notifier.posts.last?.body, "Charger connected.")
    }

    func testLidOptionOffLeavesLowPowerAlone() async throws {
        let m = h.makeManager()
        m.config.lowPowerOnLidClose = false
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: true)
        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 1"))
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
    }

    // The disable is announced iff the cause that last held while Insomnia
    // had the mode on was battery or thermal; it is silent iff that cause
    // was the lid. The cause is tracked on every run, not only at enable.

    /// Lid enable, battery takes over, charger connected with the lid still
    /// closed (the lid holds the mode: no action), then lid open: the last
    /// holding cause was the lid, so the disable is silent.
    func testBatteryTakeoverThenRecoveryUnderClosedLidEndsSilentlyOnLidOpen() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: true)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.count, 0)

        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: true)
        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: true)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertEqual(h.notifier.posts.count, 0)

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 0")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertEqual(h.notifier.posts.count, 0, "lid-open disable was announced")
    }

    /// Lid enable, battery takes over, lid opens while the battery is still
    /// below the floor (battery holds the mode: no action), then charger
    /// connected: the last holding cause was the battery, so the recovery
    /// is announced.
    func testBatteryTakeoverThenLidOpenAnnouncesTheChargerRecovery() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: true)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.count, 0)

        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: true)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertEqual(h.notifier.posts.count, 0)

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 0")
        XCTAssertEqual(h.notifier.posts.count, 1)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
        XCTAssertEqual(h.notifier.posts.last?.body, "Charger connected.")
    }

    /// The reverse: battery enable (announced), lid closes, charger
    /// connected with the lid still closed (lid holds the mode: nothing to
    /// announce), then lid open: the last holding cause was the lid, so
    /// the disable is silent.
    func testBatteryEnableThenLidTakeoverEndsSilentlyOnLidOpen() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.count, 1)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")

        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: true)
        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: true)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 0"))
        XCTAssertEqual(h.notifier.posts.count, 1)

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 0")
        XCTAssertEqual(h.notifier.posts.count, 1, "lid-open disable was announced")
    }

    /// The thermal cause is tracked the same way: lid enable, thermal
    /// takes over, lid opens (thermal holds), cools down to fair (still
    /// holds), then to nominal: announced as the cooldown it is.
    func testThermalTakeoverThenLidOpenAnnouncesTheCooldown() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: true)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .serious, lidClosed: true)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .serious, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.count, 0)

        await driver.run(battery: .percent(80), isCharging: false, thermal: .fair, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn, "the mode went off while the Mac was still cooling down")
        XCTAssertEqual(h.notifier.posts.count, 0)

        await driver.run(battery: .percent(80), isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
        XCTAssertEqual(h.notifier.posts.last?.body, "Thermal state is back to nominal.")
    }

    /// Heat with the lid open: the mode goes on once at serious and stays
    /// on through fair and a second serious, so it does not cycle, and goes
    /// off at nominal. A fair later in the session, with no serious before
    /// it since nominal, holds nothing.
    func testHeatLowPowerStaysOnUntilNominalWithoutCycling() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: true, thermal: .serious, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode on")
        XCTAssertEqual(h.notifier.posts.last?.body, "Thermal state is serious. Low Power Mode stays on until it is back to nominal.")

        for thermal in [ProcessInfo.ThermalState.fair, .serious, .fair] {
            await driver.run(battery: .percent(80), isCharging: true, thermal: thermal, lidClosed: false)
            XCTAssertTrue(h.guardFake.lowPowerOn, "off at \(PowerMonitor.name(thermal))")
        }
        XCTAssertEqual(h.guardFake.calls.filter { $0.hasPrefix("lowpowermode") }, ["lowpowermode 1"])
        XCTAssertEqual(h.notifier.posts.count, 1)

        await driver.run(battery: .percent(80), isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertEqual(h.notifier.posts.last?.body, "Thermal state is back to nominal.")

        await driver.run(battery: .percent(80), isCharging: true, thermal: .fair, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn, "fair with no serious since nominal switched the mode on")
    }

    /// Thermal rules turned off while the mode is on for heat: the next run
    /// (Settings queues one) switches it off and says why.
    func testTurningTheThermalRulesOffReleasesHeatLowPowerAndSaysWhy() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: false, thermal: .serious, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)

        m.config.thermalRules = false
        await driver.run(battery: .percent(80), isCharging: false, thermal: .serious, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
        XCTAssertEqual(h.notifier.posts.last?.body, "Thermal rules are off.")
        XCTAssertTrue(m.isActive)
    }

    /// The hold turned off in Settings while the mode is held at fair: the
    /// next run (Settings queues one) switches it off. Turned off before
    /// the heat, the mode goes on at serious and off at fair, as before
    /// the hold.
    func testTurningTheHoldOffReleasesHeatLowPowerAtFair() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: true, thermal: .serious, lidClosed: false)
        await driver.run(battery: .percent(80), isCharging: true, thermal: .fair, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)

        m.config.thermalHoldUntilNominal = false
        await driver.run(battery: .percent(80), isCharging: true, thermal: .fair, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
        XCTAssertEqual(h.notifier.posts.last?.body, "Thermal state is back to fair.")

        await driver.run(battery: .percent(80), isCharging: true, thermal: .serious, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.last?.body, "Thermal state is serious. Low Power Mode is on until it cools down.")
        await driver.run(battery: .percent(80), isCharging: true, thermal: .fair, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn, "the mode stayed on at fair with the hold off")
        XCTAssertTrue(m.isActive)
    }

    /// Settings writes through `manager.config`. A change to a floor input
    /// asks for a floor run at once (`AppServices` points the hook at
    /// `reevaluateFloors()`), and no other change does.
    func testAFloorInputChangeAsksForAFloorRunAtOnce() async throws {
        let m = h.makeManager()
        var asked = 0
        m.floorInputsChanged = { asked += 1 }

        m.config.setLowPowerFloor(50)
        m.config.setEndFloor(20)
        m.config.thermalRules = false
        m.config.thermalHoldUntilNominal = false
        m.config.lowPowerOnLidClose = false
        XCTAssertEqual(asked, 5)

        m.config.hotspotSSID = "iPhone"
        m.config.presets = [600]
        m.config.muteOnLidClose = false
        m.config.setLowPowerFloor(50)
        XCTAssertEqual(asked, 5, "a change that is not a floor input, or no change, ran the floors")
    }

    /// The same path during a session, with the hook wired as `AppServices`
    /// wires it: each change runs the floors on inputs that have not moved,
    /// with no battery, thermal or lid event, and its effect is in the
    /// power calls, the journal and the session.
    func testSettingsChangesApplyWithoutAPowerEvent() async throws {
        let m = h.makeManager()
        m.config.thermalRules = false
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        var runs: [Task<Void, Never>] = []
        m.floorInputsChanged = {
            let previous = runs.last
            runs.append(Task { @MainActor in
                await previous?.value
                await driver.run(battery: .percent(45), isCharging: false, thermal: .serious, lidClosed: false)
            })
        }
        func settle() async { for run in runs { await run.value } }

        m.config.thermalRules = true
        await settle()
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 1", "turning the thermal rules on did not apply at once")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)

        m.config.thermalRules = false
        await settle()
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 0")
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)

        m.config.setLowPowerFloor(50)
        await settle()
        XCTAssertEqual(h.guardFake.calls.last, "lowpowermode 1", "a Low Power Mode floor raised above the charge did not apply at once")
        XCTAssertTrue(h.notifier.posts.last?.body.contains("below the 50% floor") ?? false)

        m.config.setEndFloor(50)
        await settle()
        XCTAssertFalse(m.isActive, "an end floor raised above the charge did not end the session at once")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// Flipping the lid option while the lid is closed takes effect on the
    /// next floor run (`AppServices.reevaluateFloors()` queues one).
    func testTogglingLidOptionWhileLidIsClosedAppliesOnTheNextRun() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(80), isCharging: true, thermal: .nominal, lidClosed: true)
        XCTAssertTrue(h.guardFake.lowPowerOn)

        m.config.lowPowerOnLidClose = false
        await driver.run(battery: .percent(80), isCharging: true, thermal: .nominal, lidClosed: true)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, false)

        m.config.lowPowerOnLidClose = true
        await driver.run(battery: .percent(80), isCharging: true, thermal: .nominal, lidClosed: true)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        XCTAssertEqual(h.notifier.posts.count, 0)
    }
}
