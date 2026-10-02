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
