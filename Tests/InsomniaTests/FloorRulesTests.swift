import XCTest
@testable import Insomnia

final class FloorRulesTests: XCTestCase {
    /// nil is a machine with no battery (desktop).
    func eval(_ percent: Int?, charging: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, lid: Bool = false, lp: Bool = false, config: Config = Config()) -> [FloorRules.Action] {
        eval(battery: percent.map { .percent($0) } ?? .none, charging: charging, thermal: thermal, lid: lid, lp: lp, config: config)
    }

    func eval(battery: BatteryStatus, charging: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, lid: Bool = false, lp: Bool = false, config: Config = Config()) -> [FloorRules.Action] {
        FloorRules.evaluate(battery: battery, isCharging: charging, thermal: thermal, lidClosed: lid, lowPowerSetByUs: lp, config: config)
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

    func testThermalBackToNominalOrFairClearsLowPower() {
        XCTAssertEqual(eval(80, thermal: .nominal, lp: true), [.disableLowPower])
        XCTAssertEqual(eval(80, thermal: .fair, lp: true), [.disableLowPower])
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

    func cause(_ percent: Int?, charging: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, lid: Bool = false, config: Config = Config()) -> FloorRules.LowPowerCause? {
        FloorRules.lowPowerCause(percent: percent, isCharging: charging, thermal: thermal, lidClosed: lid, config: config)
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
    }

    func testLowPowerCauseHonorsTheOptions() {
        var c = Config()
        c.lowPowerOnLidClose = false
        c.thermalRules = false
        XCTAssertNil(cause(80, thermal: .serious, lid: true, config: c))
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
        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
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
    /// takes over, lid opens (thermal holds), cools down: announced.
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
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.notifier.posts.last?.title, "Low Power Mode off")
        XCTAssertEqual(h.notifier.posts.last?.body, "Back above the floor.")
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
