import Foundation
import XCTest
@testable import Insomnia

/// Static checks on .github/workflows/*.yml: every action is pinned to a
/// commit SHA with its version alongside, and no job runs with the default
/// token permissions. release.yml gets a few more: its triggers, that only a
/// pushed v* tag publishes a stable release and only main a nightly, that the
/// two channels never share their release flags, and that only the
/// publishing jobs can write. Plain text checks, except that the plan job's
/// script also runs with a stub `gh`; the files are small and have no YAML
/// anchors.
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

    private func releaseWorkflow() throws -> String {
        try XCTUnwrap(try workflows().first { $0.name == "release.yml" }).text
    }

    /// release.yml's jobs by id, each with its lines up to the next job.
    private func releaseJobs() throws -> [String: [String]] {
        let ls = lines(try releaseWorkflow())
        let start = try XCTUnwrap(ls.firstIndex(of: "jobs:"), "release.yml has no jobs")
        var jobs: [String: [String]] = [:]
        var current: String?
        for line in ls[(start + 1)...] {
            if line.range(of: #"^  [A-Za-z_][\w-]*:\s*$"#, options: .regularExpression) != nil {
                let id = String(line.trimmingCharacters(in: .whitespaces).dropLast())
                XCTAssertNil(jobs[id], "job \(id) appears twice")
                jobs[id] = []
                current = id
            } else if let current {
                jobs[current, default: []].append(line)
            }
        }
        return jobs
    }

    private func job(_ id: String) throws -> [String] {
        try XCTUnwrap(try releaseJobs()[id], "release.yml has no job \(id)")
    }

    /// The flags of the job's one `gh release create` command (comments
    /// that name it aside), continuation lines included.
    private func releaseCreateFlags(_ body: [String]) throws -> [String] {
        let starts = body.indices.filter { body[$0].trimmingCharacters(in: .whitespaces).hasPrefix("gh release create ") }
        XCTAssertEqual(starts.count, 1, "one gh release create")
        var command: [String] = []
        for line in body[try XCTUnwrap(starts.first)...] {
            command.append(line)
            if !line.hasSuffix("\\") { break }
        }
        return command.joined(separator: " ").split(separator: " ").map(String.init).filter { $0.hasPrefix("--") }
    }

    /// The scopes of the job's one `permissions:` block, comments dropped.
    /// A scope added on any later line, or an inline map or write-all in
    /// place of the block, fails the caller's comparison.
    private func permissionScopes(_ body: [String], job id: String) throws -> [String] {
        let keys = body.indices.filter { body[$0].hasPrefix("    permissions:") }
        XCTAssertEqual(keys.count, 1, "one permissions key in the \(id) job")
        let key = try XCTUnwrap(keys.first)
        XCTAssertEqual(body[key], "    permissions:", "\(id): a block, not an inline map or write-all")
        return body[(key + 1)...]
            .prefix { $0.hasPrefix("      ") }
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces) }
    }

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

    func testReleaseWorkflowTriggersAndWhatEachOnePublishes() throws {
        let text = try releaseWorkflow()
        XCTAssertTrue(text.contains("tags: ['v*']") || text.contains("tags: [\"v*\"]"), "runs on v* tags")
        XCTAssertTrue(text.contains("\n  schedule:\n") && text.contains("\n    - cron: '"), "runs daily for the nightly")
        XCTAssertTrue(text.contains("workflow_dispatch:"), "can be run by hand")
        XCTAssertTrue(text.contains("    inputs:\n      nightly:\n        description: "), "a manual run can ask for a nightly")
        XCTAssertTrue(text.contains("        type: boolean\n        default: false\n"), "a manual run publishes nothing unless asked")
        XCTAssertFalse(text.contains("pull_request"), "never runs for pull requests")
        XCTAssertTrue(text.contains("permissions: {}"), "nothing at the top level")
        XCTAssertEqual(Set(try releaseJobs().keys), ["plan", "build", "stable", "nightly"])

        let plan = try job("plan").joined(separator: "\n")
        XCTAssertTrue(plan.contains(#"if [[ "$NIGHTLY_INPUT" != true ]]; then\#n                printf 'channel=artifact\nbuild=true\n' >> "$GITHUB_OUTPUT""#), "a manual run without the input only builds")
        XCTAssertTrue(plan.contains(#"if [[ "$GITHUB_REF" != refs/heads/main ]]; then"#), "a nightly from any other ref stops before building")
        XCTAssertTrue(try job("build").contains("    if: needs.plan.outputs.build == 'true'"), "nothing is built when the plan says so")

        let stable = try job("stable")
        let nightly = try job("nightly")
        XCTAssertTrue(stable.contains("    if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"), "a stable release is gated on a pushed tag, not on a manual run that happens to use a tag ref")
        XCTAssertTrue(nightly.contains("    if: needs.plan.outputs.channel == 'nightly' && github.ref == 'refs/heads/main' && (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch')"), "a nightly is gated on main and on a scheduled or manual run")
        for (id, body) in [("stable", stable.joined(separator: "\n")), ("nightly", nightly.joined(separator: "\n"))] {
            XCTAssertTrue(body.contains("--signer-workflow $GITHUB_REPOSITORY/.github/workflows/release.yml --source-ref $GITHUB_REF --source-digest $GITHUB_SHA"), "\(id): the notes pin the verify command to this workflow, the ref and the commit")
            XCTAssertTrue(body.contains(#"echo "./install.sh --allow-unverified-origin --app ./Insomnia.app""#), "\(id): the notes' install command carries the origin opt-in install.sh needs for an ad-hoc bundle")
            XCTAssertTrue(body.contains("attest-build-provenance"), "\(id): build provenance is attested")
        }
        XCTAssertTrue(text.contains("shasum -a 256"), "a checksum file is produced")
        XCTAssertTrue(text.contains("ditto -c -k --sequesterRsrc --keepParent"), "zipped the way Finder expects")
        XCTAssertTrue(text.contains("CFBundleShortVersionString"), "the tag is checked against the bundle version")
        XCTAssertTrue(text.contains("scripts/build-app.sh --output"), "built with the same script as install.sh")
        XCTAssertFalse(text.contains("--allow-unsigned"), "no Gatekeeper workarounds")
    }

    /// A stable release is Latest and never a prerelease. A nightly is a
    /// prerelease, never Latest, under a new tag that names its date and
    /// commit; the workflow creates that tag with the call that fails when
    /// it exists, and nothing in the workflow moves, deletes or replaces a
    /// tag, a release or an asset.
    func testStableAndNightlyNeverShareTheirReleaseFlags() throws {
        XCTAssertEqual(try releaseCreateFlags(try job("stable")), ["--repo", "--title", "--notes-file", "--verify-tag", "--latest"])
        XCTAssertEqual(try releaseCreateFlags(try job("nightly")), ["--repo", "--title", "--notes-file", "--verify-tag", "--prerelease", "--latest=false"])
        let plan = try job("plan").joined(separator: "\n")
        XCTAssertTrue(plan.contains(#"sha12="${GITHUB_SHA:0:12}""#))
        XCTAssertTrue(plan.contains(#"tag="nightly-$(date -u +%Y%m%d)-$sha12""#), "the nightly tag names the UTC date and the commit")
        XCTAssertTrue(plan.contains(#"matching-refs/tags/nightly-"#), "existing nightly tags are looked up")
        XCTAssertTrue(plan.contains(#"printf 'channel=nightly\nbuild=false\n' >> "$GITHUB_OUTPUT""#), "a commit that already has a nightly is skipped")
        let build = try job("build").joined(separator: "\n")
        XCTAssertTrue(build.contains(#"want="^nightly-[0-9]{8}-${GITHUB_SHA:0:12}\$""#), "the build checks the tag names the commit it built")
        XCTAssertTrue(build.contains(#"package="Insomnia-$version-$NIGHTLY_TAG-macos""#), "a nightly zip carries its tag in its name")
        let nightly = try job("nightly").joined(separator: "\n")
        XCTAssertTrue(nightly.contains(#"gh api "repos/$GITHUB_REPOSITORY/git/refs" -f "ref=refs/tags/$TAG" -f "sha=$GITHUB_SHA""#), "the tag is created on the built commit, failing if it exists")
        let text = try releaseWorkflow()
        for absent in ["force", "PATCH", "DELETE", "--clobber", "gh release upload", "gh release edit", "gh release delete", "git push", "git tag"] {
            XCTAssertFalse(text.contains(absent), "release.yml contains \(absent)")
        }
    }

    /// Runs the plan job's script from release.yml, as a scheduled run on
    /// main would, with a stub `gh` serving the nightly tags and the release
    /// names of each case. Only a commit whose nightly tag has a release is
    /// skipped. A tag with no release, or a tag naming this commit's first 12
    /// characters on another commit, stops the run with no outputs, so
    /// nothing is built. A commit with no nightly tag gets a new one.
    func testThePlanSkipsOnlyACommitWhoseNightlyHasARelease() throws {
        let script = try planScript()
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let tag = "nightly-20261009-0123456789ab"
        let olderRef = "refs/tags/nightly-20261008-fedcba987654 fedcba9876543210fedcba9876543210fedcba98"
        let olderRelease = "nightly-20261008-fedcba987654"

        var r = try runPlan(script, sha: sha, refs: [olderRef, "refs/tags/\(tag) \(sha)"], releases: ["v0.1.0", olderRelease, tag])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.output, "channel=nightly\nbuild=false\n", "a published nightly of this commit is skipped")

        // A release whose name only starts with the tag is not its release.
        r = try runPlan(script, sha: sha, refs: [olderRef, "refs/tags/\(tag) \(sha)"], releases: ["v0.1.0", olderRelease, "\(tag)-rc"])
        XCTAssertEqual(r.status, 1, "a tag without a release stops the run")
        XCTAssertEqual(r.output, "", "no outputs, so nothing is built")
        XCTAssertTrue(r.stderr.contains("tag \(tag) exists but has no release"), r.stderr)

        let foreign = "0123456789ab" + String(repeating: "f", count: 28)
        r = try runPlan(script, sha: sha, refs: ["refs/tags/\(tag) \(foreign)"], releases: [tag])
        XCTAssertEqual(r.status, 1, "a tag of another commit with the same first 12 characters stops the run")
        XCTAssertEqual(r.output, "", "no outputs, so nothing is built")
        XCTAssertTrue(r.stderr.contains("tag \(tag) points at \(foreign), not \(sha)"), r.stderr)

        // A tag whose name only starts with this commit's nightly name is not its nightly.
        r = try runPlan(script, sha: sha, refs: [olderRef, "refs/tags/\(tag)-x \(sha)"], releases: ["v0.1.0", olderRelease])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertNotNil(r.output.range(of: #"^channel=nightly\nbuild=true\ntag=nightly-[0-9]{8}-0123456789ab\n$"#, options: .regularExpression),
                        "a commit with no nightly gets a new tag: \(r.output)")
    }

    /// The plan job's one `run: |` block, unindented.
    private func planScript() throws -> String {
        let body = try job("plan")
        let runs = body.indices.filter { body[$0] == "        run: |" }
        XCTAssertEqual(runs.count, 1, "one run block in the plan job")
        let script = body[(try XCTUnwrap(runs.first) + 1)...]
            .prefix { $0.isEmpty || $0.hasPrefix("          ") }
            .map { String($0.dropFirst(10)) }
        XCTAssertTrue(script.contains("done <<< \"$refs\""), "the whole block, up to the end of the tag loop")
        return script.joined(separator: "\n") + "\n"
    }

    /// Runs the plan script under `bash -e`, as the runner does, with only
    /// the stub `gh` ahead of /usr/bin:/bin. The stub prints the given tag
    /// refs and release names, what the script's two `gh api` calls would
    /// print after their jq filters, and fails any other call.
    private func runPlan(_ script: String, sha: String, refs: [String], releases: [String]) throws -> (status: Int32, output: String, stderr: String) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("release-plan-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try (refs.map { $0 + "\n" }.joined()).write(to: root.appendingPathComponent("refs"), atomically: true, encoding: .utf8)
        try (releases.map { $0 + "\n" }.joined()).write(to: root.appendingPathComponent("releases"), atomically: true, encoding: .utf8)
        let gh = bin.appendingPathComponent("gh")
        try #"""
            #!/bin/bash
            here="$(cd "$(dirname "$0")/.." && pwd)"
            if [[ $# -eq 5 && $1 == api && $2 == --paginate && $4 == --jq ]]; then
              case "$3" in
                repos/krishhgg/Insomnia/git/matching-refs/tags/nightly-) exec /bin/cat "$here/refs" ;;
                "repos/krishhgg/Insomnia/releases?per_page=100") exec /bin/cat "$here/releases" ;;
              esac
            fi
            echo "stub gh: unexpected call: $*" >&2
            exit 99

            """#.write(to: gh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let scriptURL = root.appendingPathComponent("plan.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let outputURL = root.appendingPathComponent("output")
        let errURL = root.appendingPathComponent("stderr")
        for url in [outputURL, errURL] { fm.createFile(atPath: url.path, contents: nil) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-e", scriptURL.path]
        p.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(),
            "EVENT": "schedule", "NIGHTLY_INPUT": "", "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": sha,
            "GITHUB_REPOSITORY": "krishhgg/Insomnia", "GITHUB_OUTPUT": outputURL.path,
        ]
        // Capture to files rather than pipes: nothing to drain, nothing to deadlock.
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? err.close() }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        let childExit = ProcessExit(p)
        try p.run()
        childExit.wait()
        return (p.terminationStatus,
                (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
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
        let text = try releaseWorkflow()
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

    /// The plan and build jobs have read-only access; only the jobs that
    /// publish may write, and only what publishing needs.
    func testOnlyThePublishingJobsMayWrite() throws {
        for id in ["plan", "build"] {
            let body = try job(id)
            XCTAssertEqual(try permissionScopes(body, job: id), ["contents: read"], "the \(id) job only reads the repository")
            XCTAssertNil(body.joined(separator: "\n").range(of: #"(?m)^\s+[\w-]+:\s*write"#, options: .regularExpression), "no write scope on any line of the \(id) job")
        }
        for id in ["stable", "nightly"] {
            let body = try job(id)
            XCTAssertEqual(try permissionScopes(body, job: id), ["contents: write", "id-token: write", "attestations: write"], id)
            let text = body.joined(separator: "\n")
            XCTAssertFalse(text.contains("packages:"), id)
            XCTAssertFalse(text.contains("actions: write"), id)
            XCTAssertFalse(text.contains("uses: actions/checkout"), "\(id): publishing needs no checkout")
        }
    }

    /// Release bundles are arm64 only (no universal build), so the notes'
    /// first line and the README's Install section say a release needs an
    /// Apple Silicon Mac. RecoveryScriptTests checks that install.sh --app
    /// stops on any other Mac.
    func testTheNotesAndTheReadmeStateTheAppleSiliconRequirement() throws {
        for id in ["stable", "nightly"] {
            XCTAssertTrue(try job(id).joined(separator: "\n").contains(#"echo "Insomnia $VERSION for Apple Silicon Macs with macOS 26 or later."#), "the \(id) notes' first line")
        }
        XCTAssertTrue(try readmeInstallSection().contains("Apple Silicon"), "the README's Install section")
    }

    /// The README's Install section lets a reader, or the coding agent the
    /// README is pasted into, choose a channel, and sends v0.1.0, which no
    /// workflow built, to its own release notes.
    func testTheReadmeOffersBothChannelsAndSetsV010Apart() throws {
        let install = try readmeInstallSection().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for phrase in ["Stable: the release GitHub marks Latest", "Nightly: prereleases tagged `nightly-", "A nightly is never marked Latest",
                       "`refs/tags/v<version>` for a stable release or `refs/heads/main` for a nightly",
                       "--source-ref <ref> --source-digest <commit>",
                       "If the release you picked is `v0.1.0`", "Install the latest stable Insomnia release from", "the newest Insomnia nightly prerelease"] {
            XCTAssertTrue(install.contains(phrase), "the README's Install section lacks: \(phrase)")
        }
    }

    private func readmeInstallSection() throws -> String {
        let repo = workflowsDir.deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8)
        let install = try XCTUnwrap(readme.range(of: "\n## Install\n"), "README has no Install section")
        let end = readme.range(of: "\n## ", range: install.upperBound..<readme.endIndex)?.lowerBound ?? readme.endIndex
        return String(readme[install.upperBound..<end])
    }

    /// The scripts the zip carries sit at its top level, so the folder above
    /// theirs is wherever the user unpacked it (/tmp, Downloads). They take
    /// sibling scripts from their own folder only; a path built from the
    /// parent of the script's folder would run whatever another account put
    /// there. RecoveryScriptTests runs both from a zip layout.
    func testTheZipsScriptsTakeNothingFromTheFolderAboveTheirOwn() throws {
        let text = try releaseWorkflow()
        let copy = try XCTUnwrap(lines(text).first { $0.contains(#""release/$pkg/""#) && $0.contains("cp ") }, "no cp into the package folder")
        let shipped = copy.split(separator: " ").map(String.init).filter { $0.hasPrefix("scripts/") }
        XCTAssertEqual(shipped, ["scripts/install.sh", "scripts/uninstall.sh"])
        let repo = workflowsDir.deletingLastPathComponent().deletingLastPathComponent()
        for path in shipped {
            let script = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(script.contains(#"BASH_SOURCE[0]}")/.."#), "\(path) resolves a path from the parent of its folder")
            XCTAssertTrue(script.contains(#"SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)""#), "\(path) has no SCRIPT_DIR")
        }
    }
}
