import CoreGraphics

/// The menu bar mark as pure geometry: the app icon's almond lens
/// (`EyeLensGeometry.eyeOutline`) with a lid that shades it, five lashes on
/// that lid, and a pupil behind it. Same 24-unit grid and conventions as
/// `EyeLensGeometry`; CoreGraphics only.
///
/// The lid's `progress` runs from 0 (closed: the whole lens shaded, lashes
/// below) to 1 (open: nothing shaded, lashes above). The lid's lower edge
/// is a cubic interpolated between the lens's lower and upper lid curves,
/// so it lifts like an eyelid and uncovers the pupil from the bottom under a
/// smooth curve. The lashes themselves never move: each side is a fixed
/// set, and the view fades one out and the other in.
enum EyeMarkGeometry {
    /// Which side of the lens a set of lashes sits on.
    enum Side {
        /// Above the upper lid: the open eye.
        case above
        /// Below the lower lid: the closed eye.
        case below
    }

    static let designSize = EyeLensGeometry.designSize
    /// The eye's horizontal axis, through both corners.
    static let axisY = EyeLensGeometry.designSize / 2

    // Lashes: five, at these fractions of the lens width, each starting
    // `lashGap` beyond the lid's centre line along its outward normal and
    // running `lashLength`. Stroked at the outline's weight with round caps.
    // Gap and length leave the centre lash's cap about half a unit inside
    // the 24-unit frame, so nothing is clipped by the view's mask.
    static let lashFractions: [CGFloat] = [0.2, 0.35, 0.5, 0.65, 0.8]
    static let lashGap: CGFloat = 2.25
    static let lashLength: CGFloat = 2.75

    // Pupil: a disc with a highlight bitten out of its upper right.
    static let pupilCenter = CGPoint(x: 12, y: 12)
    static let pupilRadius: CGFloat = 4
    static let highlightCenter = CGPoint(x: 14, y: 10)
    static let highlightRadius: CGFloat = 1.4

    /// The closed almond outline, meant to be stroked: the icon's lens.
    static func lens(in rect: CGRect) -> CGPath {
        EyeLensGeometry.eyeOutline(in: rect)
    }

    /// The lid, meant to be filled: the region between the upper edge of the
    /// lens and the lid's lower edge, which runs from the lower lid curve at
    /// progress 0 to the upper lid curve at progress 1 (corners fixed,
    /// control points interpolated). One closed subpath.
    static func lid(in rect: CGRect, progress: CGFloat) -> CGPath {
        let t = EyeLensGeometry.gridTransform(in: rect)
        let p = min(max(progress, 0), 1)
        let upper = upperLid, lower = lowerLid
        // The lower lid runs right to left, so it is already the return leg.
        let edge1 = lerp(lower.c1, upper.c2, p)
        let edge2 = lerp(lower.c2, upper.c1, p)
        let path = CGMutablePath()
        path.move(to: upper.p0, transform: t)
        path.addCurve(to: upper.p3, control1: upper.c1, control2: upper.c2, transform: t)
        path.addCurve(to: upper.p0, control1: edge1, control2: edge2, transform: t)
        path.closeSubpath()
        return path
    }

    /// Five lashes as five open subpaths, meant to be stroked. The lower set
    /// is the upper set mirrored about the axis; neither moves.
    static func lashes(in rect: CGRect, side: Side) -> CGPath {
        let t = EyeLensGeometry.gridTransform(in: rect)
        let fold: CGFloat = side == .above ? 1 : -1
        let path = CGMutablePath()
        for (start, end) in upperLashes {
            path.move(to: folded(start, fold), transform: t)
            path.addLine(to: folded(end, fold), transform: t)
        }
        return path
    }

    /// The upper lashes in grid units, laid out once: each sits on the
    /// upper lid's outward normal at its fraction of the lens width.
    private static let upperLashes: [(start: CGPoint, end: CGPoint)] = {
        let lid = upperLid
        return lashFractions.map { fraction in
            let s = lid.parameter(atX: lid.p0.x + (lid.p3.x - lid.p0.x) * fraction)
            let base = lid.point(at: s)
            let tangent = lid.tangent(at: s)
            let length = hypot(tangent.x, tangent.y)
            // Outward normal of the upper lid: the tangent turned a quarter turn towards −y.
            let normal = CGPoint(x: tangent.y / length, y: -tangent.x / length)
            return (
                start: CGPoint(x: base.x + normal.x * lashGap, y: base.y + normal.y * lashGap),
                end: CGPoint(x: base.x + normal.x * (lashGap + lashLength), y: base.y + normal.y * (lashGap + lashLength))
            )
        }
    }()

