import CoreGraphics
import Foundation

/// The app icon as one drawing. It is the menu bar's open eye,
/// `EyeMarkGeometry` at progress 1, with the lens, the pupil and the five
/// lashes above the upper lid in moon-white on a charcoal rounded tile.
/// scripts/generate-app-icon.sh compiles this file with the geometry and
/// palette into the icon generator, which writes the PNG, the ICNS members
/// and the README SVG. PackagingTests renders this drawing and compares it
/// with all three checked-in files, so a geometry edit fails the tests until
/// the script runs again. The file imports only CoreGraphics and Foundation,
/// so swiftc can build it outside the app target.
enum AppIconArtwork {
    /// Apple's macOS icon layout. The rounded tile sits 100 units in from
    /// each edge of the 1024 canvas, and the system draws the icon's shadow
    /// in that margin. The corner radius is 22.37% of the tile side.
    static let canvas: CGFloat = 1024
    static let tileInset: CGFloat = 100
    static let cornerShare: CGFloat = 0.2237
    /// The 24-unit design grid's side as a share of the tile side, 626.24
    /// canvas units.
    static let markShare: CGFloat = 0.76
    /// The thinnest stroke, in device pixels. The design stroke is 1.5 grid
    /// units, 0.61 px at 16 pixels and 1.22 px at 32, so this floor only
    /// thickens the 16 pixel member. A 0.61 px line covers at most 61% of
    /// any pixel, which draws the outline grey instead of moon-white.
    static let minimumStrokePixels: CGFloat = 1

    /// `render` draws the five lashes from this many pixels up. At 16
    /// pixels a grid unit is 0.41 px, so each lash would be a 1.1 px line
    /// under the 1 px stroke floor, with about 0.6 px between neighbours at
    /// the lid. The five would merge into one grey band over a lens 8.6 px
    /// wide.
    static let lashesFromPixels = 32

    /// The tile, in canvas units.
    static let tile = CGRect(x: tileInset, y: tileInset, width: canvas - 2 * tileInset, height: canvas - 2 * tileInset)

    /// The mark's square when the lashes are drawn, at 32 pixels and up and
    /// in the README SVG.
    static let mark = placement(lashes: true)
    /// The mark's square at 16 pixels, where `render` leaves the lashes
    /// out. The lens and pupil are symmetric about the eye's axis at y 12,
    /// so this square is the grid centred on the tile.
    static let markWithoutLashes = placement(lashes: false)

