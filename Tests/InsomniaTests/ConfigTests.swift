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
        var expected = Config()
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

    /// A config.json without the freeze-all key (written before the toggle
    /// existed, or by hand) gets the default, off: nobody is opted in to the
    /// automatic scope by an upgrade. An explicit true is honoured.
    func testFreezeAllAppsDecodesTolerantly() throws {
        let legacy = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeList": ["com.hnc.Discord"]}"#.utf8))
        XCTAssertFalse(legacy.freezeAllApps, "a missing key must not opt the user in")
        XCTAssertEqual(legacy.freezeList, ["com.hnc.Discord"])
        let on = try Store.makeDecoder().decode(Config.self, from: Data(#"{"freezeAllApps": true}"#.utf8))
        XCTAssertTrue(on.freezeAllApps)
        var expected = Config()
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
        var expected = Config()
        expected.disableAppNapForAgents = true
        XCTAssertEqual(on, expected)
        let data = try Store.makeEncoder().encode(on)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: data), on)
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
        for prefix in FreezePlanner.builtInProtectedPrefixes {
            XCTAssertTrue(prefix.hasSuffix("."), "a protected prefix must end at a label boundary: \(prefix)")
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
}
