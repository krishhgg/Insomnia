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

    /// `dockerRule` nil keeps the shipped default (off); the tests here opt
    /// in so the Docker tree (400, 401) is part of the close.
    private func make(
        dockerIdle: @escaping @Sendable () async throws -> Bool = { true },
        dockerRule: Bool? = true,
        mute: Bool = true,
        sampler: BrightnessSampler? = nil,
        reassertDelay: Duration = .seconds(3600),
        lockTimeout: TimeInterval = 0.3,
        retryDelay: TimeInterval = 60
    ) async -> (SessionManager, LidActions) {
        let m = h.makeManager(lockTimeout: lockTimeout, retryDelay: retryDelay, reassertDelay: reassertDelay)
        m.config.muteOnLidClose = mute
        m.config.freezeList = ["com.tinyspeck.slackmacgap"]
        if let dockerRule { m.config.dockerRule = dockerRule }
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
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

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
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

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: true)
        await actions.onClose()
        await actions.onOpen()
        await driver.run(battery: .percent(80), isCharging: false, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0, 0.75])
        // Auto-brightness drift stays within the tolerance...
        h.display.brightness = 0.72
        // ...a key press does not.
        h.display.brightness = 0.4

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: false)
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
        await driver.run(battery: .percent(35), isCharging: false, thermal: .nominal, lidClosed: false)
        await actions.onClose()
        await actions.onOpen()
        await actions.onClose()
        XCTAssertEqual(h.display.sets, [0, 0.75, 0])

        await driver.run(battery: .percent(35), isCharging: true, thermal: .nominal, lidClosed: true)
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

    /// The recovery agent keeps a saved display brightness but cannot
    /// restore it. An end that could not restore it says so and when
    /// Insomnia tries again, without promising the agent's retry, and the
    /// next session's end restores it.
    func testAnEndThatCouldNotRestoreTheDisplayDoesNotLeaveItToTheAgent() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        h.display.throwOnSet = true

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, SessionManager.incompleteTitle)
        XCTAssertEqual(post.body, "could not restore display brightness: set brightness. The recovery agent cannot restore display brightness or keyboard backlight. Insomnia tries again when a later session ends, and at its next launch.")
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.7)

        h.display.throwOnSet = false
        await m.start(duration: 3600)
        await m.end(reason: .user)
        XCTAssertEqual(h.display.sets, [0, 0.7])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
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
        let speakers = Self.speakersSaved
        h.audio.onMute = {
            let s = (try? store.loadState()) ?? nil
            sawSaved.value = s?.savedAudioOutputs.map(\.withoutSaveID) == [speakers]
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
        XCTAssertEqual(s.savedAudioOutputs.map(\.withoutSaveID), [Self.speakersSaved])
        XCTAssertNotNil(s.savedAudioOutputs.first?.saveID, "each save has an ID of its own")
        XCTAssertNil(s.savedOutputVolume, "a lid close no longer writes the entry without a device")
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
        XCTAssertEqual(s.savedAudioOutputs, [])
        XCTAssertTrue(s.sleepDisabledByUs)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.remainingText, "58m")
    }

    static let speakersSaved = SavedAudioOutput(deviceUID: FakeAudioControl.speakers, name: FakeAudioControl.speakersName, volume: 0.6, muted: false, saveID: nil)
    static let headsetSaved = SavedAudioOutput(deviceUID: "usb-headset", name: "USB Headset", volume: 0.3, muted: false, saveID: nil)

    /// A session whose lid closed on the USB headset, which was then
    /// unplugged: the speakers are the default output, the headset is
    /// muted and owed its volume.
    private func closeOnTheHeadsetAndUnplugIt(lockTimeout: TimeInterval = 0.3, retryDelay: TimeInterval = 60) async -> (SessionManager, LidActions) {
        let (m, actions) = await make(lockTimeout: lockTimeout, retryDelay: retryDelay)
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        h.audio.disconnect("usb-headset")
        return (m, actions)
    }

    /// Lid open restores the device lid close muted, even when another
    /// output became the default while the lid was shut: the speakers get
    /// their volume back and the headset is left as it is.
    func testOpenRestoresTheMutedDeviceNotTheNewDefault() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.speakersSaved])
        XCTAssertEqual(h.audio.device(FakeAudioControl.speakers)?.muted, true)
        h.audio.connect("usb-headset", volume: 0.3)

        await actions.onOpen()

        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, [FakeAudioControl.speakers])
        XCTAssertEqual(h.audio.device(FakeAudioControl.speakers)?.volume, 0.6)
        XCTAssertEqual(h.audio.device(FakeAudioControl.speakers)?.muted, false)
        XCTAssertEqual(h.audio.device("usb-headset")?.volume, 0.3)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// A headset unplugged under the closed lid keeps its entry at lid
    /// open, and the speakers are left alone. A later close in the same
    /// session still mutes the speakers, in an entry of their own, and the
    /// next open restores them while the headset keeps waiting. The menu
    /// names it; once it is plugged back in, the device change restores it.
    func testAWaitingHeadsetDoesNotStopTheSpeakersBeingMuted() async throws {
        let (m, actions) = await closeOnTheHeadsetAndUnplugIt()

        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.volume, 0.6, "the speakers are left alone")
        XCTAssertFalse(h.audio.muted, "the speakers are left alone")
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertEqual(m.outputsWaitingForRestore.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertNil(m.lastError)

        await actions.onClose()
        XCTAssertTrue(h.audio.muted, "the speakers are muted though the headset is still owed its volume")
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved, Self.speakersSaved])

        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, [FakeAudioControl.speakers])
        XCTAssertEqual(h.audio.volume, 0.6)
        XCTAssertFalse(h.audio.muted)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        let lines = StatusItemController.menuItems(manager: m, status: RecordingStatusSource()).map(\.title)
        XCTAssertTrue(lines.contains("\u{26A0} USB Headset is still muted from a lid close; Insomnia restores it when it reconnects"), "\(lines)")
        XCTAssertTrue(lines.contains("Stop waiting for USB Headset"), "\(lines)")

        // macOS keeps a device's mute, so the headset comes back muted.
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, [FakeAudioControl.speakers, "usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.volume, 0.3)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
        XCTAssertEqual(m.outputsWaitingForRestore, [])
        XCTAssertTrue(m.isActive)
    }

    /// While a lid close is in effect, a device that reconnects is not
    /// unmuted: the lid open restores it with the rest.
    func testADeviceThatReconnectsUnderTheClosedLidWaitsForTheLidOpen() async throws {
        let (m, actions) = await closeOnTheHeadsetAndUnplugIt()
        await actions.onOpen()
        await actions.onClose()
        h.clamshell.closed = true
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)

        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        XCTAssertEqual(h.audio.device(FakeAudioControl.speakers)?.muted, true)

        h.clamshell.closed = false
        await actions.onOpen()
        XCTAssertEqual(Set(h.audio.applied.compactMap { $0.deviceUID }), [FakeAudioControl.speakers, "usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(h.audio.device(FakeAudioControl.speakers)?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// Quit with the muted headset unplugged: the session ends and sleep is
    /// restored, Quit goes through, and the headset's entry stays in the
    /// journal. The notification and the menu name it. Plugged back in
    /// while Insomnia runs, CoreAudio's device change restores it.
    func testQuitKeepsTheEntryOfAnUnpluggedDeviceAndItsReconnectRestoresIt() async throws {
        let (m, _) = await closeOnTheHeadsetAndUnplugIt()
        m.watchOutputDevices() // LaunchGate's call once the launch holds the alive lock

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .restored, "a device that is not connected does not hold up the end")
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(s.sleepDisabledByUs)
        XCTAssertEqual(s.frozenProcesses, [])
        XCTAssertEqual(s.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertFalse(h.audio.muted, "the speakers are not touched")
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session ended")
        XCTAssertEqual(post.body, "Insomnia quit. Sleep is back to normal. USB Headset was not connected, so it is still muted. Insomnia restores its volume when it reconnects while Insomnia is running, or at the next launch.")
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle })
        XCTAssertEqual(m.outputsWaitingForRestore.map(\.withoutSaveID), [Self.headsetSaved])

        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        h.audio.fireDevicesChanged()
        for _ in 0..<300 where h.audio.applied.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        for _ in 0..<300 where !m.outputsWaitingForRestore.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(m.outputsWaitingForRestore, [])
    }

    /// The headset was plugged back in while Insomnia was not running: the
    /// next launch restores it, quietly. A launch with it still unplugged
    /// keeps the entry and the menu line and posts nothing, so a device
    /// that stays away is not announced at every launch.
    func testALaterLaunchRestoresTheDeviceOnceItIsConnected() async throws {
        let (m, _) = await closeOnTheHeadsetAndUnplugIt()
        await m.end(reason: .quit)
        let posted = h.notifier.posts.count

        let away = h.makeManager()
        await away.reconcile()
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertEqual(away.outputsWaitingForRestore.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertEqual(h.notifier.posts.count, posted)
        XCTAssertNil(away.lastError)

        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        let back = h.makeManager()
        await back.reconcile()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(back.outputsWaitingForRestore, [])
        XCTAssertEqual(h.notifier.posts.count, posted)
    }

    /// The device came back and the user unmuted it and set a volume before
    /// Insomnia could restore it: that stands, and only the entry goes.
    func testARestoreLeavesADeviceTheUserUnmutedAlone() async throws {
        let (m, _) = await closeOnTheHeadsetAndUnplugIt()
        await m.end(reason: .user)
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.8, muted: false)

        await m.outputDevicesChanged()

        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.volume, 0.8)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// "Stop waiting for <device>" drops that entry, and only that one; the
    /// device stays as it is when it comes back.
    func testStopWaitingDropsOnlyThatDevicesEntry() async throws {
        let (m, actions) = await closeOnTheHeadsetAndUnplugIt()
        await actions.onOpen()
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved, Self.speakersSaved])

        await m.stopWaitingForOutput(try XCTUnwrap(m.outputsWaitingForRestore.first))

        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.speakersSaved])
        XCTAssertEqual(m.outputsWaitingForRestore, [])
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, [FakeAudioControl.speakers])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// The restore went through but clearing its entry did not: reported,
    /// not swallowed, and the entry stays. The retry finds the device
    /// unmuted and clears it without writing again.
    func testAnAudioRestoreWhoseJournalClearFailsIsReported() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        await actions.onClose()
        let file = h.home.paths.stateFile.path
        h.audio.onApply = { _ in try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file) }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onOpen()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertFalse(h.audio.muted)
        XCTAssertNotNil(m.lastError)
        // The later lid-close entries fail to clear too and take lastError.
        XCTAssertTrue(logText().contains("audio restored on MacBook Pro Speakers but the journal entry could not be cleared"), logText())
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.speakersSaved])

        h.audio.onApply = nil
        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// The headset was away at a lid open, then came back, and its restore
    /// fails at Quit. That try finds it connected, so it is owed, not
    /// waiting: the end is incomplete, the recovery agent is asked for, and
    /// with no agent the end stays pending, so Quit is refused. Nothing
    /// says the headset is not connected.
    func testADeviceThatCameBackAndThenFailsToRestoreHoldsUpTheEnd() async throws {
        let (m, actions) = await closeOnTheHeadsetAndUnplugIt()
        await actions.onOpen()
        XCTAssertEqual(m.outputsWaitingForRestore.map(\.withoutSaveID), [Self.headsetSaved])
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        h.audio.throwOnApply = true
        h.backstop.failArm = true

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .incomplete(agentArmed: false))
        XCTAssertEqual(m.pendingEnd, .quit, "the end is retried in process")
        XCTAssertEqual(m.outputsWaitingForRestore, [], "connected, so not waiting")
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, SessionManager.incompleteTitle)
        XCTAssertFalse(post.body.contains("not connected"), post.body)
        XCTAssertTrue(logText().contains("could not restore audio on USB Headset: apply failed"), logText())
    }

    /// A restore that fails on a connected device is retried by Insomnia
    /// itself. The recovery agent keeps the entry but cannot restore output
    /// volume, and the notification says that instead of promising the
    /// agent's retry. Once the device takes the write, the retry restores
    /// it.
    func testAFailedRestoreOnAConnectedDeviceIsRetriedInProcess() async throws {
        let (m, actions) = await make(retryDelay: 1)
        await m.start(duration: 3600)
        await actions.onClose()
        h.audio.throwOnApply = true

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertNil(m.pendingEnd)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, SessionManager.incompleteTitle)
        XCTAssertEqual(post.body, "could not restore audio on MacBook Pro Speakers: apply failed (OSStatus -1); kept in the journal to retry. The recovery agent cannot restore output volume. Insomnia tries again in 1 s while it runs, and at its next launch.")
        XCTAssertTrue(h.audio.muted)

        h.audio.throwOnApply = false
        for _ in 0..<500 where h.audio.applied.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, [FakeAudioControl.speakers])
        XCTAssertEqual(h.audio.volume, 0.6)
        XCTAssertFalse(h.audio.muted)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The headset reconnects while the backstop holds the recovery lock
    /// past the app's wait. CoreAudio sends that event once, so the refused
    /// restore is retried in process, and refused again while the lock is
    /// still held. Once the lock is free, the headset gets its volume back.
    func testAReconnectRefusedByABusyLockIsRetriedOnceTheLockIsFree() async throws {
        let (m, _) = await closeOnTheHeadsetAndUnplugIt(lockTimeout: 0.05, retryDelay: 0.2)
        await m.end(reason: .user)
        XCTAssertEqual(m.outputsWaitingForRestore.map(\.withoutSaveID), [Self.headsetSaved])
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())

        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertTrue(m.lastError?.hasPrefix("output device change skipped, nothing changed") == true, m.lastError ?? "nil")
        for _ in 0..<500 where !logText().contains("audio retry skipped") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(logText().contains("audio retry skipped"), "the retry ran while the lock was held")
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])

        held.release()
        for _ in 0..<500 where h.audio.applied.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.volume, 0.3)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        for _ in 0..<500 where !m.outputsWaitingForRestore.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.lastError, "the warning of the refused restore goes once the retry restores it")
    }

    /// A refused device change puts up a warning, and a start refused for
    /// the same busy lock puts up its own after it. When the audio is
    /// restored, only the audio's warning would go, and it is no longer
    /// the line shown: the start's warning stays.
    func testAnAudioRestoreLeavesANewerFailureInTheMenu() async throws {
        let (m, _) = await closeOnTheHeadsetAndUnplugIt(lockTimeout: 0.05)
        await m.end(reason: .user)
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        await m.outputDevicesChanged()
        XCTAssertTrue(m.lastError?.hasPrefix("output device change skipped, nothing changed") == true, m.lastError ?? "nil")
        await m.start(duration: 3600)
        held.release()
        let startRefused = try XCTUnwrap(m.lastError)
        XCTAssertTrue(startRefused.hasPrefix("start skipped, nothing changed"), startRefused)

        await m.outputDevicesChanged()

        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(m.lastError, startRefused)
    }

    /// The in-process retry stops after `audioRetryLimit` tries in a row,
    /// so a lock that stays busy does not keep it going. The entry stays,
    /// and the next device change starts over and restores the headset.
    func testTheAudioRetryStopsAfterItsLimitAndADeviceChangeStartsOver() async throws {
        let (m, _) = await closeOnTheHeadsetAndUnplugIt(lockTimeout: 0.02, retryDelay: 0.02)
        await m.end(reason: .user)
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())

        await m.outputDevicesChanged()
        let gaveUp = "still not checked or restored after \(SessionManager.audioRetryLimit) retries"
        for _ in 0..<1000 where !logText().contains(gaveUp) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(logText().contains(gaveUp), logText())
        XCTAssertEqual(logText().components(separatedBy: "audio retry skipped").count - 1, SessionManager.audioRetryLimit)
        held.release()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(h.audio.applied.count, 0, "nothing retries once the limit is reached")
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])

        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// A device change that arrives before the launch reconcile has taken
    /// the session on disk over, first before it ran and then after the
    /// recovery lock refused it, does not unmute a saved output while that
    /// session's lid is closed. The reconcile resumes the session with the
    /// output still muted, and the lid open restores it.
    func testADeviceChangeBeforeTheLaunchReconcileWaitsForTheLidOfTheSessionOnDisk() async throws {
        var s = RuntimeState()
        s.sleepDisabledByUs = true
        s.savedAudioOutputs = [Self.headsetSaved]
        try h.store.saveState(s)
        try h.store.saveSession(SessionMath.newSession(now: h.clock.now, duration: 3600, maxDuration: 86400))
        h.clamshell.closed = true
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        let m = h.makeManager(lockTimeout: 0.05)

        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)

        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        await m.reconcile()
        held.release()
        XCTAssertFalse(m.isActive, "the launch reconcile was refused")
        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])

        await m.reconcile()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)

        h.clamshell.closed = false
        await m.undoLidActions()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// A "Stop waiting" click queued behind the headset's reconnection
    /// restore and a new lid close: by the time it runs, the save it was
    /// for is gone and a later one is in its place. That save stays, with
    /// the headset connected and again once it is away and waiting, with
    /// the same values. The lid open restores it.
    func testAStaleStopWaitingItemDoesNotDropALaterSave() async throws {
        let (m, actions) = await closeOnTheHeadsetAndUnplugIt(lockTimeout: 5)
        await actions.onOpen()
        let stale = try XCTUnwrap(m.outputsWaitingForRestore.first)
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)

        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        let restore = await runUntilSuspended { await m.outputDevicesChanged() }
        let close = await runUntilSuspended { await actions.onClose() }
        let discard = await runUntilSuspended { await m.stopWaitingForOutput(stale) }
        held.release()
        await restore.value
        await close.value
        await discard.value

        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"], "the reconnection restored it")
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true, "the new close muted it")
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])

        h.audio.disconnect("usb-headset")
        await actions.onOpen()
        XCTAssertEqual(m.outputsWaitingForRestore.map(\.withoutSaveID), [Self.headsetSaved])
        await m.stopWaitingForOutput(stale)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])

        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        await actions.onOpen()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset", "usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// Two copies of the app share the journal, as the installed app and a
    /// `swift run` build can. The first shows "Stop waiting" for the
    /// headset's save. The second restores the headset when it is plugged
    /// back in, mutes it again at its own lid close with the same values,
    /// and the headset is unplugged again. Nothing in the first copy has
    /// changed since it built the item, but the item is for the old save:
    /// the click drops nothing. An item built for the new save drops it.
    func testAStopWaitingItemDoesNotDropAnotherCopysLaterSaveWithTheSameValues() async throws {
        let (first, firstActions) = await closeOnTheHeadsetAndUnplugIt()
        await firstActions.onOpen()
        let stale = try XCTUnwrap(first.outputsWaitingForRestore.first)
        XCTAssertNotNil(stale.saveID)

        let (second, secondActions) = await make()
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        await second.outputDevicesChanged()
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false, "the second copy restored it")
        await second.start(duration: 3600)
        await secondActions.onClose()
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true, "the second copy muted it again")
        let later = try XCTUnwrap(try h.store.loadState()?.savedAudioOutputs.first)
        XCTAssertEqual(later.withoutSaveID, stale.withoutSaveID, "the same device, name, volume and mute")
        XCTAssertNotEqual(later.saveID, stale.saveID)
        h.audio.disconnect("usb-headset")

        await first.stopWaitingForOutput(stale)

        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [later])
        XCTAssertTrue(logText().contains("stop waiting for USB Headset not done: the menu item was for an earlier save"), logText())
        XCTAssertEqual(first.outputsWaitingForRestore, [later], "the menu now shows the later save")

        await first.stopWaitingForOutput(later)

        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// Two copies of the app share the journal. The first is idle and read
    /// it clean at launch. The second closes the lid on the headset, the
    /// headset is unplugged, and the second copy quits: sleep is restored
    /// and the headset's save stays. When the headset is plugged back in,
    /// the first copy's device change finds that save on disk and restores
    /// it. The fake keeps one listener, so the test calls the first copy's
    /// handler itself, as CoreAudio calls each app's.
    func testAnIdleCopyRestoresAnotherCopysSaveWhenTheDeviceReconnects() async throws {
        let idle = h.makeManager()
        await idle.reconcile()
        XCTAssertEqual(idle.state.savedAudioOutputs, [])
        do {
            let (writer, _) = await closeOnTheHeadsetAndUnplugIt()
            let quit = await writer.end(reason: .quit)
            XCTAssertEqual(quit, .restored)
        }
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertEqual(idle.state.savedAudioOutputs, [], "the idle copy read the journal again")

        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        await idle.outputDevicesChanged()

        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.volume, 0.3)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(idle.lastError)
    }

    /// The same two copies, with the second copy's session running and its
    /// lid closed. The headset is plugged back in, and the idle copy, which
    /// has not seen the save, leaves it muted: the session on disk has the
    /// lid closed. The second copy's lid open restores it.
    func testAnIdleCopyLeavesAnotherCopysSaveMutedUnderItsClosedLid() async throws {
        let idle = h.makeManager()
        await idle.reconcile()
        let (writer, writerActions) = await closeOnTheHeadsetAndUnplugIt()
        h.clamshell.closed = true
        XCTAssertEqual(idle.state.savedAudioOutputs, [])

        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        await idle.outputDevicesChanged()

        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertNil(idle.lastError)

        h.clamshell.closed = false
        await writerActions.onOpen()
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
        XCTAssertTrue(writer.isActive)
    }

    /// A device change with nothing saved changes nothing. Refused by a
    /// busy lock, it cannot know that nothing is saved, so it says so in
    /// the menu and is retried; the retry finds nothing and takes the line
    /// down.
    func testADeviceChangeWithNothingSavedChangesNothing() async throws {
        let m = h.makeManager(lockTimeout: 0.05, retryDelay: 0.05)
        await m.reconcile()
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)

        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        XCTAssertNil(m.lastError)

        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        await m.outputDevicesChanged()
        XCTAssertTrue(m.lastError?.hasPrefix("output device change skipped, nothing changed") == true, m.lastError ?? "nil")
        held.release()
        for _ in 0..<500 where m.lastError != nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(m.lastError)
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true)
        XCTAssertEqual(try h.store.loadState() ?? .clean, RuntimeState.clean)
    }

    /// The headset came back after the menu was built, and the click runs
    /// before its device change does. A device that is connected is not
    /// waiting, so nothing is dropped, and the device change restores it.
    func testStopWaitingForADeviceThatIsBackDropsNothing() async throws {
        let (m, actions) = await closeOnTheHeadsetAndUnplugIt()
        await actions.onOpen()
        let item = try XCTUnwrap(m.outputsWaitingForRestore.first)
        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)

        await m.stopWaitingForOutput(item)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.headsetSaved])
        XCTAssertEqual(m.outputsWaitingForRestore, [])

        await m.outputDevicesChanged()
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }

    /// An entry an earlier build wrote, without the device, is restored on
    /// the default output as that build did, after the per-device ones.
    func testAnEntryFromAnEarlierBuildRestoresTheDefaultOutput() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        try m.journal { s in
            s.savedOutputVolume = 0.25
            s.savedMuted = false
        }
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.withoutSaveID), [Self.speakersSaved])

        await actions.onOpen()

        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, [FakeAudioControl.speakers, nil])
        XCTAssertEqual(h.audio.volume, 0.25)
        XCTAssertFalse(h.audio.muted)
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedAudioOutputs, [])
        XCTAssertNil(s.savedOutputVolume)
        XCTAssertNil(s.savedMuted)
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
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs ?? [], [])
    }

    func testMuteOffLeavesAudioAlone() async throws {
        let (m, actions) = await make(mute: false)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs ?? [], [])
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
        let end = await runUntilSuspended { await m.end(reason: .user) }
        await probe.open()
        await close.value
        _ = await end.value

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// A fresh config leaves Docker alone: the rule is opt in. The probe
    /// never runs.
    func testDockerRuleIsOffByDefault() async throws {
        let probes = Locked(0)
        let (m, actions) = await make(dockerIdle: { probes.value += 1; return true }, dockerRule: nil)
        XCTAssertFalse(m.config.dockerRule)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(probes.value, 0, "docker ps ran with the rule off")
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).dockerFrozen)
    }

    // MARK: Second idle check

    /// A probe that answers from a script, one entry per call, and records
    /// what it saw on disk at each call.
    private func scriptedProbe(_ answers: [Result<Bool, Error>], seen: Locked<[[Int32]]>? = nil) -> @Sendable () async throws -> Bool {
        let calls = Locked(0)
        let store = h.store
        return {
            let i = calls.value
            calls.value = i + 1
            if let seen {
                let s = (try? store.loadState()) ?? nil
                seen.value.append(s?.frozenPids ?? [])
            }
            return try answers[min(i, answers.count - 1)].get()
        }
    }

    /// The first probe says idle, the second (right before the SIGSTOP)
    /// finds a container: Docker is left running, its journal entries go
    /// away again, and the log says why.
    func testSecondIdleCheckBusyLeavesDockerAloneAndCleansTheJournal() async throws {
        let (m, actions) = await make(dockerIdle: scriptedProbe([.success(true), .success(false)]))
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]], "Docker was stopped although the second check was busy")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 101, 102])
        XCTAssertFalse(s.dockerFrozen)
        XCTAssertEqual(m.state, s)
        let log = logText()
        XCTAssertTrue(log.contains("docker rule: first check found no running container"), log)
        XCTAssertTrue(log.contains("second check found containers running, Docker left alone"), log)
        XCTAssertTrue(log.contains("Docker left running: the check before the signal said no"), log)

        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
    }

    /// The second probe fails (here: times out). Same outcome as busy.
    func testSecondIdleCheckFailureLeavesDockerAlone() async throws {
        let timeout = ShellTimeoutError.timedOut(exe: "docker", seconds: 5)
        let (m, actions) = await make(dockerIdle: scriptedProbe([.success(true), .failure(timeout)]))
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 101, 102])
        XCTAssertFalse(s.dockerFrozen)
        let log = logText()
        XCTAssertTrue(log.contains("second check failed, Docker left alone"), log)
        XCTAssertTrue(log.contains(timeout.localizedDescription), "the reason must be logged: \(log)")
    }

    /// The Docker flag was already set by an earlier freeze whose pid is
    /// still stopped. A busy second check for a new Docker child takes only
    /// that child's entry out and leaves the flag alone, as an undone
    /// freeze does.
    func testSecondIdleCheckBusyKeepsADockerFlagItDidNotSet() async throws {
        let (m, actions) = await make(dockerIdle: scriptedProbe([.success(true), .success(false)]), mute: false)
        m.config.darkenDisplayOnLidClose = false
        m.config.freezeList = []
        await m.start(duration: 3600)
        var earlier = try XCTUnwrap(try h.store.loadState())
        earlier.frozenProcesses = [FrozenProcess(pid: 400, startedAt: 4000)]
        earlier.dockerFrozen = true
        try h.store.saveState(earlier)
        h.procs.stoppedNow = [400]

        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [], "Docker was stopped although the second check was busy")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [FrozenProcess(pid: 400, startedAt: 4000)])
        XCTAssertTrue(s.dockerFrozen, "the busy check cleared a Docker flag an earlier freeze set")
        XCTAssertEqual(m.effectiveState, s)
    }

    /// Order on close: the first probe, then the journal write for Docker,
    /// then the second probe, then the SIGSTOP. The second probe sees the
    /// Docker entries already on disk; nothing else runs between it and
    /// the signal.
    func testSecondIdleCheckRunsAfterTheJournalWriteAndRightBeforeTheSignal() async throws {
        let events = Locked<[String]>([])
        let seen = Locked<[[Int32]]>([])
        let probe = scriptedProbe([.success(true), .success(true)], seen: seen)
        let (m, actions) = await make(dockerIdle: {
            events.value.append("probe")
            return try await probe()
        })
        await m.start(duration: 3600)
        h.procs.onSuspend = { pids in events.value.append("suspend \(pids)") }

        await actions.onClose()

        XCTAssertEqual(events.value, ["suspend [100, 101, 102]", "probe", "probe", "suspend [400, 401]"])
        XCTAssertEqual(seen.value, [[100, 101, 102], [100, 101, 102, 400, 401]], "the second probe must run after Docker's journal write")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 101, 102, 400, 401])
        XCTAssertTrue(s.dockerFrozen)
        // Both answers are in insomnia.log, so a release check can read them.
        let log = logText()
        XCTAssertTrue(log.contains("docker rule: first check found no running container"), log)
        XCTAssertTrue(log.contains("docker rule: second check found no running container"), log)
    }

    /// The first check finds a container: no second check, one log line.
    func testFirstCheckBusyIsLoggedAndSkipsTheSecond() async throws {
        let probes = Locked(0)
        let (m, actions) = await make(dockerIdle: { probes.value += 1; return false })
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(probes.value, 1)
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        let log = logText()
        XCTAssertTrue(log.contains("docker rule: first check found containers running, Docker left alone"), log)
        XCTAssertFalse(log.contains("second check"), log)
    }

    /// Returns once `m.end` has been entered: its first statement bumps
    /// endTicket, the value the close transaction checks after the second
    /// probe. Opening the probe gate before that would run the two requests
    /// one after the other and test nothing; a fixed number of yields does
    /// not guarantee the end task has run.
    private func waitUntilEndIsRequested(_ m: SessionManager, after ticket: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while m.endTicket == ticket, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(m.endTicket, ticket + 1, "the end was not requested while the second probe was held", file: file, line: line)
    }

    /// An end requested while the second probe is running wins, as it does
    /// for the first one: Docker is not frozen and the end finds nothing
    /// of it in the journal.
    func testSessionEndWhileTheSecondCheckIsSuspendedNeverFreezesDocker() async throws {
        let gate = AsyncGate()
        let calls = Locked(0)
        let (m, actions) = await make(dockerIdle: {
            calls.value += 1
            if calls.value == 2 { await gate.wait() }
            return true
        })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await gate.waitUntilStarted()

        let ticket = m.endTicket
        let end = Task { await m.end(reason: .user) }
        try await waitUntilEndIsRequested(m, after: ticket)
        await gate.open()
        await close.value
        _ = await end.value

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(logText().contains("session ending during the second check"), logText())
    }

    /// The same end during the second check, then a new session started
    /// with the lid open. The close transaction must not pause the
    /// countdown of the session that was ending, and the next session's
    /// countdown must tick: the real 1 Hz timer redraws it, not only a flag.
    func testEndDuringTheSecondCheckLeavesTheNextSessionsCountdownTicking() async throws {
        // The redraw timer fires on wall-clock time, so the fake clock
        // starts there and the first tick comes within a second.
        h.clock.now = Date()
        let gate = AsyncGate()
        let calls = Locked(0)
        let (m, actions) = await make(dockerIdle: {
            calls.value += 1
            if calls.value == 2 { await gate.wait() }
            return true
        })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await gate.waitUntilStarted()
        let ticket = m.endTicket
        let end = Task { await m.end(reason: .user) }
        try await waitUntilEndIsRequested(m, after: ticket)
        await gate.open()
        await close.value
        _ = await end.value
        XCTAssertFalse(m.isActive)

        XCTAssertEqual(h.clamshell.closed, false, "the lid is open for the new session")
        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertTrue(m.countdownTimerArmed, "a session started with the lid open has no countdown timer")
        let before = m.countdownText
        h.clock.advance(7)
        let deadline = Date().addingTimeInterval(5)
        while m.countdownText == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotEqual(m.countdownText, before, "the countdown did not tick")
    }

    /// Whether `task` finishes within `seconds`. It is not cancelled
    /// either way: a test that gets false opens its gate so the task ends.
    private func finishes(_ task: Task<Void, Never>, within seconds: Double) async -> Bool {
        let done = Locked(false)
        Task { await task.value; done.value = true }
        let deadline = Date().addingTimeInterval(seconds)
        while !done.value, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done.value
    }

    /// The lid opens while the second probe runs (a slow `docker ps`).
    /// AppServices numbers the open as it arrives and queues its undo
    /// behind the close, as here. The close stops waiting at once: Docker
    /// is never stopped, its entries leave the journal, and the open's undo
    /// runs while the probe is still out. The probe's late idle answer
    /// changes nothing.
    func testLidOpenDuringTheSecondCheckLeavesDockerAloneWithoutWaitingForTheProbe() async throws {
        let gate = AsyncGate()
        let calls = Locked(0)
        let (m, actions) = await make(dockerIdle: {
            calls.value += 1
            if calls.value == 2 { await gate.wait() }
            return true
        })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await gate.waitUntilStarted()

        actions.lidEventArrived()
        let open = Task {
            await close.value
            await actions.onOpen()
        }
        let undone = await finishes(open, within: 5)
        await gate.open()
        await open.value

        XCTAssertTrue(undone, "the lid open waited for the second probe")
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]], "Docker was stopped after the lid opened")
        XCTAssertEqual(h.procs.resumed, [[100, 101, 102]])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [])
        XCTAssertFalse(s.dockerFrozen)
        let log = logText()
        XCTAssertTrue(log.contains("docker rule: lid opened during the second check, Docker left alone"), log)

        // The probe's idle answer arrives after the gate opened. It is
        // still logged by the probe, but nothing acts on it.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
    }

    /// The lid opens while the first probe runs: Docker is not asked again
    /// and not journaled, and the close does not pause the countdown of a
    /// session whose lid is open again.
    func testLidOpenDuringTheFirstCheckLeavesDockerAloneAndTheCountdownRunning() async throws {
        let gate = AsyncGate()
        let calls = Locked(0)
        let (m, actions) = await make(dockerIdle: {
            calls.value += 1
            if calls.value == 1 { await gate.wait() }
            return true
        })
        await m.start(duration: 3600)
        let close = Task { await actions.onClose() }
        await gate.waitUntilStarted()

        actions.lidEventArrived()
        let closed = await finishes(close, within: 5)
        await gate.open()
        await close.value

        XCTAssertTrue(closed, "the close waited for the first probe after the lid opened")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls.value, 1, "Docker was asked again after the lid opened")
        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenPids, [100, 101, 102])
        XCTAssertFalse(s.dockerFrozen)
        XCTAssertTrue(m.countdownTimerArmed, "a close the lid open overtook paused the countdown")
        XCTAssertTrue(logText().contains("docker rule: lid opened during the first check, Docker left alone"), logText())

        await actions.onOpen()
        XCTAssertEqual(h.procs.resumed, [[100, 101, 102]])
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
    }

    /// A close still queued (behind the recovery lock or an earlier lid
    /// event) when the lid opens again does nothing when its turn comes:
    /// no darkening, no mute, no freeze, no countdown pause.
    func testACloseTheLidOpenOvertookBeforeItRanDoesNothing() async throws {
        let (m, actions) = await make()
        await m.start(duration: 3600)
        let close = actions.lidEventArrived()
        actions.lidEventArrived()

        await actions.onClose(event: close)

        XCTAssertEqual(h.procs.suspended, [])
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertTrue(m.countdownTimerArmed)
        XCTAssertTrue(logText().contains("lid close actions skipped: the lid opened again before they ran"), logText())
    }

    /// The lid observer reports changes only, so a session started with the
    /// lid already closed (an external display, a remote start) gets no
    /// close call. Its countdown starts paused from the lid reading, and
    /// the next lid open starts it.
    func testASessionStartedUnderAClosedLidHasNoCountdownTimerUntilTheLidOpens() async throws {
        let (m, actions) = await make()
        h.clamshell.closed = true
        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.countdownTimerArmed, "a session started under a closed lid redraws every second")

        h.clamshell.closed = false
        await actions.onOpen()
        XCTAssertTrue(m.countdownTimerArmed)
    }

    /// A session ends with the lid shut and the next one starts before it
    /// opens: the new session's countdown stays paused until the open.
    func testASessionStartedAfterAnEndUnderTheStillClosedLidKeepsTheCountdownPaused() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        await m.start(duration: 3600)
        h.clamshell.closed = true
        await actions.onClose()
        await m.end(reason: .timer)

        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.countdownTimerArmed, "the lid is still closed, but the countdown redraws every second")
        h.clamshell.closed = false
        await actions.onOpen()
        XCTAssertTrue(m.countdownTimerArmed)
    }

    /// Older than the Docker rule: a session that ends with the lid shut
    /// gets no lid open call (there is no session left), so the pause from
    /// its close must not carry into the next session.
    func testEndWithTheLidClosedDoesNotPauseTheNextSessionsCountdown() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertFalse(m.countdownTimerArmed)

        await m.end(reason: .timer)
        await actions.onOpen()
        await m.start(duration: 3600)

        XCTAssertTrue(m.countdownTimerArmed, "the next session inherited the lid-closed pause")
    }

    func testAudioReadFailureSkipsMuteButStillFreezes() async throws {
        let (m, actions) = await make()
        h.audio.throwOnRead = true
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 0)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs ?? [], [])
        XCTAssertEqual(h.procs.suspended.count, 2)
    }

    // MARK: Freeze every other app

    /// Figma (600 + helper 601) and Spotify (700) are Dock apps not on
    /// any list; Bartender (800) is a menu-bar (accessory) app.
    private func addDockAndAccessoryApps() {
        freezer.apps = apps + [
            RunningApp(pid: 600, bundleId: "com.figma.Desktop", name: "Figma"),
            RunningApp(pid: 700, bundleId: "com.spotify.client", name: "Spotify"),
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

    /// The defect behind the meeting-app list: with freeze-all on, a lid
    /// close stopped all 13 of Wispr Flow's processes and the meeting notes
    /// it was taking. Meeting, recording and dictation apps and their
    /// helpers keep running; the other Dock apps are still frozen.
    func testFreezeAllLeavesMeetingAndDictationAppsRunning() async throws {
        addDockAndAccessoryApps()
        // Wispr Flow (1000) with 12 helper processes, Zoom (1100), Zoom's
        // CptHost (1101) given a Dock app's policy so that only the helper
        // prefix keeps it out, and OBS (1200).
        freezer.apps += [
            RunningApp(pid: 1000, bundleId: "com.electron.wispr-flow", name: "Wispr Flow"),
            RunningApp(pid: 1100, bundleId: "us.zoom.xos", name: "zoom.us"),
            RunningApp(pid: 1101, bundleId: "us.zoom.CptHost", name: "CptHost"),
            RunningApp(pid: 1200, bundleId: "com.obsproject.obs-studio", name: "OBS"),
        ]
        let wisprFlow: [Int32] = Array(1000...1012)
        freezer.processes += wisprFlow.map { ProcessEntry(pid: $0, ppid: $0 == 1000 ? 1 : 1000, startedAt: Int64($0) * 10) } + [
            ProcessEntry(pid: 1100, ppid: 1, startedAt: 11000),
            ProcessEntry(pid: 1101, ppid: 1, startedAt: 11010),
            ProcessEntry(pid: 1200, ppid: 1, startedAt: 12000),
        ]
        let (m, actions) = await make()
        m.config.freezeAllApps = true
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [600, 601], [700], [400, 401]])
        let meeting = Set(wisprFlow + [1100, 1101, 1200])
        XCTAssertTrue(meeting.isDisjoint(with: h.procs.suspended.flatMap { $0 }), "a meeting or dictation process was stopped")
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [100, 101, 102, 600, 601, 700, 400, 401])
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

    /// A fresh config does not opt in to the automatic scope: with Dock
    /// apps running, only the freeze list (and idle Docker) is frozen.
    func testFreezeAllIsOffByDefault() async throws {
        addDockAndAccessoryApps()
        let (m, actions) = await make()
        XCTAssertFalse(m.config.freezeAllApps)
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102], [400, 401]])
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [100, 101, 102, 400, 401])
    }

    // MARK: Journal before signal

    /// Every candidate is on disk when its SIGSTOP goes out, but without
    /// identity, so the disk at that moment holds nothing recovery would
    /// resume. The confirming write gives Insomnia's own stops their
    /// identity and drops the pid the kernel refused.
    func testCandidatesAreJournaledWithoutIdentityBeforeTheStop() async throws {
        let (m, actions) = await make()
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let store = h.store
        let journaledFirst = Locked(true)
        h.procs.onSuspend = { pids in
            let s = (try? store.loadState()) ?? nil
            let mine = (s?.frozenProcesses ?? []).filter { pids.contains($0.pid) }
            if mine.map(\.pid) != pids || !mine.allSatisfy({ $0.identity == nil }) { journaledFirst.value = false }
        }

        await actions.onClose()

        XCTAssertTrue(journaledFirst.value, "SIGSTOP went out before the pid was on disk, or the entry already had an identity")
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

    /// The app can die between any two steps of a freeze: before the
    /// journal write, between that write and the SIGSTOP, between the
    /// SIGSTOP and the confirming write, or after it. The disk does not
    /// change across the signal itself, so three snapshots cover every gap.
    /// Pid 101 was stopped by somebody else before the close, so the
    /// SIGSTOP skipped it. A relaunch from any snapshot must never resume
    /// it, and resumes 100 and 102 only once their stop was confirmed.
    func testAppDeathBetweenAnyTwoFreezeStepsNeverResumesASkippedPid() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let store = h.store
        let atSignal = Locked<RuntimeState?>(nil)
        h.procs.onSuspend = { _ in atSignal.value = (try? store.loadState()) ?? nil }
        let beforeClose = try XCTUnwrap(try store.loadState())

        await actions.onClose()

        let snapshots: [(moment: String, disk: RuntimeState, resumed: [Int32])] = [
            ("before the journal write", beforeClose, []),
            ("between the journal write and the confirming write", try XCTUnwrap(atSignal.value), []),
            ("after the confirming write", try XCTUnwrap(try store.loadState()), [100, 102]),
        ]
        for (moment, disk, resumed) in snapshots {
            let relaunch = Harness()
            defer { relaunch.home.destroy() }
            try relaunch.store.saveState(disk)
            // 101 is stopped by its other owner; 100 and 102 are stopped
            // if Insomnia's SIGSTOP went out before the death.
            relaunch.procs.stoppedNow = [100, 101, 102]

            let m2 = relaunch.makeManager()
            await m2.reconcile()

            XCTAssertFalse(relaunch.procs.signaled.contains(101), "\(moment): SIGCONT to a process Insomnia never stopped")
            XCTAssertEqual(relaunch.procs.signaled, resumed, moment)
            let kept = try XCTUnwrap(try relaunch.store.loadState(), moment).frozenProcesses
            XCTAssertTrue(kept.allSatisfy { $0.identity == nil }, "\(moment): \(kept)")
            if !kept.isEmpty {
                let err = try XCTUnwrap(m2.lastError, moment)
                XCTAssertTrue(err.contains("Check each one first"), "\(moment): \(err)")
            }
        }
    }

    /// Fail closed: when the journal cannot be written, no SIGSTOP is sent.
    /// Nothing may be stopped without a durable record that resumes it.
    func testJournalWriteFailureBeforeTheStopSignalsNothing() async throws {
        let (m, actions) = await make(mute: false)
        m.config.darkenDisplayOnLidClose = false
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        // Rename over an immutable state.json is refused.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.procs.suspended, [], "SIGSTOP sent although the freeze could not be journaled")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [])
        XCTAssertFalse(s.dockerFrozen)
        XCTAssertEqual(m.state, s)
        let log = logText()
        XCTAssertTrue(log.contains("could not journal the freeze of Slack (com.tinyspeck.slackmacgap)"), log)
        XCTAssertTrue(log.contains("its 3 pid(s) were left running"), log)
        // The status menu shows it, not only the log; Docker failed last.
        let warning = try XCTUnwrap(m.lastError)
        XCTAssertTrue(warning.contains("could not journal the freeze of Docker (com.docker.docker)"), warning)

        await actions.onOpen()
        XCTAssertEqual(h.procs.signaled, [])
    }

    /// The confirming write fails after the SIGSTOPs went out. Nothing on
    /// disk could resume those stops, so the app resumes them at once. The
    /// disk refuses the cleanup write too, so the provisional entries stay
    /// on disk, but the status counts nothing frozen and shows the failure.
    /// The skipped pid is never signaled, then or on lid open. The first
    /// write the disk takes (here at lid open) drops all three entries, the
    /// skipped one included: that freeze never stopped it, as the
    /// confirming write would have recorded.
    func testStopsAreUndoneAtOnceWhenTheConfirmWriteFails() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { _ in
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(h.procs.cancelled, [[100, 102]], "the stops Insomnia made were not undone at once")
        XCTAssertEqual(h.procs.resumed, [], "a rollback through resume skips a stop that is still pending")
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenProcesses, [
            FrozenProcess(pid: 100, startedAt: nil),
            FrozenProcess(pid: 101, startedAt: nil),
            FrozenProcess(pid: 102, startedAt: nil),
        ], "the disk refused every write, so the provisional entries are still there")
        XCTAssertEqual(m.state, after)
        XCTAssertEqual(m.effectiveState.frozenProcesses, [], "the status still counts the undone freeze")
        XCTAssertNil(StatusLines.actions(frozenCount: m.effectiveState.frozenPids.count, dockerPaused: m.effectiveState.dockerFrozen, lastGap: nil))
        let warning = try XCTUnwrap(m.lastError, "the failure is only in the log")
        XCTAssertTrue(warning.contains("could not confirm the freeze of Slack (com.tinyspeck.slackmacgap) in the journal"), warning)
        XCTAssertTrue(warning.contains("resumed 2 of the 2 pid(s) it had just stopped, so this freeze of Slack is undone"), warning)
        XCTAssertTrue(logText().contains("could not clear the entries of an undone freeze from the journal"))

        // 101 is still stopped by its other owner; 100 and 102 run again.
        h.procs.stoppedNow = [101]
        await actions.onOpen()
        XCTAssertEqual(h.procs.signaled, [100, 102], "SIGCONT to a process Insomnia never stopped")
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
        XCTAssertEqual(m.effectiveState, m.state)
        XCTAssertFalse(m.lastError?.contains("journaled without identity") ?? false, "lid open reported a pid this freeze never stopped: \(m.lastError ?? "")")
    }

    /// The confirming write fails once and the disk takes the next write:
    /// the cleanup removes the undone entries right away, so the journal
    /// and the status agree, and the warning stays in the status menu.
    func testAnUndoneFreezeLeavesTheJournalWhenTheNextWriteSucceeds() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        h.procs.refuseSuspend = [101]
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { _ in
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        }
        h.procs.onCancelStops = { _ in
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()

        XCTAssertEqual(h.procs.cancelled, [[100, 102]])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenProcesses, [])
        XCTAssertEqual(m.state, after)
        XCTAssertEqual(m.effectiveState, after)
        let warning = try XCTUnwrap(m.lastError)
        XCTAssertTrue(warning.contains("so this freeze of Slack is undone"), warning)
        XCTAssertFalse(logText().contains("could not clear the entries of an undone freeze"))
    }

    /// Docker's freeze is undone while Slack's stands. The status counts
    /// Slack's three pids and no paused Docker, although the disk kept the
    /// Docker flag and Docker's provisional entries.
    func testAnUndoneDockerFreezeIsNotShownAsPaused() async throws {
        let (m, actions) = await make(mute: false)
        m.config.darkenDisplayOnLidClose = false
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { pids in
            if pids.contains(400) { try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file) }
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()

        XCTAssertEqual(h.procs.cancelled, [[400, 401]])
        let disk = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(disk.dockerFrozen)
        XCTAssertEqual(disk.frozenPids, [100, 101, 102, 400, 401])
        let status = m.effectiveState
        XCTAssertFalse(status.dockerFrozen, "Docker runs again but the status says paused")
        XCTAssertEqual(status.frozenPids, [100, 101, 102])
        XCTAssertEqual(StatusLines.actions(frozenCount: status.frozenPids.count, dockerPaused: status.dockerFrozen, lastGap: nil), "3 apps frozen")
        let warning = try XCTUnwrap(m.lastError)
        XCTAssertTrue(warning.contains("so this freeze of Docker is undone"), warning)
    }

    /// A pid the undo could not resume stays counted as frozen, and so does
    /// Docker, since part of it may still be stopped. The warning names it.
    func testAPidTheUndoCouldNotResumeStaysInTheStatus() async throws {
        let (m, actions) = await make(mute: false)
        m.config.darkenDisplayOnLidClose = false
        await m.start(duration: 3600)
        h.procs.failResume = [401]
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { pids in
            if pids.contains(400) { try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file) }
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()

        XCTAssertEqual(h.procs.signaled, [400])
        let status = m.effectiveState
        XCTAssertEqual(status.frozenPids, [100, 101, 102, 401])
        XCTAssertTrue(status.dockerFrozen)
        let warning = try XCTUnwrap(m.lastError)
        XCTAssertTrue(warning.contains("resumed 1 of the 2 pid(s) it had just stopped, and pid(s) 401 may still be stopped"), warning)
    }

    /// The Docker flag was already set by an earlier freeze whose pid is
    /// still stopped (a lid open could not resume it). Undoing this
    /// close's freeze of a new Docker child leaves that flag alone.
    func testAnUndoneFreezeKeepsADockerFlagItDidNotSet() async throws {
        let (m, actions) = await make(mute: false)
        m.config.darkenDisplayOnLidClose = false
        m.config.freezeList = []
        await m.start(duration: 3600)
        var earlier = try XCTUnwrap(try h.store.loadState())
        earlier.frozenProcesses = [FrozenProcess(pid: 400, startedAt: 4000)]
        earlier.dockerFrozen = true
        try h.store.saveState(earlier)
        h.procs.stoppedNow = [400]
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { _ in
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()

        XCTAssertEqual(h.procs.cancelled, [[401]])
        let status = m.effectiveState
        XCTAssertEqual(status.frozenProcesses, [FrozenProcess(pid: 400, startedAt: 4000)])
        XCTAssertTrue(status.dockerFrozen, "the undo cleared a Docker flag an earlier freeze set")
    }

    /// Owed edits go out before the write that carries them, so a Docker
    /// freeze journaled afterwards keeps its flag.
    func testOwedEditsAreWrittenBeforeTheNextChange() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        try m.journal { s in
            s.frozenProcesses = [FrozenProcess(pid: 400, startedAt: nil)]
            s.dockerFrozen = true
        }
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        m.clearUndoneFreeze(.init(pids: [400], docker: true))
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        XCTAssertEqual(try h.store.loadState()?.frozenPids, [400])
        XCTAssertEqual(m.effectiveState.frozenPids, [])
        XCTAssertFalse(m.effectiveState.dockerFrozen)

        try m.journal { s in
            s.frozenProcesses.append(FrozenProcess(pid: 500, startedAt: nil))
            s.dockerFrozen = true
        }

        let disk = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(disk.frozenPids, [500])
        XCTAssertTrue(disk.dockerFrozen)
        XCTAssertEqual(m.effectiveState, disk)
    }

    /// The kernel can still hold a SIGSTOP when the confirming write fails,
    /// so that target still looks running at the rollback. The rollback
    /// sends it SIGCONT anyway, which discards the pending stop. A rollback
    /// that signals only stopped processes would skip it, and it would stop
    /// a moment later with no journal entry able to resume it.
    func testAStopStillPendingWhenTheConfirmWriteFailsIsCancelled() async throws {
        let (m, actions) = await make(dockerIdle: { false })
        h.procs.delayedStops = [102]
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        h.procs.onSuspend = { _ in
            try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onClose()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.procs.suspended, [[100, 101, 102]])
        XCTAssertEqual(h.procs.cancelled, [[100, 101, 102]])
        XCTAssertEqual(h.procs.signaled, [100, 101, 102])
        XCTAssertEqual(h.procs.pendingStops, [], "the stop still pending at the rollback was not cancelled")
        h.procs.deliverPendingStops()
        XCTAssertEqual(h.procs.stoppedNow, [], "a pid stopped after the rollback, and nothing journaled can resume it")
        let log = logText()
        XCTAssertTrue(log.contains("resumed 3 of the 3 pid(s) it had just stopped"), log)
    }

    /// Entries without identity come from a build that journaled
    /// `frozenPids`, or from a freeze whose stop was never confirmed. The
    /// next launch must not resume them, and the message names both causes.
    func testIdentityLessEntriesFromAnOlderBuildAreNotResumedAfterRestart() async throws {
        var legacy = RuntimeState()
        legacy.frozenProcesses = [FrozenProcess(pid: 100, startedAt: nil), FrozenProcess(pid: 101, startedAt: nil)]
        try h.store.saveState(legacy)
        h.procs.stoppedNow = [100]

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(h.procs.signaled, [], "restart resumed a pid it cannot prove it stopped")
        let s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.frozenProcesses, [FrozenProcess(pid: 100, startedAt: nil)], "the stopped one stays for a person; the running one is gone")
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("older build"), err)
        XCTAssertTrue(err.contains("before the stop was confirmed in the journal"), err)
        XCTAssertTrue(err.contains("Check each one first"), "message must ask for verification before any CONT: \(err)")
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
