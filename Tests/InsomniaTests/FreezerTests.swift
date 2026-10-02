import AppKit
import XCTest
@testable import Insomnia

final class FreezerTests: XCTestCase {
    // Slack main (100) with helpers 101, 102 (child of 101), 103; an unrelated
    // process 200 under launchd; Insomnia itself at 300.
    let processes: [ProcessEntry] = [
        ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
        ProcessEntry(pid: 100, ppid: 1, startedAt: 1000),
        ProcessEntry(pid: 101, ppid: 100, startedAt: 1001),
        ProcessEntry(pid: 102, ppid: 101, startedAt: 1002),
        ProcessEntry(pid: 103, ppid: 100, startedAt: 1003),
        ProcessEntry(pid: 200, ppid: 1, startedAt: 2000),
        ProcessEntry(pid: 300, ppid: 1, startedAt: 3000),
        ProcessEntry(pid: 400, ppid: 1, startedAt: 4000),
        ProcessEntry(pid: 401, ppid: 400, startedAt: 4001),
    ]
    let apps: [RunningApp] = [
        RunningApp(pid: 100, bundleId: "com.tinyspeck.slackmacgap", name: "Slack"),
        RunningApp(pid: 200, bundleId: "com.apple.Safari", name: "Safari"),
        RunningApp(pid: 300, bundleId: Paths.bundleIdentifier, name: "Insomnia"),
        RunningApp(pid: 400, bundleId: "com.docker.docker", name: "Docker"),
    ]

    func testTreeIncludesMainAndAllHelpersOnly() {
        XCTAssertEqual(FreezePlanner.tree(root: 100, in: processes), [100, 101, 103, 102])
        XCTAssertEqual(FreezePlanner.tree(root: 200, in: processes), [200])
    }

    func testGroupsMainPlusHelpersExcludingUnrelated() {
        let groups = FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap"], apps: apps, processes: processes, config: Config())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(groups[0].name, "Slack")
        XCTAssertEqual(Set(groups[0].pids), [100, 101, 102, 103])
        XCTAssertEqual(groups[0].expectedParents, [100: 1, 101: 100, 102: 101, 103: 100])
        XCTAssertFalse(groups[0].pids.contains(200))
    }

    func testNotRunningAppYieldsNoGroup() {
        let groups = FreezePlanner.groups(bundleIds: ["net.whatsapp.WhatsApp"], apps: apps, processes: processes, config: Config())
        XCTAssertTrue(groups.isEmpty)
    }

    func testDenylistApple() {
        XCTAssertTrue(FreezePlanner.isDenied("com.apple.Safari", config: Config()))
        XCTAssertTrue(FreezePlanner.isDenied("com.apple.finder", config: Config()))
        XCTAssertFalse(FreezePlanner.isDenied("com.tinyspeck.slackmacgap", config: Config()))
    }

    func testDenylistSelf() {
        XCTAssertTrue(FreezePlanner.isDenied(Paths.bundleIdentifier, config: Config()))
        XCTAssertTrue(FreezePlanner.isDenied("dev.other.insomnia", config: Config(), selfBundleId: "dev.other.insomnia"))
    }

    func testDenylistDocker() {
        var c = Config()
        c.agentList = []
        XCTAssertTrue(FreezePlanner.isDenied("com.docker.docker", config: c))
        let denied = FreezePlanner.groups(bundleIds: ["com.docker.docker"], apps: apps, processes: processes, config: c)
        XCTAssertTrue(denied.isEmpty)
        let bypassed = FreezePlanner.groups(bundleIds: ["com.docker.docker"], apps: apps, processes: processes, config: c, applyDenylist: false)
        XCTAssertEqual(bypassed.map(\.pids), [[400, 401]])
    }

