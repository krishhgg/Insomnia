import CoreGraphics

/// The eye's lens as pure geometry: an almond-shaped outline with two
/// pointed corners on the axis and one cubic curve per lid, on a 24-unit
/// grid. `EyeMarkGeometry` adds the lid, pupil and lashes for the menu bar
/// mark, and `AppIconArtwork` draws the open mark as the app icon.
///
/// Everything is laid out on a 24-unit grid and scaled into whatever rect it
/// is asked for, so the same numbers draw the 17-point status item and the
/// 1024-pixel app icon: scripts/generate-app-icon.sh compiles this file
/// straight into the icon generator. CoreGraphics only, no SwiftUI or
/// AppKit, so the file builds standalone. Coordinates are y-down (SwiftUI's
/// convention); the vertical centre line y = 12 is the eye's axis.
enum EyeLensGeometry {
    static let designSize: CGFloat = 24
    /// Outline weight in grid units: 1.5 of 24, the menu bar's line weight.
    static let strokeUnits: CGFloat = 1.5

    // Eye: two pointed corners on the axis; each lid is one cubic curve.
    private static let corners = (left: CGPoint(x: 1.5, y: 12), right: CGPoint(x: 22.5, y: 12))
    private static let lidControlX = (left: CGFloat(7), right: CGFloat(17))
    private static let lidControlY = (top: CGFloat(4.5), bottom: CGFloat(19.5))

    /// Maps the design grid onto `rect`: uniformly scaled, centred.
    static func gridTransform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / designSize
        let side = designSize * scale
        return CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
    }

    /// Stroke weight for a mark drawn into a square of `size`.
    static func lineWidth(for size: CGFloat) -> CGFloat {
        strokeUnits * size / designSize
    }

    /// The closed almond outline, meant to be stroked.
    static func eyeOutline(in rect: CGRect) -> CGPath {
        let t = gridTransform(in: rect)
        let path = CGMutablePath()
        path.move(to: corners.left, transform: t)
        path.addCurve(
            to: corners.right,
            control1: CGPoint(x: lidControlX.left, y: lidControlY.top),
            control2: CGPoint(x: lidControlX.right, y: lidControlY.top),
            transform: t
        )
        path.addCurve(
            to: corners.left,
            control1: CGPoint(x: lidControlX.right, y: lidControlY.bottom),
            control2: CGPoint(x: lidControlX.left, y: lidControlY.bottom),
            transform: t
        )
        path.closeSubpath()
        return path
    }
}
