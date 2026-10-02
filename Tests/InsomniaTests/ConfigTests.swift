import XCTest
@testable import Insomnia

final class ConfigTests: XCTestCase {
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
