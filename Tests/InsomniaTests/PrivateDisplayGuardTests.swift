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
    /// now and is written. The device holds the value, so quit goes ahead
    /// even though the disk still flags the entry, and its clear lands at
    /// the next transaction once the journal takes writes.
    func testAKeptValueWrittenWhileTheJournalRefusesItsClearLetsQuitGo() async throws {
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
        XCTAssertEqual(outcome, .restored, "the device holds the value, and the disk shows nothing dirty")
        XCTAssertNil(m.pendingEnd)
        XCTAssertTrue(try XCTUnwrap(try h.store.loadState()).displayRestoreRefused, "the disk still refuses the clear")
        XCTAssertFalse(m.effectiveState.brightnessJournaled)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        let later = await m.end(reason: .user)

        XCTAssertEqual(later, .restored)
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

    func testSettingsSeesEveryRefusalWithItsDevice() {
        let m = SessionManager(
            paths: h.home.paths,
            sleepGuard: h.guardFake,
            processControl: h.procs,
            backstop: h.backstop,
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
