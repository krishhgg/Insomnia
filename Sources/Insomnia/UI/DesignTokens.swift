import SwiftUI

/// Named values for everything the UI draws with, beside `BrandPalette`
/// (the brand colours) and `Motion` (every spring and duration).
///
/// The bar tokens are the literals the menu bar shipped with, so moving a
/// view onto them changes no pixels. The bar is always dark (it sits on the
/// menu bar), so its colours are white at fixed opacities rather than
/// semantic colours. Settings and the popover use system text styles; only
/// the shape and status tokens apply there.
enum DesignTokens {
    /// Colours, sizes and fonts drawn inside the menu bar item.
    enum Bar {
        /// Typed digits and the countdown.
        static let text = Color.white
        /// A pill's unit name while it is empty.
        static let placeholder = Color.white.opacity(0.42)
        /// A pill's border.
        static let hairline = Color.white.opacity(0.10)
        /// The hold-to-end ring's track.
        static let track = Color.white.opacity(0.14)
        /// The × inside the hold-to-end ring.
        static let glyph = Color.white.opacity(0.85)

        static let pillRadius: CGFloat = 7
        static let pillHeight: CGFloat = 19
        static let pillPadding: CGFloat = 10
        /// Between the mark and what follows it. Off the spacing scale on
        /// purpose: changing it moves the bar's width.
        static let gap: CGFloat = 7

        /// The countdown: SF Rounded 13 medium (monospaced digits are set
        /// where it is used).
        static let countdown = Font.system(size: 13, weight: .medium, design: .rounded)
        /// A pill's text, semibold when typed and regular for the placeholder.
        static func field(weight: Font.Weight) -> Font {
            .system(size: 12, weight: weight, design: .rounded)
        }
        /// Short captions in the bar.
        static let caption = Font.system(size: 11, weight: .medium, design: .rounded)
    }

    /// Spacing scale, in points.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
    }

    /// Corner radii; always drawn with the continuous style.
    enum Radius {
        static let pill: CGFloat = Bar.pillRadius
        /// Grouped panels in Settings and the popover.
        static let card: CGFloat = 10
    }

    /// Stroke widths.
    enum Stroke {
        /// Borders.
        static let hairline: CGFloat = 0.5
        /// The focus ring.
        static let focus: CGFloat = 1.5
        /// The hold-to-end ring.
        static let ring: CGFloat = 1.6
    }

    /// How a button in the popover answers the pointer
    /// (`PopoverButtonStyle`): one hover state and one pressed state, each
    /// shown at once.
    enum Hover {
        /// A chip's fill at rest, over the popover's own text colour.
        static let chipFill: Double = 0.08
        /// Added to the fill under the pointer, and while pressed.
        static let fill: Double = 0.08
        static let pressedFill: Double = 0.14
        /// How far Start / Extend's accent fill moves toward white under the
        /// pointer, and toward black while pressed.
        static let prominentLift: Double = 0.15
        static let prominentPress: Double = 0.15
        /// The corner radius of every popover button.
        static let radius: CGFloat = 6
    }

    /// Semantic colours. Not branded: warnings and errors never use the
    /// accent, which means "active or focused" and nothing else.
    enum Status {
        static let warning = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
    }

    /// The accent for the colour scheme it is drawn in: the brand accent
    /// on dark surfaces, the darker `accentOnLight` on light ones.
    static func accent(for scheme: ColorScheme) -> Color {
        Color(brand: scheme == .dark ? BrandPalette.accent : BrandPalette.accentOnLight)
    }
}
