import Foundation
import XCTest
@testable import Insomnia

/// The app and the recovery agent each decide the battery and thermal
/// cutoffs: FloorRules on `manager.config`, and backstop.sh on what the
/// app's binary decodes from config.json (`AgentCutoffsCommand`). These
/// tests take the two through each way they could part (a deleted file, a
/// Settings change that could not be saved, a file repaired or edited by
/// hand, duplicate or escaped keys, an end floor far outside 0...95) and
/// then ask both, with the battery at 25% on battery power (or the level a
/// test names) and the thermal pressure level at 3 (critical) or 0. The
/// agent is the real backstop.sh with its tools patched to fakes and this
/// build's binary as the app's, run with the app's alive lock held.
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

    /// Asks the app, then the agent, about the running session at `battery`
    /// percent, and checks that both give `expected`. An agent that ends
    /// the session ends it for good, so `expected == true` is the last
    /// question about it.
    private func assertBoth(_ m: SessionManager, critical: Bool, battery: Int = 25, end expected: Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertTrue(m.isActive, "a session runs", file: file, line: line)
        XCTAssertEqual(appEnds(m, critical: critical, battery: battery), expected, "the app on \(m.config.agentCutoffs.description)", file: file, line: line)
        try self.agent.setBattery(battery)
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

    // MARK: config.json as the app's decoder reads it

    /// config.json holding `text`, which cannot be written, so the app
    /// keeps it as written. The app's decoder takes `expected` from it, a
    /// session started on it takes the same, and at `battery` percent and
    /// critical heat or not the app and the agent both end it or both keep
    /// it. Ends a session the agent kept, so a test can run several texts.
    private func assertBothRead(_ text: String, as expected: AgentCutoffs, battery: Int = 25, critical: Bool = false, end: Bool,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        agent.clearCalls()
        let bytes = Data(text.utf8)
        try bytes.write(to: h.home.paths.configFile)
        XCTAssertEqual(try h.store.loadConfig()?.agentCutoffs, expected, "the app's decoder on \(text)", file: file, line: line)
        try setImmutable(h.home.paths.configFile, true)
        defer { try? setImmutable(h.home.paths.configFile, false) }
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive, text, file: file, line: line)
        XCTAssertNil(m.rejectedConfigFile, text, file: file, line: line)
        XCTAssertEqual(m.config.agentCutoffs, expected, "the app adopts the file's cutoffs: \(text)", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.configFile), bytes, file: file, line: line)

        XCTAssertEqual(appEnds(m, critical: critical, battery: battery), end, "the app on \(text)", file: file, line: line)
        try agent.setBattery(battery)
        let ended = try await agentEnds(level: critical ? 3 : 0)
        XCTAssertEqual(ended, end, "the agent on \(text): \(logText())", file: file, line: line)
        XCTAssertFalse(logText().contains("enforcing the strictest"), logText(), file: file, line: line)
        if ended {
            await m.noticeAgentEnd()
        } else {
            await m.end(reason: .user)
        }
        XCTAssertFalse(m.isActive, file: file, line: line)
    }

    /// The round-22 review's cases: Swift's JSONDecoder takes the first of
    /// two endFloor keys, also when one is written with an escape, where a
    /// property-list reader takes the last. The agent gets the app's
    /// answer, in either order.
    func testDuplicateAndEscapedEndFloorKeysAreReadAsTheAppReadsThem() async throws {
        let ninetyFive = AgentCutoffs(endFloor: 95, thermalRules: false)
        let off = AgentCutoffs(endFloor: 0, thermalRules: false)
        try await assertBothRead(#"{"endFloor":95,"endFloor":0,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#, as: ninetyFive, end: true)
        try await assertBothRead(#"{"end\u0046loor":95,"endFloor":0,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#, as: ninetyFive, end: true)
        try await assertBothRead(#"{"endFloor":95,"end\u0046loor":0,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#, as: ninetyFive, end: true)
        try await assertBothRead(#"{"endFloor":0,"endFloor":95,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#, as: off, battery: 5, end: false)
        try await assertBothRead(#"{"end\u0046loor":0,"endFloor":95,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#, as: off, battery: 5, end: false)
    }

    /// The same for two thermalRules keys: at critical heat both end the
    /// session when the first says true and keep it when it says false.
    func testDuplicateThermalRulesKeysAreReadAsTheAppReadsThem() async throws {
        try await assertBothRead(#"{"endFloor":0,"thermalRules":true,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 0, thermalRules: true), critical: true, end: true)
        try await assertBothRead(#"{"endFloor":0,"thermal\u0052ules":true,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 0, thermalRules: true), critical: true, end: true)
        try await assertBothRead(#"{"endFloor":0,"thermalRules":false,"thermalRules":true,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 0, thermalRules: false), critical: true, end: false)
    }

    /// Controls: ordinary files, the zero and off settings, and a file
    /// with neither key, which is the defaults.
    func testOrdinaryCutoffsAreReadAsWritten() async throws {
        try await assertBothRead(#"{"endFloor":95,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 95, thermalRules: false), end: true)
        try await assertBothRead(#"{"endFloor":0,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 0, thermalRules: false), battery: 5, critical: true, end: false)
        try await assertBothRead(#"{"endFloor":10,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 10, thermalRules: false), battery: 9, end: true)
        try await assertBothRead(#"{"endFloor":10,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 10, thermalRules: false), battery: 10, critical: true, end: false)
        try await assertBothRead(#"{"endFloor":0,"thermalRules":true,"configVersion":2,"lidCloseDefaultsApplied":true}"#,
                                 as: AgentCutoffs(endFloor: 0, thermalRules: true), battery: 5, critical: true, end: true)
        try await assertBothRead("{}", as: Config.agentDefaultCutoffs, battery: 9, end: true)
    }

    /// The round-22 review's cases: during a session on the default 10%
    /// with the thermal rules off, config.json is replaced by one holding
    /// endFloor 0 and an error in another field, so the app's decoder
    /// rejects the whole file. An app that has stopped answering keeps 10%,
    /// so at 5% the agent must end the session on its defaults, not read
    /// the floor from the rejected file as off. The same run on the app's
    /// settings is the control.
    func testAFileRejectedForAnotherFieldKeepsTheAgentOnItsDefaults() async throws {
        var c = Config()
        c.thermalRules = false
        try h.store.saveConfig(c)
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        try agent.setBattery(5)
        for field in [#""lowPowerFloor":"bad""#, #""presets":["bad"]"#, #""lowPowerFloor":-9223372036854775809"#] {
            try session.write(to: h.home.paths.sessionFile)
            try journal.write(to: h.home.paths.stateFile)
            let text = #"{"endFloor":0,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true,"# + field + "}"
            try Data(text.utf8).write(to: h.home.paths.configFile)
            XCTAssertThrowsError(try h.store.loadConfig(), text)
            XCTAssertTrue(appEnds(m, critical: false, battery: 5), "the app on \(m.config.agentCutoffs.description)")

            let ended = try await agentEnds(level: 0)
            XCTAssertTrue(ended, "the agent keeps a session at 5% on \(text): \(logText())")
            XCTAssertTrue(logText().contains("below the 10% end floor"), logText())
        }
        XCTAssertFalse(logText().contains("enforcing the strictest"), logText())

        try session.write(to: h.home.paths.sessionFile)
        try journal.write(to: h.home.paths.stateFile)
        try h.store.saveConfig(c)
        let control = try await agentEnds(level: 0)
        XCTAssertTrue(control, "the agent on the app's settings: \(logText())")
    }

    /// Greptile 4215544412: a hand edit to endFloor 1e-400 or
    /// 4.9999999999999999, which the decoder rounds to 0 and 5. The app
    /// adopts the rounded floor at its next tick and leaves the file as
    /// written; the agent enforces the same floor from the same bytes, and
    /// again after the app writes the file in its own form.
    func testARoundedEndFloorIsTheSameOnBothSides() async throws {
        let m = try await startWith(endFloor: 10, thermalRules: false)
        for (token, floor) in [("1e-400", 0), ("4.9999999999999999", 5)] {
            let raw = Data(#"{"endFloor":\#(token),"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#.utf8)
            try raw.write(to: h.home.paths.configFile)
            await m.noticeConfigFileChange()
            XCTAssertNil(m.rejectedConfigFile)
            XCTAssertEqual(m.config.agentCutoffs, AgentCutoffs(endFloor: floor, thermalRules: false), token)
            XCTAssertEqual(try Data(contentsOf: h.home.paths.configFile), raw, "the hand edit stays as written")

            try await assertBoth(m, critical: false, battery: max(floor, 1), end: false)
            try h.store.saveConfig(m.config)
            XCTAssertNotEqual(try Data(contentsOf: h.home.paths.configFile), raw)
            try await assertBoth(m, critical: false, battery: max(floor, 1), end: false)
        }
        try await assertBoth(m, critical: false, battery: 4, end: true)
    }

    // MARK: The cutoffs recorded for the session

    /// A config.json the app's decoder rejects for a field other than the
    /// cutoffs (freezeList 42).
    private let rejectedConfig = Data(#"{"endFloor":30,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true,"freezeList":42}"#.utf8)

    private func recorded() throws -> AgentCutoffs? { try h.store.loadState()?.sessionCutoffs }

    /// The round-24 review's case: a session on a 30% floor with the thermal
    /// rules off, and an app that has stopped answering (no transaction
    /// runs; the alive lock stays held). config.json is then rejected as a
    /// whole, or deleted. The agent enforces the cutoffs the app recorded
    /// for the session in state.json, so at 20% both end it, and at 40%,
    /// at critical heat too, both keep it: neither the agent's defaults
    /// (10%, rule on) nor the strictest (95%, rule on) apply. The agent's
    /// end leaves the record; the app's end of the session clears it.
    func testAHungSessionKeepsItsRecordedCutoffsWhileConfigIsRejectedOrMissing() async throws {
        let m = try await startWith(endFloor: 30, thermalRules: false)
        let cutoffs = AgentCutoffs(endFloor: 30, thermalRules: false)
        XCTAssertEqual(try recorded(), cutoffs, "Start records them")
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        let breaks: [(name: String, breakIt: () throws -> Void)] = [
            ("rejected", { try self.rejectedConfig.write(to: self.h.home.paths.configFile) }),
            ("missing", { try? FileManager.default.removeItem(at: self.h.home.paths.configFile) }),
        ]
        for (name, breakIt) in breaks {
            for (battery, critical, end) in [(40, true, false), (40, false, false), (31, false, false), (29, false, true), (20, false, true)] {
                try session.write(to: h.home.paths.sessionFile)
                try journal.write(to: h.home.paths.stateFile)
                try breakIt()
                agent.clearCalls()
                XCTAssertEqual(appEnds(m, critical: critical, battery: battery), end, "the app at \(battery)%")
                try agent.setBattery(battery)
                let ended = try await agentEnds(level: critical ? 3 : 0)
                XCTAssertEqual(ended, end, "\(name) config.json at \(battery)%, critical \(critical): \(logText())")
                XCTAssertEqual(try recorded(), cutoffs, "the agent keeps the record")
            }
        }
        XCTAssertTrue(logText().contains("below the 30% end floor"), logText())
        XCTAssertFalse(logText().contains("enforcing the strictest"), logText())

        await m.noticeAgentEnd()
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try recorded(), "the app clears it once session.json is gone")
    }

    /// The journal's record as the agent reads it through the app's binary,
    /// with config.json rejected: escaped keys as the app's decoder takes
    /// them; none (a session an older build started) and no state.json at
    /// all are the defaults; a value the app does not write is the
    /// strictest, with the reason logged. The app reads that value as none
    /// and records its own over it. A record found twice, which the app
    /// reads (the first copy) and never writes, stops the agent with the
    /// session and the journal kept, as any key twice does: plutil would
    /// read and republish the other copy.
    func testTheAgentReadsTheRecordAsTheAppDoes() async throws {
        _ = try await startWith(endFloor: 30, thermalRules: false)
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let base = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false"#
        let cases: [(value: String, battery: Int, end: Bool, log: String)] = [
            (#","sessionCutoffs":"30 false""#, 20, true, "below the 30% end floor"),
            (#","sessionCutoffs":"30 false""#, 40, false, ""),
            (#","session\u0043utoffs":"30 false""#, 20, true, "below the 30% end floor"),
            (#","session\u0043utoffs":"30 false""#, 40, false, ""),
            ("", 20, false, ""),
            ("", 9, true, "below the 10% end floor"),
            (#","sessionCutoffs":null"#, 9, true, "below the 10% end floor"),
            (#","sessionCutoffs":"96 false""#, 40, true, "enforcing the strictest, a 95% end floor and thermal rules on"),
            (#","sessionCutoffs":30"#, 40, true, "enforcing the strictest, a 95% end floor and thermal rules on"),
            (#","sessionCutoffs":"30 off""#, 94, true, "below the 95% end floor"),
        ]
        for c in cases {
            try session.write(to: h.home.paths.sessionFile)
            let text = base + c.value + "}"
            try Data(text.utf8).write(to: h.home.paths.stateFile)
            try rejectedConfig.write(to: h.home.paths.configFile)
            try? FileManager.default.removeItem(at: h.home.paths.logFile)
            agent.clearCalls()
            try agent.setBattery(c.battery)
            let ended = try await agentEnds(level: 0)
            XCTAssertEqual(ended, c.end, "\(text) at \(c.battery)%: \(logText())")
            if !c.log.isEmpty {
                XCTAssertTrue(logText().contains(c.log), "\(text): \(logText())")
            }
            if c.log.hasPrefix("enforcing") {
                XCTAssertTrue(logText().contains("is rejected by the app, and the cutoffs recorded for the session in \(h.home.paths.stateFile.path) are a value the app does not write"), logText())
            }
        }

        for twice in [#","sessionCutoffs":"30 false","sessionCutoffs":"0 false""#, #","sessionCutoffs":"0 false","sessionCutoffs":"30 false""#,
                      #","session\u0043utoffs":"30 false","sessionCutoffs":"0 false""#] {
            try session.write(to: h.home.paths.sessionFile)
            let text = base + twice + "}"
            try Data(text.utf8).write(to: h.home.paths.stateFile)
            XCTAssertNotNil(try h.store.loadState()?.sessionCutoffs, "the app reads \(text)")
            try rejectedConfig.write(to: h.home.paths.configFile)
            try? FileManager.default.removeItem(at: h.home.paths.logFile)
            agent.clearCalls()
            try agent.setBattery(5)
            try agent.setThermal(0)
            let exit = try await agent.run()
            XCTAssertEqual(exit, 1, "\(text): \(logText())")
            XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), session, text)
            XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), Data(text.utf8), text)
            XCTAssertFalse(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
            XCTAssertTrue(logText().contains("sessionCutoffs is in the top level of state.json 2 times"), logText())
            XCTAssertTrue(logText().contains("is kept as it is: its cutoffs are not read and it is not ended"), logText())
        }

        try session.write(to: h.home.paths.sessionFile)
        try? FileManager.default.removeItem(at: h.home.paths.stateFile)
        try rejectedConfig.write(to: h.home.paths.configFile)
        try agent.setBattery(20)
        let exit = try await agent.run()
        XCTAssertEqual(exit, 0, logText())
        XCTAssertNotNil(try h.store.loadSession(), "no state.json: the defaults keep the session at 20%: \(logText())")
        try agent.setBattery(9)
        _ = try await agent.run()
        XCTAssertNil(try h.store.loadSession(), "and end it at 9%: \(logText())")
    }

    /// A Settings change during a session is recorded for it in the journal
    /// before it takes effect, so a hung app's session keeps it. A change
    /// between sessions records nothing; the next Start records its own.
    func testACutoffChangeIsRecordedForTheSessionBeforeItTakesEffect() async throws {
        let m = try await startWith(endFloor: 10)
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 10, thermalRules: true))

        XCTAssertTrue(m.updateConfig {
            $0.setEndFloor(30)
            $0.thermalRules = false
        })

        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 30, thermalRules: false))
        XCTAssertEqual(try h.store.loadConfig()?.agentCutoffs, AgentCutoffs(endFloor: 30, thermalRules: false))
        XCTAssertTrue(m.updateConfig { $0.muteOnLidClose.toggle() }, "another setting records nothing")
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 30, thermalRules: false))
        XCTAssertTrue(m.updateConfig { $0.setEndFloor(200) }, "Settings clamps the floor")
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 95, thermalRules: false), "the clamped floor in use is recorded")
        XCTAssertTrue(m.updateConfig { $0.setEndFloor(30) })
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        try rejectedConfig.write(to: h.home.paths.configFile)
        XCTAssertFalse(appEnds(m, critical: true, battery: 40))
        try agent.setBattery(40)
        let keptHot = try await agentEnds(level: 3)
        XCTAssertFalse(keptHot, "the rule turned off is the one recorded: \(logText())")
        try session.write(to: h.home.paths.sessionFile)
        try journal.write(to: h.home.paths.stateFile)
        try rejectedConfig.write(to: h.home.paths.configFile)
        XCTAssertTrue(appEnds(m, critical: false, battery: 20))
        try agent.setBattery(20)
        let ended = try await agentEnds(level: 0)
        XCTAssertTrue(ended, logText())
        await m.noticeAgentEnd()
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try recorded())

        try h.store.saveConfig(m.config)
        XCTAssertTrue(m.updateConfig { $0.setEndFloor(50) })
        XCTAssertNil(try recorded(), "no session, nothing recorded")
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 50, thermalRules: false), "the next Start records its own")
        await m.end(reason: .user)
        XCTAssertNil(try recorded(), "an ordinary end clears it")
    }

    /// A cutoff change whose record cannot be written (state.json
    /// immutable, or the recovery lock busy with an agent run) changes
    /// neither side and says why; a retry once it can be written applies
    /// it. A change whose config.json write fails after the record was
    /// written puts the record back, so the agent keeps the old cutoffs
    /// too, also once config.json is rejected.
    func testACutoffChangeThatCannotBeRecordedChangesNeitherSide() async throws {
        let m = try await startWith(endFloor: 10)
        let before = AgentCutoffs(endFloor: 10, thermalRules: true)
        let state = h.home.paths.stateFile
        try setImmutable(state, true)

        XCTAssertFalse(m.updateConfig { $0.setEndFloor(30) })

        try setImmutable(state, false)
        XCTAssertEqual(m.config.agentCutoffs, before)
        XCTAssertEqual(try h.store.loadConfig()?.agentCutoffs, before, "config.json is not written")
        XCTAssertEqual(try recorded(), before)
        let error = try XCTUnwrap(m.configSaveError)
        XCTAssertTrue(error.hasPrefix("Could not record the change for the session in state.json ("), error)
        XCTAssertTrue(error.hasSuffix("so both stay at end floor 10%, thermal rules on."), error)

        let lock = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
        XCTAssertFalse(m.updateConfig { $0.setEndFloor(30) })
        lock.release()
        XCTAssertEqual(m.config.agentCutoffs, before)
        XCTAssertEqual(try recorded(), before)
        XCTAssertTrue(try XCTUnwrap(m.configSaveError).contains("the recovery lock is busy"))

        XCTAssertTrue(m.updateConfig { $0.setEndFloor(30) }, "the retry")
        XCTAssertNil(m.configSaveError)
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 30, thermalRules: true))
        XCTAssertEqual(try h.store.loadConfig()?.endFloor, 30)

        try setImmutable(h.home.paths.configFile, true)
        XCTAssertFalse(m.updateConfig { $0.setEndFloor(50) })
        try setImmutable(h.home.paths.configFile, false)
        XCTAssertEqual(m.config.endFloor, 30)
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 30, thermalRules: true), "put back")
        XCTAssertTrue(try XCTUnwrap(m.configSaveError).hasPrefix("Could not save the change to config.json ("))

        try rejectedConfig.write(to: h.home.paths.configFile)
        XCTAssertFalse(appEnds(m, critical: false, battery: 40))
        try agent.setBattery(40)
        let kept = try await agentEnds(level: 0)
        XCTAssertFalse(kept, "the agent is on 30%, not the 50% that was refused: \(logText())")
    }

    /// Greptile 4219151883: a cutoff change whose config.json write fails
    /// after the record was written, and whose record then cannot be put
    /// back either (state.json made immutable between the two writes),
    /// leaves a journal recording cutoffs config.json does not carry,
    /// looser (30% to 10%) or stricter (10% to 30%) than the app's. Left
    /// running, a hung app's session would then be kept or ended by the
    /// agent against the app, once config.json is rejected (the replay
    /// below, on a copy of the disk with session.json put back). The
    /// session ends on disk before the lock is released instead:
    /// session.json is removed, or, when it is immutable too, recorded as
    /// ended in ended-session.json. Copies of the disk taken at that moment
    /// show that the agent, with the app hung, restores sleep, and that a
    /// relaunch resumes nothing. This process then ends the session as one
    /// whose cutoffs cannot be recorded, and resumes nothing either. The
    /// controls: with the record put back, the session runs on, and the
    /// agent enforces the old cutoffs at 20% (ends on 30%, keeps on 10%).
    func testACutoffChangeWhoseRecordCannotBePutBackEndsTheSession() async throws {
        let directions: [(from: AgentCutoffs, to: Int)] = [
            (AgentCutoffs(endFloor: 30, thermalRules: false), 10),
            (AgentCutoffs(endFloor: 10, thermalRules: true), 30),
        ]
        let session = h.home.paths.sessionFile, state = h.home.paths.stateFile, config = h.home.paths.configFile
        for (from, to) in directions {
            let changed = AgentCutoffs(endFloor: to, thermalRules: from.thermalRules)

            let control = try await startWith(endFloor: from.endFloor, thermalRules: from.thermalRules)
            try setImmutable(config, true)
            XCTAssertFalse(control.updateConfig { $0.setEndFloor(to) })
            try setImmutable(config, false)
            XCTAssertTrue(control.isActive)
            XCTAssertEqual(try recorded(), from, "put back")
            XCTAssertTrue(try XCTUnwrap(control.configSaveError).hasSuffix("so both stay at \(from.description)."))
            XCTAssertEqual(appEnds(control, critical: false, battery: 20), from.endFloor > 20)
            let kept = try diskCopy(config: rejectedConfig)
            defer { discard(kept) }
            let keptEnds = try await agentEndsCopy(kept, battery: 20)
            XCTAssertEqual(keptEnds, from.endFloor > 20, "\(from) put back")
            await control.end(reason: .user)

            for recordOnly in [false, true] {
                let label = "\(from) to \(changed), session.json \(recordOnly ? "immutable" : "removable")"
                let m = try await startWith(endFloor: from.endFloor, thermalRules: from.thermalRules)
                let sessionBytes = try Data(contentsOf: session)
                let configBytes = try Data(contentsOf: config)
                let holds = h.guardFake.calls.filter { $0 == "disablesleep 1" }.count
                let restores = h.guardFake.calls.filter { $0 == "disablesleep 0" }.count
                try? FileManager.default.removeItem(at: h.home.paths.logFile)
                try setImmutable(config, true)
                if recordOnly { try setImmutable(session, true) }
                m.beforeRecordedCutoffsPutBack = {
                    do { try setImmutable(state, true) } catch { XCTFail("state.json not made immutable: \(error)") }
                }

                XCTAssertFalse(m.updateConfig { $0.setEndFloor(to) })

                // Nothing here awaits until the flags are cleared: the end
                // in process has not run, and the disk is what the update
                // left when it released the lock.
                let crashed = try diskCopy(config: rejectedConfig)
                let relaunched = try diskCopy(config: configBytes)
                let unended = try diskCopy(config: rejectedConfig)
                defer { [crashed, relaunched, unended].forEach(discard) }
                try sessionBytes.write(to: unended.home.paths.sessionFile)
                try? FileManager.default.removeItem(at: unended.home.paths.endedSessionFile)
                if recordOnly {
                    XCTAssertEqual(try Data(contentsOf: session), sessionBytes, label)
                    XCTAssertEqual(try Data(contentsOf: h.home.paths.endedSessionFile), sessionBytes, "the end is recorded: \(label)")
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: session.path), "the end: \(label)")
                }
                XCTAssertEqual(try recorded(), changed, "not put back: \(label)")
                XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, label)
                XCTAssertEqual(m.config.agentCutoffs, from, label)
                XCTAssertEqual(try h.store.loadConfig()?.agentCutoffs, from, label)
                XCTAssertEqual(m.pendingEnd, .cutoffsNotRecorded, label)
                let error = try XCTUnwrap(m.configSaveError, label)
                XCTAssertTrue(error.hasPrefix("Could not save the change to config.json ("), error)
                XCTAssertTrue(error.contains(", or put back the end floor and thermal rules recorded for the session in state.json ("), error)
                if recordOnly {
                    XCTAssertTrue(error.contains("so Insomnia ended the session: session.json could not be removed ("), error)
                    XCTAssertTrue(error.contains("its end is recorded, so a relaunch will not resume it."), error)
                } else {
                    XCTAssertTrue(error.contains("so Insomnia ended the session. The settings"), error)
                }
                XCTAssertTrue(error.hasSuffix(" The settings stay at \(from.description)."), error)
                let lock = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire(), "the lock is released: \(label)")
                lock.release()
                try setImmutable(state, false)
                try setImmutable(config, false)
                if recordOnly { try setImmutable(session, false) }
                m.beforeRecordedCutoffsPutBack = nil

                let replayEnds = try await agentEndsCopy(unended, battery: 20)
                XCTAssertEqual(replayEnds, changed.endFloor > 20, "the replay, on the record: \(label)")
                XCTAssertNotEqual(changed.endFloor > 20, appEnds(m, critical: false, battery: 20), "the app disagrees: \(label)")

                let crashedEnds = try await agentEndsCopy(crashed, battery: 20)
                XCTAssertTrue(crashedEnds, "hung app: \(label)")
                let log = (try? String(contentsOf: crashed.home.paths.logFile, encoding: .utf8)) ?? ""
                XCTAssertTrue(log.contains(recordOnly ? "already ended (recorded in" : "no session; restoring from journal"), "\(label): \(log)")
                XCTAssertFalse(log.contains("end floor"), "\(label): \(log)")

                let relaunch = relaunched.makeManager()
                await relaunch.reconcile()
                XCTAssertFalse(relaunch.isActive, "relaunch: \(label)")
                XCTAssertNil(try relaunched.store.loadSession(), label)
                XCTAssertFalse(relaunched.guardFake.calls.contains("disablesleep 1"), "\(label): \(relaunched.guardFake.calls)")
                XCTAssertTrue(relaunched.guardFake.calls.contains("disablesleep 0"), "\(label): \(relaunched.guardFake.calls)")

                await waitUntil("the end in process: \(label)") { !m.isActive && m.pendingEnd == nil }
                XCTAssertNil(try h.store.loadSession(), label)
                XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.endedSessionFile.path), label)
                XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, false, label)
                XCTAssertNil(try recorded(), label)
                XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 0" }.count, restores + 1, label)
                XCTAssertTrue(logText().contains("settings: could not put the session's recorded \(from.description) back in state.json ("), logText())
                XCTAssertTrue(logText().contains("session end (cutoffsNotRecorded)"), logText())
                XCTAssertFalse(logText().contains("the recovery agent ended it"), logText())
                XCTAssertTrue(h.notifier.posts.contains { $0.body.contains("could not record the session's end floor and thermal rules in state.json") }, label)

                let again = h.makeManager()
                await again.reconcile()
                XCTAssertFalse(again.isActive, "relaunch after the end: \(label)")
                XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, holds, "nothing held sleep again: \(label)")
            }
        }
    }

    /// A home of its own holding the session, its recorded end and the
    /// journal as the app's folder holds them now, with `config` as
    /// config.json: what an agent run or a relaunch reads if this process
    /// stops here (crashes, or hangs holding the alive lock). The app's log
    /// lines stay in this home's insomnia.log. Removed with `discard`.
    private func diskCopy(config: Data) throws -> Harness {
        let copy = Harness()
        setenv(Paths.environmentKey, h.home.root.path, 1)
        try copy.home.paths.createDirectories()
        for file in [h.home.paths.sessionFile, h.home.paths.endedSessionFile, h.home.paths.stateFile]
        where FileManager.default.fileExists(atPath: file.path) {
            try Data(contentsOf: file).write(to: copy.home.paths.appSupport.appendingPathComponent(file.lastPathComponent))
        }
        try config.write(to: copy.home.paths.configFile)
        return copy
    }

    /// Removes a home `diskCopy` made, leaving INSOMNIA_HOME on this one
    /// (`TempHome.destroy` would point it at the process's).
    private func discard(_ copy: Harness) {
        try? FileManager.default.removeItem(at: copy.home.root)
    }

    /// One agent run on `copy`, on battery power at `battery`% and nominal
    /// heat, with the app alive and not answering. Returns whether it ended
    /// the session: session.json gone and sleep restored.
    private func agentEndsCopy(_ copy: Harness, battery: Int) async throws -> Bool {
        let run = try PatchedBackstop(home: copy.home.root, dir: copy.home.root.appendingPathComponent("agent", isDirectory: true))
        try run.setThermal(0)
        try run.setBattery(battery)
        let hung = AppAliveLock(url: copy.home.paths.appAliveFile)
        XCTAssertTrue(try hung.tryAcquire())
        let exit = try await run.run()
        hung.release()
        let log = (try? String(contentsOf: copy.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertEqual(exit, 0, log)
        let ended = try copy.store.loadSession() == nil
        XCTAssertEqual(run.calls.contains(run.restoreCall), ended, run.calls.joined(separator: "\n"))
        XCTAssertEqual(try copy.store.loadState()?.sleepDisabledByUs, !ended, log)
        return ended
    }

    /// Polls for the effect of a task this test does not await.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), what)
    }

    /// The tick records the cutoffs in use where the journal holds none
    /// (a session an older build started, or one written before this
    /// build), other cutoffs (a hand edit), or a value the app does not
    /// write; and after the app adopts a hand edit of config.json, here a
    /// floor of 200 that the decoder clamps to 95.
    func testTheTickRecordsTheCutoffsInUse() async throws {
        let m = try await startWith(endFloor: 30, thermalRules: false)
        let cutoffs = AgentCutoffs(endFloor: 30, thermalRules: false)
        let base = #"{"sleepDisabledByUs":true,"lowPowerSetByUs":false,"frozenProcesses":[],"dockerFrozen":false"#
        for value in ["", #","sessionCutoffs":"0 true""#, #","sessionCutoffs":"96 false""#, #","sessionCutoffs":30"#] {
            try Data((base + value + "}").utf8).write(to: h.home.paths.stateFile)
            await m.noticeConfigFileChange()
            XCTAssertTrue(m.isActive)
            XCTAssertEqual(try recorded(), cutoffs, value)
        }
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        await m.noticeConfigFileChange()
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), journal, "a record that matches is not written again")

        try Data(#"{"endFloor":200,"thermalRules":false,"configVersion":2,"lidCloseDefaultsApplied":true}"#.utf8).write(to: h.home.paths.configFile)
        await m.noticeConfigFileChange()
        XCTAssertEqual(m.config.agentCutoffs, AgentCutoffs(endFloor: 95, thermalRules: false))
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 95, thermalRules: false))

        try rejectedConfig.write(to: h.home.paths.configFile)
        try await assertBoth(m, critical: false, battery: 94, end: true)
    }

    /// A transaction that cannot record the cutoffs in use for the running
    /// session (state.json immutable after a hand edit of config.json to a
    /// 30% floor) ends it, as a rejected config.json does, and says why.
    /// The journal cannot be cleared either, so the end's notice is the
    /// incomplete restore. The next Start, once state.json takes writes,
    /// records them.
    func testASessionWhoseCutoffsCannotBeRecordedEnds() async throws {
        let m = try await startWith(endFloor: 10)
        var edited = m.config
        edited.setEndFloor(30)
        try h.store.saveConfig(edited)
        try setImmutable(h.home.paths.stateFile, true)

        await m.noticeConfigFileChange()

        try setImmutable(h.home.paths.stateFile, false)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("ending the session: could not record its end floor 30%, thermal rules on in state.json"), logText())
        XCTAssertTrue(logText().contains("session end (cutoffsNotRecorded)"), logText())

        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 30, thermalRules: true))
    }

    /// A session resumed after a crash or at login records its cutoffs
    /// again, also over a journal an older build wrote without them, before
    /// sleep is held for it.
    func testAResumedSessionRecordsItsCutoffs() async throws {
        let first = try await startWith(endFloor: 30, thermalRules: false)
        XCTAssertTrue(first.isActive)
        var journal = try XCTUnwrap(try h.store.loadState())
        journal.sessionCutoffs = nil
        try h.store.saveState(journal)

        let m = h.makeManager()
        await m.reconcile()

        XCTAssertTrue(m.isActive, "resumed")
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 30, thermalRules: false))
        try rejectedConfig.write(to: h.home.paths.configFile)
        try agent.setBattery(20)
        let ended = try await agentEnds(level: 0)
        XCTAssertTrue(ended, logText())
    }

    // MARK: When the app's binary cannot answer

    /// The agent cannot read config.json without the app's binary. When the
    /// bundle declares no `--agent-cutoffs` version, the binary is missing,
    /// it answers something else or does not answer in time, the agent
    /// enforces the strictest cutoffs, a 95% end floor and thermal rules
    /// on, and logs why: on a file with both off, it ends a session at 94%
    /// and keeps one at 95%. Each answer the binary gives here is one the
    /// script does not take.
    func testTheAgentEnforcesTheStrictestCutoffsWhenTheAppBinaryCannotAnswer() async throws {
        var c = Config()
        c.setEndFloor(0)
        c.thermalRules = false
        try h.store.saveConfig(c)
        let control = try await agentEnds(atBattery: 94)
        XCTAssertFalse(control, "the binary answers: \(logText())")

        let cases: [(why: String, breakIt: () throws -> Void)] = [
            ("declares InsomniaAgentCutoffsVersion '', not \(AgentCutoffsCommand.version)", { try self.agent.withdrawAgentCutoffs() }),
            ("is missing or not executable", { try FileManager.default.removeItem(at: self.agent.appBinary) }),
            ("unexpected answer from '\(agent.appBinary.path) --agent-cutoffs' (exit 0, output 'cutoffs 96 false')", { try self.agent.replaceAppBinary(with: "echo 'cutoffs 96 false'") }),
            ("(exit 0, output 'rejected')", { try self.agent.replaceAppBinary(with: "echo rejected") }),
            ("(exit 65, output 'cutoffs 0 false')", { try self.agent.replaceAppBinary(with: "echo 'cutoffs 0 false'; exit 65") }),
            ("(exit 1, output '')", { try self.agent.replaceAppBinary(with: "exit 1") }),
            ("did not answer within 1s", {
                try self.agent.replaceAppBinary(with: "exec /bin/sleep 300")
                try self.agent.setCommandTimeout(1)
            }),
        ]
        for (why, breakIt) in cases {
            agent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent", isDirectory: true))
            try breakIt()
            try? FileManager.default.removeItem(at: h.home.paths.logFile)
            let ends = try await agentEnds(atBattery: 94)
            XCTAssertTrue(ends, "\(why): \(logText())")
            XCTAssertTrue(logText().contains("below the 95% end floor"), logText())
            XCTAssertTrue(logText().contains(why), "\(why): \(logText())")
            XCTAssertTrue(logText().contains("enforcing the strictest, a 95% end floor and thermal rules on"), logText())
            let kept = try await agentEnds(atBattery: 95)
            XCTAssertFalse(kept, "\(why): \(logText())")
            try agent.setThermal(3)
            let exit = try await agent.run()
            XCTAssertEqual(exit, 0, logText())
            XCTAssertNil(try h.store.loadSession(), "\(why): the thermal rule is on: \(logText())")
        }
    }

    /// The agent reads the journal's record itself when the app's binary
    /// cannot answer for config.json (it is not run again on the journal)
    /// or for the journal: the round-24 session on a 30% floor with the
    /// thermal rules off ends at 29% and is kept at 31% at critical heat,
    /// with config.json rejected, missing, or one the binary could not
    /// read, and the log says the record was read here. A journal without
    /// a record gives the defaults where config.json was missing (a session
    /// an older build started: kept at 20%, ended at 9%), and the strictest
    /// cutoffs where config.json is there and the binary could not read it,
    /// rejected or not.
    func testTheAgentReadsTheRecordItselfWhenTheAppBinaryCannotAnswer() async throws {
        _ = try await startWith(endFloor: 30, thermalRules: false)
        XCTAssertEqual(try recorded(), AgentCutoffs(endFloor: 30, thermalRules: false))
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        let config = try Data(contentsOf: h.home.paths.configFile)
        let breaks: [(why: String, breakIt: () throws -> Void)] = [
            ("declares InsomniaAgentCutoffsVersion '', not \(AgentCutoffsCommand.version)", { try self.agent.withdrawAgentCutoffs() }),
            ("is missing or not executable", { try FileManager.default.removeItem(at: self.agent.appBinary) }),
            ("(exit 0, output 'cutoffs 96 false')", { try self.agent.replaceAppBinary(with: "echo 'cutoffs 96 false'") }),
            ("did not answer within 1s", {
                try self.agent.replaceAppBinary(with: "exec /bin/sleep 300")
                try self.agent.setCommandTimeout(1)
            }),
        ]
        let configs: [(name: String, write: () throws -> Void)] = [
            ("read", { try config.write(to: self.h.home.paths.configFile) }),
            ("rejected", { try self.rejectedConfig.write(to: self.h.home.paths.configFile) }),
            ("missing", { try? FileManager.default.removeItem(at: self.h.home.paths.configFile) }),
        ]
        for (why, breakIt) in breaks {
            agent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent", isDirectory: true))
            try breakIt()
            for (name, write) in configs {
                for (battery, critical, end) in [(31, true, false), (29, false, true)] {
                    let label = "\(why), config.json \(name), \(battery)%, critical \(critical)"
                    try session.write(to: h.home.paths.sessionFile)
                    try journal.write(to: h.home.paths.stateFile)
                    try write()
                    try? FileManager.default.removeItem(at: h.home.paths.logFile)
                    agent.clearCalls()
                    try agent.setBattery(battery)
                    let ended = try await agentEnds(level: critical ? 3 : 0)
                    XCTAssertEqual(ended, end, "\(label): \(logText())")
                    XCTAssertTrue(logText().contains(why), "\(label): \(logText())")
                    XCTAssertTrue(logText().contains("enforcing the cutoffs recorded for the session in \(h.home.paths.stateFile.path), read here: a 30% end floor and thermal rules off"), "\(label): \(logText())")
                    XCTAssertFalse(logText().contains("enforcing the strictest"), "\(label): \(logText())")
                }
            }
        }

        try FileManager.default.removeItem(at: agent.appBinary)
        var older = try Store.decodeState(journal)
        older.sessionCutoffs = nil
        let olderJournal = try Store.makeEncoder().encode(older)
        for (name, write, battery, end, log) in [
            ("missing", configs[2].write, 20, false, "records no cutoffs for the session (an older build started it), so the app's defaults apply"),
            ("missing", configs[2].write, 9, true, "below the 10% end floor"),
            ("rejected", configs[1].write, 94, true, "records no cutoffs for the session; enforcing the strictest, a 95% end floor and thermal rules on"),
            ("read", configs[0].write, 94, true, "records no cutoffs for the session; enforcing the strictest, a 95% end floor and thermal rules on"),
        ] as [(String, () throws -> Void, Int, Bool, String)] {
            try session.write(to: h.home.paths.sessionFile)
            try olderJournal.write(to: h.home.paths.stateFile)
            try write()
            try? FileManager.default.removeItem(at: h.home.paths.logFile)
            agent.clearCalls()
            try agent.setBattery(battery)
            let ended = try await agentEnds(level: 0)
            XCTAssertEqual(ended, end, "no record, config.json \(name), \(battery)%: \(logText())")
            XCTAssertTrue(logText().contains(log), "no record, config.json \(name), \(battery)%: \(logText())")
        }
    }

    /// A journal the scripts' check passes and the app's binary rejects as
    /// a whole (here a stand-in that answers so) is one the app does not
    /// load: the agent stops with the session and the journal kept, as for
    /// any journal its own check refuses.
    func testTheAgentKeepsTheSessionWhenTheAppsBinaryRejectsTheJournal() async throws {
        _ = try await startWith(endFloor: 30, thermalRules: false)
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        try FileManager.default.removeItem(at: h.home.paths.configFile)
        try agent.replaceAppBinary(with: #"[[ "$1" == --agent-session-cutoffs ]] && { echo rejected; exit 65; }; exit 1"#)
        try agent.setBattery(20)
        try agent.setThermal(0)

        let exit = try await agent.run()

        XCTAssertEqual(exit, 1, logText())
        XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), session)
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), journal)
        XCTAssertFalse(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertTrue(logText().contains("the app's decoder does not load it ('\(agent.appBinary.path) --agent-session-cutoffs' answered rejected)"), logText())
        XCTAssertTrue(logText().contains("is kept as it is: its cutoffs are not read and it is not ended"), logText())
    }

    // MARK: End floors outside 0...95

    /// endFloor as written in config.json, and the floor the app takes from
    /// it, clamped to 0...95, or nil where the app rejects the file. The
    /// agent asks the app's binary to decode the same bytes, so it enforces
    /// exactly that floor, or its default 10% where the app rejects the
    /// file. The decoder (measured on this macOS) takes an integer from
    /// -2^63 through 2^63 - 1. A number with a fraction or exponent goes
    /// through a double: a whole value from -2^63 + 1 through 2^63 - 513
    /// decodes, -2^63 written that way does not, and some values that are
    /// not whole decode by rounding (4.9999999999999999 is 5, 1e-400 is 0)
    /// while others fail the file (30.5). The texts around 2^63 are the
    /// last that decode on each side and the first that do not.
    private static let endFloorsWrittenAsIntegers: [(text: String, app: Int?)] = [
        ("0", 0), ("-1", 0), ("5", 5), ("10", 10), ("94", 94), ("95", 95), ("96", 95), ("200", 95),
        ("999999999999999999", 95), ("1000000000000000000", 95),
        ("9223372036854775806", 95), ("9223372036854775807", 95),
        ("-999999999999999999", 0), ("-1000000000000000000", 0),
        ("-9223372036854775807", 0), ("-9223372036854775808", 0),
        ("9223372036854775808", nil), ("18446744073709551615", nil), ("99999999999999999999", nil),
        ("-9223372036854775809", nil), ("-99999999999999999999", nil),
        ("+5", nil), ("0x5", nil), ("05", nil), ("+30", nil),
    ]

    private static let endFloorsWrittenAsFloats: [(text: String, app: Int?)] = [
        ("30.0", 30), ("3e1", 30), ("29.999999999999999999", 30), ("0.0", 0), ("-0.0", 0),
        ("-5.0", 0), ("-5e0", 0), ("0.0e400", 0),
        ("1e2", 95), ("1e16", 95), ("1e17", 95), ("123456789012345678.5", 95),
        ("9.2e18", 95), ("-9.2e18", 0), ("9223372036854775295.0", 95), ("-9223372036854775807.0", 0),
        ("9223372036854775000.0", 95), ("9.223372036854775295e18", 95),
        ("-9.2233720368547758e18", 0), ("-0.9223372036854775807e19", 0),
        ("9223372036854775296.0", nil), ("1e19", nil), ("-1e19", nil),
        ("-9223372036854775808.0", nil), ("-9223372036854775807.5", nil),
        ("-9223372036854775000.5", nil), ("-9.223372036854775808e18", nil),
        ("30.5", nil), ("-0.5", nil), ("1e-1", nil), (#""30""#, nil), ("true", nil),
        ("5.", nil), ("-5.", nil), (".5e1", nil), ("+5.0", nil),
        ("4.9999999999999999", 5), ("1e-400", 0), ("-100000000000000000.5", 0),
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
    /// and keeps it at it (at 0%, for a floor of 0, which is off). Each of
    /// those agent runs gets its own home (`SeparateRun`), so they run
    /// several at a time.
    private func assertTheAgentFollowsTheApp(_ table: [(text: String, app: Int?)],
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        var runs: [(run: SeparateRun, ends: Bool)] = []
        for (row, (text, expected)) in table.enumerated() {
            let config = Data(#"{"endFloor": \#(text), "thermalRules": false}"#.utf8)
            try config.write(to: h.home.paths.configFile)
            let app = try? h.store.loadConfig()?.agentCutoffs.endFloor
            XCTAssertEqual(app, expected, "the app on endFloor \(text)", file: file, line: line)
            let floor = app ?? Config.agentDefaultCutoffs.endFloor
            if floor > 0 {
                runs.append((try SeparateRun(in: h, name: "\(row)-below", config: config, battery: floor - 1), true))
            }
            runs.append((try SeparateRun(in: h, name: "\(row)-at", config: config, battery: floor), false))
        }
        let ended = try await SeparateRun.runAll(runs.map(\.run))
        for ((run, ends), (status, ended)) in zip(runs, ended) {
            XCTAssertEqual(status, 0, run.log, file: file, line: line)
            XCTAssertEqual(ended, ends, "\(String(decoding: run.config, as: UTF8.self)): the agent \(ended ? "ends" : "keeps") a session at \(run.battery)%: \(run.log)", file: file, line: line)
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

    /// The round-21 review's case: during a session on the default 10%,
    /// config.json is replaced by one holding endFloor
    /// -9223372036854775809, which the app's decoder rejects. An app that has
    /// stopped answering keeps 10%, so at 5% the agent must end the session
    /// on its default instead of reading the floor as off. The same run on
    /// the app's settings is the control.
    func testARejectedEndFloorBelowIntMinDoesNotTurnTheAgentsCutoffOff() async throws {
        var c = Config()
        c.thermalRules = false
        try h.store.saveConfig(c)
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        try Data(#"{"configVersion":2,"lidCloseDefaultsApplied":true,"endFloor":-9223372036854775809,"thermalRules":false}"#.utf8)
            .write(to: h.home.paths.configFile)
        XCTAssertThrowsError(try h.store.loadConfig())
        XCTAssertTrue(appEnds(m, critical: false, battery: 5), "the app on \(m.config.agentCutoffs.description)")

        try agent.setBattery(5)
        let exit = try await agent.run()
        XCTAssertEqual(exit, 0, logText())
        XCTAssertNil(try h.store.loadSession(), "the agent keeps a session at 5% on a file the app rejects: \(logText())")
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertTrue(logText().contains("below the 10% end floor"), logText())

        try session.write(to: h.home.paths.sessionFile)
        try journal.write(to: h.home.paths.stateFile)
        try h.store.saveConfig(c)
        let control = try await agentEnds(atBattery: 5)
        XCTAssertTrue(control, "the agent on the app's settings: \(logText())")
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

/// One agent run on its own INSOMNIA_HOME inside a test's home, so that
/// runs which share nothing can go several at a time: config.json holding
/// `config`, a session on disk whose journal holds sleep, as the app leaves
/// one, the app's alive lock held, and the battery at `battery` percent on
/// battery power at nominal heat. The same as `agentEnds(atBattery:)`, one
/// home per run.
struct SeparateRun {
    let paths: Paths
    let config: Data
    let battery: Int
    let agent: PatchedBackstop
    let alive: AppAliveLock

    @MainActor init(in h: Harness, name: String, config: Data, battery: Int) throws {
        let root = h.home.root.appendingPathComponent("runs/\(name)", isDirectory: true)
        paths = Paths(root: root)
        try paths.createDirectories()
        self.config = config
        self.battery = battery
        try config.write(to: paths.configFile)
        let store = Store(paths: paths)
        let now = h.clock.now
        try store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(3600)))
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        try store.saveState(journal)
        agent = try PatchedBackstop(home: root, dir: root.appendingPathComponent("agent", isDirectory: true))
        try agent.setThermal(0)
        try agent.setBattery(battery)
        alive = AppAliveLock(url: paths.appAliveFile)
        guard try alive.tryAcquire() else { throw CocoaError(.fileLocking) }
    }

    var log: String { (try? String(contentsOf: paths.logFile, encoding: .utf8)) ?? "" }

    /// Runs each agent once, at most `width` at a time, then lets go of
    /// each alive lock. Returns, in order, each exit status and whether the
    /// run removed session.json.
    static func runAll(_ runs: [SeparateRun], width: Int = 8) async throws -> [(status: Int32, ended: Bool)] {
        var statuses = [Int32](repeating: -1, count: runs.count)
        try await withThrowingTaskGroup(of: (Int, Int32).self) { group in
            var next = 0
            func add() {
                guard next < runs.count else { return }
                let (i, agent) = (next, runs[next].agent)
                group.addTask { (i, try await agent.run()) }
                next += 1
            }
            for _ in 0..<width { add() }
            while let (i, status) = try await group.next() {
                statuses[i] = status
                add()
            }
        }
        return try zip(runs, statuses).map { run, status in
            run.alive.release()
            return (status, try Store(paths: run.paths).loadSession() == nil)
        }
    }
}
