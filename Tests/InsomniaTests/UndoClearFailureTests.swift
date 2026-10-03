import XCTest
@testable import Insomnia

/// An undo that went through but whose journal entry could not be cleared
/// is shown in the menu (`lastError`) as well as logged, and the entry stays
/// on disk for the retry. state.json is made immutable for the write: the
/// rename over it is refused, while it still reads.
@MainActor
final class UndoClearFailureTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: h.home.paths.stateFile.path)
        h.home.destroy()
    }

    private func lockJournal(_ locked: Bool) throws {
        try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: h.home.paths.stateFile.path)
    }

    private func assertShown(_ m: SessionManager, _ prefix: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let error = try XCTUnwrap(m.lastError, "the failed clear was not shown", file: file, line: line)
        XCTAssertTrue(error.hasPrefix("\(prefix) but the journal entry could not be cleared"), error, file: file, line: line)
        XCTAssertTrue(error.hasSuffix("it will be retried"), error, file: file, line: line)
    }

    /// The end's `disablesleep 0` exits 0 and the clear fails: the end is
    /// incomplete, its notification carries the reason, and the next end
    /// runs the undo again and finishes, which takes the line away.
    func testEndWhoseSleepClearFailsSaysSoAndRunsTheUndoAgain() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        try lockJournal(true)

        let outcome = await m.end(reason: .user)

        try lockJournal(false)
        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the entry went with the failed write")
        try assertShown(m, "sleep restored")
        let notice = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertTrue(notice.body.hasPrefix("sleep restored but the journal entry could not be cleared"), notice.body)

        let again = await m.end(reason: .user)
        XCTAssertEqual(again, .restored)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0", "disablesleep 0"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(m.lastError, "the line still says a clear that went through will be retried")
    }

    /// The end's `lowpowermode 0` exits 0 and the clear fails.
    func testEndWhoseLowPowerClearFailsSaysSo() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        // Sleep stays journaled for its own reason, so the low power line
        // is the last one written.
        h.guardFake.throwOn = ["disablesleep 0"]
        try lockJournal(true)

        _ = await m.end(reason: .user)

        try lockJournal(false)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        try assertShown(m, "low power mode cleared")
    }

    /// A floor switching the mode off: `lowpowermode 0` exits 0 and the
    /// clear fails.
    func testSwitchOffWhoseClearFailsSaysSo() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        try lockJournal(true)

        let off = await m.setLowPower(false)

        try lockJournal(false)
        XCTAssertTrue(off)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        try assertShown(m, "low power mode switched off")
    }

    /// `lowpowermode 1` applies and then fails; the rollback's
    /// `lowpowermode 0` exits 0 and its clear fails.
    func testRollbackWhoseClearFailsSaysSo() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let gate = AsyncGate()
        h.guardFake.lowPowerGate = gate
        h.guardFake.throwAfterEffect = ["lowpowermode 1"]
        let enabling = Task { await m.setLowPower(true) }
        await gate.waitUntilStarted()
        // Ownership is on disk before the command; the journal takes no
        // write from here on.
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        try lockJournal(true)
        await gate.open()

        let changed = await enabling.value

        try lockJournal(false)
        XCTAssertFalse(changed)
        XCTAssertEqual(h.guardFake.calls.suffix(2), ["lowpowermode 1", "lowpowermode 0"])
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.lowPowerSetByUs, true)
        try assertShown(m, "low power mode switched off after the failed enable")
    }

    /// Lid open: audio, display and keyboard written, frozen entries
    /// resumed or gone, the Docker marker with nothing left frozen. Each
    /// clear that fails says so.
    func testLidUndoWhoseClearsFailSaysSo() async throws {
        let m = h.makeManager()
        let cases: [(String, (inout RuntimeState) -> Void)] = [
            ("audio restored", { $0.savedOutputVolume = 0.4; $0.savedMuted = true }),
            ("frozen processes resumed", { $0.frozenProcesses = [FrozenProcess(pid: 9001, identity: FakeSleepGuard.identity(of: 9001))] }),
            ("Docker Desktop has no frozen process left", { $0.dockerFrozen = true }),
            ("display brightness restored", { $0.savedDisplayBrightness = 0.5 }),
            ("keyboard backlight restored", { $0.savedKeyboardBrightness = 0.3 }),
        ]
        for (prefix, entry) in cases {
            var s = RuntimeState.clean
            entry(&s)
            try h.store.saveState(s)
            try lockJournal(true)

            await m.undoLidActions()

            try lockJournal(false)
            XCTAssertEqual(try h.store.loadState(), s, "the \(prefix) entry went with the failed write")
            try assertShown(m, prefix)
            try h.store.saveState(.clean)
        }
        XCTAssertEqual(h.audio.applied.map(\.volume), [0.4])
        XCTAssertEqual(h.display.sets.first, 0.5)
        XCTAssertEqual(h.keyboard.sets.first, 0.3)
    }

    /// The line of a failed clear goes once a later write clears its entry,
    /// with the session's own entry still journaled. A write that leaves
    /// the entry keeps the line, and a newer error shown in its place is
    /// left alone.
    func testFailedClearLineGoesOnlyWithItsEntry() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        func journalAudio() throws {
            var s = try XCTUnwrap(h.store.loadState())
            s.savedOutputVolume = 0.4
            try h.store.saveState(s)
        }
        try journalAudio()
        try lockJournal(true)
        await m.undoLidActions()
        try lockJournal(false)
        try assertShown(m, "audio restored")
        let line = m.lastError

        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        XCTAssertEqual(try h.store.loadState()?.savedOutputVolume, 0.4)
        XCTAssertEqual(m.lastError, line, "a write that left the entry took the line away")

        await m.undoLidActions()
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNil(m.lastError, "the line still says a clear that went through will be retried")

        try journalAudio()
        try lockJournal(true)
        await m.undoLidActions()
        try lockJournal(false)
        try assertShown(m, "audio restored")
        m.fail("a newer failure")
        await m.undoLidActions()
        XCTAssertNil(try h.store.loadState()?.savedOutputVolume)
        XCTAssertEqual(m.lastError, "a newer failure")
    }
}
