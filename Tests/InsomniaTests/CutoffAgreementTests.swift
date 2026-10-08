import Foundation
import XCTest
@testable import Insomnia

/// The app and the recovery agent each decide the battery and thermal
/// cutoffs: FloorRules on `manager.config`, and backstop.sh on the endFloor
/// and thermalRules keys of config.json. These tests take the two through
/// each way they could part (a deleted file, a Settings change that could
/// not be saved, a file repaired or edited by hand, an end floor far
/// outside 0...95) and then ask both, with the battery at 25% on battery
/// power (or the level a test names) and the thermal pressure level at 3
/// (critical) or 0. The agent is the real backstop.sh with its tools
/// patched to fakes, run with the app's alive lock held.
@MainActor
final class CutoffAgreementTests: XCTestCase {
    var h: Harness!
    var alive: AppAliveLock!
    var agent: PatchedBackstop!

    override func setUp() async throws {
        h = Harness()
        try h.home.paths.createDirectories()
        alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        agent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent", isDirectory: true))
    }

    override func tearDown() async throws {
        alive.release()
        try? setImmutable(h.home.paths.configFile, false)
        try? TestACL.removeAll(h.home.paths.appSupport)
        h.home.destroy()
    }

    // MARK: The agent

    /// One agent run with the app alive at thermal pressure `level`.
    /// Returns whether it ended the session: session.json removed, sleep
    /// restored and the journal says so.
    private func agentEnds(level: Int) async throws -> Bool {
        try agent.setThermal(level)
        let exit = try await agent.run()
        XCTAssertEqual(exit, 0, logText())
        let ended = try h.store.loadSession() == nil
        XCTAssertEqual(agent.calls.contains(agent.restoreCall), ended, agent.calls.joined(separator: "\n"))
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, !ended)
        return ended
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    // MARK: Both sides

    /// Whether FloorRules ends the session on the app's settings at
    /// `battery` percent on battery power, at critical or nominal heat.
    private func appEnds(_ m: SessionManager, critical: Bool, battery: Int = 25) -> Bool {
        FloorRules.evaluate(battery: .percent(battery), isCharging: false, thermal: critical ? .critical : .nominal,
                            lidClosed: false, lowPowerSetByUs: false, config: m.config)
            .contains { if case .endSession = $0 { true } else { false } }
    }

    /// Asks the app, then the agent, about the running session, and checks
    /// that both give `expected`. An agent that ends the session ends it
    /// for good, so `expected == true` is the last question about it.
    private func assertBoth(_ m: SessionManager, critical: Bool, end expected: Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(m.isActive, "a session runs", file: file, line: line)
        XCTAssertEqual(appEnds(m, critical: critical), expected, "the app on \(m.config.agentCutoffs.description)", file: file, line: line)
        let agent = try await agentEnds(level: critical ? 3 : 0)
        XCTAssertEqual(agent, expected, "the agent on config.json \(String(describing: try? h.store.loadConfig()?.agentCutoffs.description)): \(logText())", file: file, line: line)
        if agent {
            await m.noticeAgentEnd()
            XCTAssertFalse(m.isActive, file: file, line: line)
        }
    }

    private func startWith(endFloor: Int, thermalRules: Bool = true, _ edit: (inout Config) -> Void = { _ in }) async throws -> SessionManager {
        var c = Config()
        c.setEndFloor(endFloor)
        c.thermalRules = thermalRules
        edit(&c)
        try h.store.saveConfig(c)
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        return m
    }

    // MARK: A deleted config.json

    /// config.json deleted during a session on a 30% floor: the agent would
    /// enforce its own 10%. The next tick writes the settings in use back,
    /// and both end at 25%.
    func testADeletedConfigIsWrittenBackAndBothEndAtTheSelectedFloor() async throws {
        let m = try await startWith(endFloor: 30)
        try FileManager.default.removeItem(at: h.home.paths.configFile)

        await m.noticeConfigFileChange()

        XCTAssertEqual(try h.store.loadConfig(), m.config)
        XCTAssertEqual(m.config.endFloor, 30)
        try await assertBoth(m, critical: false, end: true)
    }

    /// The same deletion where the settings cannot be written back, as on a
    /// full disk: the agent's 10% would differ from the app's 30%, so the
    /// tick's transaction ends the session and Start is refused until the
    /// file is written. Then both end at 25% again.
    func testADeletedConfigThatCannotBeWrittenBackStopsSessionsOnAFloorTheAgentLacks() async throws {
        let m = try await startWith(endFloor: 30)
        let dir = h.home.paths.appSupport
        try FileManager.default.removeItem(at: h.home.paths.configFile)
        try TestACL.denyNewFiles(in: dir)

        await m.noticeConfigFileChange()

        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        let why = try XCTUnwrap(m.rejectedConfigFile)
        XCTAssertTrue(why.hasSuffix("Free some disk space or make \(dir.path) writable."), why)
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)

