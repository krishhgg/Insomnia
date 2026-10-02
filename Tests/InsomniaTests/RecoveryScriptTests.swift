import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// Behavioural tests for scripts/backstop.sh and scripts/uninstall.sh.
///
/// Each test runs a private COPY of the production script against a
/// throwaway INSOMNIA_HOME. The copy has its fixed tool-path constants
/// (sudo, pmset, ps, kill, sysctl, notifyutil, pgrep, pkill, osascript,
/// launchctl, defaults) and its app-bundle / sudoers paths rewritten to
/// point inside the fixture, so nothing privileged runs, no real process is
/// signaled, no real app's preferences are read or written, and no real
/// home, LaunchAgent, sudoers file, or installed app is read or written.
/// plutil, lockf, cmp, and date are the real tools. The fakes record every
/// call.
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

    // MARK: backstop.sh: a valid session is live only while the app and the floors say so

    private let liveJournal = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#
    private let sleepRestored = "sudo -n PMSET -a disablesleep 0"
    private let batteryRead = "pmset -g batt"
    private let thermalRead = "notifyutil -g com.apple.system.thermalpressurelevel"

    /// A session with an hour left and sleep journaled as ours: what the
    /// backstop sees every minute while the app runs.
    private func writeLiveSession() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(liveJournal)
    }

    private func calls() -> [String] {
        fx.calls().map { $0.replacingOccurrences(of: fx.fakePmset, with: "PMSET") }
    }

    private func assertSessionEnded(_ r: (status: Int32, stdout: String, stderr: String), reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, 0, r.stderr + fx.log(), file: file, line: line)
        XCTAssertTrue(calls().contains(sleepRestored), "\(calls())", file: file, line: line)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false, file: file, line: line)
        XCTAssertFalse(fx.exists(fx.session), "session.json must go with the session", file: file, line: line)
        XCTAssertTrue(fx.log().contains("ending the session before its deadline"), fx.log(), file: file, line: line)
        XCTAssertTrue(fx.log().contains(reason), fx.log(), file: file, line: line)
    }

    private func assertSessionKept(_ r: (status: Int32, stdout: String, stderr: String), file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(r.status, 0, r.stderr + fx.log(), file: file, line: line)
        XCTAssertFalse(calls().contains { $0.hasPrefix("sudo") || $0.hasPrefix("kill -CONT") }, "\(calls())", file: file, line: line)
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), liveJournal, "journal must not be rewritten", file: file, line: line)
        XCTAssertTrue(fx.exists(fx.session), "the session must stand", file: file, line: line)
    }

    /// The app holds the alive lock, the Mac is on AC power and cool: the
    /// minute tick reads the battery and the heat and leaves the session
    /// alone, without a word in the log.
    func testValidSessionWithTheAppAliveAndAHealthyMachineIsLeftAlone() throws {
        try writeLiveSession()
        let app = try fx.holdAliveLock()
        defer { app.release() }

        let r = try fx.run(fx.backstop)

        try assertSessionKept(r)
        XCTAssertEqual(calls(), [batteryRead, thermalRead], "reads only, nothing privileged")
        XCTAssertFalse(fx.exists(fx.logFile), "a healthy minute must not spam the log")
    }

    /// Nobody holds the alive lock: the app crashed, was force-quit or has
    /// not started yet. The deadline no longer matters; the session ends
    /// as if --force had been given, and the battery and heat are not even
    /// read.
    func testAppNotRunningEndsAValidSession() throws {
        try writeLiveSession()

        let r = try fx.run(fx.backstop)

        try assertSessionEnded(r, reason: "Insomnia is not running")
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertTrue(fx.exists(fx.alive), "the probe creates the lock file and keeps it (lockf -k)")
        XCTAssertTrue(fx.log().contains("journal cleared"), fx.log())
    }

    /// The probe gives the lock back when it exits: the app can take it
    /// right after a run, and the next run then sees it held.
    func testAliveProbeReleasesTheLockItTook() throws {
        try writeLiveSession()
        XCTAssertEqual(try fx.run(fx.backstop).status, 0)
        XCTAssertFalse(fx.exists(fx.session))
        let app = try fx.holdAliveLock()
        defer { app.release() }
        try writeLiveSession()
        fx.clearCalls()
        try assertSessionKept(try fx.run(fx.backstop))
    }

    /// The lock the app takes (AppAliveLock.swift) is the lock the script
    /// probes: held in this process, the session stands; released, as the
    /// kernel does when the process dies, the next run ends it.
    func testAppAliveLockTakenByTheAppIsSeenByTheBackstop() throws {
        try writeLiveSession()
        let lock = AppAliveLock(url: fx.alive)
        XCTAssertTrue(try lock.tryAcquire())

        try assertSessionKept(try fx.run(fx.backstop))

        lock.release()
        fx.clearCalls()
        try assertSessionEnded(try fx.run(fx.backstop), reason: "Insomnia is not running")
    }

    /// A valid session whose journal is clean (the app died between writing
    /// session.json and pmset) is removed without running anything.
    func testAppNotRunningWithACleanJournalRemovesTheSessionOnly() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(calls(), [])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertTrue(fx.log().contains("Insomnia is not running"), fx.log())
        XCTAssertTrue(fx.log().contains("journal already clean"), fx.log())
    }

    func testBatteryBelowTheEndFloorOnBatteryPowerEndsTheSession() throws {
        try writeLiveSession()
        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.setBattery(fx.battery(source: "Battery Power", percent: 9))

        let r = try fx.run(fx.backstop)

        try assertSessionEnded(r, reason: "battery at 9% on battery power, below the 10% end floor")
        XCTAssertEqual(calls(), [batteryRead, sleepRestored], "no thermal read once the battery has decided")
    }

    /// Strict less-than, as in FloorRules.swift: at the floor is not below
    /// it. On AC power the charge does not matter at all.
    func testBatteryAtTheFloorOrOnACPowerKeepsTheSession() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        for (source, percent, state) in [("Battery Power", 10, "discharging"), ("AC Power", 3, "charging"), ("AC Power", 0, "charging")] {
            try writeLiveSession()
            fx.setBattery(fx.battery(source: source, percent: percent, state: state))
            try assertSessionKept(try fx.run(fx.backstop))
        }
    }

    /// Fail closed: a battery that is there but cannot be read, or a pmset
    /// that fails, ends the session; sleep must not stay disabled on a guess.
    func testBatteryUnreadableOrPmsetFailingEndsTheSession() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        let cases: [(output: String, reason: String)] = [
            ("FAIL", "battery state unreadable (pmset -g batt exit 1)"),
            ("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t(no estimate) present: true\n", "battery present but unreadable"),
            ("Now drawing from 'UPS Power'\n -InternalBattery-0 (id=1)\t50%; discharging; present: true\n", "battery present but unreadable"),
            (" -InternalBattery-0 (id=1)\t50%; discharging; present: true\n", "battery present but unreadable"),
        ]
        for c in cases {
            try writeLiveSession()
            fx.clearCalls()
            fx.setBattery(c.output)
            try assertSessionEnded(try fx.run(fx.backstop), reason: c.reason)
        }
    }

    /// No InternalBattery line is a desktop: there is no battery rule, and
    /// the thermal check still runs.
    func testDesktopWithoutABatteryHasNoBatteryRule() throws {
        try writeLiveSession()
        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.setBattery("Now drawing from 'AC Power'\n")

        let r = try fx.run(fx.backstop)

        try assertSessionKept(r)
        XCTAssertEqual(calls(), [batteryRead, thermalRead])
    }

    /// endFloor comes from config.json like the app's; 0 disables the rule;
    /// a value that is not a whole number falls back to the default 10.
    func testEndFloorIsReadFromConfigAndZeroDisablesIt() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try writeLiveSession()
        try fx.writeConfig(#"{"endFloor": 30}"#)
        fx.setBattery(fx.battery(source: "Battery Power", percent: 25))
        try assertSessionEnded(try fx.run(fx.backstop), reason: "battery at 25% on battery power, below the 30% end floor")

        try writeLiveSession()
        fx.clearCalls()
        try fx.writeConfig(#"{"endFloor": 0}"#)
        fx.setBattery(fx.battery(source: "Battery Power", percent: 1))
        try assertSessionKept(try fx.run(fx.backstop))

        try writeLiveSession()
        fx.clearCalls()
        try fx.writeConfig(#"{"endFloor": "ten"}"#)
        fx.setBattery(fx.battery(source: "Battery Power", percent: 9))
        try assertSessionEnded(try fx.run(fx.backstop), reason: "below the 10% end floor")

        try writeLiveSession()
        fx.clearCalls()
        try fx.writeConfig("not json at all")
        try assertSessionEnded(try fx.run(fx.backstop), reason: "below the 10% end floor")
    }

    /// With the floor off nothing is read, so a failing pmset cannot end a
    /// session the user exempted from the battery rule.
    func testEndFloorZeroSkipsTheBatteryReadSoAFailingPmsetCannotEnd() throws {
        try writeLiveSession()
        let app = try fx.holdAliveLock()
        defer { app.release() }
        try fx.writeConfig(#"{"endFloor": 0}"#)
        fx.setBattery("FAIL")

        let r = try fx.run(fx.backstop)

        try assertSessionKept(r)
        XCTAssertEqual(calls(), [thermalRead], "no battery read with the floor off")
    }

    /// A JSON string is not the Int or Bool the app decodes: "30" and
    /// "false" fall back to the defaults here as they do in the app, so both
    /// sides enforce the same floor and the same thermal rule.
    func testStringTypedConfigValuesAreIgnoredLikeTheAppDoes() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try writeLiveSession()
        try fx.writeConfig(#"{"endFloor": "30"}"#)
        fx.setBattery(fx.battery(source: "Battery Power", percent: 25))
        try assertSessionKept(try fx.run(fx.backstop))

        try writeLiveSession()
        fx.clearCalls()
        try fx.writeConfig(#"{"endFloor": "30"}"#)
        fx.setBattery(fx.battery(source: "Battery Power", percent: 9))
        try assertSessionEnded(try fx.run(fx.backstop), reason: "below the 10% end floor")

        try writeLiveSession()
        fx.clearCalls()
        try fx.writeConfig(#"{"thermalRules": "false", "endFloor": 10.0}"#)
        fx.setBattery(fx.battery(source: "AC Power", percent: 50, state: "charging"))
        fx.setThermal("4")
        try assertSessionEnded(try fx.run(fx.backstop), reason: "thermal pressure level 4")
    }

    /// The reads are bounded like the undo commands (COMMAND_TIMEOUT_SECONDS,
    /// 1 s in this fixture). A battery read that hangs is terminated and
    /// counts as unreadable: the session ends. A thermal read that hangs
    /// only warns.
    func testHungReadsAreBoundedBatteryFailsClosedThermalWarns() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try writeLiveSession()
        fx.setBattery("HANG")
        var started = Date()
        try assertSessionEnded(try fx.run(fx.backstop), reason: "pmset -g batt did not finish within 1s")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the hung read must not hold the run for its whole minute")
        XCTAssertTrue(fx.log().contains("did not finish within 1s; terminated with SIGTERM"), fx.log())
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("kill -TERM ") }, "the timeout signal goes through $KILL: \(fx.calls())")

        try writeLiveSession()
        fx.clearCalls()
        fx.setBattery(fx.battery(source: "AC Power", percent: 100, state: "charged"))
        fx.setThermal("HANG")
        started = Date()
        try assertSessionKept(try fx.run(fx.backstop))
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertTrue(fx.log().contains("thermal pressure level unreadable"), fx.log())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fx.home.path).filter { $0.hasPrefix(".backstop.") }
        XCTAssertEqual(leftovers, [], "status and capture files are cleaned up")
    }

    /// A read never holds the recovery lock: its supervisor closes fd 9
    /// before starting it, so neither has it while the run holds the lock.
    /// The fake looks with lsof, which can take seconds on a busy machine,
    /// so this run gets a 30 s time limit; the read answers as soon as it
    /// has looked, so the limit never fires.
    func testReadsRunWithoutTheLockDescriptor() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        try writeLiveSession()
        try fx.setCommandTimeout(30)
        fx.setThermal("CHECK_FD9")

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertTrue(fx.calls().contains("notifyutil checked fd 9"), "\(fx.calls())")
        XCTAssertFalse(fx.calls().contains { $0.hasSuffix("had fd 9") }, "neither the read nor its supervisor may inherit the lock: \(fx.calls())")
        XCTAssertFalse(fx.log().contains("did not finish"), fx.log())
    }

    /// A read that ignores SIGTERM and leaves a child behind is killed, and
    /// the lock is free the moment the run exits, so the next minute's run
    /// takes it and can still end the session.
    func testReadThatIgnoresSigtermLeavesTheLockToTheNextRun() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        try writeLiveSession()
        fx.setThermal("IGNORE_TERM")

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertTrue(fx.log().contains("ignored SIGTERM; sent SIGKILL"), fx.log())
        XCTAssertTrue(fx.calls().contains { $0.hasPrefix("kill -KILL ") }, "the timeout signal goes through $KILL: \(fx.calls())")
        XCTAssertTrue(fx.log().contains("thermal pressure level unreadable"), fx.log())
        XCTAssertTrue(try fx.lockIsFree(), "nothing the read started holds the lock")

        fx.clearCalls()
        fx.setThermal("3")
        try assertSessionEnded(try fx.run(fx.backstop), reason: "thermal pressure level 3")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fx.home.path).filter { $0.hasPrefix(".backstop.") }
        XCTAssertEqual(leftovers, [])
    }

    /// Levels 0 to 2 (nominal, moderate, heavy) keep the session; 3 and 4
    /// (trapping, sleeping) are what ProcessInfo reports as critical and
    /// end it.
    func testThermalPressureAtTrappingOrAboveEndsTheSession() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        for level in 0...2 {
            try writeLiveSession()
            fx.setThermal("\(level)")
            try assertSessionKept(try fx.run(fx.backstop))
        }
        for level in 3...4 {
            try writeLiveSession()
            fx.clearCalls()
            fx.setThermal("\(level)")
            try assertSessionEnded(try fx.run(fx.backstop), reason: "thermal pressure level \(level) (critical")
            XCTAssertEqual(calls(), [batteryRead, thermalRead, sleepRestored])
        }
    }

    /// Heat is read best effort: a failing or nonsensical notifyutil is a
    /// warning in the log, never an end on its own.
    func testThermalUnreadableWarnsWithoutEndingTheSession() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        for mode in ["FAIL", "GARBAGE"] {
            try writeLiveSession()
            fx.setThermal(mode)
            try assertSessionKept(try fx.run(fx.backstop))
            XCTAssertTrue(fx.log().contains("thermal pressure level unreadable"), fx.log())
            XCTAssertFalse(fx.log().contains("ending the session before its deadline"), fx.log())
        }
    }

    func testThermalRulesOffIgnoresCriticalHeat() throws {
        try writeLiveSession()
        let app = try fx.holdAliveLock()
        defer { app.release() }
        try fx.writeConfig(#"{"thermalRules": false}"#)
        fx.setThermal("4")

        let r = try fx.run(fx.backstop)

        try assertSessionKept(r)
        XCTAssertEqual(calls(), [batteryRead], "with the rule off the level is not even read")
    }

    /// A thermal end is logged with the level, and the log names the reason
    /// in the same line as the restore, so one grep tells the story.
    func testCutoffReasonIsInTheRestoreLogLine() throws {
        try writeLiveSession()
        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.setThermal("3")

        _ = try fx.run(fx.backstop)

        XCTAssertTrue(fx.log().contains("session ended early, thermal pressure level 3 (critical from 3 up) (endsAt="), fx.log())
        XCTAssertTrue(fx.log().contains("restoring from journal"), fx.log())
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

    // MARK: backstop.sh: an early end is final even when its undo is not

    private let journalWithSavedBrightness = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedDisplayBrightness":0.6}"#

    /// Saved brightness is the app's to restore, so the run that ends the
    /// session of an app that died cannot clear the journal. The session
    /// ends anyway: session.json goes, and what is left stays journaled.
    func testEarlyEndWithAnUndoOnlyTheAppCanFinishStillRemovesTheSession() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(journalWithSavedBrightness)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertFalse(fx.exists(fx.session), "a relaunched app must find no session to resume")
        let s = try fx.stateJSON()
        XCTAssertEqual(s["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual((s["savedDisplayBrightness"] as? NSNumber)?.doubleValue, 0.6, "kept for the app")
        XCTAssertTrue(fx.log().contains("Insomnia is not running"), fx.log())
    }

    /// A pmset that fails leaves sleep journaled, not the session. The next
    /// run finds no session to check and undoes what is journaled.
    func testEarlyEndWithAFailingPmsetRemovesTheSessionAndTheNextRunFinishes() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        try writeLiveSession()
        fx.setBattery(fx.battery(source: "Battery Power", percent: 9))
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "a failed pmset stays journaled")
        XCTAssertTrue(fx.log().contains("journal kept dirty"), fx.log())

        fx.setMode("sudo", "ok")
        fx.clearCalls()
        let next = try fx.run(fx.backstop)

        XCTAssertEqual(next.status, 0, next.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "no session left, so nothing is read before the undo")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
    }

    /// --force (install.sh, uninstall.sh) ends a valid session the same way.
    func testForcedEndWithAFailingPmsetStillRemovesTheSession() throws {
        try writeLiveSession()
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.backstop, ["--force"])

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true)
        XCTAssertTrue(fx.log().contains("forced end of session"), fx.log())
    }

    /// An undo that hangs stops the run with the journal as read and the
    /// lock with the live command. The session it ended is gone all the
    /// same, so the app sees the end and nothing can resume it.
    func testEarlyEndWhoseUndoHangsStillRemovesTheSession() throws {
        try writeLiveSession()
        fx.setMode("sudo", "ignore-term")

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), liveJournal, "journal unchanged while the command runs")
        XCTAssertFalse(try fx.lockIsFree(), "the live command keeps the lock")
        fx.releaseCommand()
        XCTAssertTrue(try fx.waitUntilLockIsFree())
    }

    /// The relaunch the early end must not undo. The backstop ends the
    /// session of an app that died; its pmset fails and the saved
    /// brightness is the app's to restore. Insomnia launched afterwards
    /// finds no session, so it does not disable sleep again: it restores
    /// what the journal still holds and leaves it clean.
    @MainActor
    func testAppRelaunchedAfterAPartialEarlyEndRestoresInsteadOfResuming() async throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(journalWithSavedBrightness)
        fx.setMode("sudo", "fail")
        XCTAssertEqual(try fx.run(fx.backstop).status, 1, fx.log())
        XCTAssertFalse(fx.exists(fx.session))

        // The app logs into the fixture, not ~/Library/Logs/Insomnia.
        setenv(Paths.environmentKey, fx.home.path, 1)
        defer { unsetenv(Paths.environmentKey) }
        let paths = Paths.fromEnvironment()
        let sleepGuard = FakeSleepGuard()
        let display = FakeDisplayDimmer(brightness: 0)
        let m = SessionManager(
            paths: paths,
            sleepGuard: sleepGuard,
            processControl: FakeProcessControl(),
            backstop: FakeBackstop(),
            display: display,
            clamshell: { false },
            recoveryLockTimeout: 2,
            recoveryRetryDelay: 3600,
            reassertDelay: .seconds(3600)
        )
        await m.reconcile()

        XCTAssertNil(m.session, "the ended session must not come back")
        XCTAssertFalse(sleepGuard.calls.contains("disablesleep 1"), "\(sleepGuard.calls)")
        XCTAssertTrue(sleepGuard.calls.contains("disablesleep 0"), "\(sleepGuard.calls)")
        XCTAssertEqual(display.sets.last, 0.6)
        let after = try XCTUnwrap(try Store(paths: paths).loadState())
        XCTAssertFalse(after.isDirty, "\(after)")
    }

    // MARK: backstop.sh: a session.json that cannot be removed

    /// session.json is immutable, so the run that ends the session cannot
    /// remove it. It records the end in ended-session.json, a copy of the
    /// file's bytes, and still restores sleep. Later runs end the session
    /// again without reading the battery or the heat, even with the app
    /// alive, and retry the removal; once it works the record goes too.
    func testEndThatCannotRemoveSessionJSONRecordsItAndLaterRunsFinish() throws {
        try writeLiveSession()
        try setImmutable(fx.session, true)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "sleep is restored all the same")
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try Data(contentsOf: fx.endedSession), try Data(contentsOf: fx.session), "the record is the file's exact bytes")
        XCTAssertTrue(fx.log().contains("its end is recorded in"), fx.log())

        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 1, again.stderr + fx.log())
        XCTAssertEqual(calls(), [], "a session recorded as ended is not checked again")
        XCTAssertTrue(fx.log().contains("already ended (recorded in"), fx.log())
        XCTAssertTrue(fx.exists(fx.endedSession))

        try setImmutable(fx.session, false)
        let last = try fx.run(fx.backstop)

        XCTAssertEqual(last.status, 0, last.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.endedSession), "the record goes with the file it copies")
    }

    /// Neither session.json nor the record can be written: nothing on disk
    /// says the session is over. Sleep is restored anyway, but its journal
    /// entry stays as evidence and the run exits 1.
    func testEndThatCanNeitherRemoveNorRecordKeepsTheSleepEntry() throws {
        try writeLiveSession()
        try setImmutable(fx.session, true)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "evidence kept while the session still reads as valid")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.endedSession, encoding: .utf8), "{}")
        let log = fx.log()
        XCTAssertTrue(log.contains("could not remove \(fx.session.path) or record its end"), log)
        XCTAssertTrue(log.contains("still journaled: sleepDisabledByUs is kept although sleep is restored"), log)
    }

    /// A record left from an earlier session.json matches nothing: it goes,
    /// and the live session is checked as usual.
    func testStaleEndRecordIsRemovedAndDoesNotEndTheSession() throws {
        try writeLiveSession()
        try #"{"endsAt":"2001-01-01T00:00:00Z","startedAt":"2001-01-01T00:00:00Z"}"#.write(to: fx.endedSession, atomically: true, encoding: .utf8)
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertEqual(calls(), [batteryRead, thermalRead])
        XCTAssertFalse(fx.exists(fx.endedSession))
    }

    /// A stale record that cannot be removed ends nothing, but it is a copy
    /// of a session's times, so every run says it is still there.
    func testStaleEndRecordThatCannotBeRemovedIsLogged() throws {
        try writeLiveSession()
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertTrue(fx.exists(fx.endedSession))
        XCTAssertTrue(fx.log().contains("could not remove \(fx.endedSession.path)"), fx.log())
    }

    /// The relaunch the record exists for. The backstop ends the session of
    /// an app that died and cannot remove session.json. Insomnia launched
    /// afterwards finds a valid session.json, sees the record and restores
    /// instead of resuming. Once the file can be removed, its next reconcile
    /// removes both.
    @MainActor
    func testAppRelaunchedAfterAnEndRecordRestoresInsteadOfResuming() async throws {
        // Written by the app's Store, so the app reads it as a valid session.
        try Store(paths: Paths(root: fx.home)).saveSession(Session(startedAt: Date(timeIntervalSinceNow: -600), endsAt: Date(timeIntervalSinceNow: 3600)))
        try fx.writeState(journalWithSavedBrightness)
        try setImmutable(fx.session, true)
        XCTAssertEqual(try fx.run(fx.backstop).status, 1, fx.log())
        XCTAssertTrue(fx.exists(fx.endedSession))

        setenv(Paths.environmentKey, fx.home.path, 1)
        defer { unsetenv(Paths.environmentKey) }
        let paths = Paths.fromEnvironment()
        let sleepGuard = FakeSleepGuard()
        let display = FakeDisplayDimmer(brightness: 0)
        let notifier = RecordingNotifier()
        let m = SessionManager(
            paths: paths,
            sleepGuard: sleepGuard,
            processControl: FakeProcessControl(),
            backstop: FakeBackstop(),
            display: display,
            notifier: notifier,
            clamshell: { false },
            recoveryLockTimeout: 2,
            recoveryRetryDelay: 3600,
            reassertDelay: .seconds(3600)
        )
        await m.reconcile()

        XCTAssertNil(m.session, "the ended session must not come back")
        XCTAssertFalse(sleepGuard.calls.contains("disablesleep 1"), "\(sleepGuard.calls)")
        XCTAssertEqual(display.sets.last, 0.6)
        XCTAssertFalse(try XCTUnwrap(try Store(paths: paths).loadState()).isDirty)
        XCTAssertTrue(notifier.posts.contains { $0.body.contains("its end is recorded, so a relaunch will not resume it") }, "\(notifier.posts)")

        try setImmutable(fx.session, false)
        await m.reconcile()

        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.endedSession))
        XCTAssertFalse(sleepGuard.calls.contains("disablesleep 1"), "\(sleepGuard.calls)")
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
    /// Uninstall then finishes, and nothing left running holds the lock.
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
        XCTAssertLessThan(elapsed, 20, "one bounded read, not the fake's 60 s hang")
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("defaults read") },
                       Config.defaultAgentList[...index].map { "defaults read \($0) NSAppSleepDisabled" },
                       "the check stops at the read that did not answer")
        XCTAssertFalse(fx.calls().contains("defaults FD9-OPEN"), "the read runs without the lock descriptor")
        XCTAssertTrue(fx.hungProcessGone("defaults"), "the read ignored SIGTERM, so it was killed")
        XCTAssertTrue(r.stdout.contains("defaults read did not answer within 1s for com.google.Chrome; check it yourself with: defaults read com.google.Chrome NSAppSleepDisabled"), r.stdout)
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
        XCTAssertLessThan(elapsed, 20, "one bounded print, not the fake's 60 s hang")
        XCTAssertTrue(r.stderr.contains("'launchctl print' did not answer within 1s; cannot tell whether com.insomnia.backstop is still loaded"), r.stderr)
        XCTAssertFalse(fx.calls().contains("launchctl FD9-OPEN"), "\(fx.calls())")
        XCTAssertTrue(fx.hungProcessGone("launchctl"))
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("sudo rm") }, "\(fx.calls())")
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
        XCTAssertLessThan(elapsed, 20)
        XCTAssertTrue(r.stderr.contains("pgrep did not answer within 1s; treating Insomnia as running."), r.stderr)
        XCTAssertFalse(fx.calls().contains("pgrep FD9-OPEN"), "\(fx.calls())")
        XCTAssertTrue(fx.hungProcessGone("pgrep"))
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

        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        for gone in [fx.state, fx.config, fx.endedSession, fx.logFile, fx.home.appendingPathComponent("Logs/handoffs.log"),
                     fx.installedBackstop, fx.plist, fx.app, fx.sudoers] {
            XCTAssertFalse(fx.exists(gone), gone.path)
        }
        XCTAssertFalse(fx.exists(fx.home.appendingPathComponent("Logs")), "empty owned directories are removed")
        XCTAssertFalse(fx.exists(fx.home.appendingPathComponent("LaunchAgents")))
        XCTAssertTrue(fx.exists(fx.lock), "the lock file is the documented leftover")
        XCTAssertEqual(try fx.contents(of: fx.home), [".recovery.lock"], "nothing but the lock remains")
        XCTAssertTrue(fx.exists(fx.appsDir))
        XCTAssertTrue(fx.exists(fx.bin), "nothing outside the Insomnia tree is deleted")
    }

    /// An end record that cannot be removed survives the purge, and the
    /// purge says so instead of reporting everything gone.
    func testUninstallPurgeReportsAnEndRecordItCannotRemove() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(fx.endedSession))
        XCTAssertTrue(r.stdout.contains("Kept \(fx.endedSession.path): it could not be removed"), r.stdout)
        XCTAssertFalse(fx.exists(fx.state))
        XCTAssertFalse(fx.exists(fx.config))
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
            #"{"sleepDisabledByUs":false,"appNapOverrides":"com.google.Chrome"}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":["com.google.Chrome"]}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":[{"previous":true}]}"#,
            #"{"sleepDisabledByUs":false,"appNapOverrides":[{"bundleId":"com.google.Chrome","previous":"yes"}]}"#,
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
        let json = #"{"sleepDisabledByUs":false,"lowPowerSetByUs":null,"frozenProcesses":[],"dockerFrozen":false,"savedOutputVolume":null,"savedMuted":null,"savedDisplayBrightness":null,"savedKeyboardBrightness":null,"frozenPids":null,"appNapOverrides":null}"#
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
            #"{"sleepDisabledByUs":false,"appNapOverrides":[{"previous":true}]}"#,
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
        XCTAssertEqual(fx.calls().filter { !$0.hasPrefix("kill -TERM ") }, ["sudo -n \(fx.fakePmset) -a disablesleep 0"], "no second undo while the first is alive, and no SIGKILL")
        XCTAssertEqual(fx.calls().filter { $0.hasPrefix("kill -TERM ") }.count, 1, "\(fx.calls())")
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
        XCTAssertTrue(r.stderr.contains("backstop.sh\" --force"), "manual step named: \(r.stderr)")
        XCTAssertTrue(r.stderr.contains("not replaced"), r.stderr)
        XCTAssertTrue(try fx.lockIsFree(), "the transaction ends with the script")
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

    func testInstallRestoresThePreviousAgentWhenBootstrapFails() throws {
        try fx.prepareInstall()
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
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/MacOS/Insomnia")))
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"], "no staged leftovers")
    }

    func testInstallReplacesTheAgentAfterCleanRecovery() throws {
        try fx.prepareInstall()
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
        let plist = try String(contentsOf: fx.plist, encoding: .utf8)
        XCTAssertTrue(plist.contains("<integer>60</integer>"), plist)
        XCTAssertTrue(plist.contains(fx.installedBackstop.path), plist)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertTrue(fx.exists(fx.installedBackstop))
        XCTAssertTrue(fx.exists(fx.sudoers))
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/Info.plist")))
        XCTAssertTrue(fx.exists(fx.app.appendingPathComponent("Contents/Resources/AppIcon.icns")), "the app icon is bundled")
        XCTAssertTrue(r.stdout.contains("Installed"), r.stdout)
        XCTAssertEqual(try fx.contents(of: fx.plist.deletingLastPathComponent()), ["com.insomnia.backstop.plist"])
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
    var endedSession: URL { home.appendingPathComponent("ended-session.json") }
    var state: URL { home.appendingPathComponent("state.json") }
    var config: URL { home.appendingPathComponent("config.json") }
    var lock: URL { home.appendingPathComponent(".recovery.lock") }
    var alive: URL { home.appendingPathComponent(".app.alive") }
    var installedBackstop: URL { home.appendingPathComponent("backstop.sh") }
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
        // A test that failed before clearing the flag must not leave its
        // temp home behind.
        for file in [session, endedSession] { try? setImmutable(file, false) }
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
            "NOTIFYUTIL": bin.appendingPathComponent("notifyutil").path,
            "DEFAULTS": bin.appendingPathComponent("defaults").path,
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
            "DEFAULTS": bin.appendingPathComponent("defaults").path,
            "APP": app.path,
            "SUDOERS": sudoers.path,
            "LOCK_TIMEOUT_SECONDS": "1",
            "QUIT_WAIT_SECONDS": "1",
            "CALL_TIMEOUT_SECONDS": "1",
        ]).write(to: uninstall, atomically: true, encoding: .utf8)

        // install.sh: every $HOME-derived path and every tool is redirected
        // into the fixture (build, signing, sudo, launchctl included).
        let installText = try String(contentsOf: src.appendingPathComponent("install.sh"), encoding: .utf8)
        let patchedInstall = try Self.patch(installText, [
            "QUIT_WAIT_SECONDS": "1",
            "APP_DIR": appsDir.path,
            "APP_SUPPORT": home.path,
            "LOG_DIR": home.appendingPathComponent("Logs").path,
            "LAUNCH_AGENTS": home.appendingPathComponent("LaunchAgents").path,
            "SUDOERS": sudoers.path,
            "PGREP": bin.appendingPathComponent("pgrep").path,
            "OSASCRIPT": bin.appendingPathComponent("osascript").path,
            "LAUNCHCTL": bin.appendingPathComponent("launchctl").path,
            "SUDO": bin.appendingPathComponent("sudo").path,
            "CODESIGN": bin.appendingPathComponent("codesign").path,
            "SWIFT": bin.appendingPathComponent("swift").path,
            "LOCK_TIMEOUT_SECONDS": "1",
        ])
        try patchedInstall.write(to: install, atomically: true, encoding: .utf8)
        // The redirected copy runs past the INSOMNIA_HOME refusal: that
        // variable is what makes the backstop copy it installs act on the
        // fixture instead of ~/Library. The plain copy keeps the refusal.
        try Self.replaceOnce(patchedInstall, #"if [[ -n "${INSOMNIA_HOME:-}" ]]; then"#, with: "if false; then")
            .write(to: installRedirected, atomically: true, encoding: .utf8)
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
        // pmset: `-g batt` is the only form the script may run directly. It
        // prints pmset.batt when the test wrote one ("FAIL": exit 1 with no
        // output), else a MacBook on AC power at 100%. Any other direct call
        // is recorded as DIRECT and fails: power changes go through sudo.
        try writeFake("pmset", """
        if [[ "${1:-}" == -g && "${2:-}" == batt ]]; then
          printf 'pmset -g batt\\n' >> "\(calls)"
          if [[ -f "\(r)/pmset.batt" ]]; then
            [[ "$(cat "\(r)/pmset.batt")" == FAIL ]] && exit 1
            [[ "$(cat "\(r)/pmset.batt")" == HANG ]] && exec /bin/sleep 60
            cat "\(r)/pmset.batt"; exit 0
          fi
          printf "Now drawing from 'AC Power'\\n -InternalBattery-0 (id=1)\\t100%%; charged; 0:00 remaining present: true\\n"
          exit 0
        fi
        printf 'pmset DIRECT %s\\n' "$*" >> "\(calls)"
        exit 99
        """)
        // notifyutil -g <key>: prints "<key> <level>" with the level from
        // thermal.mode (default 0). "FAIL": exit 1 with no output. "GARBAGE":
        // exit 0 with a line that has no level in it. "HANG": never returns.
        // "IGNORE_TERM": never returns and ignores SIGTERM; it leaves a child
        // behind that would keep any descriptor it inherited. "CHECK_FD9":
        // records whether it or its parent (the read's supervisor) has fd 9
        // open, then prints level 0. lsof can take seconds on a busy machine,
        // so a test using it raises the time limit (setCommandTimeout).
        try writeFake("notifyutil", """
        printf 'notifyutil %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/thermal.mode" 2>/dev/null || echo 0)"
        [[ "$mode" == FAIL ]] && exit 1
        [[ "$mode" == HANG ]] && exec /bin/sleep 60
        if [[ "$mode" == IGNORE_TERM ]]; then
          trap '' TERM
          /bin/sleep 5 </dev/null >/dev/null 2>&1 &
          exec /bin/sleep 60
        fi
        if [[ "$mode" == CHECK_FD9 ]]; then
          [[ -e /dev/fd/9 ]] && printf 'notifyutil had fd 9\\n' >> "\(calls)"
          [[ -n "$(/usr/sbin/lsof -a -p "$PPID" -d 9 -t 2>/dev/null)" ]] && printf 'notifyutil supervisor had fd 9\\n' >> "\(calls)"
          printf 'notifyutil checked fd 9\\n' >> "\(calls)"
          echo "${2:-} 0"; exit 0
        fi
        [[ "$mode" == GARBAGE ]] && { echo "something unexpected"; exit 0; }
        echo "${2:-} $mode"
        """)
        // swift / codesign: install.sh's build and signing steps, redirected
        // to a fake binary inside the fixture.
        try writeFake("swift", """
        printf 'swift %s\\n' "$*" >> "\(calls)"
        for a in "$@"; do [[ "$a" == --show-bin-path ]] && { echo "\(r)/binroot"; exit 0; }; done
        exit 0
        """)
        try writeFake("codesign", """
        printf 'codesign %s\\n' "$*" >> "\(calls)"
        exit 0
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
        // kill: a timeout's -TERM or -KILL goes on to the real kill only
        // for a command the run under test started (its pid is in one of
        // the run's .backstop.*.pid files), so that command really stops.
        // Any other pid, such as a journal's frozen pid, is never signalled.
        try writeFake("kill", """
        printf 'kill %s\\n' "$*" >> "\(calls)"
        fail="$(cat "\(r)/kill.fail.mode" 2>/dev/null || true)"
        for f in $fail; do [[ "$f" == "${2:-}" ]] && exit 1; done
        case "${1:-}" in
          -TERM|-KILL)
            if [[ -n "${2:-}" ]] && cat "\(home.path)"/.backstop.*.pid 2>/dev/null | grep -qx -- "$2"; then
              exec /bin/kill "$1" "$2"
            fi ;;
        esac
        exit 0
        """)
        try writeFake("sysctl", """
        cat "\(r)/boot.uuid"
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
        // order; the last line repeats. Default 1 (not running).
        try writeFake("pgrep", """
        printf 'pgrep %s\\n' "$*" >> "\(calls)"
        f="\(r)/pgrep.mode"
        [[ -f "$f" ]] || exit 1
        first="$(head -n 1 "$f")"
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
        fi
        \(hangHere("launchctl"))
        if [[ "${1:-}:$mode" == print:print-hangs ]]; then hang_here; fi
        prints=0
        if [[ "${1:-}" == print ]]; then
          prints=$(( $(cat "\(r)/print.count" 2>/dev/null || echo 0) + 1 )); echo "$prints" > "\(r)/print.count"
        fi
        case "${1:-}:$mode" in
          bootout:print-hangs) exit 0 ;;
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

    func setMode(_ name: String, _ value: String) {
        try? value.write(to: root.appendingPathComponent("\(name).mode"), atomically: true, encoding: .utf8)
    }

    /// What the fake `pmset -g batt` prints ("FAIL": it fails instead;
    /// "HANG": it never returns). The fixture default is a MacBook on AC
    /// power at 100%.
    func setBattery(_ output: String) {
        try? output.write(to: root.appendingPathComponent("pmset.batt"), atomically: true, encoding: .utf8)
    }

    /// `pmset -g batt` as a MacBook prints it, tab and all.
    func battery(source: String, percent: Int, state: String = "discharging") -> String {
        "Now drawing from '\(source)'\n -InternalBattery-0 (id=22610019)\t\(percent)%; \(state); 0:41 remaining present: true\n"
    }

    /// The thermal pressure level the fake notifyutil reports (default 0),
    /// or "FAIL" / "GARBAGE" / "HANG".
    func setThermal(_ mode: String) {
        setMode("thermal", mode)
    }

    func writeConfig(_ json: String) throws {
        try json.write(to: config, atomically: true, encoding: .utf8)
    }

    /// Sets COMMAND_TIMEOUT_SECONDS in this fixture's copy of backstop.sh,
    /// for a fake command that needs more than the default 1 s to look
    /// around before it answers.
    func setCommandTimeout(_ seconds: Int) throws {
        let text = try String(contentsOf: backstop, encoding: .utf8)
        try Self.patch(text, ["COMMAND_TIMEOUT_SECONDS": "\(seconds)"]).write(to: backstop, atomically: true, encoding: .utf8)
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
        try fm.copyItem(at: backstop, to: installedBackstop)
    }

    // MARK: Running

    func calls() -> [String] {
        guard let text = try? String(contentsOf: callsLog, encoding: .utf8) else { return [] }
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
        ]
    }

    /// Inode of a file, to prove the lock file was retained rather than replaced.
    func inode(_ url: URL) throws -> UInt64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// Runs a script copy. `fd9` opens that file on descriptor 9 of the child
    /// first, the way uninstall.sh hands its lock handle to the backstop.
    /// `extraEnvironment` is for install.sh's refusal test and for a
    /// private TMPDIR (see privateTmp).
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

    /// Holds the alive lock the way the running app does, with its own type
    /// (AppAliveLock.swift), in this process until the test releases it. No
    /// timer: it cannot run out between the script runs of a slow test.
    func holdAliveLock() throws -> AppAliveLock {
        let lock = AppAliveLock(url: alive)
        guard try lock.tryAcquire() else { throw FixtureError("could not take \(alive.lastPathComponent): another holder has it") }
        return lock
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
