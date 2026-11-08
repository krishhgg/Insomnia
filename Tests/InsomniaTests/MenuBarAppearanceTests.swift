import SwiftUI
import XCTest
@testable import Insomnia

/// The status item sits on the system menu bar, which is light or dark with
/// the wallpaper and appearance. Everything drawn in it has to take the
/// label colour from the environment (`.primary`), as the eye mark does; a
/// hard-coded white ring, glyph or text vanishes on a light bar.
final class MenuBarAppearanceTests: XCTestCase {
    /// Solid ink under `scheme` must be dark on a light bar and light on a dark one.
    @MainActor
    private func assertInkFollowsScheme(
        _ view: some View, name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for scheme in [ColorScheme.light, .dark] {
            let px = try Raster.render(view, scheme: scheme, scale: 2)
            var ink = 0
            var worst: CGFloat = scheme == .light ? 0 : 1
            for y in 0..<px.height {
                for x in 0..<px.width where px.alpha(x, y) > 0.5 {
                    ink += 1
                    let lum = px.rgb((x, y)).luminance
                    worst = scheme == .light ? max(worst, lum) : min(worst, lum)
                }
            }
            XCTAssertGreaterThan(ink, 10, "\(name) \(scheme): nothing drawn", file: file, line: line)
            switch scheme {
            case .light: XCTAssertLessThan(worst, 0.4, "\(name) light: ink must be dark on a light menu bar", file: file, line: line)
            case .dark: XCTAssertGreaterThan(worst, 0.6, "\(name) dark: ink must be light on a dark menu bar", file: file, line: line)
            @unknown default: XCTFail("unexpected scheme", file: file, line: line)
            }
        }
    }

    @MainActor
    func testTheHoldToEndButtonIsVisibleOnALightAndADarkMenuBar() throws {
        try assertInkFollowsScheme(HoldToEndButton(reduceMotion: true, action: {}), name: "hold-to-end button")
    }

    @MainActor
    func testAPillIsVisibleOnALightAndADarkMenuBar() throws {
        let pill = PillView(
            field: .minutes, text: "30", focused: false, valid: true, glowVisible: false,
            focusBounce: 0, rejectBounce: 0, reduceMotion: true, onTap: {}
        )
        try assertInkFollowsScheme(pill, name: "pill")
    }
}
