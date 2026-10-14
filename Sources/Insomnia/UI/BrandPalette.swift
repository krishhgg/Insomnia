import CoreGraphics
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The soft charcoal palette from the approved identity spec, as plain values.
/// The icon generator compiles this file directly, so the palette itself
/// needs neither SwiftUI nor AppKit; the `Color` conversion at the bottom is
/// guarded so it only comes along where SwiftUI exists. Semantic colours
/// (warning red, system text) are not branded and stay wherever they are used.
enum BrandPalette {
    struct RGB: Equatable, Sendable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        init(hex: UInt32) {
            red = CGFloat((hex >> 16) & 0xFF) / 255
            green = CGFloat((hex >> 8) & 0xFF) / 255
            blue = CGFloat(hex & 0xFF) / 255
        }

        var cgColor: CGColor {
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
        }
    }

    /// App icon tile: a mid charcoal grey.
    static let midnight = RGB(hex: 0x303336)
    /// The mark on the app icon: a warm off-white.
    static let moonWhite = RGB(hex: 0xE6E3DD)
    /// Active state: focus and hold rings. The menu bar mark itself stays monochrome.
    static let violet = RGB(hex: 0xA6BBC3)
}

#if canImport(SwiftUI)
extension Color {
    init(brand rgb: BrandPalette.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
#endif
