import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// Behavioural tests for scripts/backstop.sh and scripts/uninstall.sh.
///
/// Each test runs a private COPY of the production script against a
/// throwaway INSOMNIA_HOME. The copy has its fixed tool-path constants
/// (sudo, pmset, ps, kill, sysctl, pgrep, pkill, osascript, launchctl) and
/// its app-bundle / sudoers paths rewritten to point inside the fixture, so
/// nothing privileged runs, no real process is signaled, and no real home,
/// LaunchAgent, sudoers file, or installed app is read or written. plutil,
/// lockf, and date are the real tools. The fakes record every call.
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
            "ps -o lstart=,stat=,uid= -p 4242",
            "kill -CONT 4242",
        ])
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
        try fx.psTable([(111, fx.lstart(started), "T", fx.uid), (222, fx.lstart(started), "T+", fx.uid)])
        fx.setMode("kill.fail", "222")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertTrue(fx.calls().contains("kill -CONT 111"))
        XCTAssertTrue(fx.calls().contains("kill -CONT 222"))
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

    func testGoneRunningOrMismatchedProcessesClearWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[
           {"pid":301,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"},
           {"pid":302,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"},
           {"pid":303,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"},
           {"pid":304,"startedAt":\(started),"startedAtMicros":0,"bootSession":"other-boot"},
           {"pid":305,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "\(fx.calls())")
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

    func testMalformedSessionWithCleanJournalIsReportedAndKept() throws {
        try "not json".write(to: fx.session, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertTrue(fx.exists(fx.session), "unreadable evidence is kept")
    }

    func testLockContentionFailsClosed() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let dirty = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
        try fx.writeState(dirty)

        let holder = try fx.holdLock()
        defer { holder.terminate(); holder.waitUntilExit() }

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
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo rm") }, "\(calls)")
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
        XCTAssertTrue(fx.calls().contains("sudo rm -f \(fx.sudoers.path)"), "\(fx.calls())")
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
        try "handoffs\n".write(to: fx.home.appendingPathComponent("Logs/handoffs.log"), atomically: true, encoding: .utf8)
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        for gone in [fx.state, fx.config, fx.logFile, fx.home.appendingPathComponent("Logs/handoffs.log"),
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
        ]
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

    func testNullOptionalFieldsCountAsAbsent() throws {
        // Swift's decodeIfPresent treats null as nil; the shell must agree.
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":null,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":null,"savedMuted":null,"savedDisplayBrightness":null,"savedKeyboardBrightness":null,"frozenPids":null}"#
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
        ] {
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

    // MARK: - Process observation failures

    func testPsCommandFailureKeepsEntryWithoutSignal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let started = 1_789_388_423
        try fx.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[{"pid":777,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
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
         "frozenProcesses":[{"pid":778,"startedAt":\(started),"startedAtMicros":0,"bootSession":"\(fx.bootUUID)"}]}
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

    // MARK: - Uninstall locking and interleaving

    func testUninstallRefusesWhileRecoveryLockIsHeld() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let holder = try fx.holdLock()
        defer { holder.terminate(); holder.waitUntilExit() }

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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("launchctl") || $0.hasPrefix("sudo rm") }, "\(fx.calls())")
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
        defer { holder.terminate(); holder.waitUntilExit() }
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
        XCTAssertTrue(log.contains("did not finish within 1s"), log)
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo rm") }, "\(fx.calls())")
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

    func testUninstallAbortsWhenBootoutAndPrintBothFailAmbiguously() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "ambiguous")

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo rm") }, "\(fx.calls())")
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
        XCTAssertTrue(r.stderr.contains("/scripts/backstop.sh\" --force"), "manual step named, the checkout's copy: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("not replaced"), r.stderr)
        XCTAssertEqual(try fx.installedBinaryFirstLine(), "previous", "the bundle the retained agent pins stays in place")
        XCTAssertEqual(try fx.contents(of: fx.appsDir), ["Insomnia.app"], "the staged build is discarded and nothing is set aside")
        XCTAssertTrue(r.stderr.contains("discarded"), r.stderr)
        XCTAssertTrue(try fx.lockIsFree(), "the transaction ends with the script")

        // A zip install has no scripts/ directory. The checked copy of the bundle is gone when the
        // script exits and the original was never checked in place, so the hint runs no script from
        // either; it names this installer again, which checks a new copy first.
        let prebuilt = try fx.writePrebuiltApp()
        let zip = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(zip.status, 1, zip.stderr + zip.stdout)
        XCTAssertFalse(zip.stderr.contains("/bin/bash"), "no hand-run backstop.sh: \(zip.stderr)")
        XCTAssertFalse(zip.stderr.contains("\(prebuilt.path)/Contents"), "nothing inside the unchecked bundle is named: \(zip.stderr)")
        XCTAssertTrue(zip.stderr.contains("\(fx.installRedirected.path) --allow-unverified-origin --app \"\(prebuilt.path)\""), "manual step reruns the installer on the bundle: \(zip.stderr)")
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

    // MARK: - install.sh --app (a prebuilt bundle, as from a release zip)

    /// The private copy install.sh --app checks and installs, read from the
    /// first deep verify in the recorded calls. Never the path passed in.
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
        let visudo = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo visudo") }, "\(calls)")
        XCTAssertLessThan(verify, visudo, "verified before the password prompt: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("spctl") }, "Gatekeeper is asked about Developer ID builds only: \(calls)")
        XCTAssertTrue(r.stdout.contains("WARNING: the origin of Insomnia 0.1.0 is not verified: ad-hoc signed, an experimental build"), r.stdout)
        XCTAssertTrue(r.stdout.contains("--allow-unverified-origin: installing it anyway"), r.stdout)
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

    /// Integrity is not origin: an ad-hoc bundle, or a Developer ID bundle
    /// while EXPECTED_TEAM_ID is empty, passes every check on it and could
    /// still have been made by anyone. Without --allow-unverified-origin
    /// install.sh refuses it before the password prompt and names the flag.
    func testInstallFromPrebuiltAppRefusesAnUnverifiedOriginWithoutTheOptIn() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()

        let adhoc = try fx.run(fx.installRedirected, ["--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(adhoc.status, 1, adhoc.stderr + adhoc.stdout)
        let copy = try checkedCopy(of: prebuilt)
        XCTAssertEqual(fx.calls(), ["codesign --verify --strict --deep \(copy)", "codesign -dvv \(copy)"], "\(fx.calls())")
        XCTAssertTrue(adhoc.stderr.contains("The origin of Insomnia 0.1.0 at \(prebuilt.path) is not verified: ad-hoc signed"), adhoc.stderr)
        XCTAssertTrue(adhoc.stderr.contains("--allow-unverified-origin --app \"\(prebuilt.path)\""), "names the flag: \(adhoc.stderr)")
        XCTAssertTrue(adhoc.stderr.contains("Nothing was changed"), adhoc.stderr)
        XCTAssertFalse(fx.exists(fx.app))
        XCTAssertFalse(fx.exists(fx.sudoers))

        fx.setSigning("developer-id:ABCDE12345")
        fx.clearCalls()
        let unpinnedTeam = try fx.run(fx.installRedirected, ["--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(unpinnedTeam.status, 1, unpinnedTeam.stderr + unpinnedTeam.stdout)
        XCTAssertTrue(fx.calls().contains("spctl --assess --type execute \(try checkedCopy(of: prebuilt))"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertTrue(unpinnedTeam.stderr.contains("Developer ID signed by team ABCDE12345 and Gatekeeper accepts it, but EXPECTED_TEAM_ID is empty"), unpinnedTeam.stderr)
        XCTAssertTrue(unpinnedTeam.stderr.contains("Nothing was changed"), unpinnedTeam.stderr)
        XCTAssertFalse(fx.exists(fx.app))
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
        XCTAssertEqual(fx.calls(), [], "the real codesign refused before any fake tool ran: \(fx.calls())")
        XCTAssertTrue(edited.stderr.contains("fails 'codesign --verify --strict --deep'"), edited.stderr)
        XCTAssertTrue(edited.stderr.contains("Nothing was changed"), edited.stderr)
    }

    func testInstallFromPrebuiltAppStopsBeforeSudoWhenItsSignatureDoesNotVerify() throws {
        try fx.prepareInstall()
        try fx.installMachinery()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setMode("codesign", "deep-verify-fails")

        let r = try fx.run(fx.installRedirected, ["--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertEqual(calls, ["codesign --verify --strict --deep \(try checkedCopy(of: prebuilt))"], "nothing after the failed check: \(calls)")
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertTrue(r.stderr.contains("SHA256SUMS"), "points at the download checks: \(r.stderr)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle kept")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "sudoers rule kept")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist kept")
    }

    func testInstallFromPrebuiltAppRefusesAnotherIdentifierAVersionlessBundleAndAMissingBackstop() throws {
        try fx.prepareInstall()
        let cases: [(String, (ScriptFixture) throws -> URL)] = [
            ("identifier", { try $0.writePrebuiltApp(bundleID: "com.example.other") }),
            ("version", { try $0.writePrebuiltApp(version: "dev") }),
            ("backstop", { try $0.writePrebuiltApp(withBackstop: false) }),
        ]
        for (name, make) in cases {
            let bundle = try make(fx)
            fx.clearCalls()
            let r = try fx.run(fx.installRedirected, ["--app", bundle.path], extraEnvironment: ["USER": "tester"])
            XCTAssertEqual(r.status, 1, "\(name): \(r.stderr + r.stdout)")
            XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") }, "\(name): \(fx.calls())")
            XCTAssertTrue(r.stderr.contains("Nothing was changed"), "\(name): \(r.stderr)")
            XCTAssertFalse(fx.exists(fx.app), name)
            XCTAssertFalse(fx.exists(fx.sudoers), name)
            try FileManager.default.removeItem(at: bundle)
        }
    }

    /// A Developer ID bundle must also pass Gatekeeper (notarized, not
    /// revoked). Its team establishes origin only once EXPECTED_TEAM_ID is
    /// set in install.sh: while it is empty the bundle takes
    /// --allow-unverified-origin and the warning says why; another team is
    /// refused even with the flag; the expected team installs without it.
    func testInstallFromDeveloperIDAppAsksGatekeeperAndChecksTheTeamWhenOneIsExpected() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setSigning("developer-id:ABCDE12345")
        fx.setMode("launchctl", "loaded")

        let unpinned = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(unpinned.status, 0, unpinned.stderr + unpinned.stdout)
        XCTAssertTrue(fx.calls().contains("spctl --assess --type execute \(try checkedCopy(of: prebuilt))"), "\(fx.calls())")
        XCTAssertTrue(unpinned.stdout.contains("WARNING: the origin of Insomnia 0.1.0 is not verified: Developer ID signed by team ABCDE12345"), unpinned.stdout)
        XCTAssertTrue(unpinned.stdout.contains("EXPECTED_TEAM_ID is empty"), "says the team is not checked: \(unpinned.stdout)")

        try fx.writeInstallCopies(extraConstants: ["EXPECTED_TEAM_ID": "ZZZZZ99999"])
        fx.clearCalls()
        let wrongTeam = try fx.run(fx.installRedirected, ["--allow-unverified-origin", "--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(wrongTeam.status, 1, wrongTeam.stderr + wrongTeam.stdout)
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertTrue(wrongTeam.stderr.contains("signed by team 'ABCDE12345', not ZZZZZ99999"), "refused even with the flag: \(wrongTeam.stderr)")
        XCTAssertTrue(wrongTeam.stderr.contains("Nothing was changed"), wrongTeam.stderr)

        try fx.writeInstallCopies(extraConstants: ["EXPECTED_TEAM_ID": "ABCDE12345"])
        fx.clearCalls()
        let pinned = try fx.run(fx.installRedirected, ["--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(pinned.status, 0, pinned.stderr + pinned.stdout)
        XCTAssertTrue(pinned.stdout.contains("Insomnia 0.1.0: Developer ID signed by team ABCDE12345, the team this install.sh expects, and Gatekeeper accepts it"), pinned.stdout)
        XCTAssertFalse(pinned.stdout.contains("WARNING"), "origin verified, no opt-in needed: \(pinned.stdout)")
    }

    func testInstallFromDeveloperIDAppStopsBeforeSudoWhenGatekeeperRejectsIt() throws {
        try fx.prepareInstall()
        let prebuilt = try fx.writePrebuiltApp()
        fx.setSigning("developer-id:ABCDE12345")
        fx.setMode("spctl", "reject")

        let r = try fx.run(fx.installRedirected, ["--app", prebuilt.path], extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.calls().contains("spctl --assess --type execute \(try checkedCopy(of: prebuilt))"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo") }, "\(fx.calls())")
        XCTAssertTrue(r.stderr.contains("Gatekeeper rejects it"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Nothing was changed"), r.stderr)
        XCTAssertFalse(fx.exists(fx.app))
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
        let visudo = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo visudo") }, "\(calls)")
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
        XCTAssertTrue(fx.exists(fx.sudoers), "the rule step comes first and is reported")
        XCTAssertTrue(r.stderr.contains("would never run backstop.sh"), r.stderr)
        XCTAssertTrue(r.stderr.contains(fx.sudoers.path), r.stderr)
    }

    /// A first install whose agent cannot load leaves what was there before:
    /// no bundle at $APP, rather than a bundle no agent pins.
    func testInstallWithNoPreviousAppLeavesNoneWhenTheAgentCannotLoad() throws {
        try fx.prepareInstall()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "no-then-error")   // nothing loaded before; bootstrap fails

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
    /// it the set-aside copy is removed. Either way the pair matches before
    /// this run's own recovery step (unresolved here, so the run stops).
    func testInstallKeepsTheBundleThePlistOnDiskPinsAfterAnInterruptedSwap() throws {
        try fx.prepareInstall()
        let previous = fx.appsDir.appendingPathComponent(".Insomnia.app.previous", isDirectory: true)
        try fx.writeBundle(at: previous, marker: "previous")
        try fx.writeBundle(at: fx.app, marker: "interrupted")
        try fx.writeAgentPlist()
        try fx.rejectSignature(of: fx.app)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("sudo", "fail")
        fx.setMode("launchctl", "loaded")

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
        XCTAssertTrue(pinsCurrent.stdout.contains("removed the bundle an interrupted run had set aside"), pinsCurrent.stdout)
    }

    /// Leftovers are cleaned only under the recovery lock: while another
    /// process holds it, a set-aside bundle (which a live run may need to
    /// roll back) and every staging directory stay. With the lock, a dead
    /// run's staging directory is removed and a live run's (named by a PID
    /// that `$KILL -0` reports alive) is kept.
    func testInstallCleansLeftoversOnlyUnderTheLockAndKeepsALiveRunsStaging() throws {
        try fx.prepareInstall()
        try fx.writePreviousApp()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("kill.fail", "4242")   // the fake kill: 4242 is gone, 4343 is alive
        let dead = ".Insomnia.app.staging.4242.AAAAAA"
        let live = ".Insomnia.app.staging.4343.BBBBBB"
        let setAside = ".Insomnia.app.previous"
        for name in [dead, live] {
            try fx.writeBundle(at: fx.appsDir.appendingPathComponent(name).appendingPathComponent("Insomnia.app"), marker: "staged")
        }
        try fx.writeBundle(at: fx.appsDir.appendingPathComponent(setAside), marker: "set aside by a live run")

        let holder = try fx.holdLock()
        let blocked = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
        holder.terminate(); holder.waitUntilExit()

        XCTAssertEqual(blocked.status, 75, blocked.stderr + blocked.stdout)
        XCTAssertEqual(try fx.contents(of: fx.appsDir), [setAside, dead, live, "Insomnia.app"].sorted(), "nothing removed outside the lock")

        try FileManager.default.removeItem(at: fx.appsDir.appendingPathComponent(setAside))
        fx.setMode("launchctl", "loaded")
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertEqual(try fx.contents(of: fx.appsDir), [live, "Insomnia.app"].sorted(), "the dead run's staging is gone, the live run's stays")
        XCTAssertTrue(fx.calls().contains("kill -0 4242") && fx.calls().contains("kill -0 4343"), "asked through $KILL: \(fx.calls())")
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
        fx.setMode("launchctl", "loaded-tracked")
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
        fx.setMode("launchctl", "loaded-tracked-unload-fails")
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

    func testInstallDoesNotReloadOrClaimAbsenceOnAmbiguousLaunchctl() throws {
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "ambiguous")   // print and bootout fail with errors; bootstrap fails

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "no reload attempt when the prior state is unknown: \(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("unknown"), r.stderr)
        XCTAssertFalse(r.stderr.contains("No LaunchAgent"), "ambiguous is not absent: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("every minute"), r.stderr)
    }

    func testInstallReportsUnknownNotAbsentWhenTheLaterPrintFails() throws {
        // Nothing loaded before, bootstrap fails, then `print` itself errors:
        // the current state is unknown and must not be reported as absent.
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "no-then-error")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("launchctl bootstrap") }.count, 1, "no reload when nothing was loaded before: \(fx.calls())")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("unknown"), r.stderr)
        XCTAssertTrue(r.stderr.contains("not confirmed"), r.stderr)
        XCTAssertFalse(r.stderr.contains("none is loaded now"), "unknown is not absent: \(r.stderr)")
        XCTAssertFalse(r.stderr.contains("No LaunchAgent"), r.stderr)
    }

    func testInstallDoesNotAttributeAnExistingJobToAFailedReload() throws {
        // A job was loaded before; the candidate bootstrap fails and so does
        // the reload of the previous plist, while `print` keeps listing a job.
        // That job's source is unknown; it must not be called "loaded again
        // from the previous plist".
        try fx.prepareInstall()
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        fx.setMode("launchctl", "loaded-bootstrap-always-fails")

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
        try "trusted".write(to: fx.plist, atomically: true, encoding: .utf8)
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let holder = try fx.holdLock()
        defer { holder.terminate(); holder.waitUntilExit() }

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

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
        fx.setMode("pgrep", "1\n0\n")   // not running at the quit step, running again under the lock
        fx.setMode("launchctl", "loaded")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo -n \(fx.fakePmset)") }, "no recovery beside a running app: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "trusted")
        XCTAssertTrue(r.stderr.contains("started again"), r.stderr)
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "the app was asked to quit before authentication: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo install") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "sudoers rule replaced")
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("sudo visudo") }, "authentication was attempted: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("sudo install") }, "\(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("osascript") }, "nothing to quit: \(calls)")
        XCTAssertFalse(calls.contains { $0.hasPrefix("launchctl") }, "\(calls)")
        XCTAssertEqual(try String(contentsOf: fx.app.appendingPathComponent("Contents/MacOS/Insomnia"), encoding: .utf8), "binary", "old bundle replaced")
        XCTAssertEqual(try String(contentsOf: fx.installedBackstop, encoding: .utf8), "old helper", "installed backstop.sh replaced")
        XCTAssertEqual(try String(contentsOf: fx.plist, encoding: .utf8), "plist", "trusted plist touched")
        XCTAssertEqual(try String(contentsOf: fx.sudoers, encoding: .utf8), "rule", "sudoers rule replaced")
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertNotEqual(r.status, 0, r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("sudo visudo") }, "authentication was attempted: \(calls)")
        XCTAssertTrue(calls.contains { $0.hasPrefix("sudo install") }, "the rule was installed before being checked: \(calls)")
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        let calls = fx.calls()
        XCTAssertTrue(calls.contains { $0.hasPrefix("sudo install") }, "\(calls)")
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

    var backstop: URL { repoScripts.appendingPathComponent("backstop.sh") }
    var uninstall: URL { repoScripts.appendingPathComponent("uninstall.sh") }
    var install: URL { repoScripts.appendingPathComponent("install.sh") }
    var installRedirected: URL { repoScripts.appendingPathComponent("install.redirected.sh") }
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
        try writeFakes()
        try writeScriptCopies()
        try bootUUID.write(to: root.appendingPathComponent("boot.uuid"), atomically: true, encoding: .utf8)
    }

    func destroy() {
        releaseCommand()
        try? fm.removeItem(at: root)
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

    private static var productionScripts: URL {
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
            "LOCK_TIMEOUT_SECONDS": "1",
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
            "APP": app.path,
            "SUDOERS": sudoers.path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "QUIT_WAIT_SECONDS": "1",
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
    /// into the fixture (signing, Gatekeeper, sudo, launchctl included; the
    /// build goes through the patched build-app.sh above). Tests that need
    /// another constant (EXPECTED_TEAM_ID) rewrite both copies with it.
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
            "SPCTL": bin.appendingPathComponent("spctl").path,
            "LOCK_TIMEOUT_SECONDS": "1",
        ].merging(extraConstants) { $1 })
        try patchedInstall.write(to: install, atomically: true, encoding: .utf8)
        // The redirected copy runs past the INSOMNIA_HOME refusal: that
        // variable is what makes the backstop copy it installs act on the
        // fixture instead of ~/Library. The plain copy keeps the refusal.
        try Self.replaceOnce(patchedInstall, #"if [[ -n "${INSOMNIA_HOME:-}" ]]; then"#, with: "if false; then")
            .write(to: installRedirected, atomically: true, encoding: .utf8)
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

    private func writeFake(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeFakes() throws {
        let calls = callsLog.path
        let r = root.path
        // sudo: `-n <cmd>` is the pmset path and succeeds or fails by mode
        // without running anything. `rm`/`test` run unprivileged, and only
        // on a path inside the fixture.
        // Mode "hang" behaves like a pmset that never returns.
        // Mode "auth-fail": every form that would prompt (visudo, install)
        // fails like a wrong password, and `-n` forms fail as unpermitted.
        // Mode "rule-not-effective": authentication passes and the rule is
        // installed, but `sudo -n -l <pmset ...>` still says no.
        // visudo checks the candidate file exists, is non-empty and grants
        // pmset, so an installer that validated the wrong path or an empty
        // heredoc cannot pass here.
        try writeFake("sudo", """
        printf 'sudo %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/sudo.mode" 2>/dev/null || echo ok)"
        # "ignore-term" and "closes-fd9" behave like a pmset that ignores
        # SIGTERM: they live until the test creates the release file (or the
        # fixture is destroyed, or a 60 s wall-clock watchdog), so a test decides when
        # the command ends instead of racing a wall-clock sleep. On exit they
        # write command.ended = released | watchdog, so a test can tell a
        # command that is still alive (no file) from one that ended, and why.
        case "${1:-}" in
          -n) if [[ "${2:-}" == -l ]]; then
                case "$mode" in auth-fail|rule-not-effective) exit 1 ;; *) exit 0 ;; esac
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
                *) exit 1 ;;
              esac ;;
          visudo)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            # "swap-prebuilt": someone replaces the --app bundle at its path
            # (writePrebuiltApp's dist/Insomnia.app) while the password prompt waits.
            if [[ "$mode" == swap-prebuilt ]]; then printf 'swapped' > "\(r)/dist/Insomnia.app/Contents/MacOS/Insomnia"; fi
            f=""; for a in "$@"; do f="$a"; done
            [[ -s "$f" ]] && grep -q 'NOPASSWD: /usr/bin/pmset' "$f" || { printf 'sudo VISUDO-REJECTED %s\\n' "$*" >> "\(calls)"; exit 1; }
            exit 0 ;;
          install)
            if [[ "$mode" == auth-fail ]]; then echo "sudo: 3 incorrect password attempts" >&2; exit 1; fi
            src=""; dst=""
            for a in "$@"; do src="$dst"; dst="$a"; done
            case "$dst" in "\(r)"/*) mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; exit 0 ;; esac
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          rm|test)
            for a in "$@"; do
              case "$a" in "\(r)"/*) exec "$@" ;; esac
            done
            printf 'sudo REFUSED %s\\n' "$*" >> "\(calls)"; exit 1 ;;
          *) exit 1 ;;
        esac
        """)
        try writeFake("pmset", """
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
        // codesign: signing is recorded and succeeds. `-d -r-` prints a
        // fixed designated requirement the way codesign does (on stderr,
        // with the "# " an implicit requirement carries). `-dvv` describes
        // the signature per codesign.signing (adhoc | developer-id:<team>).
        // `--verify` passes unless mode "verify-fails"; mode
        // "deep-verify-fails" fails only the `--deep` form install.sh runs
        // on a prebuilt bundle, and "requirement-verify-fails" only the
        // `-R=` form (the agent's pinned check). A path listed in
        // codesign.rejects (see `rejectSignature(of:)`) fails every form.
        try writeFake("codesign", """
        printf 'codesign %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/codesign.mode" 2>/dev/null || echo ok)"
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
              if [[ -f "\(r)/codesign.rejects" ]] && grep -qxF -- "$last" "\(r)/codesign.rejects"; then echo "$last: does not satisfy its designated Requirement" >&2; exit 3; fi
              if [[ "$mode" == verify-fails || ( "$mode" == deep-verify-fails && $deep == 1 ) || ( "$mode" == requirement-verify-fails && $pinned == 1 ) ]]; then echo "$last: a sealed resource is missing or invalid" >&2; exit 1; fi
              exit 0 ;;
          esac
        done
        exit 0
        """)
        // spctl: Gatekeeper's verdict on a Developer ID bundle. Mode
        // "reject" is what an unnotarized or revoked signature gets.
        try writeFake("spctl", """
        printf 'spctl %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/spctl.mode" 2>/dev/null || echo ok)"
        last=""; for a in "$@"; do last="$a"; done
        if [[ "$mode" == reject ]]; then echo "$last: rejected" >&2; echo "source=Unnotarized Developer ID" >&2; exit 3; fi
        echo "$last: accepted" >&2; echo "source=Notarized Developer ID" >&2; exit 0
        """)
        // ps: answers from ps.table. Modes: "fail" (exit 2 with an error
        // line, like a broken ps) and "garbage" (exit 0 with nonsense).
        try writeFake("ps", """
        printf 'ps %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/ps.mode" 2>/dev/null || echo ok)"
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
        fail="$(cat "\(r)/kill.fail.mode" 2>/dev/null || true)"
        for f in $fail; do [[ "$f" == "${2:-}" ]] && exit 1; done
        exit 0
        """)
        try writeFake("sysctl", """
        cat "\(r)/boot.uuid"
        """)
        // pgrep: pgrep.mode holds one exit status per line, consumed in
        // order; the last line repeats. Default 1 (not running).
        try writeFake("pgrep", """
        printf 'pgrep %s\\n' "$*" >> "\(calls)"
        f="\(r)/pgrep.mode"
        [[ -f "$f" ]] || exit 1
        first="$(head -n 1 "$f")"
        if (( $(wc -l < "$f") > 1 )); then tail -n +2 "$f" > "$f.next" && mv "$f.next" "$f"; fi
        exit "${first:-1}"
        """)
        for tool in ["pkill", "osascript"] {
            try writeFake(tool, """
            printf '\(tool) %s\\n' "$*" >> "\(calls)"
            exit 0
            """)
        }
        // launchctl: bootout/bootstrap succeed and `print` reports "not
        // loaded" (113) by default. "loaded": print reports the job loaded.
        // Whatever the mode, a path argument is only accepted when it ends
        // in `.plist` and exists (real launchctl fails with EIO otherwise,
        // for bootstrap and bootout alike); bootout also takes a service
        // target `gui/<uid>/<label>` with no path.
        // "loaded-bootstrap-fails-once": as "loaded", but the first bootstrap
        // fails. "bootout-fails-still-loaded": bootout exits 5 and the job
        // stays listed. "ambiguous": bootout and print fail with errors.
        // Every bootstrap also records whether the recovery lock was held at
        // that moment (LOCK-HELD / LOCK-FREE), to prove the installer keeps
        // its transaction open across the agent replacement.
        // "loaded-then-lost": print says loaded once, then not loaded;
        // bootstrap always fails. "no-then-error": print says not loaded
        // once, then fails with an error; bootstrap fails.
        // "loaded-bootstrap-always-fails": print always says loaded (a job
        // already exists) and every bootstrap fails, reload included.
        // "loaded-tracked": the job starts loaded, bootout unloads it,
        // bootstrap loads it (and fails while it is loaded), and print
        // reports which. "loaded-tracked-unload-fails": the same, except
        // that a bootout after a bootstrap fails and the job stays loaded.
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
        prints=0
        if [[ "${1:-}" == print ]]; then
          prints=$(( $(cat "\(r)/print.count" 2>/dev/null || echo 0) + 1 )); echo "$prints" > "\(r)/print.count"
        fi
        case "${1:-}:$mode" in
          bootout:loaded-tracked|bootout:loaded-tracked-unload-fails)
            if [[ "$mode" == loaded-tracked-unload-fails && -e "\(r)/launchctl.bootstrapped" ]]; then
              echo "Boot-out failed: 5: Input/output error" >&2; exit 5
            fi
            : > "\(r)/launchctl.unloaded"; exit 0 ;;
          bootstrap:loaded-tracked|bootstrap:loaded-tracked-unload-fails)
            [[ -e "\(r)/launchctl.unloaded" ]] || { echo "Bootstrap failed: 37: Operation already in progress" >&2; exit 37; }
            rm -f "\(r)/launchctl.unloaded"; : > "\(r)/launchctl.bootstrapped"; exit 0 ;;
          print:loaded-tracked|print:loaded-tracked-unload-fails)
            if [[ -e "\(r)/launchctl.unloaded" ]]; then exit 113; fi; exit 0 ;;
          bootout:ok|bootout:loaded|bootout:loaded-bootstrap-fails-once|bootout:loaded-then-lost|bootout:no-then-error|bootout:loaded-bootstrap-always-fails) exit 0 ;;
          bootstrap:ok|bootstrap:loaded) exit 0 ;;
          bootstrap:loaded-then-lost|bootstrap:no-then-error) echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;;
          bootstrap:loaded-bootstrap-always-fails) echo "Bootstrap failed: 37: Operation already in progress" >&2; exit 37 ;;
          print:loaded-then-lost) if (( prints == 1 )); then exit 0; fi; exit 113 ;;
          print:no-then-error) if (( prints == 1 )); then exit 113; fi; echo "Could not print domain: 1: Operation not permitted" >&2; exit 1 ;;
          print:loaded-bootstrap-always-fails) exit 0 ;;
          bootstrap:loaded-bootstrap-fails-once)
            if [[ -e "\(r)/bootstrap.failed" ]]; then exit 0; fi
            : > "\(r)/bootstrap.failed"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5 ;;
          print:ok) exit 113 ;;
          print:loaded|print:loaded-bootstrap-fails-once) exit 0 ;;
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
        try probe.run()
        probe.waitUntilExit()
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

    func setMode(_ name: String, _ value: String) {
        try? value.write(to: root.appendingPathComponent("\(name).mode"), atomically: true, encoding: .utf8)
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

    // MARK: State

    func writeState(_ json: String) throws {
        try json.write(to: state, atomically: true, encoding: .utf8)
    }

    func writeSession(endsAt: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let json = #"{"startedAt":"\#(f.string(from: endsAt.addingTimeInterval(-3600)))","endsAt":"\#(f.string(from: endsAt))"}"#
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

    // MARK: Running

    /// Decoded lossily: the fake launchctl copies the first line of the
    /// installed binary into the log, which is Mach-O bytes, not text, for
    /// the fixture the real codesign signs.
    func calls() -> [String] {
        guard let data = try? Data(contentsOf: callsLog) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
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
        ]
    }

    /// Inode of a file, to prove the lock file was retained rather than replaced.
    func inode(_ url: URL) throws -> UInt64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// Runs a script copy. `fd9` opens that file on descriptor 9 of the child
    /// first, the way uninstall.sh hands its lock handle to the backstop.
    /// `extraEnvironment` is for install.sh's refusal test only.
    func run(_ script: URL, _ args: [String] = [], fd9: URL? = nil, extraEnvironment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        if let fd9 {
            p.arguments = ["-c", #"exec 9<>"$0" && exec /bin/bash "$@""#, fd9.path, script.path] + args
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
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    /// Runs a real tool (not a script) with the fixture's environment, for
    /// the one test that signs its fixture with the real codesign.
    func runTool(_ exe: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = childEnvironment
        p.currentDirectoryURL = root
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Holds the recovery lock from another process, the way a running app
    /// or a concurrent backstop would, until terminated.
    func holdLock() throws -> Process {
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
        try p.run()
        // Wait until the holder really owns the lock.
        var probes: [Int32] = []
        for _ in 0..<50 {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            probe.arguments = ["-k", "-s", "-t", "0", lock.path, "/usr/bin/true"]
            probe.standardOutput = diag
            probe.standardError = diag
            try probe.run()
            probe.waitUntilExit()
            probes.append(probe.terminationStatus)
            if probe.terminationStatus == 75 { return p }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.terminate()
        let text = (try? String(contentsOf: diagURL, encoding: .utf8)) ?? ""
        throw FixtureError("could not take the recovery lock for the contention test; holder running=\(p.isRunning) probes=\(probes) output=\(text)")
    }
}
