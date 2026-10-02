import CoreGraphics
import SwiftUI
import XCTest
@testable import Insomnia

/// The marks, checked on rendered geometry. The app icon's eye and moon: the
/// crescent's spine is on the left with its opening and tips to the right,
/// and it stays clear of the eye outline. The menu bar's eye: shaded shut
/// with lashes below while idle, open with a pupil and lashes above while
/// running, monochrome in both states.
final class BrandingTests: XCTestCase {
    private let grid = CGRect(x: 0, y: 0, width: EyeMoonGeometry.designSize, height: EyeMoonGeometry.designSize)

    func testCrescentSpineIsOnTheLeftAndItsOpeningAndTipsFaceRight() {
        let moon = EyeMoonGeometry.crescent(in: grid)
        let eye = EyeMoonGeometry.eyeOutline(in: grid)
        let box = moon.boundingBoxOfPath
        let axisY = grid.midY

        // Solid along the spine, and the spine sits left of the eye's centre.
        XCTAssertTrue(moon.contains(CGPoint(x: box.minX + 0.5, y: axisY)))
        XCTAssertLessThan(box.midX, eye.boundingBoxOfPath.midX)
        // The opening: the axis just inside the right edge is empty.
        XCTAssertFalse(moon.contains(CGPoint(x: box.maxX - 0.4, y: axisY)))
        // Two tips at the right edge, one above and one below the axis.
        let probeX = box.maxX - 0.4
        let rows = stride(from: box.minY, through: box.maxY, by: 0.05).filter { moon.contains(CGPoint(x: probeX, y: $0)) }
        XCTAssertFalse(rows.isEmpty, "no tip found at x=\(probeX)")
        XCTAssertTrue(rows.contains { $0 < axisY - 1 }, "upper tip missing: \(rows)")
        XCTAssertTrue(rows.contains { $0 > axisY + 1 }, "lower tip missing: \(rows)")
        XCTAssertFalse(rows.contains { abs($0 - axisY) < 0.5 }, "the moon must not bridge its own opening: \(rows)")
    }

    func testCrescentIsSolidInsideTheEyeAndNeverTouchesTheOutline() {
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let eye = EyeMoonGeometry.eyeOutline(in: rect)
        let moon = EyeMoonGeometry.crescent(in: rect)
        let outline = Raster(size: size) { ctx in
            ctx.addPath(eye)
            ctx.setLineWidth(EyeMoonGeometry.lineWidth(for: CGFloat(size)))
            ctx.strokePath()
        }
        let fill = Raster(size: size) { ctx in
            ctx.addPath(moon)
            ctx.fillPath()
        }

        var moonPixels = 0
        var overlap = 0
        var outsideEye = 0
        for y in 0..<size {
            for x in 0..<size where fill.alpha(x, y) > 0.5 {
                moonPixels += 1
                if outline.alpha(x, y) > 0.05 { overlap += 1 }
                if !eye.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { outsideEye += 1 }
            }
        }
        XCTAssertGreaterThan(moonPixels, size * size / 40, "the moon is a solid shape, not a hairline")
        XCTAssertEqual(overlap, 0, "the moon must not touch the eye outline")
        XCTAssertEqual(outsideEye, 0, "the moon must sit inside the eye")
        // Only one closed subpath: nothing else (no iris, lashes, stars) is drawn inside the eye.
        XCTAssertEqual(subpathCount(moon), 1)
        XCTAssertEqual(subpathCount(eye), 1)
    }

