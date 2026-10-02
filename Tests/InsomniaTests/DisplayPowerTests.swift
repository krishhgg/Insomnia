import XCTest
@testable import Insomnia

/// Pure logic of the display and keyboard backlight layer. The private
/// frameworks themselves are never called from tests.
final class DisplayPowerTests: XCTestCase {
    func testBrightnessIsClampedToUnitRange() {
        XCTAssertEqual(DisplayPower.clamped(-0.5), 0)
        XCTAssertEqual(DisplayPower.clamped(0), 0)
        XCTAssertEqual(DisplayPower.clamped(0.3), 0.3)
        XCTAssertEqual(DisplayPower.clamped(1), 1)
        XCTAssertEqual(DisplayPower.clamped(1.5), 1)
    }

    /// With an external monitor in clamshell mode the main display is not
    /// the panel: the built-in one is chosen wherever it is in the list.
    func testBuiltInDisplayIsChosenOverMain() {
        let chosen = DisplayPower.builtInDisplay(among: [5, 7, 9], isBuiltIn: { $0 == 7 }, fallback: 5)
        XCTAssertEqual(chosen, 7)
    }

    func testMainDisplayIsTheFallbackWithoutABuiltInOne() {
        XCTAssertEqual(DisplayPower.builtInDisplay(among: [5, 9], isBuiltIn: { _ in false }, fallback: 5), 5)
        XCTAssertEqual(DisplayPower.builtInDisplay(among: [], isBuiltIn: { _ in true }, fallback: 3), 3)
    }

    func testBuiltInKeyboardsAreFilteredById() {
        XCTAssertEqual(DisplayPower.builtInKeyboards(among: [1, 2, 3], isBuiltIn: { $0 != 2 }), [1, 3])
        XCTAssertEqual(DisplayPower.builtInKeyboards(among: [1, 2], isBuiltIn: { _ in false }), [])
        XCTAssertEqual(DisplayPower.builtInKeyboards(among: [], isBuiltIn: { _ in true }), [])
    }

    /// The defaults SessionManager and LidActions fall back on never touch
    /// hardware: reading says "nothing to save", setting does nothing.
    func testNoopControlsSaveNothing() {
        XCTAssertThrowsError(try NoopDisplayDimmer().readBrightness())
        XCTAssertNoThrow(try NoopDisplayDimmer().setBrightness(0))
        XCTAssertNoThrow(try NoopDisplayDimmer().requestSleep())
        XCTAssertNil(try NoopKeyboardBacklight().readBrightness())
        XCTAssertNoThrow(try NoopKeyboardBacklight().setBrightness(0))
    }

    func testErrorDescriptionIsTheDetail() {
        XCTAssertEqual(DisplayPowerError(what: "DisplayServices.framework not found").localizedDescription, "DisplayServices.framework not found")
    }
}
