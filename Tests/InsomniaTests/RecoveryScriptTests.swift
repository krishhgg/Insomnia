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
/// LaunchAgent, sudoers file, or installed app is read or written. lockf
/// and id are the real tools, and so is date, except for the backstop's
/// moved-aside stamp, which a test can freeze. plutil is the real tool
/// behind a wrapper that records Info.plist reads. The other fakes record
/// every call.
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
            // Both scripts read through their bounded plutil_read, so each
            // harness has that and the helpers it calls, and a folder for
            // their files.
            let work = fx.root.appendingPathComponent("work.\(script.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            var functions = try Self.readLayerSource(text, script: script.lastPathComponent, work: work)
            for name in ["epoch_of", "epoch_at"] {
                functions += try Self.shellFunction(name, in: text, script.lastPathComponent)
            }
            let harness = fx.root.appendingPathComponent("epoch_at.\(script.lastPathComponent)")
            try ("set -euo pipefail\n" + functions
                + #"for f in "$@"; do printf '[%s]\n' "$(epoch_at "$f" endsAt)"; done"# + "\n")
                .write(to: harness, atomically: true, encoding: .utf8)

            let r = try fx.run(harness, files)

            XCTAssertEqual(r.status, 0, r.stderr)
            let failures = work.appendingPathComponent("read-failures.lines")
            XCTAssertFalse(FileManager.default.fileExists(atPath: failures.path), "no read failed: \((try? String(contentsOf: failures, encoding: .utf8)) ?? "")")
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

    /// The same with a regular session.json its owner cannot open: it is
    /// present, so it never counts as absent. The backstop keeps it in
    /// place when the undo fails, and uninstall's own bounded read of it
    /// fails, so the check reports an access failure and stops.
    func testUninstallStopsWhenASessionFileWithoutReadPermissionIsKeptByAFailedUndo() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        try fx.installMachinery()
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        XCTAssertEqual(chmod(fx.session.path, 0), 0)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try movedAsideSessions(), [])
        for kept in [fx.plist, fx.sudoers, fx.app] { XCTAssertTrue(fx.exists(kept), kept.path) }
        XCTAssertTrue(r.stderr.contains("\n  - session.json is still present and cannot be read (permissions or I/O)\n"), r.stderr)
        XCTAssertTrue(try fx.lockIsFree())
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

    // MARK: - uninstall.sh

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
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(calls)")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(fx.calls())")
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
        XCTAssertFalse(fx.calls().contains { ScriptFixture.runsAsRoot($0) || $0.hasPrefix("launchctl") }, "\(fx.calls())")
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
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove \(fx.sudoers.path) ") }, "\(fx.calls())")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || ScriptFixture.runsAsRoot($0) }, "\(fx.calls())")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || ScriptFixture.runsAsRoot($0) }, "\(fx.calls())")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("backstop ") || $0.hasPrefix("launchctl") || ScriptFixture.runsAsRoot($0) }, "\(fx.calls())")
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

    /// The shared supervisor gives its call the SIGTERM and SIGHUP actions
    /// the script started with, though it ignores both itself: the fake
    /// sudo sends itself each signal from a shell that inherits its actions
    /// (see "signals-self") and logs "sudo SURVIVED <signal>" only if it
    /// lives on. A harness started with SIGTERM already ignored cannot give
    /// the default back, since bash keeps a signal ignored at its start
    /// ignored, and the fake sees that: a check on the check.
    func testTheSharedSupervisorGivesItsCallTheDefaultSignalActions() throws {
        let harness = try boundedHarness()
        fx.setMode("sudo", "signals-self")
        for ignoringTerm in [false, true] {
            fx.clearCalls()

            let r = try fx.run(harness, ignoringTerm: ignoringTerm)

            XCTAssertEqual(r.status, 0, r.stderr)
            let survived = ignoringTerm ? ["sudo SURVIVED TERM"] : []
            XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"] + survived + ["sudo SIGNALS-CHECKED", "bounded 0"],
                           "ignoringTerm \(ignoringTerm)")
            XCTAssertTrue(try fx.lockIsFree(), "ignoringTerm \(ignoringTerm)")
        }
    }

    /// The shared supervisor works alone once its run is gone, as
    /// backstop.sh's does. The harness holds the recovery lock on fd 9 and
    /// makes one bounded sudo call; the fake sudo closes its fd 9, as sudo
    /// does, and logs each SIGTERM and SIGHUP with its sender. The test
    /// kills the harness with SIGKILL while it waits, then sends SIGTERM,
    /// SIGHUP and SIGINT to its whole process group. The supervisor
    /// survives, sends its call SIGTERM at the 3 s limit and never SIGKILL,
    /// and keeps the lock until the call has exited and it has reaped it:
    /// only then does it write the call's status. The test signals only the
    /// harness it posix_spawned as a group leader, and that group, before
    /// reaping the harness.
    func testTheSharedSupervisorOutlivesItsRunAndGroupSignalsAndHoldsTheLockUntilItReapsTheCall() throws {
        let harness = try boundedHarness()
        fx.setMode("sudo", "drops-fd9-logs-signals")

        let shell = try fx.spawn(harness, ownProcessGroup: true)
        defer {
            fx.releaseCommand()
            shell.wait()
        }
        guard let command = fx.hungPid("sudo", within: 10) else {
            _ = shell.signal(SIGKILL)
            return XCTFail("the call never started: \(fx.calls())")
        }
        guard !shell.hasExited else {
            return XCTFail("the harness ended before the test could kill it (wait status \(shell.wait())): \(fx.calls())")
        }
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        signalGroupInTurn(shell, receiver: command)
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the harness did not end by SIGKILL (wait status \(status))")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor survived the group's signals and holds the lock")

        XCTAssertTrue(waitUntil(15) { self.fx.calls().filter { $0 == "sudo SIGTERM" }.count == 2 },
                      "one SIGTERM from the group, one from the supervisor at the limit: \(fx.calls())")
        let senders = try fx.signalSenders(of: command)
        XCTAssertNotEqual(senders.parent, shell.pid, "the call's parent is the supervisor, not the killed harness")
        XCTAssertEqual(senders.term.sorted(), [getpid(), senders.parent].sorted(),
                       "one SIGTERM from this test's signal to the group, one from the supervisor (pid \(senders.parent))")
        XCTAssertEqual(senders.hup, [getpid()], "the only SIGHUP is this test's signal to the group")
        XCTAssertEqual(fx.calls().filter { !$0.hasPrefix("sudo SIG") }, ["sudo -n \(fx.fakePmset) -a disablesleep 0"],
                       "the call had closed fd 9, and the killed harness wrote nothing more")
        XCTAssertNil(fx.commandEnded(), "never SIGKILLed")
        XCTAssertEqual(try harnessStatuses(), [], "no status before the call is reaped")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor still holds the lock for its live call")

        fx.releaseCommand()
        try assertLockHeldUntilGone(command, within: 10)
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(waitUntil(5) { (try? self.harnessStatuses()) == ["124"] }, "status after the reap: \(String(describing: try? harnessStatuses()))")
    }

    /// A script that runs install.sh's bounded() and supervise() on their
    /// own (testInstallAndUninstallShareTheBoundedCallHelper keeps
    /// uninstall.sh's the same): it takes the recovery lock on fd 9, makes
    /// one bounded `sudo -n pmset -a disablesleep 0` through the fake sudo
    /// with a 3 s limit, and logs "bounded <status>". Its bounded calls
    /// keep their files in the fixture's harness.* folder.
    private func boundedHarness() throws -> URL {
        let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent("install.sh"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "\nbounded() {"))
        let supervise = try XCTUnwrap(text.range(of: "\nsupervise() {", range: start.upperBound..<text.endIndex))
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: supervise.upperBound..<text.endIndex))
        let url = fx.root.appendingPathComponent("bounded-harness.sh")
        try ("""
        set -euo pipefail
        SUDO="\(fx.bin.appendingPathComponent("sudo").path)"
        MKTEMP=/usr/bin/mktemp
        CALL_TIMEOUT_SECONDS=3
        WORK="$("$MKTEMP" -d "\(fx.root.path)/harness.XXXXXX")"
        """ + String(text[start.lowerBound..<end.upperBound]) + """
        exec 9<>"\(fx.lock.path)"
        /usr/bin/lockf -t 0 9
        rc=0
        bounded "$SUDO" -n "\(fx.fakePmset)" -a disablesleep 0 || rc=$?
        echo "bounded $rc" >> "\(fx.callsLog.path)"

        """).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The status files boundedHarness's calls have written so far.
    private func harnessStatuses() throws -> [String] {
        let fm = FileManager.default
        var statuses: [String] = []
        for dir in try fm.contentsOfDirectory(atPath: fx.root.path).filter({ $0.hasPrefix("harness.") }).sorted() {
            let folder = fx.root.appendingPathComponent(dir)
            for name in try fm.contentsOfDirectory(atPath: folder.path).filter({ $0.hasSuffix(".rc") }).sorted() {
                let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                statuses.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return statuses
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || ScriptFixture.runsAsRoot($0) }, "\(fx.calls())")
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
    // journal, through its private copy (cp -X onto a file it made, which
    // copies the data and not the ACL), and turns sleep back on. The
    // cleared journal is published from that copy: a new file, owner-only
    // like the ones the app writes, without the entry. On main, publishing
    // failed here (cp could not copy the extended attributes the entry does
    // not let the owner read), and the journal was kept for the next run.
    func testBackstopReadsAJournalOnlyAnACLMakesReadableAndPublishesItOwnerOnly() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        XCTAssertEqual(chmod(fx.state.path, 0o200), 0)
        try TestACL.grantOwnerRead(fx.state)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: fx.state.path))

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"], fx.log())
        XCTAssertFalse(fx.log().contains("unreadable or malformed"), fx.log())
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual(try fx.mode(fx.state), 0o600)
        XCTAssertEqual(TestACL.entries(fx.state), 0)
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
        let work = f.root.appendingPathComponent("record-text-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(script), encoding: .utf8)
        // It reads the file through the script's own read_whole.
        try ("set -euo pipefail\n" + Self.readLayerSource(text, script: script, work: work)
            + Self.recordTextProblemsSource(script) + "\nrecord_text_problems \"$1\"\n")
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

    /// Shell function `name` as `text` (one of the scripts) defines it:
    /// from its first line to the next line that starts with "}".
    static func shellFunction(_ name: String, in text: String, _ script: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("\(name)() {") }, "\(name) in \(script)")
        let end = try XCTUnwrap(lines[(start + 1)...].firstIndex { $0.hasPrefix("}") }, "end of \(name) in \(script)")
        return lines[start...end].joined(separator: "\n") + "\n"
    }

    /// The text from work_read to snapshot, the read layer both scripts
    /// share, as `text` has it.
    static func sharedReadLayer(in text: String, _ script: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "# Reads a file this run wrote in WORK (a call's output) into READ_TEXT byte"), script)
        let snapshot = try XCTUnwrap(text.range(of: "\nsnapshot() { # file copy\n", range: start.upperBound..<text.endIndex), script)
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: snapshot.upperBound..<text.endIndex), script)
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// A script's read layer, ready to source on its own: real tools, short
    /// limits, WORK at `work`, then the script's own bounded() with what it
    /// calls, and the shared text from work_read to snapshot.
    static func readLayerSource(_ text: String, script: String, work: URL) throws -> String {
        var source = """
        PLUTIL=/usr/bin/plutil
        DATE=/bin/date
        MKTEMP=/usr/bin/mktemp
        CAT=/bin/cat
        CP=/bin/cp
        RM=/bin/rm
        WC=/usr/bin/wc
        STAT=/usr/bin/stat
        SUDO=/usr/bin/sudo
        CALL_TIMEOUT_SECONDS=5
        READ_TIMEOUT_SECONDS=5
        KILL_GRACE_SECONDS=1
        WORK='\(work.path)'
        READ_FAILURES="$WORK/read-failures.lines"
        BOUNDED_OUTPUT=""
        BOUNDED_PID=""
        BOUNDED_BASE=""
        BOUNDED_LIMIT=""
        BOUNDED_TERM_ONLY=""
        bounded_reads=0

        """
        let own = script == "backstop.sh"
            ? ["job_running", "wait_for_job", "signal_job", "bounded", "call_result"]
            : ["bounded", "supervise", "call_result"]
        for name in own { source += try shellFunction(name, in: text, script) }
        return source + (try sharedReadLayer(in: text, script))
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
            XCTAssertFalse(f.calls().contains { ScriptFixture.runsAsRoot($0) || $0.contains("pmset") }, "\(json): \(f.calls())")
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
        XCTAssertTrue(fx.log().contains("could not publish the updated journal to \(fx.state.path); previous journal kept, will retry"), fx.log())
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
                XCTAssertTrue(log.contains("could not publish the updated journal to \(f.state.path); previous journal kept, will retry"), log)
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
    /// caller handed its lock down on fd 9 (the uninstall path, which also
    /// passes down the version it read before it took the lock), and is
    /// told to end itself after COMMAND_TIMEOUT_SECONDS +
    /// KILL_GRACE_SECONDS (1 + 1 here).
    func testAppBinaryRunsWithTheRecoveryLockOnFd9() throws {
        try Data().write(to: fx.lock)
        let lockInode = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: fx.lock.path)[.systemFileNumber] as? Int)
        let identity = try infoIdentity(fx.appInfo)
        let wrapper = fx.root.appendingPathComponent("holder-then-backstop.sh")
        try """
        #!/bin/bash
        set -eu
        export INSOMNIA_INFO_PATH="\(fx.appInfo.path)" INSOMNIA_INFO_EVIDENCE="\(identity)" INSOMNIA_INFO_VERSION=1
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

    // MARK: - Uninstall locking and interleaving

    func testUninstallRefusesWhileRecoveryLockIsHeld() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let holder = try fx.holdLock()
        defer { holder.stop() }

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 75, r.stderr)
        XCTAssertEqual(fx.calls().filter { !$0.hasPrefix("pgrep") && $0 != "sudo -v" }, [], "no recovery and no removal without the lock, only the password asked before it")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(fx.calls())")
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
        XCTAssertFalse(fx.calls().contains { ScriptFixture.runsAsRoot($0) }, "no recovery under a live app: \(fx.calls())")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(fx.calls())")
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
    /// its fd 9, as sudo does, logs every SIGTERM and SIGHUP it gets with
    /// its sender (one perl process, see signalReceiverHere) and keeps
    /// running. The test kills the backstop shell with SIGKILL while
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
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        signalGroupInTurn(shell, receiver: command)
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the backstop did not end by SIGKILL (wait status \(status))")

        XCTAssertTrue(waitUntil(15) { self.fx.calls().filter { $0 == "sudo SIGTERM" }.count == 2 },
                      "one SIGTERM from the group, one from the supervisor at the limit: \(fx.calls())")
        XCTAssertTrue(waitUntil(10) { self.statusLines() == ["alive"] }, "the supervisor reached the end of the grace: \(self.statusLines())")
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGTERM" }.count, 2, "\(fx.calls())")
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGHUP" }.count, 1, "\(fx.calls())")
        let senders = try fx.signalSenders(of: command)
        XCTAssertNotEqual(senders.parent, shell.pid, "the command's parent is the supervisor, not the killed shell")
        XCTAssertEqual(senders.term.sorted(), [getpid(), senders.parent].sorted(),
                       "one SIGTERM from this test's signal to the group, one from the supervisor (pid \(senders.parent))")
        XCTAssertEqual(senders.hup, [getpid()], "the only SIGHUP is this test's signal to the group")
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

    /// Sends SIGTERM, SIGHUP and SIGINT to the process group `shell` leads,
    /// the way launchd signals what is left of a job's group, one at a
    /// time: SIGHUP once the fake sudo's receiver `command` has logged the
    /// SIGTERM, SIGINT once it has logged the SIGHUP. The kernel keeps one
    /// sender per process: of two signals pending at once, the second is
    /// delivered with sender 0, so the receiver could not say who sent it.
    private func signalGroupInTurn(_ shell: ScriptFixture.Spawned, receiver command: pid_t) {
        XCTAssertEqual(shell.signalGroup(SIGTERM), 0, "SIGTERM")
        XCTAssertTrue(waitUntil(10) { ((try? self.fx.signalSenders(of: command))?.term.count ?? 0) >= 1 }, "the group's SIGTERM arrived")
        XCTAssertEqual(shell.signalGroup(SIGHUP), 0, "SIGHUP")
        XCTAssertTrue(waitUntil(10) { ((try? self.fx.signalSenders(of: command))?.hup.count ?? 0) >= 1 }, "the group's SIGHUP arrived")
        XCTAssertEqual(shell.signalGroup(SIGINT), 0, "SIGINT")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(fx.calls())")
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
        fx.setMode("sudo", "fail")          // pmset undo fails; `sudo -n -l` still passes
        fx.setMode("launchctl", "loaded")   // an older agent is loaded

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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
        XCTAssertTrue(r.stderr.contains("/scripts/backstop.sh --force"), "manual step named, the checkout's copy: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("not replaced"), r.stderr)
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the bundle the retained agent pins stays in place")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the staged build is discarded and nothing is set aside")
        XCTAssertTrue(r.stderr.contains("discarded"), r.stderr)
        XCTAssertTrue(try fx.lockIsFree(), "the transaction ends with the script")

        // A zip install has no scripts/ directory. The checked copy of the bundle is gone when the
        // script exits and the original was never checked in place, so the hint runs no script from
        // either; it names this installer again, which checks a new copy first.
        let prebuilt = try writePrebuiltAppAtAnAwkwardPath()
        let zip = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let stopped = try fx.run(install, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(stopped.status, 1, stopped.stderr + stopped.stdout)
        XCTAssertEqual(
            try pastedWords(of: printedCommand(in: stopped.stderr, containing: "backstop.sh")),
            ["/bin/bash", checkout.appendingPathComponent("scripts/backstop.sh").path, "--force"],
            "the manual recovery runs the checkout's backstop.sh"
        )

        fx.setMode("sudo", "ok")
        let installed = try fx.run(install, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("swift") }, "nothing is built: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("codesign --force") }, "the bundle is installed as signed: \(calls)")
        let copy = try checkedCopy(of: prebuilt)
        let verify = try XCTUnwrap(calls.firstIndex(of: "codesign --verify --strict --deep \(copy)"), "\(calls)")
        let visudo = try XCTUnwrap(calls.firstIndex { $0.hasPrefix(fx.visudoCall) }, "\(calls)")
        XCTAssertLessThan(verify, visudo, "verified before the password prompt: \(calls)")
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
    /// prompt waits (the fake sudo does it during visudo) is never copied in.
    func testInstallFromPrebuiltAppInstallsTheCopyItCheckedNotABundleSwappedDuringThePrompt() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setMode("launchctl", "loaded")
        fx.setMode("sudo", "swap-prebuilt")

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(unpacked.appendingPathComponent("install.sh"), ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(unpacked.appendingPathComponent("install.sh"), extraEnvironment: ["USER": ScriptFixture.account])

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

            let r = try fx.run(unpacked.appendingPathComponent("install.sh"), extraEnvironment: ["USER": ScriptFixture.account])

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

            let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, "\(mode): " + r.stderr + r.stdout)
            XCTAssertEqual(fx.callsBesideScratchFiles(), ["sysctl -n hw.optional.arm64"], "\(mode): nothing else ran: \(fx.calls())")
            XCTAssertTrue(r.stderr.contains("Release bundles of Insomnia run on Apple Silicon Macs only, and this Mac is not one ('sysctl -n hw.optional.arm64' gave \(read))."), r.stderr)
            XCTAssertTrue(r.stderr.contains("Build and install from a source checkout instead (README, Build from source). Nothing was changed."), r.stderr)
            XCTAssertFalse(fx.exists(fx.sudoers))
            XCTAssertFalse(fx.exists(fx.app))
        }

        fx.clearCalls()
        let built = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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
            let r = try fx.run(fx.installRedirected, ["--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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
        let flagged = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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
        let edited = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(wrapper, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.callsBesideScratchFiles()
        XCTAssertEqual(calls, ["sysctl -n hw.optional.arm64", "codesign --verify --strict --deep \(try checkedCopy(of: prebuilt))"], "nothing after the failed check: \(fx.calls())")
        XCTAssertTrue(r.stderr.contains("fails 'codesign --verify --strict --deep'"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("SHA256SUMS"), "points at the download checks: \(r.stderr)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle kept")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule, "sudoers rule kept")
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
            let r = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", bundle.path], extraEnvironment: ["USER": ScriptFixture.account])
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        let build = try XCTUnwrap(calls.firstIndex(of: "swift build -c release"), "\(calls)")
        let sign = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("codesign --force --sign - ") }, "ad-hoc, no identity in the environment: \(calls)")
        let visudo = try XCTUnwrap(calls.firstIndex { $0.hasPrefix(fx.visudoCall) }, "\(calls)")
        XCTAssertLessThan(build, sign)
        XCTAssertLessThan(sign, visudo, "built and signed before the password prompt: \(calls)")
        XCTAssertFalse(calls[sign].contains(fx.app.path), "signed in staging, not in place: \(calls[sign])")
        XCTAssertFalse(calls.contains { $0.hasPrefix("codesign --verify --strict --deep") }, "the prebuilt checks are for --app only: \(calls)")
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/MacOS/Insomnia")))
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fx.appsDir.path), ["Insomnia.app"])
    }

    func testInstallRejectsUnknownArguments() throws {
        try fx.prepareInstall()

        let r = try fx.run(fx.installRedirected, ["--bogus"], extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 2, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(r.stderr.contains("usage:"), r.stderr)

        let flagAlone = try fx.run(fx.installRedirected, ["--allow-unverified-origin"], extraEnvironment: ["USER": ScriptFixture.account])

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

        let failed = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(failed.status, 1, failed.stderr + failed.stdout)
        XCTAssertTrue(fx.exists(fx.legacyBackstop), "the previous agent still runs this copy")
        XCTAssertFalse(fx.calls().contains("backstop legacy --force"), "recovery ran the sealed copy, not the old one: \(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app), "no bundle is installed without an agent that pins it")

        fx.setMode("launchctl", "loaded")
        fx.clearCalls()
        let ok = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("codesign --verify --strict -R=\(fx.requirement) \(fx.appsDir.path)/.Insomnia.app.staging.") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the previous bundle was never touched")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the staged build is discarded")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery from a bundle the agent would refuse: \(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(fx.exists(fx.legacyBackstop))
        XCTAssertTrue(fx.exists(fx.sudoers), "the rule step comes first and is reported")
        XCTAssertTrue(r.stderr.contains("would never run backstop.sh"), r.stderr)
        XCTAssertTrue(r.stderr.contains(fx.sudoers.path), r.stderr)
    }

    /// A first install whose agent cannot load leaves what was there before:
    /// no bundle at $APP, rather than a bundle no agent pins.
    func testInstallWithNoPreviousAppLeavesNoneWhenTheAgentCannotLoad() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "bootstrap-fails")   // nothing loaded, before or after the failed bootstrap

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let pinsPrevious = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(pinsPrevious.status, 1, pinsPrevious.stderr + pinsPrevious.stdout)
        XCTAssertTrue(fx.calls().contains("codesign --verify --strict -R=\(fx.requirement) \(previous.path)"), "\(fx.calls())")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the bundle the plist pins is back")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the interrupted build left with the staging directory")
        XCTAssertTrue(pinsPrevious.stdout.contains("restored \(fx.app.path)"), pinsPrevious.stdout)

        try FileManager.default.removeItem(at: fx.root.appendingPathComponent("codesign.rejects"))
        try FileManager.default.removeItem(at: fx.app)
        try fx.writeBundle(at: previous, marker: "previous")
        try fx.writeBundle(at: fx.app, marker: "interrupted")
        let pinsCurrent = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30)
        XCTAssertTrue(r.stderr.contains("aside at \(previous.path). 'codesign --verify', which tells which of the two bundles \(fx.plist.path) pins, did not answer within 5s.\nNeither bundle was moved"), r.stderr)
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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
        let blocked = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])
        holder.stop()

        XCTAssertEqual(blocked.status, 75, blocked.stderr + blocked.stdout)
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ([setAside, dead, live, link, "Insomnia.app"] + unlike).sorted(), "nothing removed outside the lock")

        try FileManager.default.removeItem(at: fx.appsDir.appendingPathComponent(setAside))
        fx.setMode("launchctl", "loaded")
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "TMPDIR": tmp.path])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        let staging = fx.appsDir.path + "/.Insomnia.app.staging."
        XCTAssertTrue(calls.contains("mktemp"), "the sudoers candidate: \(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("mktemp -d \(staging)") && $0.hasSuffix(".XXXXXX") }, "this run's staging directory: \(calls)")
        XCTAssertTrue(calls.contains("rm -rf \(dead.path)"), "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("rm -f ") && $0.hasSuffix(" \(olderCandidate.path)") }, "\(calls)")
        XCTAssertTrue(calls.contains("rm -rf \(fx.appsDir.path)/.Insomnia.app.previous"), "\(calls)")
        XCTAssertTrue(calls.contains("rm -f \(fx.legacyBackstop.path)"), "\(calls)")
        let visudo = try XCTUnwrap(calls.first { $0.hasPrefix("\(fx.visudoCall) -cf ") }, "\(calls)")
        XCTAssertTrue(calls.contains("rm -f \(visudo.dropFirst("\(fx.visudoCall) -cf ".count))"), "the sudoers candidate, on exit: \(calls)")
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "PATH": "\(shadow.path):/usr/bin:/bin:/usr/sbin:/sbin"])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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
        let rerun = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertEqual(try String(contentsOf: setAside.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertTrue(r.stderr.contains("putting back the previous app"), r.stderr)
        XCTAssertEqual(try pastedWords(of: printedCommand(in: r.stderr, containing: "mv ")), ["mv", setAside.path, fx.app.path])
    }

    /// The rule verified before the recovery lock is gone once this run
    /// holds it, as after an uninstall.sh that took the lock first. The
    /// recovery would pass without a journal, so the run checks the rule
    /// again under the lock and stops before touching the previous pair.
    func testInstallStopsWhenTheSudoersRuleIsGoneOnceItHoldsTheLock() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-gone-under-lock")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("sudoers rule verified"), "the check before the lock passed: \(r.stdout)")
        XCTAssertTrue(r.stderr.contains("is not now that this run holds the recovery lock"), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the new build is discarded")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// The sudoers check under the lock never answers (a sudo policy or
    /// directory-service lookup that stalls). At the limit it gets SIGTERM,
    /// never SIGKILL, and stops; the run exits and lets go of the lock, so
    /// the app and the agent's backstop can take it again. Nothing was
    /// replaced or recovered.
    func testInstallStopsAndLetsGoOfTheLockWhenTheSudoersRecheckDoesNotAnswer() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-check-hangs-under-lock")

        let started = Date()
        let tmp = try fx.privateTmp()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "TMPDIR": tmp.path])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30, "one bounded check, not the fake's 60 s hang")
        XCTAssertTrue(r.stdout.contains("sudoers rule verified"), "the check before the lock passed: \(r.stdout)")
        XCTAssertTrue(r.stderr.contains("holds the recovery lock, did not answer within 5s. The check\nstopped on SIGTERM and this run exits, which lets go of the lock"), r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo FD9-OPEN"), "the check keeps the lock while it runs: \(calls)")
        XCTAssertTrue(calls.contains("sudo SIGTERM"), "\(calls)")
        XCTAssertTrue(fx.hungProcessGone("sudo", within: 0), "it stopped on SIGTERM before the run went on")
        XCTAssertNil(fx.commandEnded(), "it ended on SIGTERM, not by a release or the watchdog")
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(calls.filter { $0 == "sudo -n -l /usr/bin/pmset -a disablesleep 1" }.count, 2, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery ran: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the new build is discarded")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertEqual(try fx.contents(of: tmp), [], "the scratch directory is gone, including the stopped call's files")
    }

    /// The same check before the lock (step 2) never answers and ignores
    /// SIGTERM: the run stops there, before it asks the app to quit or
    /// touches the previous pair, and leaves the check running, reported
    /// with its pid, since sudo is never sent SIGKILL. No lock is held yet.
    func testInstallStopsWhenTheSudoersCheckBeforeTheLockDoesNotAnswer() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-check-hangs")

        let started = Date()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30)
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0))
        XCTAssertTrue(r.stderr.contains("'sudo -n -l', which checks the rule, did not answer within 5s, so the rule in \(fx.sudoers.path) is not verified. It was sent SIGTERM and is still running as pid \(pid). It is not killed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("(or stop it with 'sudo kill \(pid)')"), r.stderr)
        XCTAssertFalse(r.stdout.contains("sudoers rule verified"), r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo SIGTERM"), "\(calls)")
        XCTAssertFalse(calls.contains("sudo FD9-OPEN"), "no lock is held before step 5: \(calls)")
        XCTAssertFalse(fx.hungProcessGone("sudo", within: 2), "sudo is never sent SIGKILL")
        XCTAssertEqual(calls.filter { $0.hasPrefix("sudo -n -l") }, ["sudo -n -l /usr/bin/pmset -a disablesleep 1"], "the chain stops at the check that did not answer: \(calls)")
        // The pgrep before the sudoers step looks for a copy in another
        // account; none runs after the check, the quit step included.
        let check = try XCTUnwrap(calls.firstIndex(of: "sudo -n -l /usr/bin/pmset -a disablesleep 1"), "\(calls)")
        XCTAssertFalse(calls[check...].contains { $0.hasPrefix("pgrep") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(try fx.lockIsFree())
        fx.releaseCommand()
        XCTAssertTrue(fx.hungProcessGone("sudo"))
        XCTAssertEqual(fx.commandEnded(), "released")
    }

    /// The sudoers check before the lock never answers and ignores SIGTERM,
    /// with every poll slow (see slowPollingPath). The run still gives up on
    /// it after the 5 s limit and at least two seconds for SIGTERM, within
    /// four seconds of the limit, and leaves it running: sudo is never sent
    /// SIGKILL.
    func testInstallGivesUpOnAHungSudoOnTimeWhenEveryPollIsSlow() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-check-hangs")

        let started = Date()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "PATH": try fx.slowPollingPath()])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertGreaterThan(fx.slowPolls(), 0, "the script polled through the slow sleep")
        XCTAssertGreaterThan(elapsed, 8, "the limit, then at least two seconds after SIGTERM")
        XCTAssertLessThan(elapsed, 15, "the 5 s limit, at most four seconds more, and a few slow polls")
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0))
        XCTAssertTrue(r.stderr.contains("It was sent SIGTERM and is still running as pid \(pid). It is not killed"), r.stderr)
        XCTAssertTrue(fx.calls().contains("sudo SIGTERM"), "\(fx.calls())")
        XCTAssertFalse(fx.hungProcessGone("sudo", within: 2), "sudo is never sent SIGKILL")
        fx.releaseCommand()
        XCTAssertTrue(fx.hungProcessGone("sudo"))
    }

    /// The sudoers check under the lock never answers and ignores SIGTERM.
    /// sudo is never sent SIGKILL, so it stays, and it keeps the recovery
    /// lock until it ends, as backstop.sh does with a sudo pmset: the run
    /// exits, says which pid holds the lock and how to stop it, and the lock
    /// is free once that sudo has ended.
    func testInstallLeavesASudoersRecheckThatIgnoresSigtermHoldingTheLock() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-check-ignores-term-under-lock")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0))
        XCTAssertTrue(r.stderr.contains("did not answer within 5s. It was sent SIGTERM and is still running as pid \(pid). It is not killed, because killing sudo could leave what it runs as root behind.\nIt keeps the recovery lock until it ends"), r.stderr)
        XCTAssertTrue(r.stderr.contains("  sudo kill \(pid)\n"), r.stderr)
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
        fx.setMode("pgrep", "1\n1\nhang\n")   // not running before the sudoers step or at the quit step, then no answer

        let started = Date()
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])
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
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "TMPDIR": tmp.path])
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

        let pid = try killDuringHungBootout(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        try assertLockHeldUntilGone(pid, within: 20)
        XCTAssertTrue(fx.calls().contains("launchctl FD9-OPEN"), "\(fx.calls())")
    }

    /// The killed install above, with every poll slow (see slowPollingPath).
    /// The supervisor, alone once the run is gone, still stops the bootout
    /// and lets go of the lock within three seconds of the 5 s limit.
    func testAKilledInstallLetsGoOfTheLockOnTimeWhenEveryPollIsSlow() throws {
        try writePreviousPair()
        fx.setMode("launchctl", "bootout-hangs")

        let pid = try killDuringHungBootout(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "PATH": try fx.slowPollingPath()])

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

        let plain = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])
        XCTAssertEqual(plain.status, 0, plain.stderr + plain.stdout)
        let plainBuilds = fx.calls().filter { $0.hasPrefix("swift build") }
        XCTAssertEqual(plainBuilds, ["swift build -c release", "swift build -c release --show-bin-path"], "\(fx.calls())")
        XCTAssertFalse(plain.stdout.contains("lid simulation compiled in"), plain.stdout)

        fx.clearCalls()
        let simulated = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "INSOMNIA_LID_SIMULATION": "1"])
        XCTAssertEqual(simulated.status, 0, simulated.stderr + simulated.stdout)
        let simulatedBuilds = fx.calls().filter { $0.hasPrefix("swift build") }
        XCTAssertEqual(simulatedBuilds, [
            "swift build -c release -Xswiftc -DINSOMNIA_LID_SIMULATION",
            "swift build -c release -Xswiftc -DINSOMNIA_LID_SIMULATION --show-bin-path",
        ], "\(fx.calls())")
        XCTAssertTrue(simulated.stdout.contains("lid simulation compiled in (INSOMNIA_LID_SIMULATION=1)"), simulated.stdout)

        // Any other value is "off": the define is a deliberate opt-in.
        fx.clearCalls()
        let other = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "INSOMNIA_LID_SIMULATION": "yes"])
        XCTAssertEqual(other.status, 0, other.stderr + other.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("swift build") }.first, "swift build -c release", "\(fx.calls())")

        // A prebuilt bundle is already compiled: asking for the watcher with
        // --app is refused before anything runs, instead of installing a
        // build without it.
        fx.clearCalls()
        let prebuilt = try fx.writePrebuiltApp()
        let withApp = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": ScriptFixture.account, "INSOMNIA_LID_SIMULATION": "1"])
        XCTAssertEqual(withApp.status, 2, withApp.stderr + withApp.stdout)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(withApp.stderr.contains("INSOMNIA_LID_SIMULATION=1 applies to a source build only"), withApp.stderr)
    }

    func testInstallLeavesTrustedPlistWhenBootstrapAndReloadBothFail() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-then-lost")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted", "nothing is published without a confirmed load")
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"])
        XCTAssertTrue(r.stderr.contains("not confirmed"), r.stderr)
        XCTAssertFalse(r.stdout.contains("Installed"), r.stdout)
    }

    func testInstallRefusesWhileRecoveryLockIsHeld() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let holder = try fx.holdLock()
        defer { holder.stop() }

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 75, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery outside the lock: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(r.stderr.contains("recovery lock"), r.stderr)
    }

    func testInstallStopsWhenAppStartsAgainUnderTheLock() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        // Not running before the sudoers step or at the quit step, running
        // again under the lock.
        fx.setMode("pgrep", "1\n1\n0\n")
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery beside a running app: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("started again"), r.stderr)
    }

    /// The rule at the sudoers path is one file for the whole Mac. When it
    /// grants another account, that account's recovery agent needs it to
    /// undo a session, even after its app crashed and left no process to
    /// find, so install refuses before it changes anything and says to
    /// uninstall there first.
    func testInstallRefusesWhenTheRuleGrantsAnotherAccount() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let theirs = ScriptFixture.sudoersRule(for: "alice")
        try theirs.write(to: fx.sudoers, atomically: true, encoding: .utf8)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) grants alice, not \(ScriptFixture.account)."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Uninstall Insomnia in that account first. If that account no longer exists, remove the rule with 'sudo rm \(fx.sudoers.path)', then rerun. Nothing was changed."), r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo /bin/cat \(fx.sudoers.path)"), "the rule is read through sudo: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix(fx.visudoCall) || $0.hasPrefix("sudo insomnia-sudoers-replace") || $0.hasPrefix("sudo -n") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), theirs)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "LaunchAgent replaced")
    }

    /// `#502` at the start of a line is a user ID to sudoers, not a comment,
    /// so the same rule written for another account's uid is refused the
    /// same way.
    func testInstallRefusesWhenTheRuleGrantsAnotherUserID() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let theirs = ScriptFixture.sudoersRule(for: "#\(ScriptFixture.otherUid)")
        try theirs.write(to: fx.sudoers, atomically: true, encoding: .utf8)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) grants user ID \(ScriptFixture.otherUid), not \(ScriptFixture.account)."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed."), r.stderr)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix(fx.visudoCall) || $0.hasPrefix("sudo insomnia-sudoers-replace") || $0.hasPrefix("sudo -n") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), theirs)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary", "old bundle replaced")
    }

    /// One grant to another account among this account's lines is enough.
    /// Any user field other than this account's name or `#` and its uid is
    /// refused, including forms that name no single account (a group, a
    /// netgroup, an alias, a list, a quoted name, Defaults, an include): the
    /// new file would drop the line. A line that only continues the one
    /// above it is refused too.
    func testInstallRefusesARuleWithAnyLineNotForThisAccount() throws {
        try fx.prepareInstall()
        let me = ScriptFixture.account
        let mine = ScriptFixture.sudoersRule(for: me)
        let other = ScriptFixture.otherUid
        for (extra, expected) in [
            ("bob ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "grants bob, not \(me)."),
            ("#\(other) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "grants user ID \(other), not \(me)."),
            ("#-1 ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): #-1 ALL="),
            ("%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): %admin ALL="),
            ("%#20 ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): %#20 ALL="),
            ("+staff ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): +staff ALL="),
            ("SLEEPERS ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): SLEEPERS ALL="),
            ("User_Alias SLEEPERS = bob", "has a line that is not for \(me): User_Alias SLEEPERS"),
            ("\"\(me)\" ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): \"\(me)\" ALL="),
            ("\(me),bob ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): \(me),bob ALL="),
            ("\(me) , bob ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): \(me) , bob ALL="),
            ("Defaults:bob !authenticate", "has a line that is not for \(me): Defaults:bob"),
            ("ALL ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0", "has a line that is not for \(me): ALL ALL="),
            ("#include /private/etc/sudoers.d/other", "has a line that is not for \(me): #include"),
            ("#includedir /private/etc/sudoers.d/more", "has a line that is not for \(me): #includedir"),
            ("@include /private/etc/sudoers.d/other", "has a line that is not for \(me): @include"),
            ("\(me) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, \\\n    /usr/bin/pmset -g", "has a line that is not for \(me): /usr/bin/pmset -g"),
        ] {
            try FileManager.default.createDirectory(at: fx.sudoers.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rule = mine + "  " + extra + "\n"
            try rule.write(to: fx.sudoers, atomically: true, encoding: .utf8)
            fx.clearCalls()

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, extra + ": " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) \(expected)"), extra + ": " + r.stderr)
            XCTAssertTrue(r.stderr.contains("Nothing was changed."), r.stderr)
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix(fx.visudoCall) || $0.hasPrefix("sudo insomnia-sudoers-replace") }, "\(fx.calls())")
            XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), rule)
        }
    }

    /// The check goes by the account a line names, not by its commands, so
    /// this account's own rule from any version of install.sh (here three
    /// grants under another comment, as a later rule might be) is replaced.
    /// A grant to `#` and this account's uid is its own too, and a `#` that
    /// is not followed by a digit still starts a comment.
    func testInstallReplacesThisAccountsOwnRuleWhateverItsCommands() throws {
        try fx.prepareInstall()
        let account = ScriptFixture.account
        let older = """
        # Installed by Insomnia install.sh. Three commands.
        #
        #--- 502 is not a user ID here
        \(account) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
        \(account)\tALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
          #\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0

        """
        try FileManager.default.createDirectory(at: fx.sudoers.deletingLastPathComponent(), withIntermediateDirectories: true)
        try older.write(to: fx.sudoers, atomically: true, encoding: .utf8)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo /bin/cat \(fx.sudoers.path)"), "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertTrue(r.stdout.contains("==> Installed"), r.stdout)
    }

    /// A rule that cannot be read through sudo is not replaced unseen.
    func testInstallStopsWhenTheRuleCannotBeReadThroughSudo() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        try fx.prepareInstall()
        try fx.installMachinery()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.sudoers.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.sudoers.path) }

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Could not read \(fx.sudoers.path) through sudo, so it was not replaced. Nothing was changed."), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix(fx.visudoCall) || $0.hasPrefix("sudo insomnia-sudoers-replace") }, "\(fx.calls())")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.sudoers.path)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
    }

    /// The rule is written in one sudo call that, under a lock only root can
    /// take, checks the rule is still what this run read, stages the new one
    /// beside it as root's with mode 0440, has visudo check that copy, and
    /// renames it over the rule. A fresh install expects no rule; a rerun
    /// expects the bytes it read.
    func testInstallWritesTheRuleInOneLockedCompareAndRename() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        // No rule was read, so none is handed to root: an empty last argument.
        XCTAssertEqual(calls.filter { $0.hasPrefix("sudo insomnia-sudoers-replace") }, ["sudo insomnia-sudoers-replace absent \(fx.sudoers.path) "], "\(calls)")
        let staged = try XCTUnwrap(calls.first { $0.hasPrefix("chown root:wheel \(fx.sudoers.path).") }, "staged beside the rule as root's: \(calls)")
        let stagedPath = String(staged.dropFirst("chown root:wheel ".count))
        XCTAssertTrue(calls.contains("visudo -cf \(stagedPath)"), "the copy beside the rule is checked: \(calls)")
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: staged)), try XCTUnwrap(calls.firstIndex(of: "visudo -cf \(stagedPath)")))
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try fx.mode(fx.sudoers), 0o440)
        XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction, "no staged copy left")
        XCTAssertEqual(try fx.mode(fx.sudoersLock), 0o600, "the lock is root's alone")
        let lockInode = try fx.inode(fx.sudoersLock)
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo REFUSED") }, "\(calls)")

        fx.clearCalls()
        let again = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(again.status, 0, again.stderr + again.stdout)
        // The text read is handed to root, which compares it with what it
        // reads through the descriptor it opened; no copy of it is a file.
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("sudo insomnia-sudoers-replace") },
                       ["sudo insomnia-sudoers-replace same \(fx.sudoers.path) \(ScriptFixture.loggedRuleText(fx.sudoersRule))"], "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try fx.inode(fx.sudoersLock), lockInode, "the same lock file, neither removed nor replaced")
        XCTAssertEqual(try fx.mode(fx.sudoersLock), 0o600)
    }

    /// Two accounts install at once, each from its own home with its own
    /// recovery lock, and both read the rule as absent. This account's
    /// write waits (the fake sudo's gate) until the other account's install
    /// has written its rule. It then finds a rule where it read none, so it
    /// keeps the other account's rule and stops with nothing changed. A
    /// rerun refuses that rule the way any install in this account does.
    func testInstallKeepsARuleAnotherAccountWroteAfterItsRead() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        let bob = try fx.otherHomeInstall("bob")
        let gate = fx.root.appendingPathComponent("gate")
        try "".write(to: gate, atomically: true, encoding: .utf8)

        let mine = try fx.start(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "FAKE_SUDO_GATE": gate.path])
        let waiting = fx.waitForFile(gate.appendingPathExtension("waiting"), within: 60)
        var theirs: (status: Int32, stdout: String, stderr: String)?
        if waiting {
            theirs = try fx.run(bob.script, extraEnvironment: ["USER": "bob", "INSOMNIA_HOME": bob.home.path])
        }
        try FileManager.default.removeItem(at: gate)
        let r = mine.finish()

        XCTAssertTrue(waiting, "this account's install never reached its write: \(fx.calls())")
        let b = try XCTUnwrap(theirs)
        XCTAssertEqual(b.status, 0, b.stderr + b.stdout)
        XCTAssertTrue(fx.exists(bob.app.appendingPathComponent("Contents/MacOS/Insomnia")), "the other account's install finished")
        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) changed after this install read it, or could not be shown to be a regular file of root's with one link that only root can change (see any line above). Another install.sh or uninstall.sh, perhaps in another account, may have written or removed it meanwhile. It was not replaced, so no rule written meanwhile was overwritten. Rerun to check it again. The app and the LaunchAgent were not touched."), r.stderr)
        let rule = ScriptFixture.sudoersRule(for: "bob")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), rule, "the other account's rule stays")
        XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("sudo GATED insomnia-sudoers-replace"), "\(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("sudo insomnia-sudoers-replace absent \(fx.sudoers.path) ") }.count, 2, "both read no rule: \(calls)")
        XCTAssertFalse(fx.exists(fx.app), "this account's app was installed")
        XCTAssertFalse(fx.exists(fx.plist), "this account's LaunchAgent was installed")
        XCTAssertEqual(try fx.mode(fx.sudoersLock), 0o600)

        let rerun = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(rerun.status, 1, rerun.stderr + rerun.stdout)
        XCTAssertTrue(rerun.stderr.contains("\(fx.sudoers.path) grants bob, not \(ScriptFixture.account)."), rerun.stderr)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), rule)
    }

    /// Another run holds the sudoers lock past the lock timeout: the rule is
    /// not replaced and nothing else is changed.
    func testInstallStopsWhileAnotherRunHoldsTheSudoersLock() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("launchctl", "loaded")
        try fx.prepareSudoersLock()
        let holder = try fx.holdLock(fx.sudoersLock)
        defer { holder.stop() }

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) was not replaced: \(fx.sudoersLock.path) stayed taken for 1s, so another install.sh or uninstall.sh, perhaps in another account, is changing it. Rerun in a moment. The app and the LaunchAgent were not touched."), r.stderr)
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("sudo insomnia-sudoers-replace same ") }, "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
    }

    /// The new rule passes visudo where install.sh wrote it but its copy
    /// beside the rule does not: the rule stays as it was, and the copy is
    /// removed.
    func testInstallKeepsTheRuleWhenItsCopyBesideItFailsVisudo() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("launchctl", "loaded")
        fx.setMode("visudo", "reject-staged")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("The new rule failed visudo's check once copied beside \(fx.sudoers.path), so \(fx.sudoers.path) was not replaced. The app and the LaunchAgent were not touched."), r.stderr)
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("visudo REJECTED \(fx.sudoers.path).") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction, "the rejected copy is removed")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
    }

    /// The rename over the rule fails: the rule stays as it was, and the
    /// staged copy is removed.
    func testInstallKeepsTheRuleWhenTheRenameOverItFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("launchctl", "loaded")
        try fx.failMoves([(from: "\(fx.sudoers.path).*", to: fx.sudoers.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) was not replaced: copying the new rule beside it, or renaming the copy into place, failed (see the error above). The app and the LaunchAgent were not touched."), r.stderr)
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("mv FAILED \(fx.sudoers.path).") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction, "the staged copy is removed")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
    }

    /// install.sh and uninstall.sh take the same lock around each change of
    /// the rule: a dotted name (which sudo's @includedir skips) in the
    /// rule's own folder, /private/etc/sudoers.d, which only root can
    /// write. The root-side checks of the lock, the folders, the access
    /// control lists and the rule, and the function that builds root's
    /// text, are one text in both scripts, so neither can trust a lock or
    /// rule the other refuses, and ROOT_UID (patched only by the tests) is
    /// root's. Both list access control lists with /bin/ls.
    func testInstallAndUninstallTakeTheSameRootOnlySudoersLock() throws {
        var helpers: [String: [String]] = [:]
        for name in ["install.sh", "uninstall.sh"] {
            let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(name), encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(lines.filter { $0.hasPrefix("SUDOERS_LOCK=") }, ["SUDOERS_LOCK=/private/etc/sudoers.d/.insomnia-sudoers.lock"], name)
            XCTAssertEqual(lines.filter { $0.hasPrefix("SUDOERS=") }, ["SUDOERS=/etc/sudoers.d/insomnia"], name)
            XCTAssertEqual(lines.filter { $0.hasPrefix("ROOT_UID=") }, ["ROOT_UID=0"], name)
            XCTAssertEqual(lines.filter { $0 == "  umask 077" }.count, 1, name)
            XCTAssertEqual(lines.filter { $0.hasPrefix("LS=") }, ["LS=/bin/ls"], name)
            for function in ["sudoers_file_problem", "sudoers_acl_check", "sudoers_dirs_check", "sudoers_guard_take",
                             "sudoers_read_rule", "sudoers_pin_rule", "sudoers_recheck", "root_functions"] {
                let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("\(function)() {") }, "\(name): \(function)")
                let end = try XCTUnwrap(lines[start...].firstIndex(of: "}"), "\(name): \(function)")
                helpers[name, default: []] += lines[start...end]
            }
            // Nothing in either script removes, replaces or repairs the lock.
            let touchesLock = lines.filter { line in
                line.contains("SUDOERS_LOCK") && ["\"$RM\"", "\"$MV\"", "\"$CHMOD\"", "\"$CHOWN\"", "unlink", "rm -"].contains { line.contains($0) }
            }
            XCTAssertEqual(touchesLock, [], name)
        }
        XCTAssertEqual(helpers["install.sh"], helpers["uninstall.sh"], "the root-side checks differ between the scripts")
        XCTAssertGreaterThan(helpers["install.sh"]?.count ?? 0, 150)
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

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

    /// The password prompt (visudo + install of the sudoers rule) comes
    /// before the running app is asked to quit and before the bundle, the
    /// installed backstop.sh or the LaunchAgent are touched: a failed or
    /// refused authentication leaves the previous install exactly as it was
    /// and the app running.
    func testInstallStopsBeforeQuittingOrReplacingAnythingWhenSudoAuthFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n")          // the app is running the whole time
        fx.setMode("sudo", "auth-fail")     // wrong password / no sudo rights

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "the app was asked to quit before authentication: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo insomnia-sudoers-replace") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule, "sudoers rule replaced")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
    }

    /// Authentication passes but the rule it installed does not grant the
    /// pmset commands: still nothing of the previous install is replaced.
    func testInstallStopsBeforeReplacingAnythingWhenSudoersRuleIsNotEffective() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n")
        fx.setMode("sudo", "rule-not-effective")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
        XCTAssertTrue(r.stderr.contains("still not permitted"), r.stderr)
    }

    /// With no app running there is nothing to wait for: an installer that
    /// assembled the bundle and copied backstop.sh before asking for the
    /// password would reach the overwrite path here. Authentication must
    /// still be the first thing attempted, and its failure must leave the
    /// old bundle, helper and plist byte for byte as they were.
    func testInstallWithNoAppRunningStopsBeforeReplacingAnythingWhenSudoAuthFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        // pgrep default: not running at any check
        fx.setMode("sudo", "auth-fail")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix(fx.visudoCall) }, "authentication was attempted: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo insomnia-sudoers-replace") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "nothing to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule, "sudoers rule replaced")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
    }

    /// Same with the app not running: authentication passes and the rule is
    /// installed, but it does not grant pmset. The bundle, helper and plist
    /// are still untouched.
    func testInstallWithNoAppRunningStopsBeforeReplacingAnythingWhenSudoersRuleIsNotEffective() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        // pgrep default: not running at any check
        fx.setMode("sudo", "rule-not-effective")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix(fx.visudoCall) }, "authentication was attempted: \(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("sudo insomnia-sudoers-replace") }, "the rule was installed before being checked: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "nothing to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertTrue(try String(contentsOf: fx.sudoers, encoding: .utf8).contains("NOPASSWD: /usr/bin/pmset"), "the new rule is what was installed")
        XCTAssertTrue(r.stderr.contains("still not permitted"), r.stderr)
    }

    /// The sudoers rule is installed before the app is asked to quit. When
    /// the app then keeps running, the refusal must say so: the rule is in
    /// place, and only the bundle, backstop.sh and LaunchAgent are untouched.
    func testInstallRefusalWhenAppKeepsRunningReportsSudoersInstalled() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try "old helper".write(to: fx.installedBackstop, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n")          // running, and it stays running

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("sudo insomnia-sudoers-replace") }, "\(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("osascript") }, "the app was asked to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("pkill") }, "a refused quit stands: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertTrue(try String(contentsOf: fx.sudoers, encoding: .utf8).contains("NOPASSWD: /usr/bin/pmset"), "the rule was installed")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
        XCTAssertFalse(r.stderr.contains("Nothing was changed"), "the sudoers rule was changed: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains(fx.sudoers.path), "says what was installed: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("not touched"), "says what was not: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("still running"), r.stderr)
    }

    // MARK: - Process identity (install.sh and uninstall.sh)

    /// The Insomnia API client's executable is also named Insomnia, so
    /// `pgrep -x Insomnia` finds it. It is not this app: it is neither the
    /// installed bundle's binary nor in a bundle with this app's bundle id,
    /// so it must not be asked to quit and must not block the install.
    func testInstallIgnoresAForeignProcessNamedInsomnia() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded")
        let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        fx.setMode("pgrep", "0\n")                 // a process named Insomnia the whole time
        try fx.psComm([(4242, client.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("ps -o comm= -p 4242"), "the pid is identified, not just counted: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "another app must not be told to quit: \(calls)")
        XCTAssertTrue(r.stdout.contains("pid 4242"), "says which process was found: \(r.stdout)")
        XCTAssertTrue(r.stdout.contains(client.path), r.stdout)
        XCTAssertTrue(r.stdout.contains("com.insomnia.app"), r.stdout)
        XCTAssertTrue(r.stdout.contains("not this app"), r.stdout)
        XCTAssertTrue(r.stdout.contains("Installed"), r.stdout)
        XCTAssertTrue(fx.exists(fx.plist))
        let clientPlist = client.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist").path
        XCTAssertEqual(fx.plistReads().filter { $0 == clientPlist }.count, 1, "read once before the lock and reused under it: \(fx.plistReads())")
    }

    /// Under the recovery lock install.sh reads no Info.plist: one on a
    /// stalled volume would hold the lock, and install.sh has no time limit
    /// for a call. A process first seen there counts as unverified, even
    /// one whose bundle id would have shown another app, and stops the
    /// install before the LaunchAgent is touched.
    func testInstallReadsNoInfoPlistUnderTheRecoveryLock() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        fx.setMode("launchctl", "loaded")
        let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        let clientPlist = client.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist").path
        // Not running before the sudoers step or at the quit step, running
        // under the lock.
        fx.setMode("pgrep", "1\n1\n0\n")
        try fx.psComm([(4242, client.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Insomnia started again (pid 4242 (\(client.path); first seen under the recovery lock, where no Info.plist is read))"), r.stderr)
        XCTAssertFalse(fx.plistReads().contains(clientPlist), "\(fx.plistReads())")
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// Ids kept from before the lock belong to the processes they were read
    /// for. A process that took the API client's place (another pid at the
    /// same path, such as a copy of this app) is not taken for the client
    /// under the lock: it counts as first seen there and stops the install.
    func testInstallDoesNotCarryAnIdentityOverToANewProcessAtTheSamePath() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        fx.setMode("launchctl", "loaded")
        let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        let clientPlist = client.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist").path
        // The client before the sudoers step and at the quit step, another
        // process at its path under the lock.
        fx.setMode("pgrep", "pids:4242\npids:4242\npids:5151\n")
        try fx.psComm([(4242, client.path), (5151, client.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Ignoring 1 process(es) named Insomnia that are not this app: pid 4242"), r.stdout)
        XCTAssertTrue(r.stderr.contains("Insomnia started again (pid 5151 (\(client.path); first seen under the recovery lock, where no Info.plist is read))"), r.stderr)
        XCTAssertEqual(fx.plistReads().filter { $0 == clientPlist }.count, 1, "\(fx.plistReads())")
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
    }

    /// Under the recovery lock uninstall.sh reads no Info.plist either: a
    /// call made there keeps the lock until it exits (see bounded()), so a
    /// read on a stalled volume would hold the lock for CALL_TIMEOUT_SECONDS.
    /// A process first seen there counts as unverified, even a copy whose
    /// Info.plist would have shown this app, and nothing is removed.
    func testUninstallReadsNoInfoPlistUnderTheRecoveryLock() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let stalled = try fx.otherBundle(in: "Volumes/Stalled", bundleId: "com.kgarg.insomnia")
        let plist = stalled.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        try fx.hangPlutil(on: plist)
        fx.setMode("pgrep", "1\n0\n")   // not running at the quit step, then running under the lock
        try fx.pgrepPids([5151])
        try fx.psComm([(5151, stalled.path)])

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Insomnia started again (pid 5151 (\(stalled.path); first seen under the recovery lock, where no Info.plist is read))"), r.stderr)
        XCTAssertEqual(fx.plistReads(), [fx.appInfo.path], "only the installed app's, read for its InsomniaResumeFrozenVersion before the lock")
        let calls = fx.calls()
        XCTAssertFalse(calls.contains("plutil FD9-OPEN"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") || $0.hasPrefix("kill") || $0.hasPrefix("pkill") }, "\(calls)")
        XCTAssertFalse(calls.contains { ScriptFixture.runsAsRoot($0) || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// Before the lock the read is bounded like every other call: an
    /// Info.plist that never answers (a bundle on a stalled volume) is
    /// stopped after CALL_TIMEOUT_SECONDS, and the process counts as
    /// unverified until it exits. It is not asked to quit.
    func testUninstallStopsAnInfoPlistReadThatDoesNotAnswerBeforeTheLock() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let stalled = try fx.otherBundle(in: "Volumes/Stalled", bundleId: "com.kgarg.insomnia")
        let plist = stalled.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        try fx.hangPlutil(on: plist)
        fx.setMode("pgrep", "0\n1\n")   // running at the quit step, then gone
        try fx.pgrepPids([5151])
        try fx.psComm([(5151, stalled.path)])

        let started = Date()
        let r = try fx.run(fx.uninstall)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertLessThan(elapsed, 30)
        XCTAssertTrue(r.stdout.contains("Cannot tell whether 1 process(es) named Insomnia are this app, so they count as it until they exit: pid 5151 (\(stalled.path); \(plist.path) did not answer within 5s)."), r.stdout)
        XCTAssertEqual(fx.plistReads().filter { $0 == plist.path }, [plist.path], "read once, at the quit step: \(fx.plistReads())")
        XCTAssertTrue(fx.hungProcessGone("plutil"))
        let calls = fx.calls()
        XCTAssertFalse(calls.contains("plutil FD9-OPEN"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") || $0.hasPrefix("kill") || $0.hasPrefix("pkill") }, "\(calls)")
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(stalled), "the other bundle is not touched")
    }

    /// The same for uninstall: an unknown bundle id blocks, in this account
    /// as unverified and in another account as a copy there, and nothing is
    /// asked to quit or removed.
    func testUninstallRefusesWhileProcessesWithAnUnknownBundleIdRun() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let renamed = try fx.otherBundle(in: "DevBuild", bundleId: "com.example.insomnia-copy")
        fx.setMode("pgrep", "0\n")
        try fx.psComm([(4242, renamed.path)])

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("pid 4242 (\(renamed.path); bundle id com.example.insomnia-copy is neither this app's nor the Insomnia API client's)"), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("pkill") || $0.hasPrefix("kill") }, "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.plist))

        try fx.psUid([(4242, ScriptFixture.otherUid)])
        let other = try fx.run(fx.uninstall)

        XCTAssertEqual(other.status, 1, other.stderr + other.stdout)
        XCTAssertTrue(other.stderr.contains("Insomnia is running in another account"), other.stderr)
        XCTAssertTrue(other.stderr.contains("pid 4242 (uid \(ScriptFixture.otherUid), \(renamed.path); bundle id com.example.insomnia-copy is neither"), other.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("sudo") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
    }

    func testUninstallIgnoresAForeignProcessNamedInsomnia() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        fx.setMode("pgrep", "0\n")
        try fx.psComm([(4242, client.path)])

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("pkill") || $0.hasPrefix("kill") }, "\(calls)")
        XCTAssertTrue(r.stdout.contains("pid 4242"), r.stdout)
        XCTAssertTrue(r.stdout.contains(client.path), r.stdout)
        XCTAssertTrue(r.stdout.contains("not this app"), r.stdout)
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(client), "the other app's bundle is not touched")
    }

    /// A copy of this app running from somewhere else (a development build
    /// with the same bundle id) shares the journal and the lock, so it is
    /// asked to quit and blocks the install like the installed copy does.
    func testInstallQuitsACopyWithThisBundleIdAtAnotherPath() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let dev = try fx.otherBundle(in: "DevBuild", bundleId: "com.kgarg.insomnia")
        fx.setMode("pgrep", "0\n")                 // running, and it stays running
        try fx.psComm([(4242, dev.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("pkill") }, "\(calls)")
        XCTAssertTrue(r.stderr.contains("still running"), r.stderr)
        XCTAssertTrue(r.stderr.contains("pid 4242"), "the refusal names the process: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains(dev.path), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary", "old bundle replaced")
    }

    /// Both kinds at once: the API client is ignored, the installed copy is
    /// what the refusal names, with its pid and executable path.
    func testUninstallRefusalNamesTheRunningCopyAndIgnoresTheOther() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        fx.setMode("pgrep", "0\n")
        try fx.pgrepPids([4242, 5151])
        try fx.psComm([(4242, client.path), (5151, fx.installedExecutable.path)])

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("osascript") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertTrue(r.stdout.contains("pid 4242"), "the ignored process is reported: \(r.stdout)")
        XCTAssertTrue(r.stdout.contains(client.path), r.stdout)
        XCTAssertTrue(r.stderr.contains("refusing to quit"), r.stderr)
        XCTAssertTrue(r.stderr.contains("pid 5151"), "the refusal names the process: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains(fx.installedExecutable.path), r.stderr)
        XCTAssertFalse(r.stderr.contains("pid 4242"), "the refusal is not about the other app: \(r.stderr)")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    /// A pid pgrep reported but ps cannot describe, or whose executable is
    /// not inside any bundle, might be this app. It is never signalled, but
    /// nothing is removed while it runs, and the refusal says why.
    func testProcessWithoutAnIdentifiablePathBlocksUninstall() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "0\n")
        try fx.pgrepPids([4242, 5151])
        try fx.psComm([(5151, "./Insomnia")])      // 4242 has no row: ps could not describe it
        try fx.psUid([(4242, Int(getuid()))])      // but it reads as this account's

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("pkill") || $0.hasPrefix("kill") }, "\(fx.calls())")
        XCTAssertTrue(r.stdout.contains("Cannot tell whether 2 process(es) named Insomnia are this app"), r.stdout)
        XCTAssertTrue(r.stderr.contains("pid 4242 (executable path unknown)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("pid 5151 (./Insomnia; not inside an app bundle"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was removed"), r.stderr)
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertTrue(fx.exists(fx.sudoers))
    }

    /// A development copy whose Info.plist no longer parses while it runs:
    /// its bundle id cannot be read, so it is not proven to be another app.
    /// It may be another account's copy of this app, whose grant the new
    /// rule would take away, so the installer lists the processes again for
    /// QUIT_WAIT_SECONDS and then refuses before its first sudo call (the
    /// password prompt), naming the plist. Nothing is changed.
    func testInstallRefusesWhileACopyWithAnUnreadableInfoPlistRuns() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let dev = try fx.otherBundle(in: "DevBuild", bundleId: "com.kgarg.insomnia")
        let plist = dev.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        try "not a plist".write(to: plist, atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n")                 // running, and it stays running
        try fx.psComm([(4242, dev.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("osascript") || $0.hasPrefix("pkill") || $0.hasPrefix("kill") }, "\(calls)")
        XCTAssertEqual(calls.filter { $0.hasPrefix("pgrep") }.count, 2, "listed again before refusing: \(calls)")
        XCTAssertTrue(r.stderr.contains("Cannot tell whether 1 process(es) named Insomnia are this app, and they were still running after 1s: pid 4242 (\(dev.path); no bundle id readable from \(plist.path))."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was asked to quit. Quit them, or wait for them to exit, then rerun. Nothing was changed."), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "LaunchAgent replaced")
    }

    /// Only the API client's bundle id proves a process is another app. A
    /// copy of this app whose Info.plist declares some other id would still
    /// use this account's journal, so it blocks like an unreadable one and
    /// is never asked to quit: the install refuses before its first sudo.
    func testInstallRefusesWhileAProcessWithAnUnknownBundleIdRuns() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let renamed = try fx.otherBundle(in: "DevBuild", bundleId: "com.example.insomnia-copy")
        fx.setMode("pgrep", "0\n")                 // running, and it stays running
        try fx.psComm([(4242, renamed.path)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") || $0.hasPrefix("osascript") || $0.hasPrefix("pkill") }, "\(fx.calls())")
        XCTAssertFalse(r.stdout.contains("Ignoring"), r.stdout)
        XCTAssertTrue(r.stderr.contains("Cannot tell whether 1 process(es) named Insomnia are this app, and they were still running after 1s"), r.stderr)
        XCTAssertTrue(r.stderr.contains("pid 4242 (\(renamed.path); bundle id com.example.insomnia-copy is neither this app's nor the Insomnia API client's)"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed."), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "LaunchAgent replaced")
    }

    /// An unverified process alone is waited for but never causes a quit
    /// request: osascript would reach the real app by bundle id. Here it
    /// first shows up at the quit step (one listed before the sudoers step
    /// would stop the install there), exits during the wait, and the
    /// install goes on.
    func testInstallSendsNoQuitWhenOnlyAnUnverifiedProcessRuns() throws {
        try fx.prepareInstall()
        fx.setMode("launchctl", "loaded")
        // Not seen before the sudoers step, seen at the quit step, gone on
        // the next look.
        fx.setMode("pgrep", "1\n0\n1\n")
        try fx.psComm([(4242, "./Insomnia")])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Cannot tell whether 1 process(es) named Insomnia are this app"), r.stdout)
        XCTAssertFalse(r.stdout.contains("quitting it first"), r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") }, "a quit was sent for a process that is not known to be this app: \(fx.calls())")
        XCTAssertTrue(r.stdout.contains("==> Installed"), r.stdout)
    }

    /// The same for uninstall: waited for, no quit request, and once it is
    /// gone the uninstall goes on.
    func testUninstallSendsNoQuitWhenOnlyAnUnverifiedProcessRuns() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "0\n1\n")
        try fx.psComm([(4242, "./Insomnia")])

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Cannot tell whether 1 process(es) named Insomnia are this app"), r.stdout)
        XCTAssertFalse(r.stdout.contains("asking it to quit"), r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") }, "a quit was sent for a process that is not known to be this app: \(fx.calls())")
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// The same copy during an uninstall: the API client beside it, with a
    /// readable bundle id, is still ignored; the unverified copy blocks.
    func testUninstallRefusesWhileACopyWithAnUnreadableInfoPlistRunsAndStillIgnoresTheClient() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        let dev = try fx.otherBundle(in: "DevBuild", bundleId: "com.kgarg.insomnia")
        try "".write(to: dev.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        fx.setMode("pgrep", "0\n")
        try fx.pgrepPids([4242, 5151])
        try fx.psComm([(4242, client.path), (5151, dev.path)])

        let r = try fx.run(fx.uninstall)

        XCTAssertNotEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Ignoring 1 process(es) named Insomnia that are not this app: pid 4242 (\(client.path), bundle id com.insomnia.app)"), r.stdout)
        XCTAssertTrue(r.stdout.contains("Cannot tell whether 1 process(es) named Insomnia are this app"), r.stdout)
        XCTAssertTrue(r.stderr.contains("pid 5151 (\(dev.path); no bundle id readable from"), r.stderr)
        XCTAssertFalse(r.stderr.contains("pid 4242"), "the identified client must not be listed as blocking: \(r.stderr)")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.plist))
    }
    // MARK: - Another account (install.sh and uninstall.sh)

    /// A copy of this app in another account, and a process there named
    /// Insomnia that cannot be identified: the sudoers rule is one file for
    /// the whole Mac and that copy may need it, so uninstall stops before
    /// anything is removed. Neither process is asked to quit or signalled;
    /// a quit request by bundle id could only reach this account's copy.
    func testUninstallStopsForInsomniaInAnotherAccountAndNeverSignalsIt() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let theirs = try fx.otherBundle(in: "OtherAccount", bundleId: "com.kgarg.insomnia")
        fx.setMode("pgrep", "0\n")
        try fx.pgrepPids([4242, 5151])
        try fx.psComm([(4242, theirs.path), (5151, "./Insomnia")])
        try fx.psUid([(4242, ScriptFixture.otherUid), (5151, ScriptFixture.otherUid)])

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("ps -o uid= -p 4242"), "the owner is read: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "no quit request: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("pkill") || $0.hasPrefix("kill") }, "no signal: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("launchctl") }, "nothing undone or removed: \(calls)")
        XCTAssertTrue(r.stderr.contains("Insomnia is running in another account"), r.stderr)
        XCTAssertTrue(r.stderr.contains("pid 4242 (uid \(ScriptFixture.otherUid), \(theirs.path))"), r.stderr)
        XCTAssertTrue(r.stderr.contains("pid 5151 (uid \(ScriptFixture.otherUid), ./Insomnia; not inside an app bundle"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not asked to quit"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was removed"), r.stderr)
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
    }

    /// The same copy during an install: it stops before the sudoers step,
    /// so the rule that copy may need is never replaced, and this
    /// account's running copy is not asked to quit either.
    func testInstallStopsBeforeTheSudoersStepForInsomniaInAnotherAccount() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let theirs = try fx.otherBundle(in: "OtherAccount", bundleId: "com.kgarg.insomnia")
        fx.setMode("pgrep", "0\n")
        try fx.pgrepPids([4242, 5151])
        try fx.psComm([(4242, theirs.path), (5151, fx.installedExecutable.path)])
        try fx.psUid([(4242, ScriptFixture.otherUid)])

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") }, "the rule is not replaced: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") || $0.hasPrefix("pkill") || $0.hasPrefix("kill") }, "\(calls)")
        XCTAssertTrue(r.stderr.contains("pid 4242 (uid \(ScriptFixture.otherUid), \(theirs.path))"), r.stderr)
        XCTAssertFalse(r.stderr.contains("pid 5151"), "this account's copy is not the reason: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "LaunchAgent replaced")
    }

    /// A pgrep that fails (exit 3, a fatal error) lists nothing, which does
    /// not show that no copy runs in another account: the install stops
    /// before its first sudo call, with nothing changed.
    func testInstallStopsBeforeTheSudoersStepWhenPgrepFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("pgrep", "3\n")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("pgrep exited 3, so whether Insomnia runs in this or another account is unknown. Rerun once it answers. Nothing was changed."), r.stderr)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "LaunchAgent replaced")
    }

    /// The same at uninstall's quit step: nothing is asked to quit or
    /// removed.
    func testUninstallStopsWhenPgrepFails() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("pgrep", "3\n")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("pgrep exited 3, so whether Insomnia runs in this or another account is unknown. Rerun once it answers. Nothing was removed."), r.stderr)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.plist))
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// The API client in another account is still another app: it is
    /// reported and ignored, and the uninstall goes on.
    func testUninstallIgnoresAnotherAppInAnotherAccount() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        fx.setMode("pgrep", "0\n")
        try fx.psComm([(4242, client.path)])
        try fx.psUid([(4242, ScriptFixture.otherUid)])

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") }, "\(fx.calls())")
        XCTAssertTrue(r.stdout.contains("pid 4242 (\(client.path), bundle id com.insomnia.app)"), r.stdout)
        XCTAssertFalse(r.stderr.contains("another account"), r.stderr)
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.sudoers))
    }

    // MARK: - Shared sudoers rule (uninstall.sh)

    /// The rule this account's install wrote is read through sudo, matched
    /// line by line, and then removed.
    func testUninstallReadsTheRuleBackAndRemovesItWhenThisAccountsInstallWroteIt() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let sudo = fx.calls().filter { $0.hasPrefix("sudo") }
        // The password before the lock; then, under it, only `sudo -n`: the
        // read, and the removal of exactly the text read (handed to root as
        // an argument, logged with "\n" for each newline).
        XCTAssertEqual(sudo, [
            "sudo -v",
            "sudo -n /bin/cat \(fx.sudoers.path)",
            "sudo -n insomnia-sudoers-remove \(fx.sudoers.path) \(ScriptFixture.loggedRuleText(fx.sudoersRule))",
        ])
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertEqual(try fx.mode(fx.sudoersLock), 0o600, "the lock is root's alone, and stays")
        XCTAssertFalse((r.stdout + r.stderr).contains("Kept \(fx.sudoers.path)"), r.stdout + r.stderr)
    }

    /// Another account installed Insomnia after this one, so the shared file
    /// grants that account. Removing it would leave that account's app and
    /// agent without the grant they need to undo a session, so it is kept
    /// and the rest of the uninstall goes on.
    func testUninstallKeepsARuleThatGrantsAnotherAccount() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let theirs = ScriptFixture.sudoersRule(for: "other_\(ScriptFixture.account)")
        try theirs.write(to: fx.sudoers, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -n /bin/cat \(fx.sudoers.path)"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), theirs)
        XCTAssertTrue(r.stdout.contains("Kept \(fx.sudoers.path): it grants other_\(ScriptFixture.account), not \(ScriptFixture.account)."), r.stdout)
        XCTAssertTrue(r.stdout.contains("Uninstall Insomnia in that account"), r.stdout)
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.plist))
    }

    /// The same rule written for another account's uid (`#502`) is not this
    /// account's either, so it is kept.
    func testUninstallKeepsARuleThatGrantsAnotherUserID() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let theirs = ScriptFixture.sudoersRule(for: "#\(ScriptFixture.otherUid)")
        try theirs.write(to: fx.sudoers, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), theirs)
        XCTAssertTrue(r.stdout.contains("Kept \(fx.sudoers.path): it grants #\(ScriptFixture.otherUid), not \(ScriptFixture.account)."), r.stdout)
    }

    /// A file that is not exactly what install.sh writes for this account
    /// (an extra grant, no grant at all, a line install.sh never writes) is
    /// not Insomnia's to remove. It is kept with the reason, and the rest of
    /// the uninstall goes on.
    func testUninstallKeepsARuleThatIsNotWhatInstallWritesForThisAccount() throws {
        let me = ScriptFixture.account
        let cases: [(text: String, why: String)] = [
            (ScriptFixture.sudoersRule(for: me) + "\(me) ALL=(ALL) NOPASSWD: ALL\n",
             "it has a line install.sh does not write: \(me) ALL=(ALL) NOPASSWD: ALL"),
            ("# Installed by Insomnia install.sh. Exactly four commands, nothing else.\n", "it grants nothing"),
            ("rule", "it has a line install.sh does not write: rule"),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            try c.text.write(to: f.sudoers, atomically: true, encoding: .utf8)

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 0, c.text + r.stderr + r.stdout)
            XCTAssertFalse(f.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, c.text + "\(f.calls())")
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), c.text)
            XCTAssertTrue(r.stderr.contains("Kept \(f.sudoers.path): it is not the rule install.sh writes for \(me) (\(c.why))."), c.text + r.stderr)
            XCTAssertFalse(f.exists(f.app), c.text)
        }
    }

    /// A rule that cannot be read through sudo is neither judged nor removed:
    /// the uninstall stops with the app still installed.
    func testUninstallStopsWhenTheRuleCannotBeReadThroughSudo() throws {
        try XCTSkipIf(getuid() == 0, "root reads a mode-000 file")
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fx.sudoers.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.sudoers.path) }

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove") }, "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("Could not read \(fx.sudoers.path) through sudo ('sudo -n cat' exited 1: cat: \(fx.sudoers.path): Permission denied), so it was kept."), r.stderr)
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app), "the app stays until the rule is dealt with")
    }

    /// A later install.sh writes three commands, not four, under the same
    /// header. That rule is this account's too, and is removed.
    func testUninstallRemovesTheThreeCommandRuleOfALaterInstall() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let me = ScriptFixture.account
        let three = """
        # Installed by Insomnia install.sh. Exactly three commands, nothing else.
        \(me) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
        \(me) ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
        \(me) ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0

        """
        try three.write(to: fx.sudoers, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove \(fx.sudoers.path) ") }, "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertFalse((r.stdout + r.stderr).contains("Kept \(fx.sudoers.path)"), r.stdout + r.stderr)
    }

    /// Another account's rule replaces this account's between the uninstall's
    /// read and its removal. The removal finds other bytes than it read, so
    /// it keeps the rule and stops with the app still installed. A rerun
    /// sees the other account's rule, keeps it, and finishes.
    func testUninstallKeepsARuleWrittenAfterItsRead() throws {
        // The removal is a bounded call; the gate holds it while the test
        // writes, so its limit is longer than the gate takes.
        try fx.writeUninstallCopy(extraConstants: ["CALL_TIMEOUT_SECONDS": "60"])
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let gate = fx.root.appendingPathComponent("gate")
        try "".write(to: gate, atomically: true, encoding: .utf8)
        let theirs = ScriptFixture.sudoersRule(for: "bob")

        let run = try fx.start(fx.uninstall, extraEnvironment: ["FAKE_SUDO_GATE": gate.path])
        let waiting = fx.waitForFile(gate.appendingPathExtension("waiting"), within: 60)
        if waiting { try theirs.write(to: fx.sudoers, atomically: true, encoding: .utf8) }
        try FileManager.default.removeItem(at: gate)
        let r = run.finish()

        XCTAssertTrue(waiting, "the uninstall never reached its removal: \(fx.calls())")
        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Kept \(fx.sudoers.path): it changed after this uninstall read it, or could not be shown to be a regular file of root's with one link that only root can change (\(fx.sudoers.path) is not the text this run read). Another install.sh or uninstall.sh, perhaps in another account, may have written or removed it meanwhile, and a rule written then may be another account's."), r.stderr)
        XCTAssertTrue(r.stderr.contains("The LaunchAgent is already removed; the app at \(fx.app.path) is not. Rerun this script to check the rule again."), r.stderr)
        XCTAssertTrue(fx.calls().contains("sudo GATED insomnia-sudoers-remove"), "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), theirs)
        XCTAssertTrue(fx.exists(fx.app), "the app stays until the rule is dealt with")

        let rerun = try fx.run(fx.uninstall)

        XCTAssertEqual(rerun.status, 0, rerun.stderr + rerun.stdout)
        XCTAssertTrue(rerun.stdout.contains("Kept \(fx.sudoers.path): it grants bob, not \(ScriptFixture.account)."), rerun.stdout)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), theirs)
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// This account uninstalls while another account installs from its own
    /// home. The install reads this account's rule while the uninstall
    /// waits to remove it, refuses it, and changes nothing; the uninstall
    /// then removes its rule. The other account's rerun then installs.
    func testUninstallAndAnotherAccountsInstallNeverRemoveOrReplaceTheOthersRule() throws {
        // The removal is a bounded call; the gate holds it while the other
        // account's install runs, so its limit is longer than that takes.
        try fx.writeUninstallCopy(extraConstants: ["CALL_TIMEOUT_SECONDS": "60"])
        try fx.prepareInstall()     // what the other account's build needs
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let bob = try fx.otherHomeInstall("bob")
        let bobEnvironment = ["USER": "bob", "INSOMNIA_HOME": bob.home.path]
        let gate = fx.root.appendingPathComponent("gate")
        try "".write(to: gate, atomically: true, encoding: .utf8)

        let run = try fx.start(fx.uninstall, extraEnvironment: ["FAKE_SUDO_GATE": gate.path])
        let waiting = fx.waitForFile(gate.appendingPathExtension("waiting"), within: 60)
        var theirs: (status: Int32, stdout: String, stderr: String)?
        if waiting { theirs = try fx.run(bob.script, extraEnvironment: bobEnvironment) }
        try FileManager.default.removeItem(at: gate)
        let r = run.finish()

        XCTAssertTrue(waiting, "the uninstall never reached its removal: \(fx.calls())")
        let b = try XCTUnwrap(theirs)
        XCTAssertEqual(b.status, 1, b.stderr + b.stdout)
        XCTAssertTrue(b.stderr.contains("\(fx.sudoers.path) grants \(ScriptFixture.account), not bob."), b.stderr)
        XCTAssertTrue(b.stderr.contains("Nothing was changed."), b.stderr)
        XCTAssertFalse(fx.exists(bob.app))
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.exists(fx.sudoers), "this account's uninstall removed its own rule")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo insomnia-sudoers-replace") }, "\(fx.calls())")

        fx.setMode("launchctl", "loaded")
        let rerun = try fx.run(bob.script, extraEnvironment: bobEnvironment)

        XCTAssertEqual(rerun.status, 0, rerun.stderr + rerun.stdout)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), ScriptFixture.sudoersRule(for: "bob"))
    }

    /// Another run holds the sudoers lock past the lock timeout: the rule is
    /// kept and the uninstall stops with the app still installed. A rerun
    /// once the lock is free removes both.
    func testUninstallKeepsItsRuleWhileAnotherRunHoldsTheSudoersLock() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.prepareSudoersLock()
        let holder = try fx.holdLock(fx.sudoersLock)

        let r = try fx.run(fx.uninstall)
        holder.stop()

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Kept \(fx.sudoers.path): \(fx.sudoersLock.path) stayed taken for 1s, so another install.sh or uninstall.sh, perhaps in another account, is changing it."), r.stderr)
        XCTAssertTrue(r.stderr.contains("The LaunchAgent is already removed; the app at \(fx.app.path) is not. Rerun this script to check the rule again."), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.plist))

        let rerun = try fx.run(fx.uninstall)

        XCTAssertEqual(rerun.status, 0, rerun.stderr + rerun.stdout)
        XCTAssertFalse(fx.exists(fx.sudoers))
        XCTAssertFalse(fx.exists(fx.app))
    }

    // MARK: - The sudoers lock and rule as root finds them

    /// What lstat says about a path: kind, mode, owner, links and inode, so
    /// a test can show a file was neither changed, repaired nor replaced.
    private func lstatSummary(_ url: URL) -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return "absent" }
        return "\(info.st_mode) \(info.st_uid) \(info.st_nlink) \(info.st_ino)"
    }

    /// Runs `script` in the background and waits up to 60 s for it. A run
    /// still going then is blocked (in an open of a FIFO, say): the FIFO at
    /// `fifo` is opened for writing to let that open return, and the run is
    /// reported as blocked.
    private func runWithoutBlocking(_ f: ScriptFixture, _ script: URL, fifo: URL, extraEnvironment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String, blocked: Bool) {
        let run = try f.start(script, extraEnvironment: extraEnvironment)
        let deadline = Date().addingTimeInterval(60)
        while !run.process.hasExited && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let blocked = !run.process.hasExited
        if blocked {
            let fd = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        let r = run.finish()
        return (r.status, r.stdout, r.stderr, blocked)
    }

    /// Root takes the sudoers lock only once it is shown that only root can
    /// have made or changed it: a regular file of root's (here ROOT_UID, the
    /// test account) with mode 0600 and one link, in folders that only root
    /// can write, all the way up to /. Anything else stops the write with
    /// exit 7 before the lock file is opened, so a FIFO there never blocks
    /// the run, and nothing there is repaired, replaced or removed. The rule
    /// must be in the lock's own folder.
    func testInstallRefusesASudoersLockOnlyRootCouldNotHaveMade() throws {
        typealias Setup = (ScriptFixture) throws -> (why: String, keep: [URL])
        let cases: [(name: String, setup: Setup)] = [
            ("mode 0666", { f in
                try f.prepareSudoersLock()
                XCTAssertEqual(chmod(f.sudoersLock.path, 0o666), 0)
                return ("\(f.sudoersLock.path) has mode 0666, so someone other than root may change it", [f.sudoersLock])
            }),
            ("mode 0640", { f in
                try f.prepareSudoersLock()
                XCTAssertEqual(chmod(f.sudoersLock.path, 0o640), 0)
                return ("\(f.sudoersLock.path) has mode 640, not 600", [f.sudoersLock])
            }),
            ("symlink", { f in
                let target = f.root.appendingPathComponent("lock-target")
                XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]))
                try FileManager.default.createSymbolicLink(at: f.sudoersLock, withDestinationURL: target)
                return ("\(f.sudoersLock.path) is not a regular file (stat: 12 ", [f.sudoersLock, target])
            }),
            ("FIFO", { f in
                XCTAssertEqual(mkfifo(f.sudoersLock.path, 0o600), 0)
                return ("\(f.sudoersLock.path) is not a regular file (stat: 1 ", [f.sudoersLock])
            }),
            ("hard link", { f in
                try f.prepareSudoersLock()
                let other = f.root.appendingPathComponent("lock-link")
                XCTAssertEqual(link(f.sudoersLock.path, other.path), 0)
                return ("\(f.sudoersLock.path) has 2 links, not 1", [f.sudoersLock, other])
            }),
            ("directory", { f in
                try FileManager.default.createDirectory(at: f.sudoersLock, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return ("\(f.sudoersLock.path) is not a regular file (stat: 4 ", [f.sudoersLock])
            }),
            ("another owner", { f in
                // Root is uid 0 in this copy, so the lock (the test
                // account's) is someone else's.
                try f.writeInstallCopies(extraConstants: ["ROOT_UID": "0"])
                try f.prepareSudoersLock()
                return ("\(f.sudoersLock.path) belongs to uid \(getuid()), not root", [f.sudoersLock])
            }),
            ("folder others can write", { f in
                let folder = f.sudoersLock.deletingLastPathComponent()
                XCTAssertEqual(chmod(folder.path, 0o777), 0)
                return ("\(folder.path), a folder above \(f.sudoersLock.path), is not a folder of root's that only root can write (stat: 4 777 ", [folder])
            }),
            ("folder replaced by a symlink", { f in
                let etc = f.sudoersLock.deletingLastPathComponent().deletingLastPathComponent()
                let moved = f.root.appendingPathComponent("etc-moved")
                try FileManager.default.moveItem(at: etc, to: moved)
                try FileManager.default.createSymbolicLink(at: etc, withDestinationURL: moved)
                return ("\(etc.path), a folder above \(f.sudoersLock.path), is not a folder of root's that only root can write (stat: 12 ", [etc, moved])
            }),
            ("rule in another folder", { f in
                let rule = f.root.appendingPathComponent("etc/other.d/insomnia")
                try FileManager.default.createDirectory(at: rule.deletingLastPathComponent(), withIntermediateDirectories: true)
                try f.writeInstallCopies(extraConstants: ["SUDOERS": rule.path])
                try f.prepareSudoersLock()
                return ("\(rule.path) is not in the folder that holds \(f.sudoersLock.path)", [rule, f.sudoersLock])
            }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer {
                _ = chmod(f.sudoersLock.deletingLastPathComponent().path, 0o755)
                f.destroy()
            }
            try f.prepareInstall()
            try f.installMachinery()
            f.setMode("launchctl", "loaded")
            let (why, keep) = try c.setup(f)
            let before = keep.map(lstatSummary)
            let rule = try Data(contentsOf: f.sudoers)

            let r = try runWithoutBlocking(f, f.installRedirected, fifo: f.sudoersLock, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertFalse(r.blocked, "\(c.name): the run blocked, so the lock file was opened")
            XCTAssertEqual(r.status, 1, "\(c.name): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains(why), "\(c.name): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("was not replaced: the lock file \(f.sudoersLock.path), or a folder above it, could not be shown to be one only root can change (see the line above), so the lock that keeps two runs from writing the rule at once cannot be trusted. The app and the LaunchAgent were not touched, and nothing there was repaired"), "\(c.name): " + r.stderr)
            XCTAssertEqual(keep.map(lstatSummary), before, "\(c.name): neither changed, repaired nor replaced")
            XCTAssertEqual(try Data(contentsOf: f.sudoers), rule, c.name)
            XCTAssertFalse(try f.contents(of: f.sudoers.deletingLastPathComponent()).contains { $0.hasPrefix("insomnia.") }, "\(c.name): a staged copy was made")
            let calls = f.calls()
            XCTAssertTrue(calls.contains { $0.hasPrefix("sudo insomnia-sudoers-replace ") }, "\(c.name): \(calls)")
            XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") || $0.hasPrefix("chown") }, "\(c.name): \(calls)")
            XCTAssertEqual(try String(contentsOf: f.installedExecutable, encoding: .utf8), "binary", c.name)
            XCTAssertEqual(try String(contentsOf: f.plist, encoding: .utf8), "plist", c.name)
        }
    }

    /// The control: a lock file that is already there, a regular file of
    /// root's with mode 0600 and one link, is taken as it is. The rule is
    /// written and the lock is the same file afterwards.
    func testInstallTakesARegularSudoersLockThatIsAlreadyThereAsItIs() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("launchctl", "loaded")
        try fx.prepareSudoersLock()
        let before = lstatSummary(fx.sudoersLock)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(lstatSummary(fx.sudoersLock), before)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction)
    }

    /// uninstall.sh runs the same checks before it takes the lock: a lock
    /// file only root could not have made keeps the rule, and the app with
    /// it, and nothing there is repaired.
    func testUninstallKeepsTheRuleWhenTheSudoersLockIsNotOnlyRoots() throws {
        typealias Setup = (ScriptFixture) throws -> String
        let cases: [(name: String, setup: Setup)] = [
            ("mode 0666", { f in
                try f.prepareSudoersLock()
                XCTAssertEqual(chmod(f.sudoersLock.path, 0o666), 0)
                return "\(f.sudoersLock.path) has mode 0666, so someone other than root may change it"
            }),
            ("FIFO", { f in
                XCTAssertEqual(mkfifo(f.sudoersLock.path, 0o600), 0)
                return "\(f.sudoersLock.path) is not a regular file (stat: 1 "
            }),
            ("another owner", { f in
                try f.writeUninstallCopy(extraConstants: ["ROOT_UID": "0"])
                try f.prepareSudoersLock()
                return "\(f.sudoersLock.path) belongs to uid \(getuid()), not root"
            }),
            ("folder others can write", { f in
                XCTAssertEqual(chmod(f.sudoersLock.deletingLastPathComponent().path, 0o777), 0)
                return "a folder above \(f.sudoersLock.path), is not a folder of root's that only root can write"
            }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer {
                _ = chmod(f.sudoersLock.deletingLastPathComponent().path, 0o755)
                f.destroy()
            }
            try f.installMachinery()
            try f.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            let why = try c.setup(f)
            let before = lstatSummary(f.sudoersLock)

            let r = try runWithoutBlocking(f, f.uninstall, fifo: f.sudoersLock)

            XCTAssertFalse(r.blocked, "\(c.name): the run blocked, so the lock file was opened")
            XCTAssertEqual(r.status, 1, "\(c.name): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("Kept \(f.sudoers.path): the lock file \(f.sudoersLock.path), or a folder above it, could not be shown to be one only root can change ("), "\(c.name): " + r.stderr)
            XCTAssertTrue(r.stderr.contains(why), "\(c.name): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("Nothing there was repaired"), "\(c.name): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("The LaunchAgent is already removed; the app at \(f.app.path) is not. Rerun this script to check the rule again."), "\(c.name): " + r.stderr)
            XCTAssertEqual(lstatSummary(f.sudoersLock), before, c.name)
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule, c.name)
            XCTAssertTrue(f.exists(f.app), c.name)
            XCTAssertTrue(try f.lockIsFree(), c.name)
        }
    }

    /// Root opens the rule only once it is a regular file of root's with one
    /// link that only root can change, then reads it through the descriptor
    /// it opened. A rule that is not (one others can write, a second link,
    /// a symlink to it) is kept as it is and the install stops with nothing
    /// changed.
    func testInstallKeepsARuleOnlyRootCouldNotHaveWritten() throws {
        typealias Setup = (ScriptFixture) throws -> (why: String, keep: [URL])
        let cases: [(name: String, setup: Setup)] = [
            ("mode 0666", { f in
                XCTAssertEqual(chmod(f.sudoers.path, 0o666), 0)
                return ("\(f.sudoers.path) has mode 0666, so someone other than root may change it", [f.sudoers])
            }),
            ("hard link", { f in
                let other = f.root.appendingPathComponent("rule-link")
                XCTAssertEqual(link(f.sudoers.path, other.path), 0)
                return ("\(f.sudoers.path) has 2 links, not 1", [f.sudoers, other])
            }),
            ("symlink", { f in
                let target = f.root.appendingPathComponent("rule-target")
                try FileManager.default.moveItem(at: f.sudoers, to: target)
                try FileManager.default.createSymbolicLink(at: f.sudoers, withDestinationURL: target)
                return ("\(f.sudoers.path) is not a regular file (stat: 12 ", [f.sudoers, target])
            }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.prepareInstall()
            try f.installMachinery()
            f.setMode("launchctl", "loaded")
            let (why, keep) = try c.setup(f)
            let before = keep.map(lstatSummary)

            let r = try f.run(f.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, "\(c.name): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains(why), "\(c.name): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("\(f.sudoers.path) changed after this install read it, or could not be shown to be a regular file of root's with one link that only root can change (see any line above)."), "\(c.name): " + r.stderr)
            XCTAssertEqual(keep.map(lstatSummary), before, c.name)
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule, c.name)
            XCTAssertFalse(try f.contents(of: f.sudoers.deletingLastPathComponent()).contains { $0.hasPrefix("insomnia.") }, "\(c.name): a staged copy was made")
            XCTAssertFalse(f.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(c.name): \(f.calls())")
            XCTAssertEqual(try String(contentsOf: f.installedExecutable, encoding: .utf8), "binary", c.name)
        }
    }

    /// Between root's read of the rule and its rename, another writer that
    /// takes no lock replaces the rule (here while visudo checks the staged
    /// copy). The rename happens only while the path still names the file
    /// root opened, or, for a fresh install, while nothing is there, so the
    /// rule written meanwhile stays and the staged copy goes.
    func testInstallKeepsARuleReplacedWhileTheNewOneWasStaged() throws {
        for fresh in [false, true] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.prepareInstall()
            if fresh {
                try f.installMachinery()
                try FileManager.default.removeItem(at: f.sudoers)
            } else {
                try f.installMachinery()
            }
            f.setMode("launchctl", "loaded")
            f.setMode("visudo", "replace-rule-staged")
            let theirs = ScriptFixture.sudoersRule(for: "bob")
            try theirs.write(to: f.root.appendingPathComponent("visudo.replacement"), atomically: true, encoding: .utf8)
            let label = fresh ? "fresh" : "rerun"

            let r = try f.run(f.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, "\(label): " + r.stderr + r.stdout)
            XCTAssertTrue(f.calls().contains("visudo REPLACED-RULE"), "\(label): \(f.calls())")
            XCTAssertTrue(r.stderr.contains(fresh ? "\(f.sudoers.path) is there now" : "\(f.sudoers.path) was replaced after root read it"), "\(label): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("It was not replaced, so no rule written meanwhile was overwritten."), "\(label): " + r.stderr)
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), theirs, "\(label): the rule written meanwhile stays")
            XCTAssertEqual(try f.contents(of: f.sudoers.deletingLastPathComponent()), f.sudoersFolderAfterTransaction, "\(label): the staged copy is removed")
            XCTAssertFalse(f.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(label): \(f.calls())")
        }
    }

    /// Another writer changes the rule in place (the same file, other text)
    /// between this run's read and root's. Root compares the text it reads
    /// through its own descriptor with the text this run read and judged,
    /// so it keeps the rule. Both scripts, through the fake sudo's gate.
    func testARuleChangedInPlaceAfterItsReadIsKept() throws {
        let theirs = Data(ScriptFixture.sudoersRule(for: "bob").utf8)
        func rewriteInPlace(_ url: URL) throws {
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: theirs)
            try h.close()
        }
        // install.sh
        do {
            try fx.prepareInstall()
            try fx.installMachinery()
            fx.setMode("launchctl", "loaded")
            let inode = try fx.inode(fx.sudoers)
            let gate = fx.root.appendingPathComponent("gate")
            try "".write(to: gate, atomically: true, encoding: .utf8)

            let run = try fx.start(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account, "FAKE_SUDO_GATE": gate.path])
            let waiting = fx.waitForFile(gate.appendingPathExtension("waiting"), within: 60)
            if waiting { try rewriteInPlace(fx.sudoers) }
            try FileManager.default.removeItem(at: gate)
            let r = run.finish()

            XCTAssertTrue(waiting, "install never reached its write: \(fx.calls())")
            XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) is not the text this run read"), r.stderr)
            XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) changed after this install read it"), r.stderr)
            XCTAssertEqual(try Data(contentsOf: fx.sudoers), theirs)
            XCTAssertEqual(try fx.inode(fx.sudoers), inode)
            XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction)
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        }
        // uninstall.sh
        let f = try ScriptFixture()
        defer { f.destroy() }
        try f.writeUninstallCopy(extraConstants: ["CALL_TIMEOUT_SECONDS": "60"])
        try f.installMachinery()
        try f.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let inode = try f.inode(f.sudoers)
        let gate = f.root.appendingPathComponent("gate")
        try "".write(to: gate, atomically: true, encoding: .utf8)

        let run = try f.start(f.uninstall, extraEnvironment: ["FAKE_SUDO_GATE": gate.path])
        let waiting = f.waitForFile(gate.appendingPathExtension("waiting"), within: 60)
        if waiting { try rewriteInPlace(f.sudoers) }
        try FileManager.default.removeItem(at: gate)
        let r = run.finish()

        XCTAssertTrue(waiting, "uninstall never reached its removal: \(f.calls())")
        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Kept \(f.sudoers.path): it changed after this uninstall read it, or could not be shown to be a regular file of root's with one link that only root can change (\(f.sudoers.path) is not the text this run read)."), r.stderr)
        XCTAssertEqual(try Data(contentsOf: f.sudoers), theirs)
        XCTAssertEqual(try f.inode(f.sudoers), inode)
        XCTAssertTrue(f.exists(f.app))
    }

    /// A NUL byte in the rule: the shell's $(...) drops it, so the text this
    /// run read and judged is not the file's. Root counts the bytes it read
    /// against the file's size, finds one missing, and keeps the rule (exit
    /// 8) in both scripts.
    func testARuleWithANulByteIsKept() throws {
        var bytes = Data(ScriptFixture.sudoersRule(for: ScriptFixture.account).utf8)
        bytes.append(0)
        // install.sh
        do {
            try fx.prepareInstall()
            try fx.installMachinery()
            fx.setMode("launchctl", "loaded")
            try bytes.write(to: fx.sudoers)

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) holds a NUL byte, or changed while it was read"), r.stderr)
            XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) was not replaced: read again as root, it could not be read in full, holds a NUL byte, changed while it was read, or has a line that is not for \(ScriptFixture.account) (see any line above). Rerun to check it again. The app and the LaunchAgent were not touched."), r.stderr)
            XCTAssertEqual(try Data(contentsOf: fx.sudoers), bytes)
            XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction)
            XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
        }
        // uninstall.sh
        let f = try ScriptFixture()
        defer { f.destroy() }
        try f.installMachinery()
        try f.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try bytes.write(to: f.sudoers)

        let r = try f.run(f.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(f.calls().contains { $0.hasPrefix("sudo -n insomnia-sudoers-remove ") }, "\(f.calls())")
        XCTAssertTrue(r.stderr.contains("Kept \(f.sudoers.path): read again as root, it could not be read in full, holds a NUL byte, changed while it was read, or is not the rule install.sh writes for \(ScriptFixture.account) (\(f.sudoers.path) holds a NUL byte, or changed while it was read)."), r.stderr)
        XCTAssertEqual(try Data(contentsOf: f.sudoers), bytes)
        XCTAssertTrue(f.exists(f.app))
    }

    // MARK: - Access control lists, and root's last read of the rule

    /// A fixture with the rule installed, ready for install.sh or
    /// uninstall.sh (`install`), whose copy runs root's ls and cat through
    /// the fakes named in `fakes`.
    private func ruleFixture(install: Bool, fakes: [String] = []) throws -> ScriptFixture {
        let f = try ScriptFixture()
        let constants = Dictionary(uniqueKeysWithValues: fakes.map { ($0.uppercased(), f.bin.appendingPathComponent($0).path) })
        if install {
            try f.writeInstallCopies(extraConstants: constants)
            try f.prepareInstall()
            f.setMode("launchctl", "loaded")
        } else {
            try f.writeUninstallCopy(extraConstants: constants)
        }
        try f.installMachinery()
        if !install { try f.writeState(Self.cleanJournal) }
        return f
    }

    private func runRuleScript(_ f: ScriptFixture, install: Bool) throws -> (status: Int32, stdout: String, stderr: String) {
        install ? try f.run(f.installRedirected, extraEnvironment: ["USER": ScriptFixture.account]) : try f.run(f.uninstall)
    }

    /// What each script says when root stops with `status` 4, 7 or 8.
    private func ruleRefusal(_ f: ScriptFixture, install: Bool, status: Int) -> String {
        switch (install, status) {
        case (true, 4): return "\(f.sudoers.path) changed after this install read it, or could not be shown to be a regular file of root's with one link that only root can change (see any line above)."
        case (true, 7): return "\(f.sudoers.path) was not replaced: the lock file \(f.sudoersLock.path), or a folder above it, could not be shown to be one only root can change (see the line above)"
        case (true, _): return "\(f.sudoers.path) was not replaced: read again as root, it could not be read in full, holds a NUL byte, changed while it was read, or has a line that is not for \(ScriptFixture.account) (see any line above)."
        case (false, 4): return "Kept \(f.sudoers.path): it changed after this uninstall read it, or could not be shown to be a regular file of root's with one link that only root can change ("
        case (false, 7): return "Kept \(f.sudoers.path): the lock file \(f.sudoersLock.path), or a folder above it, could not be shown to be one only root can change ("
        default: return "Kept \(f.sudoers.path): read again as root, it could not be read in full, holds a NUL byte, changed while it was read, or is not the rule install.sh writes for \(ScriptFixture.account) ("
        }
    }

    /// Root lists, with /bin/ls, the access control lists of every folder
    /// from the rule's up to /, of the lock and of the rule, and stops at an
    /// entry that allows more than reading, whoever it names: on a folder
    /// (the rule's own, one above it, or one that reaches only the files
    /// made there later) or on the lock it exits 7, on the rule 4. Nothing
    /// is repaired: the entry stays, so does the rule with its inode, and no
    /// staged copy is left. The cases that run install.sh run uninstall.sh
    /// too.
    func testRootRefusesAnAccessControlListThatAllowsAChange() throws {
        let cases: [(name: String, target: (ScriptFixture) -> URL, entry: String, status: Int, install: Bool)] = [
            ("the rule's folder", { $0.sudoersLock.deletingLastPathComponent() }, "everyone allow add_file", 7, true),
            ("inherited only", { $0.sudoersLock.deletingLastPathComponent() }, "everyone allow write,file_inherit,only_inherit", 7, false),
            ("a folder above", { $0.sudoersLock.deletingLastPathComponent().deletingLastPathComponent() }, "everyone allow delete_child", 7, false),
            ("the lock", { $0.sudoersLock }, "everyone allow write", 7, false),
            ("the rule", { $0.sudoers }, "user:\(TestACL.owner) allow read,append", 4, true),
        ]
        for c in cases {
            for install in c.install ? [true, false] : [false] {
                let label = "\(c.name), \(install ? "install" : "uninstall")"
                let f = try ruleFixture(install: install)
                defer { f.destroy() }
                try f.prepareSudoersLock()
                let target = c.target(f)
                try TestACL.add(c.entry, to: target)
                let inode = try f.inode(f.sudoers)

                let r = try runRuleScript(f, install: install)

                XCTAssertEqual(r.status, 1, "\(label): " + r.stderr + r.stdout)
                XCTAssertTrue(r.stderr.contains("\(target.path) has an access control list entry that allows more than reading ("), "\(label): " + r.stderr)
                XCTAssertTrue(r.stderr.contains(ruleRefusal(f, install: install, status: c.status)), "\(label): " + r.stderr)
                XCTAssertEqual(TestACL.entries(target), 1, "\(label): nothing repaired")
                XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule, label)
                XCTAssertEqual(try f.inode(f.sudoers), inode, label)
                XCTAssertEqual(try f.contents(of: f.sudoers.deletingLastPathComponent()), f.sudoersFolderAfterTransaction, label)
                XCTAssertTrue(f.exists(f.app), label)
            }
        }
    }

    /// Entries that cannot change anything pass: "deny" entries on the
    /// rule's folder, the one above it, the lock and the rule, and one that
    /// lets the owner read the rule. install.sh replaces the rule and
    /// uninstall.sh removes it; the entries on the folders and the lock
    /// stay.
    func testRootAcceptsAccessControlListsThatOnlyDenyOrAllowReading() throws {
        for install in [true, false] {
            let f = try ruleFixture(install: install)
            let folder = f.sudoersLock.deletingLastPathComponent()
            let above = folder.deletingLastPathComponent()
            defer {
                for url in [f.sudoersLock, folder, above] { TestACL.clear(url) }
                f.destroy()
            }
            try f.prepareSudoersLock()
            for url in [above, folder, f.sudoersLock] { try TestACL.add("everyone deny delete", to: url) }
            try TestACL.add("everyone deny chown", to: f.sudoers)
            try TestACL.add("user:\(TestACL.owner) allow read,readattr,readextattr,readsecurity", to: f.sudoers)

            let r = try runRuleScript(f, install: install)

            XCTAssertEqual(r.status, 0, "install \(install): " + r.stderr + r.stdout)
            if install {
                XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule)
                XCTAssertEqual(try f.contents(of: folder), f.sudoersFolderAfterTransaction)
            } else {
                XCTAssertFalse(f.exists(f.sudoers))
                XCTAssertEqual(try f.contents(of: folder), [f.sudoersLock.lastPathComponent])
            }
            for url in [above, folder, f.sudoersLock] { XCTAssertEqual(TestACL.entries(url), 1, "install \(install): \(url.path)") }
        }
    }

    /// A list root cannot read in full counts as one that allows a change,
    /// through the fake ls: ls fails on the rule (4, both scripts), marks
    /// the lock "+" and prints no entry (7), or prints a line after the
    /// rule's folder that is neither a file nor an entry (7).
    func testRootStopsWhenAnAccessControlListCannotBeReadInFull() throws {
        let cases: [(file: String, target: (ScriptFixture) -> String, status: Int, install: Bool)] = [
            ("ls.fail", { $0.sudoers.path }, 4, true),
            ("ls.plus", { $0.sudoersLock.path }, 7, false),
            ("ls.extra", { $0.sudoersLock.deletingLastPathComponent().path }, 7, false),
        ]
        for c in cases {
            for install in c.install ? [true, false] : [false] {
                let label = "\(c.file), \(install ? "install" : "uninstall")"
                let f = try ruleFixture(install: install, fakes: ["ls"])
                defer { f.destroy() }
                try f.prepareSudoersLock()
                let target = c.target(f)
                try (target + "\n").write(to: f.root.appendingPathComponent(c.file), atomically: true, encoding: .utf8)

                let r = try runRuleScript(f, install: install)

                XCTAssertEqual(r.status, 1, "\(label): " + r.stderr + r.stdout)
                let why = c.file == "ls.fail"
                    ? "the access control lists of \(target) could not be read (ls exited 1: ls: \(target): Permission denied)"
                    : "could not be read in full (ls: "
                XCTAssertTrue(r.stderr.contains(why), "\(label): " + r.stderr)
                if c.file == "ls.extra" { XCTAssertTrue(r.stderr.contains("unexpected line"), "\(label): " + r.stderr) }
                XCTAssertTrue(r.stderr.contains(ruleRefusal(f, install: install, status: c.status)), "\(label): " + r.stderr)
                XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule, label)
                XCTAssertTrue(f.exists(f.app), label)
            }
        }
    }

    /// An entry that appears on the rule's folder after root's first checks
    /// and its read of the rule (the fake ls adds it on its fourth call, the
    /// first of the checks made last before the rename or removal) stops the
    /// run there, with exit 7.
    func testRootChecksAccessControlListsAgainJustBeforeItChangesTheRule() throws {
        for install in [true, false] {
            let f = try ruleFixture(install: install, fakes: ["ls"])
            defer { f.destroy() }
            try "4".write(to: f.root.appendingPathComponent("ls.acl"), atomically: true, encoding: .utf8)

            let r = try runRuleScript(f, install: install)

            XCTAssertEqual(r.status, 1, "install \(install): " + r.stderr + r.stdout)
            XCTAssertTrue(f.calls().contains("ls ADDED-ACL"), "install \(install): \(f.calls())")
            XCTAssertTrue(r.stderr.contains("\(f.sudoersLock.deletingLastPathComponent().path) has an access control list entry that allows more than reading ("), "install \(install): " + r.stderr)
            XCTAssertTrue(r.stderr.contains(ruleRefusal(f, install: install, status: 7)), "install \(install): " + r.stderr)
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule)
            XCTAssertEqual(try f.contents(of: f.sudoers.deletingLastPathComponent()), f.sudoersFolderAfterTransaction, "no staged copy left")
            XCTAssertTrue(f.exists(f.app))
        }
    }

    /// Root reads the rule twice: when it pins it, and again through a new
    /// descriptor as the last check before the rename or removal. A rule
    /// changed in place between the two (after root judged it, through the
    /// fake ls's fourth call, or, for install.sh, while visudo checks the
    /// staged copy) has other bytes the second time and is kept, with its
    /// inode. One put there by a rename is another file and is kept too.
    /// No staged copy is left.
    func testRootKeepsARuleChangedAfterItsFirstRead() throws {
        let cases: [(how: String, why: String, install: Bool)] = [
            ("ls.rewrite", "changed after root read it", true),
            ("ls.rewrite", "changed after root read it", false),
            ("visudo", "changed after root read it", true),
            ("ls.replace", "was replaced after root read it", true),
            ("ls.replace", "was replaced after root read it", false),
        ]
        for c in cases {
            let label = "\(c.how), \(c.install ? "install" : "uninstall")"
            let f = try ruleFixture(install: c.install, fakes: c.how == "visudo" ? [] : ["ls"])
            defer { f.destroy() }
            let theirs = ScriptFixture.sudoersRule(for: "bob")
            let inode = try f.inode(f.sudoers)
            if c.how == "visudo" {
                f.setMode("visudo", "rewrite-rule-staged")
                try theirs.write(to: f.root.appendingPathComponent("visudo.replacement"), atomically: true, encoding: .utf8)
            } else {
                try "4".write(to: f.root.appendingPathComponent(c.how), atomically: true, encoding: .utf8)
                try theirs.write(to: f.root.appendingPathComponent("rule.replacement"), atomically: true, encoding: .utf8)
            }

            let r = try runRuleScript(f, install: c.install)

            XCTAssertEqual(r.status, 1, "\(label): " + r.stderr + r.stdout)
            XCTAssertTrue(f.calls().contains { $0.hasSuffix("-RULE") }, "\(label): \(f.calls())")
            XCTAssertTrue(r.stderr.contains("\(f.sudoers.path) \(c.why)"), "\(label): " + r.stderr)
            XCTAssertTrue(r.stderr.contains(ruleRefusal(f, install: c.install, status: 4)), "\(label): " + r.stderr)
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), theirs, "\(label): the rule written meanwhile stays")
            if c.how != "ls.replace" { XCTAssertEqual(try f.inode(f.sudoers), inode, label) }
            XCTAssertEqual(try f.contents(of: f.sudoers.deletingLastPathComponent()), f.sudoersFolderAfterTransaction, "\(label): no staged copy left")
            if c.install {
                XCTAssertFalse(f.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl bootout") || $0.hasPrefix("launchctl bootstrap") }, "\(label): \(f.calls())")
            }
            XCTAssertTrue(f.exists(f.app), label)
        }
    }

    /// Root's cat prints every byte of the rule and then fails. This rule
    /// has no newline at its end, so the bytes printed are as many as the
    /// file's size, and only cat's exit status shows the read failed; the
    /// run stops (8) whether that is the first read or the one made last
    /// before the rename or removal. With no failure, both reads happen and
    /// the run completes.
    func testRootStopsWhenItsReadOfTheRuleFails() throws {
        let rule = Data(ScriptFixture.sudoersRule(for: ScriptFixture.account).trimmingCharacters(in: .newlines).utf8)
        for install in [true, false] {
            for failing in [0, 1, 2] {
                let label = "\(install ? "install" : "uninstall"), read \(failing)"
                let f = try ruleFixture(install: install, fakes: ["cat"])
                defer { f.destroy() }
                try rule.write(to: f.sudoers)
                if failing > 0 { try String(failing).write(to: f.root.appendingPathComponent("cat.stdin.fail"), atomically: true, encoding: .utf8) }

                let r = try runRuleScript(f, install: install)

                let reads = (try? String(contentsOf: f.root.appendingPathComponent("cat.stdin.count"), encoding: .utf8)) ?? "no read"
                if failing == 0 {
                    XCTAssertEqual(r.status, 0, "\(label): " + r.stderr + r.stdout)
                    XCTAssertEqual(reads, "2\n", label)
                    XCTAssertEqual(f.exists(f.sudoers), install, label)
                    continue
                }
                XCTAssertEqual(r.status, 1, "\(label): " + r.stderr + r.stdout)
                XCTAssertEqual(reads, "\(failing)\n", label)
                XCTAssertTrue(r.stderr.contains("\(f.sudoers.path) could not be read (cat exited 1)"), "\(label): " + r.stderr)
                XCTAssertTrue(r.stderr.contains(ruleRefusal(f, install: install, status: 8)), "\(label): " + r.stderr)
                XCTAssertEqual(try Data(contentsOf: f.sudoers), rule, label)
                XCTAssertEqual(try f.contents(of: f.sudoers.deletingLastPathComponent()), f.sudoersFolderAfterTransaction, "\(label): no staged copy left")
                XCTAssertTrue(f.exists(f.app), label)
            }
        }
    }

    /// root_functions cuts the spaces that start each line of the text a
    /// root shell runs. bash reads that text back to the same functions, so
    /// the cut changes nothing root runs, and the text is shorter.
    func testRootTextWithoutIndentationDefinesTheSameFunctions() throws {
        for (name, functions) in [
            ("install.sh", "sudoers_file_problem sudoers_acl_check sudoers_dirs_check sudoers_guard_take sudoers_read_rule sudoers_pin_rule sudoers_recheck sudoers_for_others sudoers_rule_text sudoers_replace_as_root"),
            ("uninstall.sh", "sudoers_file_problem sudoers_acl_check sudoers_dirs_check sudoers_guard_take sudoers_read_rule sudoers_pin_rule sudoers_recheck sudoers_not_ours sudoers_remove_as_root"),
        ] {
            let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(name), encoding: .utf8)
            var definitions = try Self.shellFunction("root_functions", in: text, name)
            for function in functions.split(separator: " ") {
                definitions += "\n" + (try Self.shellFunction(String(function), in: text, name))
            }
            let probe = fx.root.appendingPathComponent("root-text-\(name)")
            try """
            \(definitions)
            original="$(declare -f \(functions))"
            cut="$(root_functions \(functions))"
            back="$(/bin/bash -c 'eval "$1"; declare -f \(functions)' bash "$cut")"
            [[ "$back" == "$original" ]] || { echo "differs"; exit 1; }
            (( ${#cut} < ${#original} * 85 / 100 )) || { echo "not shorter: ${#cut} of ${#original}"; exit 1; }
            echo "same ${#original} ${#cut}"

            """.write(to: probe, atomically: true, encoding: .utf8)

            let r = try fx.runTool("/bin/bash", [probe.path])

            XCTAssertEqual(r.status, 0, "\(name): " + r.output)
            XCTAssertTrue(r.output.hasPrefix("same "), "\(name): " + r.output)
        }
    }

    /// Staging the new rule fails (here its chmod to 0440): the rule stays
    /// as it was, and the staged copy is removed when the root shell exits.
    func testInstallKeepsTheRuleWhenStagingTheNewOneFails() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("launchctl", "loaded")
        try "\(fx.sudoers.path).*".write(to: fx.root.appendingPathComponent("chmod.fail"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.chmodCalls().contains { $0.hasPrefix("chmod 0440 \(fx.sudoers.path).") }, "\(fx.chmodCalls())")
        XCTAssertTrue(r.stderr.contains("\(fx.sudoers.path) was not replaced: copying the new rule beside it, or renaming the copy into place, failed (see the error above). The app and the LaunchAgent were not touched."), r.stderr)
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        XCTAssertEqual(try fx.contents(of: fx.sudoers.deletingLastPathComponent()), fx.sudoersFolderAfterTransaction, "the staged copy is removed")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
    }

    /// The sudo call that writes the rule ends by a signal after the root
    /// shell ran (here it replaced the rule), so whether the rule was
    /// replaced is not known to the install: it stops there, says so, and
    /// leaves the app and the LaunchAgent alone.
    func testInstallStopsWhenWhetherTheRuleWasReplacedIsNotKnown() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("launchctl", "loaded")
        fx.setMode("sudo", "txn-fails-after")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo TXN-EXITED 0"), "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("The sudo call that replaces \(fx.sudoers.path) exited 143 (a signal), so whether \(fx.sudoers.path) was replaced is not known. The app (with backstop.sh) and the LaunchAgent were not touched. Check it with 'sudo cat \(fx.sudoers.path)', then rerun."), r.stderr)
        XCTAssertFalse(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
    }

    /// The mv that puts the new rule in place renames it and then ends by
    /// a signal before it can say so. A failed mv would mean the rule was
    /// not replaced; a killed one does not, so the root shell passes the
    /// signal's status on and the install says the result is not known,
    /// as for a root shell killed by a signal, instead of "not replaced".
    func testInstallReportsAnUnknownResultWhenItsRenameIsKilled() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        fx.setMode("launchctl", "loaded")
        let before = try fx.inode(fx.sudoers)
        try "\(fx.sudoers.path).*|\(fx.sudoers.path)\n".write(to: fx.root.appendingPathComponent("mv.killed"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("mv KILLED \(fx.sudoers.path).") }, "\(fx.calls())")
        XCTAssertNotEqual(try fx.inode(fx.sudoers), before, "the rename happened")
        XCTAssertTrue(r.stderr.contains("The sudo call that replaces \(fx.sudoers.path) exited 143 (a signal), so whether \(fx.sudoers.path) was replaced is not known. The app (with backstop.sh) and the LaunchAgent were not touched."), r.stderr)
        XCTAssertFalse(r.stderr.contains("was not replaced"), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.installedExecutable, encoding: .utf8), "binary")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist")
    }

    /// The rm that removes the rule removes it and then ends by a signal.
    /// That is not a failed removal: the uninstall says whether the rule
    /// was removed is not known, and keeps the app and the journal.
    func testUninstallKeepsTheAppAndJournalWhenItsRuleRemovalIsKilled() throws {
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(Self.cleanJournal)
        // This copy's RM is the logging fake, which root's shell then runs.
        try fx.writeUninstallCopy(extraConstants: ["RM": fx.bin.appendingPathComponent("rm").path])
        try fx.sudoers.path.write(to: fx.root.appendingPathComponent("rm.killed"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("rm KILLED \(fx.sudoers.path)"), "\(fx.calls())")
        XCTAssertFalse(fx.exists(fx.sudoers), "the removal happened")
        XCTAssertTrue(r.stderr.contains("The sudo call that removes \(fx.sudoers.path) exited 143 (a signal), so whether the rule was removed is not known."), r.stderr)
        XCTAssertTrue(r.stderr.contains("The LaunchAgent is already removed; the app at \(fx.app.path) and the recovery journal were kept."), r.stderr)
        XCTAssertFalse(r.stderr.contains("Kept \(fx.sudoers.path)"), r.stderr)
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.state))
        XCTAssertTrue(try fx.lockIsFree())
    }

    // MARK: - Calls made under the recovery lock, and the reads before it

    private static let cleanJournal = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
    private static let journalToUndo = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#

    /// The sudo call that removes the rule runs under the recovery lock, so
    /// it is bounded. When it does not answer it is sent SIGTERM, and
    /// whether it removed the rule is not known, whether it stopped before
    /// the removal or after it: the run stops with the app and the journal
    /// kept, the pair a recovery that still needs the rule uses.
    func testUninstallKeepsTheAppAndJournalWhenTheRuleRemovalDoesNotAnswer() throws {
        for (mode, removed) in [("txn-hangs-before", false), ("txn-hangs-after", true)] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(Self.cleanJournal)
            f.setMode("sudo", mode)

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 1, "\(mode): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("The sudo call that removes \(f.sudoers.path) did not answer within 5s and stopped on SIGTERM, so whether the rule was removed is not known."), "\(mode): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("The LaunchAgent is already removed; the app at \(f.app.path) and the recovery journal were kept. Check the rule with 'sudo cat \(f.sudoers.path)', then rerun this script."), "\(mode): " + r.stderr)
            XCTAssertFalse(r.stderr.contains("Nothing was removed"), "\(mode): " + r.stderr)
            let calls = f.calls()
            XCTAssertTrue(calls.contains("sudo SIGTERM"), "\(mode): \(calls)")
            XCTAssertEqual(calls.contains("sudo TXN-EXITED 0"), removed, "\(mode): \(calls)")
            XCTAssertEqual(f.exists(f.sudoers), !removed, mode)
            XCTAssertTrue(f.exists(f.app), mode)
            XCTAssertTrue(f.exists(f.state), mode)
            XCTAssertFalse(f.exists(f.plist), mode)
            XCTAssertTrue(try f.lockIsFree(), mode)
        }
    }

    /// A sudo call that removed the rule and then ignores SIGTERM is never
    /// killed. The run stops and names its pid, and the call keeps the
    /// recovery lock until it ends, so the app cannot start a session while
    /// root may still be at work.
    func testUninstallLeavesTheLockToASudoCallThatIgnoresSigterm() throws {
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(Self.cleanJournal)
        fx.setMode("sudo", "txn-ignores-term-after")

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let pid = try XCTUnwrap(fx.hungPid("sudo", within: 0), "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("The sudo call that removes \(fx.sudoers.path) did not answer within 5s, so whether the rule was removed is not known. It was sent SIGTERM and is still running as pid \(pid). It is not killed, because killing sudo could leave what it runs as root behind. It keeps the recovery lock until it ends, so until then the app cannot start a session; if it does not end by itself, stop it with 'sudo kill \(pid)'."), r.stderr)
        XCTAssertTrue(fx.calls().contains("sudo TXN-EXITED 0"), "\(fx.calls())")
        XCTAssertTrue(fx.calls().contains("sudo SIGTERM"), "\(fx.calls())")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.state))
        XCTAssertFalse(try fx.lockIsFree(), "the sudo call still holds the recovery lock")
        XCTAssertNil(fx.commandEnded())

        fx.releaseCommand()

        XCTAssertTrue(try fx.waitUntilLockIsFree(), "the lock goes with the sudo call")
        XCTAssertEqual(fx.commandEnded(), "released")
    }

    /// uninstall.sh's root transaction runs through the shared supervisor
    /// under the recovery lock. Here the fake sudo closes its fd 9, as sudo
    /// does, removes the rule and then ignores SIGTERM, logging each SIGTERM
    /// and SIGHUP with its sender. The test kills the uninstall with SIGKILL
    /// while it waits, then sends SIGTERM, SIGHUP and SIGINT to its whole
    /// process group. The supervisor survives that, sends sudo its own
    /// SIGTERM at the 5 s limit and never SIGKILL, and is the one holder of
    /// the lock until sudo has exited and been reaped. Nothing after the
    /// transaction ran: the app and the journal stay. The test signals only
    /// the uninstall it posix_spawned as a group leader, and that group,
    /// before reaping it.
    func testUninstallsRootTransactionKeepsTheLockThroughGroupSignalsUntilSudoEnds() throws {
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(Self.cleanJournal)
        fx.setMode("sudo", "txn-drops-fd9-receives-after")

        let shell = try fx.spawn(fx.uninstall, ownProcessGroup: true)
        defer {
            fx.releaseCommand()
            shell.wait()
        }
        guard let command = fx.hungPid("sudo", within: 30) else {
            _ = shell.signal(SIGKILL)
            return XCTFail("the transaction never started: \(fx.calls())")
        }
        guard !shell.hasExited else {
            return XCTFail("the uninstall ended before the test could kill it (wait status \(shell.wait())): \(fx.calls())")
        }
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        signalGroupInTurn(shell, receiver: command)
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the uninstall did not end by SIGKILL (wait status \(status))")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor survived the group's signals and holds the lock")

        XCTAssertTrue(waitUntil(15) { self.fx.calls().filter { $0 == "sudo SIGTERM" }.count == 2 },
                      "one SIGTERM from the group, one from the supervisor at the limit: \(fx.calls())")
        let senders = try fx.signalSenders(of: command)
        XCTAssertNotEqual(senders.parent, shell.pid, "sudo's parent is the supervisor, not the killed uninstall")
        XCTAssertEqual(senders.term.sorted(), [getpid(), senders.parent].sorted(),
                       "one SIGTERM from this test's signal to the group, one from the supervisor (pid \(senders.parent))")
        XCTAssertEqual(senders.hup, [getpid()], "the only SIGHUP is this test's signal to the group")
        XCTAssertTrue(fx.calls().contains("sudo TXN-EXITED 0"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains("sudo FD9-OPEN"), "sudo had closed fd 9: \(fx.calls())")
        XCTAssertNil(fx.commandEnded(), "never SIGKILLed")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor still holds the lock for the live sudo")

        fx.releaseCommand()
        try assertLockHeldUntilGone(command, within: 10)
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.state))
    }

    /// From a checkout, uninstall.sh reads the installed app's
    /// InsomniaResumeFrozenVersion before the recovery lock, with bounded
    /// calls. A read that does not answer, fails, or finds a plist that does
    /// not parse stops the run there, before the password is asked: which
    /// backstop.sh speaks the app's interface is unknown, so none runs and
    /// nothing is removed.
    func testUninstallStopsWhenTheInstalledVersionCannotBeRead() throws {
        typealias Setup = (ScriptFixture) throws -> Void
        let cases: [(why: String, hung: Bool, setup: Setup)] = [
            ("'plutil -extract InsomniaResumeFrozenVersion' did not answer within 5s", true, { f in
                try f.plutilCalls(matching: "-extract InsomniaResumeFrozenVersion *", hang: true)
            }),
            ("'plutil -extract InsomniaResumeFrozenVersion' exited 2", false, { f in
                try f.plutilCalls(matching: "-extract InsomniaResumeFrozenVersion *", hang: false)
            }),
            ("it does not parse ('plutil -lint' exited 1)", false, { f in
                try "not a property list".write(to: f.appInfo, atomically: true, encoding: .utf8)
            }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeState(Self.journalToUndo)
            try c.setup(f)

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 1, "\(c.why): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("Could not read InsomniaResumeFrozenVersion from \(f.appInfo.path): \(c.why). Which backstop.sh speaks the installed app's interface is unknown, so none was run. Nothing was removed; rerun once it reads."), "\(c.why): " + r.stderr)
            let calls = f.calls()
            XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("launchctl") || $0.contains("FD9-OPEN") }, "\(c.why): \(calls)")
            if c.hung { XCTAssertTrue(f.hungProcessGone("plutil", within: 0), c.why) }
            XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, true, "\(c.why): no backstop ran")
            for kept in [f.plist, f.app, f.sudoers] { XCTAssertTrue(f.exists(kept), "\(c.why): \(kept.path)") }
            XCTAssertTrue(try f.lockIsFree(), c.why)
        }
    }

    /// The version read before the lock applies only to the same file,
    /// unchanged. Here an install replaces the app's Info.plist with one
    /// that declares another version while the password is asked. Under the
    /// lock a bounded stat sees another file, and no Info.plist is read
    /// there, so no backstop runs and nothing is removed.
    func testUninstallStopsWhenTheInfoPlistChangesAfterItsVersionWasRead() throws {
        try fx.installMachinery()
        try fx.writeState(Self.journalToUndo)
        try ScriptFixture.infoPlist(resumeFrozenVersion: "2").write(to: fx.root.appendingPathComponent("sudo-v.info"), atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("sudo -v"), "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("\(fx.appInfo.path) changed after this run read its InsomniaResumeFrozenVersion (an install may have replaced the app meanwhile). No Info.plist is read under the recovery lock, so which backstop.sh speaks the installed app's interface is unknown, and none was run. Nothing was removed; rerun."), r.stderr)
        XCTAssertEqual(fx.plistReads(), [fx.appInfo.path], "one read, before the lock")
        XCTAssertFalse(fx.calls().contains { ScriptFixture.runsAsRoot($0) || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "no backstop ran")
        for kept in [fx.plist, fx.app, fx.sudoers] { XCTAssertTrue(fx.exists(kept), kept.path) }
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// After an interrupted swap, which bundle the plist on disk pins is
    /// read from the plist under the recovery lock with a bounded plutil
    /// call. When it does not answer, that is unknown: the call is stopped,
    /// neither bundle moves, no job is unloaded, and the lock is let go.
    func testInstallMovesNeitherBundleWhenThePinnedRequirementReadDoesNotAnswer() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(Self.cleanJournal)
        fx.setMode("launchctl", "loaded")
        try fx.plutilCalls(matching: "-extract ProgramArguments.4 *", hang: true)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("aside at \(previous.path). 'plutil -extract ProgramArguments.4', which reads the requirement \(fx.plist.path) pins, did not answer within 5s.\nNeither bundle was moved"), r.stderr)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains("plutil FD9-OPEN"), "the read was made under the lock: \(calls)")
        XCTAssertTrue(fx.hungProcessGone("plutil", within: 0), "it was killed and reaped before the run went on")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// As above, when the read fails.
    func testInstallMovesNeitherBundleWhenThePinnedRequirementReadFails() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(Self.cleanJournal)
        fx.setMode("launchctl", "loaded")
        try fx.plutilCalls(matching: "-extract ProgramArguments.4 *", hang: false)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("aside at \(previous.path). 'plutil -extract ProgramArguments.4', which reads the requirement \(fx.plist.path) pins, exited 2.\nNeither bundle was moved"), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// As above, when the plist on disk does not parse: only a plist that
    /// parses pins nothing.
    func testInstallMovesNeitherBundleWhenThePlistOnDiskDoesNotParse() throws {
        let previous = try writeInterruptedSwap()
        try fx.writeState(Self.cleanJournal)
        fx.setMode("launchctl", "loaded")
        try "not a property list".write(to: fx.plist, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("aside at \(previous.path). 'plutil -lint \(fx.plist.path)' exited 1, so which of the two bundles it pins is unknown.\nNeither bundle was moved"), r.stderr)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") }, "\(fx.calls())")
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "interrupted")
        XCTAssertEqual(try String(contentsOf: previous.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "previous\n")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "not a property list")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// install.sh lints the new LaunchAgent plist under the recovery lock,
    /// with a bounded call. One that does not answer or fails stops the run
    /// before any job is unloaded or any plist or bundle is replaced.
    func testInstallStopsWhenTheNewPlistsLintDoesNotAnswerOrFails() throws {
        for hang in [true, false] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.prepareInstall()
            try "trusted".write(to: f.plist, atomically: true, encoding: .utf8)
            f.setMode("launchctl", "loaded")
            try f.plutilCalls(matching: "-lint *candidate-*", hang: hang)
            let result = hang ? "did not answer within 5s" : "exited 2 (plutil: \(f.root.path)/plutil.fail says this read fails)"

            let r = try f.run(f.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, "hang \(hang): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("Install stopped: 'plutil -lint' on the new LaunchAgent plist \(result).\nThe plist at \(f.plist.path) and the app at \(f.app.path) were not replaced"), "hang \(hang): " + r.stderr)
            let calls = f.calls()
            XCTAssertEqual(calls.contains("plutil FD9-OPEN"), hang, "\(calls)")
            if hang { XCTAssertTrue(f.hungProcessGone("plutil", within: 0), "hang \(hang)") }
            XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl bootout") || $0.hasPrefix("launchctl bootstrap") }, "hang \(hang): \(calls)")
            XCTAssertEqual(try String(contentsOf: f.plist, encoding: .utf8), "trusted", "hang \(hang)")
            XCTAssertFalse(f.exists(f.app), "hang \(hang)")
            XCTAssertTrue(try f.lockIsFree(), "hang \(hang)")
        }
    }

    /// uninstall.sh checks a private copy of state.json, and every copy and
    /// read is bounded. One that does not answer or fails leaves a journal
    /// that was not fully checked, never a clean one: the run stops before
    /// removing anything.
    func testUninstallStopsWhenAJournalReadDoesNotAnswerOrFails() throws {
        typealias Setup = (ScriptFixture) throws -> Void
        let cases: [(problem: String, hung: String?, setup: Setup)] = [
            ("the journal could not be fully checked: 'plutil -convert json' on state.json did not answer within 5s", "plutil", { f in
                try f.plutilCalls(matching: "*/insomnia-uninstall.*/state.json", hang: true)
            }),
            ("the journal could not be fully checked: 'plutil -convert json' on state.json exited 2", nil, { f in
                try f.plutilCalls(matching: "*/insomnia-uninstall.*/state.json", hang: false)
            }),
            ("state.json could not be read within 5s", "cp", { f in try f.copies(matching: f.state.path, hang: true) }),
            ("state.json is unreadable or malformed", nil, { f in try f.copies(matching: f.state.path, hang: false) }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(Self.cleanJournal)
            try c.setup(f)

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 1, "\(c.problem): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything"), "\(c.problem): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("\n  - \(c.problem)\n"), "\(c.problem): " + r.stderr)
            let calls = f.calls()
            if let tool = c.hung {
                XCTAssertTrue(calls.contains("\(tool) FD9-OPEN"), "\(c.problem): \(calls)")
                XCTAssertTrue(f.hungProcessGone(tool, within: 0), c.problem)
            }
            XCTAssertFalse(calls.contains { ScriptFixture.runsAsRoot($0) || $0.hasPrefix("launchctl") }, "\(c.problem): \(calls)")
            for kept in [f.plist, f.app, f.sudoers, f.state] { XCTAssertTrue(f.exists(kept), "\(c.problem): \(kept.path)") }
            XCTAssertTrue(try f.lockIsFree(), c.problem)
        }
    }

    /// The journal is clean but reading state.json again, for a brightness
    /// the app kept, fails: whether it holds one is unknown, so the file is
    /// kept and the run says so. The rest of the uninstall goes on.
    func testUninstallKeepsTheJournalWhenReadingItAgainForAKeptBrightnessFails() throws {
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6,"displayRestoreRefused":true}"#)
        // The journal check reads displayRestoreRefused once; the second
        // read is the one for the kept brightness.
        try fx.plutilCalls(matching: "-extract displayRestoreRefused raw -o - */insomnia-uninstall.*/state.json", hang: false, fromCall: 2)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try String(contentsOf: fx.root.appendingPathComponent("plutil.fail.count"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        XCTAssertTrue(r.stdout.contains("Reading \(fx.state.path) again for a brightness Insomnia kept failed ('plutil -extract displayRestoreRefused' on state.json exited 2), so whether it holds one is unknown; it is kept."), r.stdout)
        XCTAssertTrue(r.stdout.contains("Kept \(fx.state.path): reading it again failed (see above)."), r.stdout)
        XCTAssertFalse(r.stdout.contains("  - display brightness"), r.stdout)
        XCTAssertEqual(try fx.stateJSON()["savedDisplayBrightness"] as? Double, 0.6)
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.sudoers))
    }

    // MARK: - Reads that fail or block, and the limit on the whole backstop

    /// What uninstall.sh's journal check makes of reads that fail in ways
    /// set -e would not catch, through the real caller (the check runs in
    /// $(...) on the left of ||): a journal its owner cannot open, a
    /// plutil that prints a NUL byte and exits 0, and one that prints the
    /// first byte of its answer and then exits 2. Each leaves a journal
    /// that was not fully checked, never a clean one, and the run stops
    /// before removing anything.
    func testUninstallStopsWhenAJournalReadIsRefusedCutShortOrHasANulByte() throws {
        typealias Setup = (ScriptFixture) throws -> Void
        let cases: [(problem: String, setup: Setup)] = [
            ("state.json is unreadable or malformed", { f in XCTAssertEqual(chmod(f.state.path, 0), 0) }),
            ("the journal could not be fully checked: 'plutil -extract sleepDisabledByUs' on state.json printed a NUL byte, which this script cannot pass on", { f in
                try f.answer("plutil", "nul", matching: "-extract sleepDisabledByUs raw -o - */insomnia-uninstall.*/state.json")
            }),
            ("the journal could not be fully checked: 'plutil -extract frozenProcesses' on state.json exited 2", { f in
                try f.answer("plutil", "partial", matching: "-extract frozenProcesses json -o - */insomnia-uninstall.*/state.json")
            }),
        ]
        for c in cases {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(Self.cleanJournal)
            try c.setup(f)

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 1, "\(c.problem): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything"), "\(c.problem): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("\n  - \(c.problem)\n"), "\(c.problem): " + r.stderr)
            XCTAssertFalse(f.calls().contains { ScriptFixture.runsAsRoot($0) || $0.hasPrefix("launchctl") }, "\(c.problem): \(f.calls())")
            for kept in [f.plist, f.app, f.sudoers, f.state] { XCTAssertTrue(f.exists(kept), "\(c.problem): \(kept.path)") }
            XCTAssertTrue(try f.lockIsFree(), c.problem)
            XCTAssertEqual(try f.contents(of: f.privateTmp()), [], c.problem)
        }
    }

    /// A FIFO put where state.json was after uninstall.sh saw a regular
    /// file there, just before its cp opens it: the bounded cp blocks in
    /// open(2) and is stopped at the limit (2 s here), so the lock is not
    /// kept waiting, and the journal counts as not read. The FIFO stays.
    func testUninstallStopsWhenTheJournalBecomesAFIFOBeforeItIsCopied() throws {
        try fx.writeUninstallCopy(extraConstants: ["CALL_TIMEOUT_SECONDS": "2"])
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(Self.cleanJournal)
        try fx.swapForFIFO(matching: fx.state.path)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything"), r.stderr)
        XCTAssertTrue(r.stderr.contains("\n  - state.json could not be read within 2s\n"), r.stderr)
        var info = stat()
        XCTAssertEqual(lstat(fx.state.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO, "the FIFO is left as it is")
        XCTAssertFalse(fx.calls().contains { ScriptFixture.runsAsRoot($0) || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        for kept in [fx.plist, fx.app, fx.sudoers] { XCTAssertTrue(fx.exists(kept), kept.path) }
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(try fx.contents(of: fx.privateTmp()), [])
    }

    /// A journal its owner can read only through an ACL entry (mode 0200),
    /// holding a brightness the app's guard refused to restore. uninstall.sh
    /// reads it through its private copy (cp -X), lists the brightness as
    /// kept, removes the rest, and leaves state.json, its mode and its
    /// entry as they were.
    func testUninstallKeepsARefusedBrightnessInAJournalOnlyAnACLMakesReadable() throws {
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6,"displayRestoreRefused":true}"#)
        XCTAssertEqual(chmod(fx.state.path, 0o200), 0)
        try TestACL.grantOwnerRead(fx.state)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Not restored, and kept in \(fx.state.path):\n  - display brightness 0.600000\n"), r.stdout)
        XCTAssertTrue(r.stdout.contains("Kept \(fx.state.path): it holds the brightness listed above."), r.stdout)
        XCTAssertEqual(try fx.mode(fx.state), 0o200)
        XCTAssertEqual(TestACL.entries(fx.state), 1)
        XCTAssertEqual(try fx.stateJSON()["savedDisplayBrightness"] as? Double, 0.6)
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.sudoers))
    }

    /// A copy of the fixture's backstop whose file reads go through the
    /// fakes (cp, plutil, cat, stat), with READ_TIMEOUT_SECONDS of 2.
    private func readingBackstop() throws -> URL {
        let url = fx.root.appendingPathComponent("backstop-reads.sh")
        var constants = ["CP": "cp", "PLUTIL": "plutil", "CAT": "cat", "STAT": "stat"].mapValues { fx.bin.appendingPathComponent($0).path }
        constants["READ_TIMEOUT_SECONDS"] = "2"
        try ScriptFixture.patch(try String(contentsOf: fx.backstop, encoding: .utf8), constants)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// What `stat -L -f '%d:%i:%Fc:%z'` prints for `url`: the identity the
    /// scripts record for an Info.plist.
    private func infoIdentity(_ url: URL) throws -> String {
        let r = try fx.runTool("/usr/bin/stat", ["-L", "-f", "%d:%i:%Fc:%z", url.path])
        XCTAssertEqual(r.status, 0, r.output)
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The backstop's copy of the journal does not answer: the cp, which
    /// ignores SIGTERM, is killed and reaped, never had fd 9 (the lock),
    /// and nothing is undone, as for a journal that cannot be read.
    func testBackstopUndoesNothingWhenItsCopyOfTheJournalDoesNotAnswer() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.copies(matching: fx.state.path, hang: true)

        let r = try fx.run(try readingBackstop())

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertTrue(fx.log().contains("backstop: \(fx.state.path): it could not be read: cp did not answer within 2s\n"), fx.log())
        XCTAssertTrue(fx.log().contains("backstop: \(fx.state.path) is unreadable or malformed; nothing undone, evidence kept"), fx.log())
        XCTAssertEqual(fx.calls(), [], "no undo, and the cp had no fd 9")
        XCTAssertTrue(fx.hungProcessGone("cp", within: 0))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(try fx.contents(of: fx.privateTmp()), [])
    }

    /// A plutil read of the journal's copy does not answer: the run stops
    /// there with nothing undone, and the journal stays as it was.
    func testBackstopStopsWhenAReadOfItsJournalCopyDoesNotAnswer() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.plutilCalls(matching: "*/insomnia-backstop.*/state.json", hang: true)

        let r = try fx.run(try readingBackstop())

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        let log = fx.log()
        XCTAssertTrue(log.contains("backstop: could not read \(fx.state.path) ('plutil "), log)
        XCTAssertTrue(log.contains(" on state.json did not answer within 2s); recovery stopped here, nothing further undone this run, journal and session kept; will retry"), log)
        XCTAssertEqual(fx.calls(), [], "no undo, and the plutil had no fd 9")
        XCTAssertTrue(fx.hungProcessGone("plutil", within: 0))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(try fx.lockIsFree())
        XCTAssertEqual(try fx.contents(of: fx.privateTmp()), [])
    }

    /// A read that fails after an undo was made stops the run at that
    /// point: sleep was turned back on, the Low Power Mode read fails, the
    /// mode is not touched, and the journal on disk still says both, so the
    /// next run sees them again.
    func testBackstopKeepsTheJournalWhenAReadFailsAfterAnUndo() throws {
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"frozenProcesses":[],"dockerFrozen":false}"#)
        // The journal check reads the type once; the second read is the one
        // before Low Power Mode would be switched off.
        try fx.plutilCalls(matching: "-type keptDisplayUnderLowPower -o - */insomnia-backstop.*/state.json", hang: false, fromCall: 2)

        let r = try fx.run(try readingBackstop())

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertTrue(fx.log().contains("backstop: could not read keptDisplayUnderLowPower in \(fx.state.path) ('plutil -type keptDisplayUnderLowPower' on state.json exited 2); recovery stopped here, nothing further undone this run, journal and session kept; will retry"), fx.log())
        XCTAssertEqual(try String(contentsOf: fx.root.appendingPathComponent("plutil.fail.count"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertEqual(try fx.stateJSON()["lowPowerSetByUs"] as? Bool, true)
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// The copy of session.json does not answer: its end time is unknown,
    /// so the session counts as ended, the journal is undone, and the file
    /// is moved aside so no later run reads it as a session.
    func testBackstopTreatsASessionWhoseCopyDoesNotAnswerAsEnded() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try fx.copies(matching: fx.session.path, hang: true)

        let r = try fx.run(try readingBackstop())

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(fx.calls(), ["sudo -n \(fx.fakePmset) -a disablesleep 0"])
        XCTAssertTrue(fx.log().contains("session.json cannot be read (it could not be read within 2s), so its end time is unknown; treated as expired; restoring from journal"), fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try fx.contents(of: fx.home).filter { $0.hasPrefix("session.json.unreadable-") }.count, 1)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertTrue(fx.hungProcessGone("cp", within: 0))
        XCTAssertEqual(try fx.contents(of: fx.privateTmp()), [])
    }

    /// Run on its own, the backstop reads its app's version before the lock.
    /// When the stat of the Info.plist does not answer, the version is
    /// unknown: the binary is not run, and the frozen entry that needs it
    /// is kept.
    func testBackstopKeepsAMicrosecondEntryWhenItsOwnVersionReadDoesNotAnswer() throws {
        try writeMicrosecondEntry(pid: 5104, started: 1_789_388_423, micros: 7)
        try fx.answer("stat", "hang", matching: fx.appInfo.path)

        let r = try fx.run(try readingBackstop())

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("Insomnia ") }, [])
        XCTAssertTrue(fx.log().contains("pid 5104 needs the app binary for its microsecond identity check, but the InsomniaResumeFrozenVersion that \(fx.appInfo.path) declares is unknown ('stat' did not answer within 2s), and no Info.plist is read under the recovery lock; the binary was not run; kept, not signaled"), fx.log())
        XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5104)
        XCTAssertEqual(fx.plistReads(), [])
        XCTAssertTrue(fx.hungProcessGone("stat", within: 0))
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// Run with the caller's lock on fd 9, the backstop takes the version
    /// its caller read before the lock from the environment, and uses it
    /// only for the same Info.plist path and only while a stat under the
    /// lock shows the same file. It reads no Info.plist itself. Anything
    /// else keeps the entry that needs the binary.
    func testBackstopUsesTheVersionEvidenceItsCallerPassesDown() throws {
        let identity = try infoIdentity(fx.appInfo)
        let backstop = try readingBackstop()
        let unknown = "the InsomniaResumeFrozenVersion that \(fx.appInfo.path) declares is unknown"
        let cases: [(label: String, env: [String: String], hangStat: Bool, kept: String?)] = [
            ("same file, version 1", ["INSOMNIA_INFO_PATH": fx.appInfo.path, "INSOMNIA_INFO_EVIDENCE": identity, "INSOMNIA_INFO_VERSION": "1"], false, nil),
            ("same file, version 2", ["INSOMNIA_INFO_PATH": fx.appInfo.path, "INSOMNIA_INFO_EVIDENCE": identity, "INSOMNIA_INFO_VERSION": "2"], false,
             "\(fx.appInfo.path) declares InsomniaResumeFrozenVersion '2', not 1 (an older or newer build)"),
            ("another path", ["INSOMNIA_INFO_PATH": fx.root.appendingPathComponent("Other.app/Contents/Info.plist").path, "INSOMNIA_INFO_EVIDENCE": identity, "INSOMNIA_INFO_VERSION": "1"], false,
             "\(unknown) (the program that started this run holds the recovery lock and did not pass down a version it read before it took the lock), and no Info.plist is read under the recovery lock"),
            ("nothing passed", [:], false,
             "\(unknown) (the program that started this run holds the recovery lock and did not pass down a version it read before it took the lock), and no Info.plist is read under the recovery lock"),
            ("caller could not read it", ["INSOMNIA_INFO_PATH": fx.appInfo.path, "INSOMNIA_INFO_EVIDENCE": "unknown", "INSOMNIA_INFO_VERSION": ""], false,
             "\(unknown) (the program that started this run could not read it before it took the recovery lock), and no Info.plist is read under the recovery lock"),
            ("another file now", ["INSOMNIA_INFO_PATH": fx.appInfo.path, "INSOMNIA_INFO_EVIDENCE": "1:2:3.4:5", "INSOMNIA_INFO_VERSION": "1"], false,
             "\(fx.appInfo.path) changed after its InsomniaResumeFrozenVersion was read before the recovery lock (an install may have replaced the app meanwhile)"),
            ("stat under the lock hangs", ["INSOMNIA_INFO_PATH": fx.appInfo.path, "INSOMNIA_INFO_EVIDENCE": identity, "INSOMNIA_INFO_VERSION": "1"], true,
             "whether the InsomniaResumeFrozenVersion read from \(fx.appInfo.path) before the recovery lock still applies is unknown ('stat' did not answer within 2s under the lock)"),
        ]
        for c in cases {
            fx.clearCalls()
            try? FileManager.default.removeItem(at: fx.root.appendingPathComponent("plutil.reads"))
            try? FileManager.default.removeItem(at: fx.root.appendingPathComponent("stat.hang"))
            try? FileManager.default.removeItem(at: fx.logFile)
            try writeMicrosecondEntry(pid: 5105, started: 1_789_388_423, micros: 3)
            if c.hangStat { try fx.answer("stat", "hang", matching: fx.appInfo.path) }

            let r = try fx.run(backstop, fd9: fx.lock, extraEnvironment: c.env)

            let ran = fx.calls().filter { $0.hasPrefix("Insomnia ") }
            if let kept = c.kept {
                XCTAssertEqual(r.status, 1, "\(c.label): " + r.stderr + fx.log())
                XCTAssertEqual(ran, [], c.label)
                XCTAssertTrue(fx.log().contains("pid 5105 needs the app binary for its microsecond identity check, but \(kept); the binary was not run; kept, not signaled"), "\(c.label): " + fx.log())
                XCTAssertEqual(try onlyFrozenEntry()?["pid"] as? Int, 5105, c.label)
            } else {
                XCTAssertEqual(r.status, 0, "\(c.label): " + r.stderr + fx.log())
                XCTAssertEqual(ran, ["Insomnia --resume-frozen 2 < 5105 1789388423 3 \(fx.bootUUID)"], c.label)
                XCTAssertNil(try onlyFrozenEntry(), c.label)
            }
            XCTAssertEqual(fx.plistReads(), [], "\(c.label): no Info.plist is read with the caller's lock")
            XCTAssertFalse(fx.calls().contains("stat FD9-OPEN"), c.label)
            if c.hangStat { XCTAssertTrue(fx.hungProcessGone("stat", within: 0), c.label) }
        }
    }

    /// A stand-in for backstop.sh at `url`. It records the version evidence
    /// it was given as "backstop env <path>|<evidence>|<version>" ("unset"
    /// for a variable not set), closes its fd 9, so only its caller's
    /// supervisor holds the lock, and prints "stand-in output". Then, by
    /// `mode`: "exit" exits 0; "stop" waits, and on SIGTERM logs "backstop
    /// SIGTERM" and exits 143; "receive" becomes the signal receiver (see
    /// signalReceiverHere), which logs each SIGTERM and SIGHUP with its
    /// sender, ignores both, writes backstop.hung.pid once ready, and waits
    /// until the test calls releaseCommand (or a 60 s watchdog).
    private func writeStandInBackstop(in f: ScriptFixture, at url: URL, mode: String) throws {
        let calls = f.callsLog.path
        let wait: String
        switch mode {
        case "exit": wait = "exit 0"
        case "stop": wait = """
            trap 'echo "backstop SIGTERM" >> "\(calls)"; exit 143' TERM
            deadline=$(( SECONDS + 60 ))
            while [[ ! -e "\(f.root.path)/release" && -d "\(f.root.path)" ]] && (( SECONDS < deadline )); do /bin/sleep 0.1; done
            exit 0
            """
        default: wait = f.signalReceiverHere("backstop") + "\nreceive_signals"
        }
        try """
        #!/bin/bash
        exec 9<&-
        printf 'backstop env %s|%s|%s\\n' "${INSOMNIA_INFO_PATH-unset}" "${INSOMNIA_INFO_EVIDENCE-unset}" "${INSOMNIA_INFO_VERSION-unset}" >> "\(calls)"
        echo "stand-in output"
        \(wait)

        """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// uninstall.sh runs backstop.sh as one bounded call. The version it
    /// read before the lock goes down in the environment with the identity
    /// of the file it came from, and what the backstop printed is printed
    /// once it ends.
    func testUninstallPassesItsVersionEvidenceToTheBackstopAndPrintsItsOutput() throws {
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(Self.cleanJournal)
        try writeStandInBackstop(in: fx, at: fx.backstop, mode: "exit")
        let identity = try infoIdentity(fx.appInfo)

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("backstop env \(fx.appInfo.path)|\(identity)|1"), "\(fx.calls())")
        XCTAssertTrue(r.stdout.contains("using \(fx.backstop.path)\nstand-in output\n"), r.stdout)
        XCTAssertFalse(fx.exists(fx.app))
    }

    /// From a release zip's folder, uninstall.sh runs the copy sealed in the
    /// bundle and passes it the version evidence too. There a version read
    /// that fails is a note, not a stop: the sealed copy gets "unknown",
    /// and would keep a frozen entry that needs the binary.
    func testUninstallFromAZipPassesTheVersionEvidenceToTheSealedCopy() throws {
        for fails in [false, true] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(Self.cleanJournal)
            try writeStandInBackstop(in: f, at: f.installedBackstop, mode: "exit")
            let unpacked = f.root.appendingPathComponent("shared-tmp/Insomnia-0.1.0-macos", isDirectory: true)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: f.uninstall, to: unpacked.appendingPathComponent("uninstall.sh"))
            let stat = try f.runTool("/usr/bin/stat", ["-L", "-f", "%d:%i:%Fc:%z", f.appInfo.path])
            let identity = stat.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if fails { try f.plutilCalls(matching: "-extract InsomniaResumeFrozenVersion *", hang: false) }

            let r = try f.run(unpacked.appendingPathComponent("uninstall.sh"))

            XCTAssertEqual(r.status, 0, "fails \(fails): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stdout.contains("using \(f.installedBackstop.path)\nstand-in output\n"), "fails \(fails): " + r.stdout)
            let env = fails ? "\(f.appInfo.path)|unknown|" : "\(f.appInfo.path)|\(identity)|1"
            XCTAssertTrue(f.calls().contains("backstop env \(env)"), "fails \(fails): \(f.calls())")
            XCTAssertEqual(r.stderr.contains("note: could not read InsomniaResumeFrozenVersion from \(f.appInfo.path) before the recovery lock: 'plutil -extract InsomniaResumeFrozenVersion' exited 2. If the journal holds a frozen process that only the app binary can resume, it stays frozen and journaled, and step 4 then stops before anything is removed."), fails, r.stderr)
        }
    }

    /// A backstop that does not end on the SIGTERM at its limit
    /// (BACKSTOP_TIMEOUT_SECONDS, 2 here) is never sent SIGKILL. uninstall.sh
    /// stops three seconds later with nothing removed, and the supervisor,
    /// the backstop's parent, keeps the recovery lock until the backstop
    /// ends; the stand-in closed its own fd 9. The one SIGTERM came from the
    /// supervisor.
    func testUninstallLeavesABackstopThatIgnoresSIGTERMRunningWithTheLock() throws {
        try fx.writeUninstallCopy(extraConstants: ["BACKSTOP_TIMEOUT_SECONDS": "2"])
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(Self.cleanJournal)
        try writeStandInBackstop(in: fx, at: fx.backstop, mode: "receive")
        defer { fx.releaseCommand() }

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let pid = try XCTUnwrap(fx.hungPid("backstop", within: 0), "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("\(fx.backstop.path) did not finish within 2s and is still running as pid \(pid) three seconds after its SIGTERM. It is not killed, because it may be running sudo pmset, and it keeps the recovery lock until it ends. Nothing was removed; rerun once it has ended."), r.stderr)
        let senders = try fx.signalSenders(of: pid)
        XCTAssertEqual(senders.term, [senders.parent], "one SIGTERM, from the supervisor")
        XCTAssertEqual(senders.hup, [])
        XCTAssertFalse(fx.calls().contains("backstop FD9-OPEN"), "\(fx.calls())")
        XCTAssertFalse(r.stdout.contains("stand-in output"), "its output is not read while it runs")
        XCTAssertFalse(fx.calls().contains { ScriptFixture.runsAsRoot($0) || $0.hasPrefix("launchctl") }, "\(fx.calls())")
        for kept in [fx.plist, fx.app, fx.sudoers, fx.state] { XCTAssertTrue(fx.exists(kept), kept.path) }
        XCTAssertEqual(kill(pid, 0), 0, "the backstop still runs")
        XCTAssertNil(fx.commandEnded())
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor holds the lock for it")

        fx.releaseCommand()
        try assertLockHeldUntilGone(pid, within: 10)
        XCTAssertEqual(fx.commandEnded(), "released")
    }

    /// The real backstop at its limit, while a sudo pmset it started runs
    /// on (the fake closes its fd 9, as sudo does, and ignores SIGTERM): the
    /// backstop is sent SIGTERM and ends, and uninstall.sh reports that and
    /// stops with nothing removed. The sudo gets no signal from either, and
    /// the backstop's own supervisor keeps the lock until it ends.
    func testUninstallStopsABackstopAtItsLimitWhileItsSudoKeepsTheLock() throws {
        try fx.writeUninstallCopy(extraConstants: ["BACKSTOP_TIMEOUT_SECONDS": "2"])
        try ScriptFixture.patch(try String(contentsOf: fx.backstop, encoding: .utf8), ["COMMAND_TIMEOUT_SECONDS": "30"])
            .write(to: fx.backstop, atomically: true, encoding: .utf8)
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "drops-fd9-logs-signals")
        defer { fx.releaseCommand() }

        let r = try fx.run(fx.uninstall)

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("\(fx.backstop.path) did not finish within 2s and was stopped with SIGTERM; what it undid before then stays undone, and the journal shows what is left."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything"), r.stderr)
        XCTAssertTrue(r.stderr.contains("\n  - sleepDisabledByUs is still true\n"), r.stderr)
        let command = try XCTUnwrap(fx.hungPid("sudo", within: 0), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains("sudo SIGTERM"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains("sudo FD9-OPEN"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") }, "\(fx.calls())")
        for kept in [fx.plist, fx.app, fx.sudoers, fx.state] { XCTAssertTrue(fx.exists(kept), kept.path) }
        XCTAssertEqual(try fx.contents(of: fx.privateTmp()), [], "the backstop removed its private folder on SIGTERM")
        XCTAssertNil(fx.commandEnded())
        XCTAssertFalse(try fx.lockIsFree(), "the backstop's supervisor holds the lock for the sudo call")

        fx.releaseCommand()
        try assertLockHeldUntilGone(command, within: 10)
        XCTAssertEqual(fx.commandEnded(), "released")
    }

    /// The uninstall is killed with SIGKILL while its backstop runs, and
    /// its whole process group then gets SIGTERM, SIGHUP and SIGINT. The
    /// supervisor survives that, sends the backstop its own SIGTERM at the
    /// limit (4 s here), never SIGKILL, and holds the lock until the
    /// backstop has ended.
    func testUninstallsBackstopCallKeepsTheLockThroughACrashAndGroupSignals() throws {
        try fx.writeUninstallCopy(extraConstants: ["BACKSTOP_TIMEOUT_SECONDS": "4"])
        try fx.installMachinery()
        try fx.writeConfig(#"{"agentList":[]}"#)
        try fx.writeState(Self.cleanJournal)
        try writeStandInBackstop(in: fx, at: fx.backstop, mode: "receive")

        let shell = try fx.spawn(fx.uninstall, ownProcessGroup: true)
        defer {
            fx.releaseCommand()
            shell.wait()
        }
        guard let backstop = fx.hungPid("backstop", within: 30) else {
            _ = shell.signal(SIGKILL)
            return XCTFail("the backstop never started: \(fx.calls())")
        }
        guard !shell.hasExited else {
            return XCTFail("the uninstall ended before the test could kill it (wait status \(shell.wait())): \(fx.calls())")
        }
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        XCTAssertEqual(shell.signalGroup(SIGTERM), 0, "SIGTERM")
        XCTAssertTrue(waitUntil(10) { ((try? self.fx.signalSenders(of: backstop))?.term.count ?? 0) >= 1 }, "the group's SIGTERM arrived")
        XCTAssertEqual(shell.signalGroup(SIGHUP), 0, "SIGHUP")
        XCTAssertTrue(waitUntil(10) { ((try? self.fx.signalSenders(of: backstop))?.hup.count ?? 0) >= 1 }, "the group's SIGHUP arrived")
        XCTAssertEqual(shell.signalGroup(SIGINT), 0, "SIGINT")
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the uninstall did not end by SIGKILL (wait status \(status))")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor survived the group's signals and holds the lock")

        XCTAssertTrue(waitUntil(15) { self.fx.calls().filter { $0 == "backstop SIGTERM" }.count == 2 },
                      "one SIGTERM from the group, one from the supervisor at the limit: \(fx.calls())")
        let senders = try fx.signalSenders(of: backstop)
        XCTAssertNotEqual(senders.parent, shell.pid, "the backstop's parent is the supervisor, not the killed uninstall")
        XCTAssertEqual(senders.term.sorted(), [getpid(), senders.parent].sorted(),
                       "one SIGTERM from this test's signal to the group, one from the supervisor (pid \(senders.parent))")
        XCTAssertEqual(senders.hup, [getpid()], "the only SIGHUP is this test's signal to the group")
        XCTAssertFalse(fx.calls().contains("backstop FD9-OPEN"), "\(fx.calls())")
        XCTAssertNil(fx.commandEnded(), "never SIGKILLed")
        XCTAssertFalse(try fx.lockIsFree(), "the supervisor still holds the lock for the live backstop")

        fx.releaseCommand()
        try assertLockHeldUntilGone(backstop, within: 10)
        XCTAssertEqual(fx.commandEnded(), "released")
        XCTAssertTrue(fx.exists(fx.app))
        XCTAssertTrue(fx.exists(fx.state))
    }

    /// install.sh runs the new build's backstop with the same limit. One
    /// that ends on the SIGTERM there (124) stops the install like any
    /// failed recovery, saying so; one that does not (125) stops it at once
    /// and keeps the lock until it ends. Nothing is replaced or unloaded,
    /// and the version evidence, "none" with no app at $APP, went down.
    func testInstallStopsWhenItsBackstopDoesNotFinishInTime() throws {
        for mode in ["stop", "receive"] {
            let f = try ScriptFixture()
            defer { f.releaseCommand(); f.destroy() }
            try f.writeInstallCopies(extraConstants: ["BACKSTOP_TIMEOUT_SECONDS": "2"])
            try f.prepareInstall()
            try "trusted".write(to: f.plist, atomically: true, encoding: .utf8)
            try f.writeState(Self.cleanJournal)
            f.setMode("launchctl", "loaded")
            try writeStandInBackstop(in: f, at: f.backstop, mode: mode)

            let r = try f.run(f.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, "\(mode): " + r.stderr + r.stdout)
            XCTAssertTrue(f.calls().contains("backstop env \(f.appInfo.path)|none|"), "\(mode): \(f.calls())")
            XCTAssertFalse(f.calls().contains { $0.hasPrefix("launchctl bootout") || $0.hasPrefix("launchctl bootstrap") }, "\(mode): \(f.calls())")
            XCTAssertEqual(try String(contentsOf: f.plist, encoding: .utf8), "trusted", mode)
            XCTAssertFalse(f.exists(f.app), mode)
            if mode == "stop" {
                XCTAssertTrue(r.stderr.contains("Install stopped: the backstop could not fully undo a previous session\n(exit status 124).\nIt did not finish within 2s and was stopped with SIGTERM."), r.stderr)
                XCTAssertEqual(f.calls().filter { $0 == "backstop SIGTERM" }.count, 1, "\(f.calls())")
                XCTAssertTrue(try f.lockIsFree(), mode)
            } else {
                let pid = try XCTUnwrap(f.hungPid("backstop", within: 0), "\(f.calls())")
                XCTAssertTrue(r.stderr.contains("Install stopped: the backstop did not finish within 2s and is still running as\npid \(pid) three seconds after its SIGTERM."), r.stderr)
                let senders = try f.signalSenders(of: pid)
                XCTAssertEqual(senders.term, [senders.parent], "one SIGTERM, from the supervisor")
                XCTAssertFalse(try f.lockIsFree(), "the supervisor holds the lock for the live backstop")
                f.releaseCommand()
                let deadline = Date().addingTimeInterval(10)
                while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                XCTAssertTrue(try f.waitUntilLockIsFree(10), mode)
                XCTAssertEqual(f.commandEnded(), "released")
            }
        }
    }

    /// install.sh reads the version of the app it replaces before it takes
    /// the recovery lock. When that read fails, the run says so, the
    /// backstop it runs under the lock keeps a frozen entry that only the
    /// app binary can resume, and the install stops with nothing replaced.
    func testInstallKeepsAMicrosecondEntryWhenTheInstalledVersionCannotBeRead() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try ScriptFixture.infoPlist(resumeFrozenVersion: "1").write(to: fx.appInfo, atomically: true, encoding: .utf8)
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try writeFrozenEntryForUninstall(fx)
        fx.setMode("launchctl", "loaded")
        try fx.plutilCalls(matching: "-extract InsomniaResumeFrozenVersion *", hang: false)

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("note: could not read InsomniaResumeFrozenVersion from \(fx.appInfo.path) before the recovery lock: 'plutil -extract InsomniaResumeFrozenVersion' exited 2. If the journal holds a frozen process that only the app binary can resume, it stays frozen and journaled, and the install stops after the backstop runs."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Install stopped: the backstop could not fully undo a previous session\n(exit status 1)."), r.stderr)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("Insomnia ") }, [])
        XCTAssertTrue(fx.log().contains("pid 5311 needs the app binary for its microsecond identity check, but the InsomniaResumeFrozenVersion that \(fx.appInfo.path) declares is unknown (the program that started this run could not read it before it took the recovery lock)"), fx.log())
        let entries = try XCTUnwrap(fx.stateJSON()["frozenProcesses"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["pid"] as? Int }, [5311])
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl bootout") || $0.hasPrefix("launchctl bootstrap") }, "\(fx.calls())")
        XCTAssertTrue(try fx.lockIsFree())
    }

    /// Nothing is at $APP, and an interrupted run set the previous app
    /// aside. install.sh reads that bundle's Info.plist before the lock and
    /// puts the bundle back under it; a rename keeps the file's identity, so
    /// the backstop, which checks the file at $APP under the lock, runs the
    /// binary for the frozen entry, and the install completes.
    func testInstallReadsTheVersionOfASetAsideAppItPutsBack() throws {
        try fx.prepareInstall()
        try fx.writeBundle(at: setAside, marker: "previous")
        let asideInfo = setAside.appendingPathComponent("Contents/Info.plist")
        try ScriptFixture.infoPlist(resumeFrozenVersion: "1").write(to: asideInfo, atomically: true, encoding: .utf8)
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try writeFrozenEntryForUninstall(fx)
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout + fx.log())
        XCTAssertTrue(r.stdout.contains("restored \(fx.app.path), which an interrupted run had set aside"), r.stdout)
        XCTAssertTrue(fx.calls().contains("Insomnia --resume-frozen 2 < 5311 1789388423 11 \(fx.bootUUID)"), "\(fx.calls())")
        XCTAssertEqual(fx.plistReads().first, asideInfo.path, "\(fx.plistReads())")
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)
    }

    /// What the scripts share is the same text in each, so a fix to one
    /// cannot miss another: backstop.sh and uninstall.sh read through the
    /// same layer and check the journal and the session with the same
    /// functions, all three read an Info.plist's version the same way, and
    /// install.sh and uninstall.sh run the backstop the same way.
    func testTheScriptsShareTheirReadersTextForText() throws {
        func text(_ name: String) throws -> String {
            try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(name), encoding: .utf8)
        }
        let backstop = try text("backstop.sh"), uninstall = try text("uninstall.sh"), install = try text("install.sh")
        XCTAssertEqual(try Self.sharedReadLayer(in: backstop, "backstop.sh"), try Self.sharedReadLayer(in: uninstall, "uninstall.sh"))
        for name in ["journal_shape_problems", "session_shape_problems", "epoch_of", "epoch_at"] {
            XCTAssertEqual(try Self.shellFunction(name, in: backstop, "backstop.sh"), try Self.shellFunction(name, in: uninstall, "uninstall.sh"), name)
        }
        func infoBlock(_ t: String, _ script: String) throws -> String {
            let start = try XCTUnwrap(t.range(of: "\nINFO_EVIDENCE=unknown\n"), script)
            let reader = try XCTUnwrap(t.range(of: "\nread_info_version() { # file\n", range: start.upperBound..<t.endIndex), script)
            let end = try XCTUnwrap(t.range(of: "\n}\n", range: reader.upperBound..<t.endIndex), script)
            return String(t[start.lowerBound..<end.upperBound])
        }
        let info = try infoBlock(backstop, "backstop.sh")
        XCTAssertEqual(try infoBlock(uninstall, "uninstall.sh"), info)
        XCTAssertEqual(try infoBlock(install, "install.sh"), info)
        for name in ["run_backstop", "work_read"] {
            XCTAssertEqual(try Self.shellFunction(name, in: install, "install.sh"), try Self.shellFunction(name, in: uninstall, "uninstall.sh"), name)
        }
    }

    // MARK: - A process named Insomnia whose owner cannot be read

    /// How the fake ps can fail to give a user ID, and how the scripts
    /// report each.
    private static let unreadableOwners: [(answer: String, why: String)] = [
        ("fail", "ps -o uid= exited 1"),
        ("hang", "ps -o uid= did not answer within 5s"),
        ("garbage", "ps -o uid= printed 'root?', not a user ID"),
        ("empty", "ps -o uid= printed nothing"),
    ]

    /// A `ps -o uid=` that fails, does not answer, prints nothing or prints
    /// something that is not a user ID proves neither account, so the
    /// process is not taken for this account's app even when it runs this
    /// app's executable. It is listed again once a second for
    /// QUIT_WAIT_SECONDS, and then stops the install before the first sudo
    /// (the password prompt included), with nothing asked to quit and
    /// nothing changed.
    func testInstallStopsBeforeAnySudoWhileAProcessOwnerCannotBeRead() throws {
        for o in Self.unreadableOwners {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.prepareInstall()
            try f.installMachinery()
            f.setMode("launchctl", "loaded")
            f.setMode("pgrep", "0\n")
            try f.psComm([(4242, f.installedExecutable.path)])
            try f.psUidAnswer(4242, o.answer)

            let r = try f.run(f.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 1, "\(o.answer): " + r.stderr + r.stdout)
            XCTAssertTrue(r.stderr.contains("Whose process these are could not be read, so whether Insomnia runs in this or another account is unknown: pid 4242 (owner unknown: \(o.why); \(f.installedExecutable.path)"), "\(o.answer): " + r.stderr)
            XCTAssertTrue(r.stderr.contains("so nothing was asked to quit. Rerun once 'ps -o uid= -p <pid>' answers for them, or once they have exited. Nothing was changed."), "\(o.answer): " + r.stderr)
            let calls = f.calls()
            XCTAssertEqual(calls.filter { $0 == "pgrep -x Insomnia" }.count, 2, "listed again once: \(calls)")
            XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("osascript") || $0.hasPrefix("kill") || $0.hasPrefix("pkill") || $0.hasPrefix("launchctl") }, "\(o.answer): \(calls)")
            if o.answer == "hang" { XCTAssertTrue(f.hungProcessGone("ps", within: 0)) }
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule, o.answer)
            XCTAssertEqual(try String(contentsOf: f.installedExecutable, encoding: .utf8), "binary", o.answer)
            XCTAssertEqual(try String(contentsOf: f.plist, encoding: .utf8), "plist", o.answer)
        }
    }

    /// The same for uninstall.sh, before its `sudo -v`; and a process of
    /// this account with a bundle id that is neither this app's nor the API
    /// client's, which is waited for and then stops the run, also before any
    /// sudo.
    func testUninstallStopsBeforeAnySudoWhileAProcessOwnerOrIdentityCannotBeRead() throws {
        for o in Self.unreadableOwners + [("unknown bundle id", "")] {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.installMachinery()
            try f.writeState(Self.journalToUndo)
            f.setMode("pgrep", "0\n")
            let exe: String
            if o.why.isEmpty {
                exe = try f.otherBundle(in: "DevBuild", bundleId: "com.example.insomnia-copy").path
                try f.psComm([(4242, exe)])
            } else {
                exe = f.installedExecutable.path
                try f.psComm([(4242, exe)])
                try f.psUidAnswer(4242, o.answer)
            }

            let r = try f.run(f.uninstall)

            XCTAssertEqual(r.status, 1, "\(o.answer): " + r.stderr + r.stdout)
            if o.why.isEmpty {
                XCTAssertTrue(r.stderr.contains("pid 4242 (\(exe); bundle id com.example.insomnia-copy is neither this app's nor the Insomnia API client's)"), "\(o.answer): " + r.stderr)
            } else {
                XCTAssertTrue(r.stderr.contains("Whose process these are could not be read, so whether Insomnia runs in this or another account is unknown: pid 4242 (owner unknown: \(o.why); \(exe)"), "\(o.answer): " + r.stderr)
                XCTAssertEqual(f.calls().filter { $0 == "pgrep -x Insomnia" }.count, 2, "listed again once: \(f.calls())")
            }
            XCTAssertTrue(r.stderr.contains("Nothing was removed."), "\(o.answer): " + r.stderr)
            let calls = f.calls()
            XCTAssertFalse(calls.contains { $0.hasPrefix("sudo") || $0.hasPrefix("osascript") || $0.hasPrefix("kill") || $0.hasPrefix("pkill") || $0.hasPrefix("launchctl") }, "\(o.answer): \(calls)")
            if o.answer == "hang" { XCTAssertTrue(f.hungProcessGone("ps", within: 0)) }
            XCTAssertEqual(try String(contentsOf: f.sudoers, encoding: .utf8), f.sudoersRule, o.answer)
            XCTAssertEqual(try String(contentsOf: f.installedExecutable, encoding: .utf8), "binary", o.answer)
            XCTAssertTrue(f.exists(f.plist), o.answer)
            XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, true, o.answer)
        }
    }

    /// The control: the Insomnia API client (com.insomnia.app) is told
    /// apart by its bundle id alone, in any account, so a client whose
    /// owner cannot be read is ignored and both scripts finish.
    func testAnAPIClientWhoseOwnerCannotBeReadIsIgnored() throws {
        // install.sh
        do {
            try fx.prepareInstall()
            fx.setMode("launchctl", "loaded")
            let client = try fx.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
            fx.setMode("pgrep", "0\n")
            try fx.psComm([(4242, client.path)])
            try fx.psUidAnswer(4242, "fail")

            let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": ScriptFixture.account])

            XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
            XCTAssertTrue(r.stdout.contains("Ignoring 1 process(es) named Insomnia that are not this app: pid 4242 (\(client.path), bundle id com.insomnia.app)"), r.stdout)
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("kill") || $0.hasPrefix("pkill") }, "\(fx.calls())")
            XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), fx.sudoersRule)
        }
        // uninstall.sh
        let f = try ScriptFixture()
        defer { f.destroy() }
        try f.installMachinery()
        try f.writeConfig(#"{"agentList":[]}"#)
        try f.writeState(Self.cleanJournal)
        let client = try f.otherBundle(in: "Applications-foreign", bundleId: "com.insomnia.app")
        f.setMode("pgrep", "0\n")
        try f.psComm([(4242, client.path)])
        try f.psUidAnswer(4242, "fail")

        let r = try f.run(f.uninstall)

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Ignoring 1 process(es) named Insomnia that are not this app: pid 4242 (\(client.path), bundle id com.insomnia.app)"), r.stdout)
        XCTAssertFalse(f.calls().contains { $0.hasPrefix("osascript") || $0.hasPrefix("kill") || $0.hasPrefix("pkill") }, "\(f.calls())")
        XCTAssertFalse(f.exists(f.app))
        XCTAssertFalse(f.exists(f.sudoers))
    }
}

// MARK: - Fixture

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// One file for each distinct fake text, in a directory of this test
/// process, which every fixture's bin links to (see writeFake). Fixtures
/// never write to a fake or change its mode, which would change it for
/// every fixture: a test that needs another fake writes a new file in its
/// place. The directory is removed when the process exits; a process that
/// is killed leaves it in TMPDIR.
private final class SharedFakes: @unchecked Sendable {
    private static let shared = SharedFakes()
    private let lock = NSLock()
    private let dir: URL
    private var files: [String: URL] = [:]
    private var failure: String?

    private init() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-script-fakes-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            failure = "could not create \(dir.path): \(error)"
        }
        atexit { SharedFakes.shared.removeDirectory() }
    }

    private func removeDirectory() {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Links `url` to the shared file holding `text`, written and made
    /// executable the first time that text is asked for.
    static func link(_ text: String, to url: URL) throws {
        try shared.link(text, to: url)
    }

    private func link(_ text: String, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw FixtureError(failure) }
        let source: URL
        if let known = files[text] {
            source = known
        } else {
            source = dir.appendingPathComponent("fake.\(files.count)")
            try text.write(to: source, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
            files[text] = source
        }
        try FileManager.default.linkItem(at: source, to: url)
    }
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

    var backstop: URL { repoScripts.appendingPathComponent("backstop.sh") }
    var uninstall: URL { repoScripts.appendingPathComponent("uninstall.sh") }
    var install: URL { repoScripts.appendingPathComponent("install.sh") }
    var installRedirected: URL { repoScripts.appendingPathComponent("install.redirected.sh") }
    /// installRedirected with a 1 s limit for each bounded call.
    var session: URL { home.appendingPathComponent("session.json") }
    var state: URL { home.appendingPathComponent("state.json") }
    var config: URL { home.appendingPathComponent("config.json") }
    var lock: URL { home.appendingPathComponent(".recovery.lock") }
    /// backstop.sh as install.sh seals it into the bundle.
    var installedBackstop: URL { app.appendingPathComponent("Contents/Resources/backstop.sh") }
    /// The writable copy installs before the sealed layout left here.
    var legacyBackstop: URL { home.appendingPathComponent("backstop.sh") }
    /// What the fake codesign prints as the bundle's designated requirement.
    let requirement = "cdhash H\"0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c\""
    var logFile: URL { home.appendingPathComponent("Logs/insomnia.log") }
    var plist: URL { home.appendingPathComponent("LaunchAgents/com.insomnia.backstop.plist") }
    var fakePmset: String { bin.appendingPathComponent("pmset").path }
    /// install.sh's VISUDO in its copies: the fake visudo.
    var visudoPath: String { bin.appendingPathComponent("visudo").path }
    /// How the fake sudo logs install.sh's check of its candidate rule.
    var visudoCall: String { "sudo \(visudoPath)" }
    /// SUDOERS_LOCK in the copies of install.sh and uninstall.sh: a dotted
    /// name beside the rule, as in production. The path has every symlink
    /// resolved (TMPDIR is under /var, a link to /private/var), because
    /// root's check of the folders above it refuses a link.
    var sudoersLock: URL {
        URL(fileURLWithPath: Self.resolved(root.path)).appendingPathComponent("etc/sudoers.d/.insomnia-sudoers.lock")
    }
    /// What `contents(of:)` lists in the rule's folder after a transaction:
    /// the lock file, which is never removed, and the rule.
    var sudoersFolderAfterTransaction: [String] { [sudoersLock.lastPathComponent, sudoers.lastPathComponent].sorted() }

    /// `path` with every symlink resolved (realpath(3)), or as given when it
    /// does not exist.
    static func resolved(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }
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
        for dir in [home, bin, repoScripts, appsDir, sudoers.deletingLastPathComponent(), root.appendingPathComponent("tmp", isDirectory: true)] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // repo/ is a source checkout to install.sh and uninstall.sh: their
        // folder is scripts/, with Package.swift one level up.
        try "// swift-tools-version: 6.2\n".write(to: root.appendingPathComponent("repo/Package.swift"), atomically: true, encoding: .utf8)
        try writeFakes()
        try writeScriptCopies()
        try bootUUID.write(to: root.appendingPathComponent("boot.uuid"), atomically: true, encoding: .utf8)
        // The process the fake pgrep reports by default is the installed app.
        try psComm([(4242, installedExecutable.path)])
    }

    /// Executable of the installed bundle, what `ps -o comm=` prints for a
    /// copy of this app that LaunchServices launched from $APP.
    var installedExecutable: URL { app.appendingPathComponent("Contents/MacOS/Insomnia") }

    /// What `ps -o comm= -p <pid>` prints for each pid; a pid not listed is gone.
    func psComm(_ rows: [(pid: Int, exe: String)]) throws {
        let text = rows.map { "\($0.pid)|\($0.exe)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("ps.comm"), atomically: true, encoding: .utf8)
    }

    /// What `ps -o uid= -p <pid>` prints for each listed pid, for a process
    /// in another account; other pids in ps.comm are the test account's.
    func psUid(_ rows: [(pid: Int, uid: Int)]) throws {
        let text = rows.map { "\($0.pid)|\($0.uid)" }.joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("ps.uid"), atomically: true, encoding: .utf8)
    }

    /// What the fake ps answers for `pid`'s user ID instead of a number:
    /// "fail", "hang", "garbage" or "empty" (see the fake).
    func psUidAnswer(_ pid: Int, _ answer: String) throws {
        try "\(pid)|\(answer)\n".write(to: root.appendingPathComponent("ps.uid"), atomically: true, encoding: .utf8)
    }

    /// A uid that is not the test account's.
    static let otherUid = Int(getuid()) + 1

    /// Whether `call` is a logged sudo call other than uninstall.sh's
    /// `sudo -v`, which asks for the password before the recovery lock and
    /// runs nothing as root.
    static func runsAsRoot(_ call: String) -> Bool { call.hasPrefix("sudo") && call != "sudo -v" }

    /// The account running the tests, which is what uninstall.sh's `id -un`
    /// prints.
    static let account = String(cString: getpwuid(getuid())!.pointee.pw_name)

    /// The rule install.sh writes for `account`.
    static func sudoersRule(for account: String) -> String {
        let grants = ["-a disablesleep 1", "-a disablesleep 0", "-b lowpowermode 1", "-b lowpowermode 0"]
            .map { "\(account) ALL=(root) NOPASSWD: /usr/bin/pmset \($0)" }
        return (["# Installed by Insomnia install.sh. Exactly four commands, nothing else."] + grants)
            .joined(separator: "\n") + "\n"
    }

    /// What installMachinery writes to the sudoers path: this account's rule.
    var sudoersRule: String { Self.sudoersRule(for: Self.account) }

    /// How the fake sudo logs a rule's text handed to root: trailing
    /// newlines cut (as `$(...)` reads it), each other newline as "\n".
    static func loggedRuleText(_ text: String) -> String {
        var t = Substring(text)
        while t.hasSuffix("\n") { t = t.dropLast() }
        return t.replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Pids the fake pgrep prints whenever its mode says "running".
    func pgrepPids(_ pids: [Int]) throws {
        let text = pids.map(String.init).joined(separator: "\n") + "\n"
        try text.write(to: root.appendingPathComponent("pgrep.pids"), atomically: true, encoding: .utf8)
    }

    /// Another app bundle inside the fixture, named Insomnia.app like the
    /// API client, whose Info.plist declares `bundleId`. Returns the path
    /// its executable would show in `ps -o comm=`.
    func otherBundle(in dir: String, bundleId: String) throws -> URL {
        let bundle = root.appendingPathComponent(dir, isDirectory: true).appendingPathComponent("Insomnia.app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "binary".write(to: bundle.appendingPathComponent("Contents/MacOS/Insomnia"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>\(bundleId)</string></dict></plist>
        """.write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return bundle.appendingPathComponent("Contents/MacOS/Insomnia")
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

    /// What the fake sudo's signal receiver `pid` logged (see
    /// signalReceiverHere): its parent, the supervisor that started it, and
    /// the sender of each SIGTERM and each SIGHUP it got, in order. A
    /// sender the kernel did not name is left out, so it shows as a missing
    /// entry.
    func signalSenders(of pid: pid_t) throws -> (parent: pid_t, term: [pid_t], hup: [pid_t]) {
        let text = (try? String(contentsOf: root.appendingPathComponent("signals.log"), encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n").map(String.init)
        let prefix = "ready pid=\(pid) ppid="
        guard let ready = lines.lastIndex(where: { $0.hasPrefix(prefix) }),
              let parent = pid_t(lines[ready].dropFirst(prefix.count)) else {
            throw FixtureError("no readiness line for pid \(pid) in signals.log: \(lines)")
        }
        let after = lines[(ready + 1)...]
        func senders(_ name: String) -> [pid_t] {
            after.filter { $0.hasPrefix("\(name) from ") }.compactMap { pid_t($0.dropFirst(name.count + 6)) }
        }
        return (parent, senders("TERM"), senders("HUP"))
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
            "MV": bin.appendingPathComponent("mv").path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "COMMAND_TIMEOUT_SECONDS": "1",
            "KILL_GRACE_SECONDS": "1",
        ]).write(to: backstop, atomically: true, encoding: .utf8)

        try writeUninstallCopy(extraConstants: [:])

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

    /// uninstall.sh: every tool that changes or asks the system is a fake,
    /// and the rule, its lock and the app are the fixture's. ROOT_UID is the
    /// account running the tests, which owns every file the fake sudo's root
    /// shell checks. A test that needs another constant (a longer
    /// CALL_TIMEOUT_SECONDS, while a gate holds the fake sudo) rewrites the
    /// copy with it.
    func writeUninstallCopy(extraConstants: [String: String]) throws {
        let uninstallText = try String(contentsOf: Self.productionScripts.appendingPathComponent("uninstall.sh"), encoding: .utf8)
        try Self.patch(uninstallText, [
            "PGREP": bin.appendingPathComponent("pgrep").path,
            "PS": bin.appendingPathComponent("ps").path,
            "OSASCRIPT": bin.appendingPathComponent("osascript").path,
            "LAUNCHCTL": bin.appendingPathComponent("launchctl").path,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
            "DEFAULTS": bin.appendingPathComponent("defaults").path,
            "PLUTIL": bin.appendingPathComponent("plutil").path,
            "KILL": bin.appendingPathComponent("kill").path,
            "CP": bin.appendingPathComponent("cp").path,
            "APP": app.path,
            "SUDOERS": sudoers.path,
            "SUDOERS_LOCK": sudoersLock.path,
            "ROOT_UID": uid,
            "LOCK_TIMEOUT_SECONDS": "1",
            "QUIT_WAIT_SECONDS": "1",
            "CALL_TIMEOUT_SECONDS": "5",
        ].merging(extraConstants) { $1 }).write(to: uninstall, atomically: true, encoding: .utf8)
    }

    /// install.sh: every $HOME-derived path and every tool is redirected
    /// into the fixture (signing, sudo, launchctl included; the build goes
    /// through the patched build-app.sh above). Tests that need another
    /// constant (the real CODESIGN) rewrite both copies with it.
    func writeInstallCopies(extraConstants: [String: String]) throws {
        let installText = try String(contentsOf: Self.productionScripts.appendingPathComponent("install.sh"), encoding: .utf8)
        let patchedInstall = try Self.patch(installText, installConstants(appsDir: appsDir, home: home).merging(extraConstants) { $1 })
        try patchedInstall.write(to: install, atomically: true, encoding: .utf8)
        // The redirected copy runs past the INSOMNIA_HOME refusal: that
        // variable is what makes the backstop copy it installs act on the
        // fixture instead of ~/Library. The plain copy keeps the refusal.
        let redirected = try Self.replaceOnce(patchedInstall, #"if [[ -n "${INSOMNIA_HOME:-}" ]]; then"#, with: "if false; then")
        try redirected.write(to: installRedirected, atomically: true, encoding: .utf8)
    }

    /// install.sh's constants for a home at `home` with its Applications
    /// folder at `appsDir`: the rest (sudoers rule, its lock, the tools) is
    /// the fixture's, shared by every home.
    private func installConstants(appsDir: URL, home: URL) -> [String: String] {
        [
            "QUIT_WAIT_SECONDS": "1",
            "APP_DIR": appsDir.path,
            "APP_SUPPORT": home.path,
            "LOG_DIR": home.appendingPathComponent("Logs").path,
            "LAUNCH_AGENTS": home.appendingPathComponent("LaunchAgents").path,
            "SUDOERS": sudoers.path,
            "SUDOERS_LOCK": sudoersLock.path,
            "ROOT_UID": uid,
            "VISUDO": visudoPath,
            "CHOWN": bin.appendingPathComponent("chown").path,
            "PGREP": bin.appendingPathComponent("pgrep").path,
            "PS": bin.appendingPathComponent("ps").path,
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
            "PLUTIL": bin.appendingPathComponent("plutil").path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "CALL_TIMEOUT_SECONDS": "5",
        ]
    }

    /// Another account's install: a redirected copy of install.sh (see
    /// writeInstallCopies) for a home of its own under root/<name>, with
    /// its own Applications folder, Application Support (and so its own
    /// recovery lock), Logs and LaunchAgents, and the fixture's sudoers
    /// rule, sudoers lock and fakes. Run it with USER set to `name` and
    /// INSOMNIA_HOME set to the returned home.
    func otherHomeInstall(_ name: String) throws -> (script: URL, home: URL, app: URL) {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let apps = base.appendingPathComponent("Applications", isDirectory: true)
        let otherHome = base.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherHome.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
        let installText = try String(contentsOf: Self.productionScripts.appendingPathComponent("install.sh"), encoding: .utf8)
        let patched = try Self.patch(installText, installConstants(appsDir: apps, home: otherHome))
        let redirected = try Self.replaceOnce(patched, #"if [[ -n "${INSOMNIA_HOME:-}" ]]; then"#, with: "if false; then")
        // Beside the fixture's copies, so it builds from the same checkout.
        let script = repoScripts.appendingPathComponent("install.\(name).sh")
        try redirected.write(to: script, atomically: true, encoding: .utf8)
        return (script, otherHome, apps.appendingPathComponent("Insomnia.app", isDirectory: true))
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

    /// What every fake runs first: the fixture's root from the fake's own
    /// path ($0 is <root>/bin/<name>, the absolute path the scripts and the
    /// other fakes call), and that root with its symlinks resolved, as
    /// realpath(3) gives it for a root under /var, /tmp or /etc (links to
    /// /private/...).
    private static let fakePreamble = """
    FAKE_ROOT="${0%/bin/*}"
    case "$FAKE_ROOT" in /var/* | /tmp/* | /etc/*) FAKE_REAL_ROOT="/private$FAKE_ROOT" ;; *) FAKE_REAL_ROOT="$FAKE_ROOT" ;; esac

    """

    /// Writes a fake into bin as a hard link to a file shared by every
    /// fixture in this test process (see SharedFakes). macOS checks an
    /// executable file the first time it runs, which takes 85 to 400 ms per
    /// new file on a test Mac, and each fixture used to write its fakes
    /// anew; a link to a file that has already run is not checked again.
    /// So that one file serves every fixture, the fixture's root in `body`
    /// becomes ${FAKE_ROOT} (${FAKE_REAL_ROOT} where it was resolved),
    /// which the preamble derives at run time. Every path in the fakes is
    /// inside a double-quoted word or an argument list, never inside single
    /// quotes, so the variables expand where the paths stood.
    private func writeFake(_ name: String, _ body: String) throws {
        let realRoot = Self.resolved(root.path)
        let derived = ["/var/", "/tmp/", "/etc/"].contains { root.path.hasPrefix($0) } ? "/private" + root.path : root.path
        guard derived == realRoot else {
            throw FixtureError("the fakes' preamble would resolve \(root.path) to \(derived), not \(realRoot)")
        }
        var text = body
        if realRoot != root.path {
            text = text.replacingOccurrences(of: realRoot, with: "${FAKE_REAL_ROOT}")
        }
        text = text.replacingOccurrences(of: root.path, with: "${FAKE_ROOT}")
        guard !text.contains(root.lastPathComponent) else {
            throw FixtureError("fake \(name) names its fixture other than through FAKE_ROOT")
        }
        try SharedFakes.link("#!/bin/bash\n" + Self.fakePreamble + text, to: bin.appendingPathComponent(name))
    }

    private func writeFakes() throws {
        let calls = callsLog.path
        let r = root.path
        let resolvedRoot = Self.resolved(root.path)
        let visudo = visudoPath
        // sudo: `-n <cmd>` is the pmset path and succeeds or fails by mode
        // without running anything. /bin/test and /bin/cat (or the fake cat,
        // for a copy that reads through it) run unprivileged, and only on a
        // path inside the fixture. /bin/bash runs only the
        // sudoers transactions (install.sh's sudoers_replace, uninstall.sh's
        // sudoers_remove), unprivileged, only when the rule they would write
        // or remove and the lock their script takes are inside the fixture,
        // and is logged as "sudo <name> <arguments>" without the script, a
        // newline in an argument (the rule's text) logged as "\n". Those
        // three may follow `-n`, as uninstall.sh calls them under the
        // recovery lock; they are logged as "sudo -n ...". `-v` (uninstall.sh
        // asking for the password before the lock) is logged and succeeds;
        // when sudo-v.info exists, it is first moved over the installed
        // bundle's Info.plist, the way an install in another session could
        // replace the app while the prompt waits. When the run's
        // FAKE_SUDO_GATE names a file that exists, the transaction first
        // logs "sudo GATED <name>", creates "<gate>.waiting" and waits until
        // the test removes the gate (or the fixture goes, or 60 s pass), so
        // a test can act between a run's read of the rule and its write.
        // Mode "hang" behaves like a pmset that never returns.
        // Mode "auth-fail": every form that would prompt (visudo, the
        // transactions, `-v`) fails like a wrong password, and `-n` forms
        // fail as unpermitted.
        // Modes for the transactions (see sudoHangHere): "txn-hangs-before"
        // never runs it and stops on SIGTERM; "txn-fails-after" runs it and
        // then exits 143, as a sudo killed by SIGTERM; "txn-hangs-after"
        // runs it and then does not answer until SIGTERM;
        // "txn-ignores-term-after" runs it and then ignores SIGTERM until
        // the test releases it; "txn-drops-fd9-receives-after" closes its
        // fd 9 the way sudo does, runs it and then waits in
        // signalReceiverHere's receiver until the test releases it.
        // Mode "rule-not-effective": authentication passes and the rule is
        // installed, but `sudo -n -l <pmset ...>` still says no. Mode
        // "rule-gone-under-lock": `sudo -n -l` says yes while nobody holds
        // the recovery lock and no while someone does, the way a rule removed
        // by an uninstall.sh that held the lock first answers to a run that
        // then takes it. In mode "rule-check-hangs" `sudo -n -l` never
        // answers and ignores SIGTERM; in "rule-check-hangs-under-lock" it
        // never answers while the lock is held and stops on SIGTERM; in
        // "rule-check-ignores-term-under-lock" it never answers while the
        // lock is held and ignores SIGTERM (see sudoHangHere).
        // The fake visudo checks the file it is given (see below).
        try writeFake("sudo", """
        nflag=""
        if [[ "${1:-}" == -n ]]; then
          case "${2:-}" in /bin/test|/bin/cat|"\(bin.path)/cat"|/bin/bash) nflag="-n "; shift ;; esac
        fi
        # Bash 3.2 turns an empty argument in "${*:4}" into a \\177 byte, so
        # the arguments from the fourth on are joined after a shift instead.
        from_fourth() { shift 3; a="$*"; }
        if [[ "${1:-}" == /bin/bash ]]; then from_fourth "$@"; printf 'sudo %s%s\\n' "$nflag" "${a//$'\\n'/\\\\n}"; else printf 'sudo %s%s\\n' "$nflag" "$*"; fi >> "\(calls)"
        mode="$(cat "\(r)/sudo.mode" 2>/dev/null || echo ok)"
        if [[ -n "$nflag" && "$mode" == auth-fail ]]; then echo "sudo: a password is required" >&2; exit 1; fi
        \(sudoHangHere())
        \(lockHeldHere())
        \(signalReceiverHere())
        # "ignore-term" and "closes-fd9" behave like a pmset that ignores
        # SIGTERM: they live until the test creates the release file (or the
        # fixture is destroyed, or a 60 s wall-clock watchdog), so a test decides when
        # the command ends instead of racing a wall-clock sleep. On exit they
        # write command.ended = released | watchdog, so a test can tell a
        # command that is still alive (no file) from one that ended, and why.
        case "${1:-}" in
          -v) if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
              if [[ -f "\(r)/sudo-v.info" ]]; then /bin/mv -f "\(r)/sudo-v.info" "\(appInfo.path)"; fi
              exit 0 ;;
          -n) if [[ "${2:-}" == -l ]]; then
                case "$mode" in
                  auth-fail|rule-not-effective) exit 1 ;;
                  rule-gone-under-lock) if lock_held; then exit 1; fi; exit 0 ;;
                  rule-check-hangs) hang_on_term ignore ;;
                  rule-check-hangs-under-lock) if lock_held; then hang_on_term stop; fi; exit 0 ;;
                  rule-check-ignores-term-under-lock) if lock_held; then hang_on_term ignore; fi; exit 0 ;;
                  *) exit 0 ;;
                esac
              fi
              case "$mode" in
                ok) exit 0 ;;
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
                # "drops-fd9-logs-signals": closes its fd 9 the way sudo
                # does, then waits like "logs-term", logging every SIGTERM
                # and SIGHUP with its sender (see signalReceiverHere).
                drops-fd9-logs-signals) exec 9<&-; receive_signals ;;
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
                      if [[ "$(cat "$f" 2>/dev/null)" == "$$" ]]; then base="${f%.pid}"; break 2; fi
                    done
                    /bin/sleep 0.1
                  done
                  [[ -n "$base" ]] || exit 0
                  cat "\(r)/sentinel.pid" > "$base.pid"
                  /usr/bin/mkfifo "$base.rc"
                  printf 'sudo STATUS-DELAYED\\n' >> "\(calls)"
                  exit 0 ;;
                *) exit 1 ;;
              esac ;;
          "\(visudo)")
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            # "swap-prebuilt": someone replaces the --app bundle at its path
            # (writePrebuiltApp's dist/Insomnia.app) while the password prompt waits.
            if [[ "$mode" == swap-prebuilt ]]; then printf 'swapped' > "\(r)/dist/Insomnia.app/Contents/MacOS/Insomnia"; fi
            exec "$@" ;;
          /bin/test|/bin/cat|"\(bin.path)/cat")
            for a in "$@"; do
              case "$a" in "\(r)"/*) exec "$@" ;; esac
            done
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          /bin/bash)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            case "${2:-}|${4:-}" in
              "-c|insomnia-sudoers-replace") rule="${6:-}" ;;
              "-c|insomnia-sudoers-remove") rule="${5:-}" ;;
              *) printf 'sudo REFUSED %s\\n' "${*:4}" >> "\(calls)"; exit 1 ;;
            esac
            case "$rule|$3" in
              "\(r)"/*"|"*"SUDOERS_LOCK=\(resolvedRoot)/"*) ;;
              *) printf 'sudo REFUSED %s\\n' "${*:4}" >> "\(calls)"; exit 1 ;;
            esac
            if [[ -n "${FAKE_SUDO_GATE:-}" && -e "$FAKE_SUDO_GATE" ]]; then
              printf 'sudo GATED %s\\n' "$4" >> "\(calls)"
              : > "$FAKE_SUDO_GATE.waiting"
              deadline=$(( SECONDS + 60 ))
              while [[ -e "$FAKE_SUDO_GATE" && -d "\(r)" ]] && (( SECONDS < deadline )); do /bin/sleep 0.05; done
            fi
            case "$mode" in
              txn-hangs-before) hang_on_term stop ;;
              txn-fails-after) "$@"; printf 'sudo TXN-EXITED %s\\n' "$?" >> "\(calls)"; exit 143 ;;
              txn-hangs-after) "$@"; printf 'sudo TXN-EXITED %s\\n' "$?" >> "\(calls)"; hang_on_term stop ;;
              txn-ignores-term-after) "$@"; printf 'sudo TXN-EXITED %s\\n' "$?" >> "\(calls)"; hang_on_term ignore ;;
              txn-drops-fd9-receives-after) exec 9<&-; "$@"; printf 'sudo TXN-EXITED %s\\n' "$?" >> "\(calls)"; receive_signals ;;
            esac
            exec "$@" ;;
          *) exit 1 ;;
        esac
        """)
        try writeFake("pmset", """
        printf 'pmset DIRECT %s\\n' "$*" >> "\(calls)"
        exit 99
        """)
        // visudo: install.sh's VISUDO, for its check before the transaction
        // and the transaction's check of the copy beside the rule. Logged as
        // "visudo <arguments>". It passes a file that exists, is not empty
        // and grants pmset, so a check of the wrong path or of an empty
        // heredoc fails. In mode "reject-staged" it also fails every copy
        // beside the rule (a name that starts with the rule's and a dot). In
        // mode "replace-rule-staged", checking such a copy first puts the
        // text of visudo.replacement at the rule's path by a rename (a new
        // file, the way another writer that takes no lock would), logged as
        // "visudo REPLACED-RULE", and then checks the copy as usual. In mode
        // "rewrite-rule-staged" it writes that text into the rule in place
        // instead (the same file), logged as "visudo REWROTE-RULE".
        try writeFake("visudo", """
        printf 'visudo %s\\n' "$*" >> "\(calls)"
        f=""; for a in "$@"; do f="$a"; done
        if [[ "$(cat "\(r)/visudo.mode" 2>/dev/null)" == reject-staged && "$f" == "\(sudoers.path)".* ]]; then
          printf 'visudo REJECTED %s\\n' "$f" >> "\(calls)"; exit 1
        fi
        if [[ "$(cat "\(r)/visudo.mode" 2>/dev/null)" == replace-rule-staged && "$f" == "\(sudoers.path)".* ]]; then
          /bin/cp "\(r)/visudo.replacement" "\(r)/visudo.new" && /bin/mv -f "\(r)/visudo.new" "\(sudoers.path)"
          printf 'visudo REPLACED-RULE\\n' >> "\(calls)"
        fi
        if [[ "$(cat "\(r)/visudo.mode" 2>/dev/null)" == rewrite-rule-staged && "$f" == "\(sudoers.path)".* ]]; then
          /bin/cat "\(r)/visudo.replacement" > "\(sudoers.path)" && printf 'visudo REWROTE-RULE\\n' >> "\(calls)"
        fi
        [[ -s "$f" ]] && grep -q 'NOPASSWD: /usr/bin/pmset' "$f" || { printf 'sudo VISUDO-REJECTED %s\\n' "$*" >> "\(calls)"; exit 1; }
        exit 0
        """)
        // chown: install.sh's CHOWN, which only root can run as the
        // transaction does; logged, and nothing changes.
        try writeFake("chown", """
        printf 'chown %s\\n' "$*" >> "\(calls)"
        exit 0
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
        // refused rename, and both paths stay as they were. A line of
        // mv.killed in the same form makes the move and then ends this mv by
        // SIGTERM, logging "mv KILLED <from> <to>": a rename done by an mv
        // that did not live to say so.
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
        if [[ -f "\(r)/mv.killed" ]]; then
          while IFS='|' read -r f t || [[ -n "$f" ]]; do
            if [[ -n "$f" && "$from" == $f && "$to" == $t ]]; then
              /bin/mv "$@" || exit
              printf 'mv KILLED %s %s\\n' "$from" "$to" >> "\(calls)"
              kill -TERM $$
              exit 143
            fi
          done < "\(r)/mv.killed"
        fi
        exec /bin/mv "$@"
        """)
        // rm, rmdir, mktemp, mkdir: install.sh's RM, RMDIR, MKTEMP and MKDIR.
        // Each call is logged and then made by the real tool, so a test can
        // tell a file removed or created through the fixed-path variable from
        // one handled by a bare name. (Its CHMOD is the chmod fake below.)
        // An rm of a path that matches the bash glob in rm.killed removes it
        // and then ends by SIGTERM, logging "rm KILLED <path>".
        for (tool, real) in [("rm", "/bin/rm"), ("rmdir", "/bin/rmdir"), ("mktemp", "/usr/bin/mktemp"), ("mkdir", "/bin/mkdir")] {
            let killed = tool != "rm" ? "" : """
            if [[ -f "\(r)/rm.killed" ]]; then
              IFS= read -r pattern < "\(r)/rm.killed" || true
              for a in "$@"; do
                if [[ -n "$pattern" && "$a" != -* && "$a" == $pattern ]]; then
                  /bin/rm "$@" || exit
                  printf 'rm KILLED %s\\n' "$a" >> "\(calls)"
                  kill -TERM $$
                  exit 143
                fi
              done
            fi
            """
            try writeFake(tool, """
            printf '\(tool)%s\\n' "${*:+ $*}" >> "\(calls)"
            \(killed)
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
        mode="$(cat "\(r)/codesign.mode" 2>/dev/null || echo ok)"
        \(hangHere("codesign"))
        \(lockHeldHere())
        signing="$(cat "\(r)/codesign.signing" 2>/dev/null || echo adhoc)"
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
        // `-o comm= -p <pid>` (install.sh / uninstall.sh identifying a pid
        // the fake pgrep reported) answers from ps.comm instead: "pid|path"
        // per line, and a pid with no line is gone (exit 1, no output).
        // `-o uid= -p <pid>` answers from ps.uid ("pid|uid" per line), padded
        // like the real column; a pid listed only in ps.comm belongs to the
        // account running the tests. A uid of "fail" exits 1 with an error,
        // "hang" never answers (see hangHere), "garbage" prints a word that
        // is not a user ID and "empty" prints nothing, both with exit 0.
        try writeFake("ps", """
        printf 'ps %s\\n' "$*" >> "\(calls)"
        \(hangHere("ps"))
        pid=""; for a in "$@"; do pid="$a"; done
        if [[ "${2:-}" == uid= ]]; then
          if [[ -f "\(r)/ps.uid" ]]; then
            while IFS='|' read -r p u; do
              if [[ "$p" == "$pid" ]]; then
                case "$u" in
                  fail) echo "ps: cannot read process $pid" >&2; exit 1 ;;
                  hang) hang_here ;;
                  garbage) echo "  root?"; exit 0 ;;
                  empty) exit 0 ;;
                esac
                printf '%5s\\n' "$u"; exit 0
              fi
            done < "\(r)/ps.uid"
          fi
          [[ -f "\(r)/ps.comm" ]] || exit 1
          while IFS='|' read -r p exe; do
            if [[ "$p" == "$pid" ]]; then printf '%5s\\n' "$UID"; exit 0; fi
          done < "\(r)/ps.comm"
          exit 1
        fi
        if [[ "${2:-}" == comm= ]]; then
          [[ -f "\(r)/ps.comm" ]] || exit 1
          while IFS='|' read -r p exe; do
            if [[ "$p" == "$pid" ]]; then printf '%s\\n' "$exe"; exit 0; fi
          done < "\(r)/ps.comm"
          exit 1
        fi
        mode="$(cat "\(r)/ps.mode" 2>/dev/null || echo ok)"
        if [[ "$mode" == fail ]]; then echo "ps: cannot read process table" >&2; exit 2; fi
        if [[ "$mode" == garbage ]]; then echo "not a process line"; exit 0; fi
        [[ -f "\(r)/ps.table" ]] || exit 1
        while IFS='|' read -r p lstart stat uid; do
          if [[ "$p" == "$pid" ]]; then printf '%s %s %s\\n' "$lstart" "$stat" "$uid"; exit 0; fi
        done < "\(r)/ps.table"
        exit 1
        """)
        try writeFake("kill", """
        printf 'kill %s\\n' "$*" >> "\(calls)"
        fail="$(cat "\(r)/kill.fail.mode" 2>/dev/null || true)"
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
          case "$(cat "\(r)/sysctl.mode" 2>/dev/null || echo ok)" in
            intel-0) echo 0 ;;
            intel-missing) echo "sysctl: unknown oid 'hw.optional.arm64'" >&2; exit 1 ;;
            *) echo 1 ;;
          esac
          exit 0
        fi
        cat "\(r)/boot.uuid"
        """)
        // chmod: recorded in chmod.calls, apart from calls.log, then run for
        // real so the modes still change. A path that a line of chmod.fail
        // (a bash glob; a plain path matches only itself) matches fails the
        // way an immutable file does.
        try writeFake("chmod", """
        printf 'chmod %s\\n' "$*" >> "\(r)/chmod.calls"
        if [[ -f "\(r)/chmod.fail" ]]; then
          while IFS= read -r p || [[ -n "$p" ]]; do
            if [[ -n "$p" && "${2:-}" == $p ]]; then
              echo "chmod: ${2:-}: Operation not permitted" >&2
              exit 1
            fi
          done < "\(r)/chmod.fail"
        fi
        exec /bin/chmod "$@"
        """)
        // cp: the CP of uninstall.sh and of backstop copies that read
        // through fakes, which copy session.json and state.json into the
        // run's own folder before reading them. Recorded in cp.calls, apart
        // from calls.log, then made by the real tool, unless a line of
        // cp.hang (never answers; see hangHere) or cp.fail (exits 1 like an
        // unreadable file), a bash glob, matches the file copied: the first
        // argument that is not an option such as -X.
        try writeFake("cp", """
        printf 'cp %s\\n' "$*" >> "\(r)/cp.calls"
        \(hangHere("cp"))
        src=""
        for a in "$@"; do [[ "$a" == -* ]] || { src="$a"; break; }; done
        if [[ -f "\(r)/cp.hang" ]]; then
          while IFS= read -r p || [[ -n "$p" ]]; do [[ -n "$p" && "$src" == $p ]] && hang_here; done < "\(r)/cp.hang"
        fi
        if [[ -f "\(r)/cp.fail" ]]; then
          while IFS= read -r p || [[ -n "$p" ]]; do
            if [[ -n "$p" && "$src" == $p ]]; then echo "cp: $src: Permission denied" >&2; exit 1; fi
          done < "\(r)/cp.fail"
        fi
        if [[ -f "\(r)/cp.fifo" ]]; then
          while IFS= read -r p || [[ -n "$p" ]]; do
            if [[ -n "$p" && "$src" == $p ]]; then /bin/rm -f "$src" && /usr/bin/mkfifo -m 600 "$src"; fi
          done < "\(r)/cp.fifo"
        fi
        exec /bin/cp "$@"
        """)
        // cat and stat: the CAT and STAT of backstop copies that read
        // through fakes (readingBackstop), and the CAT of install.sh and
        // uninstall.sh copies whose root shell reads the rule through one.
        // Made by the real tool unless a line of <tool>.hang (never answers;
        // see hangHere) or <tool>.fail (exits 1), a bash glob, matches one
        // of the arguments. cat with no arguments, as root's read of the
        // rule calls it, counts those calls in cat.stdin.count; on the call
        // cat.stdin.fail names, it copies all of its input and then exits 1.
        for (tool, real) in [("cat", "/bin/cat"), ("stat", "/usr/bin/stat")] {
            let stdinPart = tool != "cat" ? "" : """
            if (( $# == 0 )); then
              n=$(( $(/bin/cat "\(r)/cat.stdin.count" 2>/dev/null || echo 0) + 1 ))
              echo "$n" > "\(r)/cat.stdin.count"
              if [[ "$(/bin/cat "\(r)/cat.stdin.fail" 2>/dev/null)" == "$n" ]]; then
                /bin/cat
                echo "cat: stdin: Input/output error" >&2
                exit 1
              fi
            fi
            """
            try writeFake(tool, """
            \(hangHere(tool))
            \(stdinPart)
            for a in "$@"; do
              if [[ -f "\(r)/\(tool).hang" ]]; then
                while IFS= read -r p || [[ -n "$p" ]]; do [[ -n "$p" && "$a" == $p ]] && hang_here; done < "\(r)/\(tool).hang"
              fi
              if [[ -f "\(r)/\(tool).fail" ]]; then
                while IFS= read -r p || [[ -n "$p" ]]; do
                  if [[ -n "$p" && "$a" == $p ]]; then echo "\(tool): $a: Input/output error" >&2; exit 1; fi
                done < "\(r)/\(tool).fail"
              fi
            done
            exec \(real) "$@"
            """)
        }
        // ls: the LS of install.sh and uninstall.sh copies whose root shell
        // lists access control lists through a fake. Counts its calls in
        // ls.count. On the call ls.rewrite names, it first writes the text
        // of rule.replacement into the rule in place (the same file, logged
        // "ls REWROTE-RULE"); on the call ls.replace names, it first puts
        // that text at the rule's path by a rename (a new file, logged "ls
        // REPLACED-RULE"); on the call ls.acl names, it first gives the
        // rule's folder an entry "everyone allow add_file" (logged "ls
        // ADDED-ACL"). Then, for an argument a line of ls.fail (a bash
        // glob) matches, it exits 1. Otherwise it prints what /bin/ls -lde
        // prints, with a "+" after the mode of each file a line of ls.plus
        // matches and a line "unexpected line" after each one a line of
        // ls.extra matches.
        try writeFake("ls", """
        n=$(( $(/bin/cat "\(r)/ls.count" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "\(r)/ls.count"
        if [[ "$(/bin/cat "\(r)/ls.rewrite" 2>/dev/null)" == "$n" ]]; then
          /bin/cat "\(r)/rule.replacement" > "\(sudoers.path)" && printf 'ls REWROTE-RULE\\n' >> "\(calls)"
        fi
        if [[ "$(/bin/cat "\(r)/ls.replace" 2>/dev/null)" == "$n" ]]; then
          /bin/cp "\(r)/rule.replacement" "\(r)/rule.new" && /bin/mv -f "\(r)/rule.new" "\(sudoers.path)" && printf 'ls REPLACED-RULE\\n' >> "\(calls)"
        fi
        if [[ "$(/bin/cat "\(r)/ls.acl" 2>/dev/null)" == "$n" ]]; then
          /bin/chmod +a "everyone allow add_file" "\(sudoers.deletingLastPathComponent().path)" && printf 'ls ADDED-ACL\\n' >> "\(calls)"
        fi
        matches() { # globs name
          [[ -f "$1" ]] || return 1
          local p
          while IFS= read -r p || [[ -n "$p" ]]; do [[ -n "$p" && "$2" == $p ]] && return 0; done < "$1"
          return 1
        }
        for a in "$@"; do
          if matches "\(r)/ls.fail" "$a"; then echo "ls: $a: Permission denied" >&2; exit 1; fi
        done
        out="$(/bin/ls "$@")" || exit $?
        while IFS= read -r line; do
          extra=""
          for a in "$@"; do
            [[ "$a" == -* || "$line" != *" $a" ]] && continue
            if matches "\(r)/ls.plus" "$a"; then
              if [[ "${line:10:1}" == [@+] ]]; then line="${line:0:10}+${line:11}"; else line="${line:0:10}+${line:10}"; fi
            fi
            matches "\(r)/ls.extra" "$a" && extra="unexpected line"
          done
          printf '%s\\n' "$line"
          [[ -z "$extra" ]] || printf '%s\\n' "$extra"
        done <<< "$out"
        """)
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
        mode="$(cat "\(r)/insomnia.mode" 2>/dev/null || echo ok)"
        if [[ "$mode" == hold ]]; then
          for (( i = 0; i < 300; i++ )); do
            [[ -f "\(r)/insomnia.release" ]] && break
            /bin/sleep 0.1
          done
          printf 'Insomnia released\\n' >> "\(calls)"
        fi
        if [[ "$mode" == raw ]]; then
          cat "\(r)/insomnia.output"
          exit "$(cat "\(r)/insomnia.status")"
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
          cat "\(r)/date.mode"; echo; exit 0
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
        mode="$(cat "\(r)/defaults.mode" 2>/dev/null || echo ok)"
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
        // order; the last line repeats. Default 1 (not running). A match
        // (exit 0) prints the pids in pgrep.pids, one per line (default
        // 4242, which ps.comm maps to the installed bundle's binary). A
        // line "pids:A,B" is a match that prints those pids instead. A
        // line "hang" never answers; see hangHere.
        try writeFake("pgrep", """
        printf 'pgrep %s\\n' "$*" >> "\(calls)"
        f="\(r)/pgrep.mode"
        [[ -f "$f" ]] || exit 1
        first="$(head -n 1 "$f")"
        if (( $(wc -l < "$f") > 1 )); then tail -n +2 "$f" > "$f.next" && mv "$f.next" "$f"; fi
        \(hangHere("pgrep"))
        if [[ "$first" == hang ]]; then hang_here; fi
        if [[ "$first" == pids:* ]]; then tr ',' '\\n' <<< "${first#pids:}"; exit 0; fi
        if [[ "${first:-1}" == 0 ]]; then
          if [[ -f "\(r)/pgrep.pids" ]]; then cat "\(r)/pgrep.pids"; else echo 4242; fi
        fi
        exit "${first:-1}"
        """)
        // plutil: runs the real tool. Each argument that is an app's
        // Info.plist is appended to plutil.reads first. A call that a line of
        // plutil.hang matches never answers, like a file on a stalled volume
        // (see hangHere); one that a line of plutil.fail matches exits 2
        // with an error, like an I/O error. A line is a bash glob, matched
        // against each argument and against all of them joined by spaces, so
        // a plain path matches every call that reads that file. With
        // plutil.fail.from holding N, only the Nth call that plutil.fail
        // matches and those after it fail (counted in plutil.fail.count).
        try writeFake("plutil", """
        \(hangHere("plutil"))
        all="$*"
        matches() { # list
          local p a
          [[ -f "$1" ]] || return 1
          while IFS= read -r p || [[ -n "$p" ]]; do
            [[ -n "$p" ]] || continue
            [[ "$all" == $p ]] && return 0
            for a in "${args[@]}"; do [[ "$a" == $p ]] && return 0; done
          done < "$1"
          return 1
        }
        args=("$@")
        for a in "$@"; do
          if [[ "$a" == */Contents/Info.plist ]]; then printf '%s\\n' "$a" >> "\(r)/plutil.reads"; fi
        done
        if matches "\(r)/plutil.hang"; then hang_here; fi
        # plutil.nul: answers "true", a NUL byte and a newline, exit 0.
        # plutil.partial: the real answer's first byte, then exit 2.
        if matches "\(r)/plutil.nul"; then printf 'true\\0\\n'; exit 0; fi
        if matches "\(r)/plutil.partial"; then
          /usr/bin/plutil "$@" 2>/dev/null | /usr/bin/head -c 1
          echo "plutil: cut short" >&2
          exit 2
        fi
        if matches "\(r)/plutil.fail"; then
          n=$(( $(cat "\(r)/plutil.fail.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "\(r)/plutil.fail.count"
          if (( n >= $(cat "\(r)/plutil.fail.from" 2>/dev/null || echo 1) )); then
            echo "plutil: \(r)/plutil.fail says this read fails" >&2; exit 2
          fi
        fi
        exec /usr/bin/plutil "$@"
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
        try writeFake("launchctl", """
        printf 'launchctl %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/launchctl.mode" 2>/dev/null || echo ok)"
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
            echo "launchctl APP-BINARY=$(head -n 1 "\(app.path)/Contents/MacOS/Insomnia") during bootstrap" >> "\(calls)"
          else
            echo 'launchctl APP-ABSENT during bootstrap' >> "\(calls)"
          fi
        fi
        \(hangHere("launchctl"))
        if [[ "${1:-}:$mode" == print:print-hangs ]]; then hang_here; fi
        if [[ "${1:-}:$mode" == bootout:bootout-hangs ]]; then hang_here; fi
        prints=0
        if [[ "${1:-}" == print ]]; then
          prints=$(( $(cat "\(r)/print.count" 2>/dev/null || echo 0) + 1 )); echo "$prints" > "\(r)/print.count"
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
          bootout:print-hangs) exit 0 ;;
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

    /// Every app Info.plist the plutil wrapper was asked to read, in order.
    func plistReads() -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("plutil.reads"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Makes every plutil read of `plist` hang.
    func hangPlutil(on plist: URL) throws {
        try (plist.path + "\n").write(to: root.appendingPathComponent("plutil.hang"), atomically: true, encoding: .utf8)
    }

    /// Makes every plutil call that `pattern` (a bash glob, see the fake)
    /// matches hang, or fail with exit 2. With `fromCall` (failing only),
    /// the calls it matches before that one still run.
    func plutilCalls(matching pattern: String, hang: Bool, fromCall: Int = 1) throws {
        try (pattern + "\n").write(to: root.appendingPathComponent(hang ? "plutil.hang" : "plutil.fail"), atomically: true, encoding: .utf8)
        if !hang { try String(fromCall).write(to: root.appendingPathComponent("plutil.fail.from"), atomically: true, encoding: .utf8) }
    }

    /// Makes uninstall.sh's copy of every file `pattern` (a bash glob)
    /// matches hang, or fail with exit 1.
    func copies(matching pattern: String, hang: Bool) throws {
        try (pattern + "\n").write(to: root.appendingPathComponent(hang ? "cp.hang" : "cp.fail"), atomically: true, encoding: .utf8)
    }

    /// Makes the fake cp put a FIFO where a file `pattern` matches was,
    /// just before the real cp opens it.
    func swapForFIFO(matching pattern: String) throws {
        try (pattern + "\n").write(to: root.appendingPathComponent("cp.fifo"), atomically: true, encoding: .utf8)
    }

    /// Makes every call of the fake `tool` (plutil, cat or stat) that
    /// `pattern` matches answer in a given way: "hang", "fail", and for
    /// plutil also "nul" or "partial" (see the fakes).
    func answer(_ tool: String, _ how: String, matching pattern: String) throws {
        try (pattern + "\n").write(to: root.appendingPathComponent("\(tool).\(how)"), atomically: true, encoding: .utf8)
    }

    /// The calls the fake cp recorded.
    func copyCalls() -> [String] {
        ((try? String(contentsOf: root.appendingPathComponent("cp.calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// The sudoers lock as root's transaction leaves it: a regular file with
    /// mode 0600, created here first so a test can hold it (lockf would
    /// create it 0644, which root's check refuses).
    func prepareSudoersLock() throws {
        if !fm.fileExists(atPath: sudoersLock.path) {
            guard fm.createFile(atPath: sudoersLock.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw FixtureError("could not create \(sudoersLock.path)")
            }
        }
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
    /// note an inherited fd 9 and record the pid in `sudo.hung.pid` once the
    /// SIGTERM trap and the watchdog's deadline are in place. The wait loop
    /// reads bash's SECONDS clock and runs no command substitution: a
    /// `$(...)` child is a copy of this shell with the logging trap, so a
    /// signal sent to the whole process group, or one pending when it
    /// forks, can log one SIGTERM twice.
    func sudoHangHere() -> String {
        """
        hang_on_term() {
          calls_log="\(callsLog.path)"
          if { : >&9; } 2>/dev/null; then echo 'sudo FD9-OPEN' >> "$calls_log"; fi
          if [[ "$1" == stop ]]; then
            trap 'echo "sudo SIGTERM" >> "$calls_log"; exit 143' TERM
          else
            trap 'echo "sudo SIGTERM" >> "$calls_log"' TERM
          fi
          deadline=$(( SECONDS + 60 ))
          echo $$ > "\(root.path)/sudo.hung.pid"
          while [[ ! -e "\(root.path)/release" && -d "\(root.path)" ]] && (( SECONDS < deadline )); do /bin/sleep 0.1; done
          if [[ -e "\(root.path)/release" ]]; then echo released > "\(root.path)/command.ended"
          elif [[ -d "\(root.path)" ]]; then echo watchdog > "\(root.path)/command.ended"; fi
          exit 0
        }
        """
    }

    /// Shell function for the fake sudo, or for another fake `tool`:
    /// `receive_signals` replaces the fake
    /// with one perl process that waits like `hang_on_term ignore` and
    /// records who sent each signal. It ignores SIGTERM and SIGHUP after
    /// logging each as "<tool> SIGTERM" / "<tool> SIGHUP", and adds "TERM from
    /// <pid>" / "HUP from <pid>" to signals.log, the sender's pid from the
    /// kernel's siginfo. One process, which starts no other, is the only
    /// receiver, so each delivery is logged once. signals.log starts with
    /// "ready pid=<pid> ppid=<parent>" (the parent is the supervisor that
    /// started the fake), written with `<tool>.hung.pid` once both handlers
    /// and the watchdog's deadline are in place. It notes an inherited fd 9
    /// as "<tool> FD9-OPEN". SIGINT keeps the action the fake inherited
    /// (ignored, in a background job). The handlers run at once (perl's
    /// "unsafe" signals, the only way perl passes siginfo), each with both
    /// signals blocked, while the loop sleeps in select(). The kernel keeps
    /// one sender per process, so a signal that was pending beside another
    /// is logged as sent by 0 (see signalGroupInTurn).
    func signalReceiverHere(_ tool: String = "sudo") -> String {
        """
        receive_signals() {
          exec /usr/bin/perl -MPOSIX -e '
            my ($calls, $evidence, $root) = @ARGV;
            sub note { my ($file, $line) = @_; if (open(my $fh, ">>", $file)) { print $fh "$line\\n"; close $fh } }
            my $mask = POSIX::SigSet->new(POSIX::SIGTERM, POSIX::SIGHUP);
            for my $name ("TERM", "HUP") {
              my $act = POSIX::SigAction->new(sub {
                my ($sig, $info) = @_;
                note($calls, "\(tool) SIG$name");
                note($evidence, "$name from " . (ref $info ? $info->{pid} : "unknown"));
              }, $mask, POSIX::SA_SIGINFO);
              $act->safe(0);
              POSIX::sigaction($name eq "TERM" ? POSIX::SIGTERM : POSIX::SIGHUP, $act) or die "sigaction $name: $!";
            }
            my $dup = POSIX::dup(9);
            if (defined $dup) { POSIX::close($dup); note($calls, "\(tool) FD9-OPEN") }
            my $deadline = time + 60;
            note($evidence, "ready pid=$$ ppid=" . getppid());
            open(my $ready, ">", "$root/\(tool).hung.pid") or die "\(tool).hung.pid: $!";
            print $ready "$$\\n";
            close $ready;
            select(undef, undef, undef, 0.1) while !-e "$root/release" && -d $root && time < $deadline;
            if (-e "$root/release") { note("$root/command.ended", "released") }
            elsif (-d $root) { note("$root/command.ended", "watchdog") }
            exit 0;
          ' "\(callsLog.path)" "\(root.path)/signals.log" "\(root.path)"
        }
        """
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
        try sudoersRule.write(to: sudoers, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "plist".write(to: plist, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "log\n".write(to: logFile, atomically: true, encoding: .utf8)
        try "{}".write(to: config, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: installedBackstop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: backstop, to: installedBackstop)
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
    }

    func log() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    /// Environment for the child: no inheritance, so neither the real HOME
    /// nor a TempHome's INSOMNIA_HOME can leak in. HOME is deliberately
    /// unset (see the class comment).
    private var childEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "INSOMNIA_HOME": home.path,
            // The scripts' scratch folders go in the fixture, so a run a
            // test kills leaves none in the real temporary folder.
            "TMPDIR": root.appendingPathComponent("tmp", isDirectory: true).path,
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
    /// `extraEnvironment` is for install.sh's refusal test and for a
    /// private TMPDIR (see privateTmp). `lastPid` is the script's pid
    /// afterwards: the wrappers exec it, so it is the pid of the process
    /// started here.
    private(set) var lastPid: Int32 = 0

    func run(_ script: URL, _ args: [String] = [], fd9: URL? = nil, ignoringTerm: Bool = false, extraEnvironment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        precondition(fd9 == nil || !ignoringTerm, "fd9 and ignoringTerm are not combined")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        if let fd9 {
            p.arguments = ["-c", #"exec 9<>"$0" && exec /bin/bash "$@""#, fd9.path, script.path] + args
        } else if ignoringTerm {
            p.arguments = ["-c", #"trap '' TERM && exec /bin/bash "$@""#, "bash", script.path] + args
        } else {
            p.arguments = [script.path] + args
        }
        p.environment = childEnvironment.merging(extraEnvironment) { $1 }
        p.currentDirectoryURL = root
        // Capture to files rather than pipes: nothing to drain, nothing to deadlock.
        let outURL = root.appendingPathComponent("stdout.\(UUID().uuidString)")
        let errURL = root.appendingPathComponent("stderr.\(UUID().uuidString)")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        p.standardOutput = out
        p.standardError = err
        let childExit = ProcessExit(p)
        try p.run()
        lastPid = p.processIdentifier
        childExit.wait()
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
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

    /// A script run started in the background by `start`, its standard
    /// output and error going to files.
    struct Started {
        let process: Spawned
        let stdout: URL
        let stderr: URL

        /// Waits for the run to end and reaps it. The status is the exit
        /// status, or -1 if the run was killed by a signal.
        func finish() -> (status: Int32, stdout: String, stderr: String) {
            let raw = process.wait()
            let status: Int32 = raw != -1 && (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : -1
            return (status,
                    (try? String(contentsOf: stdout, encoding: .utf8)) ?? "",
                    (try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
        }
    }

    /// Starts `script` like `run`, without waiting for it, so a test can
    /// run something else while it is in progress; `finish` collects it.
    func start(_ script: URL, extraEnvironment: [String: String] = [:]) throws -> Started {
        let id = UUID().uuidString
        let out = root.appendingPathComponent("stdout.\(id)")
        let err = root.appendingPathComponent("stderr.\(id)")
        let wrapper = root.appendingPathComponent("start.\(id).sh")
        guard ![script, out, err].contains(where: { $0.path.contains("'") }) else { throw FixtureError("fixture path contains a quote: \(script.path)") }
        try "exec /bin/bash '\(script.path)' >'\(out.path)' 2>'\(err.path)'\n".write(to: wrapper, atomically: true, encoding: .utf8)
        return Started(process: try spawn(wrapper, extraEnvironment: extraEnvironment), stdout: out, stderr: err)
    }

    /// Whether `url` exists, or comes to exist within `seconds`.
    func waitForFile(_ url: URL, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if fm.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
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
    /// or a concurrent backstop would, until stopped. With `path`, holds
    /// that lock file instead (the sudoers lock, as a transaction in another
    /// run would).
    func holdLock(_ path: URL? = nil) throws -> LockHolder {
        let lock = path ?? self.lock
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
    func testAnEscapedNameOrUIDDoesNotStopTheAgentAndTheAppRestoresIt() async throws {
        for v in Self.variants() {
            for record in [false, true] {
                for legacy in [false, true] {
                    let label = "\(v.label) record \(record) legacy \(legacy)"
                    let f = try ScriptFixture()
                    defer { f.destroy() }
                    let before = try await appJournal(uid: v.uid, name: v.name, record: record, legacy: legacy, boot: f.bootUUID)
                    if v.label != "plain" {
                        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("\(backslash)\(backslash)u0041"), label)
                    }
                    try before.write(to: f.state)
                    try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))

                    let r = try f.run(f.backstop)

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
        }
    }

    /// uninstall.sh, with and without --purge, runs the backstop it
    /// installed over the same journals: the undo goes as far as for a
    /// plain name, and the saved output, which only the app restores,
    /// stops the removal with the app, the agent and the sudoers rule in
    /// place.
    func testAnEscapedNameOrUIDDoesNotStopTheUndoOfAnUninstall() async throws {
        for v in Self.variants() {
            for record in [false, true] {
                for legacy in [false, true] {
                    for purge in [false, true] {
                        let label = "\(v.label) record \(record) legacy \(legacy) purge \(purge)"
                        let f = try ScriptFixture()
                        defer { f.destroy() }
                        let before = try await appJournal(uid: v.uid, name: v.name, record: record, legacy: legacy, boot: f.bootUUID)
                        try f.installMachinery()
                        try before.write(to: f.state)
                        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))

                        let r = try f.run(f.uninstall, purge ? ["--purge"] : [])

                        XCTAssertNotEqual(r.status, 0, label)
                        XCTAssertTrue(f.exists(f.app), label)
                        XCTAssertTrue(f.exists(f.plist), label)
                        XCTAssertTrue(f.exists(f.sudoers), label)
                        XCTAssertFalse(r.stderr.contains("malformed"), "\(label): \(r.stderr)")
                        XCTAssertTrue(r.stderr.contains("audio") || r.stdout.contains("audio"), "\(label): \(r.stdout) \(r.stderr)")
                        try checkUndone(f, before: before, label)
                    }
                }
            }
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
        for (label, tail) in tails {
            let json = base + tail
            XCTAssertNoThrow(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), label)
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeState(json)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))

            let r = try f.run(f.backstop)

            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr) \(f.log())")
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), label)
            XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, false, label)
            XCTAssertFalse(f.exists(f.session), label)
        }
    }
}
