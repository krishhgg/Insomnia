import XCTest
@testable import Insomnia

/// The agent is persistent: loaded once with RunAtLoad + StartInterval,
/// never replaced per deadline. `arm()` only touches launchd when the agent
/// is missing or its plist is stale.
final class LaunchdBackstopTests: XCTestCase {
    var home: TempHome!
    /// (exe, args) of every command the backstop ran.
    let calls = Locked<[[String]]>([])
    /// Whether `launchctl print` reports the job loaded.
    let loaded = Locked(false)
    let bootstrapFails = Locked(false)
    /// bootout returns an error and leaves the job loaded, as launchd does
    /// for a job that is mid-transition.
    let bootoutFails = Locked(false)
    /// Runs once, inside the next fake `bootout` / after the next successful
    /// fake `bootstrap`, so a test can break the filesystem at exactly that
    /// moment and still let a later arm() recover.
    let onBootout = Locked<(@Sendable () -> Void)?>(nil)
    let onBootstrapped = Locked<(@Sendable () -> Void)?>(nil)
    /// What the trusted plist path held when each `bootstrap` ran.
    let trustedPlistAtBootstrap = Locked<[Data?]>([])

    override func setUp() {
        home = TempHome()
        calls.value = []
        loaded.value = false
        bootstrapFails.value = false
        bootoutFails.value = false
        onBootout.value = nil
        onBootstrapped.value = nil
        trustedPlistAtBootstrap.value = []
    }

    override func tearDown() { home.destroy() }

    private func makeBackstop(installScript: Bool = true) throws -> LaunchdBackstop {
        if installScript {
            try Data("#!/bin/bash\n".utf8).write(to: home.paths.backstopScript)
        }
        let calls = calls, loaded = loaded, bootstrapFails = bootstrapFails, bootoutFails = bootoutFails
        let onBootout = onBootout, onBootstrapped = onBootstrapped, trustedPlistAtBootstrap = trustedPlistAtBootstrap
        let trusted = home.paths.backstopPlist
        let label = "com.insomnia.backstop"
        // What launchd itself enforces on a path argument (proven against a
        // disposable label, see the class comment on the regression test):
        // it must end in `.plist` and hold a readable plist with the label.
        // Anything else fails with EIO, for bootstrap and bootout alike.
        let launchdAccepts: @Sendable (String) -> Bool = { path in
            guard path.hasSuffix(".plist"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return false }
            return obj["Label"] as? String == label
        }
        return LaunchdBackstop(paths: home.paths, uid: 501) { exe, args in
            calls.value.append([exe] + args)
            switch args.first {
            case "print":
                return ShellResult(status: loaded.value ? 0 : 113, stdout: "", stderr: loaded.value ? "" : "Could not find service")
            case "bootstrap":
                trustedPlistAtBootstrap.value.append(try? Data(contentsOf: trusted))
                guard args.count == 3, launchdAccepts(args[2]) else {
                    return ShellResult(status: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error")
                }
                if bootstrapFails.value { return ShellResult(status: 5, stdout: "", stderr: "Input/output error") }
                // launchd refuses to bootstrap a label that is still loaded.
                if loaded.value { return ShellResult(status: 37, stdout: "", stderr: "Bootstrap failed: 37: Operation already in progress") }
                loaded.value = true
                if let hook = onBootstrapped.value { onBootstrapped.value = nil; hook() }
                return ShellResult(status: 0, stdout: "", stderr: "")
            case "bootout":
                if let hook = onBootout.value { onBootout.value = nil; hook() }
                // Either a service target (`gui/501/<label>`) or a domain plus
                // a plist path launchd can read the label from.
                let byTarget = args.count == 2 && args[1] == "gui/501/\(label)"
                let byPath = args.count == 3 && launchdAccepts(args[2])
                guard byTarget || byPath else {
                    return ShellResult(status: 5, stdout: "", stderr: "Boot-out failed: 5: Input/output error")
                }
                if bootoutFails.value { return ShellResult(status: 36, stdout: "", stderr: "Boot-out failed: 36: Operation now in progress") }
                if !loaded.value { return ShellResult(status: 3, stdout: "", stderr: "Boot-out failed: 3: No such process") }
                loaded.value = false
                return ShellResult(status: 0, stdout: "", stderr: "")
            default:
                return ShellResult(status: 1, stdout: "", stderr: "unexpected \(args)")
            }
        }
    }

    private func plistOnDisk() throws -> [String: Any] {
        let data = try Data(contentsOf: home.paths.backstopPlist)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// Names in the LaunchAgents directory: the trusted plist and any
    /// leftover from a failed replacement.
    private func launchAgentsEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: home.paths.launchAgents.path).sorted()
    }

