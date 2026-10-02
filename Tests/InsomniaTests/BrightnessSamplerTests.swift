import XCTest
@testable import Insomnia

/// A brightness reading is the user's value only while the user touched the
/// machine recently and macOS is not holding the device down itself; the
/// sampler keeps the last such reading per device for the lid close.
@MainActor
final class BrightnessSamplerTests: XCTestCase {
    var display: FakeDisplayDimmer!
    var keyboard: FakeKeyboardBacklight!
    var idle: Locked<Double>!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        display = FakeDisplayDimmer(brightness: 0.7)
        keyboard = FakeKeyboardBacklight(brightness: 0.5)
        idle = Locked(5)
    }

    private func make() -> BrightnessSampler {
        let idle = idle!
        let t0 = t0
        return BrightnessSampler(display: display, keyboard: keyboard, idleSeconds: { idle.value }, clock: { t0 })
    }

    func testRecentInputAwakeAndUnsuppressedIsTrusted() {
        let s = make()
        XCTAssertTrue(s.displayReadIsTrusted)
        XCTAssertTrue(s.keyboardReadIsTrusted)

        XCTAssertEqual(s.sample(), BrightnessSample(display: 0.7, keyboard: 0.5, takenAt: t0))
        XCTAssertEqual(s.last, BrightnessSample(display: 0.7, keyboard: 0.5, takenAt: t0))
    }

    /// The idle dim never starts within 30 s of input; at 30 s and beyond a
    /// reading may already be the dimmed one.
    func testIdleAtOrBeyondThirtySecondsIsNotTrusted() {
        let s = make()
        idle.value = 30
        XCTAssertFalse(s.displayReadIsTrusted)
        XCTAssertFalse(s.keyboardReadIsTrusted)
        XCTAssertNil(s.sample())
        XCTAssertNil(s.last)

        idle.value = 29.9
        XCTAssertTrue(s.displayReadIsTrusted)
        XCTAssertTrue(s.keyboardReadIsTrusted)
    }

    func testAsleepDisplayIsNotTrustedButKeyboardStillIs() {
        let s = make()
        display.asleep = true
        display.brightness = 0.0625
        XCTAssertFalse(s.displayReadIsTrusted)
        XCTAssertTrue(s.keyboardReadIsTrusted)

        XCTAssertEqual(s.sample(), BrightnessSample(display: nil, keyboard: 0.5, takenAt: t0))
        XCTAssertEqual(s.last, BrightnessSample(display: nil, keyboard: 0.5, takenAt: t0))
    }

    func testSuppressedKeyboardIsNotTrustedButDisplayStillIs() {
        let s = make()
        keyboard.suppressedOrDimmed = true
        keyboard.brightness = 0
        XCTAssertTrue(s.displayReadIsTrusted)
        XCTAssertFalse(s.keyboardReadIsTrusted)

        XCTAssertEqual(s.sample(), BrightnessSample(display: 0.7, keyboard: nil, takenAt: t0))
        XCTAssertEqual(s.last, BrightnessSample(display: 0.7, keyboard: nil, takenAt: t0))
    }

    /// Each field keeps its last trusted value on its own: a later sample
    /// with only a trusted display does not forget the keyboard.
    func testFieldsMergeIndependently() {
        let s = make()
        s.sample()
        XCTAssertEqual(s.last, BrightnessSample(display: 0.7, keyboard: 0.5, takenAt: t0))

        keyboard.suppressedOrDimmed = true
        keyboard.brightness = 0
        display.brightness = 0.9
        XCTAssertEqual(s.sample(), BrightnessSample(display: 0.9, keyboard: nil, takenAt: t0))
        XCTAssertEqual(s.last, BrightnessSample(display: 0.9, keyboard: 0.5, takenAt: t0), "suppressed keyboard overwrote the trusted value")

        keyboard.suppressedOrDimmed = false
        keyboard.brightness = 0.2
        display.asleep = true
        XCTAssertEqual(s.sample(), BrightnessSample(display: nil, keyboard: 0.2, takenAt: t0))
        XCTAssertEqual(s.last, BrightnessSample(display: 0.9, keyboard: 0.2, takenAt: t0))
    }

    func testFailingDisplayReadIsSkipped() {
        let s = make()
        display.throwOnRead = true
        XCTAssertEqual(s.sample(), BrightnessSample(display: nil, keyboard: 0.5, takenAt: t0))
        XCTAssertEqual(s.last?.display, nil)
        XCTAssertEqual(s.last?.keyboard, 0.5)
    }

    func testMacWithoutKeyboardBacklightIsSkipped() {
        let s = make()
        keyboard.brightness = nil
        XCTAssertEqual(s.sample(), BrightnessSample(display: 0.7, keyboard: nil, takenAt: t0))
        XCTAssertEqual(s.last, BrightnessSample(display: 0.7, keyboard: nil, takenAt: t0))
    }

    /// Nothing trustworthy read now leaves the earlier sample untouched.
    func testUntrustedSampleKeepsTheLastOne() {
        let s = make()
        s.sample()
        idle.value = 120
        XCTAssertNil(s.sample())
        XCTAssertEqual(s.last, BrightnessSample(display: 0.7, keyboard: 0.5, takenAt: t0))
    }

    /// While the display is held (Insomnia's own Low Power Mode is on and
    /// the panel reads the mode's rescaled value) the display sample is
    /// kept and the keyboard still merges.
    func testAHeldDisplayKeepsItsSampleWhileTheKeyboardStillMerges() {
        let s = make()
        s.sample()
        let held = Locked(true)
        s.displayHeld = { held.value }
        display.brightness = 0.5
        keyboard.brightness = 0.3
        XCTAssertEqual(s.sample(), BrightnessSample(display: nil, keyboard: 0.3, takenAt: t0))
        XCTAssertEqual(s.last, BrightnessSample(display: 0.7, keyboard: 0.3, takenAt: t0))

        held.value = false
        XCTAssertEqual(s.sample(), BrightnessSample(display: 0.5, keyboard: 0.3, takenAt: t0))
        XCTAssertEqual(s.last?.display, 0.5)
    }

    func testNoopControlsReadAsAwakeAndUnsuppressed() {
        XCTAssertFalse(NoopDisplayDimmer().isAsleep())
        XCTAssertFalse(NoopKeyboardBacklight().isSuppressedOrDimmed())
    }
}
