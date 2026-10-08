import XCTest
@testable import Insomnia

// Fake KeyboardBrightnessClient classes. They carry the private class's
// selectors, and the Objective-C runtime reports their type encodings the
// same way it reports the real ones, so the guard is exercised for real
// without loading CoreBrightness.

/// Shaped as measured on macOS 26: same selectors, same argument and
/// return types. Built-in keyboard 7 at brightness 0.4, idle-dimmed.
final class MeasuredShapeKeyboardClient: NSObject {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray? {
        [NSNumber(value: UInt64(7)), NSNumber(value: UInt64(8))]
    }
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool { id == 7 }
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float { id == 7 ? 0.4 : 0 }
    @objc(setBrightness:forKeyboard:) func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool { true }
    @objc(isBacklightSuppressedOnKeyboard:) func isBacklightSuppressed(onKeyboard id: UInt64) -> Bool { false }
    @objc(isBacklightDimmedOnKeyboard:) func isBacklightDimmed(onKeyboard id: UInt64) -> Bool { true }
}

/// Same selectors, but `isKeyboardBuiltIn:` now takes a 32-bit id.
final class ChangedSignatureKeyboardClient: NSObject {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray? { [] }
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: Int32) -> Bool { true }
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float { 0 }
    @objc(setBrightness:forKeyboard:) func setBrightness(_ value: Float, forKeyboard id: UInt64) -> Bool { true }
}

/// The setter was renamed; the other three are as measured.
final class RenamedSetterKeyboardClient: NSObject {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray? { [] }
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool { true }
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float { 0 }
    @objc(setBrightness:forKeyboardWithID:) func setBrightness(_ value: Float, forKeyboardWithID id: UInt64) -> Bool { true }
}

/// The real dimmer's brightness calls and refusal with its IOKit display
/// sleep and wake calls stubbed out: a test must never put this Mac's
/// display to sleep.
struct BrightnessOnlyDimmer: DisplayDimming {
    let inner: DisplayServicesDimmer
    /// Takes the sleep, wake and asleep calls and counts them.
    let power: FakeDisplayDimmer

    func readBrightness() throws -> Float { try inner.readBrightness() }
    func setBrightness(_ value: Float) throws { try inner.setBrightness(value) }
    func requestSleep() throws { try power.requestSleep() }
    func wake() { power.wake() }
    func isAsleep() -> Bool { power.isAsleep() }
    func refusal() -> String? { inner.refusal() }
}

/// The guards in front of the private display and keyboard calls. The
/// private frameworks themselves are never loaded here: the DisplayServices
/// gate is driven with an injected macOS version and refuses before dlopen,
/// and the keyboard class is injected.
final class PrivateDisplayGuardTests: XCTestCase {
    private var home: TempHome!

    /// Raw encodings measured on macOS 26.2 (25C56), see docs/release-validation.md.
    private let measured: [String: String] = [
        "copyKeyboardBacklightIDs": "@16@0:8",
        "isKeyboardBuiltIn:": "B24@0:8Q16",
        "brightnessForKeyboard:": "f24@0:8Q16",
        "setBrightness:forKeyboard:": "B28@0:8f16Q20",
        "isBacklightSuppressedOnKeyboard:": "B24@0:8Q16",
        "isBacklightDimmedOnKeyboard:": "B24@0:8Q16",
    ]

    override func setUp() async throws {
        home = TempHome()
    }

    override func tearDown() async throws {
        home.destroy()
    }

    private func log() -> String {
        (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
    }

    // MARK: DisplayServices: measured macOS majors only

    func testDisplayServicesIsAllowedOnMeasuredMajorsOnly() throws {
        XCTAssertNil(DisplayPower.displayServicesRefusal(osMajorVersion: 26))
        for major in [15, 25, 27, 30] {
            let why = try XCTUnwrap(DisplayPower.displayServicesRefusal(osMajorVersion: major))
            XCTAssertTrue(why.contains("this is macOS \(major)"), why)
            XCTAssertTrue(why.contains("measured on macOS 26 only"), why)
        }
    }

    /// On a macOS the calls were not measured on, every brightness call
    /// throws before the framework is opened, with the reason Settings
    /// shows, and the refusal is logged once.
    func testTheDimmerOnAnUnmeasuredMacOSRefusesEveryBrightnessCall() throws {
        let dimmer = DisplayServicesDimmer(osMajorVersion: 27)

        let why = try XCTUnwrap(dimmer.refusal())

        XCTAssertTrue(why.contains("this is macOS 27"), why)
        XCTAssertThrowsError(try dimmer.readBrightness()) { XCTAssertEqual($0.localizedDescription, why) }
        XCTAssertThrowsError(try dimmer.setBrightness(0)) { XCTAssertEqual($0.localizedDescription, why) }
        XCTAssertEqual(dimmer.refusal(), why)
        XCTAssertEqual(log().components(separatedBy: "display darkening refused: \(why)").count - 1, 1, log())
    }

    // MARK: KeyboardBrightnessClient: measured encodings only

    func testOffsetsAreStrippedFromTypeEncodings() {
        XCTAssertEqual(DisplayPower.typeEncodingWithoutOffsets("B24@0:8Q16"), "B@:Q")
        XCTAssertEqual(DisplayPower.typeEncodingWithoutOffsets("@16@0:8"), "@@:")
        XCTAssertEqual(DisplayPower.typeEncodingWithoutOffsets("B28@0:8f16Q20"), "B@:fQ")
    }

    func testTheMeasuredEncodingsPass() {
        XCTAssertNil(DisplayPower.keyboardClientRefusal { measured[$0] })
    }

    /// The suppressed and dimmed queries are optional; the other four are not.
    func testAMissingOptionalSelectorPassesAndAMissingRequiredOneRefuses() throws {
        var table = measured
        table["isBacklightSuppressedOnKeyboard:"] = nil
        table["isBacklightDimmedOnKeyboard:"] = nil
        XCTAssertNil(DisplayPower.keyboardClientRefusal { table[$0] })

        table["setBrightness:forKeyboard:"] = nil
        let why = try XCTUnwrap(DisplayPower.keyboardClientRefusal { table[$0] })
        XCTAssertTrue(why.contains("has no setBrightness:forKeyboard:"), why)
    }

    func testAChangedEncodingRefusesEvenOnAnOptionalSelector() throws {
        var table = measured
        table["isBacklightDimmedOnKeyboard:"] = "B24@0:8i16"
        let why = try XCTUnwrap(DisplayPower.keyboardClientRefusal { table[$0] })
        XCTAssertTrue(why.contains("isBacklightDimmedOnKeyboard: has type encoding B@:i, measured B@:Q"), why)
    }

    /// Stack offsets are layout, not signature.
    func testChangedOffsetsAloneAreNotAChange() {
        var table = measured
        table["isKeyboardBuiltIn:"] = "B32@0:16Q24"
        XCTAssertNil(DisplayPower.keyboardClientRefusal { table[$0] })
    }

    // Through the Objective-C runtime, with the fake classes above.

    func testAClassShapedAsMeasuredIsUsed() throws {
        let backlight = CoreBrightnessKeyboardBacklight(loadClass: { MeasuredShapeKeyboardClient.self })

        XCTAssertNil(backlight.refusal())
        XCTAssertEqual(try backlight.readBrightness(), 0.4, "the built-in keyboard only")
        XCTAssertNoThrow(try backlight.setBrightness(0))
        XCTAssertTrue(backlight.isSuppressedOrDimmed())
        XCTAssertFalse(log().contains("refused"), log())
    }

    func testAChangedSignatureIsRefusedBeforeAnyCall() throws {
        let backlight = CoreBrightnessKeyboardBacklight(loadClass: { ChangedSignatureKeyboardClient.self })

        let why = try XCTUnwrap(backlight.refusal())

        XCTAssertTrue(why.contains("isKeyboardBuiltIn: has type encoding B@:i, measured B@:Q on macOS 26"), why)
        XCTAssertThrowsError(try backlight.readBrightness()) { XCTAssertEqual($0.localizedDescription, why) }
        XCTAssertThrowsError(try backlight.setBrightness(0)) { XCTAssertEqual($0.localizedDescription, why) }
        XCTAssertFalse(backlight.isSuppressedOrDimmed())
        XCTAssertEqual(log().components(separatedBy: "keyboard backlight refused: \(why)").count - 1, 1, log())
    }

    func testARenamedRequiredMethodIsRefused() throws {
        let backlight = CoreBrightnessKeyboardBacklight(loadClass: { RenamedSetterKeyboardClient.self })

        let why = try XCTUnwrap(backlight.refusal())

        XCTAssertTrue(why.contains("has no setBrightness:forKeyboard:"), why)
        XCTAssertThrowsError(try backlight.readBrightness())
    }

    func testAFrameworkThatCannotBeLoadedIsTheRefusal() {
        let backlight = CoreBrightnessKeyboardBacklight(loadClass: {
            throw DisplayPowerError(what: "CoreBrightness.framework could not be loaded")
        })

        XCTAssertEqual(backlight.refusal(), "CoreBrightness.framework could not be loaded")
        XCTAssertThrowsError(try backlight.readBrightness())
    }

    /// The fakes the rest of the suite runs on refuse nothing, so no
    /// Settings note appears in their tests.
    func testTheDefaultsRefuseNothing() {
        XCTAssertNil(NoopDisplayDimmer().refusal())
        XCTAssertNil(NoopKeyboardBacklight().refusal())
        XCTAssertNil(FakeDisplayDimmer().refusal())
        XCTAssertNil(FakeKeyboardBacklight().refusal())
    }
}

/// A refused device at lid close and in Settings, through the real classes
/// with the private calls refused before they are reached.
@MainActor
final class RefusedDarkeningTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    /// Lid actions with only darkening on, over the given devices; the
    /// display's sleep and wake land on `h.display`.
    private func makeDarkeningOnly(
        display: any DisplayDimming,
        keyboard: any KeyboardBacklighting
    ) -> (SessionManager, LidActions) {
        let m = h.makeManager()
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        let actions = LidActions(
            manager: m,
            freezer: freezer,
            docker: DockerRule(freezer: freezer, probe: { true }),
            audio: h.audio,
            display: display,
            keyboard: keyboard,
            sampler: nil
        )
        return (m, actions)
    }

    private var refusedDisplay: BrightnessOnlyDimmer {
        BrightnessOnlyDimmer(inner: DisplayServicesDimmer(osMajorVersion: 27), power: h.display)
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    /// The display is refused (an unmeasured macOS), the keyboard class is
    /// shaped as measured: the close skips the display with a log line and
    /// journals nothing for it, and still darkens the keyboard. The
    /// keyboard entry is journaled, so the display may sleep: the open
    /// wakes it before the keyboard comes back.
    func testARefusedDisplayIsSkippedAndUnjournaledWhileTheKeyboardStillDarkens() async throws {
        let (m, actions) = makeDarkeningOnly(display: refusedDisplay, keyboard: h.keyboard)
        await m.start(duration: 3600)

        await actions.onClose()

        let state = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(state.savedDisplayBrightness, "nothing journaled for a device that was never read")
        XCTAssertEqual(state.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertEqual(h.display.sleepRequests, 1)
        let log = logText()
        XCTAssertTrue(log.contains("display darkening refused: DisplayServices brightness calls were measured on macOS 26 only; this is macOS 27"), log)
        XCTAssertTrue(log.contains("display darken on lid close skipped: DisplayServices brightness calls were measured on macOS 26 only; this is macOS 27"), log)
        XCTAssertTrue(log.contains("keyboard backlight off (was brightness 0.5)"), log)

        await actions.onOpen()

        XCTAssertEqual(h.display.wakes, 1, "the display the close put to sleep is woken")
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
    }

    /// Both devices refused: nothing is darkened or journaled, so nothing
    /// on open would wake the display. The close does not ask it to sleep,
    /// and the open has nothing to wake.
    func testBothRefusedLeavesTheDisplayAwake() async throws {
        let (m, actions) = makeDarkeningOnly(
            display: refusedDisplay,
            keyboard: CoreBrightnessKeyboardBacklight(loadClass: { ChangedSignatureKeyboardClient.self })
        )
        await m.start(duration: 3600)

        await actions.onClose()

        XCTAssertEqual(h.display.sleepRequests, 0, "no journaled brightness, so no wake on open: no sleep request")
        let state = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(state.brightnessJournaled)
        XCTAssertTrue(logText().contains("display sleep not requested: no display or keyboard brightness is journaled"), logText())
        XCTAssertNil(m.lastError)

        await actions.onOpen()

        XCTAssertEqual(h.display.wakes, 0)
        XCTAssertNil(m.lastError)
    }

    /// The app dies between a close that journaled only the keyboard (the
    /// display refused) and the open. The relaunch reconciles with the lid
    /// open and wakes the display from the same journal entry the sleep
    /// request was made for.
    func testARelaunchAfterTheCloseStillWakesTheDisplay() async throws {
        let (m, actions) = makeDarkeningOnly(display: refusedDisplay, keyboard: h.keyboard)
        await m.start(duration: 3600)
        await actions.onClose()
        XCTAssertEqual(h.display.sleepRequests, 1)
        XCTAssertEqual(h.display.wakes, 0)

        h.clamshell.closed = false
        let relaunched = h.makeManager()
        await relaunched.reconcile()

        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).brightnessJournaled)
    }

    private var refusedKeyboard: CoreBrightnessKeyboardBacklight {
        CoreBrightnessKeyboardBacklight(loadClass: { ChangedSignatureKeyboardClient.self })
    }

    /// Brightness saved under a lid close before an update, as the journal
    /// would hold it; `refused` as a launch of the refusing build left it.
    private func seedSavedBrightness(sessionValid: Bool, refused: Bool = false) throws {
        if sessionValid {
            let now = h.clock.now
            try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        }
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.savedKeyboardBrightness = 0.3
        st.displayRestoreRefused = refused
        st.keyboardRestoreRefused = refused
        try h.store.saveState(st)
    }

