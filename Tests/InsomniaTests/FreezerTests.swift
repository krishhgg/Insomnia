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

    let spotify = RunningApp(pid: 600, bundleId: "com.spotify.client", name: "Spotify")
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
        c.freezeAllApps = true
        c.freezeList = ["com.tinyspeck.slackmacgap"]
        XCTAssertEqual(scope(c, apps + [spotify, figma]), ["com.tinyspeck.slackmacgap", "com.figma.Desktop", "com.spotify.client"])
    }

    func testLidCloseScopeExcludesAccessoryAndProhibitedApps() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        XCTAssertEqual(scope(c, [spotify, bartender, daemon]), ["com.spotify.client"])
    }

    func testLidCloseScopeExcludesAppsWithoutBundleId() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        XCTAssertEqual(scope(c, [nameless, spotify]), ["com.spotify.client"])
    }

    func testLidCloseScopeExcludesApple() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        XCTAssertEqual(scope(c, [RunningApp(pid: 200, bundleId: "com.apple.Safari", name: "Safari"), RunningApp(pid: 201, bundleId: "com.apple.Notes", name: "Notes")]), [])
    }

    func testLidCloseScopeExcludesSelf() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        XCTAssertEqual(scope(c, [RunningApp(pid: 300, bundleId: Paths.bundleIdentifier, name: "Insomnia")]), [])
        let other = RunningApp(pid: 301, bundleId: "dev.other.insomnia", name: "Insomnia")
        XCTAssertEqual(FreezePlanner.lidCloseBundleIds(config: c, apps: [other], selfBundleId: "dev.other.insomnia"), [])
        XCTAssertEqual(FreezePlanner.lidCloseBundleIds(config: c, apps: [other], selfBundleId: "x.y"), ["dev.other.insomnia"])
    }

    func testLidCloseScopeExcludesDockerDesktop() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        c.agentList = []
        let desktopUI = RunningApp(pid: 401, bundleId: "com.electron.dockerdesktop", name: "Docker Desktop")
        XCTAssertEqual(scope(c, [RunningApp(pid: 400, bundleId: "com.docker.docker", name: "Docker"), desktopUI]), [])
    }

    func testLidCloseScopeExcludesAgentListEvenWhenOnFreezeList() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = ["com.spotify.client"]
        c.agentList = ["com.spotify.client"]
        let ids = scope(c, [spotify, figma])
        XCTAssertEqual(ids.filter { $0 != "com.spotify.client" }, ["com.figma.Desktop"], "an agent must never be an automatic candidate")
        let procs = processes + [ProcessEntry(pid: 600, ppid: 1, startedAt: 6000), ProcessEntry(pid: 700, ppid: 1, startedAt: 7000)]
        let groups = FreezePlanner.groups(bundleIds: ids, apps: apps + [spotify, figma], processes: procs, config: c)
        XCTAssertEqual(groups.map(\.bundleId), ["com.figma.Desktop"], "the hard denylist wins over an explicit entry")
    }

    func testBuiltInProtectedIsExcludedAutomaticallyButIncludedWhenOnFreezeList() {
        XCTAssertTrue(FreezePlanner.builtInProtected.contains("com.openai.codex"))
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        c.agentList = []
        XCTAssertEqual(scope(c, [chatGPT, spotify]), ["com.spotify.client"])
        c.freezeList = ["com.openai.codex"]
        XCTAssertEqual(scope(c, [chatGPT, spotify]), ["com.openai.codex", "com.spotify.client"])
    }

    func testBuiltInProtectedCoversVerifiedIdsAndNoneIsApple() {
        for id in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
                   "com.exafunction.windsurf", "dev.zed.Zed", "com.google.antigravity", "com.google.antigravity-ide",
                   "com.google.android.studio", "com.sublimetext.4", "com.panic.Nova", "com.anthropic.claudefordesktop",
                   "com.openai.codex", "com.conductor.app", "com.t3tools.t3code", "com.t3tools.t3code.reasoning",
                   "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.googlecode.iterm2", "org.alacritty",
                   "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.tabby", "co.zeit.hyper",
                   "company.thebrowser.Browser", "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
                   "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox",
                   "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
                   "io.tailscale.ipn.macsys", "ai.elementlabs.lmstudio", "com.electron.ollama", "com.electron.dockerdesktop",
                   "com.1password.1password", "com.bitwarden.desktop", "com.postgresapp.Postgres2", "dev.kdrag0n.MacVirt"] {
            XCTAssertTrue(FreezePlanner.isBuiltInProtected(id), id)
        }
        XCTAssertFalse(FreezePlanner.isBuiltInProtected("dev.orbstack.OrbStack"), "OrbStack's real id is dev.kdrag0n.MacVirt; the guessed one must not linger")
        XCTAssertFalse(FreezePlanner.builtInProtected.contains { $0.hasPrefix("com.apple.") })
        XCTAssertFalse(FreezePlanner.builtInProtectedPrefixes.contains { $0.hasPrefix("com.apple.") })
    }

    /// JetBrains ships one bundle id per product under `com.jetbrains.`;
    /// the prefix covers all of them, and only them.
    func testJetBrainsIDEsAreProtectedByPrefix() {
        for id in ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
                   "com.jetbrains.WebStorm", "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider",
                   "com.jetbrains.PhpStorm", "com.jetbrains.rubymine", "com.jetbrains.datagrip"] {
            XCTAssertTrue(FreezePlanner.isBuiltInProtected(id), id)
        }
        XCTAssertFalse(FreezePlanner.isBuiltInProtected("com.jetbrainsfan.app"))
        XCTAssertFalse(FreezePlanner.isBuiltInProtected("com.jetbrains"))
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        c.agentList = []
        let idea = RunningApp(pid: 1100, bundleId: "com.jetbrains.intellij", name: "IntelliJ IDEA")
        XCTAssertEqual(scope(c, [idea, spotify]), ["com.spotify.client"])
        c.freezeList = ["com.jetbrains.intellij"]
        XCTAssertEqual(scope(c, [idea, spotify]), ["com.jetbrains.intellij", "com.spotify.client"], "an explicit entry overrides the prefix")
    }

    /// Meeting, recording and dictation apps and their helper apps are
    /// never automatic candidates, whatever their policy. The ids are
    /// pinned: each is read from an installed app or cited in Freezer.swift.
    func testMeetingAppsAndTheirHelpersAreProtected() {
        XCTAssertEqual(FreezePlanner.meetingApps, [
            "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark", "com.cisco.washost",
            "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "com.webex.pluginagent", "com.electron.wispr-flow",
            "com.granola.app", "com.otterai.desktop", "com.obsproject.obs-studio", "com.loom.desktop",
        ])
        XCTAssertTrue(FreezePlanner.meetingApps.isSubset(of: FreezePlanner.builtInProtected))
        let helpers = ["us.zoom.CptHost", "us.zoom.ZoomCefHelper", "us.zoom.caphost", "us.zoom.aomhost",
                       "com.electron.wispr-flow.helper", "com.electron.wispr-flow.accessibility-mac-app",
                       "com.obsproject.obs-studio.helper.gpu", "com.cisco.webex.CaptureHost", "com.microsoft.teams2.helper",
                       "Cisco-Systems.Spark.helper", "com.granola.app.helper", "com.loom.desktop.helper", "com.otterai.desktop.helper"]
        for id in FreezePlanner.meetingApps.sorted() + helpers {
            XCTAssertTrue(FreezePlanner.isBuiltInProtected(id), id)
        }
        // The prefixes end at a label boundary: look-alikes stay freezable.
        for id in ["us.zoomer.app", "com.electron.wispr-flowchart", "com.loom.desktopapp", "com.granola.application", "com.webex.other"] {
            XCTAssertFalse(FreezePlanner.isBuiltInProtected(id), id)
        }

        var c = Config()
        c.freezeAllApps = true
        c.freezeList = []
        c.agentList = []
        var pid: Int32 = 2000
        let running = (FreezePlanner.meetingApps.sorted() + helpers + ["com.apple.FaceTime"]).map { id -> RunningApp in
            pid += 1
            return RunningApp(pid: pid, bundleId: id, name: id)
        }
        XCTAssertEqual(scope(c, running + [spotify]), ["com.spotify.client"], "only the ordinary Dock app is a candidate")
        // FaceTime is an Apple app: the hard denylist covers it, even as an
        // explicit entry. Other meeting apps follow the protected set: an
        // explicit entry overrides it.
        XCTAssertTrue(FreezePlanner.isDenied("com.apple.FaceTime", config: c))
        c.freezeList = ["us.zoom.xos"]
        XCTAssertEqual(scope(c, running + [spotify]), ["us.zoom.xos", "com.spotify.client"])
    }

    /// A fresh config does not opt in to the automatic scope: with Dock
    /// apps running, the lid-close scope is the freeze list alone.
    func testLidCloseScopeIsTheFreezeListOnlyByDefault() {
        let c = Config()
        XCTAssertFalse(c.freezeAllApps)
        XCTAssertEqual(scope(c, apps + [spotify, figma]), Config.defaultFreezeList)
        XCTAssertEqual(FreezePlanner.automaticCandidates(config: c, apps: apps + [spotify, figma]), [])
    }

    func testLidCloseScopeIsExplicitFirstThenAlphabeticalByName() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = ["net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap"]
        let arq = RunningApp(pid: 1000, bundleId: "com.haystack.arq", name: "arq")
        let todoist = RunningApp(pid: 1001, bundleId: "com.todoist.mac.Todoist", name: "todoist")
        XCTAssertEqual(
            scope(c, [todoist, spotify, apps[0], figma, arq]),
            ["net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap", "com.haystack.arq", "com.figma.Desktop", "com.spotify.client", "com.todoist.mac.Todoist"]
        )
    }

    func testLidCloseScopeMergesDuplicates() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = ["com.figma.Desktop", "com.figma.Desktop", "com.tinyspeck.slackmacgap"]
        let second = RunningApp(pid: 601, bundleId: "com.spotify.client", name: "Spotify")
        let figmaAgain = RunningApp(pid: 701, bundleId: "com.figma.Desktop", name: "Figma")
        XCTAssertEqual(scope(c, [figma, spotify, second, figmaAgain]), ["com.figma.Desktop", "com.tinyspeck.slackmacgap", "com.spotify.client"])
    }

    func testLidCloseScopeWithToggleOffIsTheFreezeListOnly() {
        var c = Config()
        c.freezeAllApps = false
        c.freezeList = ["com.tinyspeck.slackmacgap", "com.hnc.Discord"]
        XCTAssertEqual(scope(c, apps + [spotify, figma]), ["com.tinyspeck.slackmacgap", "com.hnc.Discord"])
    }

    /// `plan(config:)` is the lid-close scope turned into process groups.
    func testFakeFreezerPlanConfigCoversTheLidCloseScope() {
        var c = Config()
        c.freezeAllApps = true
        c.freezeList = ["com.tinyspeck.slackmacgap"]
        let procs = processes + [ProcessEntry(pid: 600, ppid: 1, startedAt: 6000), ProcessEntry(pid: 900, ppid: 1, startedAt: 9000)]
        let f = FakeFreezer(apps: apps + [spotify, bartender], processes: procs, control: FakeProcessControl())
        XCTAssertEqual(f.plan(config: c).map(\.bundleId), ["com.tinyspeck.slackmacgap", "com.spotify.client"])
        c.freezeAllApps = false
        XCTAssertEqual(f.plan(config: c).map(\.bundleId), ["com.tinyspeck.slackmacgap"])
    }
}