    @MainActor
    func testIdleMarkIsAShadedClosedEyeWithLashesBelowInLightAndDark() throws {
        for (scheme, reduceMotion) in product([ColorScheme.light, .dark], [true, false]) {
            let view = EyeMarkView(isRunning: false, reduceMotion: reduceMotion, size: 17)
            let px = try Raster.render(view, scheme: scheme, scale: 2)
            let ink = px.count { $0.alpha > 0.5 }
            XCTAssertGreaterThan(ink, 150, "\(scheme): too little ink for a shaded lens at 17pt")
            XCTAssertLessThan(ink, px.total / 2, "\(scheme): the mark must not flood its frame")

            let probes = Probes(size: 17, scale: 2)
            XCTAssertGreaterThan(px.alpha(probes.outline), 0.5, "\(scheme): outline missing at \(probes.outline)")
            // `.primary` is the system label colour, which is itself only 85% opaque.
            XCTAssertGreaterThan(px.alpha(probes.interior), 0.7, "\(scheme): the closed lens is shaded in at \(probes.interior)")
            XCTAssertGreaterThan(px.alpha(probes.pupil), 0.7, "\(scheme): the shading covers the pupil at \(probes.pupil)")
            XCTAssertGreaterThan(px.alpha(probes.lashBelow), 0.5, "\(scheme): lashes hang below the closed eye at \(probes.lashBelow)")
            XCTAssertLessThan(px.alpha(probes.lashAbove), 0.05, "\(scheme): no lashes above the closed eye at \(probes.lashAbove)")
            let ink0 = px.rgb(probes.interior)
            XCTAssertLessThan(ink0.saturation, 0.1, "\(scheme): the mark is monochrome: \(ink0)")
            switch scheme {
            case .light: XCTAssertLessThan(ink0.luminance, 0.3, "light: ink is dark")
            case .dark: XCTAssertGreaterThan(ink0.luminance, 0.7, "dark: ink is light")
            @unknown default: XCTFail("unexpected scheme")
            }
        }
    }

    @MainActor
    func testRunningMarkIsAnOpenEyeWithAPupilAndLashesAboveAndStaysMonochrome() throws {
        let probes = Probes(size: 17, scale: 2)
        for (scheme, reduceMotion) in product([ColorScheme.light, .dark], [true, false]) {
            let idle = try Raster.render(EyeMarkView(isRunning: false, reduceMotion: reduceMotion), scheme: scheme, scale: 2)
            let active = try Raster.render(EyeMarkView(isRunning: true, reduceMotion: reduceMotion), scheme: scheme, scale: 2)

            XCTAssertLessThan(active.alpha(probes.interior), 0.05, "\(scheme): the open lens is clear between pupil and outline at \(probes.interior)")
            XCTAssertGreaterThan(active.alpha(probes.pupil), 0.7, "\(scheme): pupil missing at \(probes.pupil)")
            XCTAssertGreaterThan(active.alpha(probes.outline), 0.5, "\(scheme): outline missing while running at \(probes.outline)")
            XCTAssertGreaterThan(active.alpha(probes.lashAbove), 0.5, "\(scheme): lashes stand above the open eye at \(probes.lashAbove)")
            XCTAssertLessThan(active.alpha(probes.lashBelow), 0.05, "\(scheme): no lashes below the open eye at \(probes.lashBelow)")
            XCTAssertLessThan(active.count { $0.alpha > 0.5 }, idle.count { $0.alpha > 0.5 }, "\(scheme): opening the eye removes the shading")

            // No tint in either state: the running mark takes the same label colour as the idle one.
            let pupil = active.rgb(probes.pupil)
            let shade = idle.rgb(probes.pupil)
            XCTAssertLessThan(pupil.saturation, 0.1, "\(scheme): running mark is monochrome: \(pupil)")
            XCTAssertLessThan(shade.saturation, 0.1, "\(scheme): idle mark is monochrome: \(shade)")
            XCTAssertEqual(pupil.luminance, shade.luminance, accuracy: 0.05, "\(scheme): both states share one ink")
        }
    }

