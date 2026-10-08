import XCTest
@testable import Insomnia

/// Insomnia's Low Power Mode journaled on in boot A over a display value
/// kept after a refused restore, and read off in boot B. The user or
/// another tool may have switched the mode off a moment before that read,
/// and the panel comes back from it over a time nobody has measured, so a
/// mode that reads off does not show the panel is back. The switch-off
/// counts as the mode's end in boot B whatever the mode reads: the kept
/// entry waits, the display is not sampled, and a close does not darken
/// it, until a launch in a later boot. The user's level is never written
/// over. Fake devices and a temporary home only.
@MainActor
final class EarlierBootLowPowerClaimTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws { h = Harness() }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: h.home.paths.stateFile.path)
        h.home.destroy()
        h = nil
    }

    private enum SessionLeft { case none, expired, valid }

    /// The journal boot A leaves when the app is gone with the mode on:
    /// sleep and Low Power Mode ours over the kept `saved`, the mode
    /// recorded over `recorded` in `boot`.
    private func seedClaimFromBootA(
        session: SessionLeft = .expired,
        saved: Float = 0.8,
        refused: Bool = true,
        recorded: Float? = 0.8,
        boot: String? = "boot A",
        readLit: Float? = nil
    ) throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.lowPowerSetByUs = true
        st.savedDisplayBrightness = saved
        st.displayRestoreRefused = refused
        st.keptDisplayUnderLowPower = recorded
        st.keptDisplayUnderLowPowerBoot = recorded == nil ? nil : boot
        st.keptDisplayReadLit = readLit
        try h.store.saveState(st)
        let now = h.clock.now
        switch session {
        case .none:
            break
        case .expired:
            try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-3600)))
        case .valid:
            try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3000)))
        }
    }

    private func follow(_ m: SessionManager) -> BrightnessSampler {
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        return sampler
    }

    private func lidActions(_ m: SessionManager, sampler: BrightnessSampler) -> LidActions {
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        m.config.darkenDisplayOnLidClose = true
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        return LidActions(manager: m, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { true }), audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: sampler)
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    private func setJournalImmutable(_ on: Bool) throws {
        try FileManager.default.setAttributes([.immutable: on], ofItemAtPath: h.home.paths.stateFile.path)
    }

    private func closeAndOpen(_ actions: LidActions) async {
        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()
    }

    private let readOff = "low power mode, journaled as ours before the Mac last started, reads off; it may have gone off only a moment ago, with the panel still on its way back, so it is switched off as ours in this boot"

    /// The kept 0.8 waits with the record of it for boot B: nothing
    /// written, and the display neither sampled nor sampleable.
    private func assertHeldInBootB(_ sampler: BrightnessSampler, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try XCTUnwrap(try h.store.loadState(), label, file: file, line: line)
        XCTAssertFalse(s.lowPowerSetByUs, label, file: file, line: line)
        XCTAssertEqual(s.savedDisplayBrightness, 0.8, label, file: file, line: line)
        XCTAssertTrue(s.displayRestoreRefused, label, file: file, line: line)
        XCTAssertEqual(s.keptDisplayUnderLowPower, 0.8, label, file: file, line: line)
        XCTAssertEqual(s.keptDisplayUnderLowPowerBoot, "boot B", label, file: file, line: line)
        XCTAssertEqual(h.display.sets, [], label, file: file, line: line)
        XCTAssertNil(sampler.last?.display, label, file: file, line: line)
        XCTAssertNil(sampler.sample()?.display, "\(label): the sampler holds the display", file: file, line: line)
    }

    private enum Route: String {
        /// No session.json: the launch restores the dirty journal.
        case reconcileWithNoSession
        /// The session ran out while the Mac was off.
        case reconcileOfAnExpiredSession
        /// A session still running after the restart, and the mode
        /// switched off from the menu or a floor.
        case setLowPowerOffInASession
        /// The same session, and the check after a power command.
        case lowPowerCheckInASession
        /// The same session, ended by the user.
        case endOfASession
    }

    /// Boot B: the panel reads 0.4 on its way back from a mode switched
    /// off a moment ago, and the app switches the claim off by `route`.
    /// Neither 0.4 nor the user's 0.6 after it is taken: the entry waits
    /// through ordinary transactions, two quick close and open cycles that
    /// leave the display lit and only ask it to sleep, an end and a
    /// relaunch in boot B. A launch in boot C takes 0.6, the sampler
    /// follows the panel again, and a close and an open bring back the
    /// user's level. 0.4 is never written.
    private func checkTheSwitchOffHoldsTheKeptValue(_ route: Route) async throws {
        let label = route.rawValue
        let inSession = route == .setLowPowerOffInASession || route == .lowPowerCheckInASession || route == .endOfASession
        try seedClaimFromBootA(session: route == .reconcileWithNoSession ? .none : inSession ? .valid : .expired)
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(bootSession: "boot B")
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)

        await m.reconcile()
        switch route {
        case .reconcileWithNoSession, .reconcileOfAnExpiredSession:
            XCTAssertNil(m.session, label)
        case .setLowPowerOffInASession:
            XCTAssertNotNil(m.session, label)
            XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.4 while our low power mode, journaled on before the Mac last started, may still be on"), "\(label): \(logText())")
            let off = await m.setLowPower(false)
            XCTAssertTrue(off, label)
            await m.undoLidActions()
        case .lowPowerCheckInASession:
            XCTAssertNotNil(m.session, label)
            await m.settleAfterCommand()
            await m.undoLidActions()
        case .endOfASession:
            XCTAssertNotNil(m.session, label)
            let ended = await m.end(reason: .user)
            XCTAssertEqual(ended, .restored, label)
        }

        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"), "\(label): \(h.guardFake.calls)")
        try assertHeldInBootB(sampler, label)
        if route != .lowPowerCheckInASession {
            XCTAssertTrue(logText().contains(readOff), "\(label): \(logText())")
        }
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.4 after our low power mode was or may have been on in this run, which rescales it until some time after it goes off; that is not taken as a level set since"), "\(label): \(logText())")

        // The user's level, with the panel back: not taken either.
        h.display.brightness = 0.6
        await m.undoLidActions()
        try assertHeldInBootB(sampler, label)
        XCTAssertTrue(logText().contains("reads 0.6 after our low power mode was or may have been on in this run"), "\(label): \(logText())")

        if m.session == nil { await m.start(duration: 3600) }
        XCTAssertNotNil(m.session, label)
        let sleepRequests = h.display.sleepRequests
        await closeAndOpen(actions)
        await closeAndOpen(actions)
        XCTAssertEqual(h.display.sets, [], "\(label): the display is not darkened")
        XCTAssertEqual(h.display.brightness, 0.6, label)
        XCTAssertEqual(h.display.sleepRequests, sleepRequests + 2, "\(label): only asked to sleep")
        XCTAssertTrue(logText().contains("display brightness reads 0.6 at the close after our low power mode was or may have been on in this run, which rescales it until some time after it goes off; the value kept after a refused restore, 0.8, stays journaled and undecided, and the display is not darkened"), "\(label): \(logText())")
        try assertHeldInBootB(sampler, label)
        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored, label)
        try assertHeldInBootB(sampler, label)

        let relaunched = h.makeManager(bootSession: "boot B")
        let relaunchedSampler = follow(relaunched)
        await relaunched.reconcile()
        try assertHeldInBootB(relaunchedSampler, "\(label), relaunched in boot B")
        XCTAssertTrue(logText().contains("reads 0.6 after our low power mode was or may have been on over it since the Mac last started"), "\(label): \(logText())")

        let restarted = h.makeManager(bootSession: "boot C")
        let newSampler = follow(restarted)
        let newActions = lidActions(restarted, sampler: newSampler)
        await restarted.reconcile()
        let released = try XCTUnwrap(try h.store.loadState(), label)
        XCTAssertNil(released.savedDisplayBrightness, label)
        XCTAssertNil(released.keptDisplayUnderLowPower, label)
        XCTAssertEqual(h.display.sets, [], label)
        XCTAssertEqual(newSampler.last?.display, 0.6, label)
        h.display.brightness = 0.65
        XCTAssertEqual(newSampler.sample()?.display, 0.65, "\(label): the sampler follows the panel again")
        await restarted.start(duration: 3600)
        await closeAndOpen(newActions)
        XCTAssertEqual(h.display.sets, [0, 0.65], label)
        XCTAssertEqual(h.display.brightness, 0.65, label)
        _ = await restarted.end(reason: .user)
        XCTAssertFalse(h.display.sets.contains(0.4), "\(label): \(h.display.sets)")
    }

    func testAReconcileWithNoSessionHoldsTheKeptValueAfterAClaimReadOff() async throws {
        try await checkTheSwitchOffHoldsTheKeptValue(.reconcileWithNoSession)
    }

    func testAReconcileOfAnExpiredSessionHoldsTheKeptValueAfterAClaimReadOff() async throws {
        try await checkTheSwitchOffHoldsTheKeptValue(.reconcileOfAnExpiredSession)
    }

    func testASwitchOffInASessionHoldsTheKeptValueAfterAClaimReadOff() async throws {
        try await checkTheSwitchOffHoldsTheKeptValue(.setLowPowerOffInASession)
    }

    func testTheCheckAfterAPowerCommandHoldsTheKeptValueAfterAClaimReadOff() async throws {
        try await checkTheSwitchOffHoldsTheKeptValue(.lowPowerCheckInASession)
    }

    func testAnEndOfASessionHoldsTheKeptValueAfterAClaimReadOff() async throws {
        try await checkTheSwitchOffHoldsTheKeptValue(.endOfASession)
    }

    /// The cost. The mode went off long before this launch and the panel
    /// has been at the user's 0.6 since; nothing tells that apart from a
    /// mode switched off a moment ago. In boot B the entry stays in
    /// state.json, the display is not sampled, and a close does not
    /// darken the display, only asks it to sleep, while the keyboard
    /// still goes dark. The user's 0.6 is never written over. A launch in
    /// boot C takes 0.6.
    func testAModeLongOffStillHoldsTheDisplayUntilALaterBoot() async throws {
        try seedClaimFromBootA()
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.6
        let m = h.makeManager(bootSession: "boot B")
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)

        await m.reconcile()

        try assertHeldInBootB(sampler, "long off")
        XCTAssertTrue(logText().contains(readOff), logText())
        let calls = h.guardFake.calls
        let read = try XCTUnwrap(calls.firstIndex(of: "pmset -g custom"), "\(calls)")
        let off = try XCTUnwrap(calls.firstIndex(of: "lowpowermode 0"), "\(calls)")
        XCTAssertLessThan(read, off, "\(calls)")

        await m.start(duration: 3600)
        let sleepRequests = h.display.sleepRequests
        h.clamshell.closed = true
        await actions.onClose()
        XCTAssertEqual(h.display.sets, [], "the display is not darkened")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertEqual(h.display.sleepRequests, sleepRequests + 1, "only asked to sleep")
        XCTAssertEqual(h.keyboard.sets, [0], "the keyboard still goes dark")
        h.clamshell.closed = false
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.6)
        _ = await m.end(reason: .user)
        try assertHeldInBootB(sampler, "long off, ended")

        let restarted = h.makeManager(bootSession: "boot C")
        let newSampler = follow(restarted)
        await restarted.reconcile()
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(newSampler.last?.display, 0.6)
        XCTAssertEqual(h.display.sets, [])
    }

    /// The control: with no claim and no kept entry, nothing holds the
    /// display. The sampler follows the panel, and a close and an open
    /// darken it and bring back the user's level.
    func testWithNoClaimOrKeptEntryTheDisplayIsSampledAndDarkened() async throws {
        h.clamshell.closed = false
        h.display.brightness = 0.6
        let m = h.makeManager(bootSession: "boot B")
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        await m.reconcile()

        XCTAssertEqual(sampler.sample()?.display, 0.6)
        await m.start(duration: 3600)
        await closeAndOpen(actions)
        XCTAssertEqual(h.display.sets, [0, 0.6])
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertFalse(h.guardFake.calls.contains("pmset -g custom") || h.guardFake.calls.contains("lowpowermode 0"), "\(h.guardFake.calls)")
        _ = await m.end(reason: .user)
    }

    /// The boot evidence a claim can come with: a record of this boot, of
    /// an earlier boot, no record, a record with no boot or an empty one,
    /// and a launch that cannot read its own boot. With the mode reading
    /// off, each one waits through the switch-off and through a relaunch
    /// in the same boot. Only the record of an earlier boot is read
    /// before the switch-off; the others count as this boot's from the
    /// launch, as before.
    func testEveryBootEvidenceWaitsThroughASwitchOffThatReadsOff() async throws {
        let cases: [(name: String, recorded: Float?, boot: String?, launch: String, reads: Bool)] = [
            ("record of this boot", 0.8, "boot B", "boot B", false),
            ("record of an earlier boot", 0.8, "boot A", "boot B", true),
            ("no record", nil, nil, "boot B", false),
            ("record with no boot", 0.8, nil, "boot B", false),
            ("record with an empty boot", 0.8, "", "boot B", false),
            ("launch boot unreadable", 0.8, "boot A", "", false),
        ]
        for c in cases {
            h.home.destroy()
            h = Harness()
            try seedClaimFromBootA(recorded: c.recorded, boot: c.boot)
            h.guardFake.lowPowerOn = false
            h.clamshell.closed = false
            h.display.brightness = 0.4
            let m = h.makeManager(bootSession: c.launch)
            let sampler = follow(m)

            await m.reconcile()

            XCTAssertEqual(h.guardFake.calls.contains("pmset -g custom"), c.reads, "\(c.name): \(h.guardFake.calls)")
            XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"), c.name)
            let after = try XCTUnwrap(try h.store.loadState(), c.name)
            XCTAssertFalse(after.lowPowerSetByUs, c.name)
            XCTAssertEqual(after.savedDisplayBrightness, 0.8, c.name)
            XCTAssertEqual(after.keptDisplayUnderLowPower, 0.8, c.name)
            XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, c.launch, c.name)
            XCTAssertEqual(h.display.sets, [], c.name)
            XCTAssertNil(sampler.last?.display, c.name)

            h.display.brightness = 0.6
            let relaunched = h.makeManager(bootSession: c.launch)
            let relaunchedSampler = follow(relaunched)
            await relaunched.reconcile()

            XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8, c.name)
            XCTAssertEqual(h.display.sets, [], c.name)
            XCTAssertNil(relaunchedSampler.last?.display, c.name)
        }
    }

    /// The claim is placed in boot A only while its record matches the
    /// entry. A saved value replaced since the record, or an entry no
    /// longer flagged as refused, keeps the rules it had: the claim counts
    /// as this boot's from the launch and the mode is not read. The
    /// replaced value waits under a record of its own value; the
    /// unflagged entry is an ordinary one, written back over the 0 its
    /// close left, and no record is made for it.
    func testAReplacedValueOrFlagKeepsTheRulesItHad() async throws {
        try seedClaimFromBootA(saved: 0.7)
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let replaced = h.makeManager(bootSession: "boot B")
        let replacedSampler = follow(replaced)
        await replaced.reconcile()

        XCTAssertFalse(h.guardFake.calls.contains("pmset -g custom"), "\(h.guardFake.calls)")
        let value = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(value.lowPowerSetByUs)
        XCTAssertEqual(value.savedDisplayBrightness, 0.7)
        XCTAssertTrue(value.displayRestoreRefused)
        XCTAssertEqual(value.keptDisplayUnderLowPower, 0.7)
        XCTAssertEqual(value.keptDisplayUnderLowPowerBoot, "boot B")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(replacedSampler.last?.display)

        h.home.destroy()
        h = Harness()
        try seedClaimFromBootA(refused: false)
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0
        let unflagged = h.makeManager(bootSession: "boot B")
        let unflaggedSampler = follow(unflagged)
        await unflagged.reconcile()

        XCTAssertFalse(h.guardFake.calls.contains("pmset -g custom"), "\(h.guardFake.calls)")
        let flag = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(flag.lowPowerSetByUs)
        XCTAssertNil(flag.savedDisplayBrightness)
        XCTAssertNil(flag.keptDisplayUnderLowPower)
        XCTAssertNil(flag.keptDisplayUnderLowPowerBoot)
        XCTAssertNil(flag.displayRestoredUnderLowPower)
        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(unflaggedSampler.last?.display, 0.8)
    }

    /// Zero readings after the claim reads off. Once a reading above 0 in
    /// boot A showed the darkening undone, a 0 writes nothing, and the
    /// user's 0.6 after it is not taken either, until boot C. With no such
    /// reading, a 0 is the darkening the close left, and the kept 0.8 is
    /// written as for any restore, the mode already off.
    func testZeroReadingsAfterAClaimReadOff() async throws {
        try seedClaimFromBootA(readLit: 0.8)
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(bootSession: "boot B")
        let sampler = follow(m)
        await m.reconcile()

        try assertHeldInBootB(sampler, "0 after a reading above 0")
        XCTAssertEqual(try h.store.loadState()?.keptDisplayReadLit, 0.8)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0 after our low power mode was or may have been on in this run, which rescales it until some time after it goes off, after a reading above 0 showed its darkening undone; that 0 may be a level set since, so the kept value is not written"), logText())

        h.display.brightness = 0.6
        await m.undoLidActions()
        try assertHeldInBootB(sampler, "0.6 after the 0")

        let restarted = h.makeManager(bootSession: "boot C")
        let newSampler = follow(restarted)
        await restarted.reconcile()
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(newSampler.last?.display, 0.6)
        XCTAssertEqual(h.display.sets, [])

        h.home.destroy()
        h = Harness()
        try seedClaimFromBootA()
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0
        let dark = h.makeManager(bootSession: "boot B")
        let darkSampler = follow(dark)
        await dark.reconcile()

        XCTAssertEqual(h.display.sets, [0.8])
        let written = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(written.savedDisplayBrightness)
        XCTAssertNil(written.displayRestoredUnderLowPower, "the mode is already off")
        XCTAssertNil(written.keptDisplayUnderLowPower)
        XCTAssertEqual(darkSampler.last?.display, 0.8)
    }

    /// state.json refuses every change in boot B. The switch-off goes
    /// through, its clear is owed, and so is the reading above 0: the disk
    /// keeps the claim next to the record of boot A, and this process
    /// holds the entry and the sampler. The end owes that reading, so
    /// Quit waits and Start is refused. Once the journal takes writes,
    /// the first transaction's write lands the clear, the reading and the
    /// record of boot B together; the retried end lets Quit go, and a
    /// session started after it leaves the user's 0.6 as set.
    func testARefusedClearHoldsInThisProcessAndLandsWithTheRecordOfBootB() async throws {
        try seedClaimFromBootA()
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(retryDelay: 3600, bootSession: "boot B")
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        try setJournalImmutable(true)

        await m.reconcile()

        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"), "\(h.guardFake.calls)")
        let disk = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(disk.lowPowerSetByUs, "the journal refused the clear")
        XCTAssertEqual(disk.keptDisplayUnderLowPowerBoot, "boot A")
        XCTAssertNil(disk.keptDisplayReadLit)
        XCTAssertFalse(m.effectiveState.lowPowerSetByUs)
        XCTAssertEqual(m.effectiveState.savedDisplayBrightness, 0.8)
        XCTAssertEqual(m.effectiveState.keptDisplayReadLit, 0.8)
        XCTAssertNotNil(m.keptDisplayReadDoubt)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)
        XCTAssertNil(sampler.sample()?.display)

        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .incomplete(agentArmed: false))
        XCTAssertFalse(quit.letsQuitGo, "the reading above 0 is in this process only")
        XCTAssertEqual(m.pendingEnd, .quit)
        await m.start(duration: 3600)
        XCTAssertNil(m.session, "Start is refused while the end is pending")

        h.display.brightness = 0.6
        try setJournalImmutable(false)
        await m.undoLidActions()

        let landed = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(landed.lowPowerSetByUs)
        XCTAssertEqual(landed.keptDisplayReadLit, 0.8)
        try assertHeldInBootB(sampler, "the first write after the repair")

        let retried = await m.end(reason: .user)
        XCTAssertEqual(retried, .restored)
        XCTAssertTrue(retried.letsQuitGo)
        XCTAssertNil(m.pendingEnd)
        try assertHeldInBootB(sampler, "the retried end")

        await m.start(duration: 3600)
        XCTAssertNotNil(m.session, "Start works once the end has gone through")
        await closeAndOpen(actions)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.6)
        try assertHeldInBootB(sampler, "a close and an open")
        _ = await m.end(reason: .user)
    }

    /// The same refusal, with the reading above 0 already journaled in
    /// boot A, so the end owes the agent only the claim it can see: Quit
    /// goes, with the disk still claiming the mode next to the record of
    /// boot A. A relaunch in boot B with state.json still refusing reads
    /// the claim as from boot A again and holds the entry in its process;
    /// one with the journal writable lands the clear with the record of
    /// boot B. Neither takes a reading of the panel, and boot C does.
    func testASameBootRelaunchHoldsWhetherTheJournalRefusesTheClearOrTakesIt() async throws {
        try seedClaimFromBootA(readLit: 0.8)
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(retryDelay: 3600, bootSession: "boot B")
        let sampler = follow(m)
        try setJournalImmutable(true)
        await m.reconcile()
        XCTAssertNil(sampler.last?.display)

        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .incomplete(agentArmed: true))
        XCTAssertTrue(quit.letsQuitGo)
        let disk = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(disk.lowPowerSetByUs)
        XCTAssertEqual(disk.keptDisplayUnderLowPowerBoot, "boot A")

        h.display.brightness = 0.6
        let refused = h.makeManager(retryDelay: 3600, bootSession: "boot B")
        let refusedSampler = follow(refused)
        await refused.reconcile()

        XCTAssertEqual(refused.effectiveState.savedDisplayBrightness, 0.8)
        XCTAssertFalse(refused.effectiveState.lowPowerSetByUs)
        XCTAssertNotNil(refused.keptDisplayReadDoubt)
        XCTAssertEqual(try h.store.loadState()?.keptDisplayUnderLowPowerBoot, "boot A")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(refusedSampler.last?.display)

        try setJournalImmutable(false)
        let permitted = h.makeManager(bootSession: "boot B")
        let permittedSampler = follow(permitted)
        await permitted.reconcile()
        try assertHeldInBootB(permittedSampler, "the permitted relaunch")

        let restarted = h.makeManager(bootSession: "boot C")
        let newSampler = follow(restarted)
        await restarted.reconcile()
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(newSampler.last?.display, 0.6)
        XCTAssertEqual(h.display.sets, [])
    }

    /// The same refusal with the reading above 0 journaled. The user
    /// starts a session once the journal takes writes: the start's first
    /// write lands the owed clear with the record of boot B, and the
    /// session's close and open leave the user's 0.6 as set.
    func testAStartAfterARefusedClearLandsItWithTheRecordOfBootB() async throws {
        try seedClaimFromBootA(readLit: 0.8)
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(retryDelay: 3600, bootSession: "boot B")
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        try setJournalImmutable(true)
        await m.reconcile()
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).lowPowerSetByUs)

        try setJournalImmutable(false)
        h.display.brightness = 0.6
        await m.start(duration: 3600)

        XCTAssertNotNil(m.session)
        try assertHeldInBootB(sampler, "the start")
        await closeAndOpen(actions)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.6)
        try assertHeldInBootB(sampler, "a close and an open")
        _ = await m.end(reason: .user)
    }
}
