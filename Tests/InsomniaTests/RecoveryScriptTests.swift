import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// One backslash, for the JSON escapes in the texts below, which then read
/// as they are in the file: "\#(backslash)u0041" is a \u escape in it.
private let backslash = "\\"

/// Behavioural tests for scripts/backstop.sh and scripts/uninstall.sh.
///
/// Each test runs a private COPY of the production script against a
/// throwaway INSOMNIA_HOME. The copy has its fixed tool-path constants
/// (sudo, pmset, ps, kill, sysctl, pgrep, pkill, osascript, launchctl,
/// defaults) and its app-bundle / sudoers paths rewritten to point inside
/// the fixture, so nothing privileged runs, no real process is signaled, no
/// real app's preferences are read or written, and no real home,
/// LaunchAgent, sudoers file, or installed app is read or written. plutil
/// and lockf are the real tools, and so is date, except for the backstop's
/// moved-aside stamp, which a test can freeze. The fakes record every call.
final class RecoveryScriptTests: XCTestCase {
    private var fx: ScriptFixture!

    override func setUpWithError() throws {
        fx = try ScriptFixture()
    }

    override func tearDown() {
        fx.destroy()
        fx = nil
    }

    // MARK: - backstop.sh

    func testPrivilegedCommandFailureExitsNonzeroAndKeepsJournal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false,"extra":"keep"}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "sudo -n \(fx.fakePmset) -b lowpowermode 0",
        ])
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true, "a failed pmset must stay journaled")
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
        XCTAssertEqual(s["extra"] as? String, "keep")
        XCTAssertTrue(fx.exists(fx.session), "expired session is evidence while the journal is dirty")
        let log = fx.log()
        XCTAssertTrue(log.contains("journal kept dirty"), log)
        XCTAssertFalse(log.contains("journal cleared"), log)
    }

    func testCleanIdleRunsNoCommandsAndTouchesNothing() throws {
        let clean = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"someFutureKey":[1,2]}"#
        try fx.writeState(clean)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [], "an idle run must not touch pmset, sudo, or any process")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), clean, "journal must not be rewritten")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.logFile), "an idle minute must not spam the log")
    }

    func testMissingJournalAndNoSessionDoesNothing() throws {
        let r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.state), "must not seed a journal")
    }

    func testValidFutureSessionIsNoOpWithoutForce() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.writeState(dirty)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)
        XCTAssertTrue(fx.exists(fx.session))
    }

    func testForceEndsValidSession() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop, ["--force"])

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
    }

    func testExpiredSessionRestoresEverythingAndClearsJournal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":true,"lowPowerSetByUs":true,"dockerFrozen":true,"keepMe":{"x":1},
         "frozenProcesses":[{"pid":4242,"startedAt":\(started),"startedAtMicros":17,"bootSession":"\(fx.bootUUID)"}]}
        """)
        try fx.psTable([(4242, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "sudo -n \(fx.fakePmset) -b lowpowermode 0",
            "Insomnia --resume-frozen 2 < 4242 \(started) 17 \(fx.bootUUID)",
        ], "an entry with microseconds is resumed by the app binary, never by ps and kill")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(s["dockerFrozen"] as? Bool, false)
        XCTAssertEqual((s["frozenProcesses"] as? [Any])?.count, 0)
        XCTAssertEqual((s["keepMe"] as? [String: Any])?["x"] as? Int, 1, "unknown keys survive the rewrite")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
    }

    func testFailedSigcontStaysJournaledWithIdentity() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":true,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[
           {"pid":111,"startedAt":\(started),"startedAtMicros":1,"bootSession":"\(fx.bootUUID)"},
           {"pid":222,"startedAt":\(started),"startedAtMicros":2,"bootSession":"\(fx.bootUUID)","note":"custom"}]}
        """)
        try fx.insomniaTable([(222, "failed")])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "Insomnia --resume-frozen 2 < 111 \(started) 1 \(fx.bootUUID); 222 \(started) 2 \(fx.bootUUID)",
        ], "both entries in one call, no ps and no kill")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false, "an unrelated stuck pid must not hold sleep disabled")
        let frozen = try XCTUnwrap(s["frozenProcesses"] as? [[String: Any]])
        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen.first?["pid"] as? Int, 222)
        XCTAssertEqual(frozen.first?["startedAt"] as? Int, started, "identity must survive for the next attempt")
        XCTAssertEqual(frozen.first?["startedAtMicros"] as? Int, 2)
        XCTAssertEqual(frozen.first?["bootSession"] as? String, fx.bootUUID)
        XCTAssertEqual(frozen.first?["note"] as? String, "custom")
        XCTAssertEqual(s["dockerFrozen"] as? Bool, true, "dockerFrozen clears only once no frozen process remains")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("222"), fx.log())
    }

    func testLegacyAndIdentitylessPidsAreNeverSignaledAndStayDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"dockerFrozen":false,"frozenPids":[333],"frozenProcesses":[{"pid":444}]}"#)
        // Both look stopped right now; that still proves nothing about ownership.
        try fx.psTable([(333, fx.lstart(1_700_000_000), "T", fx.uid), (444, fx.lstart(1_700_000_000), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "no ps lookup, no signal for unverifiable pids")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["frozenPids"] as? [Int], [333])
        XCTAssertEqual((s["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 444)
        XCTAssertTrue(fx.log().contains("333"), fx.log())
        XCTAssertTrue(fx.log().contains("444"), fx.log())
    }

    /// Entries without microseconds (an older build) keep the one-second
    /// ps comparison in the shell.
    func testGoneRunningOrMismatchedProcessesClearWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[
           {"pid":301,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"},
           {"pid":302,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"},
           {"pid":303,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"},
           {"pid":304,"startedAt":\(started),"bootSession":"other-boot"},
           {"pid":305,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"}]}
        """)
        try fx.psTable([
            // 301 is gone (not in the table).
            (302, fx.lstart(started), "S+", fx.uid),          // running again
            (303, fx.lstart(started + 1), "T", fx.uid),       // reused pid, different start second
            (304, fx.lstart(started), "T", fx.uid),           // stopped, but journaled in another boot
            (305, fx.lstart(started), "T", "0"),              // stopped, but not our uid
        ])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") || $0.hasPrefix("Insomnia") }, "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains("ps -o lstart=,stat=,uid= -p 304"), "another boot needs no lookup")
        let s = try fx.stateJSON()
        XCTAssertEqual((s["frozenProcesses"] as? [Any])?.count, 0)
        XCTAssertEqual(s["dockerFrozen"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
    }

    func testSavedAudioIsPreservedAndReportedAsUnresolved() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":0.5,"savedMuted":true}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, "audio needs the app; the run is not complete")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false, "sleep is still restored")
        XCTAssertEqual(s["savedOutputVolume"] as? Double, 0.5)
        XCTAssertEqual(s["savedMuted"] as? Bool, true)
        XCTAssertTrue(fx.log().contains("Open Insomnia"), fx.log())
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())
    }

    /// An output device muted on lid close can wait days to be connected
    /// again. Its entry stays byte for byte for the app, which shows it in
    /// the menu; on its own it does not make the run fail, so the agent
    /// does not log an error every minute, and an expired session goes.
    func testSavedOutputDeviceAudioIsKeptAndAloneLeavesTheJournalClean() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","name":"USB Headset","volume":0.3,"muted":false,"saveID":"5F2C9A10-7B3E-4D21-A8C4-0E6F1B2D3C4A"},{"deviceUID":"BuiltInSpeakerDevice","name":null,"volume":1,"muted":true,"saveID":null}]}"#
        try fx.writeState(json)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), json)
        XCTAssertTrue(fx.log().contains("saved audio for 2 output device(s), kept for the app"), fx.log())
        XCTAssertFalse(fx.log().contains("[error]"), fx.log())

        // With no session to remove, a later run says nothing.
        let before = fx.log()
        XCTAssertEqual(try fx.run(fx.backstop).status, 0)
        XCTAssertEqual(fx.log(), before)
    }

    /// Undoing the rest of the journal keeps every output device entry as
    /// it was.
    func testSavedOutputDeviceAudioSurvivesTheUndoOfSleep() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","name":"USB Headset","volume":0.3,"muted":false,"saveID":"5F2C9A10-7B3E-4D21-A8C4-0E6F1B2D3C4A"}]}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertTrue(fx.calls().first?.hasSuffix("pmset -a disablesleep 0") ?? false, fx.calls().description)
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        let outputs = try XCTUnwrap(s["savedAudioOutputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?["deviceUID"] as? String, "usb-headset")
        XCTAssertEqual(outputs.first?["name"] as? String, "USB Headset")
        XCTAssertEqual(outputs.first?["volume"] as? Double, 0.3)
        XCTAssertEqual(outputs.first?["muted"] as? Bool, false)
        XCTAssertEqual(outputs.first?["saveID"] as? String, "5F2C9A10-7B3E-4D21-A8C4-0E6F1B2D3C4A")
        XCTAssertTrue(fx.log().contains("journal cleared apart from saved audio for 1 output device(s)"), fx.log())
        XCTAssertFalse(fx.exists(fx.session))
    }

    /// Display brightness and keyboard backlight saved on lid close are
    /// restored only by the app; the backstop keeps both keys, still undoes
    /// the rest, and says so.
    func testSavedDisplayAndKeyboardArePreservedAndReportedAsUnresolved() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.75,"savedKeyboardBrightness":0.25}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, "display and keyboard need the app; the run is not complete")
        XCTAssertEqual(fx.calls().count, 1, "sleep is still restored; nothing else runs")
        XCTAssertTrue(fx.calls().first?.hasSuffix("pmset -a disablesleep 0") ?? false, fx.calls().description)
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["savedDisplayBrightness"] as? Double, 0.75)
        XCTAssertEqual(s["savedKeyboardBrightness"] as? Double, 0.25)
        XCTAssertTrue(fx.log().contains("Open Insomnia"), fx.log())
        XCTAssertTrue(fx.log().contains("display brightness"), fx.log())
        XCTAssertTrue(fx.log().contains("keyboard backlight"), fx.log())
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())
    }

    /// The write the app owes after its Low Power Mode is not the
    /// backstop's to make or to judge: the key is kept through the run and
    /// does not keep the journal dirty on its own. The app drops it on
    /// relaunch when it finds the mode cleared.
    func testDisplayRestoredUnderLowPowerIsIgnoredAndPreserved() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false,"displayRestoredUnderLowPower":0.75}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(s["displayRestoredUnderLowPower"] as? Double, 0.75)
    }

    /// A journal whose only entry is a saved display brightness is dirty:
    /// the backstop must not report it clean and must keep retrying.
    func testSavedDisplayBrightnessAloneKeepsTheJournalDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedKeyboardBrightness":0.5}"#
        try fx.writeState(json)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try fx.stateJSON()["savedKeyboardBrightness"] as? Double, 0.5)
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())
    }

    /// A brightness the app kept because its private-call guard refused
    /// the restore on this macOS is kept here too, with its flag, but does
    /// not keep the journal dirty: the rest is undone, the run succeeds,
    /// and the log says why the value stays instead of asking to open the
    /// app, which could not restore it either.
    func testRefusedBrightnessIsKeptWithoutKeepingTheJournalDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.75,"displayRestoreRefused":true,"savedKeyboardBrightness":0.25,"keyboardRestoreRefused":true}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls().count, 1, fx.calls().description)
        XCTAssertTrue(fx.calls().first?.hasSuffix("pmset -a disablesleep 0") ?? false, fx.calls().description)
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(s["savedDisplayBrightness"] as? Double, 0.75)
        XCTAssertEqual(s["displayRestoreRefused"] as? Bool, true)
        XCTAssertEqual(s["savedKeyboardBrightness"] as? Double, 0.25)
        XCTAssertEqual(s["keyboardRestoreRefused"] as? Bool, true)
        XCTAssertTrue(fx.log().contains("saved display brightness,saved keyboard backlight kept: the app's private-call guard refused that restore on this macOS"), fx.log())
        XCTAssertFalse(fx.log().contains("Open Insomnia"), fx.log())
        XCTAssertFalse(fx.log().contains("[error]"), fx.log())
    }

    /// Only refused brightness left: the journal counts as clean, an
    /// expired session is removed, nothing privileged runs, and with no
    /// session the periodic run exits 0 without a word, instead of failing
    /// every minute for something it can never restore.
    func testRefusedBrightnessAloneIsNotDirty() throws {
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6,"displayRestoreRefused":true}"#
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(json)

        let expired = try fx.run(fx.backstop)

        XCTAssertEqual(expired.status, 0, expired.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), json, "the journal is not rewritten")
        XCTAssertTrue(fx.log().contains("journal already clean"), fx.log())
        XCTAssertTrue(fx.log().contains("saved display brightness kept: the app's private-call guard refused that restore"), fx.log())

        let before = fx.log()
        let periodic = try fx.run(fx.backstop)

        XCTAssertEqual(periodic.status, 0, periodic.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(fx.log(), before, "nothing to report on a run with nothing to do")
    }

    /// The flag covers only its own device: an unflagged keyboard entry
    /// next to a refused display still needs the app.
    func testAnUnflaggedEntryNextToARefusedOneStillNeedsTheApp() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6,"displayRestoreRefused":true,"savedKeyboardBrightness":0.4}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertTrue(fx.log().contains("saved keyboard backlight can only be restored by the app; kept. Open Insomnia"), fx.log())
        XCTAssertTrue(fx.log().contains("saved display brightness kept: the app's private-call guard refused"), fx.log())
        XCTAssertEqual(try fx.stateJSON()["savedKeyboardBrightness"] as? Double, 0.4)
    }

    // MARK: App Nap

    /// `NSAppSleepDisabled` the app set for agent apps is put back with the
    /// same tool a person would use: `defaults write` for a recorded value,
    /// `defaults delete` when the key was absent. Each entry is cleared
    /// once its command succeeded; the rest of the journal is unaffected.
    func testAppNapOverridesAreRestoredWithDefaultsAndCleared() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState("""
        {"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"keepMe":1,
         "appNapOverrides":[
           {"bundleId":"com.google.Chrome"},
           {"bundleId":"com.apple.Terminal","previous":false},
           {"bundleId":"dev.zed.Zed","previous":true},
           {"bundleId":"org.chromium.Chromium","previous":null}]}
        """)
        try fx.defaultsTable([("com.google.Chrome", "1"), ("com.apple.Terminal", "1"), ("dev.zed.Zed", "1"), ("org.chromium.Chromium", "1")])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [
            "sudo -n \(fx.fakePmset) -a disablesleep 0",
            "defaults delete com.google.Chrome NSAppSleepDisabled",
            "defaults write com.apple.Terminal NSAppSleepDisabled -bool false",
            "defaults write dev.zed.Zed NSAppSleepDisabled -bool true",
            "defaults delete org.chromium.Chromium NSAppSleepDisabled",
        ])
        XCTAssertEqual(fx.defaultsValues(), ["com.apple.Terminal": "0", "dev.zed.Zed": "1"], "absent keys deleted, recorded values written")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual((s["appNapOverrides"] as? [Any])?.count, 0)
        XCTAssertEqual(s["keepMe"] as? Int, 1, "unknown keys survive the rewrite")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
    }

    /// A journal whose only entries are App Nap overrides is dirty: the
    /// backstop restores them instead of calling the machine clean.
    func testAppNapOverridesAloneKeepTheJournalDirtyUntilRestored() throws {
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":"com.google.Chrome"}]}"#)
        try fx.defaultsTable([("com.google.Chrome", "1")])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["defaults delete com.google.Chrome NSAppSleepDisabled"])
        XCTAssertEqual(fx.defaultsValues(), [:])
        XCTAssertEqual((try fx.stateJSON()["appNapOverrides"] as? [Any])?.count, 0)
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
    }

    /// A `defaults` that fails leaves its entry verbatim (unknown fields
    /// included) for the next run; the other entries still complete.
    func testFailedDefaultsKeepsAppNapEntryVerbatim() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,
         "appNapOverrides":[
           {"bundleId":"com.google.Chrome","previous":false,"note":"custom"},
           {"bundleId":"com.apple.Terminal"}]}
        """)
        try fx.defaultsTable([("com.google.Chrome", "1"), ("com.apple.Terminal", "1")])
        fx.setMode("defaults", "fail:com.google.Chrome")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [
            "defaults write com.google.Chrome NSAppSleepDisabled -bool false",
            "defaults delete com.apple.Terminal NSAppSleepDisabled",
        ])
        XCTAssertEqual(fx.defaultsValues(), ["com.google.Chrome": "1"])
        let kept = try XCTUnwrap(try fx.stateJSON()["appNapOverrides"] as? [[String: Any]])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["bundleId"] as? String, "com.google.Chrome")
        XCTAssertEqual(kept.first?["previous"] as? Bool, false, "the value to put back survives for the next attempt")
        XCTAssertEqual(kept.first?["note"] as? String, "custom")
        XCTAssertTrue(fx.exists(fx.session), "evidence stays while the journal is dirty")
        XCTAssertTrue(fx.log().contains("still journaled: App Nap is still off for com.google.Chrome"), fx.log())
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())
    }

    /// `defaults delete` fails when the key is already gone (the app put it
    /// back but could not clear the entry, or the user deleted it by hand).
    /// That is the wanted state: the entry clears after a read confirms the
    /// key is absent. A delete that fails with the key still set is kept.
    func testDeleteOfAlreadyAbsentKeyCountsAsRestored() throws {
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":"com.google.Chrome"},{"bundleId":"com.apple.Terminal"}]}"#)
        try fx.defaultsTable([("com.apple.Terminal", "1")])
        fx.setMode("defaults", "fail:com.apple.Terminal")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [
            "defaults delete com.google.Chrome NSAppSleepDisabled",
            "defaults read com.google.Chrome NSAppSleepDisabled",
            "defaults delete com.apple.Terminal NSAppSleepDisabled",
            "defaults read com.apple.Terminal NSAppSleepDisabled",
        ])
        let kept = try XCTUnwrap(try fx.stateJSON()["appNapOverrides"] as? [[String: Any]])
        XCTAssertEqual(kept.map { $0["bundleId"] as? String }, ["com.apple.Terminal"])
        XCTAssertTrue(fx.log().contains("com.google.Chrome NSAppSleepDisabled: the key is already absent"), fx.log())
        XCTAssertTrue(fx.log().contains("com.apple.Terminal NSAppSleepDisabled failed and the key is still set"), fx.log())
    }

    /// A failed delete followed by a read that fails for any reason other
    /// than "does not exist" (cfprefsd not answering, say) proves nothing
    /// about the key. The entry stays, the run fails, and the next run
    /// finishes the job once `defaults` answers again.
    func testDeleteAndReadBothFailingKeepsTheEntryForTheNextRun() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":"com.google.Chrome"}]}"#)
        try fx.defaultsTable([("com.google.Chrome", "1")])
        fx.setMode("defaults", "unreachable")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [
            "defaults delete com.google.Chrome NSAppSleepDisabled",
            "defaults read com.google.Chrome NSAppSleepDisabled",
        ])
        XCTAssertEqual(fx.defaultsValues(), ["com.google.Chrome": "1"], "nothing changed")
        let kept = try XCTUnwrap(try fx.stateJSON()["appNapOverrides"] as? [[String: Any]])
        XCTAssertEqual(kept.map { $0["bundleId"] as? String }, ["com.google.Chrome"], "the entry is kept, not cleared as absent")
        XCTAssertTrue(fx.exists(fx.session), "evidence stays while the journal is dirty")
        XCTAssertTrue(fx.log().contains("defaults read could not tell whether the key is still set"), fx.log())
        XCTAssertFalse(fx.log().contains("already absent"), fx.log())
        XCTAssertFalse(fx.log().contains("journal cleared"), fx.log())

        fx.setMode("defaults", "ok")
        fx.clearCalls()
        let after = try fx.run(fx.backstop)
        XCTAssertEqual(after.status, 0, after.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["defaults delete com.google.Chrome NSAppSleepDisabled"])
        XCTAssertEqual(fx.defaultsValues(), [:])
        XCTAssertEqual((try fx.stateJSON()["appNapOverrides"] as? [Any])?.count, 0)
    }

    /// An entry without a usable bundle id is never passed to `defaults`
    /// (a leading dash would be read as an option) and stays journaled.
    func testAppNapEntryWithoutUsableBundleIdIsKeptWithoutCommands() throws {
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":""},{"bundleId":"-currentHost","previous":true}]}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual((try fx.stateJSON()["appNapOverrides"] as? [Any])?.count, 2)
        XCTAssertTrue(fx.log().contains("no usable bundle id"), fx.log())
    }

    func testMalformedJournalBlocksWithoutCommandsAndKeepsEvidence() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let broken = #"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":"#
        try fx.writeState(broken)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "no privileged command without a readable journal")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), broken, "never seed a clean journal over evidence")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("malformed"), fx.log())
    }

    func testExpiredSessionWithMissingJournalRunsNothingPrivileged() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [], "nothing journaled means nothing to undo")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.state))
    }

    // MARK: - Unreadable session.json

    /// Names in APP_SUPPORT of the shape the app and backstop.sh give a
    /// moved-aside session.json.
    private func movedAsideSessions() throws -> [String] {
        try fx.contents(of: fx.home).filter { $0.hasPrefix("session.json.unreadable-") }.sorted()
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// A session.json that is not a session, with a clean journal: nothing
    /// to undo, the file is renamed to a timestamped sibling so the next run
    /// sees no session, and that next run is idle.
    func testMalformedSessionWithCleanJournalIsMovedAsideAndNextRunIsIdle() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [], "nothing journaled means nothing privileged")
        XCTAssertFalse(fx.exists(fx.session), "session.json left in place")
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        let name = try XCTUnwrap(moved.first)
        XCTAssertNotNil(name.range(of: #"^session\.json\.unreadable-[0-9]{8}T[0-9]{6}Z$"#, options: .regularExpression), name)
        XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent(name), encoding: .utf8), "not json", "bytes kept as they were")
        XCTAssertTrue(fx.log().contains("[warn] backstop: session.json unreadable; moved to \(fx.home.appendingPathComponent(name).path)"), fx.log())

        let again = try fx.run(fx.backstop)
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertEqual(try movedAsideSessions(), [name], "a second run moved something else")
    }

    /// A brightness kept after a refused restore is not dirty, so it does
    /// not hold back the move; it stays in the journal, and the log says
    /// why, as it does when an expired session is removed.
    func testMalformedSessionNextToARefusedBrightnessIsMovedAsideAndTheValueKept() throws {
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6,"displayRestoreRefused":true}"#
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(json)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.session), "session.json left in place")
        XCTAssertEqual(try movedAsideSessions().count, 1)
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), json, "the journal is not rewritten")
        XCTAssertTrue(fx.log().contains("saved display brightness kept: the app's private-call guard refused that restore"), fx.log())
    }

    /// While the journal stays dirty the file stays too: the next run must
    /// still see a session that is not valid, not a machine with nothing
    /// pending.
    func testMalformedSessionIsKeptWhileTheJournalStaysDirty() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.session), "session.json moved although the undo failed")
        XCTAssertEqual(try movedAsideSessions(), [])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    /// After the undo succeeds the journal is clean, and the file is moved
    /// aside in the same run instead of being left for a person.
    func testMalformedSessionIsMovedAsideAfterASuccessfulUndo() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertTrue(fx.calls().contains { $0.contains("disablesleep 0") }, "\(fx.calls())")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions().count, 1)
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
    }

    /// A moved-aside file is never replaced: with the stamp already taken
    /// the new one gets -1, and with -1 taken too, -2. The stamp is frozen,
    /// so the names taken first are exactly the ones the script tries.
    func testMalformedSessionNeverOverwritesAnEarlierMovedAsideFile() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("date", "20260101T000000Z")
        let taken = ["session.json.unreadable-20260101T000000Z", "session.json.unreadable-20260101T000000Z-1"]
        for name in taken {
            try "earlier".write(to: fx.home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        for name in taken {
            XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent(name), encoding: .utf8), "earlier", "\(name) was overwritten")
        }
        XCTAssertEqual(try movedAsideSessions(), taken + ["session.json.unreadable-20260101T000000Z-2"])
        XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent("session.json.unreadable-20260101T000000Z-2"), encoding: .utf8), "not json")
    }

    /// A session.json whose endsAt parses but that lacks what the app's
    /// Session decoder requires is not a session. Its endsAt is in the
    /// future, which used to count as a valid session and leave sleep
    /// disabled; now the journal is undone and the file moved aside, each
    /// problem logged.
    func testSessionWithAFutureEndsAtButMissingFieldsIsNotASession() throws {
        let f = ISO8601DateFormatter()
        let json = #"{"endsAt":"\#(f.string(from: Date(timeIntervalSinceNow: 3600)))"}"#
        try json.write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        XCTAssertEqual(try String(contentsOf: fx.home.appendingPathComponent(moved[0]), encoding: .utf8), json, "bytes kept as they were")
        XCTAssertTrue(fx.log().contains("startedAt is missing"), fx.log())
        XCTAssertTrue(fx.log().contains("extensions is missing"), fx.log())
    }

    /// Keys of the wrong type, the way the decoder refuses them: a number
    /// for a date, an array element that is not a number, a date that is
    /// not in the form Store.swift writes, a property list instead of JSON.
    /// Nothing journaled, so nothing runs; the file is moved aside.
    func testSessionWithFieldsOfTheWrongTypeIsNotASession() throws {
        let cases = [
            #"{"startedAt":12,"endsAt":"2099-01-01T00:00:00Z","extensions":[]}"#,
            #"{"startedAt":"2026-01-01T00:00:00Z","endsAt":"2099-01-01T00:00:00Z","extensions":["600"]}"#,
            #"{"startedAt":"2026-01-01T00:00:00Z","endsAt":"2099-01-01T00:00:00Zjunk","extensions":[]}"#,
            #"{"startedAt":"2026-01-01T00:00:00Z","endsAt":"2099-01-01T00:00:00Z","extensions":{}}"#,
            #"["2099-01-01T00:00:00Z"]"#,
            // A property list plutil reads with every key right; the app's
            // JSONDecoder refuses it, so the shell must too.
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>startedAt</key><string>2026-01-01T00:00:00Z</string>
            <key>endsAt</key><string>2099-01-01T00:00:00Z</string>
            <key>extensions</key><array/>
            </dict></plist>
            """,
        ]
        let problems = ["startedAt is a JSON integer, not a date string", "extensions[0] is a JSON string, not a number", "endsAt is not a date in the form 2027-01-15T08:00:00Z or 2027-01-15T10:00:00+02:00", "extensions is a JSON dictionary, not an array", "session.json is not a JSON object", "session.json is not a JSON object"]
        for (json, problem) in zip(cases, problems) {
            try json.write(to: fx.session, atomically: true, encoding: .utf8)
            try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            for name in try movedAsideSessions() { try FileManager.default.removeItem(at: fx.home.appendingPathComponent(name)) }

            let r = try fx.run(fx.backstop)

            XCTAssertEqual(r.status, 0, json + r.stderr + fx.log())
            XCTAssertEqual(fx.calls(), [], json)
            XCTAssertFalse(fx.exists(fx.session), json)
            XCTAssertEqual(try movedAsideSessions().count, 1, json)
            XCTAssertTrue(fx.log().contains(problem), problem + "\n" + fx.log())
        }
    }

    /// The fixture's own session, which has every field the decoder needs,
    /// is a session: a future one keeps sleep disabled and nothing runs.
    func testCompleteSessionWithAFutureEndsAtIsValid() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    /// Dates the app and both scripts must read alike. Each one is written
    /// into a session.json and read back the way each script reads it
    /// (plutil, then epoch_at and epoch_of cut from the script), and the
    /// second it gives must be the one the app's Session decoder gives, or
    /// both must refuse. Most refused ones are dates JSONDecoder's
    /// `.iso8601` took on macOS 26 while the scripts did not, so the app
    /// could keep a deadline that the backstop ended every minute. The
    /// whitespace ones check the read itself: command substitution would
    /// strip a stored trailing newline.
    func testScriptsAndAppReadTheSameSessionDates() throws {
        let cases = [
            "2027-01-15T08:00:00Z", "2027-01-15T10:00:00+02:00", "2027-01-15T02:30:00-05:30", "2027-01-15T08:00:00+00:00",
            "2027-01-15T08:00:00-00:00", "2027-01-16T07:59:00+23:59", "2028-02-29T08:00:00Z", "1970-01-01T00:30:00+01:00",
            "1970-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "9999-12-31T23:59:59-23:59",
            "1969-12-31T23:59:59Z", "1900-01-01T00:00:00Z", "2027-02-29T08:00:00Z", "2027-02-30T08:00:00Z", "2027-04-31T08:00:00Z",
            "2027-01-15T24:00:00Z", "2027-01-15T25:00:00Z", "2027-01-15T08:61:00Z", "2027-01-15T08:00:60Z", "2027-13-01T08:00:00Z",
            "2027-00-10T08:00:00Z", "2027-01-15T08:00:00+24:00", "2027-01-15T08:00:00+02:60", "2027-01-15T08:00:00+0200",
            "2027-01-15T08:00:00+02", "2027-01-15T08:00:00+2:00", "2027-01-15T08:00:00.5Z", "2027-01-15T08:00:00.123+02:00",
            "2027-01-15T08:00:00z", "2027-01-15t08:00:00Z", "2027-01-15T08:00:00GMT", "2027-01-15T08:00:00UTC",
            "2027-01-15T08:00:00Zjunk", "2027-01-15T08:00:00Z ", " 2027-01-15T08:00:00Z", "2027-01-15T08:00:00+02:00:00",
            "2027-1-5T8:0:0Z", "2027-01-15 08:00:00Z", "2027-01-15T08:00:00", "2027-01-15T08:00Z", "10000-01-01T00:00:00Z",
            "+2027-01-15T08:00:00Z", "\u{FF12}\u{FF10}\u{FF12}\u{FF17}-01-15T08:00:00Z", "2027-01-15T08:00:00\u{2212}02:00", "",
            "2027-01-15T08:00:00Z\n", "2027-01-15T08:00:00Z\n\n", "\n2027-01-15T08:00:00Z", "2027-01-15T08:00:00Z\r",
            "2027-01-15T08:00:00Z\t", "2027-01-15T08:00:00+02:00\n",
        ]
        let dir = fx.root.appendingPathComponent("dates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var files: [String] = []
        var app: [String] = []
        for (i, text) in cases.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: ["startedAt": "2027-01-15T08:00:00Z", "endsAt": text, "extensions": [Int]()])
            let file = dir.appendingPathComponent("\(i).json")
            try data.write(to: file)
            files.append(file.path)
            app.append((try? Store.makeDecoder().decode(Session.self, from: data)).map { String(Int($0.endsAt.timeIntervalSince1970)) } ?? "")
        }
        XCTAssertEqual(app.filter { !$0.isEmpty }.count, 11, "the app reads the first eleven: \(Array(zip(cases, app)))")
        for script in [fx.backstop, fx.uninstall] {
            let text = try String(contentsOf: script, encoding: .utf8)
            var functions = ""
            // read_at returns a status and epoch_at sets epoch; a read that
            // fails stops the harness under set -e.
            for name in ["plutil_run", "absent_reply", "read_at", "epoch_of", "epoch_at"] {
                let start = try XCTUnwrap(text.range(of: "\n\(name)() {"), "\(name) in \(script.lastPathComponent)")
                let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
                functions += text[start.lowerBound..<end.upperBound]
            }
            let work = fx.root.appendingPathComponent("work.\(script.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let harness = fx.root.appendingPathComponent("epoch_at.\(script.lastPathComponent)")
            let loop = #"for f in "$@"; do epoch_at "$f" endsAt; printf '[%s]\n' "$epoch"; done"#
            try ("set -euo pipefail\nPLUTIL=/usr/bin/plutil\nDATE=/bin/date\nREADS='\(work.path)'\n" + functions + loop + "\n")
                .write(to: harness, atomically: true, encoding: .utf8)

            let r = try fx.run(harness, files)

            XCTAssertEqual(r.status, 0, r.stderr)
            let shell = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { String($0.dropFirst().dropLast()) }
            XCTAssertEqual(shell.count, cases.count, r.stdout)
            for (i, text) in cases.enumerated() where i < shell.count {
                XCTAssertEqual(shell[i], app[i], "\(script.lastPathComponent) and the app read \(text.debugDescription) differently")
            }
        }
    }

    /// A future endsAt with a newline stored after it is not a date for the
    /// app, so it is not one for the backstop either: the session is
    /// malformed, the journal is undone and the file moved aside, as the
    /// app does.
    func testFutureEndsAtWithAStoredTrailingNewlineIsNotASession() throws {
        let f = ISO8601DateFormatter()
        let data = try JSONSerialization.data(withJSONObject: [
            "startedAt": f.string(from: Date(timeIntervalSinceNow: -60)),
            "endsAt": f.string(from: Date(timeIntervalSinceNow: 3600)) + "\n",
            "extensions": [Int](),
        ])
        XCTAssertNil(try? Store.makeDecoder().decode(Session.self, from: data), "the app reads it")
        try data.write(to: fx.session)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions().count, 1)
        XCTAssertTrue(fx.log().contains("endsAt is not a date in the form"), fx.log())
    }

    /// A session written with offsets is a session for the backstop too: a
    /// future one keeps sleep disabled and nothing runs, a past one is
    /// undone like any expired session.
    func testSessionWithOffsetDatesIsReadLikeTheApp() throws {
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: -5 * 3600 - 1800)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        func write(endsAt: Date) throws {
            let json = #"{"startedAt":"\#(f.string(from: endsAt.addingTimeInterval(-3600)))","endsAt":"\#(f.string(from: endsAt))","extensions":[]}"#
            XCTAssertTrue(json.contains("-05:30"), json)
            try json.write(to: fx.session, atomically: true, encoding: .utf8)
        }

        try write(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(dirty)
        let future = try fx.run(fx.backstop)

        XCTAssertEqual(future.status, 0, future.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)

        try write(endsAt: Date(timeIntervalSinceNow: -60))
        let past = try fx.run(fx.backstop)

        XCTAssertEqual(past.status, 0, past.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions(), [], "an expired session is removed, not moved aside as malformed")
    }

    /// A session.json that exists but cannot be read at all (here: it is a
    /// directory) has no end time anyone can enforce, so it counts as
    /// expired: the journal is undone. It may have been a valid session, so
    /// once the journal is clean it is renamed aside with its contents,
    /// never removed, and no later run sees a session.
    func testSessionThatCannotBeReadAtAllIsTreatedAsExpiredAndMovedAside() throws {
        try FileManager.default.createDirectory(at: fx.session, withIntermediateDirectories: true)
        try "inside".write(to: fx.session.appendingPathComponent("note"), atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        let copy = fx.home.appendingPathComponent(moved.first ?? "")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("note"), encoding: .utf8), "inside")
        XCTAssertTrue(fx.log().contains("session.json cannot be read (it is not a regular file, so it is not opened), so its end time is unknown; treated as expired"), fx.log())
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
        XCTAssertTrue(fx.log().contains("session.json cannot be read (it is not a regular file, so it is not opened); moved to \(copy.path)"), fx.log())

        // The next run finds no session and nothing to undo.
        fx.clearCalls()
        let again = try fx.run(fx.backstop)
        XCTAssertEqual(again.status, 0, again.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try movedAsideSessions(), moved)
    }

    /// With nothing journaled there is nothing to undo, and the file is
    /// still renamed aside, so the agent does not report it every minute.
    func testSessionThatCannotBeReadWithACleanJournalIsMovedAsideAndNothingRuns() throws {
        try FileManager.default.createDirectory(at: fx.session, withIntermediateDirectories: true)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions().count, 1)
        XCTAssertTrue(fx.log().contains("treated as expired; nothing journaled to undo"), fx.log())
    }

    /// When the rename fails (an immutable entry here) the file stays, the
    /// run exits nonzero, and the log says to remove it or move it rather
    /// than make it readable. The next run tries the rename again.
    func testSessionThatCannotBeReadOrRenamedIsKeptAndRetriedOnTheNextRun() throws {
        try FileManager.default.createDirectory(at: fx.session, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fx.session.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fx.session.path) }
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions(), [])
        let log = fx.log()
        XCTAssertTrue(log.contains("kept in place, and the next run tries again"), log)
        XCTAssertTrue(log.contains("Remove it or move it out of \(fx.home.path): if it became readable there, the app would resume it"), log)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fx.session.path)
        let next = try fx.run(fx.backstop)

        XCTAssertEqual(next.status, 0, next.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions().count, 1)
    }

    /// A regular session.json without read permission, holding a session
    /// whose end is still ahead: the same. Its bytes move unchanged, so
    /// once its permissions are fixed it is still not session.json and no
    /// run reads it back as a session.
    func testSessionWithoutReadPermissionIsTreatedAsExpiredAndMovedAside() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        let bytes = try Data(contentsOf: fx.session)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.session.path)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        let copy = fx.home.appendingPathComponent(moved.first ?? "")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path) }
        XCTAssertTrue(fx.log().contains("session.json cannot be read (permissions or I/O)"), fx.log())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy.path)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }

    /// Uninstall runs the backstop first, which undoes the journal and moves
    /// the unreadable file aside, so it no longer blocks. A directory is
    /// not something purge removes, so it is kept and named.
    func testUninstallProceedsPastASessionThatCannotBeReadOnceTheBackstopMovesItAside() throws {
        try fx.installMachinery()
        try FileManager.default.createDirectory(at: fx.session, withIntermediateDirectories: true)
        try "inside".write(to: fx.session.appendingPathComponent("note"), atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.app))
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        let copy = fx.home.appendingPathComponent(moved.first ?? "")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("note"), encoding: .utf8), "inside")
        XCTAssertTrue(r.stdout.contains("Kept \(copy.path): it is named like a moved-aside session.json but is not a regular file"), r.stdout)
    }

    /// When the undo fails, the journal stays dirty and the file stays where
    /// it is. Uninstall stops before removing anything, names the problem as
    /// an access failure, and says what would have moved it.
    func testUninstallStopsWhenSessionCannotBeReadAndTheUndoFails() throws {
        try fx.installMachinery()
        try FileManager.default.createDirectory(at: fx.session, withIntermediateDirectories: true)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions(), [])
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(r.stderr.contains("session.json is still present and cannot be read"), r.stderr)
        XCTAssertTrue(r.stderr.contains("rename it to session.json.unreadable-<time> without opening it"), r.stderr)
    }

    /// A session.json that is a FIFO is never opened by the backstop: open(2)
    /// would block while it holds the recovery lock, and neither the app nor
    /// a later run could recover. It counts as expired, so the dirty journal
    /// is undone, and then the FIFO is renamed aside, still a FIFO.
    func testSessionThatIsAFIFOIsNeverOpenedByTheBackstopAndIsMovedAside() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let fifo = try FIFOWatch(at: fx.session)
        defer { fifo.stop() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertFalse(fifo.readerSeen, "session.json was opened although it is a FIFO")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        var info = stat()
        XCTAssertEqual(lstat(fx.home.appendingPathComponent(moved.first ?? "").path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO, "the FIFO was replaced instead of renamed")
        XCTAssertTrue(fx.log().contains("not a regular file"), fx.log())
        XCTAssertTrue(fx.log().contains("treated as expired"), fx.log())
    }

    /// The same for state.json: never opened, reported as malformed, nothing
    /// undone, and the session file stays.
    func testJournalThatIsAFIFOIsNeverOpenedByTheBackstop() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let fifo = try FIFOWatch(at: fx.state)
        defer { fifo.stop() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertFalse(fifo.readerSeen, "state.json was opened although it is a FIFO")
        XCTAssertTrue(fifo.isStillFIFO)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("not a regular file"), fx.log())
    }

    /// Uninstall with both files as FIFOs: neither the backstop it runs nor
    /// its own journal check opens them, and it stops before removing
    /// anything.
    func testUninstallNeverOpensSessionOrJournalFIFOs() throws {
        try fx.installMachinery()
        let session = try FIFOWatch(at: fx.session)
        let state = try FIFOWatch(at: fx.state)
        defer { session.stop(); state.stop() }

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(session.readerSeen, "session.json was opened although it is a FIFO")
        XCTAssertFalse(state.readerSeen, "state.json was opened although it is a FIFO")
        XCTAssertTrue(session.isStillFIFO)
        XCTAssertTrue(state.isStillFIFO)
        XCTAssertTrue(r.stderr.contains("session.json is still present and cannot be read: it is not a regular file"), r.stderr)
        XCTAssertTrue(r.stderr.contains("state.json is not a regular file"), r.stderr)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
    }

    /// Uninstall runs the backstop first, which moves the file aside, so an
    /// unreadable session.json with a clean journal no longer blocks it.
    /// Without --purge the moved-aside copy is kept and said so.
    func testUninstallProceedsPastAnUnreadableSessionWithACleanJournalAndKeepsTheCopy() throws {
        try fx.installMachinery()
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.session))
        let moved = try movedAsideSessions()
        XCTAssertEqual(moved.count, 1, "\(moved)")
        XCTAssertTrue(r.stdout.contains("Kept 1 unreadable session.json file(s)"), r.stdout)
    }

    /// The record of a `sudo pmset` left running is gone after an uninstall,
    /// with or without --purge: uninstall holds the recovery lock, so the
    /// command it names has exited.
    func testUninstallRemovesTheRecordOfACommandLeftRunning() throws {
        for purge in [false, true] {
            try fx.installMachinery()
            let record = fx.home.appendingPathComponent("unfinished-command.json")
            try #"{"pid":4242,"command":"/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0","since":"2026-01-01T00:00:00Z"}"#
                .write(to: record, atomically: true, encoding: .utf8)

            let r = try fx.run(fx.uninstall, purge ? ["--purge"] : [])

            XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
            XCTAssertFalse(fx.exists(record), "purge \(purge)")
        }
    }

    /// --purge removes the moved-aside copies, but only names of exactly the
    /// shape Insomnia produces. Anything else under the prefix stays.
    func testUninstallPurgeRemovesOnlyMovedAsideSessionFilesOfInsomniasShape() throws {
        try fx.installMachinery()
        let ours = ["session.json.unreadable-20260101T000000Z", "session.json.unreadable-20260101T000000Z-3"]
        let notOurs = "session.json.unreadable-notes.txt"
        for name in ours + [notOurs] {
            try "x".write(to: fx.home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try movedAsideSessions(), [notOurs])
    }

    /// Something that is not a regular file but has a moved-aside name (here
    /// a directory with a file in it) is not Insomnia's. --purge says so,
    /// leaves it with its contents, and still finishes: the copies beside it
    /// and Insomnia's own files go, and the exit status is 0.
    func testUninstallPurgeLeavesADirectoryNamedLikeAMovedAsideCopyAndFinishes() throws {
        try fx.installMachinery()
        try fx.writeConfig("{}")
        let dir = fx.home.appendingPathComponent("session.json.unreadable-20260101T000000Z")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "keep".write(to: dir.appendingPathComponent("inside"), atomically: true, encoding: .utf8)
        let ours = "session.json.unreadable-20260101T000000Z-1"
        try "x".write(to: fx.home.appendingPathComponent(ours), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Left \(dir.path): it is named like a moved-aside session.json but is not a regular file"), r.stdout)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("inside"), encoding: .utf8), "keep")
        XCTAssertFalse(fx.exists(fx.home.appendingPathComponent(ours)))
        XCTAssertFalse(fx.exists(fx.config))
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertTrue(r.stdout.contains("Done."), r.stdout)
    }

    /// The same for Insomnia's own file names: a directory at config.json
    /// is left with a message instead of stopping the purge halfway.
    func testUninstallPurgeLeavesADirectoryAtAnOwnedPathAndFinishes() throws {
        try fx.installMachinery()
        try? FileManager.default.removeItem(at: fx.config)
        try FileManager.default.createDirectory(at: fx.config, withIntermediateDirectories: true)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Left \(fx.config.path): it is not a regular file, so Insomnia did not write it."), r.stdout)
        XCTAssertTrue(fx.exists(fx.config))
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// Paths come from the glob, never from text split on newlines: with a
    /// newline in the home directory's name, the old listing would split a
    /// copy's path in two and remove a same-named file relative to the
    /// working directory. Now only the copy itself goes.
    func testUninstallPurgeHandlesANewlineInTheHomePath() throws {
        let home = fx.root.appendingPathComponent("nl\nvictim", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let name = "session.json.unreadable-20260101T000000Z"
        try "x".write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        let victimDir = fx.root.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victimDir, withIntermediateDirectories: true)
        let victim = victimDir.appendingPathComponent(name)
        try "not Insomnia's".write(to: victim, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall, ["--purge"], extraEnvironment: ["INSOMNIA_HOME": home.path])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.exists(home.appendingPathComponent(name)))
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "not Insomnia's")
    }

    /// With the journal still dirty the uninstall stops as before, names the
    /// unreadable session file as such, and says what will happen to it
    /// rather than asking for a repair.
    func testUninstallAbortMessageIsAccurateAboutAnUnreadableSessionWhileTheJournalIsDirty() throws {
        try fx.installMachinery()
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(r.stderr.contains("session.json is still present and is not a session"), r.stderr)
        XCTAssertTrue(r.stderr.contains("sleepDisabledByUs is still true"), r.stderr)
        XCTAssertTrue(r.stderr.contains("renames it to"), r.stderr)
        XCTAssertFalse(r.stderr.contains("repair the file"), r.stderr)
    }

    func testLockContentionFailsClosed() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.writeState(dirty)

        let holder = try fx.holdLock()
        defer { holder.stop() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 75, "lockf EX_TEMPFAIL must propagate: \(r.stderr)")
        XCTAssertEqual(fx.calls(), [], "no unlocked fallback")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("lock"), fx.log())
        XCTAssertTrue(fx.exists(fx.lock), "lock file inode is retained")
    }

    func testSecondRunAfterSuccessIsIdle() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        XCTAssertEqual(try fx.run(fx.backstop).status, 0)
        fx.clearCalls()

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "the lock file must not make later runs think something is journaled")
    }

    // MARK: - backstop.sh and the pending-start marker

    /// The app died under its password dialog and the backstop ends the
    /// session. The marker goes first thing under the lock, before any
    /// privileged command, so a late answer to that dialog runs nothing.
    func testBackstopVoidsTheDialogOfAStartThatDiedBeforeItUndoesAnything() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let nonce = UUID().uuidString
        try Data(nonce.utf8).write(to: fx.pendingStart)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(fx.exists(fx.pendingStart))
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(fx.markerAtSudo(), ["absent"], "the marker must be gone before pmset runs")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("pending-start; a command a password dialog left from an abandoned start runs stops at its marker check from now on, unless this user writes the marker again or the clock is set back"), fx.log())

        let late = try runRootCommand(marker: fx.pendingStart, nonce: nonce, in: fx.root)
        XCTAssertEqual(late.status, 69, late.stderr)
        XCTAssertEqual(late.pmsetCalls, [], "the late answer must not turn sleep off")
    }

    /// The root command behind an abandoned dialog is still in pmset and
    /// holds the marker's lock. The backstop restores sleep but keeps the
    /// entry and exits 1; once the command is done the next run removes
    /// the marker and clears the entry.
    func testBackstopKeepsTheSleepEntryWhileTheMarkerIsLocked() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let nonce = UUID().uuidString
        try Data(nonce.utf8).write(to: fx.pendingStart)
        try fx.writeReceipt()
        let command = try RootCommandProcess(marker: fx.pendingStart, nonce: nonce, receipts: fx.swiftReceipts, in: fx.root, holdAt: RootCommandProcess.write)
        defer { command.release() }
        XCTAssertTrue(command.waitUntilPmsetRuns())

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "sleep itself is still restored")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "the entry stays while the command may still turn sleep off")
        XCTAssertEqual(try String(contentsOf: fx.pendingStart, encoding: .utf8), nonce, "the marker stays as the start wrote it")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fx.receipt), encoding: .utf8), "\(nonce) \(SleepOffReceipts.zero) writing\n", "the command's record is in the receipt")
        XCTAssertTrue(fx.log().contains("still locked after 1s by the command a password dialog started as root"), fx.log())
        XCTAssertTrue(fx.log().contains("journal kept dirty"), fx.log())

        command.release()
        XCTAssertEqual(command.wait().pmsetCalls, ["-g", "-g", "-a disablesleep 1"])
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertFalse(fx.exists(fx.pendingStart))
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
    }

    /// A marker that cannot be deleted (an immutable flag) is reported the
    /// same way: sleep restored, entry kept, exit 1, and cleared once the
    /// flag is gone.
    func testBackstopKeepsTheSleepEntryWhenTheMarkerCannotBeDeleted() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)
        XCTAssertEqual(chflags(fx.pendingStart.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(fx.pendingStart.path, 0) }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.pendingStart))
        XCTAssertTrue(fx.log().contains("could not be deleted"), fx.log())

        chflags(fx.pendingStart.path, 0)
        let again = try fx.run(fx.backstop)
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertFalse(fx.exists(fx.pendingStart))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    /// With nothing journaled a stuck marker still makes the run fail, so
    /// it is retried and visible in the log.
    func testBackstopFailsOnAStuckMarkerEvenWithACleanJournal() throws {
        try FileManager.default.createDirectory(at: fx.pendingStart, withIntermediateDirectories: false)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.log().contains("journal is clean, but \(fx.pendingStart.path) is still present"), fx.log())
    }

    /// A session that is still valid ends the run early, but not with
    /// success while the marker stays.
    func testBackstopFailsOnAStuckMarkerWhileTheSessionIsValid() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.createDirectory(at: fx.pendingStart, withIntermediateDirectories: false)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(fx.calls(), [], "a valid session is left alone")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(fx.log().contains("is not a regular file, so it was not opened"), fx.log())
        XCTAssertTrue(fx.log().contains("session.json is valid until "), fx.log())
        XCTAssertTrue(fx.log().contains("but \(fx.pendingStart.path) is still present"), fx.log())
    }

    /// The same after a session.json that is not a session is moved aside
    /// with nothing journaled.
    func testBackstopFailsOnAStuckMarkerAfterMovingASessionAside() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.createDirectory(at: fx.pendingStart, withIntermediateDirectories: false)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.session), "session.json is still moved aside")
        XCTAssertEqual(try movedAsideSessions().count, 1)
        XCTAssertTrue(fx.log().contains("journal is clean, but \(fx.pendingStart.path) is still present"), fx.log())
    }

    /// Round 22 (legacy): a marker that no journaled start accounts for,
    /// as a build from before sleepOffAttempt leaves it, beside a session
    /// that is still valid. The dialog of the start that died is voided,
    /// and since nothing shows whether its command turned sleep off, the
    /// session is not left to be resumed: session.json goes and the
    /// journaled entry is undone. Before, the session stayed, and an app
    /// relaunch resumed it on a SleepDisabled 1 that could be someone
    /// else's.
    func testBackstopEndsAValidSessionBesideAMarkerNoJournaledStartAccountsFor() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(fx.exists(fx.pendingStart))
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertTrue(fx.log().contains("it was beside a pending-start marker that no journaled start accounts for, so it is never resumed"), fx.log())
    }

    /// The control: the same valid session with no marker is left alone.
    func testBackstopLeavesAValidSessionWithNoMarker() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    /// Without the lock a start may still be waiting on its dialog, so the
    /// marker is left exactly as it was.
    func testBackstopLeavesTheMarkerWhenTheLockIsHeld() throws {
        let nonce = UUID().uuidString
        try Data(nonce.utf8).write(to: fx.pendingStart)
        let holder = try fx.holdLock()
        defer { holder.stop() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 75, r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.pendingStart, encoding: .utf8), nonce)
    }

    // MARK: - Settling an unfinished start (sleepOffAttempt and the receipt)

    private enum JournaledMarker {
        /// The marker the start wrote, its identity journaled.
        case written
        /// No marker journaled: no dialog was shown.
        case none
        /// Journaled, then gone before the run (the app deleted it).
        case gone
        /// A marker on disk, with another identity journaled.
        case other
    }

    /// A receipt line: `<nonce> <predecessor> <word>` and a newline, the
    /// 82 bytes the root command writes.
    private func receiptLine(_ nonce: String, _ word: String, predecessor: String = SleepOffReceipts.zero) -> String {
        "\(nonce) \(predecessor) \(word)\n"
    }

    /// What the app journals before a start's password dialog:
    /// sleepDisabledByUs with sleepOffAttempt beside it, the marker holding
    /// the nonce, the receipt as install.sh makes it with its identity and
    /// its line's nonce (the predecessor, install.sh's zero nonce)
    /// journaled, and the start's claim in the release file. session.json
    /// ends at the attempt's deadline, `endsIn` seconds from now. The
    /// dialog can be answered until `expiresIn` seconds from now (or the
    /// deadline, if sooner): over by default.
    @discardableResult
    private func journalUnfinishedStart(owedBefore: Bool = false, endsIn: Int = 3600, expiresIn: Int = -1, marker: JournaledMarker = .written, session: Bool = true) throws -> String {
        let nonce = UUID().uuidString
        let now = Int(Date().timeIntervalSince1970)
        let deadline = now + endsIn
        let expires = min(deadline, now + expiresIn)
        try fx.writeReceipt()
        let receipt = try XCTUnwrap(fx.receiptIdentity())
        try fx.writeRelease("\(nonce) held\n")
        var field = ""
        if marker != .none {
            try Data(nonce.utf8).write(to: fx.pendingStart)
            let identity = try XCTUnwrap(FileIdentity(atPath: fx.pendingStart.path)?.text)
            field = #","marker":"\#(marker == .other ? "1:2" : identity)""#
            if marker == .gone { try FileManager.default.removeItem(at: fx.pendingStart) }
        }
        if session { try fx.writeSession(endsAt: Date(timeIntervalSince1970: TimeInterval(deadline))) }
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"sleepOffAttempt":{"nonce":"\#(nonce)","owedBefore":\#(owedBefore),"receipt":"\#(receipt)","predecessor":"\#(SleepOffReceipts.zero)","deadline":\#(deadline),"expires":\#(expires)\#(field)}}"#)
        return nonce
    }

    /// Moves the journaled start's expires into the past: its dialog can
    /// no longer be answered.
    private func endTheDialog() throws {
        let text = try String(contentsOf: fx.state, encoding: .utf8)
        let past = Int(Date().timeIntervalSince1970) - 1
        let ended = text.replacingOccurrences(of: #""expires":[0-9]+"#, with: "\"expires\":\(past)", options: .regularExpression)
        XCTAssertNotEqual(ended, text)
        try ended.write(to: fx.state, atomically: true, encoding: .utf8)
    }

    /// The start is settled and its session is not resumed. `release`: what
    /// the release file holds afterwards; by default the receipt's nonce,
    /// free, as the start's claim is given back.
    private func assertSettled(sleepRestored: Bool, release: String? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(fx.calls(), sleepRestored ? ["sudo -n \(fx.fakePmset) -a disablesleep 0"] : [], file: file, line: line)
        XCTAssertFalse(fx.exists(fx.pendingStart), file: file, line: line)
        XCTAssertFalse(fx.exists(fx.session), "the session of a start that never finished is never resumed", file: file, line: line)
        let state = try fx.stateJSON()
        XCTAssertEqual(state["sleepDisabledByUs"] as? Bool, false, file: file, line: line)
        XCTAssertNil(state["sleepOffAttempt"], file: file, line: line)
        XCTAssertEqual(fx.release(), release ?? "\(String((fx.receiptText() ?? "").prefix(36))) free\n", "the claim is given back", file: file, line: line)
    }

    /// The start stays journaled with its sleep entry and its claim, and
    /// the run exits 1 having said each of `saying`. `restored`: whether
    /// sleep itself was restored; when not, the log says why the entry is
    /// left as it is.
    private func assertKept(_ r: (status: Int32, stdout: String, stderr: String), nonce: String, restored: Bool, saying: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, 1, r.stderr, file: file, line: line)
        XCTAssertEqual(fx.calls(), restored ? ["sudo -n \(fx.fakePmset) -a disablesleep 0"] : [], file: file, line: line)
        let state = try fx.stateJSON()
        XCTAssertEqual((state["sleepOffAttempt"] as? [String: Any])?["nonce"] as? String, nonce, "the start stays journaled", file: file, line: line)
        XCTAssertEqual(state["sleepDisabledByUs"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(fx.release(), "\(nonce) held\n", "the claim stays", file: file, line: line)
        let log = fx.log()
        for phrase in saying { XCTAssertTrue(log.contains(phrase), "\(phrase): \(log)", file: file, line: line) }
        XCTAssertEqual(log.contains("sleepDisabledByUs stays journaled, and sleep is left as it is: "), !restored, log, file: file, line: line)
        XCTAssertTrue(log.contains("journal kept dirty"), log, file: file, line: line)
    }

    /// The start's decision is journaled (its record marked settled, and
    /// sleepDisabledByUs as decided, then undone), its claim stays, and the
    /// run exits 1 having said each of `saying`. `restored`: whether sleep
    /// was restored in this run.
    private func assertSettledButNotFinished(_ r: (status: Int32, stdout: String, stderr: String), nonce: String, restored: Bool, saying: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, 1, r.stderr, file: file, line: line)
        XCTAssertEqual(fx.calls(), restored ? ["sudo -n \(fx.fakePmset) -a disablesleep 0"] : [], file: file, line: line)
        let state = try fx.stateJSON()
        let attempt = state["sleepOffAttempt"] as? [String: Any]
        XCTAssertEqual(attempt?["nonce"] as? String, nonce, "the record stays", file: file, line: line)
        XCTAssertEqual(attempt?["settled"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(state["sleepDisabledByUs"] as? Bool, false, "restored as decided", file: file, line: line)
        XCTAssertEqual(fx.release(), "\(nonce) held\n", "the claim stays", file: file, line: line)
        let log = fx.log()
        for phrase in saying { XCTAssertTrue(log.contains(phrase), "\(phrase): \(log)", file: file, line: line) }
    }

    /// The receipt still holds the line the start found (its predecessor)
    /// and the start's dialog can no longer be answered: the command
    /// behind it never got as far as its write, and from now on refuses.
    /// The start is settled as never having turned sleep off, so the 1
    /// pmset may report is left alone, its session (still valid) is
    /// removed, not resumed, and its claim is given back.
    func testBackstopSettlesAStartWhoseReceiptShowsItNeverTurnedSleepOff() throws {
        try journalUnfinishedStart()

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: false)
        XCTAssertTrue(fx.log().contains("its receipt shows the command behind its dialog never turned sleep off; sleepDisabledByUs goes back to false"), fx.log())
        XCTAssertTrue(fx.log().contains("removed \(fx.session.path): its start never finished, so it is never resumed"), fx.log())
    }

    /// The same receipt while the dialog can still be answered decides
    /// nothing: its command may still write. The start stays journaled
    /// with its claim, no pmset runs (nothing shows that sleep was turned
    /// off, and no earlier restore is owed) and the run exits 1. Once the
    /// dialog is over the next run settles it, still with no pmset.
    func testBackstopKeepsAStartWhoseDialogCanStillBeAnswered() throws {
        let nonce = try journalUnfinishedStart(expiresIn: 60)

        let r = try fx.run(fx.backstop)

        try assertKept(r, nonce: nonce, restored: false, saying: [
            "an unfinished start is not settled yet: the password dialog of that start can still be answered until ",
            "it stays journaled, the session is ended rather than resumed, and sleep is left as it is",
        ])

        try endTheDialog()
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        try assertSettled(sleepRestored: false)
    }

    /// Round 25 (R25-2): a restore an earlier session still owes
    /// (owedBefore) waits too. A command for this start may still turn
    /// sleep off after an undo run now, so the undo would not hold. The
    /// start stays journaled with the restore owed, and once its dialog is
    /// over and the receipt shows it never wrote, that restore runs.
    func testBackstopHoldsEvenAnOwedRestoreWhileTheDialogCanStillBeAnswered() throws {
        let nonce = try journalUnfinishedStart(owedBefore: true, expiresIn: 60)

        let r = try fx.run(fx.backstop)

        try assertKept(r, nonce: nonce, restored: false, saying: [
            "the password dialog of that start can still be answered until ",
        ])
        XCTAssertFalse(fx.log().contains("sleep restored"), fx.log())

        try endTheDialog()
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        try assertSettled(sleepRestored: true)
        XCTAssertTrue(fx.log().contains("never turned sleep off; sleepDisabledByUs goes back to true"), fx.log())
    }

    /// The same for this start's own `refused`: its last deadline check
    /// stopped it before pmset, whether or not its dialog is over. An
    /// expired session goes the same way.
    func testBackstopSettlesAStartWhoseCommandRefusedAfterItsRecord() throws {
        for expiresIn in [-1, 60] {
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            let nonce = try journalUnfinishedStart(endsIn: expiresIn < 0 ? -60 : 3600, expiresIn: expiresIn)
            try fx.writeReceipt(receiptLine(nonce, "refused"))

            let r = try fx.run(fx.backstop)

            XCTAssertEqual(r.status, 0, "\(expiresIn): \(r.stderr)")
            try assertSettled(sleepRestored: false)
            XCTAssertTrue(fx.log().contains("never turned sleep off; sleepDisabledByUs goes back to false"), fx.log())
        }
    }

    /// A start that never turned sleep off does not clear the restore an
    /// earlier session still owes: sleepDisabledByUs goes back to true and
    /// is undone.
    func testBackstopKeepsTheRestoreAnEarlierSessionOwesWhenTheStartNeverTurnedSleepOff() throws {
        try journalUnfinishedStart(owedBefore: true)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: true)
        XCTAssertTrue(fx.log().contains("never turned sleep off; sleepDisabledByUs goes back to true"), fx.log())
    }

    /// A session that is not the start's (another end) stays, and so does
    /// the restore it owes: only the attempt goes.
    func testBackstopLeavesASessionThatIsNotTheStartsWhenSettlingIt() throws {
        try journalUnfinishedStart(owedBefore: true, session: false)
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 7200))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [], "the earlier session is still valid")
        XCTAssertTrue(fx.exists(fx.session))
        let state = try fx.stateJSON()
        XCTAssertEqual(state["sleepDisabledByUs"] as? Bool, true)
        XCTAssertNil(state["sleepOffAttempt"])
    }

    /// The receipt shows this start's `writing`: its command went on to
    /// pmset. The start is undone like an end. The receipt and the release
    /// file are read through the script's HEAD, never a `head` found in PATH
    /// (the ordinary PATH here; see
    /// testBackstopSettlesThroughItsOwnToolsWhateverPathHolds), and
    /// session.json is never read in place: the script's perl copies it,
    /// and the journal's text is read from its copy through CAT.
    func testBackstopUndoesAStartWhoseReceiptShowsItsCommandWrote() throws {
        let nonce = try journalUnfinishedStart()
        try fx.writeReceipt(receiptLine(nonce, "writing"))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: true)
        XCTAssertTrue(fx.log().contains("as one that may have turned sleep off (\(fx.receipt) holds that start's writing line: its command was about to turn sleep off and may have)"), fx.log())
        let tools = fx.toolCalls()
        XCTAssertTrue(tools.contains("head -c 83"), "\(tools)")
        XCTAssertTrue(tools.contains("head -c 43 \(fx.released)"), "\(tools)")
        XCTAssertTrue(tools.contains { $0.hasPrefix("cat \(fx.home.path)/.backstop-read.") && $0.hasSuffix("/state.json") }, "\(tools)")
        XCTAssertFalse(tools.contains { $0.contains(fx.session.path) || $0.contains(fx.state.path) }, "nothing reads the live files in place: \(tools)")
    }

    /// Another start won the line this start found (the same predecessor,
    /// its own nonce): this start's command, which writes only over that
    /// line, cannot have written. Settled with no pmset. The release file
    /// shows another start's claim, which is not this start's to give
    /// back, so it stays.
    func testBackstopSettlesAStartWhoseLineAnotherStartWon() throws {
        try journalUnfinishedStart()
        let other = UUID().uuidString
        try fx.writeReceipt(receiptLine(other, "writing"))
        try fx.writeRelease("\(other) held\n")

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: false, release: "\(other) held\n")
    }

    /// A later start's line (one that found this start's line, or any other
    /// predecessor) no longer shows what this start's command did: it is
    /// undone.
    func testBackstopUndoesAStartWhoseReceiptHoldsALaterStartsLine() throws {
        let nonce = try journalUnfinishedStart()
        let later = UUID().uuidString
        try fx.writeReceipt(receiptLine(later, "refused", predecessor: nonce))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: true)
        XCTAssertTrue(fx.log().contains("\(fx.receipt) holds a later start's line, which no longer shows what the command for this start did"), fx.log())
    }

    /// Round 21's forgery, one level down: a receipt with the same bytes
    /// that is another file now (renamed over the one the start journaled)
    /// shows nothing about the start. Before the dialog's expiry the start
    /// stays journaled with no pmset; after it, the start is undone.
    func testBackstopUndoesAStartWhoseReceiptIsNotTheFileItWasOnceItsDialogIsOver() throws {
        let nonce = try journalUnfinishedStart(expiresIn: 60)
        let copy = fx.receipts + "/copy"
        try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: copy))
        XCTAssertEqual(chmod(copy, 0o600), 0)
        XCTAssertEqual(rename(copy, fx.receipt), 0)

        let r = try fx.run(fx.backstop)

        try assertKept(r, nonce: nonce, restored: false, saying: ["\(fx.receipt) is not the file it was when the start began; a command for that start could still write until "])

        try endTheDialog()
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        try assertSettled(sleepRestored: true)
        XCTAssertTrue(fx.log().contains("\(fx.receipt) is not the file it was when the start began"), fx.log())
    }

    /// A receipt replaced between its lock and the checks after it (a
    /// wrapper around lockf renames a copy over it once fd 7 is locked)
    /// shows nothing either: before the dialog's expiry the start stays
    /// journaled, with no pmset.
    func testBackstopKeepsTheStartWhenTheReceiptIsReplacedWhileItIsLocked() throws {
        let nonce = try journalUnfinishedStart(expiresIn: 60)
        try fx.swapReceiptAfterItsLock(in: fx.backstop)

        let r = try fx.run(fx.backstop)

        try assertKept(r, nonce: nonce, restored: false, saying: ["\(fx.receipt) was replaced while it was locked; a command for that start could still write until "])
    }

    /// A receipt that is missing, not in its shape, or that someone other
    /// than its owner could change, or under a folder they could change,
    /// shows nothing, and its claim cannot be given back: sleep is
    /// restored, since the start may have turned it off, but the start
    /// stays journaled with its claim, run after run, until the receipt is
    /// made again (install.sh, after `sudo rm -f` of both files). Nothing
    /// about the receipt or its folder is changed. Round 25 (R25-1): a
    /// receipt that passes the checks and can be locked, but whose line
    /// cannot be read (the lower-case nonce), is decided ("may", as its
    /// dialog is over) and the decision journaled before the claim goes
    /// back, which needs the receipt's nonce. Its record then stays settled
    /// with the claim, the restore runs once, and the next run only tries
    /// to finish it.
    func testBackstopRestoresSleepAndKeepsTheStartWhenTheReceiptOrItsFolderCannotBeTrusted() throws {
        let user = String(cString: getpwuid(getuid()).pointee.pw_name)
        let mine = AccessEntry.installed(for: getuid())
        let write = AccessEntry(allows: true, principal: .user(getuid()), rights: ["write"], flags: [])
        let cases: [(name: String, damage: () throws -> Void, repair: () throws -> Void, says: String)] = [
            ("missing", { XCTAssertEqual(unlink(self.fx.receipt), 0) }, {}, "is missing, is not the 82-byte file"),
            ("83 bytes", { try Data((SleepOffReceipts.initialContent + "\n").utf8).write(to: URL(fileURLWithPath: self.fx.receipt)) }, {}, "is missing, is not the 82-byte file"),
            ("lower-case nonce", { try self.fx.writeReceipt(SleepOffReceipts.initialContent.replacingOccurrences(of: "0", with: "a")) }, {}, "does not hold two nonces and writing or refused"),
            ("group-writable", { XCTAssertEqual(chmod(self.fx.receipt, 0o664), 0) }, {}, "someone other than root can change it"),
            ("a hard link", { XCTAssertEqual(link(self.fx.receipt, self.fx.receipts + "/link"), 0) }, { unlink(self.fx.receipts + "/link") }, "is missing, is not the 82-byte file"),
            ("a symbolic link", {
                let target = self.fx.receipts + "/target"
                try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: target))
                XCTAssertEqual(unlink(self.fx.receipt), 0)
                XCTAssertEqual(symlink(target, self.fx.receipt), 0)
            }, { unlink(self.fx.receipt); unlink(self.fx.receipts + "/target") }, "is missing, is not the 82-byte file"),
            ("a writable folder", { XCTAssertEqual(chmod(self.fx.receipts, 0o775), 0) }, { chmod(self.fx.receipts, 0o755) }, "someone other than root can change it or a folder above it"),
            // Round 30 F6: stand-ins the scripts' ls shows, where these two
            // were real entries before; no real list changes.
            ("an allow entry on the receipt", { try self.fx.writeReceiptEntries([mine, write]) },
             { try self.fx.writeReceiptEntries([mine]) }, "does not have exactly one access control entry, the one that lets uid \(getuid()) read it and nothing else"),
            ("an allow entry on the folder", { try self.fx.writeFolderEntries([self.fx.receipts: ["user:\(user) allow add_file"]]) },
             { XCTAssertEqual(unlink(self.fx.folderEntries), 0) }, "has an access control entry that allows changes"),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            let nonce = try journalUnfinishedStart()
            try c.damage()
            let modes = (try? fx.runTool("/bin/ls", ["-lde", fx.receipts, fx.receipt]).output) ?? ""

            for run in 1...2 {
                try? FileManager.default.removeItem(at: fx.logFile)
                fx.clearCalls()
                let r = try fx.run(fx.backstop)

                if c.name == "lower-case nonce" {
                    try assertSettledButNotFinished(r, nonce: nonce, restored: run == 1, saying: [c.says, "an unfinished start is settled, but its claim on the receipt could not be given back ("])
                } else {
                    try assertKept(r, nonce: nonce, restored: true, saying: [c.says, "an unfinished start could not be settled: "])
                }
                XCTAssertEqual((try? fx.runTool("/bin/ls", ["-lde", fx.receipts, fx.receipt]).output) ?? "", modes, "\(c.name), run \(run): the run changes nothing about the receipt or its folder")
            }
            try c.repair()
            if c.name == "missing" || c.name == "83 bytes" { unlink(fx.receipt) }
        }
    }

    /// F3 (round 28). A receipt with a mode other than 600, any list of
    /// access control entries but the one install.sh adds, or a list ls
    /// cannot read shows nothing: sleep is restored and the start stays
    /// journaled with its claim, and the run changes neither the receipt
    /// nor its list. The lists are stand-ins the scripts' ls shows
    /// (ScriptFixture.receiptEntries); no real list changes.
    func testBackstopTrustsOnlyAReceiptOfModeSixHundredWithTheEntryInstallShAdds() throws {
        let mine = [AccessEntry.installed(for: getuid())]
        let mode = "is missing, is not the 82-byte file install.sh made, mode 600, or someone other than root can change it or a folder above it"
        let list = "\(fx.receipt) does not have exactly one access control entry, the one that lets uid \(fx.uid) read it and nothing else, or its list could not be read"
        var cases: [(name: String, mode: mode_t, entries: [AccessEntry], listFails: Bool, says: String)] = [0o644, 0o640, 0o400].map { ("mode \(String($0, radix: 8))", $0, mine, false, mode) }
        cases += TestReceipts.refusedLists.map { ($0.name, 0o600, $0.entries, false, list) }
        cases.append(("a list ls cannot read", 0o600, mine, true, list))
        let fails = fx.receiptEntries + ".fails"
        for c in cases {
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            let nonce = try journalUnfinishedStart()
            XCTAssertEqual(chmod(fx.receipt, c.mode), 0, c.name)
            try fx.writeReceiptEntries(c.entries)
            if c.listFails { XCTAssertTrue(FileManager.default.createFile(atPath: fails, contents: nil)) }
            let before = [(try? fx.runTool("/bin/ls", ["-lde", fx.receipts, fx.receipt]).output) ?? "", fx.receiptText() ?? "", (try? String(contentsOfFile: fx.receiptEntries, encoding: .utf8)) ?? ""]

            let r = try fx.run(fx.backstop)

            try assertKept(r, nonce: nonce, restored: true, saying: [c.says, "an unfinished start could not be settled: "])
            let after = [(try? fx.runTool("/bin/ls", ["-lde", fx.receipts, fx.receipt]).output) ?? "", fx.receiptText() ?? "", (try? String(contentsOfFile: fx.receiptEntries, encoding: .utf8)) ?? ""]
            XCTAssertEqual(after, before, "\(c.name): the run changes nothing about the receipt, its list or its folder")
            unlink(fails)
            XCTAssertEqual(chmod(fx.receipt, 0o600), 0)
            try fx.writeReceiptEntries(mine)
        }
        // The control: the same start with the receipt as install.sh makes it.
        try? FileManager.default.removeItem(at: fx.logFile)
        fx.clearCalls()
        try journalUnfinishedStart()
        let r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: false)
    }

    /// F6 (round 30). What the scripts cannot see. ls(1) never prints
    /// synchronize, and prints delete_child and every inheritance flag but
    /// limit_inherit only for a folder (TestReceipts.lsText), and it skips
    /// an entry whose rights or flags it cannot read. A receipt whose entry
    /// differs from the one install.sh adds only there prints the same
    /// listing, and the backstop trusts it, where the app's own check,
    /// which reads every entry, right and flag, refuses it (and so does not
    /// start with it). The lists are stand-ins as ls prints them; no real
    /// list changes. This is the limit of a check that reads ls's text, not
    /// a list that lets another account read the receipt.
    func testBackstopSeesOnlyWhatLsPrintsOfTheReceiptsList() throws {
        let installed = AccessEntry.installed(for: getuid())
        var hidden: [(name: String, entry: AccessEntry)] = ["synchronize", "delete_child"].map {
            var entry = installed
            entry.rights.insert($0)
            return ($0, entry)
        }
        hidden += ["file_inherit", "directory_inherit", "only_inherit"].map {
            var entry = installed
            entry.flags.insert($0)
            return ($0, entry)
        }
        for h in hidden {
            XCTAssertEqual(TestReceipts.lsText(h.entry), TestReceipts.lsText(installed), h.name)
            XCTAssertNotNil(SleepOffReceipts.receiptAccessProblem([h.entry], user: getuid()), "\(h.name): the app's check refuses it")
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            try journalUnfinishedStart()
            try fx.writeReceiptEntries([h.entry])

            let r = try fx.run(fx.backstop)

            XCTAssertEqual(r.status, 0, "\(h.name): \(r.stderr)")
            try assertSettled(sleepRestored: false)
        }
        try fx.writeReceiptEntries([installed])
    }

    /// F3 (round 28). backstop.sh, uninstall.sh, install.sh and the root
    /// command (both copies) read the receipt's list with one awk program.
    /// Fed listings in ls's shapes (file_cmds ls/print.c, TestReceipts.lsText)
    /// through the real awk, it prints a name only for exactly ` 0:
    /// user:<name> allow read`, alone, under a regular file's line. Each
    /// caller then requires `id -u -- <name>` to be the uid, which the
    /// real id(1) answers here for this user and for daemon.
    func testEveryCopyReadsTheReceiptsListWithOneProgram() throws {
        let reader = "NR == 1 { k = /^-/ }; NR == 2 && k && /^ 0: user:[^ :]+ allow read$/ { n = substr($2, 6) }; END { if (NR == 2) print n }"
        var copies = try ["backstop.sh", "uninstall.sh", "install.sh"].map { try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent($0), encoding: .utf8) }
        copies += [AdministratorPrompt.rootCommand, try appleScriptEmbeddedRootCommand()]
        for (i, copy) in copies.enumerated() {
            XCTAssertEqual(copy.components(separatedBy: "/usr/bin/awk '\(reader)'").count - 1, 1, "copy \(i)")
        }
        let me = String(cString: getpwuid(getuid()).pointee.pw_name)
        let head = "-rw-------+ 1 root  wheel  82 Oct  8 12:00 /private/var/db/com.kgarg.insomnia/\(getuid())"
        func entries(_ lines: [String]) -> String { ([head] + lines.enumerated().map { " \($0.offset): \($0.element)" }).joined(separator: "\n") }
        var cases: [(String, String)] = [
            (entries(["user:\(me) allow read"]), me),
            (entries(["user:daemon allow read"]), "daemon"),
            (entries([]), ""),
            ("", ""),
            ("d" + entries(["user:\(me) allow read"]).dropFirst(), ""),
            ("l" + entries(["user:\(me) allow read"]).dropFirst(), ""),
            (head + "\n 1: user:\(me) allow read", ""),
            (head + "\n 0: user:\(me) allow read ", ""),
            (head + "\n  0: user:\(me) allow read", ""),
            (head + "\n 0: user:\(me)  allow read", ""),
            (head + "\n 0: user:a:b allow read", ""),
            (head + "\n 0: user: allow read", ""),
            (head + "\n 0: user:\(me) allow readattr", ""),
            (head + "\n 0: user:\(me) allow read\n", ""),
            (entries(["user:\(me) allow read", "user:\(me) allow read"]), ""),
        ]
        for list in TestReceipts.refusedLists {
            let lines = list.entries.map(TestReceipts.lsText)
            cases.append((entries(lines), lines == ["user:daemon allow read"] ? "daemon" : ""))
        }
        let input = fx.root.appendingPathComponent("listing")
        for (listing, name) in cases {
            try Data((listing + "\n").utf8).write(to: input)
            let p = Process()
            let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
            p.arguments = [reader]
            p.environment = ["LC_ALL": "C"]
            p.standardInput = try FileHandle(forReadingFrom: input)
            p.standardOutput = out
            let exit = ProcessExit(p)
            try p.run()
            let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            exit.wait()
            XCTAssertEqual(p.terminationStatus, 0, listing)
            // Each caller reads it through $(...), which drops the
            // newline, and then requires a name: a refused list prints an
            // empty line or nothing.
            XCTAssertTrue(printed == name + "\n" || (name.isEmpty && printed.isEmpty), "\(listing): \(printed.debugDescription)")
        }
        XCTAssertEqual(try fx.runTool("/usr/bin/id", ["-u", "--", me]).output.trimmingCharacters(in: .whitespacesAndNewlines), fx.uid)
        XCTAssertEqual(try fx.runTool("/usr/bin/id", ["-u", "--", "daemon"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    /// The marker decides nothing: the receipt does. A marker that is
    /// another file than the one the start journaled, or one already gone,
    /// with the receipt still holding the line the start found, is settled
    /// as never having turned sleep off once the dialog is over, and kept,
    /// with no pmset, while it can still be answered.
    func testBackstopTheMarkerDecidesNothing() throws {
        for marker in [JournaledMarker.other, .gone] {
            for expiresIn in [-1, 60] {
                try? FileManager.default.removeItem(at: fx.logFile)
                fx.clearCalls()
                let nonce = try journalUnfinishedStart(expiresIn: expiresIn, marker: marker)

                let r = try fx.run(fx.backstop)

                if expiresIn < 0 {
                    XCTAssertEqual(r.status, 0, "\(marker): \(r.stderr)")
                    try assertSettled(sleepRestored: false)
                } else {
                    try assertKept(r, nonce: nonce, restored: false, saying: ["the password dialog of that start can still be answered until "])
                }
            }
        }
    }

    /// No marker journaled: the start never showed its dialog, so nothing
    /// ran as root for it, whatever the receipt holds.
    func testBackstopSettlesAStartThatShowedNoDialogAsNeverTurningSleepOff() throws {
        let nonce = try journalUnfinishedStart(marker: .none)
        try fx.writeReceipt(receiptLine(nonce, "writing"))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: false)
    }

    /// The command behind the abandoned dialog is still in pmset and holds
    /// the marker's lock and the receipt's. Nothing is settled: the
    /// receipt stays locked for the run's whole wait and the attempt
    /// stays. Round 25 (R25-2): although the dialog is over, sleep is left
    /// as it is and the run exits 1, since that pmset may still turn sleep
    /// off after an undo run now. Once the command is done, the next run
    /// settles the start as one that turned sleep off and restores sleep,
    /// and a late answer to the dialog finds no marker and writes nothing.
    func testBackstopSettlesAStartOnlyOnceTheCommandBehindItsDialogIsDone() throws {
        let nonce = try journalUnfinishedStart(endsIn: -60)
        let command = try RootCommandProcess(marker: fx.pendingStart, nonce: nonce, receipts: fx.swiftReceipts, in: fx.root, holdAt: RootCommandProcess.write)
        defer { command.release() }
        XCTAssertTrue(command.waitUntilPmsetRuns())

        let r = try fx.run(fx.backstop)

        try assertKept(r, nonce: nonce, restored: false, saying: ["an unfinished start is not settled yet: \(fx.receipt) stayed locked for 1 s"])
        XCTAssertEqual(fx.receiptText(), receiptLine(nonce, "writing"))

        command.release()
        XCTAssertEqual(command.wait().pmsetCalls, ["-g", "-g", "-a disablesleep 1"])
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        try assertSettled(sleepRestored: true)
        XCTAssertTrue(fx.log().contains("holds that start's writing line: its command was about to turn sleep off and may have"), fx.log())

        let late = try runRootCommand(marker: fx.pendingStart, nonce: nonce, receipts: fx.swiftReceipts, in: fx.root)
        XCTAssertNotEqual(late.status, 0, late.stderr)
        XCTAssertEqual(late.pmsetCalls, [], "a late answer turns nothing off")
        XCTAssertEqual(fx.receiptText(), receiptLine(nonce, "writing"), "and records nothing")
    }

    /// The settled journal cannot be published (an immutable state.json,
    /// which rename(2) will not replace). For a start whose receipt shows
    /// it never turned sleep off, with no earlier restore owed, no pmset
    /// runs: the start stays journaled with its claim (given back only
    /// once the decision is published), and the run exits 1, saying that the start's
    /// session.json was removed. The next run, still blocked, removes
    /// nothing and says nothing was removed. Once the journal can be
    /// written, the start is settled, still with no pmset.
    func testBackstopRunsNoPmsetForAStartThatNeverWroteWhileItsSettlementCannotBePublished() throws {
        let nonce = try journalUnfinishedStart(marker: .gone)
        try fx.writeReceipt(receiptLine(nonce, "refused"))
        let before = try Data(contentsOf: fx.state)
        XCTAssertEqual(chflags(fx.state.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(fx.state.path, 0) }

        for run in 1...2 {
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            let r = try fx.run(fx.backstop)

            try assertKept(r, nonce: nonce, restored: false, saying: [
                "the receipt shows that the command behind that start's dialog never turned sleep off and no earlier restore is owed, but an unfinished start could not be settled: the settled journal could not be published to \(fx.state.path)",
            ])
            XCTAssertEqual(try Data(contentsOf: fx.state), before, "run \(run): the start stays journaled")
            XCTAssertFalse(fx.exists(fx.session), "run \(run): its session is not left to be resumed")
            XCTAssertEqual(fx.log().contains("; \(fx.session.path) of that start was removed"), run == 1, "run \(run): \(fx.log())")
            XCTAssertEqual(try fx.contents(of: fx.home).filter { $0.hasPrefix(".state.json.") }, [], "run \(run): no copy is left behind")
        }

        XCTAssertEqual(chflags(fx.state.path, 0), 0)
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        try assertSettled(sleepRestored: false)
    }

    /// The same for a start whose receipt shows its command wrote: sleep
    /// is restored, as the start may have turned it off, and the start
    /// stays journaled until the journal can be written.
    func testBackstopRestoresSleepAndKeepsAStartThatWroteWhileItsSettlementCannotBePublished() throws {
        let nonce = try journalUnfinishedStart(marker: .gone)
        try fx.writeReceipt(receiptLine(nonce, "writing"))
        XCTAssertEqual(chflags(fx.state.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(fx.state.path, 0) }

        let r = try fx.run(fx.backstop)

        try assertKept(r, nonce: nonce, restored: true, saying: ["an unfinished start could not be settled: the settled journal could not be published to \(fx.state.path)"])

        XCTAssertEqual(chflags(fx.state.path, 0), 0)
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        try assertSettled(sleepRestored: true)
    }

    /// The start's session.json cannot be removed (an immutable flag): the
    /// start stays journaled with its claim and the run exits 1, saying
    /// nothing was removed. No pmset runs for a start whose receipt shows
    /// it never turned sleep off; sleep is restored for one whose receipt
    /// shows it wrote. Once the session can go, the start is settled.
    func testBackstopKeepsTheStartWhenItsSessionCannotBeRemoved() throws {
        for (word, restored) in [("refused", false), ("writing", true)] {
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            let nonce = try journalUnfinishedStart()
            try fx.writeReceipt(receiptLine(nonce, word))
            XCTAssertEqual(chflags(fx.session.path, UInt32(UF_IMMUTABLE)), 0)

            let r = try fx.run(fx.backstop)

            chflags(fx.session.path, 0)
            try assertKept(r, nonce: nonce, restored: restored, saying: ["an unfinished start could not be settled: \(fx.session.path) could not be removed. Nothing was removed"])
            XCTAssertTrue(fx.exists(fx.session), word)

            fx.clearCalls()
            let again = try fx.run(fx.backstop)

            XCTAssertEqual(again.status, 0, "\(word): \(again.stderr)")
            try assertSettled(sleepRestored: restored)
        }
    }

    /// F6: a `head`, a `cat` and a `tr` first in PATH that would forge the
    /// receipt's line (this start's `refused`), a claim already given back,
    /// an unreadable session.json and JSON files that do not start with
    /// "{". The run reads the receipt, the release file, session.json and
    /// the journal through its fixed HEAD, CAT and TR only (round 28,
    /// finding 5: no bare one is left), session.json and the journal from
    /// the copies its fixed perl makes (round 30): the start is undone as
    /// its real line says, its real claim is given back and its session
    /// goes. The PATH the fixed tools were given shows that PATH was in
    /// effect.
    func testBackstopSettlesThroughItsOwnToolsWhateverPathHolds() throws {
        let nonce = try journalUnfinishedStart()
        try fx.writeReceipt(receiptLine(nonce, "writing"))
        let hostile = try fx.writeHostileTools(forging: nonce)

        let r = try fx.run(fx.backstop, extraEnvironment: ["PATH": fx.path(first: hostile)])

        XCTAssertEqual(r.status, 0, r.stderr)
        try assertSettled(sleepRestored: true)
        XCTAssertTrue(fx.log().contains("holds that start's writing line: its command was about to turn sleep off and may have"), fx.log())
        XCTAssertTrue(fx.log().contains("removed \(fx.session.path): its start never finished"), fx.log())
        XCTAssertEqual(try movedAsideSessions(), [])
        XCTAssertEqual(fx.hostileCalls(), [], "no head, cat or tr is taken from PATH")
        XCTAssertFalse(fx.toolPaths().isEmpty)
        XCTAssertTrue(fx.toolPaths().allSatisfy { $0.hasPrefix(hostile + ":") }, "PATH was in effect: \(fx.toolPaths())")
        let tools = fx.toolCalls()
        XCTAssertTrue(tools.contains("head -c 83") && tools.contains("head -c 43 \(fx.released)"), "\(tools)")
        XCTAssertTrue(tools.contains { $0.hasPrefix("cat \(fx.home.path)/.backstop-read.") && $0.hasSuffix("/state.json") }, "\(tools)")
        XCTAssertFalse(tools.contains { $0.contains(fx.session.path) || $0.contains(fx.state.path) }, "nothing reads the live files in place: \(tools)")
    }

    // MARK: Round 25 (R25-1, R25-2): settlements cut short, and a busy receipt

    /// The journal a settlement leaves when it stops once its decision is
    /// published: the start's record, settled, and sleepDisabledByUs as
    /// decided.
    private func journalTheDecision(_ sleepDisabledByUs: Bool) throws {
        var state = try fx.stateJSON()
        var attempt = try XCTUnwrap(state["sleepOffAttempt"] as? [String: Any])
        attempt["settled"] = true
        state["sleepOffAttempt"] = attempt
        state["sleepDisabledByUs"] = sleepDisabledByUs
        try fx.writeState(String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self))
    }

    /// A settlement that stopped once its decision was in the journal (a
    /// crash, or a failure) is finished by the next run from that decision
    /// alone: the claim goes back if it is still held, the record goes,
    /// and the undo follows the decision. Covered: the claim still held,
    /// the claim already given back, and one or two later starts of
    /// another Insomnia folder whose lines replaced the one this start
    /// was decided on (the later lines show nothing about this start, so
    /// a run that read the receipt again could decide otherwise). The
    /// receipt is never written, and a later start's release is left.
    func testBackstopFinishesASettlementWhoseDecisionIsJournaled() throws {
        for decided in [false, true] {
            for later in [-1, 0, 1, 2] {
                let name = "decided \(decided), later \(later)"
                try? FileManager.default.removeItem(at: fx.logFile)
                fx.clearCalls()
                let nonce = try journalUnfinishedStart(owedBefore: decided, marker: .gone, session: false)
                try journalTheDecision(decided)
                var release = "\(nonce) held\n"
                if later >= 0 {
                    release = "\(SleepOffReceipts.zero) free\n"
                    var line = SleepOffReceipts.zero
                    for _ in 0..<later {
                        let next = UUID().uuidString
                        try fx.writeReceipt(receiptLine(next, "refused", predecessor: line))
                        line = next
                        release = "\(next) free\n"
                    }
                    try fx.writeRelease(release)
                }
                let receipt = fx.receiptText()

                for run in 1...2 {
                    let r = try fx.run(fx.backstop)

                    XCTAssertEqual(r.status, 0, "\(name), run \(run): \(r.stderr) \(fx.log())")
                    XCTAssertEqual(fx.calls(), decided && run == 1 ? ["sudo -n \(fx.fakePmset) -a disablesleep 0"] : [], "\(name), run \(run)")
                    XCTAssertNil(try fx.stateJSON()["sleepOffAttempt"], name)
                    XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false, name)
                    XCTAssertEqual(fx.receiptText(), receipt, "\(name): the receipt is only read")
                    XCTAssertEqual(fx.release(), later < 0 ? "\(String((receipt ?? "").prefix(36))) free\n" : release, name)
                    if run == 1 {
                        XCTAssertTrue(fx.log().contains("finishing the settlement of an earlier start, which the journal records as settled"), "\(name): \(fx.log())")
                        XCTAssertTrue(fx.log().contains(later < 0 ? "the settlement is finished: the start's claim on the receipt was given back and its record removed" : "the settlement is finished: the start held no claim on the receipt and its record removed"), "\(name): \(fx.log())")
                    }
                    fx.clearCalls()
                }
            }
        }
    }

    /// A settled record the run cannot finish holds nothing back: the undo
    /// follows the decision, the record stays settled with its decision,
    /// the run exits 1 run after run, and once the cause is gone the next
    /// run finishes it. Causes: a claim that cannot be given back (a
    /// release file not as install.sh made it), a record that cannot be
    /// removed (an immutable state.json, once the claim went back), and a
    /// receipt that stays locked.
    func testBackstopKeepsASettledRecordItCannotFinishAndHoldsNothingBack() throws {
        let cases: [(name: String, decided: Bool, damage: () throws -> Void, repair: () throws -> Void, says: String)] = [
            ("claim", true, { try "short\n".write(toFile: self.fx.released, atomically: false, encoding: .utf8) },
             { }, "an unfinished start is settled, but its claim on the receipt could not be given back (\(fx.released) is not the 42-byte file install.sh made. Run install.sh again)"),
            ("record", false, { XCTAssertEqual(chflags(self.fx.state.path, UInt32(UF_IMMUTABLE)), 0) },
             { XCTAssertEqual(chflags(self.fx.state.path, 0), 0) }, "an unfinished start is settled, but its settled record could not be removed from \(fx.state.path)"),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            let nonce = try journalUnfinishedStart(marker: .gone, session: false)
            try journalTheDecision(c.decided)
            try c.damage()
            defer { chflags(fx.state.path, 0) }

            for run in 1...2 {
                let r = try fx.run(fx.backstop)

                XCTAssertEqual(r.status, 1, "\(c.name), run \(run): \(r.stderr)")
                XCTAssertTrue(fx.log().contains(c.says), "\(c.name), run \(run): \(fx.log())")
                XCTAssertEqual(fx.calls(), c.decided && run == 1 ? ["sudo -n \(fx.fakePmset) -a disablesleep 0"] : [], "\(c.name), run \(run): the undo follows the decision")
                let attempt = try XCTUnwrap(try fx.stateJSON()["sleepOffAttempt"] as? [String: Any], "\(c.name), run \(run)")
                XCTAssertEqual(attempt["nonce"] as? String, nonce, c.name)
                XCTAssertEqual(attempt["settled"] as? Bool, true, c.name)
                XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false, c.name)
                XCTAssertEqual(fx.release(), c.name == "claim" ? "short\n" : "\(String((fx.receiptText() ?? "").prefix(36))) free\n", c.name)
                fx.clearCalls()
            }

            try c.repair()
            if c.name == "claim" { try fx.writeRelease("\(nonce) held\n") }
            let again = try fx.run(fx.backstop)

            XCTAssertEqual(again.status, 0, "\(c.name): \(again.stderr)")
            XCTAssertEqual(fx.calls(), [], c.name)
            XCTAssertNil(try fx.stateJSON()["sleepOffAttempt"], c.name)
            XCTAssertEqual(fx.release(), "\(String((fx.receiptText() ?? "").prefix(36))) free\n", c.name)
        }

        // A receipt that stays locked: the decision still counts, so the
        // undo runs, and the record stays until the lock is let go.
        try? FileManager.default.removeItem(at: fx.logFile)
        fx.clearCalls()
        let nonce = try journalUnfinishedStart(marker: .gone, session: false)
        try journalTheDecision(true)
        let fd = open(fx.receipt, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let r = try fx.run(fx.backstop)

        close(fd)
        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertTrue(fx.log().contains("an unfinished start is settled, but the receipt could not be locked to give its claim back (\(fx.receipt) stayed locked for 1 s"), fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual((try fx.stateJSON()["sleepOffAttempt"] as? [String: Any])?["settled"] as? Bool, true)
        XCTAssertEqual(fx.release(), "\(nonce) held\n")

        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertNil(try fx.stateJSON()["sleepOffAttempt"])
        XCTAssertEqual(fx.release(), "\(String((fx.receiptText() ?? "").prefix(36))) free\n")
    }

    /// R25-2: a receipt that stays locked may be held by the command
    /// behind the start's dialog, which may still be in pmset whether or
    /// not the dialog's expiry has passed. The sleep undo waits whatever
    /// the time and whatever an earlier session owes, run after run, while
    /// the rest of the undo (Low Power Mode here) goes on. Once the lock is
    /// let go and the dialog is over, the receipt (which still shows the
    /// line the start found) settles the start, and the restore an earlier
    /// session owes runs then. The test holds the receipt's lock from
    /// before each locked run until after it, so the backstop's lockf is
    /// given no wait (`-t 0`): it finds the lock held as surely as after a
    /// longer wait, and once the test lets go it takes it at once.
    func testBackstopHoldsTheSleepUndoWhileTheReceiptIsLockedWhateverTheWindowAndTheOwedRestore() throws {
        let text = try String(contentsOf: fx.backstop, encoding: .utf8)
        try ScriptFixture.patch(text, ["RECEIPT_LOCK_TIMEOUT_SECONDS": "0"]).write(to: fx.backstop, atomically: true, encoding: .utf8)
        for expired in [false, true] {
            for owed in [false, true] {
                let name = "expired \(expired), owed \(owed)"
                try? FileManager.default.removeItem(at: fx.logFile)
                fx.clearCalls()
                let nonce = try journalUnfinishedStart(owedBefore: owed, expiresIn: expired ? -1 : 60)
                var state = try fx.stateJSON()
                state["lowPowerSetByUs"] = true
                try fx.writeState(String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self))
                let fd = open(fx.receipt, O_RDONLY)
                XCTAssertGreaterThanOrEqual(fd, 0)
                XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

                for run in 1...2 {
                    let r = try fx.run(fx.backstop)

                    XCTAssertEqual(r.status, 1, "\(name), run \(run): \(r.stderr)")
                    XCTAssertFalse(fx.calls().contains { $0.contains("disablesleep") }, "\(name), run \(run): \(fx.calls())")
                    XCTAssertEqual(fx.calls().contains("sudo -n \(fx.fakePmset) -b lowpowermode 0"), run == 1, "\(name), run \(run): \(fx.calls())")
                    let after = try fx.stateJSON()
                    XCTAssertEqual((after["sleepOffAttempt"] as? [String: Any])?["nonce"] as? String, nonce, name)
                    XCTAssertEqual(after["sleepDisabledByUs"] as? Bool, true, name)
                    XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false, name)
                    XCTAssertEqual(fx.release(), "\(nonce) held\n", name)
                    XCTAssertTrue(fx.log().contains("an unfinished start is not settled yet: \(fx.receipt) stayed locked for 0 s"), "\(name): \(fx.log())")
                    XCTAssertTrue(fx.log().contains("sleepDisabledByUs stays journaled, and sleep is left as it is: "), "\(name): \(fx.log())")
                    fx.clearCalls()
                }
                close(fd)

                if !expired {
                    let r = try fx.run(fx.backstop)
                    try assertKept(r, nonce: nonce, restored: false, saying: ["the password dialog of that start can still be answered until "])
                    try endTheDialog()
                    fx.clearCalls()
                }
                let again = try fx.run(fx.backstop)

                XCTAssertEqual(again.status, 0, "\(name): \(again.stderr)")
                try assertSettled(sleepRestored: owed)
            }
        }
    }

    // MARK: - uninstall.sh settles an unfinished start and removes the receipt

    /// uninstall.sh settles the start before its backstop runs: a receipt
    /// that shows the command never turned sleep off leaves sleep alone.
    /// Then the receipt and its release file go, under the receipt's lock
    /// while the release file shows the receipt's own nonce free, and
    /// their folder with them once empty, all through sudo by their fixed
    /// paths.
    func testUninstallSettlesAStartThatNeverTurnedSleepOffAndRemovesTheReceipt() throws {
        try fx.installMachinery()
        try journalUnfinishedStart()

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("settling an unfinished start: its receipt shows the command behind its dialog never turned sleep off; sleepDisabledByUs goes back to false"), r.stdout)
        XCTAssertTrue(r.stdout.contains("removed \(fx.session.path): its start never finished"), r.stdout)
        XCTAssertFalse(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo -n /bin/rm -f \(fx.receipt)"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo -n /bin/rm -f \(fx.released)"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo -n /bin/rmdir \(fx.receipts)"), "\(fx.calls())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts))
        XCTAssertFalse(fx.exists(fx.sudoers))
    }

    /// The receipt shows this start's `writing`: uninstall settles it as one
    /// that may have turned sleep off, and its backstop restores sleep.
    func testUninstallUndoesAStartWhoseReceiptShowsItsCommandWrote() throws {
        try fx.installMachinery()
        let nonce = try journalUnfinishedStart()
        try fx.writeReceipt(receiptLine(nonce, "writing"))

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("settling an unfinished start as one that may have turned sleep off (\(fx.receipt) holds that start's writing line: its command was about to turn sleep off and may have)"), r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts))
    }

    /// Asserts uninstall stopped with the start still journaled and its
    /// claim held, nothing of the install removed and no pmset run.
    private func assertUninstallStopped(_ r: (status: Int32, stdout: String, stderr: String), nonce: String, saying: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, 1, r.stdout, file: file, line: line)
        for phrase in saying { XCTAssertTrue(r.stderr.contains(phrase), "\(phrase): \(r.stderr)", file: file, line: line) }
        XCTAssertFalse(fx.calls().contains { $0.contains("disablesleep") }, "no pmset: \(fx.calls())", file: file, line: line)
        XCTAssertEqual((try fx.stateJSON()["sleepOffAttempt"] as? [String: Any])?["nonce"] as? String, nonce, file: file, line: line)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(fx.release(), "\(nonce) held\n", file: file, line: line)
        XCTAssertTrue(fx.exists(fx.sudoers), file: file, line: line)
        XCTAssertTrue(fx.exists(fx.plist), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.receipt), file: file, line: line)
    }

    /// A settlement uninstall cannot publish stops it with nothing removed
    /// and no pmset, the claim still held.
    func testUninstallStopsWithNothingRemovedWhenTheSettlementCannotBePublished() throws {
        try fx.installMachinery()
        let nonce = try journalUnfinishedStart(marker: .gone, session: false)
        let before = try Data(contentsOf: fx.state)
        XCTAssertEqual(chflags(fx.state.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(fx.state.path, 0) }

        let r = try fx.run(fx.uninstall)

        try assertUninstallStopped(r, nonce: nonce, saying: [
            "The unfinished start is still journaled: the settled journal could not be published to \(fx.state.path).",
            "Nothing was removed and no pmset ran. Then rerun.",
        ])
        XCTAssertEqual(try Data(contentsOf: fx.state), before)
    }

    /// A start whose dialog can still be answered is not settled yet: the
    /// uninstall stops before its backstop runs, says how long to wait,
    /// and removes nothing.
    func testUninstallStopsWhileAStartsDialogCanStillBeAnswered() throws {
        try fx.installMachinery()
        let nonce = try journalUnfinishedStart(expiresIn: 60)

        let r = try fx.run(fx.uninstall)

        try assertUninstallStopped(r, nonce: nonce, saying: [
            "The unfinished start is still journaled: it is not settled yet (the password dialog of that start can still be answered until ",
            "Wait for that to pass: a start's password dialog can be answered for about two minutes after it was shown, and a command it started holds the receipt until pmset exits.",
            "Nothing was removed and no pmset ran. Then rerun.",
        ])
        XCTAssertTrue(fx.exists(fx.session))
    }

    /// The session of a start that never turned sleep off cannot be
    /// removed: the uninstall stops with nothing removed and no pmset.
    func testUninstallStopsWhenTheStartsSessionCannotBeRemoved() throws {
        try fx.installMachinery()
        let nonce = try journalUnfinishedStart()
        XCTAssertEqual(chflags(fx.session.path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(fx.session.path, 0) }

        let r = try fx.run(fx.uninstall)

        try assertUninstallStopped(r, nonce: nonce, saying: [
            "The unfinished start is still journaled: \(fx.session.path) of that start could not be removed.",
            "Nothing was removed and no pmset ran. Then rerun.",
        ])
    }

    /// A release file that is not as install.sh made it keeps the claim
    /// from being given back. Round 25 (R25-1): the decision is journaled
    /// first, so the uninstall stops saying that it removed the start's
    /// session.json and journaled the decision, and nothing else. Once the
    /// release file is repaired, the next uninstall finishes the settled
    /// record from the journal, without reading the receipt against it
    /// again, and goes on.
    func testUninstallSaysWhatItRemovedWhenTheClaimCannotBeGivenBack() throws {
        try fx.installMachinery()
        let nonce = try journalUnfinishedStart()
        try "short\n".write(toFile: fx.released, atomically: false, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stdout)
        XCTAssertTrue(r.stderr.contains("The unfinished start is still journaled: it is settled, but its claim on the receipt could not be given back (\(fx.released) is not the 42-byte file install.sh made. Run install.sh again)."), r.stderr)
        XCTAssertTrue(r.stderr.contains("\(fx.session.path) was removed, and the decision was journaled in \(fx.state.path) as settled; nothing else was, and no pmset ran. Then rerun."), r.stderr)
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.calls().contains { $0.contains("disablesleep") }, "\(fx.calls())")
        let attempt = try XCTUnwrap(try fx.stateJSON()["sleepOffAttempt"] as? [String: Any])
        XCTAssertEqual(attempt["nonce"] as? String, nonce)
        XCTAssertEqual(attempt["settled"] as? Bool, true)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false, "never wrote, and nothing earlier owed")
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.receipt))

        try fx.writeRelease("\(nonce) held\n")
        fx.clearCalls()
        let again = try fx.run(fx.uninstall)

        XCTAssertEqual(again.status, 0, again.stderr + again.stdout)
        XCTAssertTrue(again.stdout.contains("finishing the settlement of an earlier start, which the journal records as settled"), again.stdout)
        XCTAssertTrue(again.stdout.contains("the settlement is finished: the start's claim on the receipt was given back and its record removed"), again.stdout)
        XCTAssertFalse(fx.calls().contains { $0.contains("disablesleep") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts))
    }

    /// F6 for uninstall.sh: the same hostile `head`, `cat` and `tr` first
    /// in PATH. The start is settled from the real receipt and release
    /// file, its session goes, its backstop restores sleep, and the receipt
    /// and release file are removed, as the real claim was given back. No
    /// file is read through a tool from PATH; a bare `cat` prints only this
    /// script's own messages. session.json and the journal are read only
    /// through private copies, never in place.
    func testUninstallSettlesThroughItsOwnToolsWhateverPathHolds() throws {
        try fx.installMachinery()
        let nonce = try journalUnfinishedStart()
        try fx.writeReceipt(receiptLine(nonce, "writing"))
        let hostile = try fx.writeHostileTools(forging: nonce)

        let r = try fx.run(fx.uninstall, extraEnvironment: ["PATH": fx.path(first: hostile)])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("settling an unfinished start as one that may have turned sleep off (\(fx.receipt) holds that start's writing line: its command was about to turn sleep off and may have)"), r.stdout)
        XCTAssertTrue(r.stdout.contains("removed \(fx.session.path): its start never finished"), r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo -n /bin/rm -f \(fx.released)"), "\(fx.calls())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts))
        XCTAssertEqual(fx.hostileCalls(), [], "no file is read through a head, cat or tr from PATH")
        XCTAssertFalse(fx.toolPaths().isEmpty)
        XCTAssertTrue(fx.toolPaths().allSatisfy { $0.hasPrefix(hostile + ":") }, "PATH was in effect: \(fx.toolPaths())")
        let tools = fx.toolCalls()
        XCTAssertTrue(tools.contains("head -c 83") && tools.contains("head -c 43 \(fx.released)"), "\(tools)")
        XCTAssertFalse(tools.contains { $0.contains(fx.session.path) || $0.contains(fx.state.path) }, "nothing reads the live files in place: \(tools)")
    }

    /// Round 28, finding 5: the reads of session.json and the journal
    /// outside the settlement go through the fixed CAT, HEAD and TR too.
    /// With the hostile tools first in PATH, a session that is still valid
    /// is kept and nothing is undone, where a bare `cat` that failed or a
    /// bare `tr` or `head` that misread the file made it unreadable or
    /// malformed, so treated as expired. An expired one is undone and the
    /// journal published after the undo is checked through HEAD, where a
    /// bare `head` that misread it kept the journal from being published.
    func testBackstopReadsTheSessionAndPublishesTheJournalThroughItsOwnTools() throws {
        for valid in [true, false] {
            let label = valid ? "valid session" : "expired session"
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: valid ? 3600 : -60))
            let session = try Data(contentsOf: f.session)
            try f.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            let hostile = try f.writeHostileTools(forging: UUID().uuidString)

            let r = try f.run(f.backstop, extraEnvironment: ["PATH": f.path(first: hostile)])

            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr + f.log())")
            XCTAssertEqual(f.hostileCalls(), [], label)
            XCTAssertTrue(!f.toolPaths().isEmpty && f.toolPaths().allSatisfy { $0.hasPrefix(hostile + ":") }, "\(label): \(f.toolPaths())")
            let tools = f.toolCalls()
            XCTAssertTrue(tools.contains("tr -d") && tools.contains("head -c 1"), "\(label): \(tools)")
            XCTAssertFalse(tools.contains { $0.contains(f.session.path) || $0.contains(f.state.path) }, "\(label): nothing reads the live files in place: \(tools)")
            if valid {
                XCTAssertEqual(f.calls(), [], label)
                XCTAssertEqual(try Data(contentsOf: f.session), session, label)
                XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, true, label)
                XCTAssertFalse(f.log().contains("cannot be read") || f.log().contains("unreadable") || f.log().contains("disablesleep"), "\(label): \(f.log())")
            } else {
                XCTAssertEqual(f.calls(), ["sudo -n \(f.fakePmset) -a disablesleep 0"], label)
                XCTAssertFalse(f.exists(f.session), label)
                XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, false, label)
                XCTAssertTrue(tools.contains { $0.hasPrefix("head -c 1 ") && $0.contains(".state.json.backstop.") }, "\(label): \(tools)")
            }
        }
    }

    /// Round 28, finding 5, for uninstall.sh: the session.json its own
    /// journal check finds is read through HEAD and TR, from a private
    /// copy, so with the hostile tools first in PATH it is named as a
    /// session still present, not as one that cannot be read or is not a
    /// session.
    func testUninstallReadsALeftoverSessionThroughItsOwnTools() throws {
        try fx.installMachinery()
        try "#!/bin/bash\nexit 0\n".write(to: fx.backstop, atomically: true, encoding: .utf8)
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let hostile = try fx.writeHostileTools(forging: UUID().uuidString)

        let r = try fx.run(fx.uninstall, ["--purge"], extraEnvironment: ["PATH": fx.path(first: hostile)])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(r.stderr.contains("  - session.json is still present\n"), r.stderr)
        XCTAssertFalse(r.stderr.contains("session.json is still present and cannot be read") || r.stderr.contains("session.json is still present and is not a session"), r.stderr)
        XCTAssertEqual(fx.hostileCalls(), [])
        let tools = fx.toolCalls()
        XCTAssertTrue(tools.contains("tr -d") && tools.contains("head -c 1"), "\(tools)")
        XCTAssertFalse(tools.contains { $0.contains(fx.session.path) || $0.contains(fx.state.path) }, "nothing reads the live files in place: \(tools)")
        try assertNothingRemoved(fx, state: nil, "leftover session")
    }

    /// R25-1 for uninstall.sh: a record whose decision a settlement
    /// journaled before it stopped (here behind two later starts of
    /// another Insomnia folder, which no longer show this start's line) is
    /// finished from that decision. The uninstall goes on, with the
    /// backstop's restore when the decision says sleep may be off.
    func testUninstallFinishesASettlementWhoseDecisionIsJournaled() throws {
        for decided in [false, true] {
            try? FileManager.default.removeItem(at: fx.installedBackstop)
            try fx.installMachinery()
            fx.clearCalls()
            let nonce = try journalUnfinishedStart(owedBefore: decided, marker: .gone, session: false)
            try journalTheDecision(decided)
            let first = UUID().uuidString, second = UUID().uuidString
            try fx.writeReceipt(receiptLine(first, "refused", predecessor: SleepOffReceipts.zero))
            try fx.writeReceipt(receiptLine(second, "refused", predecessor: first))
            try fx.writeRelease("\(second) free\n")

            let r = try fx.run(fx.uninstall)

            XCTAssertEqual(r.status, 0, "\(decided): \(r.stderr + r.stdout)")
            XCTAssertTrue(r.stdout.contains("finishing the settlement of an earlier start, which the journal records as settled"), r.stdout)
            XCTAssertTrue(r.stdout.contains("the settlement is finished: the start held no claim on the receipt and its record removed"), r.stdout)
            XCTAssertFalse(r.stdout.contains("settling an unfinished start"), "\(nonce): not decided again: \(r.stdout)")
            XCTAssertEqual(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), decided, "\(decided): \(fx.calls())")
            XCTAssertFalse(fx.exists(fx.sudoers), "\(decided)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts), "\(decided)")
        }
    }

    /// Another account's receipt keeps the folder; this account's receipt
    /// and release file go.
    func testUninstallKeepsTheReceiptFolderWhileAnotherAccountsReceiptIsInIt() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeReceipt()
        let other = fx.receipts + "/" + String(getuid() + 1)
        try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: other))

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.released))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other))
        XCTAssertTrue(r.stdout.contains("kept \(fx.receipts): it still holds another account's receipt"), r.stdout)
    }

    // MARK: Round 28 (finding 2): what every Insomnia folder of this user shares

    /// A journal of this folder with nothing to undo.
    private let cleanJournal = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#

    /// Whether a fake call is sudo removing something as root: rm or rmdir,
    /// with or without -n.
    static func isRootRemoval(_ call: String) -> Bool {
        call.hasPrefix("sudo /bin/rm") || call.hasPrefix("sudo -n /bin/rm")
    }

    /// Asserts the uninstall stopped before removing anything, saying
    /// `saying`: exit 1, launchctl never asked to boot the agent out, sudo
    /// asked to remove nothing, and the rule, the agent plist, the bundle
    /// with its sealed backstop.sh, the journal, the receipt and the
    /// release file all as they were.
    private func assertUninstallRemovedNothing(_ r: (status: Int32, stdout: String, stderr: String), saying: String, journal: Data, receipt: String?, release: String?, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, 1, r.stdout + r.stderr, file: file, line: line)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything: \(saying)."), r.stderr, file: file, line: line)
        XCTAssertTrue(r.stderr.contains("The LaunchAgent, \(fx.sudoers.path), \(fx.app.path), the receipt and the journal were kept."), r.stderr, file: file, line: line)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl bootout") }, "\(fx.calls())", file: file, line: line)
        XCTAssertFalse(fx.calls().contains { Self.isRootRemoval($0) }, "\(fx.calls())", file: file, line: line)
        XCTAssertTrue(fx.exists(fx.sudoers), "the rule that turns sleep back on stays", file: file, line: line)
        XCTAssertTrue(fx.exists(fx.plist), "the agent stays", file: file, line: line)
        XCTAssertTrue(fx.exists(fx.installedBackstop), "the bundle and its sealed backstop.sh stay", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fx.state), journal, file: file, line: line)
        XCTAssertTrue(fx.exists(fx.config), file: file, line: line)
        XCTAssertTrue(fx.exists(fx.logFile), file: file, line: line)
        XCTAssertEqual(fx.receiptText(), receipt, file: file, line: line)
        XCTAssertEqual(fx.release(), release, file: file, line: line)
    }

    /// Finding 2, with two Insomnia folders of this user. This folder's
    /// journal is clean, and a start of the other folder claims the
    /// receipt: its app has exited, so no Insomnia process runs, and its
    /// journal is in a folder this uninstall never sees. Whether the
    /// receipt shows that start's `writing` or `refused`, the uninstall
    /// stops before removing anything. The other folder's recovery agent
    /// can then still settle that start and, where the receipt shows its
    /// command may have turned sleep off, restore sleep through the rule
    /// (the fake sudo runs the restore only while the rule is there). Once
    /// that start is settled, the uninstall removes everything.
    func testUninstallRemovesNothingWhileAStartOfAnotherFolderClaimsTheReceipt() throws {
        for word in ["writing", "refused"] {
            try? FileManager.default.removeItem(at: fx.installedBackstop)
            try fx.installMachinery()
            fx.clearCalls()
            FileManager.default.createFile(atPath: fx.root.appendingPathComponent("sudo.needs-rule").path, contents: nil)
            // The other folder's journal: what journalUnfinishedStart
            // writes, moved to a folder of its own.
            let other = fx.root.appendingPathComponent("other-\(word)", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let nonce = try journalUnfinishedStart(marker: .gone, session: false)
            try FileManager.default.moveItem(at: fx.state, to: other.appendingPathComponent("state.json"))
            try fx.writeState(cleanJournal)
            try fx.writeReceipt(receiptLine(nonce, word))
            let journal = try Data(contentsOf: fx.state)

            let r = try fx.run(fx.uninstall)

            try assertUninstallRemovedNothing(r, saying: "\(fx.released) shows that a start (\(nonce)) claims the receipt and is not settled yet", journal: journal, receipt: receiptLine(nonce, word), release: "\(nonce) held\n")
            XCTAssertTrue(r.stderr.contains("Open Insomnia from that folder or let its recovery agent run, then rerun."), r.stderr)

            fx.clearCalls()
            let settle = try fx.run(fx.backstop, extraEnvironment: ["INSOMNIA_HOME": other.path])

            XCTAssertEqual(settle.status, 0, "\(word): \(settle.stderr)")
            XCTAssertEqual(fx.calls(), word == "writing" ? ["sudo -n \(fx.fakePmset) -a disablesleep 0"] : [], word)
            let settled = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: other.appendingPathComponent("state.json"))) as? [String: Any])
            XCTAssertNil(settled["sleepOffAttempt"], word)
            XCTAssertEqual(settled["sleepDisabledByUs"] as? Bool, false, word)
            XCTAssertEqual(fx.release(), "\(nonce) free\n", word)

            fx.clearCalls()
            let again = try fx.run(fx.uninstall)

            XCTAssertEqual(again.status, 0, "\(word): \(again.stderr + again.stdout)")
            XCTAssertFalse(fx.exists(fx.sudoers), word)
            XCTAssertFalse(fx.exists(fx.app), word)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts), word)
        }
    }

    /// The receipt stays locked (here by this test, as the root command
    /// behind another folder's dialog or that folder's settlement would
    /// hold it): what that command does is not known, so the uninstall
    /// stops before removing anything.
    func testUninstallRemovesNothingWhileTheReceiptIsLocked() throws {
        try fx.installMachinery()
        try fx.writeState(cleanJournal)
        try fx.writeReceipt()
        let journal = try Data(contentsOf: fx.state)
        let fd = open(fx.receipt, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let r = try fx.run(fx.uninstall)

        try assertUninstallRemovedNothing(r, saying: "\(fx.receipt) stayed locked for 1 s: the command behind a password dialog may be running, or another Insomnia folder of this user, or something else running as this user, is holding it", journal: journal, receipt: SleepOffReceipts.initialContent, release: SleepOffReceipts.initialRelease)
    }

    /// Release files, receipts and folders that do not show whether a start
    /// claims the receipt: each stops the uninstall before it removes
    /// anything. Round 30 (finding 2): so does a receipt without its release
    /// file or the other way round, which an install or a recovery that did
    /// not finish leaves, and a read of either file that prints it whole but
    /// exits nonzero.
    func testUninstallRemovesNothingWhileTheSharedFilesShowNothingItCanTrust() throws {
        let other = UUID().uuidString
        try wrapHead(in: fx.uninstall, of: fx)
        let headFails = fx.root.appendingPathComponent("head.fail")
        let cases: [(name: String, prepare: () throws -> Void, saying: String, receipt: String?, release: String?)] = [
            ("damaged release file", { try self.fx.writeRelease("short\n") },
             "\(fx.released) is not the 42-byte file install.sh made. Run install.sh again", SleepOffReceipts.initialContent, "short\n"),
            ("release file of another nonce", { try self.fx.writeRelease("\(other) free\n") },
             "\(fx.released) holds \(other) free, not the receipt's own nonce, so it does not show that no start claims the receipt", SleepOffReceipts.initialContent, "\(other) free\n"),
            ("unreadable release file", { XCTAssertEqual(chmod(self.fx.released, 0), 0) },
             "\(fx.released) could not be read (head exit 1)", SleepOffReceipts.initialContent, nil),
            ("release file read whole by a head that then fails", { try "-c 43 *".write(to: headFails, atomically: true, encoding: .utf8) },
             "\(fx.released) could not be read (head exit 3)", SleepOffReceipts.initialContent, SleepOffReceipts.initialRelease),
            ("receipt read whole by a head that then fails", { try "-c 83".write(to: headFails, atomically: true, encoding: .utf8) },
             "\(fx.receipt) could not be read (head exit 3)", SleepOffReceipts.initialContent, SleepOffReceipts.initialRelease),
            ("receipt without its release file", { try FileManager.default.removeItem(atPath: self.fx.released) },
             "\(fx.receipt) is there without its release file \(fx.released), so it does not show that no start claims the receipt", SleepOffReceipts.initialContent, nil),
            ("release file without its receipt", { try FileManager.default.removeItem(atPath: self.fx.receipt) },
             "\(fx.released) is there without the receipt \(fx.receipt), and no record of this folder's uninstall (\(fx.home.path)/.uninstall-receipt-removal) names it as it is now, so what the receipt showed, and whether a start still needs the rule, is unknown", nil, SleepOffReceipts.initialRelease),
            ("damaged receipt", { try self.fx.writeReceipt(String(repeating: "x", count: 81) + "\n") },
             "\(fx.receipt) does not hold two nonces and writing or refused", String(repeating: "x", count: 81) + "\n", SleepOffReceipts.initialRelease),
            ("release file that is a folder", {
                try FileManager.default.removeItem(atPath: self.fx.released)
                try FileManager.default.createDirectory(atPath: self.fx.released, withIntermediateDirectories: false)
             }, "\(fx.receipt) or \(fx.released) is not a regular file, so install.sh did not make it", SleepOffReceipts.initialContent, nil),
            ("receipt folder someone else can change", { XCTAssertEqual(chmod(self.fx.receipts, 0o775), 0) },
             "\(fx.receipts) or a folder above it is not a folder, or is not root's alone", SleepOffReceipts.initialContent, SleepOffReceipts.initialRelease),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: fx.installedBackstop)
            try fx.installMachinery()
            fx.clearCalls()
            try fx.writeState(cleanJournal)
            if FileManager.default.fileExists(atPath: fx.receipts) {
                chmod(fx.receipts, 0o755)
                try? FileManager.default.removeItem(atPath: fx.receipts)
            }
            try fx.writeReceipt()
            try c.prepare()
            let journal = try Data(contentsOf: fx.state)

            let r = try fx.run(fx.uninstall)
            unlink(headFails.path)

            try assertUninstallRemovedNothing(r, saying: c.saying, journal: journal, receipt: c.receipt, release: c.release)
            if c.name == "unreadable release file" { XCTAssertEqual(chmod(fx.released, 0o600), 0); XCTAssertEqual(fx.release(), SleepOffReceipts.initialRelease) }
            if c.name == "receipt folder someone else can change" {
                var info = stat()
                XCTAssertEqual(lstat(fx.receipts, &info), 0)
                XCTAssertEqual(info.st_mode & 0o7777, 0o775, "nothing about it is changed")
                XCTAssertEqual(chmod(fx.receipts, 0o755), 0)
            }
        }
    }

    /// A start of another folder claims the receipt while the uninstall
    /// waits for the receipt's lock, and lets the lock go: the claim is
    /// read under the lock, and the uninstall stops before removing
    /// anything.
    func testUninstallRemovesNothingWhenAClaimAppearsWhileItWaitsForTheReceiptLock() throws {
        try fx.installMachinery()
        try fx.writeState(cleanJournal)
        try fx.writeReceipt()
        let journal = try Data(contentsOf: fx.state)
        let other = UUID().uuidString
        try fx.claimTheReceiptBeforeItsLock(in: fx.uninstall, nonce: other)

        let r = try fx.run(fx.uninstall)

        try assertUninstallRemovedNothing(r, saying: "\(fx.released) shows that a start (\(other)) claims the receipt and is not settled yet", journal: journal, receipt: SleepOffReceipts.initialContent, release: "\(other) held\n")
    }

    /// A receipt replaced right after its lock (by root: here a copy with
    /// the same bytes and mode) is not the file the lock covers: the
    /// uninstall stops before removing anything.
    func testUninstallRemovesNothingWhenTheReceiptIsReplacedUnderItsLock() throws {
        try fx.installMachinery()
        try fx.writeState(cleanJournal)
        try fx.writeReceipt()
        let journal = try Data(contentsOf: fx.state)
        try fx.swapReceiptAfterItsLock(in: fx.uninstall)

        let r = try fx.run(fx.uninstall)

        try assertUninstallRemovedNothing(r, saying: "\(fx.receipt) was replaced while it was locked", journal: journal, receipt: SleepOffReceipts.initialContent, release: SleepOffReceipts.initialRelease)
    }

    /// Something that ignores the receipt's lock writes a claim into the
    /// release file after the check, while the agent is booted out. It is
    /// seen before the rule goes: the uninstall stops there, with the rule,
    /// the bundle, the receipt and the journal kept.
    func testUninstallStopsBeforeTheRuleWhenTheReleaseFileChangesAfterTheCheck() throws {
        try fx.installMachinery()
        try fx.writeState(cleanJournal)
        try fx.writeReceipt()
        let journal = try Data(contentsOf: fx.state)
        let other = UUID().uuidString
        try other.write(to: fx.root.appendingPathComponent("claim.nonce"), atomically: true, encoding: .utf8)
        fx.setMode("launchctl", "bootout-claims-receipt")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stdout + r.stderr)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped after removing the LaunchAgent: \(fx.released) changed after it was checked."), r.stderr)
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path), \(fx.app.path), the receipt and the journal were kept."), r.stderr)
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertEqual(try Data(contentsOf: fx.state), journal)
        XCTAssertEqual(fx.receiptText(), SleepOffReceipts.initialContent)
        XCTAssertEqual(fx.release(), "\(other) held\n")
        XCTAssertFalse(fx.calls().contains { Self.isRootRemoval($0) }, "\(fx.calls())")
    }

    /// The ordinary uninstall, with the receipt as install.sh made it, and
    /// with the line of another folder's start that is settled (its claim
    /// given back, "free" with its nonce): the receipt's lock is held from
    /// the check through the agent's bootout, the rule's removal and the
    /// receipt's own, and everything goes.
    func testUninstallHoldsTheReceiptLockFromTheCheckUntilTheSharedFilesAreGone() throws {
        let settled = UUID().uuidString
        for (name, line, release) in [("as made", SleepOffReceipts.initialContent, SleepOffReceipts.initialRelease),
                                      ("settled elsewhere", receiptLine(settled, "writing"), "\(settled) free\n")] {
            try? FileManager.default.removeItem(at: fx.installedBackstop)
            try? FileManager.default.removeItem(at: fx.root.appendingPathComponent("receipt-lock.log"))
            try fx.installMachinery()
            fx.clearCalls()
            try fx.writeState(cleanJournal)
            try fx.writeReceipt(line)
            try fx.writeRelease(release)

            let r = try fx.run(fx.uninstall)

            XCTAssertEqual(r.status, 0, "\(name): \(r.stderr + r.stdout)")
            XCTAssertTrue(r.stdout.contains("no start claims \(fx.receipt); it stays locked until the rule, the receipt and the bundle are gone"), "\(name): \(r.stdout)")
            XCTAssertEqual(fx.receiptLockStates(), [
                "launchctl bootout held",
                "sudo rm \(fx.sudoers.path) held",
                "sudo rm \(fx.receipt) held",
                "sudo rm \(fx.released) absent",
            ], name)
            XCTAssertFalse(fx.exists(fx.sudoers), name)
            XCTAssertFalse(fx.exists(fx.plist), name)
            XCTAssertFalse(fx.exists(fx.app), name)
            XCTAssertFalse(fx.exists(fx.state), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts), name)
        }
    }

    /// A receipt that fails its own checks (here writable by others) can
    /// be locked by nobody, and the app and the root command refuse it, so
    /// no start can claim it now. But a start may have claimed it before it
    /// failed them, and its settlement needs the rule and the bundle.
    /// Round 30 (finding 2): so the uninstall stops before removing
    /// anything, with or without a claim in its release file.
    func testUninstallRemovesNothingWhileTheReceiptFailsItsChecks() throws {
        for held in [false, true] {
            try? FileManager.default.removeItem(at: fx.installedBackstop)
            try fx.installMachinery()
            fx.clearCalls()
            try fx.writeState(cleanJournal)
            if FileManager.default.fileExists(atPath: fx.receipts) { try FileManager.default.removeItem(atPath: fx.receipts) }
            try fx.writeReceipt()
            let nonce = String(SleepOffReceipts.initialContent.prefix(36))
            if held { try fx.writeRelease("\(nonce) held\n") }
            XCTAssertEqual(chmod(fx.receipt, 0o666), 0)
            let journal = try Data(contentsOf: fx.state)

            let r = try fx.run(fx.uninstall)

            try assertUninstallRemovedNothing(r, saying: "\(fx.receipt) is missing, is not the 82-byte file install.sh made, mode 600, or someone other than root can change it or a folder above it", journal: journal, receipt: SleepOffReceipts.initialContent, release: held ? "\(nonce) held\n" : SleepOffReceipts.initialRelease)
            XCTAssertEqual(chmod(fx.receipt, 0o600), 0)
        }
    }

    /// F3 (round 28). The same for a receipt with a mode other than 600,
    /// another list of access control entries (stand-ins, as in the
    /// backstop's test) or a list ls cannot read: the checks refuse it, and
    /// since round 30 the uninstall stops before removing anything, with or
    /// without a claim.
    func testUninstallRemovesNothingWhileTheReceiptHasAnotherModeOrList() throws {
        let mine = [AccessEntry.installed(for: getuid())]
        let lists = Dictionary(uniqueKeysWithValues: TestReceipts.refusedLists.map { ($0.name, $0.entries) })
        let list = "\(fx.receipt) does not have exactly one access control entry, the one that lets uid \(fx.uid) read it and nothing else, or its list could not be read"
        let cases: [(name: String, mode: mode_t, entries: [AccessEntry], listFails: Bool, why: String)] = [
            ("mode 644", 0o644, mine, false, "\(fx.receipt) is missing, is not the 82-byte file install.sh made, mode 600, or someone other than root can change it or a folder above it"),
            ("no entry", 0o600, [], false, list),
            ("another account's entry", 0o600, try XCTUnwrap(lists["another account's entry"]), false, list),
            ("an inherited entry", 0o600, try XCTUnwrap(lists["an inherited entry"]), false, list),
            ("read and write", 0o600, try XCTUnwrap(lists["read and write"]), false, list),
            ("a list ls cannot read", 0o600, mine, true, list),
        ]
        let fails = fx.receiptEntries + ".fails"
        for c in cases {
            for held in [false, true] {
                let label = "\(c.name), \(held ? "a claim" : "no claim")"
                try? FileManager.default.removeItem(at: fx.installedBackstop)
                try fx.installMachinery()
                fx.clearCalls()
                try fx.writeState(cleanJournal)
                if FileManager.default.fileExists(atPath: fx.receipts) { try FileManager.default.removeItem(atPath: fx.receipts) }
                try fx.writeReceipt()
                let nonce = String(SleepOffReceipts.initialContent.prefix(36))
                if held { try fx.writeRelease("\(nonce) held\n") }
                XCTAssertEqual(chmod(fx.receipt, c.mode), 0, label)
                try fx.writeReceiptEntries(c.entries)
                if c.listFails { XCTAssertTrue(FileManager.default.createFile(atPath: fails, contents: nil)) }
                let journal = try Data(contentsOf: fx.state)

                let r = try fx.run(fx.uninstall)
                unlink(fails)

                XCTAssertTrue(r.stderr.contains(c.why), "\(label): \(r.stderr)")
                try assertUninstallRemovedNothing(r, saying: c.why, journal: journal, receipt: SleepOffReceipts.initialContent, release: held ? "\(nonce) held\n" : SleepOffReceipts.initialRelease)
            }
        }
    }

    // MARK: - install.sh and the receipt

    /// A new install makes the receipt folder and the receipt through sudo,
    /// by their fixed paths, modes 0755 and 0600, owner root, and the
    /// receipt holds a nonce no start has. Then it gives the receipt one
    /// access control entry, `user:<name> allow read`, through sudo chmod
    /// (the fake records it as the stand-in the fixture's ls shows). Then,
    /// under the receipt's lock, the release file beside it, the user's and
    /// 0600, with that nonce free. The app trusts what it made.
    func testInstallCreatesTheReceiptThroughSudoByItsFixedPath() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        let mkdir = try XCTUnwrap(calls.firstIndex(of: "sudo -n \(fx.bin.path)/mkdir -m 0755 \(fx.receipts)"), "\(calls)")
        let install = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo -n /usr/bin/install -m 0600 -o root -g wheel ") && $0.hasSuffix(" \(fx.receipt)") }, "\(calls)")
        let me = String(cString: getpwuid(getuid()).pointee.pw_name)
        let entry = try XCTUnwrap(calls.firstIndex(of: "sudo -n \(fx.bin.path)/chmod +a user:\(me) allow read \(fx.receipt)"), "\(calls)")
        let release = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo -n /usr/bin/install -m 0600 -o \(getuid()) ") && $0.hasSuffix(" \(fx.released)") }, "\(calls)")
        XCTAssertLessThan(mkdir, install)
        XCTAssertLessThan(install, entry)
        XCTAssertLessThan(entry, release)
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.bin.path)/chmod 0600") }, "install(1) made it 0600: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo REFUSED") }, "\(calls)")
        XCTAssertEqual(fx.receiptText(), SleepOffReceipts.initialContent)
        XCTAssertEqual(fx.release(), SleepOffReceipts.initialRelease)
        XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.receipts)), 0o755)
        XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.receipt)), 0o600)
        XCTAssertEqual(try String(contentsOfFile: fx.receiptEntries, encoding: .utf8), "user:\(me) allow read\n")
        XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.released)), 0o600)
        XCTAssertTrue(r.stdout.contains("receipt \(fx.receipt) is root's, only root can change it or the folders above it, and only root and \(me) can read it"), r.stdout)
        XCTAssertTrue(r.stdout.contains("release file \(fx.released) written: no start claims the receipt"), r.stdout)
        XCTAssertTrue(fx.toolCalls().contains("head -c 83"), "the receipt is read through HEAD: \(fx.toolCalls())")
        let receipts = fx.swiftReceipts
        XCTAssertNoThrow(try receipts.identity())
        XCTAssertEqual(try receipts.readRelease(), .free(SleepOffReceipts.zero))
    }

    /// A receipt already as install.sh makes it stays as it is, the same
    /// file with the same bytes: it may record a start that the recovery,
    /// or another Insomnia folder of this user, still has to settle. A
    /// claim in the release file stays too; a release file that is
    /// missing or shows another nonce free is written again, through sudo,
    /// with the receipt's nonce free.
    func testInstallKeepsAReceiptItMadeBefore() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        let nonce = UUID().uuidString
        let text = receiptLine(nonce, "writing")
        let cases: [(name: String, release: String?, after: String, says: String)] = [
            ("its own nonce free", "\(nonce) free\n", "\(nonce) free\n", "kept \(fx.released)\n"),
            ("a claim", "\(nonce) held\n", "\(nonce) held\n", "kept \(fx.released): a start of this user (\(nonce)) claims the receipt and is not settled yet"),
            ("another nonce free", "\(UUID().uuidString) free\n", "\(nonce) free\n", "release file \(fx.released) written: no start claims the receipt"),
            ("missing", nil, "\(nonce) free\n", "release file \(fx.released) written: no start claims the receipt"),
        ]
        for c in cases {
            fx.clearCalls()
            try fx.writeReceipt(text)
            if let release = c.release { try fx.writeRelease(release) } else { unlink(fx.released) }
            let identity = fx.receiptIdentity()

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 0, "\(c.name): \(r.stderr + r.stdout)")
            XCTAssertFalse(fx.calls().contains { $0.hasSuffix(" " + fx.receipt) && $0.hasPrefix("sudo ") }, "\(c.name): \(fx.calls())")
            XCTAssertEqual(fx.calls().contains { $0.hasSuffix(" " + fx.released) && $0.hasPrefix("sudo ") }, c.release == nil || c.name == "another nonce free", "\(c.name): \(fx.calls())")
            XCTAssertEqual(fx.receiptIdentity(), identity, c.name)
            XCTAssertEqual(fx.receiptText(), text, c.name)
            XCTAssertEqual(fx.release(), c.after, c.name)
            XCTAssertTrue(r.stdout.contains(c.says), "\(c.name): \(r.stdout)")
        }
    }

    /// F3 (round 28), F5 (round 30). A receipt an earlier build made (0644,
    /// no entry), or one an install left between `install` and `chmod +a`
    /// (0600, no entry), is repaired in place through sudo chmod while its
    /// release file shows no claim: the entry first, then the mode, and
    /// only the steps it needs. One this user can open is locked through
    /// both; one it cannot open (0600, no entry) is refused by every reader
    /// until it has the entry, and is not locked. It stays the same file
    /// with the same bytes. No release file is no claim, and the release
    /// step writes one. The entries are the fixture's stand-ins; no real
    /// list changes.
    func testInstallRepairsTheModeAndEntryOfAReceiptItMadeBefore() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        let me = String(cString: getpwuid(getuid()).pointee.pw_name)
        let mine = [AccessEntry.installed(for: getuid())]
        let mode = "sudo -n \(fx.bin.path)/chmod 0600 \(fx.receipt)"
        let entry = "sudo -n \(fx.bin.path)/chmod +a user:\(me) allow read \(fx.receipt)"
        let cases: [(name: String, mode: mode_t, entries: [AccessEntry], release: Bool, calls: [String], locks: [String])] = [
            ("an earlier build's: 0644, no entry", 0o644, [], true, [entry, mode], ["sudo chmod +a held", "sudo chmod 0600 held", "launchctl bootout free"]),
            ("an install stopped before chmod +a: 0600, no entry", 0o600, [], true, [entry], ["sudo chmod +a free", "launchctl bootout free"]),
            ("0644 with the entry", 0o644, mine, true, [mode], ["sudo chmod 0600 held", "launchctl bootout free"]),
            ("0400, no entry", 0o400, [], true, [entry, mode], ["sudo chmod +a held", "sudo chmod 0600 held", "launchctl bootout free"]),
            ("0644, no entry, no release file", 0o644, [], false, [entry, mode], ["sudo chmod +a held", "sudo chmod 0600 held", "launchctl bootout free"]),
        ]
        for c in cases {
            fx.clearCalls()
            try? FileManager.default.removeItem(at: fx.root.appendingPathComponent("receipt-lock.log"))
            let nonce = UUID().uuidString
            let text = receiptLine(nonce, "writing")
            try fx.writeReceipt(text)
            try fx.writeRelease("\(nonce) free\n")
            if !c.release { XCTAssertEqual(unlink(fx.released), 0, c.name) }
            XCTAssertEqual(chmod(fx.receipt, c.mode), 0, c.name)
            try fx.writeReceiptEntries(c.entries)
            let identity = fx.receiptIdentity()

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 0, "\(c.name): \(r.stderr + r.stdout)")
            XCTAssertEqual(fx.calls().filter { $0.hasPrefix("sudo -n \(fx.bin.path)/chmod ") }, c.calls, c.name)
            XCTAssertEqual(fx.receiptLockStates(), c.locks, c.name)
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo REFUSED") }, "\(c.name): \(fx.calls())")
            XCTAssertEqual(fx.receiptIdentity(), identity, "\(c.name): the same file")
            XCTAssertEqual(fx.receiptText(), text, c.name)
            XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.receipt)), 0o600, c.name)
            XCTAssertEqual(try String(contentsOfFile: fx.receiptEntries, encoding: .utf8), "user:\(me) allow read\n", c.name)
            XCTAssertEqual(fx.release(), "\(nonce) free\n", c.name)
            XCTAssertTrue(r.stdout.contains(c.release ? "kept \(fx.released)\n" : "release file \(fx.released) written: no start claims the receipt"), "\(c.name): \(r.stdout)")
            XCTAssertTrue(r.stdout.contains("only root and \(me) can read it"), "\(c.name): \(r.stdout)")
            XCTAssertNoThrow(try fx.swiftReceipts.identity(), c.name)
        }
    }

    /// F5 (round 30). A receipt that needs repair is not changed while its
    /// release file does not show that no start claims it: a claim, a
    /// release file head cannot read, one that is not a regular file, or
    /// one with other bytes. The install stops before any sudo chmod, and
    /// the receipt, its mode, its list and its release file stay as they
    /// were.
    func testInstallDoesNotRepairAReceiptAStartMayStillNeed() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        try wrapHead(in: fx.installRedirected, of: fx)
        let headFails = fx.root.appendingPathComponent("head.fail")
        let mine = [AccessEntry.installed(for: getuid())]
        let other = UUID().uuidString
        let releases: [(name: String, damage: () throws -> Void, why: String)] = [
            ("a claim", { try self.fx.writeRelease("\(other) held\n") },
             "\(fx.released) shows that a start (\(other)) claims the receipt and is not settled yet"),
            ("a release file head cannot read", {
                try self.fx.writeRelease("\(other) free\n")
                try "-c 43 \(self.fx.released)".write(to: headFails, atomically: true, encoding: .utf8)
            }, "\(fx.released) could not be read (head exit 3)"),
            ("a folder", { unlink(self.fx.released); XCTAssertEqual(mkdir(self.fx.released, 0o700), 0) }, "\(fx.released) is not a regular file"),
            ("other bytes", { try self.fx.writeRelease("short\n") },
             "\(fx.released) does not hold a nonce and free or held, so whether a start claims the receipt is unknown"),
        ]
        let receipts: [(name: String, mode: mode_t, entries: [AccessEntry])] = [
            ("0644, no entry", 0o644, []), ("0600, no entry", 0o600, []), ("0644 with the entry", 0o644, mine),
        ]
        for receipt in receipts {
            for release in releases where receipt.name != "0644 with the entry" || release.name == "a claim" {
                let name = "\(receipt.name), \(release.name)"
                fx.clearCalls()
                rmdir(fx.released)
                unlink(fx.released)
                let nonce = UUID().uuidString
                let text = receiptLine(nonce, "writing")
                try fx.writeReceipt(text)
                try release.damage()
                XCTAssertEqual(chmod(fx.receipt, receipt.mode), 0, name)
                try fx.writeReceiptEntries(receipt.entries)
                let identity = fx.receiptIdentity()
                let entries = try String(contentsOfFile: fx.receiptEntries, encoding: .utf8)
                let before = fx.release()

                let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
                unlink(headFails.path)

                XCTAssertEqual(r.status, 1, "\(name): \(r.stderr + r.stdout)")
                XCTAssertTrue(r.stderr.contains("Install stopped before changing \(fx.receipt): \(release.why).\nIts mode or access entry needs repair"), "\(name): \(r.stderr)")
                XCTAssertEqual(fx.calls().filter { $0.hasPrefix("sudo -n \(fx.bin.path)/chmod ") }, [], name)
                XCTAssertFalse(fx.calls().contains { $0.hasSuffix(" " + fx.released) && $0.hasPrefix("sudo ") }, "\(name): \(fx.calls())")
                XCTAssertEqual(fx.receiptIdentity(), identity, name)
                XCTAssertEqual(fx.receiptText(), text, name)
                XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.receipt)), Int(receipt.mode), name)
                XCTAssertEqual(try String(contentsOfFile: fx.receiptEntries, encoding: .utf8), entries, name)
                XCTAssertEqual(fx.release(), before, name)
            }
        }
        rmdir(fx.released)
    }

    /// F5 (round 30). A receipt this user can open is repaired only under
    /// its lock, and only while it is still the file it locked: one another
    /// process keeps locked, or one replaced once it is locked, stops the
    /// install before any sudo chmod.
    func testInstallRepairsAReceiptOnlyUnderItsLock() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        let nonce = UUID().uuidString
        let text = receiptLine(nonce, "writing")

        try fx.writeReceipt(text)
        try fx.writeRelease("\(nonce) free\n")
        XCTAssertEqual(chmod(fx.receipt, 0o644), 0)
        try fx.writeReceiptEntries([])
        let fd = open(fx.receipt, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        close(fd)
        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Install stopped: \(fx.receipt) stayed locked for 1 s (lockf exit"), r.stderr)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("sudo -n \(fx.bin.path)/chmod ") }, [])
        XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.receipt)), 0o644)
        XCTAssertEqual(try String(contentsOfFile: fx.receiptEntries, encoding: .utf8), "")

        fx.clearCalls()
        try fx.swapReceiptAfterItsLock(in: fx.installRedirected)
        let r2 = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        XCTAssertEqual(r2.status, 1, r2.stderr + r2.stdout)
        XCTAssertTrue(r2.stderr.contains("Install stopped: \(fx.receipt) was replaced while it was locked."), r2.stderr)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("sudo -n \(fx.bin.path)/chmod ") }, [])
        XCTAssertEqual(fx.receiptText(), text)
        XCTAssertEqual(try String(contentsOfFile: fx.receiptEntries, encoding: .utf8), "")
        XCTAssertEqual(fx.release(), "\(nonce) free\n")
    }

    /// F5 (round 30). A release file head cannot read in the release step
    /// stops the install there: it is not taken for one with no bytes and
    /// written again.
    func testInstallStopsWhenItCannotReadTheReleaseFile() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        try wrapHead(in: fx.installRedirected, of: fx)
        let nonce = UUID().uuidString
        try fx.writeReceipt(receiptLine(nonce, "refused"))
        try fx.writeRelease("\(UUID().uuidString) free\n")
        let before = fx.release()
        try "-c 43 \(fx.released)".write(to: fx.root.appendingPathComponent("head.fail"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Install stopped: \(fx.released) could not be read (head exit 3)."), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasSuffix(" " + fx.released) && $0.hasPrefix("sudo ") }, "\(fx.calls())")
        XCTAssertEqual(fx.release(), before)
    }

    /// F3 (round 28). A receipt with any other entry (stand-ins), a list
    /// ls cannot read, or a mode that lets someone other than root change
    /// it is not repaired: the install stops before its lock is taken,
    /// with no sudo chmod, and the receipt, its mode, its list and its
    /// release file stay as they were. So does a sudo chmod that fails,
    /// and an account name chmod +a could not take.
    func testInstallStopsAtAReceiptItCannotRepair() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        let me = String(cString: getpwuid(getuid()).pointee.pw_name)
        let mine = [AccessEntry.installed(for: getuid())]
        let lists = Dictionary(uniqueKeysWithValues: TestReceipts.refusedLists.map { ($0.name, $0.entries) })
        let list = "Install stopped: \(fx.receipt) does not have exactly one access control entry, the one that lets \(me) (uid \(fx.uid)) read it and nothing else, or its list could not be read."
        let fails = fx.receiptEntries + ".fails"
        var cases: [(name: String, mode: mode_t, entries: [AccessEntry], listFails: Bool, chmodFails: Bool, says: String)] = [
            "another account's entry", "a group's entry", "an inherited entry", "a deny entry", "read and write", "read and writesecurity", "read and chown", "the entry twice",
        ].map { (String($0), 0o600, lists[String($0)] ?? [], false, false, list) }
        cases += [
            ("an earlier build's mode with another entry", 0o644, lists["read and write"] ?? [], false, false, "Install stopped: \(fx.receipt) has mode 644, not 600."),
            ("a list ls cannot read", 0o600, [], true, false, list),
            ("writable by others", 0o646, [], false, false, "Install stopped: \(fx.receipt) is not a regular file of root's with one link and 82 bytes that only root can change."),
            ("sudo chmod fails", 0o644, [], false, true, "Install stopped: 'sudo chmod +a \"user:\(me) allow read\" \(fx.receipt)' exited 1"),
        ]
        for c in cases {
            fx.clearCalls()
            let nonce = UUID().uuidString
            let text = receiptLine(nonce, "writing")
            // A claim stops a repair before any chmod (F5), so the case
            // whose chmod fails has a release file that shows none.
            let release = c.chmodFails ? "\(nonce) free\n" : "\(nonce) held\n"
            try fx.writeReceipt(text)
            try fx.writeRelease(release)
            XCTAssertEqual(chmod(fx.receipt, c.mode), 0, c.name)
            try fx.writeReceiptEntries(c.entries)
            if c.listFails { XCTAssertTrue(FileManager.default.createFile(atPath: fails, contents: nil)) }
            if c.chmodFails { XCTAssertTrue(FileManager.default.createFile(atPath: fx.root.appendingPathComponent("sudo-chmod.fail").path, contents: nil)) }
            let identity = fx.receiptIdentity()
            let entries = try String(contentsOfFile: fx.receiptEntries, encoding: .utf8)

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
            unlink(fails)
            unlink(fx.root.appendingPathComponent("sudo-chmod.fail").path)

            XCTAssertEqual(r.status, 1, "\(c.name): \(r.stderr + r.stdout)")
            XCTAssertTrue(r.stderr.contains(c.says), "\(c.name): \(r.stderr)")
            XCTAssertEqual(fx.calls().filter { $0.hasPrefix("sudo -n \(fx.bin.path)/chmod ") }, c.chmodFails ? ["sudo -n \(fx.bin.path)/chmod +a user:\(me) allow read \(fx.receipt)"] : [], c.name)
            XCTAssertFalse(fx.calls().contains { $0.hasSuffix(" " + fx.released) && $0.hasPrefix("sudo ") }, "\(c.name): \(fx.calls())")
            XCTAssertEqual(fx.receiptIdentity(), identity, c.name)
            XCTAssertEqual(fx.receiptText(), text, c.name)
            XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.receipt)), Int(c.mode), c.name)
            XCTAssertEqual(try String(contentsOfFile: fx.receiptEntries, encoding: .utf8), entries, c.name)
            XCTAssertEqual(fx.release(), release, c.name)
            XCTAssertEqual(chmod(fx.receipt, 0o600), 0)
            try fx.writeReceiptEntries(mine)
        }

        // An account name with a space, which chmod +a would split, stops
        // the install before the receipt is touched (a fake id answers -un).
        let id = fx.bin.appendingPathComponent("id-two-words")
        try "#!/bin/bash\nif [[ \"$*\" == -un ]]; then echo 'two words'; exit 0; fi\nexec /usr/bin/id \"$@\"\n".write(to: id, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(id.path, 0o755), 0)
        try fx.writeInstallCopies(extraConstants: ["ID": id.path])
        fx.clearCalls()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Install stopped: the account name of uid \(fx.uid) (two words) is empty, holds a space or a colon, or is not this uid's, so the receipt cannot be given an entry for it."), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n \(fx.bin.path)/chmod ") }, "\(fx.calls())")
    }

    /// F2 for install.sh: the release file is written only under the
    /// receipt's lock. A receipt that stays locked stops the install
    /// before the bundle is touched, with the release file as it was.
    func testInstallStopsWhileTheReceiptIsLocked() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        try fx.writeReceipt()
        try fx.writeRelease("\(UUID().uuidString) free\n")
        let before = fx.release()
        let fd = open(fx.receipt, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stdout)
        XCTAssertTrue(r.stderr.contains("Install stopped: \(fx.receipt) stayed locked for 1 s"), r.stderr)
        XCTAssertEqual(fx.release(), before)
        XCTAssertFalse(fx.exists(fx.app.appendingPathComponent("Contents/MacOS/Insomnia")), "the bundle is not installed")
    }

    /// A receipt, its release file or the folder that is not as install.sh
    /// makes it stops the install before the bundle is touched. Its owner
    /// and mode are never changed, and nothing is written through a link.
    func testInstallStopsAtAReceiptOrFolderItDidNotMakeAndChangesNothingAboutIt() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        let elsewhere = fx.root.appendingPathComponent("elsewhere", isDirectory: true).path
        let cases: [(name: String, damage: () throws -> Void, repair: () throws -> Void)] = [
            ("a group-writable receipt", { try self.fx.writeReceipt(); XCTAssertEqual(chmod(self.fx.receipt, 0o664), 0) }, { unlink(self.fx.receipt) }),
            ("a receipt of 83 bytes", { try self.fx.writeReceipt(SleepOffReceipts.initialContent + "\n") }, { unlink(self.fx.receipt) }),
            ("a receipt with two links", { try self.fx.writeReceipt(); XCTAssertEqual(link(self.fx.receipt, self.fx.root.path + "/second"), 0) },
             { unlink(self.fx.receipt); unlink(self.fx.root.path + "/second") }),
            ("a link at the receipt", {
                XCTAssertEqual(mkdir(self.fx.receipts, 0o755), 0)
                XCTAssertEqual(symlink(self.fx.root.path + "/target", self.fx.receipt), 0)
            }, { unlink(self.fx.receipt) }),
            ("a link at the release file", {
                try self.fx.writeReceipt()
                XCTAssertEqual(unlink(self.fx.released), 0)
                XCTAssertEqual(symlink(self.fx.root.path + "/target", self.fx.released), 0)
            }, { unlink(self.fx.released) }),
            ("a writable folder", { try self.fx.writeReceipt(); XCTAssertEqual(chmod(self.fx.receipts, 0o777), 0) }, { chmod(self.fx.receipts, 0o755); unlink(self.fx.receipt) }),
            ("a link at the folder", {
                XCTAssertEqual(mkdir(elsewhere, 0o755), 0)
                XCTAssertEqual(symlink(elsewhere, self.fx.receipts), 0)
            }, { unlink(self.fx.receipts) }),
        ]
        // The folder itself (a link at it as the link) and, through it,
        // everything in it, with modes, owners, links and ACLs.
        func receiptListing() throws -> String {
            try fx.runTool("/bin/ls", ["-lde", fx.receipts]).output + fx.runTool("/bin/ls", ["-leAR", fx.receipts + "/"]).output
        }
        for c in cases {
            try? FileManager.default.removeItem(atPath: fx.receipts)
            fx.clearCalls()
            try c.damage()
            let listing = try receiptListing()

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 1, "\(c.name): \(r.stderr + r.stdout)")
            XCTAssertTrue(r.stderr.contains("Install stopped: "), "\(c.name): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("Insomnia does not change\nthe owner or mode of anything it did not make"), "\(c.name): \(r.stderr)")
            XCTAssertFalse(fx.exists(fx.app.appendingPathComponent("Contents/MacOS/Insomnia")), "\(c.name): the bundle is not installed")
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n /usr/bin/install") && $0.contains(fx.receipts) }, "\(c.name): \(fx.calls())")
            XCTAssertFalse(fx.chmodCalls().contains { $0.contains(fx.receipts) }, "\(c.name): \(fx.chmodCalls())")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fx.root.path + "/target"), "\(c.name): nothing is written through the link")
            XCTAssertEqual(try receiptListing(), listing, "\(c.name): nothing about it changed")
            try c.repair()
        }
    }

    /// R25-3: a claim the release file shows is kept even when install.sh
    /// has just made the receipt (one of another Insomnia folder of this
    /// user that is not settled yet, whatever happened to the receipt).
    /// The receipt is made as ever; the claim is not replaced.
    func testInstallKeepsAClaimRightAfterItMakesTheReceipt() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        let other = UUID().uuidString
        XCTAssertEqual(mkdir(fx.receipts, 0o755), 0)
        try fx.writeRelease("\(other) held\n")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(fx.receiptText(), SleepOffReceipts.initialContent)
        XCTAssertEqual(fx.release(), "\(other) held\n")
        XCTAssertTrue(r.stdout.contains("kept \(fx.released): a start of this user (\(other)) claims the receipt and is not settled yet"), r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo ") && $0.hasSuffix(" " + fx.released) }, "\(fx.calls())")
    }

    /// R25-3: the release file is read only once the receipt's lock is
    /// held. Here a start (of another Insomnia folder) claims the receipt
    /// and writes its line while install.sh waits for the lock, for a
    /// receipt install.sh made just now and for one it made before, with
    /// the release file showing another nonce free beforehand. The claim
    /// and the line stay.
    func testInstallKeepsAClaimTakenWhileItWaitedForTheReceiptsLock() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        for made in [true, false] {
            try? FileManager.default.removeItem(atPath: fx.receipts)
            fx.clearCalls()
            let other = UUID().uuidString
            let line = receiptLine(other, "writing")
            if made {
                XCTAssertEqual(mkdir(fx.receipts, 0o755), 0)
            } else {
                try fx.writeReceipt()
            }
            try fx.writeRelease("\(UUID().uuidString) free\n")
            let wrapper = fx.bin.appendingPathComponent("lockf-claim")
            try """
            #!/bin/bash
            if [[ "${!#}" == 7 ]]; then
              printf '%s' '\(line)' 1<> '\(fx.receipt)'
              printf '%s held\\n' '\(other)' 1<> '\(fx.released)'
            fi
            exec /usr/bin/lockf "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
            XCTAssertEqual(chmod(wrapper.path, 0o755), 0)
            let text = try String(contentsOf: fx.installRedirected, encoding: .utf8)
            try ScriptFixture.patch(text, ["LOCKF": wrapper.path]).write(to: fx.installRedirected, atomically: true, encoding: .utf8)

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 0, "made \(made): \(r.stderr + r.stdout)")
            XCTAssertEqual(fx.receiptText(), line, "made \(made)")
            XCTAssertEqual(fx.release(), "\(other) held\n", "made \(made)")
            XCTAssertTrue(r.stdout.contains("kept \(fx.released): a start of this user (\(other)) claims the receipt and is not settled yet"), "made \(made): \(r.stdout)")
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo ") && $0.hasSuffix(" " + fx.released) }, "made \(made): \(fx.calls())")
        }
    }

    /// R25-3: a release file is written again only when it shows no claim
    /// the app would honour, and only by install(1)'s rename, from bytes
    /// read under the receipt's lock. A claim in a file that is not this
    /// user's 0600 file with one link stops the install rather than be
    /// replaced. A file with no claim in it (malformed, or the receipt's
    /// own nonce free with a mode the app does not make) is written again,
    /// the user's and 0600. A release file that changes between that read
    /// and the write stops the install, with its bytes as they are.
    func testInstallRepairsAReleaseFileOnlyWhenItHoldsNoClaim() throws {
        let other = UUID().uuidString
        let nonce = UUID().uuidString
        let cases: [(name: String, damage: () throws -> Void, cleanup: () -> Void, stops: String?)] = [
            ("a claim readable by others", { try self.fx.writeRelease("\(other) held\n"); XCTAssertEqual(chmod(self.fx.released, 0o644), 0) }, {},
             "\(fx.released) claims the receipt for a start (\(other)), but is not this user's 0600 file with one link, so it is not replaced"),
            ("a claim with two links", { try self.fx.writeRelease("\(other) held\n"); XCTAssertEqual(link(self.fx.released, self.fx.root.path + "/second"), 0) },
             { unlink(self.fx.root.path + "/second") }, "\(fx.released) claims the receipt for a start (\(other)), but is not this user's 0600 file with one link, so it is not replaced"),
            ("a claim written after it was read", {
                try self.fx.writeRelease("\(UUID().uuidString) free\n")
                let wrapper = self.fx.bin.appendingPathComponent("head-claim")
                try """
                #!/bin/bash
                '\(self.fx.bin.appendingPathComponent("head").path)' "$@"; rc=$?
                if [[ "$*" == '-c 43 \(self.fx.released)' && ! -e '\(self.fx.root.path)/claimed' ]]; then
                  : > '\(self.fx.root.path)/claimed'
                  printf '%s held\\n' '\(other)' 1<> '\(self.fx.released)'
                fi
                exit $rc
                """.write(to: wrapper, atomically: true, encoding: .utf8)
                XCTAssertEqual(chmod(wrapper.path, 0o755), 0)
                let text = try String(contentsOf: self.fx.installRedirected, encoding: .utf8)
                try ScriptFixture.patch(text, ["HEAD": wrapper.path]).write(to: self.fx.installRedirected, atomically: true, encoding: .utf8)
            }, {
                unlink(self.fx.root.path + "/claimed")
                if let text = try? String(contentsOf: self.fx.installRedirected, encoding: .utf8),
                   let restored = try? ScriptFixture.patch(text, ["HEAD": self.fx.bin.appendingPathComponent("head").path]) {
                    try? restored.write(to: self.fx.installRedirected, atomically: true, encoding: .utf8)
                }
            }, "\(fx.released) changed while the receipt was locked"),
            ("six bytes", { try self.fx.writeRelease("short\n") }, {}, nil),
            ("a lower-case nonce", { try self.fx.writeRelease("\(other.lowercased()) held\n") }, {}, nil),
            ("a claim with a byte more", { try self.fx.writeRelease("\(other) held\n\n") }, {}, nil),
            ("its own nonce free, readable by others", { try self.fx.writeRelease("\(nonce) free\n"); XCTAssertEqual(chmod(self.fx.released, 0o644), 0) }, {}, nil),
        ]
        // Every case that stops comes before the first that installs, so
        // none of them finds a bundle installed.
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        for c in cases {
            try? FileManager.default.removeItem(atPath: fx.receipts)
            fx.clearCalls()
            try fx.writeReceipt(receiptLine(nonce, "refused"))
            try c.damage()
            defer { c.cleanup() }
            let before = fx.release()
            let mode = try fx.mode(URL(fileURLWithPath: fx.released))

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(fx.receiptText(), receiptLine(nonce, "refused"), c.name)
            if let stops = c.stops {
                XCTAssertEqual(r.status, 1, "\(c.name): \(r.stdout)")
                XCTAssertTrue(r.stderr.contains("Install stopped: "), "\(c.name): \(r.stderr)")
                XCTAssertTrue(r.stderr.contains(stops), "\(c.name): \(r.stderr)")
                XCTAssertFalse(fx.exists(fx.app.appendingPathComponent("Contents/MacOS/Insomnia")), "\(c.name): the bundle is not installed")
                XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo ") && $0.hasSuffix(" " + fx.released) }, "\(c.name): \(fx.calls())")
                XCTAssertEqual(fx.release(), c.name == "a claim written after it was read" ? "\(other) held\n" : before, c.name)
                XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.released)), mode, c.name)
            } else {
                XCTAssertEqual(r.status, 0, "\(c.name): \(r.stderr + r.stdout)")
                XCTAssertTrue(fx.calls().contains { $0.hasPrefix("sudo -n /usr/bin/install -m 0600 -o \(getuid()) ") && $0.hasSuffix(" " + fx.released) }, "\(c.name): \(fx.calls())")
                XCTAssertEqual(fx.release(), "\(nonce) free\n", c.name)
                XCTAssertEqual(try fx.mode(URL(fileURLWithPath: fx.released)), 0o600, c.name)
                XCTAssertTrue(r.stdout.contains("release file \(fx.released) written: no start claims the receipt"), "\(c.name): \(r.stdout)")
            }
        }
    }

    // MARK: - uninstall.sh

    /// uninstall.sh deletes the marker itself, before the backstop it runs,
    /// which may be an older copy that does not know the file.
    func testUninstallDeletesTheMarkerBeforeRunningTheBackstop() throws {
        try fx.installMachinery()
        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)
        try """
        #!/bin/bash
        if [[ -e "\(fx.pendingStart.path)" ]]; then echo present; else echo absent; fi > "\(fx.root.path)/marker-at-backstop"
        exit 0
        """.write(to: fx.backstop, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try String(contentsOf: fx.root.appendingPathComponent("marker-at-backstop"), encoding: .utf8), "absent\n")
        XCTAssertFalse(fx.exists(fx.pendingStart))
        XCTAssertFalse(fx.exists(fx.sudoers))
    }

    /// The root command behind an abandoned dialog holds the marker's lock:
    /// uninstall does not delete it under that command and removes nothing.
    func testUninstallAbortsWhileTheMarkerIsLocked() throws {
        try fx.installMachinery()
        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)
        let holder = try FileLockHolder(fx.pendingStart)
        defer { holder.release() }

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0, r.stdout)
        XCTAssertTrue((r.stderr + r.stdout).contains("pending-start is still present"), r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(fx.pendingStart))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.plist))
    }

    /// A marker that cannot be deleted keeps everything, the sudoers rule
    /// included: the dialog it belongs to could still turn sleep off.
    func testUninstallAbortsWhenTheMarkerCannotBeDeleted() throws {
        try fx.installMachinery()
        try FileManager.default.createDirectory(at: fx.pendingStart, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: fx.pendingStart.appendingPathComponent("keep"))

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0, r.stdout)
        XCTAssertTrue((r.stderr + r.stdout).contains("pending-start is still present"), r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.app))
    }

    /// A file put in the marker's place after the backstop opened and
    /// locked it is not covered by that lock, so it is not deleted: sleep
    /// is restored, the entry stays, the run exits 1 and says why. The next
    /// run locks the file that is there and deletes it.
    func testBackstopLeavesAMarkerReplacedAfterItWasLocked() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)
        let plain = try String(contentsOf: fx.backstop, encoding: .utf8)
        try fx.swapMarkerAfterItsLock(in: fx.backstop)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "sleep itself is still restored")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: fx.pendingStart, encoding: .utf8), "copy", "the copy is not deleted")
        XCTAssertTrue(fx.log().contains("pending-start was replaced after it was opened, so its lock does not cover the file now at that path"), fx.log())

        try plain.write(to: fx.backstop, atomically: true, encoding: .utf8)
        let again = try fx.run(fx.backstop)
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertFalse(fx.exists(fx.pendingStart))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    /// uninstall.sh checks the same way, and the marker it leaves stops it.
    func testUninstallLeavesAMarkerReplacedAfterItWasLocked() throws {
        try fx.installMachinery()
        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)
        // A stub backstop, so only uninstall.sh's own deletion acts.
        try "#!/bin/bash\nexit 0\n".write(to: fx.backstop, atomically: true, encoding: .utf8)
        try fx.swapMarkerAfterItsLock(in: fx.uninstall)

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0, r.stdout)
        XCTAssertTrue((r.stderr + r.stdout).contains("pending-start is still present"), r.stderr + r.stdout)
        XCTAssertEqual(try String(contentsOf: fx.pendingStart, encoding: .utf8), "copy", "the copy is not deleted")
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
    }

    /// A FIFO in the marker's place is never opened (open(2) would block
    /// under the recovery lock): it is reported and left, and the entry
    /// stays.
    func testBackstopDoesNotOpenAFIFOAtTheMarker() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let watch = try FIFOWatch(at: fx.pendingStart)
        defer { watch.stop() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertFalse(watch.readerSeen, "the FIFO was opened")
        XCTAssertTrue(watch.isStillFIFO)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(fx.log().contains("pending-start is not a regular file, so it was not opened"), fx.log())
    }

    /// Both scripts delete the marker through RM=/bin/rm, never an rm found
    /// on PATH: one first on PATH that leaves the marker in place changes
    /// nothing, for a plain marker (deleted under lockf) and for a link to
    /// nothing (deleted after lockf finds nothing to open).
    func testScriptsDeleteTheMarkerWithoutPATH() throws {
        let shadow = fx.root.appendingPathComponent("shadow", isDirectory: true)
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
        let shadowRm = shadow.appendingPathComponent("rm")
        try """
        #!/bin/bash
        for a in "$@"; do [[ "$a" == "\(fx.pendingStart.path)" ]] && exit 0; done
        exec /bin/rm "$@"
        """.write(to: shadowRm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shadowRm.path)
        let path = ["PATH": "\(shadow.path):/usr/bin:/bin:/usr/sbin:/sbin"]

        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)
        var r = try fx.run(fx.backstop, extraEnvironment: path)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(fx.exists(fx.pendingStart))

        try FileManager.default.createSymbolicLink(
            atPath: fx.pendingStart.path, withDestinationPath: fx.root.appendingPathComponent("nowhere").path)
        r = try fx.run(fx.backstop, extraEnvironment: path)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: fx.pendingStart.path), "the link must be gone")

        // A stub backstop, so only uninstall.sh's own deletion can remove it.
        try fx.installMachinery()
        try Data(UUID().uuidString.utf8).write(to: fx.pendingStart)
        try "#!/bin/bash\nexit 0\n".write(to: fx.backstop, atomically: true, encoding: .utf8)
        r = try fx.run(fx.uninstall, extraEnvironment: path)
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.exists(fx.pendingStart))
    }

    func testUninstallAbortsWhenRestoreFailsAndKeepsEverything() throws {
        try fx.installMachinery()
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.plist), "LaunchAgent must keep retrying")
        XCTAssertTrue(fx.exists(fx.sudoers), "the pmset grant is still needed")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.session), "evidence is not deleted up front")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { Self.isRootRemoval($0) }, "\(calls)")
        XCTAssertTrue(r.stderr.contains("BEFORE removing anything"), r.stderr)
        XCTAssertTrue(r.stderr.contains("sleepDisabledByUs is still true"), r.stderr)
        XCTAssertTrue(r.stderr.contains(fx.sudoers.path), r.stderr)
    }

    func testUninstallAbortsOnSavedAudioAndExplainsReopeningTheApp() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":0.25,"savedMuted":true}"#)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.home), "--purge must not run before recovery is verified")
        XCTAssertEqual(try fx.stateJSON()["savedOutputVolume"] as? Double, 0.25)
        XCTAssertTrue(r.stderr.contains("saved audio"), r.stderr)
        XCTAssertTrue(r.stderr.contains("open Insomnia.app"), r.stderr)
    }

    /// A brightness the app kept after a refused restore does not stop the
    /// uninstall, since nothing can restore it on this macOS, but
    /// state.json stays, even with --purge, so a later Insomnia that can
    /// make the call restores it. The output names the level to set.
    func testUninstallCompletesPastARefusedBrightnessAndKeepsTheJournal() throws {
        for purge in [false, true] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6,"displayRestoreRefused":true}"#)

            let r = try f.run(f.uninstall, purge ? ["--purge"] : [])

            XCTAssertEqual(r.status, 0, "purge \(purge): " + r.stderr + r.stdout)
            XCTAssertFalse(f.exists(f.plist), "purge \(purge)")
            XCTAssertFalse(f.exists(f.app), "purge \(purge)")
            XCTAssertTrue(f.exists(f.state), "purge \(purge)")
            XCTAssertEqual(try f.stateJSON()["savedDisplayBrightness"] as? Double, 0.6)
            XCTAssertEqual(try f.stateJSON()["displayRestoreRefused"] as? Bool, true)
            XCTAssertEqual(f.exists(f.config), !purge, "purge \(purge)")
            XCTAssertTrue(r.stdout.contains("  - display brightness 0.6"), r.stdout)
            XCTAssertTrue(r.stdout.contains("Set the level with the brightness keys or Control Center"), r.stdout)
            XCTAssertTrue(r.stdout.contains("Kept \(f.state.path): it holds the brightness listed above."), r.stdout)
        }
    }
    /// The backstop leaves an output device entry alone and exits 0, but
    /// removing Insomnia would leave that device muted for good: uninstall
    /// names the device and says how to get it back or let it go.
    func testUninstallAbortsOnAnOutputDeviceStillMutedAndNamesIt() throws {
        try fx.installMachinery()
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","name":"USB Headset","volume":0.3,"muted":false},{"deviceUID":"70-8C-F2:output","volume":0.5,"muted":false}]}"#
        try fx.writeState(json)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.home), "--purge must not run before recovery is verified")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), json)
        XCTAssertTrue(r.stderr.contains("USB Headset is still muted from a lid close"), r.stderr)
        XCTAssertTrue(r.stderr.contains("70-8C-F2:output is still muted from a lid close"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Stop waiting for <device>"), r.stderr)
    }
    func testUninstallAbortsOnSavedDisplayBrightnessAndExplainsReopeningTheApp() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6}"#)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.home), "--purge must not run before recovery is verified")
        XCTAssertEqual(try fx.stateJSON()["savedDisplayBrightness"] as? Double, 0.6)
        XCTAssertTrue(r.stderr.contains("display brightness"), r.stderr)
        XCTAssertTrue(r.stderr.contains("open Insomnia.app"), r.stderr)
    }

    /// Uninstall's own journal check sees App Nap entries the backstop
    /// could not put back, and stops before removing anything.
    func testUninstallAbortsOnAppNapEntriesWhenDefaultsFails() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":"com.google.Chrome","previous":false}]}"#)
        try fx.defaultsTable([("com.google.Chrome", "1")])
        fx.setMode("defaults", "fail")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.calls().contains("defaults write com.google.Chrome NSAppSleepDisabled -bool false"), "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.config), "--purge must not run before recovery is verified")
        XCTAssertEqual((try fx.stateJSON()["appNapOverrides"] as? [Any])?.count, 1)
        XCTAssertTrue(r.stderr.contains("App Nap settings (NSAppSleepDisabled) are not put back"), r.stderr)
        XCTAssertTrue(r.stderr.contains("com.google.Chrome"), r.stderr)
        XCTAssertTrue(r.stderr.contains("defaults write"), r.stderr)
    }

    /// The same with the key recorded as absent: a delete and a read that
    /// both fail leave the entry, and uninstall stops with it on screen
    /// instead of treating the key as gone.
    func testUninstallAbortsWhenDeleteAndReadBothFail() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":"com.google.Chrome"}]}"#)
        try fx.defaultsTable([("com.google.Chrome", "1")])
        fx.setMode("defaults", "unreachable")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("defaults") }, [
            "defaults delete com.google.Chrome NSAppSleepDisabled",
            "defaults read com.google.Chrome NSAppSleepDisabled",
        ], "the legacy listing never runs while the journal is dirty")
        XCTAssertEqual(fx.defaultsValues(), ["com.google.Chrome": "1"])
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.config))
        XCTAssertEqual((try fx.stateJSON()["appNapOverrides"] as? [Any])?.count, 1)
        XCTAssertTrue(r.stderr.contains("App Nap settings (NSAppSleepDisabled) are not put back"), r.stderr)
        XCTAssertTrue(r.stderr.contains("com.google.Chrome"), r.stderr)
    }

    /// Even an older backstop that exits 0 without touching the entries
    /// cannot get App Nap entries past uninstall's own check.
    func testUninstallRejectsAppNapEntriesEvenWhenBackstopExitsZero() throws {
        try fx.installMachinery()
        try "#!/bin/bash\nexit 0\n".write(to: fx.backstop, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":"com.google.Chrome"}]}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.state))
        XCTAssertTrue(r.stderr.contains("App Nap settings (NSAppSleepDisabled) are not put back"), r.stderr)
    }

    /// The normal path: the backstop puts the entries back under
    /// uninstall's lock, the check passes, and everything is removed.
    func testUninstallRestoresAppNapViaBackstopThenRemoves() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[{"bundleId":"com.google.Chrome"},{"bundleId":"com.apple.Terminal","previous":false}]}"#)
        try fx.defaultsTable([("com.google.Chrome", "1"), ("com.apple.Terminal", "1")])

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("defaults delete com.google.Chrome NSAppSleepDisabled"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("defaults write com.apple.Terminal NSAppSleepDisabled -bool false"), "\(fx.calls())")
        XCTAssertEqual(fx.defaultsValues(), ["com.apple.Terminal": "0"])
        XCTAssertFalse(fx.exists(fx.state))
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// Values an older build wrote without recording the previous one are
    /// not guessed at: uninstall names each agent app whose key is YES with
    /// no journal entry, prints the exact command to undo it, and goes on.
    func testUninstallListsUnrecordedAppNapAndContinues() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"appNapOverrides":[]}"#)
        try fx.writeConfig(#"{"agentList":["com.google.Chrome","com.apple.Terminal","dev.zed.Zed","com.todesktop.230313mzl4w4u92"]}"#)
        try fx.defaultsTable([("com.google.Chrome", "1"), ("com.apple.Terminal", "0"), ("com.todesktop.230313mzl4w4u92", "1")])

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let defaultsCalls = fx.calls().filter { $0.hasPrefix("defaults") }
        XCTAssertTrue(defaultsCalls.allSatisfy { $0.hasPrefix("defaults read ") }, "read only: nothing is written or deleted without a record: \(defaultsCalls)")
        for id in ["com.google.Chrome", "com.apple.Terminal", "dev.zed.Zed", "com.todesktop.230313mzl4w4u92"] {
            XCTAssertEqual(defaultsCalls.filter { $0 == "defaults read \(id) NSAppSleepDisabled" }.count, 1, "\(id) is read once: \(defaultsCalls)")
        }
        XCTAssertEqual(fx.defaultsValues(), ["com.google.Chrome": "1", "com.apple.Terminal": "0", "com.todesktop.230313mzl4w4u92": "1"], "left as they were")
        XCTAssertTrue(r.stdout.contains("no record of"), r.stdout)
        XCTAssertTrue(r.stdout.contains("  defaults delete com.google.Chrome NSAppSleepDisabled\n"), r.stdout)
        XCTAssertTrue(r.stdout.contains("  defaults delete com.todesktop.230313mzl4w4u92 NSAppSleepDisabled\n"), r.stdout)
        XCTAssertFalse(r.stdout.contains("defaults delete com.apple.Terminal"), "a key that is 0 is not App Nap off: \(r.stdout)")
        XCTAssertFalse(r.stdout.contains("defaults delete dev.zed.Zed"), "an absent key is nothing to undo: \(r.stdout)")
        XCTAssertFalse(fx.exists(fx.config), "the listing runs before --purge removes config.json")
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// Nothing to list: the check still runs, reads the shipped list plus
    /// config.json's (each once), and says how many it checked rather than
    /// claiming nothing is left anywhere.
    func testUninstallReportsNoUnrecordedAppNapWhenNoneIsSet() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeConfig(#"{"agentList":["com.google.Chrome","com.example.extra"]}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let expected = (Config.defaultAgentList + ["com.example.extra"]).map { "defaults read \($0) NSAppSleepDisabled" }
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("defaults") }, expected)
        XCTAssertTrue(r.stdout.contains("Checking App Nap settings of agent apps"), r.stdout)
        XCTAssertTrue(r.stdout.contains("none of the \(expected.count) agent apps checked has NSAppSleepDisabled set"), r.stdout)
        XCTAssertFalse(r.stdout.contains("defaults delete"), r.stdout)
    }

    /// An app the user took off the list may still carry a value an older
    /// build set. The shipped list is checked as well, so it is listed.
    func testUninstallListsUnrecordedAppNapForAgentsRemovedFromTheList() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeConfig(#"{"agentList":["com.apple.Terminal"]}"#)
        try fx.defaultsTable([("com.google.Chrome", "1")])

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("  defaults delete com.google.Chrome NSAppSleepDisabled\n"), r.stdout)
        XCTAssertFalse(r.stdout.contains("none of the"), r.stdout)
        XCTAssertEqual(fx.defaultsValues(), ["com.google.Chrome": "1"], "listed, not changed")
        XCTAssertFalse(fx.exists(fx.config))
    }

    /// The list editor takes any string, so the printed command is
    /// shell-quoted; an id a `defaults read` cannot settle is reported
    /// rather than counted as clear.
    func testUninstallQuotesPrintedCommandsAndReportsUnreadableIds() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeConfig(#"{"agentList":["com.example.My App","com.example.Broken"]}"#)
        try fx.defaultsTable([("com.example.My App", "1")])
        fx.setMode("defaults", "unreachable:com.example.Broken")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("  defaults delete com.example.My\\ App NSAppSleepDisabled\n"), r.stdout)
        XCTAssertTrue(r.stdout.contains("could not read NSAppSleepDisabled for com.example.Broken; check it yourself with: defaults read com.example.Broken NSAppSleepDisabled"), r.stdout)
        XCTAssertTrue(r.stdout.contains("1 could not be read"), r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("defaults write") || $0.hasPrefix("defaults delete") }, "\(fx.calls())")
    }

    /// A `defaults read` that never answers (cfprefsd stuck) is stopped
    /// after the call limit, reported with the command to check it by hand,
    /// and ends the check, since every later read would wait the same way.
    /// The read keeps the lock until it has been killed and reaped; then
    /// uninstall finishes, and nothing left running holds the lock.
    func testUninstallStopsAHungDefaultsReadAndFinishes() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeConfig(#"{"agentList":["com.google.Chrome"]}"#)
        fx.setMode("defaults", "hang:com.google.Chrome")
        let index = try XCTUnwrap(Config.defaultAgentList.firstIndex(of: "com.google.Chrome"))

        let started = Date()
        let tmp = try fx.privateTmp()
        let r = try fx.run(fx.uninstall, ["--purge"], extraEnvironment: ["TMPDIR": tmp.path])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30, "one bounded read, not the fake's 60 s hang")
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("defaults read") },
                       Config.defaultAgentList[...index].map { "defaults read \($0) NSAppSleepDisabled" },
                       "the check stops at the read that did not answer")
        XCTAssertTrue(fx.calls().contains("defaults FD9-OPEN"), "the read keeps the lock while it runs")
        XCTAssertTrue(fx.hungProcessGone("defaults", within: 0), "the read ignored SIGTERM, so it was killed")
        XCTAssertTrue(r.stdout.contains("defaults read did not answer within 5s for com.google.Chrome; check it yourself with: defaults read com.google.Chrome NSAppSleepDisabled"), r.stdout)
        XCTAssertTrue(r.stdout.contains("stopped after com.google.Chrome did not answer; \(Config.defaultAgentList.count - index - 1) more agent apps were not checked"), r.stdout)
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.config))
        XCTAssertEqual(try fx.contents(of: tmp), [], "the scratch directory is gone, including the stopped call's files")
    }

    /// A `launchctl print` that never answers cannot prove the agent is
    /// gone: uninstall stops with every recovery file in place, and exits
    /// instead of holding the lock while it waits.
    func testUninstallStopsAHungLaunchctlPrintAndKeepsEverything() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "print-hangs")

        let started = Date()
        let tmp = try fx.privateTmp()
        let r = try fx.run(fx.uninstall, ["--purge"], extraEnvironment: ["TMPDIR": tmp.path])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(elapsed, 30, "one bounded print, not the fake's 60 s hang")
        XCTAssertTrue(r.stderr.contains("'launchctl print' did not answer within 5s; cannot tell whether com.insomnia.backstop is still loaded"), r.stderr)
        XCTAssertTrue(fx.calls().contains("launchctl FD9-OPEN"), "\(fx.calls())")
        XCTAssertTrue(fx.hungProcessGone("launchctl", within: 0))
        XCTAssertFalse(fx.calls().contains { Self.isRootRemoval($0) }, "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.config))
        XCTAssertTrue(fx.exists(fx.state))
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(try fx.contents(of: tmp), [], "the scratch directory is gone, including the stopped call's files")
    }

    /// A `pgrep` that never answers under the lock counts as "Insomnia is
    /// running": uninstall stops before the backstop runs and lets go of
    /// the lock.
    func testUninstallTreatsAHungPgrepAsRunning() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "1\nhang\n")   // not running at the quit step, then no answer

        let started = Date()
        let tmp = try fx.privateTmp()
        let r = try fx.run(fx.uninstall, extraEnvironment: ["TMPDIR": tmp.path])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(elapsed, 30)
        XCTAssertTrue(r.stderr.contains("pgrep did not answer within 5s; treating Insomnia as running."), r.stderr)
        XCTAssertTrue(fx.calls().contains("pgrep FD9-OPEN"), "\(fx.calls())")
        XCTAssertTrue(fx.hungProcessGone("pgrep", within: 0))
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(try fx.contents(of: tmp), [], "the scratch directory is gone, including the stopped call's files")
    }

    /// uninstall.sh carries a copy of the shipped agent list so its check
    /// covers apps the user later removed from config.json. The copy must
    /// match Config.defaultAgentList, in order.
    func testUninstallShippedAgentListMatchesTheAppsDefault() throws {
        let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent("uninstall.sh"), encoding: .utf8)
        guard let start = text.range(of: "\nDEFAULT_AGENTS=(\n"),
              let end = text.range(of: "\n)\n", range: start.upperBound..<text.endIndex) else {
            return XCTFail("DEFAULT_AGENTS=( ... ) not found in uninstall.sh")
        }
        let ids = text[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line -> String? in
            let id = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        XCTAssertEqual(ids, Config.defaultAgentList)
    }

    /// The --resume-frozen interface version is the same in the binary, in
    /// the bundle's Info.plist, and in the two scripts that check it.
    func testTheResumeFrozenVersionIsTheSameEverywhere() throws {
        let scripts = ScriptFixture.productionScripts
        let info = scripts.deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        XCTAssertEqual(plist["InsomniaResumeFrozenVersion"] as? Int, ResumeFrozenCommand.version)
        for name in ["backstop.sh", "uninstall.sh"] {
            let text = try String(contentsOf: scripts.appendingPathComponent(name), encoding: .utf8)
            let lines = text.split(separator: "\n").filter { $0.hasPrefix("RESUME_FROZEN_VERSION=") }
            XCTAssertEqual(lines, ["RESUME_FROZEN_VERSION=\(ResumeFrozenCommand.version)"], name)
        }
    }

    /// uninstall.sh from a newer checkout must not run its own backstop.sh
    /// against an installed app that lacks the --resume-frozen mode that
    /// backstop needs. When the installed Info.plist does not declare the
    /// version, the backstop.sh installed with that app restores the
    /// machine instead: the copy sealed in its bundle, or for an install
    /// before that layout the writable copy in Application Support (each
    /// the copy its LaunchAgent runs). Here that copy is a stand-in that
    /// records its run.
    func testUninstallUsesTheInstalledBackstopWhenTheAppDoesNotDeclareTheVersion() throws {
        for version in [nil, "2"] as [String?] {
            for sealed in [true, false] {
                let f = try ScriptFixture()
                defer { f.destroy() }
                try f.installMachinery()
                try ScriptFixture.infoPlist(resumeFrozenVersion: version).write(to: f.appInfo, atomically: true, encoding: .utf8)
                let copy = sealed ? f.installedBackstop : f.legacyBackstop
                if !sealed { try FileManager.default.removeItem(at: f.installedBackstop) }
                try "printf 'installed backstop %s\\n' \"$*\" >> '\(f.callsLog.path)'\n".write(to: copy, atomically: true, encoding: .utf8)
                try f.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

                let r = try f.run(f.uninstall)

                let label = "\(version ?? "no key"), \(sealed ? "sealed" : "legacy") copy"
                XCTAssertEqual(r.status, 0, "\(label): \(r.stderr)")
                XCTAssertTrue(f.calls().contains("installed backstop --force"), "\(label): \(f.calls())")
                XCTAssertTrue(r.stdout.contains("does not declare InsomniaResumeFrozenVersion 1; using the backstop installed with it, \(copy.path)"), "\(label): \(r.stdout)")
            }
        }
    }

    /// An installed app that declares the version gets this checkout's
    /// backstop.sh, which reads the same Info.plist, hands the frozen entry
    /// to the app binary and clears it. That holds with installed copies
    /// present (stand-ins, sealed and legacy, that must not run) and with
    /// no installed copy.
    func testUninstallUsesTheCheckoutBackstopWhenTheAppDeclaresTheVersion() throws {
        for installedCopy in [true, false] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            if installedCopy {
                for copy in [f.installedBackstop, f.legacyBackstop] {
                    try "printf 'installed backstop %s\\n' \"$*\" >> '\(f.callsLog.path)'\n".write(to: copy, atomically: true, encoding: .utf8)
                }
            } else {
                try FileManager.default.removeItem(at: f.installedBackstop)
            }
            try writeFrozenEntryForUninstall(f)

            let r = try f.run(f.uninstall)

            let label = installedCopy ? "installed copy" : "no installed copy"
            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr) \(f.log())")
            XCTAssertFalse(f.calls().contains("installed backstop --force"), "\(label): \(f.calls())")
            XCTAssertTrue(f.calls().contains("Insomnia --resume-frozen 2 < 5311 1789388423 11 \(f.bootUUID)"), "\(label): \(f.calls())")
            XCTAssertFalse(f.exists(f.app), label)
            XCTAssertFalse(f.exists(f.state), label)
        }
    }

    /// An installed app that does not declare the version, with no
    /// installed backstop to fall back on: the checkout's backstop reads the
    /// same Info.plist, so it never runs the binary and keeps the frozen
    /// entry, and uninstall stops before removing anything.
    func testUninstallKeepsEverythingWhenTheAppDoesNotDeclareTheVersionAndNoCopyIsInstalled() throws {
        for version in [nil, "2"] as [String?] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try ScriptFixture.infoPlist(resumeFrozenVersion: version).write(to: f.appInfo, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: f.installedBackstop)
            try writeFrozenEntryForUninstall(f)

            let r = try f.run(f.uninstall)

            let label = version ?? "no key"
            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertEqual(f.calls().filter { $0.hasPrefix("Insomnia ") }, [], "\(label): the binary ran")
            XCTAssertTrue(f.log().contains("pid 5311 needs the app binary for its microsecond identity check, but \(f.appInfo.path) declares InsomniaResumeFrozenVersion"), "\(label): \(f.log())")
            XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything"), "\(label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("frozen processes are still journaled"), "\(label): \(r.stderr)")
            let entries = try XCTUnwrap(f.stateJSON()["frozenProcesses"] as? [[String: Any]], label)
            XCTAssertEqual(entries.map { $0["pid"] as? Int }, [5311], label)
            for kept in [f.app, f.plist, f.sudoers, f.session] {
                XCTAssertTrue(f.exists(kept), "\(label): \(kept.lastPathComponent) was removed")
            }
        }
    }

    /// An expired session and one frozen entry with a microsecond identity,
    /// for the uninstall tests above.
    private func writeFrozenEntryForUninstall(_ f: ScriptFixture) throws {
        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try f.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[{"pid":5311,"startedAt":1789388423,"startedAtMicros":11,"bootSession":"\(f.bootUUID)"}]}
        """)
    }

    func testUninstallAbortsOnMalformedJournal() throws {
        try fx.installMachinery()
        let broken = "{\"sleepDisabledByUs\":tru"
        try fx.writeState(broken)

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), broken)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(r.stderr.contains("malformed"), r.stderr)
    }

    func testUninstallAbortsOnLegacyPidsAndExplainsManualResolution() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"frozenPids":[555]}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") })
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(r.stderr.contains("555"), r.stderr)
        XCTAssertTrue(r.stderr.contains("kill -CONT"), r.stderr)
    }

    func testUninstallVerifiesJournalEvenWhenBackstopExitsZero() throws {
        try fx.installMachinery()
        // An older backstop that claims success without restoring anything.
        try "#!/bin/bash\nexit 0\n".write(to: fx.backstop, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.state))
        XCTAssertTrue(r.stderr.contains("sleepDisabledByUs is still true"), r.stderr)
    }

    func testUninstallSuccessRemovesMachineryAndKeepsConfig() throws {
        try fx.installMachinery()
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("launchctl bootout gui/\(fx.uid) \(fx.plist.path)"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo -n /bin/rm -f \(fx.sudoers.path)"), "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.state))
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.config), "config.json survives without --purge")
        XCTAssertTrue(fx.exists(fx.logFile), "logs survive without --purge")
        XCTAssertTrue(fx.exists(fx.appsDir), "only the bundle goes, not its parent")
    }

    /// A rule in a directory only root can search is removed by `sudo -n
    /// /bin/rm -f`, by full path, without first asking whether it is there.
    func testUninstallFindsAndRemovesARuleOnlyRootCanSee() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let dir = fx.sudoers.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        fx.setMode("sudo-root", "search")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.contains("/bin/test") }, "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo -n /bin/rm -f \(fx.sudoers.path)"), "\(fx.calls())")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        XCTAssertFalse(fx.exists(fx.sudoers))
    }

    /// Round 30 (finding 4): every command uninstall.sh runs as root goes
    /// through `sudo -n`, bounded (as_root), after one `sudo -v`, which asks
    /// for the password before anything is removed and runs nothing as
    /// root. Neither installer script keeps or prints a pid to kill.
    func testUninstallRunsEveryRootCommandBoundedThroughSudoN() throws {
        let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent("uninstall.sh"), encoding: .utf8)
        let uses = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && $0.contains("\"$SUDO\"") }
        XCTAssertEqual(uses, [
            #"if [[ "$1" == "$SUDO" ]]; then"#,
            #"if [[ "$1" != "$SUDO" ]]; then"#,
            #"bounded "$SUDO" -n "$@" || rc=$?"#,
            #"if ! "$SUDO" -v; then"#,
        ])
        for name in ["install.sh", "uninstall.sh"] {
            let script = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(script.contains("BOUNDED_PID") || script.contains("sudo kill"), name)
        }
    }

    /// sudo forgets the credential `sudo -v` cached at once (as with
    /// timestamp_timeout 0): the uninstall stops before the agent is booted
    /// out, with nothing removed.
    func testUninstallStopsBeforeRemovingAnythingWhenSudoKeepsNoCredential() throws {
        try fx.installMachinery()
        try fx.writeState(cleanJournal)
        try fx.writeReceipt()
        let journal = try Data(contentsOf: fx.state)
        fx.setMode("sudo", "cache-expires")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stdout + r.stderr)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything: 'sudo -n -v' exited 1, so sudo did not keep the credential the commands below need."), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl bootout") || Self.isRootRemoval($0) }, "\(fx.calls())")
        for kept in [fx.plist, fx.sudoers, fx.app, fx.installedBackstop] { XCTAssertTrue(fx.exists(kept), kept.path) }
        XCTAssertEqual(try Data(contentsOf: fx.state), journal)
        XCTAssertEqual(fx.receiptText(), SleepOffReceipts.initialContent)
        XCTAssertEqual(fx.release(), SleepOffReceipts.initialRelease)
    }

    /// Whether someone holds the receipt's lock, asked without waiting.
    private func receiptLockIsHeld() -> Bool {
        let fd = open(fx.receipt, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    /// Round 30 (finding 4): the removal of the rule never answers and
    /// ignores SIGTERM. It gets SIGTERM once at its limit and never
    /// SIGKILL; the uninstall stops there and removes nothing after it,
    /// and the recovery lock and the receipt's lock stay held by its
    /// supervisor until it has ended. No pid is printed.
    func testUninstallStopsAndKeepsTheLocksWhileARootRemovalHangs() throws {
        try fx.installMachinery()
        try fx.writeState(cleanJournal)
        try fx.writeReceipt()
        let journal = try Data(contentsOf: fx.state)
        try fx.sudoers.path.write(to: fx.root.appendingPathComponent("sudo-rm.hangs"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stdout + r.stderr)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped after removing the LaunchAgent: 'sudo -n /bin/rm -f \(fx.sudoers.path)' did not answer within 5s and is still running; it is not stopped from here, and the recovery lock and the receipt's lock stay held until it ends."), r.stderr)
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) may still be there. \(fx.app.path), the receipt and the journal were kept."), r.stderr)
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0))
        XCTAssertFalse(r.stderr.contains("sudo kill") || r.stderr.contains("pid \(pid)") || r.stdout.contains("pid \(pid)"), r.stderr)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0 == "sudo SIGTERM" }.count, 1, "\(calls)")
        XCTAssertFalse(calls.contains("sudo -n /bin/rm -f \(fx.receipt)") || calls.contains("sudo -n /bin/rmdir \(fx.receipts)"), "\(calls)")
        XCTAssertFalse(fx.hungProcessGone("sudo", within: 2), "sudo is never sent SIGKILL")
        XCTAssertFalse(try fx.lockIsFree(), "the recovery lock stays held while the removal runs")
        XCTAssertTrue(receiptLockIsHeld(), "the receipt's lock stays held while the removal runs")
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertEqual(try Data(contentsOf: fx.state), journal)
        XCTAssertEqual(fx.receiptText(), SleepOffReceipts.initialContent)
        XCTAssertEqual(fx.release(), SleepOffReceipts.initialRelease)

        fx.releaseCommand()
        XCTAssertTrue(fx.hungProcessGone("sudo"))
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(try fx.waitUntilLockIsFree(5), "the recovery lock goes with the sudo that held it")
        let deadline = Date(timeIntervalSinceNow: 5)
        while receiptLockIsHeld() && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertFalse(receiptLockIsHeld(), "the receipt's lock goes with it too")
    }

    /// Round 30 (finding 4): a removal as root that fails stops the
    /// uninstall there: what comes after it is kept.
    func testUninstallStopsWhenARootRemovalFails() throws {
        for failing in ["rule", "receipt"] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeState(cleanJournal)
            try f.writeReceipt()
            let journal = try Data(contentsOf: f.state)
            let path = failing == "rule" ? f.sudoers.path : f.receipt
            try path.write(to: f.root.appendingPathComponent("sudo-rm.fails"), atomically: true, encoding: .utf8)

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 1, "\(failing): \(r.stdout + r.stderr)")
            let why = "'sudo -n /bin/rm -f \(path)' exited 1 (rm: \(path): Operation not permitted)"
            if failing == "rule" {
                XCTAssertTrue(r.stderr.contains("Uninstall stopped after removing the LaunchAgent: \(why).\n\(f.sudoers.path) may still be there."), r.stderr)
                XCTAssertTrue(f.exists(f.sudoers))
                XCTAssertEqual(f.receiptText(), SleepOffReceipts.initialContent)
            } else {
                XCTAssertTrue(r.stderr.contains("Uninstall stopped after removing the LaunchAgent and \(f.sudoers.path): \(why)."), r.stderr)
                XCTAssertFalse(f.exists(f.sudoers))
                XCTAssertEqual(f.receiptText(), SleepOffReceipts.initialContent)
            }
            XCTAssertFalse(f.calls().contains("sudo -n /bin/rm -f \(f.released)"), "\(failing): \(f.calls())")
            XCTAssertEqual(f.release(), SleepOffReceipts.initialRelease, failing)
            XCTAssertTrue(f.exists(f.installedBackstop), failing)
            XCTAssertEqual(try Data(contentsOf: f.state), journal, failing)
            // Round 30: the receipt and its release file are both still
            // there, so a rerun removes them as the first run would have.
            if failing == "receipt" {
                unlink(f.root.appendingPathComponent("sudo-rm.fails").path)
                let again = try f.run(f.uninstall)
                XCTAssertEqual(again.status, 0, again.stdout + again.stderr)
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.receipt))
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.released))
                XCTAssertFalse(f.exists(f.home.appendingPathComponent(".uninstall-receipt-removal")))
                XCTAssertFalse(f.exists(f.installedBackstop))
            }
        }
    }

    /// Greptile on 7e233e8 (an interrupted uninstall cannot finish): a stop
    /// between removing the receipt and removing its release file leaves
    /// the release file alone, which the check before step 5 refuses as
    /// unknown. Before it removes the receipt, the uninstall writes the
    /// release file's device, inode, change time and line to
    /// .uninstall-receipt-removal in its own folder, so a rerun that finds
    /// that very file, unwritten since and free, finishes the removal.
    /// Covered: the release file's removal fails, sudo has lost the
    /// credential, and the removal stops on SIGTERM at its limit. Another
    /// account's receipt in the folder stays, and so does the folder.
    func testUninstallFinishesTheReceiptsRemovalAfterAStopBetweenItsRemovals() throws {
        for stop in ["fails", "no-credential", "stops"] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            let progress = f.home.appendingPathComponent(".uninstall-receipt-removal")
            try f.installMachinery()
            try f.writeState(cleanJournal)
            try f.writeReceipt()
            let other = f.receipts + "/4242424"
            try "another account\n".write(toFile: other, atomically: true, encoding: .utf8)
            let journal = try Data(contentsOf: f.state)
            let control = f.root.appendingPathComponent("sudo-rm.\(stop)")
            try f.released.write(to: control, atomically: true, encoding: .utf8)

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 1, "\(stop): \(r.stdout + r.stderr)")
            let removal = "'sudo -n /bin/rm -f \(f.released)'"
            let why = [
                "fails": "\(removal) exited 1 (rm: \(f.released): Operation not permitted)",
                "no-credential": "\(removal) exited 1 (sudo: a password is required)",
                "stops": "\(removal) did not answer within 5s and stopped on SIGTERM, so what it did is unknown",
            ][stop]!
            XCTAssertTrue(r.stderr.contains("Uninstall stopped after removing the LaunchAgent and \(f.sudoers.path): \(why)."), "\(stop): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("\(progress.path) records the receipt's removal: a rerun finishes it while \(f.released) stays as it is now."), "\(stop): \(r.stderr)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.receipt), stop)
            XCTAssertEqual(f.release(), SleepOffReceipts.initialRelease, stop)
            let identity = try f.runTool("/usr/bin/stat", ["-f", "%d:%i:%Fc", f.released]).output.trimmingCharacters(in: .newlines)
            XCTAssertEqual(try String(contentsOf: progress, encoding: .utf8), "\(identity) \(SleepOffReceipts.initialRelease)", stop)
            XCTAssertTrue(f.exists(f.installedBackstop), stop)
            XCTAssertEqual(try Data(contentsOf: f.state), journal, stop)

            unlink(control.path)
            let again = try f.run(f.uninstall)

            XCTAssertEqual(again.status, 0, "\(stop): \(again.stdout + again.stderr)")
            XCTAssertTrue(again.stdout.contains("\(f.receipt) is gone and \(f.released) is as this folder's uninstall left it when it began removing them (\(progress.path)); step 5 finishes the removal"), "\(stop): \(again.stdout)")
            XCTAssertTrue(again.stdout.contains("removed \(f.released)\n"), "\(stop): \(again.stdout)")
            XCTAssertTrue(again.stdout.contains("kept \(f.receipts): it still holds another account's receipt"), "\(stop): \(again.stdout)")
            XCTAssertTrue(again.stdout.contains("removed \(progress.path)\n"), "\(stop): \(again.stdout)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.released), stop)
            XCTAssertFalse(f.exists(progress), stop)
            XCTAssertEqual(try String(contentsOfFile: other, encoding: .utf8), "another account\n", stop)
            XCTAssertFalse(f.exists(f.installedBackstop), stop)
            XCTAssertFalse(f.exists(f.sudoers), stop)
        }
    }

    /// The same stop, with the release file's removal still running at its
    /// limit: it gets SIGTERM once and never SIGKILL, and its supervisor
    /// keeps the recovery lock until it has ended. (The receipt's lock is
    /// on a file that is gone by then, so no path reaches it to check.)
    /// The rerun after that finishes the removal.
    func testUninstallFinishesTheReceiptsRemovalAfterARemovalThatOutlivedItsLimit() throws {
        try fx.installMachinery()
        try fx.writeState(cleanJournal)
        try fx.writeReceipt()
        let control = fx.root.appendingPathComponent("sudo-rm.hangs")
        try fx.released.write(to: control, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stdout + r.stderr)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped after removing the LaunchAgent and \(fx.sudoers.path): 'sudo -n /bin/rm -f \(fx.released)' did not answer within 5s and is still running; it is not stopped from here, and the recovery lock and the receipt's lock stay held until it ends."), r.stderr)
        XCTAssertNotNil(fx.hungPid("sudo", within: 0))
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGTERM" }.count, 1, "\(fx.calls())")
        XCTAssertFalse(fx.hungProcessGone("sudo", within: 2), "sudo is never sent SIGKILL")
        XCTAssertFalse(try fx.lockIsFree(), "the recovery lock stays held while the removal runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipt))
        XCTAssertEqual(fx.release(), SleepOffReceipts.initialRelease)
        XCTAssertTrue(fx.exists(fx.home.appendingPathComponent(".uninstall-receipt-removal")))

        fx.releaseCommand()
        XCTAssertTrue(fx.hungProcessGone("sudo"))
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(try fx.waitUntilLockIsFree(5), "the recovery lock goes with the sudo that held it")
        unlink(control.path)
        let again = try fx.run(fx.uninstall)

        XCTAssertEqual(again.status, 0, again.stdout + again.stderr)
        XCTAssertTrue(again.stdout.contains("removed \(fx.released)\n"), again.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.released))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.receipts))
        XCTAssertFalse(fx.exists(fx.home.appendingPathComponent(".uninstall-receipt-removal")))
    }

    /// A release file without its receipt stays refused, with nothing
    /// removed, unless this folder's record names it as it is now. Each
    /// case starts from a record that would finish the removal and then
    /// changes one thing: the file written to since with the same line,
    /// another file with the same line in its place, a claim of another
    /// folder's start written since, a second link, mode 644, or no record.
    /// A receipt without its release file stays refused with a record too.
    func testUninstallStillRefusesALoneSharedFileItsRecordDoesNotName() throws {
        let progress = fx.home.appendingPathComponent(".uninstall-receipt-removal")
        let start = UUID().uuidString
        let lone = "\(fx.released) is there without the receipt \(fx.receipt), and no record of this folder's uninstall (\(progress.path)) names it as it is now, so what the receipt showed, and whether a start still needs the rule, is unknown"
        let initial = SleepOffReceipts.initialRelease
        let cases: [(name: String, change: () throws -> Void, saying: String, receipt: String?, release: String?)] = [
            ("written to since, with the same line", { try self.fx.writeRelease(initial) }, lone, nil, initial),
            ("another file with the same line", {
                let next = self.fx.receipts + "/next"
                try initial.write(toFile: next, atomically: false, encoding: .utf8)
                XCTAssertEqual(chmod(next, 0o600), 0)
                XCTAssertEqual(rename(next, self.fx.released), 0)
             }, lone, nil, initial),
            ("a claim of another folder's start", { try self.fx.writeRelease("\(start) held\n") }, lone, nil, "\(start) held\n"),
            ("a second link", { XCTAssertEqual(link(self.fx.released, self.fx.receipts + "/second"), 0) }, lone, nil, initial),
            ("mode 644", { XCTAssertEqual(chmod(self.fx.released, 0o644), 0) }, lone, nil, initial),
            ("no record", { XCTAssertEqual(unlink(progress.path), 0) }, lone, nil, initial),
            ("a receipt without its release file", {
                try self.fx.writeReceipt()
                XCTAssertEqual(unlink(self.fx.released), 0)
             }, "\(fx.receipt) is there without its release file \(fx.released), so it does not show that no start claims the receipt", SleepOffReceipts.initialContent, nil),
        ]
        for c in cases {
            try? FileManager.default.removeItem(at: fx.installedBackstop)
            try fx.installMachinery()
            fx.clearCalls()
            try fx.writeState(cleanJournal)
            if FileManager.default.fileExists(atPath: fx.receipts) { try FileManager.default.removeItem(atPath: fx.receipts) }
            try fx.writeReceipt()
            XCTAssertEqual(unlink(fx.receipt), 0)
            let identity = try fx.runTool("/usr/bin/stat", ["-f", "%d:%i:%Fc", fx.released]).output.trimmingCharacters(in: .newlines)
            try "\(identity) \(initial)".write(to: progress, atomically: true, encoding: .utf8)
            try c.change()
            let journal = try Data(contentsOf: fx.state)

            let r = try fx.run(fx.uninstall)

            try assertUninstallRemovedNothing(r, saying: c.saying, journal: journal, receipt: c.receipt, release: c.release)
        }
    }

    func testUninstallPurgeRemovesOwnedFilesAndEmptyDirectoriesOnly() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        for rotated in ["Logs/handoffs.log", "Logs/insomnia.log.1", "Logs/handoffs.log.1"] {
            try "older lines\n".write(to: fx.home.appendingPathComponent(rotated), atomically: true, encoding: .utf8)
        }
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        for gone in [fx.state, fx.config, fx.logFile, fx.home.appendingPathComponent("Logs/handoffs.log"),
                     fx.home.appendingPathComponent("Logs/insomnia.log.1"), fx.home.appendingPathComponent("Logs/handoffs.log.1"),
                     fx.installedBackstop, fx.legacyBackstop, fx.plist, fx.app, fx.sudoers] {
            XCTAssertFalse(fx.exists(gone), gone.path)
        }
        XCTAssertFalse(fx.exists(fx.home.appendingPathComponent("Logs")), "empty owned directories are removed")
        XCTAssertFalse(fx.exists(fx.home.appendingPathComponent("LaunchAgents")))
        XCTAssertTrue(fx.exists(fx.lock), "the lock file is the documented leftover")
        XCTAssertEqual(try fx.contents(of: fx.home), [".recovery.lock"], "nothing but the lock remains")
        XCTAssertTrue(fx.exists(fx.appsDir))
        XCTAssertTrue(fx.exists(fx.bin), "nothing outside the Insomnia tree is deleted")
    }

    func testUninstallPurgeNeverDeletesFilesItDidNotCreate() throws {
        // INSOMNIA_HOME pointing at a directory that also holds other things:
        // the exact owned files go, everything else and the directories stay.
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let stray = fx.home.appendingPathComponent("photos.txt")
        let strayLog = fx.home.appendingPathComponent("Logs/other-app.log")
        let strayDir = fx.home.appendingPathComponent("Documents", isDirectory: true)
        try "mine".write(to: stray, atomically: true, encoding: .utf8)
        try "theirs".write(to: strayLog, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        try "doc".write(to: strayDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(stray))
        XCTAssertTrue(fx.exists(strayLog))
        XCTAssertTrue(fx.exists(strayDir.appendingPathComponent("a.txt")))
        XCTAssertTrue(fx.exists(fx.home))
        XCTAssertFalse(fx.exists(fx.state))
        XCTAssertFalse(fx.exists(fx.config))
        XCTAssertFalse(fx.exists(fx.logFile))
        XCTAssertFalse(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.lock))
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertTrue(r.stdout.contains("Kept \(fx.home.appendingPathComponent("Logs").path)"), r.stdout)
    }

    /// What install.sh leaves beside the bundle goes with it: the previous
    /// bundle an interrupted upgrade set aside and the staging directories
    /// of runs that are gone, matched by the exact names install.sh gives
    /// them. A staging directory whose run `$KILL -0` reports alive stays,
    /// and so does every other name, symlink and symlink target. The
    /// candidate plists install.sh and the app stage the agent in go with
    /// the agent plist, and only those.
    func testUninstallRemovesTheInstallersLeftoversByTheirExactNames() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let leftovers = try writeInstallerLeftovers()
        fx.setMode("kill.fail", "4242")   // the fake kill: 4242 is gone, 4343 is alive

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertEqual(try fx.contents(of: fx.appsDir), leftovers.keptInApps, "only install.sh's own leftovers are removed")
        XCTAssertTrue(fx.exists(leftovers.linkTarget.appendingPathComponent("Insomnia.app/Contents/MacOS/Insomnia")), "a symlink's target is never touched")
        XCTAssertTrue(fx.calls().contains("kill -0 4242") && fx.calls().contains("kill -0 4343"), "asked through $KILL: \(fx.calls())")
        XCTAssertTrue(r.stdout.contains("kept \(fx.appsDir.path)/.Insomnia.app.staging.4343.BBBBBB"), r.stdout)
        let launchAgents = fx.plist.deletingLastPathComponent()
        XCTAssertEqual(try fx.contents(of: launchAgents), [".com.insomnia.backstop.staging", "com.other.agent.plist"])
        XCTAssertEqual(try fx.contents(of: launchAgents.appendingPathComponent(".com.insomnia.backstop.staging")), ["notes.txt"], "a file that is not a candidate stays, and so does its directory")

        // With no foreign file left, the staging directory itself goes.
        try FileManager.default.removeItem(at: launchAgents.appendingPathComponent(".com.insomnia.backstop.staging/notes.txt"))
        try fx.installMachinery()
        try "<plist/>".write(to: launchAgents.appendingPathComponent(".com.insomnia.backstop.staging/com.insomnia.backstop.candidate-77.plist"), atomically: true, encoding: .utf8)
        let again = try fx.run(fx.uninstall)
        XCTAssertEqual(again.status, 0, again.stderr + again.stdout)
        XCTAssertEqual(try fx.contents(of: launchAgents), ["com.other.agent.plist"])
    }

    /// The leftovers go only after recovery is confirmed and the agent is
    /// unloaded, like the bundle: an uninstall that stops for an unresolved
    /// journal or a job launchd still lists leaves every one of them.
    func testUninstallKeepsTheInstallersLeftoversWhenItStopsBeforeRemoving() throws {
        for stop in ["recovery fails", "agent still loaded"] {
            fx.destroy()
            fx = try ScriptFixture()
            try fx.installMachinery()
            try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            let leftovers = try writeInstallerLeftovers()
            fx.setMode("kill.fail", "4242 4343")   // every staging run is gone
            if stop == "recovery fails" {
                fx.setMode("sudo", "fail")
            } else {
                fx.setMode("launchctl", "bootout-fails-still-loaded")
            }
            let launchAgents = fx.plist.deletingLastPathComponent()
            let before = try fx.contents(of: launchAgents)
            let staged = try fx.contents(of: launchAgents.appendingPathComponent(".com.insomnia.backstop.staging"))

            let r = try fx.run(fx.uninstall)

            XCTAssertEqual(r.status, 1, "\(stop): \(r.stderr + r.stdout)")
            XCTAssertEqual(try fx.contents(of: fx.appsDir), (leftovers.removable + leftovers.keptInApps + ["Insomnia.app"]).sorted(), stop)
            XCTAssertEqual(try fx.contents(of: launchAgents), before, stop)
            XCTAssertEqual(try fx.contents(of: launchAgents.appendingPathComponent(".com.insomnia.backstop.staging")), staged, stop)
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill ") }, "\(stop): \(fx.calls())")
        }
    }

    /// Beside the installed bundle: what install.sh can leave (the
    /// set-aside previous bundle, a dead and a live run's staging
    /// directory) and names it must not touch. In the LaunchAgents
    /// directory: candidate plists of install.sh, of the app and of older
    /// builds, plus another agent's plist and a stray file.
    private func writeInstallerLeftovers() throws -> (removable: [String], keptInApps: [String], linkTarget: URL) {
        let removable = [".Insomnia.app.previous", ".Insomnia.app.staging.4242.AAAAAA"]
        let live = ".Insomnia.app.staging.4343.BBBBBB"
        let unlike = [".Insomnia.app.staging.4242", ".Insomnia.app.staging.4242.AAAAAA.old", ".Insomnia.app.staging.x4242.AAAAAA",
                      ".Insomnia.app.previous.old", "Other.app", ".Other.app.previous"]
        let link = ".Insomnia.app.staging.4242.CCCCCC"
        for name in removable + [live] + unlike {
            try fx.writeBundle(at: fx.appsDir.appendingPathComponent(name).appendingPathComponent("Insomnia.app"), marker: "left")
        }
        let elsewhere = fx.root.appendingPathComponent("elsewhere", isDirectory: true)
        try fx.writeBundle(at: elsewhere.appendingPathComponent("Insomnia.app"), marker: "not the installer's")
        try FileManager.default.createSymbolicLink(at: fx.appsDir.appendingPathComponent(link), withDestinationURL: elsewhere)

        let launchAgents = fx.plist.deletingLastPathComponent()
        let staging = launchAgents.appendingPathComponent(".com.insomnia.backstop.staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for url in [staging.appendingPathComponent("com.insomnia.backstop.candidate-4242.plist"),
                    staging.appendingPathComponent("com.insomnia.backstop.candidate-0F2C9A54-1B7E-4D7A-9C11-5E3B2A7D9F00.plist"),
                    launchAgents.appendingPathComponent("com.insomnia.backstop.candidate-0F2C9A54-1B7E-4D7A-9C11-5E3B2A7D9F01"),
                    staging.appendingPathComponent("notes.txt"),
                    launchAgents.appendingPathComponent("com.other.agent.plist")] {
            try "<plist/>".write(to: url, atomically: true, encoding: .utf8)
        }
        return (removable, ([live, link] + unlike).sorted(), elsewhere)
    }

    // MARK: - Which backstop uninstall.sh runs

    /// Newest first: the checkout's script (every test above), else the copy
    /// install.sh sealed into the bundle, else the writable copy of installs
    /// before that layout. Each marker records which one ran.
    func testUninstallRunsTheSealedCopyWhenTheCheckoutHasNoBackstop() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.removeItem(at: fx.backstop)
        try fx.writeMarkerBackstop(at: fx.installedBackstop, name: "sealed")
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("backstop ") }, ["backstop sealed --force"], "\(fx.calls())")
        XCTAssertTrue(r.stdout.contains("using \(fx.installedBackstop.path)"), r.stdout)
        let verify = try XCTUnwrap(fx.calls().firstIndex(of: "codesign --verify --strict \(fx.app.path)"), "the sealed copy is verified: \(fx.calls())")
        let ran = try XCTUnwrap(fx.calls().firstIndex(of: "backstop sealed --force"))
        XCTAssertLessThan(verify, ran, "verified before it runs: \(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.legacyBackstop), "the writable copy goes with the rest")
    }

    /// A release zip has no backstop.sh beside its uninstall.sh. Unpacked
    /// at /tmp/Insomnia-<version>, the parent folder is /tmp, where any
    /// account can create scripts/backstop.sh; uninstall runs the sealed
    /// copy after verifying the bundle and never one from the parent.
    func testUninstallFromAZipRunsTheSealedCopyNotABackstopInTheParentFolder() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeMarkerBackstop(at: fx.installedBackstop, name: "sealed")
        let shared = fx.root.appendingPathComponent("shared-tmp", isDirectory: true)
        let unpacked = shared.appendingPathComponent("Insomnia-0.1.0-macos", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fx.uninstall, to: unpacked.appendingPathComponent("uninstall.sh"))
        try fx.writeMarkerBackstop(at: shared.appendingPathComponent("scripts/backstop.sh"), name: "planted")

        let r = try fx.run(unpacked.appendingPathComponent("uninstall.sh"))

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("backstop ") }, ["backstop sealed --force"], "\(fx.calls())")
        XCTAssertTrue(r.stdout.contains("using \(fx.installedBackstop.path)"), r.stdout)
        let verify = try XCTUnwrap(fx.calls().firstIndex(of: "codesign --verify --strict \(fx.app.path)"), "the sealed copy is verified: \(fx.calls())")
        let ran = try XCTUnwrap(fx.calls().firstIndex(of: "backstop sealed --force"))
        XCTAssertLessThan(verify, ran, "verified before it runs: \(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// A backstop.sh added beside the zip's uninstall.sh (the zip has none),
    /// as another account could do in a folder it created in /tmp before the
    /// zip was unpacked there, is not run. Outside a source checkout
    /// (scripts/ with Package.swift one level up) uninstall.sh runs only the
    /// sealed copy, after the bundle verifies, and says it left the other
    /// one alone. Also in a folder named scripts with no Package.swift above
    /// it, and in a zip folder unpacked inside a checkout, which has
    /// Package.swift above it but is not scripts/.
    func testUninstallFromAZipRunsTheSealedCopyNotABackstopPlantedBesideIt() throws {
        for folder in ["shared-tmp/Insomnia-0.1.0-macos", "shared-tmp/scripts", "repo/Insomnia-0.1.0-macos"] {
            fx.destroy()
            fx = try ScriptFixture()
            try fx.installMachinery()
            try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            try fx.writeMarkerBackstop(at: fx.installedBackstop, name: "sealed")
            let unpacked = fx.root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fx.uninstall, to: unpacked.appendingPathComponent("uninstall.sh"))
            let planted = unpacked.appendingPathComponent("backstop.sh")
            try fx.writeMarkerBackstop(at: planted, name: "planted")

            let r = try fx.run(unpacked.appendingPathComponent("uninstall.sh"))

            XCTAssertEqual(r.status, 0, "\(folder): " + r.stderr + r.stdout)
            XCTAssertEqual(fx.calls().filter { $0.hasPrefix("backstop ") }, ["backstop sealed --force"], "\(folder): \(fx.calls())")
            XCTAssertTrue(r.stdout.contains("using \(fx.installedBackstop.path)"), r.stdout)
            XCTAssertTrue(r.stderr.contains("not running \(planted.path): \(unpacked.path) is not the scripts folder of a source checkout"), r.stderr)
            let verify = try XCTUnwrap(fx.calls().firstIndex(of: "codesign --verify --strict \(fx.app.path)"), "the sealed copy is verified: \(fx.calls())")
            let ran = try XCTUnwrap(fx.calls().firstIndex(of: "backstop sealed --force"))
            XCTAssertLessThan(verify, ran, "verified before it runs: \(fx.calls())")
            XCTAssertFalse(fx.exists(fx.app))
        }
    }

    /// From a zip folder, the sealed copy is the only one uninstall.sh runs.
    /// With no sealed copy in the installed app, it runs neither a planted
    /// backstop.sh beside it nor the writable copy an install before the
    /// sealed layout left in Application Support, removes nothing, and
    /// names the checkout's uninstaller (which still runs the writable copy,
    /// see testUninstallRunsTheLegacyCopyWhenNeitherCheckoutNorBundleHasOne).
    func testUninstallFromAZipRunsNoOtherCopyWhenTheBundleHasNoSealedOne() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.removeItem(at: fx.installedBackstop)
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")
        let unpacked = fx.root.appendingPathComponent("shared-tmp/Insomnia-0.1.0-macos", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fx.uninstall, to: unpacked.appendingPathComponent("uninstall.sh"))
        try fx.writeMarkerBackstop(at: unpacked.appendingPathComponent("backstop.sh"), name: "planted")

        let r = try fx.run(unpacked.appendingPathComponent("uninstall.sh"), ["--purge"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("backstop ") }, "neither the planted nor the writable copy ran: \(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("no backstop.sh sealed in \(fx.app.path)/Contents/Resources, and outside a source checkout this script runs no other copy; nothing was removed."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Run scripts/uninstall.sh from a checkout of the source"), r.stderr)
        for kept in [fx.plist, fx.sudoers, fx.app, fx.config, fx.legacyBackstop] {
            XCTAssertTrue(fx.exists(kept), kept.path)
        }
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    /// The sealed copy is covered by the bundle's resource seal; when the
    /// bundle no longer verifies (the script was edited, as the LaunchAgent
    /// would also find), uninstall does not run it and removes nothing. The
    /// checkout's copy is not verified: it is the source.
    func testUninstallRefusesTheSealedCopyWhenTheBundleFailsVerification() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.removeItem(at: fx.backstop)
        try fx.writeMarkerBackstop(at: fx.installedBackstop, name: "sealed")
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")
        fx.setMode("codesign", "verify-fails")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("codesign --verify --strict \(fx.app.path)"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("backstop ") }, "neither the unverified sealed copy nor the legacy copy ran: \(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("sealed resource"), "codesign's reason is reported: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("Nothing was removed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("checkout"), "the way out is named: \(r.stderr)")
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.config))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    /// A `codesign --verify` that never answers proves nothing about the
    /// sealed copy: uninstall stops it, runs no backstop, removes nothing,
    /// and exits instead of holding the lock while it waits.
    func testUninstallStopsAHungCodesignVerifyAndKeepsEverything() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.removeItem(at: fx.backstop)
        try fx.writeMarkerBackstop(at: fx.installedBackstop, name: "sealed")
        fx.setMode("codesign", "verify-hangs")

        let started = Date()
        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "one bounded call, not the fake's 60 s hang")
        XCTAssertTrue(r.stderr.contains("'codesign --verify --strict \(fx.app.path)' did not answer within 5s"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was removed"), r.stderr)
        XCTAssertTrue(fx.calls().contains("codesign FD9-OPEN"), "the call keeps the lock while it runs: \(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("backstop ") || $0.hasPrefix("launchctl") || $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertTrue(fx.hungProcessGone("codesign", within: 0))
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// The same hung `codesign --verify`, with every poll the script makes
    /// a quarter second slower (see slowPollingPath). The limits are read
    /// from bash's SECONDS clock, so the call is still stopped within three
    /// seconds of its 5 s limit: SIGTERM once the limit has passed, SIGKILL
    /// one to two seconds later. Limits counted in polls (100 a second) took
    /// minutes here, and up to 36 s on a loaded CI runner.
    func testUninstallStopsAHungCallOnTimeWhenEveryPollIsSlow() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.removeItem(at: fx.backstop)
        try fx.writeMarkerBackstop(at: fx.installedBackstop, name: "sealed")
        fx.setMode("codesign", "verify-hangs")

        let started = Date()
        let r = try fx.run(fx.uninstall, ["--purge"], extraEnvironment: ["PATH": try fx.slowPollingPath()])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertGreaterThan(fx.slowPolls(), 0, "the script polled through the slow sleep")
        XCTAssertGreaterThan(elapsed, 5, "the call had its whole limit")
        XCTAssertLessThan(elapsed, 15, "the 5 s limit, at most a second more, at most two of grace, and a few slow polls")
        XCTAssertTrue(r.stderr.contains("'codesign --verify --strict \(fx.app.path)' did not answer within 5s"), r.stderr)
        XCTAssertTrue(fx.hungProcessGone("codesign", within: 0))
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// install.sh and uninstall.sh make their calls through the same
    /// bounded() and supervise(), so a fix to one cannot miss the other.
    func testInstallAndUninstallShareTheBoundedCallHelper() throws {
        func helper(_ name: String) throws -> String {
            let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(name), encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: "\nbounded() {"), name)
            let supervise = try XCTUnwrap(text.range(of: "\nsupervise() {", range: start.upperBound..<text.endIndex), name)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: supervise.upperBound..<text.endIndex), name)
            return String(text[start.lowerBound..<end.upperBound])
        }
        XCTAssertEqual(try helper("install.sh"), try helper("uninstall.sh"))
    }

    // MARK: Round 28 (finding 7): the bounded-call supervisor

    /// A private run of the exact bounded() and supervise() text of
    /// install.sh or uninstall.sh (testInstallAndUninstallShareTheBoundedCallHelper
    /// keeps the two the same). `main.sh` sets the scripts' shell options,
    /// takes a lock of its own on fd 9 the way they take the recovery lock,
    /// and makes one bounded sudo call, as install.sh makes its receipt
    /// calls. It calls bounded() bare, so errexit is on in the supervisor
    /// (the scripts' callers all add `|| rc=$?` or `|| true`, which turns it
    /// off there). The fake sudo first checks, from shells that inherit its
    /// signal actions, that SIGTERM and SIGHUP would still end it, and logs
    /// "sudo SURVIVED <signal>" if not. With `logsSignals` it then logs every
    /// SIGTERM and SIGHUP it gets and keeps running; a shell started with a
    /// signal ignored cannot trap it, so a logged signal also shows that the
    /// call got the default action back. It closes its fd 9, as sudo does,
    /// and only then writes sudo.ready. It starts after the supervisor has
    /// set its own signal actions, so those are in place once it is ready.
    /// It runs until the test creates `release` and logs "sudo exiting" just
    /// before it exits. With `pidWriteFails`, a directory stands where the
    /// supervisor writes the call's pid.
    private struct SupervisedCall {
        let dir: URL
        let main: URL

        init(root: URL, script: String, callTimeout: Int, logsSignals: Bool, pidWriteFails: Bool) throws {
            let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(script), encoding: .utf8)
            guard let start = text.range(of: "\nbounded() {"),
                  let supervise = text.range(of: "\nsupervise() {", range: start.upperBound..<text.endIndex),
                  let end = text.range(of: "\n}\n", range: supervise.upperBound..<text.endIndex) else {
                throw FixtureError("no bounded() and supervise() in \(script)")
            }
            let helper = String(text[start.lowerBound..<end.upperBound])
            dir = root.appendingPathComponent("supervised-\(script)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            main = dir.appendingPathComponent("main.sh")
            let fm = FileManager.default
            try fm.createDirectory(at: dir.appendingPathComponent("work"), withIntermediateDirectories: true)
            let h = dir.path
            try #"""
            #!/bin/bash
            H="\#(h)"
            for s in TERM HUP; do /bin/bash -c "kill -$s \$\$; echo 'sudo SURVIVED $s' >> '$H/events'"; done
            if [[ \#(logsSignals ? "yes" : "no") == yes ]]; then
              trap 'echo "sudo SIGTERM" >> "$H/events"' TERM
              trap 'echo "sudo SIGHUP" >> "$H/events"' HUP
            fi
            exec 9<&-
            : > "$H/sudo.ready"
            while [[ ! -e "$H/release" && -d "$H" ]] && (( SECONDS < 60 )); do /bin/sleep 0.05; done
            echo "sudo exiting" >> "$H/events"

            """#.write(to: dir.appendingPathComponent("sudo"), atomically: true, encoding: .utf8)
            try #"""
            #!/bin/bash
            b="$(/usr/bin/mktemp "$@")" || exit 1
            if [[ \#(pidWriteFails ? "yes" : "no") == yes ]]; then /bin/mkdir "$b.pid" || exit 1; fi
            echo "$b"

            """#.write(to: dir.appendingPathComponent("mktemp"), atomically: true, encoding: .utf8)
            try #"""
            #!/bin/bash
            set -euo pipefail
            H="\#(h)"
            MKTEMP="$H/mktemp"
            SUDO="$H/sudo"
            WORK="$H/work"
            CALL_TIMEOUT_SECONDS=\#(callTimeout)
            \#(helper)
            exec 9<>"$H/lock"
            /usr/bin/lockf -t 0 9
            bounded "$SUDO" -n /usr/bin/true

            """#.write(to: main, atomically: true, encoding: .utf8)
            for name in ["sudo", "mktemp", "main.sh"] {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(name).path)
            }
            fm.createFile(atPath: dir.appendingPathComponent("lock").path, contents: nil)
        }

        var isReady: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("sudo.ready").path) }

        func events() -> [String] {
            ((try? String(contentsOf: dir.appendingPathComponent("events"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func release() {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("release").path, contents: nil)
        }

        /// The status the supervisor wrote once it had reaped the call; nil
        /// before that.
        func status() -> String? {
            let work = dir.appendingPathComponent("work")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
            guard let rc = names.first(where: { $0.hasSuffix(".rc") }) else { return nil }
            return (try? String(contentsOf: work.appendingPathComponent(rc), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Whether a directory stands where the supervisor writes the pid.
        var pidIsDirectory: Bool {
            let work = dir.appendingPathComponent("work")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
            var isDirectory: ObjCBool = false
            return names.contains { $0.hasSuffix(".pid") && FileManager.default.fileExists(atPath: work.appendingPathComponent($0).path, isDirectory: &isDirectory) && isDirectory.boolValue }
        }

        func lockIsFree() -> Bool {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-k", "-s", "-t", "0", dir.appendingPathComponent("lock").path, "/usr/bin/true"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            let exit = ProcessExit(probe)
            guard (try? probe.run()) != nil else { return false }
            exit.wait()
            return probe.terminationStatus == 0
        }
    }

    /// Releases the call and samples the lock until it is free: by then the
    /// call must have logged its end and the supervisor must have written
    /// the status it writes only after reaping the call.
    private func assertLockFreeOnlyAfterTheCallIsReaped(_ call: SupervisedCall, status: String, _ label: String,
                                                        file: StaticString = #filePath, line: UInt = #line) {
        call.release()
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline {
            if call.lockIsFree() {
                XCTAssertEqual(call.events().last, "sudo exiting", "\(label): the lock was free before the call ended", file: file, line: line)
                XCTAssertEqual(call.status(), status, "\(label): the lock was free before the supervisor reaped the call", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("\(label): the lock was not free within 10 s of the release: \(call.events())", file: file, line: line)
    }

    /// The call closes its fd 9 and keeps running through SIGTERM, the run
    /// is killed, and SIGTERM and SIGHUP then reach the run's whole process
    /// group, as launchd sends them to what is left of a job's group. The
    /// supervisor survives both, sends the call its own SIGTERM at the 3 s
    /// limit (never SIGKILL: the call is sudo), and keeps the lock until it
    /// has reaped the call. Before round 28 the group SIGTERM ended the
    /// supervisor, and the lock was free while the call still ran. The test
    /// signals only the shell it spawned as the leader of a new group, and
    /// that group, before it reaps the shell.
    func testTheBoundedCallSupervisorSurvivesGroupSignalsAndKeepsTheLockUntilItReapsTheCall() throws {
        for script in ["install.sh", "uninstall.sh"] {
            let call = try SupervisedCall(root: fx.root, script: script, callTimeout: 3, logsSignals: true, pidWriteFails: false)
            let started = Date()
            let main = try fx.spawn(call.main, ownProcessGroup: true)
            defer {
                call.release()
                main.wait()
            }
            guard waitUntil(10, { call.isReady }) else {
                _ = main.signal(SIGKILL)
                return XCTFail("\(script): the call never got ready: \(call.events())")
            }
            XCTAssertFalse(main.hasExited, script)
            XCTAssertEqual(main.signal(SIGKILL), 0, script)
            XCTAssertEqual(main.signalGroup(SIGTERM), 0, script)
            XCTAssertEqual(main.signalGroup(SIGHUP), 0, script)
            let status = main.wait()
            XCTAssertEqual(status & 0x7f, SIGKILL, "\(script): wait status \(status)")

            XCTAssertTrue(waitUntil(2) { Set(call.events()) == ["sudo SIGTERM", "sudo SIGHUP"] }, "\(script): \(call.events())")
            XCTAssertLessThan(Date().timeIntervalSince(started), 3, "\(script): both came from the group, before the supervisor's limit")
            XCTAssertFalse(call.lockIsFree(), "\(script): the run is dead and the call closed its fd 9, so only the supervisor can hold the lock")

            XCTAssertTrue(waitUntil(10) { call.events().filter { $0 == "sudo SIGTERM" }.count == 2 },
                          "\(script): the supervisor's own SIGTERM at the limit: \(call.events())")
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3, script)
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(call.events().filter { $0 == "sudo SIGTERM" }.count, 2, "\(script): one from the group, one from the supervisor: \(call.events())")
            XCTAssertEqual(call.events().filter { $0 == "sudo SIGHUP" }.count, 1, "\(script): \(call.events())")
            XCTAssertFalse(call.events().contains("sudo exiting"), "\(script): never SIGKILLed, and still running")
            XCTAssertFalse(call.lockIsFree(), "\(script): the supervisor still holds the lock for its live call")
            XCTAssertNil(call.status(), script)

            assertLockFreeOnlyAfterTheCallIsReaped(call, status: "124", script)
        }
    }

    /// The run alone is killed, with no signal to its group: the supervisor
    /// keeps the lock until it has reaped the call, also when its write of
    /// the call's pid fails. Before round 28 a failed write under errexit
    /// ended the supervisor, and the lock was free while the call ran. The
    /// call's limit (10 s) does not pass in this test.
    func testTheBoundedCallSupervisorKeepsTheLockAfterItsRunIsKilledEvenWhenAStatusWriteFails() throws {
        for (script, pidWriteFails) in [("install.sh", false), ("install.sh", true), ("uninstall.sh", true)] {
            let label = "\(script) pidWriteFails \(pidWriteFails)"
            let call = try SupervisedCall(root: fx.root, script: script, callTimeout: 10, logsSignals: true, pidWriteFails: pidWriteFails)
            let main = try fx.spawn(call.main, ownProcessGroup: true)
            defer {
                call.release()
                main.wait()
            }
            guard waitUntil(10, { call.isReady }) else {
                _ = main.signal(SIGKILL)
                return XCTFail("\(label): the call never got ready: \(call.events())")
            }
            XCTAssertEqual(main.signal(SIGKILL), 0, label)
            let status = main.wait()
            XCTAssertEqual(status & 0x7f, SIGKILL, "\(label): wait status \(status)")
            XCTAssertEqual(call.pidIsDirectory, pidWriteFails, label)

            XCTAssertFalse(waitUntil(1) { call.lockIsFree() }, "\(label): the lock was free while the call ran")
            XCTAssertEqual(call.events(), [], "\(label): no signal reached the call")
            XCTAssertNil(call.status(), label)

            assertLockFreeOnlyAfterTheCallIsReaped(call, status: "0", label)
        }
    }

    /// The call does not inherit the supervisor's ignored SIGTERM and
    /// SIGHUP: shells it starts are ended by both, and a call that does not
    /// catch SIGTERM is stopped by the supervisor's at its 1 s limit. The
    /// run gets 124, and the lock is free once the call has been reaped.
    func testTheBoundedCallGetsTheDefaultSignalActionsAndIsStoppedAtItsLimit() throws {
        let call = try SupervisedCall(root: fx.root, script: "install.sh", callTimeout: 1, logsSignals: false, pidWriteFails: false)
        let started = Date()
        let main = try fx.spawn(call.main)
        defer {
            call.release()
            main.wait()
        }
        XCTAssertTrue(waitUntil(10) { call.isReady }, "\(call.events())")
        XCTAssertTrue(waitUntil(10) { main.hasExited }, "\(call.events())")
        let status = main.wait()
        XCTAssertEqual(status & 0x7f, 0, "exited, not signalled: wait status \(status)")
        XCTAssertEqual((status >> 8) & 0xff, 124, "bounded() returned 124: wait status \(status)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 7, "the 1 s limit, at most a second more, and the run's wait")
        XCTAssertEqual(call.events(), [], "no shell survived its signal, and SIGTERM ended the call before its own end")
        XCTAssertEqual(call.status(), "124")
        XCTAssertTrue(call.lockIsFree())
    }

    /// An uninstall killed while its `launchctl bootout` does not answer:
    /// the bootout keeps the recovery lock until its supervisor has stopped
    /// it at the limit, so it cannot unload an agent the app loads and
    /// confirms once it can take the lock.
    func testAKilledUninstallKeepsTheLockUntilItsBootoutIsStopped() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "bootout-hangs")

        let pid = try killDuringHungBootout(fx.uninstall)

        try assertLockHeldUntilGone(pid, within: 20)
        XCTAssertTrue(fx.calls().contains("launchctl FD9-OPEN"), "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.plist), "nothing was removed: the run was killed before")
    }

    func testUninstallRunsTheLegacyCopyWhenNeitherCheckoutNorBundleHasOne() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.removeItem(at: fx.backstop)
        try FileManager.default.removeItem(at: fx.installedBackstop)
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("backstop ") }, ["backstop legacy --force"], "\(fx.calls())")
        XCTAssertTrue(r.stdout.contains("using \(fx.legacyBackstop.path)"), r.stdout)
        XCTAssertFalse(fx.exists(fx.legacyBackstop))
    }

    func testUninstallStopsBeforeRemovingAnythingWhenNoBackstopExists() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.removeItem(at: fx.backstop)
        try FileManager.default.removeItem(at: fx.installedBackstop)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("no backstop.sh found"), r.stderr)
        XCTAssertTrue(r.stderr.contains(fx.installedBackstop.deletingLastPathComponent().path), "every place looked is named: \(r.stderr)")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.config))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    func testUninstallPurgeKeepsADirectoryNamedLikeARotatedLogAndFinishes() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let rotatedDir = fx.home.appendingPathComponent("Logs/insomnia.log.1", isDirectory: true)
        try FileManager.default.createDirectory(at: rotatedDir, withIntermediateDirectories: true)
        try "theirs".write(to: rotatedDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "older lines\n".write(to: fx.home.appendingPathComponent("Logs/handoffs.log.1"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Left \(rotatedDir.path): it is not a regular file, so Insomnia did not write it."), r.stdout)
        XCTAssertTrue(r.stdout.hasSuffix("Done.\n"), r.stdout)
        XCTAssertTrue(fx.exists(rotatedDir.appendingPathComponent("a.txt")))
        for gone in [fx.state, fx.config, fx.logFile, fx.home.appendingPathComponent("Logs/handoffs.log.1")] {
            XCTAssertFalse(fx.exists(gone), gone.path)
        }
    }

    // MARK: Round 28 (finding 8): a journal read that fails is not a clean journal

    /// Points `script`'s PLUTIL at a wrapper around the real plutil. The
    /// `call`th call whose arguments, joined by spaces, match the bash
    /// pattern `trigger` runs `action` instead of going straight on, with
    /// $f set to the file plutil was given (its last argument). The action
    /// can end the call (`exit 1`), or run the real plutil itself first.
    /// Each time it runs, the call's arguments are added to plutil.fired.
    private func wrapPlutil(in script: URL, of f: ScriptFixture, on trigger: String, call: Int = 1, _ action: String) throws {
        let tag = UUID().uuidString.prefix(8)
        let wrapper = f.bin.appendingPathComponent("plutil-\(tag)")
        let counter = f.root.appendingPathComponent("plutil.count.\(tag)")
        try """
        #!/bin/bash
        f="${!#}"
        if [[ "$*" == \(trigger) ]]; then
          n=0
          if [[ -f '\(counter.path)' ]]; then read -r n < '\(counter.path)'; fi
          n=$((n + 1))
          echo "$n" > '\(counter.path)'
          if (( n == \(call) )); then
            echo "$*" >> '\(f.root.path)/plutil.fired'
            \(action)
          fi
        fi
        exec /usr/bin/plutil "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        try ScriptFixture.patch(text, ["PLUTIL": wrapper.path]).write(to: script, atomically: true, encoding: .utf8)
    }

    /// Points `script`'s HEAD at a wrapper around the fixture's head. While
    /// head.fail holds a bash pattern that a call's arguments, joined by
    /// spaces, match, that call prints what head prints and then exits 3,
    /// the way a read that fails after printing part or all of a file does.
    private func wrapHead(in script: URL, of f: ScriptFixture) throws {
        let wrapper = f.bin.appendingPathComponent("head-fails")
        let fail = f.root.appendingPathComponent("head.fail").path
        try """
        #!/bin/bash
        p=""; if [[ -f '\(fail)' ]]; then IFS= read -r p < '\(fail)' || true; fi
        if [[ -n "$p" && "$*" == $p ]]; then '\(f.bin.path)/head' "$@"; exit 3; fi
        exec '\(f.bin.path)/head' "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        try ScriptFixture.patch(text, ["HEAD": wrapper.path]).write(to: script, atomically: true, encoding: .utf8)
    }

    /// The calls the wrapper acted on.
    private func plutilFired(_ f: ScriptFixture) -> [String] {
        ((try? String(contentsOf: f.root.appendingPathComponent("plutil.fired"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Runs the real plutil, then takes every permission off the file it
    /// read: this read works and the next read of that file does not.
    private static let readThenLock = #"/usr/bin/plutil "$@"; rc=$?; /bin/chmod 000 "$f"; exit $rc"#

    /// The file step 4 reads: the copy of state.json in the run's scratch
    /// folder (read.state.json). The pattern also matches state.json itself,
    /// so the same schedule applies to a script that reads the journal in
    /// place, as the reviewed one did; this script reads no state.json in
    /// place with these arguments before step 4.
    private static let journalRead = "state.json"

    /// Prints part of an answer, then fails the way an I/O error would.
    private static func failAfterPrinting(_ partial: String) -> String {
        #"printf '%s' '\#(partial)'; echo 'simulated read error' >&2; exit 1"#
    }

    /// What uninstall leaves when it stops before removing anything.
    private func assertNothingRemoved(_ f: ScriptFixture, state json: String?, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for kept in [f.plist, f.sudoers, f.app, f.config, f.installedBackstop] {
            XCTAssertTrue(f.exists(kept), "\(label): \(kept.path)", file: file, line: line)
        }
        if let json {
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json, label, file: file, line: line)
        }
        XCTAssertFalse(f.calls().contains { $0.hasPrefix("launchctl bootout") || $0.hasPrefix("sudo") }, "\(label): \(f.calls())", file: file, line: line)
    }

    /// The schedule of the review's probe: the copy of the journal that
    /// step 4 reads loses its permissions after the type reads of the shape
    /// check and before its text is read for the kept display records. The
    /// text read fails, so what the journal holds is unknown: uninstall
    /// stops with the kept brightness and everything else in place, where
    /// before it printed "journal clean", found no kept brightness and
    /// removed state.json.
    func testUninstallStopsWhenItsCopyOfTheJournalCannotBeReadForTheKeptRecords() throws {
        for purge in [true, false] {
            let label = "purge \(purge)"
            let json = Self.keptDisplayJournal("", ours: false)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeState(json)
            try wrapPlutil(in: f.uninstall, of: f, on: #""-type keptDisplayUnderLowPowerBoot -o - "*"# + Self.journalRead, Self.readThenLock)

            let r = try f.run(f.uninstall, purge ? ["--purge"] : [])

            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertEqual(plutilFired(f).count, 1, label)
            XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything: \(f.state.path) could not be read"), "\(label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("state.json could not be read whole"), "\(label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("its text could not be read for the kept display records"), "\(label): \(r.stderr)")
            XCTAssertFalse(r.stdout.contains("journal clean"), "\(label): \(r.stdout)")
            try assertNothingRemoved(f, state: json, label)
        }
    }

    /// A read that fails after the shape check, in the journal check or in
    /// the list of kept brightness, with part of an answer printed or none:
    /// uninstall stops and names the failed read. Each of these reads, when
    /// it works, is part of a clean run (the control below).
    func testUninstallStopsWhenAnyLaterReadOfTheJournalFails() throws {
        let cases: [(label: String, args: String, call: Int, action: String, names: String)] = [
            ("the refusal flag, part printed", "-extract displayRestoreRefused raw -o -", 1, Self.failAfterPrinting("tr"),
             "displayRestoreRefused: plutil -extract exited 1 (simulated read error)"),
            ("the kept level, second read", "-extract savedDisplayBrightness raw -o -", 2, Self.failAfterPrinting("0."),
             "savedDisplayBrightness: plutil -extract exited 1 (simulated read error)"),
            ("an optional record's type", "-type keptDisplayReadLit -o -", 1, Self.failAfterPrinting(""),
             "keptDisplayReadLit: plutil -type exited 1 (simulated read error)"),
            ("the JSON for the shape check", "-convert json -o -", 1, Self.failAfterPrinting("{"),
             "plutil -convert json failed"),
            ("the copy made unreadable at the refusal flag", "-extract displayRestoreRefused raw -o -", 1, Self.readThenLock,
             "savedKeyboardBrightness: plutil -extract exited 1"),
        ]
        for c in cases {
            let json = Self.keptDisplayJournal("", ours: false)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeState(json)
            try wrapPlutil(in: f.uninstall, of: f, on: "\"\(c.args) \"*" + Self.journalRead, call: c.call, c.action)

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertNotEqual(r.status, 0, c.label)
            XCTAssertEqual(plutilFired(f).count, 1, c.label)
            XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything: \(f.state.path) could not be read"), "\(c.label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains(c.names), "\(c.label): \(r.stderr)")
            XCTAssertFalse(r.stdout.contains("journal clean"), "\(c.label): \(r.stdout)")
            XCTAssertFalse(r.stdout.contains("display brightness"), "\(c.label): \(r.stdout)")
            try assertNothingRemoved(f, state: json, c.label)
        }
    }

    /// Two kept levels, the first read and the second failing: one found
    /// is not all found, and nothing is removed.
    func testUninstallStopsWhenOnlyOneOfTwoKeptLevelsCanBeRead() throws {
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6,"displayRestoreRefused":true,"savedKeyboardBrightness":0.4,"keyboardRestoreRefused":true}"#
        try fx.installMachinery()
        try fx.writeState(json)
        try wrapPlutil(in: fx.uninstall, of: fx, on: #""-extract savedKeyboardBrightness raw -o - "*"# + Self.journalRead, call: 2, Self.failAfterPrinting("0.4"))

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(plutilFired(fx).count, 1)
        XCTAssertTrue(r.stderr.contains("savedKeyboardBrightness: plutil -extract exited 1 (simulated read error)"), r.stderr)
        XCTAssertFalse(r.stdout.contains("journal clean"), r.stdout)
        XCTAssertFalse(r.stdout.contains("display brightness 0.6"), r.stdout)
        try assertNothingRemoved(fx, state: json, "keyboard")
    }

    /// Keys that hold null or are not there are absent, as for the app,
    /// through the real plutil's own errors for them: the run completes,
    /// removing state.json, or keeping it for a kept level.
    func testUninstallReadsNullAndMissingKeysAsAbsentAndCompletes() throws {
        let nulls = #""lowPowerSetByUs":null,"savedOutputVolume":null,"savedMuted":null,"savedKeyboardBrightness":null,"frozenPids":null,"appNapOverrides":null,"savedAudioOutputs":null,"keyboardRestoreRefused":null,"displayRestoredUnderLowPower":null,"keptDisplayUnderLowPower":null,"keptDisplayUnderLowPowerBoot":null,"keptDisplayReadLit":null"#
        let cases: [(json: String, kept: String?)] = [
            (#"{"sleepDisabledByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":null,"displayRestoreRefused":null,"# + nulls + "}", nil),
            (#"{"sleepDisabledByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.8,"displayRestoreRefused":true,"# + nulls + "}", "  - display brightness 0.8"),
            (#"{"sleepDisabledByUs":false}"#, nil),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(c.json)

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertEqual(r.status, 0, c.json + r.stderr + r.stdout)
            XCTAssertTrue(r.stdout.contains("journal clean"), r.stdout)
            XCTAssertFalse(f.exists(f.app), c.json)
            if let kept = c.kept {
                XCTAssertTrue(r.stdout.contains(kept), r.stdout)
                XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), c.json)
            } else {
                XCTAssertFalse(f.exists(f.state), c.json)
            }
        }
    }

    /// Points `script`'s PERL, which makes the private copies, at a
    /// wrapper. A copy whose destination matches the bash pattern
    /// `trigger` runs `action` first, with $src set to the file being
    /// copied; the action can end the copy (`exit 2`) or let it go on. Each
    /// time it runs, "fired" is added to perl.fired. The wrapper runs under
    /// `env -i`, as the copy does, so the action names its tools by path.
    private func wrapPerl(in script: URL, of f: ScriptFixture, on trigger: String, _ action: String) throws {
        let wrapper = f.bin.appendingPathComponent("perl-\(UUID().uuidString.prefix(8))")
        try """
        #!/bin/bash
        src="${@: -2:1}"
        if [[ "${!#}" == \(trigger) ]]; then
          echo fired >> '\(f.root.path)/perl.fired'
          \(action)
        fi
        exec /usr/bin/perl "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        try ScriptFixture.patch(text, ["PERL": wrapper.path]).write(to: script, atomically: true, encoding: .utf8)
    }

    /// state.json is a regular file at the check, then a FIFO with no
    /// writer by the time it is copied: the copy opens it without blocking
    /// and refuses anything but a regular file, so the run does not hang
    /// with the recovery lock held. It stops, and the FIFO stays.
    func testUninstallStopsWhenTheJournalBecomesAFifoBeforeItIsCopied() throws {
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.installMachinery()
        try fx.writeState(json)
        try wrapPerl(in: fx.uninstall, of: fx, on: "*/insomnia-uninstall.*/read.state.json", #"/bin/rm -f "$src" && /usr/bin/mkfifo "$src""#)

        // Awake time, not wall-clock time: the Mac can sleep during a run.
        let started = ProcessInfo.processInfo.systemUptime
        let r = try fx.run(fx.uninstall, ["--purge"])
        let took = ProcessInfo.processInfo.systemUptime - started

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(try String(contentsOf: fx.root.appendingPathComponent("perl.fired"), encoding: .utf8), "fired\n")
        XCTAssertTrue(r.stderr.contains("state.json is not a regular file, so it was not read"), r.stderr)
        XCTAssertLessThan(took, 30, "nothing waits for a writer")
        var info = stat()
        XCTAssertEqual(lstat(fx.state.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO, "the FIFO is left where it is")
        try assertNothingRemoved(fx, state: nil, "fifo")
    }

    /// state.json changes, or appears, after the journal check and before
    /// it would be removed (here, as the LaunchAgent is booted out): the
    /// file is left, named, and the run exits 1. The rest is removed, as
    /// the journal that was checked allowed.
    func testUninstallLeavesAJournalThatChangedOrAppearedAfterItsCheck() throws {
        let checked = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        let later = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        for appears in [false, true] {
            let label = appears ? "appeared" : "changed"
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            if !appears { try f.writeState(checked) }
            let wrapper = f.bin.appendingPathComponent("launchctl-writes-state")
            try """
            #!/bin/bash
            if [[ "$1" == bootout ]]; then printf '%s' '\(later)' > '\(f.state.path)'; fi
            exec '\(f.bin.appendingPathComponent("launchctl").path)' "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            let text = try String(contentsOf: f.uninstall, encoding: .utf8)
            try ScriptFixture.patch(text, ["LAUNCHCTL": wrapper.path]).write(to: f.uninstall, atomically: true, encoding: .utf8)

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertEqual(r.status, 1, "\(label): \(r.stderr)")
            XCTAssertTrue(r.stdout.contains("journal clean"), "\(label): \(r.stdout)")
            XCTAssertFalse(f.exists(f.app), label)
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), later, label)
            let why = appears ? "it appeared after the journal check" : "it is not the file the journal check read (cmp exit 1)"
            XCTAssertTrue(r.stderr.contains("Left \(f.state.path): \(why)"), "\(label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("Done, except 1 file(s) that could not be removed"), "\(label): \(r.stderr)")
        }
    }

    /// The settlement's own reads, all of its private copy of the journal:
    /// one that fails stops the uninstall before the backstop, with the
    /// start, its claim, its marker and its session in place, and no pmset.
    func testUninstallStopsWhenAReadForTheSettlementFails() throws {
        let nonce = try journalUnfinishedStart()
        let json = try String(contentsOf: fx.state, encoding: .utf8)
        try fx.installMachinery()
        try wrapPlutil(in: fx.uninstall, of: fx, on: #""-extract sleepOffAttempt.receipt raw -o - "*/insomnia-uninstall.*/read.settle.json"#, Self.failAfterPrinting(""))

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(plutilFired(fx).count, 1)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything: \(fx.state.path) could not be read whole (sleepOffAttempt.receipt: plutil -extract exited 1 (simulated read error))"), r.stderr)
        XCTAssertEqual(fx.release(), "\(nonce) held\n")
        XCTAssertTrue(fx.exists(fx.session))
        try assertNothingRemoved(fx, state: json, "settlement")
    }

    /// Round 30 (finding 7): the settlement's copy of the journal fails
    /// (it changed while it was read), or its read of the start's
    /// session.json does, as a copy or as a read of that copy: whether that
    /// session is the start's is unknown, so it is not removed, and the
    /// uninstall stops with the start, its claim and its session in place
    /// and no pmset.
    func testUninstallStopsWhenTheSettlementCannotReadTheJournalOrTheSession() throws {
        let changed = #"echo "it changed while it was read" >&2; exit 2"#
        // The expected text names each case's own fixture's paths.
        let cases: [(label: String, perl: String?, plutil: String?, saying: (ScriptFixture) -> String)] = [
            ("journal copy", "*/insomnia-uninstall.*/read.settle.json", nil,
             { "Uninstall stopped BEFORE removing anything: \($0.state.path) could not be read whole (it changed while it was read)" }),
            ("session copy", "*/insomnia-uninstall.*/read.settle-session.json", nil,
             { "The unfinished start is still journaled: \($0.session.path) could not be read (it changed while it was read), so whether it is that start's session is unknown." }),
            ("session read", nil, #""-extract endsAt raw -o - "*/insomnia-uninstall.*/read.settle-session.json"#,
             { "The unfinished start is still journaled: \($0.session.path) could not be read (endsAt: plutil -extract exited 1 (simulated read error)), so whether it is that start's session is unknown." }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            let previous = fx
            fx = f
            defer { fx = previous }
            let nonce = try journalUnfinishedStart()
            let json = try String(contentsOf: f.state, encoding: .utf8)
            let session = try Data(contentsOf: f.session)
            try f.installMachinery()
            if let perl = c.perl { try wrapPerl(in: f.uninstall, of: f, on: perl, changed) }
            if let plutil = c.plutil { try wrapPlutil(in: f.uninstall, of: f, on: plutil, Self.failAfterPrinting("")) }

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertEqual(r.status, 1, "\(c.label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains(c.saying(f)), "\(c.label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("Nothing was removed and no pmset ran"), "\(c.label): \(r.stderr)")
            XCTAssertEqual(f.release(), "\(nonce) held\n", c.label)
            XCTAssertEqual(try Data(contentsOf: f.session), session, c.label)
            try assertNothingRemoved(f, state: json, c.label)
        }
    }

    /// record_text_problems as it is in `script`, run on its own the way
    /// its callers run it: its status and what it printed.
    private func recordTextStatus(_ script: String, _ path: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let f = try ScriptFixture()
        defer { f.destroy() }
        let runner = f.root.appendingPathComponent("record-text-status.sh")
        try ("set -euo pipefail\nCAT=/bin/cat\nSTAT=/usr/bin/stat\n" + Self.recordTextProblemsSource(script) + "\nrecord_text_problems \"$1\" || exit $?\n")
            .write(to: runner, atomically: true, encoding: .utf8)
        return try f.run(runner, [path])
    }

    /// A file the reader cannot open, and a folder, return 2 with nothing
    /// printed in both scripts, where they returned 0 as a file with no
    /// records.
    func testTheRecordReaderReturnsTwoForWhatItCannotRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("record-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let locked = dir.appendingPathComponent("locked.json")
        try Self.keptDisplayJournal(#""keptDisplayReadLit":1e-400"#).write(to: locked, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o600) }
        let folder = dir.appendingPathComponent("folder.json", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for script in ["backstop.sh", "uninstall.sh"] {
            for path in [locked.path, folder.path] {
                let r = try recordTextStatus(script, path)
                XCTAssertEqual(r.status, 2, "\(script) \(path): \(r.stderr)")
                XCTAssertEqual(r.stdout, "", "\(script) \(path)")
                if path == locked.path { XCTAssertTrue(r.stderr.contains("Permission denied"), "\(script): \(r.stderr)") }
            }
        }
    }

    /// The backstop's journal read, with the text read of its copy of the
    /// journal failing after the type reads passed (the same schedule as
    /// above): the journal is unknown, not clean. Nothing is undone, the
    /// expired session stays, and the run exits 1, where before it found
    /// the journal clean and removed the session. The same in its
    /// settlement, before the start it journals is settled.
    func testTheBackstopTreatsAJournalItCannotReadWholeAsUnknown() throws {
        for settling in [false, true] {
            let label = settling ? "settlement" : "journal read"
            let f = try ScriptFixture()
            defer { f.destroy() }
            let previous = fx
            fx = f
            defer { fx = previous }
            if settling {
                try journalUnfinishedStart()
            } else {
                try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
                try f.writeState(Self.keptDisplayJournal(""))
            }
            let json = try String(contentsOf: f.state, encoding: .utf8)
            let session = try Data(contentsOf: f.session)
            try wrapPlutil(in: f.backstop, of: f, on: "\"-type keptDisplayUnderLowPowerBoot -o - \"*/.backstop-read.*/state.json", Self.readThenLock)

            let r = try f.run(f.backstop)

            XCTAssertEqual(r.status, 1, "\(label): \(r.stderr)")
            XCTAssertEqual(plutilFired(f).count, 1, label)
            XCTAssertEqual(f.calls(), [], label)
            XCTAssertEqual(chmod(f.state.path, 0o644), 0)
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json, label)
            XCTAssertEqual(try Data(contentsOf: f.session), session, label)
            let logged = settling
                ? "could not be read whole (its JSON, or its text for the kept display records), so the unfinished start it journals was not settled; nothing undone"
                : "could not be read whole (its JSON, or its text for the kept display records); nothing undone, evidence kept"
            XCTAssertTrue(f.log().contains(logged), "\(label): \(f.log())")
            XCTAssertFalse(f.log().contains("journal already clean"), "\(label): \(f.log())")
        }
    }

    // MARK: Round 30 (F7/F8): a later read that fails undoes nothing more

    /// Fails the way an I/O error would, with nothing printed.
    private static let readFails = #"echo 'simulated read error' >&2; exit 1"#

    /// The pattern of a plutil call with `arguments` on the backstop's
    /// private copy of `file` (copy_private).
    private static func onCopy(_ arguments: String, of file: String = "state.json") -> String {
        "\"\(arguments) -o - \"*/.backstop-read.*/\(file)"
    }

    /// Runs the backstop with the read `trigger` (its `call`th match)
    /// failing, in a fixture `setUp` prepares. Returns the run, with the
    /// journal and session bytes from before it.
    private func runBackstop(failing trigger: String?, call: Int = 1, _ setUp: (ScriptFixture) throws -> Void) throws -> (f: ScriptFixture, r: (status: Int32, stdout: String, stderr: String), journal: Data?, session: Data?) {
        let f = try ScriptFixture()
        try setUp(f)
        let journal = try? Data(contentsOf: f.state)
        let session = try? Data(contentsOf: f.session)
        if let trigger {
            try wrapPlutil(in: f.backstop, of: f, on: trigger, call: call, Self.readFails)
        }
        return (f, try f.run(f.backstop), journal, session)
    }

    /// The review's first pair (round 29): an entry journaled in an earlier
    /// boot and a second, from this boot, that ps cannot observe. The
    /// control clears the first without a signal and keeps the second, still
    /// owed, with the kept brightness and both kinds of saved audio as they
    /// were. Each read of the second entry failing in turn (its type in the
    /// shape check, the count, its boot, the read back of the kept entry)
    /// now ends the run with both files as they were and no signal, where
    /// before the failed count dropped the owed entry.
    func testBackstopKeepsTheOwedFrozenEntryWhenALaterReadOfItFails() throws {
        func setUp(_ f: ScriptFixture) throws {
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState("""
            {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,"savedOutputVolume":0.5,"savedMuted":true,
             "savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.6,"muted":false}],"savedDisplayBrightness":0.8,"displayRestoreRefused":true,
             "frozenProcesses":[{"pid":12345,"startedAt":1,"bootSession":"old-boot"},{"pid":12346,"startedAt":2,"bootSession":"\(f.bootUUID)"}]}
            """)
            f.setMode("ps", "fail")
        }
        let control = try runBackstop(failing: nil, setUp)
        defer { control.f.destroy() }
        XCTAssertEqual(control.r.status, 1, control.r.stderr + control.f.log())
        XCTAssertFalse(control.f.calls().contains { $0.hasPrefix("kill") }, "\(control.f.calls())")
        XCTAssertTrue(control.f.calls().contains("ps -o lstart=,stat=,uid= -p 12346"), "\(control.f.calls())")
        let after = try control.f.stateJSON()
        let frozen = try XCTUnwrap(after["frozenProcesses"] as? [[String: Any]])
        XCTAssertEqual(frozen.count, 1, "the earlier boot's entry goes, the owed one stays")
        XCTAssertEqual(frozen.first?["pid"] as? Int, 12346)
        XCTAssertEqual(frozen.first?["bootSession"] as? String, control.f.bootUUID)
        XCTAssertEqual(after["dockerFrozen"] as? Bool, true)
        XCTAssertEqual(after["savedOutputVolume"] as? Double, 0.5)
        XCTAssertEqual(after["savedMuted"] as? Bool, true)
        XCTAssertEqual((after["savedAudioOutputs"] as? [[String: Any]])?.first?["deviceUID"] as? String, "usb-headset")
        XCTAssertEqual(after["savedDisplayBrightness"] as? Double, 0.8)
        XCTAssertEqual(after["displayRestoreRefused"] as? Bool, true)

        let faults: [(trigger: String, call: Int, says: String)] = [
            (Self.onCopy("-type frozenProcesses.1"), 1, "could not be read whole (its JSON, or its text for the kept display records); nothing undone, evidence kept"),
            (Self.onCopy("-type frozenProcesses.1"), 2, "frozenProcesses.1: plutil -type exited 1 (simulated read error); nothing more undone this run, the journal is kept as it was"),
            (Self.onCopy("-extract frozenProcesses.1.bootSession raw"), 1, "frozenProcesses.1.bootSession: plutil -extract exited 1 (simulated read error); nothing more undone this run"),
            (Self.onCopy("-extract frozenProcesses.1 json"), 1, "frozenProcesses.1: plutil -extract exited 1 (simulated read error); nothing more undone this run"),
        ]
        for fault in faults {
            let label = "\(fault.trigger) #\(fault.call)"
            let run = try runBackstop(failing: fault.trigger, call: fault.call, setUp)
            defer { run.f.destroy() }
            XCTAssertEqual(run.r.status, 1, "\(label): \(run.r.stderr)")
            XCTAssertEqual(plutilFired(run.f).count, 1, label)
            XCTAssertEqual(try Data(contentsOf: run.f.state), run.journal, "\(label): the journal is as it was")
            XCTAssertEqual(try Data(contentsOf: run.f.session), run.session, label)
            XCTAssertFalse(run.f.calls().contains { $0.hasPrefix("kill") }, "\(label): \(run.f.calls())")
            XCTAssertTrue(run.f.log().contains(fault.says), "\(label): \(run.f.log())")
            XCTAssertFalse(run.f.log().contains("journal cleared"), label)
        }
    }

    /// The review's second pair: an App Nap entry that recorded the key as
    /// true. The control writes true back and clears the entry; a null, as
    /// the app's decoder reads it, is still a key that was absent, and is
    /// deleted. A failed read of what the entry recorded, or of its bundle,
    /// now writes and deletes nothing and keeps the journal, where before
    /// the failed read was taken for an absent key and the key was deleted.
    func testBackstopPutsNoAppNapKeyBackOnAReadThatFailed() throws {
        func setUp(previous: String) -> (ScriptFixture) throws -> Void {
            { f in
                try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
                try f.defaultsTable([("com.example.agent", "1")])
                try f.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.6,"muted":false}],"savedDisplayBrightness":0.8,"displayRestoreRefused":true,"appNapOverrides":[{"bundleId":"com.example.agent","previous":\#(previous)}]}"#)
            }
        }
        for (previous, undo) in [("true", "defaults write com.example.agent NSAppSleepDisabled -bool true"), ("null", "defaults delete com.example.agent NSAppSleepDisabled")] {
            let control = try runBackstop(failing: nil, setUp(previous: previous))
            defer { control.f.destroy() }
            XCTAssertEqual(control.r.status, 0, "\(previous): \(control.r.stderr) \(control.f.log())")
            XCTAssertEqual(control.f.calls().filter { $0.hasPrefix("defaults") }, [undo], previous)
            XCTAssertEqual(control.f.defaultsValues(), previous == "true" ? ["com.example.agent": "1"] : [:], previous)
            let after = try control.f.stateJSON()
            XCTAssertEqual((after["appNapOverrides"] as? [Any])?.count, 0, previous)
            XCTAssertEqual((after["savedAudioOutputs"] as? [[String: Any]])?.first?["deviceUID"] as? String, "usb-headset", previous)
            XCTAssertEqual(after["savedDisplayBrightness"] as? Double, 0.8, previous)
            XCTAssertEqual(after["displayRestoreRefused"] as? Bool, true, previous)
        }

        let faults: [(trigger: String, says: String)] = [
            (Self.onCopy("-type appNapOverrides.0.previous"), "could not be read whole (its JSON, or its text for the kept display records); nothing undone, evidence kept"),
            (Self.onCopy("-extract appNapOverrides.0.previous raw"), "appNapOverrides.0.previous: plutil -extract exited 1 (simulated read error); nothing more undone this run"),
            (Self.onCopy("-extract appNapOverrides.0.bundleId raw"), "appNapOverrides.0.bundleId: plutil -extract exited 1 (simulated read error); nothing more undone this run"),
        ]
        for fault in faults {
            let run = try runBackstop(failing: fault.trigger, setUp(previous: "true"))
            defer { run.f.destroy() }
            XCTAssertEqual(run.r.status, 1, "\(fault.trigger): \(run.r.stderr)")
            XCTAssertEqual(plutilFired(run.f).count, 1, fault.trigger)
            XCTAssertEqual(run.f.calls().filter { $0.hasPrefix("defaults") }, [], fault.trigger)
            XCTAssertEqual(run.f.defaultsValues(), ["com.example.agent": "1"], fault.trigger)
            XCTAssertEqual(try Data(contentsOf: run.f.state), run.journal, "\(fault.trigger): the journal is as it was")
            XCTAssertTrue(run.f.log().contains(fault.says), "\(fault.trigger): \(run.f.log())")
        }
    }

    /// The review's third pair: Low Power Mode ours over a kept display
    /// entry recorded in an earlier boot. The control publishes this boot
    /// for the record, then switches the mode off (#43). A failed read of
    /// the record, in the shape check, of its type before the switch or of
    /// its boot, now leaves the mode on and the journal as it was, where
    /// before the failed type read switched the mode off with the earlier
    /// boot still on disk. Sleep, restored before the mode, is restored
    /// again by the next run, which finds it still journaled.
    func testBackstopLeavesLowPowerModeOnWhenAReadOfTheKeptRecordFails() throws {
        let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A","keptDisplayReadLit":0.8"#)
        func setUp(_ f: ScriptFixture) throws {
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)
        }
        let control = try runBackstop(failing: nil, setUp)
        defer { control.f.destroy() }
        XCTAssertEqual(control.r.status, 0, control.r.stderr + control.f.log())
        XCTAssertEqual(control.f.calls(), ["sudo -n \(control.f.fakePmset) -a disablesleep 0", "sudo -n \(control.f.fakePmset) -b lowpowermode 0"])
        XCTAssertEqual(try control.f.stateJSON()["keptDisplayUnderLowPowerBoot"] as? String, control.f.bootUUID)
        XCTAssertTrue(control.f.log().contains("kept display entry's record given this boot"), control.f.log())

        let faults: [(trigger: String, call: Int, sleepFirst: Bool, says: String)] = [
            (Self.onCopy("-type keptDisplayUnderLowPower"), 1, false, "could not be read whole (its JSON, or its text for the kept display records); nothing undone, evidence kept"),
            (Self.onCopy("-type keptDisplayUnderLowPower"), 2, true, "keptDisplayUnderLowPower: plutil -type exited 1 (simulated read error); Low Power Mode left on and nothing more undone this run"),
            (Self.onCopy("-extract keptDisplayUnderLowPowerBoot raw"), 1, true, "keptDisplayUnderLowPowerBoot: plutil -extract exited 1 (simulated read error); Low Power Mode left on and nothing more undone this run"),
        ]
        for fault in faults {
            let label = "\(fault.trigger) #\(fault.call)"
            let run = try runBackstop(failing: fault.trigger, call: fault.call, setUp)
            defer { run.f.destroy() }
            XCTAssertEqual(run.r.status, 1, "\(label): \(run.r.stderr)")
            XCTAssertEqual(plutilFired(run.f).count, 1, label)
            XCTAssertEqual(run.f.calls(), fault.sleepFirst ? ["sudo -n \(run.f.fakePmset) -a disablesleep 0"] : [], label)
            XCTAssertEqual(try String(contentsOf: run.f.state, encoding: .utf8), json, "\(label): the earlier boot and the kept brightness stay")
            XCTAssertTrue(run.f.log().contains(fault.says), "\(label): \(run.f.log())")
        }
    }

    /// A session whose end cannot be read is not an expired one. The
    /// control leaves a dirty journal alone while its session runs. A read
    /// of the session's end that fails, in the shape check or in the
    /// decision, or of its type, now undoes nothing and keeps both files,
    /// where before the empty read made the session expired and the run
    /// ended it.
    func testBackstopEndsNoSessionWhoseEndItCouldNotRead() throws {
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        func setUp(_ f: ScriptFixture) throws {
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
            try f.writeState(dirty)
        }
        let control = try runBackstop(failing: nil, setUp)
        defer { control.f.destroy() }
        XCTAssertEqual(control.r.status, 0, control.r.stderr)
        XCTAssertEqual(control.f.calls(), [])
        XCTAssertEqual(try Data(contentsOf: control.f.state), control.journal)
        XCTAssertTrue(control.f.exists(control.f.session))

        let faults: [(trigger: String, call: Int, says: String)] = [
            (Self.onCopy("-type endsAt", of: "session.json"), 1, "could not be read (endsAt: plutil -type exited 1 (simulated read error)); nothing undone, evidence kept, will retry"),
            (Self.onCopy("-extract endsAt raw", of: "session.json"), 1, "could not be read (endsAt: plutil -extract exited 1 (simulated read error)); nothing undone, evidence kept, will retry"),
            (Self.onCopy("-extract endsAt raw", of: "session.json"), 2, "its endsAt could not be read again (endsAt: plutil -extract exited 1 (simulated read error)); nothing undone, evidence kept, will retry"),
        ]
        for fault in faults {
            let label = "\(fault.trigger) #\(fault.call)"
            let run = try runBackstop(failing: fault.trigger, call: fault.call, setUp)
            defer { run.f.destroy() }
            XCTAssertEqual(run.r.status, 1, "\(label): \(run.r.stderr)")
            XCTAssertEqual(plutilFired(run.f).count, 1, label)
            XCTAssertEqual(run.f.calls(), [], label)
            XCTAssertEqual(try Data(contentsOf: run.f.state), run.journal, label)
            XCTAssertEqual(try Data(contentsOf: run.f.session), run.session, label)
            XCTAssertTrue(run.f.log().contains(fault.says), "\(label): \(run.f.log())")
        }
    }

    /// The app's Info.plist read from its private copy: a read of the
    /// interface it declares that fails keeps the entry that needs the
    /// binary, unsignaled, and the binary is not run, as for an interface
    /// it does not declare. The rest of the run goes on.
    func testBackstopKeepsAnEntryWhenTheAppsInfoPlistCannotBeRead() throws {
        let started = 1_789_388_423
        let run = try runBackstop(failing: Self.onCopy("-extract InsomniaResumeFrozenVersion raw", of: "Info.plist")) { f in
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState("""
            {"sleepDisabledByUs":true,"lowPowerSetByUs":false,"dockerFrozen":false,
             "frozenProcesses":[{"pid":4242,"startedAt":\(started),"startedAtMicros":17,"bootSession":"\(f.bootUUID)"}]}
            """)
            try f.psTable([(4242, f.lstart(started), "T", f.uid)])
        }
        defer { run.f.destroy() }

        XCTAssertEqual(run.r.status, 1, run.r.stderr)
        XCTAssertEqual(plutilFired(run.f).count, 1)
        XCTAssertEqual(run.f.calls(), ["sudo -n \(run.f.fakePmset) -a disablesleep 0"], "the binary is not run and nothing is signaled")
        let after = try run.f.stateJSON()
        XCTAssertEqual(after["sleepDisabledByUs"] as? Bool, false, "the rest of the run is published")
        XCTAssertEqual((after["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 4242)
        XCTAssertTrue(run.f.log().contains("but \(run.f.appInfo.path) could not be read (InsomniaResumeFrozenVersion: plutil -extract exited 1 (simulated read error)); the binary was not run; kept, not signaled"), run.f.log())
    }

    /// A receipt head cannot read shows nothing about what the start's
    /// command did: with its dialog over, the start is settled as one that
    /// may have turned sleep off, sleep is restored, and its claim stays,
    /// since the nonce it would be given back with is unknown. A release
    /// file head cannot read keeps the claim of a start the receipt has
    /// settled as never having turned sleep off.
    func testBackstopTakesAReceiptOrReleaseHeadCannotReadForNoProof() throws {
        for (file, args) in [("receipt", #""-c 83""#), ("release", #""-c 43 "*"#)] {
            let wrapper = fx.bin.appendingPathComponent("head-\(file)")
            try """
            #!/bin/bash
            if [[ "$*" == \(args) ]]; then echo 'head: simulated read error' >&2; exit 1; fi
            exec /usr/bin/head "$@"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
            XCTAssertEqual(chmod(wrapper.path, 0o755), 0)
            let original = try String(contentsOf: fx.backstop, encoding: .utf8)
            try ScriptFixture.patch(original, ["HEAD": wrapper.path]).write(to: fx.backstop, atomically: true, encoding: .utf8)
            defer { try? original.write(to: fx.backstop, atomically: true, encoding: .utf8) }
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            let nonce = try journalUnfinishedStart()

            let r = try fx.run(fx.backstop)

            if file == "receipt" {
                try assertSettledButNotFinished(r, nonce: nonce, restored: true, saying: ["receipts/\(getuid()) could not be read (head exit 1)", "settling an unfinished start as one that may have turned sleep off", "an unfinished start is settled, but its claim on the receipt could not be given back ("])
            } else {
                try assertSettledButNotFinished(r, nonce: nonce, restored: false, saying: ["receipts/\(getuid()).released could not be read (head exit 1)", "an unfinished start is settled, but its claim on the receipt could not be given back ("])
            }
        }
    }

    /// copy_private, on its own: a FIFO with no writer is refused (4) at
    /// once without blocking, a file it cannot open is 3, and a regular
    /// file is copied whole to a new mode-600 file with the identity stat
    /// gives the live file.
    func testTheBackstopsPrivateCopyRefusesAFIFOAndReportsTheFilesIdentity() throws {
        let text = try String(contentsOf: fx.backstop, encoding: .utf8)
        let perl = try XCTUnwrap(text.range(of: "\nCOPY_PERL='"))
        let copy = try XCTUnwrap(text.range(of: "\ncopy_private() {", range: perl.upperBound..<text.endIndex))
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: copy.upperBound..<text.endIndex))
        let reads = fx.root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        let harness = fx.root.appendingPathComponent("copy_private.sh")
        try ("set -euo pipefail\nRM=/bin/rm\nENV=/usr/bin/env\nPERL=/usr/bin/perl\nREAD_TIMEOUT_SECONDS=10\nREADS='\(reads.path)'"
            + text[perl.lowerBound..<end.upperBound]
            + #"rc=0; copy_private "$1" "$2" || rc=$?; printf '%s|%s|%s\n' "$rc" "$copy_id" "$copy_why""# + "\n")
            .write(to: harness, atomically: true, encoding: .utf8)

        let fifo = fx.root.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let started = Date()
        let refused = try fx.run(harness, [fifo, "pipe"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a FIFO with no writer does not block the copy")
        XCTAssertEqual(refused.stdout, "4||not a regular file\n", refused.stderr)

        let locked = fx.root.appendingPathComponent("locked.json")
        try Data("{}".utf8).write(to: locked)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        let unreadable = try fx.run(harness, [locked.path, "locked"])
        XCTAssertEqual(unreadable.stdout, "3||Permission denied\n", unreadable.stderr)

        let source = fx.root.appendingPathComponent("journal.json")
        let bytes = Data(#"{"sleepDisabledByUs":false,"x":"\#(String(repeating: "y", count: 200_000))"}"#.utf8)
        try bytes.write(to: source)
        let copied = try fx.run(harness, [source.path, "journal.json"])
        let id = try fx.runTool("/usr/bin/stat", ["-L", "-f", "%d:%i:%z:%m:%c", source.path]).output.trimmingCharacters(in: .newlines)
        XCTAssertEqual(copied.stdout, "0|\(id)|\n", copied.stderr)
        let copyURL = reads.appendingPathComponent("journal.json")
        XCTAssertEqual(try Data(contentsOf: copyURL), bytes)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copyURL.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
    }

    /// Points `script`'s constant `name` (a tool's path) at a bash wrapper
    /// in f.bin whose body is `body`: a fault injected into one tool.
    private func patchTool(_ name: String, in script: URL, of f: ScriptFixture, _ body: String) throws {
        let wrapper = f.bin.appendingPathComponent("\(name.lowercased())-\(UUID().uuidString.prefix(8))")
        try "#!/bin/bash\n\(body)\n".write(to: wrapper, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(wrapper.path, 0o755), 0)
        let text = try String(contentsOf: script, encoding: .utf8)
        try ScriptFixture.patch(text, [name: wrapper.path]).write(to: script, atomically: true, encoding: .utf8)
    }

    /// The names in the fixture's folder that a run of the backstop makes
    /// and removes before it exits: its folder for copies and the journal
    /// copies it publishes from.
    private func backstopLeftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fx.home.path)
            .filter { $0.hasPrefix(".backstop-read.") || $0.hasPrefix(".state.json.") }
            .sorted()
    }

    /// Greptile on 7e233e8 (a full disk blocks backstop recovery):
    /// copy_private, on its own, with no folder for its copies or one it
    /// cannot write in. With COPY_IN_MEMORY 1 (backstop.sh) it keeps the
    /// copy in memory with the same checks: a FIFO is still 4 and a file
    /// it cannot open still 3, and it keeps the file's bytes exactly,
    /// control bytes, trailing newlines and a final dot included. A NUL
    /// byte, which a shell variable cannot hold, is 2. A copy whose file
    /// cannot be created, or stops growing partway (RLIMIT_FSIZE, as a
    /// full disk stops a write), is made again in memory and its file
    /// removed. With COPY_IN_MEMORY 0 (uninstall.sh) the same copy is 2.
    /// plutil_run reads a copy in memory through its standard input, and
    /// keeps a failure's message in memory when no file can hold it.
    func testTheBackstopsPrivateCopyFallsBackToMemoryWhenNoFileCanBeWritten() throws {
        let text = try String(contentsOf: fx.backstop, encoding: .utf8)
        let perl = try XCTUnwrap(text.range(of: "\nCOPY_PERL='"))
        let copy = try XCTUnwrap(text.range(of: "\ncopy_private() {", range: perl.upperBound..<text.endIndex))
        let copyEnd = try XCTUnwrap(text.range(of: "\n}\n", range: copy.upperBound..<text.endIndex))
        func function(_ name: String) throws -> Substring {
            let start = try XCTUnwrap(text.range(of: "\n\(name)() {"), name)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex), name)
            return text[start.lowerBound..<end.upperBound]
        }
        let harness = fx.root.appendingPathComponent("copy_memory.sh")
        try ("set -euo pipefail\nRM=/bin/rm\nENV=/usr/bin/env\nPERL=/usr/bin/perl\nPLUTIL=/usr/bin/plutil\nREAD_TIMEOUT_SECONDS=10\n"
            + #"READS="$3"; COPY_IN_MEMORY="$4""#
            + text[perl.lowerBound..<copyEnd.upperBound] + (try function("plutil_on")) + (try function("plutil_run"))
            + #"""
            if [[ "${6:-}" == fsize ]]; then trap '' XFSZ; ulimit -S -f 1; fi
            rc=0; copy_private "$1" "$2" || rc=$?
            ulimit -S -f unlimited
            printf '%s|%s|%s|%s\n' "$rc" "$copy_path" "$copy_id" "$copy_why"
            if [[ "$copy_path" == mem:* ]]; then v="mem_${copy_path#mem:}"; printf '%s' "${!v}" > "$5"; fi
            if (( rc == 0 )); then
              plutil_run -extract noSuchKey raw -o - "$copy_path"
              printf '%s|%s\n' "$plutil_rc" "$plutil_err"
            fi

            """#)
            .write(to: harness, atomically: true, encoding: .utf8)
        let reads = fx.root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        let kept = fx.root.appendingPathComponent("kept")
        func run(_ file: String, _ name: String, reads: String = "", inMemory: Int = 1, fsize: Bool = false) throws -> [String] {
            try? FileManager.default.removeItem(at: kept)
            let r = try fx.run(harness, [file, name, reads, String(inMemory), kept.path] + (fsize ? ["fsize"] : []))
            XCTAssertEqual(r.status, 0, name)
            XCTAssertEqual(r.stderr, "", name)
            return r.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        func identity(_ path: String) throws -> String {
            try fx.runTool("/usr/bin/stat", ["-L", "-f", "%d:%i:%z:%m:%c", path]).output.trimmingCharacters(in: .newlines)
        }
        let missing = "1|<stdin>: Could not extract value, error: No value at that key path or invalid key path: noSuchKey"

        let fifo = fx.root.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let started = Date()
        XCTAssertEqual(try run(fifo, "pipe"), ["4|mem:pipe||not a regular file"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a FIFO with no writer does not block the copy")

        let locked = fx.root.appendingPathComponent("locked.json")
        try Data("{}".utf8).write(to: locked)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        XCTAssertEqual(try run(locked.path, "locked"), ["3|mem:locked||Permission denied"])

        let nul = fx.root.appendingPathComponent("nul.json")
        try Data("{\"a\":\"x\u{0}y\"}".utf8).write(to: nul)
        XCTAssertEqual(try run(nul.path, "nul.json"), ["2|mem:nul_json||it holds a NUL byte, which a copy kept in memory cannot hold"])
        XCTAssertEqual(try Data(contentsOf: kept), Data(), "nothing of a refused copy is kept")

        let source = fx.root.appendingPathComponent("journal.json")
        let large = Data(#"{"sleepDisabledByUs":false,"x":"\#(String(repeating: "y", count: 200_000))"}"#.utf8)
        for bytes in [Data(), Data("{}".utf8), Data("{\"a\":\"\u{1}\u{7f}\u{1b}[0m\"}\n\n".utf8), Data("{} ends with a dot.".utf8),
                      Data("\n\n.\n".utf8), large] {
            try bytes.write(to: source)
            let lines = try run(source.path, "journal.json")
            XCTAssertEqual(lines.first, "0|mem:journal_json|\(try identity(source.path))|", "\(bytes.count) bytes")
            XCTAssertEqual(try Data(contentsOf: kept), bytes, "\(bytes.count) bytes")
            if bytes == large { XCTAssertEqual(lines.dropFirst().first, missing) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: reads.path), [])

        // A folder the copy cannot be created in.
        XCTAssertEqual(chmod(reads.path, 0o500), 0)
        defer { chmod(reads.path, 0o700) }
        XCTAssertEqual(try run(source.path, "journal.json", reads: reads.path),
                       ["0|mem:journal_json|\(try identity(source.path))|", missing])
        XCTAssertEqual(try Data(contentsOf: kept), large)
        XCTAssertEqual(try run(source.path, "journal.json", reads: reads.path, inMemory: 0),
                       ["2|\(reads.path)/journal.json||\(reads.path)/journal.json: Permission denied"])
        XCTAssertFalse(fx.exists(kept), "uninstall.sh keeps no copy in memory")
        XCTAssertEqual(chmod(reads.path, 0o700), 0)

        // A copy that stops growing partway.
        XCTAssertEqual(try run(source.path, "journal.json", reads: reads.path, fsize: true),
                       ["0|mem:journal_json|\(try identity(source.path))|", missing])
        XCTAssertEqual(try Data(contentsOf: kept), large)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: reads.path), ["plutil.err"],
                       "the part written is removed; plutil's message still has its file in the folder")
        XCTAssertEqual(try run(source.path, "journal.json", reads: reads.path, inMemory: 0, fsize: true),
                       ["2|\(reads.path)/journal.json||\(reads.path)/journal.json: File too large"])

        // A folder it can write in: a copy there, and plutil's message
        // through a file, naming the copy.
        let inFolder = try run(source.path, "journal.json", reads: reads.path)
        XCTAssertEqual(inFolder, ["0|\(reads.path)/journal.json|\(try identity(source.path))|",
                                  "1|\(reads.path)/journal.json: Could not extract value, error: No value at that key path or invalid key path: noSuchKey"])
    }

    /// Greptile on 7e233e8: with no folder for its copies (mktemp -d fails,
    /// as on a full disk), or a folder nothing can be created in, the
    /// backstop keeps its copies in memory and restores what the journal
    /// records with every check it makes on a file. An expired session is
    /// undone and its journal cleared, other keys kept; a valid session is
    /// left alone; a start whose receipt shows it never turned sleep off
    /// is settled; a malformed session is moved aside. A journal of the
    /// wrong shape, not JSON, unreadable, holding a NUL byte or not a
    /// regular file undoes nothing.
    func testBackstopRestoresWithItsCopiesInMemoryWhenItCannotMakeItsFolder() throws {
        let original = try String(contentsOf: fx.backstop, encoding: .utf8)
        let memory = "could not create a private folder in \(fx.home.path) for this run's copies of session.json and state.json; this run keeps its copies in memory"
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"keepMe":{"x":1}}"#
        func reset() throws {
            try? FileManager.default.removeItem(at: fx.logFile)
            try? FileManager.default.removeItem(at: fx.session)
            try? FileManager.default.removeItem(at: fx.state)
            fx.clearCalls()
        }
        for staging in ["no folder", "a folder nothing can be created in"] {
            try original.write(to: fx.backstop, atomically: true, encoding: .utf8)
            if staging == "no folder" {
                try patchTool("MKTEMP", in: fx.backstop, of: fx, #"if [[ "$*" == *"/.backstop-read."* ]]; then exit 1; fi; exec /usr/bin/mktemp "$@""#)
            } else {
                try patchTool("MKTEMP", in: fx.backstop, of: fx, #"""
                    if [[ "$*" == *"/.backstop-read."* ]]; then d="$(/usr/bin/mktemp "$@")" || exit; /bin/chmod 500 "$d"; echo "$d"; exit 0; fi
                    exec /usr/bin/mktemp "$@"
                    """#)
            }

            try reset()
            try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try fx.writeState(dirty)
            var r = try fx.run(fx.backstop)
            XCTAssertEqual(r.status, 0, "\(staging): \(r.stderr) \(fx.log())")
            XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], staging)
            let s = try fx.stateJSON()
            XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false, staging)
            XCTAssertEqual((s["keepMe"] as? [String: Any])?["x"] as? Int, 1, "\(staging): other keys stay")
            XCTAssertFalse(fx.exists(fx.session), staging)
            XCTAssertTrue(fx.log().contains("journal cleared"), "\(staging): \(fx.log())")
            XCTAssertEqual(fx.log().contains(memory), staging == "no folder", "\(staging): \(fx.log())")
            XCTAssertEqual(try backstopLeftovers(), [], staging)

            try reset()
            try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try fx.writeState(#"{"sleepDisabledByUs":"yes","lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            r = try fx.run(fx.backstop)
            XCTAssertEqual(r.status, 1, staging)
            XCTAssertEqual(fx.calls(), [], staging)
            XCTAssertTrue(fx.log().contains("\(fx.state.path): sleepDisabledByUs is a string, not a bool"), "\(staging): \(fx.log())")
            XCTAssertEqual(try backstopLeftovers(), [], staging)
        }

        // With no folder: the remaining cases.
        try original.write(to: fx.backstop, atomically: true, encoding: .utf8)
        try patchTool("MKTEMP", in: fx.backstop, of: fx, #"if [[ "$*" == *"/.backstop-read."* ]]; then exit 1; fi; exec /usr/bin/mktemp "$@""#)

        try reset()
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(dirty)
        var r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [], "a valid session is left alone")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)
        XCTAssertTrue(fx.exists(fx.session))

        try reset()
        try journalUnfinishedStart()
        r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        try assertSettled(sleepRestored: false)
        XCTAssertTrue(fx.log().contains("its receipt shows the command behind its dialog never turned sleep off; sleepDisabledByUs goes back to false"), fx.log())
        XCTAssertTrue(fx.log().contains(memory), fx.log())

        try reset()
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(dirty)
        r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fx.home.path).contains { $0.hasPrefix("session.json.unreadable-") })
        XCTAssertTrue(fx.log().contains("session.json unreadable; moved to"), fx.log())

        let refusals: [(name: String, write: () throws -> Void, saying: String)] = [
            ("not JSON", { try self.fx.writeState(#"{"sleepDisabledByUs":true,"#) }, "\(fx.state.path): not valid JSON\n"),
            ("unreadable", {
                try self.fx.writeState(dirty)
                XCTAssertEqual(chmod(self.fx.state.path, 0), 0)
             }, "\(fx.state.path): not valid JSON (it could not be read: Permission denied)"),
            ("a NUL byte", { try Data("{\"sleepDisabledByUs\":true,\"a\":\"x\u{0}y\"}".utf8).write(to: self.fx.state) },
             "nothing undone, evidence kept: it holds a NUL byte, which a copy kept in memory cannot hold"),
            ("not a regular file", { XCTAssertEqual(mkfifo(self.fx.state.path, 0o600), 0) }, "\(fx.state.path): not a regular file"),
        ]
        for c in refusals {
            try reset()
            try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try c.write()
            r = try fx.run(fx.backstop)
            XCTAssertEqual(r.status, 1, c.name)
            XCTAssertEqual(fx.calls(), [], c.name)
            XCTAssertTrue(fx.log().contains(c.saying), "\(c.name): \(fx.log())")
            XCTAssertTrue(fx.log().contains(memory), c.name)
            XCTAssertTrue(fx.exists(fx.session), "\(c.name): the session stays with the journal it ends")
            if c.name == "not a regular file" {
                var st = stat()
                XCTAssertEqual(lstat(fx.state.path, &st), 0)
                XCTAssertEqual(st.st_mode & S_IFMT, S_IFIFO, "the FIFO is never opened or replaced")
                unlink(fx.state.path)
            } else {
                XCTAssertEqual(chmod(fx.state.path, 0o600), 0)
                XCTAssertNotNil(try? Data(contentsOf: fx.state), c.name)
            }
        }
    }

    /// Greptile on 7e233e8: a restore made from copies kept in memory whose
    /// updated journal cannot be published keeps the journal as it was, the
    /// same file, so the next run undoes what it records again: cp fails
    /// (as on a full disk), cp copies something other than what this run
    /// read, or the journal is rewritten in place, to the same size, while
    /// this run reads it. Each run makes the restore, exits 1 and names
    /// why, and keeps the session; the run after it clears the journal.
    func testBackstopKeepsTheJournalWhenItsPublishFailsWithItsCopiesInMemory() throws {
        try patchTool("MKTEMP", in: fx.backstop, of: fx, #"if [[ "$*" == *"/.backstop-read."* ]]; then exit 1; fi; exec /usr/bin/mktemp "$@""#)
        let withMemory = try String(contentsOf: fx.backstop, encoding: .utf8)
        let journal = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        let swapped = #"{"lowPowerSetByUs":false,"sleepDisabledByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#
        XCTAssertEqual(journal.utf8.count, swapped.utf8.count)
        let other = "(its copy does not hold the bytes this run read: it changed since, or cp copied something else)"
        let cases: [(name: String, inject: () throws -> Void, saying: String, after: String)] = [
            ("cp fails", { try self.patchTool("CP", in: self.fx.backstop, of: self.fx, "exit 1") }, "(it could not be copied)", journal),
            ("cp adds a byte", {
                try self.patchTool("CP", in: self.fx.backstop, of: self.fx, #"/bin/cp "$@" || exit; printf x >> "${!#}""#)
             }, other, journal),
            ("rewritten in place while read", {
                try self.wrapPlutil(in: self.fx.backstop, of: self.fx, on: #""-extract sleepDisabledByUs raw -o - -""#,
                                    "printf '%s' '\(swapped)' 1<> '\(self.fx.state.path)'")
             }, other, swapped),
        ]
        for c in cases {
            try withMemory.write(to: fx.backstop, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.clearCalls()
            try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try fx.writeState(journal)
            let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: fx.state.path)[.systemFileNumber] as? Int)
            try c.inject()

            let r = try fx.run(fx.backstop)

            XCTAssertEqual(r.status, 1, "\(c.name): \(fx.log())")
            XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], c.name)
            XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), c.after, c.name)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fx.state.path)[.systemFileNumber] as? Int, inode, "\(c.name): the same file")
            XCTAssertTrue(fx.log().contains("could not publish the updated journal to \(fx.state.path) \(c.saying); previous journal kept, will retry"), "\(c.name): \(fx.log())")
            XCTAssertTrue(fx.exists(fx.session), "\(c.name): the session goes only with the journal it ends")
            XCTAssertEqual(try backstopLeftovers(), [], c.name)

            try withMemory.write(to: fx.backstop, atomically: true, encoding: .utf8)
            fx.clearCalls()
            let again = try fx.run(fx.backstop)

            XCTAssertEqual(again.status, 0, "\(c.name): \(again.stderr) \(fx.log())")
            XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "\(c.name): the restore is made again")
            XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false, c.name)
            XCTAssertFalse(fx.exists(fx.session), c.name)
        }
        XCTAssertEqual(try String(contentsOf: fx.root.appendingPathComponent("plutil.fired"), encoding: .utf8), "-extract sleepDisabledByUs raw -o - -\n")
    }

    /// Round 30 (the hosted failure on 7e233e8): the backstop publishes
    /// from the live journal, as main does, so what cp copies with it, its
    /// extended attributes and its access control list, stays with the
    /// journal. 7e233e8 published from its private copy, and the
    /// journal's owner ACL was gone afterwards (the hosted run of
    /// testBackstopKeepsAnOwnerACLAndStillUndoesTheJournal). No test here
    /// may change an ACL, so this control uses an extended attribute, which
    /// cp copies the same way: the published journal keeps it, and every
    /// cp the run makes starts from state.json itself.
    func testBackstopPublishesFromTheLiveJournalSoWhatCpCopiesStaysWithIt() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let mark = try fx.runTool("/usr/bin/xattr", ["-w", "com.kgarg.insomnia.test", "kept", fx.state.path])
        XCTAssertEqual(mark.status, 0, mark.output)
        let copies = fx.root.appendingPathComponent("cp.log")
        try patchTool("CP", in: fx.backstop, of: fx, "printf '%s\\n' \"$*\" >> '\(copies.path)'; exec /bin/cp \"$@\"")

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        let kept = try fx.runTool("/usr/bin/xattr", ["-p", "com.kgarg.insomnia.test", fx.state.path])
        XCTAssertEqual(kept.status, 0, kept.output)
        XCTAssertEqual(kept.output, "kept\n", "the published journal keeps what cp copied with it")
        let calls = try String(contentsOf: copies, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertFalse(calls.isEmpty)
        for call in calls { XCTAssertTrue(call.hasPrefix("\(fx.state.path) \(fx.home.path)/.state.json."), call) }
    }

    // MARK: - Owner-only files

    /// `umask 077`: the log and its directory, the lock file and the
    /// republished journal are owner-only even when the journal the run
    /// started from was world-readable.
    func testBackstopCreatesOwnerOnlyFilesAndRepublishesTheJournalOwnerOnly() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.state.path)
        XCTAssertFalse(fx.exists(fx.lock), "the fixture starts without a lock file")

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(try fx.mode(fx.logFile), 0o600)
        XCTAssertEqual(try fx.mode(fx.logFile.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try fx.mode(fx.lock), 0o600)
        XCTAssertEqual(try fx.mode(fx.state), 0o600, "the published journal must not inherit 0644 from the old one")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    /// An upgrade over an older build: the log, lock, journal, session and
    /// the two directories it left loose are tightened by the backstop too,
    /// since it may run before the upgraded app has opened them.
    func testBackstopTightensWhatAnOlderBuildLeftLoose() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let logsDir = fx.logFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try "old line\n".write(to: fx.logFile, atomically: true, encoding: .utf8)
        try "".write(to: fx.lock, atomically: true, encoding: .utf8)
        for (url, mode) in [(fx.home, 0o755), (logsDir, 0o755), (fx.logFile, 0o644), (fx.lock, 0o644), (fx.state, 0o644), (fx.session, 0o644)] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(try fx.mode(fx.home), 0o700)
        XCTAssertEqual(try fx.mode(logsDir), 0o700)
        for file in [fx.logFile, fx.lock, fx.state, fx.session] {
            XCTAssertEqual(try fx.mode(file), 0o600, file.lastPathComponent)
        }
        XCTAssertTrue(fx.log().hasPrefix("old line\n"), "the loose log was replaced instead of kept")
        XCTAssertEqual(fx.chmodCalls(), [fx.home, logsDir, fx.logFile, fx.lock, fx.state, fx.session].map { "chmod go-rwx \($0.path)" },
            "the backstop changes modes through its fixed CHMOD path")
    }

    /// Tightening only takes group and other access away. An owner bit an
    /// older build or the user left off stays off: a write-only log stays
    /// write-only (0244 becomes 0200, not 0600) and a Logs directory the
    /// owner cannot list stays unlistable (0355 becomes 0300, not 0700).
    func testBackstopTighteningNeverAddsAPermission() throws {
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let logsDir = fx.logFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try "old line\n".write(to: fx.logFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o244], ofItemAtPath: fx.logFile.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o355], ofItemAtPath: logsDir.path)
        defer {
            _ = chmod(logsDir.path, 0o700)
            _ = chmod(fx.logFile.path, 0o600)
        }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(try fx.mode(fx.logFile), 0o200)
        XCTAssertEqual(try fx.mode(logsDir), 0o300)
    }

    // The journal is mode 0200 and only an ACL entry lets its owner read
    // it. Tightening leaves the entry, so the backstop still reads the
    // journal and turns sleep back on. Publishing the cleared journal still
    // fails, as it does on main: the entry lets the owner read the file's
    // data but not its extended attributes, and cp fails copying those.
    // The journal is kept for the next run, so the exit status is not
    // checked here.
    func testBackstopKeepsAnOwnerACLAndStillUndoesTheJournal() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        XCTAssertEqual(chmod(fx.state.path, 0o200), 0)
        try TestACL.grantOwnerRead(fx.state)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: fx.state.path))

        _ = try fx.run(fx.backstop)

        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], fx.log())
        XCTAssertFalse(fx.log().contains("unreadable or malformed"), fx.log())
        XCTAssertEqual(TestACL.entries(fx.state), 1)
    }

    func testBackstopLogsAFailedTighteningAndStillRecovers() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.state.path)
        try fx.state.path.write(to: fx.root.appendingPathComponent("chmod.fail"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "recovery went on after the failed chmod")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertTrue(fx.log().contains("[error] backstop: could not make \(fx.state.path) owner-only: chmod: \(fx.state.path): Operation not permitted\n"), fx.log())
        XCTAssertEqual(fx.log().components(separatedBy: "owner-only").count, 2, "only the failed path is reported: \(fx.log())")
    }

    // MARK: - Journal shape (typed corruption)

    func testTypedCorruptJournalIsRejectedByBackstopWithoutCommands() throws {
        let corrupt = [
            "[]",
            #"{"sleepDisabledByUs":"true"}"#,
            #"{"sleepDisabledByUs":false,"frozenProcesses":"garbage"}"#,
            #"{"sleepDisabledByUs":false,"frozenProcesses":[{"pid":"12"}]}"#,
            #"{"sleepDisabledByUs":false,"frozenProcesses":[{"pid":12,"startedAt":"5","bootSession":"b"}]}"#,
            #"{"sleepDisabledByUs":false,"frozenPids":["7"]}"#,
            #"{"sleepDisabledByUs":false,"savedOutputVolume":"loud"}"#,
            #"{"sleepDisabledByUs":false,"savedMuted":1}"#,
            #"{"sleepDisabledByUs":false,"savedDisplayBrightness":"bright"}"#,
            #"{"sleepDisabledByUs":false,"savedKeyboardBrightness":true}"#,
            #"{"sleepDisabledByUs":false,"savedDisplayBrightness":0.5,"displayRestoreRefused":"yes"}"#,
            #"{"sleepDisabledByUs":false,"savedKeyboardBrightness":0.5,"keyboardRestoreRefused":1}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":"com.google.Chrome"}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":["com.google.Chrome"]}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":[{"previous":true}]}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":[{"bundleId":"com.google.Chrome","previous":"yes"}]}"#,
        ] + Self.corruptOutputJournals
        for json in corrupt {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)

            let r = try f.run(f.backstop)

            XCTAssertNotEqual(r.status, 0, json)
            XCTAssertEqual(f.calls(), [], "no privileged command for \(json)")
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json, "evidence kept for \(json)")
            XCTAssertTrue(f.exists(f.session), json)
            XCTAssertTrue(f.log().contains("malformed"), f.log())
        }
    }

    /// Output device entries the app's decoder refuses too (StoreTests
    /// checks that side).
    static let corruptOutputJournals = [
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":"usb-headset"}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[null]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"volume":0.3,"muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":7,"volume":0.3,"muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":"loud","muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.3,"muted":1}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.3}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","name":3,"volume":0.3,"muted":false}]}"#,
        #"{"sleepDisabledByUs":false,"savedAudioOutputs":[{"deviceUID":"usb-headset","volume":0.3,"muted":false,"saveID":3}]}"#,
    ]

    func testNullOptionalFieldsCountAsAbsent() throws {
        // Swift's decodeIfPresent treats null as nil; the shell must agree.
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":null,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":null,"savedMuted":null,"savedDisplayBrightness":null,"savedKeyboardBrightness":null,"frozenPids":null,"appNapOverrides":null,"savedAudioOutputs":null,"displayRestoreRefused":null,"keyboardRestoreRefused":null,"displayRestoredUnderLowPower":null,"keptDisplayUnderLowPower":null,"keptDisplayUnderLowPowerBoot":null,"keptDisplayReadLit":null}"#
        try fx.writeState(json)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), json, "a clean journal is not rewritten")
    }

    func testPublishedJournalStaysJsonWithTypedValues() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":0.5,"custom":{"nested":["x"]}}"#)

        _ = try fx.run(fx.backstop)

        let text = try String(contentsOf: fx.state, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{"), text)
        XCTAssertTrue(text.contains(#""sleepDisabledByUs":false"#), "must be a JSON bool, not a string or number: \(text)")
        XCTAssertTrue(text.contains(#""savedOutputVolume":0.5"#), text)
        let s = try fx.stateJSON()
        XCTAssertEqual(((s["custom"] as? [String: Any])?["nested"] as? [String]), ["x"])
        // The published file must itself pass the scripts' shape check.
        let probe = try fx.run(fx.backstop)
        XCTAssertNotEqual(probe.status, 0, "audio is still journaled")
        XCTAssertFalse(fx.log().contains("malformed"), fx.log())
    }

    func testUninstallRejectsTypedCorruptJournalEvenWhenBackstopExitsZero() throws {
        for json in [
            "[]",
            #"{"sleepDisabledByUs":"true"}"#,
            #"{"sleepDisabledByUs":false,"frozenProcesses":"garbage"}"#,
            #"{"sleepDisabledByUs":false,"savedDisplayBrightness":"bright"}"#,
            #"{"sleepDisabledByUs":false,"savedDisplayBrightness":0.5,"displayRestoreRefused":"yes"}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":[{"previous":true}]}"#,
        ] + Self.corruptOutputJournals {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try "#!/bin/bash\nexit 0\n".write(to: f.backstop, atomically: true, encoding: .utf8)
            try f.writeState(json)

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertNotEqual(r.status, 0, json)
            XCTAssertTrue(f.exists(f.plist), json)
            XCTAssertTrue(f.exists(f.sudoers), json)
            XCTAssertTrue(f.exists(f.app), json)
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json)
            XCTAssertTrue(r.stderr.contains("malformed") || r.stderr.contains("not a JSON object"), r.stderr)
        }
    }

    // MARK: Kept display records

    /// A journal with a kept display entry and the app's records about it,
    /// sleep and Low Power Mode still ours: a run that took it for clean
    /// would call pmset twice and republish it.
    static func keptDisplayJournal(_ records: String, ours: Bool = true) -> String {
        #"{"sleepDisabledByUs":\#(ours),"lowPowerSetByUs":\#(ours),"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.8,"displayRestoreRefused":true"#
            + (records.isEmpty ? "" : "," + records) + "}"
    }

    /// Records the app's decoder refuses, each with the start of the line
    /// the log gives the problem: wrong types, numbers a Float cannot hold,
    /// and numbers plutil reads otherwise than the app. plutil turns
    /// 1e-400 into 0, reads 1., .5 and +1, which are not JSON numbers, and
    /// keeps the last of two copies of a key, where the app keeps the
    /// first. A key spelled with a \u escape is that key to both. plutil
    /// also reads keys written as JSON5 or with a \x escape, and comments;
    /// the app reads none of them.
    static let malformedKeptDisplayRecords: [(problem: String, json: String)] = [
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":"0.8""#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":true"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":[0.8]"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e39"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":-1e39"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e-50"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e-400"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":-1e-400"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1."#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPower":1e-400,"keptDisplayUnderLowPower":0.8"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":"0.8""#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":false"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":{"value":0.8}"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":3.5e38"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":5e-46"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":1e-400"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":-1e-400"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":.5"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":+1"#),
        ("keptDisplayReadLit is ", #""keptDisplayReadLit":1e-400,"keptDisplayReadLit":0.8"#),
        ("keptDisplayReadLit is ", #""kept\u0044isplayReadLit":1e-400"#),
        ("keptDisplayUnderLowPower is ", #""keptDisplayUnderLowPowe\#(backslash)u0072":"0.8""#),
        ("a key in state.json has an escape JSON does not have", #""kept\#(backslash)x44isplayReadLit":0.8"#),
        ("the top level of state.json cannot be followed here", #"keptDisplayReadLit:1e-400"#),
        ("the top level of state.json cannot be followed here", #"'keptDisplayReadLit':0.8"#),
        ("the top level of state.json cannot be followed here", #"/* note */"keptDisplayReadLit":0.8"#),
        ("keptDisplayUnderLowPowerBoot is ", #""keptDisplayUnderLowPowerBoot":7"#),
        ("keptDisplayUnderLowPowerBoot is ", #""keptDisplayUnderLowPowerBoot":true"#),
        ("keptDisplayUnderLowPowerBoot is ", #""keptDisplayUnderLowPowerBoot":["boot-a"]"#),
        ("displayRestoredUnderLowPower is ", #""displayRestoredUnderLowPower":"0.75""#),
        ("displayRestoredUnderLowPower is ", #""displayRestoredUnderLowPower":false"#),
    ]

    /// Forms the app's decoder reads: null and absent are none, a number
    /// may be written as an integer, 0 in any form is 0, the ends of a
    /// Float's range hold, and so does a Float as a script republishes it,
    /// with 17 significant digits.
    static let validKeptDisplayRecords = [
        "",
        #""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"8F2C1A3E-0B6D-4C11-9E3F-2A7B5C4D1E00","keptDisplayReadLit":0.8"#,
        #""keptDisplayUnderLowPower":1,"keptDisplayReadLit":0"#,
        #""keptDisplayUnderLowPower":null,"keptDisplayUnderLowPowerBoot":null,"keptDisplayReadLit":null,"displayRestoredUnderLowPower":null"#,
        #""keptDisplayUnderLowPowerBoot":"","displayRestoredUnderLowPower":0.75"#,
        #""keptDisplayUnderLowPower":1e-45,"keptDisplayReadLit":3.4028235e38"#,
        #""keptDisplayUnderLowPower":-3.4028235e38,"keptDisplayReadLit":-1e-45"#,
        #""keptDisplayUnderLowPower":-0,"keptDisplayReadLit":0e-400"#,
        #""keptDisplayUnderLowPower":0.0,"keptDisplayReadLit":0.80000001192092896"#,
        #""keptDisplayReadL\#(backslash)u0069t":0.8,"kept\#(backslash)u0044isplayUnderLowPower":0.8"#,
        #""keptDisplayReadLit":0.8,"note":{"keptDisplayReadLit":1e-400,"keptDisplayUnderLowPower":"0.8"},"list":[{"keptDisplayReadLit":0.7},"]}{["]"#,
        #""note":"\#(backslash)"keptDisplayReadLit\#(backslash)":1e-400 \#(backslash)\#(backslash)u0041 \#(backslash)\#(backslash)","keptDisplayReadLit" : 0.8"#,
    ]

    /// Journals the app reads, taking the first copy of a key, that both
    /// scripts refuse: plutil checks the last copy, and a republished
    /// journal would keep only that one.
    static let duplicatedKeptDisplayRecords: [(problem: String, json: String)] = [
        ("keptDisplayReadLit is in the top level of state.json 2 times; the app reads the first and plutil the last", #""keptDisplayReadLit":0.8,"keptDisplayReadLit":0.7"#),
        ("keptDisplayReadLit is in the top level of state.json 2 times", #""keptDisplayReadLit":0.8,"keptDisplayReadL\#(backslash)u0069t":0.7"#),
        ("keptDisplayUnderLowPower is in the top level of state.json 3 times", #""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPower":0.8"#),
        ("keptDisplayUnderLowPowerBoot is in the top level of state.json 2 times", #""keptDisplayUnderLowPowerBoot":"boot A","keptDisplayUnderLowPowerBoot":"boot B""#),
    ]

    static let keptDisplayRecordKeys = [
        "keptDisplayUnderLowPower", "keptDisplayUnderLowPowerBoot", "keptDisplayReadLit", "displayRestoredUnderLowPower",
    ]

    /// A record the app could not decode makes the journal malformed, as
    /// any other key of the wrong shape does: no pmset, the bytes and the
    /// session kept, and the log names the key. The app's decoder refuses
    /// each of these journals too.
    func testMalformedKeptDisplayRecordsAreRejectedByBackstopWithoutCommands() throws {
        for (problem, record) in Self.malformedKeptDisplayRecords {
            let json = Self.keptDisplayJournal(record)
            XCTAssertThrowsError(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), "the app refuses \(json)")
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)

            let r = try f.run(f.backstop)

            XCTAssertNotEqual(r.status, 0, json)
            XCTAssertEqual(f.calls(), [], "no privileged command for \(json)")
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json, "evidence kept for \(json)")
            XCTAssertTrue(f.exists(f.session), json)
            XCTAssertTrue(f.log().contains("\(f.state.path): \(problem)"), "\(json): \(f.log())")
            XCTAssertTrue(f.log().contains("is unreadable or malformed; nothing undone, evidence kept"), f.log())
        }
    }

    /// Every form the app reads passes: sleep and the mode are undone, the
    /// records stay as they were for the app, but for the boot of a record
    /// of the kept entry, which becomes this boot as the mode goes off. The
    /// published journal still decodes in the app and passes the check on
    /// the next run.
    func testValidKeptDisplayRecordsAreKeptForTheApp() throws {
        for records in Self.validKeptDisplayRecords {
            let json = Self.keptDisplayJournal(records)
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let decodedBefore = try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8))
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)

            let r = try f.run(f.backstop)

            XCTAssertEqual(r.status, 0, json + r.stderr + f.log())
            XCTAssertEqual(f.calls(), [
                "sudo -n \(f.fakePmset) -a disablesleep 0",
                "sudo -n \(f.fakePmset) -b lowpowermode 0",
            ], json)
            let after = try f.stateJSON()
            XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false, json)
            let stamped = decodedBefore.keptDisplayUnderLowPower != nil
            for key in Self.keptDisplayRecordKeys + ["savedDisplayBrightness", "displayRestoreRefused"] {
                if stamped, key == "keptDisplayUnderLowPowerBoot" {
                    XCTAssertEqual(after[key] as? String, f.bootUUID, "\(key) in \(json)")
                } else {
                    XCTAssertEqual(after[key] as? NSObject, before[key] as? NSObject, "\(key) in \(json)")
                }
            }
            let published = try Data(contentsOf: f.state)
            let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: published)
            XCTAssertEqual(decoded.keptDisplayUnderLowPower, decodedBefore.keptDisplayUnderLowPower, json)
            XCTAssertEqual(decoded.keptDisplayUnderLowPowerBoot, stamped ? f.bootUUID : decodedBefore.keptDisplayUnderLowPowerBoot, json)
            XCTAssertEqual(decoded.keptDisplayReadLit, decodedBefore.keptDisplayReadLit, json)
            XCTAssertEqual(decoded.displayRestoredUnderLowPower, decodedBefore.displayRestoredUnderLowPower, json)

            let again = try f.run(f.backstop)
            XCTAssertEqual(again.status, 0, json + again.stderr + f.log())
            XCTAssertEqual(f.calls().count, 2, json)
            XCTAssertFalse(f.log().contains("malformed"), f.log())
            XCTAssertEqual(try Data(contentsOf: f.state), published, "a clean journal is not rewritten: \(json)")
        }
    }

    /// uninstall.sh checks the same records itself: one the app could not
    /// decode stops it with everything in place, even when the backstop
    /// exits 0.
    func testUninstallRejectsMalformedKeptDisplayRecordsEvenWhenBackstopExitsZero() throws {
        for (problem, record) in Self.malformedKeptDisplayRecords {
            let json = Self.keptDisplayJournal(record, ours: false)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try "#!/bin/bash\nexit 0\n".write(to: f.backstop, atomically: true, encoding: .utf8)
            try f.writeState(json)

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertNotEqual(r.status, 0, json)
            XCTAssertTrue(f.exists(f.plist), json)
            XCTAssertTrue(f.exists(f.sudoers), json)
            XCTAssertTrue(f.exists(f.app), json)
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json)
            XCTAssertTrue(r.stderr.contains("state.json is malformed (unexpected shape)"), "\(json): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains(problem), "\(json): \(r.stderr)")
            XCTAssertThrowsError(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), "the app refuses \(json)")
        }
    }

    /// A key the app reads more than once, as in `duplicatedKeptDisplayRecords`:
    /// the app decodes the journal, and both scripts refuse it before any
    /// command, with the bytes kept.
    func testDuplicatedKeptDisplayRecordsAreRefusedByBothScripts() throws {
        for (problem, record) in Self.duplicatedKeptDisplayRecords {
            let json = Self.keptDisplayJournal(record)
            XCTAssertNoThrow(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), "the app reads \(json)")
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)

            let r = try f.run(f.backstop)

            XCTAssertNotEqual(r.status, 0, json)
            XCTAssertEqual(f.calls(), [], "no privileged command for \(json)")
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json)
            XCTAssertTrue(f.log().contains("\(f.state.path): \(problem)"), "\(json): \(f.log())")

            let u = try ScriptFixture()
            defer { u.destroy() }
            try u.installMachinery()
            try "#!/bin/bash\nexit 0\n".write(to: u.backstop, atomically: true, encoding: .utf8)
            try u.writeState(Self.keptDisplayJournal(record, ours: false))

            let ur = try u.run(u.uninstall, ["--purge"])

            XCTAssertNotEqual(ur.status, 0, json)
            XCTAssertTrue(u.exists(u.app), json)
            XCTAssertTrue(ur.stderr.contains(problem), "\(json): \(ur.stderr)")
        }
    }

    /// record_text_problems as it is in each script, run on its own over
    /// exact bytes: what it prints, or nothing.
    private func recordTextProblems(_ inputs: [(label: String, bytes: Data)], script: String = "backstop.sh") throws -> [String: String] {
        let f = try ScriptFixture()
        defer { f.destroy() }
        let runner = f.root.appendingPathComponent("record-text-problems.sh")
        try ("set -euo pipefail\nCAT=/bin/cat\nSTAT=/usr/bin/stat\n" + Self.recordTextProblemsSource(script) + "\nrecord_text_problems \"$1\"\n")
            .write(to: runner, atomically: true, encoding: .utf8)
        var printed: [String: String] = [:]
        for (i, input) in inputs.enumerated() {
            let file = f.root.appendingPathComponent("input.\(i)")
            try input.bytes.write(to: file)
            let r = try f.run(runner, [file.path])
            XCTAssertEqual(r.status, 0, "\(input.label): \(r.stderr)")
            XCTAssertEqual(r.stderr, "", input.label)
            printed[input.label] = r.stdout
        }
        return printed
    }

    private static func recordTextProblemsSource(_ script: String) throws -> String {
        let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(script), encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: "record_text_problems() { # file"), script)
        let end = try XCTUnwrap(lines[start...].firstIndex(of: "}"), script)
        return lines[start...end].joined(separator: "\n")
    }

    /// The two scripts carry the same reader, comment and all.
    func testBothScriptsReadTheRecordsTheSameWay() throws {
        func withComment(_ script: String) throws -> String {
            let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(script), encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: "# Prints one line per way the app's records about a kept display entry would"), script)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex), script)
            return String(text[start.lowerBound..<end.upperBound])
        }
        XCTAssertEqual(try withComment("backstop.sh"), try withComment("uninstall.sh"))
        XCTAssertEqual(try Self.recordTextProblemsSource("backstop.sh"), try Self.recordTextProblemsSource("uninstall.sh"))
    }

    /// Round 30 (finding 13): a run whose output cannot be captured
    /// throws, which fails the row or test that ran it
    /// (AppEncodedJournalScriptTests.ScriptRow.outcome), never reads as no
    /// output: output that is not UTF-8, and a capture file that cannot be
    /// made (the fixture's folder is read-only here).
    func testAFixtureRunWhoseOutputCannotBeCapturedThrows() throws {
        let f = try ScriptFixture()
        defer {
            chmod(f.root.path, 0o755)
            f.destroy()
        }
        let script = f.root.appendingPathComponent("bytes.sh")
        try "printf 'ok\\n'; printf '\\377' >&2\n".write(to: script, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try f.run(script)) { XCTAssertTrue("\($0)".hasSuffix(" is not UTF-8 text"), "\($0)") }
        try "printf 'ok\\n'\n".write(to: script, atomically: true, encoding: .utf8)
        let ran = try f.run(script)
        XCTAssertEqual(ran.status, 0)
        XCTAssertEqual(ran.stdout, "ok\n")
        XCTAssertEqual(ran.stderr, "")
        XCTAssertEqual(chmod(f.root.path, 0o555), 0)
        XCTAssertThrowsError(try f.run(script)) { XCTAssertTrue("\($0)".hasPrefix("could not create \(f.root.path)/stdout."), "\($0)") }
    }

    /// Round 30 (findings 7 and 8): uninstall.sh reads the journal, the
    /// session, config.json and the app's Info.plist with backstop.sh's
    /// readers, so a read that fails is unknown in both, never absent: the
    /// private copy (its perl text too), every plutil read and its status,
    /// the shape checks, the dates and the receipt's access check. Also
    /// the readers of a copy kept in memory (plutil_on) and the byte check
    /// of a copy of the live journal (same_as_read).
    func testBothScriptsShareTheirReaders() throws {
        let backstop = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent("backstop.sh"), encoding: .utf8)
        let uninstall = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent("uninstall.sh"), encoding: .utf8)
        func function(_ name: String, in text: String) throws -> String {
            let start = try XCTUnwrap(text.range(of: "\n\(name)() {"), name)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex), name)
            return String(text[start.lowerBound..<end.upperBound])
        }
        func perl(_ text: String) throws -> String {
            let start = try XCTUnwrap(text.range(of: "\nCOPY_PERL='"))
            let end = try XCTUnwrap(text.range(of: "'\n", range: start.upperBound..<text.endIndex))
            return String(text[start.lowerBound..<end.upperBound])
        }
        XCTAssertEqual(try perl(backstop), try perl(uninstall))
        for name in ["copy_private", "plutil_run", "absent_reply", "type_at", "ty", "read_at", "count_at", "json_object", "shape_of",
                     "record_text_problems", "journal_shape_problems", "epoch_of", "epoch_at", "session_shape_problems",
                     "receipt_access_problem", "unlock_receipt", "plutil_on", "same_as_read"] {
            XCTAssertEqual(try function(name, in: backstop), try function(name, in: uninstall), name)
        }
    }

    /// The reader over texts no fixture writes whole: what it reads as the
    /// app does prints nothing, and what it refuses names the problem.
    /// Each text is also given to the app's decoder, which reads every one
    /// printing nothing. It also reads some the reader refuses: UTF-16 and
    /// a NUL byte in a string, which the reader cannot follow, and the keys
    /// read twice, where plutil would check the other copy. The BOM-less
    /// UTF-16 file hiding a key is one the reader passed before it refused
    /// NUL bytes: the shell drops them, and what is left reads as a key
    /// inside an array, while the app reads 1e-400 at the top level.
    func testTheRecordReaderFollowsTheTopLevelAsTheAppReadsIt() throws {
        let b = backslash
        let bom = Data([0xEF, 0xBB, 0xBF])
        func utf8(_ s: String) -> Data { Data(s.utf8) }
        let cases: [(label: String, bytes: Data, prints: String, appReads: Bool)] = [
            ("no records", utf8(#"{"sleepDisabledByUs":true}"#), "", true),
            ("empty object", utf8("{ }"), "", true),
            ("UTF-8 byte order mark", bom + utf8(#"{"keptDisplayReadLit":0.8}"#), "", true),
            ("UTF-8 byte order mark, too small", bom + utf8(#"{"keptDisplayReadLit":1e-400}"#),
             "keptDisplayReadLit is 1e-400, too small a number for the app to read\n", false),
            ("UTF-16 with a byte order mark", Data([0xFF, 0xFE]) + #"{"keptDisplayReadLit":0.8}"#.data(using: .utf16LittleEndian)!,
             "the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked\n", true),
            ("UTF-16 without a byte order mark", #"{"keptDisplayReadLit":0.8}"#.data(using: .utf16LittleEndian)!,
             "the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked\n", true),
            ("UTF-16 without a byte order mark, hiding a key",
             "{\"a\":\"\u{2278}\u{222C}\u{2271}\u{203A}\u{205B}\",\"keptDisplayReadLit\":1e-400,\"b\":\"\u{2C5D}\u{2220}\u{2263}\u{203A}\u{7822}\"}"
                .data(using: .utf16LittleEndian)!,
             "the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked\n", false),
            ("UTF-16 without records", #"{"sleepDisabledByUs":true}"#.data(using: .utf16LittleEndian)!, "", true),
            ("NUL byte in a string", utf8("{\"keptDisplayReadLit\":0.8,\"a\":\"x\u{0}y\"}"),
             "the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked\n", true),
            ("comma before the end", utf8(#"{"keptDisplayReadLit":0.8,}"#), "", true),
            ("whitespace everywhere", utf8("\n{ \"a\" :\t[ 1 ,2 ] ,\r\n \"keptDisplayReadLit\"\n:\n0.8\n}\n"), "", true),
            ("escaped letter, upper hex", utf8(#"{"kept\#(b)u0044isplayReadLit":1e-400}"#),
             "keptDisplayReadLit is 1e-400, too small a number for the app to read\n", false),
            ("escaped letter, lower hex", utf8(#"{"keptDisplayRead\#(b)u004cit":1e39}"#),
             "keptDisplayReadLit is 1e39, too large a number for the app to read\n", false),
            ("escaped letter, valid value", utf8(#"{"keptDisplayReadL\#(b)u0069t":0.8}"#), "", true),
            ("other escapes in keys", utf8(#"{"a\#(b)"\#(b)\#(b)\#(b)/\#(b)b\#(b)f\#(b)n\#(b)r\#(b)t\#(b)u00e9\#(b)ud83d\#(b)ude00":1}"#), "", true),
            ("a key with a \\x escape", utf8(#"{"kept\#(b)x44isplayReadLit":0.8}"#),
             "a key in state.json has an escape JSON does not have, so its records about a kept display entry cannot be checked\n", false),
            ("unquoted key", utf8(#"{keptDisplayReadLit:0.8}"#),
             "the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked\n", false),
            ("block comment", utf8(#"{"a":1,/* c */"keptDisplayReadLit":0.8}"#),
             "the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked\n", false),
            ("line comment", utf8("{\"a\":1, // c\n\"keptDisplayReadLit\":0.8}"),
             "the top level of state.json cannot be followed here, so its records about a kept display entry cannot be checked\n", false),
            ("escaped backslash in a value", utf8(#"{"name":"Headset \#(b)\#(b)u0041","uid":"\#(b)\#(b)"}"#), "", true),
            ("escape in a value", utf8(#"{"name":"Headset \#(b)u0041 \#(b)"keptDisplayReadLit\#(b)":1e-400"}"#), "", true),
            ("nested copies", utf8(#"{"keptDisplayReadLit":0.8,"a":{"keptDisplayReadLit":1e-400,"b":[["keptDisplayReadLit",{"keptDisplayReadLit":0.7}]]}}"#), "", true),
            ("brackets in nested strings", utf8(#"{"a":{"b":"}]","c":["{[",{"d":"\#(b)"}"}]},"keptDisplayReadLit":1e-400}"#),
             "keptDisplayReadLit is 1e-400, too small a number for the app to read\n", false),
            ("read twice", utf8(#"{"keptDisplayReadLit":0.8,"keptDisplayReadL\#(b)u0069t":0.8}"#),
             "keptDisplayReadLit is in the top level of state.json 2 times; the app reads the first and plutil the last\n", true),
            ("boot read twice", utf8(#"{"keptDisplayUnderLowPowerBoot":"a","keptDisplayUnderLowPowerBoot":null}"#),
             "keptDisplayUnderLowPowerBoot is in the top level of state.json 2 times; the app reads the first and plutil the last\n", true),
            ("zero forms", utf8(#"{"keptDisplayReadLit":-0,"keptDisplayUnderLowPower":0e-400}"#), "", true),
            ("leading zero", utf8(#"{"keptDisplayReadLit":01}"#),
             "keptDisplayReadLit is written as 01, which the app does not read as a number\n", false),
        ]
        let printed = try recordTextProblems(cases.map { ($0.label, $0.bytes) })
        let printedByUninstall = try recordTextProblems(cases.map { ($0.label, $0.bytes) }, script: "uninstall.sh")
        for c in cases {
            XCTAssertEqual(printed[c.label], c.prints, c.label)
            XCTAssertEqual(printedByUninstall[c.label], c.prints, c.label)
            let reads = (try? Store.makeDecoder().decode(RuntimeState.self, from: c.bytes)) != nil
            XCTAssertEqual(reads, c.appReads, "the app's decoder on \(c.label)")
        }
    }

    /// The same records in a form the app reads do not stop the uninstall:
    /// it completes past the kept entry, and state.json stays byte for byte
    /// with them, even with --purge.
    func testUninstallCompletesPastValidKeptDisplayRecordsAndKeepsThem() throws {
        for records in Self.validKeptDisplayRecords {
            let json = Self.keptDisplayJournal(records, ours: false)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(json)

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertEqual(r.status, 0, json + r.stderr + r.stdout)
            XCTAssertFalse(f.exists(f.plist), json)
            XCTAssertFalse(f.exists(f.app), json)
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json)
            XCTAssertTrue(r.stdout.contains("  - display brightness 0.8"), r.stdout)
        }
    }

    /// uninstall.sh with the backstop it installed, not a stub, on numbers
    /// plutil reads as 0 or as other numbers than the app: the backstop
    /// refuses before any command, and so does uninstall.sh, with the app,
    /// the agent, the sudoers rule, the session and state.json all kept.
    func testUninstallWithItsBackstopRejectsNumbersPlutilMisreads() throws {
        let records = [
            #""keptDisplayUnderLowPower":1e-400"#,
            #""keptDisplayReadLit":1e-400"#,
            #""keptDisplayReadLit":-1e-400,"keptDisplayReadLit":0.8"#,
            #""keptDisplayUnderLowPower":+1"#,
        ]
        for record in records {
            let json = Self.keptDisplayJournal(record)
            XCTAssertThrowsError(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), "the app refuses \(json)")
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            let sessionBytes = try Data(contentsOf: f.session)
            try f.writeState(json)

            let r = try f.run(f.uninstall, ["--purge"])

            XCTAssertNotEqual(r.status, 0, json)
            XCTAssertFalse(f.calls().contains { $0.hasPrefix("sudo") || $0.contains("pmset") }, "\(json): \(f.calls())")
            XCTAssertTrue(f.exists(f.app), json)
            XCTAssertTrue(f.exists(f.plist), json)
            XCTAssertTrue(f.exists(f.sudoers), json)
            XCTAssertTrue(f.exists(f.installedBackstop), json)
            XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json, "evidence kept")
            XCTAssertEqual(try Data(contentsOf: f.session), sessionBytes, "session kept")
            XCTAssertTrue(f.log().contains("is unreadable or malformed; nothing undone, evidence kept"), "\(json): \(f.log())")
        }
    }

    /// Low Power Mode on over a kept display entry the app recorded in an
    /// earlier boot. The backstop switches the mode off before the app
    /// launches in this boot, and gives the record this boot, so the app
    /// takes no reading of the entry in this boot as the user's level
    /// while the panel comes back from the mode. The value, the reading
    /// above 0 and the entry stay as they were.
    func testBackstopGivesTheKeptDisplayRecordThisBootWhenItSwitchesTheModeOff() throws {
        let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A","keptDisplayReadLit":0.8"#)
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(json)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -b lowpowermode 0"), "\(fx.calls())")
        let after = try fx.stateJSON()
        XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, fx.bootUUID)
        XCTAssertEqual(after["keptDisplayUnderLowPower"] as? Double, 0.8)
        XCTAssertEqual(after["keptDisplayReadLit"] as? Double, 0.8)
        XCTAssertEqual(after["savedDisplayBrightness"] as? Double, 0.8)
        XCTAssertEqual(after["displayRestoreRefused"] as? Bool, true)
        let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: fx.state))
        XCTAssertTrue(decoded.keptDisplayReadUnderLowPower(inBoot: fx.bootUUID), "the app's doubt in this boot")
        XCTAssertFalse(decoded.lowPowerClaimFromEarlierBoot(boot: fx.bootUUID))
    }

    /// The same with a boot the backstop cannot read: the record gets an
    /// empty boot, which the app reads as this boot's too.
    func testBackstopGivesTheKeptDisplayRecordAnEmptyBootWhenItCannotReadThisOne() throws {
        let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A""#)
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(json)
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("boot.uuid"))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -b lowpowermode 0"), "\(fx.calls())")
        let after = try fx.stateJSON()
        XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, "")
        let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: fx.state))
        XCTAssertTrue(decoded.keptDisplayReadUnderLowPower(inBoot: "a boot the app reads"))
    }

    /// Nothing to give a boot to: no record, or a null one. The mode goes
    /// off, nothing is published before it, and the journal keeps its
    /// records as they were.
    func testBackstopGivesNoBootWithoutARecord() throws {
        for records in ["", #""keptDisplayUnderLowPower":null,"keptDisplayReadLit":0.8"#] {
            let json = Self.keptDisplayJournal(records)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)

            let r = try f.run(f.backstop)

            XCTAssertEqual(r.status, 0, json + r.stderr + f.log())
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(json): \(f.calls())")
            XCTAssertFalse(f.log().contains("given this boot"), f.log())
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let after = try f.stateJSON()
            XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false, json)
            XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? NSObject, before["keptDisplayUnderLowPowerBoot"] as? NSObject, json)
            XCTAssertEqual(after["keptDisplayUnderLowPower"] as? NSObject, before["keptDisplayUnderLowPower"] as? NSObject, json)
            XCTAssertEqual(after["keptDisplayReadLit"] as? NSObject, before["keptDisplayReadLit"] as? NSObject, json)
        }
    }

    /// A record of the kept entry from an earlier boot, or one with no boot
    /// as builds before the boot wrote it: the record gets this boot in a
    /// journal published before `lowpowermode 0` runs, and the log says so
    /// first. When that command then fails, the record keeps this boot next
    /// to the claim, which the app reads as its own mode on in this boot:
    /// the mode is still on. The retry in the same boot switches the mode
    /// off without publishing the boot again.
    func testBackstopPublishesThisBootBeforeTheModeGoesOffEvenWhenTheCommandFails() throws {
        for records in [#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A","keptDisplayReadLit":0.8"#, #""keptDisplayUnderLowPower":0.8"#] {
            let json = Self.keptDisplayJournal(records)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            let sessionBytes = try Data(contentsOf: f.session)
            try f.writeState(json)
            f.setMode("sudo", "fail")

            let r = try f.run(f.backstop)

            XCTAssertNotEqual(r.status, 0, json)
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(json): \(f.calls())")
            let after = try f.stateJSON()
            XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, true, json)
            XCTAssertEqual(after["sleepDisabledByUs"] as? Bool, true, json)
            XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, f.bootUUID, json)
            XCTAssertEqual(after["keptDisplayUnderLowPower"] as? Double, 0.8, json)
            XCTAssertEqual(after["savedDisplayBrightness"] as? Double, 0.8, json)
            XCTAssertEqual(after["displayRestoreRefused"] as? Bool, true, json)
            XCTAssertEqual(try Data(contentsOf: f.session), sessionBytes, "session kept: \(json)")
            let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: f.state))
            XCTAssertFalse(decoded.lowPowerClaimFromEarlierBoot(boot: f.bootUUID), "the claim is this boot's: \(json)")
            XCTAssertTrue(decoded.keptDisplayReadUnderLowPower(inBoot: f.bootUUID), json)
            let log = f.log()
            let stamped = try XCTUnwrap(log.range(of: "kept display entry's record given this boot (\(f.bootUUID)) before Low Power Mode is switched off"), log)
            let failed = try XCTUnwrap(log.range(of: "pmset -b lowpowermode 0 failed; keeping journal entry for retry"), log)
            XCTAssertLessThan(stamped.lowerBound, failed.lowerBound, "published before the command")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.home.path).filter { $0.hasPrefix(".state.json.backstop") }, [])

            f.setMode("sudo", "ok")
            let again = try f.run(f.backstop)

            XCTAssertEqual(again.status, 0, json + again.stderr + f.log())
            let retried = try f.stateJSON()
            XCTAssertEqual(retried["lowPowerSetByUs"] as? Bool, false, json)
            XCTAssertEqual(retried["keptDisplayUnderLowPowerBoot"] as? String, f.bootUUID, json)
            XCTAssertEqual(f.log().components(separatedBy: "given this boot").count - 1, 1, "not published again in the same boot: \(f.log())")
            XCTAssertFalse(f.exists(f.session), json)
        }
    }

    /// R25-4: the journal published before Low Power Mode goes off is
    /// checked through the script's HEAD, never a `head` found in PATH.
    /// With a `head` first in PATH that prints something else for that
    /// copy, the record still gets this boot before the mode goes off and
    /// everything else stays as with the ordinary PATH.
    func testBackstopPublishesThisBootThroughItsOwnHeadWhateverPathHolds() throws {
        for hostilePath in [false, true] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A","keptDisplayReadLit":0.8"#)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)
            let dir = f.root.appendingPathComponent("hostile-head", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let head = dir.appendingPathComponent("head")
            try """
            #!/bin/bash
            printf 'head %s\\n' "$*" >> '\(f.hostileLog.path)'
            if [[ "$*" == "-c 1 "*".state.json.backstop-boot."* ]]; then printf x; exit 0; fi
            exec /usr/bin/head "$@"
            """.write(to: head, atomically: true, encoding: .utf8)
            XCTAssertEqual(chmod(head.path, 0o755), 0)

            let r = try f.run(f.backstop, extraEnvironment: hostilePath ? ["PATH": f.path(first: dir.path)] : [:])

            XCTAssertEqual(r.status, 0, "\(hostilePath): \(r.stderr + f.log())")
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(hostilePath): \(f.calls())")
            XCTAssertTrue(f.log().contains("kept display entry's record given this boot (\(f.bootUUID)) before Low Power Mode is switched off"), "\(hostilePath): \(f.log())")
            let after = try f.stateJSON()
            XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false, "\(hostilePath)")
            XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, f.bootUUID, "\(hostilePath)")
            XCTAssertEqual(after["keptDisplayUnderLowPower"] as? Double, 0.8, "\(hostilePath)")
            XCTAssertEqual(after["keptDisplayReadLit"] as? Double, 0.8, "\(hostilePath)")
            XCTAssertEqual(after["savedDisplayBrightness"] as? Double, 0.8, "\(hostilePath)")
            XCTAssertEqual(after["displayRestoreRefused"] as? Bool, true, "\(hostilePath)")
            let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: f.state))
            XCTAssertTrue(decoded.keptDisplayReadUnderLowPower(inBoot: f.bootUUID), "\(hostilePath)")
            XCTAssertFalse(decoded.lowPowerClaimFromEarlierBoot(boot: f.bootUUID), "\(hostilePath)")
            XCTAssertTrue(f.toolCalls().contains { $0.hasPrefix("head -c 1 ") && $0.contains(".state.json.backstop-boot.") }, "\(hostilePath): \(f.toolCalls())")
            XCTAssertEqual(f.hostileCalls(), [], "\(hostilePath): no head is taken from PATH")
            if hostilePath {
                XCTAssertTrue(!f.toolPaths().isEmpty && f.toolPaths().allSatisfy { $0.hasPrefix(dir.path + ":") }, "PATH was in effect: \(f.toolPaths())")
            }
        }
    }

    /// A record that already has this boot needs nothing before the mode
    /// goes off: one journal is published, after the undo.
    func testBackstopPublishesNothingBeforeTheModeGoesOffForARecordOfThisBoot() throws {
        let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"\#(fx.bootUUID)""#)
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(json)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -b lowpowermode 0"), "\(fx.calls())")
        XCTAssertFalse(fx.log().contains("given this boot"), fx.log())
        let after = try fx.stateJSON()
        XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, fx.bootUUID)
    }

    /// The Mac restarts after a run that gave the record its boot but could
    /// not switch the mode off: the next run gives the record the new boot
    /// before it does.
    func testBackstopGivesTheRecordTheNewBootAfterARestart() throws {
        let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A""#)
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(json)
        fx.setMode("sudo", "fail")
        _ = try fx.run(fx.backstop)
        XCTAssertEqual(try fx.stateJSON()["keptDisplayUnderLowPowerBoot"] as? String, fx.bootUUID)

        let newBoot = "5A5A5A5A-6666-7777-8888-999999999999"
        try newBoot.write(to: fx.root.appendingPathComponent("boot.uuid"), atomically: true, encoding: .utf8)
        fx.setMode("sudo", "ok")
        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        let after = try fx.stateJSON()
        XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, newBoot)
        XCTAssertTrue(fx.log().contains("kept display entry's record given this boot (\(newBoot)) before Low Power Mode is switched off"), fx.log())
    }

    /// The mode goes off, and then the journal of the undo cannot be
    /// published (its rename fails). state.json still says the mode and
    /// sleep are ours, but its record already has this boot, published
    /// before the mode went off, so the app reads the claim as its own
    /// mode on in this boot. A retry once the rename works clears the
    /// claim.
    func testAFailedFinalPublishLeavesTheRecordWithThisBoot() throws {
        let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A","keptDisplayReadLit":0.8"#)
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let sessionBytes = try Data(contentsOf: fx.session)
        try fx.writeState(json)
        try fx.failMoves([("*/.state.json.backstop.*", "*")])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -b lowpowermode 0"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("mv FAILED \(fx.home.path)/.state.json.backstop.") }, "\(fx.calls())")
        XCTAssertTrue(fx.log().contains("could not publish the updated journal to \(fx.state.path) (the edited copy could not be renamed over it); previous journal kept, will retry"), fx.log())
        let after = try fx.stateJSON()
        XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, true)
        XCTAssertEqual(after["sleepDisabledByUs"] as? Bool, true)
        XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, fx.bootUUID)
        XCTAssertEqual(after["keptDisplayReadLit"] as? Double, 0.8)
        XCTAssertEqual(try Data(contentsOf: fx.session), sessionBytes)
        let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: fx.state))
        XCTAssertFalse(decoded.lowPowerClaimFromEarlierBoot(boot: fx.bootUUID))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fx.home.path).filter { $0.hasPrefix(".state.json.backstop") }, [])

        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("mv.fail"))
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr + fx.log())
        let retried = try fx.stateJSON()
        XCTAssertEqual(retried["lowPowerSetByUs"] as? Bool, false)
        XCTAssertEqual(retried["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(retried["keptDisplayUnderLowPowerBoot"] as? String, fx.bootUUID)
        XCTAssertFalse(fx.exists(fx.session))
    }

    /// The journal with this boot cannot be published before the mode
    /// goes off, by a failed rename or a state.json that refuses every
    /// change: the mode is left on and its entry kept for the retry,
    /// since switched off with the earlier boot on disk, the app could
    /// take the panel coming back from it for the user's level. The rest
    /// of the undo still runs: sleep and the frozen process.
    func testBackstopLeavesTheModeOnWhenItCannotPublishThisBootFirst() throws {
        let frozen = #""frozenProcesses":[{"pid":4242,"startedAt":1789388423,"startedAtMicros":17,"bootSession":"\#(fx.bootUUID)"}]"#
        let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A""#)
            .replacingOccurrences(of: #""frozenProcesses":[]"#, with: frozen)
        for immutable in [false, true] {
            let f = try ScriptFixture()
            defer {
                try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)
                f.destroy()
            }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            let sessionBytes = try Data(contentsOf: f.session)
            try f.writeState(json)
            if immutable {
                try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: f.state.path)
            } else {
                try f.failMoves([("*/.state.json.backstop-boot.*", "*")])
            }

            let r = try f.run(f.backstop)
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)

            let label = immutable ? "immutable" : "rename fails"
            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), "\(label): \(f.calls())")
            XCTAssertTrue(f.calls().contains { $0.hasPrefix("Insomnia --resume-frozen") && $0.contains("4242 1789388423 17") }, "\(label): \(f.calls())")
            XCTAssertFalse(f.calls().contains { $0.contains("lowpowermode") }, "\(label): \(f.calls())")
            let log = f.log()
            XCTAssertTrue(log.contains("could not publish this boot for the kept display entry's record to \(f.state.path); Low Power Mode left on, keeping journal entry for retry"), log)
            if immutable {
                XCTAssertTrue(log.contains("could not publish the updated journal to \(f.state.path) (the edited copy could not be renamed over it); previous journal kept, will retry"), log)
            } else {
                XCTAssertTrue(log.contains("still journaled: Low Power Mode is still set: state.json could not take this boot for the kept display entry's record, so the mode was not switched off"), log)
            }
            XCTAssertFalse(log.contains("given this boot"), log)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.home.path).filter { $0.hasPrefix(".state.json.backstop") }, [], label)
            XCTAssertEqual(try Data(contentsOf: f.session), sessionBytes, label)
            if immutable {
                XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), json, "nothing could be written")
            } else {
                let after = try f.stateJSON()
                XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, true, label)
                XCTAssertEqual(after["sleepDisabledByUs"] as? Bool, false, "the rest of the undo is published: \(label)")
                XCTAssertEqual((after["frozenProcesses"] as? [Any])?.count, 0, label)
                XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, "boot A", label)
            }
        }
    }

    /// uninstall.sh runs the backstop it installed, which publishes this
    /// boot before the mode goes off. When its final journal then cannot be
    /// published, the uninstall stops with everything in place, and the
    /// record keeps this boot.
    func testUninstallStopsAfterAFailedFinalPublishWithTheRecordGivenThisBoot() throws {
        for purge in [false, true] {
            let json = Self.keptDisplayJournal(#""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"boot A""#)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)
            try f.failMoves([("*/.state.json.backstop.*", "*")])

            let r = try f.run(f.uninstall, purge ? ["--purge"] : [])

            XCTAssertNotEqual(r.status, 0, "purge \(purge)")
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(f.calls())")
            XCTAssertTrue(f.exists(f.app))
            XCTAssertTrue(f.exists(f.plist))
            XCTAssertTrue(f.exists(f.sudoers))
            XCTAssertTrue(f.exists(f.session))
            let after = try f.stateJSON()
            XCTAssertEqual(after["lowPowerSetByUs"] as? Bool, true)
            XCTAssertEqual(after["keptDisplayUnderLowPowerBoot"] as? String, f.bootUUID)
        }
    }

    // MARK: - Process observation failures (entries without microseconds)

    func testPsCommandFailureKeepsEntryWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[{"pid":777,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"}]}
        """)
        fx.setMode("ps", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "\(fx.calls())")
        let s = try fx.stateJSON()
        XCTAssertEqual((s["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 777, "unobservable is not gone")
        XCTAssertEqual(s["dockerFrozen"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("could not be observed"), fx.log())
    }

    func testPsUnparseableOutputKeepsEntryWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[{"pid":778,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"}]}
        """)
        fx.setMode("ps", "garbage")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "\(fx.calls())")
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 778)
        XCTAssertTrue(fx.log().contains("could not be observed"), fx.log())
    }

    func testSysctlFailureKeepsEntryWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[{"pid":779,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
        """)
        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("boot.uuid"))
        try fx.psTable([(779, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "no ps lookup and no signal without a boot session to compare")
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])?.first?["pid"] as? Int, 779)
    }

    // MARK: - Microsecond identity through the app binary

    private func writeMicrosecondEntry(pid: Int, started: Int, micros: Int, boot: String? = nil, extra: String = "") throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[{"pid":\(pid),"startedAt":\(started),"startedAtMicros":\(micros),"bootSession":"\(boot ?? fx.bootUUID)"\(extra)}]}
        """)
    }

    private func onlyFrozenEntry() throws -> [String: Any]? {
        (try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])?.first
    }

    /// Polls `condition` every 0.05 s; false if it does not hold within
    /// `seconds`.
    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    /// The shell passes the four identity fields through unchanged, as one
    /// line on the binary's standard input, and never runs ps or kill for
    /// such an entry. "resumed" clears it. The binary's parent is the
    /// backstop shell itself: no supervisor process sits between them that
    /// could reap it before the shell decides whether to signal it.
    func testMicrosecondEntryIsHandedToTheAppBinaryWithItsFullIdentity() throws {
        let started = 1_789_388_423
        try writeMicrosecondEntry(pid: 5100, started: started, micros: 654_321)
        try fx.psTable([(5100, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["Insomnia --resume-frozen 2 < 5100 \(started) 654321 \(fx.bootUUID)"])
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)
        XCTAssertEqual(try fx.stateJSON()["dockerFrozen"] as? Bool, false)
        XCTAssertTrue(fx.log().contains("SIGCONT sent to pid 5100 by the app binary"), fx.log())
        let parent = try String(contentsOf: fx.root.appendingPathComponent("insomnia.ppid"), encoding: .utf8)
        XCTAssertEqual(parent.trimmingCharacters(in: .whitespacesAndNewlines), String(fx.lastPid), "the binary is not a direct child of the backstop shell")
    }

    /// Microseconds of 0 are an identity too (the key is present), not a
    /// missing value: the binary is asked, ps is not.
    func testZeroMicrosecondsStillUsesTheAppBinary() throws {
        let started = 1_789_388_423
        try writeMicrosecondEntry(pid: 5101, started: started, micros: 0)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["Insomnia --resume-frozen 2 < 5101 \(started) 0 \(fx.bootUUID)"])
    }

    func testAppBinaryGoneClearsTheEntryWithoutSignal() throws {
        try writeMicrosecondEntry(pid: 5102, started: 1_789_388_423, micros: 5)
        try fx.insomniaTable([(5102, "gone")])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "\(fx.calls())")
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)
        XCTAssertTrue(fx.log().contains("pid 5102 is gone, running, or not the process we froze"), fx.log())
        XCTAssertFalse(fx.exists(fx.session))
    }

    /// failed, unobserved and unverifiable keep the entry verbatim for the
    /// next run, with the journal dirty and the session file in place.
    func testAppBinaryFailedUnobservedAndUnverifiableKeepTheEntry() throws {
        for (word, expectation) in [("failed", "SIGCONT failed"), ("unobserved", "could not be verified"), ("unverifiable", "could not be verified")] {
            fx.destroy()
            fx = try ScriptFixture()
            try writeMicrosecondEntry(pid: 5103, started: 1_789_388_423, micros: 9, extra: #","note":"custom""#)
            try fx.insomniaTable([(5103, word)])

            let r = try fx.run(fx.backstop)

            XCTAssertNotEqual(r.status, 0, word)
            let entry = try XCTUnwrap(try onlyFrozenEntry(), word)
            XCTAssertEqual(entry["pid"] as? Int, 5103, word)
            XCTAssertEqual(entry["startedAtMicros"] as? Int, 9, "\(word): identity must survive for the next attempt")
            XCTAssertEqual(entry["note"] as? String, "custom", word)
            XCTAssertEqual(try fx.stateJSON()["dockerFrozen"] as? Bool, true, word)
            XCTAssertTrue(fx.exists(fx.session), word)
            XCTAssertTrue(fx.log().contains(expectation), "\(word): \(fx.log())")
        }
    }

    /// No app binary at the fixed path: the entry is kept, nothing is
    /// signaled, and the log names the path. The shell does not fall back
    /// to its one-second comparison.
    func testMissingAppBinaryKeepsTheEntryWithoutSignal() throws {
        let started = 1_789_388_423
        try writeMicrosecondEntry(pid: 5104, started: started, micros: 1)
        try fx.psTable([(5104, fx.lstart(started), "T", fx.uid)])
        try FileManager.default.removeItem(at: fx.fakeInsomnia)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [], "ps or kill ran although the identity check needs the app binary")
        XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5104)
        XCTAssertTrue(fx.log().contains("\(fx.fakeInsomnia.path) is missing or not executable"), fx.log())
        XCTAssertTrue(fx.exists(fx.session))
    }

    /// The answer is checked whole. A word the shell does not know, a known
    /// word with the wrong exit status, the wrong pid, anything before or
    /// after the word, or a missing or extra line is not acted on: the entry
    /// is kept, nothing is signaled, and the log carries the answer.
    func testUnexpectedAppBinaryAnswerKeepsTheEntry() throws {
        let cases: [(output: String, status: Int)] = [
            ("5105 bogus\n", 0),
            ("5105 resumed\n", 1),
            ("5105 gone\n", 1),
            ("5105 failed\n", 0),
            ("", 0),
            ("", 70),
            ("usage\n", 64),
            ("resumed\n", 0),
            ("5106 resumed\n", 0),
            ("5105 resumed extra\n", 0),
            ("5105 resumed\nextra\n", 0),
            ("5105 resumed\n5105 resumed\n", 0),
            ("5105 resumed\n\n", 0),
            (" 5105 resumed\n", 0),
            ("5105  resumed\n", 0),
            ("5105 resumed\r\n", 0),
            ("05105 resumed\n", 0),
        ]
        for (output, status) in cases {
            let label = "\(output.debugDescription) exit \(status)"
            fx.destroy()
            fx = try ScriptFixture()
            try writeMicrosecondEntry(pid: 5105, started: 1_789_388_423, micros: 2)
            try fx.insomniaRaw(output, status: status)

            let r = try fx.run(fx.backstop)

            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertEqual(fx.calls().filter { !$0.hasPrefix("Insomnia --resume-frozen") }, [], label)
            XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5105, label)
            XCTAssertEqual(try fx.stateJSON()["dockerFrozen"] as? Bool, true, label)
            XCTAssertTrue(fx.exists(fx.session), label)
            XCTAssertTrue(fx.log().contains("unexpected answer from \(fx.fakeInsomnia.path) for pid(s) 5105 (exit \(status), output '"), "\(label): \(fx.log())")
        }
        // Control characters are logged as spaces, on one line.
        XCTAssertTrue(fx.log().contains("output '05105 resumed '"), fx.log())
    }

    /// Another boot session is settled by the shell: cleared without a
    /// lookup, so the binary is not run.
    func testMicrosecondEntryFromAnotherBootIsClearedWithoutRunningTheBinary() throws {
        try writeMicrosecondEntry(pid: 5106, started: 1_789_388_423, micros: 3, boot: "other-boot")

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)
    }

    /// Negative microseconds pass the shape check (an integer) but are not
    /// an identity the binary accepts: kept, binary not run.
    func testNegativeMicrosecondsKeepTheEntryWithoutRunningTheBinary() throws {
        try writeMicrosecondEntry(pid: 5107, started: 1_789_388_423, micros: -1)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5107)
        XCTAssertTrue(fx.log().contains("startedAtMicros (-1); kept, not signaled"), fx.log())
    }

    /// Mixed journal: the entry without microseconds keeps the ps path in
    /// the loop, the entry with microseconds goes to the binary after it.
    func testEntriesWithAndWithoutMicrosecondsTakeTheirOwnPath() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[
           {"pid":5108,"startedAt":\(started),"startedAtMicros":8,"bootSession":"\(fx.bootUUID)"},
           {"pid":5109,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"}]}
        """)
        try fx.psTable([(5108, fx.lstart(started), "T", fx.uid), (5109, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), [
            "ps -o lstart=,stat=,uid= -p 5109",
            "kill -CONT 5109",
            "Insomnia --resume-frozen 2 < 5108 \(started) 8 \(fx.bootUUID)",
        ])
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)
    }

    /// Every entry with microseconds goes to the binary in one call, after
    /// the shell-path entries. Kept entries are republished in journal
    /// order, not in the order they were settled.
    func testMicrosecondEntriesShareOneCallAndKeptEntriesKeepJournalOrder() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[
           {"pid":5201,"startedAt":\(started),"startedAtMicros":1,"bootSession":"\(fx.bootUUID)","note":"a"},
           {"pid":5202},
           {"pid":5203,"startedAt":\(started),"startedAtMicros":3,"bootSession":"\(fx.bootUUID)"},
           {"pid":5204,"startedAt":\(started),"bootSession":"\(fx.bootUUID)"},
           {"pid":5205,"startedAt":\(started),"startedAtMicros":5,"bootSession":"\(fx.bootUUID)","note":"e"},
           {"pid":5206,"startedAt":\(started),"startedAtMicros":6,"bootSession":"\(fx.bootUUID)"}]}
        """)
        // 5204 (no microseconds) is gone; 5201 failed, 5203 resumed, 5205
        // unobserved, 5206 gone.
        try fx.insomniaTable([(5201, "failed"), (5205, "unobserved"), (5206, "gone")])

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [
            "ps -o lstart=,stat=,uid= -p 5204",
            "Insomnia --resume-frozen 2 < 5201 \(started) 1 \(fx.bootUUID); 5203 \(started) 3 \(fx.bootUUID); 5205 \(started) 5 \(fx.bootUUID); 5206 \(started) 6 \(fx.bootUUID)",
        ])
        let frozen = try XCTUnwrap(try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])
        XCTAssertEqual(frozen.map { $0["pid"] as? Int }, [5201, 5202, 5205], "journal order, not settle order")
        XCTAssertEqual(frozen.map { $0["note"] as? String }, ["a", nil, "e"], "kept verbatim")
        let log = fx.log()
        XCTAssertTrue(log.contains("SIGCONT to pid 5201 failed (app binary: failed)"), log)
        XCTAssertTrue(log.contains("SIGCONT sent to pid 5203 by the app binary"), log)
        XCTAssertTrue(log.contains("pid 5205 could not be verified (app binary: unobserved)"), log)
        XCTAssertTrue(log.contains("pid 5206 is gone, running, or not the process we froze (app binary: gone)"), log)
    }

    /// A binary that prints a correct answer but does not exit in time gets
    /// SIGTERM, and its answer is not used: every entry of the call is kept
    /// and the lock is free afterwards. The wait status in the log (143,
    /// 128 + SIGTERM) is the kernel's record that SIGTERM ended the fake,
    /// which sleeps for 300 s otherwise; no wall-clock bound is needed.
    func testAppBinaryThatDoesNotExitInTimeKeepsEveryEntry() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[
           {"pid":5301,"startedAt":\(started),"startedAtMicros":1,"bootSession":"\(fx.bootUUID)"},
           {"pid":5302,"startedAt":\(started),"startedAtMicros":2,"bootSession":"\(fx.bootUUID)"}]}
        """)
        fx.setMode("insomnia", "hang")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        let frozen = try XCTUnwrap(try fx.stateJSON()["frozenProcesses"] as? [[String: Any]])
        XCTAssertEqual(frozen.map { $0["pid"] as? Int }, [5301, 5302])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(try fx.lockIsFree())
        let log = fx.log()
        XCTAssertTrue(log.contains("did not answer within 1s; sent SIGTERM, and it ended (wait status 143)"), log)
        XCTAssertFalse(log.contains("SIGKILL"), log)
        XCTAssertTrue(log.contains("unexpected answer from \(fx.fakeInsomnia.path) for pid(s) 5301 5302 (exit 124"), log)
        XCTAssertEqual(try fx.contents(of: fx.home).filter { $0.hasPrefix(".backstop") }, [], "input and answer files removed")
        XCTAssertEqual(r.stderr, "", "bash's own report of the signaled job must not reach the caller")
    }

    /// A binary that ignores SIGTERM gets SIGKILL: the run still ends, the
    /// entry is kept, and the lock is free. The backstop runs with SIGTERM
    /// ignored, so the fake inherits SIG_IGN from its first instruction
    /// instead of racing to install a trap before the signal arrives. Wait
    /// status 137 (128 + SIGKILL) shows SIGKILL ended it.
    func testAppBinaryThatIgnoresSigtermIsKilled() throws {
        try writeMicrosecondEntry(pid: 5303, started: 1_789_388_423, micros: 3)
        fx.setMode("insomnia", "hang")

        let r = try fx.run(fx.backstop, ignoringTerm: true)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5303)
        XCTAssertTrue(try fx.lockIsFree())
        let log = fx.log()
        XCTAssertTrue(log.contains("did not answer within 1s and was still running 1s after SIGTERM; sent SIGKILL, and it ended (wait status 137)"), log)
        XCTAssertTrue(log.contains("(exit 124"), log)
        XCTAssertEqual(try fx.contents(of: fx.home).filter { $0.hasPrefix(".backstop") }, [], "input and answer files removed")
        XCTAssertEqual(r.stderr, "", "bash's own report of the signaled job must not reach the caller")
    }

    /// The binary runs with the recovery lock open on its fd 9, also when a
    /// caller handed its lock down on fd 9 (the uninstall path), and is
    /// told to end itself after COMMAND_TIMEOUT_SECONDS +
    /// KILL_GRACE_SECONDS (1 + 1 here).
    func testAppBinaryRunsWithTheRecoveryLockOnFd9() throws {
        try Data().write(to: fx.lock)
        let lockInode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: fx.lock.path)[.systemFileNumber] as? Int)
        let wrapper = fx.root.appendingPathComponent("holder-then-backstop.sh")
        try """
        #!/bin/bash
        set -eu
        exec 9<>"\(fx.lock.path)"
        /usr/bin/lockf -t 0 9
        /bin/bash "\(fx.backstop.path)"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        for run in [{ try self.fx.run(self.fx.backstop) }, { try self.fx.run(wrapper) }] {
            try writeMicrosecondEntry(pid: 5304, started: 1_789_388_423, micros: 4)
            fx.clearCalls()
            let r = try run()
            XCTAssertEqual(r.status, 0, r.stderr + fx.log())
            XCTAssertEqual(fx.calls(), ["Insomnia --resume-frozen 2 < 5304 1789388423 4 \(fx.bootUUID)"])
            let fd9 = try String(contentsOf: fx.root.appendingPathComponent("insomnia.fd9"), encoding: .utf8)
            XCTAssertEqual(fd9.trimmingCharacters(in: .whitespacesAndNewlines), String(lockInode), "the binary did not get the lock on fd 9")
        }
    }

    /// A backstop run that dies abruptly while the binary is still working
    /// must not free the recovery lock, or the binary could resume a
    /// process that a session started after that freezes. The binary keeps
    /// the lock on its fd 9 until it exits. The
    /// only process this test signals is the backstop shell it spawned
    /// itself, with SIGKILL, while that shell is still waiting for the
    /// binary (its limit is 30 s here). The shell is posix_spawned and
    /// reaped only after the signal, so its pid cannot have been reused,
    /// and if the binary never starts or the shell has already exited the
    /// test fails without signaling anything. The fake binary is never
    /// signaled: it ends on its own once the test creates insomnia.release.
    func testABackstopKilledMidCallLeavesTheLockHeldUntilTheBinaryEnds() throws {
        try writeMicrosecondEntry(pid: 5309, started: 1_789_388_423, micros: 9)
        fx.setMode("insomnia", "hold")
        let release = fx.root.appendingPathComponent("insomnia.release")
        let slow = fx.root.appendingPathComponent("backstop-30s.sh")
        try ScriptFixture.patch(try String(contentsOf: fx.backstop, encoding: .utf8), ["COMMAND_TIMEOUT_SECONDS": "30"])
            .write(to: slow, atomically: true, encoding: .utf8)

        let shell = try fx.spawn(slow)
        // The release first: a shell still running waits for the binary.
        defer {
            try? Data().write(to: release)
            shell.wait()
        }
        let call = "Insomnia --resume-frozen 31 < 5309 1789388423 9 \(fx.bootUUID)"
        guard waitUntil(10, { self.fx.calls().contains(call) }) else {
            return XCTFail("the binary never started, so the backstop was not signaled: \(fx.calls()) \(fx.log())")
        }
        guard !shell.hasExited else {
            return XCTFail("the backstop ended before the test could kill it (wait status \(shell.wait())), so it was not signaled: \(fx.log())")
        }
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the backstop did not end by SIGKILL (wait status \(status))")

        XCTAssertFalse(try fx.lockIsFree(), "the lock was free while the binary of a killed run could still send SIGCONT")
        XCTAssertFalse(fx.calls().contains("Insomnia released"))

        try Data().write(to: release)
        XCTAssertTrue(try fx.waitUntilLockIsFree(10), "the lock stayed held after the binary ended")
        XCTAssertTrue(fx.calls().contains("Insomnia released"))
        XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5309, "the killed run published nothing")
    }

    /// A binary that does not answer, with every poll the script makes a
    /// quarter second slower (see slowPollingPath). Its 4 s limit is read
    /// from bash's SECONDS clock, so it gets SIGTERM up to a second and a
    /// slow poll after the limit, and the run is over long before polls
    /// counted ten a second (about 16 s here) would have sent it.
    func testAppBinaryThatDoesNotAnswerIsStoppedOnTimeWhenEveryPollIsSlow() throws {
        try writeMicrosecondEntry(pid: 5311, started: 1_789_388_423, micros: 11)
        fx.setMode("insomnia", "hang")

        let started = Date()
        let r = try fx.run(try backstop(commandTimeout: 4), extraEnvironment: ["PATH": try fx.slowPollingPath()])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertGreaterThan(fx.slowPolls(), 0, "the script polled through the slow sleep")
        XCTAssertGreaterThan(elapsed, 4, "the binary had its whole limit")
        XCTAssertLessThan(elapsed, 9, "4 s, up to a second and a slow poll late, and the slow poll that sees it end")
        XCTAssertEqual(fx.calls(), ["Insomnia --resume-frozen 5 < 5311 1789388423 11 \(fx.bootUUID)"])
        XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5311)
        XCTAssertTrue(try fx.lockIsFree())
        let log = fx.log()
        XCTAssertTrue(log.contains("did not answer within 4s; sent SIGTERM, and it ended (wait status 143)"), log)
        XCTAssertFalse(log.contains("SIGKILL"), log)
    }

    /// The binary of an older build has no --resume-frozen mode and would
    /// start the menu bar app. The backstop runs the binary only when the
    /// bundle's Info.plist declares the interface version it speaks;
    /// otherwise it keeps every entry without running anything.
    func testAppThatDoesNotDeclareTheResumeFrozenVersionIsNeverRun() throws {
        let cases: [(String, () throws -> Void)] = [
            ("no Info.plist", {}),
            ("no key", { try ScriptFixture.infoPlist(resumeFrozenVersion: nil).write(to: self.fx.appInfo, atomically: true, encoding: .utf8) }),
            ("version 2", { try ScriptFixture.infoPlist(resumeFrozenVersion: "2").write(to: self.fx.appInfo, atomically: true, encoding: .utf8) }),
            ("a directory", { try FileManager.default.createDirectory(at: self.fx.appInfo, withIntermediateDirectories: false) }),
        ]
        for (label, setUp) in cases {
            try? FileManager.default.removeItem(at: fx.appInfo)
            try setUp()
            try writeMicrosecondEntry(pid: 5310, started: 1_789_388_423, micros: 10)
            fx.clearCalls()

            let r = try fx.run(fx.backstop)

            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertEqual(fx.calls(), [], "\(label): the binary ran")
            XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5310, label)
            XCTAssertTrue(fx.log().contains("pid 5310 needs the app binary for its microsecond identity check, but \(fx.appInfo.path) declares InsomniaResumeFrozenVersion"), "\(label): \(fx.log())")
            XCTAssertTrue(try fx.lockIsFree(), label)
        }
    }

    // MARK: - --own-bundle (install.sh's run of the staged copy)

    /// A copy of the fixture's backstop sealed in a bundle at `bundle`: a
    /// binary beside it records "OWN-BINARY <path it was run by>" and then
    /// answers as the fake app binary does, and its Info.plist declares
    /// InsomniaResumeFrozenVersion `version` (no key when nil). Returns the
    /// copy's path.
    private func writeOwnBundle(at bundle: URL, version: String?) throws -> URL {
        let fm = FileManager.default
        let script = bundle.appendingPathComponent("Contents/Resources/backstop.sh")
        let binary = bundle.appendingPathComponent("Contents/MacOS/Insomnia")
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fx.backstop, to: script)
        try "#!/bin/bash\nprintf 'OWN-BINARY %s\\n' \"$0\" >> '\(fx.callsLog.path)'\nexec '\(fx.fakeInsomnia.path)' \"$@\"\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try ScriptFixture.infoPlist(resumeFrozenVersion: version).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return script
    }

    /// With --own-bundle the backstop runs the binary beside its own copy
    /// and reads the Info.plist beside it, never the installed app's. The
    /// installed app here declares the version and its binary answers, so a
    /// run that fell back to it would resume the entry as well; only the
    /// OWN-BINARY line tells them apart. When the Info.plist beside the copy
    /// does not declare the version, no binary runs, the installed one
    /// included, and the entry stays.
    func testOwnBundleUsesTheBinaryAndInfoPlistBesideItsCopy() throws {
        let script = try writeOwnBundle(at: fx.root.appendingPathComponent("staged/Insomnia.app"), version: "1")
        try writeMicrosecondEntry(pid: 5320, started: 1_789_388_423, micros: 20)

        let r = try fx.run(script, ["--own-bundle"])

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [
            "OWN-BINARY \(fx.root.path)/staged/Insomnia.app/Contents/MacOS/Insomnia",
            "Insomnia --resume-frozen 2 < 5320 1789388423 20 \(fx.bootUUID)",
        ])
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)

        let older = try writeOwnBundle(at: fx.root.appendingPathComponent("older/Insomnia.app"), version: nil)
        try writeMicrosecondEntry(pid: 5321, started: 1_789_388_423, micros: 21)
        fx.clearCalls()

        let kept = try fx.run(older, ["--own-bundle"])

        XCTAssertNotEqual(kept.status, 0)
        XCTAssertEqual(fx.calls(), [], "a binary ran")
        XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5321)
        XCTAssertEqual(try onlyFrozenEntry()?["startedAtMicros"] as? Int, 21)
        XCTAssertTrue(fx.log().contains("but \(fx.root.path)/older/Insomnia.app/Contents/Info.plist declares InsomniaResumeFrozenVersion '', not 1"), fx.log())
    }

    /// --own-bundle accepts only a copy run by a full path that ends in
    /// .app/Contents/Resources/backstop.sh. The checkout's copy, a loose
    /// copy, a copy elsewhere in a bundle and a bundle's copy run by a
    /// relative path all stop with exit 2 before the lock file is opened or
    /// the journal read: no binary runs, the installed app's included, and
    /// the entry and its microseconds stay. The same bundle copy run by its
    /// full path then resumes the entry, so the refusal came from the path.
    func testOwnBundleRefusesACopyOutsideABundlesResources() throws {
        let fm = FileManager.default
        try writeMicrosecondEntry(pid: 5322, started: 1_789_388_423, micros: 22)
        let journal = try Data(contentsOf: fx.state)
        let loose = fx.root.appendingPathComponent("loose/backstop.sh")
        let misplaced = fx.root.appendingPathComponent("odd/Insomnia.app/Contents/backstop.sh")
        for copy in [loose, misplaced] {
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: fx.backstop, to: copy)
        }
        let bundled = try writeOwnBundle(at: fx.root.appendingPathComponent("rel/Insomnia.app"), version: "1")
        let runs: [(label: String, run: () throws -> (status: Int32, output: String))] = [
            ("the checkout's copy", { let r = try self.fx.run(self.fx.backstop, ["--own-bundle"]); return (r.status, r.stdout + r.stderr) }),
            ("a loose copy", { let r = try self.fx.run(loose, ["--own-bundle"]); return (r.status, r.stdout + r.stderr) }),
            ("a copy outside Contents/Resources", { let r = try self.fx.run(misplaced, ["--own-bundle"]); return (r.status, r.stdout + r.stderr) }),
            ("a bundle's copy by a relative path", {
                try self.fx.runTool("/bin/bash", ["-c", #"cd "$1" && exec /bin/bash Insomnia.app/Contents/Resources/backstop.sh --own-bundle"#, "bash", self.fx.root.appendingPathComponent("rel").path])
            }),
        ]
        for (label, run) in runs {
            let r = try run()

            XCTAssertEqual(r.status, 2, "\(label): \(r.output)")
            XCTAssertTrue(r.output.contains("is not an absolute path ending in .app/Contents/Resources/backstop.sh; nothing was done"), "\(label): \(r.output)")
            XCTAssertEqual(fx.calls(), [], "\(label): a binary ran")
            XCTAssertEqual(try Data(contentsOf: fx.state), journal, label)
            XCTAssertFalse(fx.exists(fx.lock), "\(label): the lock file was opened")
            XCTAssertEqual(fx.log(), "", label)
        }

        let r = try fx.run(bundled, ["--own-bundle"])

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls().first, "OWN-BINARY \(fx.root.path)/rel/Insomnia.app/Contents/MacOS/Insomnia")
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)
    }

    // MARK: - Uninstall locking and interleaving

    func testUninstallRefusesWhileRecoveryLockIsHeld() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let holder = try fx.holdLock()
        defer { holder.stop() }

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 75, r.stderr)
        XCTAssertEqual(fx.calls().filter { !$0.hasPrefix("pgrep") }, [], "no recovery and no removal without the lock")
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(r.stderr.contains("Nothing was removed"), r.stderr)
    }

    func testUninstallRunsRecoveryUnderItsOwnLockAndKeepsLockInode() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try Data().write(to: fx.lock)
        let before = try fx.inode(fx.lock)

        let r = try fx.run(fx.uninstall)

        // With the lock held by the uninstaller for the whole run, the inner
        // backstop must share it (a second open would time out at 1 s -> 75).
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(fx.calls())")
        XCTAssertFalse(fx.log().contains("still held"), fx.log())
        XCTAssertTrue(fx.exists(fx.lock), "non-purge uninstall keeps the lock file")
        XCTAssertEqual(try fx.inode(fx.lock), before, "the lock inode is retained, never replaced")
        XCTAssertFalse(fx.exists(fx.state))
    }

    func testUninstallRefusesDeletionWhenAppRelaunchesAfterRecovery() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        // Not running at the first check, not running under the lock, then
        // running again by the time deletion is about to start.
        fx.setMode("pgrep", "1\n1\n0\n")

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "recovery still ran: \(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || Self.isRootRemoval($0) }, "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(r.stderr.contains("started again"), r.stderr)
    }

    func testUninstallRefusesWhenAppRelaunchesBeforeRecovery() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "1\n0\n")

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") }, "no recovery under a live app: \(fx.calls())")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.plist))
    }

    func testBackstopWithUnrelatedFd9DoesNotShareAForeignLock() throws {
        // A caller that happens to pass some other file as fd 9 must not be
        // mistaken for a lock holder: the backstop opens the real lock itself.
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let holder = try fx.holdLock()
        defer { holder.stop() }
        let other = fx.root.appendingPathComponent("other.file")
        try Data().write(to: other)

        let r = try fx.run(fx.backstop, [], fd9: other)

        XCTAssertEqual(r.status, 75, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    func testBackstopSharesLockHandedDownOnFd9() throws {
        // The uninstall path: the caller holds the lock and passes its handle.
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try Data().write(to: fx.lock)
        // A bash wrapper that takes the lock on fd 9 and then runs the backstop.
        let wrapper = fx.root.appendingPathComponent("holder-then-backstop.sh")
        try """
        #!/bin/bash
        set -eu
        exec 9<>"\(fx.lock.path)"
        /usr/bin/lockf -t 0 9
        /bin/bash "\(fx.backstop.path)"
        """.write(to: wrapper, atomically: true, encoding: .utf8)

        let r = try fx.run(wrapper)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertFalse(fx.log().contains("still held"), fx.log())
    }

    /// The inodes that decide whether fd 9 is the caller's lock come from
    /// STAT=/usr/bin/stat, never a stat found first on PATH. One that
    /// prints the same number for every file would let an unrelated fd 9
    /// pass for the lock while someone else holds it, and one that prints a
    /// new number each time would make the caller's own lock look foreign.
    /// Neither changes what the backstop does.
    func testLockSharingIgnoresAStatOnPATH() throws {
        let shadow = fx.root.appendingPathComponent("shadow", isDirectory: true)
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
        let shadowStat = shadow.appendingPathComponent("stat")
        let counter = fx.root.appendingPathComponent("shadow-stat-count")
        try """
        #!/bin/bash
        printf x >> '\(counter.path)'
        if [[ "${FAKE_STAT_SAME:-}" == 1 ]]; then echo 1; else wc -c < '\(counter.path)' | tr -d ' '; fi
        """.write(to: shadowStat, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shadowStat.path)
        let path = "\(shadow.path):/usr/bin:/bin:/usr/sbin:/sbin"
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        // An unrelated fd 9 while someone else holds the lock.
        let holder = try fx.holdLock()
        let other = fx.root.appendingPathComponent("other.file")
        try Data().write(to: other)
        var r = try fx.run(fx.backstop, [], fd9: other, extraEnvironment: ["PATH": path, "FAKE_STAT_SAME": "1"])
        holder.stop()
        XCTAssertEqual(r.status, 75, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(try fx.lockIsFree(), "the holder let go")

        // The caller's own lock, handed down on fd 9.
        try Data().write(to: fx.lock)
        let wrapper = fx.root.appendingPathComponent("holder-then-backstop.sh")
        try """
        #!/bin/bash
        set -eu
        exec 9<>"\(fx.lock.path)"
        /usr/bin/lockf -t 0 9
        /bin/bash "\(fx.backstop.path)"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        let logged = fx.log().count
        r = try fx.run(wrapper, extraEnvironment: ["PATH": path])
        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        let second = String(fx.log().dropFirst(logged))
        XCTAssertFalse(second.contains("still held"), second)
    }

    // MARK: - Final integration checks

    func testHungPowerCommandTimesOutReleasesLockAndKeepsJournalDirty() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "hang")
        let started = Date()

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "two 1 s timeouts, not two hung commands")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true, "ownership is preserved on timeout")
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertTrue(try fx.lockIsFree(), "a timed-out child must not keep the recovery lock")
        let log = fx.log()
        XCTAssertTrue(log.contains("did not finish within 1s; terminated with SIGTERM"), log)
        XCTAssertTrue(log.contains("journal kept dirty"), log)
    }

    func testHungCommandDoesNotBlockTheNextRunOrTheApp() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "hang")
        XCTAssertNotEqual(try fx.run(fx.backstop).status, 0)
        fx.setMode("sudo", "ok")
        fx.clearCalls()

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    func testUninstallNeverForceKillsAnAppThatRefusesToQuit() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "0\n")   // running, and it stays running

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("pkill") }, "a refused quit must stand: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(r.stderr.contains("refusing to quit"), r.stderr)
    }

    func testUninstallAbortsWhenAgentIsStillLoadedAfterBootout() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "bootout-fails-still-loaded")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.calls().contains("launchctl print gui/\(fx.uid)/com.insomnia.backstop"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { Self.isRootRemoval($0) }, "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.plist), "the agent file stays while launchd still lists the job")
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.config))
        XCTAssertTrue(fx.exists(fx.lock))
        XCTAssertTrue(r.stderr.contains("still loaded"), r.stderr)
    }

    func testUninstallPurgeKeepsLockInode() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try Data().write(to: fx.lock)
        let before = try fx.inode(fx.lock)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(fx.lock), "the lock is never unlinked, even on purge")
        XCTAssertEqual(try fx.inode(fx.lock), before)
        XCTAssertFalse(fx.exists(fx.state))
        XCTAssertFalse(fx.exists(fx.config))
        XCTAssertFalse(fx.exists(fx.logFile))
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertTrue(r.stdout.contains("Kept \(fx.lock.path)"), r.stdout)
    }

    func testCommandThatIgnoresSigtermIsNeverKilledAndKeepsTheLock() throws {
        // A "terminated" signal is not a dead child. The fake ignores TERM and
        // lives until this test releases it; the script must return while it
        // is still alive, leave the lock held until the command really ends,
        // and must not SIGKILL it (that would orphan a root pmset outside the
        // transaction).
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "ignore-term")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertNil(fx.commandEnded(), "the script returned while the command was still alive (it has not been released)")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "ownership retained")
        XCTAssertFalse(try fx.lockIsFree(), "the command survived SIGTERM, so it was not killed and still holds the lock")
        let log = fx.log()
        XCTAssertTrue(log.contains("did not finish within 1s"), log)
        XCTAssertTrue(log.contains("keeps the recovery lock"), log)
        XCTAssertTrue(log.contains("recovery stopped"), "the transaction ends right there: \(log)")
        XCTAssertFalse(log.contains("SIGKILL"), log)
        fx.setMode("sudo", "ok")
        fx.clearCalls()
        let blocked = try fx.run(fx.backstop)
        XCTAssertEqual(blocked.status, 75, "no new transaction while the command lives: \(blocked.stderr)")
        XCTAssertEqual(fx.calls(), [], "no mutation outside the lock")
        XCTAssertNil(fx.commandEnded(), "still alive before the release")
        fx.releaseCommand()
        XCTAssertTrue(try fx.waitUntilLockIsFree(), "the lock is released only when the command exits")
        XCTAssertEqual(fx.commandEnded(), "released", "the command ended because of the release, not the watchdog")
        let after = try fx.run(fx.backstop)
        XCTAssertEqual(after.status, 0, after.stderr + fx.log())
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    func testTimedOutLiveCommandStopsTheTransactionBeforeTheNextUndo() throws {
        // Both power flags are dirty and the first pmset ignores TERM. The run
        // must stop right there: no second privileged command while the first
        // is alive, no flag cleared, and the retry later clears both.
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "ignore-term")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertNil(fx.commandEnded(), "the script returned while the first command was still alive (not released)")
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "no second undo while the first is alive")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true)
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertFalse(try fx.lockIsFree(), "the live command keeps the lock")
        let log = fx.log()
        XCTAssertTrue(log.contains("keeps the recovery lock"), log)
        XCTAssertFalse(log.contains("lowpowermode"), "the second undo was never attempted: \(log)")
        fx.releaseCommand()
        XCTAssertTrue(try fx.waitUntilLockIsFree(), "the lock is released only when the command exits")
        XCTAssertEqual(fx.commandEnded(), "released", "ended by the release, not the watchdog")
        fx.setMode("sudo", "ok")
        fx.clearCalls()
        let after = try fx.run(fx.backstop)
        XCTAssertEqual(after.status, 0, after.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0", "sudo -n \(fx.fakePmset) -b lowpowermode 0"])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(try fx.stateJSON()["lowPowerSetByUs"] as? Bool, false)
    }

    func testLiveSupervisorDoesNotHoldACallersCapturePipe() throws {
        // A caller that captures the script's output (command substitution,
        // like uninstall.sh's helpers or a pipe) must get EOF when the script
        // exits, even though the supervisor and its live command go on.
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "ignore-term")
        let capture = fx.root.appendingPathComponent("capture.sh")
        try #"""
        #!/bin/bash
        out="$(/bin/bash "$1" 2>&1)"; rc=$?
        echo "captured rc=$rc"
        """#.write(to: capture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: capture.path)

        let r = try fx.run(capture, [fx.backstop.path])

        XCTAssertNil(fx.commandEnded(), "the capture got EOF while the command was still alive (not released): \(r.stdout) \(r.stderr)")
        XCTAssertTrue(r.stdout.contains("captured rc=1"), r.stdout + r.stderr)
        XCTAssertFalse(try fx.lockIsFree(), "the command is still alive and still holds the lock: \(r.stdout) \(r.stderr) \(fx.log())")
        fx.releaseCommand()
        XCTAssertTrue(try fx.waitUntilLockIsFree(), "the lock is released when the command exits")
        XCTAssertEqual(fx.commandEnded(), "released", "ended by the release, not the watchdog")
    }

    func testLockOutlivesASudoThatClosedItsInheritedHandle() throws {
        // Real sudo closes extra descriptors before running pmset, so nothing
        // may rely on the command inheriting the lock. This fake closes fd 9
        // first, ignores TERM and lives until this test releases it. The lock
        // must stay held by the script's supervisor until then, and no new
        // transaction may start in the meantime.
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "closes-fd9")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertNil(fx.commandEnded(), "the script returned while the command was still alive (not released)")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "ownership retained")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor, not the command, holds the lock")
        fx.setMode("sudo", "ok")
        fx.clearCalls()
        let blocked = try fx.run(fx.backstop)
        XCTAssertEqual(blocked.status, 75, "no new transaction while the command lives: \(blocked.stderr)")
        XCTAssertEqual(fx.calls(), [], "no mutation outside the lock")
        XCTAssertTrue(fx.log().contains("keeps the recovery lock"), fx.log())
        fx.releaseCommand()
        XCTAssertTrue(try fx.waitUntilLockIsFree(), "the lock is released when the command exits")
        XCTAssertEqual(fx.commandEnded(), "released", "ended by the release, not the watchdog")
        let after = try fx.run(fx.backstop)
        XCTAssertEqual(after.status, 0, after.stderr + fx.log())
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "the retry runs in its own transaction")
    }

    /// A command's supervisor writes its status only after it has reaped
    /// the command, so until the status is there the call's .pid file can
    /// name a pid the kernel has already given to another process. The fake
    /// sudo exits at once, after writing the pid of a sentinel this test
    /// started into its call's .pid file and putting a FIFO where the status
    /// goes, so the supervisor's status write waits until the test opens
    /// it. The run must not signal the sentinel, whatever the .pid file
    /// says, and with no status in time it stops the transaction: journal
    /// and session kept, no second undo. The supervisor holds the lock until
    /// it has written its status. The sentinel is a /bin/sleep this test
    /// posix_spawned and reaps only at the end, so its pid stays its own.
    func testALateStatusNeverLeadsToSignalingThePidInTheStatusFiles() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#)
        let sentinelScript = fx.root.appendingPathComponent("sentinel.sh")
        try "exec /bin/sleep 120\n".write(to: sentinelScript, atomically: true, encoding: .utf8)
        let sentinel = try fx.spawn(sentinelScript)
        defer {
            _ = sentinel.signal(SIGTERM)
            sentinel.wait()
        }
        try String(sentinel.pid).write(to: fx.root.appendingPathComponent("sentinel.pid"), atomically: true, encoding: .utf8)
        fx.setMode("sudo", "status-delayed")

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertFalse(sentinel.hasExited, "the pid read from the .pid file was signaled")
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0", "sudo STATUS-DELAYED"], "no second undo")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true)
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.session))
        let log = fx.log()
        XCTAssertTrue(log.contains("(pid \(sentinel.pid)): its supervisor reported no result within 6s"), "the pid is only logged: \(log)")
        XCTAssertTrue(log.contains("recovery stopped"), log)
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor has not written its status yet, so it still holds the lock")

        XCTAssertEqual(Array(fx.drainStatusFIFOs(within: 5).values), ["exit 0\n"], "the supervisor writes the status it got from wait")
        XCTAssertTrue(try fx.waitUntilLockIsFree(5), "the supervisor lets go of the lock once its status is written")
        XCTAssertFalse(sentinel.hasExited)

        fx.setMode("sudo", "ok")
        fx.clearCalls()
        let after = try fx.run(fx.backstop)
        XCTAssertEqual(after.status, 0, after.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0", "sudo -n \(fx.fakePmset) -b lowpowermode 0"])
        XCTAssertEqual(try fx.backstopFiles(), [], "the next run that took the lock itself removed the stopped call's files")
    }

    /// A power command that ignores SIGTERM, with every poll the script and
    /// its supervisor make a quarter second slower (see slowPollingPath).
    /// The supervisor reads its 4 s limit and its 1 s grace from bash's
    /// SECONDS clock: the command gets one SIGTERM, after its whole limit,
    /// and the run reports it still running after the grace. Each wait can
    /// end up to a second and a slow poll late. Counted in polls (ten a
    /// second) the two took about 20 s here.
    func testALiveCommandIsReportedOnTimeWhenEveryPollIsSlow() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "logs-term")

        let started = Date()
        let r = try fx.run(try backstop(commandTimeout: 4), extraEnvironment: ["PATH": try fx.slowPollingPath()])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertGreaterThan(fx.slowPolls(), 0, "the script polled through the slow sleep")
        XCTAssertGreaterThan(elapsed, 5, "the command had its whole 4 s limit and the 1 s grace")
        XCTAssertLessThan(elapsed, 12, "4 s and 1 s, up to a second and a slow poll late each, and the run's own slow poll")
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGTERM" }.count, 1, "\(fx.calls())")
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("sudo -n") }, ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "no second undo")
        XCTAssertNil(fx.commandEnded(), "never SIGKILLed")
        XCTAssertFalse(try fx.lockIsFree())
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        let log = fx.log()
        XCTAssertTrue(log.contains("did not finish within 4s and did not stop on SIGTERM"), log)
        XCTAssertTrue(log.contains("recovery stopped"), log)

        fx.releaseCommand()
        XCTAssertTrue(try fx.waitUntilLockIsFree(10))
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(fx.log().contains("left running after SIGTERM, has exited (wait status 0)"), fx.log())
    }

    /// The supervisor works alone once its run is gone. The fake sudo closes
    /// its fd 9, as sudo does, logs every SIGTERM and SIGHUP it gets and
    /// keeps running. The test kills the backstop shell with SIGKILL while
    /// it waits for the command, then sends SIGTERM, SIGHUP and SIGINT to
    /// the shell's whole process group, the way launchd signals what is
    /// left of a job's process group once the job has exited. The supervisor
    /// survives that, sends the command its own SIGTERM at the 3 s limit
    /// (never SIGKILL), and keeps the recovery lock until the command has
    /// exited and been reaped. What this test signals is the shell it
    /// posix_spawned as the leader of a new process group, and that group,
    /// before reaping the shell: until then neither the pid nor the group
    /// id can name another process.
    func testTheSupervisorOutlivesItsRunAndGroupSignalsAndHoldsTheLockUntilItReapsTheCommand() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "drops-fd9-logs-signals")

        let shell = try fx.spawn(try backstop(commandTimeout: 3), ownProcessGroup: true)
        defer {
            fx.releaseCommand()
            shell.wait()
        }
        guard let command = fx.hungPid("sudo", within: 10) else {
            _ = shell.signal(SIGKILL)
            return XCTFail("the command never started: \(fx.calls()) \(fx.log())")
        }
        guard !shell.hasExited else {
            return XCTFail("the backstop ended before the test could kill it (wait status \(shell.wait())): \(fx.log())")
        }
        // The fake wrote "ready" after its traps and before its pid, so
        // what was sent from here reaches a command whose traps are set.
        let ready = fx.sudoEvents()
        XCTAssertEqual(ready.count, 1, "\(ready)")
        XCTAssertTrue(ready.first?.hasPrefix("ready ") == true, "\(ready)")
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            XCTAssertEqual(shell.signalGroup(sig), 0, "signal \(sig)")
        }
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the backstop did not end by SIGKILL (wait status \(status))")

        XCTAssertTrue(waitUntil(15) { self.fx.calls().filter { $0 == "sudo SIGTERM" }.count == 2 },
                      "one SIGTERM from the group, one from the supervisor at the limit: \(fx.calls()) \(fx.sudoEvents())")
        XCTAssertTrue(waitUntil(10) { self.statusLines() == ["alive"] }, "the supervisor reached the end of the grace: \(self.statusLines()) \(fx.sudoEvents())")
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGTERM" }.count, 2, "\(fx.calls()) \(fx.sudoEvents())")
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGHUP" }.count, 1, "\(fx.calls()) \(fx.sudoEvents())")
        // The fake's own clock: its last SIGTERM came at the 3 s limit or
        // later (its SECONDS counts whole seconds, so at least 2), not
        // from something sent before then.
        let events = fx.sudoEvents()
        XCTAssertEqual(events.filter { $0.hasPrefix("TERM ") }.count, 2, "\(events)")
        XCTAssertEqual(events.filter { $0.hasPrefix("HUP ") }.count, 1, "\(events)")
        XCTAssertGreaterThanOrEqual(events.last { $0.hasPrefix("TERM ") }.flatMap { Int($0.dropFirst(5)) } ?? -1, 2, "\(events)")
        XCTAssertEqual(fx.calls().filter { !$0.hasPrefix("sudo SIG") }, ["sudo -n \(fx.fakePmset) -a disablesleep 0"],
                       "the command had closed fd 9, and nothing else ran")
        XCTAssertNil(fx.commandEnded(), "never SIGKILLed")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor still holds the lock for its live command")

        fx.releaseCommand()
        try assertLockHeldUntilGone(command, within: 10)
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(fx.log().contains("left running after SIGTERM, has exited"), fx.log())
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, true, "the killed run published nothing")
        XCTAssertEqual(s["lowPowerSetByUs"] as? Bool, true)
    }

    /// The supervisor ignores SIGTERM and SIGHUP, and a child inherits
    /// ignored signals, but the command must not: SIGTERM at its limit has
    /// to be able to stop it. The fake checks both from a shell that
    /// inherits its signal actions (see "signals-self"). As a check on the
    /// check, a backstop started with SIGTERM already ignored, which no
    /// launchd job is, cannot give the command the default back (bash keeps
    /// a signal ignored at its start ignored), and the fake sees that.
    func testTheUndoCommandStopsOnSigtermAndSighupThoughItsSupervisorIgnoresThem() throws {
        fx.setMode("sudo", "signals-self")
        for ignoringTerm in [false, true] {
            try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            fx.clearCalls()

            let r = try fx.run(fx.backstop, ignoringTerm: ignoringTerm)

            XCTAssertEqual(r.status, 0, r.stderr + fx.log())
            let survived = ignoringTerm ? ["sudo SURVIVED TERM"] : []
            XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"] + survived + ["sudo SIGNALS-CHECKED"], "ignoringTerm \(ignoringTerm)")
        }
    }

    /// Each call's status files go when the call ends, whatever the command
    /// did. A run that took the lock itself also removes the files earlier
    /// runs left: their supervisors held the lock while they lived. A run
    /// that shares its caller's lock leaves them, since an earlier run
    /// under that same lock may still have a supervisor waiting for its
    /// command.
    func testStatusFilesGoWithTheirCallAndLeftoversOnlyUnderTheRunsOwnLock() throws {
        let leftovers = [".backstop.4242.1.pid", ".backstop.4242.1.rc"]
        for name in leftovers {
            try "4242\n".write(to: fx.home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try Data().write(to: fx.lock)
        let sharing = fx.root.appendingPathComponent("holder-then-backstop.sh")
        try """
        #!/bin/bash
        set -eu
        exec 9<>"\(fx.lock.path)"
        /usr/bin/lockf -t 0 9
        /bin/bash "\(fx.backstop.path)"
        """.write(to: sharing, atomically: true, encoding: .utf8)

        for (mode, expected) in [("ok", Int32(0)), ("fail", 1), ("hang", 1)] {
            try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            fx.setMode("sudo", mode)

            let r = try fx.run(sharing)

            XCTAssertEqual(r.status, expected, "\(mode): \(r.stderr) \(fx.log())")
            XCTAssertEqual(try fx.backstopFiles(), leftovers, mode)
            XCTAssertTrue(try fx.lockIsFree(), mode)
        }
        XCTAssertTrue(fx.log().contains("terminated with SIGTERM"), fx.log())

        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "ok")
        let r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(try fx.backstopFiles(), [])
    }

    /// A copy of the fixture's backstop with COMMAND_TIMEOUT_SECONDS set to
    /// `seconds`.
    private func backstop(commandTimeout seconds: Int) throws -> URL {
        let url = fx.root.appendingPathComponent("backstop-\(seconds)s.sh")
        try ScriptFixture.patch(try String(contentsOf: fx.backstop, encoding: .utf8), ["COMMAND_TIMEOUT_SECONDS": String(seconds)])
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The lines in the bounded calls' .rc status files, in file name order.
    private func statusLines() -> [String] {
        let names = ((try? fx.backstopFiles()) ?? []).filter { $0.hasSuffix(".rc") }
        return names.compactMap { try? String(contentsOf: fx.home.appendingPathComponent($0), encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func testUninstallAbortsWhenBootoutAndPrintBothFailAmbiguously() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "ambiguous")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { Self.isRootRemoval($0) }, "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.plist), "an unproven bootout keeps the agent file")
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.config))
        XCTAssertTrue(r.stderr.contains("cannot tell"), r.stderr)
    }

    // MARK: - install.sh (fully redirected: fake build, signing, sudo, launchctl)

    func testInstallKeepsTheTrustedAgentWhenRecoveryIsUnresolved() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")          // pmset undo fails; install.sh's check still passes
        fx.setMode("launchctl", "loaded")   // an older agent is loaded

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootout") }, "the loaded agent is left alone: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootstrap") }, "\(calls)")
        XCTAssertTrue(calls.contains("launchctl print gui/\(fx.uid)/com.insomnia.backstop"), "the claim about the agent is checked: \(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted", "the trusted plist is untouched")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "ownership retained")
        XCTAssertTrue(r.stderr.contains("left as it was"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not verified"), "no schedule claim from print alone: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("every minute"), r.stderr)
        // A hand-run scripts/backstop.sh would hand frozen processes to the build at $APP, which may
        // predate --resume-frozen; the installer runs the staged build's copy with --own-bundle.
        XCTAssertFalse(r.stderr.contains("backstop.sh --force"), "no hand-run backstop.sh: \(r.stderr)")
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "install.sh")), [fx.install.path], "manual step reruns the installer")
        XCTAssertTrue(r.stderr.contains("not replaced"), r.stderr)
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the bundle the retained agent pins stays in place")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the staged build is discarded and nothing is set aside")
        XCTAssertTrue(r.stderr.contains("discarded"), r.stderr)
        XCTAssertTrue(try fx.lockIsFree(), "the transaction ends with the script")

        // A zip install has no scripts/ directory. The checked copy of the bundle is gone when the
        // script exits and the original was never checked in place, so the hint runs no script from
        // either; it names this installer again, which checks a new copy first.
        let prebuilt = try writePrebuiltAppAtAnAwkwardPath()
        let zip = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(zip.status, 1, zip.stderr + zip.stdout)
        XCTAssertFalse(zip.stderr.contains("/bin/bash"), "no hand-run backstop.sh: \(zip.stderr)")
        XCTAssertFalse(zip.stderr.contains("backstop.sh --force"), "nothing inside the unchecked bundle is run: \(zip.stderr)")
        XCTAssertEqual(try pastedWords(of: printedCommand(in: zip.stderr, containing: " --app ")), [fx.installRedirected.path, "--allow-unverified-origin", "--app", prebuilt.path], "manual step reruns the installer on the bundle")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
    }

    func testInstallDoesNotClaimAnAgentRetriesWhenNoneIsLoaded() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")
        // launchctl mode ok: `print` exits 113, nothing is loaded

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl bootstrap") || $0.hasPrefix("launchctl bootout") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.plist), "no agent file is written while recovery is unresolved")
        XCTAssertTrue(r.stderr.contains("No LaunchAgent"), r.stderr)
        XCTAssertTrue(r.stderr.contains("nothing retries"), r.stderr)
        XCTAssertFalse(r.stderr.contains("every minute"), "no retry is promised: \(r.stderr)")
    }

    /// The commands install.sh prints for pasting name paths inside the
    /// checkout it runs from. Under a checkout whose path has a space, double
    /// quotes and a `$`, bash and zsh still read each one back as that path.
    func testInstallQuotesTheCheckoutPathsInTheCommandsItPrints() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try fx.writeAgentPlist()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let checkout = fx.root.appendingPathComponent(#"My "src" $HOME"#, isDirectory: true)
        try FileManager.default.copyItem(at: fx.repoScripts.deletingLastPathComponent(), to: checkout)
        let install = checkout.appendingPathComponent("scripts/install.redirected.sh")
        fx.setMode("sudo", "fail")          // recovery stops the first run
        fx.setMode("launchctl", "loaded")

        let stopped = try fx.run(install, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(stopped.status, 1, stopped.stderr + stopped.stdout)
        XCTAssertEqual(
            try pastedWords(of: printedCommand(in: stopped.stderr, containing: "install.sh")),
            [checkout.appendingPathComponent("scripts/install.sh").path],
            "the manual step reruns the checkout's installer"
        )

        fx.setMode("sudo", "ok")
        let installed = try fx.run(install, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(installed.status, 0, installed.stderr + installed.stdout)
        let step = try XCTUnwrap(installed.stdout.split(separator: "\n").first { $0.contains("Uninstall:") }, installed.stdout)
        let uninstall = String(step.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(try pastedWords(of: uninstall), [checkout.appendingPathComponent("scripts/uninstall.sh").path], "the uninstaller of the checkout")
    }

    /// The indented line an install.sh message gives the user to paste.
    private func printedCommand(in output: String, containing marker: String) throws -> String {
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("  ") && $0.contains(marker) }, output)
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// The words bash and zsh (the default login shell) read from a pasted
    /// command line; set -- only assigns them, nothing runs.
    private func pastedWords(of line: String) throws -> [String] {
        var read: [[String]] = []
        for shell in [["/bin/bash"], ["/bin/zsh", "-f"]] {
            let r = try fx.runTool(shell[0], Array(shell.dropFirst()) + ["-c", #"eval "set -- $1" && printf '%s\n' "$@""#, "sh", line])
            XCTAssertEqual(r.status, 0, "\(shell[0]): \(r.output)")
            read.append(r.output.split(separator: "\n").map(String.init))
        }
        XCTAssertEqual(read[0], read[1], "bash and zsh read the same words from \(line)")
        return read[0]
    }

    /// An upgrade whose new agent cannot load: the previous plist is reloaded
    /// and the previous bundle is back at $APP before that, so the reloaded
    /// agent verifies the build it pins. The new bundle was in place only
    /// while its own agent was being loaded.
    func testInstallRestoresThePreviousAgentWhenBootstrapFails() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-bootstrap-fails-once")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let bootstraps = fx.calls().filter { $0.hasPrefix("launchctl bootstrap") }
        XCTAssertEqual(bootstraps.count, 2, "candidate, then the previous plist again: \(fx.calls())")
        XCTAssertTrue(bootstraps[0].contains("candidate-") && bootstraps[0].hasSuffix(".plist"), "loaded through a private candidate launchctl accepts: \(bootstraps)")
        XCTAssertEqual(bootstraps[1], "launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted", "the trusted plist was never modified")
        XCTAssertTrue(r.stderr.contains("loaded again"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not verified"), "reload success is not a schedule claim: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("every minute"), r.stderr)
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertEqual(
            fx.calls().filter { $0.hasPrefix("launchctl APP-") },
            ["launchctl APP-BINARY=#!/bin/bash during bootstrap", "launchctl APP-BINARY=previous during bootstrap"],
            "new bundle under the new agent's load, previous bundle under the previous agent's reload: \(fx.calls())"
        )
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the previous bundle is back for the previous agent")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "no staged or set-aside bundle is left")
        XCTAssertTrue(r.stderr.contains("put back"), r.stderr)
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"], "no staged leftovers")
    }

    func testInstallReplacesTheAgentAfterCleanRecovery() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try Data().write(to: fx.lock)
        let lockInode = try fx.inode(fx.lock)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "recovery ran with the new backstop: \(calls)")
        XCTAssertTrue(calls.contains("launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(calls)")
        let bootstraps = calls.filter { $0.hasPrefix("launchctl bootstrap") }
        XCTAssertEqual(bootstraps.count, 1, "\(calls)")
        XCTAssertTrue(bootstraps.first?.contains("candidate-") == true, "loaded through a private candidate: \(calls)")
        XCTAssertTrue(calls.contains("launchctl LOCK-HELD during bootstrap"), "recovery check and replacement are one lock transaction: \(calls)")
        XCTAssertFalse(calls.contains("launchctl LOCK-FREE during bootstrap"), "\(calls)")
        XCTAssertEqual(try fx.inode(fx.lock), lockInode, "the lock inode is preserved")
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertTrue(r.stdout.contains("launchctl print confirms"), r.stdout)
        let plist = try fx.plistOnDisk()
        XCTAssertEqual(plist["StartInterval"] as? Int, 60)
        // The plist must be exactly what the app builds for the same bundle
        // and requirement, or the app reloads the agent at every start.
        let expected = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", target: BackstopTarget(bundle: fx.app, requirement: fx.requirement))
        XCTAssertTrue(NSDictionary(dictionary: plist).isEqual(to: expected), "install.sh wrote \(plist), the app builds \(expected)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("codesign --verify --strict -R=\(fx.requirement) \(fx.appsDir.path)/.Insomnia.app.staging.") && $0.hasSuffix("/Insomnia.app") }, "the installer runs the agent's own check once, on the staged bundle: \(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash", "the new bundle is installed")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the previous bundle and the staging directory are gone")
        let bootout = try XCTUnwrap(calls.firstIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"))
        let swapped = try XCTUnwrap(calls.firstIndex(of: "launchctl APP-BINARY=#!/bin/bash during bootstrap"), "\(calls)")
        XCTAssertLessThan(bootout, swapped, "the previous agent is unloaded before its bundle is replaced: \(calls)")
        XCTAssertTrue(r.stdout.contains("replaced the previous"), r.stdout)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertTrue(fx.exists(fx.installedBackstop), "backstop.sh is sealed in the bundle")
        XCTAssertFalse(fx.exists(fx.legacyBackstop), "no writable copy is installed")
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/Info.plist")))
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/Resources/AppIcon.icns")), "the app icon is bundled")
        XCTAssertTrue(r.stdout.contains("Installed"), r.stdout)
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"])
    }

    // MARK: - install.sh over a build from before --resume-frozen

    /// The binary of an installed build from before --resume-frozen. Given
    /// any argument it would open the menu bar app; here it records
    /// "OLD-APP <arguments>".
    private func oldAppBinary(_ f: ScriptFixture) -> String {
        "#!/bin/bash\nprintf 'OLD-APP %s\\n' \"$*\" >> '\(f.callsLog.path)'\n"
    }

    /// The binary of the build being installed, a --resume-frozen
    /// responder. It records whether the recovery lock is held and the path
    /// it was run by ("STAGED-BINARY LOCK-HELD <path>"), then answers as the
    /// fixture's fake app binary does, which records the call and the inode
    /// on its fd 9.
    private func newBuildBinary(_ f: ScriptFixture) -> String {
        """
        #!/bin/bash
        \(f.lockHeldHere())
        if lock_held; then held=LOCK-HELD; else held=LOCK-FREE; fi
        printf 'STAGED-BINARY %s %s\\n' "$held" "$0" >> '\(f.callsLog.path)'
        exec '\(f.fakeInsomnia.path)' "$@"

        """
    }

    /// The Info.plist of the build being installed: what install.sh checks
    /// in a release bundle, and InsomniaResumeFrozenVersion 1 when
    /// `declares`, as Resources/Info.plist has it.
    private static func newBuildInfoPlist(declares: Bool) -> String {
        let key = declares ? "<key>InsomniaResumeFrozenVersion</key><integer>1</integer>" : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Insomnia</string>
        <key>CFBundleIdentifier</key><string>com.kgarg.insomnia</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>0.1.0</string>\(key)
        </dict></plist>

        """
    }

    /// An installed build from before --resume-frozen (an Info.plist
    /// without InsomniaResumeFrozenVersion, and oldAppBinary), its agent
    /// loaded from the plist that pins it, and the journal it left: an
    /// expired session and two frozen processes recorded with microseconds.
    /// The new build comes from this checkout (the fake swift's binroot) or,
    /// with `prebuilt`, from a release bundle. Either way its binary is
    /// newBuildBinary and its Info.plist declares the interface when
    /// `declares`. Returns the arguments for install.sh.
    private func writeUpgradeFromABuildWithoutResumeFrozen(_ f: ScriptFixture, prebuilt: Bool = false, declares: Bool = true) throws -> [String] {
        let fm = FileManager.default
        try f.prepareInstall()
        let oldBinary = f.app.appendingPathComponent("Contents/MacOS/Insomnia")
        try fm.createDirectory(at: oldBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldAppBinary(f).write(to: oldBinary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldBinary.path)
        try ScriptFixture.infoPlist(resumeFrozenVersion: nil).write(to: f.appInfo, atomically: true, encoding: .utf8)
        try f.writeAgentPlist()
        f.setMode("launchctl", "loaded")
        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try f.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":false,
         "frozenProcesses":[
           {"pid":5401,"startedAt":1789388423,"startedAtMicros":401,"bootSession":"\(f.bootUUID)"},
           {"pid":5402,"startedAt":1789388424,"startedAtMicros":402,"bootSession":"\(f.bootUUID)"}]}
        """)
        let info = Self.newBuildInfoPlist(declares: declares)
        let bundle = try prebuilt ? f.writePrebuiltApp() : nil
        let infoURL = bundle?.appendingPathComponent("Contents/Info.plist")
            ?? f.repoScripts.deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let binary = bundle?.appendingPathComponent("Contents/MacOS/Insomnia") ?? f.root.appendingPathComponent("binroot/Insomnia")
        try info.write(to: infoURL, atomically: true, encoding: .utf8)
        try newBuildBinary(f).write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return bundle.map { ["--allow-unverified-origin", "--app", $0.path] } ?? []
    }

    /// What a finished upgrade over that build shows. The staged binary,
    /// run by its path inside the staging directory with the recovery lock
    /// held on its fd 9, resumed both processes before the previous agent
    /// was unloaded. The old binary never ran, and the new pair is in place.
    private func assertUpgradeResumedWithTheStagedBinary(_ r: (status: Int32, stdout: String, stderr: String), file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout + fx.log(), file: file, line: line)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("OLD-APP") }, "the previous build's binary ran: \(calls)", file: file, line: line)
        let staged = calls.filter { $0.hasPrefix("STAGED-BINARY ") }
        XCTAssertEqual(staged.count, 1, "\(calls)", file: file, line: line)
        let run = try XCTUnwrap(staged.first, file: file, line: line)
        XCTAssertTrue(run.hasPrefix("STAGED-BINARY LOCK-HELD \(fx.appsDir.path)/.Insomnia.app.staging."), run, file: file, line: line)
        XCTAssertTrue(run.hasSuffix("/Insomnia.app/Contents/MacOS/Insomnia"), run, file: file, line: line)
        XCTAssertTrue(calls.contains("Insomnia --resume-frozen 2 < 5401 1789388423 401 \(fx.bootUUID); 5402 1789388424 402 \(fx.bootUUID)"), "\(calls)", file: file, line: line)
        let fd9 = try String(contentsOf: fx.root.appendingPathComponent("insomnia.fd9"), encoding: .utf8)
        XCTAssertEqual(fd9.trimmingCharacters(in: .whitespacesAndNewlines), String(try fx.inode(fx.lock)), "the binary did not get the recovery lock on fd 9", file: file, line: line)
        let resumed = try XCTUnwrap(calls.firstIndex(of: run), file: file, line: line)
        let bootout = try XCTUnwrap(calls.firstIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(calls)", file: file, line: line)
        XCTAssertLessThan(resumed, bootout, "resumed before the previous agent and bundle were replaced: \(calls)", file: file, line: line)
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0, file: file, line: line)
        for pid in [5401, 5402] {
            XCTAssertTrue(fx.log().contains("SIGCONT sent to pid \(pid) by the app binary"), fx.log(), file: file, line: line)
        }
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), newBuildBinary(fx), "the new build is at $APP", file: file, line: line)
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], file: file, line: line)
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "\(calls)", file: file, line: line)
        XCTAssertTrue(try fx.lockIsFree(), file: file, line: line)
    }

    /// Greptile P1 (issue comment 6046657261): an upgrade over a build that
    /// predates --resume-frozen, with processes it froze still journaled
    /// with microseconds. install.sh runs the staged copy's recovery with
    /// --own-bundle, so the staged binary, which declares the interface,
    /// resumes them before the swap. Before, the staged copy asked the
    /// installed bundle, which does not declare it, kept the entries and
    /// stopped the install after the rule was narrowed.
    func testUpgradeOverABuildWithoutResumeFrozenResumesWithTheStagedBinary() throws {
        let args = try writeUpgradeFromABuildWithoutResumeFrozen(fx)

        let r = try fx.run(fx.installRedirected, args, extraEnvironment: ["USER": "tester"])

        try assertUpgradeResumedWithTheStagedBinary(r)
    }

    /// The same upgrade from a release bundle (--app): the staged binary is
    /// the checked private copy's, staged, never the bundle at the --app
    /// path or the installed one.
    func testUpgradeFromAPrebuiltBundleOverABuildWithoutResumeFrozenResumesWithTheStagedBinary() throws {
        let args = try writeUpgradeFromABuildWithoutResumeFrozen(fx, prebuilt: true)

        let r = try fx.run(fx.installRedirected, args, extraEnvironment: ["USER": "tester"])

        try assertUpgradeResumedWithTheStagedBinary(r)
    }

    /// When the staged build cannot settle an entry, the entry stays as it
    /// was journaled, microseconds included, and the install stops at the
    /// recovery. The previous bundle, its Info.plist and the agent plist
    /// that pins it stay as they were, no agent is unloaded or loaded, the
    /// staged build is discarded, and the old binary never runs. A failed
    /// SIGCONT or an unverifiable process keeps that entry only; an answer
    /// that is malformed or late keeps both; a staged Info.plist without
    /// the interface runs no binary at all. Each case starts from a fresh
    /// fixture.
    func testUpgradeKeepsWhatTheStagedBinaryCannotResumeAndThePreviousPair() throws {
        let cases: [(label: String, declares: Bool, kept: [Int], setUp: (ScriptFixture) throws -> Void)] = [
            ("a failed SIGCONT", true, [5401], { try $0.insomniaTable([(5401, "failed")]) }),
            ("an unverifiable process", true, [5402], { try $0.insomniaTable([(5402, "unverifiable")]) }),
            ("a malformed answer", true, [5401, 5402], { try $0.insomniaRaw("5401 resumed\n5402 resumed now\n", status: 0) }),
            ("no answer in time", true, [5401, 5402], { $0.setMode("insomnia", "hang") }),
            ("a staged build without the interface", false, [5401, 5402], { _ in }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            let args = try writeUpgradeFromABuildWithoutResumeFrozen(f, declares: c.declares)
            try c.setUp(f)
            let agentPlist = try Data(contentsOf: f.plist)

            let r = try f.run(f.installRedirected, args, extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 1, "\(c.label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("Install stopped: the backstop could not fully undo a previous session"), "\(c.label): \(r.stderr)")
            let calls = f.calls()
            XCTAssertFalse(calls.contains { $0.hasPrefix("OLD-APP") }, "\(c.label): the previous build's binary ran: \(calls)")
            let staged = calls.filter { $0.hasPrefix("STAGED-BINARY ") }
            if c.declares {
                XCTAssertEqual(staged.count, 1, "\(c.label): \(calls)")
                XCTAssertTrue(staged.first?.hasPrefix("STAGED-BINARY LOCK-HELD \(f.appsDir.path)/.Insomnia.app.staging.") == true, "\(c.label): \(staged)")
            } else {
                XCTAssertEqual(staged, [], c.label)
                XCTAssertTrue(f.log().contains("Insomnia.app/Contents/Info.plist declares InsomniaResumeFrozenVersion '', not 1"), "\(c.label): \(f.log())")
            }
            let entries = try XCTUnwrap(f.stateJSON()["frozenProcesses"] as? [[String: Any]], c.label)
            XCTAssertEqual(entries.map { $0["pid"] as? Int }, c.kept.map { Int?($0) }, c.label)
            XCTAssertEqual(entries.map { $0["startedAtMicros"] as? Int }, c.kept.map { Int?($0 - 5000) }, c.label)
            XCTAssertEqual(try String(contentsOf: f.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), oldAppBinary(f), "\(c.label): the previous build left $APP")
            XCTAssertEqual(try String(contentsOf: f.appInfo, encoding: .utf8), ScriptFixture.infoPlist(resumeFrozenVersion: nil), c.label)
            XCTAssertEqual(try Data(contentsOf: f.plist), agentPlist, "\(c.label): the agent plist changed")
            XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootout") || $0.hasPrefix("launchctl bootstrap") }, "\(c.label): \(calls)")
            XCTAssertEqual(try f.contents(of: f.appsDir), ["Insomnia.app"], "\(c.label): the staged build is discarded")
            XCTAssertTrue(r.stderr.contains("Finish the install by rerunning"), "\(c.label): \(r.stderr)")
            XCTAssertTrue(try f.lockIsFree(), c.label)
        }
    }

    // MARK: - install.sh --app (a prebuilt bundle, as from a release zip)

    /// The private copy install.sh --app checks and installs, read from the
    /// first deep verify in the recorded calls. Never the path passed in.
    /// A prebuilt bundle in a directory whose name has a space, double quotes
    /// and a `$`, all of which a command printed for pasting has to keep.
    private func writePrebuiltAppAtAnAwkwardPath() throws -> URL {
        let dir = fx.root.appendingPathComponent(#"My "dl" $HOME"#, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = dir.appendingPathComponent("Insomnia.app", isDirectory: true)
        try FileManager.default.moveItem(at: try fx.writePrebuiltApp(), to: app)
        return app
    }

    private func checkedCopy(of prebuilt: URL) throws -> String {
        let prefix = "codesign --verify --strict --deep "
        let call = try XCTUnwrap(fx.calls().first { $0.hasPrefix(prefix) }, "\(fx.calls())")
        let path = String(call.dropFirst(prefix.count))
        XCTAssertNotEqual(path, prebuilt.path, "checked at the path passed in")
        XCTAssertTrue(path.hasSuffix("/Insomnia.app"), path)
        return path
    }

    /// The prebuilt bundle is checked before the password prompt and
    /// installed as it is: no build, the signature verified with --deep,
    /// the identifier and version read, then the usual steps with the same
    /// agent plist a source install writes. An ad-hoc bundle's origin cannot
    /// be verified, so this takes --allow-unverified-origin and the installer
    /// says what that means.
    func testInstallFromPrebuiltAppVerifiesItBeforeSudoAndInstallsItWithoutBuilding() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("swift") }, "nothing is built: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("codesign --force") }, "the bundle is installed as signed: \(calls)")
        let copy = try checkedCopy(of: prebuilt)
        let verify = try XCTUnwrap(calls.firstIndex(of: "codesign --verify --strict --deep \(copy)"), "\(calls)")
        let auth = try XCTUnwrap(calls.firstIndex(of: "sudo -v"), "\(calls)")
        XCTAssertLessThan(verify, auth, "verified before the password prompt: \(calls)")
        XCTAssertTrue(r.stdout.contains("WARNING: the origin of Insomnia 0.1.0 is not verified. Its signature shows the bundle is intact, not who made it."), r.stdout)
        XCTAssertTrue(r.stdout.contains("--allow-unverified-origin: installing it anyway"), r.stdout)
        XCTAssertTrue(r.stdout.contains("macOS blocks the first launch"), r.stdout)
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "prebuilt")
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(prebuilt), "the source bundle is copied, not moved")
        let plist = try fx.plistOnDisk()
        let expected = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", target: BackstopTarget(bundle: fx.app, requirement: fx.requirement))
        XCTAssertTrue(NSDictionary(dictionary: plist).isEqual(to: expected), "same agent as a source install: \(plist)")
        XCTAssertTrue(r.stdout.contains("Uninstall:"), r.stdout)
    }

    /// The checks run on a private copy, and that copy is what gets staged
    /// and pinned. A bundle swapped at the --app path while the password
    /// prompt waits (the fake sudo does it during `sudo -v`) is never copied
    /// in.
    func testInstallFromPrebuiltAppInstallsTheCopyItCheckedNotABundleSwappedDuringThePrompt() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setMode("launchctl", "loaded")
        fx.setMode("sudo", "swap-prebuilt")

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try String(contentsOf: prebuilt.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "swapped", "the bundle at the --app path was replaced during the prompt")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "prebuilt", "the checked copy is installed")
        let copy = try checkedCopy(of: prebuilt)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasSuffix(" \(prebuilt.path)") }, "no tool reads the --app path itself: \(calls)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy), "the private copy is removed at exit")
    }

    /// A release zip unpacked inside a source checkout: the uninstaller the
    /// installer names is the one beside it, not the checkout's.
    func testInstallFromAZipInsideACheckoutNamesTheUninstallerBesideIt() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setMode("launchctl", "loaded")
        let unpacked = fx.repoScripts.deletingLastPathComponent().appendingPathComponent("Insomnia-0.1.0-macos", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fx.installRedirected, to: unpacked.appendingPathComponent("install.sh"))
        try "# the zip's uninstaller\n".write(to: unpacked.appendingPathComponent("uninstall.sh"), atomically: true, encoding: .utf8)
        XCTAssertTrue(fx.exists(fx.repoScripts.appendingPathComponent("uninstall.sh")), "the checkout around it has one too")

        let r = try fx.run(unpacked.appendingPathComponent("install.sh"), ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Uninstall:         \(unpacked.path)/uninstall.sh"), r.stdout)
    }

    /// A release zip has install.sh but no build-app.sh. Run without --app
    /// from a zip unpacked at /tmp/Insomnia-<version>, install.sh refuses
    /// before anything runs instead of running a scripts/build-app.sh that
    /// any account could have put in the parent folder.
    func testInstallFromAZipWithoutTheAppFlagRefusesAndRunsNoBuildScriptFromTheParentFolder() throws {
        try fx.prepareInstall()
        let shared = fx.root.appendingPathComponent("shared-tmp", isDirectory: true)
        let unpacked = shared.appendingPathComponent("Insomnia-0.1.0-macos", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fx.installRedirected, to: unpacked.appendingPathComponent("install.sh"))
        let planted = shared.appendingPathComponent("scripts/build-app.sh")
        try FileManager.default.createDirectory(at: planted.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\nprintf 'planted build-app.sh %s\\n' \"$*\" >> \"\(fx.callsLog.path)\"\nexit 1\n"
            .write(to: planted, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)

        let r = try fx.run(unpacked.appendingPathComponent("install.sh"), extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(fx.callsBesideScratchFiles(), [], "nothing ran, the planted script included")
        XCTAssertTrue(r.stderr.contains("\(unpacked.path) is not the scripts folder of a source checkout"), r.stderr)
        XCTAssertTrue(r.stderr.contains("pass it with --app"), r.stderr)
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// A build-app.sh added beside the zip's install.sh, as another account
    /// could do in a folder it created in /tmp before the zip was unpacked
    /// there. Without --app, install.sh builds only in a source checkout
    /// (scripts/ with Package.swift one level up), so it refuses, runs
    /// nothing and says the script was not run. Also in a folder named
    /// scripts with no Package.swift above it, and in a zip folder unpacked
    /// inside a checkout, which has Package.swift above it but is not
    /// scripts/.
    func testInstallFromAZipRunsNoBuildScriptPlantedBesideIt() throws {
        try fx.prepareInstall()
        for folder in ["shared-tmp/Insomnia-0.1.0-macos", "shared-tmp/scripts", "repo/Insomnia-0.1.0-macos"] {
            fx.clearCalls()
            let unpacked = fx.root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fx.installRedirected, to: unpacked.appendingPathComponent("install.sh"))
            let planted = unpacked.appendingPathComponent("build-app.sh")
            try "#!/bin/bash\nprintf 'planted build-app.sh %s\\n' \"$*\" >> \"\(fx.callsLog.path)\"\nexit 0\n"
                .write(to: planted, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: planted.path)

            let r = try fx.run(unpacked.appendingPathComponent("install.sh"), extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 1, "\(folder): " + r.stderr + r.stdout)
            XCTAssertEqual(fx.callsBesideScratchFiles(), [], "\(folder): nothing ran, the planted script included")
            XCTAssertTrue(r.stderr.contains("\(unpacked.path) is not the scripts folder of a source checkout"), r.stderr)
            XCTAssertTrue(r.stderr.contains("\(planted.path) was not run: a release zip has no build-app.sh"), r.stderr)
            XCTAssertFalse(fx.exists(fx.sudoers))
            XCTAssertFalse(fx.exists(fx.app))
        }
    }

    /// Release bundles are arm64 only. On a Mac whose hardware is not Apple
    /// Silicon (sysctl reads 0, or has no hw.optional.arm64), install.sh
    /// --app refuses before it copies or checks the bundle, and names the
    /// source build. A source build on the same Mac does not ask.
    func testInstallFromPrebuiltAppRefusesOnAMacThatIsNotAppleSilicon() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setMode("launchctl", "loaded")
        for (mode, read) in [("intel-0", "0"), ("intel-missing", "no value")] {
            fx.clearCalls()
            fx.setMode("sysctl", mode)

            let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 1, "\(mode): " + r.stderr + r.stdout)
            XCTAssertEqual(fx.callsBesideScratchFiles(), ["sysctl -n hw.optional.arm64"], "\(mode): nothing else ran: \(fx.calls())")
            XCTAssertTrue(r.stderr.contains("Release bundles of Insomnia run on Apple Silicon Macs only, and this Mac is not one ('sysctl -n hw.optional.arm64' gave \(read))."), r.stderr)
            XCTAssertTrue(r.stderr.contains("Build and install from a source checkout instead (README, Build from source). Nothing was changed."), r.stderr)
            XCTAssertFalse(fx.exists(fx.sudoers))
            XCTAssertFalse(fx.exists(fx.app))
        }

        fx.clearCalls()
        let built = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(built.status, 0, built.stderr + built.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sysctl") }, "a source build fits the Mac it is built on: \(fx.calls())")
        XCTAssertTrue(fx.exists(fx.app))
    }

    /// Integrity is not origin: a bundle that passes every check on it could
    /// still have been signed by anyone, and install.sh does not take the
    /// signer's word for where it came from. Whatever the signature names
    /// (ad-hoc, or a Developer ID certificate and team), without
    /// --allow-unverified-origin install.sh refuses it before the password
    /// prompt and names the flag. With the flag the Developer ID bundle gets
    /// the same warning as an ad-hoc one, not a verified origin.
    func testInstallFromPrebuiltAppNeedsTheOptInWhateverItsSignatureNames() throws {
        try fx.prepareInstall()
        let prebuilt = try writePrebuiltAppAtAnAwkwardPath()
        fx.setMode("launchctl", "loaded")

        for signing in ["adhoc", "developer-id:ABCDE12345"] {
            fx.setSigning(signing)
            fx.clearCalls()
            let r = try fx.run(fx.installRedirected, ["--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 1, "\(signing): \(r.stderr + r.stdout)")
            let copy = try checkedCopy(of: prebuilt)
            XCTAssertEqual(fx.callsBesideScratchFiles(), ["sysctl -n hw.optional.arm64", "codesign --verify --strict --deep \(copy)"], "\(signing): \(fx.calls())")
            XCTAssertTrue(r.stderr.contains("The origin of Insomnia 0.1.0 at \(prebuilt.path) is not verified."), "\(signing): \(r.stderr)")
            XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: " --app ")), [fx.installRedirected.path, "--allow-unverified-origin", "--app", prebuilt.path], "\(signing): names the flag")
            XCTAssertTrue(r.stderr.contains("Nothing was changed"), "\(signing): \(r.stderr)")
            XCTAssertFalse(fx.exists(fx.app), signing)
            XCTAssertFalse(fx.exists(fx.sudoers), signing)
        }

        fx.clearCalls()
        let flagged = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(flagged.status, 0, flagged.stderr + flagged.stdout)
        XCTAssertTrue(flagged.stdout.contains("WARNING: the origin of Insomnia 0.1.0 is not verified."), flagged.stdout)
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "prebuilt")
        XCTAssertTrue(fx.exists(fx.installedBackstop))
    }

    /// The release-install path with the real codesign: a bundle ad-hoc
    /// signed with `codesign -s -` inside the fixture (every other tool stays
    /// a fake) verifies before the password prompt, the copy ditto makes at
    /// the installed path verifies again against the requirement codesign
    /// read from it, and the agent plist pins that real cdhash. After the
    /// sealed script is edited the same bundle is refused before sudo with
    /// codesign's reason.
    func testInstallFromAnAdHocSignedPrebuiltAppVerifiesTheRealSignatureAndItsDittoCopy() throws {
        try fx.prepareInstall()
        try fx.writeInstallCopies(extraConstants: ["CODESIGN": "/usr/bin/codesign"])
        let prebuilt = try fx.writePrebuiltApp(machO: true)
        let sign = try fx.runTool("/usr/bin/codesign", ["--force", "--sign", "-", prebuilt.path])
        XCTAssertEqual(sign.status, 0, sign.output)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let requirement = try CodeRequirement.designated(ofCodeAt: prebuilt)
        XCTAssertTrue(requirement.hasPrefix("cdhash H\""), requirement)
        XCTAssertTrue(r.stdout.contains("LaunchAgent will require: \(requirement)"), r.stdout)
        let installed = try fx.runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", fx.app.path])
        XCTAssertEqual(installed.status, 0, "the ditto copy at the installed path verifies: \(installed.output)")
        XCTAssertNoThrow(try CodeRequirement.verify(codeAt: fx.app, satisfies: requirement))
        let plist = try fx.plistOnDisk()
        let expected = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", target: BackstopTarget(bundle: fx.app, requirement: requirement))
        XCTAssertTrue(NSDictionary(dictionary: plist).isEqual(to: expected), "the agent pins the real requirement: \(plist)")
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("launchctl bootstrap") }, "\(fx.calls())")

        let sealed = prebuilt.appendingPathComponent("Contents/Resources/backstop.sh")
        try (String(contentsOf: sealed, encoding: .utf8) + "# edited\n").write(to: sealed, atomically: true, encoding: .utf8)
        fx.clearCalls()
        let edited = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(edited.status, 1, edited.stderr + edited.stdout)
        XCTAssertEqual(fx.callsBesideScratchFiles(), ["sysctl -n hw.optional.arm64"], "the real codesign refused before any other fake tool ran: \(fx.calls())")
        XCTAssertTrue(edited.stderr.contains("fails 'codesign --verify --strict --deep'"), edited.stderr)
        XCTAssertTrue(edited.stderr.contains("Nothing was changed"), edited.stderr)
    }

    /// A zip unpacked by a tool that keeps group and other write bits, or a
    /// download given an ACL, leaves a bundle other accounts could edit.
    /// Neither is part of the signature: the bundle verifies with them, and
    /// the installed copy loses both, keeps the quarantine flag and still
    /// passes the real codesign and the requirement the agent pins.
    func testInstallFromAPrebuiltAppDropsOtherAccountsWriteAccessButKeepsTheSignatureAndQuarantine() throws {
        try fx.prepareInstall()
        // install.sh's chmod -R -N runs for real here (see writeFakes).
        XCTAssertTrue(FileManager.default.createFile(atPath: fx.root.appendingPathComponent("chmod.real-acl").path, contents: nil))
        try fx.writeInstallCopies(extraConstants: ["CODESIGN": "/usr/bin/codesign"])
        let prebuilt = try fx.writePrebuiltApp(machO: true)
        let sign = try fx.runTool("/usr/bin/codesign", ["--force", "--sign", "-", prebuilt.path])
        XCTAssertEqual(sign.status, 0, sign.output)
        let loosen = try fx.runTool("/bin/chmod", ["-R", "go+w", prebuilt.path])
        XCTAssertEqual(loosen.status, 0, loosen.output)
        let resources = prebuilt.appendingPathComponent("Contents/Resources")
        for (path, rule) in [(resources.path, "everyone allow add_file,delete_child"),
                             (resources.appendingPathComponent("backstop.sh").path, "everyone allow write,append")] {
            let acl = try fx.runTool("/bin/chmod", ["+a", rule, path])
            XCTAssertEqual(acl.status, 0, acl.output)
        }
        let mark = try fx.runTool("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;66f00000;Safari;", prebuilt.path])
        XCTAssertEqual(mark.status, 0, mark.output)
        XCTAssertFalse(try writableByOthers(prebuilt).isEmpty)
        XCTAssertEqual(try aclEntries(prebuilt).count, 2, "the ACLs are in place before the install")
        let before = try fx.runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", prebuilt.path])
        XCTAssertEqual(before.status, 0, "modes and ACLs are not part of the signature: \(before.output)")
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try writableByOthers(fx.app), [], "no group or other write bit is left")
        XCTAssertEqual(try aclEntries(fx.app), [], "no ACL entry is left")
        let quarantine = try fx.runTool("/usr/bin/xattr", ["-p", "com.apple.quarantine", fx.app.path])
        XCTAssertEqual(quarantine.status, 0, "the quarantine flag stays: \(quarantine.output)")
        XCTAssertFalse(quarantine.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let installed = try fx.runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", fx.app.path])
        XCTAssertEqual(installed.status, 0, "the installed copy still verifies: \(installed.output)")
        let requirement = try CodeRequirement.designated(ofCodeAt: prebuilt)
        XCTAssertTrue(r.stdout.contains("LaunchAgent will require: \(requirement)"), r.stdout)
        XCTAssertNoThrow(try CodeRequirement.verify(codeAt: fx.app, satisfies: requirement))
    }

    /// A source build made under umask 002 has group-writable files and
    /// folders; the installed bundle has none.
    func testInstallFromSourceUnderAGroupWritableUmaskLeavesNothingGroupWritable() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        let wrapper = fx.root.appendingPathComponent("umask-002.sh")
        try "umask 0002\nexec /bin/bash \"\(fx.installRedirected.path)\" \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)

        let r = try fx.run(wrapper, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertEqual(try writableByOthers(fx.app), [], "no group or other write bit is left")
    }

    /// Every path in `bundle`, itself included.
    private func bundlePaths(_ bundle: URL) throws -> [String] {
        let walk = try XCTUnwrap(FileManager.default.enumerator(atPath: bundle.path))
        var paths = [bundle.path]
        while let relative = walk.nextObject() as? String {
            paths.append(bundle.appendingPathComponent(relative).path)
        }
        return paths
    }

    /// The paths in `bundle` (symbolic links aside) that group or other may write.
    private func writableByOthers(_ bundle: URL) throws -> [String] {
        try bundlePaths(bundle).filter { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { return false }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return mode & 0o022 != 0
        }
    }

    /// The ACL entries `ls -led` prints for the paths in `bundle`, such as
    /// " 0: group:everyone allow write,append".
    private func aclEntries(_ bundle: URL) throws -> [String] {
        try bundlePaths(bundle).flatMap { path in
            let ls = try fx.runTool("/bin/ls", ["-led", path])
            XCTAssertEqual(ls.status, 0, ls.output)
            return ls.output.split(separator: "\n").map(String.init).filter { $0.range(of: #"^ \d+: "#, options: .regularExpression) != nil }
        }
    }

    /// The integrity checks below hold with --allow-unverified-origin: the
    /// flag vouches for where a bundle came from, never for a bundle that
    /// fails them.
    func testInstallFromPrebuiltAppStopsBeforeSudoWhenItsSignatureDoesNotVerify() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setMode("codesign", "deep-verify-fails")

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.callsBesideScratchFiles()
        XCTAssertEqual(calls, ["sysctl -n hw.optional.arm64", "codesign --verify --strict --deep \(try checkedCopy(of: prebuilt))"], "nothing after the failed check: \(fx.calls())")
        XCTAssertTrue(r.stderr.contains("fails 'codesign --verify --strict --deep'"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("SHA256SUMS"), "points at the download checks: \(r.stderr)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle kept")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "sudoers rule kept")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist kept")
    }

    func testInstallFromPrebuiltAppRefusesAnotherIdentifierAVersionlessBundleAndAMissingBackstop() throws {
        try fx.prepareInstall()
        let cases: [(String, String, (ScriptFixture) throws -> URL)] = [
            ("identifier", "has bundle identifier 'com.example.other', not com.kgarg.insomnia", { try $0.writePrebuiltApp(bundleID: "com.example.other") }),
            ("version", "has no usable CFBundleShortVersionString ('dev')", { try $0.writePrebuiltApp(version: "dev") }),
            ("backstop", "has no Contents/Resources/backstop.sh", { try $0.writePrebuiltApp(withBackstop: false) }),
        ]
        for (name, reason, make) in cases {
            let bundle = try make(fx)
            fx.clearCalls()
            let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", bundle.path], extraEnvironment: ["USER": "tester"])
            XCTAssertEqual(r.status, 1, "\(name): \(r.stderr + r.stdout)")
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") }, "\(name): \(fx.calls())")
            XCTAssertTrue(r.stderr.contains(reason), "\(name): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("Nothing was changed"), "\(name): \(r.stderr)")
            XCTAssertFalse(fx.exists(fx.app), name)
            XCTAssertFalse(fx.exists(fx.sudoers), name)
            try FileManager.default.removeItem(at: bundle)
        }
    }

    /// A source install builds through build-app.sh into a staging
    /// directory before the password prompt; the installed bundle is that
    /// build, and the staging directory is gone afterwards.
    func testInstallFromSourceBuildsBeforeSudoAndInstallsTheStagedBundle() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        let build = try XCTUnwrap(calls.firstIndex(of: "swift build -c release"), "\(calls)")
        let sign = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("codesign --force --sign - ") }, "ad-hoc, no identity in the environment: \(calls)")
        let auth = try XCTUnwrap(calls.firstIndex(of: "sudo -v"), "\(calls)")
        XCTAssertLessThan(build, sign)
        XCTAssertLessThan(sign, auth, "built and signed before the password prompt: \(calls)")
        XCTAssertFalse(calls[sign].contains(fx.app.path), "signed in staging, not in place: \(calls[sign])")
        XCTAssertFalse(calls.contains { $0.hasPrefix("codesign --verify --strict --deep") }, "the prebuilt checks are for --app only: \(calls)")
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/MacOS/Insomnia")))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fx.appsDir.path), ["Insomnia.app"])
    }

    func testInstallRejectsUnknownArguments() throws {
        try fx.prepareInstall()

        let r = try fx.run(fx.installRedirected, ["--bogus"], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 2, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(r.stderr.contains("usage:"), r.stderr)

        let flagAlone = try fx.run(fx.installRedirected, ["--allow-unverified-origin"], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(flagAlone.status, 2, flagAlone.stderr + flagAlone.stdout)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(flagAlone.stderr.contains("applies to --app only"), flagAlone.stderr)
        XCTAssertFalse(fx.exists(fx.sudoers))
    }

    /// The writable copy of installs before the sealed layout is removed
    /// once the verifying agent is confirmed loaded, not before: until then
    /// the previous agent (which runs that copy) is what retries.
    func testInstallRemovesTheLegacyWritableCopyOnlyAfterTheNewAgentIsLoaded() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-bootstrap-fails-once")

        let failed = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(failed.status, 1, failed.stderr + failed.stdout)
        XCTAssertTrue(fx.exists(fx.legacyBackstop), "the previous agent still runs this copy")
        XCTAssertFalse(fx.calls().contains("backstop legacy --force"), "recovery ran the sealed copy, not the old one: \(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app), "no bundle is installed without an agent that pins it")

        fx.setMode("launchctl", "loaded")
        fx.clearCalls()
        let ok = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(ok.status, 0, ok.stderr + ok.stdout)
        XCTAssertFalse(fx.exists(fx.legacyBackstop), "the writable copy is gone once the verifying agent is loaded")
        XCTAssertTrue(ok.stdout.contains("removed the previous install's"), ok.stdout)
        XCTAssertTrue(fx.exists(fx.installedBackstop))
    }

    /// install.sh runs the agent's own check (`--verify -R=<requirement>`)
    /// once, on the installed copy. A bundle that fails it would give an
    /// agent that always refuses, so the agent is not installed and the
    /// previous one is left alone. (build-app.sh's plain `--verify` passed
    /// before the password prompt; only the pinned check fails here.)
    func testInstallStopsBeforeTheAgentWhenTheBundleFailsItsOwnRequirementCheck() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("codesign", "requirement-verify-fails")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("codesign --verify --strict -R=\(fx.requirement) \(fx.appsDir.path)/.Insomnia.app.staging.") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the previous bundle was never touched")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the staged build is discarded")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery from a bundle the agent would refuse: \(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(fx.exists(fx.legacyBackstop))
        XCTAssertFalse(fx.exists(fx.sudoers), "the bundle is checked before the lock, so the rule is not written")
        XCTAssertFalse(calls.contains { $0.contains("/usr/sbin/visudo") }, "\(calls)")
        XCTAssertTrue(r.stderr.contains("would never run backstop.sh. \(fx.sudoers.path), the app at \(fx.app.path) and the LaunchAgent were not touched."), r.stderr)
    }

    /// A first install whose agent cannot load leaves what was there before:
    /// no bundle at $APP, rather than a bundle no agent pins.
    func testInstallWithNoPreviousAppLeavesNoneWhenTheAgentCannotLoad() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "bootstrap-fails")   // nothing loaded, before or after the failed bootstrap

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("launchctl APP-BINARY=#!/bin/bash during bootstrap"), "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app), "the new bundle is discarded with its agent")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), [])
        XCTAssertTrue(r.stderr.contains("none is now"), r.stderr)
        XCTAssertFalse(fx.exists(fx.plist))
    }

    /// A run killed between the two renames of the swap leaves the previous
    /// bundle set aside and nothing at $APP. The next run puts it back as
    /// soon as it holds the recovery lock, so a stop later in that run
    /// (here: unresolved recovery) still leaves the previous pair in place.
    func testInstallPutsBackABundleAnInterruptedRunSetAside() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp(at: fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true))
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("restored \(fx.app.path)"), r.stdout)
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"])
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
    }

    /// A run killed after the second rename leaves its new build at $APP and
    /// the previous one set aside. Which of the two stays is decided by the
    /// plist on disk, the one launchd loads at the next login: when it pins
    /// only the set-aside bundle that one goes back, and when $APP satisfies
    /// it the set-aside copy is removed. Here this run's own load is then not
    /// confirmed (print never lists the job), so it undoes its swap and stops,
    /// and $APP shows what the repair left.
    func testInstallKeepsTheBundleThePlistOnDiskPinsAfterAnInterruptedSwap() throws {
        try fx.prepareInstall()
        let previous = fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true)
        try fx.writeBundle(at: previous, marker: "previous")
        try fx.writeBundle(at: fx.app, marker: "interrupted")
        try fx.writeAgentPlist()
        try fx.rejectSignature(of: fx.app)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        // launchctl mode ok: nothing is loaded, and a bootstrap's job is never listed

        let pinsPrevious = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(pinsPrevious.status, 1, pinsPrevious.stderr + pinsPrevious.stdout)
        XCTAssertTrue(fx.calls().contains("codesign --verify --strict -R=\(fx.requirement) \(previous.path)"), "\(fx.calls())")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the bundle the plist pins is back")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the interrupted build left with the staging directory")
        XCTAssertTrue(pinsPrevious.stdout.contains("restored \(fx.app.path)"), pinsPrevious.stdout)

        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("codesign.rejects"))
        try FileManager.default.removeItem(at: fx.app)
        try fx.writeBundle(at: previous, marker: "previous")
        try fx.writeBundle(at: fx.app, marker: "interrupted")
        let pinsCurrent = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(pinsCurrent.status, 1, pinsCurrent.stderr + pinsCurrent.stdout)
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted", "$APP satisfies the plist, so it stays")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the set-aside copy is removed")
        XCTAssertTrue(fx.calls().contains("rm -rf \(previous.path)"), "removed through $RM: \(fx.calls())")
        XCTAssertTrue(pinsCurrent.stdout.contains("removed the bundle an interrupted run had set aside"), pinsCurrent.stdout)
    }

    /// The interrupted run may have left its own job loaded (killed after
    /// its bootstrap, or its unload failed), and that job pins the build at
    /// $APP. The rerun first ends the stale session (its recovery step), and
    /// only then unloads that job, print confirms it is gone, the previous
    /// bundle goes back and the previous plist is loaded again. The install
    /// then goes on from that pair.
    func testInstallUnloadsTheInterruptedRunsJobBeforePuttingThePreviousBundleBack() throws {
        try writeInterruptedSwap()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")   // the interrupted run's job

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        let recovery = try XCTUnwrap(calls.firstIndex(of: "sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(calls)")
        let unload = try XCTUnwrap(calls.firstIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(calls)")
        let reload = try XCTUnwrap(calls.firstIndex(of: "launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)"), "\(calls)")
        XCTAssertLessThan(recovery, unload, "the job that may be retrying recovery stays until recovery succeeds: \(calls)")
        XCTAssertLessThan(unload, reload, "\(calls)")
        XCTAssertTrue(calls[unload..<reload].contains("launchctl print gui/\(fx.uid)/com.insomnia.backstop"), "the unload is confirmed first: \(calls)")
        XCTAssertEqual(
            calls.filter { $0.hasPrefix("launchctl APP-") },
            ["launchctl APP-BINARY=previous during bootstrap", "launchctl APP-BINARY=#!/bin/bash during bootstrap"],
            "the previous plist is loaded with the previous bundle back, then this run's: \(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the interrupted build left with the staging directory")
        XCTAssertTrue(r.stdout.contains("unloaded the job the interrupted run left and loaded \(fx.plist.path) again"), r.stdout)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    /// As above, but this run's recovery fails, so the job the interrupted
    /// run left (which may be the one retrying that recovery) stays loaded
    /// with the build it pins: nothing is unloaded or loaded and neither
    /// bundle moves. The run stops and says the next login's plist pins the
    /// other bundle.
    func testInstallLeavesAnInterruptedSwapAloneWhileRecoveryIsUnresolved() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")
        fx.setMode("launchctl", "loaded")   // the interrupted run's job
        let plistBefore = try Data(contentsOf: fx.plist)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootout") || $0.hasPrefix("launchctl bootstrap") }, "the loaded job stays: \(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted", "the build the loaded job pins stays")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n", "the previous app stays set aside")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), [".Insomnia.app.previous", "Insomnia.app"], "the staged build is discarded")
        XCTAssertEqual(try Data(contentsOf: fx.plist), plistBefore)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "ownership retained")
        XCTAssertTrue(r.stderr.contains("Neither bundle was moved"), r.stderr)
        XCTAssertTrue(r.stderr.contains("\(fx.plist.path) pins the previous app"), r.stderr)
        XCTAssertTrue(r.stderr.contains("is loaded and was left as it was"), r.stderr)
        XCTAssertFalse(r.stderr.contains("still match each other"), "the pair is not claimed to match: \(r.stderr)")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// After recovery succeeds the repair unloads the interrupted run's job
    /// and puts the previous bundle back, but loading the previous plist
    /// again is not confirmed: the bootstrap fails, or it succeeds and print
    /// then fails. No later step may count on a loaded job, so the run stops
    /// there, before it writes or loads anything of its own, and says how to
    /// load the previous job.
    func testInstallStopsWhenTheRepairCannotLoadThePreviousPlistAgain() throws {
        for (mode, printed) in [("loaded-bootstrap-fails-once", "no"), ("loaded-print-fails-once-after-bootstrap", "unknown:1")] {
            fx.destroy()
            fx = try ScriptFixture()
            try writeInterruptedSwap()
            try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            fx.setMode("launchctl", mode)
            let plistBefore = try Data(contentsOf: fx.plist)

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

            XCTAssertEqual(r.status, 1, "\(mode): \(r.stderr + r.stdout)")
            let calls = fx.calls()
            let recovery = try XCTUnwrap(calls.firstIndex(of: "sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(mode): \(calls)")
            let unload = try XCTUnwrap(calls.firstIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(mode): \(calls)")
            XCTAssertLessThan(recovery, unload, "\(mode): \(calls)")
            XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }, ["launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)"], "only the reload, no candidate: \(mode): \(calls)")
            XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootout") }.count, 1, "\(mode): \(calls)")
            XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "\(mode)")
            XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "\(mode)")
            XCTAssertEqual(try Data(contentsOf: fx.plist), plistBefore, "\(mode)")
            XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"], "no candidate written: \(mode)")
            XCTAssertFalse(r.stdout.contains("loaded \(fx.plist.path) again"), "\(mode): \(r.stdout)")
            XCTAssertTrue(r.stderr.contains("No job with label com.insomnia.backstop is confirmed loaded (launchctl print: \(printed))"), "\(mode): \(r.stderr)")
            XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "launchctl bootstrap")), ["launchctl", "bootstrap", "gui/\(fx.uid)", fx.plist.path], "\(mode)")
            XCTAssertTrue(r.stderr.contains("matches\nthe app at \(fx.app.path)"), "\(mode): \(r.stderr)")
            XCTAssertTrue(try fx.lockIsFree(), "\(mode)")
        }
    }

    /// The state an install killed after the second rename of its swap
    /// leaves: its build at $APP (marker "interrupted"), the previous one set
    /// aside, and the plist on disk pinning only the previous one.
    @discardableResult
    private func writeInterruptedSwap() throws -> URL {
        try fx.prepareInstall()
        let previous = fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true)
        try fx.writeBundle(at: previous, marker: "previous")
        try fx.writeBundle(at: fx.app, marker: "interrupted")
        try fx.writeAgentPlist()
        try fx.rejectSignature(of: fx.app)
        return previous
    }

    /// After an interrupted swap, `codesign --verify` decides which bundle
    /// the plist on disk pins. When it never answers, that is unknown, so
    /// the run stops it, moves neither bundle, unloads no job, and exits
    /// instead of holding the lock. Deleting the set-aside copy here would
    /// lose the bundle the plist may pin.
    func testInstallMovesNeitherBundleWhenCodesignDoesNotAnswerDuringTheRepair() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        fx.setMode("codesign", "verify-hangs-under-lock")

        let started = Date()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30)
        XCTAssertTrue(r.stderr.contains("aside at \(previous.path), and 'codesign --verify', which tells which of the two bundles \(fx.plist.path) pins,\ndid not answer within 5s.\nNeither bundle was moved"), r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("codesign FD9-OPEN"), "the call keeps the lock while it runs: \(calls)")
        XCTAssertTrue(fx.hungProcessGone("codesign", within: 0), "it was killed and reaped before the run went on")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// As above, but the job cannot be unloaded: print still lists it after
    /// the bootout. It pins the build at $APP, so neither bundle moves, and
    /// the run stops and says how to finish.
    func testInstallMovesNoBundleWhenTheInterruptedRunsJobCannotBeUnloaded() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "bootout-fails-still-loaded")
        let plistBefore = try Data(contentsOf: fx.plist)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        let recovery = try XCTUnwrap(calls.firstIndex(of: "sudo -n \(fx.fakePmset) -a disablesleep 0"), "\(calls)")
        let unload = try XCTUnwrap(calls.firstIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(calls)")
        XCTAssertLessThan(recovery, unload, "the unload is tried only once recovery succeeded: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootstrap") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted", "the build the loaded job pins stays")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n", "the previous app stays set aside")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), [".Insomnia.app.previous", "Insomnia.app"])
        XCTAssertEqual(try Data(contentsOf: fx.plist), plistBefore)
        XCTAssertTrue(r.stderr.contains("not confirmed (launchctl print: yes)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("neither bundle was moved"), r.stderr)
        XCTAssertTrue(r.stderr.contains("  launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), r.stderr)
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// Leftovers are cleaned only under the recovery lock: while another
    /// process holds it, a set-aside bundle (which a live run may need to
    /// roll back) and every staging directory stay. With the lock, a dead
    /// run's staging directory is removed and a live run's (named by a PID
    /// that `$KILL -0` reports alive) is kept, and so is anything whose name
    /// is not exactly one step 3 gives, or that is a symlink.
    func testInstallCleansLeftoversOnlyUnderTheLockAndKeepsALiveRunsStaging() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("kill.fail", "4242")   // the fake kill: 4242 is gone, 4343 is alive
        let dead = ".Insomnia.app.staging.4242.AAAAAA"
        let live = ".Insomnia.app.staging.4343.BBBBBB"
        let setAside = ".Insomnia.app.previous"
        let unlike = [".Insomnia.app.staging.4242", ".Insomnia.app.staging.4242.AAAAAA.old", ".Insomnia.app.staging.x4242.AAAAAA"]
        let link = ".Insomnia.app.staging.4242.CCCCCC"
        for name in [dead, live] + unlike {
            try fx.writeBundle(at: fx.appsDir.appendingPathComponent(name).appendingPathComponent("Insomnia.app"), marker: "staged")
        }
        let elsewhere = fx.root.appendingPathComponent("elsewhere", isDirectory: true)
        try fx.writeBundle(at: elsewhere.appendingPathComponent("Insomnia.app"), marker: "not the installer's")
        try FileManager.default.createSymbolicLink(at: fx.appsDir.appendingPathComponent(link), withDestinationURL: elsewhere)
        try fx.writeBundle(at: fx.appsDir.appendingPathComponent(setAside), marker: "set aside by a live run")

        let holder = try fx.holdLock()
        let blocked = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        holder.stop()

        XCTAssertEqual(blocked.status, 75, blocked.stderr + blocked.stdout)
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ([setAside, dead, live, link, "Insomnia.app"] + unlike).sorted(), "nothing removed outside the lock")

        try FileManager.default.removeItem(at: fx.appsDir.appendingPathComponent(setAside))
        fx.setMode("launchctl", "loaded")
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ([live, link, "Insomnia.app"] + unlike).sorted(), "the dead run's staging is gone, the live run's stays")
        XCTAssertTrue(fx.exists(elsewhere.appendingPathComponent("Insomnia.app/Contents/MacOS/Insomnia")), "a symlink's target is never touched")
        XCTAssertTrue(fx.calls().contains("kill -0 4242") && fx.calls().contains("kill -0 4343"), "asked through $KILL: \(fx.calls())")
    }

    /// Every file install.sh removes, and every scratch file or directory
    /// it creates, goes through RM, RMDIR and MKTEMP, the fixed-path
    /// variables the fixture points at logging fakes: a dead run's staging
    /// directory, an older build's candidate plist, the set-aside previous
    /// app, the legacy writable backstop.sh, and on exit the sudoers
    /// candidate, the candidate directory and this run's staging directory.
    func testInstallRemovesAndCreatesFilesOnlyThroughItsFixedPathTools() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        fx.setMode("kill.fail", "4242")   // the fake kill: 4242 is gone
        let dead = fx.appsDir.appendingPathComponent(".Insomnia.app.staging.4242.AAAAAA")
        try fx.writeBundle(at: dead.appendingPathComponent("Insomnia.app"), marker: "staged")
        let olderCandidate = fx.plist.deletingLastPathComponent().appendingPathComponent("com.insomnia.backstop.candidate-1.plist")
        try "older".write(to: olderCandidate, atomically: true, encoding: .utf8)
        let candidateDir = fx.plist.deletingLastPathComponent().appendingPathComponent(".com.insomnia.backstop.staging")
        let tmp = try fx.privateTmp()

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "TMPDIR": tmp.path])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        let staging = fx.appsDir.path + "/.Insomnia.app.staging."
        XCTAssertTrue(calls.contains("mktemp"), "the sudoers candidate: \(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("mktemp -d \(staging)") && $0.hasSuffix(".XXXXXX") }, "this run's staging directory: \(calls)")
        XCTAssertTrue(calls.contains("rm -rf \(dead.path)"), "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("rm -f ") && $0.hasSuffix(" \(olderCandidate.path)") }, "\(calls)")
        XCTAssertTrue(calls.contains("rm -rf \(fx.appsDir.path)/.Insomnia.app.previous"), "\(calls)")
        XCTAssertTrue(calls.contains("rm -f \(fx.legacyBackstop.path)"), "\(calls)")
        let visudo = try XCTUnwrap(calls.first { $0.hasPrefix("sudo -n /usr/sbin/visudo -cf ") }, "\(calls)")
        XCTAssertTrue(calls.contains("rm -f \(visudo.dropFirst("sudo -n /usr/sbin/visudo -cf ".count))"), "the sudoers candidate, on exit: \(calls)")
        let bootstrap = try XCTUnwrap(calls.first { $0.hasPrefix("launchctl bootstrap gui/\(fx.uid) ") }, "\(calls)")
        XCTAssertTrue(calls.contains("rm -f \(bootstrap.dropFirst("launchctl bootstrap gui/\(fx.uid) ".count))"), "the candidate, on exit: \(calls)")
        XCTAssertTrue(calls.contains("rmdir \(candidateDir.path)"), "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("rm -rf \(staging)") && $0 != "rm -rf \(dead.path)" }, "this run's staging directory, on exit: \(calls)")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"])
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"])
        XCTAssertFalse(fx.exists(fx.legacyBackstop))
        XCTAssertEqual(try fx.contents(of: tmp), [], "no scratch file is left")
    }

    /// install.sh makes the folders it installs into and fixes the staged
    /// bundle's modes only through MKDIR and CHMOD; build-app.sh assembles
    /// the bundle through its own fixed paths and install.sh copies it with
    /// DITTO. The run has `mkdir`, `cp`, `chmod` and `ditto` stubs first on
    /// PATH that log and fail, and none of them runs; install.sh's calls
    /// reach the fixture's logging fakes, and the installed bundle has every
    /// file in place.
    func testInstallAssemblesTheBundleOnlyThroughItsFixedPathTools() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        let shadow = fx.root.appendingPathComponent("shadow", isDirectory: true)
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
        for tool in ["mkdir", "cp", "chmod", "ditto"] {
            let stub = shadow.appendingPathComponent(tool)
            try "#!/bin/bash\nprintf 'PATH \(tool) %s\\n' \"$*\" >> \"\(fx.callsLog.path)\"\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "PATH": "\(shadow.path):/usr/bin:/bin:/usr/sbin:/sbin"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("PATH ") }, [], "a tool from PATH ran")
        let staging = fx.appsDir.path + "/.Insomnia.app.staging."
        let goW = try XCTUnwrap(fx.chmodCalls().first { $0.hasPrefix("chmod -R go-w \(staging)") }, "\(fx.chmodCalls())")
        let newApp = String(goW.dropFirst("chmod -R go-w ".count))
        XCTAssertTrue(newApp.hasSuffix("/Insomnia.app"), newApp)
        XCTAssertTrue(fx.chmodCalls().contains("chmod -R -N \(newApp)"), "\(fx.chmodCalls())")
        for call in [
            "mkdir -p \(fx.appsDir.path)",
            "mkdir -p \(fx.home.path) \(fx.home.path)/Logs \(fx.plist.deletingLastPathComponent().path)",
            "mkdir -p \(fx.plist.deletingLastPathComponent().path)/.com.insomnia.backstop.staging",
        ] {
            XCTAssertTrue(calls.contains(call), "\(call) not in \(calls)")
        }
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash", "the built binary is installed")
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/Info.plist")))
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/Resources/AppIcon.icns")))
        XCTAssertEqual(try fx.mode(fx.installedBackstop) & 0o777, 0o755, "the sealed backstop.sh is executable")
    }

    /// The new agent loads but its plist cannot be moved into place (the
    /// LaunchAgents directory is read-only here). The next login would load
    /// the old plist, which pins the previous build, so the new job is
    /// unloaded (launchctl print confirms it is gone), the previous bundle
    /// goes back and the previous plist is loaded again, the same as for a
    /// failed load.
    func testInstallPutsThePreviousPairBackWhenThePlistCannotBePublished() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        let agents = fx.plist.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agents.appendingPathComponent(".com.insomnia.backstop.staging"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: agents.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.path) }

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        let bootstraps = calls.filter { $0.hasPrefix("launchctl bootstrap") }
        XCTAssertEqual(bootstraps.count, 2, "candidate, then the previous plist again: \(calls)")
        XCTAssertEqual(bootstraps.last, "launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)")
        let firstLoad = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("launchctl bootstrap") })
        XCTAssertTrue(calls[firstLoad...].contains("launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "the new job is unloaded: \(calls)")
        XCTAssertEqual(
            calls.filter { $0.hasPrefix("launchctl APP-") },
            ["launchctl APP-BINARY=#!/bin/bash during bootstrap", "launchctl APP-BINARY=previous during bootstrap"],
            "the previous bundle is back before the previous plist is loaded again: \(calls)"
        )
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted", "the trusted plist was never modified")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "no staged or set-aside bundle is left")
        XCTAssertTrue(r.stderr.contains("could not be moved to \(fx.plist.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("put back"), r.stderr)
        XCTAssertTrue(r.stderr.contains("loaded again from the previous plist"), r.stderr)
        XCTAssertTrue(r.stderr.contains("is writable and rerun"), r.stderr)
    }

    /// As above, but the new job cannot be unloaded again: launchctl print
    /// still lists it after the bootout. That job pins the new build, so
    /// putting the previous bundle back would leave it refusing every run.
    /// The new build stays, the previous bundle stays set aside (the state
    /// an install killed mid-swap leaves, which the next run repairs; see
    /// testInstallKeepsTheBundleThePlistOnDiskPinsAfterAnInterruptedSwap),
    /// and nothing is loaded over the job.
    func testInstallKeepsTheNewBuildWhenItsJobCannotBeUnloadedAfterAFailedPublish() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-unload-fails-after-bootstrap")
        let agents = fx.plist.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agents.appendingPathComponent(".com.insomnia.backstop.staging"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: agents.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agents.path) }
        let previous = fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "the previous plist is not loaded over the job: \(calls)")
        let firstLoad = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("launchctl bootstrap") })
        let unload = try XCTUnwrap(calls.lastIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"))
        XCTAssertGreaterThan(unload, firstLoad, "the new job's unload was tried: \(calls)")
        XCTAssertTrue(calls[unload...].contains("launchctl print gui/\(fx.uid)/com.insomnia.backstop"), "and checked: \(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash", "the build the loaded job pins stays at $APP")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), [".Insomnia.app.previous", "Insomnia.app"], "the previous bundle stays set aside")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted", "the trusted plist was never modified")
        XCTAssertTrue(r.stderr.contains("not confirmed (launchctl print: yes)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("stays at \(fx.app.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("kept at \(previous.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("is writable and rerun"), r.stderr)
    }

    /// bootstrap exits 0 but the print after it fails, so the new job may be
    /// loaded. It is unloaded and the next print confirms it is gone before
    /// the previous bundle goes back and the previous plist is loaded again.
    func testInstallUnloadsTheNewJobBeforeRollingBackWhenItsLoadIsUnconfirmed() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-print-fails-once-after-bootstrap")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        let load = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("launchctl bootstrap") && $0.contains("candidate-") }, "\(calls)")
        let unload = try XCTUnwrap(calls.lastIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(calls)")
        XCTAssertGreaterThan(unload, load, "the job print could not rule out is unloaded: \(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }.last, "launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)", "\(calls)")
        XCTAssertEqual(
            calls.filter { $0.hasPrefix("launchctl APP-") },
            ["launchctl APP-BINARY=#!/bin/bash during bootstrap", "launchctl APP-BINARY=previous during bootstrap"],
            "the previous bundle is back before the previous plist is loaded again: \(calls)"
        )
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"])
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("not confirmed loaded (launchctl print: unknown:1)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("The new job was unloaded again (launchctl print confirms)."), r.stderr)
        XCTAssertTrue(r.stderr.contains("put back"), r.stderr)
        XCTAssertTrue(r.stderr.contains("loaded again from the previous plist"), r.stderr)
    }

    /// As above, but print keeps failing, so the unload is not confirmed. A
    /// job that may be loaded is this run's and pins the new build, so the
    /// new build stays, the previous one stays set aside for the rerun, and
    /// nothing is loaded over the job.
    func testInstallKeepsTheNewBuildWhenItsLoadAndUnloadAreBothUnconfirmed() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-print-fails-after-bootstrap")
        let previous = fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "nothing is loaded over the job: \(calls)")
        let load = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("launchctl bootstrap") }, "\(calls)")
        XCTAssertTrue(calls[load...].contains("launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "the unload was tried: \(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash", "the build the job pins stays at $APP")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), [".Insomnia.app.previous", "Insomnia.app"])
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("not confirmed (launchctl print: unknown:1)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("stays at \(fx.app.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("kept at \(previous.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("rerun before you log out"), r.stderr)
    }

    /// bootout leaves the previous job loaded (print still lists it). The
    /// swap waits for print to confirm that job is gone, so nothing is
    /// replaced: the previous bundle stays with the job that pins it.
    func testInstallReplacesNothingWhenThePreviousJobCannotBeUnloaded() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "bootout-fails-still-loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootstrap") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the staged build is discarded and nothing is set aside")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("(launchctl print: yes), so the app at \(fx.app.path) was not replaced"), r.stderr)
        XCTAssertFalse(r.stderr.contains("launchctl bootstrap gui/"), "the job is still loaded, so there is nothing to reload: \(r.stderr)")
    }

    // A rename of the swap or of its undo that fails. Each one is handled:
    // the previous app goes back to $APP and its job is loaded again, and
    // when the previous app cannot go back, no bundle is deleted and the
    // message says how to put it back. Before, set -e exited at the failed
    // rename with the previous job unloaded, and cleanup deleted the
    // staged build.

    /// The previous pair of an earlier install: its app at $APP, the
    /// trusted plist, a clean journal, and its job loaded.
    private func writePreviousPair() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
    }

    private var stagedBuildPattern: String { fx.appsDir.path + "/.Insomnia.app.staging.*/Insomnia.app" }
    private var setAside: URL { fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true) }

    /// The staging directories left in $APP_DIR.
    private func stagingDirs() throws -> [URL] {
        try fx.contents(of: fx.appsDir).filter { $0.hasPrefix(".Insomnia.app.staging.") }.map { fx.appsDir.appendingPathComponent($0) }
    }

    /// The new build cannot be moved in after the previous app was set
    /// aside: the previous app goes back and its job is loaded again.
    func testInstallPutsThePreviousPairBackWhenTheNewBuildCannotBeMovedIn() throws {
        try writePreviousPair()
        try fx.failMoves([(stagedBuildPattern, fx.app.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("mv FAILED ") && $0.hasSuffix(" \(fx.app.path)") }, "\(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }, ["launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)"], "only the previous plist is loaded again: \(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl APP-") }, ["launchctl APP-BINARY=previous during bootstrap"], "the previous app is back before its job is loaded: \(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "nothing is left set aside or staged")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("the new build could not be moved from"), r.stderr)
        XCTAssertTrue(r.stderr.contains("The previous app was put back at \(fx.app.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("loaded again from the previous plist"), r.stderr)
    }

    /// The previous app cannot be moved aside: it never left $APP, and its
    /// job, already unloaded for the swap, is loaded again.
    func testInstallLoadsThePreviousJobAgainWhenThePreviousAppCannotBeMovedAside() throws {
        try writePreviousPair()
        try fx.failMoves([(fx.app.path, setAside.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        let unload = try XCTUnwrap(calls.firstIndex(of: "launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "\(calls)")
        XCTAssertEqual(calls[unload...].filter { $0.hasPrefix("launchctl bootstrap") }, ["launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)"], "\(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl APP-") }, ["launchctl APP-BINARY=previous during bootstrap"], "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"])
        XCTAssertTrue(r.stderr.contains("could not be moved aside to \(setAside.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("The previous app was never moved from \(fx.app.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("loaded again from the previous plist"), r.stderr)
    }

    /// Neither the new build nor the previous app can be moved to $APP, so
    /// nothing is there. Both bundles are kept, no job is loaded against an
    /// empty $APP, the message gives the two commands that restore the
    /// pair, and a rerun puts the previous app back first and installs.
    func testInstallDeletesNoBundleWhenThePreviousAppCannotBePutBack() throws {
        try writePreviousPair()
        try fx.failMoves([(stagedBuildPattern, fx.app.path), (setAside.path, fx.app.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl bootstrap") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertEqual(try String(contentsOf: setAside.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        let staged = try XCTUnwrap(try stagingDirs().first, "the new build is kept: \(String(describing: try? fx.contents(of: fx.appsDir)))")
        XCTAssertTrue(fx.exists(staged.appendingPathComponent("Insomnia.app/Contents/Resources/backstop.sh")), "the kept build still carries its backstop.sh")
        XCTAssertTrue(r.stderr.contains("nothing is at \(fx.app.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("neither was deleted"), r.stderr)
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "mv ")), ["mv", setAside.path, fx.app.path])
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "launchctl bootstrap")), ["launchctl", "bootstrap", "gui/\(fx.uid)", fx.plist.path])

        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("mv.fail"))
        fx.clearCalls()
        let rerun = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(rerun.status, 0, rerun.stderr + rerun.stdout)
        XCTAssertTrue(rerun.stdout.contains("restored \(fx.app.path), which an interrupted run had set aside"), rerun.stdout)
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash")
        XCTAssertFalse(fx.exists(setAside))
    }

    /// The new job failed to load and is not loaded, but the new build
    /// cannot be moved out of $APP: it stays there and the previous app
    /// stays set aside, the state the next run's repair handles. Nothing
    /// is loaded against the build that is not the previous one.
    func testInstallKeepsTheNewBuildWhenItCannotBeMovedBackAfterAFailedLoad() throws {
        try writePreviousPair()
        fx.setMode("launchctl", "loaded-bootstrap-fails-once")
        try fx.failMoves([(fx.app.path, stagedBuildPattern)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "the candidate only, no reload: \(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("mv FAILED \(fx.app.path) ") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash")
        XCTAssertEqual(try String(contentsOf: setAside.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("so it stays there"), r.stderr)
        XCTAssertTrue(r.stderr.contains("kept at \(setAside.path)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("rerun before you log out"), r.stderr)
    }

    /// The new job failed to load and the new build was moved out, but the
    /// previous app cannot be moved back: nothing is at $APP. Both bundles
    /// are kept and the previous job is not loaded against an empty $APP.
    func testInstallDeletesNoBundleWhenThePreviousAppCannotBePutBackAfterAFailedLoad() throws {
        try writePreviousPair()
        fx.setMode("launchctl", "loaded-bootstrap-fails-once")
        try fx.failMoves([(setAside.path, fx.app.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "the candidate only, no reload: \(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertEqual(try String(contentsOf: setAside.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        let staged = try XCTUnwrap(try stagingDirs().first, "the new build is kept: \(String(describing: try? fx.contents(of: fx.appsDir)))")
        XCTAssertTrue(fx.exists(staged.appendingPathComponent("Insomnia.app/Contents/Resources/backstop.sh")))
        XCTAssertTrue(r.stderr.contains("'launchctl bootstrap' exited 5"), r.stderr)
        XCTAssertTrue(r.stderr.contains("neither was deleted"), r.stderr)
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "mv ")), ["mv", setAside.path, fx.app.path])
    }

    /// The repair of an interrupted swap cannot move that run's build out
    /// of $APP: neither bundle moves, and the message says the job that run
    /// left was unloaded and that the next login would not match.
    func testInstallStopsWhenTheRepairCannotMoveTheInterruptedBuildAside() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        try fx.failMoves([(fx.app.path, "*/Interrupted.app")])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl bootstrap") }, "\(fx.calls())")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertTrue(r.stderr.contains("moving that build out of \(fx.app.path) failed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("The job that run left was unloaded"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Neither bundle was moved"), r.stderr)
    }

    /// The repair moved the interrupted build out but cannot move the
    /// previous app back: nothing is at $APP, both bundles are kept, and
    /// the message gives the commands that restore the previous pair.
    func testInstallDeletesNoBundleWhenTheRepairCannotPutThePreviousAppBack() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        try fx.failMoves([(previous.path, fx.app.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl bootstrap") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        let staged = try XCTUnwrap(try stagingDirs().first, "\(String(describing: try? fx.contents(of: fx.appsDir)))")
        XCTAssertEqual(try String(contentsOf: staged.appendingPathComponent("Interrupted.app/Contents/MacOS/Insomnia"), encoding: .utf8), "interrupted\n")
        XCTAssertTrue(fx.exists(staged.appendingPathComponent("Insomnia.app")), "the new build is kept too")
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "mv ")), ["mv", previous.path, fx.app.path])
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "launchctl bootstrap")), ["launchctl", "bootstrap", "gui/\(fx.uid)", fx.plist.path])
    }

    /// Nothing is at $APP and the set-aside bundle cannot be put back: the
    /// run stops before the recovery and touches no job.
    func testInstallStopsWhenTheSetAsideBundleCannotBePutBack() throws {
        try fx.prepareInstall()
        try fx.writeBundle(at: setAside, marker: "previous")
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        try fx.failMoves([(setAside.path, fx.app.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertEqual(try String(contentsOf: setAside.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertTrue(r.stderr.contains("putting back the previous app"), r.stderr)
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "mv ")), ["mv", setAside.path, fx.app.path])
    }

    /// The sudoers check under the lock never answers (a sudo policy or
    /// directory-service lookup that stalls). At the limit it gets SIGTERM,
    /// never SIGKILL, and stops; the run exits and lets go of the lock, so
    /// the app and the agent's backstop can take it again. Nothing was
    /// replaced or recovered, and since the rule was already written the
    /// stop gives the rerun command.
    func testInstallStopsAndLetsGoOfTheLockWhenTheSudoersCheckDoesNotAnswer() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-check-hangs-under-lock")

        let started = Date()
        let tmp = try fx.privateTmp()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "TMPDIR": tmp.path])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30, "one bounded check, not the fake's 60 s hang")
        XCTAssertTrue(r.stderr.contains("Install stopped: 'sudo -k -n -l', which checks the rule just written to \(fx.sudoers.path), did not answer within 5s. It stopped on SIGTERM and this\nrun exits, which lets go of the lock"), r.stderr)
        assertRerunNote(r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo FD9-OPEN"), "the check keeps the lock while it runs: \(calls)")
        XCTAssertTrue(calls.contains("sudo SIGTERM"), "\(calls)")
        XCTAssertTrue(fx.hungProcessGone("sudo", within: 0), "it stopped on SIGTERM before the run went on")
        XCTAssertNil(fx.commandEnded(), "it ended on SIGTERM, not by a release or the watchdog")
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(calls.filter { $0.contains(" -l ") }, ["sudo -k -n -l /usr/bin/pmset -a disablesleep 0"], "the chain stops at the check that did not answer: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery ran: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the new build is discarded")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertEqual(try fx.contents(of: tmp), [], "the scratch directory is gone, including the stopped call's files")
    }

    /// The sudo that validates the new rule under the lock never answers
    /// and ignores SIGTERM. It is never sent SIGKILL, so it keeps the
    /// recovery lock until it ends; the run exits, without a pid to kill
    /// (round 30: one noted now could name another process by the time
    /// anyone acts on it), and leaves the sudoers file, the bundle and the LaunchAgent as they were,
    /// so no rerun note is printed.
    func testInstallLeavesAVisudoThatIgnoresSigtermHoldingTheLockAndTheRuleUntouched() throws {
        try writePreviousPair()
        try FileManager.default.createDirectory(at: fx.sudoers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "rule".write(to: fx.sudoers, atomically: true, encoding: .utf8)
        fx.setMode("sudo", "visudo-hangs-under-lock")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0))
        XCTAssertTrue(r.stderr.contains("Install stopped: 'sudo visudo -cf', which validates the new rule, did not answer within 5s. It was sent SIGTERM and is still running. It is not killed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing here stops it\nby pid: a pid noted now could name another process by the time anyone acts on\nit. Once it has ended (a restart ends it too), rerun this script."), r.stderr)
        XCTAssertFalse(r.stderr.contains("sudo kill") || r.stderr.contains("pid \(pid)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertFalse(r.stderr.contains("already holds the new three-line rule"), r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo FD9-OPEN"), "\(calls)")
        XCTAssertTrue(calls.contains("sudo SIGTERM"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.contains("/usr/bin/install") || $0.contains(" -l ") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(fx.hungProcessGone("sudo", within: 2), "sudo is never sent SIGKILL")
        XCTAssertFalse(try fx.lockIsFree(), "the sudo started under the lock still runs, so the lock stays held")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")

        fx.releaseCommand()
        XCTAssertTrue(fx.hungProcessGone("sudo"))
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(try fx.waitUntilLockIsFree(5), "the lock goes with the sudo that held it")
    }

    /// The sudoers check under the lock never answers and ignores SIGTERM,
    /// with every poll slow (see slowPollingPath). The run still gives up on
    /// it after the 5 s limit and at least two seconds for SIGTERM, within
    /// four seconds of the limit, and leaves it running: sudo is never sent
    /// SIGKILL.
    func testInstallGivesUpOnAHungSudoOnTimeWhenEveryPollIsSlow() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-check-hangs")

        let started = Date()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "PATH": try fx.slowPollingPath()])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertGreaterThan(fx.slowPolls(), 0, "the script polled through the slow sleep")
        XCTAssertGreaterThan(elapsed, 8, "the limit, then at least two seconds after SIGTERM")
        XCTAssertLessThan(elapsed, 15, "the 5 s limit, at most four seconds more, and a few slow polls")
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0))
        XCTAssertTrue(r.stderr.contains("It was sent SIGTERM and is still running. It is not killed"), r.stderr)
        XCTAssertFalse(r.stderr.contains("sudo kill") || r.stderr.contains("pid \(pid)"), r.stderr)
        XCTAssertTrue(fx.calls().contains("sudo SIGTERM"), "\(fx.calls())")
        XCTAssertFalse(fx.hungProcessGone("sudo", within: 2), "sudo is never sent SIGKILL")
        fx.releaseCommand()
        XCTAssertTrue(fx.hungProcessGone("sudo"))
    }

    /// The sudoers check under the lock never answers and ignores SIGTERM.
    /// sudo is never sent SIGKILL, so it stays, and it keeps the recovery
    /// lock until it ends, as backstop.sh does with a sudo pmset: the run
    /// exits, says the lock is held until that sudo ends, without a pid to
    /// kill, and the lock is free once that sudo has ended.
    func testInstallLeavesASudoersCheckThatIgnoresSigtermHoldingTheLock() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-check-ignores-term-under-lock")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0))
        XCTAssertTrue(r.stderr.contains("did not answer within 5s. It was sent SIGTERM and is still running. It is not killed, because killing sudo could leave what it runs as root behind.\nIt keeps the recovery lock until it ends"), r.stderr)
        XCTAssertFalse(r.stderr.contains("sudo kill") || r.stderr.contains("pid \(pid)"), r.stderr)
        assertRerunNote(r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo FD9-OPEN"), "\(calls)")
        XCTAssertTrue(calls.contains("sudo SIGTERM"), "\(calls)")
        XCTAssertFalse(fx.hungProcessGone("sudo", within: 2), "sudo is never sent SIGKILL")
        XCTAssertFalse(try fx.lockIsFree(), "the sudo started under the lock still runs, so the lock stays held")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")

        fx.releaseCommand()
        XCTAssertTrue(fx.hungProcessGone("sudo"))
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(try fx.waitUntilLockIsFree(5), "the lock goes with the sudo that held it")
    }

    /// A `pgrep` that never answers under the lock does not show the app is
    /// gone, so the run stops before recovery and lets go of the lock.
    func testInstallTreatsAPgrepThatDoesNotAnswerUnderTheLockAsUnknown() throws {
        try writePreviousPair()
        fx.setMode("pgrep", "1\nhang\n")   // not running at the quit step, then no answer

        let started = Date()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30)
        XCTAssertTrue(r.stderr.contains("pgrep did not answer within 5s, so whether Insomnia started again is unknown."), r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("pgrep FD9-OPEN"), "\(calls)")
        XCTAssertTrue(fx.hungProcessGone("pgrep", within: 0))
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// `launchctl print` never answers under the lock: the previous job's
    /// state is unknown, before the bootout and after it, so the bundle is
    /// not replaced. Each print is stopped at the limit, and the run exits
    /// and lets go of the lock instead of waiting on launchd.
    func testInstallStopsAndLetsGoOfTheLockWhenLaunchctlPrintDoesNotAnswer() throws {
        try writePreviousPair()
        fx.setMode("launchctl", "print-hangs")

        let started = Date()
        let tmp = try fx.privateTmp()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "TMPDIR": tmp.path])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 45, "two bounded prints, not two 60 s hangs")
        XCTAssertTrue(r.stderr.contains("'launchctl print gui/\(fx.uid)/com.insomnia.backstop' did not answer within 5s; whether the job is loaded is unknown (unknown:124)."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Install stopped: unloading the previous LaunchAgent job was not confirmed\n(launchctl print: unknown:124)"), r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("launchctl FD9-OPEN"), "\(calls)")
        XCTAssertTrue(fx.hungProcessGone("launchctl", within: 0))
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl print") }.count, 2, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootstrap") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"])
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(try fx.contents(of: tmp), [], "the scratch directory is gone, including the stopped calls' files")
    }

    /// An install killed while its `launchctl bootout` does not answer. The
    /// bootout keeps the recovery lock until its supervisor has stopped it
    /// at the limit, although the run that started it is gone: the lock is
    /// never free while the bootout still runs, so it cannot unload an agent
    /// the app confirms after taking the lock.
    func testAKilledInstallKeepsTheLockUntilItsBootoutIsStopped() throws {
        try writePreviousPair()
        fx.setMode("launchctl", "bootout-hangs")

        let pid = try killDuringHungBootout(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        try assertLockHeldUntilGone(pid, within: 20)
        XCTAssertTrue(fx.calls().contains("launchctl FD9-OPEN"), "\(fx.calls())")
    }

    /// The killed install above, with every poll slow (see slowPollingPath).
    /// The supervisor, alone once the run is gone, still stops the bootout
    /// and lets go of the lock within three seconds of the 5 s limit.
    func testAKilledInstallLetsGoOfTheLockOnTimeWhenEveryPollIsSlow() throws {
        try writePreviousPair()
        fx.setMode("launchctl", "bootout-hangs")

        let pid = try killDuringHungBootout(fx.installRedirected, extraEnvironment: ["USER": "tester", "PATH": try fx.slowPollingPath()])

        try assertLockHeldUntilGone(pid, within: 10)
        XCTAssertGreaterThan(fx.slowPolls(), 0, "the script polled through the slow sleep")
        XCTAssertTrue(fx.calls().contains("launchctl FD9-OPEN"), "\(fx.calls())")
    }

    /// Starts `script`, waits for its `launchctl bootout` to hang, and kills
    /// the script with SIGKILL; returns the hung bootout's pid. The only
    /// process signaled is the script shell, posix_spawned and reaped only
    /// after the signal, so its pid cannot have been reused. Throws if the
    /// bootout never starts or the script ends before it can be killed.
    func killDuringHungBootout(_ script: URL, extraEnvironment: [String: String] = [:]) throws -> pid_t {
        let shell = try fx.spawn(script, extraEnvironment: extraEnvironment)
        defer { shell.wait() }
        guard let pid = fx.hungPid("launchctl", within: 60) else {
            _ = shell.signal(SIGKILL)
            throw FixtureError("the bootout never started: \(fx.calls())")
        }
        guard !shell.hasExited else {
            throw FixtureError("the script ended before the test could kill it (wait status \(shell.wait())), so it was not signaled: \(fx.calls())")
        }
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the script did not end by SIGKILL (wait status \(status))")
        return pid
    }

    /// Samples the lock until it is free: whenever it is, the hung fake
    /// `pid` must be gone already. Fails if the lock is not free within
    /// `seconds`.
    func assertLockHeldUntilGone(_ pid: pid_t, within seconds: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try fx.lockIsFree() {
                XCTAssertFalse(kill(pid, 0) == 0, "the lock was free while pid \(pid) still ran", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("the lock was not free within \(seconds) s; pid \(pid) running: \(kill(pid, 0) == 0)", file: file, line: line)
    }

    /// The scripts/simulate-lid.sh watcher is compiled out of a release
    /// build unless the installer is told to compile it in: only
    /// INSOMNIA_LID_SIMULATION=1 adds the define to the swift build lines,
    /// and the installer says so.
    func testInstallCompilesTheLidSimulationInOnlyWhenAsked() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")

        let plain = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        XCTAssertEqual(plain.status, 0, plain.stderr + plain.stdout)
        let plainBuilds = fx.calls().filter { $0.hasPrefix("swift build") }
        XCTAssertEqual(plainBuilds, ["swift build -c release", "swift build -c release --show-bin-path"], "\(fx.calls())")
        XCTAssertFalse(plain.stdout.contains("lid simulation compiled in"), plain.stdout)

        fx.clearCalls()
        let simulated = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "INSOMNIA_LID_SIMULATION": "1"])
        XCTAssertEqual(simulated.status, 0, simulated.stderr + simulated.stdout)
        let simulatedBuilds = fx.calls().filter { $0.hasPrefix("swift build") }
        XCTAssertEqual(simulatedBuilds, [
            "swift build -c release -Xswiftc -DINSOMNIA_LID_SIMULATION",
            "swift build -c release -Xswiftc -DINSOMNIA_LID_SIMULATION --show-bin-path",
        ], "\(fx.calls())")
        XCTAssertTrue(simulated.stdout.contains("lid simulation compiled in (INSOMNIA_LID_SIMULATION=1)"), simulated.stdout)

        // Any other value is "off": the define is a deliberate opt-in.
        fx.clearCalls()
        let other = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "INSOMNIA_LID_SIMULATION": "yes"])
        XCTAssertEqual(other.status, 0, other.stderr + other.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("swift build") }.first, "swift build -c release", "\(fx.calls())")

        // A prebuilt bundle is already compiled: asking for the watcher with
        // --app is refused before anything runs, instead of installing a
        // build without it.
        fx.clearCalls()
        let prebuilt = try fx.writePrebuiltApp()
        let withApp = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester", "INSOMNIA_LID_SIMULATION": "1"])
        XCTAssertEqual(withApp.status, 2, withApp.stderr + withApp.stdout)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(withApp.stderr.contains("INSOMNIA_LID_SIMULATION=1 applies to a source build only"), withApp.stderr)
    }

    func testInstallLeavesTrustedPlistWhenBootstrapAndReloadBothFail() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-then-lost")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("launchctl bootstrap") }.count, 2, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted", "byte-for-byte untouched")
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"], "no candidate left behind")
        XCTAssertTrue(r.stderr.contains("could not be loaded again"), r.stderr)
        XCTAssertTrue(r.stderr.contains("launchctl bootstrap gui/\(fx.uid)"), "manual command named: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("every minute"), r.stderr)
    }

    /// print cannot say whether the previous job is gone after the bootout,
    /// so the swap does not happen: no bundle moves and nothing is loaded.
    func testInstallDoesNotReloadOrClaimAbsenceOnAmbiguousLaunchctl() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "ambiguous")   // print and bootout fail with errors; bootstrap fails

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("launchctl bootstrap") }.count, 0, "nothing is loaded while the previous job may still be: \(fx.calls())")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the previous bundle was not replaced")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the staged build is discarded")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("(launchctl print: unknown:1), so the app at \(fx.app.path) was not replaced"), r.stderr)
        XCTAssertTrue(r.stderr.contains("  launchctl bootstrap gui/\(fx.uid) \(fx.plist.path)\n"), "how to reload the previous job if it is gone: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("unknown"), r.stderr)
        XCTAssertFalse(r.stderr.contains("No LaunchAgent"), "ambiguous is not absent: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("every minute"), r.stderr)
    }

    func testInstallReportsUnknownNotAbsentWhenTheLaterPrintFails() throws {
        // Nothing loaded before, bootstrap fails, then `print` itself errors:
        // the current state is unknown and must not be reported as absent.
        // A job print cannot rule out would be this run's, so after the
        // unload is not confirmed either the new build stays with it.
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "no-then-error")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "no reload when nothing was loaded before: \(calls)")
        let load = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("launchctl bootstrap") })
        XCTAssertTrue(calls[load...].contains("launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "the job print cannot rule out is unloaded: \(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "#!/bin/bash", "the unload is not confirmed, so the new build stays")
        XCTAssertTrue(r.stderr.contains("not confirmed (launchctl print: unknown:1)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("No app was installed at \(fx.app.path) before this run"), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("unknown"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not confirmed"), r.stderr)
        XCTAssertFalse(r.stderr.contains("none is loaded now"), "unknown is not absent: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("No LaunchAgent"), r.stderr)
    }

    func testInstallDoesNotAttributeAnExistingJobToAFailedReload() throws {
        // A job was loaded before; the candidate bootstrap fails and so does
        // the reload of the previous plist, after which `print` lists a job.
        // That job's source is unknown; it must not be called "loaded again
        // from the previous plist".
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-reload-fails-yet-listed")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("launchctl bootstrap") }.count, 2, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("reload"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not confirmed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("unknown"), "source of the existing job is unknown: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("loaded again from the previous plist"), r.stderr)
        XCTAssertFalse(r.stderr.contains("every minute"), r.stderr)
    }

    func testInstallDoesNotPublishWhenLoadedStatusIsNotConfirmed() throws {
        // Mode ok: bootstrap reports success but `print` never lists the job.
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted", "nothing is published without a confirmed load")
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"])
        XCTAssertTrue(r.stderr.contains("not confirmed"), r.stderr)
        XCTAssertFalse(r.stdout.contains("Installed"), r.stdout)
    }

    func testInstallRefusesWhileRecoveryLockIsHeld() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let holder = try fx.holdLock()
        defer { holder.stop() }

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 75, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery outside the lock: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(r.stderr.contains("recovery lock"), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "the rule is written only under the lock")
        XCTAssertFalse(calls.contains { $0.contains("/usr/sbin/visudo") }, "\(calls)")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertFalse(r.stderr.contains("already holds the new three-line rule"), r.stderr)
    }

    func testInstallStopsWhenAppStartsAgainUnderTheLock() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "1\n0\n")   // not running at the quit step, running again under the lock
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery beside a running app: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("started again"), r.stderr)
        XCTAssertFalse(calls.contains { $0.contains("/usr/sbin/visudo") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
    }

    /// The rule is written under the recovery lock, after the look for a
    /// running app and while the previous build is still at $APP: an
    /// uninstall.sh that removes the rule under the same lock cannot come
    /// between the write and the check, and the new build reaches $APP only
    /// after both, with its backstop.sh sealed inside it.
    func testInstallWritesTheRuleUnderTheLockBeforeTheNewBundle() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(try String(contentsOf: fx.root.appendingPathComponent("at-visudo"), encoding: .utf8), "lock=held app=old\n")
        let look = try XCTUnwrap(calls.lastIndex(of: "pgrep -x Insomnia"), "\(calls)")
        let visudo = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo -n /usr/sbin/visudo -cf ") }, "\(calls)")
        let install = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo -n /usr/bin/install -m 0440 -o root -g wheel ") }, "\(calls)")
        let check = try XCTUnwrap(calls.firstIndex(of: "sudo -k -n -l /usr/bin/pmset -a disablesleep 0"), "\(calls)")
        let bootout = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("launchctl bootout") }, "\(calls)")
        XCTAssertLessThan(look, visudo, "the app is looked for under the lock first: \(calls)")
        XCTAssertLessThan(visudo, install)
        XCTAssertLessThan(install, check, "the listing checks the file just written: \(calls)")
        XCTAssertLessThan(check, bootout, "the previous pair is touched only after the check: \(calls)")
        XCTAssertEqual(try sudoersRules(), Self.passwordlessLines)
        XCTAssertEqual(try Data(contentsOf: fx.installedBackstop), try Data(contentsOf: fx.backstop))
        XCTAssertEqual(try fx.mode(fx.installedBackstop) & 0o777, 0o755)
        XCTAssertNotEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertFalse(r.stderr.contains("already holds the new three-line rule"), r.stderr)
    }

    /// install.sh's exit trap deletes its temporary sudoers file through
    /// RM=/bin/rm. An rm first on PATH that keeps mktemp's files changes
    /// nothing, on a stop at the rule check and on a full install. The bundle, backstop.sh and the LaunchAgent
    /// are written through fixed paths too: a full install calls none of
    /// the file tools first on PATH for them. The temporary sudoers file is
    /// made and written the same way, so a cat first on PATH that adds a
    /// line to the rule never reaches the installed file.
    func testInstallCleansUpWithoutPATH() throws {
        let shadow = fx.root.appendingPathComponent("shadow", isDirectory: true)
        try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
        let shadowCalls = shadow.appendingPathComponent("calls")
        let tools = ["rm": "/bin/rm", "rmdir": "/bin/rmdir", "mkdir": "/bin/mkdir", "cp": "/bin/cp", "install": "/usr/bin/install",
                     "mv": "/bin/mv", "mktemp": "/usr/bin/mktemp", "cat": "/bin/cat"]
        for (tool, real) in tools {
            let keep = switch tool {
            case "rm": #"for a in "$@"; do [[ "${a##*/}" == tmp.* ]] && exit 0; done"#
            case "cat": #"if (( $# == 0 )); then t="$(/bin/cat)"; printf '%s\n' "$t"; [[ "$t" == *NOPASSWD* ]] && echo "tester ALL=(ALL) NOPASSWD: ALL"; exit 0; fi"#
            default: ""
            }
            let url = shadow.appendingPathComponent(tool)
            try """
            #!/bin/bash
            printf '%s %s\\n' \(tool) "$*" >> '\(shadowCalls.path)'
            \(keep)
            exec \(real) "$@"
            """.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let env = ["USER": "tester", "PATH": "\(shadow.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        // The file install.sh validated with visudo is its temporary copy.
        func tempFile() throws -> String {
            let line = try XCTUnwrap(fx.calls().last { $0.hasPrefix("sudo -n /usr/sbin/visudo -cf ") }, "\(fx.calls())")
            return String(line.dropFirst("sudo -n /usr/sbin/visudo -cf ".count))
        }

        fx.setMode("sudo", "rule-not-effective")
        var r = try fx.run(fx.installRedirected, extraEnvironment: env)
        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("does not list its commands without a password"), r.stderr)
        var temp = try tempFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp), "the trap left \(temp) after a stop")
        try? FileManager.default.removeItem(atPath: temp)

        fx.clearCalls()
        fx.setMode("sudo", "ok")
        fx.setMode("launchctl", "loaded")
        r = try fx.run(fx.installRedirected, extraEnvironment: env)
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        temp = try tempFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp), "the trap left \(temp) after an install")
        try? FileManager.default.removeItem(atPath: temp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.app.appendingPathComponent("Contents/MacOS/Insomnia").path))
        let fromPATH = (try? String(contentsOf: shadowCalls, encoding: .utf8)) ?? ""
        for path in [fx.app.path, fx.installedBackstop.path, fx.plist.deletingLastPathComponent().path] {
            XCTAssertFalse(fromPATH.contains(path), "install.sh reached a tool through PATH for \(path):\n\(fromPATH)")
        }
        XCTAssertFalse(fromPATH.split(separator: "\n").contains { $0.hasPrefix("mktemp") }, fromPATH)
        let rule = try String(contentsOf: fx.sudoers, encoding: .utf8)
        XCTAssertTrue(rule.contains("NOPASSWD: /usr/bin/pmset -a disablesleep 0"), rule)
        XCTAssertFalse(rule.contains("NOPASSWD: ALL"), rule)
    }

    func testInstallRefusesRelocatedHomeBeforeDoingAnything() throws {
        // The only install.sh run in this suite: INSOMNIA_HOME is set, so the
        // script must exit before its first build/quit/install step.
        let r = try fx.run(fx.install, [], extraEnvironment: ["INSOMNIA_HOME": fx.home.path])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("INSOMNIA_HOME"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertFalse(r.stdout.contains("==>"), "no step ran: \(r.stdout)")
    }

    /// Same regression as LaunchdBackstopTests: launchctl refuses a path
    /// without a `.plist` suffix (EIO) for bootstrap and bootout alike, and
    /// login's directory-level load ignores subdirectories. The installer's
    /// candidate must be a `.plist` one level below the trusted plist, and
    /// the old job is booted out by label.
    func testInstallCandidateIsALaunchdLoadablePlistThatLoginCannotPickUp() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("launchctl bootout gui/\(fx.uid)/com.insomnia.backstop"), "boot out by service target: \(calls)")
        let bootstrap = try XCTUnwrap(calls.first { $0.hasPrefix("launchctl bootstrap") })
        let candidate = URL(fileURLWithPath: String(bootstrap.dropFirst("launchctl bootstrap gui/\(fx.uid) ".count)))
        XCTAssertTrue(candidate.lastPathComponent.hasSuffix(".plist"), "launchctl refuses to bootstrap \(candidate.lastPathComponent)")
        let launchAgents = fx.plist.deletingLastPathComponent()
        XCTAssertNotEqual(candidate.deletingLastPathComponent().path, launchAgents.path, "a *.plist directly in LaunchAgents is loaded at login as a second copy")
        XCTAssertEqual(candidate.deletingLastPathComponent().deletingLastPathComponent().path, launchAgents.path, "one level below the trusted plist, same filesystem")
        XCTAssertTrue(try String(contentsOf: fx.plist, encoding: .utf8).contains("<integer>60</integer>"))
        XCTAssertEqual(try fx.contents(of: launchAgents), ["com.insomnia.backstop.plist"], "staging directory not removed")
    }

    /// The password comes before the quit. A wrong or cancelled password
    /// stops the install with the app still running: it is never asked to
    /// quit, and the sudoers file, bundle, backstop.sh and plist are as
    /// they were.
    func testInstallWithTheAppRunningChangesNothingWhenSudoAuthFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n")          // running
        fx.setMode("sudo", "auth-fail")     // wrong password / no sudo rights

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("sudo") }, ["sudo -v"], "the password is the first and only sudo: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "the app was asked to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("pkill") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "sudoers rule replaced")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not asked to quit"), r.stderr)
        XCTAssertFalse(r.stderr.contains("Insomnia was quit"), r.stderr)
    }

    /// A cancelled password while a session runs: the installer said the
    /// upgrade would end the session before it asked, and the cancel leaves
    /// the app and its session running. session.json is untouched and no
    /// recovery runs.
    func testInstallCancelledPasswordDuringASessionLeavesTheSessionRunning() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try fx.writeSession(endsAt: Date().addingTimeInterval(3600))
        let session = try Data(contentsOf: fx.session)
        fx.setMode("pgrep", "0\n")          // running
        fx.setMode("sudo", "auth-fail")     // the password dialog was cancelled

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let warning = try XCTUnwrap(r.stdout.range(of: "A session is running and the upgrade will end it."), r.stdout)
        let auth = try XCTUnwrap(r.stdout.range(of: "==> Authenticating"), r.stdout)
        XCTAssertLessThan(warning.lowerBound, auth.lowerBound, "said before the password is asked for")
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("sudo") }, ["sudo -v"], "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "the app was asked to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try Data(contentsOf: fx.session), session, "session.json changed")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("a running session keeps going"), r.stderr)
    }

    /// In a terminal, the installer asks before it ends a session. Anything
    /// but yes stops it before the password: no sudo, no quit.
    func testInstallInATerminalStopsBeforeThePasswordWhenTheUserKeepsTheSession() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try fx.writeSession(endsAt: Date().addingTimeInterval(3600))
        fx.setMode("pgrep", "0\n")          // running

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"], terminalInput: "n\n")

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("A session is running and the upgrade will end it."), r.stdout)
        XCTAssertTrue(r.stderr.contains("Continue? [y/N]"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed; the session keeps running."), r.stderr)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.session.path))
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule")
    }

    /// Yes in a terminal goes ahead: password, quit, rule, bundle.
    func testInstallInATerminalGoesAheadWhenTheUserAgreesToEndTheSession() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeSession(endsAt: Date().addingTimeInterval(3600))
        fx.setMode("pgrep", "0\n1\n")       // running, then quits when asked
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"], terminalInput: "y\n")

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Continue? [y/N]"), r.stderr)
        let calls = fx.calls()
        let auth = try XCTUnwrap(calls.firstIndex(of: "sudo -v"), "\(calls)")
        let quit = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertLessThan(auth, quit, "the password comes before the quit: \(calls)")
        XCTAssertEqual(try sudoersRules(), Self.passwordlessLines)
    }

    /// Without a terminal there is no one to ask: the line is printed and
    /// the install goes ahead.
    func testInstallWithoutATerminalSaysTheSessionWillEndAndGoesAhead() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeSession(endsAt: Date().addingTimeInterval(3600))
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("A session is running and the upgrade will end it."), r.stdout)
        XCTAssertFalse(r.stderr.contains("Continue?"), r.stderr)
    }

    /// A session whose deadline has passed is not running: no line, and no
    /// question even in a terminal.
    func testInstallDoesNotAskAboutAnExpiredSession() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.writeSession(endsAt: Date().addingTimeInterval(-60))
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"], terminalInput: "n\n")

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(r.stdout.contains("A session is running"), r.stdout)
        XCTAssertFalse(r.stderr.contains("Continue?"), r.stderr)
    }

    /// The quit can outlast sudo's cached credential. The installer then
    /// asks for the password once more and finishes.
    func testInstallAsksAgainWhenTheCredentialExpiredDuringTheQuit() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "0\n1\n")       // running, then quits when asked
        fx.setMode("sudo", "cache-expires")
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("asking again"), r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0 == "sudo -v" }.count, 2, "\(calls)")
        XCTAssertEqual(try sudoersRules(), Self.passwordlessLines)
    }

    /// The app quit, the cached credential expired, and the second password
    /// fails: the sudoers file, bundle, backstop.sh and plist are as they
    /// were, and the message says the app was quit so the old build can be
    /// opened again with its rule intact.
    func testInstallThatQuitTheAppChangesNothingElseWhenTheSecondPasswordFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n1\n")       // running, then quits when asked
        fx.setMode("sudo", "reauth-fails")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        let auth = try XCTUnwrap(calls.firstIndex(of: "sudo -v"), "\(calls)")
        let quit = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("osascript") }, "the app was not asked to quit: \(calls)")
        XCTAssertLessThan(auth, quit, "the password comes before the quit: \(calls)")
        XCTAssertEqual(calls.filter { $0 == "sudo -v" }.count, 2, "\(calls)")
        XCTAssertFalse(calls.contains { $0.contains("/usr/sbin/visudo") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.contains("/usr/bin/install") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "sudoers rule replaced")
        XCTAssertTrue(r.stderr.contains("Insomnia was quit"), r.stderr)
        XCTAssertTrue(r.stderr.contains("nothing else was changed"), r.stderr)
        XCTAssertFalse(r.stderr.contains("already holds the new three-line rule"), r.stderr)
    }

    /// Authentication passes, the app quits, but sudo does not list the
    /// commands of the rule it installed: the rule is new, the bundle (its
    /// backstop.sh included) and the LaunchAgent are as they were, and the
    /// message says the old build cannot start a session until the rerun.
    func testInstallStopsBeforeTheBundleWhenSudoersRuleIsNotEffective() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n1\n")       // running, then quits when asked
        fx.setMode("sudo", "rule-not-effective")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        let auth = try XCTUnwrap(calls.firstIndex(of: "sudo -v"), "\(calls)")
        let quit = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("osascript") }, "the app was not asked to quit: \(calls)")
        let visudo = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo -n /usr/sbin/visudo") }, "\(calls)")
        XCTAssertLessThan(auth, quit, "the password comes before the quit: \(calls)")
        XCTAssertLessThan(quit, visudo, "the app is quit before the rule is written: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery ran: \(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
        XCTAssertTrue(try sudoersRules() == Self.passwordlessLines, "the new rule is what was installed")
        XCTAssertTrue(r.stderr.contains("does not list its commands without a password"), r.stderr)
        XCTAssertTrue(try fx.lockIsFree())
        assertRerunNote(r.stderr)
    }

    /// With no app running there is nothing to wait for: an installer that
    /// assembled the bundle and copied backstop.sh before asking for the
    /// password would reach the overwrite path here. Authentication must
    /// still be the first sudo, and its failure must leave the old bundle,
    /// helper, plist and sudoers file byte for byte as they were.
    func testInstallWithNoAppRunningStopsBeforeReplacingAnythingWhenSudoAuthFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        // pgrep default: not running at any check
        fx.setMode("sudo", "auth-fail")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.hasPrefix("sudo") }, ["sudo -v"], "authentication was attempted, and nothing after it: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "nothing to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "sudoers rule replaced")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
    }

    /// Same with the app not running: authentication passes and the rule is
    /// installed, but it does not grant pmset. The bundle and plist are
    /// still untouched.
    func testInstallWithNoAppRunningStopsBeforeTheBundleWhenSudoersRuleIsNotEffective() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        // pgrep default: not running at any check
        fx.setMode("sudo", "rule-not-effective")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls.first { $0.hasPrefix("sudo") }, "sudo -v", "authentication comes first: \(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("sudo -n /usr/bin/install") && $0.hasSuffix(" " + fx.sudoers.path) }, "the rule was installed before being checked: \(calls)")
        XCTAssertFalse(calls.contains { $0.contains(fx.receipts) }, "the receipt comes after the rule's check: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "nothing to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertTrue(try String(contentsOf: fx.sudoers, encoding: .utf8).contains("NOPASSWD: /usr/bin/pmset"), "the new rule is what was installed")
        XCTAssertTrue(r.stderr.contains("does not list its commands without a password"), r.stderr)
        assertRerunNote(r.stderr)
    }

    /// An app that will not quit stops the install after the password and
    /// before the rule: no sudo besides `sudo -v`, the sudoers file, bundle,
    /// backstop.sh and LaunchAgent exactly as they were, and the refusal
    /// stands (no pkill).
    func testInstallStopsBeforeTheSudoersRuleWhenAppKeepsRunning() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n")          // running, and it stays running

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("osascript") }, "the app was asked to quit: \(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("sudo") }, ["sudo -v"], "nothing written for an install that cannot finish: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("pkill") }, "a refused quit stands: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "the sudoers file was touched")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
        XCTAssertTrue(r.stderr.contains("still running"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
    }

    /// The passwordless lines, in one place for the tests below. None of
    /// them can keep the Mac awake: turning sleep off has no line and goes
    /// through the administrator password dialog in the app.
    private static let passwordlessLines = [
        "tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0",
        "tester ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1",
        "tester ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0",
    ]

    private func sudoersRules() throws -> [String] {
        try String(contentsOf: fx.sudoers, encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func testInstallWritesExactlyThreePasswordlessLinesAndNoneTurnsSleepOff() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try sudoersRules(), Self.passwordlessLines)
        let text = try String(contentsOf: fx.sudoers, encoding: .utf8)
        XCTAssertFalse(text.contains("disablesleep 1"), "a passwordless way to keep the Mac awake: \(text)")
        let calls = fx.calls()
        XCTAssertEqual(calls.filter { $0.contains(" -l ") }, [
            "sudo -k -n -l /usr/bin/pmset -a disablesleep 0",
            "sudo -k -n -l /usr/bin/pmset -b lowpowermode 1",
            "sudo -k -n -l /usr/bin/pmset -b lowpowermode 0",
        ], "each line is listed with -k, which ignores the credential sudo -v cached: \(calls)")
        XCTAssertTrue(r.stdout.contains("'sudo -k -n -l' lists its three commands"), r.stdout)
        // The sudoers file, then the receipt and its release file; nothing
        // else goes through install.
        let installs = calls.filter { $0.hasPrefix("sudo -n /usr/bin/install") }
        XCTAssertEqual(installs.filter { $0.hasSuffix(" " + fx.sudoers.path) }.count, 1, "written once, never through a four-line state: \(calls)")
        XCTAssertEqual(installs.count, 3, "\(installs)")
        XCTAssertTrue(installs.dropFirst().first?.hasSuffix(" " + fx.receipt) == true, "\(installs)")
        XCTAssertTrue(installs.last?.hasSuffix(" " + fx.released) == true, "\(installs)")
    }

    /// install.sh never runs pmset itself, so it changes no power setting,
    /// whatever SleepDisabled reads: no `pmset -g`, and pmset reaches sudo
    /// only in a listing.
    func testInstallRunsNoPmsetCommand() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        fx.setMode("pmset", "1")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("pmset") }, "\(calls)")
        let sudoPmset = calls.filter { $0.hasPrefix("sudo") && $0.contains("pmset") }
        XCTAssertFalse(sudoPmset.isEmpty, "\(calls)")
        XCTAssertTrue(sudoPmset.allSatisfy { $0.hasPrefix("sudo -k -n -l /usr/bin/pmset ") }, "\(sudoPmset)")
    }

    /// An administrator without the rule: `sudo -v` cached a credential,
    /// so a listing without -k, or a plain `sudo -n`, would pass. The check
    /// lists with -k, which ignores that credential, so the install stops
    /// before the bundle and says the rule is not in effect.
    func testInstallStopsWhenOnlyTheCachedCredentialWouldListTheRule() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("sudo", "no-rule-cached")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo -k -n -l /usr/bin/pmset -a disablesleep 0"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n -l") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
        XCTAssertTrue(r.stderr.contains("does not list its commands without a password"), r.stderr)
        assertRerunNote(r.stderr)
    }

    /// A reinstall over the four-line rule of an older build replaces the
    /// file: the `disablesleep 1` line does not survive.
    func testReinstallOverFourLineRuleLeavesThreeLines() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try """
        # Installed by Insomnia install.sh. Exactly four commands, nothing else.
        tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
        tester ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
        tester ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
        tester ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0

        """.write(to: fx.sudoers, atomically: true, encoding: .utf8)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try sudoersRules(), Self.passwordlessLines)
        XCTAssertFalse(try String(contentsOf: fx.sudoers, encoding: .utf8).contains("disablesleep 1"))
        let installs = fx.calls().filter { $0.hasPrefix("sudo -n /usr/bin/install") }
        XCTAssertEqual(installs.filter { $0.hasSuffix(" " + fx.sudoers.path) }.count, 1, "written once: \(fx.calls())")
        XCTAssertEqual(installs.count, 3, "the sudoers file, the receipt and its release file: \(installs)")
        XCTAssertTrue(installs.dropFirst().first?.hasSuffix(" " + fx.receipt) == true, "\(installs)")
        XCTAssertTrue(installs.last?.hasSuffix(" " + fx.released) == true, "\(installs)")
    }

    /// No path of the installer may grant passwordless `disablesleep 1`:
    /// no line outside a comment mentions it at all.
    func testInstallerHasNoLineThatGrantsPasswordlessSleepOff() throws {
        try fx.prepareInstall()
        let text = try String(contentsOf: fx.installRedirected, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .filter { $0.contains("disablesleep 1") }
        XCTAssertEqual(lines, [])
    }

    private func assertRerunNote(_ stderr: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(stderr.contains("already holds the new three-line rule"), stderr, file: file, line: line)
        XCTAssertTrue(stderr.contains("cannot start a session"), stderr, file: file, line: line)
        XCTAssertTrue(stderr.contains("Finish the install by rerunning:\n  "), stderr, file: file, line: line)
        XCTAssertTrue(stderr.contains("/scripts/install.sh"), stderr, file: file, line: line)
    }
}

// MARK: - Fixture

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// A throwaway tree:
///   root/home              INSOMNIA_HOME (session.json, state.json, Logs/, LaunchAgents/)
///   root/bin               recording fakes
///   root/repo/scripts      patched copies of backstop.sh and uninstall.sh
///   root/Applications      fake Insomnia.app bundle
///   root/etc/sudoers.d     fake sudoers rule
/// The child gets no HOME at all: every $HOME-derived constant is patched in
/// the copy, and a stray $HOME would fail under `set -u` instead of reaching
/// the real home directory.
private final class ScriptFixture {
    let root: URL
    let home: URL
    let bin: URL
    let repoScripts: URL
    let appsDir: URL
    let app: URL
    let sudoers: URL
    let callsLog: URL
    let bootUUID = "0F0F0F0F-1111-2222-3333-444444444444"
    let uid = String(getuid())
    /// The scripts' RECEIPTS: a folder in the real path of `root`, so the
    /// folder checks meet no link on the way up (the temporary directory is
    /// under /var, a link to /private/var). RECEIPT_OWNER is the test user,
    /// who owns it and every folder up to the temporary directory.
    private(set) var receipts = ""
    var receipt: String { receipts + "/" + uid }
    /// The release file beside it (SleepOffReceipts.releaseFile).
    var released: String { receipt + ".released" }
    /// Every call to the scripts' CAT, HEAD and TR (see writeFakes).
    var toolsLog: URL { root.appendingPathComponent("tools.log") }
    /// The PATH each of those calls was given.
    var toolPathsLog: URL { root.appendingPathComponent("tools.path") }

    var backstop: URL { repoScripts.appendingPathComponent("backstop.sh") }
    var uninstall: URL { repoScripts.appendingPathComponent("uninstall.sh") }
    var install: URL { repoScripts.appendingPathComponent("install.sh") }
    var installRedirected: URL { repoScripts.appendingPathComponent("install.redirected.sh") }
    /// installRedirected with a 1 s limit for each bounded call.
    var session: URL { home.appendingPathComponent("session.json") }
    var state: URL { home.appendingPathComponent("state.json") }
    var config: URL { home.appendingPathComponent("config.json") }
    var lock: URL { home.appendingPathComponent(".recovery.lock") }
    var pendingStart: URL { home.appendingPathComponent("pending-start") }
    /// backstop.sh as install.sh seals it into the bundle.
    var installedBackstop: URL { app.appendingPathComponent("Contents/Resources/backstop.sh") }
    /// The writable copy installs before the sealed layout left here.
    var legacyBackstop: URL { home.appendingPathComponent("backstop.sh") }
    /// What the fake codesign prints as the bundle's designated requirement.
    let requirement = "cdhash H\"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c\""
    var logFile: URL { home.appendingPathComponent("Logs/insomnia.log") }
    var plist: URL { home.appendingPathComponent("LaunchAgents/com.insomnia.backstop.plist") }
    var fakePmset: String { bin.appendingPathComponent("pmset").path }
    /// The fake app binary backstop.sh calls for `--resume-frozen`.
    var fakeInsomnia: URL { bin.appendingPathComponent("Insomnia") }
    /// The installed bundle's Info.plist. As in production, both scripts
    /// read this one file: uninstall.sh to pick a backstop, and the
    /// backstop copies before they run the fake binary. writeFakes makes it
    /// declare InsomniaResumeFrozenVersion 1. The fake binary itself stays
    /// in `bin`, so installMachinery and install.sh can put their own
    /// Contents/MacOS/Insomnia in the bundle.
    var appInfo: URL { app.appendingPathComponent("Contents/Info.plist") }

    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("insomnia-script-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        bin = root.appendingPathComponent("bin", isDirectory: true)
        repoScripts = root.appendingPathComponent("repo/scripts", isDirectory: true)
        appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        app = appsDir.appendingPathComponent("Insomnia.app", isDirectory: true)
        sudoers = root.appendingPathComponent("etc/sudoers.d/insomnia")
        callsLog = root.appendingPathComponent("calls.log")
        for dir in [home, bin, repoScripts, appsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let resolved = realpath(root.path, nil) else { throw FixtureError("no real path for \(root.path)") }
        receipts = String(cString: resolved) + "/receipts"
        free(resolved)
        // repo/ is a source checkout to install.sh and uninstall.sh: their
        // folder is scripts/, with Package.swift one level up.
        try "// swift-tools-version: 6.2\n".write(to: root.appendingPathComponent("repo/Package.swift"), atomically: true, encoding: .utf8)
        try writeFakes()
        try writeScriptCopies()
        try bootUUID.write(to: root.appendingPathComponent("boot.uuid"), atomically: true, encoding: .utf8)
    }

    func destroy() {
        releaseCommand()
        // A supervisor still waiting to write its status into a FIFO would
        // wait forever once the FIFO is gone.
        drainStatusFIFOs(within: 1)
        try? fm.removeItem(at: root)
    }

    /// The backstop's files in INSOMNIA_HOME: each bounded call's .pid and
    /// .rc status files, and the app binary's input and answer directory.
    func backstopFiles() throws -> [String] {
        try contents(of: home).filter { $0.hasPrefix(".backstop") }
    }

    /// Opens each FIFO among the backstop's files for reading, without
    /// waiting for a writer, so a supervisor blocked on writing its status
    /// there (see the fake sudo's "status-delayed") can go on. Returns what
    /// was written to each, by file name, once its writer has closed it or
    /// after `seconds`.
    @discardableResult
    func drainStatusFIFOs(within seconds: Double) -> [String: String] {
        var written: [String: String] = [:]
        for name in (try? backstopFiles()) ?? [] {
            let path = home.appendingPathComponent(name).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { continue }
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64)
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    data.append(contentsOf: buffer[0..<n])
                } else if n == 0 && !data.isEmpty {
                    break   // the writer has closed it
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            written[name] = String(decoding: data, as: UTF8.self)
        }
        return written
    }

    /// Lets a fake command in mode "ignore-term" / "closes-fd9" finish.
    func releaseCommand() {
        fm.createFile(atPath: root.appendingPathComponent("release").path, contents: nil)
    }

    /// nil while a release-controlled fake command is still running;
    /// "released" or "watchdog" once it has ended, saying what ended it.
    func commandEnded() -> String? {
        (try? String(contentsOf: root.appendingPathComponent("command.ended"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polls until the recovery lock is free; false after `seconds`.
    func waitUntilLockIsFree(_ seconds: Double = 15) throws -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            if try lockIsFree() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return try lockIsFree()
    }

    /// What install.sh's build and bundle steps need from the "repo":
    /// Resources/Info.plist, Resources/AppIcon.icns and a binary at the fake
    /// swift's bin path.
    func prepareInstall() throws {
        // An install test starts with nothing at $APP unless it writes a
        // bundle there: the Info.plist written for the backstop's binary
        // check would otherwise leave a bundle with no binary at $APP.
        try fm.removeItem(at: app)
        let resources = repoScripts.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.kgarg.insomnia</string></dict></plist>
        """.write(to: resources.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try "icns".write(to: resources.appendingPathComponent("AppIcon.icns"), atomically: true, encoding: .utf8)
        let binroot = root.appendingPathComponent("binroot", isDirectory: true)
        try fm.createDirectory(at: binroot, withIntermediateDirectories: true)
        let binary = binroot.appendingPathComponent("Insomnia")
        try "#!/bin/bash\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// A bundle from an earlier install at $APP, with a binary whose first
    /// line ("previous") tells it apart from the fake build's ("#!/bin/bash").
    func writePreviousApp(at url: URL? = nil) throws {
        let bundle = url ?? app
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "previous\n".write(to: bundle.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
    }

    /// First line of the binary installed at $APP.
    func installedBinaryFirstLine() throws -> String {
        let text = try String(contentsOf: app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8)
        return String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// A stand-in backstop that records which copy ran and claims success.
    func writeMarkerBackstop(at url: URL, name: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\nprintf 'backstop \(name) %s\\n' \"$*\" >> \"\(callsLog.path)\"\nexit 0\n"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func plistOnDisk() throws -> [String: Any] {
        let data = try Data(contentsOf: plist)
        guard let obj = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw FixtureError("the LaunchAgent plist is not a dictionary")
        }
        return obj
    }

    func contents(of dir: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: dir.path).sorted()
    }

    /// The receipt as install.sh leaves it, with `text` in place of its
    /// initial content: the folder 0755 and the file 0600. An existing
    /// receipt is written over in place, as the root command's perl does.
    /// A new receipt, or one with no receiptEntries file, gets the access
    /// control entry install.sh adds, as a stand-in in receiptEntries
    /// (see writeFakes' ls). A release file is made beside it, as
    /// install.sh makes it, unless there is one.
    func writeReceipt(_ text: String = SleepOffReceipts.initialContent) throws {
        if mkdir(receipts, 0o755) != 0 && errno != EEXIST { throw FixtureError("mkdir \(receipts): \(errno)") }
        let made = !fm.fileExists(atPath: receipt)
        try Self.writeInPlace(receipt, text)
        XCTAssertEqual(chmod(receipt, 0o600), 0)
        if made || !fm.fileExists(atPath: receiptEntries) { try writeReceiptEntries([.installed(for: getuid())]) }
        if !fm.fileExists(atPath: released) { try writeRelease(SleepOffReceipts.initialRelease) }
    }

    /// The stand-in access control entries of the receipt, which the
    /// scripts' LS shows in front of its real ones (writeFakes).
    var receiptEntries: String { root.path + "/receipt.acl" }

    /// Puts `list` in receiptEntries.
    func writeReceiptEntries(_ list: [AccessEntry]) throws {
        try TestReceipts.writeEntries(list, to: receiptEntries)
    }

    /// The stand-in entries the scripts' LS shows for folders, in front of
    /// their real ones, while this file exists (TestReceipts.writeFakeLs).
    var folderEntries: String { receiptEntries + ".folders" }

    /// Puts `lines` (by folder, each as ls prints it) in folderEntries.
    func writeFolderEntries(_ lines: [String: [String]]) throws {
        try TestReceipts.writeFolderEntries(lines, besides: receiptEntries)
    }

    /// The receipt's checks in Swift, with the entry install.sh adds as
    /// their stand-in, as writeReceipt puts it in receiptEntries.
    var swiftReceipts: SleepOffReceipts {
        SleepOffReceipts(folder: receipts, owners: [0, getuid()], user: getuid(), standIn: [.installed(for: getuid())])
    }

    /// The release file with `text`, the test user's, 0600: written over in
    /// place when it is there, as the app and the scripts write it.
    func writeRelease(_ text: String) throws {
        try Self.writeInPlace(released, text)
        XCTAssertEqual(chmod(released, 0o600), 0)
    }

    /// The release file's bytes; nil when it cannot be read.
    func release() -> String? {
        try? String(contentsOf: URL(fileURLWithPath: released), encoding: .utf8)
    }

    /// The receipt's bytes; nil when it cannot be read.
    func receiptText() -> String? {
        try? String(contentsOf: URL(fileURLWithPath: receipt), encoding: .utf8)
    }

    private static func writeInPlace(_ path: String, _ text: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    /// "device:inode" of the receipt, as the journal keeps it.
    func receiptIdentity() -> String? {
        FileIdentity(atPath: receipt)?.text
    }

    // MARK: Scripts

    static var productionScripts: URL {
        // .../Tests/InsomniaTests/RecoveryScriptTests.swift -> .../scripts
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts", isDirectory: true)
    }

    private func writeScriptCopies() throws {
        let src = Self.productionScripts
        let backstopText = try String(contentsOf: src.appendingPathComponent("backstop.sh"), encoding: .utf8)
        try Self.patch(backstopText, [
            "PMSET": fakePmset,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "PS": bin.appendingPathComponent("ps").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "SYSCTL": bin.appendingPathComponent("sysctl").path,
            "CHMOD": bin.appendingPathComponent("chmod").path,
            "INSOMNIA_BIN": fakeInsomnia.path,
            "INSOMNIA_INFO": appInfo.path,
            "DEFAULTS": bin.appendingPathComponent("defaults").path,
            "DATE": bin.appendingPathComponent("date").path,
            "CAT": bin.appendingPathComponent("cat").path,
            "HEAD": bin.appendingPathComponent("head").path,
            "TR": bin.appendingPathComponent("tr").path,
            "LS": bin.appendingPathComponent("ls").path,
            "RECEIPTS": receipts,
            "RECEIPT_OWNER": uid,
            "MV": bin.appendingPathComponent("mv").path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "PENDING_LOCK_TIMEOUT_SECONDS": "1",
            "RECEIPT_LOCK_TIMEOUT_SECONDS": "1",
            "COMMAND_TIMEOUT_SECONDS": "1",
            "KILL_GRACE_SECONDS": "1",
        ]).write(to: backstop, atomically: true, encoding: .utf8)

        let uninstallText = try String(contentsOf: src.appendingPathComponent("uninstall.sh"), encoding: .utf8)
        try Self.patch(uninstallText, [
            "PGREP": bin.appendingPathComponent("pgrep").path,
            "OSASCRIPT": bin.appendingPathComponent("osascript").path,
            "LAUNCHCTL": bin.appendingPathComponent("launchctl").path,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
            "DEFAULTS": bin.appendingPathComponent("defaults").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "APP": app.path,
            "SUDOERS": sudoers.path,
            "CAT": bin.appendingPathComponent("cat").path,
            "HEAD": bin.appendingPathComponent("head").path,
            "TR": bin.appendingPathComponent("tr").path,
            "LS": bin.appendingPathComponent("ls").path,
            "RECEIPTS": receipts,
            "RECEIPT_OWNER": uid,
            "LOCK_TIMEOUT_SECONDS": "1",
            "PENDING_LOCK_TIMEOUT_SECONDS": "1",
            "RECEIPT_LOCK_TIMEOUT_SECONDS": "1",
            "QUIT_WAIT_SECONDS": "1",
            "CALL_TIMEOUT_SECONDS": "5",
        ]).write(to: uninstall, atomically: true, encoding: .utf8)

        // build-app.sh (run by install.sh from $ROOT/scripts): build and
        // signing go to the fakes.
        let buildText = try String(contentsOf: src.appendingPathComponent("build-app.sh"), encoding: .utf8)
        let buildApp = repoScripts.appendingPathComponent("build-app.sh")
        try Self.patch(buildText, [
            "SWIFT": bin.appendingPathComponent("swift").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
        ]).write(to: buildApp, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: buildApp.path)

        try writeInstallCopies(extraConstants: [:])
    }

    /// install.sh: every $HOME-derived path and every tool is redirected
    /// into the fixture (signing, sudo, launchctl included; the build goes
    /// through the patched build-app.sh above). Tests that need another
    /// constant (the real CODESIGN) rewrite both copies with it.
    func writeInstallCopies(extraConstants: [String: String]) throws {
        let installText = try String(contentsOf: Self.productionScripts.appendingPathComponent("install.sh"), encoding: .utf8)
        let patchedInstall = try Self.patch(installText, [
            "QUIT_WAIT_SECONDS": "1",
            "APP_DIR": appsDir.path,
            "APP_SUPPORT": home.path,
            "LOG_DIR": home.appendingPathComponent("Logs").path,
            "LAUNCH_AGENTS": home.appendingPathComponent("LaunchAgents").path,
            "SUDOERS": sudoers.path,
            "PGREP": bin.appendingPathComponent("pgrep").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "OSASCRIPT": bin.appendingPathComponent("osascript").path,
            "LAUNCHCTL": bin.appendingPathComponent("launchctl").path,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
            "SYSCTL": bin.appendingPathComponent("sysctl").path,
            "MV": bin.appendingPathComponent("mv").path,
            "RM": bin.appendingPathComponent("rm").path,
            "RMDIR": bin.appendingPathComponent("rmdir").path,
            "MKTEMP": bin.appendingPathComponent("mktemp").path,
            "MKDIR": bin.appendingPathComponent("mkdir").path,
            "CHMOD": bin.appendingPathComponent("chmod").path,
            "CAT": bin.appendingPathComponent("cat").path,
            "HEAD": bin.appendingPathComponent("head").path,
            "LS": bin.appendingPathComponent("ls").path,
            "RECEIPTS": receipts,
            "RECEIPT_OWNER": uid,
            "LOCK_TIMEOUT_SECONDS": "1",
            "RECEIPT_LOCK_TIMEOUT_SECONDS": "1",
            "CALL_TIMEOUT_SECONDS": "5",
        ].merging(extraConstants) { $1 })
        try patchedInstall.write(to: install, atomically: true, encoding: .utf8)
        // The redirected copy runs past the INSOMNIA_HOME refusal: that
        // variable is what makes the backstop copy it installs act on the
        // fixture instead of ~/Library. The plain copy keeps the refusal.
        let redirected = try Self.replaceOnce(patchedInstall, #"if [[ -n "${INSOMNIA_HOME:-}" ]]; then"#, with: "if false; then")
        try redirected.write(to: installRedirected, atomically: true, encoding: .utf8)
    }

    /// A bundle the way a release zip carries it: Info.plist, a marker
    /// executable (or a real Mach-O, a copy of /usr/bin/true, when `machO`
    /// is set so the real codesign can sign the bundle) and the sealed
    /// backstop (the fixture's patched copy, so install.sh's recovery step
    /// acts on the fixture). What the fake codesign says about its signature
    /// is set with `setMode("codesign", ...)` and `setSigning(...)`.
    func writePrebuiltApp(bundleID: String = "com.kgarg.insomnia", version: String = "0.1.0", withBackstop: Bool = true, machO: Bool = false) throws -> URL {
        let app = root.appendingPathComponent("dist/Insomnia.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Insomnia</string>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        </dict></plist>
        """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        if machO {
            try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Insomnia").path)
        } else {
            try "prebuilt".write(to: app.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
        }
        if withBackstop {
            try fm.copyItem(at: backstop, to: app.appendingPathComponent("Contents/Resources/backstop.sh"))
        }
        return app
    }

    /// What the fake codesign reports for `-dvv`: "adhoc", or
    /// "developer-id:<team>" for a Developer ID Application signature.
    func setSigning(_ value: String) {
        try? value.write(to: root.appendingPathComponent("codesign.signing"), atomically: true, encoding: .utf8)
    }

    /// Rewrites `NAME=...` constant lines. Every name must match exactly one
    /// line, so a renamed constant in the script fails loudly here instead of
    /// letting a test run the real tool.
    static func patch(_ text: String, _ constants: [String: String]) throws -> String {
        var lines = text.components(separatedBy: "\n")
        for (name, value) in constants {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            guard hits.count == 1 else {
                throw FixtureError("expected exactly one '\(name)=' line, found \(hits.count)")
            }
            guard !value.contains("'") else { throw FixtureError("fixture path contains a quote: \(value)") }
            lines[hits[0]] = "\(name)='\(value)'"
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces one exact line; fails loudly if the script no longer has it.
    static func replaceOnce(_ text: String, _ exact: String, with replacement: String) throws -> String {
        guard text.components(separatedBy: exact).count == 2 else {
            throw FixtureError("expected exactly one occurrence of '\(exact)'")
        }
        return text.replacingOccurrences(of: exact, with: replacement)
    }

    // MARK: Fakes

    /// An app bundle's Info.plist, with InsomniaResumeFrozenVersion set to
    /// `resumeFrozenVersion` as an integer, or without the key when nil.
    static func infoPlist(resumeFrozenVersion: String?) -> String {
        let key = resumeFrozenVersion.map { "<key>InsomniaResumeFrozenVersion</key><integer>\($0)</integer>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleExecutable</key><string>Insomnia</string>\(key)</dict></plist>

        """
    }

    private func writeFake(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeFakes() throws {
        let calls = callsLog.path
        let r = root.path
        // cat, head and tr: the scripts' CAT, HEAD and TR. Each call goes
        // to tools.log, apart from calls.log, with the PATH it was given in
        // tools.path, and then to the real tool. tr's arguments hold a tab
        // and line breaks, so only its first goes to the log. The child's
        // PATH never holds this folder, so a bare `cat`, `head` or `tr` in
        // a script never reaches them. The fakes below call /bin/cat and
        // /usr/bin/head by full path, so a hostile folder put first in PATH
        // sees only the scripts' own calls.
        try writeFake("cat", """
        printf 'cat %s\\n' "$*" >> "\(toolsLog.path)"
        printf '%s\\n' "$PATH" >> "\(toolPathsLog.path)"
        exec /bin/cat "$@"
        """)
        try writeFake("head", """
        printf 'head %s\\n' "$*" >> "\(toolsLog.path)"
        printf '%s\\n' "$PATH" >> "\(toolPathsLog.path)"
        exec /usr/bin/head "$@"
        """)
        try writeFake("tr", """
        printf 'tr %s\\n' "$1" >> "\(toolsLog.path)"
        printf '%s\\n' "$PATH" >> "\(toolPathsLog.path)"
        exec /usr/bin/tr "$@"
        """)
        // sudo: `-n <cmd>` is the pmset path and succeeds or fails by mode
        // without running anything. /bin/rm and /bin/test run unprivileged,
        // and only on a path inside the fixture. With sudo-root.mode
        // "search", they can also see through a directory the user cannot
        // search, as root can.
        // Mode "hang" behaves like a pmset that never returns.
        // Mode "auth-fail": every form that would prompt (visudo, install)
        // fails like a wrong password, and `-n` forms fail as unpermitted.
        // Mode "rule-not-effective": authentication passes and the rule is
        // installed, but install.sh's check, `sudo -k -n -l <pmset ...>`,
        // still says no. Mode "no-rule-cached": the same, but the way an
        // administrator without the rule sees it: `sudo -n -l` and `sudo -n
        // <cmd>` pass on the credential `sudo -v` cached, and only `-k`,
        // which ignores that credential, fails. Mode "rule-gone-under-lock":
        // the listing says yes while nobody holds the recovery lock and no
        // while someone does. In mode "rule-check-hangs" the listing never
        // answers and ignores SIGTERM; in "rule-check-hangs-under-lock" it
        // never answers while the lock is held and stops on SIGTERM; in
        // "rule-check-ignores-term-under-lock" it never answers while the
        // lock is held and ignores SIGTERM (see sudoHangHere). Any other
        // mode passes the listing, "fail" included, which fails only the
        // backstop's undo. `sudo -v` authenticates and `sudo -n -v` checks
        // the cached credential. Mode "cache-expires": the credential has
        // expired by the time `-n -v` asks, and `-v` succeeds again. Mode
        // "reauth-fails": the same, but every `-v` after the first fails.
        // Mode "visudo-hangs-under-lock": `sudo -n visudo` never answers
        // while the lock is held and ignores SIGTERM.
        // visudo checks the candidate file exists, is non-empty and grants
        // pmset, so an installer that validated the wrong path or an empty
        // heredoc cannot pass here. visudo and install are only known by the
        // full paths install.sh passes; a bare name, which real sudo would
        // look up in PATH, fails like an unknown command. visudo also
        // records in at-visudo whether the recovery lock is held and whether
        // the binary at the installed app is already the new build.
        try writeFake("sudo", """
        printf 'sudo %s\\n' "$*" >> "\(calls)"
        if [[ -e "\(pendingStart.path)" ]]; then echo present; else echo absent; fi >> "\(r)/marker-at-sudo"
        # The shell's own read: an ordinary call, with no mode file, starts
        # no process for it.
        mode=ok; if [[ -e "\(r)/sudo.mode" ]]; then IFS= read -r mode < "\(r)/sudo.mode" || true; fi
        \(sudoHangHere())
        \(lockHeldHere())
        \(receiptLockHere())
        # "ignore-term" and "closes-fd9" behave like a pmset that ignores
        # SIGTERM: they live until the test creates the release file (or the
        # fixture is destroyed, or a 60 s wall-clock watchdog), so a test decides when
        # the command ends instead of racing a wall-clock sleep. On exit they
        # write command.ended = released | watchdog, so a test can tell a
        # command that is still alive (no file) from one that ended, and why.
        # list_check answers `sudo [-k] -n -l <pmset ...>`; "k" is passed
        # when -k makes sudo ignore the cached credential.
        list_check() {
          case "$mode" in
            auth-fail|rule-not-effective) exit 1 ;;
            no-rule-cached) if [[ "${1:-}" == k ]]; then echo "sudo: a password is required" >&2; exit 1; fi; exit 0 ;;
            rule-gone-under-lock) if lock_held; then exit 1; fi; exit 0 ;;
            rule-check-hangs) hang_on_term ignore ;;
            rule-check-hangs-under-lock) if lock_held; then hang_on_term stop; fi; exit 0 ;;
            rule-check-ignores-term-under-lock) if lock_held; then hang_on_term ignore; fi; exit 0 ;;
            *) exit 0 ;;
          esac
        }
        # `-n visudo` and `-n install` (install.sh under the lock) are
        # handled below like the forms without -n.
        if [[ "${1:-}" == -n && ( "${2:-}" == /usr/sbin/visudo || "${2:-}" == /usr/bin/install || "${2:-}" == "\(bin.path)/mkdir" || "${2:-}" == "\(bin.path)/chmod" ) ]]; then shift; fi
        # `-n /bin/rm` and `-n /bin/rmdir` (uninstall.sh's as_root, after
        # its `sudo -v`): with no cached credential (modes
        # auth-fail, cache-expires and reauth-fails) they fail the way sudo
        # -n does. Otherwise they run as the forms without -n below, unless
        # sudo-rm.hangs, sudo-rm.stops, sudo-rm.fails or
        # sudo-rm.no-credential holds the path the command is given last:
        # then it never answers and ignores SIGTERM (hang_on_term ignore),
        # never answers and stops on SIGTERM (hang_on_term stop), fails like
        # a refused removal, or fails as sudo -n does once the credential
        # is gone.
        if [[ "${1:-}" == -n && ( "${2:-}" == /bin/rm || "${2:-}" == /bin/rmdir ) ]]; then
          case "$mode" in auth-fail|cache-expires|reauth-fails) echo "sudo: a password is required" >&2; exit 1 ;; esac
          shift
          p=""; if [[ -f "\(r)/sudo-rm.hangs" ]]; then IFS= read -r p < "\(r)/sudo-rm.hangs" || true; fi
          if [[ -n "$p" && "$p" == "${!#}" ]]; then hang_on_term ignore; fi
          p=""; if [[ -f "\(r)/sudo-rm.stops" ]]; then IFS= read -r p < "\(r)/sudo-rm.stops" || true; fi
          if [[ -n "$p" && "$p" == "${!#}" ]]; then hang_on_term stop; fi
          p=""; if [[ -f "\(r)/sudo-rm.fails" ]]; then IFS= read -r p < "\(r)/sudo-rm.fails" || true; fi
          if [[ -n "$p" && "$p" == "${!#}" ]]; then echo "${1##*/}: ${!#}: Operation not permitted" >&2; exit 1; fi
          p=""; if [[ -f "\(r)/sudo-rm.no-credential" ]]; then IFS= read -r p < "\(r)/sudo-rm.no-credential" || true; fi
          if [[ -n "$p" && "$p" == "${!#}" ]]; then echo "sudo: a password is required" >&2; exit 1; fi
        fi
        case "${1:-}" in
          -v) case "$mode" in
                auth-fail) echo "sudo: 3 incorrect password attempts" >&2; exit 1 ;;
                # "swap-prebuilt": someone replaces the --app bundle at its path
                # (writePrebuiltApp's dist/Insomnia.app) while the password prompt waits.
                swap-prebuilt) printf 'swapped' > "\(r)/dist/Insomnia.app/Contents/MacOS/Insomnia"; exit 0 ;;
                reauth-fails)
                  n=$(( $(/bin/cat "\(r)/sudo.auths" 2>/dev/null || echo 0) + 1 )); echo "$n" > "\(r)/sudo.auths"
                  if (( n > 1 )); then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
                  exit 0 ;;
                *) exit 0 ;;
              esac ;;
          -k) if [[ "${2:-}" == -n && "${3:-}" == -l ]]; then list_check k; fi
              exit 1 ;;
          -n) if [[ "${2:-}" == -v ]]; then
                case "$mode" in auth-fail|cache-expires|reauth-fails) exit 1 ;; *) exit 0 ;; esac
              fi
              if [[ "${2:-}" == -l ]]; then list_check; fi
              # sudo.needs-rule: the restore runs only while the rule is
              # there, as real sudo runs it without a password only then.
              if [[ -e "\(r)/sudo.needs-rule" && ! -e "\(sudoers.path)" ]]; then
                printf 'sudo NO-RULE %s\\n' "$*" >> "\(calls)"; echo "sudo: a password is required" >&2; exit 1
              fi
              case "$mode" in
                ok|no-rule-cached) exit 0 ;;
                hang) exec /bin/sleep 60 ;;
                ignore-term) trap '' TERM; deadline=$(( $(date +%s) + 60 ))
                  while [[ ! -e "\(r)/release" && -d "\(r)" && $(date +%s) -lt $deadline ]]; do /bin/sleep 0.1; done
                  if [[ -e "\(r)/release" ]]; then echo released > "\(r)/command.ended"
                  elif [[ -d "\(r)" ]]; then echo watchdog > "\(r)/command.ended"; fi
                  exit 0 ;;
                closes-fd9) exec 9<&-; trap '' TERM; deadline=$(( $(date +%s) + 60 ))
                  while [[ ! -e "\(r)/release" && -d "\(r)" && $(date +%s) -lt $deadline ]]; do /bin/sleep 0.1; done
                  if [[ -e "\(r)/release" ]]; then echo released > "\(r)/command.ended"
                  elif [[ -d "\(r)" ]]; then echo watchdog > "\(r)/command.ended"; fi
                  exit 0 ;;
                # "logs-term": like "ignore-term", and every SIGTERM it gets
                # is logged as "sudo SIGTERM" (see sudoHangHere).
                logs-term) hang_on_term ignore ;;
                # "drops-fd9-logs-signals": like "logs-term", after closing
                # its fd 9 the way sudo does, and every SIGHUP it gets is
                # logged as "sudo SIGHUP".
                drops-fd9-logs-signals) exec 9<&-; trap 'echo "sudo SIGHUP" >> "\(calls)"; echo "HUP $SECONDS" >> "\(r)/sudo.events"' HUP; hang_on_term ignore ;;
                # "signals-self": for SIGTERM and then SIGHUP, a shell that
                # inherits this command's signal actions sends itself the
                # signal and, if it is still there afterwards, logs "sudo
                # SURVIVED <signal>". Then it exits 0.
                signals-self) for s in TERM HUP; do /bin/bash -c "kill -$s \\$\\$; echo 'sudo SURVIVED $s' >> '\(calls)'"; done
                  printf 'sudo SIGNALS-CHECKED\\n' >> "\(calls)"; exit 0 ;;
                # "status-delayed": finds the status files of the backstop
                # call that runs it (the .pid file holding its own pid),
                # changes two of them and exits 0. The .pid file then names
                # the process in sentinel.pid, the way a pid the kernel gave
                # to another process after this one was reaped would, and a
                # FIFO stands where the call's status goes, so the
                # supervisor's status write waits until the test opens the
                # FIFO to read it (see drainStatusFIFOs).
                status-delayed) base=""
                  for (( i = 0; i < 50; i++ )); do
                    for f in "\(home.path)"/.backstop.*.pid; do
                      if [[ "$(/bin/cat "$f" 2>/dev/null)" == "$$" ]]; then base="${f%.pid}"; break 2; fi
                    done
                    /bin/sleep 0.1
                  done
                  [[ -n "$base" ]] || exit 0
                  /bin/cat "\(r)/sentinel.pid" > "$base.pid"
                  /usr/bin/mkfifo "$base.rc"
                  printf 'sudo STATUS-DELAYED\\n' >> "\(calls)"
                  exit 0 ;;
                *) exit 1 ;;
              esac ;;
          /usr/sbin/visudo)
            if lock_held; then l=held; else l=free; fi
            if [[ -e "\(app.path)/Contents/MacOS/Insomnia" ]] && cmp -s "\(app.path)/Contents/MacOS/Insomnia" "\(r)/binroot/Insomnia"; then a=new; else a=old; fi
            echo "lock=$l app=$a" > "\(r)/at-visudo"
            if [[ "$mode" == visudo-hangs-under-lock && "$l" == held ]]; then hang_on_term ignore; fi
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            f=""; for a in "$@"; do f="$a"; done
            [[ -s "$f" ]] && grep -q 'NOPASSWD: /usr/bin/pmset' "$f" || { printf 'sudo VISUDO-REJECTED %s\\n' "$*" >> "\(calls)"; exit 1; }
            exit 0 ;;
          /usr/bin/install)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            src=""; dst=""; perm=""; prev=""
            for a in "$@"; do src="$dst"; dst="$a"; [[ "$prev" == -m ]] && perm="$a"; prev="$a"; done
            case "$dst" in "\(r)"/*|"\(receipts)"/*)
              /bin/mkdir -p "$(dirname "$dst")"; /bin/cp "$src" "$dst"
              if [[ -n "$perm" ]]; then /bin/chmod "$perm" "$dst"; fi
              # A file install(1) makes has no access control entry.
              if [[ "$dst" == "\(receipt)" ]]; then : > "\(receiptEntries)"; fi
              exit 0 ;;
            esac
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          # install.sh's two calls of its CHMOD as root, on the receipt:
          # `0600` sets the mode for real (the fixture's own file), and
          # `+a <entry>` on a receipt with no entry writes the entry to
          # receiptEntries, where the fixture's ls shows it, and changes no
          # real access control list. While sudo-chmod.fail exists both
          # fail. Anything else is refused. Each records in receipt-lock.log
          # whether the receipt's lock is held.
          "\(bin.path)/chmod")
            if [[ "$mode" == auth-fail ]]; then echo "sudo: a password is required" >&2; exit 1; fi
            receipt_lock_state "sudo chmod $2"
            if [[ -e "\(r)/sudo-chmod.fail" ]]; then echo "chmod: \(receipt): Operation not permitted" >&2; exit 1; fi
            if [[ $# == 3 && "$2" == 0600 && "$3" == "\(receipt)" ]]; then exec /bin/chmod 0600 "$3"; fi
            if [[ $# == 4 && "$2" == +a && "$4" == "\(receipt)" && ! -s "\(receiptEntries)" ]]; then printf '%s\\n' "$3" > "\(receiptEntries)"; exit 0; fi
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          "\(bin.path)/mkdir")
            if [[ "$mode" == auth-fail ]]; then echo "sudo: a password is required" >&2; exit 1; fi
            case "${!#}" in "\(r)"/*|"\(receipts)"|"\(receipts)"/*) exec "$@" ;; esac
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          /bin/rmdir)
            case "${!#}" in "\(r)"/*|"\(receipts)") exec "$@" ;; esac
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          /bin/rm|/bin/test)
            if [[ "${1:-}" == /bin/rm ]]; then receipt_lock_state "sudo rm ${!#}"; fi
            for a in "$@"; do
              case "$a" in "\(r)"/*|"\(receipts)"/*)
                if [[ "$(/bin/cat "\(r)/sudo-root.mode" 2>/dev/null)" == search ]]; then
                  d="$(dirname "$a")"; /bin/chmod u+x "$d"; "$@"; rc=$?; /bin/chmod u-x "$d"; exit $rc
                fi
                exec "$@" ;;
              esac
            done
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          *) exit 1 ;;
        esac
        """)
        // pmset: only `pmset -g` may run without sudo. It reports
        // SleepDisabled as pmset.mode says: 0 (the default), 1, "none" (no
        // such line) or "fail" (exit 1). Anything else is recorded as a
        // DIRECT call and fails.
        try writeFake("pmset", """
        if [[ "$*" == -g ]]; then
          printf 'pmset -g\\n' >> "\(calls)"
          case "$(/bin/cat "\(r)/pmset.mode" 2>/dev/null || echo 0)" in
            fail) echo "pmset: could not read the settings" >&2; exit 1 ;;
            none) printf 'System-wide power settings:\\n' ;;
            1) printf 'System-wide power settings:\\n SleepDisabled\\t\\t1\\n' ;;
            *) printf 'System-wide power settings:\\n SleepDisabled\\t\\t0\\n' ;;
          esac
          exit 0
        fi
        printf 'pmset DIRECT %s\\n' "$*" >> "\(calls)"
        exit 99
        """)
        // swift / codesign: install.sh's build and signing steps, redirected
        // to a fake binary inside the fixture.
        try writeFake("swift", """
        printf 'swift %s\\n' "$*" >> "\(calls)"
        for a in "$@"; do [[ "$a" == --show-bin-path ]] && { echo "\(r)/binroot"; exit 0; }; done
        exit 0
        """)
        // mv: install.sh's and backstop.sh's MV. Runs /bin/mv unless a line
        // of mv.fail, "<from pattern>|<to pattern>" (bash globs), matches the
        // move; then it logs "mv FAILED <from> <to>" and exits 1 like a
        // refused rename, and both paths stay as they were.
        try writeFake("mv", """
        args=(); for a in "$@"; do [[ "$a" == -* ]] || args+=("$a"); done
        from="${args[0]:-}"; to="${args[1]:-}"
        if [[ -f "\(r)/mv.fail" ]]; then
          while IFS='|' read -r f t; do
            if [[ -n "$f" && "$from" == $f && "$to" == $t ]]; then
              printf 'mv FAILED %s %s\\n' "$from" "$to" >> "\(calls)"
              echo "mv: rename $from to $to: Permission denied" >&2
              exit 1
            fi
          done < "\(r)/mv.fail"
        fi
        exec /bin/mv "$@"
        """)
        // rm, rmdir, mktemp, mkdir: install.sh's RM, RMDIR, MKTEMP and MKDIR.
        // Each call is logged and then made by the real tool, so a test can
        // tell a file removed or created through the fixed-path variable from
        // one handled by a bare name. (Its CHMOD is the chmod fake below.)
        for (tool, real) in [("rm", "/bin/rm"), ("rmdir", "/bin/rmdir"), ("mktemp", "/usr/bin/mktemp"), ("mkdir", "/bin/mkdir")] {
            try writeFake(tool, """
            printf '\(tool)%s\\n' "${*:+ $*}" >> "\(calls)"
            exec \(real) "$@"
            """)
        }
        // codesign: signing is recorded and succeeds. `-d -r-` prints a
        // fixed designated requirement the way codesign does (on stderr,
        // with the "# " an implicit requirement carries). `-dvv` describes
        // the signature per codesign.signing (adhoc | developer-id:<team>).
        // `--verify` passes unless mode "verify-fails"; mode
        // "deep-verify-fails" fails only the `--deep` form install.sh runs
        // on a prebuilt bundle, and "requirement-verify-fails" only the
        // `-R=` form (the agent's pinned check). A path listed in
        // codesign.rejects (see `rejectSignature(of:)`) fails every form.
        // Mode "verify-hangs": `--verify` never answers (see hangHere);
        // "verify-hangs-under-lock": only while someone holds the recovery
        // lock.
        try writeFake("codesign", """
        printf 'codesign %s\\n' "$*" >> "\(calls)"
        mode="$(/bin/cat "\(r)/codesign.mode" 2>/dev/null || echo ok)"
        \(hangHere("codesign"))
        \(lockHeldHere())
        signing="$(/bin/cat "\(r)/codesign.signing" 2>/dev/null || echo adhoc)"
        last=""; deep=0; pinned=0; for a in "$@"; do last="$a"; [[ "$a" == --deep ]] && deep=1; [[ "$a" == -R=* ]] && pinned=1; done
        for a in "$@"; do
          case "$a" in
            -r-) echo "Executable=$last/Contents/MacOS/Insomnia" >&2; echo '# designated => \(requirement)' >&2; exit 0 ;;
            -dvv) echo "Executable=$last/Contents/MacOS/Insomnia" >&2; echo "Identifier=com.kgarg.insomnia" >&2
                  case "$signing" in
                    developer-id:*) echo "Authority=Developer ID Application: Tester (${signing#developer-id:})" >&2
                                    echo "Authority=Developer ID Certification Authority" >&2
                                    echo "Authority=Apple Root CA" >&2
                                    echo "TeamIdentifier=${signing#developer-id:}" >&2 ;;
                    *) echo "Signature=adhoc" >&2; echo "TeamIdentifier=not set" >&2 ;;
                  esac
                  exit 0 ;;
            --verify)
              if [[ "$mode" == verify-hangs ]]; then hang_here; fi
              if [[ "$mode" == verify-hangs-under-lock ]] && lock_held; then hang_here; fi
              if [[ -f "\(r)/codesign.rejects" ]] && grep -qxF -- "$last" "\(r)/codesign.rejects"; then echo "$last: does not satisfy its designated Requirement" >&2; exit 3; fi
              if [[ "$mode" == verify-fails || ( "$mode" == deep-verify-fails && $deep == 1 ) || ( "$mode" == requirement-verify-fails && $pinned == 1 ) ]]; then echo "$last: a sealed resource is missing or invalid" >&2; exit 1; fi
              exit 0 ;;
          esac
        done
        exit 0
        """)
        // ps: answers from ps.table. Modes: "fail" (exit 2 with an error
        // line, like a broken ps) and "garbage" (exit 0 with nonsense).
        try writeFake("ps", """
        printf 'ps %s\\n' "$*" >> "\(calls)"
        mode="$(/bin/cat "\(r)/ps.mode" 2>/dev/null || echo ok)"
        if [[ "$mode" == fail ]]; then echo "ps: cannot read process table" >&2; exit 2; fi
        if [[ "$mode" == garbage ]]; then echo "not a process line"; exit 0; fi
        pid=""; for a in "$@"; do pid="$a"; done
        [[ -f "\(r)/ps.table" ]] || exit 1
        while IFS='|' read -r p lstart stat uid; do
          if [[ "$p" == "$pid" ]]; then printf '%s %s %s\\n' "$lstart" "$stat" "$uid"; exit 0; fi
        done < "\(r)/ps.table"
        exit 1
        """)
        try writeFake("kill", """
        printf 'kill %s\\n' "$*" >> "\(calls)"
        fail="$(/bin/cat "\(r)/kill.fail.mode" 2>/dev/null || true)"
        for f in $fail; do [[ "$f" == "${2:-}" ]] && exit 1; done
        exit 0
        """)
        // sysctl: `-n kern.bootsessionuuid` reads boot.uuid and is not
        // logged (backstop.sh asks on every run; it changes nothing).
        // `-n hw.optional.arm64` is logged and reads 1, an Apple Silicon Mac
        // (also what a shell under Rosetta reads there). Mode "intel-0"
        // reads 0; "intel-missing" fails the way sysctl does for a key the
        // Mac lacks.
        try writeFake("sysctl", """
        if [[ "$*" == "-n hw.optional.arm64" ]]; then
          printf 'sysctl %s\\n' "$*" >> "\(calls)"
          case "$(/bin/cat "\(r)/sysctl.mode" 2>/dev/null || echo ok)" in
            intel-0) echo 0 ;;
            intel-missing) echo "sysctl: unknown oid 'hw.optional.arm64'" >&2; exit 1 ;;
            *) echo 1 ;;
          esac
          exit 0
        fi
        /bin/cat "\(r)/boot.uuid"
        """)
        // chmod: recorded in chmod.calls, apart from calls.log, then run for
        // real so the modes still change. A path listed in chmod.fail fails
        // the way an immutable file does. It changes no access control list
        // (round 30 F6): a call that would (install.sh's `chmod -R -N
        // <bundle>`) is only recorded, unless chmod.real-acl exists. Only
        // testInstallFromAPrebuiltAppDropsOtherAccountsWriteAccessButKeepsTheSignatureAndQuarantine
        // creates it, since it checks that real entries go; it is not run
        // where no real list may change.
        try writeFake("chmod", """
        printf 'chmod %s\\n' "$*" >> "\(r)/chmod.calls"
        if [[ -f "\(r)/chmod.fail" ]] && grep -qxF -- "${2:-}" "\(r)/chmod.fail"; then
          echo "chmod: ${2:-}: Operation not permitted" >&2
          exit 1
        fi
        for a in "$@"; do
          case "$a" in -N|[+=-]a|[+=-]a\\#) [[ -e "\(r)/chmod.real-acl" ]] || exit 0 ;; esac
        done
        exec /bin/chmod "$@"
        """)
        // ls: the scripts' LS. `ls -le <receipt>` shows receiptEntries'
        // lines as the receipt's first entries (TestReceipts.writeFakeLs),
        // since a test cannot give its receipt the entry install.sh adds
        // without changing a real access control list. Any other call is
        // /bin/ls.
        try TestReceipts.writeFakeLs(at: bin.appendingPathComponent("ls").path, receipt: receipt, entries: receiptEntries)
        // Insomnia --resume-frozen: reads its entries from standard input,
        // one "<pid> <startedAt> <micros> <boot>" line each, and records the
        // call as "Insomnia <arguments> < <line>; <line>; ...". Answers one
        // "<pid> <word>" line per entry, the word from insomnia.table
        // (pid|word) or "resumed" for a pid without a row; exit 0 when every
        // word is resumed or gone, 1 otherwise. Writes its parent's pid to
        // insomnia.ppid, and the inode of the file open on its fd 9 to
        // insomnia.fd9 (empty without an fd 9). Modes: "raw" prints insomnia.output verbatim and
        // exits with insomnia.status. "hang" prints its answer and then
        // sleeps for 300 s, so only a signal ends it in time. "hold" waits
        // until insomnia.release exists (30 s at most), records "Insomnia
        // released", and then answers as usual. A test that
        // needs SIGTERM ignored runs the backstop with it ignored (see
        // ScriptFixture.run): the fake inherits that from its first
        // instruction, so no trap has to be in place before the signal.
        try fm.createDirectory(at: appInfo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.infoPlist(resumeFrozenVersion: "1").write(to: appInfo, atomically: true, encoding: .utf8)
        try writeFake("Insomnia", """
        input=()
        while IFS= read -r line || [[ -n "$line" ]]; do input+=("$line"); done
        joined=""
        for line in "${input[@]}"; do joined="${joined:+$joined; }$line"; done
        printf 'Insomnia %s < %s\\n' "$*" "$joined" >> "\(calls)"
        echo "$PPID" > "\(r)/insomnia.ppid"
        if [[ -e /dev/fd/9 ]]; then stat -f %i /dev/fd/9 > "\(r)/insomnia.fd9"; else : > "\(r)/insomnia.fd9"; fi
        mode="$(/bin/cat "\(r)/insomnia.mode" 2>/dev/null || echo ok)"
        if [[ "$mode" == hold ]]; then
          for (( i = 0; i < 300; i++ )); do
            [[ -f "\(r)/insomnia.release" ]] && break
            /bin/sleep 0.1
          done
          printf 'Insomnia released\\n' >> "\(calls)"
        fi
        if [[ "$mode" == raw ]]; then
          /bin/cat "\(r)/insomnia.output"
          exit "$(/bin/cat "\(r)/insomnia.status")"
        fi
        status=0
        for line in "${input[@]}"; do
          pid="${line%% *}"
          word=resumed
          if [[ -f "\(r)/insomnia.table" ]]; then
            while IFS='|' read -r p w; do [[ "$p" == "$pid" ]] && word="$w"; done < "\(r)/insomnia.table"
          fi
          printf '%s %s\\n' "$pid" "$word"
          case "$word" in resumed|gone) ;; *) status=1 ;; esac
        done
        [[ "$mode" == hang ]] && exec /bin/sleep 300
        exit "$status"
        """)
        // date: the real tool, except that with date.mode present the stamp
        // a moved-aside session.json is named after (`-u +%Y%m%dT%H%M%SZ`)
        // is the mode's text, so a test can take that exact name first.
        // Not logged: it changes nothing.
        try writeFake("date", """
        if [[ "$*" == "-u +%Y%m%dT%H%M%SZ" && -f "\(r)/date.mode" ]]; then
          /bin/cat "\(r)/date.mode"; echo; exit 0
        fi
        exec /bin/date "$@"
        """)
        // defaults: an NSAppSleepDisabled table per domain (defaults.table,
        // `domain|value` with the value as `defaults read` prints a bool: 1
        // or 0). `read` prints it or fails like the real tool when absent;
        // `write -bool` and `delete` edit the table, and `delete` of an
        // absent key fails like the real tool. Mode "fail" makes every
        // write and delete fail; "fail:<domain>" only that domain's. Mode
        // "unreachable" (or "unreachable:<domain>") fails every command,
        // read included, the way a cfprefsd that does not answer would:
        // non-zero without the "does not exist" message. Mode "hang" (or
        // "hang:<domain>") never answers; see hangHere.
        try writeFake("defaults", """
        printf 'defaults %s\\n' "$*" >> "\(calls)"
        mode="$(/bin/cat "\(r)/defaults.mode" 2>/dev/null || echo ok)"
        table="\(r)/defaults.table"
        cmd="${1:-}"; domain="${2:-}"; key="${3:-}"
        [[ "$key" == NSAppSleepDisabled ]] || { echo "fake defaults: unexpected key '$key'" >&2; exit 2; }
        lookup() {
          [[ -f "$table" ]] || return 1
          local d v
          while IFS='|' read -r d v; do
            if [[ "$d" == "$domain" ]]; then echo "$v"; return 0; fi
          done < "$table"
          return 1
        }
        drop() {
          [[ -f "$table" ]] || return 0
          awk -F'|' -v d="$domain" '$1 != d' "$table" > "$table.next" && mv "$table.next" "$table"
        }
        failing() { [[ "$mode" == fail || "$mode" == "fail:$domain" ]]; }
        \(hangHere("defaults"))
        if [[ "$mode" == hang || "$mode" == "hang:$domain" ]]; then hang_here; fi
        if [[ "$mode" == unreachable || "$mode" == "unreachable:$domain" ]]; then
          echo "fake defaults: cfprefsd did not answer for $domain" >&2; exit 1
        fi
        case "$cmd" in
          read)
            v="$(lookup)" || { echo "The domain/default pair of ($domain, $key) does not exist" >&2; exit 1; }
            echo "$v"; exit 0 ;;
          write)
            failing && exit 1
            [[ "${4:-}" == -bool ]] || { echo "fake defaults: expected -bool" >&2; exit 2; }
            case "${5:-}" in true|TRUE|yes|YES|1) v=1 ;; false|FALSE|no|NO|0) v=0 ;; *) echo "fake defaults: bad bool" >&2; exit 2 ;; esac
            drop; echo "$domain|$v" >> "$table"; exit 0 ;;
          delete)
            failing && exit 1
            lookup >/dev/null || { echo "Domain ($domain) not found." >&2; exit 1; }
            drop; exit 0 ;;
          *) echo "fake defaults: unexpected command '$cmd'" >&2; exit 2 ;;
        esac
        """)
        // pgrep: pgrep.mode holds one exit status per line, consumed in
        // order; the last line repeats. Default 1 (not running).
        try writeFake("pgrep", """
        printf 'pgrep %s\\n' "$*" >> "\(calls)"
        f="\(r)/pgrep.mode"
        [[ -f "$f" ]] || exit 1
        first="$(/usr/bin/head -n 1 "$f")"
        if (( $(wc -l < "$f") > 1 )); then tail -n +2 "$f" > "$f.next" && mv "$f.next" "$f"; fi
        \(hangHere("pgrep"))
        if [[ "$first" == hang ]]; then hang_here; fi
        exit "${first:-1}"
        """)
        for tool in ["pkill", "osascript"] {
            try writeFake(tool, """
            printf '\(tool) %s\\n' "$*" >> "\(calls)"
            exit 0
            """)
        }
        // launchctl: bootout/bootstrap succeed and `print` reports "not
        // loaded" (113) by default. Whatever the mode, a path argument is
        // only accepted when it ends in `.plist` and exists (real launchctl
        // fails with EIO otherwise, for bootstrap and bootout alike); bootout
        // also takes a service target `gui/<uid>/<label>` with no path.
        // Every bootstrap also records whether the recovery lock was held at
        // that moment (LOCK-HELD / LOCK-FREE), to prove the installer keeps
        // its transaction open across the agent replacement.
        // Modes that keep state like launchd: the job starts loaded, bootout
        // unloads it, bootstrap loads it (and fails with 37 while it is
        // loaded), and print reports which.
        //   "loaded": just that.
        //   "loaded-bootstrap-fails-once": the first bootstrap fails (5).
        //   "loaded-unload-fails-after-bootstrap": a bootout after a
        //     bootstrap fails (5) and the job stays loaded.
        //   "loaded-print-fails-once-after-bootstrap": the first print after
        //     a bootstrap fails with an error (1), later ones report state.
        //   "loaded-print-fails-after-bootstrap": every print after a
        //     bootstrap fails with an error.
        //   "loaded-reload-fails-yet-listed": the first bootstrap fails (5);
        //     the second fails (5) too, but leaves a job listed.
        // Fixed answers:
        //   "bootout-fails-still-loaded": bootout exits 5 and print always
        //     lists the job. "ambiguous": bootout and print fail with errors.
        //   "loaded-then-lost": print says loaded once, then not loaded;
        //     bootstrap always fails. "no-then-error": print says not loaded
        //     once, then fails with an error; bootstrap fails.
        //   "bootstrap-fails": nothing is loaded and every bootstrap fails.
        //   "print-hangs": print never answers (see hangHere); bootout succeeds.
        //   "bootout-hangs": bootout never answers (see hangHere); print
        //     lists the job.
        //   "bootout-claims-receipt": bootout succeeds and, without the
        //     receipt's lock, writes "<claim.nonce> held" over the release
        //     file, as a writer that ignores the lock could; print says not
        //     loaded.
        // Every bootout also records in receipt-lock.log whether the
        // receipt's lock is held (see receiptLockHere).
        try writeFake("launchctl", """
        printf 'launchctl %s\\n' "$*" >> "\(calls)"
        mode="$(/bin/cat "\(r)/launchctl.mode" 2>/dev/null || echo ok)"
        \(receiptLockHere())
        if [[ "${1:-}" == bootout ]]; then
          receipt_lock_state "launchctl bootout"
          if [[ "$mode" == bootout-claims-receipt ]]; then
            printf '%s held\\n' "$(/bin/cat "\(r)/claim.nonce")" 1<> "\(released)"
          fi
        fi
        if [[ "${1:-}" == bootstrap ]]; then
          [[ "${3:-}" == *.plist && -f "${3:-}" ]] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
        elif [[ "${1:-}" == bootout && $# -ge 3 ]]; then
          [[ "${3:-}" == *.plist && -f "${3:-}" ]] || { echo "Boot-out failed: 5: Input/output error" >&2; exit 5; }
        elif [[ "${1:-}" == bootout ]]; then
          [[ "${2:-}" == gui/\(uid)/com.insomnia.backstop ]] || { echo "Boot-out failed: 5: Input/output error" >&2; exit 5; }
        fi
        if [[ "${1:-}" == bootstrap ]]; then
          if /usr/bin/lockf -k -s -t 0 "\(r)/home/.recovery.lock" /usr/bin/true 2>/dev/null; then
            echo 'launchctl LOCK-FREE during bootstrap' >> "\(calls)"
          else
            echo 'launchctl LOCK-HELD during bootstrap' >> "\(calls)"
          fi
          if [[ -f "\(app.path)/Contents/MacOS/Insomnia" ]]; then
            echo "launchctl APP-BINARY=$(/usr/bin/head -n 1 "\(app.path)/Contents/MacOS/Insomnia") during bootstrap" >> "\(calls)"
          else
            echo 'launchctl APP-ABSENT during bootstrap' >> "\(calls)"
          fi
        fi
        \(hangHere("launchctl"))
        if [[ "${1:-}:$mode" == print:print-hangs ]]; then hang_here; fi
        if [[ "${1:-}:$mode" == bootout:bootout-hangs ]]; then hang_here; fi
        prints=0
        if [[ "${1:-}" == print ]]; then
          prints=$(( $(/bin/cat "\(r)/print.count" 2>/dev/null || echo 0) + 1 )); echo "$prints" > "\(r)/print.count"
        fi
        case "$mode" in
          loaded|loaded-bootstrap-fails-once|loaded-unload-fails-after-bootstrap|loaded-print-fails-once-after-bootstrap|loaded-print-fails-after-bootstrap|loaded-reload-fails-yet-listed)
            unloaded="\(r)/launchctl.unloaded"; bootstrapped="\(r)/launchctl.bootstrapped"
            case "${1:-}" in
              bootout)
                if [[ "$mode" == loaded-unload-fails-after-bootstrap && -e "$bootstrapped" ]]; then
                  echo "Boot-out failed: 5: Input/output error" >&2; exit 5
                fi
                : > "$unloaded"; exit 0 ;;
              bootstrap)
                [[ -e "$unloaded" ]] || { echo "Bootstrap failed: 37: Operation already in progress" >&2; exit 37; }
                if [[ "$mode" == loaded-bootstrap-fails-once || "$mode" == loaded-reload-fails-yet-listed ]] && [[ ! -e "\(r)/bootstrap.failed" ]]; then
                  : > "\(r)/bootstrap.failed"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
                fi
                if [[ "$mode" == loaded-reload-fails-yet-listed ]]; then
                  rm -f "$unloaded"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5
                fi
                rm -f "$unloaded"; : > "$bootstrapped"; exit 0 ;;
              print)
                if [[ -e "$bootstrapped" ]] && { [[ "$mode" == loaded-print-fails-after-bootstrap ]] \
                    || { [[ "$mode" == loaded-print-fails-once-after-bootstrap ]] && [[ ! -e "\(r)/print.failed" ]]; }; }; then
                  : > "\(r)/print.failed"; echo "Could not print domain: 1: Operation not permitted" >&2; exit 1
                fi
                if [[ -e "$unloaded" ]]; then exit 113; fi; exit 0 ;;
            esac ;;
        esac
        case "${1:-}:$mode" in
          bootout:print-hangs|bootout:bootout-claims-receipt) exit 0 ;;
          print:bootout-claims-receipt) exit 113 ;;
          bootout:ok|bootout:loaded-then-lost|bootout:no-then-error|bootout:bootstrap-fails) exit 0 ;;
          bootstrap:ok) exit 0 ;;
          bootstrap:loaded-then-lost|bootstrap:no-then-error|bootstrap:bootstrap-fails) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;;
          print:loaded-then-lost) if (( prints == 1 )); then exit 0; fi; exit 113 ;;
          print:no-then-error) if (( prints == 1 )); then exit 113; fi; echo "Could not print domain: 1: Operation not permitted" >&2; exit 1 ;;
          print:ok|print:bootstrap-fails) exit 113 ;;
          bootout:ambiguous) echo "Boot-out failed: 1: Operation not permitted" >&2; exit 1 ;;
          print:ambiguous) echo "Could not print domain: 1: Operation not permitted" >&2; exit 1 ;;
          bootout:*) exit 5 ;;
          print:*) exit 0 ;;
          *) exit 1 ;;
        esac
        """)
    }

    /// True when nobody holds the recovery lock right now.
    func lockIsFree() throws -> Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        probe.arguments = ["-k", "-s", "-t", "0", lock.path, "/usr/bin/true"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        let probeExit = ProcessExit(probe)
        try probe.run()
        probeExit.wait()
        return probe.terminationStatus == 0
    }

    /// Makes the fake codesign's `--verify` fail for the bundle at `url`
    /// only, the way a bundle that is not the build a requirement pins does.
    func rejectSignature(of url: URL) throws {
        let list = root.appendingPathComponent("codesign.rejects")
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        try (existing + url.path + "\n").write(to: list, atomically: true, encoding: .utf8)
    }

    /// A bundle at `url` whose binary's first line is `marker`.
    func writeBundle(at url: URL, marker: String) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "\(marker)\n".write(to: url.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
    }

    /// The agent plist an install writes for the bundle at $APP, pinning
    /// the fake codesign's requirement.
    func writeAgentPlist() throws {
        let dict = LaunchdBackstop.plistDictionary(label: "com.insomnia.backstop", target: BackstopTarget(bundle: app, requirement: requirement))
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plist)
    }

    /// Makes the fake mv refuse every move whose source and destination
    /// match one of these bash glob patterns.
    func failMoves(_ rules: [(from: String, to: String)]) throws {
        try rules.map { "\($0.from)|\($0.to)\n" }.joined()
            .write(to: root.appendingPathComponent("mv.fail"), atomically: true, encoding: .utf8)
    }

    func setMode(_ name: String, _ value: String) {
        try? value.write(to: root.appendingPathComponent("\(name).mode"), atomically: true, encoding: .utf8)
    }

    /// The word the fake app binary answers per pid; the exit status follows
    /// from the words.
    func insomniaTable(_ rows: [(pid: Int, word: String)]) throws {
        let text = rows.map { "\($0.pid)|\($0.word)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("insomnia.table"), atomically: true, encoding: .utf8)
    }

    /// Makes the fake app binary print exactly `output` and exit `status`,
    /// whatever it is asked.
    func insomniaRaw(_ output: String, status: Int) throws {
        setMode("insomnia", "raw")
        try output.write(to: root.appendingPathComponent("insomnia.output"), atomically: true, encoding: .utf8)
        try String(status).write(to: root.appendingPathComponent("insomnia.status"), atomically: true, encoding: .utf8)
    }

    func psTable(_ rows: [(pid: Int, lstart: String, stat: String, uid: String)]) throws {
        let text = rows.map { "\($0.pid)|\($0.lstart)|\($0.stat)|\($0.uid)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("ps.table"), atomically: true, encoding: .utf8)
    }

    /// What `TZ=UTC LC_ALL=C ps -o lstart=` prints for a start second.
    func lstart(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// Shell function for a fake: a call that never answers. It notes in
    /// the call log if it inherited fd 9 (the recovery lock), records its
    /// pid in `<tool>.hung.pid`, ignores SIGTERM and sleeps 60 s, so only a
    /// SIGKILL ends it before then.
    func hangHere(_ tool: String) -> String {
        """
        hang_here() {
          if { : >&9; } 2>/dev/null; then echo '\(tool) FD9-OPEN' >> "\(callsLog.path)"; fi
          echo $$ > "\(root.path)/\(tool).hung.pid"
          trap '' TERM
          exec /bin/sleep 60
        }
        """
    }

    /// Shell function for the fake sudo: a `sudo -n -l` that never answers.
    /// sudo is never sent SIGKILL, so unlike hangHere this one does not
    /// wait for it. `hang_on_term stop` logs "sudo SIGTERM" and exits on
    /// SIGTERM, the way sudo ends a policy check. `hang_on_term ignore` logs
    /// it and keeps running until the test calls releaseCommand (or the
    /// fixture goes, or a 60 s watchdog), then writes command.ended. Both
    /// note an inherited fd 9. The watchdog's deadline is set first and the
    /// SIGTERM trap next; only then does it write "ready" to sudo.events
    /// and its pid to `sudo.hung.pid`, so a test that waits for the pid
    /// signals a command that is ready. Each SIGTERM also goes to
    /// sudo.events with the fake's SECONDS (sudoEvents).
    /// Nothing after the trap runs a command substitution. Under Bash 3.2,
    /// a signal sent to the process group while `$(...)` runs reaches the
    /// substitution's child too: it can kill that child, so the
    /// substitution comes back empty (a watchdog deadline of 60 from
    /// `$(( $(date +%s) + 60 ))` ends the wait at once), or, while the
    /// child is being forked, the child runs the trap as well and one
    /// SIGTERM is logged twice.
    func sudoHangHere() -> String {
        """
        hang_on_term() {
          calls_log="\(callsLog.path)"
          watchdog=$(( SECONDS + 60 ))
          if { : >&9; } 2>/dev/null; then echo 'sudo FD9-OPEN' >> "$calls_log"; fi
          if [[ "$1" == stop ]]; then
            trap 'echo "sudo SIGTERM" >> "$calls_log"; echo "TERM $SECONDS" >> "\(root.path)/sudo.events"; exit 143' TERM
          else
            trap 'echo "sudo SIGTERM" >> "$calls_log"; echo "TERM $SECONDS" >> "\(root.path)/sudo.events"' TERM
          fi
          echo "ready $SECONDS" >> "\(root.path)/sudo.events"
          echo $$ > "\(root.path)/sudo.hung.pid"
          while [[ ! -e "\(root.path)/release" && -d "\(root.path)" ]] && (( SECONDS < watchdog )); do /bin/sleep 0.1; done
          if [[ -e "\(root.path)/release" ]]; then echo released > "\(root.path)/command.ended"
          elif [[ -d "\(root.path)" ]]; then echo watchdog > "\(root.path)/command.ended"; fi
          exit 0
        }
        """
    }

    /// What the fake sudo's hang_on_term wrote to sudo.events: "ready <s>",
    /// then "TERM <s>" or "HUP <s>" for each signal it trapped, <s> being
    /// its SECONDS (whole seconds since the fake started) at that point.
    func sudoEvents() -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("sudo.events"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Shell function for a fake: `lock_held` succeeds while someone holds
    /// the recovery lock. It asks lockf for the lock without waiting and
    /// without creating the file, the way lockIsFree does from the test.
    func lockHeldHere() -> String {
        """
        lock_held() {
          [[ -e "\(lock.path)" ]] && ! /usr/bin/lockf -k -s -t 0 "\(lock.path)" /usr/bin/true 2>/dev/null
        }
        """
    }

    /// Shell function for a fake: `receipt_lock_state <what>` appends
    /// "<what> held", "<what> free" or "<what> absent" to receipt-lock.log:
    /// whether someone holds the receipt's lock at that moment, asked
    /// without waiting and without creating the file.
    func receiptLockHere() -> String {
        """
        receipt_lock_state() {
          local s
          /usr/bin/lockf -k -n -s -t 0 "\(receipt)" /usr/bin/true 2>/dev/null
          case $? in 0) s=free ;; 75) s=held ;; 69) s=absent ;; *) s=unknown ;; esac
          echo "$1 $s" >> "\(root.path)/receipt-lock.log"
        }
        """
    }

    /// What receipt-lock.log holds, one line per record.
    func receiptLockStates() -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("receipt-lock.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Points `script`'s LOCKF at a wrapper around the real lockf. The first
    /// time the script locks fd 7 (the receipt), a start of another
    /// Insomnia folder claims the receipt just before, the way one that
    /// held the lock first and let it go would leave it: "<nonce> held" in
    /// the release file.
    func claimTheReceiptBeforeItsLock(in script: URL, nonce: String) throws {
        let wrapper = bin.appendingPathComponent("lockf-claim")
        let claimed = root.appendingPathComponent("claimed")
        try """
        #!/bin/bash
        if [[ "${!#}" == 7 && ! -e '\(claimed.path)' ]]; then
          : > '\(claimed.path)'
          printf '%s held\\n' '\(nonce)' 1<> '\(released)'
        fi
        exec /usr/bin/lockf "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        try Self.patch(text, ["LOCKF": wrapper.path]).write(to: script, atomically: true, encoding: .utf8)
    }

    /// A TMPDIR inside the fixture for one run, so a test can check that
    /// the script leaves no scratch files behind.
    func privateTmp() throws -> URL {
        let dir = root.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether the hung fake of `tool` ran and has since exited.
    func hungProcessGone(_ tool: String, within seconds: Double = 5) -> Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("\(tool).hung.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    /// What the fake `defaults` holds: one NSAppSleepDisabled value per
    /// domain, as `defaults read` prints a bool (1 or 0).
    func defaultsTable(_ rows: [(domain: String, value: String)]) throws {
        let text = rows.map { "\($0.domain)|\($0.value)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("defaults.table"), atomically: true, encoding: .utf8)
    }

    /// The fake's table after a run: domain to value; absent means no key.
    func defaultsValues() -> [String: String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("defaults.table"), encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { out[parts[0]] = parts[1] }
        }
        return out
    }

    // MARK: State

    /// Whether the pending-start marker existed at each sudo call.
    func markerAtSudo() -> [String] {
        let text = (try? String(contentsOf: root.appendingPathComponent("marker-at-sudo"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func writeState(_ json: String) throws {
        try json.write(to: state, atomically: true, encoding: .utf8)
    }

    func writeConfig(_ json: String) throws {
        try json.write(to: config, atomically: true, encoding: .utf8)
    }

    func writeSession(endsAt: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let json = #"{"startedAt":"\#(f.string(from: endsAt.addingTimeInterval(-3600)))","endsAt":"\#(f.string(from: endsAt))","extensions":[]}"#
        try json.write(to: session, atomically: true, encoding: .utf8)
    }

    func stateJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: state)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError("state.json is not a JSON object")
        }
        return obj
    }

    /// Everything uninstall.sh would remove on success.
    func installMachinery() throws {
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "binary".write(to: app.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
        try Self.infoPlist(resumeFrozenVersion: "1").write(to: appInfo, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: sudoers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "rule".write(to: sudoers, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plist".write(to: plist, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "log\n".write(to: logFile, atomically: true, encoding: .utf8)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: installedBackstop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: backstop, to: installedBackstop)
    }

    /// Points `script`'s LOCKF at a wrapper around the real lockf. Once it
    /// has locked fd 7 (`lockf -s -t N 7`, the scripts' lock on the
    /// receipt), a copy with the same bytes and mode takes the receipt's
    /// place, as root could put one there between the lock and the checks
    /// after it.
    func swapReceiptAfterItsLock(in script: URL) throws {
        let wrapper = bin.appendingPathComponent("lockf-swap-receipt")
        let copy = receipts + "/swap-copy"
        try """
        #!/bin/bash
        /usr/bin/lockf "$@"; rc=$?
        if (( rc == 0 )) && [[ "${!#}" == 7 ]]; then
          /bin/cp '\(receipt)' '\(copy)' && /bin/chmod 0600 '\(copy)' && /bin/mv -f '\(copy)' '\(receipt)'
        fi
        exit $rc
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        try Self.patch(text, ["LOCKF": wrapper.path]).write(to: script, atomically: true, encoding: .utf8)
    }

    /// Points `script`'s LOCKF at a wrapper around the real lockf. Once it
    /// has locked a descriptor (`lockf -s -t N 8`, the scripts' lock on
    /// pending-start), a copy takes the marker's place, as another process
    /// could put one there between the open and the check.
    func swapMarkerAfterItsLock(in script: URL) throws {
        let wrapper = bin.appendingPathComponent("lockf-swap")
        let copy = root.appendingPathComponent("marker-copy")
        try """
        #!/bin/bash
        /usr/bin/lockf "$@"; rc=$?
        if (( rc == 0 )) && [[ "${!#}" == 8 ]]; then
          printf copy > '\(copy.path)' && /bin/mv -f '\(copy.path)' '\(pendingStart.path)'
        fi
        exit $rc
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let text = try String(contentsOf: script, encoding: .utf8)
        try Self.patch(text, ["LOCKF": wrapper.path]).write(to: script, atomically: true, encoding: .utf8)
    }

    // MARK: Running

    /// Decoded lossily: the fake launchctl copies the first line of the
    /// installed binary into the log, which is Mach-O bytes, not text, for
    /// the fixture the real codesign signs.
    func calls() -> [String] {
        guard let data = try? Data(contentsOf: callsLog) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The calls besides those to the logging mktemp, rm, rmdir and mkdir,
    /// which every install run makes for its own scratch files (see
    /// bounded()) and the folders it installs into.
    func callsBesideScratchFiles() -> [String] {
        calls().filter { call in !["mktemp", "rm", "rmdir", "mkdir"].contains { call == $0 || call.hasPrefix($0 + " ") } }
    }

    func chmodCalls() -> [String] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("chmod.calls"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    func clearCalls() {
        try? fm.removeItem(at: callsLog)
        try? fm.removeItem(at: toolsLog)
        try? fm.removeItem(at: hostileLog)
    }

    /// The calls to the scripts' CAT and HEAD, as "cat <args>" and
    /// "head <args>".
    func toolCalls() -> [String] {
        ((try? String(contentsOf: toolsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var hostileLog: URL { root.appendingPathComponent("hostile.log") }

    /// A folder to put first in PATH, with a `head`, a `cat` and a `tr`
    /// that would mislead a script that found them there. Every call is
    /// logged to hostileLog. `head -c 83` prints `<nonce> <zero> refused`,
    /// the line of a start whose command stopped before pmset; `head -c 43`
    /// prints `<nonce> free`, a claim already given back; `head -c 1` and
    /// `tr` print `x`, so a JSON file looks like something else; `cat` of
    /// session.json fails as if it could not be read. Anything else runs
    /// the real tool.
    func writeHostileTools(forging nonce: String) throws -> String {
        let dir = root.appendingPathComponent("hostile", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tools = [
            ("head", """
            #!/bin/bash
            printf 'head %s\\n' "$*" >> "\(hostileLog.path)"
            case "$*" in
              "-c 83") printf '%s %s refused\\n' '\(nonce)' '\(SleepOffReceipts.zero)'; exit 0 ;;
              "-c 43 "*) printf '%s free\\n' '\(nonce)'; exit 0 ;;
              "-c 1"|"-c 1 "*) printf x; exit 0 ;;
            esac
            exec /usr/bin/head "$@"
            """),
            ("cat", """
            #!/bin/bash
            printf 'cat %s\\n' "$*" >> "\(hostileLog.path)"
            [[ "$*" == '\(session.path)' ]] && exit 1
            exec /bin/cat "$@"
            """),
            ("tr", """
            #!/bin/bash
            printf 'tr %s\\n' "$1" >> "\(hostileLog.path)"
            printf x
            """),
        ]
        for (name, body) in tools {
            let url = dir.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return dir.path
    }

    func hostileCalls() -> [String] {
        ((try? String(contentsOf: hostileLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The PATH each call to the scripts' CAT, HEAD and TR was given: with
    /// a folder put first, it shows that PATH was in effect for the run.
    func toolPaths() -> [String] {
        ((try? String(contentsOf: toolPathsLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// The child's PATH with `dir` first.
    func path(first dir: String) -> String {
        dir + ":" + (childEnvironment["PATH"] ?? "")
    }

    func log() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    /// Environment for the child: no inheritance, so neither the real HOME
    /// nor a TempHome's INSOMNIA_HOME can leak in. HOME is deliberately
    /// unset (see the class comment).
    var scriptEnvironment: [String: String] { childEnvironment }

    private var childEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "INSOMNIA_HOME": home.path,
        ]
    }

    /// POSIX mode bits of a file or directory.
    func mode(_ url: URL) throws -> Int {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        guard let m = attrs[.posixPermissions] as? Int else { throw FixtureError("no mode for \(url.path)") }
        return m
    }

    /// Inode of a file, to prove the lock file was retained rather than replaced.
    func inode(_ url: URL) throws -> UInt64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// Runs a script copy. `fd9` opens that file on descriptor 9 of the child
    /// first, the way uninstall.sh hands its lock handle to the backstop.
    /// `ignoringTerm` starts the script with SIGTERM ignored, which every
    /// process it starts inherits (not combined with `fd9`).
    /// `environment`, when given, is the child's whole environment in place
    /// of scriptEnvironment (see AppEncodedJournalScriptTests.ScriptRow).
    /// `extraEnvironment` is for install.sh's refusal test, the PATH tests
    /// and a private TMPDIR (see privateTmp). stdin is
    /// /dev/null, never the test process's own (a terminal when `swift test`
    /// runs in one), unless `terminalInput` is given: then stdin is a pty
    /// whose input queue already holds that text, so `[[ -t 0 ]]` is true
    /// and `read` gets the answer without any timing. `lastPid` is the
    /// script's pid afterwards: the wrappers exec it, so it is the pid of
    /// the process started here.
    private(set) var lastPid: Int32 = 0

    func run(_ script: URL, _ args: [String] = [], fd9: URL? = nil, ignoringTerm: Bool = false, environment: [String: String]? = nil, extraEnvironment: [String: String] = [:], terminalInput: String? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        precondition(fd9 == nil || !ignoringTerm, "fd9 and ignoringTerm are not combined")
        let p = Process()
        var terminal: (master: FileHandle, slave: FileHandle)?
        if let terminalInput {
            var master: Int32 = -1
            var slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw FixtureError("openpty failed: errno \(errno)") }
            let m = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            let sl = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            try m.write(contentsOf: Data(terminalInput.utf8))
            terminal = (m, sl)
            p.standardInput = sl
        } else {
            p.standardInput = FileHandle.nullDevice
        }
        defer { if let terminal { try? terminal.slave.close(); try? terminal.master.close() } }
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        if let fd9 {
            p.arguments = ["-c", #"exec 9<>"$0" && exec /bin/bash "$@""#, fd9.path, script.path] + args
        } else if ignoringTerm {
            p.arguments = ["-c", #"trap '' TERM && exec /bin/bash "$@""#, "bash", script.path] + args
        } else {
            p.arguments = [script.path] + args
        }
        p.environment = (environment ?? childEnvironment).merging(extraEnvironment) { $1 }
        p.currentDirectoryURL = root
        // Capture to files rather than pipes: nothing to drain, nothing to
        // deadlock. A capture file that cannot be made, or read back once
        // the child is reaped, fails the run: it never reads as no output.
        let outURL = root.appendingPathComponent("stdout.\(UUID().uuidString)")
        let errURL = root.appendingPathComponent("stderr.\(UUID().uuidString)")
        for url in [outURL, errURL] where !fm.createFile(atPath: url.path, contents: nil) {
            throw FixtureError("could not create \(url.path)")
        }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        p.standardOutput = out
        p.standardError = err
        let childExit = ProcessExit(p)
        try p.run()
        lastPid = p.processIdentifier
        childExit.wait()
        return (p.terminationStatus, try captured(outURL), try captured(errURL))
    }

    /// What a run wrote to the capture file `url`. A file that cannot be
    /// read, or whose bytes are not UTF-8, throws.
    private func captured(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FixtureError("\(url.lastPathComponent) is not UTF-8 text")
        }
        return text
    }

    /// The pid a hung fake of `tool` recorded (see hangHere), once it has
    /// started; nil if it has not within `seconds`.
    func hungPid(_ tool: String, within seconds: Double) -> pid_t? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let text = try? String(contentsOf: root.appendingPathComponent("\(tool).hung.pid"), encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return nil
    }

    /// A PATH whose `sleep` waits a quarter second before the sleep it was
    /// asked for, so every poll install.sh and uninstall.sh make is slow, as
    /// on a loaded machine where each fork takes long. The scripts call sleep
    /// by name; the fakes call /bin/sleep. Each call is counted (slowPolls()).
    func slowPollingPath() throws -> String {
        let dir = root.appendingPathComponent("slow-poll", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent("sleep")
        try """
        #!/bin/bash
        echo "$*" >> "\(root.path)/slow-poll.log"
        /bin/sleep 0.25
        exec /bin/sleep "$@"

        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return "\(dir.path):/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// How many times the scripts called the slow `sleep`.
    func slowPolls() -> Int {
        let text = (try? String(contentsOf: root.appendingPathComponent("slow-poll.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    /// Runs a real tool (not a script) with the fixture's environment: the
    /// real codesign for the one test that signs its fixture, and the shells
    /// that read back a command install.sh prints for pasting.
    func runTool(_ exe: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = childEnvironment
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let toolExit = ProcessExit(p)
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        toolExit.wait()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A script started in the background by `spawn`. Nothing in the test
    /// process reaps it but `wait`: Foundation reaps only the Processes it
    /// started, and nothing else here calls waitpid. Until `wait`, its pid
    /// stays its own even after it exits (as a zombie), so `signal` reaches
    /// this child or nothing, never a process that reused the pid.
    final class Spawned {
        let pid: pid_t
        /// Started as the leader of a process group of its own (see spawn).
        let leadsGroup: Bool
        private(set) var status: Int32?

        init(pid: pid_t, leadsGroup: Bool) {
            self.pid = pid
            self.leadsGroup = leadsGroup
        }

        /// Whether the child has exited, checked without reaping it.
        var hasExited: Bool {
            guard status == nil else { return true }
            var info = siginfo_t()
            return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
        }

        /// Sends `sig` to the child. Refuses with -1 once `wait` has reaped
        /// it, since the pid may then belong to another process.
        func signal(_ sig: Int32) -> Int32 {
            guard status == nil else { return -1 }
            return kill(pid, sig)
        }

        /// Sends `sig` to every process in the group the child leads, the
        /// way launchd signals what is left of a job's process group once
        /// its main process has exited. Only for a child spawned with
        /// `ownProcessGroup`, so the group holds nothing but the child and
        /// what it started. Refuses with -1 once `wait` has reaped the
        /// child: until then its pid, the group's id, cannot name another
        /// process or group.
        func signalGroup(_ sig: Int32) -> Int32 {
            guard leadsGroup, status == nil else { return -1 }
            return killpg(pid, sig)
        }

        /// Waits for the child to exit, reaps it, and returns its wait
        /// status (-1 if waitpid failed).
        @discardableResult
        func wait() -> Int32 {
            if let status { return status }
            var raw: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
            let result = reaped == pid ? raw : -1
            status = result
            return result
        }
    }

    /// Starts `script` under /bin/bash with the same environment (plus
    /// `extraEnvironment`) and working directory as `run`, standard input and output on /dev/null,
    /// and returns without waiting for it. Like a Process, the child gets
    /// no other descriptor of the test process, an empty signal mask and
    /// default signal actions. With `ownProcessGroup` it leads a new process
    /// group, as launchd starts a job, instead of joining the test's.
    func spawn(_ script: URL, extraEnvironment: [String: String] = [:], ownProcessGroup: Bool = false) throws -> Spawned {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir(&actions, root.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var mask = sigset_t()
        sigemptyset(&mask)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        if ownProcessGroup {
            posix_spawnattr_setpgroup(&attr, 0)
            flags |= POSIX_SPAWN_SETPGROUP
        }
        posix_spawnattr_setflags(&attr, Int16(flags))

        let arguments = ["/bin/bash", script.path]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let environment = childEnvironment.merging(extraEnvironment) { $1 }.map { "\($0.key)=\($0.value)" }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/bash", &actions, &attr, argv, envp)
        guard spawned == 0, pid > 0 else { throw FixtureError("posix_spawn /bin/bash \(script.path) failed: \(spawned)") }
        return Spawned(pid: pid, leadsGroup: ownProcessGroup)
    }

    /// A lockf process that holds the recovery lock.
    struct LockHolder {
        let process: Process
        let exit: ProcessExit

        /// Terminates the holder and returns once it has exited.
        func stop() {
            process.terminate()
            exit.wait()
        }
    }

    /// Holds the recovery lock from another process, the way a running app
    /// or a concurrent backstop would, until stopped.
    func holdLock() throws -> LockHolder {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        // The holder waits (not -t 0): a probe below may briefly own the lock
        // at the same instant, and the holder must outlast that, not give up.
        p.arguments = ["-k", "-t", "10", lock.path, "/bin/sleep", "30"]
        let diagURL = root.appendingPathComponent("lock-holder.log")
        fm.createFile(atPath: diagURL.path, contents: nil)
        let diag = try FileHandle(forWritingTo: diagURL)
        defer { try? diag.close() }
        p.standardOutput = diag
        p.standardError = diag
        let holder = LockHolder(process: p, exit: ProcessExit(p))
        try p.run()
        // Wait until the holder really owns the lock.
        var probes: [Int32] = []
        for _ in 0..<50 {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-k", "-s", "-t", "0", lock.path, "/usr/bin/true"]
            probe.standardOutput = diag
            probe.standardError = diag
            let probeExit = ProcessExit(probe)
            try probe.run()
            probeExit.wait()
            probes.append(probe.terminationStatus)
            if probe.terminationStatus == 75 { return holder }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.terminate()
        let text = (try? String(contentsOf: diagURL, encoding: .utf8)) ?? ""
        throw FixtureError("could not take the recovery lock for the contention test; holder running=\(p.isRunning) probes=\(probes) output=\(text)")
    }
}

/// The app and the production copy of backstop.sh across restarts, with
/// fake devices and a temporary home: what the agent publishes is what the
/// next launch reads.
@MainActor
final class AgentModeExitInANewBootTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy(); h = nil }

    private func lidActions(_ m: SessionManager, sampler: BrightnessSampler) -> LidActions {
        m.config.muteOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        m.config.darkenDisplayOnLidClose = true
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        return LidActions(manager: m, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { true }), audio: h.audio, display: h.display, keyboard: h.keyboard, sampler: sampler)
    }

    private func follow(_ m: SessionManager) -> BrightnessSampler {
        let sampler = BrightnessSampler(display: h.display, keyboard: h.keyboard, idleSeconds: { 1 })
        sampler.follow(m)
        return sampler
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    /// In boot A the app switches Low Power Mode on over a kept 0.8, and
    /// an open reads it at 0.4: the journal records that reading and the
    /// mode over the entry, in boot A. The Mac restarts, and in boot B the
    /// agent switches the mode off before the app launches. The app's
    /// first reading in boot B, 0.4 again while the panel comes back from
    /// the mode, is not taken as the user's level: the entry waits and
    /// nothing is sampled. The user's 0.6 then reads the same way, so a
    /// close and an open leave the panel at 0.6 and never write 0.4. A
    /// launch in boot C reads 0.6 and leaves it as set.
    func testAReadingAfterTheAgentSwitchedTheModeOffInANewBootWaitsForTheNextBoot() async throws {
        var seeded = RuntimeState()
        seeded.savedDisplayBrightness = 0.8
        seeded.displayRestoreRefused = true
        try h.store.saveState(seeded)
        h.clamshell.closed = false
        h.display.brightness = 0.4
        let first = h.makeManager(bootSession: "boot A")
        await first.start(duration: 3600)
        let on = await first.setLowPower(true)
        XCTAssertTrue(on)
        await lidActions(first, sampler: follow(first)).onOpen()
        let bootA = try XCTUnwrap(try h.store.loadState())
        XCTAssertTrue(bootA.lowPowerSetByUs)
        XCTAssertEqual(bootA.keptDisplayReadLit, 0.8)
        XCTAssertEqual(bootA.keptDisplayUnderLowPowerBoot, "boot A")

        let f = try ScriptFixture()
        defer { f.destroy() }
        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try f.writeState(try String(contentsOf: h.home.paths.stateFile, encoding: .utf8))
        let r = try f.run(f.backstop)
        XCTAssertEqual(r.status, 0, r.stderr + f.log())
        XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(f.calls())")
        try Data(contentsOf: f.state).write(to: h.home.paths.stateFile)
        try FileManager.default.removeItem(at: h.home.paths.sessionFile)
        h.guardFake.lowPowerOn = false
        let published = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(published.lowPowerSetByUs)
        XCTAssertEqual(published.keptDisplayUnderLowPowerBoot, f.bootUUID)

        let m = h.makeManager(bootSession: f.bootUUID)
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        await m.reconcile()

        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8, "0.4 is not taken as the user's level")
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertNil(sampler.last?.display, "nothing sampled")
        XCTAssertTrue(logText().contains("display brightness 0.8, kept after a refused restore, reads 0.4 after our low power mode was or may have been on over it since the Mac last started, which rescales it until some time after it goes off; that is not taken as a level set since"), logText())

        await m.start(duration: 3600)
        h.display.brightness = 0.6
        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.4), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertEqual(try h.store.loadState()?.savedDisplayBrightness, 0.8)
        XCTAssertNil(sampler.last?.display)
        _ = await m.end(reason: .user)

        let later = h.makeManager(bootSession: "boot C")
        let laterSampler = follow(later)
        await later.reconcile()

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(laterSampler.last?.display, 0.6)
        XCTAssertFalse(h.display.sets.contains(0.4), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
    }
    /// The same journal from boot A, and in boot B the agent switches the
    /// mode off, but the journal of its undo cannot be published: the
    /// file still claims the mode and the session. The record was given
    /// boot B before the mode went off, so the app reads the claim as its
    /// own mode on in this boot: the first reading, 0.4 while the panel
    /// comes back, is not taken as the user's level, and a close and an
    /// open never write it. A launch in boot C decides on the user's 0.6.
    func testAReadingAfterTheAgentSwitchedTheModeOffWaitsWhenItsJournalIsNotPublished() async throws {
        var seeded = RuntimeState()
        seeded.savedDisplayBrightness = 0.8
        seeded.displayRestoreRefused = true
        seeded.lowPowerSetByUs = true
        seeded.keptDisplayUnderLowPower = 0.8
        seeded.keptDisplayUnderLowPowerBoot = "boot A"
        seeded.keptDisplayReadLit = 0.8
        let f = try ScriptFixture()
        defer { f.destroy() }
        try Store.makeEncoder().encode(seeded).write(to: f.state)
        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try f.failMoves([("*/.state.json.backstop.*", "*")])

        let r = try f.run(f.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(f.calls())")
        XCTAssertTrue(f.exists(f.session))
        let onDisk = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: f.state))
        XCTAssertTrue(onDisk.lowPowerSetByUs, "the undo's journal was not published")
        XCTAssertEqual(onDisk.keptDisplayUnderLowPowerBoot, f.bootUUID)
        try Data(contentsOf: f.state).write(to: h.home.paths.stateFile)
        // The session the agent kept, expired by the app's clock too.
        try h.store.saveSession(Session(startedAt: h.clock.now.addingTimeInterval(-7200), endsAt: h.clock.now.addingTimeInterval(-60)))
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4

        let m = h.makeManager(bootSession: f.bootUUID)
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        await m.reconcile()

        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8, "0.4 is not taken as the user's level")
        XCTAssertTrue(waiting.displayRestoreRefused)
        XCTAssertFalse(waiting.lowPowerSetByUs)
        XCTAssertEqual(m.effectiveState.savedDisplayBrightness, 0.8)
        XCTAssertNil(sampler.last?.display, "nothing sampled")
        XCTAssertEqual(h.display.sets, [])

        await m.start(duration: 3600)
        h.display.brightness = 0.6
        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.4), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertNil(sampler.last?.display)
        _ = await m.end(reason: .user)

        let later = h.makeManager(bootSession: "boot C")
        let laterSampler = follow(later)
        await later.reconcile()

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(laterSampler.last?.display, 0.6)
        XCTAssertFalse(h.display.sets.contains(0.4), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
    }

    /// The same journal from boot A, and in boot B state.json refuses
    /// every change, so the agent cannot publish boot B before the mode
    /// goes off and leaves the mode on. The app launches with the claim
    /// from boot A and reads the mode on, so the switch-off is the mode's
    /// end in this boot: 0.4 is not taken as the user's level, and a close
    /// and an open never write it.
    func testAReadingWaitsWhenTheAgentLeftTheModeOnForWantOfAJournal() async throws {
        var seeded = RuntimeState()
        seeded.savedDisplayBrightness = 0.8
        seeded.displayRestoreRefused = true
        seeded.lowPowerSetByUs = true
        seeded.keptDisplayUnderLowPower = 0.8
        seeded.keptDisplayUnderLowPowerBoot = "boot A"
        seeded.keptDisplayReadLit = 0.8
        let original = try Store.makeEncoder().encode(seeded)
        let f = try ScriptFixture()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)
            f.destroy()
        }
        try original.write(to: f.state)
        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: f.state.path)

        let r = try f.run(f.backstop)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(f.calls().contains { $0.contains("lowpowermode") }, "\(f.calls())")
        XCTAssertEqual(try Data(contentsOf: f.state), original)
        try original.write(to: h.home.paths.stateFile)
        try h.store.saveSession(Session(startedAt: h.clock.now.addingTimeInterval(-7200), endsAt: h.clock.now.addingTimeInterval(-60)))
        h.guardFake.lowPowerOn = true
        h.clamshell.closed = false
        h.display.brightness = 0.4

        let m = h.makeManager(bootSession: f.bootUUID)
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        await m.reconcile()

        XCTAssertFalse(h.guardFake.lowPowerOn, "the app switches its mode off itself")
        let waiting = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(waiting.savedDisplayBrightness, 0.8, "0.4 is not taken as the user's level")
        XCTAssertEqual(waiting.keptDisplayUnderLowPowerBoot, f.bootUUID)
        XCTAssertNil(sampler.last?.display, "nothing sampled")
        XCTAssertTrue(logText().contains("low power mode, journaled as ours before the Mac last started, reads on; it is switched off as ours in this boot"), logText())

        await m.start(duration: 3600)
        h.display.brightness = 0.6
        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.4), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertNil(sampler.last?.display)
        _ = await m.end(reason: .user)
    }

    /// The same journal from boot A. In boot B the user or another tool
    /// switches Low Power Mode off a moment before the app launches: with
    /// no agent run before it, or after the agent could not publish this
    /// boot and so left the mode on. The app reads the mode off, which
    /// does not show the panel is back: 0.4 is not taken as the user's
    /// level, nothing is sampled, and a close and an open leave the
    /// user's 0.6 as set and never write 0.4. A launch in boot C decides
    /// on 0.6.
    private func checkARecentSwitchOffByHandIsNotTakenAsTheUsersLevel(failedPreparation: Bool) async throws {
        var seeded = RuntimeState()
        seeded.savedDisplayBrightness = 0.8
        seeded.displayRestoreRefused = true
        seeded.lowPowerSetByUs = true
        seeded.keptDisplayUnderLowPower = 0.8
        seeded.keptDisplayUnderLowPowerBoot = "boot A"
        seeded.keptDisplayReadLit = 0.8
        let original = try Store.makeEncoder().encode(seeded)
        let f = try ScriptFixture()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)
            f.destroy()
        }
        if failedPreparation {
            try original.write(to: f.state)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: f.state.path)
            let r = try f.run(f.backstop)
            try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.state.path)
            XCTAssertNotEqual(r.status, 0)
            XCTAssertFalse(f.calls().contains { $0.contains("lowpowermode") }, "\(f.calls())")
            XCTAssertEqual(try Data(contentsOf: f.state), original)
        }
        try original.write(to: h.home.paths.stateFile)
        try h.store.saveSession(Session(startedAt: h.clock.now.addingTimeInterval(-7200), endsAt: h.clock.now.addingTimeInterval(-60)))
        // Switched off by hand a moment ago: the panel is on its way back
        // to the user's 0.6.
        h.guardFake.lowPowerOn = false
        h.clamshell.closed = false
        h.display.brightness = 0.4

        let m = h.makeManager(bootSession: f.bootUUID)
        let sampler = follow(m)
        let actions = lidActions(m, sampler: sampler)
        await m.reconcile()

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.savedDisplayBrightness, 0.8, "a mode off a moment ago does not show the panel is back")
        XCTAssertFalse(after.lowPowerSetByUs)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, f.bootUUID)
        XCTAssertNil(sampler.last?.display, "0.4 is not the user's sample")
        XCTAssertEqual(h.display.sets, [])
        XCTAssertTrue(logText().contains("low power mode, journaled as ours before the Mac last started, reads off; it may have gone off only a moment ago, with the panel still on its way back, so it is switched off as ours in this boot"), logText())

        await m.start(duration: 3600)
        h.display.brightness = 0.6
        h.clamshell.closed = true
        await actions.onClose()
        h.clamshell.closed = false
        await actions.onOpen()

        XCTAssertFalse(h.display.sets.contains(0.4), "the next close and open do not write over the user's 0.6: \(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
        XCTAssertNil(sampler.last?.display)
        _ = await m.end(reason: .user)

        let later = h.makeManager(bootSession: "boot C")
        let laterSampler = follow(later)
        await later.reconcile()

        XCTAssertNil(try h.store.loadState()?.savedDisplayBrightness)
        XCTAssertEqual(laterSampler.last?.display, 0.6)
        XCTAssertFalse(h.display.sets.contains(0.4), "\(h.display.sets)")
        XCTAssertEqual(h.display.brightness, 0.6)
    }

    func testARecentSwitchOffByHandWithNoAgentIsNotTakenAsTheUsersLevel() async throws {
        try await checkARecentSwitchOffByHandIsNotTakenAsTheUsersLevel(failedPreparation: false)
    }

    func testARecentSwitchOffByHandAfterAFailedAgentPreparationIsNotTakenAsTheUsersLevel() async throws {
        try await checkARecentSwitchOffByHandIsNotTakenAsTheUsersLevel(failedPreparation: true)
    }
}

/// Journals the app writes itself, through LidActions and the Store, over
/// an output device whose name or UID holds a backslash with "u0041" after
/// it. The app's encoder writes that backslash as \\, so the text holds
/// "\\u0041": a string with a backslash in it, not a \u escape. The
/// scripts read it as the app does and undo the rest of the journal, and
/// the app then restores the device.
@MainActor
final class AppEncodedJournalScriptTests: XCTestCase {
    private static let escapedName = "Headset \(backslash)u0041"
    private static let escapedUID = "Device-\(backslash)u0041"

    /// The journal the app writes as the lid closes with muting on, with
    /// sleep, Low Power Mode and a frozen process journaled beside it,
    /// and, with `record`, a kept display entry and its records from boot
    /// A. `legacy` drops the save ID, as builds before it wrote the entry.
    private func appJournal(uid: String, name: String, record: Bool, legacy: Bool, boot: String) async throws -> Data {
        let h = Harness()
        defer { h.home.destroy() }
        h.audio.connect(uid, name: name, volume: 0.6)
        let m = h.makeManager(bootSession: boot)
        m.config.muteOnLidClose = true
        m.config.darkenDisplayOnLidClose = false
        m.config.freezeList = []
        m.config.freezeAllApps = false
        await m.start(duration: 3600)
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        let actions = LidActions(manager: m, freezer: freezer, docker: DockerRule(freezer: freezer, probe: { true }), audio: h.audio, display: h.display, keyboard: h.keyboard)
        await actions.onClose()
        XCTAssertEqual(h.audio.mutes, 1)
        var s = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(s.savedAudioOutputs.map(\.deviceUID), [uid])
        XCTAssertEqual(s.savedAudioOutputs.map(\.name), [name])
        if legacy {
            s.savedAudioOutputs = s.savedAudioOutputs.map { SavedAudioOutput(deviceUID: $0.deviceUID, name: $0.name, volume: $0.volume, muted: $0.muted, saveID: nil) }
        }
        s.sleepDisabledByUs = true
        s.lowPowerSetByUs = true
        s.frozenProcesses = [FrozenProcess(pid: 4242, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: boot))]
        if record {
            s.savedDisplayBrightness = 0.8
            s.displayRestoreRefused = true
            s.keptDisplayUnderLowPower = 0.8
            s.keptDisplayUnderLowPowerBoot = "boot A"
            s.keptDisplayReadLit = 0.8
        }
        try h.store.saveState(s)
        let data = try Data(contentsOf: h.home.paths.stateFile)
        XCTAssertEqual(try Store.makeDecoder().decode(RuntimeState.self, from: data), s)
        return data
    }

    private static func variants() -> [(label: String, uid: String, name: String)] {
        [("name", "Device-A", escapedName), ("uid", escapedUID, "Headset A"), ("plain", "Device-A", "Headset A")]
    }

    /// One script run of a fixture of its own. The child's whole
    /// environment is taken from that fixture when the row is made, before
    /// anything runs, and only that fixture's tree is written to, so two
    /// rows can run at once. The result is set once the child has exited
    /// and been reaped (ScriptFixture.run waits for it).
    private final class ScriptRow: @unchecked Sendable {
        let label: String
        let fixture: ScriptFixture
        let script: URL
        let args: [String]
        let environment: [String: String]
        private(set) var result: Result<(status: Int32, stdout: String, stderr: String), Error>?

        init(_ label: String, _ fixture: ScriptFixture, _ script: URL, _ args: [String] = []) {
            self.label = label
            self.fixture = fixture
            self.script = script
            self.args = args
            environment = fixture.scriptEnvironment
        }

        func run() {
            result = Result { try fixture.run(script, args, environment: environment) }
        }

        /// The run's result; fails the test for a row that did not run or
        /// whose run threw.
        func outcome(file: StaticString = #filePath, line: UInt = #line) throws -> (status: Int32, stdout: String, stderr: String) {
            try XCTUnwrap(result, "\(label): the script did not run", file: file, line: line).get()
        }
    }

    /// Hands out the rows one at a time and counts how many run at once.
    private final class RowQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let rows: [ScriptRow]
        private var next = 0
        private var running = 0
        private(set) var mostAtOnce = 0

        init(_ rows: [ScriptRow]) { self.rows = rows }

        func take() -> ScriptRow? {
            lock.lock()
            defer { lock.unlock() }
            guard next < rows.count else { return nil }
            next += 1
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            return rows[next - 1]
        }

        func done() {
            lock.lock()
            running -= 1
            lock.unlock()
        }
    }

    /// Runs the rows' scripts at most two at a time, each from a thread of
    /// its own, and returns once every row has run: each child has then
    /// exited and been reaped. Only the scripts run here; everything that
    /// builds a journal with the app or reads one back runs before or after,
    /// on the test's own thread. Checks that every row ran, that no more
    /// than two ran at once, and that each child's environment was its own
    /// fixture's.
    private static func runTwoAtATime(_ rows: [ScriptRow], file: StaticString = #filePath, line: UInt = #line) {
        let queue = RowQueue(rows)
        let group = DispatchGroup()
        for _ in 0..<min(2, rows.count) {
            group.enter()
            Thread.detachNewThread {
                while let row = queue.take() {
                    row.run()
                    queue.done()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertLessThanOrEqual(queue.mostAtOnce, 2, file: file, line: line)
        XCTAssertEqual(rows.filter { $0.result == nil }.map(\.label), [], "rows that did not run", file: file, line: line)
        for row in rows {
            XCTAssertEqual(row.environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "INSOMNIA_HOME": row.fixture.home.path], row.label, file: file, line: line)
        }
        XCTAssertEqual(Set(rows.map { $0.environment["INSOMNIA_HOME"] ?? "" }).count, rows.count, "each row has a home of its own", file: file, line: line)
    }

    /// Sleep, Low Power Mode and the frozen process are undone, the session
    /// goes, and the saved output stays in the journal as the app wrote it.
    private func checkUndone(_ f: ScriptFixture, before: Data, _ label: String) throws {
        XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), "\(label): \(f.calls())")
        XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -b lowpowermode 0"), "\(label): \(f.calls())")
        XCTAssertTrue(f.calls().contains { $0.hasPrefix("Insomnia --resume-frozen") && $0.contains("4242 1789388423 17") }, "\(label): \(f.calls())")
        XCTAssertFalse(f.log().contains("malformed"), "\(label): \(f.log())")
        let wrote = try Store.makeDecoder().decode(RuntimeState.self, from: before)
        let after = try Store.makeDecoder().decode(RuntimeState.self, from: Data(contentsOf: f.state))
        XCTAssertFalse(after.sleepDisabledByUs, label)
        XCTAssertFalse(after.lowPowerSetByUs, label)
        XCTAssertEqual(after.frozenProcesses, [], label)
        XCTAssertEqual(after.savedAudioOutputs, wrote.savedAudioOutputs, label)
        XCTAssertEqual(after.keptDisplayUnderLowPowerBoot, wrote.keptDisplayUnderLowPower == nil ? nil : f.bootUUID, label)
    }

    /// The agent on an expired session: the same outcome for each name or
    /// UID as for a plain one, with or without a kept display record, in
    /// the current entry form and the legacy one. The app then restores
    /// the device from the journal the agent published.
    /// The journals are written one at a time with the app, the agent runs
    /// on them two at a time (runTwoAtATime), and each is then checked and
    /// read back by the app one at a time.
    func testAnEscapedNameOrUIDDoesNotStopTheAgentAndTheAppRestoresIt() async throws {
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        var rows: [(row: ScriptRow, v: (label: String, uid: String, name: String), before: Data)] = []
        for v in Self.variants() {
            for record in [false, true] {
                for legacy in [false, true] {
                    let label = "\(v.label) record \(record) legacy \(legacy)"
                    let f = try ScriptFixture()
                    fixtures.append(f)
                    let before = try await appJournal(uid: v.uid, name: v.name, record: record, legacy: legacy, boot: f.bootUUID)
                    if v.label != "plain" {
                        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("\(backslash)\(backslash)u0041"), label)
                    }
                    try before.write(to: f.state)
                    try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
                    rows.append((ScriptRow(label, f, f.backstop), v, before))
                }
            }
        }
        XCTAssertEqual(rows.count, 12)

        Self.runTwoAtATime(rows.map(\.row))

        for (row, v, before) in rows {
            let label = row.label
            let f = row.fixture
            let r = try row.outcome()

            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr) \(f.log())")
            XCTAssertFalse(f.exists(f.session), label)
            try checkUndone(f, before: before, label)

            let h = Harness()
            defer { h.home.destroy() }
            h.audio.connect(v.uid, name: v.name, volume: 0.6, muted: true)
            h.clamshell.closed = false
            try Data(contentsOf: f.state).write(to: h.home.paths.stateFile)
            let m = h.makeManager(bootSession: f.bootUUID)
            await m.reconcile()

            XCTAssertEqual(h.audio.device(v.uid)?.muted, false, label)
            XCTAssertEqual(h.audio.device(v.uid)?.volume, 0.6, label)
            XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [], label)
        }
    }

    /// uninstall.sh, with and without --purge, runs the backstop it
    /// installed over the same journals: the undo goes as far as for a
    /// plain name, and the saved output, which only the app restores,
    /// stops the removal with the app, the agent and the sudoers rule in
    /// place.
    /// The journals are written one at a time with the app, and the
    /// uninstalls run two at a time (runTwoAtATime).
    func testAnEscapedNameOrUIDDoesNotStopTheUndoOfAnUninstall() async throws {
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        var rows: [(row: ScriptRow, before: Data)] = []
        for v in Self.variants() {
            for record in [false, true] {
                for legacy in [false, true] {
                    for purge in [false, true] {
                        let label = "\(v.label) record \(record) legacy \(legacy) purge \(purge)"
                        let f = try ScriptFixture()
                        fixtures.append(f)
                        let before = try await appJournal(uid: v.uid, name: v.name, record: record, legacy: legacy, boot: f.bootUUID)
                        try f.installMachinery()
                        try before.write(to: f.state)
                        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
                        rows.append((ScriptRow(label, f, f.uninstall, purge ? ["--purge"] : []), before))
                    }
                }
            }
        }
        XCTAssertEqual(rows.count, 24)

        Self.runTwoAtATime(rows.map(\.row))

        for (row, before) in rows {
            let label = row.label
            let f = row.fixture
            let r = try row.outcome()

            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertTrue(f.exists(f.app), label)
            XCTAssertTrue(f.exists(f.plist), label)
            XCTAssertTrue(f.exists(f.sudoers), label)
            XCTAssertFalse(r.stderr.contains("malformed"), "\(label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("audio") || r.stdout.contains("audio"), "\(label): \(r.stdout) \(r.stderr)")
            try checkUndone(f, before: before, label)
        }
    }

    /// Journals the app reads, each with sleep journaled, through the
    /// agent: what is around the records, in strings and nested values,
    /// holds none, and the forms of a record the app reads pass. Sleep is
    /// undone each time.
    func testWhatTheAppReadsAroundTheRecordsDoesNotStopTheAgent() throws {
        let b = backslash
        let base = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false"#
        let tails: [(label: String, tail: String)] = [
            ("an escaped backslash in a value", #","unrelated":"Device \#(b)\#(b)u0041"}"#),
            ("an escape in a value", #","unrelated":"Device \#(b)u0041"}"#),
            ("a nested number too small", #","unrelated":{"keptDisplayReadLit":1e-400}}"#),
            ("a nested copy", #","keptDisplayReadLit":0.8,"unrelated":{"keptDisplayReadLit":0.7}}"#),
            ("an escaped key", #","keptDisplayReadL\#(b)u0069t":0.8}"#),
            ("a float", #","keptDisplayReadLit":0.80000001192092896}"#),
            ("zero with an exponent", #","keptDisplayReadLit":0e-400}"#),
            ("negative zero", #","keptDisplayReadLit":-0}"#),
            ("an integer", #","keptDisplayReadLit":1}"#),
            ("null", #","keptDisplayReadLit":null}"#),
        ]
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        var rows: [ScriptRow] = []
        for (label, tail) in tails {
            let json = base + tail
            XCTAssertNoThrow(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), label)
            let f = try ScriptFixture()
            fixtures.append(f)
            try f.writeState(json)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            rows.append(ScriptRow(label, f, f.backstop))
        }
        XCTAssertEqual(rows.count, 10)

        // The agent runs on them two at a time (runTwoAtATime).
        Self.runTwoAtATime(rows)

        for row in rows {
            let label = row.label
            let f = row.fixture
            let r = try row.outcome()

            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr) \(f.log())")
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), label)
            XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, false, label)
            XCTAssertFalse(f.exists(f.session), label)
        }
    }
}
