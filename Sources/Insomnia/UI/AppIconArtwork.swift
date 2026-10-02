import CoreGraphics
import Foundation

/// The app icon as one drawing: the menu bar's open eye (`EyeMarkGeometry`
/// at progress 1, so the lens, the pupil and the five lashes above the upper
/// lid) in moon-white on a charcoal rounded tile. scripts/generate-app-icon.sh
/// compiles this file with the geometry and palette into the icon generator,
/// which writes the PNG, the ICNS members and the README SVG from it, and
/// the tests render it to check those files, so the icon and the running
/// menu bar mark share one geometry and cannot drift apart. CoreGraphics and
/// Foundation only, no SwiftUI or AppKit, so the file builds standalone.
enum AppIconArtwork {
    /// Apple's macOS icon layout: a rounded tile inset in the 1024 canvas
    /// (the margin is where the system draws its shadow), corners rounded
    /// at a fixed share of the tile side.
    static let canvas: CGFloat = 1024
    static let tileInset: CGFloat = 100
    static let cornerShare: CGFloat = 0.2237
    /// The 24-unit design grid's side as a share of the tile side.
    static let markShare: CGFloat = 0.76
    /// The outline never gets thinner than one device pixel, so the 16 and
    /// 32 pixel sizes keep a readable eye instead of a grey smudge.
    static let minimumStrokePixels: CGFloat = 1

    /// Below this many pixels the five lashes are left out: at 16 they are
    /// a grey band over a nine-pixel eye, and the eye reads better alone.
    static let lashesFromPixels = 32

    /// The tile, in canvas units.
    static let tile = CGRect(x: tileInset, y: tileInset, width: canvas - 2 * tileInset, height: canvas - 2 * tileInset)

