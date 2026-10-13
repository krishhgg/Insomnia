import Darwin
import Foundation
import XCTest
@testable import Insomnia

final class AgentActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let identity = ProcessIdentity(startedAt: 42, startedAtMicros: 12, bootSession: "test-boot")
    private func live(_ pid: Int32) -> ProcessLookup {
        .present(ProcessSignalState(ppid: 1, stopped: false, identity: identity))
    }

    func testBeginHeartbeatFinishAndOwnerOnlyFiles() throws {
        let home = TempHome(); defer { home.destroy() }
        let api = AgentActivity(paths: home.paths)
        let job = try api.begin(name: "Codex: issue 57", pid: 4242, now: now, uptime: 100, lookup: live)
        let original = try api.read(job.id)
        try api.heartbeat(job.id, now: now.addingTimeInterval(15), uptime: 115, lookup: live)
        let renewed = try api.read(job.id)
        XCTAssertEqual(renewed.deadline, original.deadline, "Heartbeats must never move the hard deadline")
        XCTAssertEqual(renewed.heartbeatUptime, 115)
        XCTAssertEqual(api.snapshot(now: now.addingTimeInterval(30), uptime: 130, lookup: live).active.count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: api.file(job.id).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try api.finish(job.id)
        try api.finish(job.id)
        XCTAssertTrue(api.snapshot(now: now, uptime: 100, lookup: live).active.isEmpty)
    }

    func testStaleLeaseCannotBeRevived() throws {
        let home = TempHome(); defer { home.destroy() }
        let api = AgentActivity(paths: home.paths)
        let job = try api.begin(name: "Claude turn", pid: 4242, now: now, uptime: 100, lookup: live)
        let stale = now.addingTimeInterval(90)
        XCTAssertTrue(api.snapshot(now: stale, uptime: 190, lookup: live).active.isEmpty)
        XCTAssertThrowsError(try api.heartbeat(job.id, now: stale, uptime: 190, lookup: live))
        XCTAssertEqual(try api.read(job.id).heartbeatAt, now)
    }

    func testIdleOrStoppedOwnerIsNotCompletionButExitedReusedOrUnverifiedOwnerIs() throws {
        let home = TempHome(); defer { home.destroy() }
        let api = AgentActivity(paths: home.paths)
        let job = try api.begin(name: "agent", pid: 4242, now: now, uptime: 100, lookup: live)
        XCTAssertNil(job.inactiveReason(at: now, uptime: 100) { _ in
            .present(ProcessSignalState(ppid: 1, stopped: true, identity: self.identity))
        })
        XCTAssertNotNil(job.inactiveReason(at: now, uptime: 100) { _ in .absent })
        XCTAssertNotNil(job.inactiveReason(at: now, uptime: 100) { _ in .unreadable(EPERM) })
        XCTAssertNotNil(job.inactiveReason(at: now, uptime: 100) { _ in
            .present(ProcessSignalState(ppid: 1, stopped: false,
                                       identity: ProcessIdentity(startedAt: 42, startedAtMicros: 13, bootSession: "test-boot")))
        })
    }

    func testHardLimitWinsDespiteHealthyHeartbeatAndWallClockRollback() throws {
        let home = TempHome(); defer { home.destroy() }
        let api = AgentActivity(paths: home.paths)
        var job = try api.begin(name: "stuck", pid: 4242, now: now, uptime: 100, lookup: live)
        job.heartbeatAt = now
        job.heartbeatUptime = 100 + AgentJob.maximumSeconds
        XCTAssertEqual(job.inactiveReason(at: now, uptime: job.heartbeatUptime, lookup: live), "8-hour safety limit reached")
        // A wall-clock jump forward also fails closed.
        XCTAssertNotNil(job.inactiveReason(at: job.deadline, uptime: 100, lookup: live))
    }

    func testMonotonicLeaseExpiresEvenWhenWallClockDoesNotAdvance() throws {
        let home = TempHome(); defer { home.destroy() }
        let api = AgentActivity(paths: home.paths)
        let job = try api.begin(name: "disconnected", pid: 4242, now: now, uptime: 100, lookup: live)
        XCTAssertNotNil(job.inactiveReason(at: now, uptime: 190, lookup: live))
    }

    func testRejectsSymlinkFIFOAndMalformedRecordWithoutBlocking() throws {
        let home = TempHome(); defer { home.destroy() }
        let api = AgentActivity(paths: home.paths)
        let job = try api.begin(name: "agent", pid: 4242, now: now, uptime: 100, lookup: live)
        let linkID = UUID()
        try FileManager.default.createSymbolicLink(at: api.file(linkID), withDestinationURL: api.file(job.id))
        XCTAssertThrowsError(try api.read(linkID))
        let fifoID = UUID()
        XCTAssertEqual(mkfifo(api.file(fifoID).path, 0o600), 0)
        XCTAssertThrowsError(try api.read(fifoID))
        let badID = UUID()
        try OwnerOnly.createFile(at: api.file(badID), contents: Data("{}".utf8))
        let snapshot = api.snapshot(now: now, uptime: 100, lookup: live)
        XCTAssertEqual(snapshot.active.map(\.id), [job.id])
        XCTAssertEqual(snapshot.warnings.count, 3)
    }

    func testUnknownBackgroundProcessesAndInvalidCLIArgumentsDoNotRegisterWork() {
        let home = TempHome(); defer { home.destroy() }
        XCTAssertTrue(AgentActivity(paths: home.paths).snapshot().active.isEmpty)
        XCTAssertEqual(AgentActivityCommand.run(["--agent", "heartbeat", "../../state.json"], paths: home.paths)?.status, 2)
        XCTAssertNil(AgentActivityCommand.run(["--unrelated"], paths: home.paths))
    }
}

