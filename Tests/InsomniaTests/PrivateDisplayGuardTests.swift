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
    /// refused and not dirty. The end counts it anyway, through the live
    /// guard: "Restore incomplete" and the agent armed, not a restore.
    func testAFailedRestoreWhoseFlagCannotBeClearedIsNotReportedRestored() async throws {
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
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertTrue(after.displayRestoreRefused, "the flag could not be cleared")
        XCTAssertFalse(after.isDirty)
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertTrue(h.notifier.posts.contains { $0.title == SessionManager.incompleteTitle }, "\(h.notifier.posts)")
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("could not mark the display brightness for retry"), m.lastError ?? "")
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
