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
        XCTAssertEqual(c.presets, [1800, 3600, 7200, 14400, 28800, 43200, 86400])
        XCTAssertEqual(c.lowPowerFloor, 40)
        XCTAssertEqual(c.endFloor, 10)
        XCTAssertEqual(c.nudgeThreshold, 90)
        XCTAssertEqual(c.maxDuration, 24 * 3600)
        XCTAssertTrue(c.presets.allSatisfy { $0 <= c.maxDuration }, "no shipped preset may exceed the maximum")
        XCTAssertLessThanOrEqual(c.defaultPreset, c.maxDuration)
        XCTAssertEqual(c.freezeList, ["com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.hnc.Discord"])
        XCTAssertTrue(c.agentList.contains("com.apple.Terminal"))
        XCTAssertTrue(c.agentList.contains("com.t3tools.t3code"))
        XCTAssertTrue(c.agentList.contains("com.docker.docker"))
        XCTAssertTrue(c.agentList.contains("com.microsoft.VSCode"))
        XCTAssertTrue(c.agentList.contains("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(c.agentList.contains("io.tailscale.ipn.macsys"))
        XCTAssertFalse(c.dockerRule, "the Docker rule is opt in")
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

    /// The 24-hour ceiling is the decoder's default too, so an older
    /// config.json without the key gets it; a written value is kept, so a
    /// user who raised it in config.json keeps the longer sessions.
    func testMaxDurationDefaultsTo24HoursAndAnExplicitValueIsKept() throws {
        let old = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lowPowerFloor": 25}"#.utf8))
        XCTAssertEqual(old.maxDuration, 24 * 3600)
        let raised = try Store.makeDecoder().decode(Config.self, from: Data(#"{"maxDuration": 604800}"#.utf8))
        XCTAssertEqual(raised.maxDuration, 7 * 24 * 3600)
    }

    /// Settings saves the whole struct, so every ordinary config.json from an
    /// older build holds that build's defaults (30 days, a 3-day preset) as
    /// explicit values. Exactly those read as the current defaults; any other
    /// value was chosen by hand and is kept, a 3-day preset included, unless
    /// the ceiling it sits under was not (see the next test).
    func testLegacyDefaultsSavedByOlderBuildsReadAsTheCurrentDefaults() throws {
        let saved = #"{"maxDuration": 2592000, "presets": [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200]}"#
        let migrated = try Store.makeDecoder().decode(Config.self, from: Data(saved.utf8))
        XCTAssertEqual(migrated.maxDuration, 24 * 3600)
        XCTAssertEqual(migrated.presets, Config.defaultPresets)
        XCTAssertEqual(migrated, earlierBuild())

        let custom = #"{"maxDuration": 604800, "presets": [3600, 259200]}"#
        let kept = try Store.makeDecoder().decode(Config.self, from: Data(custom.utf8))
        XCTAssertEqual(kept.maxDuration, 7 * 24 * 3600)
        XCTAssertEqual(kept.presets, [3600, 259200])

        // A customized list that still has the old default's shape minus one
        // entry is not the old default: it is kept, minus the entry above
        // the 24-hour ceiling it now sits under.
        let trimmed = #"{"presets": [1800, 3600, 7200, 14400, 28800, 43200, 259200]}"#
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: Data(trimmed.utf8)).presets, [1800, 3600, 7200, 14400, 28800, 43200])
    }

    /// An older build could have the 3-day preset as its default. Once the
    /// 30-day ceiling the user never chose becomes 24 hours, that default
    /// would make bare Enter refuse, so it moves to the largest preset left
    /// under the ceiling, and presets above the ceiling go (Settings refuses
    /// to add them). A ceiling the user set keeps everything as it was.
    @MainActor
    func testADefaultAboveTheMigratedCeilingMovesToTheLargestPresetUnderIt() throws {
        func decode(_ json: String) throws -> Config {
            try Store.makeDecoder().decode(Config.self, from: Data(json.utf8))
        }
        func bareEnter(_ c: Config) -> MenuBarModel.CommitAction {
            MenuBarModel.commitAction(mode: .start, typed: nil, defaultPreset: c.defaultPreset, maxDuration: c.maxDuration)
        }

        let stock = try decode(#"{"maxDuration": 2592000, "presets": [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200], "defaultPreset": 259200}"#)
        XCTAssertEqual(stock.maxDuration, 24 * 3600)
        XCTAssertEqual(stock.presets, Config.defaultPresets)
        XCTAssertEqual(stock.defaultPreset, 24 * 3600)
        XCTAssertEqual(bareEnter(stock), .run(24 * 3600))

        let trimmed = try decode(#"{"maxDuration": 2592000, "presets": [1800, 3600, 7200, 14400, 28800, 43200, 259200], "defaultPreset": 259200}"#)
        XCTAssertEqual(trimmed.presets, [1800, 3600, 7200, 14400, 28800, 43200])
        XCTAssertEqual(trimmed.defaultPreset, 12 * 3600)
        XCTAssertEqual(bareEnter(trimmed), .run(12 * 3600))

        // Nothing left under the ceiling: the stock default.
        let onlyLong = try decode(#"{"presets": [259200], "defaultPreset": 259200}"#)
        XCTAssertEqual(onlyLong.presets, [])
        XCTAssertEqual(onlyLong.defaultPreset, Config().defaultPreset)
        XCTAssertEqual(bareEnter(onlyLong), .run(Config().defaultPreset))

        // A default that still fits stays where the user put it.
        let fits = try decode(#"{"maxDuration": 2592000, "presets": [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200], "defaultPreset": 7200}"#)
        XCTAssertEqual(fits.defaultPreset, 7200)

        // A ceiling set by hand keeps the 3-day default; only the stock list changes.
        let raised = try decode(#"{"maxDuration": 604800, "presets": [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200], "defaultPreset": 259200}"#)
        XCTAssertEqual(raised.maxDuration, 7 * 24 * 3600)
        XCTAssertEqual(raised.presets, Config.defaultPresets)
        XCTAssertEqual(raised.defaultPreset, 3 * 24 * 3600)
        XCTAssertEqual(bareEnter(raised), .run(3 * 24 * 3600))
    }

    /// Only a file without `configVersion` can hold an older build's stock
    /// values. A current file's 30-day ceiling was set by hand and is kept,
    /// with the presets and default under it.
    func testACurrentFileKeepsA30DayCeilingSetByHand() throws {
        let json = #"{"configVersion": 2, "maxDuration": 2592000, "presets": [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200], "defaultPreset": 259200}"#
        let c = try Store.makeDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.maxDuration, 30 * 24 * 3600)
        XCTAssertEqual(c.presets, Config.legacyPresets)
        XCTAssertEqual(c.defaultPreset, 3 * 24 * 3600)

        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Store.makeEncoder().encode(Config())) as? [String: Any])
        XCTAssertEqual(written["configVersion"] as? Int, 2)
    }

    /// The app reads an older file with the stock values migrated and writes
    /// it back once with the marker, so a 30-day ceiling typed into that file
    /// afterwards is the user's. A current file is not rewritten at launch.
    @MainActor
    func testAnOlderFileIsWrittenBackOnceSoALaterHandEditIsKept() throws {
        let h = Harness()
        defer { h.home.destroy() }
        let url = h.home.paths.configFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"maxDuration": 2592000, "presets": [1800, 3600, 7200, 14400, 28800, 43200, 86400, 259200], "defaultPreset": 259200, "endFloor": 15}"#.utf8).write(to: url)

        let upgraded = h.makeManager()
        XCTAssertEqual(upgraded.config.maxDuration, 24 * 3600)
        XCTAssertEqual(upgraded.config.defaultPreset, 24 * 3600)
        XCTAssertEqual(upgraded.config.endFloor, 15)
        var onDisk = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(onDisk["configVersion"] as? Int, 2)
        XCTAssertEqual(onDisk["maxDuration"] as? Double, 24 * 3600)
        XCTAssertEqual(onDisk["endFloor"] as? Int, 15)

        onDisk["maxDuration"] = 2592000
        let handEdited = try JSONSerialization.data(withJSONObject: onDisk)
        try handEdited.write(to: url)
        let later = h.makeManager()
        XCTAssertEqual(later.config.maxDuration, 30 * 24 * 3600)
        XCTAssertEqual(try Data(contentsOf: url), handEdited, "a current file is read, not rewritten")
    }

    /// A config.json without the key (older build, or written by hand)
    /// gets the default, off: an upgrade never opts anyone in. An explicit
    /// true is honoured and round-trips.
    func testDockerRuleDecodesTolerantly() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"muteOnLidClose": true}"#.utf8))
        XCTAssertFalse(legacy.dockerRule, "a missing key must not opt the user in")
        let on = try Store.makeDecoder().decode(Config.self, from: Data(#"{"dockerRule": true}"#.utf8))
        XCTAssertTrue(on.dockerRule)
        var expected = earlierBuild()
        expected.dockerRule = true
        XCTAssertEqual(on, expected)
        let data = try Store.makeEncoder().encode(on)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), on)
        let off = try Store.makeDecoder().decode(Config.self, from: Data(#"{"dockerRule": false}"#.utf8))
        XCTAssertFalse(off.dockerRule)
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

    private func writeConfig(_ json: String) throws -> Data {
        try h.home.paths.createDirectories()
        let data = Data(json.utf8)
        try data.write(to: h.home.paths.configFile)
        return data
    }

    private func movedAsideConfigs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: h.home.paths.appSupport.path)
            .filter { $0.hasPrefix(Paths.unreadableConfigPrefix) }.sorted()
    }

    /// The marker's presence is what makes a file current; its value is
    /// never read. A hand-edited "2" keeps every setting, the 30-day
    /// ceiling included, and the file is neither migrated nor rewritten.
    /// The file has had the lid-close update, which would write it once.
    func testAVersionMarkerOfAnotherTypeKeepsTheSettings() async throws {
        let json = #"{"configVersion": "2", "lidCloseDefaultsApplied": true, "maxDuration": 2592000, "endFloor": 30, "lowPowerFloor": 40, "freezeAllApps": false}"#
        let written = try writeConfig(json)

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.config.maxDuration, 30 * 24 * 3600)
        XCTAssertEqual([m.config.endFloor, m.config.lowPowerFloor], [30, 40])
        XCTAssertFalse(m.config.freezeAllApps)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.configFile), written)
        XCTAssertEqual(try movedAsideConfigs(), [])
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionManager.configFileTitle })
    }

    /// A file this build cannot decode is the user's settings with one bad
    /// value or a typo. It is renamed aside with its bytes, never written
    /// over. The first reconcile, which runs only once the launch holds the
    /// alive lock, writes the defaults the app runs on to config.json and
    /// says where the file went, once.
    func testAConfigThatDoesNotDecodeIsMovedAsideNotOverwritten() async throws {
        let cases = [
            #"{"configVersion": 2, "endFloor": "30", "freezeAllApps": false}"#,
            #"{"configVersion": 2, "endFloor": 30"#,
        ]
        for json in cases {
            h.home.destroy()
            h = Harness()
            let written = try writeConfig(json)

            let m = h.makeManager()

            XCTAssertEqual(m.config, Config(), json)
            XCTAssertEqual(try movedAsideConfigs(), ["config.json.unreadable-20270115T080000Z"], json)
            let moved = h.home.paths.appSupport.appendingPathComponent("config.json.unreadable-20270115T080000Z")
            XCTAssertEqual(try Data(contentsOf: moved), written, json)
            XCTAssertNil(try h.store.loadConfig(), "init writes nothing: it runs before LaunchGate")
            XCTAssertTrue(log().contains("[error] insomnia: config.json could not be read ("), log())

            await m.reconcile()
            XCTAssertEqual(try h.store.loadConfig(), Config(), json)
            await m.reconcile()
            let notices = h.notifier.posts.filter { $0.title == SessionManager.configFileTitle }
            XCTAssertEqual(notices.count, 1, "\(notices)")
            XCTAssertTrue(notices.first?.body.contains("It was moved to \(moved.path)") == true, "\(notices)")
        }
    }

    /// When the rename fails, nothing is written over the file: the app runs
    /// on defaults and says the file was left as it is, and how to fix it.
    /// The rename keeps failing in reconcile's transaction, which sets
    /// `rejectedConfigFile` without a second notification.
    func testAConfigThatCannotBeMovedAsideIsLeftAsItIs() async throws {
        let written = try writeConfig(rejectedConfig)
        let file = h.home.paths.configFile
        try setImmutable(file, true)
        defer { try? setImmutable(file, false) }

        let m = h.makeManager()

        XCTAssertEqual(m.config, Config())
        XCTAssertEqual(try Data(contentsOf: file), written)
        XCTAssertEqual(try movedAsideConfigs(), [])
        await m.reconcile()
        XCTAssertNotNil(m.rejectedConfigFile)
        let notices = h.notifier.posts.filter { $0.title == SessionManager.configFileTitle }
        XCTAssertEqual(notices.count, 1, "\(notices)")
        XCTAssertTrue(notices.first?.body.contains("left the file as it is") == true, "\(notices)")
        XCTAssertTrue(notices.first?.body.contains("Make \(file.path) writable or delete it.") == true, "\(notices)")
    }

    // MARK: config.json rejected in place

    /// The app's decoder refuses this file (freezeList is not a list), but
    /// its endFloor and thermalRules are valid scalars that backstop.sh
    /// reads by itself: a 0% floor and no thermal rule.
    private let rejectedConfig = #"{"endFloor": 0, "thermalRules": false, "freezeList": 42}"#

    /// While a file the app rejects cannot be moved aside, the agent would
    /// enforce its cutoffs, not the app's defaults, so Start changes nothing
    /// and says which file to fix and how. Once the file can be renamed,
    /// the next Start moves it aside, writes the settings in use back, and
    /// starts.
    func testStartIsRefusedWhileARejectedConfigCannotBeMovedAside() async throws {
        let written = try writeConfig(rejectedConfig)
        let file = h.home.paths.configFile
        try setImmutable(file, true)
        defer { try? setImmutable(file, false) }
        let m = h.makeManager()
        await m.reconcile()

        await m.start(duration: 3600)

        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState() ?? .clean, RuntimeState.clean)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertEqual(try Data(contentsOf: file), written)
        XCTAssertEqual(try movedAsideConfigs(), [])
        XCTAssertTrue(m.lastError?.hasPrefix("start refused, nothing changed: config.json could not be read (") == true, m.lastError ?? "nil")
        let refusal = h.notifier.posts.last
        XCTAssertEqual(refusal?.title, SessionManager.configFileTitle)
        XCTAssertTrue(refusal?.body.hasPrefix("Insomnia did not start a session. config.json could not be read (") == true, "\(String(describing: refusal))")
        XCTAssertTrue(refusal?.body.hasSuffix("Make \(file.path) writable or delete it.") == true, "\(String(describing: refusal))")

        try setImmutable(file, false)
        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 1"))
        XCTAssertNil(m.rejectedConfigFile)
        let moved = h.home.paths.appSupport.appendingPathComponent("config.json.unreadable-20270115T080000Z")
        XCTAssertEqual(try movedAsideConfigs(), [moved.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: moved), written)
        XCTAssertEqual(try h.store.loadConfig(), m.config)
        XCTAssertTrue(h.notifier.posts.contains { $0.title == SessionManager.configFileTitle && $0.body.contains("It was moved to \(moved.path)") }, "\(h.notifier.posts)")
    }

    /// Deleting the file is the other fix. Start writes the settings the
    /// app fell back to in its place, so the agent reads them, and goes
    /// ahead.
    func testStartGoesAheadOnceTheRejectedConfigIsDeleted() async throws {
        _ = try writeConfig(rejectedConfig)
        let file = h.home.paths.configFile
        try setImmutable(file, true)
        defer { try? setImmutable(file, false) }
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)

        try setImmutable(file, false)
        try FileManager.default.removeItem(at: file)
        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.config, Config())
        XCTAssertEqual(try h.store.loadConfig(), m.config)
        XCTAssertEqual(try movedAsideConfigs(), [])
    }

    /// The same fix after the file turned bad during a session, while the
    /// app runs on a 30% floor: without a file the agent would enforce its
    /// own 10%. So the deleted file is replaced by the settings in use
    /// before a session runs, and while that write fails Start is refused.
    func testADeletedRejectedConfigIsReplacedByTheSettingsInUseBeforeAStart() async throws {
        var mine = Config()
        mine.endFloor = 30
        try h.store.saveConfig(mine)
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        _ = try writeConfig(rejectedConfig)
        let file = h.home.paths.configFile
        let dir = h.home.paths.appSupport
        try setImmutable(file, true)
        defer { try? setImmutable(file, false) }
        await m.extend(by: 600)
        XCTAssertFalse(m.isActive)

        try setImmutable(file, false)
        try FileManager.default.removeItem(at: file)
        try TestACL.denyNewFiles(in: dir)
        defer { try? TestACL.removeAll(dir) }
        await m.start(duration: 3600)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let why = m.rejectedConfigFile ?? "no refusal"
        XCTAssertTrue(why.hasSuffix("Free some disk space or make \(dir.path) writable."), why)
        XCTAssertEqual(h.notifier.posts.last?.body, "Insomnia did not start a session. \(why)")

        try TestACL.removeAll(dir)
        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertNil(m.rejectedConfigFile)
        XCTAssertEqual(try h.store.loadConfig()?.endFloor, 30)
        XCTAssertEqual(try movedAsideConfigs(), [])
    }

    /// A session already running when config.json becomes a file the app
    /// rejects and cannot move ends at the next transaction, through the
    /// normal end: sleep restored, session.json removed, the journal clean,
    /// and a notification that names the file. The file is left as it is,
    /// and the next Start is refused.
    func testARunningSessionEndsAtTheNextTransactionOnceConfigIsRejectedInPlace() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let written = try writeConfig(rejectedConfig)
        let file = h.home.paths.configFile
        try setImmutable(file, true)
        defer { try? setImmutable(file, false) }

        await m.extend(by: 600)

        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState() ?? .clean, RuntimeState.clean)
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try Data(contentsOf: file), written)
        let end = h.notifier.posts.last
        XCTAssertEqual(end?.title, "Session ended")
        XCTAssertTrue(end?.body.contains("Make \(file.path) writable or delete it.") == true, "\(String(describing: end))")
        XCTAssertTrue(log().contains("session end (settingsFileRejected)"), log())

        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
    }

    /// At launch, a valid session on disk is not resumed while config.json
    /// is rejected in place. Reconcile ends it from the journal instead.
    func testReconcileEndsAValidSessionInsteadOfResumingItWhileConfigIsRejected() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
        _ = try writeConfig(rejectedConfig)
        let file = h.home.paths.configFile
        try setImmutable(file, true)
        defer { try? setImmutable(file, false) }

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.backstop.arms, 0)
        let end = h.notifier.posts.last
        XCTAssertEqual(end?.title, "Session restored")
        XCTAssertTrue(end?.body.contains("Make \(file.path) writable or delete it.") == true, "\(String(describing: end))")
    }

    /// A file the app rejects that can be renamed is moved aside at the
    /// next transaction, and the settings the app runs on are written in its
    /// place, so the agent reads the app's cutoffs again. The session goes
    /// on.
    func testARejectedConfigThatCanBeMovedIsReplacedByTheSettingsInUse() async throws {
        var mine = Config()
        mine.endFloor = 30
        try h.store.saveConfig(mine)
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        let written = try writeConfig(rejectedConfig)

        await m.extend(by: 600)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(m.config.endFloor, 30)
        XCTAssertEqual(try h.store.loadConfig(), m.config)
        let moved = h.home.paths.appSupport.appendingPathComponent("config.json.unreadable-20270115T080000Z")
        XCTAssertEqual(try Data(contentsOf: moved), written)
        XCTAssertTrue(h.notifier.posts.contains { $0.title == SessionManager.configFileTitle && $0.body.contains("It was moved to \(moved.path)") }, "\(h.notifier.posts)")
    }

    /// A rejected file moved aside whose replacement cannot be written, as
    /// on a full disk, leaves no config.json: the agent would enforce its
    /// 10% default floor while the app enforces 30%. The running session
    /// ends, Start is refused, and every transaction writes again until the
    /// file is there. config.json is a directory here, which the rename
    /// moves under the ACL entry that stops the write's temp file.
    func testSessionsWaitForTheSettingsInUseToBeWrittenWhereTheRejectedConfigWas() async throws {
        var mine = Config()
        mine.endFloor = 30
        try h.store.saveConfig(mine)
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let file = h.home.paths.configFile
        let dir = h.home.paths.appSupport
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try TestACL.denyNewFiles(in: dir)
        defer { try? TestACL.removeAll(dir) }

        await m.extend(by: 600)

        XCTAssertFalse(m.isActive)
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try movedAsideConfigs(), ["config.json.unreadable-20270115T080000Z"])
        let why = try XCTUnwrap(m.rejectedConfigFile)
        XCTAssertTrue(why.hasSuffix("Free some disk space or make \(dir.path) writable."), why)
        let moved = dir.appendingPathComponent("config.json.unreadable-20270115T080000Z")
        XCTAssertTrue(h.notifier.posts.contains { $0.title == SessionManager.configFileTitle && $0.body.hasSuffix("was moved to \(moved.path). \(why)") }, "\(h.notifier.posts)")

        await m.start(duration: 3600)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(h.notifier.posts.last?.body, "Insomnia did not start a session. \(why)")

        try TestACL.removeAll(dir)
        await m.reconcile()

        XCTAssertNil(m.rejectedConfigFile)
        XCTAssertEqual(try h.store.loadConfig()?.endFloor, 30)
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
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

    /// Settings' Dismiss clears the notice in config.json, and a relaunch
    /// neither brings the line back nor posts the notification again.
    func testDismissingTheLidCloseNoticeIsSavedAndStaysDismissed() async throws {
        try writeEarlierBuildConfig(#"{"freezeAllApps": true, "muteOnLidClose": false}"#)
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNotNil(m.config.lidCloseDefaultsNotice)

        m.dismissLidCloseNotice()

        XCTAssertNil(m.config.lidCloseDefaultsNotice)
        let saved = try XCTUnwrap(try h.store.loadConfig())
        XCTAssertNil(saved.lidCloseDefaultsNotice, "the dismissal was not saved")
        XCTAssertTrue(saved.lidCloseDefaultsApplied)
        XCTAssertFalse(saved.freezeAllApps, "dismissing changes only the notice")
        XCTAssertTrue(saved.muteOnLidClose, "dismissing changes only the notice")

        let again = h.makeManager()
        await again.reconcile()
        XCTAssertNil(again.config.lidCloseDefaultsNotice)
        XCTAssertEqual(h.notifier.posts.count, 1, "only the first launch announces the update")
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

    /// A config.json from before both one-time updates gets each once: the
    /// stock 30-day ceiling becomes 24 hours and the lid-close settings
    /// change, with one notice, while a value the user set is kept. The
    /// file is written back with both marks, so a 30-day ceiling the user
    /// then sets and a dismissed notice stay as they are after a relaunch.
    func testAnOlderConfigGetsTheDurationAndLidCloseUpdatesOnceEach() async throws {
        try writeEarlierBuildConfig(#"{"maxDuration": 2592000, "endFloor": 30, "freezeAllApps": true, "muteOnLidClose": false}"#)

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.config.maxDuration, 24 * 3600)
        XCTAssertEqual(m.config.endFloor, 30)
        XCTAssertFalse(m.config.freezeAllApps)
        XCTAssertTrue(m.config.muteOnLidClose)
        XCTAssertNotNil(m.config.lidCloseDefaultsNotice)
        XCTAssertEqual(try h.store.loadConfig(), m.config)
        XCTAssertTrue(try h.store.configHasVersion())
        XCTAssertEqual(h.notifier.posts.map(\.title), [LidCloseDefaultsChange.title])

        m.config.maxDuration = 30 * 24 * 3600
        try h.store.saveConfig(m.config)
        m.dismissLidCloseNotice()
        let again = h.makeManager()
        await again.reconcile()

        XCTAssertEqual(again.config.maxDuration, 30 * 24 * 3600)
        XCTAssertNil(again.config.lidCloseDefaultsNotice)
        XCTAssertEqual(again.config, m.config)
        XCTAssertEqual(h.notifier.posts.count, 1)
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
