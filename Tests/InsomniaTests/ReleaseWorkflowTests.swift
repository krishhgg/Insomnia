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
        XCTAssertTrue(text.contains(#"if [[ "$HAVE_SIGNING" != "$HAVE_NOTARY" ]]"#), "signing secrets without notary secrets (or the reverse) fail the run")
        XCTAssertTrue(text.contains("--signer-workflow $GITHUB_REPOSITORY/.github/workflows/release.yml --source-ref $GITHUB_REF"), "the notes pin the verify command to this workflow and the tag")
        XCTAssertTrue(text.contains("--allow-unverified-origin"), "the notes say when install.sh needs the origin opt-in")
        XCTAssertTrue(text.contains("permissions: {}"), "nothing at the top level")
        XCTAssertTrue(text.contains("--prerelease"), "unsigned builds are marked prerelease")
        XCTAssertTrue(text.contains("attest-build-provenance"), "build provenance is attested")
        XCTAssertTrue(text.contains("shasum -a 256"), "a checksum file is produced")
        XCTAssertTrue(text.contains("ditto -c -k --sequesterRsrc --keepParent"), "zipped the way notarization and Finder expect")
        XCTAssertTrue(text.contains("CFBundleShortVersionString"), "the tag is checked against the bundle version")
        XCTAssertTrue(text.contains("scripts/build-app.sh --output"), "built with the same script as install.sh")
        XCTAssertTrue(text.contains("security delete-keychain"), "the temporary keychain is removed")
        XCTAssertFalse(text.contains("--allow-unsigned"), "no Gatekeeper workarounds")
    }

    /// The job that holds the signing key has read-only access; only the job
    /// that publishes may write, and only what publishing needs.
    func testOnlyTheReleaseJobMayWrite() throws {
        let text = try XCTUnwrap(try workflows().first { $0.name == "release.yml" }).text
        let ls = lines(text)
        let buildStart = try XCTUnwrap(ls.firstIndex(of: "  build:"))
        let releaseStart = try XCTUnwrap(ls.firstIndex(of: "  release:"))
        XCTAssertLessThan(buildStart, releaseStart)
        let build = ls[buildStart..<releaseStart].joined(separator: "\n")
        let release = ls[releaseStart...].joined(separator: "\n")
        XCTAssertTrue(build.contains("    permissions:\n      contents: read\n"), "build job is read-only")
        XCTAssertNil(build.range(of: #"^\s+[\w-]+: write"#, options: .regularExpression), "no write scope in the build job")
        for scope in ["contents: write", "id-token: write", "attestations: write"] {
            XCTAssertTrue(release.contains("      \(scope)"), "release job needs \(scope)")
        }
        XCTAssertFalse(release.contains("packages:"), release)
        XCTAssertFalse(release.contains("actions: write"), release)
        XCTAssertFalse(release.contains("uses: actions/checkout"), "publishing needs no checkout")
    }
}