    func testLashesAreFiveStrokesThatSwapSidesAndThePupilSitsInsideTheLens() {
        let lens = EyeMarkGeometry.lens(in: grid)
        let axisY = grid.midY
        let open = EyeMarkGeometry.lashes(in: grid, side: .above)
        let closed = EyeMarkGeometry.lashes(in: grid, side: .below)
        XCTAssertEqual(subpathCount(open), 5)
        XCTAssertEqual(subpathCount(closed), 5)
        for point in points(of: open) {
            XCTAssertLessThan(point.y, axisY, "open lashes stand above the axis: \(point)")
            XCTAssertFalse(lens.contains(point), "lashes stay outside the lens: \(point)")
        }
        for point in points(of: closed) {
            XCTAssertGreaterThan(point.y, axisY, "closed lashes hang below the axis: \(point)")
            XCTAssertFalse(lens.contains(point), "lashes stay outside the lens: \(point)")
        }
        // Each lash is a plain segment of the designed length.
        XCTAssertEqual(points(of: open).count, 10)
        for pair in stride(from: 0, to: 10, by: 2) {
            let a = points(of: open)[pair], b = points(of: open)[pair + 1]
            XCTAssertEqual(hypot(b.x - a.x, b.y - a.y), EyeMarkGeometry.lashLength, accuracy: 0.01)
        }

        let pupil = EyeMarkGeometry.pupil(in: grid)
        XCTAssertEqual(subpathCount(pupil), 1)
        for point in points(of: pupil) {
            XCTAssertTrue(lens.contains(point), "the pupil sits inside the lens: \(point)")
        }
        // Solid at the centre, open at the highlight.
        XCTAssertTrue(pupil.contains(EyeMarkGeometry.pupilCenter))
        XCTAssertFalse(pupil.contains(EyeMarkGeometry.highlightCenter))

    }

    func testLidShadesTheWholeLensClosedNothingOpenAndLiftsOffThePupilFromTheBottom() {
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let unit = CGFloat(size) / EyeMoonGeometry.designSize
        func raster(_ path: CGPath) -> Raster {
            Raster(size: size) { ctx in
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
        func inked(_ path: CGPath) -> Int { raster(path).count { $0.alpha > 0.5 } }

        let closed = inked(EyeMarkGeometry.lid(in: rect, progress: 0))
        let open = inked(EyeMarkGeometry.lid(in: rect, progress: 1))
        let half = inked(EyeMarkGeometry.lid(in: rect, progress: 0.5))
        XCTAssertEqual(open, 0, "an open lid shades nothing")
        // Pixel for pixel, the closed lid is the filled lens.
        let closedLid = raster(EyeMarkGeometry.lid(in: rect, progress: 0))
        let lens = raster(EyeMarkGeometry.lens(in: rect))
        var mismatches = 0
        for y in 0..<size {
            for x in 0..<size where (closedLid.alpha(x, y) > 0.5) != (lens.alpha(x, y) > 0.5) { mismatches += 1 }
        }
        XCTAssertEqual(mismatches, 0, "a closed lid shades exactly the lens")
        XCTAssertGreaterThan(half, open, "half way, some of the lens is shaded")
        XCTAssertLessThan(half, closed, "half way, some of the lens is clear")
        XCTAssertEqual(subpathCount(EyeMarkGeometry.lid(in: rect, progress: 0.5)), 1)

        // Half way, the pupil's centre column is covered above the axis and clear below it.
        let lid = raster(EyeMarkGeometry.lid(in: rect, progress: 0.5))
        let column = Int(EyeMarkGeometry.pupilCenter.x * unit)
        let axis = Int(EyeMarkGeometry.pupilCenter.y * unit)
        let radius = Int(EyeMarkGeometry.pupilRadius * unit)
        for y in (axis + 1)...(axis + radius) {
            XCTAssertLessThan(lid.alpha(column, y), 0.5, "the lower pupil is uncovered at row \(y)")
        }
        for y in (axis - radius)...(axis - 1) {
            XCTAssertGreaterThan(lid.alpha(column, y), 0.5, "the upper pupil is still shaded at row \(y)")
        }
    }

    func testStrokedLensAndLashesFitInsideTheSeventeenPointFrame() {
        let frame = CGRect(x: 0, y: 0, width: 17, height: 17)
        let width = EyeMoonGeometry.lineWidth(for: frame.width)
        let stroked = CGMutablePath()
        for path in [EyeMarkGeometry.lens(in: frame), EyeMarkGeometry.lashes(in: frame, side: .above), EyeMarkGeometry.lashes(in: frame, side: .below)] {
            stroked.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        let box = stroked.boundingBoxOfPath
        XCTAssertTrue(frame.contains(box), "the view's frame clips the mark: \(box)")
        // Enough headroom that a sub-pixel rasteriser does not clip the caps.
        let headroom = 0.4 * frame.width / EyeMoonGeometry.designSize
        XCTAssertGreaterThanOrEqual(box.minY - frame.minY, headroom, "upper lashes too close to the edge: \(box)")
        XCTAssertLessThanOrEqual(box.maxY, frame.maxY - headroom, "lower lashes too close to the edge: \(box)")
    }

    func testPupilStaysClearOfTheOutlineAtSeventeenPoints() {
        let size = 34  // 17 pt @2x
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let outline = Raster(size: size) { ctx in
            ctx.addPath(EyeMarkGeometry.lens(in: rect))
            ctx.setLineWidth(EyeMoonGeometry.lineWidth(for: CGFloat(size)))
            ctx.strokePath()
        }
        let fill = Raster(size: size) { ctx in
            ctx.addPath(EyeMarkGeometry.pupil(in: rect))
            ctx.fillPath()
        }
        var pupilPixels = 0
        var overlap = 0
        for y in 0..<size {
            for x in 0..<size where fill.alpha(x, y) > 0.5 {
                pupilPixels += 1
                if outline.alpha(x, y) > 0.05 { overlap += 1 }
            }
        }
        XCTAssertGreaterThan(pupilPixels, size * size / 40, "the pupil is a solid disc, not a dot")
        XCTAssertEqual(overlap, 0, "the pupil must not touch the eye outline")
    }

    // MARK: - The blink

    /// The blink has to be seen: the lid lifts on a long spring and drops on
    /// a slightly shorter, better-damped one; the pupil arrives a beat after
    /// the lid starts and bounces a little, and shrinks straight away on
    /// close. Under Reduce Motion everything is one 0.3 s crossfade.
    @MainActor
    func testTheBlinkRunsOnSeparateLidAndPupilCurvesInEachDirection() {
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), .spring(response: 0.95, dampingFraction: 0.9))
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: false), .spring(response: 0.8, dampingFraction: 0.95))
        XCTAssertEqual(Motion.blink(opening: true, reduceMotion: false), Motion.blink)
        XCTAssertEqual(Motion.blink(opening: false, reduceMotion: false), Motion.blinkClose)
        XCTAssertGreaterThan(Motion.blinkResponse, Motion.baseResponse)
        XCTAssertGreaterThan(Motion.blinkCloseResponse, Motion.baseResponse)

