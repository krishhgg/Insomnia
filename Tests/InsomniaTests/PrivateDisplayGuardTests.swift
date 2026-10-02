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

    func readBrightness() throws -> Float { try inner.readBrightness() }
    func setBrightness(_ value: Float) throws { try inner.setBrightness(value) }
    func requestSleep() throws {}
    func wake() {}
    func isAsleep() -> Bool { false }
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

    /// The display is refused (an unmeasured macOS), the keyboard class is
    /// shaped as measured: the close skips the display with a log line and
    /// journals nothing for it, and still darkens the keyboard.
    func testARefusedDisplayIsSkippedAndUnjournaledWhileTheKeyboardStillDarkens() async throws {
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
            display: BrightnessOnlyDimmer(inner: DisplayServicesDimmer(osMajorVersion: 27)),
            keyboard: h.keyboard,
            sampler: nil
        )
        await m.start(duration: 3600)

        await actions.onClose()

        let state = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(state.savedDisplayBrightness, "nothing journaled for a device that was never read")
        XCTAssertEqual(state.savedKeyboardBrightness, 0.5)
        XCTAssertEqual(h.keyboard.sets, [0])
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("display darkening refused: DisplayServices brightness calls were measured on macOS 26 only; this is macOS 27"), log)
        XCTAssertTrue(log.contains("display darken on lid close skipped: DisplayServices brightness calls were measured on macOS 26 only; this is macOS 27"), log)
        XCTAssertTrue(log.contains("keyboard backlight off (was brightness 0.5)"), log)
    }

    func testSettingsSeesEveryRefusalWithItsDevice() {
        let m = SessionManager(
            paths: h.home.paths,
            sleepGuard: h.guardFake,
            processControl: h.procs,
            backstop: h.backstop,
            display: BrightnessOnlyDimmer(inner: DisplayServicesDimmer(osMajorVersion: 27)),
            keyboard: CoreBrightnessKeyboardBacklight(loadClass: { ChangedSignatureKeyboardClient.self })
        )

        let notes = m.darkenRefusals

        XCTAssertEqual(notes.count, 2, "\(notes)")
        XCTAssertTrue(notes.first?.hasPrefix("Display: DisplayServices brightness calls were measured on macOS 26 only; this is macOS 27") == true, "\(notes)")
        XCTAssertTrue(notes.last?.hasPrefix("Keyboard backlight: KeyboardBrightnessClient isKeyboardBuiltIn: has type encoding B@:i") == true, "\(notes)")
        XCTAssertEqual(h.makeManager().darkenRefusals, [], "the harness fakes refuse nothing")
    }
}