    /// The values were saved on a measured Mac; after an update the guard
    /// refuses both devices. The relaunch with the lid open wakes the
    /// display and writes nothing through the refused calls. Both values
    /// stay journaled, flagged as refused so they are no longer lid
    /// actions to undo, and one error names both saved levels, says why
    /// each was refused and how to set them by hand.
    func testASavedValueTheGuardNowRefusesStaysJournaled() async throws {
        try seedSavedBrightness(sessionValid: true)
        h.clamshell.closed = false
        let m = h.makeManager(display: refusedDisplay, keyboard: refusedKeyboard)

        await m.reconcile()

        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.savedKeyboardBrightness, 0.3)
        XCTAssertTrue(after.displayRestoreRefused)
        XCTAssertTrue(after.keyboardRestoreRefused)
        XCTAssertTrue(after.hasRefusedBrightness)
        XCTAssertFalse(after.hasLidActions, "the live session keeps the sleep guard journaled, but no lid action is left to undo")
        let error = try XCTUnwrap(m.lastError)
        XCTAssertTrue(error.hasPrefix("could not restore the brightness saved before the lid closed on this macOS build. "), error)
        XCTAssertTrue(error.contains("Display brightness 0.8: DisplayServices brightness calls were measured on macOS 26 only; this is macOS 27"), error)
        XCTAssertTrue(error.contains("Keyboard backlight 0.3: KeyboardBrightnessClient isKeyboardBuiltIn: has type encoding B@:i"), error)
        XCTAssertTrue(error.contains("Set the levels with the brightness keys or Control Center"), error)
        XCTAssertTrue(error.contains("the saved values stay in the journal"), error)
        XCTAssertTrue(logText().contains(error), logText())
    }

    /// No session left, only the refused entries. The first launch of the
    /// refusing build runs the usual end for a dirty journal, keeps both
    /// values and flags them, and tells the user. After that the journal
    /// is not dirty: no "Restore incomplete", no recovery agent armed for
    /// it. The next launch tries again and says so, and nothing is
    /// pending, so a new session starts, ends as restored, and Quit is not
    /// held back. The values are still there afterwards.
    func testAKeptRefusedEntryBlocksNothing() async throws {
        try seedSavedBrightness(sessionValid: false)
        h.clamshell.closed = false
        let first = h.makeManager(display: refusedDisplay, keyboard: refusedKeyboard)

        await first.reconcile()

        let kept = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(kept.savedDisplayBrightness, 0.8)
        XCTAssertEqual(kept.savedKeyboardBrightness, 0.3)
        XCTAssertTrue(kept.hasRefusedBrightness)
        XCTAssertFalse(kept.isDirty)
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")
        XCTAssertTrue(try XCTUnwrap(first.lastError).contains("with the brightness keys or Control Center"))

        let m = h.makeManager(display: refusedDisplay, keyboard: refusedKeyboard)
        await m.reconcile()

        XCTAssertTrue(logText().contains("reconcile: no session; trying again the brightness kept after a refused restore"), logText())
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("with the brightness keys or Control Center"))
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")

        await m.start(duration: 3600)
        XCTAssertNotNil(m.session, "a kept refused entry does not block a new session")

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .restored, "quit is not held back for an entry no retry can restore")
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.savedKeyboardBrightness, 0.3)
        XCTAssertFalse(after.isDirty)
    }

    /// A later build, or macOS, makes the call again, and both devices
    /// still read 0 as the close left them: the next launch restores the
    /// kept values and clears them with their flags.
    func testABuildThatCanMakeTheCallRestoresAKeptValue() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.keyboard.brightness = 0
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertEqual(h.display.sets.first, 0.8)
        XCTAssertEqual(h.keyboard.sets.first, 0.3)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertNil(after.savedKeyboardBrightness)
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertFalse(after.keyboardRestoreRefused)
        XCTAssertFalse(after.isDirty)
    }

    /// The user set the display by hand, as the error asked, and left the
    /// keyboard dark. A build that can make the call leaves the display at
    /// the level set, writes the keyboard's kept value, and clears both.
    func testAKeptValueGivesWayToALevelSetSince() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.keyboard.brightness = 0
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertEqual(h.display.sets, [], "the level set since is not overwritten")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertEqual(h.keyboard.sets.first, 0.3)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertNil(after.savedKeyboardBrightness)
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertFalse(after.keyboardRestoreRefused)
        XCTAssertFalse(after.isDirty)
        XCTAssertTrue(logText().contains("display brightness reads 0.6, set since its restore to 0.8 was refused; left as set, and the saved value cleared"), logText())
    }

    /// The re-read runs on its own task; polls for up to 3 s.
    private func waitFor(_ condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The user set the keyboard to 0.6 by hand, and a build that can make
    /// the call launches while macOS still holds the backlight down after
    /// the wake, so it reads 0. That reading decides nothing: no write, and
    /// the entry stays. The read a moment later, with the backlight back,
    /// finds the level set and clears the entry without a write.
    func testASuppressedKeyboardReadingWaitsForOneThatCanBeTrusted() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50))

        await m.reconcile()

        XCTAssertEqual(h.keyboard.sets, [], "a held-down reading of 0 is not the level")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedKeyboardBrightness, 0.3)
        XCTAssertTrue(waiting.keyboardRestoreRefused)
        XCTAssertTrue(logText().contains("keyboard backlight 0.3, kept after a refused restore, not read: macOS has the backlight suppressed or dimmed; nothing written or cleared, tried again in"), logText())

        h.keyboard.brightness = 0.6
        h.keyboard.suppressedOrDimmed = false
        try await waitFor { try self.h.store.loadState()?.savedKeyboardBrightness == nil }

        XCTAssertEqual(h.keyboard.sets, [], "the level set since is not overwritten")
        XCTAssertEqual(h.keyboard.brightness, 0.6)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedKeyboardBrightness)
        XCTAssertFalse(after.keyboardRestoreRefused)
        XCTAssertTrue(logText().contains("keyboard backlight reads 0.6, set since its restore to 0.3 was refused; left as set, and the saved value cleared"), logText())
    }

    /// An expired session ends while the display is asleep, so its reading
    /// is the idle-dim value. The kept display value waits, and the end is
    /// a restore, not "Restore incomplete": nothing failed. Once the display
    /// is awake and still reads 0, the re-read writes the kept value.
    func testASleepingDisplayWaitsAndTheEndIsNotIncomplete() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.display.asleep = true
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50))

        await m.reconcile()

        XCTAssertEqual(h.display.sets, [], "an asleep reading of 0 is not the level")
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertNil(m.lastError)

        h.display.asleep = false
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        XCTAssertEqual(h.display.sets.first, 0.8)
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).displayRestoreRefused)
    }

    /// The lid closed before the re-read: it writes nothing, though the
    /// keyboard now reads 0 and is no longer held down, since the backlight
    /// would light under the lid. No session runs, so no lid service would
    /// report the open: the re-read goes on by itself, logs the closed lid
    /// once, and decides the entry once the lid is open.
    func testTheReReadWritesNothingUnderAClosedLidAndDecidesOnceItOpens() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50), keptRecheckSlowDelay: .milliseconds(20))

        await m.reconcile()
        h.clamshell.closed = true
        h.keyboard.suppressedOrDimmed = false
        let closed = "brightness re-check: the lid is not known to be open, so the kept value is not read"
        try await waitFor { self.logText().contains(closed) }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(h.keyboard.sets, [], "nothing is written under the lid")
        XCTAssertEqual(logText().components(separatedBy: closed).count - 1, 1, "logged once, not at every read: \(logText())")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedKeyboardBrightness, 0.3)
        XCTAssertTrue(waiting.keyboardRestoreRefused)

        h.keyboard.brightness = 0.6
        h.clamshell.closed = false
        try await waitFor { try self.h.store.loadState()?.savedKeyboardBrightness == nil }

        XCTAssertEqual(h.keyboard.sets, [], "the level set since is not overwritten")
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).keyboardRestoreRefused)
        XCTAssertTrue(logText().contains("keyboard backlight reads 0.6, set since its restore to 0.3 was refused; left as set, and the saved value cleared"), logText())
    }

    /// A read that fails decides nothing either: the kept value is not
    /// written over a level that may have been set, and the entry stays.
    /// After the last quick re-read it is read at the slow pace, so once a
    /// read works the entry is decided with no lid open, end or launch.
    /// The display, read fine at 0, is restored as before.
    func testAKeptValueWhoseReadFailsIsKeptAndReadAgainSlowly() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.keyboard.throwOnRead = true
        let m = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckAttempts: 2, keptRecheckSlowDelay: .milliseconds(20))

        await m.reconcile()
        let last = "still so after 2 readings, so it is read again every"
        try await waitFor { self.logText().contains(last) }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sets.first, 0.8)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedKeyboardBrightness, 0.3)
        XCTAssertTrue(after.keyboardRestoreRefused)
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertTrue(logText().contains("keyboard backlight 0.3, kept after a refused restore, not read: it could not be read"), logText())
        XCTAssertEqual(logText().components(separatedBy: last).count - 1, 1, "logged once, not at every slow read: \(logText())")
        XCTAssertFalse(after.isDirty)

        h.keyboard.throwOnRead = false
        h.keyboard.brightness = 0
        try await waitFor { try self.h.store.loadState()?.savedKeyboardBrightness == nil }

        XCTAssertEqual(h.keyboard.sets.first, 0.3, "still at the level the close left, so the kept value is written")
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).keyboardRestoreRefused)
    }

    /// Launch recovery leaves both kept values waiting, the display asleep
    /// and the keyboard backlight suppressed, and a session starts. Once
    /// both come back, still at the 0 the old close left, the sampler takes
    /// no reading of them while they are journaled, and the re-read's
    /// restore becomes its sample. A lid close soon after, with the panel
    /// pulled down by auto-brightness and the backlight suppressed again,
    /// journals 0.8 and 0.3, not 0, and the open restores them.
    func testADelayedRestoreIsTheSampleTheNextCloseJournals() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.display.asleep = true
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50))
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        let actions = LidActions(
            manager: m,
            freezer: freezer,
            docker: DockerRule(freezer: freezer, probe: { true }),
            audio: h.audio,
            display: h.display,
            keyboard: h.keyboard,
            sampler: sampler
        )

        await m.reconcile()
        await m.start(duration: 3600)
        // One main-actor turn, so the re-read cannot run in between.
        h.display.asleep = false
        h.keyboard.suppressedOrDimmed = false
        sampler.sample()
        XCTAssertNil(sampler.last, "the 0 the close left is not the user's level")

        try await waitFor {
            let s = try self.h.store.loadState()
            return s?.savedDisplayBrightness == nil && s?.savedKeyboardBrightness == nil
        }
        XCTAssertEqual(h.display.sets.first, 0.8)
        XCTAssertEqual(h.keyboard.sets.first, 0.3)
        XCTAssertEqual(sampler.last?.display, 0.8)
        XCTAssertEqual(sampler.last?.keyboard, 0.3)

        h.clamshell.closed = true
        h.display.brightness = 0.335
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8, "the restored level, not a stale 0 or the pulled-down read")
        XCTAssertEqual(closed.savedKeyboardBrightness, 0.3)

        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertEqual(h.display.sets.last, 0.8)
        XCTAssertEqual(h.keyboard.sets.last, 0.3)
        XCTAssertEqual(h.display.brightness, 0.8)
    }

    /// Both kept values were set by hand since, the display at once and the
    /// keyboard once its backlight comes back. Each reading that clears an
    /// entry is the sampler's sample from then on, though the sampler's own
    /// reads are not trusted here, with no input for ten minutes.
    func testAKeptValueSetSinceIsTheSample() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50))
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 600 })
        sampler.follow(m)

        await m.reconcile()
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.6)
        XCTAssertNil(sampler.last?.keyboard, "still waiting")

        h.keyboard.brightness = 0.4
        h.keyboard.suppressedOrDimmed = false
        try await waitFor { try self.h.store.loadState()?.savedKeyboardBrightness == nil }

        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(sampler.last?.keyboard, 0.4)
        XCTAssertEqual(sampler.last?.display, 0.6)
    }

    /// The recovery lock is busy at a re-read: that read is skipped, not
    /// the ones after it, and the entry is decided once the lock is free.
    func testABusyLockSkipsOneReReadNotTheRest() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        let m = h.makeManager(lockTimeout: 0.05, keptRecheckDelay: .milliseconds(50), keptRecheckSlowDelay: .milliseconds(20))

        await m.reconcile()
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        h.keyboard.brightness = 0.6
        h.keyboard.suppressedOrDimmed = false
        try await waitFor { self.logText().contains("brightness re-check skipped, nothing changed") }

        XCTAssertTrue(logText().contains("brightness re-check skipped, nothing changed"), logText())
        XCTAssertEqual(try h.store.loadState()?.savedKeyboardBrightness, 0.3)

        held.release()
        try await waitFor { try self.h.store.loadState()?.savedKeyboardBrightness == nil }

        XCTAssertEqual(h.keyboard.sets, [], "the level set since is not overwritten")
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        XCTAssertTrue(logText().contains("keyboard backlight reads 0.6, set since its restore to 0.3 was refused; left as set, and the saved value cleared"), logText())
    }

    /// A launch with no session and the lid closed: the display reads what
    /// the closed lid leaves, and the keyboard 0 with nothing holding it
    /// down. Neither reading decides anything, so nothing is written or
    /// cleared. Once the lid opens the re-read writes the display, still
    /// at 0, and clears the keyboard, set since, without a write.
    func testALaunchUnderAClosedLidDecidesNothingUntilItOpens() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = true
        h.display.brightness = 0.3
        h.keyboard.brightness = 0
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50), keptRecheckSlowDelay: .milliseconds(20))

        await m.reconcile()

        XCTAssertEqual(h.display.sets, [], "a reading under the lid is not a level set since")
        XCTAssertEqual(h.keyboard.sets, [], "nothing is written under the lid")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8)
        XCTAssertEqual(waiting.savedKeyboardBrightness, 0.3)
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertTrue(waiting.keyboardRestoreRefused)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, not read: the lid is not known to be open"), logText())
        XCTAssertTrue(logText().contains("keyboard backlight 0.3, kept after a refused restore, not read: the lid is not known to be open"), logText())

        h.display.brightness = 0
        h.keyboard.brightness = 0.6
        h.clamshell.closed = false
        try await waitFor {
            let s = try self.h.store.loadState()
            return s?.savedDisplayBrightness == nil && s?.savedKeyboardBrightness == nil
        }

        XCTAssertEqual(h.display.sets.first, 0.8)
        XCTAssertEqual(h.keyboard.sets, [], "the level set since is not overwritten")
    }

    /// As above for an expired session, whose end restores everything else
    /// the journal holds, with the lid state unknown.
    func testAnEndWithTheLidUnknownLeavesAKeptValueWaiting() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.savedKeyboardBrightness = 0.3
        st.keyboardRestoreRefused = true
        try h.store.saveState(st)
        h.clamshell.closed = nil
        h.keyboard.brightness = 0
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50), keptRecheckSlowDelay: .milliseconds(20))

        await m.reconcile()

        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(try h.store.loadState()?.savedKeyboardBrightness, 0.3)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")
        XCTAssertTrue(logText().contains("keyboard backlight 0.3, kept after a refused restore, not read: the lid is not known to be open"), logText())

        h.clamshell.closed = false
        try await waitFor { try self.h.store.loadState()?.savedKeyboardBrightness == nil }

        XCTAssertEqual(h.keyboard.sets.first, 0.3, "still at 0 once the lid is open, so the kept value is written")
    }

    /// Both levels were set by hand, but state.json cannot take the clear.
    /// The entries are done all the same: only the clear is retried, with
    /// no read and no write, so when the user then turns both down to 0,
    /// the old values do not come back over them. The clear lands once the
    /// file can be written.
    func testASetSinceWhoseClearFailsIsNeverWrittenAndClearedLater() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0.5
        h.keyboard.brightness = 0.6
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50), keptRecheckSlowDelay: .milliseconds(20))
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await m.reconcile()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        let error = try XCTUnwrap(m.lastError)
        XCTAssertTrue(error.contains("display brightness was set since its restore was refused, but the saved value could not be cleared"), error)
        XCTAssertTrue(error.contains("keyboard backlight was set since its restore was refused, but the saved value could not be cleared"), error)
        XCTAssertTrue(logText().contains("display brightness 0.8, set since its refused restore, still to be cleared from the journal; keyboard backlight 0.3, set since its refused restore, still to be cleared from the journal; nothing written or cleared, tried again in"), logText())

        h.display.brightness = 0
        h.keyboard.brightness = 0
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(h.display.sets, [], "the 0 the user set is not overwritten")
        XCTAssertEqual(h.keyboard.sets, [], "the 0 the user set is not overwritten")
        let kept = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(kept.savedDisplayBrightness, 0.8)
        XCTAssertEqual(kept.savedKeyboardBrightness, 0.3)
        XCTAssertTrue(kept.displayRestoreRefused)
        XCTAssertTrue(kept.keyboardRestoreRefused)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        try await waitFor {
            let s = try self.h.store.loadState()
            return s?.savedDisplayBrightness == nil && s?.savedKeyboardBrightness == nil
        }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertFalse(after.keyboardRestoreRefused)
        XCTAssertTrue(logText().contains("display brightness 0.8, set since its refused restore, cleared from the journal"), logText())
        XCTAssertTrue(logText().contains("keyboard backlight 0.3, set since its refused restore, cleared from the journal"), logText())
    }

    /// The guard allows the call now but the write fails: an ordinary
    /// failed restore, so the flag goes and the entry is dirty again for
    /// the usual retries.
    func testAFailedWriteOnAKeptValueMakesItRetryable() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.keyboard.brightness = 0
        h.display.throwOnSet = true
        let m = h.makeManager()

        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertTrue(after.isDirty)
        XCTAssertNil(after.savedKeyboardBrightness, "the keyboard restored")
    }

    /// The guard allows the call, the write fails, and state.json cannot
    /// take the cleared flag either, so on disk the entry still reads as
    /// refused and not dirty, which the agent passes over. The end counts
    /// it anyway and keeps it in this process: "Restore incomplete" without
    /// "the recovery agent retries", the end left pending, and quit held
    /// back. Once the journal takes writes again, the flag goes first, so
    /// the agent sees an ordinary failed restore and quit goes ahead; the
    /// write itself lands later.
    func testAFailedRestoreWhoseFlagCannotBeClearedHoldsQuitUntilTheJournalTakesIt() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.display.throwOnSet = true
        let m = h.makeManager()
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await m.reconcile()

        let hidden = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(hidden.savedDisplayBrightness, 0.8)
        XCTAssertTrue(hidden.displayRestoreRefused, "the flag could not be cleared")
        XCTAssertFalse(hidden.isDirty)
        XCTAssertEqual(h.backstop.arms, 1)
        let body = try XCTUnwrap(h.notifier.posts.last { $0.title == SessionManager.incompleteTitle }?.body)
        XCTAssertTrue(body.contains("do not quit until it is restored"), body)
        XCTAssertFalse(body.contains("The recovery agent retries every minute"), body)
        XCTAssertEqual(m.pendingEnd, .timer)
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("could not mark the display brightness for retry"), m.lastError ?? "")

        let held = await m.end(reason: .quit)
        XCTAssertEqual(held, .incomplete(agentArmed: false), "quit waits while the disk hides the failed restore")
        XCTAssertNotNil(m.pendingEnd)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let handedOn = await m.end(reason: .quit)

        XCTAssertEqual(handedOn, .incomplete(agentArmed: true))
        XCTAssertNil(m.pendingEnd)
        let dirty = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(dirty.savedDisplayBrightness, 0.8)
        XCTAssertFalse(dirty.displayRestoreRefused)
        XCTAssertTrue(dirty.isDirty, "an ordinary failed restore the agent retries")
        XCTAssertTrue(logText().contains("display brightness 0.8, whose restore failed, marked in the journal for retry"), logText())

        h.display.throwOnSet = false
        let restored = await m.end(reason: .user)

        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(h.display.sets.last, 0.8)
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
    }

    /// The same double failure, and then the write lands while state.json
    /// still refuses every change. The panel is asleep, which would leave a
    /// refused entry waiting, but this one is an ordinary failed restore
    /// now and is written. The device holds the value, but the disk still
    /// flags the entry, and a launch after a quit would read it again and
    /// could write 0.8 over a 0 set since: quit waits until the clear lands
    /// at the next transaction, once the journal takes writes.
    func testAKeptValueWrittenWhileTheJournalRefusesItsClearHoldsQuitUntilTheClearLands() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.display.throwOnSet = true
        let m = h.makeManager(retryDelay: 3600)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await m.reconcile()
        XCTAssertEqual(m.pendingEnd, .timer)

        h.display.throwOnSet = false
        h.display.asleep = true
        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(h.display.sets.last, 0.8)
        XCTAssertEqual(outcome, .incomplete(agentArmed: false), "the device holds the value, but the disk still reads the entry as kept")
        XCTAssertFalse(outcome.letsQuitGo)
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).displayRestoreRefused, "the disk still refuses the clear")
        XCTAssertFalse(m.effectiveState.brightnessJournaled)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let later = await m.end(reason: .user)

        XCTAssertEqual(later, .restored)
        XCTAssertNil(m.pendingEnd)
        XCTAssertEqual(h.display.sets, [0.8], "written once")
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertTrue(logText().contains("display brightness 0.8, restored, cleared from the journal"), logText())
    }

    /// A launch with no session retries a kept keyboard value, and both
    /// the write and the clearing of its flag fail. Nothing else would
    /// retry it, and the agent cannot see it, so the launch ends as for a
    /// dirty journal and this process retries it until the write lands.
    func testAKeptValueThatFailsAtALaunchWithNoSessionIsRetriedInProcess() async throws {
        var st = RuntimeState()
        st.savedKeyboardBrightness = 0.3
        st.keyboardRestoreRefused = true
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.keyboard.brightness = 0
        h.keyboard.throwOnSet = true
        let m = h.makeManager(retryDelay: 0.1)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await m.reconcile()

        XCTAssertEqual(m.pendingEnd, .backstop, "this process keeps the entry the agent cannot see")
        let body = try XCTUnwrap(h.notifier.posts.last { $0.title == SessionManager.incompleteTitle }?.body)
        XCTAssertTrue(body.contains("do not quit until it is restored"), body)
        XCTAssertTrue(logText().contains("reconcile: a kept brightness failed to restore; ending as for a dirty journal"), logText())
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).keyboardRestoreRefused)

        h.keyboard.throwOnSet = false
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        try await waitFor { self.h.keyboard.sets.contains(0.3) && m.pendingEnd == nil }

        XCTAssertNil(m.pendingEnd)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedKeyboardBrightness)
        XCTAssertFalse(after.keyboardRestoreRefused)
    }

    /// With no session, a re-read finds the display still at 0 and its
    /// write fails. The cleared flag makes it an ordinary failed restore,
    /// and the re-read ends as for a dirty journal: the agent is armed and
    /// counts it dirty, and the notice says only the app can restore it.
    func testAReReadWhoseWriteFailsHandsTheEntryToTheAgent() async throws {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.display.asleep = true
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50))

        await m.reconcile()
        XCTAssertEqual(h.backstop.arms, 0)

        h.display.throwOnSet = true
        h.display.asleep = false
        // The end arms the agent before it posts, so wait for both.
        try await waitFor { self.h.backstop.arms == 1 && self.h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle } }

        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertNil(m.pendingEnd)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertTrue(after.isDirty)
        let body = try XCTUnwrap(h.notifier.posts.last { $0.title == SessionManager.incompleteTitle }?.body)
        XCTAssertTrue(body.contains(SessionManager.brightnessRetrySentence), body)
        XCTAssertFalse(body.contains("The recovery agent retries every minute"), body)
        XCTAssertTrue(logText().contains("brightness re-check: a kept value failed to restore; ending as for a dirty journal"), logText())
    }

    /// During a session a lid open finds both kept levels set by hand, but
    /// state.json refuses the clear. The user then turns the display down
    /// to 0.2 and the backlight off. A lid open while the file is still
    /// read-only writes nothing, and the sampler, no longer held by the
    /// settled entries, takes the new levels. Once the journal takes writes
    /// again, the lid close clears the old entries first and journals the
    /// levels the user chose, so the open brings back 0.2 and 0, never the
    /// old 0.8 and 0.3.
    func testACloseAfterAClearTheJournalRefusedJournalsTheLevelChosenSince() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.display.asleep = true
        h.keyboard.brightness = 0
        h.keyboard.suppressedOrDimmed = true
        let m = h.makeManager()
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        let actions = LidActions(
            manager: m,
            freezer: freezer,
            docker: DockerRule(freezer: freezer, probe: { true }),
            audio: h.audio,
            display: h.display,
            keyboard: h.keyboard,
            sampler: sampler
        )
        await m.reconcile()
        await m.start(duration: 3600)
        h.display.asleep = false
        h.display.brightness = 0.5
        h.keyboard.suppressedOrDimmed = false
        h.keyboard.brightness = 0.6
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onOpen()

        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).hasRefusedBrightness, "still on disk")
        XCTAssertFalse(m.effectiveState.brightnessJournaled, "settled in this process")

        h.display.brightness = 0.2
        h.keyboard.brightness = 0
        await actions.onOpen()
        sampler.sample()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.2)
        XCTAssertEqual(sampler.last?.keyboard, 0)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        h.clamshell.closed = true
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.2)
        XCTAssertEqual(closed.savedKeyboardBrightness, 0)
        XCTAssertFalse(closed.displayRestoreRefused)
        XCTAssertFalse(closed.keyboardRestoreRefused)
        XCTAssertTrue(logText().contains("keyboard backlight 0.3, set since its refused restore, cleared from the journal"), logText())

        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.8), "\(h.display.sets)")
        XCTAssertFalse(h.keyboard.sets.contains(0.3), "\(h.keyboard.sets)")
        XCTAssertEqual(h.display.brightness, 0.2)
        XCTAssertEqual(h.keyboard.brightness, 0)
    }

    /// The display refused, the keyboard's write failing: the report keeps
    /// both, so "Restore incomplete" names the device the app still has to
    /// retry as well as the one to set by hand.
    func testARefusalDoesNotHideAFailedWriteOnTheOtherDevice() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.savedKeyboardBrightness = 0.3
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.keyboard.throwOnSet = true
        let m = h.makeManager(display: refusedDisplay, keyboard: h.keyboard)

        await m.reconcile()

        let incomplete = try XCTUnwrap(h.notifier.posts.first { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")
        XCTAssertTrue(incomplete.body.contains("could not restore keyboard backlight"), incomplete.body)
        XCTAssertTrue(incomplete.body.contains("Display brightness 0.8: DisplayServices brightness calls were measured on macOS 26 only"), incomplete.body)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedKeyboardBrightness, 0.3, "the failed write keeps its entry")
        XCTAssertTrue(after.displayRestoreRefused)
    }

    /// The refusal comes up at every lid open, so it must not hide a failed
    /// audio restore from earlier in the same undo either.
    func testARefusalDoesNotHideAFailedAudioRestore() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.savedOutputVolume = 0.4
        st.savedMuted = false
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.audio.throwOnApply = true
        let m = h.makeManager(display: refusedDisplay)

        await m.reconcile()

        let incomplete = try XCTUnwrap(h.notifier.posts.first { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")
        XCTAssertTrue(incomplete.body.contains("could not restore audio"), incomplete.body)
        XCTAssertTrue(incomplete.body.contains("Display brightness 0.8: DisplayServices brightness calls were measured on macOS 26 only"), incomplete.body)
        XCTAssertEqual(m.lastError.map { incomplete.body.hasPrefix($0) }, true, "\(String(describing: m.lastError))")
    }

    /// Only a refusal keeps an entry out of the dirty set: a measured
    /// device whose write fails keeps it dirty for the retry, as before.
    func testAFailedWriteOnAMeasuredDeviceStillKeepsTheEntry() async throws {
        try seedSavedBrightness(sessionValid: true)
        h.clamshell.closed = false
        h.display.throwOnSet = true
        let m = h.makeManager()

        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertTrue(after.hasLidActions)
        XCTAssertNil(after.savedKeyboardBrightness, "the keyboard restored")
    }

    /// A close on a build that can read the devices again, both still at
    /// 0 as the earlier close left them: the earlier saved value is kept,
    /// as for any close that was never undone, and becomes an ordinary
    /// entry the open restores.
    func testACloseOverADeviceStillDarkKeepsTheKeptValue() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.display.brightness = 0
        h.keyboard.brightness = 0
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)

        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8, "the earlier save is kept")
        XCTAssertEqual(closed.savedKeyboardBrightness, 0.3)
        XCTAssertFalse(closed.displayRestoreRefused)
        XCTAssertFalse(closed.keyboardRestoreRefused)
        XCTAssertTrue(closed.hasLidActions)

        await actions.onOpen()

        XCTAssertEqual(h.display.sets.last, 0.8)
        XCTAssertEqual(h.keyboard.sets.last, 0.3)
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).brightnessJournaled)
    }

    /// The same close after the user set both levels by hand: those levels
    /// replace the kept values, and the open comes back to them.
    func testACloseAfterTheLevelWasSetSavesThatLevel() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.display.brightness = 0.6
        h.keyboard.brightness = 0.4
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)

        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.6)
        XCTAssertEqual(closed.savedKeyboardBrightness, 0.4)
        XCTAssertFalse(closed.displayRestoreRefused)
        XCTAssertFalse(closed.keyboardRestoreRefused)

        await actions.onOpen()

        XCTAssertEqual(h.display.sets.last, 0.6)
        XCTAssertEqual(h.keyboard.sets.last, 0.4)
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).brightnessJournaled)
    }

    /// Lid actions with only darkening on, over the fake devices, for a
    /// manager built by the test and the sampler given.
    private func makeDarkening(_ m: SessionManager, sampler: BrightnessSampler?) -> LidActions {
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        return LidActions(
            manager: m,
            freezer: freezer,
            docker: DockerRule(freezer: freezer, probe: { true }),
            audio: h.audio,
            display: h.display,
            keyboard: h.keyboard,
            sampler: sampler
        )
    }

    private func seedKeptDisplay() throws {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        try h.store.saveState(st)
    }

    /// A launch writes both kept values, still at 0, while state.json
    /// refuses the clears. The restores are done all the same, so the
    /// second write still goes out after powerd has put its own
    /// remembered levels back following the wake.
    func testARestoreWhoseClearIsOwedIsStillReasserted() async throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        h.clamshell.closed = false
        h.display.brightness = 0
        h.keyboard.brightness = 0
        let m = h.makeManager(reassertDelay: .milliseconds(100))
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await m.reconcile()

        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(h.keyboard.sets, [0.3])
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).hasRefusedBrightness, "the clears are still owed")
        XCTAssertFalse(m.effectiveState.brightnessJournaled)
        // powerd puts back its own remembered levels after the wake.
        h.display.brightness = 0.35
        h.keyboard.brightness = 0.1
        try await waitFor { self.h.display.sets.count == 2 && self.h.keyboard.sets.count == 2 }

        XCTAssertEqual(h.display.sets, [0.8, 0.8])
        XCTAssertEqual(h.keyboard.sets, [0.3, 0.3])
        XCTAssertEqual(h.display.brightness, 0.8)
        XCTAssertEqual(h.keyboard.brightness, 0.3)
        XCTAssertTrue(logText().contains("display restore re-asserted (brightness 0.8)"), logText())
        XCTAssertTrue(logText().contains("keyboard restore re-asserted (brightness 0.3)"), logText())
    }

    /// The display was set by hand since its refused restore, and
    /// state.json refused that clear. A close while the file still refuses
    /// writes journals nothing and darkens nothing, and the settled entry
    /// still on disk is no reason to ask the display to sleep: the open
    /// would not wake it for an entry already settled.
    func testACloseThatJournalsNothingDoesNotSleepTheDisplayForASettledEntry() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.5
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).brightnessJournaled, "the clear is still owed")
        XCTAssertFalse(m.effectiveState.brightnessJournaled)

        h.clamshell.closed = true
        await actions.onClose()

        XCTAssertEqual(h.display.sets, [], "nothing journaled, so nothing darkened")
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertEqual(h.display.sleepRequests, 0)
        XCTAssertTrue(logText().contains("display sleep not requested: no display or keyboard brightness is journaled"), logText())
    }

    /// A lid open under Insomnia's Low Power Mode writes a kept display
    /// value, still at 0, while state.json refuses the clear. The owed
    /// clear keeps the write owed once the mode is off, as the clear
    /// itself would have, so switching the mode off writes it once more.
    func testAnOwedClearUnderOurLowPowerModeStillOwesTheWriteAfterIt() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).displayRestoreRefused, "the clear is still owed")
        XCTAssertNil(m.effectiveState.savedDisplayBrightness)
        XCTAssertEqual(m.effectiveState.displayRestoredUnderLowPower, 0.8)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let off = await m.setLowPower(false)

        XCTAssertTrue(off)
        XCTAssertEqual(h.display.sets, [0.8, 0.8], "written once more after the mode")
        XCTAssertTrue(logText().contains("display restored again after low power mode (brightness 0.8)"), logText())
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertFalse(after.displayRestoreRefused)
        XCTAssertNil(after.displayRestoredUnderLowPower)
    }

    /// The user set the display to 0.6 by hand after its refused restore,
    /// and Insomnia's Low Power Mode is on, so the panel reads the mode's
    /// rescaled 0.4. A lid open and every re-read leave the entry waiting:
    /// that reading is not the user's level, so it is not the sampler's
    /// sample either. Once a floor switches the mode off, the panel still
    /// reads 0.4 at the next re-reads, and only later comes back to 0.6. No
    /// reading in this run decides the entry, so the close that follows
    /// leaves it, and the panel, as they are. The next launch reads 0.6 and
    /// clears the entry without a write, and 0.6 is the level the close
    /// after it journals and the open restores.
    func testAKeptDisplayReadUnderOrAfterOurLowPowerModeWaitsForARestart() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckSlowDelay: .milliseconds(20))
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        let actions = makeDarkening(m, sampler: sampler)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)

        await actions.onOpen()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(h.display.sets, [])
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8)
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertNil(sampler.last?.display, "the rescaled reading is not the user's level")
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.4 under our low power mode, which rescales it"), logText())

        let off = await m.setLowPower(false)
        XCTAssertTrue(off)
        try await waitFor { self.logText().contains("reads 0.4 after our low power mode was or may have been on in this run") }
        h.display.brightness = 0.6
        try await waitFor { self.logText().contains("reads 0.6 after our low power mode was or may have been on in this run") }

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.savedDisplayBrightness, 0.8, "not decided on a reading taken after the mode")
        XCTAssertTrue(after.displayRestoreRefused)
        XCTAssertNil(sampler.last?.display, "0.4 was on its way back, and nothing tells 0.6 apart from it")
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.4 after our low power mode was or may have been on in this run, which rescales it until some time after it goes off; that is not taken as a level set since"), logText())

        h.clamshell.closed = true
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8)
        XCTAssertTrue(closed.displayRestoreRefused, "still undecided")
        XCTAssertEqual(h.display.sets, [], "not darkened: the open would read that 0 as the darkening never undone")
        XCTAssertEqual(h.display.sleepRequests, 1)
        XCTAssertTrue(logText().contains("display brightness reads 0.6 at the close after our low power mode was or may have been on in this run, which rescales it until some time after it goes off; the value kept after a refused restore, 0.8, stays journaled and undecided, and the display is not darkened"), logText())

        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.6)

        // A relaunch is no sign the panel is back: the entry is journaled
        // as one the mode was on over, in this boot.
        let marked = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(marked.keptDisplayUnderLowPower, 0.8)
        XCTAssertEqual(marked.keptDisplayUnderLowPowerBoot, SignalProcessControl.bootSession)
        let relaunched = h.makeManager()
        let relaunchedSampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        relaunchedSampler.follow(relaunched)
        await relaunched.reconcile()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8, "not decided by a relaunch in the same boot")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(relaunchedSampler.last?.display)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.6 after our low power mode was or may have been on over it since the Mac last started, which rescales it until some time after it goes off; that is not taken as a level set since"), logText())

        let restarted = h.makeManager(bootSession: "a later boot")
        let newSampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        newSampler.follow(restarted)
        let newActions = makeDarkening(restarted, sampler: newSampler)
        await restarted.reconcile()

        let decided = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(decided.savedDisplayBrightness)
        XCTAssertNil(decided.keptDisplayUnderLowPower, "the record goes with the entry")
        XCTAssertNil(decided.keptDisplayUnderLowPowerBoot)
        XCTAssertEqual(h.display.sets, [], "the level set since is not overwritten")
        XCTAssertEqual(newSampler.last?.display, 0.6)

        h.clamshell.closed = true
        h.display.brightness = 0.335
        await newActions.onClose()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.6)

        h.clamshell.closed = false
        await newActions.onOpen()

        XCTAssertEqual(h.display.sets, [0, 0.6])
        XCTAssertEqual(h.display.brightness, 0.6)
    }

    /// The same entry and mode: the open reads 0.4, which decides nothing.
    /// The user then sets the display to 0 by hand after the mode is off.
    /// That 0 is not the close's darkening, which the reading above 0
    /// showed undone, so the kept 0.8 is not written over it.
    func testAKeptDisplayReadAboveZeroIsNotWrittenOverALaterZero() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckSlowDelay: .milliseconds(20))
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        await actions.onOpen()
        let off = await m.setLowPower(false)
        XCTAssertTrue(off)

        h.display.brightness = 0
        try await waitFor { self.logText().contains("after a reading above 0 showed its darkening undone") }

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0)
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertEqual(try h.store.loadState()?.keptDisplayReadLit, 0.8, "journaled for later runs")
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0 after our low power mode was or may have been on in this run, which rescales it until some time after it goes off, after a reading above 0 showed its darkening undone; that 0 may be a level set since, so the kept value is not written"), logText())
    }

    /// A lid open writes a kept display value while state.json refuses
    /// the clear, and the end that follows cannot clear the sleep entry
    /// either. The agent is armed for the sleep entry but cannot clear the
    /// kept one, so this process keeps the end and quit waits.
    /// "Restore incomplete" says to wait for state.json and does not say
    /// the brightness still waits for the app: it is restored, with only
    /// its clear owed.
    func testAnEndAfterAnOwedClearDoesNotSayTheBrightnessIsStillOwed() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.8])

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .incomplete(agentArmed: false))
        XCTAssertEqual(h.backstop.arms, 2, "armed at the start and again for the sleep entry")
        let body = try XCTUnwrap(h.notifier.posts.last { $0.title == SessionManager.incompleteTitle }?.body)
        XCTAssertTrue(body.contains("do not quit until state.json can be written."), body)
        XCTAssertFalse(body.contains(SessionManager.brightnessRetrySentence), body)
    }

    /// The user set the display to 0.6 by hand after its refused restore,
    /// and the lid closes under Insomnia's Low Power Mode with no sample to
    /// go on: the panel's 0.4 is the mode's rescaled value, and the kept
    /// 0.8 is not the user's level either. The entry stays undecided and
    /// the panel lit, with the display asked to sleep. The open reads the
    /// panel again under the mode, which decides nothing, and switching
    /// the mode off writes nothing: 0.8 never comes back over the 0.6.
    func testACloseUnderOurLowPowerModeLeavesTheKeptValueUndecided() async throws {
        try seedKeptDisplay()
        h.display.brightness = 0.4
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)

        h.clamshell.closed = true
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8, "not the rescaled 0.4")
        XCTAssertTrue(closed.displayRestoreRefused, "the kept 0.8 is not taken as the level to restore either")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.sleepRequests, 1)
        XCTAssertTrue(logText().contains("display brightness reads 0.4 at the close under our low power mode, which rescales it; the value kept after a refused restore, 0.8, stays journaled and undecided, and the display is not darkened, so the open reads it again"), logText())

        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)

        let off = await m.setLowPower(false)

        XCTAssertTrue(off)
        XCTAssertEqual(h.display.sets, [], "0.8 is never written over the level the user set")
        XCTAssertEqual(h.display.brightness, 0.4)
    }

    /// With no sample and the panel asleep, the reading at the close is
    /// its idle-dim value: the entry stays undecided and the panel is not
    /// darkened. The open reads the 0.6 the user set by hand and clears
    /// the entry without a write.
    func testACloseOverASleepingDisplayLeavesTheKeptValueUndecided() async throws {
        try seedKeptDisplay()
        h.display.brightness = 0.2
        h.display.asleep = true
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)

        h.clamshell.closed = true
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8, "not the idle-dim 0.2")
        XCTAssertTrue(closed.displayRestoreRefused)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.sleepRequests, 1)
        XCTAssertTrue(logText().contains("display brightness reads 0.2 at the close while dimmed or asleep; the value kept after a refused restore, 0.8, stays journaled and undecided"), logText())
        XCTAssertFalse(logText().contains("restoring that value on open"), logText())

        h.clamshell.closed = false
        h.display.asleep = false
        h.display.brightness = 0.6
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
    }

    /// The same close, and the panel reads 0 at the open. The 0.2 at the
    /// close was read of a panel asleep and shows no darkening undone, so
    /// that 0 is still the darkening: the kept value is written.
    func testACloseOverASleepingDisplayStillWritesTheKeptValueOverALaterZero() async throws {
        try seedKeptDisplay()
        h.display.brightness = 0.2
        h.display.asleep = true
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)
        h.clamshell.closed = true
        await actions.onClose()
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(try h.store.loadState()?.keptDisplayReadLit, "a reading of a panel asleep under a closing lid is no evidence")

        h.clamshell.closed = false
        h.display.asleep = false
        h.display.brightness = 0
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(h.display.brightness, 0.8)
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertFalse(logText().contains("after a reading above 0 showed its darkening undone"), logText())
    }

    /// A close under Insomnia's Low Power Mode reads the awake panel at 0.4
    /// under the closing lid: no sign of the darkening undone either. The
    /// open reads 0 under the mode and writes the kept value, owed once
    /// more after the mode, and switching the mode off writes it again.
    func testACloseUnderOurLowPowerModeStillWritesTheKeptValueOverALaterZero() async throws {
        try seedKeptDisplay()
        h.display.brightness = 0.4
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        h.clamshell.closed = true
        await actions.onClose()
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertNil(try h.store.loadState()?.keptDisplayReadLit, "a reading under the closing lid is no evidence")

        h.clamshell.closed = false
        h.display.brightness = 0
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(try h.store.loadState()?.displayRestoredUnderLowPower, 0.8)

        let off = await m.setLowPower(false)

        XCTAssertTrue(off)
        XCTAssertEqual(h.display.sets, [0.8, 0.8])
        XCTAssertEqual(h.display.brightness, 0.8)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertNil(after.displayRestoredUnderLowPower)
    }

    /// An open reads the kept 0.8 at 0.4 under the mode: that entry's
    /// darkening is undone. The entry is then replaced by another kept
    /// value, 0.7, which nothing has read above 0, and its 0 gets the kept
    /// value. So does a later 0.8, a new entry with the same value: the
    /// reading above 0 was about the entry gone.
    func testAReadingAboveZeroIsAboutTheKeptEntryItRead() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let (m, actions) = makeDarkeningOnly(display: h.display, keyboard: h.keyboard)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [])
        let off = await m.setLowPower(false)
        XCTAssertTrue(off)

        var replaced = try XCTUnwrap(try h.store.loadState())
        replaced.savedDisplayBrightness = 0.7
        replaced.displayRestoreRefused = true
        try h.store.saveState(replaced)
        h.display.brightness = 0
        await m.undoLidActions()

        XCTAssertEqual(h.display.sets, [0.7])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertNil(try h.store.loadState()?.keptDisplayReadLit, "the record goes with the entry it was about")

        var again = try XCTUnwrap(try h.store.loadState())
        again.savedDisplayBrightness = 0.8
        again.displayRestoreRefused = true
        try h.store.saveState(again)
        h.display.brightness = 0
        await m.undoLidActions()

        XCTAssertEqual(h.display.sets, [0.7, 0.8])
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertFalse(logText().contains("after a reading above 0 showed its darkening undone"), logText())
    }

    /// What a reading of 0 of the kept 0.8 logs once a reading above 0
    /// showed its darkening undone, with no doubt left.
    private let zeroWaits = "display brightness 0.8, kept after a refused restore, reads 0 after a reading above 0 showed its darkening undone; that 0 may be a level set since or one macOS still holds the panel at after a lid close, and only a reading above 0 tells them apart, so the kept value is not written"

    /// A sampler that follows `m`, for the levels a launch or reading
    /// decides.
    private func follow(_ m: SessionManager) -> BrightnessSampler {
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        return sampler
    }

    /// An open reads the kept 0.8 at 0.4 under Insomnia's Low Power Mode:
    /// its darkening is undone, and the journal says so. The session ends
    /// and the user sets the display to 0 by hand. A relaunch in the same
    /// boot still doubts its reading, and does not write 0.8 over that 0.
    /// A launch after a restart has no doubt left, but no reading of 0
    /// tells that 0 from one macOS holds the panel at: its first reading
    /// and every re-read leave the entry waiting, with nothing written or
    /// sampled, and so do a close and an open. 0.8 never comes back. Once
    /// the user sets 0.3, the next reading takes it as the level set since.
    func testAReadingAboveZeroIsKeptAcrossARelaunchAndARestart() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let first = h.makeManager()
        let actions = makeDarkening(first, sampler: nil)
        await first.start(duration: 3600)
        let on = await first.setLowPower(true)
        XCTAssertTrue(on)
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(try h.store.loadState()?.keptDisplayReadLit, 0.8)
        let outcome = await first.end(reason: .user)
        XCTAssertEqual(outcome, .restored)
        h.display.brightness = 0

        let relaunched = h.makeManager()
        let relaunchedSampler = follow(relaunched)
        await relaunched.reconcile()

        XCTAssertEqual(h.display.sets, [], "the user's 0 is not written over")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8)
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertEqual(waiting.keptDisplayReadLit, 0.8)
        XCTAssertNil(relaunchedSampler.last?.display)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0 after our low power mode was or may have been on over it since the Mac last started, which rescales it until some time after it goes off, after a reading above 0 showed its darkening undone; that 0 may be a level set since, so the kept value is not written"), logText())

        let restarted = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckAttempts: 3, keptRecheckSlowDelay: .milliseconds(20), bootSession: "a later boot")
        let sampler = follow(restarted)
        let laterActions = makeDarkening(restarted, sampler: sampler)
        let readsBefore = h.display.reads
        await restarted.reconcile()
        try await waitFor { self.logText().contains("\(self.zeroWaits); still so after 3 readings") }

        XCTAssertTrue(logText().contains("\(zeroWaits); still so after 3 readings"), logText())
        XCTAssertGreaterThanOrEqual(h.display.reads - readsBefore, 4, "the launch's reading and three re-reads")
        XCTAssertEqual(h.display.sets, [], "the user's 0 is not written over")
        let afterRestart = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(afterRestart.savedDisplayBrightness, 0.8, "no reading of 0 decides")
        XCTAssertTrue(afterRestart.displayRestoreRefused)
        XCTAssertEqual(afterRestart.keptDisplayReadLit, 0.8)
        XCTAssertNil(sampler.last?.display, "nothing sampled")
        XCTAssertFalse(logText().contains("that 0 is a level set since"), logText())

        await restarted.start(duration: 3600)
        h.clamshell.closed = true
        await laterActions.onClose()
        h.clamshell.closed = false
        await laterActions.onOpen()

        XCTAssertEqual(h.display.sets, [], "0.8 never comes back")
        XCTAssertEqual(h.display.brightness, 0)
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertNil(sampler.last?.display)

        h.display.brightness = 0.3
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        let decided = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(decided.savedDisplayBrightness)
        XCTAssertFalse(decided.displayRestoreRefused)
        XCTAssertNil(decided.keptDisplayReadLit, "the record goes with its entry")
        XCTAssertNil(decided.keptDisplayUnderLowPower)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.3)
    }

    /// The same reading while state.json refuses every write: the record
    /// is owed, and this process holds it, so a 0 read under the mode is
    /// not written over. Once the journal takes writes, the next write
    /// records it, and a launch after a restart finds it and leaves the
    /// user's 0 as set, with the entry waiting, until the panel reads
    /// above 0.
    func testAReadingAboveZeroTheJournalRefusedIsHeldAndRecordedLater() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager()
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await actions.onOpen()

        XCTAssertNil(try h.store.loadState()?.keptDisplayReadLit)
        XCTAssertEqual(m.effectiveState.keptDisplayReadLit, 0.8, "this process holds it")
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, read above 0, but the journal could not record it"), logText())

        h.display.brightness = 0
        await m.undoLidActions()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0 under our low power mode, which rescales it, after a reading above 0 showed its darkening undone; that 0 may be a level set since, so the kept value is not written"), logText())

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let off = await m.setLowPower(false)
        XCTAssertTrue(off)

        XCTAssertEqual(try h.store.loadState()?.keptDisplayReadLit, 0.8)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, journaled as read above 0"), logText())
        _ = await m.end(reason: .user)
        XCTAssertEqual(h.display.sets, [])

        let restarted = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckAttempts: 3, keptRecheckSlowDelay: .milliseconds(20), bootSession: "a later boot")
        let sampler = follow(restarted)
        await restarted.reconcile()
        try await waitFor { self.logText().contains("\(self.zeroWaits); still so after 3 readings") }

        XCTAssertTrue(logText().contains("\(zeroWaits); still so after 3 readings"), logText())
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8, "no reading of 0 decides")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)

        h.display.brightness = 0.6
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.6)
    }

    /// The same reading refused by state.json, and the user sets 0 by hand
    /// and quits while the record is still owed. The agent never needs
    /// that reading, but a relaunch without it would write 0.8 over the 0.
    /// So the end does not let quit go: "Restore incomplete" says Insomnia
    /// retries and not to quit until state.json can be written, and the
    /// end stays pending. Once state.json takes writes, the next end
    /// records the reading and lets quit go, and a relaunch leaves the 0
    /// as it is.
    func testQuitWaitsWhileAReadingAboveZeroIsOwed() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(retryDelay: 3600)
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await actions.onOpen()
        XCTAssertNil(try h.store.loadState()?.keptDisplayReadLit)
        XCTAssertEqual(m.effectiveState.keptDisplayReadLit, 0.8)
        h.display.brightness = 0

        let held = await m.end(reason: .quit)

        XCTAssertEqual(held, .incomplete(agentArmed: false), "quit waits while only this process holds the reading")
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertEqual(m.effectiveState.keptDisplayReadLit, 0.8, "still held")
        let body = try XCTUnwrap(h.notifier.posts.last { $0.title == SessionManager.incompleteTitle }?.body)
        XCTAssertTrue(body.contains("do not quit until state.json can be written"), body)
        XCTAssertEqual(h.display.sets, [])

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let done = await m.end(reason: .quit)

        XCTAssertEqual(done, .restored)
        XCTAssertNil(m.pendingEnd)
        XCTAssertEqual(try h.store.loadState()?.keptDisplayReadLit, 0.8)

        let relaunched = h.makeManager()
        await relaunched.reconcile()

        XCTAssertEqual(h.display.sets, [], "the user's 0 is not written over")
        XCTAssertEqual(h.display.brightness, 0)
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
    }

    /// With no session and nothing else to undo, a launch reads the kept
    /// 0.8 at 0.4 after Insomnia's Low Power Mode was on over it in this
    /// boot, and state.json refuses the record of that reading. The end of
    /// a quit has nothing for the agent, and would report a full restore,
    /// but it does not let quit go while the record is owed. Once
    /// state.json takes writes, the next end records it and lets quit go.
    func testQuitWaitsWhenOnlyAReadingAboveZeroIsOwed() async throws {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        st.keptDisplayUnderLowPower = 0.8
        st.keptDisplayUnderLowPowerBoot = "this boot"
        try h.store.saveState(st)
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let m = h.makeManager(retryDelay: 3600, bootSession: "this boot")
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await m.reconcile()
        XCTAssertNil(m.pendingEnd)
        XCTAssertNil(try h.store.loadState()?.keptDisplayReadLit)
        XCTAssertEqual(m.effectiveState.keptDisplayReadLit, 0.8)

        let held = await m.end(reason: .quit)

        XCTAssertEqual(held, .incomplete(agentArmed: false))
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertEqual(h.backstop.arms, 0, "nothing for the agent")
        let body = try XCTUnwrap(h.notifier.posts.last { $0.title == SessionManager.incompleteTitle }?.body)
        XCTAssertTrue(body.contains("state.json could not record a reading of the display brightness kept after a refused restore"), body)
        XCTAssertTrue(body.contains("do not quit until state.json can be written"), body)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let done = await m.end(reason: .quit)

        XCTAssertEqual(done, .restored)
        XCTAssertNil(m.pendingEnd)
        XCTAssertEqual(try h.store.loadState()?.keptDisplayReadLit, 0.8)
        XCTAssertEqual(h.display.sets, [])
    }

    /// An open reads the kept 0.8 at 0.4 under Insomnia's Low Power Mode,
    /// and the session ends: the journal keeps the entry and its reading
    /// above 0 (`RuntimeState.keptDisplayReadLit`) for a later boot.
    private func journalAReadingAboveZeroInAnEarlierBoot() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let first = h.makeManager()
        let actions = makeDarkening(first, sampler: nil)
        await first.start(duration: 3600)
        let on = await first.setLowPower(true)
        XCTAssertTrue(on)
        await actions.onOpen()
        let outcome = await first.end(reason: .user)
        XCTAssertEqual(outcome, .restored)
        let kept = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(kept.savedDisplayBrightness, 0.8)
        XCTAssertTrue(kept.displayRestoreRefused)
        XCTAssertEqual(kept.keptDisplayReadLit, 0.8)
        XCTAssertEqual(h.display.sets, [])
    }

    /// A reading above 0 left by an earlier boot. In a later boot the
    /// panel is at 0.5 and nothing has read it: the sampler is held while
    /// the entry is journaled. The lid closes, and auto-brightness has
    /// pulled the panel down to 0 under it. That 0 is no level to restore,
    /// so the kept 0.8 stays, undecided, and the panel is not darkened.
    /// The open reads 0 before the panel comes back, which is not taken as
    /// a level set since either. The re-read finds 0.5 and leaves it as
    /// set. Neither 0 nor 0.8 is ever written.
    func testAZeroUnderTheClosingLidLeavesAKeptValueReadAboveZeroUndecided() async throws {
        try await journalAReadingAboveZeroInAnEarlierBoot()
        h.display.brightness = 0.5
        let m = h.makeManager(keptRecheckDelay: .milliseconds(100), bootSession: "a later boot")
        let sampler = follow(m)
        let actions = makeDarkening(m, sampler: sampler)
        await m.start(duration: 3600)
        sampler.sample()
        XCTAssertNil(sampler.last?.display, "no sample")

        h.clamshell.closed = true
        h.display.brightness = 0
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8, "the kept value stays")
        XCTAssertTrue(closed.displayRestoreRefused, "and is undecided")
        XCTAssertEqual(closed.keptDisplayReadLit, 0.8)
        XCTAssertEqual(h.display.sets, [], "not darkened")
        XCTAssertEqual(h.display.sleepRequests, 1)
        XCTAssertTrue(logText().contains("display brightness reads 0.0 at the close with no sample, where auto-brightness under the closing lid may have pulled it down; the value kept after a refused restore, 0.8, stays journaled and undecided, and the display is not darkened, so the open reads it again"), logText())

        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [])
        let opened = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(opened.savedDisplayBrightness, 0.8)
        XCTAssertTrue(opened.displayRestoreRefused)
        XCTAssertTrue(logText().contains(zeroWaits), logText())

        h.display.brightness = 0.5
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.5)
        XCTAssertEqual(sampler.last?.display, 0.5)
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).displayRestoreRefused)
        XCTAssertFalse(logText().contains("that 0 is a level set since"), logText())
    }

    /// The same, after the user set the panel to 0 by hand. The close
    /// leaves the entry undecided, and the open and every re-read after it
    /// read 0 and wait: that 0 may be the user's or one macOS holds the
    /// panel at. Nothing is written or sampled, at the next close and open
    /// too, so the user's 0 stays and 0.8 never comes back. The panel read
    /// at 0.4 later decides the entry.
    func testAZeroSetByHandBeforeTheCloseWaitsForAReadingAboveZero() async throws {
        try await journalAReadingAboveZeroInAnEarlierBoot()
        h.display.brightness = 0
        let m = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckAttempts: 3, keptRecheckSlowDelay: .milliseconds(20), bootSession: "a later boot")
        let sampler = follow(m)
        let actions = makeDarkening(m, sampler: sampler)
        await m.start(duration: 3600)

        h.clamshell.closed = true
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8)
        XCTAssertTrue(closed.displayRestoreRefused)

        h.clamshell.closed = false
        let readsBefore = h.display.reads
        await actions.onOpen()
        try await waitFor { self.logText().contains("\(self.zeroWaits); still so after 3 readings") }

        XCTAssertTrue(logText().contains("\(zeroWaits); still so after 3 readings"), logText())
        XCTAssertGreaterThanOrEqual(h.display.reads - readsBefore, 4, "the open's reading and three re-reads")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8, "no reading of 0 decides")
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertEqual(waiting.keptDisplayReadLit, 0.8)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display, "nothing sampled")

        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [], "the user's 0 is not written over")
        XCTAssertEqual(h.display.brightness, 0)
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertNil(sampler.last?.display)

        h.display.brightness = 0.4
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertNil(try h.store.loadState()?.keptDisplayReadLit)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.4)
    }

    /// A reading above 0 left by an earlier boot, and a close over the
    /// panel asleep, which leaves the kept 0.8 undecided. The open finds
    /// the panel awake at 0, and an end follows at once. Neither reading
    /// takes that 0 as a level set since: the panel may still be at the 0
    /// auto-brightness pulled it down to under the closing lid, and no
    /// reading of 0 tells that from a 0 the user set. Nothing is written,
    /// and the entry stays for the re-read.
    func testAZeroReadRightAfterTheOpenIsNotYetALevelSetSince() async throws {
        try await journalAReadingAboveZeroInAnEarlierBoot()
        h.display.brightness = 0.2
        h.display.asleep = true
        let m = h.makeManager(bootSession: "a later boot")
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        h.clamshell.closed = true
        await actions.onClose()
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)

        h.clamshell.closed = false
        h.display.asleep = false
        h.display.brightness = 0
        await actions.onOpen()
        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(h.display.sets, [])
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8)
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertEqual(waiting.keptDisplayReadLit, 0.8)
        XCTAssertGreaterThanOrEqual(logText().components(separatedBy: zeroWaits).count - 1, 2, "the open and the end: \(logText())")
        XCTAssertFalse(logText().contains("that 0 is a level set since"), logText())
    }

    /// A reading above 0 left by an earlier boot, and a sample of 0 taken
    /// with the lid open, the panel awake and recent input. A close with
    /// that sample journals it in place of the kept 0.8, as the user's
    /// level, and the open writes 0, not 0.8.
    func testASampleOfZeroStillReplacesAKeptValueReadAboveZero() async throws {
        try await journalAReadingAboveZeroInAnEarlierBoot()
        h.display.brightness = 0
        let m = h.makeManager(bootSession: "a later boot")
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.sample()
        sampler.follow(m)
        XCTAssertEqual(sampler.last?.display, 0)
        let actions = makeDarkening(m, sampler: sampler)
        await m.start(duration: 3600)

        h.clamshell.closed = true
        await actions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0)
        XCTAssertFalse(closed.displayRestoreRefused)
        XCTAssertNil(closed.keptDisplayReadLit)

        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.8), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0)
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
    }

    /// A reading above 0 left by an earlier boot, and a launch of a later
    /// boot under a closed lid, with no session: the re-read waits for the
    /// lid. Once it opens the panel reads 0, which may still be the closing
    /// lid's, and no re-read takes it as set since, however many come.
    /// Nothing is written or sampled. One quick re-read only, so the
    /// re-read logs what it waits for, then the slow ones; the panel read
    /// at 0.5 decides the entry.
    func testAReReadAfterTheLidWasClosedLeavesAZeroUndecided() async throws {
        try await journalAReadingAboveZeroInAnEarlierBoot()
        h.clamshell.closed = true
        h.display.brightness = 0
        let m = h.makeManager(keptRecheckDelay: .milliseconds(50), keptRecheckAttempts: 1, keptRecheckSlowDelay: .milliseconds(20), bootSession: "a later boot")
        let sampler = follow(m)
        await m.reconcile()
        try await waitFor { self.logText().contains("brightness re-check: the lid is not known to be open") }

        let readsBefore = h.display.reads
        h.clamshell.closed = false
        try await waitFor { self.h.display.reads - readsBefore >= 5 }

        XCTAssertGreaterThanOrEqual(h.display.reads - readsBefore, 5)
        XCTAssertTrue(logText().contains("\(zeroWaits); still so after 1 readings"), logText())
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8, "no reading of 0 decides")
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertEqual(waiting.keptDisplayReadLit, 0.8)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)

        h.display.brightness = 0.5
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.5)
    }

    /// Greptile's relaunch trace, with Insomnia gone before the open. A
    /// reading above 0 left by an earlier boot. In a later boot a session
    /// starts with the panel at 0.5 and no sample, and a close reads 0
    /// under the closing lid, which leaves the kept 0.8 undecided. That
    /// process is gone with its session still on disk (a crash, or a quit
    /// that never ran its end). The lid opens with the panel still at the
    /// 0 auto-brightness left, and a new process reads the same journal:
    /// its reconcile resumes the session and, the lid open, undoes the lid
    /// actions. Its first 0 is not taken as a level set since: nothing is
    /// written or cleared, and nothing is sampled. The re-read finds 0.5
    /// and leaves it as set.
    func testARelaunchBeforeTheOpenDoesNotTakeTheClosingLidsZero() async throws {
        try await journalAReadingAboveZeroInAnEarlierBoot()
        h.display.brightness = 0.5
        let gone = h.makeManager(bootSession: "a later boot")
        let goneActions = makeDarkening(gone, sampler: follow(gone))
        await gone.start(duration: 3600)
        h.clamshell.closed = true
        h.display.brightness = 0
        await goneActions.onClose()
        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8)
        XCTAssertTrue(closed.displayRestoreRefused)
        XCTAssertEqual(closed.keptDisplayReadLit, 0.8)
        XCTAssertNotNil(try h.store.loadSession())

        h.clamshell.closed = false
        let relaunched = h.makeManager(keptRecheckDelay: .milliseconds(100), bootSession: "a later boot")
        let sampler = follow(relaunched)
        await relaunched.reconcile()

        XCTAssertEqual(h.display.sets, [], "no restore")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8, "the kept value stays")
        XCTAssertTrue(waiting.displayRestoreRefused, "and is undecided")
        XCTAssertEqual(waiting.keptDisplayReadLit, 0.8)
        XCTAssertNil(sampler.last?.display, "nothing sampled")
        XCTAssertTrue(logText().contains(zeroWaits), logText())
        XCTAssertFalse(logText().contains("that 0 is a level set since"), logText())

        h.display.brightness = 0.5
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.5)
        XCTAssertEqual(sampler.last?.display, 0.5)
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).displayRestoreRefused)
        XCTAssertFalse(logText().contains("that 0 is a level set since"), logText())
    }

    /// The same, with Insomnia gone after the open read its first 0. The
    /// new process reads the panel still at 0, and neither its first
    /// reading nor any re-read after it takes that 0 as set since, however
    /// late: nothing is written, cleared or sampled. The panel read at 0.5
    /// decides the entry.
    func testARelaunchAfterTheOpensFirstZeroStillWaits() async throws {
        try await journalAReadingAboveZeroInAnEarlierBoot()
        h.display.brightness = 0.5
        let gone = h.makeManager(bootSession: "a later boot")
        let goneActions = makeDarkening(gone, sampler: follow(gone))
        await gone.start(duration: 3600)
        h.clamshell.closed = true
        h.display.brightness = 0
        await goneActions.onClose()
        h.clamshell.closed = false
        await goneActions.onOpen()
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertTrue(logText().contains(zeroWaits), logText())

        let relaunched = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckAttempts: 3, keptRecheckSlowDelay: .milliseconds(20), bootSession: "a later boot")
        let sampler = follow(relaunched)
        let readsBefore = h.display.reads
        await relaunched.reconcile()
        try await waitFor { self.h.display.reads - readsBefore >= 6 }

        XCTAssertGreaterThanOrEqual(h.display.reads - readsBefore, 6)
        XCTAssertEqual(h.display.sets, [], "no restore")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8, "the kept value stays")
        XCTAssertTrue(waiting.displayRestoreRefused, "and is undecided")
        XCTAssertEqual(waiting.keptDisplayReadLit, 0.8)
        XCTAssertNil(sampler.last?.display, "nothing sampled")
        XCTAssertFalse(logText().contains("that 0 is a level set since"), logText())

        h.display.brightness = 0.5
        try await waitFor { try self.h.store.loadState()?.savedDisplayBrightness == nil }

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.5)
        XCTAssertNil(try XCTUnwrap(try h.store.loadState()).keptDisplayReadLit)
    }

    /// A reading above 0 is journaled for the kept 0.8 it read. A launch
    /// after a restart finds 0.8 set by hand and clears the entry, and the
    /// record goes with it. The next close journals 0.8 again, an entry of
    /// the same value, and a launch of a build whose guard refuses the call
    /// keeps it as refused. Nothing has read that entry above 0, so the 0
    /// a build that can make the call reads at its launch is the
    /// darkening: 0.8 is written.
    func testAReadingAboveZeroGoesWithItsEntryAcrossLaunches() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let first = h.makeManager()
        let actions = makeDarkening(first, sampler: nil)
        await first.start(duration: 3600)
        let on = await first.setLowPower(true)
        XCTAssertTrue(on)
        await actions.onOpen()
        XCTAssertEqual(try h.store.loadState()?.keptDisplayReadLit, 0.8)
        _ = await first.end(reason: .user)

        h.display.brightness = 0.8
        let restarted = h.makeManager(bootSession: "a later boot")
        let sampler = follow(restarted)
        let laterActions = makeDarkening(restarted, sampler: sampler)
        await restarted.reconcile()

        let settled = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(settled.savedDisplayBrightness)
        XCTAssertNil(settled.keptDisplayReadLit, "the record goes with its entry")
        XCTAssertEqual(sampler.last?.display, 0.8)

        await restarted.start(duration: 3600)
        h.clamshell.closed = true
        await laterActions.onClose()

        let closed = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(closed.savedDisplayBrightness, 0.8)
        XCTAssertFalse(closed.displayRestoreRefused)
        XCTAssertNil(closed.keptDisplayReadLit)
        XCTAssertEqual(h.display.brightness, 0)

        h.clamshell.closed = false
        let refusing = h.makeManager(display: refusedDisplay, bootSession: "a later boot")
        await refusing.reconcile()

        let kept = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(kept.savedDisplayBrightness, 0.8)
        XCTAssertTrue(kept.displayRestoreRefused)
        XCTAssertNil(kept.keptDisplayReadLit)
        let setsBefore = h.display.sets

        let measured = h.makeManager(bootSession: "a later boot")
        await measured.reconcile()

        XCTAssertEqual(h.display.sets, setsBefore + [0.8], "the darkening is undone")
        XCTAssertEqual(h.display.brightness, 0.8)
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
    }

    /// The journal a session of boot A leaves when the app is gone before
    /// its end: sleep and Low Power Mode ours over the kept 0.8, the mode
    /// recorded over it in `boot` (none: a journal from before the record),
    /// and the session over by now.
    private func seedClaimFromBootA(record: Bool = true, boot: String? = "boot A") throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.lowPowerSetByUs = true
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        if record {
            st.keptDisplayUnderLowPower = 0.8
            st.keptDisplayUnderLowPowerBoot = boot
        }
        try h.store.saveState(st)
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-3600)))
    }

    /// Boot A: a session switches Insomnia's Low Power Mode on over the
    /// kept 0.8, the open reads the rescaled 0.4, and the app is gone
    /// before the session ends. The Mac restarts. In boot B the mode reads
    /// off and the panel 0.6. The launch ends the session and reads the
    /// mode before its `lowpowermode 0`, for the log: the mode may have
    /// gone off a moment ago, with the panel on its way back, and nothing
    /// tells that from a mode long off. So the switch-off counts as ours
    /// in boot B: the entry waits with the record for boot B, nothing is
    /// written, and nothing is sampled. A launch in boot C takes 0.6.
    func testAClaimFromBeforeARestartWithTheModeOffStillHoldsTheKeptValue() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let first = h.makeManager(bootSession: "boot A")
        let actions = makeDarkening(first, sampler: nil)
        await first.start(duration: 3600)
        let on = await first.setLowPower(true)
        XCTAssertTrue(on)
        await actions.onOpen()
        let left = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(left.lowPowerSetByUs)
        XCTAssertEqual(left.keptDisplayUnderLowPower, 0.8)
        XCTAssertEqual(left.keptDisplayUnderLowPowerBoot, "boot A")

        h.clock.now = h.clock.now.addingTimeInterval(7200)
        h.guardFake.lowPowerOn = false
        h.display.brightness = 0.6
        let callsBefore = h.guardFake.calls.count
        let restarted = h.makeManager(bootSession: "boot B")
        let sampler = follow(restarted)
        await restarted.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.keptDisplayUnderLowPower, 0.8)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, "boot B")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)
        XCTAssertTrue(logText().contains("low power mode, journaled as ours before the Mac last started, reads off; it may have gone off only a moment ago, with the panel still on its way back, so it is switched off as ours in this boot"), logText())
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.6 after our low power mode was or may have been on in this run"), logText())
        let calls = Array(h.guardFake.calls.dropFirst(callsBefore))
        let read = try XCTUnwrap(calls.firstIndex(of: "pmset -g custom"), "\(calls)")
        let off = try XCTUnwrap(calls.firstIndex(of: "lowpowermode 0"), "\(calls)")
        XCTAssertLessThan(read, off, "\(calls)")

        let later = h.makeManager(bootSession: "boot C")
        let laterSampler = follow(later)
        await later.reconcile()

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(laterSampler.last?.display, 0.6)
    }

    /// The same claim with the mode still on in boot B, as Low Power Mode
    /// may outlast a restart: the switch-off ends it in this boot, so the
    /// panel's 0.6 may be on its way back. The entry waits, the record is
    /// for boot B now, and a relaunch in boot B waits too. A launch in
    /// boot C decides it.
    func testAClaimFromBeforeARestartWithTheModeOnWaitsForTheNextRestart() async throws {
        try seedClaimFromBootA()
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.guardFake.lowPowerOn = true
        let m = h.makeManager(bootSession: "boot B")
        let sampler = follow(m)

        await m.reconcile()

        XCTAssertFalse(h.guardFake.lowPowerOn)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.keptDisplayUnderLowPower, 0.8)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, "boot B")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)
        XCTAssertTrue(logText().contains("low power mode, journaled as ours before the Mac last started, reads on; it is switched off as ours in this boot"), logText())
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.6 after our low power mode was or may have been on in this run"), logText())

        let relaunched = h.makeManager(bootSession: "boot B")
        let relaunchedSampler = follow(relaunched)
        await relaunched.reconcile()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertNil(relaunchedSampler.last?.display)

        let callsBefore = h.guardFake.calls.count
        let restarted = h.makeManager(bootSession: "boot C")
        let newSampler = follow(restarted)
        await restarted.reconcile()

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(newSampler.last?.display, 0.6)
        let later = Array(h.guardFake.calls.dropFirst(callsBefore))
        XCTAssertFalse(later.contains("pmset -g custom") || later.contains("lowpowermode 0"), "no claim left to read or switch off: \(later)")
    }

    /// A read of the mode that fails counts as on: the entry waits, with
    /// the record for boot B.
    func testAClaimFromBeforeARestartWhoseModeCannotBeReadWaits() async throws {
        try seedClaimFromBootA()
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.guardFake.throwOn = ["pmset -g custom"]
        let m = h.makeManager(bootSession: "boot B")
        let sampler = follow(m)

        await m.reconcile()

        XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"), "\(h.guardFake.calls)")
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, "boot B")
        XCTAssertNil(sampler.last?.display)
        XCTAssertTrue(logText().contains("could not read low power mode, journaled as ours before the Mac last started; it is switched off as ours in this boot"), logText())
    }

    /// A claim that cannot be placed in an earlier boot keeps the doubt it
    /// had: a journal from before the record, a record with no boot or an
    /// empty one, and a launch that could not read its own boot. The mode
    /// is not read for it, and the entry waits through the switch-off.
    func testAClaimWithoutAKnownEarlierBootStillWaits() async throws {
        let cases: [(record: Bool, recorded: String?, boot: String)] = [
            (false, nil, "boot B"),
            (true, nil, "boot B"),
            (true, "", "boot B"),
            (true, "boot A", ""),
        ]
        for c in cases {
            h.home.destroy()
            h = Harness()
            try seedClaimFromBootA(record: c.record, boot: c.recorded)
            h.clamshell.closed = false
            h.display.brightness = 0.6
            let m = h.makeManager(bootSession: c.boot)
            let sampler = follow(m)

            await m.reconcile()

            XCTAssertFalse(h.guardFake.calls.contains("pmset -g custom"), "\(c): \(h.guardFake.calls)")
            XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"), "\(c)")
            let after = try XCTUnwrap(try h.store.loadState())
            XCTAssertFalse(after.lowPowerSetByUs, "\(c)")
            XCTAssertEqual(after.savedDisplayBrightness, 0.8, "\(c)")
            XCTAssertEqual(after.keptDisplayUnderLowPower, 0.8, "\(c)")
            XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, c.boot, "\(c)")
            XCTAssertEqual(h.display.sets, [], "\(c)")
            XCTAssertNil(sampler.last?.display, "\(c)")
        }
    }

    /// The claim from boot A, with the mode off in boot B and the lid
    /// closed at launch: the end clears the claim and gives the record
    /// boot B, and the entry waits for the lid. A session of boot B then
    /// switches the mode on itself: the record stays for boot B, the open
    /// under the mode and the re-reads after it decide nothing, and
    /// neither does a relaunch in boot B.
    func testOurLowPowerModeOfTheNewBootStillHoldsTheKeptValue() async throws {
        try seedClaimFromBootA()
        h.clamshell.closed = true
        h.display.brightness = 0.6
        let m = h.makeManager(bootSession: "boot B")
        let actions = makeDarkening(m, sampler: nil)
        await m.reconcile()

        let cleared = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(cleared.lowPowerSetByUs)
        XCTAssertEqual(cleared.savedDisplayBrightness, 0.8, "not read under a closed lid")
        XCTAssertEqual(cleared.keptDisplayUnderLowPower, 0.8)
        XCTAssertEqual(cleared.keptDisplayUnderLowPowerBoot, "boot B")

        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        XCTAssertEqual(try h.store.loadState()?.keptDisplayUnderLowPowerBoot, "boot B")
        h.clamshell.closed = false
        h.display.brightness = 0.4
        await actions.onOpen()
        let off = await m.setLowPower(false)
        XCTAssertTrue(off)
        h.display.brightness = 0.6
        await m.undoLidActions()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.6 after our low power mode was or may have been on in this run"), logText())

        let relaunched = h.makeManager(bootSession: "boot B")
        let sampler = follow(relaunched)
        await relaunched.reconcile()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)
    }

    /// The claim from boot A with the mode on in boot B, while state.json
    /// refuses writes: the switch-off goes through and its clear is owed.
    /// The disk keeps the claim and the record of boot A, and this process
    /// counts the mode as its own, so the entry waits. The clear lands with
    /// the next transaction, and the record with it is for boot B.
    func testAClaimFromBeforeARestartWhoseClearIsOwedStillWaits() async throws {
        try seedClaimFromBootA()
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.guardFake.lowPowerOn = true
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        let m = h.makeManager(retryDelay: 3600, bootSession: "boot B")
        let sampler = follow(m)

        await m.reconcile()

        XCTAssertFalse(h.guardFake.lowPowerOn)
        let disk = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(disk.lowPowerSetByUs)
        XCTAssertEqual(disk.keptDisplayUnderLowPowerBoot, "boot A")
        XCTAssertFalse(m.effectiveState.lowPowerSetByUs)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)
        XCTAssertEqual(m.effectiveState.savedDisplayBrightness, 0.8)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        await m.undoLidActions()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, "boot B")
        XCTAssertNil(sampler.last?.display)
    }

    /// state.json cannot be read when the app starts in boot B, and is
    /// repaired before the next try: the claim from boot A read then is
    /// placed in boot A all the same, the mode is read, and with it off
    /// the entry waits for a later boot as for any such claim.
    func testAClaimFromBeforeARestartReadFromARepairedJournalIsReadLikeAnyOther() async throws {
        try seedClaimFromBootA()
        let file = h.home.paths.stateFile
        let readable = try Data(contentsOf: file)
        try Data("{ unreadable journal".utf8).write(to: file)
        h.clamshell.closed = false
        h.display.brightness = 0.6
        h.guardFake.lowPowerOn = false
        let m = h.makeManager(retryDelay: 3600, bootSession: "boot B")
        let sampler = follow(m)
        await m.reconcile()
        XCTAssertFalse(h.guardFake.calls.contains("lowpowermode 0"))

        try readable.write(to: file)
        await m.reconcile()

        XCTAssertTrue(h.guardFake.calls.contains("pmset -g custom"), "\(h.guardFake.calls)")
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, "boot B")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)
    }

    /// The claim was already given back, by the app before the restart or
    /// by the agent: the record of boot A is about another boot, nothing
    /// reads or switches the mode, and the launch in boot B decides the
    /// entry.
    func testARecordFromBeforeARestartWithTheClaimGivenBackDecidesTheEntry() async throws {
        try seedClaimFromBootA()
        var given = try XCTUnwrap(try h.store.loadState())
        given.sleepDisabledByUs = false
        given.lowPowerSetByUs = false
        try h.store.saveState(given)
        try h.store.deleteSession()
        h.clamshell.closed = false
        h.display.brightness = 0.6
        let m = h.makeManager(bootSession: "boot B")
        let sampler = follow(m)

        await m.reconcile()

        XCTAssertFalse(h.guardFake.calls.contains("pmset -g custom") || h.guardFake.calls.contains("lowpowermode 0"), "\(h.guardFake.calls)")
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertNil(after.keptDisplayUnderLowPower)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.6)
    }

    /// A session switches Insomnia's Low Power Mode off over the kept 0.8,
    /// and the app relaunches while the panel is still on its way back,
    /// reading 0.4. The relaunch in the same boot does not take that for
    /// the user's level: the entry stays, there is no sample, and a close
    /// and open at 0.6 write nothing, 0.4 least of all.
    func testARelaunchWhileThePanelComesBackFromOurLowPowerModeDecidesNothing() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let first = h.makeManager()
        await first.start(duration: 3600)
        let on = await first.setLowPower(true)
        XCTAssertTrue(on)
        await first.undoLidActions()
        let off = await first.setLowPower(false)
        XCTAssertTrue(off)
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).lowPowerSetByUs)

        let next = h.makeManager()
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(next)
        let actions = makeDarkening(next, sampler: sampler)
        await next.reconcile()

        XCTAssertEqual(next.effectiveState.savedDisplayBrightness, 0.8)
        XCTAssertEqual(try h.store.loadState()?.keptDisplayUnderLowPower, 0.8)
        XCTAssertNil(sampler.last?.display)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.4 after our low power mode was or may have been on over it since the Mac last started"), logText())

        h.display.brightness = 0.6
        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
    }

    /// The control: a kept entry no Low Power Mode of ours was on over is
    /// decided by a relaunch, as before.
    func testARelaunchDecidesAKeptDisplayOurLowPowerModeWasNeverOver() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.6
        let m = h.makeManager()
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)

        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertNil(after.keptDisplayUnderLowPower)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(sampler.last?.display, 0.6)
    }

    /// A session ends with the entry still waiting under the mode. The end
    /// switches the mode off and reads the panel a moment later, before it
    /// has its level back, and the re-reads after it find 0.5: none of
    /// those readings is taken as the user's level in this run, nor in a
    /// relaunch in the same boot, so the entry stays for a launch after a
    /// restart, which clears it without a write. The end is not incomplete.
    func testAnEndThatSwitchesOurLowPowerModeOffLeavesTheKeptValueToARestart() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0.3
        let m = h.makeManager(keptRecheckDelay: .milliseconds(20), keptRecheckSlowDelay: .milliseconds(20))
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .restored)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8, "not decided on the reading taken as the mode went off")
        XCTAssertNil(sampler.last?.display)
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.3 after our low power mode was or may have been on in this run"), logText())

        h.display.brightness = 0.5
        try await waitFor { self.logText().contains("reads 0.5 after our low power mode was or may have been on in this run") }

        XCTAssertTrue(logText().contains("reads 0.5 after our low power mode was or may have been on in this run"), logText())
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(sampler.last?.display)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")

        let relaunched = h.makeManager()
        let relaunchedSampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        relaunchedSampler.follow(relaunched)
        await relaunched.reconcile()

        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8, "not decided by a relaunch in the same boot")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertNil(relaunchedSampler.last?.display)

        let restarted = h.makeManager(bootSession: "a later boot")
        let newSampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        newSampler.follow(restarted)
        await restarted.reconcile()

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(newSampler.last?.display, 0.5)
    }

    /// A lid open under Insomnia's Low Power Mode writes a kept display
    /// value, still at 0, while state.json refuses the clear. The user then
    /// sets 0.55 by hand, so switching the mode off drops the write owed
    /// after it, and state.json refuses that clear too. The `lowpowermode 0`
    /// goes through and the journal takes writes again: the clear of
    /// ownership that follows writes the owed restore, which must not
    /// bring the dropped write back.
    func testAWriteAfterOurLowPowerModeDroppedWhileTheJournalRefusedStaysDropped() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        let file = h.home.paths.stateFile.path
        let sleepGuard = AfterSwitchOffSleepGuard(h.guardFake)
        let m = h.makeManager(sleepGuard: sleepGuard)
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(m.effectiveState.displayRestoredUnderLowPower, 0.8)

        h.display.brightness = 0.55
        sleepGuard.afterSwitchOff = { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        let off = await m.setLowPower(false)

        XCTAssertTrue(off)
        XCTAssertEqual(h.display.sets, [0.8], "the write dropped for the user's 0.55 is not made")
        XCTAssertEqual(h.display.brightness, 0.55)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertNil(after.displayRestoredUnderLowPower)
        XCTAssertTrue(logText().contains("display restore after low power mode dropped: the display moved since the restore (0.55, restored 0.8)"), logText())
        XCTAssertTrue(logText().contains("display write owed after low power mode cleared from the journal"), logText())
    }

    /// The same open, with no change by the user. `lowpowermode 0` goes
    /// through and only the journal refuses to clear its ownership: the
    /// mode is off, so the write owed after it goes at once, as when the
    /// clear lands (see testAnOwedClearUnderOurLowPowerModeStillOwesTheWriteAfterIt).
    /// The mode's end then rescales the panel to 0.45. The next switch-off,
    /// with the journal writable again, does not take that for a change by
    /// the user, and the second write still lands.
    func testASwitchOffWhoseClearTheJournalRefusedStillWritesTheDisplayAfterTheMode() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(reassertDelay: .milliseconds(300))
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.8])

        let off = await m.setLowPower(false)

        XCTAssertTrue(off)
        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).lowPowerSetByUs, "the clear is still owed")
        XCTAssertFalse(m.effectiveState.lowPowerSetByUs)
        XCTAssertNil(m.effectiveState.displayRestoredUnderLowPower)
        XCTAssertTrue(logText().contains("display restored again after low power mode (brightness 0.8)"), logText())

        h.display.brightness = 0.45
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        _ = await m.setLowPower(false)
        try await waitFor { self.h.display.brightness == 0.8 }

        XCTAssertEqual(h.display.brightness, 0.8)
        XCTAssertFalse(logText().contains("dropped: the display moved since the restore"), logText())
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertNil(after.displayRestoredUnderLowPower)
        XCTAssertNil(after.savedDisplayBrightness)
    }

    /// The same as an end: `restoreAll` switches the mode off and the
    /// journal refuses the clear. The write owed after the mode goes at
    /// once, and the next end does not take the rescaled 0.45 for a change
    /// by the user.
    func testAnEndWhoseLowPowerClearTheJournalRefusedStillWritesTheDisplayAfterTheMode() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(reassertDelay: .milliseconds(300))
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.8])

        _ = await m.end(reason: .user)

        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).lowPowerSetByUs, "the clear is still owed")
        XCTAssertFalse(m.effectiveState.lowPowerSetByUs)
        XCTAssertTrue(logText().contains("display restored again after low power mode (brightness 0.8)"), logText())

        h.display.brightness = 0.45
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        _ = await m.end(reason: .user)
        try await waitFor { self.h.display.brightness == 0.8 }

        XCTAssertEqual(h.display.brightness, 0.8)
        XCTAssertFalse(logText().contains("dropped: the display moved since the restore"), logText())
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).lowPowerSetByUs)
    }

    /// The kept 0.8 is written under the mode while state.json refuses the
    /// clear, and the end's `lowpowermode 0` outlives its wait. It then
    /// exits 0 with state.json unreadable: the mode is known off, and the
    /// write owed after it is kept with the clear. Once state.json reads
    /// again, the end that was waiting writes the display after the mode;
    /// the panel's 0.45 is the mode's end, not the user's. The unreadable
    /// bytes are never written over.
    func testASwitchOffThatExits0OnAnUnreadableJournalStillWritesTheKeptDisplayAfterIt() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(retryDelay: 3600)
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(m.effectiveState.displayRestoredUnderLowPower, 0.8)

        h.guardFake.stillRunning = ["lowpowermode 0"]
        let end = await m.end(reason: .user)
        XCTAssertEqual(end, .privilegedCommandRunning(pid: 4242))
        let readable = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
        let broken = Data("{ unreadable journal".utf8)
        try broken.write(to: file)
        h.display.brightness = 0.45
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        try await waitFor { m.unfinishedCommand == nil }

        XCTAssertFalse(h.guardFake.lowPowerOn)
        XCTAssertEqual(try Data(contentsOf: file), broken, "the unreadable journal is not written over")
        XCTAssertEqual(h.display.sets, [0.8], "nothing is written on a journal not read")
        XCTAssertNotNil(m.pendingEnd)
        XCTAssertTrue(logText().contains("the clear and the display write owed after it (0.8) wait for the journal to read again"), logText())

        try readable.write(to: file)
        _ = await m.end(reason: .user)

        XCTAssertEqual(h.display.sets, [0.8, 0.8])
        XCTAssertEqual(h.display.brightness, 0.8)
        XCTAssertEqual(h.guardFake.unlockedPrivilegedCalls, [])
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "lowpowermode 0" }.count, 1, "the mode known off is not switched off again")
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertNil(after.displayRestoredUnderLowPower)
        XCTAssertNil(after.savedDisplayBrightness)
    }

    /// The same switch-off, and state.json reads again as another journal,
    /// one whose kept entry went meanwhile and so owes no write after the
    /// mode: nothing is written over the panel.
    func testASwitchOffThatExits0OnAnUnreadableJournalWritesNothingTheRepairedJournalDoesNotOwe() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(retryDelay: 3600)
        let actions = makeDarkening(m, sampler: nil)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path) }
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.8])

        h.guardFake.stillRunning = ["lowpowermode 0"]
        let end = await m.end(reason: .user)
        XCTAssertEqual(end, .privilegedCommandRunning(pid: 4242))
        var other = try XCTUnwrap(try h.store.loadState())
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
        try Data("{ unreadable journal".utf8).write(to: file)
        h.display.brightness = 0.45
        h.guardFake.stillRunning = []
        h.guardFake.exitStuckCommands()
        try await waitFor { m.unfinishedCommand == nil }

        other.savedDisplayBrightness = nil
        other.displayRestoreRefused = false
        try h.store.saveState(other)
        _ = await m.end(reason: .user)

        XCTAssertEqual(h.display.sets, [0.8])
        XCTAssertEqual(h.display.brightness, 0.45)
        XCTAssertTrue(logText().contains("display write owed after low power mode (0.8) not made: the journal read back after the switch-off does not owe it"), logText())
    }

    /// The kept 0.8 is written under the mode, a sample, while state.json
    /// refuses the clear; the mode then goes off with its clear owed too.
    /// The mode's end rescales the panel to 0.45 before anything writes it
    /// again: the sampler does not take it, so the close journals 0.8.
    /// The keyboard is sampled all the while, and the display again once
    /// the clear lands.
    func testASwitchOffWhoseClearIsOwedKeepsTheSampleWrittenAfterTheMode() async throws {
        try seedKeptDisplay()
        h.clamshell.closed = false
        h.display.brightness = 0
        h.keyboard.brightness = 0.3
        let m = h.makeManager()
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        let actions = makeDarkening(m, sampler: sampler)
        await m.start(duration: 3600)
        let on = await m.setLowPower(true)
        XCTAssertTrue(on)
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        await actions.onOpen()
        XCTAssertEqual(sampler.last?.display, 0.8)
        let off = await m.setLowPower(false)
        XCTAssertTrue(off)
        XCTAssertEqual(h.display.sets, [0.8, 0.8])
        XCTAssertFalse(m.effectiveState.lowPowerSetByUs)
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).lowPowerSetByUs, "the clear is still owed")

        h.display.brightness = 0.45
        h.keyboard.brightness = 0.5
        _ = sampler.sample()

        XCTAssertEqual(sampler.last?.display, 0.8, "the mode's end is not the user's level")
        XCTAssertEqual(sampler.last?.keyboard, 0.5)

        h.display.brightness = 0.8
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        h.clamshell.closed = true
        await actions.onClose()
        XCTAssertFalse(try XCTUnwrap(try h.store.loadState()).lowPowerSetByUs, "the clear landed with the close")
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.45))
        XCTAssertEqual(h.display.brightness, 0.8)

        h.display.brightness = 0.6
        _ = sampler.sample()
        XCTAssertEqual(sampler.last?.display, 0.6, "sampled again once the clear landed")
    }

    func testSettingsSeesEveryRefusalWithItsDevice() {
        let m = SessionManager(
            paths: h.home.paths,
            sleepGuard: h.guardFake,
            processControl: h.procs,
            backstop: h.backstop,
            receipts: h.receipts,
            display: refusedDisplay,
            keyboard: CoreBrightnessKeyboardBacklight(loadClass: { ChangedSignatureKeyboardClient.self })
        )

        let notes = m.darkenRefusals

        XCTAssertEqual(notes.count, 2, "\(notes)")
        XCTAssertTrue(notes.first?.hasPrefix("Display: DisplayServices brightness calls were measured on macOS 26 only; this is macOS 27") == true, "\(notes)")
        XCTAssertTrue(notes.last?.hasPrefix("Keyboard backlight: KeyboardBrightnessClient isKeyboardBuiltIn: has type encoding B@:i") == true, "\(notes)")
        XCTAssertEqual(h.makeManager().darkenRefusals, [], "the harness fakes refuse nothing")
    }

    /// With values kept after a refused restore, each Settings line also
    /// names its device's saved level, so neither is only in state.json.
    func testSettingsNamesEachKeptLevel() throws {
        try seedSavedBrightness(sessionValid: false, refused: true)
        let m = h.makeManager(display: refusedDisplay, keyboard: refusedKeyboard)

        let notes = m.darkenRefusals

        XCTAssertEqual(notes.count, 2, "\(notes)")
        XCTAssertTrue(notes.first?.hasSuffix("measured again. The level saved before the lid closed, 0.8, was not restored; set it with the brightness keys or Control Center.") == true, "\(notes)")
        XCTAssertTrue(notes.last?.hasSuffix("The level saved before the lid closed, 0.3, was not restored; set it with the brightness keys or Control Center.") == true, "\(notes)")
    }
}