    /// The mark's square, in canvas units: the 24-unit grid at `markShare`
    /// of the tile, centred across it, and placed so that what is drawn
    /// (the stroked lens and lashes together) is centred down it. The open
    /// eye's lashes stand above the axis with nothing below, so a grid
    /// centred on the tile would leave the mark sitting high.
    static let mark: CGRect = {
        let side = tile.width * markShare
        let grid = CGRect(x: 0, y: 0, width: EyeLensGeometry.designSize, height: EyeLensGeometry.designSize)
        let lift = (grid.midY - inked(in: grid).midY) * side / EyeLensGeometry.designSize
        return CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2 + lift, width: side, height: side)
    }()

    /// The box the mark's strokes and fills cover when drawn into `rect`:
    /// the lens and the lashes grown by half the line weight for their
    /// round caps, and the pupil, which lies inside the lens.
    static func inked(in rect: CGRect) -> CGRect {
        let half = EyeLensGeometry.lineWidth(for: rect.width) / 2
        return EyeMarkGeometry.lens(in: rect).boundingBoxOfPath
            .union(EyeMarkGeometry.lashes(in: rect, side: .above).boundingBoxOfPath)
            .insetBy(dx: -half, dy: -half)
    }

    /// The pieces of the mark, as paths in canvas units.
    static var lens: CGPath { EyeMarkGeometry.lens(in: mark) }
    static var pupil: CGPath { EyeMarkGeometry.pupil(in: mark) }
    static var lashes: CGPath { EyeMarkGeometry.lashes(in: mark, side: .above) }

    /// The whole icon at `pixels` square, or nil if no bitmap context of
    /// that size can be made.
    static func render(pixels: Int) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // Work in canvas units, y-down like the geometry.
        let scale = CGFloat(pixels) / canvas
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)
        draw(in: ctx, scale: scale, lashes: pixels >= lashesFromPixels)
        return ctx.makeImage()
    }

    /// Draws the icon into a context already set up in canvas units, with
    /// `scale` device pixels per canvas unit (for the stroke floor), with
    /// or without the lashes.
    static func draw(in ctx: CGContext, scale: CGFloat, lashes: Bool) {
        let corner = tile.width * cornerShare
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(BrandPalette.midnight.cgColor)
        ctx.fillPath()

        let stroke = max(EyeLensGeometry.lineWidth(for: mark.width), minimumStrokePixels / scale)
        ctx.setStrokeColor(BrandPalette.moonWhite.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(lens)
        ctx.strokePath()
        if lashes {
            ctx.addPath(Self.lashes)
            ctx.strokePath()
        }
        ctx.setFillColor(BrandPalette.moonWhite.cgColor)
        ctx.addPath(pupil)
        ctx.fillPath()
    }

    // MARK: - The README SVG

    /// The same drawing as an SVG document: the tile alone (the canvas
    /// margin is cropped by the viewBox) at 112 CSS pixels, with the mark's
    /// paths written out on the 24-unit grid from the same geometry.
    static func svg() -> String {
        let grid = CGRect(x: 0, y: 0, width: EyeLensGeometry.designSize, height: EyeLensGeometry.designSize)
        let scale = mark.width / EyeLensGeometry.designSize
        let ink = hex(BrandPalette.moonWhite)
        let strokeAttributes = "fill=\"none\" stroke=\"\(ink)\" stroke-width=\"\(number(EyeLensGeometry.strokeUnits))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="112" height="112" viewBox="\(number(tile.minX)) \(number(tile.minY)) \(number(tile.width)) \(number(tile.height))" role="img" aria-labelledby="eo-title eo-desc">
          <title id="eo-title">Insomnia</title>
          <desc id="eo-desc">The Insomnia mark: an open almond-shaped eye with a round pupil and five lashes above the upper lid, drawn in moon-white on a charcoal rounded tile.</desc>
          <!-- Written by scripts/generate-app-icon.sh from AppIconArtwork; do not edit by hand. Same layout as the app icon: an \(number(tile.width))-unit tile inset \(number(tileInset)) units in a \(number(canvas)) canvas, corners at \(number(cornerShare * 100))% of the tile, the 24-unit mark grid at \(number(markShare * 100))% of the tile side. -->
          <rect x="\(number(tile.minX))" y="\(number(tile.minY))" width="\(number(tile.width))" height="\(number(tile.height))" rx="\(number(tile.width * cornerShare))" fill="\(hex(BrandPalette.midnight))"/>
          <!-- EyeMarkGeometry at progress 1 on its 24-unit grid: the lens (two cubic lids), the pupil with its highlight bitten out, and the five lashes above the upper lid. -->
          <g transform="translate(\(number(mark.minX)) \(number(mark.minY))) scale(\(number(scale)))">
            <path d="\(pathData(EyeMarkGeometry.lens(in: grid)))" \(strokeAttributes)/>
            <path d="\(pathData(EyeMarkGeometry.pupil(in: grid)))" fill="\(ink)"/>
            <path d="\(pathData(EyeMarkGeometry.lashes(in: grid, side: .above)))" \(strokeAttributes)/>
          </g>
        </svg>

        """
    }

    /// A CGPath as SVG path data: moves, lines, cubics and closes, which is
    /// all CoreGraphics hands back (its arcs come out as cubics).
    static func pathData(_ path: CGPath) -> String {
        var commands: [String] = []
        var current = CGPoint.zero
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                commands.append("M\(point(p[0]))")
                current = p[0]
            case .addLineToPoint:
                // An arc starts with a line to its first point, which is a
                // zero-length segment when the path is already there.
                if hypot(p[0].x - current.x, p[0].y - current.y) > 0.00005 {
                    commands.append("L\(point(p[0]))")
                }
                current = p[0]
            case .addQuadCurveToPoint:
                commands.append("Q\(point(p[0])) \(point(p[1]))")
                current = p[1]
            case .addCurveToPoint:
                commands.append("C\(point(p[0])) \(point(p[1])) \(point(p[2]))")
                current = p[2]
            case .closeSubpath:
                commands.append("Z")
            @unknown default:
                break
            }
        }
        return commands.joined(separator: " ")
    }

    private static func point(_ p: CGPoint) -> String {
        "\(number(p.x)) \(number(p.y))"
    }

    /// A number to four decimals with trailing zeros dropped, so the SVG is
    /// stable from run to run and readable.
    static func number(_ value: CGFloat) -> String {
        var text = String(format: "%.4f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// A palette colour as `#RRGGBB`.
    static func hex(_ rgb: BrandPalette.RGB) -> String {
        let channels = [rgb.red, rgb.green, rgb.blue].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }
}
