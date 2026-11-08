import SwiftUI

/// Named sizes and colours for the menu bar popover, beside `BrandPalette`
/// (the brand colours) and `Motion` (every spring and duration). The
/// popover uses system text styles; only the spacing, hover and status
/// values here apply to it.
enum DesignTokens {
    /// Spacing scale, in points.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
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
}
