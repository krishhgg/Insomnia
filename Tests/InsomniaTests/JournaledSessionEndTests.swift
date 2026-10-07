import Foundation
import XCTest
@testable import Insomnia

/// A session ended while its session.json cannot be removed is recorded as
/// ended, and no later launch resumes it. These tests take the case where
/// ended-session.json cannot hold that record either: an unrelated record
/// there that cannot be replaced. The end then goes in the journal
/// (state.json's endedSession), before anything is undone, written by the
/// recovery agent (the real backstop.sh, tools patched to fakes) or by the
/// app. A record of one session.json never ends another, and a journal
/// that cannot be written holds no session either.
@MainActor
final class JournaledSessionEndTests: XCTestCase {
    var h: Harness!
    var agent: PatchedBackstop!

    override func setUp() async throws {
        h = Harness()
        try h.home.paths.createDirectories()
        agent = try PatchedBackstop(home: h.home.root, dir: h.home.root.appendingPathComponent("agent", isDirectory: true))
    }

    override func tearDown() async throws {
        for file in [h.home.paths.sessionFile, h.home.paths.endedSessionFile, h.home.paths.stateFile] {
            try? setImmutable(file, false)
        }
        h.home.destroy()
    }

    private let unrelatedRecord = Data("an end record of some other session.json".utf8)

    /// A running session, then an unrelated ended-session.json, and both
    /// files made immutable: neither can be removed or replaced.
    private func startThenPin() async throws -> SessionManager {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        try unrelatedRecord.write(to: h.home.paths.endedSessionFile)
        try setImmutable(h.home.paths.sessionFile, true)
        try setImmutable(h.home.paths.endedSessionFile, true)
        return m
    }

    private func marker() throws -> String {
        try Data(contentsOf: h.home.paths.sessionFile).base64EncodedString()
    }

    private func runAgent(expecting status: Int32, file: StaticString = #filePath, line: UInt = #line) async throws {
        let exit = try await agent.run()
        XCTAssertEqual(exit, status, logText(), file: file, line: line)
    }

    private func logText() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    private func sleepHeldAgain(since count: Int) -> Bool {
        h.guardFake.calls.dropFirst(count).contains("disablesleep 1")
    }

    /// The reviewer's case. The app dies (its alive lock is free), and the
    /// agent ends the session but can neither remove session.json nor
    /// write ended-session.json. It records the end in the journal before
    /// it restores sleep, and the next launch restores instead of resuming.
    /// Later agent runs end it again without the checks. Once the file can
    /// be removed it goes, and the next Start removes the record before it
    /// writes its own session.json.
    func testAnAgentCutoffRecordedOnlyInTheJournalIsNotResumedByTheNextLaunch() async throws {
        _ = try await startThenPin()
        let marker = try marker()

        try await runAgent(expecting: 1)

        XCTAssertNotNil(try h.store.loadSession(), "session.json is still there")
        XCTAssertEqual(try Data(contentsOf: h.home.paths.endedSessionFile), unrelatedRecord)
        XCTAssertFalse(h.store.sessionEndIsRecorded())
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        let journal = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(journal.endedSession, marker)
        XCTAssertFalse(journal.sleepDisabledByUs)
        let atRestore = try Store.makeDecoder().decode(RuntimeState.self, from: XCTUnwrap(agent.stateAtSudo))
        XCTAssertEqual(atRestore.endedSession, marker, "recorded before sleep was restored")
        XCTAssertTrue(atRestore.sleepDisabledByUs)
        XCTAssertTrue(logText().contains("ending the session before its deadline"), logText())
        XCTAssertTrue(logText().contains("its end is recorded in \(h.home.paths.stateFile.path) (endedSession) instead"), logText())

        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, "a session the agent ended must not come back")
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("reconcile: session.json holds a session already ended (recorded in state.json); restoring, not resuming"), logText())
        XCTAssertEqual(try h.store.loadState()?.endedSession, marker, "the record stays while the file does")

        let callsBefore = agent.calls.count
        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(h.home.paths.stateFile.path) (endedSession))"), logText())
        XCTAssertFalse(agent.calls.dropFirst(callsBefore).contains("pmset -g batt"), "no checks for a session recorded as ended")

        try setImmutable(h.home.paths.sessionFile, false)
        try await runAgent(expecting: 0)
        XCTAssertNil(try h.store.loadSession())

        let third = h.makeManager()
        await third.reconcile()
        await third.start(duration: 600)
        XCTAssertTrue(third.isActive)
        XCTAssertNil(try h.store.loadState()?.endedSession, "a start removes the record of an earlier session")
    }

    /// The app's own end in the same files: it records the end in the
    /// journal before it restores anything, and both a relaunch and the
    /// agent then treat the session as over.
    func testAnAppEndRecordedOnlyInTheJournalIsHonouredByARelaunchAndTheAgent() async throws {
        let m = try await startThenPin()
        let marker = try marker()
        let gate = AsyncGate()
        h.guardFake.restoreGate = gate

        let end = Task { @MainActor in _ = await m.end(reason: .user) }
        await gate.waitUntilStarted()
        let atRestore = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(atRestore.endedSession, marker, "recorded before sleep is restored")
        XCTAssertTrue(atRestore.sleepDisabledByUs)
        await gate.open()
        await end.value
        h.guardFake.restoreGate = nil

        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState()?.endedSession, marker)
        XCTAssertTrue(h.notifier.posts.contains { $0.body.contains("its end is recorded, so a relaunch will not resume it") }, "\(h.notifier.posts)")

        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")

        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(h.home.paths.stateFile.path) (endedSession))"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"), agent.calls.joined(separator: "\n"))
    }

    /// While the app is running and stopped or busy, the agent ends its
    /// session (here on the battery floor) and can record the end only in
    /// the journal. The app's next tick sees that record and ends its side.
    func testTheRunningAppNoticesAnEndRecordedInTheJournal() async throws {
        var c = Config()
        c.endFloor = 30
        try h.store.saveConfig(c)
        let m = try await startThenPin()
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }

        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("battery"), logText())
        XCTAssertEqual(try h.store.loadState()?.endedSession, try marker())

        XCTAssertTrue(m.isActive)
        await m.noticeAgentEnd()
        XCTAssertFalse(m.isActive)
        XCTAssertTrue(logText().contains("is recorded as ended in state.json (endedSession)"), logText())
    }

    /// A record of an earlier session.json (other bytes) ends nothing: the
    /// agent keeps the newer session of an app that is alive and within its
    /// floors, the app resumes it after a relaunch, and its tick does not
    /// end it.
    func testARecordOfAnEarlierSessionDoesNotEndANewerOne() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(3600)))
        let earlier = try marker()
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(3600)))
        XCTAssertNotEqual(try marker(), earlier)
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        journal.endedSession = earlier
        try h.store.saveState(journal)
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }

        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertFalse(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))

        let m = h.makeManager()
        await m.reconcile()
        XCTAssertTrue(m.isActive, logText())
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 1"))
        await m.noticeAgentEnd()
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(try h.store.loadState()?.endedSession, earlier, "only a start or a removed session.json clears it")
    }

    /// Nothing can record the end: session.json, ended-session.json and
    /// state.json are all immutable. The agent restores sleep but keeps
    /// sleepDisabledByUs; the relaunched app cannot write the journal, so
    /// it does not resume the session either.
    func testACutoffThatCanRecordNothingIsNotResumedWhileTheJournalCannotBeWritten() async throws {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)

        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall))
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNil(try h.store.loadState()?.endedSession)

        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("could not journal sleep guard"), logText())
    }
}