        XCTAssertEqual(Motion.pupil(opening: true, reduceMotion: false), .spring(response: 0.5, dampingFraction: 0.6).delay(0.2))
        XCTAssertEqual(Motion.pupil(opening: false, reduceMotion: false), .easeOut(duration: 0.4))
        XCTAssertEqual(Motion.pupilOpenDelay, 0.2)
        XCTAssertLessThan(Motion.pupilOpenDelay, Motion.blinkResponse, "the pupil starts while the lid is still lifting")

        for opening in [true, false] {
            XCTAssertEqual(Motion.blink(opening: opening, reduceMotion: true), .easeInOut(duration: 0.3))
            XCTAssertEqual(Motion.pupil(opening: opening, reduceMotion: true), .easeInOut(duration: 0.3))
        }
        XCTAssertEqual(Motion.reducedBlinkDuration, 0.3)
    }

    /// One state value drives the pupil: full and present in the open eye,
    /// shrunk and gone in the closed one. Under Reduce Motion it never
    /// scales; only its opacity crosses over.
    @MainActor
    func testThePupilShrinksAwayWhenTheEyeClosesAndNeverScalesUnderReduceMotion() {
        XCTAssertEqual(Motion.pupilClosedScale, 0.6)
        let open = EyeMarkView(isRunning: true, reduceMotion: false)
        let closed = EyeMarkView(isRunning: false, reduceMotion: false)
        XCTAssertEqual(open.pupilScale, 1)
        XCTAssertEqual(open.pupilOpacity, 1)
        XCTAssertEqual(closed.pupilScale, 0.6)
        XCTAssertEqual(closed.pupilOpacity, 0)

        let reducedOpen = EyeMarkView(isRunning: true, reduceMotion: true)
        let reducedClosed = EyeMarkView(isRunning: false, reduceMotion: true)
        XCTAssertEqual(reducedOpen.pupilScale, 1)
        XCTAssertEqual(reducedClosed.pupilScale, 1, "no pupil scaling at all under Reduce Motion")
        XCTAssertEqual(reducedOpen.pupilOpacity, 1)
        XCTAssertEqual(reducedClosed.pupilOpacity, 0)
    }

    /// The opening spring peaks at about 1.04 and an interrupted blink can
    /// stop anywhere, so the drawn pupil is clipped to the lens: nothing of
    /// it, at any scale, lands outside the outline.
    @MainActor
    func testThePupilIsClippedToTheLensHoweverFarItOvershoots() throws {
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let lens = EyeMarkGeometry.lens(in: rect)
        func outsideLens(_ px: Raster) -> Int {
            var n = 0
            for y in 0..<size {
                for x in 0..<size where px.alpha(x, y) > 0.5 && !lens.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { n += 1 }
            }
            return n
        }
        func render<V: View>(_ view: V) throws -> Raster {
            try Raster.render(view.frame(width: CGFloat(size), height: CGFloat(size)), scheme: .light, scale: 1)
        }

        let rest = try render(EyePupilLayer(scale: 1, opacity: 1))
        let peak = try render(EyePupilLayer(scale: 1.04, opacity: 1))
        XCTAssertEqual(outsideLens(rest), 0)
        XCTAssertEqual(outsideLens(peak), 0, "the overshoot peak stays inside the lens")
        XCTAssertGreaterThan(peak.count { $0.alpha > 0.5 }, rest.count { $0.alpha > 0.5 }, "the clip does not eat a pupil that fits")

        // Far beyond any real overshoot, the clip is what keeps it in: the
        // same pupil unclipped would show outside the outline.
        let wild = try render(EyePupilLayer(scale: 1.6, opacity: 1))
        let unclipped = try render(EyePupil().fill(.black).scaleEffect(1.6, anchor: EyePupilLayer.anchor))
        XCTAssertGreaterThan(outsideLens(unclipped), 0, "the control should overshoot the lens")
        XCTAssertEqual(outsideLens(wild), 0, "clipped, the pupil never leaves the lens")
        XCTAssertGreaterThan(wild.count { $0.alpha > 0.5 }, 0)
    }

    /// The lid's progress is left unclamped in the view so the spring can
    /// overshoot; the geometry bounds what is drawn instead.
    func testTheLidGeometryClampHoldsBelowZeroAndAboveOne() {
        let size = 96
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        func raster(_ progress: CGFloat) -> Raster {
            Raster(size: size) { ctx in
                ctx.addPath(EyeMarkGeometry.lid(in: rect, progress: progress))
                ctx.fillPath()
            }
        }
        func mismatches(_ a: Raster, _ b: Raster) -> Int {
            var n = 0
            for y in 0..<size {
                for x in 0..<size where (a.alpha(x, y) > 0.5) != (b.alpha(x, y) > 0.5) { n += 1 }
            }
            return n
        }
        let closed = raster(0), open = raster(1)
        for below in [-0.01, -0.5, -3] as [CGFloat] {
            XCTAssertEqual(mismatches(raster(below), closed), 0, "progress \(below) draws the closed lid")
        }
        for above in [1.01, 1.04, 1.5, 4] as [CGFloat] {
            XCTAssertEqual(mismatches(raster(above), open), 0, "progress \(above) draws the open lid")
            XCTAssertEqual(raster(above).count { $0.alpha > 0.5 }, 0, "progress \(above) shades nothing")
        }
        // And every out-of-range lid is still one well-formed subpath inside the frame.
        for progress in [-3, 4] as [CGFloat] {
            let lid = EyeMarkGeometry.lid(in: rect, progress: progress)
            XCTAssertEqual(subpathCount(lid), 1)
            XCTAssertTrue(rect.contains(lid.boundingBoxOfPath), "\(lid.boundingBoxOfPath)")
        }
    }

    // MARK: - Helpers

    private func product<A, B>(_ a: [A], _ b: [B]) -> [(A, B)] {
        a.flatMap { x in b.map { (x, $0) } }
    }

    private func subpathCount(_ path: CGPath) -> Int {
        var moves = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moves += 1 }
        }
        return moves
    }

    /// Every point of every element, control points included.
    private func points(of path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for i in 0..<count { points.append(element.pointee.points[i]) }
        }
        return points
    }

    /// Grid points worth probing, mapped into a rendered view of `size`
    /// points at `scale`: derived from the paths' own bounding boxes so the
    /// test follows the geometry rather than pinning magic numbers.
    private struct Probes {
        let outline: (Int, Int)
        /// Between the pupil's right edge and the outline: shaded when closed, clear when open.
        let interior: (Int, Int)
        let pupil: (Int, Int)
        /// Midway along the centre lash in each position.
        let lashAbove: (Int, Int)
        let lashBelow: (Int, Int)

        init(size: CGFloat, scale: CGFloat) {
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let eyeBox = EyeMarkGeometry.lens(in: rect).boundingBoxOfPath
            let pupilBox = EyeMarkGeometry.pupil(in: rect).boundingBoxOfPath
            let aboveBox = EyeMarkGeometry.lashes(in: rect, side: .above).boundingBoxOfPath
            let belowBox = EyeMarkGeometry.lashes(in: rect, side: .below).boundingBoxOfPath
            let unit = size / EyeMoonGeometry.designSize
            func px(_ x: CGFloat, _ y: CGFloat) -> (Int, Int) { (Int((x * scale).rounded()), Int((y * scale).rounded())) }
            outline = px(eyeBox.minX + 0.3 * unit, eyeBox.midY)
            interior = px((pupilBox.maxX + eyeBox.maxX) / 2, eyeBox.midY)
            pupil = px(EyeMarkGeometry.pupilCenter.x * unit, EyeMarkGeometry.pupilCenter.y * unit)
            lashAbove = px(aboveBox.midX, aboveBox.minY + EyeMarkGeometry.lashLength / 2 * unit)
            lashBelow = px(belowBox.midX, belowBox.maxY - EyeMarkGeometry.lashLength / 2 * unit)
        }
    }
}

