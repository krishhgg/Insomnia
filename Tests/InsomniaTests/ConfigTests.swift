import XCTest
@testable import Insomnia

final class ConfigTests: XCTestCase {
    /// `Config()` as a config.json from an earlier build decodes without the
    /// key under test: no lid-close update yet, and a missing mute key read
    /// as off, as those builds read it.
    private func earlierBuild() -> Config {
        var c = Config()
        c.lidCloseDefaultsApplied = false
        c.muteOnLidClose = false
        return c
    }

    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.presets, [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200])
        XCTAssertEqual(c.lowPowerFloor, 40)
        XCTAssertEqual(c.endFloor, 10)
        XCTAssertEqual(c.nudgeThreshold, 90)
        XCTAssertEqual(c.maxDuration, 30 * 24 * 3600)
        XCTAssertEqual(c.freezeList, ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.hnc.Discord"])
        XCTAssertTrue(c.agentList.contains("com.apple.Terminal"))
        XCTAssertTrue(c.agentList.contains("com.t3tools.t3code"))
        XCTAssertTrue(c.agentList.contains("com.docker.docker"))
        XCTAssertTrue(c.agentList.contains("com.microsoft.VSCode"))
        XCTAssertTrue(c.agentList.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(c.agentList.contains("io.tailscale.ipn.macsys"))
        XCTAssertTrue(c.dockerRule)
        XCTAssertTrue(c.muteOnLidClose, "mute on lid close is on by default")
        XCTAssertTrue(c.lidCloseDefaultsApplied, "a config this build creates never needs the lid-close update")
        XCTAssertNil(c.lidCloseDefaultsNotice)
        XCTAssertTrue(c.darkenDisplayOnLidClose)
        XCTAssertFalse(c.freezeAllApps, "freeze-all is opt in")
        XCTAssertTrue(c.lowPowerOnLidClose)
        XCTAssertTrue(c.thermalRules)
        XCTAssertFalse(c.disableAppNapForAgents, "writing other apps' preferences is opt-in")
        XCTAssertEqual(c.hotspotSSID, "")
        XCTAssertEqual(c.tmuxTargets, [])
        XCTAssertFalse(c.tmuxNudgePressesEnter)
        XCTAssertFalse(c.launchAtLogin)
    }

    /// Enter after `continue` is opt-in: a config.json written before the
    /// key existed, or without it, keeps it off; an explicit true is honoured.
    func testTmuxNudgePressesEnterDecodesAndDefaultsOff() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"tmuxTargets": ["agents:0.0"]}"#.utf8))
        XCTAssertFalse(legacy.tmuxNudgePressesEnter)
        XCTAssertEqual(legacy.tmuxTargets, ["agents:0.0"])
        let on = try Store.makeDecoder().decode(Config.self, from: Data(#"{"tmuxNudgePressesEnter": true}"#.utf8))
        XCTAssertTrue(on.tmuxNudgePressesEnter)
        var expected = earlierBuild()
        expected.tmuxNudgePressesEnter = true
        XCTAssertEqual(on, expected)
        let data = try Store.makeEncoder().encode(on)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), on)
    }

    // MARK: Battery floors

    func testDefaultFloorsAreOrdered() {
        XCTAssertTrue(Config().floorsAreOrdered)
        XCTAssertEqual(Config.floorStep, 5)
        XCTAssertEqual(Config.maxEndFloor, 95)
    }

    /// Raising the end floor onto or past the Low Power Mode floor pushes
    /// that floor one step up; the end floor itself stops at 95.
    func testRaisingEndFloorPushesLowPowerFloorUp() {
        var c = Config()
        c.setEndFloor(35)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [40, 35])
        c.setEndFloor(40)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [45, 40])
        c.setEndFloor(70)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [75, 70])
        c.setEndFloor(100)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [100, 95])
        c.setEndFloor(-5)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [100, 0])
        XCTAssertTrue(c.floorsAreOrdered)
    }

    /// Lowering the Low Power Mode floor onto or past the end floor pulls
    /// the end floor one step down, to 0 (off) at the bottom.
    func testLoweringLowPowerFloorPullsEndFloorDown() {
        var c = Config()
        c.setLowPowerFloor(15)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [15, 10])
        c.setLowPowerFloor(10)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [10, 5])
        c.setLowPowerFloor(5)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [5, 0])
        c.setLowPowerFloor(0)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [0, 0])
        c.setLowPowerFloor(150)
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [100, 0])
        XCTAssertTrue(c.floorsAreOrdered)
    }

    /// An end floor of 0 is off and stays off wherever the other floor goes.
    func testEndFloorOffIsNotMovedByTheLowPowerFloor() {
        var c = Config()
        c.setEndFloor(0)
        for v in [100, 40, 5, 0] {
            c.setLowPowerFloor(v)
            XCTAssertEqual(c.endFloor, 0, "lowPowerFloor \(v)")
            XCTAssertTrue(c.floorsAreOrdered)
        }
    }

    /// Decoding keeps whatever the file says; normalization is a separate
    /// step that fixes the order by raising the Low Power Mode floor and
    /// reports the change.
    func testNormalizeFloorsCorrectsAnOutOfOrderFile() throws {
        var c = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lowPowerFloor": 40, "endFloor": 60}"#.utf8))
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [40, 60])
        XCTAssertFalse(c.floorsAreOrdered)

        let change = c.normalizeFloors()

        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [65, 60])
        XCTAssertEqual(change, "battery floors corrected: lowPowerFloor 40 -> 65, endFloor 60 -> 60")
        XCTAssertTrue(c.floorsAreOrdered)
    }

    func testNormalizeFloorsClampsOutOfRangeValues() {
        var c = Config()
        c.lowPowerFloor = 140
        c.endFloor = 100
        XCTAssertEqual(c.normalizeFloors(), "battery floors corrected: lowPowerFloor 140 -> 100, endFloor 100 -> 95")
        XCTAssertEqual([c.lowPowerFloor, c.endFloor], [100, 95])

        var d = Config()
        d.endFloor = -3
        XCTAssertEqual(d.normalizeFloors(), "battery floors corrected: lowPowerFloor 40 -> 40, endFloor -3 -> 0")
        XCTAssertEqual([d.lowPowerFloor, d.endFloor], [40, 0])

        var e = Config()
        e.lowPowerFloor = 40
        e.endFloor = 40
        XCTAssertEqual(e.normalizeFloors(), "battery floors corrected: lowPowerFloor 40 -> 45, endFloor 40 -> 40")
    }

    func testNormalizeFloorsLeavesAnOrderedConfigAlone() {
        for (low, end) in [(40, 10), (5, 0), (0, 0), (100, 95), (100, 0)] {
            var c = Config()
            c.lowPowerFloor = low
            c.endFloor = end
            XCTAssertNil(c.normalizeFloors(), "\(low)/\(end)")
            XCTAssertEqual([c.lowPowerFloor, c.endFloor], [low, end])
        }
    }

    func testPartialJSONFillsDefaults() throws {
        let data = Data(#"{"lowPowerFloor": 25}"#.utf8)
        let c = try Store.makeDecoder().decode(Config.self, from: data)
        var expected = earlierBuild()
        expected.lowPowerFloor = 25
        XCTAssertEqual(c, expected)
    }

    func testLowPowerOnLidCloseDecodesAndDefaultsOn() throws {
        let off = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lowPowerOnLidClose": false}"#.utf8))
        XCTAssertFalse(off.lowPowerOnLidClose)
        // A config written before the key existed keeps the default.
        let old = try Store.makeDecoder().decode(Config.self, from: Data(#"{"muteOnLidClose": true}"#.utf8))
        XCTAssertTrue(old.lowPowerOnLidClose)
        XCTAssertTrue(old.muteOnLidClose)
    }

    /// An empty object is what an earlier build saved minus every key. It
    /// decodes to the defaults as those builds read them, and the lid-close
    /// update then brings it to this build's defaults, reporting the mute.
    func testEmptyObjectIsDefaultsOnceUpdated() throws {
        var c = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(c, earlierBuild())
        XCTAssertEqual(c.applyLidCloseDefaults(), LidCloseDefaultsChange(turnedOffFreezeAll: false, turnedOnMute: true))
        c.lidCloseDefaultsNotice = nil
        XCTAssertEqual(c, Config())
    }

    /// A config.json this build saved carries the mark; a missing mute key
    /// there (a hand edit) gets this build's default, on.
    func testThisBuildsConfigWithoutMuteKeyIsMutedByDefault() throws {
        let c = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lidCloseDefaultsApplied": true}"#.utf8))
        XCTAssertEqual(c, Config())
        XCTAssertTrue(c.muteOnLidClose)
        let data = try Store.makeEncoder().encode(Config())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["lidCloseDefaultsApplied"] as? Bool, true, "the mark must reach config.json")
        XCTAssertEqual(json["muteOnLidClose"] as? Bool, true)
    }

    // MARK: Lid-close update

    /// The maintainer's config: freeze-all on (saved when it was the
    /// default) and mute off. Both change, once, and the notice is kept.
    func testLidCloseUpdateTurnsFreezeAllOffAndMuteOnOnce() throws {
        var c = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": true, "muteOnLidClose": false, "dockerRule": true}"#.utf8))
        XCTAssertFalse(c.lidCloseDefaultsApplied)
        let change = c.applyLidCloseDefaults()
        XCTAssertEqual(change, LidCloseDefaultsChange(turnedOffFreezeAll: true, turnedOnMute: true))
        XCTAssertFalse(c.freezeAllApps)
        XCTAssertTrue(c.muteOnLidClose)
        XCTAssertTrue(c.lidCloseDefaultsApplied)
        XCTAssertEqual(c.lidCloseDefaultsNotice, change)
        XCTAssertTrue(c.dockerRule, "nothing else changes")

        // The user turns both back: the update never runs again.
        c.freezeAllApps = true
        c.muteOnLidClose = false
        XCTAssertNil(c.applyLidCloseDefaults())
        XCTAssertTrue(c.freezeAllApps)
        XCTAssertFalse(c.muteOnLidClose)
        let reloaded = try Store.makeDecoder().decode(Config.self, from: Store.makeEncoder().encode(c))
        XCTAssertEqual(reloaded, c, "the mark and the notice round-trip")
    }

    /// Only what actually changes is reported; a config already set the new
    /// way is marked with no notice.
    func testLidCloseUpdateReportsOnlyWhatChanged() throws {
        var muteOnly = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": false, "muteOnLidClose": false}"#.utf8))
        XCTAssertEqual(muteOnly.applyLidCloseDefaults(), LidCloseDefaultsChange(turnedOffFreezeAll: false, turnedOnMute: true))
        var freezeOnly = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": true, "muteOnLidClose": true}"#.utf8))
        XCTAssertEqual(freezeOnly.applyLidCloseDefaults(), LidCloseDefaultsChange(turnedOffFreezeAll: true, turnedOnMute: false))
        var already = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": false, "muteOnLidClose": true}"#.utf8))
        XCTAssertNil(already.applyLidCloseDefaults())
        XCTAssertTrue(already.lidCloseDefaultsApplied)
        XCTAssertNil(already.lidCloseDefaultsNotice)
    }

    /// The notice names each change and where to change it back.
    func testLidCloseNoticeNamesTheChangesAndWhereToChangeThemBack() {
        let both = LidCloseDefaultsChange(turnedOffFreezeAll: true, turnedOnMute: true)
        XCTAssertEqual(LidCloseDefaultsChange.title, "Lid-close settings changed")
        XCTAssertEqual(both.notificationBody, "This update changed two lid-close settings: \"Freeze every other app while the lid is closed\" is now off and \"Mute audio on lid close\" is now on. To change them back, choose Settings\u{2026} from the Insomnia menu bar icon and look under Lid-close actions.")
        XCTAssertEqual(both.settingsLine, "This update changed two lid-close settings: \"Freeze every other app while the lid is closed\" is now off and \"Mute audio on lid close\" is now on. Both toggles are below.")
        let mute = LidCloseDefaultsChange(turnedOffFreezeAll: false, turnedOnMute: true)
        XCTAssertEqual(mute.notificationBody, "This update changed a lid-close setting: \"Mute audio on lid close\" is now on. To change it back, choose Settings\u{2026} from the Insomnia menu bar icon and look under Lid-close actions.")
        XCTAssertEqual(mute.settingsLine, "This update changed a lid-close setting: \"Mute audio on lid close\" is now on. The toggle is below.")
        let freeze = LidCloseDefaultsChange(turnedOffFreezeAll: true, turnedOnMute: false)
        XCTAssertEqual(freeze.changes, "\"Freeze every other app while the lid is closed\" is now off")
    }

    /// A config.json written before the display toggle existed keeps the
    /// default (on); an explicit false is honoured.
    func testDarkenDisplayDecodesTolerantly() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"muteOnLidClose": true}"#.utf8))
        XCTAssertTrue(legacy.darkenDisplayOnLidClose)
        let off = try Store.makeDecoder().decode(Config.self, from: Data(#"{"darkenDisplayOnLidClose": false}"#.utf8))
        XCTAssertFalse(off.darkenDisplayOnLidClose)
        var expected = earlierBuild()
        expected.darkenDisplayOnLidClose = false
        XCTAssertEqual(off, expected)
        let data = try Store.makeEncoder().encode(off)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), off)
    }

    /// A config.json without the freeze-all key (written before the toggle
    /// existed, or by hand) gets the default, off: nobody is opted in to the
    /// automatic scope by an upgrade. An explicit true is honoured.
    func testFreezeAllAppsDecodesTolerantly() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeList": ["com.hnc.Discord"]}"#.utf8))
        XCTAssertFalse(legacy.freezeAllApps, "a missing key must not opt the user in")
        XCTAssertEqual(legacy.freezeList, ["com.hnc.Discord"])
        let on = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": true}"#.utf8))
        XCTAssertTrue(on.freezeAllApps)
        var expected = earlierBuild()
        expected.freezeAllApps = true
        XCTAssertEqual(on, expected)
        let data = try Store.makeEncoder().encode(on)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), on)
        let off = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": false}"#.utf8))
        XCTAssertFalse(off.freezeAllApps)
    }

    /// A config.json written before the App Nap opt-in existed keeps the
    /// default (off); an explicit true is honoured and round-trips.
    func testDisableAppNapDecodesTolerantlyAndDefaultsOff() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"agentList": ["com.google.Chrome"]}"#.utf8))
        XCTAssertFalse(legacy.disableAppNapForAgents)
        XCTAssertEqual(legacy.agentList, ["com.google.Chrome"])
        let on = try Store.makeDecoder().decode(Config.self, from: Data(#"{"disableAppNapForAgents": true}"#.utf8))
        XCTAssertTrue(on.disableAppNapForAgents)
        var expected = earlierBuild()
        expected.disableAppNapForAgents = true
        XCTAssertEqual(on, expected)
        let data = try Store.makeEncoder().encode(on)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), on)
    }

    /// Cheap typo guard for the shipped defaults: no duplicates, and every
    /// id looks like a reverse-DNS bundle id with a lowercase first label.
    func testDefaultListsAreUniqueReverseDNSIds() throws {
        let pattern = #"^[a-z][a-z0-9-]*(\.[A-Za-z0-9_-]+)+$"#
        // Webex's real id starts with an uppercase label (read from the
        // installed app); it is the one exception.
        let uppercaseFirstLabel: Set<String> = ["Cisco-Systems.Spark"]
        for (name, ids) in [("agentList", Config.defaultAgentList), ("freezeList", Config.defaultFreezeList), ("builtInProtected", Array(FreezePlanner.builtInProtected))] {
            XCTAssertEqual(Set(ids).count, ids.count, "\(name) has duplicates")
            for id in ids where !uppercaseFirstLabel.contains(id) {
                XCTAssertNotNil(id.range(of: pattern, options: .regularExpression), "\(name): \(id) does not look like a bundle id")
            }
        }
        for prefix in FreezePlanner.builtInProtectedPrefixes {
            XCTAssertTrue(prefix.hasSuffix("."), "a protected prefix must end at a label boundary: \(prefix)")
            if uppercaseFirstLabel.contains(String(prefix.dropLast())) { continue }
            XCTAssertNotNil(String(prefix.dropLast()).range(of: pattern, options: .regularExpression), "builtInProtectedPrefixes: \(prefix) does not look like a bundle id prefix")
        }
    }

    func testRoundTrip() throws {
        var c = Config()
        c.hotspotSSID = "iPhone"
        c.tmuxTargets = ["main:0.1"]
        c.presets = [60]
        let data = try Store.makeEncoder().encode(c)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), c)
    }

    /// The install on file for the login item is absent in configs written
    /// before it existed, decodes as nil, and round-trips when set.
    func testLaunchAtLoginInstallIsOptional() throws {
        XCTAssertNil(Config().launchAtLoginInstall)
        let old = try Store.makeDecoder().decode(Config.self, from: Data(#"{"launchAtLogin": true}"#.utf8))
        XCTAssertTrue(old.launchAtLogin)
        XCTAssertNil(old.launchAtLoginInstall)

        var c = Config()
        c.launchAtLogin = true
        c.launchAtLoginInstall = "0b1c@/Users/me/Applications/Insomnia.app"
        let data = try Store.makeEncoder().encode(c)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), c)
    }
}

