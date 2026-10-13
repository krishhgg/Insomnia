import XCTest
@testable import Insomnia

final class MinimalConfigTests: XCTestCase {
    func testFreshAndOlderConfigsKeepTheDefaultPresentation() throws {
        XCTAssertEqual(Config().menuBarMode, .standard)
        let old = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(old.menuBarMode, .standard)
        XCTAssertFalse(old.compactMode)
    }

    func testLegacyCompactChoiceMigratesWithoutChangingSessionSettings() throws {
        for oldChoice in [false, true] {
            let json = "{\"compactMode\": \(oldChoice), \"defaultPreset\": 900, \"maxDuration\": 86400, \"hotspotSSID\": \"iPhone\"}"
            let config = try Store.makeDecoder().decode(Config.self, from: Data(json.utf8))
            XCTAssertEqual(config.menuBarMode, oldChoice ? .compact : .standard)
            XCTAssertEqual(config.compactMode, oldChoice)
            XCTAssertEqual(config.defaultPreset, 900)
            XCTAssertEqual(config.maxDuration, 86400)
            XCTAssertEqual(config.hotspotSSID, "iPhone")
        }
    }

    func testNewModeTakesPrecedenceOverAnObsoleteCompactKey() throws {
        for mode in Config.MenuBarMode.allCases {
            let json = "{\"menuBarMode\": \"\(mode.rawValue)\", \"compactMode\": true}"
            let config = try Store.makeDecoder().decode(Config.self, from: Data(json.utf8))
            XCTAssertEqual(config.menuBarMode, mode)
        }
    }

    func testEachModeRoundTripsWithTheSameSharedDurationAndOtherSettings() throws {
        for mode in Config.MenuBarMode.allCases {
            var config = Config()
            config.menuBarMode = mode
            config.defaultPreset = 95400 // 1d 2h 30m
            config.presets = [900, 3600]
            config.disableAppNapForAgents = true
            config.lidCloseDefaultsNotice = LidCloseDefaultsChange(turnedOffFreezeAll: true, turnedOnMute: false)
            let encoded = try Store.makeEncoder().encode(config)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(json["menuBarMode"] as? String, mode.rawValue)
            XCTAssertNil(json["compactMode"], "write only the current mode, not conflicting representations")
            XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: encoded), config)
        }
    }

    func testCompactSceneRemovalCannotReplaceMinimalMode() {
        var config = Config()
        config.compactMode = true
        XCTAssertEqual(config.menuBarMode, .compact)
        config.menuBarMode = .minimal
        config.compactMode = false
        XCTAssertEqual(config.menuBarMode, .minimal, "a delayed native scene removal must preserve the Settings choice")
        XCTAssertFalse(config.compactMode)

        config.compactMode = true
        XCTAssertEqual(config.menuBarMode, .compact)
        config.compactMode = false
        XCTAssertEqual(config.menuBarMode, .standard)
    }

    func testDurationEditsUpdateTheExistingDefaultPreset() throws {
        var config = Config()
        let presets = config.presets
        var field = MinimalDurationSetting(seconds: config.defaultPreset)
        field.text = "1d2h30m"

        XCTAssertTrue(field.apply(to: &config))
        XCTAssertEqual(config.defaultPreset, 95400)
        XCTAssertEqual(config.presets, presets, "the single-click duration does not add another preset")
        XCTAssertEqual(field.text, "1d 2h 30m")
        XCTAssertNil(field.error)
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: Store.makeEncoder().encode(config)), config)
    }

    func testInvalidAndOverLimitDurationEditsNeverReplaceTheSavedValue() {
        let original = Config()
        for text in ["", "0", "0m", "-1h", "tomorrow", "1h5", "31d", "99999999999999999999h"] {
            var config = original
            var field = MinimalDurationSetting(seconds: config.defaultPreset)
            field.text = text

            XCTAssertFalse(field.apply(to: &config), text)
            XCTAssertEqual(config, original, text)
            XCTAssertNotNil(field.error, text)
            XCTAssertEqual(field.text, text, "keep the edit available for correction")
        }
    }

    func testDurationLimitIsInclusiveAndUsesTheConfiguredCeiling() {
        var config = Config()
        config.maxDuration = 90 * 60
        var field = MinimalDurationSetting(seconds: config.defaultPreset)
        field.text = "91m"
        XCTAssertFalse(field.apply(to: &config))
        XCTAssertEqual(field.error, "The duration cannot exceed 1h 30m.")
        XCTAssertEqual(config.defaultPreset, Config().defaultPreset)

        field.text = "90m"
        XCTAssertTrue(field.apply(to: &config))
        XCTAssertEqual(config.defaultPreset, config.maxDuration)
        XCTAssertNil(field.error)
    }

    func testEquivalentOrUntouchedValuesDoNotRequireSaving() {
        var config = Config()
        var field = MinimalDurationSetting(seconds: config.defaultPreset)
        XCTAssertFalse(field.apply(to: &config))
        field.text = "240m"
        XCTAssertFalse(field.apply(to: &config))
        XCTAssertEqual(field.text, "4h")
        XCTAssertNil(field.error)

        // A manually written value can contain seconds. Opening or tabbing
        // through the minute-based editor must not silently round it.
        config.defaultPreset = 61
        field = MinimalDurationSetting(seconds: config.defaultPreset)
        XCTAssertFalse(field.apply(to: &config))
        XCTAssertEqual(config.defaultPreset, 61)
    }

    func testReturningToTheSavedValueClearsAValidationError() {
        var config = Config()
        var field = MinimalDurationSetting(seconds: config.defaultPreset)
        field.text = "0m"
        XCTAssertFalse(field.apply(to: &config))
        XCTAssertNotNil(field.error)
        field.text = "4h"
        XCTAssertFalse(field.apply(to: &config))
        XCTAssertNil(field.error)
        XCTAssertEqual(config.defaultPreset, Config().defaultPreset)
    }

    func testFormattingRetainsMinutesInMultiDayDurations() {
        XCTAssertEqual(MinimalDurationSetting.label(for: 2 * 86400 + 3 * 3600 + 45 * 60), "2d 3h 45m")
        XCTAssertEqual(MinimalDurationSetting.label(for: 60), "1m")
        XCTAssertEqual(MinimalDurationSetting.label(for: 86400), "1d")
    }
}