/// RGBA8 bitmap with the design's y-down orientation, drawn by CoreGraphics
/// or filled from a rendered SwiftUI view.
struct Raster {
    struct RGB: CustomStringConvertible {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
        var saturation: CGFloat {
            let hi = max(red, green, blue)
            let lo = min(red, green, blue)
            return hi == 0 ? 0 : (hi - lo) / hi
        }
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }

    let width: Int
    let height: Int
    private let data: [UInt8]

    var total: Int { width * height }

    init(size: Int, draw: (CGContext) -> Void) {
        self.init(width: size, height: size) { ctx in
            // Design coordinates are y-down; CoreGraphics bitmaps are y-up.
            ctx.translateBy(x: 0, y: CGFloat(size))
            ctx.scaleBy(x: 1, y: -1)
            draw(ctx)
        }
    }

    private init(width: Int, height: Int, draw: (CGContext) -> Void) {
        self.width = width
        self.height = height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            draw(ctx)
        }
        data = bytes
    }

    /// Renders a SwiftUI view under `scheme` at `scale` into a bitmap whose
    /// (0,0) is the view's top-left.
    @MainActor
    static func render<V: View>(_ view: V, scheme: ColorScheme, scale: CGFloat) throws -> Raster {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        return Raster(width: image.width, height: image.height) { ctx in
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private func offset(_ x: Int, _ y: Int) -> Int {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "pixel (\(x), \(y)) outside \(width)x\(height)")
        return (y * width + x) * 4
    }

    func alpha(_ x: Int, _ y: Int) -> CGFloat {
        CGFloat(data[offset(x, y) + 3]) / 255
    }

    func alpha(_ p: (Int, Int)) -> CGFloat { alpha(p.0, p.1) }

    /// Straight (un-premultiplied) colour at a pixel.
    func rgb(_ p: (Int, Int)) -> RGB {
        let o = offset(p.0, p.1)
        let a = max(CGFloat(data[o + 3]), 1)
        return RGB(red: CGFloat(data[o]) / a, green: CGFloat(data[o + 1]) / a, blue: CGFloat(data[o + 2]) / a)
    }

    func count(where pass: ((alpha: CGFloat, rgb: RGB)) -> Bool) -> Int {
        var n = 0
        for y in 0..<height {
            for x in 0..<width where pass((alpha(x, y), rgb((x, y)))) { n += 1 }
        }
        return n
    }
}
