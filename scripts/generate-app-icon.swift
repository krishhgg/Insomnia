import CoreGraphics
import Foundation
import ImageIO

/// Writes the Insomnia app icon files from the drawing the app carries.
/// Not part of the SwiftPM targets: scripts/generate-app-icon.sh compiles
/// this file together with Sources/Insomnia/UI/AppIconArtwork.swift, the
/// geometry it draws (EyeLensGeometry.swift, EyeMarkGeometry.swift) and
/// BrandPalette.swift, so there is one drawing and no pixel art to keep in
/// step.
///
///   generate-app-icon --png PATH --iconset DIR --svg PATH
///
/// Writes the 1024x1024 master PNG to the PNG path, every size `iconutil`
/// needs into DIR (an .iconset folder), each rendered straight from the
/// vector geometry at its own pixel size rather than downscaled, and the
/// README's SVG of the same mark to the SVG path. Output depends only on
/// the sources, so re-running it reproduces the checked-in bytes.
@main
struct GenerateAppIcon {
    /// File name and pixel size of each iconset member.
    static let iconset: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    static let usage = "usage: generate-app-icon --png PATH --iconset DIR --svg PATH"

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var png: String?
        var iconsetDir: String?
        var svg: String?
        while !args.isEmpty {
            let flag = args.removeFirst()
            switch (flag, args.first) {
            case ("--png", .some(let value)):
                png = value
                args.removeFirst()
            case ("--iconset", .some(let value)):
                iconsetDir = value
                args.removeFirst()
            case ("--svg", .some(let value)):
                svg = value
                args.removeFirst()
            default:
                throw Failure(description: usage)
            }
        }
        guard let png, let iconsetDir, let svg else {
            throw Failure(description: usage)
        }

        try write(render(pixels: Int(AppIconArtwork.canvas)), to: URL(fileURLWithPath: png))
        let dir = URL(fileURLWithPath: iconsetDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for member in iconset {
            try write(render(pixels: member.pixels), to: dir.appendingPathComponent("\(member.name).png"))
        }
        try AppIconArtwork.svg().write(to: URL(fileURLWithPath: svg), atomically: true, encoding: .utf8)
    }

    static func render(pixels: Int) throws -> CGImage {
        guard let image = AppIconArtwork.render(pixels: pixels) else {
            throw Failure(description: "could not rasterise the \(pixels)px icon")
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw Failure(description: "could not open \(url.path) for writing")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "could not write \(url.path)")
        }
    }
}
