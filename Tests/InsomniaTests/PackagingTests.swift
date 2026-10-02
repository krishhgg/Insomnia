import AppKit
import Foundation
import ImageIO
import XCTest

/// The checked-in icon artifacts and the bundle wiring that points at them.
/// These read the real files and decode them; nothing here greps sources.
final class PackagingTests: XCTestCase {
    private static var repoRoot: URL {
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
        XCTAssertGreaterThan(light, 4, "the eye/moon should cross the centre line")
        XCTAssertGreaterThan(px.alpha(160, mid), 0.99, "the tile should start well inside the canvas")
        XCTAssertLessThan(px.luminance(160, mid), 0.3, "the tile edge is charcoal, not white")
        XCTAssertEqual(px.alpha(20, mid), 0, "a margin is left around the tile")
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