@MainActor
final class AgentAutoTests: XCTestCase {
    private func job(_ h: Harness, name: String = "Codex", lease: TimeInterval = 90) -> AgentJob {
        let now = h.clock.now
        return AgentJob(id: UUID(), name: name, pid: 4242,
                        identity: ProcessIdentity(startedAt: 42, startedAtMicros: 12, bootSession: "test"),
                        startedAt: now, deadline: now.addingTimeInterval(8 * 3600),
                        heartbeatAt: now.addingTimeInterval(lease - 90),
                        startedUptime: 100, heartbeatUptime: 100)
    }

    private func controller(_ h: Harness, _ manager: SessionManager) -> AgentAutoController {
        let clock = h.clock
        let auto = AgentAutoController(manager: manager, clock: { clock.now })
        manager.agentAuto = auto
        return auto
    }

    func testIdleAutoDoesNotTouchPowerAndCompletionReleasesImmediately() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        await auto.setEnabled(true)
        XCTAssertTrue(auto.enabled)
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"))
        let work = job(h)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        XCTAssertEqual(m.session?.agentAuto, true)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadSession()?.agentAuto, true)
        await auto.poll(snapshot: AgentSnapshot())
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertTrue(auto.enabled, "Auto remains armed for the next turn")
        await auto.setEnabled(false)
    }

    func testMultipleJobsHoldUntilLastFinishesAndShortLeaseIsNotClampedToMinute() async {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        await auto.setEnabled(true)
        let first = job(h); let second = job(h, name: "Claude Code", lease: 5)
        await auto.poll(snapshot: AgentSnapshot(active: [first, second]))
        await auto.poll(snapshot: AgentSnapshot(active: [second]))
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(auto.jobs.map(\.name), ["Claude Code"])
        await auto.poll(snapshot: AgentSnapshot())
        await auto.poll(snapshot: AgentSnapshot(active: [second]))
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(5))
        await auto.setEnabled(false)
    }

    func testHeartbeatRenewsJournalButUserCannotExtendAuto() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        await auto.setEnabled(true)
        var work = job(h)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        h.clock.advance(15)
        work.heartbeatAt = h.clock.now
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(90))
        XCTAssertEqual(try h.store.loadSession()?.endsAt, m.session?.endsAt)
        let deadline = m.session?.endsAt
        await m.extend(by: 3600)
        XCTAssertEqual(m.session?.endsAt, deadline)
        await auto.setEnabled(false)
    }

    func testSafetyAndManualEndsDisarmSoOutstandingJobCannotRestart() async {
        for reason in [EndReason.batteryFloor, .batteryUnreadable, .thermalCritical, .user, .timer, .quit] {
            let h = Harness()
            let m = h.makeManager(); let auto = controller(h, m)
            await auto.setEnabled(true)
            let work = job(h)
            await auto.poll(snapshot: AgentSnapshot(active: [work]))
            await m.end(reason: reason)
            await auto.poll(snapshot: AgentSnapshot(active: [work]))
            XCTAssertFalse(auto.enabled, "\(reason)")
            XCTAssertFalse(m.isActive)
            XCTAssertFalse(h.guardFake.sleepDisabled)
            h.home.destroy()
        }
    }

    func testAutoSafetyCannotBeDisabledByTimedSessionSettings() async {
        for (battery, thermal, charging) in [(BatteryStatus.percent(9), ProcessInfo.ThermalState.nominal, false),
                                              (.percent(80), .critical, true),
                                              (.unreadable(misses: 2), .nominal, false)] {
            let h = Harness()
            let m = h.makeManager(); let auto = controller(h, m)
            m.config.endFloor = 0
            m.config.thermalRules = false
            await auto.setEnabled(true)
            await auto.poll(snapshot: AgentSnapshot(active: [job(h)]))
            XCTAssertEqual(m.floorConfig.endFloor, 10)
            XCTAssertTrue(m.floorConfig.thermalRules)
            await FloorRuleDriver(manager: m, notifier: h.notifier).run(battery: battery, isCharging: charging, thermal: thermal, lidClosed: true)
            XCTAssertFalse(m.isActive)
            XCTAssertFalse(auto.enabled)
            XCTAssertFalse(h.guardFake.sleepDisabled)
            h.home.destroy()
        }
    }

    func testTimedSessionAndAutoAreMutuallyExclusive() async {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        await m.start(duration: 3600)
        await auto.setEnabled(true)
        XCTAssertFalse(auto.enabled)
        XCTAssertNil(m.session?.agentAuto)
        await m.end(reason: .user)
    }

    func testDisableDuringSuspendedStartInvalidatesIt() async {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        await auto.setEnabled(true)
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let work = job(h)
        let start = Task { await auto.poll(snapshot: AgentSnapshot(active: [work])) }
        await gate.waitUntilStarted()
        let disable = await runUntilSuspended { await auto.setEnabled(false) }
        await gate.open()
        await start.value
        await disable.value
        XCTAssertFalse(auto.enabled)
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    func testFinishedWhileStartWaitedDoesNotKeepFullLease() async throws {
        let h = Harness(now: Date()); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        let api = AgentActivity(paths: h.home.paths)
        let work = try api.begin(name: "finite turn", pid: getpid())
        let gate = AsyncGate()
        h.backstop.armGate = gate
        let start = Task { await auto.setEnabled(true) }
        await gate.waitUntilStarted()
        try api.finish(work.id)
        await gate.open()
        await start.value
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        await auto.setEnabled(false)
    }

    func testRecoveryFailureEndsRatherThanRenewingWithoutBackstop() async {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        await auto.setEnabled(true)
        var work = job(h)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        h.clock.advance(15); work.heartbeatAt = h.clock.now
        h.backstop.failArm = true
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        XCTAssertFalse(auto.enabled)
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    func testRelaunchRestoresAutoInsteadOfReapplyingSleepHold() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 90, agentAuto: true)
        XCTAssertEqual(try h.store.loadSession()?.agentAuto, true)
        let previousCalls = h.guardFake.calls.filter { $0 == "disablesleep 1" }.count
        let relaunched = h.makeManager()
        await relaunched.reconcile()
        XCTAssertFalse(relaunched.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, previousCalls)
        XCTAssertNil(try h.store.loadSession())
        await m.end(reason: .user)
    }

    func testMenuShowsJobNameOwnerAndWarning() async {
        let h = Harness(); defer { h.home.destroy() }
        let m = h.makeManager(); let auto = controller(h, m)
        await auto.setEnabled(true)
        await auto.poll(snapshot: AgentSnapshot(active: [job(h, name: "Codex: issue 57")], warnings: ["old job: heartbeat expired"]))
        let items = StatusItemController.menuItems(manager: m, status: PlaceholderStatus())
        XCTAssertTrue(items.contains { $0.title.contains("Codex: issue 57") && $0.title.contains("4242") })
        XCTAssertTrue(items.contains { $0.title == "old job: heartbeat expired" && $0.kind == .warning })
        XCTAssertTrue(items.contains { $0.kind == .toggleAuto })
        await auto.setEnabled(false)
    }
}