    /// A hook that makes this test's own temporary LaunchAgents directory
    /// refuse new entries and renames, like a volume that stopped taking
    /// writes. Undone by `restoreLaunchAgentsWrites()` and again at
    /// teardown, so the temp tree is always removable.
    private func stopLaunchAgentsWritesHook() -> @Sendable () -> Void {
        let dir = home.paths.launchAgents.path
        addTeardownBlock { _ = chmod(dir, 0o755) }
        return { _ = chmod(dir, 0o500) }
    }

    private func restoreLaunchAgentsWrites() {
        _ = chmod(home.paths.launchAgents.path, 0o755)
    }

    /// An older build's plist: RunAtLoad only, no polling.
    private func writeStalePlist() throws {
        let stale: [String: Any] = ["Label": "com.insomnia.backstop", "ProgramArguments": ["/bin/bash", home.paths.backstopScript.path], "RunAtLoad": true]
        try FileManager.default.createDirectory(at: home.paths.backstopPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: stale, format: .xml, options: 0).write(to: home.paths.backstopPlist)
    }

    func testPlistIsAPersistentPollingAgent() {
        let d = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", scriptPath: "/x/backstop.sh")
        XCTAssertEqual(d["Label"] as? String, "com.insomnia.backstop")
        XCTAssertEqual(d["ProgramArguments"] as? [String], ["/bin/bash", "/x/backstop.sh"])
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["StartInterval"] as? Int, 60)
        XCTAssertNil(d["StartCalendarInterval"], "a per-deadline trigger would need a reload per extension")
    }

    func testArmWritesPlistAndBootstrapsWhenNotLoaded() async throws {
        let b = try makeBackstop()
        try await b.arm()
        // No plist on disk yet, so launchctl is not even asked: write and load.
        XCTAssertEqual(calls.value.map { Array($0[0...2]) }, [
            ["/bin/launchctl", "bootout", "gui/501/com.insomnia.backstop"],
            ["/bin/launchctl", "bootstrap", "gui/501"],
        ])
        let plist = try plistOnDisk()
        XCTAssertEqual(plist["StartInterval"] as? Int, 60)
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?.last, home.paths.backstopScript.path)
        XCTAssertEqual(try launchAgentsEntries(), ["com.insomnia.backstop.plist"], "candidate left next to the published plist")
    }

    /// The trusted plist path is what the next arm() believes when launchd
    /// says the label is loaded, so it may only ever hold a plist launchd
    /// actually loaded: bootstrap goes through a private candidate and the
    /// trusted path changes after bootstrap succeeded, not before.
    func testDesiredPlistIsPublishedOnlyAfterLaunchdLoadedIt() async throws {
        let b = try makeBackstop()
        try writeStalePlist()
        let stale = try Data(contentsOf: home.paths.backstopPlist)
        try await b.arm()
        let bootstrap = try XCTUnwrap(calls.value.first { $0[1] == "bootstrap" })
        XCTAssertNotEqual(bootstrap[3], home.paths.backstopPlist.path, "bootstrapped from the trusted path: it was rewritten before launchd loaded it")
        XCTAssertEqual(trustedPlistAtBootstrap.value, [stale], "trusted plist changed before bootstrap succeeded")
        XCTAssertEqual(try plistOnDisk()["StartInterval"] as? Int, 60)
        XCTAssertEqual(try launchAgentsEntries(), ["com.insomnia.backstop.plist"])
    }

    /// Regression for the blank timer after Enter: every arm() failed with
    /// "launchctl bootstrap failed (5): Input/output error" and the stale
    /// RunAtLoad-only agent stayed loaded. Measured against a disposable
    /// label on this machine (launchctl 2026-09-15): bootstrap and bootout
    /// both refuse a path without a `.plist` suffix with EIO; a `.plist` in
    /// a subdirectory loads fine; a directory-level load (what login does
    /// to ~/Library/LaunchAgents) ignores subdirectories; and bootout by
    /// service target works whatever is on disk. So the candidate must be
    /// a `.plist` in a private subdirectory of the LaunchAgents directory
    /// (same filesystem, so publishing stays one rename), and the old job
    /// is booted out by label, not by a candidate path.
    func testCandidateIsALaunchdLoadablePlistThatLoginCannotPickUp() async throws {
        let b = try makeBackstop()
        try writeStalePlist()
        loaded.value = true
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"])
        let bootout = try XCTUnwrap(calls.value.first { $0[1] == "bootout" })
        XCTAssertEqual(Array(bootout.dropFirst()), ["bootout", "gui/501/com.insomnia.backstop"], "boot out by service target: a candidate path is refused when it has no .plist suffix and is pointless once it does")
        let bootstrap = try XCTUnwrap(calls.value.first { $0[1] == "bootstrap" })
        let candidate = URL(fileURLWithPath: bootstrap[3])
        XCTAssertTrue(candidate.lastPathComponent.hasSuffix(".plist"), "launchctl refuses to bootstrap \(candidate.lastPathComponent) (EIO)")
        let stagingDir = candidate.deletingLastPathComponent()
        XCTAssertNotEqual(stagingDir.path, home.paths.launchAgents.path, "a *.plist candidate directly in LaunchAgents is loaded at login as a second copy of the label")
        XCTAssertEqual(stagingDir.deletingLastPathComponent().path, home.paths.launchAgents.path, "the candidate must live one level below the trusted plist so publishing is a rename on the same filesystem")
        XCTAssertEqual(try plistOnDisk()["StartInterval"] as? Int, 60)
        XCTAssertTrue(loaded.value)
        XCTAssertEqual(try launchAgentsEntries(), ["com.insomnia.backstop.plist"], "staging directory not removed after publishing")
    }

    func testArmIsANoopWhenLoadedWithCurrentPlist() async throws {
        let b = try makeBackstop()
        try await b.arm()
        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value, [["/bin/launchctl", "print", "gui/501/com.insomnia.backstop"]], "a loaded agent was reloaded, opening a window with no agent")
    }

    /// Plist current but the job not loaded (logged out and in without the
    /// agent, or booted out by hand): reload without rewriting.
    func testArmBootstrapsWhenPlistIsCurrentButJobIsNotLoaded() async throws {
        let b = try makeBackstop()
        try await b.arm()
        loaded.value = false
        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["print", "bootout", "bootstrap"])
    }

    func testArmReloadsWhenThePlistOnDiskIsStale() async throws {
        let b = try makeBackstop()
        try await b.arm()
        try writeStalePlist()
        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"])
        XCTAssertEqual(try plistOnDisk()["StartInterval"] as? Int, 60)
    }

    /// bootout leaves the old, non-polling job loaded and bootstrap is
    /// refused. The desired plist must not end up on disk over that old
    /// job: the next arm() would see "plist current, label loaded" and call
    /// the old job the polling agent.
    func testFailedReplacementLeavesThePreviousPlistSoTheOldJobIsNotMistakenForUpgraded() async throws {
        let b = try makeBackstop()
        try writeStalePlist()
        loaded.value = true
        bootoutFails.value = true
        do {
            try await b.arm()
            XCTFail("arm succeeded while the old job stayed loaded")
        } catch {}
        XCTAssertNil(try plistOnDisk()["StartInterval"], "desired plist left on disk over the old job")
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"])

        // launchd cooperates now: the next arm must really replace the job.
        bootoutFails.value = false
        calls.value = []
        try await b.arm()
        XCTAssertTrue(calls.value.map { $0[1] }.contains("bootstrap"), "old job accepted as the polling agent: \(calls.value)")
        XCTAssertEqual(try plistOnDisk()["StartInterval"] as? Int, 60)
        XCTAssertTrue(loaded.value)
    }

    /// First load with nothing on disk fails: no plist may be left behind
    /// claiming an agent that was never loaded.
    func testFailedFirstLoadLeavesNoPlistBehind() async throws {
        let b = try makeBackstop()
        bootstrapFails.value = true
        do {
            try await b.arm()
            XCTFail("arm succeeded with no agent loaded")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.backstopPlist.path), "plist written although the agent failed to load")
        XCTAssertEqual(try launchAgentsEntries(), [], "candidate left behind by the failed load")

        bootstrapFails.value = false
        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"])
        XCTAssertEqual(try plistOnDisk()["StartInterval"] as? Int, 60)
    }

    /// The replacement fails (old job stays loaded, bootstrap refused) and
    /// the directory stops taking writes mid-way, so no rollback of the
    /// trusted file could ever succeed. The trusted plist must still be the
    /// old one, and no later arm() may report success without loading the
    /// polling agent.
    func testFailedReplacementWithImpossibleRollbackNeverPublishesTheDesiredPlist() async throws {
        let b = try makeBackstop()
        try writeStalePlist()
        loaded.value = true
        bootoutFails.value = true
        onBootout.value = stopLaunchAgentsWritesHook()
        do {
            try await b.arm()
            XCTFail("arm succeeded while the old job stayed loaded")
        } catch {}
        XCTAssertNil(try plistOnDisk()["StartInterval"], "desired plist published over the old, non-polling job")

        // launchd would cooperate now, but the volume still refuses writes:
        // arm may fail, it may not call the old job the polling agent.
        bootoutFails.value = false
        calls.value = []
        do {
            try await b.arm()
            XCTFail("arm reported success without loading the polling agent: \(calls.value)")
        } catch {}
        XCTAssertNil(try plistOnDisk()["StartInterval"])

        // Writes work again: the next arm really replaces the job.
        restoreLaunchAgentsWrites()
        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"], "old job accepted as the polling agent")
        XCTAssertEqual(try plistOnDisk()["StartInterval"] as? Int, 60)
        XCTAssertTrue(loaded.value)
        XCTAssertEqual(try launchAgentsEntries(), ["com.insomnia.backstop.plist"], "leftover candidate not swept once writes worked again")
    }

    /// launchd loaded the desired job but the trusted plist could not be
    /// published: the file launchd reads at the next login is still stale,
    /// so arm() must fail now and finish the job on a later call.
    func testFailedPublishAfterLoadFailsArmAndIsRetriedNextArm() async throws {
        let b = try makeBackstop()
        try writeStalePlist()
        loaded.value = true
        onBootstrapped.value = stopLaunchAgentsWritesHook()
        do {
            try await b.arm()
            XCTFail("arm succeeded although the plist launchd loads at login is stale")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("published"), error.localizedDescription)
        }
        XCTAssertNil(try plistOnDisk()["StartInterval"], "stale plist replaced although publishing failed")

        restoreLaunchAgentsWrites()
        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"])
        XCTAssertEqual(try plistOnDisk()["StartInterval"] as? Int, 60)
        XCTAssertTrue(loaded.value)
        XCTAssertEqual(try launchAgentsEntries(), ["com.insomnia.backstop.plist"])
    }

    func testArmFailsWhenBootstrapFails() async throws {
        bootstrapFails.value = true
        let b = try makeBackstop()
        do {
            try await b.arm()
            XCTFail("arm succeeded with no agent loaded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("bootstrap"), error.localizedDescription)
        }
    }

    func testArmFailsBeforeTouchingLaunchdWhenScriptIsMissing() async throws {
        let b = try makeBackstop(installScript: false)
        do {
            try await b.arm()
            XCTFail("arm succeeded without backstop.sh")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("install.sh"), error.localizedDescription)
        }
        XCTAssertEqual(calls.value, [])
    }
}