/// SessionManager normalizes the floors when it loads config.json.
@MainActor
final class ConfigLoadTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func log() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    func testOutOfOrderFloorsAreCorrectedLoggedAndWrittenBack() throws {
        var bad = Config()
        bad.lowPowerFloor = 40
        bad.endFloor = 60
        try h.store.saveConfig(bad)

        let m = h.makeManager()

        XCTAssertEqual([m.config.lowPowerFloor, m.config.endFloor], [65, 60])
        XCTAssertTrue(m.config.floorsAreOrdered)
        XCTAssertEqual(try h.store.loadConfig(), m.config, "the corrected config was not written back")
        XCTAssertTrue(log().contains("[info] insomnia: config.json: battery floors corrected: lowPowerFloor 40 -> 65, endFloor 60 -> 60; saved"), log())
    }

    /// When the corrected file cannot be written, the corrected floors still
    /// apply in memory and the log says the save failed instead of
    /// announcing a correction that did not reach the disk.
    func testUnsavableCorrectionIsLoggedAsAnError() throws {
        var bad = Config()
        bad.lowPowerFloor = 40
        bad.endFloor = 60
        try h.store.saveConfig(bad)
        // Store writes a temp file next to config.json; a read-only
        // directory refuses it. Under INSOMNIA_HOME the Logs directory sits
        // inside that directory, so it must exist before the chmod for the
        // log line to land.
        try h.home.paths.createDirectories()
        let dir = h.home.paths.appSupport.path
        XCTAssertEqual(chmod(dir, 0o500), 0)
        defer { chmod(dir, 0o700) }

        let m = h.makeManager()

        XCTAssertEqual([m.config.lowPowerFloor, m.config.endFloor], [65, 60])
        XCTAssertEqual(try h.store.loadConfig(), bad, "the file should be untouched when the write fails")
        let log = log()
        XCTAssertTrue(log.contains("[error] insomnia: config.json: battery floors corrected: lowPowerFloor 40 -> 65, endFloor 60 -> 60; could not save the correction: "), log)
        XCTAssertFalse(log.contains("; saved"), log)
    }

    func testOrderedFloorsLoadUnchanged() throws {
        var fine = Config()
        fine.lowPowerFloor = 30
        fine.endFloor = 25
        try h.store.saveConfig(fine)

        let m = h.makeManager()

        XCTAssertEqual(m.config, fine)
        XCTAssertFalse(log().contains("battery floors corrected"), log())
    }

    // MARK: Lid-close update at launch

    /// config.json as an earlier build left it: no lid-close mark.
    private func writeEarlierBuildConfig(_ json: String) throws {
        try h.home.paths.createDirectories()
        try Data(json.utf8).write(to: h.home.paths.configFile)
    }

    /// The maintainer's upgrade: freeze-all on (saved when it was the
    /// default) and mute off. The first launch turns freeze-all off and mute
    /// on, writes that back with the mark, keeps the notice for Settings and
    /// posts one notification naming both changes. The next launch does
    /// nothing.
    func testFirstLaunchAfterAnUpgradeAppliesTheLidCloseUpdateOnceWithANotice() async throws {
        try writeEarlierBuildConfig(#"{"freezeAllApps": true, "muteOnLidClose": false, "freezeList": ["com.hnc.Discord"]}"#)

        let m = h.makeManager()
        XCTAssertEqual(h.notifier.posts.count, 0, "posted before the launch reconcile, when the app's notification delegate may not be installed yet")
        await m.reconcile()

        XCTAssertFalse(m.config.freezeAllApps)
        XCTAssertTrue(m.config.muteOnLidClose)
        XCTAssertTrue(m.config.lidCloseDefaultsApplied)
        XCTAssertEqual(m.config.freezeList, ["com.hnc.Discord"], "nothing else changes")
        let change = LidCloseDefaultsChange(turnedOffFreezeAll: true, turnedOnMute: true)
        XCTAssertEqual(m.config.lidCloseDefaultsNotice, change)
        XCTAssertEqual(try h.store.loadConfig(), m.config, "the update and its mark were not written back")
        XCTAssertEqual(h.notifier.posts.map(\.title), [LidCloseDefaultsChange.title])
        XCTAssertEqual(h.notifier.posts.first?.body, change.notificationBody)
        XCTAssertTrue(log().contains(#"[info] insomnia: config.json: lid-close update: "Freeze every other app while the lid is closed" is now off and "Mute audio on lid close" is now on; saved"#), log())

        await m.reconcile()
        let again = h.makeManager()
        await again.reconcile()
        XCTAssertEqual(again.config, m.config)
        XCTAssertEqual(h.notifier.posts.count, 1, "the update is announced once")
    }

    /// A launch reconcile that cannot run (here the recovery lock is held)
    /// still posts the notice.
    func testTheLidCloseNoticeIsPostedEvenWhenTheLaunchReconcileIsRefused() async throws {
        try writeEarlierBuildConfig(#"{"freezeAllApps": true, "muteOnLidClose": false}"#)
        let m = h.makeManager()
        let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        defer { held.release() }

        await m.reconcile()

        XCTAssertNotNil(m.lastError, "the reconcile ran despite the held lock")
        XCTAssertEqual(h.notifier.posts.filter { $0.title == LidCloseDefaultsChange.title }.count, 1)
    }

    /// A user who turns either setting back after the update is never
    /// overridden again.
    func testASettingTurnedBackAfterTheUpdateStaysBack() async throws {
        try writeEarlierBuildConfig(#"{"freezeAllApps": true, "muteOnLidClose": false}"#)
        let m = h.makeManager()
        await m.reconcile()
        m.config.freezeAllApps = true
        m.config.muteOnLidClose = false
        try h.store.saveConfig(m.config)

        let again = h.makeManager()
        await again.reconcile()

        XCTAssertTrue(again.config.freezeAllApps)
        XCTAssertFalse(again.config.muteOnLidClose)
        XCTAssertEqual(h.notifier.posts.count, 1, "only the first launch announces the update")
    }

    /// A fresh install gets the new defaults, a config.json with the mark,
    /// and no notice.
    func testFreshInstallGetsTheNewDefaultsWithoutANotice() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.configFile.path))

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertTrue(m.config.muteOnLidClose)
        XCTAssertFalse(m.config.freezeAllApps)
        XCTAssertNil(m.config.lidCloseDefaultsNotice)
        XCTAssertEqual(try h.store.loadConfig()?.lidCloseDefaultsApplied, true, "the first config.json carries the mark")
        await h.makeManager().reconcile()
        XCTAssertEqual(h.notifier.posts.count, 0)
    }

    /// An earlier build's config.json already set the new way is marked and
    /// written back with nothing to announce.
    func testUpgradeWithNothingToChangeIsMarkedSilently() async throws {
        try writeEarlierBuildConfig(#"{"freezeAllApps": false, "muteOnLidClose": true}"#)

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertNil(m.config.lidCloseDefaultsNotice)
        XCTAssertEqual(h.notifier.posts.count, 0)
        XCTAssertEqual(try h.store.loadConfig()?.lidCloseDefaultsApplied, true)
        XCTAssertTrue(log().contains("config.json: lid-close update: nothing to change; saved"), log())
    }
}
