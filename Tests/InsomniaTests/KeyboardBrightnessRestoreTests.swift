import XCTest
@testable import Insomnia

@MainActor
final class KeyboardBrightnessRestoreTests: XCTestCase {
    var h: Harness!
    var m: SessionManager!
    var sampler: BrightnessSampler!
    var actions: LidActions!
    let idle = Locked<Double>(3)

    override func setUp() async throws {
        h = Harness()
        m = h.makeManager(reassertDelay: .milliseconds(150))
        m.config.freezeList = []
        m.config.dockerRule = false
        m.config.muteOnLidClose = false
        sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { [idle] in idle.value })
        sampler.follow(m)
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        actions = LidActions(manager: m, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { false }), audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: sampler)
        await m.start(duration: 3600)
    }

    override func tearDown() async throws {
        m.cancelBrightnessReassert()
        h.home.destroy()
    }

    func testAmbientZeroDoesNotOverwriteSystemPolicy() async throws {
        sampler.sample()
        h.keyboard.brightness = 0
        sampler.sample()
        XCTAssertEqual(sampler.last?.keyboard, 0)
        await actions.onClose()
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        await actions.onOpen()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sets, [0, 0.7, 0.7])
    }

    func testTrustedCloseZeroDoesNotUseStalePositiveCache() async throws {
        sampler.sample()
        h.keyboard.brightness = 0
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(sampler.last?.keyboard, 0.5)
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
    }

    func testManualOffWithSuppressionDoesNotResurrectPositiveCache() async throws {
        sampler.sample()
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.keyboard.brightness, 0)
    }

    func testZeroAtStartupNeedsNoSample() async throws {
        h.keyboard.brightness = 0
        await actions.onClose()
        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [])
    }

    func testZeroCacheIsNotUsedForAnUntrustedPositiveRead() async throws {
        h.keyboard.brightness = 0
        sampler.sample()
        h.keyboard.brightness = 0.01
        idle.value = 40
        await actions.onClose()
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
    }

    func testLegacyZeroClearsWithoutWriteOrReassert() async throws {
        try m.journal { $0.savedKeyboardBrightness = 0 }
        await actions.onOpen()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertNil(sampler.last?.keyboard)
    }

    func testLegacyZeroClearsOnLaunchWithoutASession() async throws {
        await m.end(reason: .user)
        try m.journal { $0.savedKeyboardBrightness = 0 }
        let launched = h.makeManager()
        defer { launched.cancelBrightnessReassert() }
        await launched.reconcile()
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertEqual(h.keyboard.sets, [])
    }

    func testRefusedLegacyZeroAlsoClearsWithoutWrite() async throws {
        let calls = Locked<Int>(0)
        let unavailable = h.makeManager(keyboard: UnavailableKeyboard(calls: calls))
        defer { unavailable.cancelBrightnessReassert() }
        try unavailable.journal {
            $0.savedKeyboardBrightness = 0
            $0.keyboardRestoreRefused = true
        }
        await unavailable.undoLidActions()
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertFalse(unavailable.state.keyboardRestoreRefused)
        XCTAssertEqual(calls.value, 0)
    }

    func testLegacyZeroClearFailureRemainsOwedWithoutHardwareWrite() async throws {
        try m.journal { $0.savedKeyboardBrightness = 0 }
        let path = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        await actions.onOpen()
        XCTAssertNotNil(m.lastError)
        XCTAssertEqual(try h.store.loadState()?.savedKeyboardBrightness, 0)
        XCTAssertNil(m.effectiveState.savedKeyboardBrightness)
        XCTAssertEqual(h.keyboard.sets, [])
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path)
        try m.journal { _ in }
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
    }

    func testEarlierPositiveObligationSurvivesAnotherZeroClose() async throws {
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedKeyboardBrightness, 0.5)
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedKeyboardBrightness, 0.5)
        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [0, 0, 0.5])
    }

    func testPositiveRestoreAndReassertStillWork() async throws {
        await actions.onClose()
        await actions.onOpen()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.keyboard.sets, [0, 0.5, 0.5])
    }

    func testNewZeroCloseCancelsPendingPositiveReassert() async throws {
        await actions.onClose()
        await actions.onOpen()
        h.keyboard.brightness = 0
        await actions.onClose()
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
    }

    func testOwedZeroClearDoesNotRemoveANewerPositiveEntry() async throws {
        try m.journal { $0.savedKeyboardBrightness = 0 }
        let path = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path) }
        await actions.onOpen()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path)
        try m.journal { $0.savedKeyboardBrightness = 0.8 }
        XCTAssertEqual(m.effectiveState.savedKeyboardBrightness, 0.8)
        await actions.onOpen()
        XCTAssertEqual(h.keyboard.sets, [0.8])
    }

    /// A restore macOS refused leaves the old value kept and the user told
    /// to set the level by hand. A close that reads 0, as a real lid close
    /// does once macOS has turned the backlight off, shows no level, so the
    /// kept value stays undecided and the open keeps the level set since.
    func testARefusedRestoreStaysUndecidedAtAZeroClose() async throws {
        try m.journal {
            $0.savedKeyboardBrightness = 0.6
            $0.keyboardRestoreRefused = true
        }
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true

        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedKeyboardBrightness, 0.6)
        XCTAssertTrue(closed.keyboardRestoreRefused)
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertTrue(logText().contains("keyboard backlight reads 0.0 at the close; the value kept after a refused restore, 0.6, stays journaled and undecided"), logText())

        h.keyboard.suppressedOrDimmed = false
        h.keyboard.brightness = 0.3
        await actions.onOpen()

        XCTAssertEqual(h.keyboard.sets, [], "the level set since is not overwritten")
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
    }

    /// The sampler takes no keyboard reading while an entry is journaled,
    /// so its last sample is older than the refusal and is not the level
    /// the user set since.
    func testARefusedRestoreIgnoresASampleOlderThanIt() async throws {
        sampler.sample()
        XCTAssertEqual(sampler.last?.keyboard, 0.5)
        try m.journal {
            $0.savedKeyboardBrightness = 0.6
            $0.keyboardRestoreRefused = true
        }
        h.keyboard.brightness = 0.2
        h.keyboard.suppressedOrDimmed = true

        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedKeyboardBrightness, 0.6)
        XCTAssertTrue(closed.keyboardRestoreRefused)
        XCTAssertEqual(h.keyboard.sets, [])
    }

    /// A trusted reading above 0 is the level the user set, so it still
    /// replaces the kept value.
    func testATrustedReadingStillReplacesARefusedRestore() async throws {
        try m.journal {
            $0.savedKeyboardBrightness = 0.6
            $0.keyboardRestoreRefused = true
        }
        h.keyboard.brightness = 0.3

        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedKeyboardBrightness, 0.3)
        XCTAssertFalse(closed.keyboardRestoreRefused)
        XCTAssertEqual(h.keyboard.sets, [0])
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }
}

private struct UnavailableKeyboard: KeyboardBacklighting {
    let calls: Locked<Int>

    func refusal() -> String? { "test: private keyboard API unavailable" }
    func isSuppressedOrDimmed() -> Bool { true }
    func readBrightness() throws -> Float? {
        calls.value += 1
        throw DisplayPowerError(what: "keyboard API unavailable")
    }
    func setBrightness(_ value: Float) throws {
        calls.value += 1
        throw DisplayPowerError(what: "keyboard API unavailable")
    }
}