    /// The mark's square, in canvas units. The square takes `markShare` of
    /// the tile side and is centred across the tile. Down the tile, this
    /// centres the inked box instead of the grid. With lashes the inked box
    /// runs from y 0.625 to 18.375 on the grid, so its centre is 9.5 against
    /// the grid's 12, and the square moves down 2.5 grid units, which is
    /// 65.2 canvas units and 2 px at 32 pixels. Without lashes the box
    /// runs from 5.625 to 18.375, its centre is 12, and the square does not
    /// move.
    static func placement(lashes: Bool) -> CGRect {
        let side = tile.width * markShare
        let grid = CGRect(x: 0, y: 0, width: EyeLensGeometry.designSize, height: EyeLensGeometry.designSize)
        let lift = (grid.midY - inked(in: grid, lashes: lashes).midY) * side / EyeLensGeometry.designSize
        return CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2 + lift, width: side, height: side)
    }

    /// The box that the mark's strokes and fills cover when drawn into
    /// `rect`. This takes the lens's bounding box, adds the lashes' box when
    /// `lashes` is true, and grows it by half the line width on each side
    /// for the round caps. The pupil lies inside the lens and adds nothing.
    static func inked(in rect: CGRect, lashes: Bool) -> CGRect {
        let half = EyeLensGeometry.lineWidth(for: rect.width) / 2
        var box = EyeMarkGeometry.lens(in: rect).boundingBoxOfPath
        if lashes {
            box = box.union(EyeMarkGeometry.lashes(in: rect, side: .above).boundingBoxOfPath)
        }
        return box.insetBy(dx: -half, dy: -half)
    }

    /// The whole icon at `pixels` square. Returns nil if CoreGraphics cannot
    /// create a bitmap context of that size.
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

    /// Draws the icon into a context whose transform maps canvas units to
    /// device pixels. `scale` is device pixels per canvas unit, which sets
    /// the stroke floor, and `lashes` says whether to draw the five lashes.
    static func draw(in ctx: CGContext, scale: CGFloat, lashes: Bool) {
        let corner = tile.width * cornerShare
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil))
        ctx.setFillColor(BrandPalette.midnight.cgColor)
        ctx.fillPath()

        let square = lashes ? mark : markWithoutLashes
        let stroke = max(EyeLensGeometry.lineWidth(for: square.width), minimumStrokePixels / scale)
        ctx.setStrokeColor(BrandPalette.moonWhite.cgColor)
        ctx.setLineWidth(stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(EyeMarkGeometry.lens(in: square))
        ctx.strokePath()
        if lashes {
            ctx.addPath(EyeMarkGeometry.lashes(in: square, side: .above))
            ctx.strokePath()
        }
        ctx.setFillColor(BrandPalette.moonWhite.cgColor)
        ctx.addPath(EyeMarkGeometry.pupil(in: square))
        ctx.fillPath()
    }

    // MARK: - The README SVG

    /// The same drawing as an SVG document, 112 CSS pixels square. The
    /// viewBox is the tile alone, which drops the 100-unit canvas margin.
    /// The mark's paths come from the same geometry on the 24-unit grid,
    /// inside a transform that places the grid on the tile.
    static func svg() -> String {
        let grid = CGRect(x: 0, y: 0, width: EyeLensGeometry.designSize, height: EyeLensGeometry.designSize)
        let scale = mark.width / EyeLensGeometry.designSize
        let ink = hex(BrandPalette.moonWhite)
        let strokeAttributes = "fill=\"none\" stroke=\"\(ink)\" stroke-width=\"\(number(EyeLensGeometry.strokeUnits))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="112" height="112" viewBox="\(number(tile.minX)) \(number(tile.minY)) \(number(tile.width)) \(number(tile.height))" role="img" aria-labelledby="eo-title eo-desc">
          <title id="eo-title">Insomnia</title>
          <desc id="eo-desc">The Insomnia mark: an open almond-shaped eye with a round pupil and five lashes above the upper lid, drawn in moon-white on a charcoal rounded tile.</desc>
          <!-- scripts/generate-app-icon.sh writes this file from AppIconArtwork, and PackagingTests fails if the two differ, so edit the Swift drawing and rerun the script. The layout matches the app icon: an \(number(tile.width))-unit tile inset \(number(tileInset)) units in a \(number(canvas)) canvas, corners at \(number(cornerShare * 100))% of the tile, the 24-unit mark grid at \(number(markShare * 100))% of the tile side. -->
          <rect x="\(number(tile.minX))" y="\(number(tile.minY))" width="\(number(tile.width))" height="\(number(tile.height))" rx="\(number(tile.width * cornerShare))" fill="\(hex(BrandPalette.midnight))"/>
          <!-- EyeMarkGeometry at progress 1 on its 24-unit grid. The paths are the lens, closed by two cubic lids, then the pupil with the highlight cut as a notch from its upper right edge, then the five lashes above the upper lid. -->
          <g transform="translate(\(number(mark.minX)) \(number(mark.minY))) scale(\(number(scale)))">
            <path d="\(pathData(EyeMarkGeometry.lens(in: grid)))" \(strokeAttributes)/>
            <path d="\(pathData(EyeMarkGeometry.pupil(in: grid)))" fill="\(ink)"/>
            <path d="\(pathData(EyeMarkGeometry.lashes(in: grid, side: .above)))" \(strokeAttributes)/>
          </g>
        </svg>

        """
    }

    /// Converts a CGPath to SVG path data. CoreGraphics turns arcs into
    /// cubic curves when it adds them to a path, so the geometry's paths
    /// hold only moves, lines, cubics and closes.
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

    /// Formats a number to four decimals and drops trailing zeros, so two
    /// runs write identical SVG bytes and a coordinate reads 12.5, not
    /// 12.5000.
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
