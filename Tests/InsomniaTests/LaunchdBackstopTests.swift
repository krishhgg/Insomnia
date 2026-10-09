import XCTest
@testable import Insomnia

/// The agent is persistent: loaded once with RunAtLoad + StartInterval,
/// never replaced per deadline. `arm()` only touches launchd when the agent
/// is missing or its plist is stale. Its plist pins the bundle's code
/// requirement and runs the backstop.sh sealed inside the bundle.
final class LaunchdBackstopTests: XCTestCase {
    /// What install.sh reads from `codesign -d -r-` for an ad-hoc build. The
    /// fake reader below hands it out for the fixture bundle.
    static let requirement = "cdhash H\"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c\""
    var home: TempHome!
    /// (exe, args) of every command the backstop ran.
    let calls = Locked<[[String]]>([])
    /// Whether `launchctl print` reports the job loaded.
    let loaded = Locked(false)
    /// The ProgramArguments of the plist the loaded job was bootstrapped
    /// from, which `launchctl print` lists under `arguments`.
    let loadedJob = Locked<[String]>([])
    /// Its StartInterval, which `launchctl print` lists as `run interval`.
    let loadedInterval = Locked<Int?>(nil)
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
        loadedJob.value = []
        loadedInterval.value = nil
        bootstrapFails.value = false
        bootoutFails.value = false
        onBootout.value = nil
        onBootstrapped.value = nil
        trustedPlistAtBootstrap.value = []
    }

    override func tearDown() { home.destroy() }

    private func makeBackstop(
        installScript: Bool = true,
        requirement: String = LaunchdBackstopTests.requirement,
        requirementUnreadable: Bool = false,
        bundleFailsCheck: Bool = false
    ) throws -> LaunchdBackstop {
        if installScript {
            let script = home.paths.backstopScript
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/bash\n".utf8).write(to: script)
        }
        let calls = calls, loaded = loaded, loadedJob = loadedJob, loadedInterval = loadedInterval, bootstrapFails = bootstrapFails, bootoutFails = bootoutFails
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
        let bundle = home.paths.appBundle
        // Stands in for CodeRequirement.pin: the requirement of the fixture
        // bundle, or the two ways the real one refuses (no readable
        // signature; a bundle that fails the agent's check).
        let pin: LaunchdBackstop.BundlePinner = { asked in
            guard asked == bundle, !requirementUnreadable else {
                throw CodeRequirement.ReadError(path: asked.path, step: "SecStaticCodeCreateWithPath", status: -67062)
            }
            if bundleFailsCheck {
                throw CodeRequirement.VerifyError(path: asked.path, requirement: requirement, reason: "a sealed resource is missing or invalid")
            }
            return requirement
        }
        return LaunchdBackstop(paths: home.paths, bundle: bundle, pin: pin, uid: 501) { exe, args in
            calls.value.append([exe] + args)
            switch args.first {
            case "print":
                guard loaded.value else { return ShellResult(status: 113, stdout: "", stderr: "Could not find service") }
                return ShellResult(status: 0, stdout: Self.printOutput(arguments: loadedJob.value, runInterval: loadedInterval.value), stderr: "")
            case "bootstrap":
                trustedPlistAtBootstrap.value.append(try? Data(contentsOf: trusted))
                guard args.count == 3, launchdAccepts(args[2]) else {
                    return ShellResult(status: 5, stdout: "", stderr: "Bootstrap failed: 5: Input/output error")
                }
                if bootstrapFails.value { return ShellResult(status: 5, stdout: "", stderr: "Input/output error") }
                // launchd refuses to bootstrap a label that is still loaded.
                if loaded.value { return ShellResult(status: 37, stdout: "", stderr: "Bootstrap failed: 37: Operation already in progress") }
                loaded.value = true
                let plist = (try? Data(contentsOf: URL(fileURLWithPath: args[2])))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                loadedJob.value = plist?["ProgramArguments"] as? [String] ?? []
                loadedInterval.value = plist?["StartInterval"] as? Int
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

    /// `launchctl print gui/501/<label>` for a loaded job, in the layout
    /// launchctl prints (checked 2026-10-02): top-level keys indented by one
    /// tab, each argument on its own line indented by two, and `run
    /// interval` only for a job with a StartInterval.
    static func printOutput(arguments: [String], runInterval: Int?) -> String {
        """
        gui/501/com.insomnia.backstop = {
        \tactive count = 0
        \tpath = /Users/tester/Library/LaunchAgents/.com.insomnia.backstop.staging/com.insomnia.backstop.candidate-1.plist
        \ttype = LaunchAgent
        \tstate = not running

        \tprogram = /bin/sh
        \targuments = {
        \(arguments.map { "\t\t\($0)\n" }.joined())\t}

        \tdefault environment = {
        \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
        \t}

        \tdomain = gui/501 [100022]
        \tcpumon = default
        \(runInterval.map { "\trun interval = \($0) seconds\n" } ?? "")
        \tproperties = runatload | inferred program | managed LWCR | has LWCR
        }

        """
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

    /// The writable copy installs before the sealed layout ran from.
    private var legacyScriptPath: String { home.paths.appSupport.appendingPathComponent("backstop.sh").path }

    private func writePlist(_ plist: [String: Any]) throws {
        try FileManager.default.createDirectory(at: home.paths.backstopPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: home.paths.backstopPlist)
    }

    /// An older build's plist: RunAtLoad only, no polling, writable script.
    private func writeStalePlist() throws {
        try writePlist(["Label": "com.insomnia.backstop", "ProgramArguments": ["/bin/bash", legacyScriptPath], "RunAtLoad": true])
    }

    /// The polling agent as installed before this layout: bash on a writable
    /// copy in Application Support, no verification.
    private func writeLegacyPollingPlist() throws {
        try writePlist(["Label": "com.insomnia.backstop", "ProgramArguments": ["/bin/bash", legacyScriptPath], "RunAtLoad": true, "StartInterval": 60])
    }

    private var expectedArguments: [String] {
        ["/bin/sh", "-c", LaunchdBackstop.agentProgram, "sh", Self.requirement, home.paths.appBundle.path]
    }

    func testPlistIsAPersistentPollingAgentThatVerifiesTheBundleFirst() {
        let target = BackstopTarget(bundle: URL(fileURLWithPath: "/x/Insomnia.app", isDirectory: true), requirement: "cdhash H\"ab\"")
        let d = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", target: target)
        XCTAssertEqual(d["Label"] as? String, "com.insomnia.backstop")
        XCTAssertEqual(d["ProgramArguments"] as? [String], ["/bin/sh", "-c", LaunchdBackstop.agentProgram, "sh", "cdhash H\"ab\"", "/x/Insomnia.app"])
        XCTAssertEqual(d["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(d["StartInterval"] as? Int, 60)
        XCTAssertNil(d["StartCalendarInterval"], "a per-deadline trigger would need a reload per extension")
        XCTAssertEqual(target.script.path, "/x/Insomnia.app/Contents/Resources/backstop.sh")
    }

    /// The program itself: verify the bundle ($2) against the requirement
    /// ($1), exec the sealed script only then, and never run anything else.
    /// PackagingTests runs it against a real signed bundle; this pins the
    /// shape install.sh and the shell depend on.
    func testAgentProgramVerifiesBeforeExecAndRunsNothingOnFailure() throws {
        let p = LaunchdBackstop.agentProgram
        let verify = try XCTUnwrap(p.range(of: #"/usr/bin/codesign --verify --strict "-R=$1" "$2""#))
        let exec = try XCTUnwrap(p.range(of: #"&& exec /bin/bash "$2/Contents/Resources/backstop.sh""#))
        XCTAssertLessThan(verify.lowerBound, exec.lowerBound, "exec must follow a successful verify")
        XCTAssertTrue(p.hasSuffix("; exit 1"), "a failed verification ends the program: \(p)")
        XCTAssertTrue(p.contains(#"f="$HOME/Library/Logs/Insomnia/insomnia.log"; "#), "the refusal is logged where the app logs")
        XCTAssertEqual(p.components(separatedBy: #">> "$f""#).count, 3, "a newline after a line cut short, then the refusal")
        XCTAssertFalse(p.contains("'"), "install.sh holds the program in single quotes")
        XCTAssertFalse(p.contains("\n"), "one line, so install.sh's AGENT_PROGRAM line stays one line")
        XCTAssertEqual(p.components(separatedBy: "/bin/bash").count, 2, "exactly one exec target: the sealed script")
    }

    /// install.sh embeds the same program (its AGENT_PROGRAM line). The two
    /// must be byte for byte equal: otherwise plistOnDiskMatches is never
    /// true after an install and the app reloads the agent at every start.
    func testAgentProgramIsByteForByteWhatInstallShWrites() throws {
        let installSh = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/install.sh")
        let lines = try String(contentsOf: installSh, encoding: .utf8).components(separatedBy: "\n")
        let definitions = lines.filter { $0.hasPrefix("AGENT_PROGRAM='") }
        XCTAssertEqual(definitions.count, 1, "install.sh defines AGENT_PROGRAM once, single-quoted, on one line")
        let line = try XCTUnwrap(definitions.first)
        XCTAssertTrue(line.hasSuffix("'"), line)
        XCTAssertEqual(String(line.dropFirst("AGENT_PROGRAM='".count).dropLast()), LaunchdBackstop.agentProgram)
    }

    /// The program run as launchd runs it, in a scratch HOME, with codesign
    /// replaced by /usr/bin/false, so the bundle fails the check and
    /// nothing is verified or executed. Its refusal line starts on a line
    /// of its own after a line cut short: the record of a session's end
    /// whose newline alone is missing, a line a write left partway, or a
    /// last byte it cannot read in a log this user may only write to. A log
    /// that ends in a newline, an empty log and a missing one get no extra
    /// newline.
    func testAgentProgramsRefusalLineNeverJoinsALineCutShort() throws {
        let p = LaunchdBackstop.agentProgram
        XCTAssertEqual(p.components(separatedBy: "/usr/bin/codesign").count, 2)
        let failing = p.replacingOccurrences(of: "/usr/bin/codesign", with: "/usr/bin/false")
        let log = home.root.appendingPathComponent("Library/Logs/Insomnia/insomnia.log")
        let record = "\(LogEndRecord.tag) 2 e30="
        let cases: [(name: String, before: String?, mode: Int, lines: [String])] = [
            ("a record without its newline", "a line\n\(record)", 0o600, ["a line", record]),
            ("a line cut short", "a line\ncut sh", 0o600, ["a line", "cut sh"]),
            ("a whole line", "a line\n", 0o600, ["a line"]),
            ("empty", "", 0o600, []),
            ("missing", nil, 0o600, []),
            ("write-only, cut short", "a line\ncut sh", 0o200, ["a line", "cut sh"]),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: log)
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let before = c.before {
                try Data(before.utf8).write(to: log)
                try FileManager.default.setAttributes([.posixPermissions: c.mode], ofItemAtPath: log.path)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", failing, "sh", Self.requirement, home.root.appendingPathComponent("Missing.app").path]
            process.environment = ["HOME": home.root.path, "PATH": "/usr/bin:/bin"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exit = ProcessExit(process)
            try process.run()
            exit.wait()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)

            XCTAssertEqual(process.terminationStatus, 1, c.name)
            let lines = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
            XCTAssertEqual(Array(lines.dropLast(2)), c.lines, c.name)
            XCTAssertTrue(lines.dropLast().last?.contains("[error] backstop agent: \(home.root.path)/Missing.app does not satisfy") == true, "\(c.name): \(lines)")
            XCTAssertEqual(lines.last, "", c.name)
        }
    }

    /// Running from a bundle pins that bundle; `swift run` falls back to the
    /// installed one so a development build still arms a verifiable agent.
    func testBundleIsTheRunningOneOrElseTheInstalledOne() {
        let running = URL(fileURLWithPath: "/Applications/Insomnia.app/", isDirectory: true)
        XCTAssertEqual(LaunchdBackstop.runningOrInstalledBundle(paths: home.paths, running: running).path, "/Applications/Insomnia.app")
        let debugBinary = URL(fileURLWithPath: "/x/.build/debug/Insomnia")
        XCTAssertEqual(LaunchdBackstop.runningOrInstalledBundle(paths: home.paths, running: debugBinary), home.paths.appBundle)
        XCTAssertEqual(home.paths.backstopScript.path, home.paths.appBundle.path + "/Contents/Resources/backstop.sh")
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
        XCTAssertEqual(plist["ProgramArguments"] as? [String], expectedArguments)
        XCTAssertEqual(try launchAgentsEntries(), ["com.insomnia.backstop.plist"], "candidate left next to the published plist")
    }

    /// Upgrading from the layout that ran a writable copy: the loaded agent
    /// polls at the right interval but runs the wrong thing, so it is stale.
    func testLegacyWritableCopyAgentIsReplacedByTheVerifyingOne() async throws {
        let b = try makeBackstop()
        try writeLegacyPollingPlist()
        loaded.value = true
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"])
        XCTAssertEqual(try plistOnDisk()["ProgramArguments"] as? [String], expectedArguments)
        XCTAssertTrue(loaded.value)
    }

    /// After an upgrade the bundle's requirement changes (a new ad-hoc
    /// cdhash). The plist pinning the previous build would make the agent
    /// refuse the new bundle, so the first arm() of the new build reloads it.
    func testAgentPinnedToAnotherBuildIsReloadedWithThisBuildsRequirement() async throws {
        let previous = try makeBackstop(requirement: "cdhash H\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"")
        try await previous.arm()
        XCTAssertTrue(loaded.value)
        calls.value = []

        let upgraded = try makeBackstop()
        try await upgraded.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["bootout", "bootstrap"], "a plist pinning another build is stale")
        XCTAssertEqual(try plistOnDisk()["ProgramArguments"] as? [String], expectedArguments)

        calls.value = []
        try await upgraded.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["print"], "once pinned to this build, arm() is a no-op")
    }

    /// An unsigned or unreadable bundle cannot be pinned, so no agent is
    /// written or loaded for it: a plist that can never verify would leave
    /// a session with an agent that always refuses.
    func testArmFailsBeforeTouchingLaunchdWhenTheBundleRequirementCannotBeRead() async throws {
        let b = try makeBackstop(requirementUnreadable: true)
        do {
            try await b.arm()
            XCTFail("arm succeeded without a requirement to pin")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("install.sh"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(home.paths.appBundle.path), error.localizedDescription)
        }
        XCTAssertEqual(calls.value, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.backstopPlist.path))
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
    /// The plist is current and launchd lists the job, but the bundle no
    /// longer passes the agent's check (its sealed script was edited after
    /// signing: the requirement still reads, the resource seal is broken,
    /// and the agent refuses every run). Reporting that as armed would let
    /// a session hold sleep behind an agent that never runs.
    func testArmFailsWhenTheLoadedAgentsBundleNoLongerPassesTheAgentsCheck() async throws {
        try await makeBackstop().arm()
        XCTAssertTrue(loaded.value)
        let trusted = try Data(contentsOf: home.paths.backstopPlist)
        calls.value = []

        let b = try makeBackstop(bundleFailsCheck: true)
        do {
            try await b.arm()
            XCTFail("arm reported an agent whose bundle fails verification as armed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sealed resource"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("install.sh"), error.localizedDescription)
        }
        XCTAssertEqual(calls.value, [], "nothing is asked of launchd: the plist is right, the bundle is wrong")
        XCTAssertEqual(try Data(contentsOf: home.paths.backstopPlist), trusted, "the trusted plist is left for the reinstall")
    }

    /// The plist on disk is this build's, but the loaded job runs another
    /// build's command line: install.sh stopped after its bootstrap and
    /// before it published its plist, or a job was loaded by hand from
    /// another plist with the label. That job verifies a bundle or
    /// requirement this build does not satisfy, so arm() reloads it from
    /// this build's plist.
    func testLoadedJobRunningAnotherBuildsCommandLineIsReloadedThoughThePlistIsCurrent() async throws {
        let b = try makeBackstop()
        try await b.arm()
        let trusted = try Data(contentsOf: home.paths.backstopPlist)
        loadedJob.value = ["/bin/sh", "-c", LaunchdBackstop.agentProgram, "sh", "cdhash H\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"", home.paths.appBundle.path]
        calls.value = []

        try await b.arm()

        XCTAssertEqual(calls.value.map { $0[1] }, ["print", "bootout", "bootstrap"], "a loaded label is not this build's agent")
        XCTAssertEqual(loadedJob.value, expectedArguments)
        XCTAssertEqual(try Data(contentsOf: home.paths.backstopPlist), trusted)

        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["print"], "the job now runs this build's command line")
    }

    /// The parser reads the arguments block and the run interval in the
    /// layout launchctl prints, with arguments holding spaces, quotes and `$`
    /// as the agent's do, and gives up on output it does not know rather
    /// than guess. `captured` is `launchctl print` of the agent an earlier
    /// install loaded on this Mac (2026-10-02), with the home directory
    /// replaced; `nonPolling` is the start of one for an Apple agent that
    /// has no StartInterval.
    func testLoadedJobIsReadFromLaunchctlsLayout() {
        XCTAssertEqual(
            LaunchdBackstop.loadedJob(fromPrint: Self.printOutput(arguments: expectedArguments, runInterval: 60)),
            LaunchdBackstop.LoadedJob(arguments: expectedArguments, runInterval: 60)
        )
        let captured = """
        gui/501/com.insomnia.backstop = {
        \tactive count = 0
        \tpath = /Users/tester/Library/LaunchAgents/com.insomnia.backstop.plist
        \ttype = LaunchAgent
        \tstate = not running

        \tprogram = /bin/bash
        \targuments = {
        \t\t/bin/bash
        \t\t/Users/tester/Library/Application Support/Insomnia/backstop.sh
        \t}

        \tinherited environment = {
        \t\tSSH_AUTH_SOCK => /private/tmp/com.apple.launchd.0teygTyWhX/Listeners
        \t}

        \tdefault environment = {
        \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
        \t}

        \tenvironment = {
        \t\tOSLogRateLimit => 64
        \t\tXPC_SERVICE_NAME => com.insomnia.backstop
        \t}

        \tdomain = gui/501 [100022]
        \tasid = 100022
        \tminimum runtime = 10
        \texit timeout = 5
        \truns = 22
        \tlast exit code = 0

        \tresource coalition = {
        \t\tID = 939
        \t\ttype = resource
        \t\tstate = active
        \t\tactive count = 1
        \t\tname = com.insomnia.backstop
        \t}

        \tspawn type = daemon (3)
        \tjetsam priority = 40
        \tcpumon = default
        \trun interval = 60 seconds

        \tproperties = runatload | inferred program | managed LWCR | has LWCR
        }

        """
        XCTAssertEqual(
            LaunchdBackstop.loadedJob(fromPrint: captured),
            LaunchdBackstop.LoadedJob(arguments: ["/bin/bash", "/Users/tester/Library/Application Support/Insomnia/backstop.sh"], runInterval: 60)
        )
        let nonPolling = "gui/501/com.apple.webkit.webpushd = {\n\tactive count = 0\n\tpath = /System/Volumes/Preboot/Cryptexes/App/System/Library/LaunchAgents/com.apple.webkit.webpushd.plist\n\ttype = LaunchAgent\n\tstate = not running\n\n\tprogram = /System/Cryptexes/App/usr/libexec/webpushd\n\targuments = {\n\t\t/System/Cryptexes/App/usr/libexec/webpushd\n\t\t--machServiceName\n\t\tcom.apple.webkit.webpushd.service\n\t}\n\n\tstderr path = /dev/null\n"
        XCTAssertEqual(
            LaunchdBackstop.loadedJob(fromPrint: nonPolling),
            LaunchdBackstop.LoadedJob(arguments: ["/System/Cryptexes/App/usr/libexec/webpushd", "--machServiceName", "com.apple.webkit.webpushd.service"], runInterval: nil)
        )
        XCTAssertEqual(
            LaunchdBackstop.loadedJob(fromPrint: "x = {\n\targuments = {\n\t\t/bin/sh\n\t}\n\trun interval = 1 minute\n}\n")?.runInterval, .some(nil),
            "an interval in another form reads as none"
        )
        XCTAssertNil(LaunchdBackstop.loadedJob(fromPrint: "gui/501/com.insomnia.backstop = {\n\tprogram = /bin/sh\n\trun interval = 60 seconds\n}\n"), "no arguments block")
        XCTAssertNil(LaunchdBackstop.loadedJob(fromPrint: "x = {\n\targuments = {\n\t\t/bin/sh\n"), "no closing line")
        XCTAssertNil(LaunchdBackstop.loadedJob(fromPrint: "x = {\n\targuments = {\n\t\t/bin/sh\n\tprogram = /bin/sh\n\t}\n}\n"), "a line that is not an argument")
        XCTAssertNil(LaunchdBackstop.loadedJob(fromPrint: "x = {\n\targuments = {\n\t\t/bin/sh\n\t}\n\targuments = {\n\t\t/bin/zsh\n\t}\n}\n"), "two arguments blocks")
    }

    /// The plist on disk is this build's and the loaded job runs its command
    /// line, but launchd starts that job only at load: it was loaded from a
    /// plist without the StartInterval (an older layout, or one written by
    /// hand). Once its first run is over nothing runs the backstop again, so
    /// a session would hold sleep with no agent to end it. arm() reloads it.
    func testLoadedJobWithoutThePollIntervalIsReloadedThoughItsCommandLineMatches() async throws {
        let b = try makeBackstop()
        try await b.arm()
        loadedInterval.value = nil
        calls.value = []

        try await b.arm()

        XCTAssertEqual(calls.value.map { $0[1] }, ["print", "bootout", "bootstrap"], "a job that does not poll is not armed")
        XCTAssertEqual(loadedInterval.value, 60)

        loadedInterval.value = 3600
        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["print", "bootout", "bootstrap"], "nor one that polls once an hour")

        calls.value = []
        try await b.arm()
        XCTAssertEqual(calls.value.map { $0[1] }, ["print"])
    }

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
