import XCTest
@testable import Insomnia

@MainActor
final class LidActionsTests: XCTestCase {
    var h: Harness!
    var freezer: FakeFreezer!

    let processes: [ProcessEntry] = [
        ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
        ProcessEntry(pid: 100, ppid: 1, startedAt: 1000),
        ProcessEntry(pid: 101, ppid: 100, startedAt: 1001),
        ProcessEntry(pid: 102, ppid: 100, startedAt: 1002),
        ProcessEntry(pid: 400, ppid: 1, startedAt: 4000),
        ProcessEntry(pid: 401, ppid: 400, startedAt: 4001),
    ]
    let apps: [RunningApp] = [
        RunningApp(pid: 100, bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
        RunningApp(pid: 400, bundleId: "com.docker.docker", name: "Docker"),
    ]

    override func setUp() async throws {
        h = Harness()
        freezer = FakeFreezer(apps: apps, processes: processes, control: h.procs)
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    private func make(
        dockerIdle: @escaping @Sendable () async throws -> Bool = { true },
        mute: Bool = true,
        sampler: BrightnessSampler? = nil,
        reassertDelay: Duration = .seconds(3600)
    ) async -> (SessionManager, LidActions) {
        let m = h.makeManager(reassertDelay: reassertDelay)
        m.config.muteOnLidClose = mute
        m.config.freezeList = ["com.tinyspeck.slackmacgap"]
        let docker = DockerRule(freezer: freezer, probe: dockerIdle)
        let actions = LidActions(manager: m, freezer: freezer, docker: docker, audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: sampler)
        return (m, actions)
    }

    /// A sampler over the harness fakes whose idle clock the test controls.
    private func makeSampler(idle: Locked<Double>) -> BrightnessSampler {
        BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { idle.value })
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    // MARK: Trusted brightness samples

    /// The live defect: the lid coming down covers the light sensor and
    /// auto-brightness has pulled the panel down (0.75 to 0.335) by the
    /// time the close is reported, with the user at the keyboard a moment
    /// ago and the panel awake. That read is trusted by the idle rule and
    /// still not the user's value: the last open-lid sample is journaled.
    /// The keyboard keeps the trusted current read.
    func testCloseJournalsTheLastOpenLidSampleOverTheCloseTimeRead() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        h.display.brightness = 0.75
        h.keyboard.brightness = 0.2
        sampler.sample()
        h.display.brightness = 0.335
        h.keyboard.brightness = 0.5

        await actions.onClose()

        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.75, "the sample, not the read under the closing lid")
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5, "the keyboard takes the trusted current read")
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertNil(m.lastError)
        XCTAssertTrue(logText().contains("display brightness reads 0.335 at the close; journaling the last open-lid sample 0.75"), logText())

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.75])
    }

    /// No sample yet (a close right after start, before the first sample
    /// could be taken): a trusted current read is journaled as before.
    func testCloseWithoutASampleJournalsTheTrustedCurrentRead() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        h.display.brightness = 0.7
        h.keyboard.brightness = 0.5

        await actions.onClose()

        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertNil(m.lastError)
    }

    /// The live defect: the lid closes after the panel idle-dimmed and
    /// slept. The display reads its dim value and the keyboard reads 0.
    /// Restoring those would leave a dim panel and a dead backlight; the
    /// last trusted sample is journaled instead. Both are still set to 0.
    func testAsleepAndSuppressedAtCloseJournalsTheLastTrustedSample() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        sampler.sample()
        idle.value = 400
        h.display.asleep = true
        h.display.brightness = 0.0625
        h.keyboard.suppressedOrDimmed = true
        h.keyboard.brightness = 0

        await actions.onClose()

        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7, "the idle-dim value was journaled")
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5, "the suppressed 0 was journaled")
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertNil(m.lastError)

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
    }

    /// Nothing trustworthy is known for the keyboard and it reads 0 under
    /// suppression: journaling that 0 would restore "off" on open, so the
    /// keyboard is left to macOS entirely. The display is still darkened.
    func testSuppressedKeyboardWithNoSampleIsLeftAlone() async throws {
        let idle = Locked<Double>(400)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        h.keyboard.suppressedOrDimmed = true
        h.keyboard.brightness = 0

        await actions.onClose()

        XCTAssertEqual(h.keyboard.sets, [], "a suppressed keyboard with nothing to restore must not be written")
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertNil(m.lastError)
        XCTAssertTrue(logText().contains("keyboard backlight suppressed by display sleep and no trusted sample; leaving it to macOS"), logText())

        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sets, [0, 0.7])
    }

    /// An asleep display with no sample: the dim value is journaled anyway
    /// and set to 0. A dim panel on open beats a black one; the
    /// brightness-up key is the manual fallback.
    func testAsleepDisplayWithNoSampleJournalsTheDimValue() async throws {
        let idle = Locked<Double>(400)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        h.display.asleep = true
        h.display.brightness = 0.0625

        await actions.onClose()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.0625)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertNil(m.lastError)
        XCTAssertTrue(logText().contains("display brightness read while dimmed or asleep and no trusted sample; restoring that value on open"), logText())
        XCTAssertFalse(logText().contains("[error] insomnia: display brightness read while dimmed"), "a known-dim save is a warning, not an error")

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.0625])
    }

    /// Without a sampler (tests, or a build that never wired one) the
    /// device's own asleep/suppressed reading decides on its own.
    func testWithoutASamplerTheDeviceStateAloneDecides() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        h.keyboard.suppressedOrDimmed = true
        h.keyboard.brightness = 0

        await actions.onClose()

        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
    }

    // MARK: Re-asserted restore

    // MARK: Low Power Mode and brightness

    /// The measured run: the session's battery floor switches Low Power
    /// Mode on, which rescales the panel (0.75 to 0.5); the sampler must
    /// not take that value. The manager asks for a sample just before the
    /// mode is taken, before the ownership is journaled, and the sample is
    /// held while the mode is ours.
    func testLowPowerEnableSamplesTheDisplayFirstAndHoldsTheSample() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, _) = await make(sampler: sampler)
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        var journaledAtSample: Bool?
        var callsAtSample: [String]?
        m.willEnableLowPower = { [weak m] in
            journaledAtSample = m?.state.lowPowerSetByUs
            callsAtSample = self.h.guardFake.calls
            sampler.sample()
        }
        await m.start(duration: 3600)
        h.display.brightness = 0.75

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertEqual(journaledAtSample, false, "sampled before the ownership was journaled")
        XCTAssertEqual(callsAtSample, ["disablesleep 1", "pmset -g custom"], "and before lowpowermode 1")
        XCTAssertEqual(sampler.last?.display, 0.75)

        // The mode's rescale is not taken.
        h.display.brightness = 0.5
        sampler.sample()
        XCTAssertEqual(sampler.last?.display, 0.75, "held under our Low Power Mode")
        h.keyboard.brightness = 0.3
        sampler.sample()
        XCTAssertEqual(sampler.last?.keyboard, 0.3, "the keyboard still samples")

        await driver.run(percent: 35, isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        h.display.brightness = 0.8
        sampler.sample()
        XCTAssertEqual(sampler.last?.display, 0.8, "released with the mode")
    }

    /// The measured run, end to end: the floor takes Low Power Mode, the
    /// lid closes (the held 0.75 is journaled, not the rescaled panel),
    /// opens (0.75 written under the mode), and the mode ends when the
    /// charger is connected: 0.75 goes out once more after `lowpowermode
    /// 0`, since the mode's end can leave the panel elsewhere, and is
    /// re-asserted like any restore.
    func testADisplayRestoredUnderOurLowPowerModeIsWrittenAgainWhenTheModeEnds() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler, reassertDelay: .zero)
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)
        h.display.brightness = 0.75
        let modeAtWrite = Locked<[Bool]>([])
        let guardFake = h.guardFake
        h.display.onSet = { _ in modeAtWrite.value.append(guardFake.lowPowerOn) }

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        h.display.brightness = 0.5
        sampler.sample()
        h.display.brightness = 0.335
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.75)
        await actions.onOpen()
        XCTAssertEqual(h.display.sets.prefix(2), [0, 0.75])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        for _ in 0..<300 where h.display.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.display.sets, [0, 0.75, 0.75], "the open's restore and its re-assert, under the mode")

        await driver.run(percent: 35, isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        for _ in 0..<300 where h.display.sets.count < 5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.display.sets, [0, 0.75, 0.75, 0.75, 0.75], "written again after the mode, and re-asserted")
        XCTAssertEqual(modeAtWrite.value, [true, true, true, false, false])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness, "not a journaled action")
        XCTAssertNil(m.lastError)
        XCTAssertTrue(logText().contains("display restored again after low power mode (brightness 0.75)"), logText())

        // Once written after the mode, it is done: the session end has
        // nothing to write.
        await m.end(reason: .user)
        XCTAssertEqual(h.display.sets.count, 5)
    }

    /// The other half of the measured run: the mode held until the session
    /// ended. The end switches the mode off first, then writes the value
    /// once more and re-asserts it; the open's own pending second write
    /// (display and keyboard) is folded into that re-assert, not dropped
    /// by the end's undo, which has nothing of its own to restore.
    func testSessionEndAfterAnOpenUnderOurLowPowerModeWritesTheRestoreAgainAfterTheMode() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler, reassertDelay: .milliseconds(150))
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)
        h.display.brightness = 0.75
        let modeAtWrite = Locked<[Bool]>([])
        let guardFake = h.guardFake
        h.display.onSet = { _ in modeAtWrite.value.append(guardFake.lowPowerOn) }

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.75])
        XCTAssertEqual(try h.store.loadState()?.displayRestoredUnderLowPower, 0.75, "the write owed after the mode is journaled")

        await m.end(reason: .user)
        XCTAssertEqual(h.display.sets, [0, 0.75, 0.75])
        XCTAssertEqual(modeAtWrite.value, [true, true, false], "the last write lands after lowpowermode 0")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.lastError)

        for _ in 0..<300 where h.display.sets.count < 4 || h.keyboard.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.display.sets, [0, 0.75, 0.75, 0.75], "re-asserted after the end")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5], "the open's keyboard second write is kept")
    }

    /// Lid-only Low Power Mode ends within the same lid transaction as the
    /// open: the display's write after the mode replaces the open's pending
    /// second write for the display only; the keyboard's still lands.
    func testTheModeEndingRightAfterTheOpenKeepsTheKeyboardSecondWrite() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler, reassertDelay: .milliseconds(150))
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)
        h.display.brightness = 0.75

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 80, isCharging: false, thermal: .nominal, lidClosed: true)
        await actions.onClose()
        await actions.onOpen()
        await driver.run(percent: 80, isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.display.sets, [0, 0.75, 0.75])

        for _ in 0..<300 where h.display.sets.count < 4 || h.keyboard.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.display.sets, [0, 0.75, 0.75, 0.75])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
        XCTAssertNil(try h.store.loadState()?.displayRestoredUnderLowPower)
    }

    /// The lid opened under a battery floor and the user then set the
    /// panel with the brightness keys. When the charger ends the mode hours
    /// later the panel is theirs: the write owed is dropped, not landed
    /// over their value.
    func testADisplayMovedSinceTheOpenIsLeftAloneWhenTheModeEnds() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler, reassertDelay: .milliseconds(150))
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)
        h.display.brightness = 0.75

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.75])
        // Auto-brightness drift stays within the tolerance...
        h.display.brightness = 0.72
        // ...a key press does not.
        h.display.brightness = 0.4

        await driver.run(percent: 35, isCharging: true, thermal: .nominal, lidClosed: false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.display.sets, [0, 0.75], "nothing written over the user's value")
        XCTAssertNil(try h.store.loadState()?.displayRestoredUnderLowPower)
        XCTAssertTrue(logText().contains("display restore after low power mode dropped: the display moved since the restore (0.4, restored 0.75)"), logText())

        // The open's pending second write is taken out with it; the
        // keyboard's still lands.
        for _ in 0..<300 where h.keyboard.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.display.sets, [0, 0.75], "the display's re-assert was dropped with it")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
    }

    /// A write owed from an earlier interval whose clear failed must not be
    /// found by a later one: taking the mode over discards it in the same
    /// journal write.
    func testTakingLowPowerOwnershipDiscardsAStaleWriteOwed() async throws {
        var st = RuntimeState()
        st.displayRestoredUnderLowPower = 0.3
        try h.store.saveState(st)
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, _) = await make(sampler: sampler)
        await m.start(duration: 3600)

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertTrue(h.guardFake.lowPowerOn)
        XCTAssertNil(try h.store.loadState()?.displayRestoredUnderLowPower)
        XCTAssertTrue(logText().contains("dropped: a new low power mode interval starts"), logText())

        await m.end(reason: .user)
        XCTAssertEqual(h.display.sets, [], "the stale 0.3 never lands")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// Relaunched under our mode after an open: the new sampler has no
    /// sample and is held, so a second close would journal the panel's
    /// rescaled reading. The value restored under the mode, still
    /// journaled as owed, is what the close journals instead.
    func testASecondCloseAfterARelaunchUnderOurModeJournalsTheValueOwedNotTheDimRead() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)
        h.display.brightness = 0.75
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        await actions.onClose()
        await actions.onOpen()

        let relaunched = h.makeManager()
        let freshSampler = makeSampler(idle: idle)
        freshSampler.displayHeld = { [weak relaunched] in relaunched?.state.lowPowerSetByUs ?? false }
        await relaunched.reconcile()
        XCTAssertTrue(relaunched.isActive)
        let freshActions = LidActions(manager: relaunched, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { true }), audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: freshSampler)
        freshSampler.sample()
        XCTAssertNil(freshSampler.last?.display, "held: nothing sampled under our mode")
        h.display.brightness = 0.5

        await freshActions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.75, "the value owed, not the rescaled read")
        await freshActions.onOpen()
        await relaunched.end(reason: .user)
        XCTAssertEqual(h.display.sets, [0, 0.75, 0, 0.75, 0.75])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The write owed after the mode is journaled, so a relaunch mid-session
    /// (the session still valid, the mode still ours) lands it at the end.
    func testTheWriteOwedAfterLowPowerIsJournaledAndSurvivesARelaunch() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)
        h.display.brightness = 0.75
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(try h.store.loadState()?.displayRestoredUnderLowPower, 0.75)

        // Relaunch over the same journal.
        let relaunched = h.makeManager()
        await relaunched.reconcile()
        XCTAssertTrue(relaunched.isActive, "the session on disk is still valid")
        XCTAssertEqual(try h.store.loadState()?.displayRestoredUnderLowPower, 0.75, "kept: the mode is still ours")

        await relaunched.end(reason: .user)
        XCTAssertEqual(h.display.sets, [0, 0.75, 0.75])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// An entry left behind after the mode was released (its clear failed)
    /// is not a value to journal at a close: with no sample the close takes
    /// the current read, as before.
    func testAnOrphanedWriteOwedIsNotJournaledAtACloseOnceTheModeIsReleased() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        await m.start(duration: 3600)
        try m.journal { $0.displayRestoredUnderLowPower = 0.3 }
        h.display.brightness = 0.7

        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7, "the read, not the orphan")
    }

    /// The mode was cleared by someone else (the backstop after a kill, or
    /// the user) and no session is left: the write is dropped, never landed
    /// on a panel that has been the user's for who knows how long.
    func testAWriteOwedAfterLowPowerIsDroppedWhenTheModeIsNotOurs() async throws {
        var st = RuntimeState()
        st.displayRestoredUnderLowPower = 0.75
        try h.store.saveState(st)
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(logText().contains("display restore after low power mode dropped: no session and the mode is not ours"), logText())
    }

    /// A Low Power Mode interval with no lid restore under it (the battery
    /// floor with the lid open throughout) writes nothing: the panel was
    /// never Insomnia's to set.
    func testLowPowerModeWithoutARestoreUnderItLeavesTheDisplayAlone() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, _) = await make(sampler: sampler)
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        await driver.run(percent: 35, isCharging: true, thermal: .nominal, lidClosed: false)
        await m.end(reason: .user)
        XCTAssertEqual(h.display.sets, [])
    }

    /// The lid closed again before the mode ended (the lid is not a cause
    /// here, the battery floor is, and the charger comes back under the
    /// closed lid): nothing is written under the closed lid, and the next
    /// open restores with the mode already off, so no second write is owed.
    func testLowPowerModeEndingUnderAClosedLidWritesNothingAndTheOpenRestoresOnce() async throws {
        let idle = Locked<Double>(3)
        let sampler = makeSampler(idle: idle)
        let (m, actions) = await make(sampler: sampler)
        m.config.lowPowerOnLidClose = false
        sampler.displayHeld = { [weak m] in m?.state.lowPowerSetByUs ?? false }
        m.willEnableLowPower = { sampler.sample() }
        await m.start(duration: 3600)
        h.display.brightness = 0.75

        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(percent: 35, isCharging: false, thermal: .nominal, lidClosed: false)
        await actions.onClose()
        await actions.onOpen()
        await actions.onClose()
        XCTAssertEqual(h.display.sets, [0, 0.75, 0])

        await driver.run(percent: 35, isCharging: true, thermal: .nominal, lidClosed: true)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(h.display.sets, [0, 0.75, 0], "nothing lit under the closed lid")
        XCTAssertTrue(logText().contains("display restore after low power mode dropped: darkened again"), logText())

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.75, 0, 0.75])
        await m.end(reason: .user)
        XCTAssertEqual(h.display.sets, [0, 0.75, 0, 0.75], "no write owed: the restore landed with the mode off")
    }

    /// powerd re-applies its own remembered brightness a moment after the
    /// wake and can override the restore, so the restore is written a
    /// second time after a delay. With the delay at zero both writes land.
    func testOpenReassertsTheRestoreAfterTheDelay() async throws {
        let (m, actions) = await make(reassertDelay: .zero)
        await m.start(duration: 3600)
        await actions.onClose()

        await actions.onOpen()

        for _ in 0..<300 where h.display.sets.count < 3 || h.keyboard.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.display.sets, [0, 0.7, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness, "the re-assert is not a journaled action")
        XCTAssertNil(s.savedKeyboardBrightness)
        XCTAssertNil(m.lastError)
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("display restore re-asserted"), log)
        XCTAssertTrue(log.contains("keyboard restore re-asserted"), log)
    }

    /// The lid closed again before the delayed re-assert ran: the close
    /// journaled fresh values before darkening, so the stale re-assert
    /// must skip rather than light the panel under a closed lid.
    func testReassertIsSkippedWhenTheLidClosedAgain() async throws {
        let (m, actions) = await make(reassertDelay: .milliseconds(200))
        await m.start(duration: 3600)
        await actions.onClose()
        await actions.onOpen()

        await actions.onClose()
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(h.display.sets, [0, 0.7, 0], "no 0.7 after the second close")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7, "the second close is journaled")
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("display restore re-assert skipped: darkened again"), log)
        XCTAssertFalse(log.contains("display restore re-asserted"), log)
    }

    /// A restore that failed is not re-asserted: there is nothing known to
    /// have been written, and the entry stays for the next undo.
    func testFailedRestoreIsNotReasserted() async throws {
        let (m, actions) = await make(reassertDelay: .zero)
        await m.start(duration: 3600)
        await actions.onClose()
        h.display.throwOnSet = true

        await actions.onOpen()

        for _ in 0..<300 where h.keyboard.sets.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
        XCTAssertEqual(h.display.sets, [0], "a display whose restore threw must not be written again")
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
    }

    /// The restore succeeded but clearing its journal entry did not: that
    /// is reported, not swallowed, and the entry stays so the next undo
    /// retries (writing the same value again is harmless).
    func testRestoreWhoseJournalClearFailsIsReported() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        let file = h.home.paths.stateFile.path
        h.display.onSet = { value in
            // Rename over an immutable state.json is refused.
            if value != 0 { try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file) }
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onOpen()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("restored but the journal entry could not be cleared"), err)
        XCTAssertTrue(err.contains("it will be retried"), err)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7, "the entry must stay for the next undo")
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)

        h.display.onSet = nil
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.7, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
    }

    // MARK: Display and keyboard backlight

    /// The saved brightness is on disk before the display or keyboard is
    /// touched: a crash between the two leaves a journal that restores.
    func testCloseJournalsBrightnessBeforeDarkening() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let store = h.store
        let displaySaw = Locked<Float?>(nil)
        h.display.onSet = { _ in displaySaw.value = ((try? store.loadState()) ?? nil)?.savedDisplayBrightness }
        let keyboardSaw = Locked<Float?>(nil)
        h.keyboard.onSet = { _ in keyboardSaw.value = ((try? store.loadState()) ?? nil)?.savedKeyboardBrightness }

        await actions.onClose()

        XCTAssertEqual(displaySaw.value, 0.7, "display set to 0 before its brightness was journaled")
        XCTAssertEqual(keyboardSaw.value, 0.5, "keyboard set to 0 before its backlight was journaled")
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(h.display.sleepRequests, 1)
        let s = try XCTUnwrap(try store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(m.state, s)
        XCTAssertNil(m.lastError)
    }

    /// Darkening is the first step, before mute and every freeze.
    func testDarkeningRunsBeforeMuteAndFreezes() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let order = Locked<[String]>([])
        h.display.onSet = { _ in order.value.append("display") }
        h.keyboard.onSet = { _ in order.value.append("keyboard") }
        h.audio.onMute = { order.value.append("mute") }
        h.procs.onSuspend = { _ in order.value.append("freeze") }

        await actions.onClose()

        XCTAssertEqual(order.value, ["display", "keyboard", "mute", "freeze", "freeze"])
    }

    /// A second close without an open in between (a crash, a reconcile with
    /// the lid still shut) reads 0 and must not overwrite the real values.
    func testSecondCloseKeepsTheFirstSavedBrightness() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.display.brightness, 0)
        XCTAssertEqual(h.keyboard.brightness, 0)

        await actions.onClose()

        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.display.sets, [0, 0])
        XCTAssertEqual(h.keyboard.sets, [0, 0])

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0, 0.5])
    }

    func testDisplayReadFailureSkipsTheDisplayButKeyboardAndFreezesStillRun() async throws {
        let (m, actions) = await make()
        h.display.throwOnRead = true
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [], "a display whose brightness is unknown must not be set")
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertNil(m.lastError, "a skipped display is logged, not surfaced as an error")

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [], "nothing saved, nothing restored")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
    }

    /// Setting 0 failed: the value is still journaled, so the open restores
    /// it (harmless if the panel never dimmed).
    func testDisplaySetFailureKeepsTheSavedValueForTheOpen() async throws {
        let (m, actions) = await make()
        h.display.throwOnSet = true
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertNil(m.lastError)

        h.display.throwOnSet = false
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.7])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
    }

    func testDarkenOffTouchesNeitherDisplayNorKeyboard() async throws {
        let (m, actions) = await make()
        m.config.darkenDisplayOnLidClose = false
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sleepRequests, 0)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness)
        XCTAssertNil(s.savedKeyboardBrightness)
        XCTAssertEqual(h.procs.suspended.count, 2, "the rest of the transaction still runs")

        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.wakes, 0)
    }

    /// Open: wake the panel first (a slept display lights before its
    /// brightness returns), restore both, clear both entries.
    func testOpenWakesThenRestoresBothAndClearsTheJournal() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        let display = h.display
        let wokeBeforeDisplaySet = Locked<Bool?>(nil)
        display.onSet = { value in if value != 0 { wokeBeforeDisplaySet.value = display.wakes == 1 } }
        let wokeBeforeKeyboardSet = Locked<Bool?>(nil)
        h.keyboard.onSet = { value in if value != 0 { wokeBeforeKeyboardSet.value = display.wakes == 1 } }

        await actions.onOpen()

        XCTAssertEqual(wokeBeforeDisplaySet.value, true, "display brightness restored before the panel was woken")
        XCTAssertEqual(wokeBeforeKeyboardSet.value, true)
        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness)
        XCTAssertNil(s.savedKeyboardBrightness)
        XCTAssertEqual(m.state, s)
        XCTAssertNil(m.lastError)
        XCTAssertTrue(m.isActive)
    }

    func testDisplayRestoreFailureKeepsTheEntryAndReportsIt() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.display.throwOnSet = true

        await actions.onOpen()

        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not restore display brightness"), err)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedDisplayBrightness, 0.7, "a failed restore stays journaled for the next undo")
        XCTAssertNil(s.savedKeyboardBrightness, "the keyboard is restored independently")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)

        // The next open retries from disk.
        h.display.throwOnSet = false
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.keyboard.sets, [0, 0.5], "already restored, not restored twice")
    }

    func testKeyboardRestoreFailureKeepsTheEntryAndReportsIt() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.keyboard.throwOnSet = true

        await actions.onOpen()

        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not restore keyboard backlight"), err)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(s.savedDisplayBrightness)
        XCTAssertEqual(s.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.display.sets, [0, 0.7])

        h.keyboard.throwOnSet = false
        await m.end(reason: .user)
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testSessionEndWhileClosedRestoresDisplayAndKeyboard() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()

        await m.end(reason: .timer)

        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// Display sleep is refused whenever any process holds a display
    /// assertion; brightness 0 is the mechanism, the sleep is a bonus.
    func testDisplaySleepRequestFailureIsOnlyLogged() async throws {
        let (m, actions) = await make()
        h.display.throwOnSleep = true
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertEqual(h.procs.suspended.count, 2)
        XCTAssertNil(m.lastError)
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("display sleep request failed"), log)
    }

    func testNoKeyboardBacklightSkipsTheKeyboard() async throws {
        let (m, actions) = await make()
        h.keyboard.brightness = nil
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)
        XCTAssertNil(m.lastError)

        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sets, [0, 0.7])
    }

    func testCloseJournalsBeforeActing() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let store = h.store

        // The fake audio's mute sees state.json already holding the saved values.
        let sawSaved = Locked(false)
        h.audio.onMute = {
            let s = (try? store.loadState()) ?? nil
            sawSaved.value = s?.savedOutputVolume == 0.6 && s?.savedMuted == false
        }
        // Each suspend sees its own pids already journaled.
        let sawPids = Locked(true)
        h.procs.onSuspend = { pids in
            let s = (try? store.loadState()) ?? nil
            if !Set(pids).isSubset(of: Set(s?.frozenPids ?? [])) { sawPids.value = false }
        }

        await actions.onClose()

        XCTAssertTrue(sawSaved.value, "mute ran before the journal was written")
        XCTAssertTrue(sawPids.value, "SIGSTOP ran before the pids were journaled")
        XCTAssertEqual(h.audio.mutes, 1)
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [400, 401]])
        let s = try XCTUnwrap(try store.loadState())
        // Identity travels with each pid so resume can prove it is the same process.
        XCTAssertEqual(s.frozenProcesses, [
            FrozenProcess(pid: 100, startedAt: 1000),
            FrozenProcess(pid: 101, startedAt: 1001),
            FrozenProcess(pid: 102, startedAt: 1002),
            FrozenProcess(pid: 400, startedAt: 4000),
            FrozenProcess(pid: 401, startedAt: 4001),
        ])
        XCTAssertTrue(s.dockerFrozen)
        XCTAssertEqual(s.savedOutputVolume, 0.6)
        XCTAssertEqual(s.savedMuted, false)
        XCTAssertEqual(m.state, s)
        XCTAssertTrue(m.isActive)
    }

    func testOpenRestoresFromDiskAndClears() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.clock.advance(120)

        await actions.onOpen()

        XCTAssertEqual(h.procs.resumed, [[100, 101, 102, 400, 401]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.volume, 0.6)
        XCTAssertEqual(h.audio.applied.first?.muted, false)
        XCTAssertFalse(h.audio.muted)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [])
        XCTAssertFalse(s.dockerFrozen)
        XCTAssertNil(s.savedOutputVolume)
        XCTAssertNil(s.savedMuted)
        XCTAssertTrue(s.sleepDisabledByUs)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.remainingText, "58m")
    }

    /// The whole lid-close transaction, each journal write and the side
    /// effect that follows it, runs under the recovery lock: a backstop that
    /// wakes up in between cannot restore from a journal whose SIGSTOP or
    /// mute is still pending. Checked from inside the fakes with a second
    /// attempt on the same lock file.
    func testLidCloseHoldsTheRecoveryLockAcrossJournalAndSideEffects() async throws {
        let lock = RecoveryLock(url: h.home.paths.recoveryLock)
        let busyAtMute = Locked<Bool?>(nil)
        let busyAtSuspend = Locked<[Bool]>([])
        let busyAtProbe = Locked<Bool?>(nil)
        h.audio.onMute = { busyAtMute.value = (try? lock.tryAcquire()) == nil }
        h.procs.onSuspend = { _ in busyAtSuspend.value.append((try? lock.tryAcquire()) == nil) }
        let (m, actions) = await make(dockerIdle: {
            busyAtProbe.value = (try? lock.tryAcquire()) == nil
            return true
        })
        await m.start(duration: 3600)
        await actions.onClose()

        XCTAssertEqual(busyAtMute.value, true, "mute ran without the recovery lock")
        XCTAssertEqual(busyAtSuspend.value, [true, true], "SIGSTOP ran without the recovery lock")
        XCTAssertEqual(busyAtProbe.value, true, "Docker probe ran outside the transaction")
        XCTAssertNotNil(try lock.tryAcquire(), "lock still held after the transaction")
    }

    func testOpenTwiceIsIdempotent() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        await actions.onOpen()
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
    }

    func testOpenWithCleanStateDoesNothing() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.audio.applied.count, 0)
    }

    func testNoSessionIsNoop() async throws {
        let (_, actions) = await make()
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.procs.suspended, [])
        XCTAssertEqual(h.procs.resumed, [])
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
    }

    func testMuteOffLeavesAudioAlone() async throws {
        let (m, actions) = await make(mute: false)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.count, 0)
    }

    func testDockerWithContainersIsLeftAlone() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).dockerFrozen)
    }

    func testDockerProbeErrorLeavesDockerAlone() async throws {
        let (m, actions) = await make(dockerIdle: { throw ShellTimeoutError.timedOut(exe: "docker", seconds: 5) })
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).dockerFrozen)
    }

    func testDockerRuleOffSkipsDocker() async throws {
        let (m, actions) = await make()
        m.config.dockerRule = false
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
    }

    func testSessionEndWhileClosedRestoresEverything() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        await m.end(reason: .timer)
        XCTAssertEqual(h.procs.resumed, [[100, 101, 102, 400, 401]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        // Lid open afterwards: no session, nothing happens.
        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed.count, 1)
        XCTAssertEqual(h.audio.applied.count, 1)
    }

    func testSessionEndWhileDockerProbeIsSuspendedNeverFreezesDocker() async throws {
        let probe = AsyncGate()
        let (m, actions) = await make(dockerIdle: {
            await probe.wait()
            return true
        })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await probe.waitUntilStarted()

        // The end queues behind the lid-close transaction; release the probe
        // first, then wait for both.
        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        await probe.open()
        await close.value
        _ = await end.value

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    func testAudioReadFailureSkipsMuteButStillFreezes() async throws {
        let (m, actions) = await make()
        h.audio.throwOnRead = true
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        XCTAssertEqual(h.procs.suspended.count, 2)
    }

    // MARK: Freeze every other app

    /// Figma (600 + helper 601) and Wispr Flow (700) are Dock apps not on
    /// any list; Bartender (800) is a menu-bar (accessory) app.
    private func addDockAndAccessoryApps() {
        freezer.apps = apps + [
            RunningApp(pid: 600, bundleId: "com.figma.Desktop", name: "Figma"),
            RunningApp(pid: 700, bundleId: "com.electron.wispr-flow", name: "Wispr Flow"),
            RunningApp(pid: 800, bundleId: "com.surteesstudios.Bartender", name: "Bartender", activationPolicy: .accessory),
        ]
        freezer.processes = processes + [
            ProcessEntry(pid: 600, ppid: 1, startedAt: 6000),
            ProcessEntry(pid: 601, ppid: 600, startedAt: 6001),
            ProcessEntry(pid: 700, ppid: 1, startedAt: 7000),
            ProcessEntry(pid: 800, ppid: 1, startedAt: 8000),
        ]
    }

    /// With the toggle on, every regular app outside the denylist is frozen
    /// after the explicit list; the accessory app is never touched. Each
    /// group is journaled before its SIGSTOP, as for the explicit list.
    func testFreezeAllFreezesRegularAppsButNotAccessoryApps() async throws {
        addDockAndAccessoryApps()
        let (m, actions) = await make()
        m.config.freezeAllApps = true
        await m.start(duration: 3600)
        let store = h.store
        let sawPids = Locked(true)
        h.procs.onSuspend = { pids in
            let s = (try? store.loadState()) ?? nil
            if !Set(pids).isSubset(of: Set(s?.frozenPids ?? [])) { sawPids.value = false }
        }

        await actions.onClose()

        XCTAssertTrue(sawPids.value, "SIGSTOP ran before the pids were journaled")
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [600, 601], [700], [400, 401]])
        XCTAssertFalse(h.procs.suspended.flatMap { $0 }.contains(800), "accessory app frozen")
        let s = try XCTUnwrap(try store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 101, 102, 600, 601, 700, 400, 401])
        XCTAssertTrue(s.frozenProcesses.allSatisfy { $0.identity != nil })
        XCTAssertEqual(m.state, s)

        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [[100, 101, 102, 600, 601, 700, 400, 401]])
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
    }

    func testFreezeAllOffFreezesTheListOnly() async throws {
        addDockAndAccessoryApps()
        let (m, actions) = await make()
        m.config.freezeAllApps = false
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [400, 401]])
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [100, 101, 102, 400, 401])
    }

    /// A helper that was already stopped before the lid closed (a debugger,
    /// the user, an earlier crash) is not Insomnia's to freeze: it is never
    /// journaled and never resumed on lid open.
    func testProcessStoppedBeforeTheSessionIsNeverOwned() async throws {
        freezer.processes = [
            ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
            ProcessEntry(pid: 100, ppid: 1, startedAt: 1000),
            ProcessEntry(pid: 101, ppid: 100, startedAt: 1001),
            ProcessEntry(pid: 102, ppid: 100, startedAt: 1002, stopped: true),
            ProcessEntry(pid: 400, ppid: 1, startedAt: 4000),
            ProcessEntry(pid: 401, ppid: 400, startedAt: 4001),
        ]
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101], [400, 401]])
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [100, 101, 400, 401])

        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [[100, 101, 400, 401]])
        XCTAssertFalse(h.procs.resumed.flatMap { $0 }.contains(102), "SIGCONT sent to a process Insomnia never stopped")
    }

    /// The kernel is re-checked at SIGSTOP time. A pid it would not stop
    /// (already stopped, exited, reused) was journaled first and must leave
    /// the journal, or a later resume would claim it.
    func testPidTheKernelWouldNotStopIsDroppedFromTheJournal() async throws {
        let (m, actions) = await make()
        h.procs.refuseSuspend = [101, 400, 401]
        await m.start(duration: 3600)
        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [400, 401]])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 102])
        XCTAssertFalse(s.dockerFrozen, "Docker marked frozen although no Docker pid was stopped")

        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [[100, 102]])
    }

    // MARK: Provisional freeze entries

    /// Until the kernel has reported which pids it stopped, the journal must
    /// not claim any of them. Entries are written without identity first
    /// and only the confirmed SIGSTOPs gain one.
    func testCandidatesAreJournaledWithoutIdentityUntilTheKernelConfirmsTheStop() async throws {
        let (m, actions) = await make()
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let store = h.store
        let provisional = Locked(true)
        h.procs.onSuspend = { pids in
            let s = (try? store.loadState()) ?? nil
            let mine = (s?.frozenProcesses ?? []).filter { pids.contains($0.pid) }
            if mine.map(\.pid) != pids || !mine.allSatisfy({ $0.identity == nil }) { provisional.value = false }
        }

        await actions.onClose()

        XCTAssertTrue(provisional.value, "candidates were journaled as owned before the kernel confirmed the stop")
        let s = try XCTUnwrap(try store.loadState())
        XCTAssertEqual(s.frozenProcesses, [
            FrozenProcess(pid: 100, startedAt: 1000),
            FrozenProcess(pid: 102, startedAt: 1002),
            FrozenProcess(pid: 400, startedAt: 4000),
            FrozenProcess(pid: 401, startedAt: 4001),
        ])
        XCTAssertTrue(s.dockerFrozen)
        XCTAssertEqual(m.state, s)
    }

    /// Greptile P1: a skipped pid whose removal from the journal fails must
    /// not stay recorded as owned, or the next resume SIGCONTs a process
    /// Insomnia never stopped. Whatever the failed confirmation leaves on
    /// disk has to be non-resumable.
    func testSkippedPidWhoseConfirmationSaveFailsIsNeverResumed() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { _ in
            // The confirmation write after SIGSTOP fails: rename over an
            // immutable state.json is refused.
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenPids, [100, 101, 102])
        XCTAssertTrue(after.frozenProcesses.allSatisfy { $0.identity == nil },
                      "failed confirmation left ownership evidence on disk: \(after.frozenProcesses)")
        XCTAssertEqual(m.state, after)

        // 100 and 102 were stopped by Insomnia. 101 is stopped too, but by
        // somebody else: that is why the kernel refused our SIGSTOP. Nothing
        // on disk distinguishes them, so none may be resumed.
        h.procs.stoppedNow = [100, 101, 102]
        await actions.onOpen()
        XCTAssertFalse(h.procs.signaled.contains(101), "SIGCONT sent to a process Insomnia never stopped")
        XCTAssertEqual(h.procs.signaled, [], "provisional entries were treated as ownership")
        let opened = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(opened.frozenPids, [100, 101, 102], "stopped pids without proof must all stay for manual recovery")
        XCTAssertTrue(opened.frozenProcesses.allSatisfy { $0.identity == nil }, "\(opened.frozenProcesses)")
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("100, 101, 102"), err)
        XCTAssertTrue(err.contains("interrupted"), "message must name an unconfirmed freeze as a cause: \(err)")
        XCTAssertTrue(err.contains("Check each one first"), "message must ask for verification before any CONT: \(err)")
    }

    /// A crash between the provisional write and the confirmation leaves
    /// identity-less entries. The next launch must not resume them.
    func testProvisionalEntriesLeftByACrashAreNotResumedAfterRestart() async throws {
        var crashed = RuntimeState()
        crashed.frozenProcesses = [FrozenProcess(pid: 100, startedAt: nil), FrozenProcess(pid: 101, startedAt: nil)]
        try h.store.saveState(crashed)
        h.procs.stoppedNow = [100]

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(h.procs.signaled, [], "restart resumed a pid it cannot prove it stopped")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [FrozenProcess(pid: 100, startedAt: nil)], "the stopped one stays for a person; the running one is gone")
        XCTAssertNotNil(m.lastError)
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T
    init(_ v: T) { _v = v }
    var value: T {
        get { lock.withLock { _v } }
        set { lock.withLock { _v = newValue } }
    }
}
