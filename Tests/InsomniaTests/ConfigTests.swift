import XCTest
@testable import Insomnia

final class ConfigTests: XCTestCase {
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
        XCTAssertTrue(c.dockerRule)
        XCTAssertFalse(c.muteOnLidClose)
        XCTAssertTrue(c.darkenDisplayOnLidClose)
        XCTAssertTrue(c.freezeAllApps)
        XCTAssertTrue(c.lowPowerOnLidClose)
        XCTAssertTrue(c.thermalRules)
        XCTAssertEqual(c.hotspotSSID, "")
        XCTAssertEqual(c.tmuxTargets, [])
        XCTAssertFalse(c.launchAtLogin)
    }

    func testPartialJSONFillsDefaults() throws {
        let data = Data(#"{"lowPowerFloor": 25}"#.utf8)
        let c = try Store.makeDecoder().decode(Config.self, from: data)
        var expected = Config()
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
        XCTAssertEqual(migrated, Config())

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

    func testEmptyObjectIsDefaults() throws {
        let c = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(c, Config())
    }

    /// A config.json written before the display toggle existed keeps the
    /// default (on); an explicit false is honoured.
    func testDarkenDisplayDecodesTolerantly() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"muteOnLidClose": true}"#.utf8))
        XCTAssertTrue(legacy.darkenDisplayOnLidClose)
        let off = try Store.makeDecoder().decode(Config.self, from: Data(#"{"darkenDisplayOnLidClose": false}"#.utf8))
        XCTAssertFalse(off.darkenDisplayOnLidClose)
        var expected = Config()
        expected.darkenDisplayOnLidClose = false
        XCTAssertEqual(off, expected)
        let data = try Store.makeEncoder().encode(off)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), off)
    }

    /// A config.json written before the freeze-all toggle existed keeps the
    /// default (on); an explicit false is honoured.
    func testFreezeAllAppsDecodesTolerantly() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeList": ["com.hnc.Discord"]}"#.utf8))
        XCTAssertTrue(legacy.freezeAllApps)
        XCTAssertEqual(legacy.freezeList, ["com.hnc.Discord"])
        let off = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": false}"#.utf8))
        XCTAssertFalse(off.freezeAllApps)
        var expected = Config()
        expected.freezeAllApps = false
        XCTAssertEqual(off, expected)
        let data = try Store.makeEncoder().encode(off)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), off)
    }

    /// Cheap typo guard for the shipped defaults: no duplicates, and every
    /// id looks like a reverse-DNS bundle id with a lowercase first label.
    func testDefaultListsAreUniqueReverseDNSIds() throws {
        let pattern = #"^[a-z][a-z0-9-]*(\.[A-Za-z0-9_-]+)+$"#
        for (name, ids) in [("agentList", Config.defaultAgentList), ("freezeList", Config.defaultFreezeList), ("builtInProtected", Array(FreezePlanner.builtInProtected))] {
            XCTAssertEqual(Set(ids).count, ids.count, "\(name) has duplicates")
            for id in ids {
                XCTAssertNotNil(id.range(of: pattern, options: .regularExpression), "\(name): \(id) does not look like a bundle id")
            }
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
}
