import AppKit
import Foundation
import ImageIO
import XCTest
@testable import Insomnia

/// The checked-in icon artifacts and the bundle wiring that points at them,
/// and the recovery agent's verify-then-exec command line run against a
/// scratch signed bundle with the real codesign. These read the real files
/// and decode them; nothing here greps sources.
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

    // MARK: - The recovery agent's command line (real codesign, scratch bundle)

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-packaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A throwaway bundle laid out the way install.sh lays out Insomnia.app
    /// (Mach-O main executable, Info.plist, backstop.sh under
    /// Contents/Resources), ad-hoc signed afterwards so the resource seal
    /// covers the script. The executable is a copy of /usr/bin/true. Nothing
    /// here touches an installed app, a LaunchAgent or a keychain.
    private func makeSignedBundle(named name: String = "Insomnia") throws -> URL {
        let fm = FileManager.default
        let bundle = scratch.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: bundle.appendingPathComponent("Contents/MacOS/\(name)").path)
        let info: [String: Any] = [
            "CFBundleExecutable": name, "CFBundleIdentifier": "com.kgarg.insomnia.packaging-test",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.1",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let script = Paths.backstopScript(inBundle: bundle)
        try "#!/bin/bash\nprintf 'ran %s\\n' \"$*\" >> \"$HOME/backstop.ran\"\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let sign = try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        XCTAssertEqual(sign.status, 0, sign.output)
        return bundle
    }

    /// Runs the agent's command line exactly as launchd would, with HOME in
    /// the scratch tree so the refusal log lands there.
    private func runAgent(requirement: String, bundle: URL, home: URL) throws -> (status: Int32, output: String) {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return try run("/bin/sh", ["-c", LaunchdBackstop.agentProgram, "sh", requirement, bundle.path], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    }

    private func run(_ exe: String, _ args: [String], environment: [String: String]? = nil, currentDirectory: URL? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let environment { p.environment = environment }
        if let currentDirectory { p.currentDirectoryURL = currentDirectory }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// What install.sh reads: the `designated =>` line of `codesign -d -r-`,
    /// without the "# " an implicit requirement carries.
    private func codesignDesignatedRequirement(of path: String) throws -> String {
        let r = try run("/usr/bin/codesign", ["-d", "-r-", path])
        let line = try XCTUnwrap(r.output.components(separatedBy: "\n").first { $0.contains("designated => ") }, r.output)
        return String(line[line.range(of: "designated => ")!.upperBound...])
    }

    /// The app reads the requirement through the Security framework and
    /// install.sh through codesign; the plist only matches when both print
    /// the same text. Checked on Apple-signed code and on an ad-hoc bundle.
    func testDesignatedRequirementMatchesWhatCodesignPrints() throws {
        XCTAssertEqual(try CodeRequirement.designated(ofCodeAt: URL(fileURLWithPath: "/bin/ls")), try codesignDesignatedRequirement(of: "/bin/ls"))
        let bundle = try makeSignedBundle()
        let fromSecurity = try CodeRequirement.designated(ofCodeAt: bundle)
        XCTAssertEqual(fromSecurity, try codesignDesignatedRequirement(of: bundle.path))
        XCTAssertTrue(fromSecurity.hasPrefix("cdhash H\""), "an ad-hoc signature is pinned by cdhash: \(fromSecurity)")
        XCTAssertFalse(fromSecurity.contains("'"), "install.sh and the plist must hold it without quoting trouble")
    }

    func testUnsignedCodeHasNoRequirementToPin() {
        let unsigned = scratch.appendingPathComponent("plain.sh")
        try? "#!/bin/bash\n".write(to: unsigned, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CodeRequirement.designated(ofCodeAt: unsigned)) { error in
            XCTAssertTrue(error.localizedDescription.contains(unsigned.path), error.localizedDescription)
        }
    }

    /// The command line the LaunchAgent runs: an intact bundle runs its
    /// sealed backstop.sh; a bundle whose sealed script was edited, or one
    /// that is not the build the plist pins, runs nothing and logs why.
    func testAgentProgramRunsTheSealedBackstopOnlyWhileTheBundleSatisfiesItsRequirement() throws {
        let bundle = try makeSignedBundle()
        let requirement = try CodeRequirement.designated(ofCodeAt: bundle)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let ran = home.appendingPathComponent("backstop.ran")
        let log = home.appendingPathComponent("Library/Logs/Insomnia/insomnia.log")

        let intact = try runAgent(requirement: requirement, bundle: bundle, home: home)
        XCTAssertEqual(intact.status, 0, intact.output)
        XCTAssertEqual(try String(contentsOf: ran, encoding: .utf8), "ran \n", "the sealed script ran, with no arguments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "nothing to log while the bundle verifies")

        try FileManager.default.removeItem(at: ran)
        let script = Paths.backstopScript(inBundle: bundle)
        try (String(contentsOf: script, encoding: .utf8) + "echo tampered\n").write(to: script, atomically: true, encoding: .utf8)
        let edited = try runAgent(requirement: requirement, bundle: bundle, home: home)
        XCTAssertEqual(edited.status, 1, edited.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path), "an edited sealed script must not run")
        var logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains("[error] backstop agent: \(bundle.path) does not satisfy the pinned code requirement"), logged)
        XCTAssertTrue(logged.contains("sealed resource"), "codesign's reason is kept: \(logged)")
        XCTAssertEqual(logged.components(separatedBy: "\n").count, 2, "one line per refusal: \(logged)")

        // Another build: a fresh, intact bundle that the pinned requirement
        // (the first bundle's cdhash) does not describe.
        let other = try makeSignedBundle(named: "Other")
        XCTAssertNotEqual(try CodeRequirement.designated(ofCodeAt: other), requirement)
        let wrongBuild = try runAgent(requirement: requirement, bundle: other, home: home)
        XCTAssertEqual(wrongBuild.status, 1, wrongBuild.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path))
        logged = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logged.contains("\(other.path) does not satisfy"), logged)
        XCTAssertTrue(logged.contains("failed to satisfy specified code requirement"), logged)

        // Its own requirement still runs it.
        let own = try runAgent(requirement: try CodeRequirement.designated(ofCodeAt: other), bundle: other, home: home)
        XCTAssertEqual(own.status, 0, own.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ran.path))
    }

    // MARK: - What arm() pins (CodeRequirement.pin, real codesign)

    /// Reading a requirement does not validate the bundle: a sealed script
    /// edited after signing still reads its old requirement, and an agent
    /// pinned to it refuses every run. pin() runs the agent's check as well
    /// and refuses the bundle, so arm() fails with the reason.
    func testPinRefusesABundleWhoseSealedScriptWasEditedAfterSigning() throws {
        let bundle = try makeSignedBundle()
        let requirement = try CodeRequirement.designated(ofCodeAt: bundle)
        // The test host is not an app bundle, so pin() takes the development
        // path: the requirement comes from the bundle on disk.
        XCTAssertEqual(try CodeRequirement.pin(bundle: bundle), requirement)

        let script = Paths.backstopScript(inBundle: bundle)
        try (String(contentsOf: script, encoding: .utf8) + "echo tampered\n").write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(try CodeRequirement.designated(ofCodeAt: bundle), requirement, "the requirement alone still reads")
        XCTAssertThrowsError(try CodeRequirement.verify(codeAt: bundle, satisfies: requirement)) { error in
            XCTAssertTrue(error.localizedDescription.contains("sealed resource"), error.localizedDescription)
        }
        XCTAssertThrowsError(try CodeRequirement.pin(bundle: bundle)) { error in
            XCTAssertTrue(error.localizedDescription.contains(bundle.path), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("sealed resource"), error.localizedDescription)
        }
    }

    /// The installed app pins the code it is running, not what is on disk.
    /// A same-user process can replace the sealed script and re-sign the
    /// bundle ad hoc under the running app; the bundle then carries a new
    /// requirement, and pin() refuses it instead of publishing it.
    func testPinOfTheRunningAppRefusesABundleReSignedSinceLaunch() throws {
        let bundle = try makeSignedBundle()
        let launched = CodeRequirement.RunningCode(path: bundle, requirement: try CodeRequirement.designated(ofCodeAt: bundle))
        XCTAssertEqual(try CodeRequirement.pin(bundle: bundle, running: { launched }, mainBundle: bundle), launched.requirement)

        let script = Paths.backstopScript(inBundle: bundle)
        try (String(contentsOf: script, encoding: .utf8) + "echo tampered\n").write(to: script, atomically: true, encoding: .utf8)
        let reSign = try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        XCTAssertEqual(reSign.status, 0, reSign.output)
        let replacement = try CodeRequirement.designated(ofCodeAt: bundle)
        XCTAssertNotEqual(replacement, launched.requirement, "re-signing gives the bundle a new cdhash")
        XCTAssertNoThrow(try CodeRequirement.verify(codeAt: bundle, satisfies: replacement), "the replacement is a valid bundle in its own right")
        XCTAssertThrowsError(try CodeRequirement.pin(bundle: bundle, running: { launched }, mainBundle: bundle)) { error in
            XCTAssertTrue(error.localizedDescription.contains("failed to satisfy"), error.localizedDescription)
        }

        // A process running from one bundle never pins another.
        let other = try makeSignedBundle(named: "Other")
        XCTAssertThrowsError(try CodeRequirement.pin(bundle: other, running: { launched }, mainBundle: other)) { error in
            XCTAssertTrue(error.localizedDescription.contains("runs from \(bundle.path)"), error.localizedDescription)
        }
    }

    /// CodeRequirement.running() is the kernel's view of this process; the
    /// bundle re-signed under a running app fails its SecCodeCheckValidity,
    /// which the test host cannot stage against itself. What it can check:
    /// the reading is consistent (the code at the reported path satisfies
    /// the reported requirement) and the host is not an app bundle, so the
    /// default pin() in these tests reads bundles from disk.
    func testRunningCodeSatisfiesItsOwnRequirement() throws {
        let me = try CodeRequirement.running()
        XCTAssertTrue(FileManager.default.fileExists(atPath: me.path.path), me.path.path)
        XCTAssertFalse(me.requirement.isEmpty)
        XCTAssertNoThrow(try CodeRequirement.verify(codeAt: me.path, satisfies: me.requirement))
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app")
    }

    // MARK: - scripts/build-app.sh (patched copy: fake swift, real or recording codesign)

    /// A private copy of build-app.sh whose `swift` is a fake that reports a
    /// prepared binary directory (a copy of /usr/bin/true, so the real
    /// codesign can sign the result) and whose `codesign` is either the real
    /// tool or a recorder. ROOT is a scratch checkout with the real
    /// Info.plist, icon and backstop.sh copied in.
    private func patchedBuildApp(recordingCodesign: Bool) throws -> (script: URL, calls: URL) {
        let fm = FileManager.default
        let checkout = scratch.appendingPathComponent("checkout", isDirectory: true)
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        let binroot = scratch.appendingPathComponent("binroot", isDirectory: true)
        let calls = scratch.appendingPathComponent("calls.log")
        for dir in [checkout.appendingPathComponent("scripts"), checkout.appendingPathComponent("Resources"), bin, binroot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for name in ["Info.plist", "AppIcon.icns"] {
            try fm.copyItem(at: Self.repoRoot.appendingPathComponent("Resources/\(name)"), to: checkout.appendingPathComponent("Resources/\(name)"))
        }
        try fm.copyItem(at: Self.repoRoot.appendingPathComponent("scripts/backstop.sh"), to: checkout.appendingPathComponent("scripts/backstop.sh"))
        try fm.copyItem(atPath: "/usr/bin/true", toPath: binroot.appendingPathComponent("Insomnia").path)

        func fake(_ name: String, _ body: String) throws -> URL {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let swift = try fake("swift", """
        printf 'swift %s\\n' "$*" >> "\(calls.path)"
        for a in "$@"; do [[ "$a" == --show-bin-path ]] && { echo "\(binroot.path)"; exit 0; }; done
        exit 0
        """)
        let codesign = recordingCodesign
            ? try fake("codesign", """
              printf 'codesign %s\\n' "$*" >> "\(calls.path)"
              exit 0
              """)
            : URL(fileURLWithPath: "/usr/bin/codesign")

        var lines = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8).components(separatedBy: "\n")
        for (name, value) in ["SWIFT": swift.path, "CODESIGN": codesign.path] {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            XCTAssertEqual(hits.count, 1, "build-app.sh must have exactly one \(name)= line")
            lines[hits[0]] = "\(name)='\(value)'"
        }
        let script = checkout.appendingPathComponent("scripts/build-app.sh")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, calls)
    }

    /// Ad-hoc by default: the output is a complete bundle (binary,
    /// Info.plist, icon, backstop.sh) whose real signature verifies, whose
    /// resource seal covers the backstop, and whose designated requirement
    /// is the build's cdhash, the pin install.sh's agent uses.
    func testBuildAppAssemblesAndAdHocSignsABundleWhoseSealCoversTheBackstop() throws {
        let (script, _) = try patchedBuildApp(recordingCodesign: false)
        let out = scratch.appendingPathComponent("out", isDirectory: true)

        let r = try run("/bin/bash", [script.path, "--output", out.path], environment: ["PATH": "/usr/bin:/bin", "HOME": scratch.path])

        XCTAssertEqual(r.status, 0, r.output)
        let bundle = out.appendingPathComponent("Insomnia.app")
        XCTAssertEqual(r.output.components(separatedBy: "\n").filter { !$0.isEmpty }.last, bundle.path, "the bundle path is printed last")
        for rel in ["Contents/MacOS/Insomnia", "Contents/Info.plist", "Contents/Resources/AppIcon.icns", "Contents/Resources/backstop.sh", "Contents/_CodeSignature/CodeResources"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(rel).path), rel)
        }
        let perms = try FileManager.default.attributesOfItem(atPath: Paths.backstopScript(inBundle: bundle).path)[.posixPermissions] as? Int
        XCTAssertEqual(perms.map { $0 & 0o111 }, 0o111, "backstop.sh is executable")
        XCTAssertEqual(try run("/usr/bin/codesign", ["--verify", "--strict", bundle.path]).status, 0)
        XCTAssertTrue(r.output.contains("Signature=adhoc"), r.output)
        XCTAssertTrue(try CodeRequirement.designated(ofCodeAt: bundle).hasPrefix("cdhash H\""))

        let script2 = Paths.backstopScript(inBundle: bundle)
        try (String(contentsOf: script2, encoding: .utf8) + "# edited\n").write(to: script2, atomically: true, encoding: .utf8)
        let edited = try run("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        XCTAssertNotEqual(edited.status, 0, "an edited backstop.sh breaks the seal: \(edited.output)")
    }

    func testBuildAppReplacesABundleAlreadyInTheOutputDirectory() throws {
        let (script, _) = try patchedBuildApp(recordingCodesign: false)
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        let stale = out.appendingPathComponent("Insomnia.app/Contents/Resources/stale.txt")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "old".write(to: stale, atomically: true, encoding: .utf8)

        let r = try run("/bin/bash", [script.path, "--output", out.path], environment: ["PATH": "/usr/bin:/bin", "HOME": scratch.path])

        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "the previous bundle is replaced, not merged")
    }

    /// `--output` is resolved before the build changes into the checkout, so
    /// a relative path means relative to the caller: release.yml runs the
    /// script from the repository root, but a caller elsewhere gets its own
    /// `dist`, not one inside the checkout.
    func testBuildAppResolvesARelativeOutputAgainstTheCallersDirectory() throws {
        let (script, _) = try patchedBuildApp(recordingCodesign: true)
        let caller = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: caller, withIntermediateDirectories: true)

        let r = try run("/bin/bash", [script.path, "--output", "dist"], environment: ["PATH": "/usr/bin:/bin", "HOME": scratch.path], currentDirectory: caller)

        XCTAssertEqual(r.status, 0, r.output)
        let bundle = caller.appendingPathComponent("dist/Insomnia.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path), "written under the caller's directory: \(r.output)")
        let checkout = script.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("dist").path), "nothing written into the checkout")
        let printed = try XCTUnwrap(r.output.components(separatedBy: "\n").filter { !$0.isEmpty }.last)
        XCTAssertEqual(URL(fileURLWithPath: printed).resolvingSymlinksInPath(), bundle.resolvingSymlinksInPath(), "the printed path is absolute")
    }

    /// The signing command depends only on INSOMNIA_SIGN_IDENTITY: ad-hoc
    /// without it, Developer ID with the hardened runtime and a timestamp
    /// with it. Neither uses --deep (no nested code). Checked with a
    /// recording codesign so no identity is needed.
    func testBuildAppSignsAdHocWithoutAnIdentityAndWithHardenedRuntimeAndTimestampWithOne() throws {
        let (script, calls) = try patchedBuildApp(recordingCodesign: true)
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        let bundle = out.appendingPathComponent("Insomnia.app").path

        let adhoc = try run("/bin/bash", [script.path, "--output", out.path], environment: ["PATH": "/usr/bin:/bin", "HOME": scratch.path])
        XCTAssertEqual(adhoc.status, 0, adhoc.output)
        var recorded = try String(contentsOf: calls, encoding: .utf8).components(separatedBy: "\n").filter { $0.hasPrefix("codesign") }
        XCTAssertEqual(recorded, [
            "codesign --force --sign - \(bundle)",
            "codesign --verify --strict \(bundle)",
            "codesign -dvv \(bundle)",
        ])

        try FileManager.default.removeItem(at: calls)
        let signed = try run("/bin/bash", [script.path, "--output", out.path],
                             environment: ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "INSOMNIA_SIGN_IDENTITY": "Developer ID Application: Example (ABCDE12345)"])
        XCTAssertEqual(signed.status, 0, signed.output)
        recorded = try String(contentsOf: calls, encoding: .utf8).components(separatedBy: "\n").filter { $0.hasPrefix("codesign") }
        XCTAssertEqual(recorded, [
            "codesign --force --sign Developer ID Application: Example (ABCDE12345) --options runtime --timestamp \(bundle)",
            "codesign --verify --strict \(bundle)",
            "codesign -dvv \(bundle)",
        ])
        XCTAssertTrue(signed.output.contains("Signing with \"Developer ID Application: Example (ABCDE12345)\""), signed.output)
    }

    func testBuildAppNeedsAnOutputDirectory() throws {
        let (script, calls) = try patchedBuildApp(recordingCodesign: true)
        for args in [[String](), ["--output"], ["--bogus", "x"]] {
            let r = try run("/bin/bash", [script.path] + args, environment: ["PATH": "/usr/bin:/bin", "HOME": scratch.path])
            XCTAssertEqual(r.status, 2, "\(args): \(r.output)")
            XCTAssertTrue(r.output.contains("usage:"), r.output)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "nothing was built or signed")
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
