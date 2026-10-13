import Foundation
import Observation

/// Auto is armed explicitly, even while idle. Hold sleep BEFORE the lid
/// closes: an observer fired after clamshell sleep would be too late.
/// SessionManager remains the sole owner of power settings and recovery.
@MainActor
@Observable
final class AgentAutoController {
    private(set) var enabled = false
    private(set) var jobs: [AgentJob] = []
    private(set) var warnings: [String] = []
    private(set) var status = "Auto off"
    private(set) var pauseReason: EndReason?
    @ObservationIgnored private weak var manager: SessionManager?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observedSession = false
    @ObservationIgnored private let activity: AgentActivity
    @ObservationIgnored private let clock: () -> Date
    /// Nil lets deterministic tests supply snapshots without a real timer
    /// racing their injected jobs. Production always uses the default 2s.
    @ObservationIgnored private let pollInterval: TimeInterval?

    init(manager: SessionManager, clock: @escaping () -> Date = Date.init, pollInterval: TimeInterval? = 2) {
        self.manager = manager
        self.activity = AgentActivity(paths: manager.paths)
        self.clock = clock
        self.pollInterval = pollInterval
    }

    func setEnabled(_ value: Bool) async {
        guard value != enabled else { return }
        generation += 1
        pauseReason = nil
        enabled = value
        timer?.invalidate()
        timer = nil
        if !value {
            status = "Auto off"
            if manager?.session?.agentAuto == true || (polling && manager?.session == nil) {
                await manager?.end(reason: .user)
            }
            return
        }
        guard manager?.isActive != true else {
            enabled = false
            status = "End the timed session before enabling Auto"
            return
        }
        observedSession = false
        status = "Auto armed — checking agent work"
        if let pollInterval {
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.poll() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        await poll()
    }

    /// Called at end REQUEST time, before an in-flight power command returns.
    /// A floor, Quit, manual End or recovery failure must never be followed
    /// by Auto starting the same outstanding job again.
    func suspend(reason: EndReason) {
        guard enabled else { return }
        generation += 1
        enabled = false
        timer?.invalidate()
        timer = nil
        pauseReason = reason
        status = "Auto paused (\(reason.rawValue)) — enable again to resume"
    }

    func poll(snapshot supplied: AgentSnapshot? = nil) async {
        guard enabled, !polling, let manager else { return }
        polling = true
        defer { polling = false }
        let ticket = generation
        let now = clock()
        let activity = self.activity
        let snapshot: AgentSnapshot
        if let supplied { snapshot = supplied }
        else {
            snapshot = await Task.detached { activity.snapshot(now: now) }.value
        }
        guard enabled, generation == ticket else { return }
        jobs = snapshot.active
        warnings = snapshot.warnings
        if manager.session == nil, manager.startingSessionIsAuto == nil, manager.state.sleepDisabledByUs {
            suspend(reason: .recoveryUnavailable)
            return
        }
        if observedSession, manager.session == nil, manager.pendingEnd != .agentsFinished {
            suspend(reason: .timer)
            return
        }
        if manager.session != nil, manager.session?.agentAuto != true {
            suspend(reason: .user)
            return
        }
        if jobs.isEmpty {
            status = "Auto idle — no registered agent work; normal sleep allowed"
            observedSession = false
            if manager.session?.agentAuto == true { await manager.end(reason: .agentsFinished) }
            if manager.session == nil, manager.state.sleepDisabledByUs {
                suspend(reason: .recoveryUnavailable)
            }
            return
        }
        // A short rolling journal deadline makes the EXISTING launchd
        // backstop restore sleep if this app crashes, hangs or disconnects.
        // Each job is bounded by its own lease and hard deadline; the last
        // valid job to expire bounds the hold for their union.
        let endsAt = jobs.map { min($0.deadline, $0.heartbeatAt.addingTimeInterval(AgentJob.leaseSeconds)) }.max()!
        status = manager.session?.agentAuto == true
            ? "Auto — \(jobs.count) active job(s); awake for agent work"
            : "Auto — \(jobs.count) registered job(s); preparing sleep hold"
        guard manager.pendingEnd == nil else {
            status = "Auto — waiting for sleep restoration"
            return
        }
        if manager.session == nil {
            await manager.start(duration: endsAt.timeIntervalSince(now), agentAuto: true)
            guard enabled, generation == ticket else { return }
            observedSession = manager.session?.agentAuto == true
            if !observedSession {
                suspend(reason: .startFailed)
                return
            }
            status = "Auto — \(jobs.count) active job(s); awake for agent work"
            // Start can wait on launchd/pmset. A job finishing during that
            // wait must not gain a full lease of unnecessary awake time.
            if supplied == nil {
                let fresh = await Task.detached { activity.snapshot() }.value
                guard enabled, generation == ticket else { return }
                jobs = fresh.active
                warnings = fresh.warnings
                status = jobs.isEmpty
                    ? "Auto idle — no registered agent work; normal sleep allowed"
                    : "Auto — \(jobs.count) active job(s); awake for agent work"
                if jobs.isEmpty {
                    observedSession = false
                    await manager.end(reason: .agentsFinished)
                }
            }
        } else if let current = manager.session, endsAt.timeIntervalSince(current.endsAt) >= 10 || current.endsAt.timeIntervalSince(endsAt) >= 1 {
            await manager.renewAgentDeadline(endsAt)
        }
    }
}