    /// The pupil as one closed subpath, meant to be filled: the disc's rim
    /// runs the long way round from one intersection with the highlight to
    /// the other, and the highlight's arc comes back through the disc. A
    /// single subpath keeps it independent of the fill rule.
    static func pupil(in rect: CGRect) -> CGPath {
        let t = EyeLensGeometry.gridTransform(in: rect)
        let c = pupilCenter, h = highlightCenter
        let R = pupilRadius, r = highlightRadius
        let d = hypot(h.x - c.x, h.y - c.y)
        // Where the two circles meet, measured from the pupil's centre along the line to the highlight.
        let along = (d * d + R * R - r * r) / (2 * d)
        let half = (R * R - along * along).squareRoot()
        let towards = atan2(h.y - c.y, h.x - c.x)
        let rimSpread = acos(along / R)
        let biteSpread = atan2(half, along - d)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x + R * cos(towards + rimSpread), y: c.y + R * sin(towards + rimSpread)), transform: t)
        // Increasing angle: around the rim away from the highlight.
        path.addArc(center: c, radius: R, startAngle: towards + rimSpread, endAngle: towards - rimSpread, clockwise: false, transform: t)
        // Decreasing angle: along the highlight's inner arc back to the start.
        path.addArc(center: h, radius: r, startAngle: towards - biteSpread, endAngle: towards + biteSpread, clockwise: true, transform: t)
        path.closeSubpath()
        return path
    }

    // MARK: - The upper lid

    /// One cubic Bézier in grid units.
    private struct Cubic {
        let p0: CGPoint
        let c1: CGPoint
        let c2: CGPoint
        let p3: CGPoint

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
        }

        func tangent(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = 3 * u * u, b = 6 * u * t, c = 3 * t * t
            return CGPoint(
                x: a * (c1.x - p0.x) + b * (c2.x - c1.x) + c * (p3.x - c2.x),
                y: a * (c1.y - p0.y) + b * (c2.y - c1.y) + c * (p3.y - c2.y)
            )
        }

        /// Parameter at which the curve crosses `x`; x is monotone along a lid.
        func parameter(atX x: CGFloat) -> CGFloat {
            var lo: CGFloat = 0, hi: CGFloat = 1
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if point(at: mid).x < x { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }
    }

    /// The lens's two lids, read back from the outline (upper curve left to
    /// right, lower curve right to left) so the mark follows the icon's lens
    /// without repeating its numbers. Should the outline ever stop being two
    /// cubics, the lids fall back to a symmetric pair fitted to its bounding
    /// box rather than trapping at first draw; the branding tests pin the
    /// parse so that fallback never ships unnoticed.
    private static let lids: (upper: Cubic, lower: Cubic) = {
        let grid = CGRect(x: 0, y: 0, width: designSize, height: designSize)
        let outline = EyeLensGeometry.eyeOutline(in: grid)
        var points: [CGPoint] = []
        outline.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint where points.isEmpty:
                points.append(element.pointee.points[0])
            case .addCurveToPoint where points.count == 1 || points.count == 4:
                points.append(contentsOf: [element.pointee.points[0], element.pointee.points[1], element.pointee.points[2]])
            default:
                break
            }
        }
        assert(points.count == 7, "the eye outline should be two cubic lids")
        guard points.count == 7 else {
            // Corners at the box's mid-height; control points a third of the
            // way in from each corner, at the height that puts the cubic's
            // apex on the box's edge (apex = (2·corner + 6·control) / 8).
            let box = outline.boundingBoxOfPath
            let left = CGPoint(x: box.minX, y: box.midY), right = CGPoint(x: box.maxX, y: box.midY)
            let x1 = box.minX + box.width / 3, x2 = box.maxX - box.width / 3
            let topY = (8 * box.minY - 2 * box.midY) / 6, bottomY = (8 * box.maxY - 2 * box.midY) / 6
            return (
                upper: Cubic(p0: left, c1: CGPoint(x: x1, y: topY), c2: CGPoint(x: x2, y: topY), p3: right),
                lower: Cubic(p0: right, c1: CGPoint(x: x2, y: bottomY), c2: CGPoint(x: x1, y: bottomY), p3: left)
            )
        }
        return (
            upper: Cubic(p0: points[0], c1: points[1], c2: points[2], p3: points[3]),
            lower: Cubic(p0: points[3], c1: points[4], c2: points[5], p3: points[6])
        )
    }()

    private static var upperLid: Cubic { lids.upper }
    private static var lowerLid: Cubic { lids.lower }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Mirrors a point about the axis when `fold` is −1, leaves it at 1.
    private static func folded(_ p: CGPoint, _ fold: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: axisY + (p.y - axisY) * fold)
    }
}
