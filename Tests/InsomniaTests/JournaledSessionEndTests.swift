import Foundation
import XCTest
@testable import Insomnia

/// A session ended while its session.json cannot be removed is recorded as
/// ended, and no later launch resumes it. These tests take the case where
/// ended-session.json cannot hold that record either: an unrelated record
/// there that cannot be replaced. The end then goes in the journal
/// (state.json's endedSession), before anything is undone, written by the
/// recovery agent (the real backstop.sh, tools patched to fakes) or by the
/// app. A record of one session.json never ends another. When the journal
/// cannot be written either, the record goes to a new file beside them
/// (ended-session.json.<8 letters or digits>), or in the log folder when
/// their folder takes no new file, and no launch resumes the session,
/// whatever SleepDisabled reads and whichever file is repaired. When no
/// record can be written at all (here MKTEMP fails, or both folders refuse
/// new files), the agent still restores sleep, and no launch holds sleep
/// again for that session while session.json cannot be replaced or the
/// journal cannot be written, or once pmset says sleep is not held.
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

    private func pinAll() throws {
        for file in [h.home.paths.sessionFile, h.home.paths.endedSessionFile, h.home.paths.stateFile] {
            try setImmutable(file, true)
        }
    }

    private func unpinAll() throws {
        for file in [h.home.paths.sessionFile, h.home.paths.endedSessionFile, h.home.paths.stateFile] {
            try setImmutable(file, false)
        }
    }

    /// The single record aside, which must hold session.json's bytes.
    private func recordAside(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let records = h.store.sessionEndRecordsAside()
        XCTAssertEqual(records.count, 1, "\(records)", file: file, line: line)
        let record = try XCTUnwrap(records.first, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: record), try Data(contentsOf: h.home.paths.sessionFile), file: file, line: line)
        return record
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
        h.guardFake.sleepDisabled = true // the newer session's hold
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
    /// state.json are all immutable and the agent cannot create a record
    /// aside. The agent restores sleep but keeps sleepDisabledByUs; the
    /// relaunched app cannot write the journal, so it does not resume the
    /// session either. The app's pmset still reads SleepDisabled 1 here
    /// (the fake sudo above changes nothing it reads): the journal write
    /// alone keeps the session from resuming.
    func testACutoffThatCanRecordNothingIsNotResumedWhileTheJournalCannotBeWritten() async throws {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        try agent.refuseRecordsAside()

        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall))
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNil(try h.store.loadState()?.endedSession)
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])

        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("could not journal sleep guard"), logText())
    }

    /// An agent end that could record nothing, with all three files
    /// immutable and no record aside: the agent restores sleep, which the
    /// app's pmset then reads too, and keeps sleepDisabledByUs.
    private func endWithNothingRecorded() async throws {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        try agent.refuseRecordsAside()
        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNil(try h.store.loadState()?.endedSession)
        XCTAssertFalse(h.store.sessionEndIsRecorded())
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        XCTAssertTrue(logText().contains("could not remove \(h.home.paths.sessionFile.path) or record its end in \(h.home.paths.endedSessionFile.path), \(h.home.paths.stateFile.path) or a new file in"), logText())
        h.guardFake.sleepDisabled = false
    }

    private let undoneHoldLine = "reconcile: session.json holds a session whose sleep hold was undone while Insomnia was not running"

    /// The reviewer's case: after that end, state.json alone is made
    /// writable again and the app relaunches (holding the alive lock). The
    /// journal says sleep is held and pmset says it is not, so the session
    /// is ended, not held again, and its end is recorded in the journal
    /// this time. The agent then treats it as ended, and once session.json
    /// can be removed it goes.
    func testACutoffThatCanRecordNothingIsNotResumedOnceOnlyTheJournalCanBeWritten() async throws {
        try await endWithNothingRecorded()
        let marker = try marker()
        try setImmutable(h.home.paths.stateFile, false)
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }

        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, "a session the agent ended must not come back")
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertTrue(logText().contains(undoneHoldLine), logText())
        XCTAssertNotNil(try h.store.loadSession(), "session.json is still immutable")
        let journal = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(journal.endedSession, marker)
        XCTAssertFalse(journal.sleepDisabledByUs)

        let callsBefore = agent.calls.count
        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(h.home.paths.stateFile.path) (endedSession))"), logText())
        XCTAssertFalse(agent.calls.dropFirst(callsBefore).contains("pmset -g batt"), "no checks for a session recorded as ended")

        try setImmutable(h.home.paths.sessionFile, false)
        try await runAgent(expecting: 0)
        XCTAssertNil(try h.store.loadSession())
        let third = h.makeManager()
        await third.reconcile()
        XCTAssertFalse(third.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
    }

    /// The same end, then every file made writable again before the
    /// relaunch: the session is ended and its file removed, and sleep is
    /// not held again.
    func testACutoffThatCanRecordNothingIsNotResumedOnceEveryFileCanBeWritten() async throws {
        try await endWithNothingRecorded()
        for file in [h.home.paths.sessionFile, h.home.paths.endedSessionFile, h.home.paths.stateFile] {
            try setImmutable(file, false)
        }

        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, "a session the agent ended must not come back")
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains(undoneHoldLine), logText())
        XCTAssertNil(try h.store.loadSession())
        let journal = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(journal.isDirty)
        XCTAssertNil(journal.endedSession)
    }

    // MARK: The record aside

    /// The reviewer's files: session.json, an unrelated ended-session.json
    /// and state.json all immutable, the folder still writable. The agent
    /// (the app dead) records the end in a new file before it restores
    /// sleep. The next launch restores instead of resuming, later runs end
    /// it again without the checks and keep the record, and once the files
    /// can be changed session.json and the record go.
    func testAnAgentCutoffThatCanWriteOnlyANewFileIsRecordedAsideAndNotResumed() async throws {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)

        try await runAgent(expecting: 1)

        let record = try recordAside()
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertTrue(agent.namesAtSudo.contains(record.lastPathComponent), "recorded before sleep was restored: \(agent.namesAtSudo)")
        XCTAssertEqual(try Data(contentsOf: h.home.paths.endedSessionFile), unrelatedRecord)
        XCTAssertNil(try h.store.loadState()?.endedSession)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the journal could not be written")
        XCTAssertTrue(logText().contains("its end is recorded in \(record.path) instead"), logText())
        var info = stat()
        XCTAssertEqual(lstat(record.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, "a session the agent ended must not come back")
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("reconcile: session.json holds a session already ended (recorded in \(record.lastPathComponent)); restoring, not resuming"), logText())
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [record], "the app's end reuses the record")

        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        let callsBefore = agent.calls.count
        try await runAgent(expecting: 1)
        alive.release()
        XCTAssertTrue(logText().contains("already ended (recorded in \(record.path))"), logText())
        XCTAssertFalse(agent.calls.dropFirst(callsBefore).contains("pmset -g batt"), "no checks for a session recorded as ended")
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [record], "a record that matches stays")

        try unpinAll()
        try await runAgent(expecting: 0)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [], "the record goes with the file it copies")
    }

    /// The reviewer's two probes. After that end, only state.json is made
    /// writable and the app relaunches holding the alive lock while
    /// SleepDisabled reads 1: because the restore failed, or because
    /// something else set it again. The record aside ends the session all
    /// the same; neither the bit nor the journal's sleepDisabledByUs
    /// resumes it.
    private func endAsideThenRepairTheJournal(restoreFails: Bool) async throws {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        if restoreFails { try agent.failSudo() }

        try await runAgent(expecting: 1)
        let record = try recordAside()
        XCTAssertTrue(agent.calls.contains(agent.restoreCall))
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)

        h.guardFake.sleepDisabled = true
        try setImmutable(h.home.paths.stateFile, false)
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, "an agent cutoff stays final after the journal is repaired")
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("already ended (recorded in \(record.lastPathComponent))"), logText())
        XCTAssertNotNil(try h.store.loadSession(), "session.json is still immutable")
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [record])

        // The relaunch's own end could write the journal: now both record it.
        XCTAssertEqual(try h.store.loadState()?.endedSession, try marker())
        await next.noticeAgentEnd()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
    }

    func testAFailedRestoreDoesNotResumeASessionRecordedAsideOnceTheJournalIsRepaired() async throws {
        try await endAsideThenRepairTheJournal(restoreFails: true)
    }

    func testAnotherHoldDoesNotResumeASessionRecordedAsideOnceTheJournalIsRepaired() async throws {
        try await endAsideThenRepairTheJournal(restoreFails: false)
    }

    /// The same end, then every file made writable before a relaunch with
    /// SleepDisabled reading 1 (the restore failed): the session ends,
    /// session.json and its record go, and sleep is restored, not held.
    func testAFailedRestoreDoesNotResumeASessionRecordedAsideOnceEveryFileIsRepaired() async throws {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        try agent.failSudo()
        try await runAgent(expecting: 1)
        _ = try recordAside()

        h.guardFake.sleepDisabled = true
        try unpinAll()
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled, "the relaunch restores the hold the agent could not")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        let journal = try XCTUnwrap(try h.store.loadState())
        XCTAssertFalse(journal.isDirty)
    }

    /// The app ends its own session in the same files: it writes the
    /// record aside before it restores anything, says the end is recorded,
    /// and a relaunch and the agent both treat the session as over.
    func testAnAppEndThatCanWriteOnlyANewFileIsHonouredByARelaunchAndTheAgent() async throws {
        let m = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        let gate = AsyncGate()
        h.guardFake.restoreGate = gate

        let end = Task { @MainActor in _ = await m.end(reason: .user) }
        await gate.waitUntilStarted()
        let record = try recordAside()
        await gate.open()
        await end.value
        h.guardFake.restoreGate = nil

        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertTrue(h.notifier.posts.contains { $0.body.contains("its end is recorded, so a relaunch will not resume it") }, "\(h.notifier.posts)")
        XCTAssertTrue(logText().contains("its end is recorded in \(record.lastPathComponent)"), logText())

        h.guardFake.sleepDisabled = true // whatever the bit reads, no resume
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")

        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(record.path))"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [record])
    }

    /// While the app is running and stopped or busy, the agent ends its
    /// session on the battery floor and can record the end only aside. The
    /// app's next tick sees that record and ends its side.
    func testTheRunningAppNoticesAnEndRecordedAside() async throws {
        var c = Config()
        c.endFloor = 30
        try h.store.saveConfig(c)
        let m = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }

        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("battery"), logText())
        let record = try recordAside()

        XCTAssertTrue(m.isActive)
        let before = h.guardFake.calls.count
        await m.noticeAgentEnd()
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("is recorded as ended in \(record.lastPathComponent)"), logText())
    }

    /// A record aside of an earlier session.json (other bytes) ends
    /// nothing: the agent keeps the newer session of an app that is alive
    /// and within its floors and removes the stale record, a relaunch
    /// resumes the session past another such record, its tick does not end
    /// it, and its own end removes the record with session.json.
    func testARecordAsideOfAnEarlierSessionDoesNotEndANewerOne() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(3600)))
        let earlier = try Data(contentsOf: h.home.paths.sessionFile)
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(3600)))
        XCTAssertNotEqual(try Data(contentsOf: h.home.paths.sessionFile), earlier)
        let stale = h.home.paths.appSupport.appendingPathComponent("ended-session.json.Stale001")
        try earlier.write(to: stale)
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        try h.store.saveState(journal)
        h.guardFake.sleepDisabled = true // the newer session's hold
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }

        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertFalse(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a record that matches nothing goes")

        try earlier.write(to: stale)
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertTrue(m.isActive, logText())
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 1"))
        await m.noticeAgentEnd()
        XCTAssertTrue(m.isActive)

        _ = await m.end(reason: .user)
        XCTAssertFalse(m.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [], "an end removes the records with session.json")
    }

    /// Only a regular file with exactly the record's name is a record
    /// aside: a symlink to a copy of session.json, a FIFO and other names
    /// never end the session, the FIFO is never opened, and neither side
    /// removes any of them. A record nobody can read is not removed as
    /// stale and ends nothing.
    func testOnlyARegularFileOfTheRecordsShapeIsARecordAside() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        let dir = h.home.paths.appSupport
        let copy = h.home.root.appendingPathComponent("copy-of-session")
        try bytes.write(to: copy)
        let link = dir.appendingPathComponent("ended-session.json.Link0000")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: copy)
        let other = dir.appendingPathComponent("ended-session.json.Other0000")
        try bytes.write(to: other)
        let unreadable = dir.appendingPathComponent("ended-session.json.NoRead00")
        try bytes.write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let fifo = try FIFOWatch(at: dir.appendingPathComponent("ended-session.json.Fifo0000"))
        defer { fifo.stop() }

        XCTAssertEqual(h.store.sessionEndRecordsAside(), [unreadable])
        XCTAssertNil(h.store.sessionEndRecordAside())
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        try await runAgent(expecting: 0)
        XCTAssertFalse(fifo.readerSeen, "a FIFO named like a record was opened")
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertFalse(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        for kept in [link, other, unreadable] {
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: kept.path), kept.lastPathComponent)
        }
        await m.noticeAgentEnd()
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(fifo.readerSeen)
    }

    // MARK: The record in the log folder

    private var logs: URL { h.home.paths.logs }

    /// The round-22 review's files: session.json, an unrelated
    /// ended-session.json and state.json all immutable, and the folder
    /// holding them takes no new file. The agent (the app dead) cannot
    /// remove session.json or write any record there, so it writes the
    /// record in the log folder, reads it back, and only then restores
    /// sleep. Its status files fail in that folder too, so the run exits 1
    /// once its supervisor reports no result.
    private func endRecordedInTheLogFolder(restoreFails: Bool) async throws -> URL {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        if restoreFails { try agent.failSudo() }
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        defer { try? TestACL.removeAll(h.home.paths.appSupport) }

        try await runAgent(expecting: 1)

        let record = try recordAside()
        XCTAssertEqual(record.deletingLastPathComponent().resolvingSymlinksInPath(), logs.resolvingSymlinksInPath())
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertTrue(agent.logsAtSudo.contains(record.lastPathComponent), "recorded before sleep was restored: \(agent.logsAtSudo)")
        XCTAssertFalse(agent.namesAtSudo.contains { Paths.isEndedSessionAsideName($0) }, "\(agent.namesAtSudo)")
        XCTAssertEqual(try Data(contentsOf: h.home.paths.endedSessionFile), unrelatedRecord)
        XCTAssertNil(try h.store.loadState()?.endedSession)
        XCTAssertFalse(h.store.sessionEndIsRecorded())
        XCTAssertTrue(logText().contains("its end is recorded in \(record.path) instead"), logText())
        var info = stat()
        XCTAssertEqual(lstat(record.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        return record
    }

    /// Then the folder and state.json are repaired, SleepDisabled reads 1
    /// (the restore failed, or something else set it again) and the app
    /// launches first, holding the alive lock. The record in the log folder
    /// ends the session: no disablesleep 1. A later agent run ends it again
    /// without the checks, and once session.json can be removed, it and the
    /// record go.
    private func relaunchAfterTheFolderAndJournalAreRepaired(_ record: URL) async throws {
        try TestACL.removeAll(h.home.paths.appSupport)
        try setImmutable(h.home.paths.stateFile, false)
        h.guardFake.sleepDisabled = true
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, "the agent's end survives the folder and journal repair")
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("reconcile: session.json holds a session already ended (recorded in \(record.lastPathComponent)); restoring, not resuming"), logText())
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [record], "the app's end reuses the record")
        XCTAssertEqual(try h.store.loadState()?.endedSession, try marker(), "now the journal records it too")

        let callsBefore = agent.calls.count
        try await runAgent(expecting: 1)
        XCTAssertFalse(agent.calls.dropFirst(callsBefore).contains("pmset -g batt"), "no checks for a session recorded as ended")

        try unpinAll()
        try await runAgent(expecting: 0)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [], "the record goes with the file it copies")
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testAFailedRestoreRecordedInTheLogFolderIsNotResumedOnceTheFolderAndJournalAreRepaired() async throws {
        let record = try await endRecordedInTheLogFolder(restoreFails: true)
        try await relaunchAfterTheFolderAndJournalAreRepaired(record)
    }

    func testAnotherHoldDoesNotResumeASessionRecordedInTheLogFolder() async throws {
        let record = try await endRecordedInTheLogFolder(restoreFails: false)
        try await relaunchAfterTheFolderAndJournalAreRepaired(record)
    }

    /// The app ends its own session in the same files: it writes the
    /// record in the log folder before it restores anything, and a
    /// relaunch and the agent both treat the session as over.
    func testAnAppEndThatCanWriteOnlyInTheLogFolderIsHonouredByARelaunchAndTheAgent() async throws {
        let m = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        defer { try? TestACL.removeAll(h.home.paths.appSupport) }
        let gate = AsyncGate()
        h.guardFake.restoreGate = gate

        let end = Task { @MainActor in _ = await m.end(reason: .user) }
        await gate.waitUntilStarted()
        let record = try recordAside()
        XCTAssertEqual(record.deletingLastPathComponent().resolvingSymlinksInPath(), logs.resolvingSymlinksInPath())
        await gate.open()
        await end.value
        h.guardFake.restoreGate = nil

        XCTAssertFalse(m.isActive)
        XCTAssertTrue(h.notifier.posts.contains { $0.body.contains("its end is recorded, so a relaunch will not resume it") }, "\(h.notifier.posts)")
        try TestACL.removeAll(h.home.paths.appSupport)

        h.guardFake.sleepDisabled = true
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")

        try await runAgent(expecting: 1)
        XCTAssertTrue(logText().contains("already ended (recorded in \(record.path))"), logText())
        XCTAssertFalse(agent.calls.contains("pmset -g batt"), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [record])
    }

    /// A running app's tick sees a record in the log folder and ends its
    /// side; one of an earlier session.json ends nothing, and the agent
    /// removes it.
    func testTheRunningAppAndTheAgentReadTheLogFolder() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        let stale = logs.appendingPathComponent("ended-session.json.Stale001")
        try Data("an earlier session.json".utf8).write(to: stale)
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }

        await m.noticeAgentEnd()
        XCTAssertTrue(m.isActive, "a record of another session.json ends nothing")
        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertFalse(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a record that matches nothing goes")

        let record = logs.appendingPathComponent("ended-session.json.Match001")
        try bytes.write(to: record)
        let before = h.guardFake.calls.count
        await m.noticeAgentEnd()
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path), "the end removes the record with session.json")
    }

    /// In the log folder as beside session.json: a symlink to a copy of
    /// session.json, a FIFO and other names never end the session, the
    /// FIFO is never opened, and neither side removes any of them. A record
    /// nobody can read is not removed as stale and ends nothing. A log
    /// folder that is a symlink is not searched at all, by either side, and
    /// the app does not write a record through it.
    func testOnlyARegularFileInTheRealLogFolderIsARecord() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let bytes = try Data(contentsOf: h.home.paths.sessionFile)
        let copy = h.home.root.appendingPathComponent("copy-of-session")
        try bytes.write(to: copy)
        let link = logs.appendingPathComponent("ended-session.json.Link0000")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: copy)
        let other = logs.appendingPathComponent("ended-session.json.Other0000")
        try bytes.write(to: other)
        let unreadable = logs.appendingPathComponent("ended-session.json.NoRead00")
        try bytes.write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        let fifo = try FIFOWatch(at: logs.appendingPathComponent("ended-session.json.Fifo0000"))
        defer { fifo.stop() }

        XCTAssertEqual(h.store.sessionEndRecordsAside(), [unreadable])
        XCTAssertNil(h.store.sessionEndRecordAside())
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        try await runAgent(expecting: 0)
        XCTAssertFalse(fifo.readerSeen, "a FIFO named like a record was opened")
        XCTAssertNotNil(try h.store.loadSession())
        XCTAssertFalse(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        for kept in [link, other, unreadable] {
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: kept.path), kept.lastPathComponent)
        }
        await m.noticeAgentEnd()
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(fifo.readerSeen)

        // The log folder replaced by a symlink to a folder holding a
        // matching record.
        let elsewhere = h.home.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try bytes.write(to: elsewhere.appendingPathComponent("ended-session.json.Elsewher"))
        let realLogs = h.home.root.appendingPathComponent("real-logs", isDirectory: true)
        try FileManager.default.moveItem(at: logs, to: realLogs)
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: elsewhere)
        defer {
            try? FileManager.default.removeItem(at: logs)
            try? FileManager.default.moveItem(at: realLogs, to: logs)
        }
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        await m.noticeAgentEnd()
        XCTAssertTrue(m.isActive, "a record through a symlinked log folder ends nothing")
        try await runAgent(expecting: 0)
        XCTAssertNotNil(try h.store.loadSession(), "the agent ends nothing on a record through a symlinked log folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("ended-session.json.Elsewher").path))

        try setImmutable(h.home.paths.sessionFile, true)
        try setImmutable(h.home.paths.stateFile, true)
        try unrelatedRecord.write(to: h.home.paths.endedSessionFile)
        try setImmutable(h.home.paths.endedSessionFile, true)
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        defer { try? TestACL.removeAll(h.home.paths.appSupport) }
        XCTAssertNil(h.store.recordSessionEndAside(), "no record is written through the symlink")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), ["ended-session.json.Elsewher"])
    }

    /// Every place refuses the record: session.json, ended-session.json and
    /// state.json immutable, and neither the folder holding them nor the
    /// log folder takes a new file. The agent still restores sleep (here it
    /// fails, so SleepDisabled stays 1) and keeps sleepDisabledByUs. Then
    /// both folders and state.json are repaired and the app launches first.
    /// session.json still cannot be replaced, so the app does not hold
    /// sleep again for it: it ends it and records the end in the journal.
    func testAnEndRecordedNowhereIsNotResumedWhileSessionJSONCannotBeReplaced() async throws {
        _ = try await startThenPin()
        try setImmutable(h.home.paths.stateFile, true)
        try agent.failSudo()
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        try TestACL.denyNewFiles(in: logs)
        defer {
            try? TestACL.removeAll(h.home.paths.appSupport)
            try? TestACL.removeAll(logs)
        }

        try await runAgent(expecting: 1)
        XCTAssertTrue(agent.calls.contains(agent.restoreCall), agent.calls.joined(separator: "\n"))
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        XCTAssertFalse(h.store.sessionEndIsRecorded())
        XCTAssertNil(try h.store.loadState()?.endedSession)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertTrue(logText().contains("could not remove \(h.home.paths.sessionFile.path) or record its end in \(h.home.paths.endedSessionFile.path), \(h.home.paths.stateFile.path) or a new file in \(h.home.paths.appSupport.path) or \(logs.path)"), logText())

        try TestACL.removeAll(h.home.paths.appSupport)
        try TestACL.removeAll(logs)
        try setImmutable(h.home.paths.stateFile, false)
        h.guardFake.sleepDisabled = true
        let alive = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try alive.tryAcquire())
        defer { alive.release() }
        let marker = try marker()
        let before = h.guardFake.calls.count
        let next = h.makeManager()
        await next.reconcile()

        XCTAssertFalse(next.isActive, "a session whose end may have gone unrecorded must not come back")
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled, "the relaunch restores the hold the agent could not")
        XCTAssertTrue(logText().contains("but it cannot be replaced, so an end of it may have gone unrecorded"), logText())
        XCTAssertEqual(try h.store.loadState()?.endedSession, marker)
    }

    /// The cost of that rule: a session the app was running when it died,
    /// with nothing ended, is not resumed either while session.json cannot
    /// be replaced. The same crash with a writable session.json resumes.
    func testACrashedSessionWhoseFileCannotBeReplacedIsEndedNotResumed() async throws {
        let m = h.makeManager()
        await m.reconcile()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        let session = try Data(contentsOf: h.home.paths.sessionFile)
        let journal = try Data(contentsOf: h.home.paths.stateFile)
        try setImmutable(h.home.paths.sessionFile, true)

        var before = h.guardFake.calls.count
        let pinned = h.makeManager()
        await pinned.reconcile()
        XCTAssertFalse(pinned.isActive)
        XCTAssertFalse(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertTrue(logText().contains("but it cannot be replaced"), logText())

        // Undo that end: the same crash, but session.json can be replaced.
        try setImmutable(h.home.paths.sessionFile, false)
        try? FileManager.default.removeItem(at: h.home.paths.endedSessionFile)
        try session.write(to: h.home.paths.sessionFile)
        try journal.write(to: h.home.paths.stateFile)
        h.guardFake.sleepDisabled = true
        before = h.guardFake.calls.count
        let control = h.makeManager()
        await control.reconcile()
        XCTAssertTrue(control.isActive, logText())
        XCTAssertTrue(sleepHeldAgain(since: before), "\(h.guardFake.calls)")
        XCTAssertEqual(try Data(contentsOf: h.home.paths.sessionFile), session, "the rewrite keeps the same bytes")
    }

    /// The Store's side: a record goes in the log folder only when the
    /// folder beside session.json takes no new file, is found there, and
    /// is removed with session.json.
    func testTheStoreWritesARecordInTheLogFolderOnlyWhenItsOwnFolderRefuses() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        try TestACL.denyNewFiles(in: h.home.paths.appSupport)
        defer { try? TestACL.removeAll(h.home.paths.appSupport) }
        let record = try XCTUnwrap(h.store.recordSessionEndAside())
        XCTAssertEqual(record.deletingLastPathComponent().resolvingSymlinksInPath(), logs.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: record), try Data(contentsOf: h.home.paths.sessionFile))
        var info = stat()
        XCTAssertEqual(lstat(record.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(h.store.recordSessionEndAside(), record, "used again while it matches")
        try TestACL.removeAll(h.home.paths.appSupport)
        XCTAssertEqual(h.store.recordSessionEndAside(), record, "found in the log folder once the other takes files again")
        try h.store.deleteSession()
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))

        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let beside = try XCTUnwrap(h.store.recordSessionEndAside())
        XCTAssertEqual(beside.deletingLastPathComponent().resolvingSymlinksInPath(), h.home.paths.appSupport.resolvingSymlinksInPath(), "beside session.json first")
    }

    /// The app's record aside: created 0600 under a fresh name, used again
    /// while it matches, nil when session.json is gone, and removed with
    /// session.json.
    func testTheStoreWritesOneRecordAsideAndRemovesItWithTheSession() throws {
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(600)))
        let record = try XCTUnwrap(h.store.recordSessionEndAside())
        XCTAssertTrue(Paths.isEndedSessionAsideName(record.lastPathComponent), record.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: record), try Data(contentsOf: h.home.paths.sessionFile))
        var info = stat()
        XCTAssertEqual(lstat(record.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(h.store.recordSessionEndAside(), record)
        XCTAssertEqual(h.store.sessionEndRecordAside(), record)
        try h.store.deleteSession()
        XCTAssertEqual(h.store.sessionEndRecordsAside(), [])
        XCTAssertNil(h.store.recordSessionEndAside())
        for name in ["ended-session.json.Abcd123", "ended-session.json.Abcd12345", "ended-session.json.Abcd-123", "ended-session.json.Abcd123é"] {
            XCTAssertFalse(Paths.isEndedSessionAsideName(name), name)
        }
        XCTAssertTrue(Paths.isEndedSessionAsideName("ended-session.json.Abcd1234"))
    }
}