/// The fake sleep guard, with a hook run once `lowpowermode 0` has gone
/// through, before the caller's next step.
private final class AfterSwitchOffSleepGuard: SleepGuarding, @unchecked Sendable {
    let inner: FakeSleepGuard
    var afterSwitchOff: (@Sendable () -> Void)?

    init(_ inner: FakeSleepGuard) { self.inner = inner }

    func checkSleepSettingForStart(sleepOffIsOurs: Bool) async throws { try await inner.checkSleepSettingForStart(sleepOffIsOurs: sleepOffIsOurs) }
    func disableSleep(_ start: PendingStart) async throws { try await inner.disableSleep(start) }
    func enableSleep() async throws { try await inner.enableSleep() }
    func isSleepDisabled() async throws -> Bool { try await inner.isSleepDisabled() }
    func isLowPowerModeOn() async throws -> Bool { try await inner.isLowPowerModeOn() }
    func setLowPowerMode(_ on: Bool) async throws {
        try await inner.setLowPowerMode(on)
        if !on { afterSwitchOff?() }
    }
}

/// A brightness kept after a refused restore that this process settles,
/// as set since or by writing the kept value, while state.json refuses the
/// clear. On disk the entry still reads as kept, so a launch after a quit
/// would read it again and write the saved value over a 0 the user set
/// since. An end holds quit, and Start, until the clear reaches the disk.
@MainActor
final class OwedKeptClearQuitTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: h.home.paths.stateFile.path)
        h.home.destroy()
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    private func setJournalImmutable(_ on: Bool) throws {
        try FileManager.default.setAttributes([.immutable: on], ofItemAtPath: h.home.paths.stateFile.path)
    }

    /// Polls for up to 3 s.
    private func waitFor(_ condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func seedKept(keyboard: Bool = false) throws {
        var st = RuntimeState()
        if keyboard {
            st.savedKeyboardBrightness = 0.3
            st.keyboardRestoreRefused = true
        } else {
            st.savedDisplayBrightness = 0.8
            st.displayRestoreRefused = true
        }
        try h.store.saveState(st)
    }

    private func makeDarkening(_ m: SessionManager) -> LidActions {
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        return LidActions(
            manager: m,
            freezer: freezer,
            docker: DockerRule(freezer: freezer, probe: { true }),
            audio: h.audio,
            display: h.display,
            keyboard: h.keyboard,
            sampler: nil
        )
    }

    private func incompleteBody() -> String {
        h.notifier.posts.last { $0.title == SessionManager.incompleteTitle }?.body ?? ""
    }

    /// The mapping `AppDelegate.applicationShouldTerminate` quits by.
    func testOnlyARestoreOrAnEndTheArmedAgentCanFinishLetsQuitGo() {
        XCTAssertTrue(EndOutcome.restored.letsQuitGo)
        XCTAssertTrue(EndOutcome.incomplete(agentArmed: true).letsQuitGo)
        XCTAssertFalse(EndOutcome.incomplete(agentArmed: false).letsQuitGo)
        XCTAssertFalse(EndOutcome.locked.letsQuitGo)
        XCTAssertFalse(EndOutcome.sessionRetained.letsQuitGo)
        XCTAssertFalse(EndOutcome.journalUnreadable.letsQuitGo)
        XCTAssertFalse(EndOutcome.privilegedCommandRunning(pid: 1).letsQuitGo)
    }

    /// With no session, a launch reads the kept display entry while
    /// state.json refuses every change: the panel reads `reads`, 0.6 set
    /// since or 0 that gets the kept 0.8. The user then sets the panel to
    /// 0. Quit waits, and Start is refused, while the clear is owed. Once
    /// the journal takes writes the retry lands the clear, Start works
    /// again, and a relaunch writes nothing over the 0.
    private func checkNoSessionSettlementHoldsQuit(reads: Float, writes: [Float]) async throws {
        try seedKept()
        h.clamshell.closed = false
        h.display.brightness = reads
        let m = h.makeManager(retryDelay: 3600)
        try setJournalImmutable(true)

        await m.reconcile()

        XCTAssertEqual(h.display.sets, writes)
        XCTAssertNil(m.effectiveState.savedDisplayBrightness, "settled in this process")
        let onDisk = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(onDisk.savedDisplayBrightness, 0.8, "the journal refused the clear")
        XCTAssertTrue(onDisk.displayRestoreRefused)

        h.display.brightness = 0
        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .incomplete(agentArmed: false))
        XCTAssertFalse(quit.letsQuitGo, "quit waits for the clear")
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertEqual(h.backstop.arms, 0, "nothing for the agent: it cannot clear a kept entry")
        let body = incompleteBody()
        XCTAssertTrue(body.hasPrefix("state.json could not record that a brightness kept after a refused restore is settled. "), body)
        XCTAssertTrue(body.hasSuffix("do not quit until state.json can be written."), body)
        XCTAssertFalse(body.contains(SessionManager.brightnessRetrySentence), body)
        XCTAssertTrue(logText().contains("end: the journal has not taken the clear of a brightness kept after a refused restore and settled in this process; a relaunch would read that entry again and could write its saved value over a 0 set since, so Insomnia keeps it and retries"), logText())

        await m.start(duration: 3600)

        XCTAssertNil(m.session, "Start is refused while the end is pending")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("start refused: the previous session is still being ended"), m.lastError ?? "")

        let stillRefused = await m.end(reason: .user)

        XCTAssertEqual(stillRefused, .incomplete(agentArmed: false), "the retry while the journal still refuses it")
        XCTAssertNotNil(m.pendingEnd)

        try setJournalImmutable(false)
        let retried = await m.end(reason: .user)

        XCTAssertEqual(retried, .restored)
        XCTAssertTrue(retried.letsQuitGo)
        XCTAssertNil(m.pendingEnd)
        let cleared = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(cleared.savedDisplayBrightness)
        XCTAssertFalse(cleared.displayRestoreRefused)
        XCTAssertEqual(h.display.sets, writes, "nothing written over the 0")

        await m.start(duration: 3600)
        XCTAssertNotNil(m.session, "Start works once the clear has landed")
        let ended = await m.end(reason: .user)
        XCTAssertEqual(ended, .restored)

        let relaunched = h.makeManager()
        await relaunched.reconcile()

        XCTAssertEqual(h.display.sets, writes, "the relaunch has no kept entry to read")
        XCTAssertEqual(h.display.brightness, 0)
    }

    func testANoSessionClearOfALevelSetSinceHoldsQuitUntilItLands() async throws {
        try await checkNoSessionSettlementHoldsQuit(reads: 0.6, writes: [])
    }

    func testANoSessionRestoreWhoseClearIsOwedHoldsQuitUntilItLands() async throws {
        try await checkNoSessionSettlementHoldsQuit(reads: 0, writes: [0.8])
    }

    /// The keyboard entry, with the same owed clear: quit waits as for
    /// the display.
    func testAKeyboardRestoreWhoseClearIsOwedHoldsQuitUntilItLands() async throws {
        try seedKept(keyboard: true)
        h.clamshell.closed = false
        h.keyboard.brightness = 0
        let m = h.makeManager(retryDelay: 3600)
        try setJournalImmutable(true)
        await m.reconcile()
        XCTAssertEqual(h.keyboard.sets, [0.3])
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).keyboardRestoreRefused)

        h.keyboard.brightness = 0
        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .incomplete(agentArmed: false))
        XCTAssertEqual(m.pendingEnd, .quit)

        try setJournalImmutable(false)
        let retried = await m.end(reason: .user)

        XCTAssertEqual(retried, .restored)
        XCTAssertNil(try h.store.loadState()?.savedKeyboardBrightness)
        let relaunched = h.makeManager()
        await relaunched.reconcile()
        XCTAssertEqual(h.keyboard.sets, [0.3], "nothing written over the 0")
        XCTAssertEqual(h.keyboard.brightness, 0)
    }

    /// In a session, a lid open writes the kept 0.8 while state.json
    /// refuses every change, so neither its clear nor the end's own
    /// entries land. The agent armed for those entries cannot clear the
    /// kept one, so quit waits; with the agent armed and without.
    private func checkSessionSettlementHoldsQuit(agentArms: Bool) async throws {
        try seedKept()
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(retryDelay: 3600)
        let actions = makeDarkening(m)
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        let armsAtStart = h.backstop.arms
        h.backstop.failArm = !agentArms
        try setJournalImmutable(true)
        await actions.onOpen()
        XCTAssertEqual(h.display.sets, [0.8])

        h.display.brightness = 0
        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .incomplete(agentArmed: false))
        XCTAssertFalse(quit.letsQuitGo)
        XCTAssertEqual(m.pendingEnd, .quit)
        XCTAssertEqual(h.backstop.arms, agentArms ? armsAtStart + 1 : armsAtStart, "armed for the session's own entries, or not")
        let body = incompleteBody()
        XCTAssertTrue(body.hasSuffix("do not quit until state.json can be written."), body)
        XCTAssertFalse(body.contains(SessionManager.brightnessRetrySentence), body)

        try setJournalImmutable(false)
        let retried = await m.end(reason: .user)

        XCTAssertEqual(retried, .restored)
        XCTAssertNil(m.pendingEnd)
        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(after.savedDisplayBrightness)
        XCTAssertFalse(after.isDirty)
        let relaunched = h.makeManager()
        await relaunched.reconcile()
        XCTAssertEqual(h.display.sets, [0.8], "nothing written over the 0")
        XCTAssertEqual(h.display.brightness, 0)
    }

    func testAnArmedAgentDoesNotLetQuitGoWhileAKeptClearIsOwed() async throws {
        try await checkSessionSettlementHoldsQuit(agentArms: true)
    }

    func testAnUnarmedAgentDoesNotLetQuitGoWhileAKeptClearIsOwed() async throws {
        try await checkSessionSettlementHoldsQuit(agentArms: false)
    }

    /// The in-process retry the held quit schedules lands the clear on
    /// its own once the journal takes writes.
    func testTheEndRetryLandsAnOwedKeptClear() async throws {
        try seedKept()
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(retryDelay: 0.1)
        try setJournalImmutable(true)
        await m.reconcile()
        h.display.brightness = 0
        let quit = await m.end(reason: .quit)
        XCTAssertEqual(quit, .incomplete(agentArmed: false))

        try setJournalImmutable(false)
        try await waitFor { m.pendingEnd == nil }

        XCTAssertNil(m.pendingEnd)
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertTrue(logText().contains("retrying pending end (quit)"), logText())
        XCTAssertEqual(h.display.sets, [0.8])
    }

    /// The control: a journal that takes the clear lets quit go at once.
    func testAKeptEntrySettledOnDiskLetsQuitGo() async throws {
        try seedKept()
        h.clamshell.closed = false
        h.display.brightness = 0
        let m = h.makeManager(retryDelay: 3600)
        await m.reconcile()
        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)

        h.display.brightness = 0
        let quit = await m.end(reason: .quit)

        XCTAssertEqual(quit, .restored)
        XCTAssertTrue(quit.letsQuitGo)
        XCTAssertNil(m.pendingEnd)
        XCTAssertEqual(h.display.sets, [0.8])
    }
}
