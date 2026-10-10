import Foundation
import XCTest

/// Static checks on .github/workflows/*.yml: every action is pinned to a
/// commit SHA with its version alongside, and no job runs with the default
/// token permissions. release.yml gets a few more: its triggers, that a
/// manual run never publishes, and that only the publishing job can write.
/// Plain text checks; the files are small and have no YAML anchors.
final class ReleaseWorkflowTests: XCTestCase {
    private var workflowsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/workflows", isDirectory: true)
    }

    private func workflows() throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: workflowsDir.path).filter { $0.hasSuffix(".yml") }.sorted()
        XCTAssertTrue(names.contains("release.yml"), "\(names)")
        return try names.map { ($0, try String(contentsOf: workflowsDir.appendingPathComponent($0), encoding: .utf8)) }
    }

    private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

    func testEveryActionIsPinnedToACommitSHAWithItsVersionNoted() throws {
        let pinned = try NSRegularExpression(pattern: #"^\s*-?\s*uses:\s*[\w.-]+/[\w./-]+@[0-9a-f]{40}\s+#\s*v\d+(\.\d+)*\s*$"#)
        for (name, text) in try workflows() {
            let uses = lines(text).filter { $0.range(of: #"^\s*-?\s*uses:"#, options: .regularExpression) != nil }
            XCTAssertFalse(uses.isEmpty, "\(name) uses no actions?")
            for line in uses {
                XCTAssertNotNil(pinned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                                "\(name): not pinned to a full commit SHA with a version comment: \(line)")
            }
        }
    }

    /// A top-level `permissions:` block in every workflow, so no job inherits
    /// the default token scopes. A job may rely on it only when it grants
    /// nothing beyond `contents: read`; otherwise every job declares its own.
    func testEveryJobDeclaresItsOwnPermissions() throws {
        for (name, text) in try workflows() {
            let ls = lines(text)
            let top = try XCTUnwrap(ls.firstIndex { $0.hasPrefix("permissions:") }, "\(name): no top-level permissions")
            var topScopes: [String] = []
            if ls[top] != "permissions: {}" {
                for line in ls[(top + 1)...] {
                    guard line.hasPrefix("  "), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                    topScopes.append(line.trimmingCharacters(in: .whitespaces))
                }
            }
            let readOnlyTop = topScopes.isEmpty || topScopes == ["contents: read"]
            XCTAssertTrue(readOnlyTop, "\(name): top-level permissions grant more than contents: read: \(topScopes)")
            let jobsIndex = try XCTUnwrap(ls.firstIndex(of: "jobs:"), "\(name): no jobs")
            var jobs: [(id: String, body: [String])] = []
            for line in ls[(jobsIndex + 1)...] {
                if line.range(of: #"^  [A-Za-z_][\w-]*:\s*$"#, options: .regularExpression) != nil {
                    jobs.append((line.trimmingCharacters(in: .whitespaces).dropLast().description, []))
                } else if !jobs.isEmpty {
                    jobs[jobs.count - 1].body.append(line)
                }
            }
            XCTAssertFalse(jobs.isEmpty, name)
            for job in jobs where !(topScopes == ["contents: read"]) {
                XCTAssertTrue(job.body.contains { $0.hasPrefix("    permissions:") }, "\(name): job \(job.id) declares no permissions and the top level grants none")
            }
        }
    }

    func testReleaseWorkflowRunsOnVersionTagsAndManuallyButOnlyTagsPublish() throws {
        let text = try XCTUnwrap(try workflows().first { $0.name == "release.yml" }).text
        XCTAssertTrue(text.contains("tags: ['v*']") || text.contains("tags: [\"v*\"]"), "runs on v* tags")
        XCTAssertTrue(text.contains("workflow_dispatch:"), "can be run by hand")
        XCTAssertFalse(text.contains("pull_request"), "never runs for pull requests")
        XCTAssertTrue(text.contains("if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"), "publishing is gated on a pushed tag, not on a manual run that happens to use a tag ref")
        XCTAssertTrue(text.contains("--signer-workflow $GITHUB_REPOSITORY/.github/workflows/release.yml --source-ref $GITHUB_REF"), "the notes pin the verify command to this workflow and the tag")
        XCTAssertTrue(text.contains(#"echo "./install.sh --allow-unverified-origin --app ./Insomnia.app""#), "the notes' install command carries the origin opt-in install.sh needs for an ad-hoc bundle")
        XCTAssertTrue(text.contains("permissions: {}"), "nothing at the top level")
        XCTAssertTrue(text.contains("--prerelease"), "ad-hoc releases are marked prerelease")
        XCTAssertTrue(text.contains("attest-build-provenance"), "build provenance is attested")
        XCTAssertTrue(text.contains("shasum -a 256"), "a checksum file is produced")
        XCTAssertTrue(text.contains("ditto -c -k --sequesterRsrc --keepParent"), "zipped the way Finder expects")
        XCTAssertTrue(text.contains("CFBundleShortVersionString"), "the tag is checked against the bundle version")
        XCTAssertTrue(text.contains("scripts/build-app.sh --output"), "built with the same script as install.sh")
        XCTAssertFalse(text.contains("--allow-unsigned"), "no Gatekeeper workarounds")
    }

    /// Releases are ad-hoc signed and not notarized: the workflow reads no
    /// secret, imports no certificate, notarizes nothing, build-app.sh has
    /// no Developer ID path (no signing identity from the environment, no
    /// hardened runtime, no timestamp), and install.sh has no Developer ID
    /// origin check (no Gatekeeper assessment, no expected team) that could
    /// let a bundle skip --allow-unverified-origin. RecoveryScriptTests'
    /// testInstallFromPrebuiltAppNeedsTheOptInWhateverItsSignatureNames
    /// checks the behaviour.
    func testTheReleaseIsAdHocSignedWithNoSigningOrNotarizationStep() throws {
        let text = try XCTUnwrap(try workflows().first { $0.name == "release.yml" }).text
        for absent in ["secrets.", "security ", "create-keychain", "notarytool", "stapler", "INSOMNIA_SIGN", "INSOMNIA_NOTARY"] {
            XCTAssertFalse(text.contains(absent), "release.yml contains \(absent)")
        }
        let repo = workflowsDir.deletingLastPathComponent().deletingLastPathComponent()
        let build = try String(contentsOf: repo.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        for absent in ["INSOMNIA_SIGN_IDENTITY", "--options", "--timestamp"] {
            XCTAssertFalse(build.contains(absent), "build-app.sh contains \(absent)")
        }
        XCTAssertTrue(build.contains(#""$CODESIGN" --force --sign - "$APP""#), "build-app.sh signs ad-hoc")
        let install = try String(contentsOf: repo.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        for absent in ["spctl", "SPCTL", "EXPECTED_TEAM_ID", "TeamIdentifier"] {
            XCTAssertFalse(install.contains(absent), "install.sh contains \(absent)")
        }
    }

    /// The build job has read-only access; only the job
    /// that publishes may write, and only what publishing needs.
    func testOnlyTheReleaseJobMayWrite() throws {
        let text = try XCTUnwrap(try workflows().first { $0.name == "release.yml" }).text
        let ls = lines(text)
        let buildStart = try XCTUnwrap(ls.firstIndex(of: "  build:"))
        let releaseStart = try XCTUnwrap(ls.firstIndex(of: "  release:"))
        XCTAssertLessThan(buildStart, releaseStart)
        let buildLines = Array(ls[buildStart..<releaseStart])
        let build = buildLines.joined(separator: "\n")
        let release = ls[releaseStart...].joined(separator: "\n")
        // The build job's one permissions key is a block whose entries are
        // exactly `contents: read`, so a scope added on any later line, or
        // an inline map or write-all in its place, fails here.
        let keys = buildLines.indices.filter { buildLines[$0].hasPrefix("    permissions:") }
        XCTAssertEqual(keys.count, 1, "one permissions key in the build job")
        let key = try XCTUnwrap(keys.first)
        XCTAssertEqual(buildLines[key], "    permissions:", "a block, not an inline map or write-all")
        let scopes = buildLines[(key + 1)...]
            .prefix { $0.hasPrefix("      ") }
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(scopes, ["contents: read"], "the build job only reads the repository")
        XCTAssertNil(build.range(of: #"(?m)^\s+[\w-]+:\s*write"#, options: .regularExpression), "no write scope on any line of the build job")
        for scope in ["contents: write", "id-token: write", "attestations: write"] {
            XCTAssertTrue(release.contains("      \(scope)"), "release job needs \(scope)")
        }
        XCTAssertFalse(release.contains("packages:"), release)
        XCTAssertFalse(release.contains("actions: write"), release)
        XCTAssertFalse(release.contains("uses: actions/checkout"), "publishing needs no checkout")
    }

    /// Release bundles are arm64 only (no universal build), so the notes'
    /// first line and the README's Install section say a release needs an
    /// Apple Silicon Mac. RecoveryScriptTests checks that install.sh --app
    /// stops on any other Mac.
    func testTheNotesAndTheReadmeStateTheAppleSiliconRequirement() throws {
        let text = try XCTUnwrap(try workflows().first { $0.name == "release.yml" }).text
        XCTAssertTrue(text.contains(#"echo "Insomnia $VERSION for Apple Silicon Macs with macOS 26 or later."#), "the notes' first line")
        let repo = workflowsDir.deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)
        let install = try XCTUnwrap(readme.range(of: "\n## Install\n"), "README has no Install section")
        let end = readme.range(of: "\n## ", range: install.upperBound..<readme.endIndex)?.lowerBound ?? readme.endIndex
        XCTAssertTrue(readme[install.upperBound..<end].contains("Apple Silicon"), "the README's Install section")
    }

    /// The scripts the zip carries sit at its top level, so the folder above
    /// theirs is wherever the user unpacked it (/tmp, Downloads). They take
    /// sibling scripts from their own folder only; a path built from the
    /// parent of the script's folder would run whatever another account put
    /// there. Each script's own code up to in_checkout runs here from a zip
    /// folder whose parent looks like a source checkout (scripts/ and
    /// Package.swift): SCRIPT_DIR is the zip folder, which is no checkout.
    /// uninstall.sh also runs with a dirname first in PATH and CDPATH that
    /// both name a decoy folder, and finds its own folder without either;
    /// install.sh's line is main's and is run without them.
    /// RecoveryScriptTests runs both whole from a zip layout.
    func testTheZipsScriptsTakeNothingFromTheFolderAboveTheirOwn() throws {
        let text = try XCTUnwrap(try workflows().first { $0.name == "release.yml" }).text
        let copy = try XCTUnwrap(lines(text).first { $0.contains(#""release/$pkg/""#) && $0.contains("cp ") }, "no cp into the package folder")
        let shipped = copy.split(separator: " ").map(String.init).filter { $0.hasPrefix("scripts/") }
        XCTAssertEqual(shipped, ["scripts/install.sh", "scripts/uninstall.sh"])
        let repo = workflowsDir.deletingLastPathComponent().deletingLastPathComponent()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("zip-scripts-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let unpackedIn = tmp.appendingPathComponent("unpacked", isDirectory: true)
        let zip = unpackedIn.appendingPathComponent("Insomnia-1.0", isDirectory: true)
        let decoy = tmp.appendingPathComponent("decoy", isDirectory: true)
        for dir in [zip, unpackedIn.appendingPathComponent("scripts"), decoy.appendingPathComponent("Insomnia-1.0")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "".write(to: unpackedIn.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "".write(to: unpackedIn.appendingPathComponent("scripts/backstop.sh"), atomically: true, encoding: .utf8)
        let shadow = tmp.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: shadow, withIntermediateDirectories: true)
        let ranShadow = tmp.appendingPathComponent("dirname.ran")
        try "#!/bin/bash\ntouch '\(ranShadow.path)'\necho '\(decoy.path)'\n".write(to: shadow.appendingPathComponent("dirname"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shadow.appendingPathComponent("dirname").path)
        for path in shipped {
            let name = String(path.dropFirst("scripts/".count))
            let script = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(script.contains(#"BASH_SOURCE[0]}")/.."#), "\(path) resolves a path from the parent of its folder")
            let checkout = try XCTUnwrap(script.range(of: "\nin_checkout() {"), "\(path) has no in_checkout")
            let lineEnd = try XCTUnwrap(script.range(of: "\n", range: checkout.upperBound..<script.endIndex), path)
            try (String(script[..<lineEnd.upperBound]) + #"printf '%s\n' "$SCRIPT_DIR"; if in_checkout; then echo checkout; else echo zip; fi"# + "\n")
                .write(to: zip.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let shadowed = name == "uninstall.sh"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", #"cd "$0" && exec /bin/bash "$1""#, unpackedIn.path, "Insomnia-1.0/\(name)"]
            p.environment = ["PATH": (shadowed ? "\(shadow.path):" : "") + "/usr/bin:/bin", "HOME": tmp.path]
                .merging(shadowed ? ["CDPATH": decoy.path] : [:]) { $1 }
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, path)
            let got = printed.split(separator: "\n").map(String.init)
            XCTAssertEqual(got.count, 2, "\(path): \(printed)")
            XCTAssertTrue(got.first?.hasSuffix("/unpacked/Insomnia-1.0") == true, "\(path) found \(printed)")
            XCTAssertEqual(got.last, "zip", "\(path): \(printed)")
            if shadowed {
                XCTAssertFalse(fm.fileExists(atPath: ranShadow.path), "\(path) ran the dirname in PATH")
            }
        }
    }
}
