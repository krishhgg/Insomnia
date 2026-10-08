import XCTest
@testable import Insomnia

final class StoreTests: XCTestCase {
    var home: TempHome!
    var store: Store!

    override func setUp() {
        home = TempHome()
        store = Store(paths: home.paths)
    }

    override func tearDown() {
        home.destroy()
    }

    func testMissingFileReturnsNil() throws {
        XCTAssertNil(try store.loadSession())
        XCTAssertNil(try store.loadState())
        XCTAssertNil(try store.loadConfig())
    }

    func testSessionRoundTrip() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let s = Session(startedAt: t0, endsAt: t0.addingTimeInterval(3600), extensions: [600, 1200])
        try store.saveSession(s)
        XCTAssertEqual(try store.loadSession(), s)
    }

    func testStateRoundTripPreservesOptionals() throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 12, startedAt: 1_700_000_000), FrozenProcess(pid: 34, startedAt: 1_700_000_001)]
        st.savedOutputVolume = 0.6
        st.savedMuted = false
        st.savedDisplayBrightness = 0.75
        st.savedKeyboardBrightness = 0.25
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
    }

    /// backstop.sh reads the display and keyboard entries by these flat keys
    /// and must see plain numbers; absent means nothing saved.
    func testStateWritesSavedBrightnessAsFlatNumbersForTheBackstop() throws {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.75
        st.savedKeyboardBrightness = 0.25
        try store.saveState(st)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"savedDisplayBrightness\" : 0.75"), text)
        XCTAssertTrue(text.contains("\"savedKeyboardBrightness\" : 0.25"), text)

        try store.saveState(RuntimeState())
        let clean = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertFalse(clean.contains("savedDisplayBrightness"), clean)
        XCTAssertFalse(clean.contains("savedKeyboardBrightness"), clean)
    }

    /// Output device entries are flat objects that backstop.sh and
    /// uninstall.sh check with plutil: a string UID, an optional string
    /// name, a number, a bool and an optional string save ID.
    func testSavedAudioOutputsAreWrittenFlatForTheScripts() throws {
        var st = RuntimeState()
        st.savedAudioOutputs = [
            SavedAudioOutput(deviceUID: "usb-headset", name: "USB Headset", volume: 0.25, muted: false, saveID: "8C1F0E2A-55B1-4F0D-9D7B-3E1A2B4C5D6E"),
            SavedAudioOutput(deviceUID: "70-8C-F2:output", name: nil, volume: 1, muted: true, saveID: nil),
        ]
        try store.saveState(st)
        XCTAssertEqual(try store.loadState()?.savedAudioOutputs, st.savedAudioOutputs)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.paths.stateFile)) as? [String: Any])
        let outputs = try XCTUnwrap(json["savedAudioOutputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.first?["deviceUID"] as? String, "usb-headset")
        XCTAssertEqual(outputs.first?["name"] as? String, "USB Headset")
        XCTAssertEqual(outputs.first?["volume"] as? Double, 0.25)
        XCTAssertEqual(outputs.first?["muted"] as? Bool, false)
        XCTAssertEqual(outputs.first?["saveID"] as? String, "8C1F0E2A-55B1-4F0D-9D7B-3E1A2B4C5D6E")
        XCTAssertNil(outputs.last?["name"])
        XCTAssertNil(outputs.last?["saveID"])
        XCTAssertTrue(st.isDirty)
        XCTAssertFalse(st.isDirty(leavingOutAudioOf: ["usb-headset", "70-8C-F2:output"]))
    }

    /// A journal from before output device entries has no key, and a null
    /// counts as absent, as the scripts read it. An entry from before save
    /// IDs, or with a null one, has none. Every entry the scripts call
    /// malformed, the app's decoder refuses too, so neither side undoes a
    /// journal the other cannot read.
    func testSavedAudioOutputsDecodeLikeTheScriptsCheckThem() throws {
        for legacy in [
            #"{"sleepDisabledByUs":false,"savedOutputVolume":0.5,"savedMuted":false}"#,
            #"{"sleepDisabledByUs":false,"savedOutputVolume":0.5,"savedMuted":false,"savedAudioOutputs":null}"#,
        ] {
            let st = try Store.makeDecoder().decode(RuntimeState.self, from: Data(legacy.utf8))
            XCTAssertEqual(st.savedAudioOutputs, [], legacy)
            XCTAssertEqual(st.savedOutputVolume, 0.5, legacy)
        }
        for earlier in [
            #"{"savedAudioOutputs":[{"deviceUID":"usb-headset","name":"USB Headset","volume":0.3,"muted":false}]}"#,
            #"{"savedAudioOutputs":[{"deviceUID":"usb-headset","name":"USB Headset","volume":0.3,"muted":false,"saveID":null}]}"#,
        ] {
            let st = try Store.makeDecoder().decode(RuntimeState.self, from: Data(earlier.utf8))
            XCTAssertEqual(st.savedAudioOutputs, [SavedAudioOutput(deviceUID: "usb-headset", name: "USB Headset", volume: 0.3, muted: false, saveID: nil)], earlier)
        }
        for json in RecoveryScriptTests.corruptOutputJournals {
            XCTAssertThrowsError(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), json)
        }
    }

    /// App Nap entries are flat objects with a string bundle id and an
    /// optional bool, which is what backstop.sh reads with plutil; an
    /// absent previous value stays absent in the JSON. They keep the
    /// journal dirty on their own and are not lid actions.
    func testAppNapOverridesRoundTripAsFlatKeysAndAreDirty() throws {
        var st = RuntimeState()
        st.appNapOverrides = [
            AppNapOverride(bundleId: "com.google.Chrome", previous: nil),
            AppNapOverride(bundleId: "com.apple.Terminal", previous: false),
            AppNapOverride(bundleId: "dev.zed.Zed", previous: true),
        ]
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
        XCTAssertTrue(st.isDirty)
        XCTAssertFalse(st.hasLidActions)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"bundleId\" : \"com.google.Chrome\""), text)
        XCTAssertTrue(text.contains("\"previous\" : false"), text)
        XCTAssertTrue(text.contains("\"previous\" : true"), text)
        XCTAssertEqual(text.components(separatedBy: "\"previous\"").count, 3, "an absent previous value is left out: \(text)")

        try store.saveState(RuntimeState())
        let clean = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(clean.contains("\"appNapOverrides\" : [\n\n  ]") || clean.contains("\"appNapOverrides\" : []"), clean)
    }

    /// A journal written before App Nap was journaled has no key; a null
    /// previous value means absent, the same as backstop.sh reads it.
    func testLegacyJournalWithoutAppNapKeyDecodesAndNullPreviousIsAbsent() throws {
        let legacy = Data(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#.utf8)
        let st = try Store.makeDecoder().decode(RuntimeState.self, from: legacy)
        XCTAssertEqual(st.appNapOverrides, [])
        XCTAssertFalse(st.isDirty)
        let withNull = Data(#"{"appNapOverrides":[{"bundleId":"com.google.Chrome","previous":null},{"bundleId":"dev.zed.Zed","previous":true}]}"#.utf8)
        let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: withNull)
        XCTAssertEqual(decoded.appNapOverrides, [
            AppNapOverride(bundleId: "com.google.Chrome", previous: nil),
            AppNapOverride(bundleId: "dev.zed.Zed", previous: true),
        ])
        XCTAssertTrue(decoded.isDirty)
    }

    /// A journal written before display darkening existed has neither key.
    func testLegacyJournalWithoutBrightnessKeysDecodes() throws {
        let data = Data(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":0.5,"savedMuted":true}"#.utf8)
        let st = try Store.makeDecoder().decode(RuntimeState.self, from: data)
        XCTAssertNil(st.savedDisplayBrightness)
        XCTAssertNil(st.savedKeyboardBrightness)
        XCTAssertEqual(st.savedOutputVolume, 0.5)
        XCTAssertTrue(st.isDirty)
    }

    /// The write owed after Low Power Mode is journaled next to the saved
    /// values, as a flat number, but is not something to undo: a journal
    /// with only that entry is clean for the backstop and for reconcile.
    func testDisplayRestoredUnderLowPowerRoundTripsAndIsNotDirty() throws {
        var st = RuntimeState()
        st.displayRestoredUnderLowPower = 0.75
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"displayRestoredUnderLowPower\" : 0.75"), text)
        XCTAssertFalse(st.isDirty)
        XCTAssertFalse(st.hasLidActions)

        let legacy = Data(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#.utf8)
        XCTAssertNil(try Store.makeDecoder().decode(RuntimeState.self, from: legacy).displayRestoredUnderLowPower)
    }

    /// The record of our Low Power Mode over a kept display entry stays in
    /// the file, flat, with its boot session, and is neither dirty nor an
    /// undo entry. Written only while set; a journal without it decodes
    /// with none.
    func testKeptDisplayUnderLowPowerRoundTripsAndIsNotDirty() throws {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        st.keptDisplayUnderLowPower = 0.8
        st.keptDisplayUnderLowPowerBoot = "boot-a"
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"keptDisplayUnderLowPower\" : 0.8"), text)
        XCTAssertTrue(text.contains("\"keptDisplayUnderLowPowerBoot\" : \"boot-a\""), text)
        XCTAssertFalse(st.isDirty)
        XCTAssertNil(st.undoEntries.keptDisplayUnderLowPower)
        XCTAssertNil(st.undoEntries.keptDisplayUnderLowPowerBoot)

        try store.saveState(RuntimeState())
        let bare = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertFalse(bare.contains("keptDisplayUnderLowPower"), bare)
        let legacy = Data(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.8,"displayRestoreRefused":true}"#.utf8)
        let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: legacy)
        XCTAssertNil(decoded.keptDisplayUnderLowPower)
        XCTAssertFalse(decoded.keptDisplayReadUnderLowPower(inBoot: "boot-a"), "a journal from before the record is no doubt")
    }

    /// The record holds only for the kept entry it names, with that value
    /// and its flag, in the boot it was written in; a journal write drops
    /// it otherwise. One with no boot session holds, and takes the boot of
    /// the next write that knows it.
    func testKeptDisplayUnderLowPowerHoldsForItsEntryInItsBoot() {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        st.noteLowPowerOverKeptDisplay(ours: false, boot: "boot-a")
        XCTAssertNil(st.keptDisplayUnderLowPower, "recorded with the mode never ours")

        st.noteLowPowerOverKeptDisplay(ours: true, boot: "boot-a")
        XCTAssertEqual(st.keptDisplayUnderLowPower, 0.8)
        XCTAssertEqual(st.keptDisplayUnderLowPowerBoot, "boot-a")
        XCTAssertTrue(st.keptDisplayReadUnderLowPower(inBoot: "boot-a"))
        XCTAssertFalse(st.keptDisplayReadUnderLowPower(inBoot: "boot-b"))
        XCTAssertTrue(st.keptDisplayReadUnderLowPower(inBoot: ""), "a boot not read is no restart")
        var sameBoot = st
        sameBoot.noteLowPowerOverKeptDisplay(ours: false, boot: "boot-a")
        XCTAssertEqual(sameBoot, st, "kept with the mode no longer ours")

        var later = st
        later.noteLowPowerOverKeptDisplay(ours: false, boot: "boot-b")
        XCTAssertNil(later.keptDisplayUnderLowPower)
        XCTAssertNil(later.keptDisplayUnderLowPowerBoot)

        var replaced = st
        replaced.savedDisplayBrightness = 0.7
        XCTAssertFalse(replaced.keptDisplayReadUnderLowPower(inBoot: "boot-a"))
        replaced.noteLowPowerOverKeptDisplay(ours: false, boot: "boot-a")
        XCTAssertNil(replaced.keptDisplayUnderLowPower)

        var unflagged = st
        unflagged.displayRestoreRefused = false
        XCTAssertFalse(unflagged.keptDisplayReadUnderLowPower(inBoot: "boot-a"))
        unflagged.noteLowPowerOverKeptDisplay(ours: true, boot: "boot-a")
        XCTAssertNil(unflagged.keptDisplayUnderLowPower, "an ordinary entry is not recorded")

        var settled = st
        settled.savedDisplayBrightness = nil
        settled.displayRestoreRefused = false
        settled.noteLowPowerOverKeptDisplay(ours: true, boot: "boot-a")
        XCTAssertNil(settled.keptDisplayUnderLowPower)

        var unknown = st
        unknown.keptDisplayUnderLowPowerBoot = nil
        XCTAssertTrue(unknown.keptDisplayReadUnderLowPower(inBoot: "boot-b"))
        unknown.noteLowPowerOverKeptDisplay(ours: false, boot: "boot-b")
        XCTAssertEqual(unknown.keptDisplayUnderLowPower, 0.8)
        XCTAssertEqual(unknown.keptDisplayUnderLowPowerBoot, "boot-b")
        XCTAssertFalse(unknown.keptDisplayReadUnderLowPower(inBoot: "boot-c"), "held until the next restart only")
    }

    /// Our Low Power Mode claim next to a record from another boot is a
    /// claim from before the Mac last started: the record keeps that boot
    /// while the claim stays, is stamped again only when the mode is ours
    /// in this boot, and goes once the claim is cleared. A record with no
    /// boot, a boot not read, no record or another entry is not taken for
    /// one.
    func testLowPowerClaimFromAnEarlierBootKeepsItsRecord() {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        st.lowPowerSetByUs = true
        st.noteLowPowerOverKeptDisplay(ours: true, boot: "boot-a")
        XCTAssertFalse(st.lowPowerClaimFromEarlierBoot(boot: "boot-a"))
        XCTAssertTrue(st.lowPowerClaimFromEarlierBoot(boot: "boot-b"))
        XCTAssertFalse(st.lowPowerClaimFromEarlierBoot(boot: ""), "a boot not read is no restart")

        var later = st
        later.noteLowPowerOverKeptDisplay(ours: false, boot: "boot-b")
        XCTAssertEqual(later, st, "kept, earlier boot and all, while the claim stays")
        XCTAssertFalse(later.keptDisplayReadUnderLowPower(inBoot: "boot-b"))

        var restamped = st
        restamped.noteLowPowerOverKeptDisplay(ours: true, boot: "boot-b")
        XCTAssertEqual(restamped.keptDisplayUnderLowPowerBoot, "boot-b", "the mode ours in this boot")
        XCTAssertFalse(restamped.lowPowerClaimFromEarlierBoot(boot: "boot-b"))

        var cleared = st
        cleared.lowPowerSetByUs = false
        XCTAssertFalse(cleared.lowPowerClaimFromEarlierBoot(boot: "boot-b"))
        cleared.noteLowPowerOverKeptDisplay(ours: false, boot: "boot-b")
        XCTAssertNil(cleared.keptDisplayUnderLowPower)
        XCTAssertNil(cleared.keptDisplayUnderLowPowerBoot)

        var noBoot = st
        noBoot.keptDisplayUnderLowPowerBoot = nil
        XCTAssertFalse(noBoot.lowPowerClaimFromEarlierBoot(boot: "boot-b"))
        XCTAssertTrue(noBoot.keptDisplayReadUnderLowPower(inBoot: "boot-b"), "still doubt")

        var noRecord = st
        noRecord.keptDisplayUnderLowPower = nil
        noRecord.keptDisplayUnderLowPowerBoot = nil
        XCTAssertFalse(noRecord.lowPowerClaimFromEarlierBoot(boot: "boot-b"))

        var replaced = st
        replaced.savedDisplayBrightness = 0.7
        XCTAssertFalse(replaced.lowPowerClaimFromEarlierBoot(boot: "boot-b"))
    }

    /// The record that a kept display entry read above 0 with the lid open
    /// and the panel awake stays in the file, flat, and is neither dirty
    /// nor an undo entry. Written only while set; a journal without it
    /// decodes with none.
    func testKeptDisplayReadLitRoundTripsAndIsNotDirty() throws {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        st.keptDisplayReadLit = 0.8
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"keptDisplayReadLit\" : 0.8"), text)
        XCTAssertTrue(st.keptDisplayReadLitHolds)
        XCTAssertFalse(st.isDirty)
        XCTAssertNil(st.undoEntries.keptDisplayReadLit)

        try store.saveState(RuntimeState())
        let bare = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertFalse(bare.contains("keptDisplayReadLit"), bare)
        let legacy = Data(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.8,"displayRestoreRefused":true}"#.utf8)
        let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: legacy)
        XCTAssertNil(decoded.keptDisplayReadLit)
        XCTAssertFalse(decoded.keptDisplayReadLitHolds, "a journal from before the record has no reading above 0")
    }

    /// It holds only for the kept entry it names, with that value and its
    /// flag; the normalization every journal write runs drops it once the
    /// entry is settled, unflagged or replaced.
    func testKeptDisplayReadLitHoldsOnlyForItsEntry() {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        st.keptDisplayReadLit = 0.8
        var kept = st
        kept.dropKeptDisplayReadLitUnlessKept()
        XCTAssertEqual(kept, st)

        var settled = st
        settled.savedDisplayBrightness = nil
        settled.displayRestoreRefused = false
        XCTAssertFalse(settled.keptDisplayReadLitHolds)
        settled.dropKeptDisplayReadLitUnlessKept()
        XCTAssertNil(settled.keptDisplayReadLit)

        var unflagged = st
        unflagged.displayRestoreRefused = false
        XCTAssertFalse(unflagged.keptDisplayReadLitHolds, "an ordinary entry is restored, not judged")
        unflagged.dropKeptDisplayReadLitUnlessKept()
        XCTAssertNil(unflagged.keptDisplayReadLit)

        var replaced = st
        replaced.savedDisplayBrightness = 0.7
        XCTAssertFalse(replaced.keptDisplayReadLitHolds)
        replaced.dropKeptDisplayReadLitUnlessKept()
        XCTAssertNil(replaced.keptDisplayReadLit)

        var stray = RuntimeState()
        stray.keptDisplayReadLit = 0.8
        stray.dropKeptDisplayReadLitUnlessKept()
        XCTAssertNil(stray.keptDisplayReadLit)
    }

    func testSavedBrightnessCountsAsDirty() throws {
        var st = RuntimeState()
        XCTAssertFalse(st.isDirty)
        st.savedDisplayBrightness = 0.5
        XCTAssertTrue(st.isDirty)
        st = RuntimeState()
        st.savedKeyboardBrightness = 0
        XCTAssertTrue(st.isDirty)
    }

    /// A saved brightness kept after a refused restore stays in the file
    /// with its flag, flat for the scripts, and is not dirty. The flags are
    /// written only while set, and a journal without them decodes as not
    /// refused.
    func testRefusedBrightnessRoundTripsAndIsNotDirty() throws {
        var st = RuntimeState()
        st.savedDisplayBrightness = 0.8
        st.displayRestoreRefused = true
        st.savedKeyboardBrightness = 0.3
        st.keyboardRestoreRefused = true
        try store.saveState(st)
        XCTAssertEqual(try store.loadState(), st)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"displayRestoreRefused\" : true"), text)
        XCTAssertTrue(text.contains("\"keyboardRestoreRefused\" : true"), text)
        XCTAssertTrue(st.brightnessJournaled, "the open still wakes a display a close may have put to sleep")
        XCTAssertTrue(st.hasRefusedBrightness)
        XCTAssertFalse(st.hasLidActions)
        XCTAssertFalse(st.isDirty)

        st.keyboardRestoreRefused = false
        XCTAssertTrue(st.isDirty, "an unflagged entry is still one to restore")

        var plain = RuntimeState()
        plain.savedDisplayBrightness = 0.5
        try store.saveState(plain)
        let plainText = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertFalse(plainText.contains("RestoreRefused"), plainText)
        XCTAssertFalse(try XCTUnwrap(try store.loadState()).displayRestoreRefused)

        var flagOnly = RuntimeState()
        flagOnly.displayRestoreRefused = true
        XCTAssertFalse(flagOnly.hasRefusedBrightness, "a flag without a value keeps nothing")
        XCTAssertFalse(flagOnly.isDirty)
    }

    /// Reconcile keeps lid-close actions while the lid is closed; every
    /// entry a lid close can write must count, not only freezes and audio.
    func testHasLidActionsCoversEveryLidCloseEntry() throws {
        XCTAssertFalse(RuntimeState.clean.hasLidActions)
        var sleepOnly = RuntimeState()
        sleepOnly.sleepDisabledByUs = true
        sleepOnly.lowPowerSetByUs = true
        XCTAssertFalse(sleepOnly.hasLidActions, "sleep and Low Power Mode are not lid-close actions")

        var frozen = RuntimeState()
        frozen.frozenProcesses = [FrozenProcess(pid: 1, startedAt: nil)]
        XCTAssertTrue(frozen.hasLidActions)
        var docker = RuntimeState()
        docker.dockerFrozen = true
        XCTAssertTrue(docker.hasLidActions)
        var volume = RuntimeState()
        volume.savedOutputVolume = 0.5
        XCTAssertTrue(volume.hasLidActions)
        var muted = RuntimeState()
        muted.savedMuted = false
        XCTAssertTrue(muted.hasLidActions)
        var display = RuntimeState()
        display.savedDisplayBrightness = 0.5
        XCTAssertTrue(display.hasLidActions)
        var keyboard = RuntimeState()
        keyboard.savedKeyboardBrightness = 0.5
        XCTAssertTrue(keyboard.hasLidActions)
    }

    /// backstop.sh reads the same file: each frozen process carries its
    /// kernel start time under the key the script looks for, and the legacy
    /// identity-less list is no longer written.
    func testStateWritesProcessIdentityForTheBackstop() throws {
        var st = RuntimeState()
        st.frozenProcesses = [FrozenProcess(pid: 12, startedAt: 1_700_000_000)]
        try store.saveState(st)
        let text = try String(contentsOf: home.paths.stateFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"frozenProcesses\""), text)
        XCTAssertTrue(text.contains("\"pid\" : 12"), text)
        XCTAssertTrue(text.contains("\"startedAt\" : 1700000000"), text)
        XCTAssertTrue(text.contains("\"startedAtMicros\" : 0"), text)
        XCTAssertTrue(text.contains("\"bootSession\" : \"boot\""), text)
        XCTAssertFalse(text.contains("frozenPids"), text)
    }

    /// A journal written by an older build lists bare pids. They decode as
    /// entries with no identity, which still count as dirty so the limitation
    /// is reported rather than silently dropped.
    func testLegacyFrozenPidsDecodeWithoutIdentity() throws {
        let data = Data(#"{"sleepDisabledByUs": false, "frozenPids": [12, 34]}"#.utf8)
        let st = try Store.makeDecoder().decode(RuntimeState.self, from: data)
        XCTAssertEqual(st.frozenProcesses, [FrozenProcess(pid: 12, startedAt: nil), FrozenProcess(pid: 34, startedAt: nil)])
        XCTAssertTrue(st.isDirty)
    }

    func testDatesAreISO8601ForBackstopScript() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveSession(Session(startedAt: t0, endsAt: t0))
        let text = try String(contentsOf: home.paths.sessionFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"endsAt\" : \"2027-01-15T08:00:00Z\""), text)
    }

    /// Store.parseDate takes `Z` or an offset and gives the same instant;
    /// anything else is refused, including dates JSONDecoder's `.iso8601`
    /// took. RecoveryScriptTests checks the scripts read the same table.
    func testParseDateReadsOffsetsAndRefusesEverythingElse() {
        let read: [(String, TimeInterval)] = [
            ("2027-01-15T08:00:00Z", 1_800_000_000),
            ("2027-01-15T10:00:00+02:00", 1_800_000_000),
            ("2027-01-15T02:30:00-05:30", 1_800_000_000),
            ("2027-01-16T07:59:00+23:59", 1_800_000_000),
            ("2027-01-15T08:00:00-00:00", 1_800_000_000),
            ("1970-01-01T00:30:00+01:00", -1800),
            ("2028-02-29T00:00:00Z", 1_835_395_200),
        ]
        for (text, seconds) in read {
            XCTAssertEqual(Store.parseDate(text)?.timeIntervalSince1970, seconds, text)
        }
        for text in ["2027-02-30T08:00:00Z", "2027-02-29T08:00:00Z", "2027-01-15T24:00:00Z", "2027-01-15T08:00:60Z",
                     "2027-01-15T08:00:00Zjunk", "2027-01-15T08:00:00GMT", "2027-01-15T08:00:00+0200", "2027-01-15T08:00:00+02",
                     "2027-01-15T08:00:00+24:00", "2027-01-15T08:00:00.5Z", "2027-01-15T08:00:00z", "2027-1-5T8:0:0Z",
                     "1969-12-31T23:59:59Z", "10000-01-01T00:00:00Z", ""] {
            XCTAssertNil(Store.parseDate(text), text)
        }
        let decoded = try? Store.makeDecoder().decode(Session.self, from: Data(#"{"startedAt":"2027-01-15T08:00:00Z","endsAt":"2027-02-30T08:00:00Z","extensions":[]}"#.utf8))
        XCTAssertNil(decoded, "the decoder used .iso8601, which rolls February 30 over to March 2")
    }

    /// Every date the encoder writes, the decoder reads back.
    func testEveryDateTheEncoderWritesIsReadBack() throws {
        for seconds: TimeInterval in [0, 1_800_000_000, 1_835_395_200, 253_402_300_799] {
            let t = Date(timeIntervalSince1970: seconds)
            try store.saveSession(Session(startedAt: t, endsAt: t))
            XCTAssertEqual(try store.loadSession()?.endsAt, t, "\(seconds)")
        }
    }

    func testAtomicWriteLeavesNoTempFile() throws {
        try store.saveState(RuntimeState())
        try store.saveState(RuntimeState())
        let names = try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path)
        XCTAssertEqual(names.filter { $0.contains(".tmp-") }, [])
        XCTAssertTrue(names.contains("state.json"))
    }

    func testOverwriteReplacesContent() throws {
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try store.saveState(st)
        try store.saveState(RuntimeState())
        XCTAssertEqual(try store.loadState(), RuntimeState())
    }

    func testRemoveMissingIsNotAnError() throws {
        XCTAssertNoThrow(try store.deleteSession())
    }

    func testStateDecodesWithMissingKeys() throws {
        let data = Data(#"{"sleepDisabledByUs": true}"#.utf8)
        let st = try Store.makeDecoder().decode(RuntimeState.self, from: data)
        XCTAssertTrue(st.sleepDisabledByUs)
        XCTAssertEqual(st.frozenProcesses, [])
        XCTAssertNil(st.savedOutputVolume)
        XCTAssertNil(st.savedDisplayBrightness)
        XCTAssertNil(st.savedKeyboardBrightness)
    }

    func testPathsFromEnvironment() {
        let p = Paths.fromEnvironment(["INSOMNIA_HOME": "/tmp/x"])
        XCTAssertEqual(p.sessionFile.path, "/tmp/x/session.json")
        XCTAssertEqual(p.recoveryLock.path, "/tmp/x/.recovery.lock")
        XCTAssertEqual(p.logFile.path, "/tmp/x/Logs/insomnia.log")
        XCTAssertEqual(p.backstopPlist.path, "/tmp/x/LaunchAgents/com.insomnia.backstop.plist")
        let std = Paths.fromEnvironment([:])
        XCTAssertTrue(std.sessionFile.path.hasSuffix("/Library/Application Support/Insomnia/session.json"))
        XCTAssertTrue(std.backstopPlist.path.hasSuffix("/Library/LaunchAgents/com.insomnia.backstop.plist"))
    }

    /// A journal that does not decode is evidence of what a previous run
    /// changed. It is left exactly where it is, never moved or overwritten,
    /// and every later read keeps failing until a person deals with it: the
    /// next reader (this app, backstop.sh, uninstall.sh) must not see "no
    /// journal" and call the machine clean.
    /// A journal that is a FIFO is never opened (open(2) would block until a
    /// writer appears). The read fails instead and the FIFO stays.
    func testStateThatIsAFIFOIsNotOpenedAndFailsTheRead() throws {
        try FileManager.default.createDirectory(at: home.paths.appSupport, withIntermediateDirectories: true)
        let fifo = try FIFOWatch(at: home.paths.stateFile)
        defer { fifo.stop() }

        XCTAssertThrowsError(try store.loadState()) { error in
            guard case StoreError.notRegularFile = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains(home.paths.stateFile.path), error.localizedDescription)
        }
        XCTAssertFalse(fifo.readerSeen, "state.json was opened although it is a FIFO")
        XCTAssertTrue(fifo.isStillFIFO)
    }

    func testCorruptStateIsLeftInPlaceAndKeepsFailing() throws {
        try Data("{not json".utf8).write(to: home.paths.stateFile)
        for _ in 0..<2 {
            XCTAssertThrowsError(try store.loadState()) { error in
                guard case StoreError.corrupt = error else { return XCTFail("\(error)") }
                XCTAssertTrue(error.localizedDescription.contains(home.paths.stateFile.path), error.localizedDescription)
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("state.json") }, ["state.json"], "\(names)")
        XCTAssertEqual(try String(contentsOf: home.paths.stateFile, encoding: .utf8), "{not json")
    }
}
