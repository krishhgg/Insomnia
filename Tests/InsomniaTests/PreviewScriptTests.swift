import Foundation
import XCTest
@testable import Insomnia

/// The preview builder runs only against a private checkout with stubbed
/// compiler, signer and launcher. PlistBuddy edits the fixture bundle only.
final class PreviewScriptTests: XCTestCase {
    func testBuildsASeparateBundleAndForwardsPreviewArguments() async throws {
        let fixture = try Fixture(failingBuild: false)
        defer { fixture.remove() }
        let result = try await Shell.run("/bin/bash", [fixture.script.path, "--ui-preview-menu"])
        XCTAssertEqual(result.status, 0, result.stderr)
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: fixture.app.appendingPathComponent("Contents/Info.plist")),
            format: nil
        ) as? [String: Any]
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, "com.kgarg.insomnia.preview")
        XCTAssertEqual(plist?["CFBundleDisplayName"] as? String, "Insomnia Preview")
        XCTAssertEqual(plist?["LSUIElement"] as? Bool, false)
        let binary = try String(contentsOf: fixture.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8)
        XCTAssertEqual(binary, "fixture binary")
        let calls = try String(contentsOf: fixture.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("codesign\n--force\n--sign\n-\n\(fixture.app.path)"), calls)
        XCTAssertTrue(calls.contains("open\n\(fixture.app.path)\n--args\n--ui-preview\n--ui-preview-menu"), calls)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".build/Insomnia.app").path))
    }

    func testFailedBuildDoesNotCreateSignOrLaunchThePreview() async throws {
        let fixture = try Fixture(failingBuild: true)
        defer { fixture.remove() }
        let result = try await Shell.run("/bin/bash", [fixture.script.path])
        XCTAssertEqual(result.status, 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path))
        let calls = try String(contentsOf: fixture.calls, encoding: .utf8)
        XCTAssertFalse(calls.contains("codesign"), calls)
        XCTAssertFalse(calls.contains("open"), calls)
    }

    private struct Fixture {
        let root: URL
        var script: URL { root.appendingPathComponent("scripts/preview-app.sh") }
        var calls: URL { root.appendingPathComponent("calls.txt") }
        var app: URL { root.appendingPathComponent(".build/preview/Insomnia Preview.app") }

        init(failingBuild: Bool) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("insomnia preview test \(UUID().uuidString)")
            for name in ["scripts", "Resources", "bin", ".build/mock"] {
                try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let repo = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            var source = try String(contentsOf: repo.appendingPathComponent("scripts/preview-app.sh"), encoding: .utf8)
            for tool in ["SWIFT", "CODESIGN", "OPEN"] {
                let stub = root.appendingPathComponent("bin/\(tool.lowercased())")
                var body = "#!/bin/bash\nprintf '%s\\n' '\(tool.lowercased())' \"$@\" >> '\(calls.path)'\n"
                if tool == "SWIFT" {
                    body += failingBuild ? "exit 9\n" : "for arg in \"$@\"; do if [[ $arg == --show-bin-path ]]; then printf '%s\\n' '\(root.path)/.build/mock'; fi; done\n"
                }
                body += "exit 0\n"
                try body.write(to: stub, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
                let lines = source.components(separatedBy: "\n")
                XCTAssertEqual(lines.filter { $0.hasPrefix("\(tool)=") }.count, 1)
                source = lines.map { $0.hasPrefix("\(tool)=") ? "\(tool)='\(stub.path)'" : $0 }.joined(separator: "\n")
            }
            try source.write(to: script, atomically: true, encoding: .utf8)
            try "fixture binary".write(to: root.appendingPathComponent(".build/mock/Insomnia"), atomically: true, encoding: .utf8)
            let info: [String: Any] = ["CFBundleIdentifier": "com.kgarg.insomnia", "CFBundleName": "Insomnia", "CFBundleDisplayName": "Insomnia", "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Resources/Info.plist"))
            try Data([0, 1, 2]).write(to: root.appendingPathComponent("Resources/AppIcon.icns"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