    func testDenylistAgentListOverridesFreezeList() {
        var c = Config()
        c.agentList = ["com.tinyspeck.slackmacgap"]
        XCTAssertTrue(FreezePlanner.isDenied("com.tinyspeck.slackmacgap", config: c))
        XCTAssertTrue(FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap"], apps: apps, processes: processes, config: c).isEmpty)

        c.agentList = []
        XCTAssertFalse(FreezePlanner.isDenied("com.tinyspeck.slackmacgap", config: c))
        XCTAssertEqual(FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap"], apps: apps, processes: processes, config: c).count, 1)
    }

    func testDeniedIdsAreSkippedInMixedList() {
        let groups = FreezePlanner.groups(
            bundleIds: ["com.apple.Safari", Paths.bundleIdentifier, "com.docker.docker", "com.tinyspeck.slackmacgap"],
            apps: apps, processes: processes, config: Config()
        )
        XCTAssertEqual(groups.map(\.bundleId), ["com.tinyspeck.slackmacgap"])
    }

    func testDuplicateBundleIdsAndInstancesAreMergedOnce() {
        let two = apps + [RunningApp(pid: 500, bundleId: "com.tinyspeck.slackmacgap", name: "Slack")]
        let procs = processes + [ProcessEntry(pid: 500, ppid: 1, startedAt: 5000), ProcessEntry(pid: 501, ppid: 500, startedAt: 5001)]
        let groups = FreezePlanner.groups(bundleIds: ["com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap"], apps: two, processes: procs, config: Config())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].pids), [100, 101, 102, 103, 500, 501])
    }

    func testSuspendAndResumeSignalsGoToProcessControl() {
        let control = FakeProcessControl()
        let f = FakeFreezer(apps: apps, processes: processes, control: control)
        let frozen = [FrozenProcess(pid: 100, startedAt: 1000), FrozenProcess(pid: 101, startedAt: 1001)]
        _ = f.suspend(frozen, expectedParents: [100: 1, 101: 100])
        _ = f.resume(frozen)
        XCTAssertEqual(control.suspended, [[100, 101]])
        XCTAssertEqual(control.resumed, [[100, 101]])
    }

    func testSignalFiltersUseCurrentParentAndStoppedState() {
        let states: [Int32: ProcessSignalState] = [
            100: ProcessSignalState(ppid: 1, stopped: false, startedAt: 1000),
            101: ProcessSignalState(ppid: 999, stopped: true, startedAt: 1001),
            102: ProcessSignalState(ppid: 100, stopped: true, startedAt: 1002),
            103: ProcessSignalState(ppid: 100, stopped: false, startedAt: 1003),
        ]
        let lookup: SignalProcessControl.StateLookup = { states[$0].map(ProcessLookup.present) ?? .absent }
        let frozen = [
            FrozenProcess(pid: 100, startedAt: 1000),
            FrozenProcess(pid: 101, startedAt: 1001),
            FrozenProcess(pid: 103, startedAt: 1003),
            FrozenProcess(pid: 404, startedAt: 4040),
        ]

        // 100 and 103 run under the expected parent; 101 is reparented and
        // 404 is gone. 102 is already stopped, so it is not a candidate.
        XCTAssertEqual(
            SignalProcessControl.suspendable(
                frozen,
                expectedParents: [100: 1, 101: 100, 103: 100, 404: 100],
                stateLookup: lookup
            ),
            [100, 103]
        )
        let plan = SignalProcessControl.resumePlan(
            [FrozenProcess(pid: 101, startedAt: 1001), FrozenProcess(pid: 102, startedAt: 1002),
             FrozenProcess(pid: 103, startedAt: 1003), FrozenProcess(pid: 404, startedAt: 4040)],
            stateLookup: lookup
        )
        XCTAssertEqual(plan.signal, [101, 102])
        XCTAssertEqual(plan.gone, [103, 404])
    }

    // MARK: Lid-close scope (freeze every other app)

    let wispr = RunningApp(pid: 600, bundleId: "com.electron.wispr-flow", name: "Wispr Flow")
    let figma = RunningApp(pid: 700, bundleId: "com.figma.Desktop", name: "Figma")
    let chatGPT = RunningApp(pid: 800, bundleId: "com.openai.codex", name: "ChatGPT")
    let bartender = RunningApp(pid: 900, bundleId: "com.surteesstudios.Bartender", name: "Bartender", activationPolicy: .accessory)
    let daemon = RunningApp(pid: 950, bundleId: "com.example.daemon", name: "Daemon", activationPolicy: .prohibited)
    let nameless = RunningApp(pid: 960, bundleId: nil, name: "Nameless")

    private func scope(_ config: Config, _ apps: [RunningApp]) -> [String] {
        FreezePlanner.lidCloseBundleIds(config: config, apps: apps)
    }

    func testRunningAppDefaultsToRegular() {
        XCTAssertEqual(RunningApp(pid: 1, bundleId: "a.b", name: "A").activationPolicy, .regular)
        XCTAssertEqual(RunningApp.ActivationPolicy(NSApplication.ActivationPolicy.regular), .regular)
        XCTAssertEqual(RunningApp.ActivationPolicy(NSApplication.ActivationPolicy.accessory), .accessory)
        XCTAssertEqual(RunningApp.ActivationPolicy(NSApplication.ActivationPolicy.prohibited), .prohibited)
    }

    func testLidCloseScopeIncludesRegularAppsThatAreNotDenied() {
        var c = Config()
        c.freezeList = ["com.tinyspeck.slackmacgap"]
        XCTAssertEqual(scope(c, apps + [wispr, figma]), ["com.tinyspeck.slackmacgap", "com.figma.Desktop", "com.electron.wispr-flow"])
    }

    func testLidCloseScopeExcludesAccessoryAndProhibitedApps() {
        var c = Config()
        c.freezeList = []
        XCTAssertEqual(scope(c, [wispr, bartender, daemon]), ["com.electron.wispr-flow"])
    }

    func testLidCloseScopeExcludesAppsWithoutBundleId() {
        var c = Config()
        c.freezeList = []
        XCTAssertEqual(scope(c, [nameless, wispr]), ["com.electron.wispr-flow"])
    }

    func testLidCloseScopeExcludesApple() {
        var c = Config()
        c.freezeList = []
        XCTAssertEqual(scope(c, [RunningApp(pid: 200, bundleId: "com.apple.Safari", name: "Safari"), RunningApp(pid: 201, bundleId: "com.apple.Notes", name: "Notes")]), [])
    }

    func testLidCloseScopeExcludesSelf() {
        var c = Config()
        c.freezeList = []
        XCTAssertEqual(scope(c, [RunningApp(pid: 300, bundleId: Paths.bundleIdentifier, name: "Insomnia")]), [])
        let other = RunningApp(pid: 301, bundleId: "dev.other.insomnia", name: "Insomnia")
        XCTAssertEqual(FreezePlanner.lidCloseBundleIds(config: c, apps: [other], selfBundleId: "dev.other.insomnia"), [])
        XCTAssertEqual(FreezePlanner.lidCloseBundleIds(config: c, apps: [other], selfBundleId: "x.y"), ["dev.other.insomnia"])
    }

    func testLidCloseScopeExcludesDockerDesktop() {
        var c = Config()
        c.freezeList = []
        c.agentList = []
        let desktopUI = RunningApp(pid: 401, bundleId: "com.electron.dockerdesktop", name: "Docker Desktop")
        XCTAssertEqual(scope(c, [RunningApp(pid: 400, bundleId: "com.docker.docker", name: "Docker"), desktopUI]), [])
    }

    func testLidCloseScopeExcludesAgentListEvenWhenOnFreezeList() {
        var c = Config()
        c.freezeList = ["com.electron.wispr-flow"]
        c.agentList = ["com.electron.wispr-flow"]
        let ids = scope(c, [wispr, figma])
        XCTAssertEqual(ids.filter { $0 != "com.electron.wispr-flow" }, ["com.figma.Desktop"], "an agent must never be an automatic candidate")
        let procs = processes + [ProcessEntry(pid: 600, ppid: 1, startedAt: 6000), ProcessEntry(pid: 700, ppid: 1, startedAt: 7000)]
        let groups = FreezePlanner.groups(bundleIds: ids, apps: apps + [wispr, figma], processes: procs, config: c)
        XCTAssertEqual(groups.map(\.bundleId), ["com.figma.Desktop"], "the hard denylist wins over an explicit entry")
    }

    func testBuiltInProtectedIsExcludedAutomaticallyButIncludedWhenOnFreezeList() {
        XCTAssertTrue(FreezePlanner.builtInProtected.contains("com.openai.codex"))
        var c = Config()
        c.freezeList = []
        c.agentList = []
        XCTAssertEqual(scope(c, [chatGPT, wispr]), ["com.electron.wispr-flow"])
        c.freezeList = ["com.openai.codex"]
        XCTAssertEqual(scope(c, [chatGPT, wispr]), ["com.openai.codex", "com.electron.wispr-flow"])
    }

    func testBuiltInProtectedCoversVerifiedIdsAndNoneIsApple() {
        for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.anthropic.claudefordesktop",
                   "io.tailscale.ipn.macsys", "ai.elementlabs.lmstudio", "com.electron.ollama", "com.t3tools.t3code",
                   "com.mitchellh.ghostty", "company.thebrowser.Browser", "com.google.Chrome"] {
            XCTAssertTrue(FreezePlanner.builtInProtected.contains(id), id)
        }
        XCTAssertFalse(FreezePlanner.builtInProtected.contains { $0.hasPrefix("com.apple.") })
    }

    func testLidCloseScopeIsExplicitFirstThenAlphabeticalByName() {
        var c = Config()
        c.freezeList = ["net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap"]
        let arq = RunningApp(pid: 1000, bundleId: "com.haystack.arq", name: "arq")
        let zoom = RunningApp(pid: 1001, bundleId: "us.zoom.xos", name: "zoom.us")
        XCTAssertEqual(
            scope(c, [zoom, wispr, apps[0], figma, arq]),
            ["net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap", "com.haystack.arq", "com.figma.Desktop", "com.electron.wispr-flow", "us.zoom.xos"]
        )
    }

    func testLidCloseScopeMergesDuplicates() {
        var c = Config()
        c.freezeList = ["com.figma.Desktop", "com.figma.Desktop", "com.tinyspeck.slackmacgap"]
        let second = RunningApp(pid: 601, bundleId: "com.electron.wispr-flow", name: "Wispr Flow")
        let figmaAgain = RunningApp(pid: 701, bundleId: "com.figma.Desktop", name: "Figma")
        XCTAssertEqual(scope(c, [figma, wispr, second, figmaAgain]), ["com.figma.Desktop", "com.tinyspeck.slackmacgap", "com.electron.wispr-flow"])
    }

    func testLidCloseScopeWithToggleOffIsTheFreezeListOnly() {
        var c = Config()
        c.freezeAllApps = false
        c.freezeList = ["com.tinyspeck.slackmacgap", "com.hnc.Discord"]
        XCTAssertEqual(scope(c, apps + [wispr, figma]), ["com.tinyspeck.slackmacgap", "com.hnc.Discord"])
    }

    /// `plan(config:)` is the lid-close scope turned into process groups.
    func testFakeFreezerPlanConfigCoversTheLidCloseScope() {
        var c = Config()
        c.freezeList = ["com.tinyspeck.slackmacgap"]
        let procs = processes + [ProcessEntry(pid: 600, ppid: 1, startedAt: 6000), ProcessEntry(pid: 900, ppid: 1, startedAt: 9000)]
        let f = FakeFreezer(apps: apps + [wispr, bartender], processes: procs, control: FakeProcessControl())
        XCTAssertEqual(f.plan(config: c).map(\.bundleId), ["com.tinyspeck.slackmacgap", "com.electron.wispr-flow"])
        c.freezeAllApps = false
        XCTAssertEqual(f.plan(config: c).map(\.bundleId), ["com.tinyspeck.slackmacgap"])
    }
}
