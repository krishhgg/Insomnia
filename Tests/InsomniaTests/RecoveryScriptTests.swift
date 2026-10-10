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
/// (sudo, pmset, ps, kill, sysctl, notifyutil, ioreg, pgrep, pkill,
/// osascript, launchctl, defaults) and its app-bundle / sudoers paths rewritten to
/// point inside the fixture, so nothing privileged runs, no real process is
/// signaled, no real app's preferences are read or written, and no real
/// home, LaunchAgent, sudoers file, or installed app is read or written.
/// plutil, lockf and cmp are the real tools, and so is date, except for the
/// backstop's moved-aside stamp, which a test can freeze. The fakes record
/// every call.
final class RecoveryScriptTests: XCTestCase {
    private var fx: ScriptFixture!

    override func setUpWithError() throws {
        fx = try ScriptFixture()
    }

    override func tearDown() {
        fx.destroy()
        fx = nil
        // The app tests here point INSOMNIA_HOME at the fixture. Whatever a
        // test did, the next one must start on the loader's throwaway home,
        // never on an unset variable that resolves the real ~/Library.
        let home = ProcessTestHome.current
        if home != ProcessTestHome.root.path {
            setenv(Paths.environmentKey, ProcessTestHome.root.path, 1)
            XCTFail("the test left INSOMNIA_HOME at \(home ?? "unset"), not \(ProcessTestHome.root.path)")
        }
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
    private let batteryServiceRead = "ioreg -r -c AppleSmartBattery -d 1"

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

    /// Greptile 4219151866: a journal the app does not load stops the run
    /// before a valid session is ended, whatever ends it (the battery with
    /// the app alive, config.json missing or read, the app not running,
    /// --force): session.json and the journal stay byte for byte, no end is
    /// recorded anywhere, nothing runs, and the log says why. The app's
    /// decoder refuses each of these journals. The review's trace is the
    /// first journal with config.json missing, at 20%. Once the journal is
    /// repaired the next run ends the session. A journal with a key written
    /// twice, which the app reads by its first copy, ends the session: the
    /// next test.
    func testAJournalTheAppDoesNotLoadKeepsAValidSessionTheRunWouldEnd() throws {
        let journals = [
            #"{"sleepDisabledByUs":true,"frozenProcesses":"bad","sessionCutoffs":"30 false"}"#,
            #"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":2147483648}],"sessionCutoffs":"30 false"}"#,
            #"{"sleepDisabledByUs":true,"sessionCutoffs":"30 false","#,
        ]
        let modes: [(name: String, alive: Bool, config: String?, args: [String], kept: String)] = [
            ("app alive, config.json missing", true, nil, [], "its cutoffs are not read and it is not ended"),
            ("app alive, config.json read", true, #"{"endFloor":30,"thermalRules":false}"#, [], "it is not ended"),
            ("app not running", false, nil, [], "it is not ended"),
            ("--force", true, nil, ["--force"], "it is not ended"),
        ]
        for journal in journals {
            XCTAssertThrowsError(try Store.makeDecoder().decode(RuntimeState.self, from: Data(journal.utf8)), journal)
            for mode in modes {
                let label = "\(mode.name), \(journal)"
                try? FileManager.default.removeItem(at: fx.config)
                if let config = mode.config { try fx.writeConfig(config) }
                try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
                let session = try Data(contentsOf: fx.session)
                try fx.writeState(journal)
                try? FileManager.default.removeItem(at: fx.logFile)
                fx.setBattery(fx.battery(source: "Battery Power", percent: 20))
                fx.clearCalls()
                let app = mode.alive ? try fx.holdAliveLock() : nil

                let r = try fx.run(fx.backstop, mode.args)
                app?.release()

                XCTAssertEqual(r.status, 1, "\(label): \(fx.log())")
                XCTAssertEqual(try Data(contentsOf: fx.session), session, label)
                XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), journal, label)
                XCTAssertEqual(try fx.contents(of: fx.home).filter { $0.hasPrefix("ended-session") }, [], label)
                XCTAssertEqual(((try? fx.contents(of: fx.logFile.deletingLastPathComponent())) ?? []).filter { $0.hasPrefix("ended-session") }, [], label)
                let lockBytes = fx.exists(fx.lock) ? try Data(contentsOf: fx.lock) : Data()
                XCTAssertFalse(String(decoding: lockBytes, as: UTF8.self).contains("ended-session-v1"), label)
                XCTAssertFalse(calls().contains { $0.hasPrefix("sudo") || $0.hasPrefix("kill") }, "\(label): \(calls())")
                XCTAssertTrue(fx.log().contains("is unreadable or malformed; nothing undone, evidence kept"), "\(label): \(fx.log())")
                XCTAssertTrue(fx.log().contains("\(fx.session.path) is kept as it is: \(mode.kept) while"), "\(label): \(fx.log())")
            }
        }

        try? FileManager.default.removeItem(at: fx.config)
        try fx.writeState(#"{"sleepDisabledByUs":true,"frozenProcesses":[],"sessionCutoffs":"30 false"}"#)
        fx.clearCalls()
        let r = try fx.run(fx.backstop)
        try assertSessionEnded(r, reason: "Insomnia is not running")
    }

    /// The controls: the same session with a journal the app loads, as this
    /// build writes it or as an older one did (frozenPids, no record of the
    /// cutoffs), ends in each mode. With the app alive and config.json
    /// missing, the record's 30% floor ends it at 20%, and the defaults'
    /// 10% one at 9% only. A key written twice, as such or once with an
    /// escape, is read by its first copy, as the app reads it: those
    /// journals end the session in each mode of the test above, and the
    /// journal published holds the key once, with that copy's value.
    func testAJournalTheAppLoadsLetsTheRunEndAValidSession() throws {
        let current = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"savedAudioOutputs":[],"appNapOverrides":[],"sessionCutoffs":"30 false"}"#
        let legacy = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenPids":[],"dockerFrozen":false}"#
        let cases: [(journal: String, alive: Bool, args: [String], battery: Int, reason: String?)] = [
            (current, true, [], 20, "below the 30% end floor"),
            (current, true, [], 31, nil),
            (legacy, true, [], 9, "below the 10% end floor"),
            (legacy, true, [], 20, nil),
            (current, false, [], 20, "Insomnia is not running"),
            (legacy, false, [], 20, "Insomnia is not running"),
            (current, true, ["--force"], 20, "forced end of session"),
            (legacy, true, ["--force"], 20, "forced end of session"),
        ]
        for c in cases {
            let label = "\(c.args) alive \(c.alive) at \(c.battery)%: \(c.journal)"
            XCTAssertNoThrow(try Store.makeDecoder().decode(RuntimeState.self, from: Data(c.journal.utf8)), label)
            try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
            try fx.writeState(c.journal)
            try? FileManager.default.removeItem(at: fx.logFile)
            fx.setBattery(fx.battery(source: "Battery Power", percent: c.battery))
            fx.clearCalls()
            let app = c.alive ? try fx.holdAliveLock() : nil

            let r = try fx.run(fx.backstop, c.args)
            app?.release()

            if let reason = c.reason {
                XCTAssertEqual(r.status, 0, "\(label): \(fx.log())")
                XCTAssertTrue(calls().contains(sleepRestored), "\(label): \(calls()) \(fx.log())")
                XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false, label)
                XCTAssertFalse(fx.exists(fx.session), label)
                XCTAssertTrue(fx.log().contains(reason), "\(label): \(fx.log())")
                XCTAssertFalse(fx.log().contains("unreadable or malformed"), "\(label): \(fx.log())")
            } else {
                XCTAssertEqual(r.status, 0, "\(label): \(fx.log())")
                XCTAssertTrue(fx.exists(fx.session), label)
                XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), c.journal, label)
            }
        }

        // pids: the frozen processes the app reads, by pid (nil: no
        // frozenProcesses key). Pid 5 has no startedAt, so there is no
        // identity to check and nothing signals it; its entry stays, and
        // the run exits 1 with the journal kept for it.
        let b = backslash
        let twice: [(journal: String, pids: [Int32]?)] = [
            (#"{"sleepDisabledByUs":true,"sleepDisabledByUs":false,"frozenProcesses":[],"sessionCutoffs":"30 false"}"#, []),
            (#"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":5,"pid":6}],"sessionCutoffs":"30 false"}"#, [5]),
            (#"{"sleepDisabledByUs":true,"sleepDisabledBy\#(b)u0055s":true,"sessionCutoffs":"30 false"}"#, nil),
        ]
        let modes: [(name: String, alive: Bool, config: String?, args: [String], reason: String)] = [
            ("app alive, config.json missing", true, nil, [], "below the 30% end floor"),
            ("app alive, config.json read", true, #"{"endFloor":30,"thermalRules":false}"#, [], "below the 30% end floor"),
            ("app not running", false, nil, [], "Insomnia is not running"),
            ("--force", true, nil, ["--force"], "forced end of session"),
        ]
        for row in twice {
            let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: Data(row.journal.utf8))
            XCTAssertTrue(decoded.sleepDisabledByUs, row.journal)
            XCTAssertEqual(decoded.frozenProcesses.map(\.pid), row.pids ?? [], row.journal)
            for mode in modes {
                let label = "\(mode.name), \(row.journal)"
                try? FileManager.default.removeItem(at: fx.config)
                if let config = mode.config { try fx.writeConfig(config) }
                try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
                try fx.writeState(row.journal)
                try? FileManager.default.removeItem(at: fx.logFile)
                fx.setBattery(fx.battery(source: "Battery Power", percent: 20))
                fx.clearCalls()
                let app = mode.alive ? try fx.holdAliveLock() : nil

                let r = try fx.run(fx.backstop, mode.args)
                app?.release()

                let kept = row.pids ?? []
                XCTAssertEqual(r.status, kept.isEmpty ? 0 : 1, "\(label): \(fx.log())")
                for pid in kept {
                    XCTAssertTrue(fx.log().contains("pid \(pid) was journaled without identity; not signaled, kept for the app to resolve"), "\(label): \(fx.log())")
                }
                XCTAssertTrue(calls().contains(sleepRestored), "\(label): \(calls()) \(fx.log())")
                XCTAssertFalse(calls().contains { $0.hasPrefix("kill") }, "\(label): \(calls())")
                XCTAssertFalse(fx.exists(fx.session), label)
                XCTAssertTrue(fx.log().contains(mode.reason), "\(label): \(fx.log())")
                XCTAssertFalse(fx.log().contains("unreadable or malformed"), "\(label): \(fx.log())")
                let text = try String(contentsOf: fx.state, encoding: .utf8)
                XCTAssertEqual(text.components(separatedBy: "sleepDisabledBy").count, 2, "\(label): \(text)")
                XCTAssertEqual(text.components(separatedBy: #""pid""#).count, (row.pids?.count ?? 0) + 1, "\(label): \(text)")
                let published = try fx.stateJSON()
                XCTAssertEqual(published["sleepDisabledByUs"] as? Bool, false, label)
                XCTAssertEqual(published["frozenProcesses"] as? [[String: Int]], row.pids.map { $0.map { ["pid": Int($0)] } }, label)
                XCTAssertEqual(published["sessionCutoffs"] as? String, "30 false", label)
            }
        }
        try? FileManager.default.removeItem(at: fx.config)
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

    /// No InternalBattery line and no AppleSmartBattery service is a
    /// desktop: there is no battery rule, and the thermal check still runs.
    func testDesktopWithoutABatteryHasNoBatteryRule() throws {
        try writeLiveSession()
        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.setBattery("Now drawing from 'AC Power'\n")

        let r = try fx.run(fx.backstop)

        try assertSessionKept(r)
        XCTAssertEqual(calls(), [batteryRead, batteryServiceRead, thermalRead])
    }

    /// A laptop whose power source list lost its battery row still has the
    /// AppleSmartBattery service, as the app's PowerMonitor.classify checks.
    /// Its level is unknown, so the session ends unless the driver reports a
    /// charger. An ioreg that fails or hangs cannot show a desktop either.
    func testABatteryMissingFromPmsetIsJudgedByTheBatteryService() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        let ended: [(mode: String, reason: String)] = [
            ("BATTERY", "battery present (AppleSmartBattery) but missing from pmset -g batt, and no charger reported"),
            ("BATTERY_NOKEY", "battery present (AppleSmartBattery) but missing from pmset -g batt, and no charger reported"),
            ("FAIL", "no battery in pmset -g batt, and ioreg exit 1 could not show there is none"),
            ("HANG", "no battery in pmset -g batt, and ioreg did not finish within 1s"),
        ]
        for c in ended {
            try writeLiveSession()
            fx.clearCalls()
            fx.clearLog()
            fx.setBattery("Now drawing from 'AC Power'\n")
            fx.setBatteryService(c.mode)
            try assertSessionEnded(try fx.run(fx.backstop), reason: c.reason)
            XCTAssertTrue(calls().contains(batteryServiceRead), "\(calls())")
        }

        try writeLiveSession()
        fx.clearCalls()
        fx.setBatteryService("BATTERY_AC")
        try assertSessionKept(try fx.run(fx.backstop))
        XCTAssertEqual(calls(), [batteryRead, batteryServiceRead, thermalRead])
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

    /// JSONDecoder reads a number that is exactly an integer as an Int, so
    /// 30.0 and 3e1 are a 30% floor in the app and 0.0 turns the rule off; a
    /// fraction fails the app's decode, which then uses the default 10. The
    /// app clamps the floor to 0...95 (Config.normalizeFloors). The backstop
    /// enforces the same floor in every case.
    func testNumericEndFloorsAreReadAsTheAppDecodesAndClampsThem() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        let ended: [(config: String, percent: Int, floor: Int)] = [
            (#"{"configVersion": 2, "endFloor": 30.0}"#, 25, 30),
            (#"{"endFloor": 3e1}"#, 25, 30),
            (#"{"endFloor": 30.5}"#, 9, 10),
            (#"{"endFloor": 30.0000001}"#, 9, 10),
            (#"{"endFloor": 200}"#, 90, 95),
        ]
        for c in ended {
            try writeLiveSession()
            fx.clearCalls()
            fx.clearLog()
            try fx.writeConfig(c.config)
            fx.setBattery(fx.battery(source: "Battery Power", percent: c.percent))
            try assertSessionEnded(try fx.run(fx.backstop), reason: "battery at \(c.percent)% on battery power, below the \(c.floor)% end floor")
        }
        let kept: [(config: String, percent: Int)] = [
            (#"{"endFloor": 30.5}"#, 25),
            (#"{"endFloor": 0.0}"#, 1),
            (#"{"endFloor": -5}"#, 1),
        ]
        for c in kept {
            try writeLiveSession()
            fx.clearCalls()
            try fx.writeConfig(c.config)
            fx.setBattery(fx.battery(source: "Battery Power", percent: c.percent))
            try assertSessionKept(try fx.run(fx.backstop))
        }
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "the read is signaled as this shell's job, never by a pid handed to $KILL: \(fx.calls())")
        XCTAssertTrue(fx.hungReadIsGone(), "the hung read was stopped and reaped")
        let seen = try String(contentsOf: fx.root.appendingPathComponent("read.files"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(seen.count, 1, "\(seen)")
        // The battery read is the run's second: with no config.json, the
        // cutoffs the journal records for the session are read first.
        XCTAssertTrue(seen.allSatisfy { $0.hasSuffix(".2.out") }, "a read has its output file and no .pid or .rc status files: \(seen)")

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

    /// A read never holds the recovery lock: it starts with fd 9 closed, so
    /// it does not have it while the run holds the lock.
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
        XCTAssertFalse(fx.calls().contains { $0.hasSuffix("had fd 9") }, "the read must not inherit the lock: \(fx.calls())")
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
        XCTAssertFalse(fx.calls().contains { $0.hasPrefix("kill") }, "the read is signaled as this shell's job, never by a pid handed to $KILL: \(fx.calls())")
        XCTAssertTrue(fx.hungReadIsGone(), "the read that ignored SIGTERM was killed and reaped")
        XCTAssertTrue(fx.log().contains("thermal pressure level unreadable"), fx.log())
        XCTAssertTrue(try fx.lockIsFree(), "nothing the read started holds the lock")

        fx.clearCalls()
        fx.setThermal("3")
        try assertSessionEnded(try fx.run(fx.backstop), reason: "thermal pressure level 3")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fx.home.path).filter { $0.hasPrefix(".backstop.") }
        XCTAssertEqual(leftovers, [])
    }

    /// The first read of a run cleans up like the first undo command (see
    /// testStatusFilesGoWithTheirCallAndLeftoversOnlyUnderTheRunsOwnLock):
    /// a run that took the lock itself removes the status and output files
    /// earlier runs left, and a run that shares its caller's lock leaves
    /// them, since an earlier run under that lock may still have a
    /// supervisor waiting for its command. The read's own output file goes
    /// with its call either way.
    func testReadsRemoveLeftoversOnlyUnderTheRunsOwnLock() throws {
        let app = try fx.holdAliveLock()
        defer { app.release() }
        try writeLiveSession()
        let leftovers = [".backstop.4242.1.out", ".backstop.4242.1.pid", ".backstop.4242.1.rc"]
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

        try assertSessionKept(try fx.run(sharing))
        XCTAssertEqual(calls(), [batteryRead, thermalRead])
        XCTAssertEqual(try fx.backstopFiles(), leftovers)

        try assertSessionKept(try fx.run(fx.backstop))
        XCTAssertEqual(try fx.backstopFiles(), [])
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
        let restoreHome = pointInsomniaHome(at: fx.home)
        defer { restoreHome() }
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
        XCTAssertNil(try fx.stateJSON()["endedSession"], "ended-session.json holds the record; the journal needs none")
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

    /// session.json cannot be removed and ended-session.json holds an
    /// unrelated record that cannot be replaced. The end goes in the journal
    /// instead (endedSession, the file's bytes in base64), and every other
    /// key stays. Sleep is restored and its entry cleared: the record says
    /// the session is over. Later runs end it again without reading the
    /// battery or the heat, even with the app alive. The record stays once
    /// the file is gone; only the app removes it, and it matches nothing.
    func testEndThatCannotWriteTheEndRecordRecordsItInTheJournal() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"futureKey":{"kept":1}}"#)
        try setImmutable(fx.session, true)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)
        let marker = try Data(contentsOf: fx.session).base64EncodedString()

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored])
        let journal = try fx.stateJSON()
        XCTAssertEqual(journal["endedSession"] as? String, marker)
        XCTAssertEqual(journal["sleepDisabledByUs"] as? Bool, false)
        XCTAssertEqual((journal["futureKey"] as? [String: Any])?["kept"] as? Int, 1, "keys the agent does not own survive")
        XCTAssertNoThrow(try Store(paths: Paths(root: fx.home)).loadState(), "the app still reads the journal")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.endedSession, encoding: .utf8), "{}")
        XCTAssertTrue(fx.log().contains("its end is recorded in \(fx.state.path) (endedSession) instead"), fx.log())

        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 1, again.stderr + fx.log())
        XCTAssertEqual(calls(), [], "a session recorded as ended is not checked again")
        XCTAssertTrue(fx.log().contains("already ended (recorded in \(fx.state.path) (endedSession))"), fx.log())

        try setImmutable(fx.session, false)
        let last = try fx.run(fx.backstop)

        XCTAssertEqual(last.status, 0, last.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try fx.stateJSON()["endedSession"] as? String, marker)
    }

    /// The same with sleep that cannot be restored: the record is in the
    /// journal before the undo is tried, so it is there although the undo
    /// failed and sleepDisabledByUs stays for the retry.
    func testEndRecordGoesInTheJournalBeforeTheUndo() throws {
        try writeLiveSession()
        try setImmutable(fx.session, true)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)
        fx.setMode("sudo", "fail")

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        let journal = try fx.stateJSON()
        XCTAssertEqual(journal["endedSession"] as? String, try Data(contentsOf: fx.session).base64EncodedString())
        XCTAssertEqual(journal["sleepDisabledByUs"] as? Bool, true)
    }

    /// No journal on disk: the record is a journal of its own, which the app
    /// reads as clean.
    func testEndRecordWithNoJournalWritesOne() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try setImmutable(fx.session, true)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [], "nothing journaled means nothing to undo")
        let journal = try XCTUnwrap(try Store(paths: Paths(root: fx.home)).loadState())
        XCTAssertEqual(journal.endedSession, try Data(contentsOf: fx.session).base64EncodedString())
        XCTAssertFalse(journal.isDirty)
    }

    /// The records aside in the fixture's home: names of the record's shape.
    private func recordsAside() throws -> [String] {
        try fx.contents(of: fx.home).filter { Paths.isEndedSessionAsideName($0) }
    }

    /// Neither session.json, nor ended-session.json, nor the journal can be
    /// written, but the folder takes new files: the end is recorded in a
    /// new file beside them, ended-session.json.<8 letters or digits>, the
    /// file's exact bytes, mode 0600. Sleep is restored; the journal keeps
    /// sleepDisabledByUs because it cannot be written. Later runs end the
    /// session again without the checks, even with the app alive, and keep
    /// the record. Once the files can be changed, session.json and the
    /// record go.
    func testEndThatCanWriteOnlyANewFileRecordsItAside() throws {
        try writeLiveSession()
        try setImmutable(fx.session, true)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)
        try setImmutable(fx.state, true)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored])
        let names = try recordsAside()
        XCTAssertEqual(names.count, 1, "\(names)")
        let record = fx.home.appendingPathComponent(try XCTUnwrap(names.first))
        XCTAssertEqual(try Data(contentsOf: record), try Data(contentsOf: fx.session), "the record is the file's exact bytes")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "state.json cannot be written")
        XCTAssertNil(try fx.stateJSON()["endedSession"])
        XCTAssertEqual(try String(contentsOf: fx.endedSession, encoding: .utf8), "{}")
        XCTAssertTrue(fx.log().contains("could not remove \(fx.session.path) or record its end in \(fx.endedSession.path) or \(fx.state.path); its end is recorded in \(record.path) instead"), fx.log())

        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 1, again.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "no checks; the journal still asks for the restore")
        XCTAssertTrue(fx.log().contains("already ended (recorded in \(record.path))"), fx.log())
        XCTAssertEqual(try recordsAside(), names, "a record that matches is kept and used again")

        for file in [fx.session, fx.endedSession, fx.state] { try setImmutable(file, false) }
        let last = try fx.run(fx.backstop)

        XCTAssertEqual(last.status, 0, last.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try recordsAside(), [], "the record goes with the file it copies")
    }

    /// The same files, the record aside cannot be created either (the
    /// MKTEMP constant is /usr/bin/false here), and the recovery lock file
    /// takes no record (LOCK_RECORD_MAX_BYTES is 0 here, a stand-in for a
    /// write it refuses), nor does insomnia.log (LOG_RECORD_MAX_BYTES is 0):
    /// nothing on disk says the session is over. Sleep
    /// is restored anyway, but its journal entry stays as evidence and the
    /// run exits 1. (The app then resumes nothing either: it writes the
    /// journal before it resumes a session; JournaledSessionEndTests.)
    func testEndThatCanNeitherRemoveNorRecordKeepsTheSleepEntry() throws {
        try writeLiveSession()
        try setImmutable(fx.session, true)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)
        try setImmutable(fx.state, true)
        var text = try String(contentsOf: fx.backstop, encoding: .utf8)
        text = try ScriptFixture.replaceOnce(text, "MKTEMP=/usr/bin/mktemp", with: "MKTEMP=/usr/bin/false")
        text = try ScriptFixture.replaceOnce(text, "\nLOG_RECORD_MAX_BYTES=65536\n", with: "\nLOG_RECORD_MAX_BYTES=0\n")
        try ScriptFixture.replaceOnce(text, "\nLOCK_RECORD_MAX_BYTES=1048576\n", with: "\nLOCK_RECORD_MAX_BYTES=0\n")
            .write(to: fx.backstop, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, true, "evidence kept while the session still reads as valid")
        XCTAssertNil(try fx.stateJSON()["endedSession"])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.endedSession, encoding: .utf8), "{}")
        XCTAssertEqual(try recordsAside(), [])
        XCTAssertEqual(try Data(contentsOf: fx.lock), Data())
        let log = fx.log()
        XCTAssertTrue(log.contains("could not remove \(fx.session.path) or record its end in \(fx.endedSession.path), \(fx.state.path), a new file in \(fx.home.path) or \(logs.path), the recovery lock file \(fx.lock.path), or the log file \(fx.logFile.path)"), log)
        XCTAssertTrue(log.contains("still journaled: sleepDisabledByUs is kept although sleep is restored"), log)
    }

    /// The same files and no record aside, with a recovery lock file that
    /// takes the record: it then holds the tag and the file's bytes in
    /// base64, written in place, so its inode stays. Sleep is restored and
    /// the run exits 1 while session.json stays. Later runs end the session
    /// again without the checks, even with the app alive. Once the files
    /// can be changed, session.json goes and the lock file is emptied, the
    /// same inode still.
    func testEndThatCanWriteOnlyTheLockFileRecordsItThere() throws {
        try writeLiveSession()
        FileManager.default.createFile(atPath: fx.lock.path, contents: nil)
        let lockInode = try fx.inode(fx.lock)
        try setImmutable(fx.session, true)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)
        try setImmutable(fx.state, true)
        let text = try String(contentsOf: fx.backstop, encoding: .utf8)
        try ScriptFixture.replaceOnce(text, "MKTEMP=/usr/bin/mktemp", with: "MKTEMP=/usr/bin/false")
            .write(to: fx.backstop, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored])
        let record = "ended-session-v1 \(try Data(contentsOf: fx.session).base64EncodedString())\n"
        XCTAssertEqual(try String(contentsOf: fx.lock, encoding: .utf8), record)
        XCTAssertEqual(try fx.inode(fx.lock), lockInode)
        XCTAssertEqual(try recordsAside(), [])
        XCTAssertTrue(fx.log().contains("its end is recorded in the recovery lock file \(fx.lock.path) instead"), fx.log())

        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 1, again.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "no checks; the journal still asks for the restore")
        XCTAssertTrue(fx.log().contains("already ended (recorded in \(fx.lock.path))"), fx.log())
        XCTAssertEqual(try String(contentsOf: fx.lock, encoding: .utf8), record, "a record that matches is kept and used again")

        for file in [fx.session, fx.endedSession, fx.state] { try setImmutable(file, false) }
        let last = try fx.run(fx.backstop)

        XCTAssertEqual(last.status, 0, last.stderr + fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try Data(contentsOf: fx.lock), Data(), "the record goes with the file it copies")
        XCTAssertEqual(try fx.inode(fx.lock), lockInode)
    }

    private var logs: URL { fx.home.appendingPathComponent("Logs", isDirectory: true) }

    /// The records aside in the log folder.
    private func recordsInTheLogFolder() throws -> [String] {
        try fx.contents(of: logs).filter { Paths.isEndedSessionAsideName($0) }
    }

    /// A folder that takes no new file (mode 0555; the lock file and the
    /// log folder already exist): session.json cannot be removed and no
    /// record can be written beside it. The record goes in the log folder,
    /// the file's exact bytes, mode 0600. The restore still runs, but its
    /// supervisor cannot write the status files either, so the run cannot
    /// tell whether the command finished: it reports no result, keeps the
    /// journal as it was and exits 1. Once the folder takes files again, a
    /// run with the app alive ends the session without the checks, and
    /// session.json and the record go.
    func testEndInAFolderThatTakesNoNewFileRecordsItInTheLogFolder() throws {
        try writeLiveSession()
        FileManager.default.createFile(atPath: fx.lock.path, contents: nil)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let journal = try Data(contentsOf: fx.state)
        fx.clearCalls()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fx.home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.home.path) }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "the restore runs")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.endedSession))
        XCTAssertEqual(try recordsAside(), [])
        let names = try recordsInTheLogFolder()
        XCTAssertEqual(names.count, 1, "\(names)")
        let record = logs.appendingPathComponent(try XCTUnwrap(names.first))
        XCTAssertEqual(try Data(contentsOf: record), try Data(contentsOf: fx.session), "the record is the file's exact bytes")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: record.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try Data(contentsOf: fx.state), journal, "the journal is kept as it was")
        XCTAssertEqual(try Data(contentsOf: fx.lock), Data(), "the lock file is only the last place")
        let log = fx.log()
        XCTAssertTrue(log.contains("its end is recorded in \(record.path) instead"), log)
        XCTAssertTrue(log.contains("its supervisor reported no result within"), log)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.home.path)
        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "no checks; the journal still asks for the restore")
        XCTAssertTrue(fx.log().contains("already ended (recorded in \(record.path))"), fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try recordsInTheLogFolder(), [], "the record goes with the file it copies")
    }

    /// The same with the log folder refusing new files too (both mode
    /// 0555): no new file can be written anywhere. The record goes in the
    /// recovery lock file, which exists already, in place, before the
    /// restore. The restore still runs, the run reports no result, keeps
    /// the journal as it was and exits 1. Once both folders take files
    /// again, a run with the app alive ends the session without the
    /// checks, and session.json goes and the lock file is emptied, its
    /// inode the same throughout.
    func testEndWhereNeitherFolderTakesANewFileRecordsItInTheLockFile() throws {
        try writeLiveSession()
        FileManager.default.createFile(atPath: fx.lock.path, contents: nil)
        let lockInode = try fx.inode(fx.lock)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fx.logFile.path, contents: nil)
        let journal = try Data(contentsOf: fx.state)
        fx.clearCalls()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logs.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fx.home.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.home.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path)
        }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "the restore runs")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.endedSession))
        XCTAssertEqual(try recordsAside(), [])
        XCTAssertEqual(try recordsInTheLogFolder(), [])
        XCTAssertEqual(try String(contentsOf: fx.lock, encoding: .utf8), "ended-session-v1 \(try Data(contentsOf: fx.session).base64EncodedString())\n")
        XCTAssertEqual(try fx.inode(fx.lock), lockInode)
        XCTAssertEqual(try Data(contentsOf: fx.state), journal, "the journal is kept as it was")
        let log = fx.log()
        XCTAssertTrue(log.contains("or a new file in \(fx.home.path) or \(logs.path); its end is recorded in the recovery lock file \(fx.lock.path) instead"), log)
        XCTAssertTrue(log.contains("its supervisor reported no result within"), log)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.home.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path)
        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.clearCalls()
        let again = try fx.run(fx.backstop)

        XCTAssertEqual(again.status, 0, again.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "no checks; the journal still asks for the restore")
        XCTAssertTrue(fx.log().contains("already ended (recorded in \(fx.lock.path))"), fx.log())
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertEqual(try Data(contentsOf: fx.lock), Data())
        XCTAssertEqual(try fx.inode(fx.lock), lockInode)
    }

    /// The same, and neither the lock file nor insomnia.log takes a
    /// record (LOCK_RECORD_MAX_BYTES and LOG_RECORD_MAX_BYTES are 0 here,
    /// stand-ins for a write each refuses): no record can be written
    /// anywhere. The restore still
    /// runs, the run reports no result, keeps the journal as it was and
    /// exits 1. This is the case no record covers (the app then resumes
    /// nothing while session.json cannot be replaced;
    /// JournaledSessionEndTests).
    func testEndWhereNeitherFolderNorTheLockFileTakesTheRecordRecordsNothing() throws {
        try writeLiveSession()
        FileManager.default.createFile(atPath: fx.lock.path, contents: nil)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fx.logFile.path, contents: nil)
        let text = try ScriptFixture.replaceOnce(try String(contentsOf: fx.backstop, encoding: .utf8), "\nLOG_RECORD_MAX_BYTES=65536\n", with: "\nLOG_RECORD_MAX_BYTES=0\n")
        try ScriptFixture.replaceOnce(text, "\nLOCK_RECORD_MAX_BYTES=1048576\n", with: "\nLOCK_RECORD_MAX_BYTES=0\n")
            .write(to: fx.backstop, atomically: true, encoding: .utf8)
        let journal = try Data(contentsOf: fx.state)
        fx.clearCalls()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: logs.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fx.home.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.home.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path)
        }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "the restore runs")
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.endedSession))
        XCTAssertEqual(try recordsAside(), [])
        XCTAssertEqual(try recordsInTheLogFolder(), [])
        XCTAssertEqual(try Data(contentsOf: fx.lock), Data())
        XCTAssertEqual(try Data(contentsOf: fx.state), journal, "the journal is kept as it was")
        let log = fx.log()
        XCTAssertTrue(log.contains("a new file in \(fx.home.path) or \(logs.path), the recovery lock file \(fx.lock.path), or the log file \(fx.logFile.path). Sleep is restored anyway"), log)
        XCTAssertTrue(log.contains("its supervisor reported no result within"), log)
    }

    /// In the log folder as beside session.json: a record that matches no
    /// session.json goes, and the live session is checked as usual. One
    /// that cmp cannot read stays and ends nothing. A symlink, a FIFO and
    /// other names are never opened or removed.
    func testStaleRecordInTheLogFolderIsRemovedAndOthersAreLeft() throws {
        try writeLiveSession()
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stale = logs.appendingPathComponent("ended-session.json.Stale001")
        try #"{"endsAt":"2001-01-01T00:00:00Z","startedAt":"2001-01-01T00:00:00Z"}"#.write(to: stale, atomically: true, encoding: .utf8)
        let unreadable = logs.appendingPathComponent("ended-session.json.NoRead00")
        try FileManager.default.copyItem(at: fx.session, to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let copy = fx.root.appendingPathComponent("copy-of-session")
        try FileManager.default.copyItem(at: fx.session, to: copy)
        let link = logs.appendingPathComponent("ended-session.json.Link0000")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: copy)
        let other = logs.appendingPathComponent("ended-session.json.Other0000")
        try FileManager.default.copyItem(at: fx.session, to: other)
        let fifo = try FIFOWatch(at: logs.appendingPathComponent("ended-session.json.Fifo0000"))
        defer { fifo.stop() }
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertEqual(calls(), [batteryRead, thermalRead])
        XCTAssertFalse(fifo.readerSeen, "a FIFO named like a record was opened")
        XCTAssertFalse(fx.exists(stale))
        for kept in [unreadable, link, other, fifo.url] {
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: kept.path), kept.lastPathComponent)
        }
    }

    /// A log folder that is a symlink is not searched: a matching record
    /// in the folder it points to ends nothing and stays. Nor is a record
    /// written through it when the folder beside session.json takes no new
    /// file: the record goes in the recovery lock file, as when both
    /// folders refuse.
    func testALogFolderThatIsASymlinkIsNeitherSearchedNorWrittenThrough() throws {
        try writeLiveSession()
        let elsewhere = fx.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        if fx.exists(logs) {
            for name in try fx.contents(of: logs) {
                try FileManager.default.moveItem(at: logs.appendingPathComponent(name), to: elsewhere.appendingPathComponent(name))
            }
            try FileManager.default.removeItem(at: logs)
        }
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: elsewhere)
        let matching = elsewhere.appendingPathComponent("ended-session.json.Elsewher")
        try FileManager.default.copyItem(at: fx.session, to: matching)
        do {
            let app = try fx.holdAliveLock()
            defer { app.release() }
            try assertSessionKept(try fx.run(fx.backstop))
            XCTAssertEqual(calls(), [batteryRead, thermalRead], "checked as usual")
            XCTAssertTrue(fx.exists(matching))
        }

        try FileManager.default.removeItem(at: matching)
        FileManager.default.createFile(atPath: fx.lock.path, contents: nil)
        fx.clearCalls()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fx.home.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.home.path) }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try fx.contents(of: elsewhere).filter { Paths.isEndedSessionAsideName($0) }, [], "no record through the symlink")
        XCTAssertTrue(fx.log().contains("or a new file in \(fx.home.path) or \(logs.path); its end is recorded in the recovery lock file \(fx.lock.path) instead"), fx.log())
        XCTAssertEqual(try String(contentsOf: fx.lock, encoding: .utf8), "ended-session-v1 \(try Data(contentsOf: fx.session).base64EncodedString())\n")
    }

    /// A record aside that matches no session.json goes, as a stale
    /// ended-session.json does, and the live session is checked as usual.
    /// One that cmp cannot read is not shown to be stale and stays; it ends
    /// nothing. A symlink, a FIFO and other names are never opened or
    /// removed.
    func testStaleRecordAsideIsRemovedAndOthersAreLeft() throws {
        try writeLiveSession()
        let stale = fx.home.appendingPathComponent("ended-session.json.Stale001")
        try #"{"endsAt":"2001-01-01T00:00:00Z","startedAt":"2001-01-01T00:00:00Z"}"#.write(to: stale, atomically: true, encoding: .utf8)
        let unreadable = fx.home.appendingPathComponent("ended-session.json.NoRead00")
        try FileManager.default.copyItem(at: fx.session, to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let copy = fx.root.appendingPathComponent("copy-of-session")
        try FileManager.default.copyItem(at: fx.session, to: copy)
        let link = fx.home.appendingPathComponent("ended-session.json.Link0000")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: copy)
        let other = fx.home.appendingPathComponent("ended-session.json.Other0000")
        try FileManager.default.copyItem(at: fx.session, to: other)
        let fifo = try FIFOWatch(at: fx.home.appendingPathComponent("ended-session.json.Fifo0000"))
        defer { fifo.stop() }
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertEqual(calls(), [batteryRead, thermalRead])
        XCTAssertFalse(fifo.readerSeen, "a FIFO named like a record was opened")
        XCTAssertFalse(fx.exists(stale))
        for kept in [unreadable, link, other, fifo.url] {
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: kept.path), kept.lastPathComponent)
        }
    }

    /// A journaled end of another session.json (other bytes) ends nothing:
    /// the live session is checked as usual and kept, and the record stays.
    func testJournalRecordOfAnotherSessionDoesNotEndTheSession() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        let other = Data(#"{"endsAt":"2001-01-01T00:00:00Z","startedAt":"2001-01-01T00:00:00Z"}"#.utf8).base64EncodedString()
        let journal = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"endedSession":"\#(other)"}"#
        try fx.writeState(journal)
        let app = try fx.holdAliveLock()
        defer { app.release() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(calls(), [batteryRead, thermalRead])
        XCTAssertTrue(fx.exists(fx.session), "the session must stand")
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), journal, "journal must not be rewritten")
    }

    /// endedSession is a string or absent, as the app decodes it. Any other
    /// type makes the journal malformed for the agent and the app alike.
    func testJournalWithAnEndRecordThatIsNotAStringIsMalformed() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        let broken = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"endedSession":42}"#
        try fx.writeState(broken)

        let r = try fx.run(fx.backstop)

        XCTAssertNotEqual(r.status, 0)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), broken)
        XCTAssertTrue(fx.log().contains("endedSession is a integer, not a string"), fx.log())
        XCTAssertThrowsError(try Store(paths: Paths(root: fx.home)).loadState())
    }

    /// sessionCutoffs is a record the app writes as "30 false". A value it
    /// does not write, of any type, leaves the journal usable for the agent
    /// and both uninstall modes, as for the app, which reads it as none:
    /// the undo runs, and the value stays as it is. Each run has a fixture
    /// of its own, and they go several at a time.
    func testJournalWithSessionCutoffsTheAppDoesNotWriteIsStillUsable() async throws {
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        var rows: [(value: String, purge: Bool?, f: ScriptFixture)] = []
        for value in [#""96 false""#, "30", "true", #"["30 false"]"#, #"{"endFloor":30}"#, "null", #""30 false""#] {
            for purge in [nil, false, true] {
                let f = try ScriptFixture.concurrentRow()
                fixtures.append(f)
                if purge != nil {
                    try f.installMachinery()
                }
                try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
                let journal = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false,"sessionCutoffs":\#(value)}"#
                try f.writeState(journal)
                XCTAssertEqual(try Store(paths: Paths(root: f.home)).loadState()?.sleepDisabledByUs, true, value)
                rows.append((value, purge, f))
            }
        }

        let results = try await ScriptFixture.runAll(rows.map { row in
            row.purge.map { row.f.launch(row.f.uninstall, $0 ? ["--purge"] : []) } ?? row.f.launch(row.f.backstop)
        })

        for (row, r) in zip(rows, results) {
            let (value, purge, f) = (row.value, row.purge, row.f)
            let label = "\(value), \(purge.map { $0 ? "uninstall --purge" : "uninstall" } ?? "agent")"
            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr) \(r.stdout) \(f.log())")
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), "\(label): \(f.calls())")
            XCTAssertFalse(f.log().contains("sessionCutoffs is a"), "\(label): \(f.log())")
            if purge == nil {
                let after = try String(contentsOf: f.state, encoding: .utf8)
                XCTAssertTrue(after.contains(#""sessionCutoffs":\#(value)"#) || after.contains(#""sessionCutoffs" : \#(value)"#), "\(label): kept as it is: \(after)")
                XCTAssertFalse(f.exists(f.session), label)
            }
        }
    }

    /// Greptile 4219151895, uninstall.sh's side (PathSubstitutionTests has
    /// the agent's): an uninstall that undoes a journaled sleep hold through
    /// the checkout's backstop.sh, run on twin fixtures with the usual PATH
    /// (the control) and with PathSubstitutes first in PATH, prints the
    /// same, makes the same calls and removes the same files, and neither
    /// script calls a stand-in. Its readers (session.json and the journal's
    /// shape, the App Nap list, its uid and the app's folder names) would
    /// read otherwise from a stand-in.
    func testUninstallAndItsBackstopTakeNoToolFromPath() throws {
        let twin = try ScriptFixture()
        defer { twin.destroy() }
        for f in [fx!, twin] {
            try f.installMachinery()
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        }
        let log = twin.root.appendingPathComponent("substitutes.log")
        let path = try PathSubstitutes.path(in: twin.root.appendingPathComponent("substitutes", isDirectory: true), log: log,
                                            scripts: [twin.repoScripts.path + "/", twin.app.path + "/"])

        let control = try fx.run(fx.uninstall)
        let r = try twin.run(twin.uninstall, extraEnvironment: ["PATH": path])

        XCTAssertEqual(PathSubstitutes.calls(in: log), [], "uninstall.sh or its backstop.sh called a tool from PATH")
        XCTAssertEqual(control.status, 0, control.stderr + control.stdout)
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        let same = { (text: String, f: ScriptFixture) in text.replacingOccurrences(of: f.root.path, with: "<root>") }
        XCTAssertEqual(same(r.stdout, twin), same(control.stdout, fx))
        XCTAssertEqual(same(r.stderr, twin), same(control.stderr, fx))
        XCTAssertEqual(twin.calls().map { same($0, twin) }, fx.calls().map { same($0, fx) })
        XCTAssertTrue(fx.calls().contains("sudo -n \(fx.fakePmset) -a disablesleep 0"), fx.calls().joined(separator: "\n"))
        for f in [fx!, twin] {
            XCTAssertFalse(f.exists(f.session))
            XCTAssertFalse(f.exists(f.app))
        }
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

    /// An exact record beside a session.json that cannot be read (mode 0,
    /// immutable, so it cannot be moved aside either) is not shown to be
    /// stale: cmp cannot compare them (exit 2), so it stays, on every
    /// retry. Once session.json can be read again it ends that session:
    /// the next run, with the app alive, ends it without the checks and
    /// removes both. A record beside a session.json that is not a regular
    /// file stays too; one beside no session.json goes.
    func testAnExactEndRecordStaysWhileSessionJSONCannotBeCompared() throws {
        try writeLiveSession()
        try FileManager.default.copyItem(at: fx.session, to: fx.endedSession)
        let bytes = try Data(contentsOf: fx.session)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fx.session.path)
        try setImmutable(fx.session, true)
        defer {
            try? setImmutable(fx.session, false)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fx.session.path)
        }
        let app = try fx.holdAliveLock()
        defer { app.release() }

        let r = try fx.run(fx.backstop)
        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertEqual(try Data(contentsOf: fx.endedSession), bytes, "kept while it cannot be compared")
        let retry = try fx.run(fx.backstop)
        XCTAssertEqual(retry.status, 1, retry.stderr + fx.log())
        XCTAssertEqual(try Data(contentsOf: fx.endedSession), bytes, "kept on the retry too")

        try setImmutable(fx.session, false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fx.session.path)
        try fx.writeState(liveJournal)
        fx.clearCalls()
        let repaired = try fx.run(fx.backstop)
        XCTAssertEqual(repaired.status, 0, repaired.stderr + fx.log())
        XCTAssertTrue(fx.log().contains("already ended (recorded in \(fx.endedSession.path))"), fx.log())
        XCTAssertEqual(calls(), [sleepRestored], "no checks for a session recorded as ended")
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.endedSession))

        try FileManager.default.createDirectory(at: fx.session, withIntermediateDirectories: false)
        try bytes.write(to: fx.endedSession)
        _ = try fx.run(fx.backstop)
        XCTAssertEqual(try Data(contentsOf: fx.endedSession), bytes, "not shown to be stale beside a session.json that is not a file")
        // That run moved the directory aside, as any session.json it cannot
        // read; nothing is at session.json now.
        try? FileManager.default.removeItem(at: fx.session)
        _ = try fx.run(fx.backstop)
        XCTAssertFalse(fx.exists(fx.endedSession), "stale once session.json is gone")
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

    /// A FIFO at ended-session.json is never opened: cmp would block on it
    /// while the run holds the recovery lock, and then neither this script
    /// nor the app could ever end the session. It is not a record, so it
    /// matches nothing and goes, and the session is judged as usual: with no
    /// app alive it ends and sleep is restored.
    func testEndRecordThatIsAFIFOIsNeverOpenedAndTheSessionStillEnds() throws {
        try writeLiveSession()
        let fifo = try FIFOWatch(at: fx.endedSession)
        defer { fifo.stop() }

        let r = try fx.run(fx.backstop)

        XCTAssertFalse(fifo.readerSeen, "ended-session.json was opened although it is a FIFO")
        try assertSessionEnded(r, reason: "Insomnia is not running")
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertFalse(fx.exists(fx.session))
        XCTAssertFalse(fx.exists(fx.endedSession))
    }

    /// The same FIFO with the app alive: the session stands, the reads run,
    /// and the FIFO goes without being opened.
    func testEndRecordThatIsAFIFODoesNotEndALiveAppsSession() throws {
        try writeLiveSession()
        let fifo = try FIFOWatch(at: fx.endedSession)
        defer { fifo.stop() }
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertFalse(fifo.readerSeen, "ended-session.json was opened although it is a FIFO")
        XCTAssertEqual(calls(), [batteryRead, thermalRead])
        XCTAssertFalse(fx.exists(fx.endedSession))
    }

    /// A FIFO there that cannot be removed either, with session.json that
    /// cannot be removed: recording the end compares and replaces, and
    /// neither opens the FIFO. Sleep is restored and the run exits 1.
    func testEndRecordFIFOThatCannotBeReplacedIsNeverOpenedWhenRecordingTheEnd() throws {
        try writeLiveSession()
        try setImmutable(fx.session, true)
        let fifo = try FIFOWatch(at: fx.endedSession)
        defer { fifo.stop() }
        try setImmutable(fx.endedSession, true)
        defer { try? setImmutable(fx.endedSession, false) }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 1, r.stderr + fx.log())
        XCTAssertFalse(fifo.readerSeen, "ended-session.json was opened although it is a FIFO")
        XCTAssertTrue(fifo.isStillFIFO)
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertTrue(fx.log().contains("could not remove \(fx.session.path) or record its end"), fx.log())
    }

    /// config.json is read only as a regular file, like session.json and
    /// state.json. A FIFO there reads as a missing file: the defaults apply
    /// (10% floor, thermal rules on), so both reads run and the session
    /// stands. plutil on macOS 26 refuses a FIFO by itself, so this pins
    /// the outcome; the regular-file check does not rely on that.
    func testConfigThatIsAFIFOIsNeverOpenedAndTheDefaultsApply() throws {
        try writeLiveSession()
        let fifo = try FIFOWatch(at: fx.config)
        defer { fifo.stop() }
        let app = try fx.holdAliveLock()
        defer { app.release() }

        try assertSessionKept(try fx.run(fx.backstop))

        XCTAssertFalse(fifo.readerSeen, "config.json was opened although it is a FIFO")
        XCTAssertTrue(fifo.isStillFIFO)
        XCTAssertEqual(calls(), [batteryRead, thermalRead])
    }

    /// A config.json this user cannot read gives the app no settings
    /// either (it moves the file aside), so the defaults apply, 10% and
    /// thermal rules on, whatever the file holds.
    func testConfigThatCannotBeReadGivesTheDefaults() throws {
        try writeLiveSession()
        try fx.writeConfig(#"{"endFloor": 0, "thermalRules": false}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fx.config.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fx.config.path) }
        let app = try fx.holdAliveLock()
        defer { app.release() }
        fx.setBattery(fx.battery(source: "Battery Power", percent: 9))

        try assertSessionEnded(try fx.run(fx.backstop), reason: "battery at 9% on battery power, below the 10% end floor")
        XCTAssertFalse(fx.log().contains("enforcing the strictest"), fx.log())
    }

    /// The log is appended to only as a regular file. Most lines are written
    /// under the recovery lock, and open(2) for writing on a FIFO with no
    /// reader blocks. The test holds a read end open, so a write lands in
    /// the FIFO's buffer instead of hanging the run, and the buffer must
    /// stay empty. The lines are dropped; the session still ends.
    func testLogThatIsAFIFOIsNeverWrittenAndTheSessionStillEnds() throws {
        try writeLiveSession()
        try FileManager.default.createDirectory(at: fx.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fx.logFile.path, 0o600), 0)
        let reader = open(fx.logFile.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { close(reader) }

        let r = try fx.run(fx.backstop)

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(reader, &buffer, buffer.count)
        XCTAssertLessThanOrEqual(n, 0, "the log FIFO was written: \(String(decoding: buffer.prefix(max(n, 0)), as: UTF8.self))")
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(calls(), [sleepRestored])
        XCTAssertEqual(try fx.stateJSON()["sleepDisabledByUs"] as? Bool, false)
        XCTAssertFalse(fx.exists(fx.session))
        var info = stat()
        XCTAssertTrue(lstat(fx.logFile.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO)
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

        let restoreHome = pointInsomniaHome(at: fx.home)
        defer { restoreHome() }
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

    /// Frozen entries the app decodes without an identity, because a
    /// startedAt or startedAtMicros is missing or null (FrozenProcess),
    /// with what follows of the wrong type or past Int32: the app loads the
    /// journal, so the run restores sleep, signals nothing and keeps each
    /// entry for the app. The same values in an entry with every identity
    /// key are read by the app and refused, so that journal stops the run
    /// before any command, its bytes and session.json kept.
    func testProvisionalEntriesTheAppDoesNotReadFurtherDoNotBlockRecovery() throws {
        let rows: [(entry: String, loads: Bool)] = [
            (#"{"pid":4242,"startedAtMicros":"bad","bootSession":"test"}"#, true),
            (#"{"pid":4242,"startedAt":123,"bootSession":42}"#, true),
            (#"{"pid":4242,"startedAtMicros":2147483648}"#, true),
            (#"{"pid":4242,"startedAt":null,"startedAtMicros":"bad","bootSession":42}"#, true),
            (#"{"pid":4242,"startedAt":123,"startedAtMicros":0,"bootSession":42}"#, false),
            (#"{"pid":4242,"startedAt":123,"startedAtMicros":2147483648,"bootSession":"test"}"#, false),
        ]
        for row in rows {
            let f = try ScriptFixture()
            defer { f.destroy() }
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            let journal = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"dockerFrozen":false,"frozenProcesses":["# + row.entry + "]}"
            try f.writeState(journal)
            let session = try Data(contentsOf: f.session)

            let r = try f.run(f.backstop)

            let calls = f.calls().map { $0.replacingOccurrences(of: f.fakePmset, with: "PMSET") }
            XCTAssertNotEqual(r.status, 0, row.entry)
            XCTAssertFalse(calls.contains { $0.hasPrefix("kill") || $0.contains("-CONT") }, "\(row.entry): \(calls)")
            if row.loads {
                XCTAssertEqual(calls, [sleepRestored], row.entry)
                XCTAssertTrue(f.log().contains("pid 4242 was journaled without identity; not signaled, kept for the app to resolve"), "\(row.entry): \(f.log())")
                XCTAssertFalse(f.log().contains("malformed"), "\(row.entry): \(f.log())")
                XCTAssertEqual((try f.stateJSON()["frozenProcesses"] as? [Any])?.count, 1, row.entry)
                XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, false, row.entry)
            } else {
                XCTAssertEqual(calls, [], row.entry)
                XCTAssertTrue(f.log().contains("malformed"), "\(row.entry): \(f.log())")
                XCTAssertEqual(try String(contentsOf: f.state, encoding: .utf8), journal, row.entry)
                XCTAssertEqual(try Data(contentsOf: f.session), session, row.entry)
            }
        }
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
    /// is a session: a future one, with the app holding the alive lock,
    /// keeps sleep disabled, and only the battery and thermal reads run.
    func testCompleteSessionWithAFutureEndsAtIsValid() throws {
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
        try fx.writeState(#"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        let app = try fx.holdAliveLock()
        defer { app.release() }

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr + fx.log())
        XCTAssertEqual(calls(), [batteryRead, thermalRead], "reads only, nothing privileged")
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
            for name in ["extract", "epoch_of", "epoch_at"] {
                let start = try XCTUnwrap(text.range(of: "\n\(name)() {"), "\(name) in \(script.lastPathComponent)")
                let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
                functions += text[start.lowerBound..<end.upperBound]
            }
            let harness = fx.root.appendingPathComponent("epoch_at.\(script.lastPathComponent)")
            try ("set -euo pipefail\nPLUTIL=/usr/bin/plutil\nDATE=/bin/date" + functions
                + #"for f in "$@"; do printf '[%s]\n' "$(epoch_at "$f" endsAt)"; done"# + "\n")
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
    /// future one with the app running keeps sleep disabled, and only the
    /// battery and thermal reads run. A past one is undone like any expired
    /// session.
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
        let app = try fx.holdAliveLock()
        let future = try fx.run(fx.backstop)
        app.release()

        XCTAssertEqual(future.status, 0, future.stderr + fx.log())
        XCTAssertEqual(calls(), [batteryRead, thermalRead])
        XCTAssertTrue(fx.exists(fx.session))
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), dirty)

        fx.clearCalls()
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

    /// Records aside (ended-session.json.<8 letters or digits>) go with or
    /// without --purge. The backstop run removes a stale one first; one it
    /// cannot remove (immutable here) is named and counted by uninstall,
    /// a directory of that name is left and named, other names stay.
    func testUninstallRemovesRecordsAsideAndNamesWhatItCannot() throws {
        for purge in [false, true] {
            try fx.installMachinery()
            let removable = fx.home.appendingPathComponent("ended-session.json.Abcd1234")
            let pinned = fx.home.appendingPathComponent("ended-session.json.Pinned00")
            let dir = fx.home.appendingPathComponent("ended-session.json.Dir00000")
            let notOurs = fx.home.appendingPathComponent("ended-session.json.notes")
            for file in [removable, pinned, notOurs] {
                try "{}".write(to: file, atomically: true, encoding: .utf8)
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try setImmutable(pinned, true)
            defer { try? setImmutable(pinned, false) }

            let r = try fx.run(fx.uninstall, purge ? ["--purge"] : [])

            XCTAssertEqual(r.status, 1, "purge \(purge): " + r.stderr + r.stdout)
            XCTAssertFalse(fx.exists(removable), "purge \(purge)")
            XCTAssertTrue(fx.exists(pinned))
            XCTAssertTrue(r.stderr.contains("Could not remove \(pinned.path); left in place."), r.stderr)
            XCTAssertTrue(r.stdout.contains("Left \(dir.path): it is not a regular file, so Insomnia did not write it."), r.stdout)
            XCTAssertTrue(fx.exists(dir))
            XCTAssertTrue(fx.exists(notOurs))
            try setImmutable(pinned, false)
            try FileManager.default.removeItem(at: pinned)
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.removeItem(at: notOurs)
        }
    }

    /// The record of a session's end in the recovery lock file goes with or
    /// without --purge, emptied in place: the file and its inode stay. The
    /// fixture's backstop is changed here to leave it, so what empties it
    /// is uninstall's own copy of the rule. A symlink at the lock path
    /// before uninstall starts stops it before it removes anything, as on
    /// main: the backstop cannot show that the link is the lock uninstall
    /// holds, so it waits on that lock and gives up (exit 75). One put there
    /// during the run is named and left. Neither writes the file a symlink
    /// points to.
    func testUninstallEmptiesTheLockFileRecordInPlaceInBothModes() throws {
        let text = try String(contentsOf: fx.backstop, encoding: .utf8)
        let clear = #"  if lock_is_held_file && { : > "$LOCK"; } 2>/dev/null; then return 0; fi"#
        try ScriptFixture.replaceOnce(text, clear, with: "  return 0")
            .write(to: fx.backstop, atomically: true, encoding: .utf8)
        let record = Data("ended-session-v1 QUJD\n".utf8)
        for purge in [false, true] {
            try fx.installMachinery()
            FileManager.default.createFile(atPath: fx.lock.path, contents: record)
            let lockInode = try fx.inode(fx.lock)

            let r = try fx.run(fx.uninstall, purge ? ["--purge"] : [])

            XCTAssertEqual(r.status, 0, "purge \(purge): " + r.stderr + r.stdout)
            XCTAssertEqual(try Data(contentsOf: fx.lock), Data(), "purge \(purge)")
            XCTAssertEqual(try fx.inode(fx.lock), lockInode, "purge \(purge)")
            XCTAssertTrue(r.stdout.contains("Emptied \(fx.lock.path) of the record of a session's end; the file itself is kept."), r.stdout)
        }

        try fx.installMachinery()
        let target = fx.root.appendingPathComponent("elsewhere.lock")
        try record.write(to: target)
        try FileManager.default.removeItem(at: fx.lock)
        try FileManager.default.createSymbolicLink(at: fx.lock, withDestinationURL: target)
        var r = try fx.run(fx.uninstall)
        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Uninstall stopped BEFORE removing anything"), r.stderr)
        XCTAssertTrue(r.stderr.contains("backstop exited 75"), r.stderr)
        XCTAssertTrue((try? String(contentsOf: fx.logFile, encoding: .utf8))?.contains("recovery lock \(fx.lock.path) still held") == true)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fx.lock.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), record)

        // That uninstall removed nothing, so the machinery is still there.
        try FileManager.default.removeItem(at: fx.lock)
        FileManager.default.createFile(atPath: fx.lock.path, contents: record)
        let moved = fx.root.appendingPathComponent("moved.lock")
        try ScriptFixture.replaceOnce(text, clear, with: "  /bin/mv \"$LOCK\" '\(moved.path)' && /bin/ln -s '\(target.path)' \"$LOCK\"; return 0")
            .write(to: fx.backstop, atomically: true, encoding: .utf8)
        r = try fx.run(fx.uninstall)
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertTrue(r.stdout.contains("Left the contents of \(fx.lock.path): it is not a regular file this user owns."), r.stdout)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fx.lock.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), record)
        XCTAssertEqual(try Data(contentsOf: moved), record)
    }

    /// Records in the log folder go with or without --purge, as those
    /// beside session.json do: one uninstall cannot remove (immutable) is
    /// named by uninstall itself, and other names stay. With only a record
    /// in it, --purge then removes the log folder.
    func testUninstallRemovesRecordsInTheLogFolderInBothModes() throws {
        for purge in [false, true] {
            try fx.installMachinery()
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let removable = logs.appendingPathComponent("ended-session.json.Abcd1234")
            let pinned = logs.appendingPathComponent("ended-session.json.Pinned00")
            let notOurs = logs.appendingPathComponent("ended-session.json.notes")
            for file in [removable, pinned, notOurs] {
                try "{}".write(to: file, atomically: true, encoding: .utf8)
            }
            try setImmutable(pinned, true)
            defer { try? setImmutable(pinned, false) }

            let r = try fx.run(fx.uninstall, purge ? ["--purge"] : [])

            XCTAssertEqual(r.status, 1, "purge \(purge): " + r.stderr + r.stdout)
            XCTAssertFalse(fx.exists(removable), "purge \(purge)")
            XCTAssertTrue(fx.exists(pinned))
            XCTAssertTrue(r.stderr.contains("Could not remove \(pinned.path); left in place."), r.stderr)
            XCTAssertTrue(fx.exists(notOurs))
            try setImmutable(pinned, false)
            try FileManager.default.removeItem(at: pinned)
            try FileManager.default.removeItem(at: notOurs)
        }

        try fx.installMachinery()
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let only = logs.appendingPathComponent("ended-session.json.Only0000")
        try "{}".write(to: only, atomically: true, encoding: .utf8)
        let r = try fx.run(fx.uninstall, ["--purge"])
        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        XCTAssertFalse(fx.exists(only))
        XCTAssertFalse(fx.exists(logs), "--purge removes the log folder once the record is gone")
    }

    /// --purge keeps insomnia.log and insomnia.log.1 while session.json is
    /// still there, as they may record its end (record_end_in_log in
    /// backstop.sh); it removes them once session.json is gone. Purge runs
    /// only with no session.json (journal_problems), so this copy of
    /// uninstall.sh puts a pinned one back once purge starts: the guard is
    /// defensive, and this is the only way to reach it.
    func testUninstallPurgeKeepsTheLogsWhileSessionJSONIsThere() throws {
        try fx.installMachinery()
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let rotated = logs.appendingPathComponent("insomnia.log.1")
        for file in [fx.logFile, rotated] {
            try "insomnia-ended-session-v1 2 e30=\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let step = "  step \"Purging Insomnia's files in $APP_SUPPORT and $LOG_DIR\"\n"
        var text = try String(contentsOf: fx.uninstall, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: step).count, 2)
        text = text.replacingOccurrences(of: step, with: step + "  printf '{}' > \"$SESSION\"; /usr/bin/chflags uchg \"$SESSION\"\n")
        try text.write(to: fx.uninstall, atomically: true, encoding: .utf8)
        defer { try? setImmutable(fx.session, false) }

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(r.stderr.contains("Could not remove \(fx.session.path); left in place."), r.stderr)
        XCTAssertTrue(r.stdout.contains("Kept \(logs.path)/insomnia.log and \(logs.path)/insomnia.log.1: \(fx.session.path) is still there, and they may record its end."), r.stdout)
        XCTAssertTrue(fx.exists(fx.logFile))
        XCTAssertTrue(fx.exists(rotated))

        try setImmutable(fx.session, false)
        try FileManager.default.removeItem(at: fx.session)
        text = text.replacingOccurrences(of: "  printf '{}' > \"$SESSION\"; /usr/bin/chflags uchg \"$SESSION\"\n", with: "")
        try text.write(to: fx.uninstall, atomically: true, encoding: .utf8)
        try fx.installMachinery()
        let again = try fx.run(fx.uninstall, ["--purge"])
        XCTAssertEqual(again.status, 0, again.stderr + again.stdout)
        XCTAssertFalse(fx.exists(fx.logFile))
        XCTAssertFalse(fx.exists(rotated))
    }

    /// The backstop run uninstall makes (--force), in both modes, with a
    /// log that ends in a line cut short. session.json, ended-session.json
    /// and state.json are pinned, no record aside can be created and the
    /// lock file takes none, so the log is the only place left for the
    /// record. A record of this session whose newline alone is missing
    /// ends it, and every line the run writes after it starts on a line of
    /// its own, so it stays whole and is used again. Otherwise the log ends
    /// in a line a write left partway, and another write leaves `cut sh`
    /// at its end again before each check for a record (GREP is a fake
    /// here), the one just before the record is written included: the
    /// run's first attempt writes the record on a line of its own and
    /// reads it back. Uninstall then stops with session.json and the logs
    /// kept.
    func testUninstallsBackstopRunKeepsALineCutShortApartInBothModes() throws {
        for purge in [false, true] {
            for recorded in [true, false] {
                let f = try ScriptFixture()
                defer {
                    for file in [f.session, f.endedSession, f.state] { try? setImmutable(file, false) }
                    f.destroy()
                }
                try f.installMachinery()
                try f.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
                try f.writeState(liveJournal)
                let record = String(decoding: try XCTUnwrap(LogEndRecord.line(for: try Data(contentsOf: f.session))), as: UTF8.self)
                try Data("log\n\(recorded ? record : "cut sh")".utf8).write(to: f.logFile)
                try "{}".write(to: f.endedSession, atomically: true, encoding: .utf8)
                for file in [f.session, f.endedSession, f.state] { try setImmutable(file, true) }
                var text = try ScriptFixture.replaceOnce(try String(contentsOf: f.backstop, encoding: .utf8), "MKTEMP=/usr/bin/mktemp", with: "MKTEMP=/usr/bin/false")
                text = try ScriptFixture.replaceOnce(text, "\nLOCK_RECORD_MAX_BYTES=1048576\n", with: "\nLOCK_RECORD_MAX_BYTES=0\n")
                if !recorded {
                    let grep = f.root.appendingPathComponent("grep")
                    try #"""
                    #!/bin/bash
                    if [[ "${1:-}" == -Fxq && "${2:-}" == -e && "${3:-}" == "insomnia-ended-session-v1 "* ]]; then
                      if [[ "$(/usr/bin/tail -c 1 '\#(f.logFile.path)'; printf x)" == $'\nx' ]]; then printf 'cut sh' >> '\#(f.logFile.path)'; fi
                    fi
                    exec /usr/bin/grep "$@"

                    """#.write(to: grep, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grep.path)
                    text = try ScriptFixture.replaceOnce(text, "\nGREP=/usr/bin/grep\n", with: "\nGREP='\(grep.path)'\n")
                }
                try text.write(to: f.backstop, atomically: true, encoding: .utf8)

                let r = try f.run(f.uninstall, purge ? ["--purge"] : [])

                let label = "\(purge ? "--purge" : "plain"), \(recorded ? "record" : "cut sh")"
                let log = f.log()
                XCTAssertNotEqual(r.status, 0, "\(label): \(r.stdout)")
                XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), "\(label): \(f.calls())")
                XCTAssertEqual(log.components(separatedBy: "\n").filter { $0 == record }.count, 1, "\(label): \(log)")
                XCTAssertTrue(log.contains("\(record)\n"), "\(label): \(log)")
                XCTAssertTrue(log.contains("its end is recorded in the log file \(f.logFile.path) instead"), "\(label): \(log)")
                if recorded {
                    XCTAssertTrue(log.hasPrefix("log\n\(record)\n"), "\(label): \(log)")
                } else {
                    XCTAssertTrue(log.hasPrefix("log\ncut sh\n"), "\(label): \(log)")
                    XCTAssertTrue(log.contains("cut sh\n\(record)\n"), "\(label): \(log)")
                    XCTAssertEqual(Set(log.components(separatedBy: "\n").filter { $0.contains("cut sh") }), ["cut sh"], "\(label): \(log)")
                }
                XCTAssertTrue(f.exists(f.session), label)
                XCTAssertTrue(f.exists(f.logFile), label)
            }
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

    /// The app renames a config.json it cannot decode to the same shape
    /// (Store.moveAsideUnreadableConfig). A plain uninstall keeps those
    /// copies, as it keeps config.json; --purge removes them, and only them:
    /// another name under the prefix and a directory named like a copy stay.
    func testUninstallKeepsMovedAsideConfigCopiesAndPurgeRemovesOnlyThose() throws {
        func movedAsideConfigs() throws -> [String] {
            try fx.contents(of: fx.home).filter { $0.hasPrefix("config.json.unreadable-") }.sorted()
        }
        try fx.installMachinery()
        let ours = ["config.json.unreadable-20260101T000000Z", "config.json.unreadable-20260101T000000Z-2"]
        let notOurs = "config.json.unreadable-notes.txt"
        for name in ours + [notOurs] {
            try "x".write(to: fx.home.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let dir = fx.home.appendingPathComponent("config.json.unreadable-20260101T000000Z-1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let kept = try fx.run(fx.uninstall)

        XCTAssertEqual(kept.status, 0, kept.stderr + kept.stdout)
        XCTAssertEqual(try movedAsideConfigs().count, 4)
        XCTAssertTrue(kept.stdout.contains("Kept 2 unreadable config.json file(s) moved aside"), kept.stdout)
        XCTAssertTrue(kept.stdout.contains("Kept \(dir.path): it is named like a moved-aside config.json but is not a regular file"), kept.stdout)

        try fx.installMachinery()
        let purged = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(purged.status, 0, purged.stderr + purged.stdout)
        XCTAssertEqual(try movedAsideConfigs(), [dir.lastPathComponent, notOurs].sorted())
        XCTAssertTrue(purged.stdout.contains("Left \(dir.path): it is named like a moved-aside config.json but is not a regular file"), purged.stdout)
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
        for rotated in ["Logs/handoffs.log", "Logs/insomnia.log.1", "Logs/handoffs.log.1"] {
            try "older lines\n".write(to: fx.home.appendingPathComponent(rotated), atomically: true, encoding: .utf8)
        }
        try fx.writeMarkerBackstop(at: fx.legacyBackstop, name: "legacy")

        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 0, r.stderr + r.stdout)
        for gone in [fx.state, fx.config, fx.endedSession, fx.logFile, fx.home.appendingPathComponent("Logs/handoffs.log"),
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

    /// An end record that cannot be removed survives the purge, and the
    /// purge names it and fails, as for any file it owns, instead of
    /// reporting everything gone. The rest is still removed.
    func testUninstallPurgeReportsAnEndRecordItCannotRemove() throws {
        try fx.installMachinery()
        try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
        try "{}".write(to: fx.endedSession, atomically: true, encoding: .utf8)
        try setImmutable(fx.endedSession, true)

        let r = try fx.run(fx.uninstall, ["--purge"])

        XCTAssertEqual(r.status, 1, r.stderr + r.stdout)
        XCTAssertTrue(fx.exists(fx.endedSession))
        XCTAssertTrue(r.stderr.contains("Could not remove \(fx.endedSession.path); left in place."), r.stderr)
        XCTAssertTrue(r.stderr.contains("Done, except 1 file(s) that could not be removed"), r.stderr)
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

    /// The folder uninstall.sh takes a checkout's backstop.sh from is found
    /// without PATH or CDPATH (script_dir). Run by a relative path from the
    /// checkout, with a dirname and a cat first in PATH that both print a
    /// decoy checkout's scripts folder to uninstall.sh, and with CDPATH
    /// holding that decoy, it runs the checkout's own backstop.sh; it calls
    /// neither stand-in. The
    /// control is the same copy with the folder found the way it was
    /// before (cd "$(dirname ...)"): the stand-in dirname then picks the
    /// decoy, whose backstop.sh runs.
    func testUninstallFindsItsCheckoutWithoutPATHOrCDPATH() throws {
        let found = "SCRIPT_DIR=\"$(script_dir)\"\n"
        let original = try String(contentsOf: fx.uninstall, encoding: .utf8)
        XCTAssertEqual(original.components(separatedBy: found).count, 2)
        for control in [false, true] {
            fx.destroy()
            fx = try ScriptFixture()
            try fx.installMachinery()
            try fx.writeState(#"{"sleepDisabledByUs":false,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false}"#)
            try fx.writeMarkerBackstop(at: fx.backstop, name: "checkout")
            if control {
                let text = try String(contentsOf: fx.uninstall, encoding: .utf8)
                    .replacingOccurrences(of: found, with: "SCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n")
                try text.write(to: fx.uninstall, atomically: true, encoding: .utf8)
            }
            let decoy = fx.root.appendingPathComponent("decoy", isDirectory: true)
            let decoyScripts = decoy.appendingPathComponent("repo/scripts", isDirectory: true)
            try fx.writeMarkerBackstop(at: decoyScripts.appendingPathComponent("backstop.sh"), name: "decoy")
            try "// swift-tools-version: 6.2\n".write(to: decoy.appendingPathComponent("repo/Package.swift"), atomically: true, encoding: .utf8)
            let shadow = fx.root.appendingPathComponent("shadow", isDirectory: true)
            try FileManager.default.createDirectory(at: shadow, withIntermediateDirectories: true)
            let standIns = fx.root.appendingPathComponent("stand-ins.log")
            // A stand-in answers uninstall.sh only; the fake tools' own
            // calls (they read their mode files with cat) go to the real one.
            for (tool, real) in [("dirname", "/usr/bin/dirname"), ("cat", "/bin/cat")] {
                let url = shadow.appendingPathComponent(tool)
                try """
                    #!/bin/bash
                    case "$(/bin/ps -o command= -p "$PPID")" in
                      *repo/scripts/uninstall.sh*) ;;
                      *) exec \(real) "$@" ;;
                    esac
                    printf '\(tool) %s\\n' "$*" >> '\(standIns.path)'
                    printf '%s\\n' '\(decoyScripts.path)'

                    """.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
            let relative = fx.root.appendingPathComponent("relative-uninstall.sh")
            try "cd '\(fx.root.path)' && exec /bin/bash repo/scripts/uninstall.sh \"$@\"\n".write(to: relative, atomically: true, encoding: .utf8)

            let r = try fx.run(relative, extraEnvironment: ["PATH": "\(shadow.path):/usr/bin:/bin:/usr/sbin:/sbin", "CDPATH": decoy.path])

            XCTAssertEqual(r.status, 0, "control \(control): " + r.stderr + r.stdout)
            let ran = fx.calls().filter { $0.hasPrefix("backstop ") }
            if control {
                XCTAssertEqual(ran, ["backstop decoy --force"], "the control picks the decoy: \(fx.calls())")
                XCTAssertTrue(((try? String(contentsOf: standIns, encoding: .utf8)) ?? "").hasPrefix("dirname "), "the control runs the stand-in dirname")
            } else {
                XCTAssertEqual(ran, ["backstop checkout --force"], "\(fx.calls())")
                XCTAssertTrue(r.stdout.contains("using \(fx.backstop.path)\n"), r.stdout)
                XCTAssertFalse(fx.exists(standIns), "a stand-in ran: \((try? String(contentsOf: standIns, encoding: .utf8)) ?? "")")
            }
        }
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
    /// The one tool bounded() takes by name, cat, reads a sudo call's pid,
    /// and uninstall.sh calls bounded() only with fixed paths that are not
    /// $SUDO, so it never reaches that cat: every call site names one of
    /// them, and a whole uninstall with a stand-in cat first in PATH runs
    /// no stand-in (testUninstallFindsItsCheckoutWithoutPATHOrCDPATH).
    func testInstallAndUninstallShareTheBoundedCallHelper() throws {
        func text(_ name: String) throws -> String {
            try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(name), encoding: .utf8)
        }
        func helper(_ name: String) throws -> String {
            let text = try text(name)
            let start = try XCTUnwrap(text.range(of: "\nbounded() {"), name)
            let supervise = try XCTUnwrap(text.range(of: "\nsupervise() {", range: start.upperBound..<text.endIndex), name)
            let end = try XCTUnwrap(text.range(of: "\n}\n", range: supervise.upperBound..<text.endIndex), name)
            return String(text[start.lowerBound..<end.upperBound])
        }
        XCTAssertEqual(try helper("install.sh"), try helper("uninstall.sh"))
        let uninstall = try text("uninstall.sh")
        let calls = uninstall.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && $0.range(of: #"(^|[^_A-Za-z])bounded( |$)"#, options: .regularExpression) != nil
        }
        XCTAssertFalse(calls.isEmpty)
        for line in calls {
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            let tool = try XCTUnwrap(words.firstIndex(of: "bounded").map { words.index(after: $0) }.flatMap { $0 < words.endIndex ? String(words[$0]) : nil }, line)
            XCTAssertTrue(["\"$DEFAULTS\"", "\"$PGREP\"", "\"$CODESIGN\"", "\"$LAUNCHCTL\""].contains(tool), "bounded runs \(tool): \(line)")
        }
        for name in ["DEFAULTS", "PGREP", "CODESIGN", "LAUNCHCTL"] {
            XCTAssertNotNil(uninstall.range(of: "\n\(name)=/", options: .literal), "\(name) is a fixed path")
        }
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
    /// since it may run before the upgraded app has opened them. The app is
    /// running, so the session stands and session.json is still there to
    /// check.
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

        let app = try fx.holdAliveLock()
        defer { app.release() }
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

    func testTypedCorruptJournalIsRejectedByBackstopWithoutCommands() async throws {
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
        // One fixture per journal; the runs go several at a time.
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for json in corrupt {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })

        for (json, (f, r)) in zip(corrupt, zip(fixtures, results)) {
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
        ("a key in the top level of state.json is text the app's decoder does not read", #""kept\#(backslash)x44isplayReadLit":0.8"#),
        ("the text of state.json is not JSON the app's decoder reads", #"keptDisplayReadLit:1e-400"#),
        ("the text of state.json is not JSON the app's decoder reads", #"'keptDisplayReadLit':0.8"#),
        ("the text of state.json is not JSON the app's decoder reads", #"/* note */"keptDisplayReadLit":0.8"#),
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

    /// Journals the app reads, taking the first copy of a key it reads
    /// twice, however the copy is spelled. plutil would read the last copy,
    /// so both scripts read the view of the journal that the reader writes,
    /// which holds the first copy alone.
    static let duplicatedKeptDisplayRecords = [
        #""keptDisplayReadLit":0.8,"keptDisplayReadLit":0.7"#,
        #""keptDisplayReadLit":0.8,"keptDisplayReadL\#(backslash)u0069t":0.7"#,
        #""keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPower":0.7,"keptDisplayUnderLowPower":0.6"#,
        #""keptDisplayUnderLowPowerBoot":"boot A","keptDisplayUnderLowPowerBoot":"boot B""#,
    ]

    static let keptDisplayRecordKeys = [
        "keptDisplayUnderLowPower", "keptDisplayUnderLowPowerBoot", "keptDisplayReadLit", "displayRestoredUnderLowPower",
    ]

    /// A record the app could not decode makes the journal malformed, as
    /// any other key of the wrong shape does: no pmset, the bytes and the
    /// session kept, and the log names the key. The app's decoder refuses
    /// each of these journals too.
    func testMalformedKeptDisplayRecordsAreRejectedByBackstopWithoutCommands() async throws {
        // One fixture per journal; the runs go several at a time.
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for (_, record) in Self.malformedKeptDisplayRecords {
            let json = Self.keptDisplayJournal(record)
            XCTAssertThrowsError(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), "the app refuses \(json)")
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(json)
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })

        for ((problem, record), (f, r)) in zip(Self.malformedKeptDisplayRecords, zip(fixtures, results)) {
            let json = Self.keptDisplayJournal(record)
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
    func testValidKeptDisplayRecordsAreKeptForTheApp() async throws {
        // One fixture per journal; each round of runs goes several at a time.
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for records in Self.validKeptDisplayRecords {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(Self.keptDisplayJournal(records))
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })

        var publishedJournals: [Data] = []
        for (records, (f, r)) in zip(Self.validKeptDisplayRecords, zip(fixtures, results)) {
            let json = Self.keptDisplayJournal(records)
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            let decodedBefore = try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8))
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
            publishedJournals.append(published)
        }

        let again = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })

        for (records, (f, (r, published))) in zip(Self.validKeptDisplayRecords, zip(fixtures, zip(again, publishedJournals))) {
            let json = Self.keptDisplayJournal(records)
            XCTAssertEqual(r.status, 0, json + r.stderr + f.log())
            XCTAssertEqual(f.calls().count, 2, json)
            XCTAssertFalse(f.log().contains("malformed"), f.log())
            XCTAssertEqual(try Data(contentsOf: f.state), published, "a clean journal is not rewritten: \(json)")
        }
    }

    /// uninstall.sh checks the same records itself: one the app could not
    /// decode stops it with everything in place, even when the backstop
    /// exits 0.
    func testUninstallRejectsMalformedKeptDisplayRecordsEvenWhenBackstopExitsZero() async throws {
        // One fixture per journal; the runs go several at a time.
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for (_, record) in Self.malformedKeptDisplayRecords {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.installMachinery()
            try "#!/bin/bash\nexit 0\n".write(to: f.backstop, atomically: true, encoding: .utf8)
            try f.writeState(Self.keptDisplayJournal(record, ours: false))
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.uninstall, ["--purge"]) })

        for ((problem, record), (f, r)) in zip(Self.malformedKeptDisplayRecords, zip(fixtures, results)) {
            let json = Self.keptDisplayJournal(record, ours: false)
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

    /// A key the app reads more than once, as in
    /// `duplicatedKeptDisplayRecords`: the backstop reads the first copy,
    /// as the app does, undoes sleep and the mode, and publishes the
    /// journal with each key once, from which the app decodes the records
    /// it read before, but for the boot of a record of the kept entry,
    /// which becomes this boot as the mode goes off. uninstall.sh, with
    /// the backstop it installed, completes past the same records and
    /// keeps state.json byte for byte.
    func testDuplicatedKeptDisplayRecordsAreReadAsTheAppReadsThem() async throws {
        // One fixture per journal and script; the runs go several at a time.
        var fixtures: [ScriptFixture] = []
        var uninstallFixtures: [ScriptFixture] = []
        defer { (fixtures + uninstallFixtures).forEach { $0.destroy() } }
        for record in Self.duplicatedKeptDisplayRecords {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
            try f.writeState(Self.keptDisplayJournal(record))
            let u = try ScriptFixture.concurrentRow()
            uninstallFixtures.append(u)
            try u.installMachinery()
            try u.writeConfig(#"{"agentList":[]}"#)
            try u.writeState(Self.keptDisplayJournal(record, ours: false))
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })
        let uninstalls = try await ScriptFixture.runAll(uninstallFixtures.map { $0.launch($0.uninstall, ["--purge"]) })

        for (record, ((f, r), (u, ur))) in zip(Self.duplicatedKeptDisplayRecords, zip(zip(fixtures, results), zip(uninstallFixtures, uninstalls))) {
            let json = Self.keptDisplayJournal(record)
            let decodedBefore = try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8))
            XCTAssertEqual(r.status, 0, json + r.stderr + f.log())
            XCTAssertEqual(f.calls(), [
                "sudo -n \(f.fakePmset) -a disablesleep 0",
                "sudo -n \(f.fakePmset) -b lowpowermode 0",
            ], json)
            XCTAssertFalse(f.log().contains("malformed"), f.log())
            let published = try Data(contentsOf: f.state)
            let text = String(decoding: published, as: UTF8.self)
            for key in Self.keptDisplayRecordKeys {
                XCTAssertLessThanOrEqual(text.components(separatedBy: "\"\(key)\"").count - 1, 1, "\(key) in what \(json) became: \(text)")
            }
            let decoded = try Store.makeDecoder().decode(RuntimeState.self, from: published)
            let stamped = decodedBefore.keptDisplayUnderLowPower != nil
            XCTAssertFalse(decoded.lowPowerSetByUs, json)
            XCTAssertEqual(decoded.keptDisplayUnderLowPower, decodedBefore.keptDisplayUnderLowPower, json)
            XCTAssertEqual(decoded.keptDisplayUnderLowPowerBoot, stamped ? f.bootUUID : decodedBefore.keptDisplayUnderLowPowerBoot, json)
            XCTAssertEqual(decoded.keptDisplayReadLit, decodedBefore.keptDisplayReadLit, json)
            XCTAssertEqual(decoded.displayRestoredUnderLowPower, decodedBefore.displayRestoredUnderLowPower, json)

            let kept = Self.keptDisplayJournal(record, ours: false)
            XCTAssertEqual(ur.status, 0, kept + ur.stderr + ur.stdout)
            XCTAssertFalse(u.exists(u.plist), kept)
            XCTAssertFalse(u.exists(u.app), kept)
            XCTAssertEqual(try String(contentsOf: u.state, encoding: .utf8), kept)
            XCTAssertTrue(ur.stdout.contains("  - display brightness 0.8"), ur.stdout)
        }
    }

    /// The reader as it is in each script (`readerBlock`), run on its own
    /// over exact bytes as state.json: what record_text_problems prints, or
    /// nothing, and the view it writes, if it writes one, which plutil must
    /// read for the run to pass.
    private func recordTextProblems(_ inputs: [(label: String, bytes: Data)], script: String = "backstop.sh") throws -> [String: (printed: String, view: Data?)] {
        let f = try ScriptFixture()
        defer { f.destroy() }
        let runner = f.root.appendingPathComponent("record-text-problems.sh")
        try ("""
        set -euo pipefail
        STAT=/usr/bin/stat
        HEAD=/usr/bin/head
        CMP=/usr/bin/cmp
        ICONV=/usr/bin/iconv
        TEXT_READ_SECONDS=30

        """ + Self.readerBlock(script) + """

        record_text_problems "$1" state "$2"
        [[ ! -f "$2" ]] || /usr/bin/plutil -convert json -o /dev/null "$2"

        """)
            .write(to: runner, atomically: true, encoding: .utf8)
        var printed: [String: (printed: String, view: Data?)] = [:]
        for (i, input) in inputs.enumerated() {
            let file = f.root.appendingPathComponent("input.\(i)")
            let view = f.root.appendingPathComponent("view.\(i)")
            try input.bytes.write(to: file)
            let r = try f.run(runner, [file.path, view.path])
            XCTAssertEqual(r.status, 0, "\(input.label): \(r.stderr)")
            XCTAssertEqual(r.stderr, "", input.label)
            var written: Data?
            if f.exists(view) { written = try Data(contentsOf: view) }
            printed[input.label] = (r.stdout, written)
        }
        return printed
    }

    /// The lines of `script`, which is ASCII.
    private static func scriptLines(_ script: String) throws -> [String] {
        let text = try String(contentsOf: ScriptFixture.productionScripts.appendingPathComponent(script), encoding: .utf8)
        XCTAssertTrue(text.allSatisfy(\.isASCII), script)
        return text.components(separatedBy: "\n")
    }

    /// The index of the one line of `lines` that is the header of the
    /// function `name`, with or without a comment after the brace, and of
    /// the first line after it that is a closing brace alone. Fails unless
    /// the header is there exactly once and every line between is empty or
    /// indented, so that what is taken is the function and nothing else.
    private static func functionRange(_ name: String, in lines: [String], script: String) throws -> ClosedRange<Int> {
        let headers = lines.indices.filter { lines[$0] == "\(name)() {" || lines[$0].hasPrefix("\(name)() { #") }
        XCTAssertEqual(headers.count, 1, "\(name) in \(script)")
        let start = try XCTUnwrap(headers.first, "\(name) in \(script)")
        let end = try XCTUnwrap(lines[start...].firstIndex(of: "}"), "\(name) in \(script)")
        for line in lines[(start + 1)..<end] {
            XCTAssertTrue(line.isEmpty || line.hasPrefix(" "), "\(name) in \(script): \(line)")
        }
        return start...end
    }

    /// The functions `names` as they are in `script` (`functionRange`).
    private static func scriptFunctions(_ names: [String], script: String) throws -> String {
        let lines = try scriptLines(script)
        return try names.map { name in
            lines[try functionRange(name, in: lines, script: script)].joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The reader both scripts carry: from the comment on json_whole, its
    /// first function, to the end of record_text_problems, its last. Every
    /// line of it is a comment, a function's header or closing brace, empty
    /// or indented, so it defines functions and runs nothing.
    private static func readerBlock(_ script: String) throws -> String {
        let lines = try scriptLines(script)
        let first = "# Sets whole_value to the whole number the app's JSONDecoder reads for the"
        XCTAssertEqual(lines.filter { $0 == first }.count, 1, script)
        let start = try XCTUnwrap(lines.firstIndex(of: first), script)
        let end = try functionRange("record_text_problems", in: lines, script: script).upperBound
        XCTAssertLessThan(start, end, script)
        for line in lines[start...end] {
            let header = line.range(of: #"^[a-z_]+\(\) \{( #.*)?$"#, options: .regularExpression) != nil
            XCTAssertTrue(line.isEmpty || line.hasPrefix("#") || line.hasPrefix(" ") || line == "}" || header, "\(script): \(line)")
        }
        return lines[start...end].joined(separator: "\n")
    }

    /// Greptile 4219151866: one table of journals, each read by the app
    /// (`Store.decodeState`, what `Store.loadState` runs), by the agent's
    /// mode of the app's binary (`AgentCutoffsCommand.sessionAnswer`), and
    /// by each script's own check as the script runs it: check_journal in
    /// backstop.sh, and journal_view then journal_problems in uninstall.sh.
    /// For the agent, the record is also read as its own reader takes it
    /// (journal_cutoffs). Both scripts accept exactly the journals the app
    /// loads here. Where plutil would read the text otherwise than the app
    /// (a key the app reads twice or spelled with an escape, a whole number
    /// written with a fraction or an exponent, UTF-16 or UTF-32, text plutil
    /// cannot parse under a key the app skips), both read the view the
    /// reader writes, the same bytes in each script, which the app decodes
    /// to the same state as the journal. They accept what the app skips (a
    /// key twice in an object it does not read, a \x escape or 1. under a
    /// key it does not read, and in a frozen process without a startedAt,
    /// or without a startedAtMicros, what follows it: FrozenProcess). On
    /// every journal they accept, the agent's reader gives the binary's
    /// record: for a record twice, the app's first copy, and for a value
    /// the app reads as no record (an object, 1., a \x escape), foreign.
    /// The journals the app writes now and wrote before (frozenPids, no
    /// record) pass.
    func testTheAppTheBinaryAndBothScriptsAcceptTheSameJournals() async throws {
        let b = backslash
        var full = RuntimeState()
        full.sleepDisabledByUs = true
        full.lowPowerSetByUs = true
        full.dockerFrozen = true
        full.frozenProcesses = [FrozenProcess(pid: 5105, identity: ProcessIdentity(startedAt: 1_700_000_000, startedAtMicros: 250_000, bootSession: "0F0F0F0F-1111-2222-3333-444444444444"))]
        full.savedAudioOutputs = [SavedAudioOutput(deviceUID: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", volume: 0.5, muted: false, saveID: "a")]
        full.savedOutputVolume = 0.25
        full.savedMuted = false
        full.savedDisplayBrightness = 0.8
        full.savedKeyboardBrightness = 0.3
        full.appNapOverrides = [AppNapOverride(bundleId: "com.example.agent", previous: nil)]
        full.endedSession = "e30="
        full.sessionCutoffs = AgentCutoffs(endFloor: 30, thermalRules: false)
        let written = String(decoding: try Store.makeEncoder().encode(full), as: UTF8.self)
        // (label, text, the app loads)
        let rows: [(label: String, text: String, app: Bool)] = [
            ("the app's journal now", written, true),
            ("an older build's journal", #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenPids":[5105,5106],"dockerFrozen":false}"#, true),
            ("a frozen process without identity", #"{"frozenProcesses":[{"pid":5105}]}"#, true),
            ("no keys", "{}", true),
            ("commas before the ends", #"{"frozenProcesses":[],"sleepDisabledByUs":true,}"#, true),
            ("keys spelled with escapes", #"{"sleep\#(b)u0044isabledByUs":true,"session\#(b)u0043utoffs":"30 false"}"#, true),
            ("an escaped record", #"{"sessionCutoffs":"\#(b)u0033\#(b)u0030 false"}"#, true),
            ("other keys and values", #"{"note":{"a":[1,{"b":null}],"c":"\#(b)u00e9"},"sessionCutoffs":"0 true"}"#, true),
            ("a record the app does not write", #"{"sessionCutoffs":"96 false"}"#, true),
            ("a record of another type", #"{"sessionCutoffs":30}"#, true),
            ("a record with a newline", #"{"sessionCutoffs":"30 false\#(b)n"}"#, true),
            ("a null record", #"{"sessionCutoffs":null}"#, true),
            ("a bool of the wrong type", #"{"sleepDisabledByUs":"yes","sessionCutoffs":"30 false"}"#, false),
            ("frozenProcesses of the wrong type", #"{"sleepDisabledByUs":true,"frozenProcesses":"bad","sessionCutoffs":"30 false"}"#, false),
            ("a pid of the wrong type", #"{"frozenProcesses":[{"pid":"5105"}]}"#, false),
            ("a pid written as 1.0", #"{"frozenProcesses":[{"pid":5105.0}]}"#, true),
            ("whole numbers written with a fraction or an exponent", #"{"frozenProcesses":[{"pid":5105.0,"startedAt":1.7e9,"startedAtMicros":25E4,"bootSession":"x"}],"frozenPids":[1e2,-0.0,0e999]}"#, true),
            ("a pid that is not whole", #"{"frozenProcesses":[{"pid":5105.5}]}"#, false),
            ("a pid past Int32 written as a float", #"{"frozenProcesses":[{"pid":2147483648.0}]}"#, false),
            ("a startedAt up to 2^53 written as a float", #"{"frozenProcesses":[{"pid":1,"startedAt":9007199254740992.0}]}"#, true),
            ("an identity with a startedAt of 1e18", #"{"frozenProcesses":[{"pid":4242,"startedAt":1e18,"startedAtMicros":0,"bootSession":"test"}]}"#, true),
            ("a startedAt of 2^62 written as a float", #"{"frozenProcesses":[{"pid":1,"startedAt":4611686018427387904.0},{"pid":2,"startedAt":-4611686018427387904.0}]}"#, true),
            ("a startedAt a Double does not hold, written as a float", #"{"frozenProcesses":[{"pid":1,"startedAt":9007199254740993.0}]}"#, true),
            ("the ends of Int64", #"{"frozenProcesses":[{"pid":1,"startedAt":-9223372036854775808},{"pid":2,"startedAt":9223372036854775807}]}"#, true),
            ("the lowest Int64 written as a float", #"{"frozenProcesses":[{"pid":1,"startedAt":-9223372036854775808.0}]}"#, false),
            ("the ends of Int32 written as floats", #"{"frozenProcesses":[{"pid":2147483647.0}],"frozenPids":[-2147483648.0,21474836.47e2]}"#, true),
            ("a pid a Double rounds to whole", #"{"frozenProcesses":[{"pid":1.0000000000000001}]}"#, true),
            ("a legacy pid a Double rounds to 0", #"{"frozenPids":[1e-99999]}"#, true),
            ("a provisional entry: startedAtMicros of the wrong type, no startedAt", #"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":4242,"startedAtMicros":"bad","bootSession":"test"}]}"#, true),
            ("a provisional entry: bootSession of the wrong type, no startedAtMicros", #"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":4242,"startedAt":123,"bootSession":42}]}"#, true),
            ("a provisional entry: startedAtMicros past Int32, no startedAt", #"{"sleepDisabledByUs":true,"frozenProcesses":[{"pid":4242,"startedAtMicros":2147483648}]}"#, true),
            ("a provisional entry: a null startedAt", #"{"frozenProcesses":[{"pid":4242,"startedAt":null,"startedAtMicros":"bad","bootSession":42}]}"#, true),
            ("a provisional entry: startedAtMicros twice, no startedAt", #"{"frozenProcesses":[{"pid":4242,"startedAtMicros":1,"startedAtMicros":"x"}]}"#, true),
            ("a provisional entry: bootSession twice, no startedAtMicros", #"{"frozenProcesses":[{"pid":4242,"startedAt":123,"bootSession":"a","bootSession":5}]}"#, true),
            ("an identity with a bootSession of the wrong type", #"{"frozenProcesses":[{"pid":4242,"startedAt":123,"startedAtMicros":0,"bootSession":42}]}"#, false),
            ("an identity with startedAtMicros past Int32", #"{"frozenProcesses":[{"pid":4242,"startedAt":123,"startedAtMicros":2147483648,"bootSession":"test"}]}"#, false),
            ("an identity with startedAtMicros of the wrong type", #"{"frozenProcesses":[{"pid":4242,"startedAt":123,"startedAtMicros":"bad","bootSession":"test"}]}"#, false),
            ("an identity with startedAtMicros after its bad bootSession", #"{"frozenProcesses":[{"pid":4242,"bootSession":42,"startedAtMicros":0,"startedAt":123}]}"#, false),
            ("an identity with startedAtMicros twice", #"{"frozenProcesses":[{"pid":4242,"startedAt":123,"startedAtMicros":1,"startedAtMicros":2,"bootSession":"b"}]}"#, true),
            ("a pid too large", #"{"frozenProcesses":[{"pid":2147483648}]}"#, false),
            ("a saved output without muted", #"{"savedAudioOutputs":[{"deviceUID":"a","volume":0.5}]}"#, false),
            ("an App Nap entry without its bundle", #"{"appNapOverrides":[{"previous":true}]}"#, false),
            ("an endedSession of the wrong type", #"{"endedSession":5}"#, false),
            ("a level too large", #"{"savedKeyboardBrightness":1e39}"#, false),
            ("a key twice", #"{"sleepDisabledByUs":true,"sleepDisabledByUs":false}"#, true),
            ("a bad first copy", #"{"frozenProcesses":"bad","frozenProcesses":[]}"#, false),
            ("a bad last copy", #"{"frozenProcesses":[],"frozenProcesses":"bad"}"#, true),
            ("a nested key twice", #"{"frozenProcesses":[{"pid":5,"pid":"x"}]}"#, true),
            ("a key twice in objects the app does not read", #"{"note":{"x":1,"x":2},"frozenProcesses":[{"pid":5,"extra":{"y":1,"y":2}}],"sessionCutoffs":"30 false"}"#, true),
            ("a key the app does not read twice", #"{"note":1,"note":2,"savedAudioOutputs":[{"deviceUID":"a","volume":0.5,"muted":false,"x":1,"x":2}]}"#, true),
            ("an object under the record", #"{"sessionCutoffs":{"a":1,"a":2}}"#, true),
            ("a key twice, once escaped", #"{"sleepDisabledByUs":true,"sleepDisabledBy\#(b)u0055s":"x"}"#, true),
            ("a key twice, once with a Kelvin sign", "{\"saved\u{212A}eyboardBrightness\":\"bad\",\"savedKeyboardBrightness\":0.5}", false),
            ("a record twice", #"{"sessionCutoffs":"30 false","sessionCutoffs":"0 true"}"#, true),
            ("a record with an escape JSON does not have", #"{"sessionCutoffs":"3\#(b)x30 false"}"#, true),
            ("a record written as 1.", #"{"sessionCutoffs":1.}"#, true),
            ("a bad escape under another key", #"{"note":"\#(b)x41"}"#, true),
            ("values the app skips", #"{"note":[1.,-.5,2.e3,1e-400,"\#(b)x41\#(b)'",{"\#(b)x41":1}],"frozenProcesses":[{"pid":1,"x":0.,"y":"\#(b)x41"}],"sessionCutoffs":"0 true"}"#, true),
            ("+1 under another key", #"{"note":+1}"#, false),
            ("a bad escape in a key of an entry the app reads", #"{"appNapOverrides":[{"bundleId":"a","\#(b)x41":1}]}"#, false),
            ("a leading zero under another key", #"{"note":01}"#, true),
            ("not an object", #"["sleepDisabledByUs",true]"#, false),
            ("not JSON", #"{"sleepDisabledByUs":true,"#, false),
        ]
        // The app's journal in other encodings the app reads; it writes
        // only UTF-8.
        let encoded: [(label: String, bytes: Data, app: Bool)] = [
            ("UTF-16 with a byte order mark", Data([0xFF, 0xFE]) + written.data(using: .utf16LittleEndian)!, true),
            ("UTF-16 big-endian without a byte order mark", written.data(using: .utf16BigEndian)!, true),
            ("UTF-32 without a byte order mark", written.data(using: .utf32LittleEndian)!, true),
            ("UTF-32 big-endian without a byte order mark", written.data(using: .utf32BigEndian)!, true),
            ("UTF-32 big-endian with a byte order mark", Data([0x00, 0x00, 0xFE, 0xFF]) + written.data(using: .utf32BigEndian)!, true),
            ("UTF-32 with a byte order mark", Data([0xFF, 0xFE, 0x00, 0x00]) + written.data(using: .utf32LittleEndian)!, false),
        ]
        let table = rows.map { (label: $0.label, bytes: Data($0.text.utf8), app: $0.app) } + encoded
        let f = try ScriptFixture()
        defer { f.destroy() }
        var states: [URL] = []
        for (i, row) in table.enumerated() {
            let dir = f.root.appendingPathComponent("journal.\(i)")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("uninstall"), withIntermediateDirectories: true)
            states.append(dir.appendingPathComponent("state.json"))
            try row.bytes.write(to: states[i])
        }
        let setup = """
            set -euo pipefail
            export LC_ALL=C
            RM=/bin/rm
            CAT=/bin/cat
            PLUTIL=/usr/bin/plutil
            HEAD=/usr/bin/head
            STAT=/usr/bin/stat
            CMP=/usr/bin/cmp
            ICONV=/usr/bin/iconv
            TEXT_READ_SECONDS=30

            """
        // Prints per journal "refused", or "accepted", the journal the
        // script read (state or view), and for backstop.sh the record. Each
        // script reads the journals in `parts` runs, each over folders of
        // its own; both scripts' runs go at once (runAll), and their lines
        // are put back in the journals' order.
        let parts = 4
        let size = (states.count + parts - 1) / parts
        let chunks = stride(from: 0, to: states.count, by: size).map { Array(states[$0..<min($0 + size, states.count)]) }
        func launches(_ script: String, functions: [String], loop: String) throws -> [ScriptFixture.Launch] {
            let runner = f.root.appendingPathComponent("accept.\(script)")
            try (setup + Self.readerBlock(script) + "\n" + Self.scriptFunctions(functions, script: script) + "\n" + loop)
                .write(to: runner, atomically: true, encoding: .utf8)
            return chunks.map { f.launch(runner, $0.map(\.path)) }
        }
        func lines(_ script: String, _ results: ArraySlice<(status: Int32, stdout: String, stderr: String)>) -> [String] {
            var printed: [String] = []
            for (chunk, r) in zip(chunks, results) {
                XCTAssertEqual(r.status, 0, "\(script): \(r.stderr)")
                XCTAssertEqual(r.stderr, "", script)
                let part = r.stdout.split(separator: "\n").map(String.init)
                XCTAssertEqual(part.count, chunk.count, "\(script): \(r.stdout)")
                printed += part
            }
            return printed
        }
        let agentRuns = try launches("backstop.sh", functions: ["extract", "type_of", "shape_types", "shape_value_type", "shape_type", "shape_name", "journal_shape_problems", "check_journal", "journal_cutoffs"], loop: """
            lock_shared=0
            for STATE in "$@"; do
              APP_SUPPORT="${STATE%/*}"
              JOURNAL_VIEW="$APP_SUPPORT/backstop-view"
              journal_checked=0
              journal_state=""
              check_journal
              if [[ "$journal_state" != clean ]]; then
                echo refused
              elif [[ "$JOURNAL" == "$STATE" ]]; then
                echo "accepted state $(journal_cutoffs)"
              else
                echo "accepted view $(journal_cutoffs)"
              fi
            done

            """)
        let uninstallRuns = try launches("uninstall.sh", functions: ["extract", "extract_json", "type_of", "shape_types", "shape_value_type", "shape_type", "shape_name", "journal_shape_problems", "is_refused", "journal_view", "journal_problems"], loop: """
            for STATE in "$@"; do
              SESSION="${STATE%/*}/session.json"
              WORK="${STATE%/*}/uninstall"
              journal_view
              problems="$(journal_problems)"
              if [[ $'\\n'"$problems" == *$'\\n'"state.json is malformed"* || $'\\n'"$problems" == *$'\\n'"state.json is unreadable"* ]]; then
                echo refused
              elif [[ "$JOURNAL" == "$STATE" ]]; then
                echo "accepted state"
              else
                echo "accepted view"
              fi
            done

            """)
        let results = try await ScriptFixture.runAll(agentRuns + uninstallRuns)
        let agent = lines("backstop.sh", results[..<agentRuns.count])
        let uninstall = lines("uninstall.sh", results[agentRuns.count...])
        XCTAssertEqual(agent.count, table.count)
        XCTAssertEqual(uninstall.count, table.count)
        for (i, row) in table.enumerated() where i < agent.count && i < uninstall.count {
            let data = row.bytes
            let app = try? Store.decodeState(data)
            let binary = AgentCutoffsCommand.sessionAnswer(for: data).lines.joined()
            XCTAssertEqual(app != nil, row.app, "the app on \(row.label)")
            XCTAssertEqual(binary == "rejected", !row.app, "the binary on \(row.label): \(binary)")
            XCTAssertEqual(agent[i] != "refused", row.app, "backstop.sh on \(row.label): \(agent[i])")
            XCTAssertEqual(uninstall[i] != "refused", row.app, "uninstall.sh on \(row.label): \(uninstall[i])")
            guard row.app else { continue }
            let read = agent[i].hasPrefix("accepted view ") ? "view" : "state"
            XCTAssertEqual(agent[i], "accepted \(read) \(binary)", "the agent's reader and the binary on \(row.label)")
            XCTAssertEqual(uninstall[i], "accepted \(read)", "the journal each script read on \(row.label)")
            guard read == "view" else { continue }
            let dir = states[i].deletingLastPathComponent()
            let view = try Data(contentsOf: dir.appendingPathComponent("backstop-view"))
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("uninstall/call.state-view")), view, row.label)
            XCTAssertEqual(try? Store.decodeState(view), app, "the app reads the view of \(row.label) as the journal")
        }
    }

    /// The two scripts carry the same reader, every function and comment of
    /// it (`readerBlock`).
    func testBothScriptsReadTheRecordsTheSameWay() throws {
        let reader = try Self.readerBlock("backstop.sh")
        XCTAssertEqual(reader, try Self.readerBlock("uninstall.sh"))
        for name in ["json_whole", "json_decimal_reads", "json_range", "json_magnitude_above", "json_digits_times", "json_float", "json_string_check", "json_nul_mark", "json_view_put", "json_window_trim", "record_text_problems"] {
            XCTAssertTrue(reader.contains("\n\(name)() {"), name)
        }
    }

    /// The reader over texts no fixture writes whole, as each script runs
    /// it: what it prints, the view it writes, and the app's decoder on the
    /// same bytes. Where the app reads the text, the reader prints nothing
    /// or only "view: " and "record: " lines, and writes a view that plutil
    /// reads and the app decodes to the same state. A "view: " line names
    /// what plutil would read otherwise than the app: a key the app reads
    /// twice in one object it reads, or spelled with an escape; a whole
    /// number written with a fraction or an exponent, also one a Double
    /// does not hold or rounds to whole; UTF-16 and UTF-32 (without a byte
    /// order mark, or with UTF-32BE's); -0 where the app reads a Float, and
    /// a NUL byte in text the app skips (both as in
    /// testTheRecordReaderKeepsFloatsAndNULsAsTheAppReadsThem). A "record: "
    /// line is a sessionCutoffs the app reads as no record. Where the app
    /// refuses the text, a line names the problem and no view is written,
    /// but for a key spelled twice whose first copy has a type the app does
    /// not take: the view holds that copy, and journal_shape_problems
    /// refuses it there. What the app skips passes: a key twice in an
    /// object it does not read, a bad escape or 1. in a value it does not
    /// read, and in a frozen process what follows a startedAt or a
    /// startedAtMicros that is missing or null, wherever it is in the
    /// object. The BOM-less UTF-16
    /// file hiding a key is one the reader passed before it refused NUL
    /// bytes: the shell drops them, and what is left reads as a key inside
    /// an array, while the app reads 1e-400 at the top level, as the reader
    /// now does through iconv.
    func testTheRecordReaderFollowsTheTopLevelAsTheAppReadsIt() throws {
        let b = backslash
        let bom = Data([0xEF, 0xBB, 0xBF])
        func utf8(_ s: String) -> Data { Data(s.utf8) }
        let cases: [(label: String, bytes: Data, prints: String, appReads: Bool)] = [
            ("no records", utf8(#"{"sleepDisabledByUs":true}"#), "", true),
            ("empty object", utf8("{ }"), "", true),
            ("UTF-8 byte order mark", bom + utf8(#"{"keptDisplayReadLit":0.8}"#), "", true),
            ("UTF-8 byte order mark, too small", bom + utf8(#"{"keptDisplayReadLit":1e-400}"#),
             "keptDisplayReadLit is 1e-400, which the app reads as a Float that is not 0 and rounds to 0, and throws\n", false),
            ("UTF-16 with a byte order mark", Data([0xFF, 0xFE]) + #"{"keptDisplayReadLit":0.8}"#.data(using: .utf16LittleEndian)!,
             "view: state.json is UTF-16LE, read here as UTF-8\n", true),
            ("UTF-16 without a byte order mark", #"{"keptDisplayReadLit":0.8}"#.data(using: .utf16LittleEndian)!,
             "view: state.json is UTF-16LE, read here as UTF-8\n", true),
            ("UTF-16 big-endian with a byte order mark", Data([0xFE, 0xFF]) + "{\"keptDisplayReadLit\":0.8,\"a\":\"\u{E9}\u{1F600}\"}".data(using: .utf16BigEndian)!,
             "view: state.json is UTF-16BE, read here as UTF-8\n", true),
            ("UTF-16 big-endian, too small", #"{"keptDisplayReadLit":1e-400}"#.data(using: .utf16BigEndian)!,
             "view: state.json is UTF-16BE, read here as UTF-8\n"
                + "keptDisplayReadLit is 1e-400, which the app reads as a Float that is not 0 and rounds to 0, and throws\n", false),
            ("UTF-16 with a key twice", #"{"keptDisplayReadLit":0.8,"keptDisplayReadLit":0.7}"#.data(using: .utf16LittleEndian)!,
             "view: state.json is UTF-16LE, read here as UTF-8\n"
                + "view: the top level of state.json has keptDisplayReadLit more than once; the app reads the first, and so is it read here\n", true),
            ("UTF-32 without a byte order mark", #"{"keptDisplayReadLit":0.8}"#.data(using: .utf32LittleEndian)!,
             "view: state.json is UTF-32LE, read here as UTF-8\n", true),
            ("UTF-32 without a byte order mark, too small", #"{"keptDisplayReadLit":1e-400}"#.data(using: .utf32LittleEndian)!,
             "view: state.json is UTF-32LE, read here as UTF-8\n"
                + "keptDisplayReadLit is 1e-400, which the app reads as a Float that is not 0 and rounds to 0, and throws\n", false),
            ("UTF-32 big-endian without a byte order mark", #"{"keptDisplayReadLit":0.8}"#.data(using: .utf32BigEndian)!,
             "view: state.json is UTF-32BE, read here as UTF-8\n", true),
            ("UTF-32 big-endian with a byte order mark", Data([0x00, 0x00, 0xFE, 0xFF]) + "{\"keptDisplayReadLit\":0.8,\"a\":\"\u{E9}\u{1F600}\"}".data(using: .utf32BigEndian)!,
             "view: state.json is UTF-32BE, read here as UTF-8\n", true),
            ("UTF-32 big-endian with a byte order mark, too large", Data([0x00, 0x00, 0xFE, 0xFF]) + #"{"keptDisplayReadLit":1e39}"#.data(using: .utf32BigEndian)!,
             "view: state.json is UTF-32BE, read here as UTF-8\n"
                + "keptDisplayReadLit is 1e39, too large a number for the app's Float\n", false),
            ("UTF-32 with a byte order mark", Data([0xFF, 0xFE, 0x00, 0x00]) + #"{"keptDisplayReadLit":0.8}"#.data(using: .utf32LittleEndian)!,
             "view: state.json is UTF-16LE, read here as UTF-8\n"
                + "state.json is not a JSON object, which the app's decoder requires\n", false),
            ("UTF-16 without a byte order mark, hiding a key",
             "{\"a\":\"\u{2278}\u{222C}\u{2271}\u{203A}\u{205B}\",\"keptDisplayReadLit\":1e-400,\"b\":\"\u{2C5D}\u{2220}\u{2263}\u{203A}\u{7822}\"}"
                .data(using: .utf16LittleEndian)!,
             "view: state.json is UTF-16LE, read here as UTF-8\n"
                + "keptDisplayReadLit is 1e-400, which the app reads as a Float that is not 0 and rounds to 0, and throws\n", false),
            ("UTF-16 without records", #"{"sleepDisabledByUs":true}"#.data(using: .utf16LittleEndian)!,
             "view: state.json is UTF-16LE, read here as UTF-8\n", true),
            ("NUL byte in a string", utf8("{\"keptDisplayReadLit\":0.8,\"a\":\"x\u{0}y\"}"),
             "view: state.json holds a NUL byte in text the app skips, which plutil does not read; left out\n", true),
            ("comma before the end", utf8(#"{"keptDisplayReadLit":0.8,}"#), "", true),
            ("whitespace everywhere", utf8("\n{ \"a\" :\t[ 1 ,2 ] ,\r\n \"keptDisplayReadLit\"\n:\n0.8\n}\n"), "", true),
            ("escaped letter, upper hex", utf8(#"{"kept\#(b)u0044isplayReadLit":1e-400}"#),
             "view: the top level of state.json has keptDisplayReadLit written as another key the app reads as keptDisplayReadLit; read here as keptDisplayReadLit\n"
                + "keptDisplayReadLit is 1e-400, which the app reads as a Float that is not 0 and rounds to 0, and throws\n", false),
            ("escaped letter, lower hex", utf8(#"{"keptDisplayRead\#(b)u004cit":1e39}"#),
             "view: the top level of state.json has keptDisplayReadLit written as another key the app reads as keptDisplayReadLit; read here as keptDisplayReadLit\n"
                + "keptDisplayReadLit is 1e39, too large a number for the app's Float\n", false),
            ("escaped letter, valid value", utf8(#"{"keptDisplayReadL\#(b)u0069t":0.8}"#),
             "view: the top level of state.json has keptDisplayReadLit written as another key the app reads as keptDisplayReadLit; read here as keptDisplayReadLit\n", true),
            ("other escapes in keys", utf8(#"{"a\#(b)"\#(b)\#(b)\#(b)/\#(b)b\#(b)f\#(b)n\#(b)r\#(b)t\#(b)u00e9\#(b)ud83d\#(b)ude00":1}"#), "", true),
            ("a key with a \\x escape", utf8(#"{"kept\#(b)x44isplayReadLit":0.8}"#),
             "a key in the top level of state.json is text the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)\n", false),
            ("unquoted key", utf8(#"{keptDisplayReadLit:0.8}"#),
             "the text of state.json is not JSON the app's decoder reads\n", false),
            ("block comment", utf8(#"{"a":1,/* c */"keptDisplayReadLit":0.8}"#),
             "the text of state.json is not JSON the app's decoder reads\n", false),
            ("line comment", utf8("{\"a\":1, // c\n\"keptDisplayReadLit\":0.8}"),
             "the text of state.json is not JSON the app's decoder reads\n", false),
            ("escaped backslash in a value", utf8(#"{"name":"Headset \#(b)\#(b)u0041","uid":"\#(b)\#(b)"}"#), "", true),
            ("escape in a value", utf8(#"{"name":"Headset \#(b)u0041 \#(b)"keptDisplayReadLit\#(b)":1e-400"}"#), "", true),
            ("nested copies", utf8(#"{"keptDisplayReadLit":0.8,"a":{"keptDisplayReadLit":1e-400,"b":[["keptDisplayReadLit",{"keptDisplayReadLit":0.7}]]}}"#), "", true),
            ("brackets in nested strings", utf8(#"{"a":{"b":"}]","c":["{[",{"d":"\#(b)"}"}]},"keptDisplayReadLit":1e-400}"#),
             "keptDisplayReadLit is 1e-400, which the app reads as a Float that is not 0 and rounds to 0, and throws\n", false),
            ("read twice", utf8(#"{"keptDisplayReadLit":0.8,"keptDisplayReadL\#(b)u0069t":0.8}"#),
             "view: the top level of state.json has keptDisplayReadLit more than once; the app reads the first, and so is it read here\n", true),
            ("boot read twice", utf8(#"{"keptDisplayUnderLowPowerBoot":"a","keptDisplayUnderLowPowerBoot":null}"#),
             "view: the top level of state.json has keptDisplayUnderLowPowerBoot more than once; the app reads the first, and so is it read here\n", true),
            ("zero forms", utf8(#"{"keptDisplayReadLit":-0,"keptDisplayUnderLowPower":0e-400}"#),
             "view: keptDisplayReadLit is written as -0, which plutil would write back as text the app reads as another Float; read here as -0.0\n", true),
            ("leading zero", utf8(#"{"keptDisplayReadLit":01}"#),
             "keptDisplayReadLit is written as 01, which is not a JSON number the app's decoder reads\n", false),
            ("any key read twice", utf8(#"{"sleepDisabledByUs":true,"sleepDisabledByUs":false}"#),
             "view: the top level of state.json has sleepDisabledByUs more than once; the app reads the first, and so is it read here\n", true),
            ("a nested key read twice", utf8(#"{"frozenProcesses":[{"pid":5,"p\#(b)u0069d":6}]}"#),
             "view: frozenProcesses[0] has pid more than once; the app reads the first, and so is it read here\n", true),
            ("a key twice in an object the app does not read", utf8(#"{"a":{"x":1,"x":2}}"#), "", true),
            ("a key twice in an object under an entry", utf8(#"{"frozenProcesses":[{"pid":1,"a":{"x":1,"x":2}}]}"#), "", true),
            ("a key the app does not read twice", utf8(#"{"a":1,"a":2,"frozenProcesses":[{"pid":1,"x":1,"x":2}]}"#), "", true),
            ("a key twice in an entry the app reads", utf8(#"{"savedAudioOutputs":[{"deviceUID":"a","volume":0.5,"muted":false,"device\#(b)u0055ID":"b"}]}"#),
             "view: savedAudioOutputs[0] has deviceUID more than once; the app reads the first, and so is it read here\n", true),
            ("an App Nap key twice", utf8(#"{"appNapOverrides":[{"bundleId":"a","previous":true,"previous":null}]}"#),
             "view: appNapOverrides[0] has previous more than once; the app reads the first, and so is it read here\n", true),
            ("an object under the record", utf8(#"{"sessionCutoffs":{"a":1,"a":2,"b":"\#(b)x41"}}"#),
             "record: sessionCutoffs is an object, which the app does not read as a record\n", true),
            ("a record twice", utf8(#"{"sessionCutoffs":"30 false","session\#(b)u0043utoffs":"0 true"}"#),
             "view: the top level of state.json has sessionCutoffs more than once; the app reads the first, and so is it read here\n", true),
            ("a record with a \\x escape", utf8(#"{"sessionCutoffs":"3\#(b)x30 false"}"#),
             "record: sessionCutoffs is a string the app does not read as a record\n", true),
            ("a record written as +1", utf8(#"{"sessionCutoffs":+1}"#),
             "sessionCutoffs is written as +1, which is not a JSON value the app's decoder reads\n", false),
            ("a record written as 1.", utf8(#"{"sessionCutoffs":1.}"#),
             "record: sessionCutoffs is written as 1., which the app does not read as a record\n", true),
            ("one key in two objects", utf8(#"{"a":{"x":1},"b":{"x":2}}"#), "", true),
            ("a Kelvin sign spelling a key twice", utf8("{\"saved\u{212A}eyboardBrightness\":\"bad\",\"savedKeyboardBrightness\":0.5}"),
             "view: the top level of state.json has savedKeyboardBrightness written as another key the app reads as savedKeyboardBrightness; read here as savedKeyboardBrightness\n"
                + "view: the top level of state.json has savedKeyboardBrightness more than once; the app reads the first, and so is it read here\n", false),
            ("an escaped Kelvin sign spelling a key twice", utf8(#"{"savedKeyboardBrightness":0.5,"saved\#(b)u212AeyboardBrightness":0.4}"#),
             "view: the top level of state.json has savedKeyboardBrightness more than once; the app reads the first, and so is it read here\n", true),
            ("commas before the ends inside", utf8(#"{"a":[1,2,],"b":{"c":1,}}"#), "", true),
            ("an Int32 too large", utf8(#"{"frozenProcesses":[{"pid":2147483648}]}"#),
             "frozenProcesses[0].pid is 2147483648, which the app's decoder does not read as a whole number it holds there\n", false),
            ("the ends of Int32 and Int64", utf8(#"{"frozenProcesses":[{"pid":-2147483648,"startedAt":9223372036854775807,"startedAtMicros":2147483647}]}"#), "", true),
            ("an Int64 too large", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":9223372036854775808}]}"#),
             "frozenProcesses[0].startedAt is 9223372036854775808, which the app's decoder does not read as a whole number it holds there\n", false),
            ("a legacy pid too small", utf8(#"{"frozenPids":[1,2,-2147483649]}"#),
             "frozenPids[2] is -2147483649, which the app's decoder does not read as a whole number it holds there\n", false),
            ("an output volume too large", utf8(#"{"savedAudioOutputs":[{"deviceUID":"a","volume":1e39,"muted":false}]}"#),
             "savedAudioOutputs[0].volume is 1e39, too large a number for the app's Float\n", false),
            ("a saved level written as 1.", utf8(#"{"savedOutputVolume":1.}"#),
             "savedOutputVolume is written as 1., which is not a JSON number the app's decoder reads\n", false),
            ("not a JSON number in an object the app does not read", utf8(#"{"note":{"a":+1}}"#),
             "note.a is written as +1, which is not a JSON value the app's decoder reads\n", false),
            ("single quotes in an array", utf8(#"{"note":['s']}"#),
             "note[0] is written as 's', which is not a JSON value the app's decoder reads\n", false),
            ("a \\x escape in a value the app reads", utf8(#"{"endedSession":"abc\#(b)x41"}"#),
             "endedSession is a string the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)\n", false),
            ("a \\x escape in a value the app does not read", utf8(#"{"note":"abc\#(b)x41"}"#), "", true),
            ("a \\x escape in a key the app does not read", utf8(#"{"note":{"\#(b)x41":1},"frozenProcesses":[{"pid":1,"y":{"\#(b)x41":"\#(b)'"}}]}"#), "", true),
            ("a \\x escape in a key of an entry the app reads", utf8(#"{"appNapOverrides":[{"bundleId":"a","\#(b)x41":1}]}"#),
             "a key in appNapOverrides[0] is text the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)\n", false),
            ("a \\x escape in a saved output's name", utf8(#"{"savedAudioOutputs":[{"deviceUID":"a","name":"\#(b)x41","volume":0.5,"muted":false}]}"#),
             "savedAudioOutputs[0].name is a string the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)\n", false),
            ("numbers the app skips", utf8(#"{"note":[1.,-.5,2.e3,1e-400,1-2],"frozenProcesses":[{"pid":1,"x":0.}]}"#), "", true),
            (".5 under a key the app does not read", utf8(#"{"frozenProcesses":[{"pid":1,"x":.5}]}"#),
             "frozenProcesses[0].x is written as .5, which is not a JSON value the app's decoder reads\n", false),
            ("a pid written as 1.0", utf8(#"{"frozenProcesses":[{"pid":5105.0,"startedAt":1.7e9,"startedAtMicros":25E4}]}"#),
             "view: frozenProcesses[0].pid is written as 5105.0, which the app reads as 5105; read here as 5105\n"
                + "view: frozenProcesses[0].startedAt is written as 1.7e9, which the app reads as 1700000000; read here as 1700000000\n"
                + "view: frozenProcesses[0].startedAtMicros is written as 25E4, which the app reads as 250000; read here as 250000\n", true),
            ("a pid that is not whole", utf8(#"{"frozenProcesses":[{"pid":5105.5}]}"#),
             "frozenProcesses[0].pid is 5105.5, which the app's decoder does not read as a whole number it holds there\n", false),
            ("whole numbers within Int32 written with a fraction or an exponent", utf8(#"{"frozenPids":[214748364.7e1,-2147483648.0,0e999,-0.0,100e-2]}"#),
             "view: frozenPids[0] is written as 214748364.7e1, which the app reads as 2147483647; read here as 2147483647\n"
                + "view: frozenPids[1] is written as -2147483648.0, which the app reads as -2147483648; read here as -2147483648\n"
                + "view: frozenPids[2] is written as 0e999, which the app reads as 0; read here as 0\n"
                + "view: frozenPids[3] is written as -0.0, which the app reads as 0; read here as 0\n"
                + "view: frozenPids[4] is written as 100e-2, which the app reads as 1; read here as 1\n", true),
            ("a whole number past Int32 written with an exponent", utf8(#"{"frozenPids":[21474836480e-1]}"#),
             "frozenPids[0] is 21474836480e-1, which the app's decoder does not read as a whole number it holds there\n", false),
            ("a startedAt up to 2^53 written with a fraction", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":9007199254740992.0}]}"#),
             "view: frozenProcesses[0].startedAt is written as 9007199254740992.0, which the app reads as 9007199254740992; read here as 9007199254740992\n", true),
            ("a startedAt of 1e18", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":1e18}]}"#),
             "view: frozenProcesses[0].startedAt is written as 1e18, which the app reads as 1000000000000000000; read here as 1000000000000000000\n", true),
            ("a startedAt of 2^62 written with a fraction", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":4611686018427387904.0},{"pid":2,"startedAt":-4611686018427387904.0}]}"#),
             "view: frozenProcesses[0].startedAt is written as 4611686018427387904.0, which the app reads as 4611686018427387904; read here as 4611686018427387904\n"
                + "view: frozenProcesses[1].startedAt is written as -4611686018427387904.0, which the app reads as -4611686018427387904; read here as -4611686018427387904\n", true),
            ("a startedAt a Double does not hold, written with a fraction", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":9007199254740993.0}]}"#),
             "view: frozenProcesses[0].startedAt is written as 9007199254740993.0, which the app reads as 9007199254740993; read here as 9007199254740993\n", true),
            ("the lowest Int64 written with a fraction", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":-9223372036854775808.0}]}"#),
             "frozenProcesses[0].startedAt is -9223372036854775808.0, which the app's decoder does not read as a whole number it holds there\n", false),
            ("startedAtMicros past Int32, no startedAt", utf8(#"{"frozenProcesses":[{"pid":1,"startedAtMicros":2147483648}]}"#), "", true),
            ("startedAtMicros past Int32 after a null startedAt", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":null,"startedAtMicros":2147483648}]}"#), "", true),
            ("startedAtMicros past Int32 after a startedAt", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":5,"startedAtMicros":2147483648}]}"#),
             "frozenProcesses[0].startedAtMicros is 2147483648, which the app's decoder does not read as a whole number it holds there\n", false),
            ("startedAtMicros past Int32 before a startedAt", utf8(#"{"frozenProcesses":[{"pid":1,"startedAtMicros":2147483648,"startedAt":5}]}"#),
             "frozenProcesses[0].startedAtMicros is 2147483648, which the app's decoder does not read as a whole number it holds there\n", false),
            ("startedAtMicros past Int32 in the second entry only", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":5,"startedAtMicros":1,"bootSession":"b"},{"pid":2,"startedAtMicros":2147483648}]}"#), "", true),
            ("a \\x escape in bootSession, no startedAtMicros", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":5,"bootSession":"\#(b)x41"}]}"#),
             "view: frozenProcesses[0].bootSession, which the app does not read there, is a string the app would not read; left out\n", true),
            ("a \\x escape in bootSession of an identity", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":5,"startedAtMicros":0,"bootSession":"\#(b)x41"}]}"#),
             "frozenProcesses[0].bootSession is a string the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)\n", false),
            ("startedAtMicros written as +1, no startedAt", utf8(#"{"frozenProcesses":[{"pid":1,"startedAtMicros":+1}]}"#),
             "frozenProcesses[0].startedAtMicros is written as +1, which is not a JSON value the app's decoder reads\n", false),
            ("startedAtMicros twice, no startedAt", utf8(#"{"frozenProcesses":[{"pid":1,"startedAtMicros":1,"startedAtMicros":2}]}"#),
             "view: frozenProcesses[0] has startedAtMicros more than once; the app reads the first, and so is it read here\n", true),
            ("startedAtMicros twice in an identity", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":5,"startedAtMicros":1,"startedAtMicros":2,"bootSession":"b"}]}"#),
             "view: frozenProcesses[0] has startedAtMicros more than once; the app reads the first, and so is it read here\n", true),
            ("a pid a Double rounds to whole", utf8(#"{"frozenProcesses":[{"pid":1.0000000000000001}]}"#),
             "view: frozenProcesses[0].pid is written as 1.0000000000000001, which the app reads as 1; read here as 1\n", true),
            // A Double rounds this one to 0.
            ("a pid with a very small exponent", utf8(#"{"frozenPids":[1e-99999]}"#),
             "view: frozenPids[0] is written as 1e-99999, which the app reads as 0; read here as 0\n", true),
        ]
        try checkRecordReader(cases)
    }

    /// Runs the reader of each script over each text (`recordTextProblems`)
    /// and checks what it prints, the view it writes, and the app's decoder
    /// on the same bytes. Both scripts print the same and write the same
    /// view. A view is written exactly when the reader prints nothing or
    /// only "view: " and "record: " lines, and the app decodes it to the
    /// state it decodes from the text, bit for bit (each Float too, as the
    /// app's encoder writes it). A view that holds U+E000 for \u0000
    /// (json_nul_mark) is checked as every journal published from it is
    /// (journal_candidate_ok): each U+E000 put back as \u0000.
    private func checkRecordReader(_ cases: [(label: String, bytes: Data, prints: String, appReads: Bool)]) throws {
        let b = backslash
        let printed = try recordTextProblems(cases.map { ($0.label, $0.bytes) })
        let printedByUninstall = try recordTextProblems(cases.map { ($0.label, $0.bytes) }, script: "uninstall.sh")
        for c in cases {
            let backstop = try XCTUnwrap(printed[c.label], c.label)
            let uninstall = try XCTUnwrap(printedByUninstall[c.label], c.label)
            XCTAssertEqual(backstop.printed, c.prints, c.label)
            XCTAssertEqual(uninstall.printed, c.prints, c.label)
            XCTAssertEqual(uninstall.view, backstop.view, c.label)
            let app = try? Store.makeDecoder().decode(RuntimeState.self, from: c.bytes)
            XCTAssertEqual(app != nil, c.appReads, "the app's decoder on \(c.label)")
            let onlyViewLines = c.prints.split(separator: "\n").allSatisfy { $0.hasPrefix("view: ") || $0.hasPrefix("record: ") }
            XCTAssertEqual(backstop.view != nil, onlyViewLines, "a view for \(c.label)")
            if var view = backstop.view {
                if c.prints.contains("written in the view as U+E000") {
                    view = Data(String(decoding: view, as: UTF8.self).replacingOccurrences(of: "\(b)uE000", with: "\(b)u0000").utf8)
                }
                let read = try? Store.makeDecoder().decode(RuntimeState.self, from: view)
                XCTAssertEqual(read, app, "the app reads the view of \(c.label) as the text")
                XCTAssertEqual(try read.map { try Store.makeEncoder().encode($0) }, try app.map { try Store.makeEncoder().encode($0) }, "the view of \(c.label), bit for bit")
            }
        }
    }

    /// Review35 R35-1: the reader over Floats and NULs, as
    /// checkRecordReader checks it. A Float plutil would write back as text
    /// the app reads as another Float (it reads up to 17 digits through a
    /// Double and up to 38 through a Decimal, and "-0" as the whole number
    /// 0) is held in the view as the same Float in 9 digits, -0 as -0.0;
    /// one plutil keeps stays as written. A NUL byte in text the app skips,
    /// which plutil does not read, is left out of the view; one the app
    /// refuses (in a string it reads, between values) is refused. A string
    /// the app reads that holds \u0000, which plutil cannot hold, is held
    /// in the view with U+E000 for each \u0000 (json_nul_mark); after
    /// escaped backslashes too, in each place the app reads a string: an
    /// audio output, an App Nap entry, the kept record's boot, a frozen
    /// process's bootSession, endedSession. Where the app does not read the
    /// string, or reads it as no record, it goes as any such string. The
    /// texts the app loads that the reader refuses, its kept residual
    /// cost: such a string longer than 1024 bytes, as bash takes time that
    /// grows with the square of the length to mark it, and a journal that
    /// holds U+E000 as well, raw or as an escape, which the view could not
    /// tell from a mark. U+E000 alone passes.
    func testTheRecordReaderKeepsFloatsAndNULsAsTheAppReadsThem() throws {
        let b = backslash
        func utf8(_ s: String) -> Data { Data(s.utf8) }
        // The line for a string the app reads that holds \u0000.
        func marked(_ shown: String) -> String {
            "view: \(shown) holds \(b)u0000, which plutil cannot hold; written in the view as U+E000 (\(b)uE000), which each journal published from it writes back as \(b)u0000\n"
        }
        let markRefused = "state.json holds \(b)u0000 where the app reads it, which the view writes as U+E000, and U+E000 as well, so what the app reads is not known here\n"
        let skippedNUL = "view: state.json holds a NUL byte in text the app skips, which plutil does not read; left out\n"
        let cases: [(label: String, bytes: Data, prints: String, appReads: Bool)] = [
            ("NUL byte in a key the app skips", utf8("{\"a\":{\"x\u{0}\":1}}"), skippedNUL, true),
            ("NUL byte in a string the app reads", utf8("{\"appNapOverrides\":[{\"bundleId\":\"a\u{0}b\"}]}"),
             "appNapOverrides[0].bundleId is a string the app's decoder does not read (a control character, bytes that are not UTF-8, an escape JSON does not have, or a lone surrogate)\n", false),
            ("NUL byte between values", utf8("{\"a\":1,\u{0}\"b\":2}"), "the text of state.json is not JSON the app's decoder reads\n", false),
            ("\\u0000 in a device UID", utf8(#"{"savedAudioOutputs":[{"deviceUID":"a\#(b)u0000b","volume":0.5,"muted":false}]}"#),
             marked("savedAudioOutputs[0].deviceUID"), true),
            ("\\u0000 after escaped backslashes", utf8(#"{"appNapOverrides":[{"bundleId":"a\#(b)\#(b)u0000\#(b)\#(b)\#(b)u0000"}]}"#),
             marked("appNapOverrides[0].bundleId"), true),
            ("\\u0000 in the kept record's boot", utf8(#"{"keptDisplayUnderLowPower":0.8,"keptDisplayUnderLowPowerBoot":"\#(b)u0000"}"#),
             marked("keptDisplayUnderLowPowerBoot"), true),
            ("\\u0000 in a bootSession", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":5,"startedAtMicros":0,"bootSession":"b\#(b)u0000"}]}"#),
             marked("frozenProcesses[0].bootSession"), true),
            ("\\u0000 in a bootSession the app does not read", utf8(#"{"frozenProcesses":[{"pid":1,"startedAt":5,"bootSession":"b\#(b)u0000"}]}"#),
             "view: frozenProcesses[0].bootSession, which the app does not read there, is a string the app would not read; left out\n", true),
            ("\\u0000 in an endedSession", utf8(#"{"endedSession":"e\#(b)u0000"}"#), marked("endedSession"), true),
            ("\\u0000 in a record", utf8(#"{"sessionCutoffs":"30\#(b)u0000 false"}"#),
             "record: sessionCutoffs is a string the app does not read as a record\n", true),
            ("\\u0000 where the app does not read it", utf8(#"{"note":"\#(b)u0000","appNapOverrides":[{"bundleId":"a","a\#(b)u0000":1}]}"#), "", true),
            ("U+E000 without \\u0000", utf8("{\"appNapOverrides\":[{\"bundleId\":\"\u{E000}\"}],\"note\":\"\(b)uE000\"}"), "", true),
            ("\\u0000 and U+E000", utf8("{\"appNapOverrides\":[{\"bundleId\":\"a\(b)u0000\"},{\"bundleId\":\"\u{E000}\"}]}"),
             marked("appNapOverrides[0].bundleId") + markRefused, true),
            ("\\u0000 and U+E000 as an escape", utf8(#"{"appNapOverrides":[{"bundleId":"a\#(b)u0000"}],"note":"\#(b)ue000"}"#),
             marked("appNapOverrides[0].bundleId") + markRefused, true),
            ("\\u0000 in a string longer than 1024 bytes",
             utf8(#"{"savedAudioOutputs":[{"deviceUID":"a","name":""# + String(repeating: "n", count: 1100) + #"\#(b)u0000","volume":0.5,"muted":false}]}"#),
             "savedAudioOutputs[0].name holds \(b)u0000, which the app reads and plutil does not; not read here\n", true),
            ("a Float plutil would write back as another", utf8(#"{"keptDisplayReadLit":0.5000000298023223876953125000000000000001}"#),
             "view: keptDisplayReadLit is written as 0.50000002980232238769531250000000000000, which plutil would write back as text the app reads as another Float; read here as 0.50000006\n", true),
            ("a Float at the midpoint of two", utf8(#"{"keptDisplayReadLit":0.5000000298023223876953125}"#),
             "view: keptDisplayReadLit is written as 0.5000000298023223876953125, which plutil would write back as text the app reads as another Float; read here as 0.5\n", true),
            ("negative zero Floats", utf8(#"{"keptDisplayReadLit":-0,"savedDisplayBrightness":-0.0}"#),
             "view: keptDisplayReadLit is written as -0, which plutil would write back as text the app reads as another Float; read here as -0.0\n", true),
            ("a Float plutil keeps", utf8(#"{"keptDisplayReadLit":0.30000001192092896}"#), "", true),
        ]
        try checkRecordReader(cases)
    }

    /// A journal the app loads whose Floats plutil would write back as
    /// others, or whose strings the app reads hold \u0000, what a backstop
    /// run over it calls and exits with, and what the journal it publishes
    /// holds afterwards. `ending` journals go with a valid session whose
    /// end is recorded in the journal.
    private typealias PublishedJournalRow = (label: String, journal: String, ending: Bool, status: Int32,
                                             calls: (ScriptFixture) -> [String], undone: (inout RuntimeState, ScriptFixture) throws -> Void)

    private static func publishedJournalRows() -> [PublishedJournalRow] {
        let lit = "0.5000000298023223876953125000000000000001"
        let mid = "0.50000002980232238769531250"
        let above = "0.500000059604644775390625"
        let sleepOff = { (f: ScriptFixture) in "sudo -n \(f.fakePmset) -a disablesleep 0" }
        let lowPowerOff = { (f: ScriptFixture) in "sudo -n \(f.fakePmset) -b lowpowermode 0" }
        return [
            ("Floats plutil would write back as others",
             #"{"sleepDisabledByUs":true,"savedOutputVolume":0.50000002980232239,"savedDisplayBrightness":\#(lit),"savedKeyboardBrightness":0.500000029802322387695312500000000001,"displayRestoredUnderLowPower":\#(mid),"displayRestoreRefused":true,"keyboardRestoreRefused":true,"keptDisplayUnderLowPower":\#(above),"keptDisplayUnderLowPowerBoot":"boot-private","keptDisplayReadLit":0.5000000298023223876953125000000000000000000000000000001}"#,
             false, 1, { [sleepOff($0)] }, { s, _ in s.sleepDisabledByUs = false }),
            ("-0 through four edits, with Low Power Mode",
             #"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"dockerFrozen":true,"frozenProcesses":[{"pid":4343,"startedAt":1760000001}],"savedAudioOutputs":[{"deviceUID":"u\u0000","volume":-0,"muted":true}],"savedOutputVolume":-0.0,"savedDisplayBrightness":-0,"displayRestoreRefused":true,"keptDisplayUnderLowPower":-0e0,"keptDisplayUnderLowPowerBoot":"boot\u0000","keptDisplayReadLit":-0,"appNapOverrides":[{"bundleId":"com.example.y","previous":false}]}"#,
             false, 1, { [sleepOff($0), lowPowerOff($0), "defaults write com.example.y NSAppSleepDisabled -bool false"] },
             { s, f in s.sleepDisabledByUs = false; s.lowPowerSetByUs = false; s.keptDisplayUnderLowPowerBoot = f.bootUUID; s.appNapOverrides = [] }),
            ("\\u0000 in each string the app reads",
             #"{"sleepDisabledByUs":true,"savedAudioOutputs":[{"deviceUID":"u\u0000id","name":"n\u0000\\u0000","volume":\#(lit),"muted":true,"saveID":"\u0000"}],"keptDisplayUnderLowPowerBoot":"k\u0000","frozenProcesses":[{"pid":4242,"startedAt":1760000000,"startedAtMicros":5,"bootSession":"b\u0000"},{"pid":4343,"startedAt":1760000001,"bootSession":"c\u0000"}],"appNapOverrides":[{"bundleId":"com.example\u0000x","previous":true},{"bundleId":"com.example.y","previous":false}]}"#,
             false, 1, { [sleepOff($0), "defaults write com.example.y NSAppSleepDisabled -bool false"] },
             { s, _ in s.sleepDisabledByUs = false; s.frozenProcesses.removeFirst(); s.appNapOverrides.removeLast() }),
            ("\\u0000 in the kept display entry's boot, with Low Power Mode",
             #"{"sleepDisabledByUs":true,"lowPowerSetByUs":true,"savedDisplayBrightness":\#(above),"displayRestoreRefused":true,"keptDisplayUnderLowPower":\#(above),"keptDisplayUnderLowPowerBoot":"boot\u0000","keptDisplayReadLit":\#(above)}"#,
             false, 0, { [sleepOff($0), lowPowerOff($0)] },
             { s, f in s.sleepDisabledByUs = false; s.lowPowerSetByUs = false; s.keptDisplayUnderLowPowerBoot = f.bootUUID }),
            ("\\u0000 in endedSession, the end recorded in the journal",
             #"{"sleepDisabledByUs":true,"endedSession":"e\u0000","savedDisplayBrightness":\#(lit),"displayRestoreRefused":true,"keptDisplayUnderLowPower":\#(above),"keptDisplayUnderLowPowerBoot":"boot-private","keptDisplayReadLit":\#(above)}"#,
             true, 1, { [sleepOff($0)] },
             { s, f in s.sleepDisabledByUs = false; s.endedSession = try Data(contentsOf: f.session).base64EncodedString() }),
        ]
    }

    /// Review35 R35-1, past the reader: whole backstop runs on journals the
    /// app loads whose Floats plutil would write back as others (38 digits,
    /// the midpoint of two Floats and digits beside it, -0 in each
    /// spelling) and whose strings the app reads hold \u0000. Each journal
    /// the run publishes (the end record in the journal, the kept display
    /// entry's record given this boot before Low Power Mode goes off, the
    /// undo at the end, which can take four edits) decodes, bit for bit, to
    /// what the app read before, but for what the run undid or recorded:
    /// sleep, Low Power Mode, a frozen process of another boot, an App Nap
    /// entry restored, this boot, the end. An App Nap entry whose bundle id
    /// holds \u0000 is kept with no defaults call, and nothing is left
    /// beside the journal.
    func testPublishedJournalsKeepTheFloatsAndStringsTheAppReads() async throws {
        let rows = Self.publishedJournalRows()
        // One fixture per journal; the runs go several at a time.
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for row in rows {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.writeState(row.journal)
            if row.ending {
                // session.json, with the app gone, cannot be removed, and
                // ended-session.json holds a record that cannot be replaced.
                try f.writeSession(endsAt: Date(timeIntervalSinceNow: 3600))
                try setImmutable(f.session, true)
                try "{}".write(to: f.endedSession, atomically: true, encoding: .utf8)
                try setImmutable(f.endedSession, true)
            }
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })

        for (row, (f, r)) in zip(rows, zip(fixtures, results)) {
            let before = try Store.makeDecoder().decode(RuntimeState.self, from: Data(row.journal.utf8))
            XCTAssertEqual(r.status, row.status, row.label + r.stderr + f.log())
            XCTAssertEqual(f.calls().filter { call in ["sudo", "defaults", "kill"].contains { call.hasPrefix($0 + " ") } }, row.calls(f), row.label)
            XCTAssertFalse(f.log().contains("could not publish"), "\(row.label): \(f.log())")
            XCTAssertEqual(try f.contents(of: f.home).filter { $0.hasPrefix(".state.json") }, [], row.label)
            let published = try Data(contentsOf: f.state)
            let text = String(decoding: published, as: UTF8.self)
            XCTAssertFalse(text.contains("\u{E000}") || text.lowercased().contains("\(backslash)ue000") || text.contains("\u{0}"), "\(row.label): \(text)")
            var expected = before
            try row.undone(&expected, f)
            let after = try Store.makeDecoder().decode(RuntimeState.self, from: published)
            XCTAssertEqual(after, expected, "\(row.label): \(text)")
            XCTAssertEqual(try Store.makeEncoder().encode(after), try Store.makeEncoder().encode(expected), "\(row.label), bit for bit: \(text)")
        }
    }

    /// Review35 R35-1, the same journals through uninstall.sh, which
    /// publishes a journal only through the backstop it runs. Each
    /// uninstall undoes what the backstop alone undoes, exits as it does,
    /// and leaves a journal that decodes, bit for bit, to the same. Where
    /// an entry only the app restores stays, the uninstall stops with the
    /// app, the agent and the sudoers rule in place; where only the kept
    /// display entry stays, it removes them. Every row but the one that
    /// records a session's end in the journal, which needs a valid session.
    /// The runs go several at a time, one fixture each.
    func testAnUninstallPublishesTheFloatsAndStringsTheAppReads() async throws {
        let rows = Self.publishedJournalRows().filter { !$0.ending }
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for row in rows {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(row.journal)
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.uninstall) })

        for (row, (f, r)) in zip(rows, zip(fixtures, results)) {
            let label = "\(row.label): \(r.stdout) \(r.stderr) \(f.log())"
            XCTAssertEqual(r.status, row.status, label)
            XCTAssertFalse(r.stderr.contains("malformed") || f.log().contains("malformed"), label)
            XCTAssertFalse(f.log().contains("could not publish"), label)
            let undoing = f.calls().filter { call in ["sudo -n ", "defaults write ", "defaults delete ", "kill "].contains { call.hasPrefix($0) } }
            XCTAssertEqual(undoing, row.calls(f), label)
            for url in [f.app, f.plist, f.sudoers] {
                XCTAssertEqual(f.exists(url), row.status != 0, "\(url.lastPathComponent): \(label)")
            }
            XCTAssertEqual(try f.contents(of: f.home).filter { $0.hasPrefix(".state.json") }, [], row.label)
            let published = try Data(contentsOf: f.state)
            let text = String(decoding: published, as: UTF8.self)
            XCTAssertFalse(text.contains("\u{E000}") || text.lowercased().contains("\(backslash)ue000") || text.contains("\u{0}"), "\(row.label): \(text)")
            var expected = try Store.makeDecoder().decode(RuntimeState.self, from: Data(row.journal.utf8))
            try row.undone(&expected, f)
            let after = try Store.makeDecoder().decode(RuntimeState.self, from: published)
            XCTAssertEqual(after, expected, "\(row.label): \(text)")
            XCTAssertEqual(try Store.makeEncoder().encode(after), try Store.makeEncoder().encode(expected), "\(row.label), bit for bit: \(text)")
        }
    }

    /// The same records in a form the app reads do not stop the uninstall:
    /// it completes past the kept entry, and state.json stays byte for byte
    /// with them, even with --purge.
    func testUninstallCompletesPastValidKeptDisplayRecordsAndKeepsThem() async throws {
        // One fixture per journal; the runs go several at a time.
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for records in Self.validKeptDisplayRecords {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.installMachinery()
            try f.writeConfig(#"{"agentList":[]}"#)
            try f.writeState(Self.keptDisplayJournal(records, ours: false))
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.uninstall, ["--purge"]) })

        for (records, (f, r)) in zip(Self.validKeptDisplayRecords, zip(fixtures, results)) {
            let json = Self.keptDisplayJournal(records, ours: false)
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

    /// On `f`, or on `fx` when nil.
    private func writeMicrosecondEntry(pid: Int, started: Int, micros: Int, boot: String? = nil, extra: String = "", on f: ScriptFixture? = nil) throws {
        let target: ScriptFixture = f ?? fx
        try target.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try target.writeState("""
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[{"pid":\(pid),"startedAt":\(started),"startedAtMicros":\(micros),"bootSession":"\(boot ?? target.bootUUID)"\(extra)}]}
        """)
    }

    private func onlyFrozenEntry(on f: ScriptFixture? = nil) throws -> [String: Any]? {
        let target: ScriptFixture = f ?? fx
        return (try target.stateJSON()["frozenProcesses"] as? [[String: Any]])?.first
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

    /// The same entry with each whole number written with a fraction or an
    /// exponent (5100.0, 1.789388423e9, 654321.0), which the app reads as
    /// those numbers: the binary gets the same line, digits alone
    /// (extract_whole). The control is a pid that is not whole (5100.5),
    /// which the app does not load: the journal is refused, nothing runs
    /// and the file is kept.
    func testWholeNumbersWrittenWithAFractionReachTheBinaryAsDigits() throws {
        let started = 1_789_388_423
        let json = """
        {"sleepDisabledByUs":false,"lowPowerSetByUs":false,"dockerFrozen":true,
         "frozenProcesses":[{"pid":5100.0,"startedAt":1.789388423e9,"startedAtMicros":654321.0,"bootSession":"\(fx.bootUUID)"}]}
        """
        let entry = try XCTUnwrap(try Store.decodeState(Data(json.utf8)).frozenProcesses.first)
        XCTAssertEqual(entry.pid, 5100)
        XCTAssertEqual(entry.identity, ProcessIdentity(startedAt: Int64(started), startedAtMicros: 654_321, bootSession: fx.bootUUID))
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(json)
        try fx.psTable([(5100, fx.lstart(started), "T", fx.uid)])

        let r = try fx.run(fx.backstop)

        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(fx.calls(), ["Insomnia --resume-frozen 2 < 5100 \(started) 654321 \(fx.bootUUID)"])
        XCTAssertEqual((try fx.stateJSON()["frozenProcesses"] as? [Any])?.count, 0)

        fx.destroy()
        fx = try ScriptFixture()
        let half = json.replacingOccurrences(of: "5100.0", with: "5100.5")
        XCTAssertThrowsError(try Store.decodeState(Data(half.utf8)))
        try fx.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        try fx.writeState(half)
        try fx.psTable([(5100, fx.lstart(started), "T", fx.uid)])

        let refused = try fx.run(fx.backstop)

        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(fx.calls(), [])
        XCTAssertEqual(try String(contentsOf: fx.state, encoding: .utf8), half)
        XCTAssertTrue(fx.log().contains("frozenProcesses[0].pid is 5100.5, which the app's decoder does not read as a whole number it holds there"), fx.log())
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
    /// is kept, nothing is signaled, and the log carries the answer. Each
    /// answer runs on a fixture of its own, several at a time.
    func testUnexpectedAppBinaryAnswerKeepsTheEntry() async throws {
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
        // One fixture per answer; the runs go several at a time.
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        for (output, status) in cases {
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try writeMicrosecondEntry(pid: 5105, started: 1_789_388_423, micros: 2, on: f)
            try f.insomniaRaw(output, status: status)
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })

        for ((output, status), (f, r)) in zip(cases, zip(fixtures, results)) {
            let label = "\(output.debugDescription) exit \(status)"
            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertEqual(f.calls().filter { !$0.hasPrefix("Insomnia --resume-frozen") }, [], label)
            XCTAssertEqual(try onlyFrozenEntry(on: f)?["pid"] as? Int, 5105, label)
            XCTAssertEqual(try f.stateJSON()["dockerFrozen"] as? Bool, true, label)
            XCTAssertTrue(f.exists(f.session), label)
            XCTAssertTrue(f.log().contains("unexpected answer from \(f.fakeInsomnia.path) for pid(s) 5105 (exit \(status), output '"), "\(label): \(f.log())")
        }
        // Control characters are logged as spaces, on one line.
        let last = try XCTUnwrap(fixtures.last)
        XCTAssertTrue(last.log().contains("output '05105 resumed '"), last.log())
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
        XCTAssertEqual(shell.signal(SIGKILL), 0)
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            XCTAssertEqual(shell.signalGroup(sig), 0, "signal \(sig)")
        }
        let status = shell.wait()
        XCTAssertEqual(status & 0x7f, SIGKILL, "the backstop did not end by SIGKILL (wait status \(status))")

        XCTAssertTrue(waitUntil(15) { self.fx.calls().filter { $0 == "sudo SIGTERM" }.count == 2 },
                      "one SIGTERM from the group, one from the supervisor at the limit: \(fx.calls())")
        XCTAssertTrue(waitUntil(10) { self.statusLines() == ["alive"] }, "the supervisor reached the end of the grace: \(self.statusLines())")
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGTERM" }.count, 2, "\(fx.calls())")
        XCTAssertEqual(fx.calls().filter { $0 == "sudo SIGHUP" }.count, 1, "\(fx.calls())")
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
            try pastedWords(of: printedCommand(in: stopped.stderr, containing: "backstop.sh")),
            ["/bin/bash", checkout.appendingPathComponent("scripts/backstop.sh").path, "--force"],
            "the manual recovery runs the checkout's backstop.sh"
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
        let visudo = try XCTUnwrap(calls.firstIndex { $0.hasPrefix("sudo visudo") }, "\(calls)")
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
        let visudo = try XCTUnwrap(calls.first { $0.hasPrefix("sudo visudo -cf ") }, "\(calls)")
        XCTAssertTrue(calls.contains("rm -f \(visudo.dropFirst("sudo visudo -cf ".count))"), "the sudoers candidate, on exit: \(calls)")
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

    /// The rule verified before the recovery lock is gone once this run
    /// holds it, as after an uninstall.sh that took the lock first. The
    /// recovery would pass without a journal, so the run checks the rule
    /// again under the lock and stops before touching the previous pair.
    func testInstallStopsWhenTheSudoersRuleIsGoneOnceItHoldsTheLock() throws {
        try writePreviousPair()
        fx.setMode("sudo", "rule-gone-under-lock")

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

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
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "TMPDIR": tmp.path])
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
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])
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
        XCTAssertFalse(calls.contains { $0.hasPrefix("pgrep") || $0.hasPrefix("osascript") || $0.hasPrefix("launchctl") }, "\(calls)")
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
        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester", "PATH": try fx.slowPollingPath()])
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

        let r = try fx.run(fx.installRedirected, extraEnvironment: ["USER": "tester"])

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
    /// installRedirected with a 1 s limit for each bounded call.
    var session: URL { home.appendingPathComponent("session.json") }
    var endedSession: URL { home.appendingPathComponent("ended-session.json") }
    var state: URL { home.appendingPathComponent("state.json") }
    var config: URL { home.appendingPathComponent("config.json") }
    var lock: URL { home.appendingPathComponent(".recovery.lock") }
    /// Every run's TMPDIR (childEnvironment): uninstall.sh's scratch folder
    /// goes here, inside the fixture, not in the shared /tmp.
    var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var alive: URL { home.appendingPathComponent(".app.alive") }
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
        for dir in [home, bin, repoScripts, appsDir, tmp] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
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
        // A test that failed before clearing the flag must not leave its
        // temp home behind.
        for file in [session, endedSession, state] { try? setImmutable(file, false) }
        try? fm.removeItem(at: root)
    }

    /// The backstop's files in INSOMNIA_HOME: each bounded call's .pid and
    /// .rc status files, each read's .out file, and the app binary's input
    /// and answer directory.
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

    /// Whether the read a fake recorded in read.hung.pid is gone: stopped
    /// and reaped, so the pid names no process. False when no fake wrote it.
    func hungReadIsGone() -> Bool {
        guard let text = try? String(contentsOf: root.appendingPathComponent("read.hung.pid"), encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == -1 && errno == ESRCH
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
            "NOTIFYUTIL": bin.appendingPathComponent("notifyutil").path,
            "IOREG": bin.appendingPathComponent("ioreg").path,
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
            "LOCK_TIMEOUT_SECONDS": "1",
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
            "LOCK_TIMEOUT_SECONDS": "1",
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
    /// `resumeFrozenVersion` as an integer, or without the key when nil,
    /// and InsomniaAgentCutoffsVersion set to `agentCutoffsVersion` the
    /// same way.
    static func infoPlist(resumeFrozenVersion: String?, agentCutoffsVersion: String? = "\(AgentCutoffsCommand.version)") -> String {
        BuiltApp.infoPlist(resumeFrozenVersion: resumeFrozenVersion, agentCutoffsVersion: agentCutoffsVersion)
    }

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
        // installed, but `sudo -n -l <pmset ...>` still says no. Mode
        // "rule-gone-under-lock": `sudo -n -l` says yes while nobody holds
        // the recovery lock and no while someone does, the way a rule removed
        // by an uninstall.sh that held the lock first answers to a run that
        // then takes it. In mode "rule-check-hangs" `sudo -n -l` never
        // answers and ignores SIGTERM; in "rule-check-hangs-under-lock" it
        // never answers while the lock is held and stops on SIGTERM; in
        // "rule-check-ignores-term-under-lock" it never answers while the
        // lock is held and ignores SIGTERM (see sudoHangHere).
        // visudo checks the candidate file exists, is non-empty and grants
        // pmset, so an installer that validated the wrong path or an empty
        // heredoc cannot pass here.
        try writeFake("sudo", """
        printf 'sudo %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/sudo.mode" 2>/dev/null || echo ok)"
        \(sudoHangHere())
        \(lockHeldHere())
        # "ignore-term" and "closes-fd9" behave like a pmset that ignores
        # SIGTERM: they live until the test creates the release file (or the
        # fixture is destroyed, or a 60 s wall-clock watchdog), so a test decides when
        # the command ends instead of racing a wall-clock sleep. On exit they
        # write command.ended = released | watchdog, so a test can tell a
        # command that is still alive (no file) from one that ended, and why.
        case "${1:-}" in
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
                # "drops-fd9-logs-signals": like "logs-term", after closing
                # its fd 9 the way sudo does, and every SIGHUP it gets is
                # logged as "sudo SIGHUP".
                drops-fd9-logs-signals) exec 9<&-; trap 'echo "sudo SIGHUP" >> "\(calls)"' HUP; hang_on_term ignore ;;
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
            case "$dst" in "\(r)"/*) /bin/mkdir -p "$(dirname "$dst")"; /bin/cp "$src" "$dst"; exit 0 ;; esac
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
        // output; "HANG": never returns, after writing its pid to
        // read.hung.pid and the names of the backstop's files it sees to
        // read.files), else a MacBook on AC power at 100%. Any other direct
        // call is recorded as DIRECT and fails: power changes go through sudo.
        try writeFake("pmset", """
        if [[ "${1:-}" == -g && "${2:-}" == batt ]]; then
          printf 'pmset -g batt\\n' >> "\(calls)"
          if [[ -f "\(r)/pmset.batt" ]]; then
            [[ "$(cat "\(r)/pmset.batt")" == FAIL ]] && exit 1
            if [[ "$(cat "\(r)/pmset.batt")" == HANG ]]; then
              echo $$ > "\(r)/read.hung.pid"
              /bin/ls -A "\(home.path)" | /usr/bin/grep '^\\.backstop\\.' > "\(r)/read.files" || true
              exec /bin/sleep 60
            fi
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
        // "IGNORE_TERM": never returns and ignores SIGTERM, after writing its
        // pid to read.hung.pid; it leaves a child behind that would keep any
        // descriptor it inherited. "CHECK_FD9": records whether it has fd 9
        // open, by its own descriptor table and by lsof, then prints level 0.
        // lsof can take seconds on a busy machine, so a test using it raises
        // the time limit (setCommandTimeout).
        try writeFake("notifyutil", """
        printf 'notifyutil %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/thermal.mode" 2>/dev/null || echo 0)"
        [[ "$mode" == FAIL ]] && exit 1
        [[ "$mode" == HANG ]] && exec /bin/sleep 60
        if [[ "$mode" == IGNORE_TERM ]]; then
          trap '' TERM
          echo $$ > "\(r)/read.hung.pid"
          /bin/sleep 5 </dev/null >/dev/null 2>&1 &
          exec /bin/sleep 60
        fi
        if [[ "$mode" == CHECK_FD9 ]]; then
          [[ -e /dev/fd/9 ]] && printf 'notifyutil had fd 9\\n' >> "\(calls)"
          [[ -n "$(/usr/sbin/lsof -a -p "$$" -d 9 -t 2>/dev/null)" ]] && printf 'notifyutil lsof had fd 9\\n' >> "\(calls)"
          printf 'notifyutil checked fd 9\\n' >> "\(calls)"
          echo "${2:-} 0"; exit 0
        fi
        [[ "$mode" == GARBAGE ]] && { echo "something unexpected"; exit 0; }
        echo "${2:-} $mode"
        """)
        // ioreg -r -c AppleSmartBattery -d 1, by battery_service.mode.
        // "NONE" (the default): no service, so nothing is printed. "BATTERY":
        // the service, on battery power. "BATTERY_AC": the service with a
        // charger. "BATTERY_NOKEY": the service without ExternalConnected.
        // "FAIL": exit 1. "HANG": never returns.
        try writeFake("ioreg", """
        printf 'ioreg %s\\n' "$*" >> "\(calls)"
        mode="$(cat "\(r)/battery_service.mode" 2>/dev/null || echo NONE)"
        case "$mode" in
          FAIL) exit 1 ;;
          HANG) exec /bin/sleep 60 ;;
          NONE) exit 0 ;;
        esac
        echo '+-o AppleSmartBattery  <class AppleSmartBattery, id 0x100000a1b, registered, matched, active, busy 0 (25 ms), retain 9>'
        echo '    {'
        echo '      "AppleRawExternalConnected" = No'
        case "$mode" in
          BATTERY) echo '      "ExternalConnected" = No' ;;
          BATTERY_AC) echo '      "ExternalConnected" = Yes' ;;
        esac
        echo '      "BatteryInstalled" = Yes'
        echo '    }'
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
        // real so the modes still change. A path listed in chmod.fail fails
        // the way an immutable file does.
        try writeFake("chmod", """
        printf 'chmod %s\\n' "$*" >> "\(r)/chmod.calls"
        if [[ -f "\(r)/chmod.fail" ]] && grep -qxF -- "${2:-}" "\(r)/chmod.fail"; then
          echo "chmod: ${2:-}: Operation not permitted" >&2
          exit 1
        fi
        exec /bin/chmod "$@"
        """)
        // Insomnia --agent-cutoffs and --agent-session-cutoffs: this build's
        // own binary, unrecorded, so config.json and the journal's cutoffs
        // are read by the app's decoder as in production.
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
        [[ "${1:-}" == --agent-cutoffs || "${1:-}" == --agent-session-cutoffs ]] && exec '\(BuiltApp.binary.path)' "$@"
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

    /// What the fake ioreg reports for AppleSmartBattery: "NONE" (the
    /// default, a desktop), "BATTERY", "BATTERY_AC", "BATTERY_NOKEY",
    /// "FAIL" or "HANG".
    func setBatteryService(_ mode: String) {
        setMode("battery_service", mode)
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
    /// note an inherited fd 9 and record the pid in `sudo.hung.pid`, once
    /// the SIGTERM trap and the watchdog's deadline are in place. The
    /// watchdog runs on bash's SECONDS, so the fake forks nothing but
    /// /bin/sleep while it waits. A test may signal the fake's process
    /// group as soon as the pid appears, and a signal that killed a `date`
    /// setting the deadline would leave it at 60, ending the fake at once.
    /// A command substitution would also log one signal twice. Bash 3.2
    /// starts it with the shell's pending traps and trap commands, so a
    /// SIGTERM that lands just before the fork runs the trap in both.
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
          while [[ ! -e "\(root.path)/release" && -d "\(root.path)" && $SECONDS -lt $deadline ]]; do /bin/sleep 0.1; done
          if [[ -e "\(root.path)/release" ]]; then echo released > "\(root.path)/command.ended"
          elif [[ -d "\(root.path)" ]]; then echo watchdog > "\(root.path)/command.ended"; fi
          exit 0
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

    /// The TMPDIR inside the fixture that every run gets (`tmp`), so a
    /// test can check that the script leaves no scratch files behind.
    func privateTmp() throws -> URL {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
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

    // MARK: Running

    /// Decoded lossily: the fake launchctl copies the first line of the
    /// installed binary into the log, which is Mach-O bytes, not text, for
    /// the fixture the real codesign signs.
    func calls(file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let data = record(callsLog, file: file, line: line) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The calls besides those to the logging mktemp, rm, rmdir and mkdir,
    /// which every install run makes for its own scratch files (see
    /// bounded()) and the folders it installs into.
    func callsBesideScratchFiles() -> [String] {
        calls().filter { call in !["mktemp", "rm", "rmdir", "mkdir"].contains { call == $0 || call.hasPrefix($0 + " ") } }
    }

    func chmodCalls(file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let data = record(root.appendingPathComponent("chmod.calls"), file: file, line: line) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func clearCalls() {
        try? fm.removeItem(at: callsLog)
    }

    /// Removes the backstop's log, so a loop's next case cannot pass on a
    /// line an earlier case wrote.
    func clearLog() {
        try? fm.removeItem(at: logFile)
    }

    /// The backstop's log, or "" when there is none. A log that is there
    /// but cannot be read fails the test instead of reading as empty.
    func log(file: StaticString = #filePath, line: UInt = #line) -> String {
        String(decoding: record(logFile, file: file, line: line) ?? Data(), as: UTF8.self)
    }

    /// The bytes of a file a run or a fake writes, or nil when there is
    /// none. A file that is there but cannot be read fails the test instead
    /// of reading as missing, so an unread record never passes for no
    /// calls or no lines.
    private func record(_ url: URL, file: StaticString, line: UInt) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            XCTFail("could not read \(url.path): \(error)", file: file, line: line)
            return nil
        }
    }

    /// Environment for the child: no inheritance, so neither the real HOME
    /// nor a TempHome's INSOMNIA_HOME can leak in. HOME is deliberately
    /// unset (see the class comment).
    private var childEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "INSOMNIA_HOME": home.path,
            "TMPDIR": tmp.path,
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
    /// `extraEnvironment` is for install.sh's refusal test and USER; every
    /// run already has the fixture's TMPDIR (see privateTmp). `lastPid` is the script's pid
    /// afterwards: the wrappers exec it, so it is the pid of the process
    /// started here.
    private(set) var lastPid: Int32 = 0

    func run(_ script: URL, _ args: [String] = [], fd9: URL? = nil, ignoringTerm: Bool = false, extraEnvironment: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let launch = launch(script, args, fd9: fd9, ignoringTerm: ignoringTerm, extraEnvironment: extraEnvironment)
        let (p, childExit) = try launch.start()
        lastPid = p.processIdentifier
        childExit.wait()
        return try launch.result(of: p)
    }

    /// One run of a script copy as `run` starts it, held as paths and
    /// strings only, so that runs on separate fixtures can go several at a
    /// time (`runAll`).
    struct Launch: Sendable {
        let arguments: [String]
        let environment: [String: String]
        let directory: URL
        let stdout: URL
        let stderr: URL

        /// Starts the run. Its output goes to files rather than pipes:
        /// nothing to drain, nothing to deadlock. Each file is created
        /// empty here, or the run is not started.
        func start() throws -> (Process, ProcessExit) {
            let fm = FileManager.default
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = arguments
            p.environment = environment
            p.currentDirectoryURL = directory
            for url in [stdout, stderr] {
                guard fm.createFile(atPath: url.path, contents: nil) else {
                    throw FixtureError("could not create \(url.path) for the run's output")
                }
            }
            let out = try FileHandle(forWritingTo: stdout)
            let err = try FileHandle(forWritingTo: stderr)
            defer { try? out.close(); try? err.close() }
            p.standardOutput = out
            p.standardError = err
            let childExit = ProcessExit(p)
            try p.run()
            return (p, childExit)
        }

        /// The exit status and what the run printed, once it has exited. An
        /// output file that cannot be read throws, so it never reads as a
        /// run that printed nothing; bytes that are not UTF-8 are kept as
        /// replacement characters. A run a signal ended throws too, with
        /// the signal and what it printed on standard error: it has no exit
        /// status, and the signal's number must not read as one the script
        /// chose. No test ends such a run with a signal (spawn is for that).
        func result(of p: Process) throws -> (status: Int32, stdout: String, stderr: String) {
            let out = String(decoding: try Data(contentsOf: stdout), as: UTF8.self)
            let err = String(decoding: try Data(contentsOf: stderr), as: UTF8.self)
            guard p.terminationReason == .exit else {
                throw FixtureError("bash \(arguments.joined(separator: " ")) ended on signal \(p.terminationStatus); stderr: \(err)")
            }
            return (p.terminationStatus, out, err)
        }
    }

    func launch(_ script: URL, _ args: [String] = [], fd9: URL? = nil, ignoringTerm: Bool = false, extraEnvironment: [String: String] = [:]) -> Launch {
        precondition(fd9 == nil || !ignoringTerm, "fd9 and ignoringTerm are not combined")
        let arguments: [String]
        if let fd9 {
            arguments = ["-c", #"exec 9<>"$0" && exec /bin/bash "$@""#, fd9.path, script.path] + args
        } else if ignoringTerm {
            arguments = ["-c", #"trap '' TERM && exec /bin/bash "$@""#, "bash", script.path] + args
        } else {
            arguments = [script.path] + args
        }
        return Launch(arguments: arguments, environment: childEnvironment.merging(extraEnvironment) { $1 }, directory: root,
                      stdout: root.appendingPathComponent("stdout.\(UUID().uuidString)"),
                      stderr: root.appendingPathComponent("stderr.\(UUID().uuidString)"))
    }

    /// A fixture for a row that runs beside others (runAll). Its copies of
    /// backstop.sh and uninstall.sh keep the production limits on commands,
    /// the lock and uninstall's calls, not the 1 s and 5 s the other tests
    /// set: with eight runs at once, a fake that answers at once here was
    /// seen to start too late for 1 s. No fake in such a row hangs, so a
    /// limit never fires there. The limits are copied before
    /// installMachinery(), which installs this backstop.
    static func concurrentRow() throws -> ScriptFixture {
        let f = try ScriptFixture()
        do {
            for (copy, script, names) in [
                (f.backstop, "backstop.sh", ["LOCK_TIMEOUT_SECONDS", "COMMAND_TIMEOUT_SECONDS", "KILL_GRACE_SECONDS"]),
                (f.uninstall, "uninstall.sh", ["LOCK_TIMEOUT_SECONDS", "CALL_TIMEOUT_SECONDS"]),
            ] {
                let production = try String(contentsOf: productionScripts.appendingPathComponent(script), encoding: .utf8).components(separatedBy: "\n")
                var limits: [String: String] = [:]
                for name in names {
                    let lines = production.filter { $0.hasPrefix("\(name)=") }
                    guard lines.count == 1 else { throw FixtureError("expected exactly one '\(name)=' line in \(script), found \(lines.count)") }
                    limits[name] = String(lines[0].dropFirst(name.count + 1))
                }
                try patch(try String(contentsOf: copy, encoding: .utf8), limits).write(to: copy, atomically: true, encoding: .utf8)
            }
        } catch {
            f.destroy()
            throw error
        }
        return f
    }

    /// Runs each launch once, at most `width` at a time, and returns their
    /// results in order. The runs share no file they write: each launch
    /// belongs to its own fixture or works only in folders of its own, as
    /// the journal acceptance table's do. Every run that started is waited
    /// for and reaped, also when another fails to start: the group waits for
    /// its tasks before it throws.
    static func runAll(_ launches: [Launch], width: Int = 8) async throws -> [(status: Int32, stdout: String, stderr: String)] {
        var results = [(status: Int32, stdout: String, stderr: String)](repeating: (-1, "", ""), count: launches.count)
        try await withThrowingTaskGroup(of: (Int, Int32, String, String).self) { group in
            var next = 0
            func add() {
                guard next < launches.count else { return }
                let (i, launch) = (next, launches[next])
                group.addTask {
                    let (p, childExit) = try launch.start()
                    await childExit.exited()
                    let r = try launch.result(of: p)
                    return (i, r.status, r.stdout, r.stderr)
                }
                next += 1
            }
            for _ in 0..<width { add() }
            while let (i, status, stdout, stderr) = try await group.next() {
                results[i] = (status, stdout, stderr)
                add()
            }
        }
        return results
    }

    /// Holds the alive lock the way the running app does, with its own type
    /// (AppAliveLock.swift), in this process until the test releases it. No
    /// timer: it cannot run out between the script runs of a slow test.
    func holdAliveLock() throws -> AppAliveLock {
        let lock = AppAliveLock(url: alive)
        guard try lock.tryAcquire() else { throw FixtureError("could not take \(alive.lastPathComponent): another holder has it") }
        return lock
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
    func slowPolls(file: StaticString = #filePath, line: UInt = #line) -> Int {
        String(decoding: record(root.appendingPathComponent("slow-poll.log"), file: file, line: line) ?? Data(), as: UTF8.self)
            .split(separator: "\n").count
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
    /// the device from the journal the agent published. The journals are
    /// written one at a time (each Harness points INSOMNIA_HOME at its
    /// home), the agent runs go several at a time, one fixture each, and
    /// the app's restores one at a time again.
    func testAnEscapedNameOrUIDDoesNotStopTheAgentAndTheAppRestoresIt() async throws {
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        var rows: [(label: String, uid: String, name: String, f: ScriptFixture, before: Data)] = []
        for v in Self.variants() {
            for record in [false, true] {
                for legacy in [false, true] {
                    let label = "\(v.label) record \(record) legacy \(legacy)"
                    let f = try ScriptFixture.concurrentRow()
                    fixtures.append(f)
                    let before = try await appJournal(uid: v.uid, name: v.name, record: record, legacy: legacy, boot: f.bootUUID)
                    if v.label != "plain" {
                        XCTAssertTrue(String(decoding: before, as: UTF8.self).contains("\(backslash)\(backslash)u0041"), label)
                    }
                    try before.write(to: f.state)
                    try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
                    rows.append((label, v.uid, v.name, f, before))
                }
            }
        }

        let results = try await ScriptFixture.runAll(rows.map { $0.f.launch($0.f.backstop) })

        for (row, r) in zip(rows, results) {
            let (label, f) = (row.label, row.f)
            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr) \(f.log())")
            XCTAssertFalse(f.exists(f.session), label)
            try checkUndone(f, before: row.before, label)

            let h = Harness()
            defer { h.home.destroy() }
            h.audio.connect(row.uid, name: row.name, volume: 0.6, muted: true)
            h.clamshell.closed = false
            try Data(contentsOf: f.state).write(to: h.home.paths.stateFile)
            let m = h.makeManager(bootSession: f.bootUUID)
            await m.reconcile()

            XCTAssertEqual(h.audio.device(row.uid)?.muted, false, label)
            XCTAssertEqual(h.audio.device(row.uid)?.volume, 0.6, label)
            XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [], label)
        }
    }

    /// uninstall.sh, with and without --purge, runs the backstop it
    /// installed over the same journals: the undo goes as far as for a
    /// plain name, and the saved output, which only the app restores,
    /// stops the removal with the app, the agent and the sudoers rule in
    /// place. The journals are written one at a time, and the uninstalls
    /// go several at a time, one fixture each.
    func testAnEscapedNameOrUIDDoesNotStopTheUndoOfAnUninstall() async throws {
        var fixtures: [ScriptFixture] = []
        defer { fixtures.forEach { $0.destroy() } }
        var rows: [(label: String, f: ScriptFixture, before: Data, purge: Bool)] = []
        for v in Self.variants() {
            for record in [false, true] {
                for legacy in [false, true] {
                    for purge in [false, true] {
                        let label = "\(v.label) record \(record) legacy \(legacy) purge \(purge)"
                        let f = try ScriptFixture.concurrentRow()
                        fixtures.append(f)
                        let before = try await appJournal(uid: v.uid, name: v.name, record: record, legacy: legacy, boot: f.bootUUID)
                        try f.installMachinery()
                        try before.write(to: f.state)
                        try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
                        rows.append((label, f, before, purge))
                    }
                }
            }
        }

        let results = try await ScriptFixture.runAll(rows.map { $0.f.launch($0.f.uninstall, $0.purge ? ["--purge"] : []) })

        for (row, r) in zip(rows, results) {
            let (label, f) = (row.label, row.f)
            XCTAssertNotEqual(r.status, 0, label)
            XCTAssertTrue(f.exists(f.app), label)
            XCTAssertTrue(f.exists(f.plist), label)
            XCTAssertTrue(f.exists(f.sudoers), label)
            XCTAssertFalse(r.stderr.contains("malformed"), "\(label): \(r.stderr)")
            XCTAssertTrue(r.stderr.contains("audio") || r.stdout.contains("audio"), "\(label): \(r.stdout) \(r.stderr)")
            try checkUndone(f, before: row.before, label)
        }
    }

    /// Journals the app reads, each with sleep journaled, through the
    /// agent: what is around the records, in strings and nested values,
    /// holds none, and the forms of a record the app reads pass. Sleep is
    /// undone each time. The runs go several at a time, one fixture each.
    func testWhatTheAppReadsAroundTheRecordsDoesNotStopTheAgent() async throws {
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
        for (label, tail) in tails {
            let json = base + tail
            XCTAssertNoThrow(try Store.makeDecoder().decode(RuntimeState.self, from: Data(json.utf8)), label)
            let f = try ScriptFixture.concurrentRow()
            fixtures.append(f)
            try f.writeState(json)
            try f.writeSession(endsAt: Date(timeIntervalSinceNow: -60))
        }

        let results = try await ScriptFixture.runAll(fixtures.map { $0.launch($0.backstop) })

        for ((label, _), (f, r)) in zip(tails, zip(fixtures, results)) {
            XCTAssertEqual(r.status, 0, "\(label): \(r.stderr) \(f.log())")
            XCTAssertTrue(f.calls().contains("sudo -n \(f.fakePmset) -a disablesleep 0"), label)
            XCTAssertEqual(try f.stateJSON()["sleepDisabledByUs"] as? Bool, false, label)
            XCTAssertFalse(f.exists(f.session), label)
        }
    }
}
