import AppKit
import Foundation
import ImageIO
import XCTest
@testable import Insomnia

/// The checked-in icon artifacts and the bundle wiring that points at them.
/// These read the real files and decode them; nothing here greps sources.
final class PackagingTests: XCTestCase {
    fileprivate static var repoRoot: URL {
        // .../Tests/InsomniaTests/PackagingTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private var resources: URL { Self.repoRoot.appendingPathComponent("Resources", isDirectory: true) }

    func testInfoPlistNamesAnIconThatResolvesToAnIcnsInResources() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let name = try XCTUnwrap(plist["CFBundleIconFile"] as? String, "CFBundleIconFile missing")
        XCTAssertFalse(name.isEmpty)
        // Launch Services accepts the name with or without the extension.
        let file = name.hasSuffix(".icns") ? name : name + ".icns"
        let icns = resources.appendingPathComponent(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: icns.path), "\(icns.path) does not exist")
        let image = try XCTUnwrap(NSImage(contentsOf: icns), "AppKit cannot decode \(icns.path)")
        XCTAssertFalse(image.representations.isEmpty)
    }

    func testIcnsCarriesEveryMacIconSize() throws {
        let url = resources.appendingPathComponent("AppIcon.icns")
        let data = try Data(contentsOf: url)
        // ICNS container: "icns", total length, then (type, length, payload) entries.
        guard data.count >= 8 else {
            return XCTFail("\(url.lastPathComponent) is \(data.count) bytes, too short for an ICNS header")
        }
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "icns")
        XCTAssertEqual(Int(bigEndian32(data, at: 4)), data.count, "container length must match the file")
        var types: [String: Int] = [:]
        var cursor = 8
        while cursor + 8 <= data.count {
            let type = String(decoding: data[cursor..<cursor + 4], as: UTF8.self)
            let length = Int(bigEndian32(data, at: cursor + 4))
            // A short or oversized length would loop forever or slice past the end.
            guard length >= 8, length <= data.count - cursor else {
                return XCTFail("corrupt element \(type) at \(cursor): length \(length) of \(data.count - cursor) remaining")
            }
            XCTAssertGreaterThan(length, 8, "empty element \(type)")
            types[type] = length - 8
            cursor += length
        }
        XCTAssertEqual(cursor, data.count, "elements must tile the container exactly")
        // 16, 16@2x, 32, 32@2x, 128, 128@2x, 256, 256@2x, 512, 512@2x. The
        // 16 and 32 point members are stored as ic04/ic05 by current iconutil
        // and as icp4/icp5 by older ones; either satisfies Finder.
        let required: [[String]] = [["icp4", "ic04"], ["ic11"], ["icp5", "ic05"], ["ic12"], ["ic07"], ["ic13"], ["ic08"], ["ic14"], ["ic09"], ["ic10"]]
        for alternatives in required {
            XCTAssertTrue(alternatives.contains { types[$0] != nil }, "missing \(alternatives); have \(types.keys.sorted())")
        }
        // The 1024 element is a PNG, so Finder shows the vector-rendered art, not a scaled copy.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let ic10 = try XCTUnwrap(elementPayload(data, type: "ic10"))
        XCTAssertEqual(ic10.prefix(8), png)

        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let widths = Set(image.representations.map(\.pixelsWide))
        for w in [16, 32, 64, 128, 256, 512, 1024] {
            XCTAssertTrue(widths.contains(w), "no \(w)px representation; have \(widths.sorted())")
        }
    }

    func testMasterPngIsA1024TileWithTransparentMarginDarkTileAndLightMark() throws {
        let url = resources.appendingPathComponent("AppIcon-1024.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)

        let px = Pixels(image)
        // Corners are outside the rounded tile: fully transparent.
        for (x, y) in [(2, 2), (1021, 2), (2, 1021), (1021, 1021)] {
            XCTAssertEqual(px.alpha(x, y), 0, "corner (\(x), \(y)) must be transparent")
        }
        // Along the horizontal centre line: the charcoal tile edge is dark
        // and opaque, and somewhere inside it the mark is light.
        let mid = 512
        var dark = 0
        var light = 0
        for x in stride(from: 0, to: 1024, by: 2) {
            guard px.alpha(x, mid) > 0.99 else { continue }
            let l = px.luminance(x, mid)
            if l < 0.3 { dark += 1 }
            if l > 0.75 { light += 1 }
        }
        XCTAssertGreaterThan(dark, 200, "charcoal tile should dominate the centre line")
        XCTAssertGreaterThan(light, 4, "the eye should cross the centre line")
        XCTAssertGreaterThan(px.alpha(160, mid), 0.99, "the tile should start well inside the canvas")
        XCTAssertLessThan(px.luminance(160, mid), 0.3, "the tile edge is charcoal, not white")
        XCTAssertEqual(px.alpha(20, mid), 0, "a margin is left around the tile")
    }

    /// The checked-in files are what `AppIconArtwork` draws now, so a
    /// geometry change without `scripts/generate-app-icon.sh` fails here.
    func testMasterPngIsTheOpenEyeArtworkRenderedAt1024() throws {
        let url = resources.appendingPathComponent("AppIcon-1024.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let committed = IconPixels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let drawn = IconPixels(try XCTUnwrap(AppIconArtwork.render(pixels: 1024)))
        XCTAssertEqual(committed.width, drawn.width)
        XCTAssertEqual(committed.height, drawn.height)
        let differences = committed.differences(from: drawn, tolerance: 32)
        XCTAssertLessThan(differences, 1024 * 1024 / 1000, "AppIcon-1024.png differs from the artwork at \(differences) pixels; run scripts/generate-app-icon.sh")
    }

    func testIcnsMembersAreTheArtworkRenderedAtTheirOwnSizes() throws {
        let url = resources.appendingPathComponent("AppIcon.icns")
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        for pixels in [16, 32, 64, 128, 256, 512, 1024] {
            let rep = try XCTUnwrap(image.representations.first { $0.pixelsWide == pixels && $0.pixelsHigh == pixels }, "no \(pixels)px member")
            let ctx = try XCTUnwrap(CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            XCTAssertTrue(rep.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)), "\(pixels)px member does not draw")
            NSGraphicsContext.restoreGraphicsState()
            let member = IconPixels(try XCTUnwrap(ctx.makeImage()))
            let drawn = IconPixels(try XCTUnwrap(AppIconArtwork.render(pixels: pixels)))
            let differences = member.differences(from: drawn, tolerance: 32)
            XCTAssertLessThan(differences, max(pixels * pixels / 1000, 3), "the \(pixels)px member differs from the artwork at \(differences) pixels; run scripts/generate-app-icon.sh")
        }
    }

    func testReadmeSvgIsTheArtworkWrittenOut() throws {
        let url = Self.repoRoot.appendingPathComponent("docs/assets/eye-open.svg")
        let committed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(committed, AppIconArtwork.svg(), "docs/assets/eye-open.svg differs from the artwork; run scripts/generate-app-icon.sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repoRoot.appendingPathComponent("docs/assets/eye-moon.svg").path), "the old eye-and-moon SVG is gone")

        // What the README embeds: the tile, then the lens, pupil and lashes on the 24-unit grid, named for what they are.
        let grid = CGRect(x: 0, y: 0, width: EyeLensGeometry.designSize, height: EyeLensGeometry.designSize)
        XCTAssertTrue(committed.contains("<title id=\"eo-title\">Insomnia</title>"))
        XCTAssertTrue(committed.contains("<desc id=\"eo-desc\">The Insomnia mark: an open almond-shaped eye with a round pupil and five lashes above the upper lid"))
        XCTAssertFalse(committed.lowercased().contains("crescent"))
        XCTAssertTrue(committed.contains("<rect x=\"100\" y=\"100\" width=\"824\" height=\"824\" rx=\"184.3288\" fill=\"#303336\"/>"))
        XCTAssertTrue(committed.contains("d=\"\(AppIconArtwork.pathData(EyeMarkGeometry.lens(in: grid)))\" fill=\"none\" stroke=\"#E6E3DD\" stroke-width=\"1.5\""))
        XCTAssertTrue(committed.contains("d=\"\(AppIconArtwork.pathData(EyeMarkGeometry.pupil(in: grid)))\" fill=\"#E6E3DD\""))
        XCTAssertTrue(committed.contains("d=\"\(AppIconArtwork.pathData(EyeMarkGeometry.lashes(in: grid, side: .above)))\" fill=\"none\" stroke=\"#E6E3DD\""))
        XCTAssertFalse(committed.contains(AppIconArtwork.pathData(EyeMarkGeometry.lashes(in: grid, side: .below))), "no lower lashes: the eye is open")
        // The grid is placed where the icon places it.
        let mark = AppIconArtwork.mark
        let scale = AppIconArtwork.number(mark.width / EyeLensGeometry.designSize)
        XCTAssertTrue(committed.contains("transform=\"translate(\(AppIconArtwork.number(mark.minX)) \(AppIconArtwork.number(mark.minY))) scale(\(scale))\""))
        // Path data is moves, lines, cubics and closes with no empty segments.
        let pupil = AppIconArtwork.pathData(EyeMarkGeometry.pupil(in: grid))
        XCTAssertTrue(pupil.hasPrefix("M"))
        XCTAssertTrue(pupil.hasSuffix("Z"))
        XCTAssertFalse(pupil.contains("L"), "an arc's lead-in line to its own start is dropped")
        XCTAssertEqual(AppIconArtwork.number(184.32880), "184.3288")
        XCTAssertEqual(AppIconArtwork.number(12), "12")
        XCTAssertEqual(AppIconArtwork.number(-0.00001), "0")
    }

    // MARK: - Regeneration

    /// A patched copy of scripts/generate-app-icon.sh in a temporary tree,
    /// with fake swiftc and iconutil, replaces the PNG, ICNS and SVG
    /// together on success and leaves all three as they were when any step
    /// fails, without staged copies left beside them.
    func testRegenerationReplacesAllThreeAssetsOrNone() throws {
        let fixture = try IconScriptFixture()
        defer { fixture.remove() }

        // An unwritable docs/assets: the SVG cannot be staged, and the PNG
        // and ICNS, already staged in Resources, must not be swapped in.
        try fixture.setWritable(fixture.assets, false)
        let blocked = try fixture.run()
        try fixture.setWritable(fixture.assets, true)
        XCTAssertNotEqual(blocked.status, 0, "an unwritable docs/assets fails the run: \(blocked.stderr)")
        XCTAssertEqual(try fixture.contents(), ["old png", "old icns", "old svg"])
        XCTAssertEqual(try fixture.leftovers(), [])

        // iconutil fails: nothing is replaced.
        fixture.failIconutil(true)
        let noIcns = try fixture.run()
        fixture.failIconutil(false)
        XCTAssertNotEqual(noIcns.status, 0, "a failed iconutil fails the run")
        XCTAssertEqual(try fixture.contents(), ["old png", "old icns", "old svg"])
        XCTAssertEqual(try fixture.leftovers(), [])

        let ok = try fixture.run()
        XCTAssertEqual(ok.status, 0, ok.stderr)
        XCTAssertEqual(try fixture.contents(), ["new png", "new icns", "new svg"])
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    // MARK: - Helpers

    private func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func elementPayload(_ data: Data, type wanted: String) -> Data? {
        var cursor = 8
        while cursor + 8 <= data.count {
            let type = String(decoding: data[cursor..<cursor + 4], as: UTF8.self)
            let length = Int(bigEndian32(data, at: cursor + 4))
            guard length >= 8, length <= data.count - cursor else { return nil }
            if type == wanted { return data[(cursor + 8)..<(cursor + length)] }
            cursor += length
        }
        return nil
    }

    /// Straight RGBA at integer pixels, (0,0) top-left.
    private struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init(_ image: CGImage) {
            let w = image.width
            let h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(
                    data: buffer.baseAddress,
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            width = w
            height = h
            data = bytes
        }

        func alpha(_ x: Int, _ y: Int) -> Double {
            Double(data[(y * width + x) * 4 + 3]) / 255
        }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let o = (y * width + x) * 4
            let a = max(Double(data[o + 3]), 1)
            let r = Double(data[o]) / a, g = Double(data[o + 1]) / a, b = Double(data[o + 2]) / a
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
    }
}

/// A throwaway tree for scripts/generate-app-icon.sh:
///   root/scripts/generate-app-icon.sh   copy with SWIFTC and ICONUTIL patched to the fakes
///   root/Resources, root/docs/assets    the three assets, holding "old ..."
///   root/bin                            fake swiftc and iconutil
///   root/tmp                            TMPDIR for the script's mktemp
/// The fake swiftc writes a fake generator that writes "new png", one
/// iconset member, and "new svg" through a file beside the target the way
/// the real generator's atomic String write does; the fake iconutil writes
/// "new icns", or fails while root/iconutil-fails exists.
private struct IconScriptFixture {
    let root: URL
    var script: URL { root.appendingPathComponent("scripts/generate-app-icon.sh") }
    var resources: URL { root.appendingPathComponent("Resources", isDirectory: true) }
    var assets: URL { root.appendingPathComponent("docs/assets", isDirectory: true) }
    private var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    private var assetFiles: [URL] {
        [resources.appendingPathComponent("AppIcon-1024.png"), resources.appendingPathComponent("AppIcon.icns"), assets.appendingPathComponent("eye-open.svg")]
    }
    private let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-script-\(UUID().uuidString)", isDirectory: true)
        for dir in ["scripts", "Resources", "docs/assets", "bin", "tmp"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }
        for (file, text) in zip(assetFiles, ["old png", "old icns", "old svg"]) {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let source = PackagingTests.repoRoot.appendingPathComponent("scripts/generate-app-icon.sh")
        var text = try String(contentsOf: source, encoding: .utf8)
        for (name, fake) in [("SWIFTC", "swiftc"), ("ICONUTIL", "iconutil")] {
            let line = "\(name)=/usr/bin/\(fake)"
            guard text.components(separatedBy: "\n").filter({ $0 == line }).count == 1 else {
                throw NSError(domain: "IconScriptFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected one '\(line)' line"])
            }
            text = text.replacingOccurrences(of: line, with: "\(name)='\(bin.appendingPathComponent(fake).path)'")
        }
        try text.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        try writeFake("swiftc", #"""
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-o" ]; then out="$2"; shift; fi
          shift
        done
        cat > "$out" <<'GENERATOR'
        #!/bin/bash
        set -e
        while [ $# -gt 0 ]; do
          case "$1" in
            --png) printf 'new png' > "$2" ;;
            --iconset) mkdir -p "$2"; printf 'member' > "$2/icon_16x16.png" ;;
            --svg) printf 'new svg' > "$2.tmp.$$" || exit 1; mv -f "$2.tmp.$$" "$2" ;;
            *) exit 2 ;;
          esac
          shift 2
        done
        GENERATOR
        chmod +x "$out"
        """#)
        try writeFake("iconutil", """
        [ -e '\(root.appendingPathComponent("iconutil-fails").path)' ] && exit 1
        [ "$1" = -c ] && [ "$2" = icns ] && [ -d "$3" ] && [ "$4" = -o ] || exit 2
        printf 'new icns' > "$5"
        """)
    }

    private func writeFake(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func setWritable(_ dir: URL, _ writable: Bool) throws {
        try fm.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: dir.path)
    }

    func failIconutil(_ fail: Bool) {
        let flag = root.appendingPathComponent("iconutil-fails")
        if fail { fm.createFile(atPath: flag.path, contents: Data()) } else { try? fm.removeItem(at: flag) }
    }

    /// The PNG, ICNS and SVG, in that order.
    func contents() throws -> [String] {
        try assetFiles.map { try String(contentsOf: $0, encoding: .utf8) }
    }

    /// Anything in the two asset folders besides the three assets.
    func leftovers() throws -> [String] {
        let names = Set(assetFiles.map(\.lastPathComponent))
        return try [resources, assets].flatMap { try fm.contentsOfDirectory(atPath: $0.path) }.filter { !names.contains($0) }.sorted()
    }

    func run() throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.appendingPathComponent("tmp").path]
        p.currentDirectoryURL = root
        let errURL = root.appendingPathComponent("stderr.\(UUID().uuidString)")
        fm.createFile(atPath: errURL.path, contents: nil)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? err.close() }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        return (p.terminationStatus, (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    func remove() {
        try? setWritable(assets, true)
        try? fm.removeItem(at: root)
    }
}