        try TestACL.removeAll(dir)
        await m.start(duration: 3600)

        XCTAssertNil(m.rejectedConfigFile)
        XCTAssertEqual(try h.store.loadConfig()?.endFloor, 30)
        try await assertBoth(m, critical: false, end: true)
    }

    /// When the settings in use carry the agent's own defaults (10%,
    /// thermal rules on), a missing file that cannot be written changes
    /// nothing either side enforces: the session goes on, the failure is
    /// logged once, and the tick looks again only after the retry delay.
    func testADeletedConfigThatCannotBeWrittenBackKeepsASessionOnTheAgentsDefaults() async throws {
        let m = try await startWith(endFloor: 10)
        let dir = h.home.paths.appSupport
        try FileManager.default.removeItem(at: h.home.paths.configFile)
        try TestACL.denyNewFiles(in: dir)

        await m.noticeConfigFileChange()
        await m.noticeConfigFileChange()

        XCTAssertTrue(m.isActive)
        XCTAssertNil(m.rejectedConfigFile)
        let failure = "could not write the settings in use to the missing config.json"
        XCTAssertEqual(logText().components(separatedBy: failure).count - 1, 1, logText())
        try TestACL.removeAll(dir)
        h.clock.advance(59)
        await m.noticeConfigFileChange()
        XCTAssertNil(try h.store.loadConfig(), "inside the retry delay")

        try await assertBoth(m, critical: false, end: false)

        h.clock.advance(1)
        await m.noticeConfigFileChange()
        XCTAssertEqual(try h.store.loadConfig(), m.config)
        try await assertBoth(m, critical: true, end: true)
    }

    // MARK: A Settings change that cannot be saved

    /// Raising the end floor from 10% to 30% while config.json cannot be
    /// written changes neither side: Settings says why, and both keep the
    /// session at 25%. Once the file can be written, the same change ends
    /// it on both sides.
    func testAnEndFloorChangeThatCannotBeSavedChangesNeitherSide() async throws {
        let m = try await startWith(endFloor: 10)
        let file = h.home.paths.configFile
        try setImmutable(file, true)

        XCTAssertFalse(m.updateConfig { $0.setEndFloor(30) })

        XCTAssertEqual(m.config.endFloor, 10)
        XCTAssertEqual(try h.store.loadConfig()?.endFloor, 10)
        let error = try XCTUnwrap(m.configSaveError)
        XCTAssertTrue(error.hasPrefix("Could not save the change to config.json ("), error)
        XCTAssertTrue(error.hasSuffix("so both stay at end floor 10%, thermal rules on."), error)
        try await assertBoth(m, critical: false, end: false)

        try setImmutable(file, false)
        XCTAssertTrue(m.updateConfig { $0.setEndFloor(30) })

        XCTAssertNil(m.configSaveError)
        XCTAssertEqual(try h.store.loadConfig()?.endFloor, 30)
        try await assertBoth(m, critical: false, end: true)
    }

    /// Turning the thermal rules on while config.json cannot be written:
    /// at critical heat both keep the session; once saved, both end it.
    func testAThermalRuleChangeThatCannotBeSavedChangesNeitherSide() async throws {
        let m = try await startWith(endFloor: 0, thermalRules: false)
        let file = h.home.paths.configFile
        try setImmutable(file, true)

        XCTAssertFalse(m.updateConfig { $0.thermalRules = true })

        XCTAssertFalse(m.config.thermalRules)
        XCTAssertEqual(try h.store.loadConfig()?.thermalRules, false)
        XCTAssertNotNil(m.configSaveError)
        try await assertBoth(m, critical: true, end: false)

        try setImmutable(file, false)
        XCTAssertTrue(m.updateConfig { $0.thermalRules = true })

        XCTAssertNil(m.configSaveError)
        try await assertBoth(m, critical: true, end: true)
    }

    /// A change to any other setting is not held back by a write that
    /// fails: it applies at once, as before, and Settings shows no cutoff
    /// error.
    func testAnotherSettingChangesThoughItCannotBeSaved() async throws {
        let m = try await startWith(endFloor: 10)
        try setImmutable(h.home.paths.configFile, true)

        XCTAssertFalse(m.updateConfig { $0.muteOnLidClose.toggle() })

        XCTAssertEqual(m.config.muteOnLidClose, !Config().muteOnLidClose)
        XCTAssertNil(m.configSaveError)
        XCTAssertEqual(try h.store.loadConfig()?.muteOnLidClose, Config().muteOnLidClose)
    }

    /// A cutoff changed in memory without its write (code that bypasses
    /// `updateConfig`) lasts only to the next transaction, which takes the
    /// file's value back: the app never runs on a cutoff the agent lacks.
    func testACutoffChangedOnlyInMemoryIsTakenBackFromTheFile() async throws {
        let m = try await startWith(endFloor: 10)
        try setImmutable(h.home.paths.configFile, true)
        m.config.setEndFloor(30)

        await m.extend(by: 60)

        XCTAssertEqual(m.config.endFloor, 10)
        XCTAssertTrue(logText().contains("config.json has end floor 10%, thermal rules on, the app had end floor 30%, thermal rules on"), logText())
        try await assertBoth(m, critical: false, end: false)
    }

    // MARK: config.json repaired or edited by hand

    /// A file the app rejects and cannot move ends the session. Repaired by
    /// hand into a valid file with a 0% floor and no thermal rule, it is
    /// what the agent enforces, so the next Start takes those two values
    /// and nothing else from it: both keep the session at 25% and critical
    /// heat. A later hand edit to a 50% floor reaches the app at the next
    /// tick, and both end.
    func testAConfigRepairedByHandIsWhatBothEnforce() async throws {
        let m = try await startWith(endFloor: 30) { $0.muteOnLidClose = !Config().muteOnLidClose }
        let file = h.home.paths.configFile
        try Data(#"{"endFloor": 0, "thermalRules": false, "freezeList": 42}"#.utf8).write(to: file)
        try setImmutable(file, true)
        await m.extend(by: 60)
        XCTAssertFalse(m.isActive)
        XCTAssertNotNil(m.rejectedConfigFile)

        try setImmutable(file, false)
        var repaired = Config()
        repaired.endFloor = 0
        repaired.thermalRules = false
        try h.store.saveConfig(repaired)
        await m.start(duration: 3600)

        XCTAssertNil(m.rejectedConfigFile)
        XCTAssertEqual(m.config.agentCutoffs, AgentCutoffs(endFloor: 0, thermalRules: false))
        XCTAssertEqual(m.config.muteOnLidClose, !Config().muteOnLidClose, "only the cutoffs come from the file")
        XCTAssertEqual(try h.store.loadConfig(), repaired, "the file is not rewritten")
        try await assertBoth(m, critical: true, end: false)

        var edited = repaired
        edited.endFloor = 50
        try h.store.saveConfig(edited)
        await m.noticeConfigFileChange()

        XCTAssertEqual(m.config.endFloor, 50)
        XCTAssertEqual(m.config.lowPowerFloor, 55, "raised above the new end floor")
        try await assertBoth(m, critical: false, end: true)
    }

    // MARK: End floors outside 0...95

    /// endFloor as written in config.json, and the floor the app takes from
    /// it, clamped to 0...95, or nil where the app rejects the file. Swift
    /// decodes an Int from -2^63 through 2^63 - 1, and a number written as
    /// a float when its Double is whole and an Int holds it; anything else
    /// (a fraction, a string, a bool) fails the whole file. The texts
    /// around 2^63 are the last that decode on each side and the first
    /// that do not.
    private static let endFloorsWrittenAsIntegers: [(text: String, app: Int?)] = [
        ("0", 0), ("-1", 0), ("5", 5), ("94", 94), ("95", 95), ("96", 95), ("200", 95),
        ("999999999999999999", 95), ("1000000000000000000", 95),
        ("9223372036854775806", 95), ("9223372036854775807", 95),
        ("-999999999999999999", 0), ("-1000000000000000000", 0),
        ("-9223372036854775807", 0), ("-9223372036854775808", 0),
        ("9223372036854775808", nil), ("18446744073709551615", nil), ("99999999999999999999", nil),
    ]

    private static let endFloorsWrittenAsFloats: [(text: String, app: Int?)] = [
        ("30.0", 30), ("3e1", 30), ("29.999999999999999999", 30), ("0.0", 0), ("-0.0", 0),
        ("1e2", 95), ("1e16", 95), ("1e17", 95), ("123456789012345678.5", 95),
        ("9.2e18", 95), ("-9.2e18", 0), ("9223372036854775295.0", 95), ("-9223372036854775807.0", 0),
        ("9223372036854775296.0", nil), ("1e19", nil), ("-1e19", nil),
        ("30.5", nil), ("-0.5", nil), ("1e-1", nil), (#""30""#, nil), ("true", nil),
    ]

    /// A session on disk whose journal holds sleep, as the app leaves one,
    /// and one agent run at `percent` on battery power and nominal heat.
    /// Returns whether it ended the session.
    private func agentEnds(atBattery percent: Int, file: StaticString = #filePath, line: UInt = #line) async throws -> Bool {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(3600)))
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        try h.store.saveState(journal)
        try agent.setThermal(0)
        try agent.setBattery(percent)
        let exit = try await agent.run()
        XCTAssertEqual(exit, 0, logText(), file: file, line: line)
        return try h.store.loadSession() == nil
    }

    /// For each text, the floor the agent enforces on that config.json is
    /// the one the app takes from it, or the agent's default 10% where the
    /// app rejects the file: the agent ends a session one point below it
    /// and keeps it at it (at 0%, for a floor of 0, which is off).
    private func assertTheAgentFollowsTheApp(_ table: [(text: String, app: Int?)],
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        for (text, expected) in table {
            try Data(#"{"endFloor": \#(text), "thermalRules": false}"#.utf8).write(to: h.home.paths.configFile)
            let app = try? h.store.loadConfig()?.agentCutoffs.endFloor
            XCTAssertEqual(app, expected, "the app on endFloor \(text)", file: file, line: line)
            let floor = app ?? Config.agentDefaultCutoffs.endFloor
            if floor > 0 {
                let below = try await agentEnds(atBattery: floor - 1, file: file, line: line)
                XCTAssertTrue(below, "endFloor \(text): the agent keeps a session at \(floor - 1)%: \(logText())", file: file, line: line)
            }
            let at = try await agentEnds(atBattery: floor, file: file, line: line)
            XCTAssertFalse(at, "endFloor \(text): the agent ends a session at \(floor)%: \(logText())", file: file, line: line)
        }
    }

    func testTheAgentEnforcesTheEndFloorTheAppTakesFromAnyInteger() async throws {
        try await assertTheAgentFollowsTheApp(Self.endFloorsWrittenAsIntegers)
    }

    func testTheAgentEnforcesTheEndFloorTheAppTakesFromAnyFloat() async throws {
        try await assertTheAgentFollowsTheApp(Self.endFloorsWrittenAsFloats)
    }

    /// The reviewer's case: config.json holds endFloor Int.max and cannot
    /// be written, so the app cannot put the 95 it clamps that to in its
    /// place. Start accepts the file, since both sides read it, and at 25%
    /// both end the session. The same agent run on a file holding the
    /// app's settings is the control.
    func testAnEndFloorOfIntMaxThatCannotBeRewrittenIsNinetyFiveOnBothSides() async throws {
        try await assertAnUnwritableEndFloor(Int.max, battery: 25, ends: true)
    }

    /// Int.min, which the app clamps to 0 (off): at 5% both keep the
    /// session, where the agent's default 10% would end it.
    func testAnEndFloorOfIntMinThatCannotBeRewrittenIsOffOnBothSides() async throws {
        try await assertAnUnwritableEndFloor(Int.min, battery: 5, ends: false)
    }

    private func assertAnUnwritableEndFloor(_ value: Int, battery: Int, ends expected: Bool,
                                            file: StaticString = #filePath, line: UInt = #line) async throws {
        var c = Config()
        c.endFloor = value
        c.thermalRules = false
        try h.store.saveConfig(c)
        let written = try Data(contentsOf: h.home.paths.configFile)
        try setImmutable(h.home.paths.configFile, true)
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive, file: file, line: line)
        XCTAssertNil(m.rejectedConfigFile, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.configFile), written, "the file still holds \(value)", file: file, line: line)
        XCTAssertEqual(appEnds(m, critical: false, battery: battery), expected, "the app on \(m.config.agentCutoffs.description)", file: file, line: line)

        try agent.setBattery(battery)
        let exit = try await agent.run()
        XCTAssertEqual(exit, 0, logText(), file: file, line: line)
        let ended = try h.store.loadSession() == nil
        XCTAssertEqual(ended, expected, "the agent on endFloor \(value) at \(battery)%: \(logText())", file: file, line: line)
        XCTAssertEqual(agent.calls.contains(agent.restoreCall), expected, agent.calls.joined(separator: "\n"), file: file, line: line)

        try setImmutable(h.home.paths.configFile, false)
        try h.store.saveConfig(m.config)
        XCTAssertEqual(try h.store.loadConfig()?.endFloor, m.config.agentCutoffs.endFloor, file: file, line: line)
        let control = try await agentEnds(atBattery: battery, file: file, line: line)
        XCTAssertEqual(control, expected, "the agent on the app's settings: \(logText())", file: file, line: line)
    }
}
