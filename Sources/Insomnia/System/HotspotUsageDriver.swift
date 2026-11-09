import Foundation
import Observation

/// Owns the opt-in polling lifetime and disk state. It changes no network or
/// power settings. All work is injected for tests and read-only validation.
@MainActor
@Observable
final class HotspotUsageDriver {
    private(set) var status = HotspotUsageStatus()
    @ObservationIgnored var onChange: ((HotspotUsageStatus) -> Void)?
    @ObservationIgnored private let store: any HotspotUsageStoring
    @ObservationIgnored private let sampler: any HotspotUsageSampling
    @ObservationIgnored private let observer: any HotspotUsageObserving
    @ObservationIgnored private let notifier: any Notifying
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var file: HotspotUsageFile?
    @ObservationIgnored private var tracker: HotspotUsageTracker?
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var ssid = ""
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var budget: UInt64 = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pending: [String: Set<HotspotBudgetWarning>] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inflight: Task<Void, Never>?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var storageProblem: String?
    @ObservationIgnored private var monitorProblem: String?

    init(store: any HotspotUsageStoring, sampler: any HotspotUsageSampling = WiFiUsageSampler(),
         observer: any HotspotUsageObserving = WiFiUsageObserver(), notifier: any Notifying,
         clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.sampler = sampler
        self.observer = observer
        self.notifier = notifier
        self.clock = clock
    }

    func configure(config: Config, sessionActive: Bool, schedule: Bool = true) {
        let newSSID = config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabled == config.trackHotspotUsage, active == sessionActive, ssid == newSSID,
           budget == config.hotspotBudgetBytes, key != nil, file != nil { return }
        cancelPolling()
        flush(notify: false)
        enabled = config.trackHotspotUsage
        active = sessionActive
        budget = config.hotspotBudgetBytes
        ssid = newSSID
        key = ssid.isEmpty ? nil : HotspotUsageFile.key(for: ssid)
        tracker = nil
        status = HotspotUsageStatus(phase: basePhase)
        if load(), let key, let record = file?.records[key] {
            tracker = HotspotUsageTracker(ledger: record.ledger)
            enqueue(tracker!.setBudget(budget), for: key)
            remember()
        } else if file != nil, key != nil {
            tracker = HotspotUsageTracker(ledger: HotspotUsageLedger(budgetBytes: budget))
        }
        flush(notify: enabled && active)
        publish()
        if shouldPoll {
            _ = startWatching()
            if schedule {
                timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.requestSample() }
                }
                requestSample()
            }
        }
    }

    private var shouldPoll: Bool { enabled && active && !ssid.isEmpty }
    private var basePhase: HotspotUsagePhase {
        !enabled ? .off : ssid.isEmpty ? .missingHotspot : !active ? .idle : .waiting
    }

    private func load() -> Bool {
        if file != nil { return true }
        do {
            file = try store.load() ?? HotspotUsageFile()
            storageProblem = nil
            return true
        } catch {
            storageProblem = "Saved hotspot usage cannot be read. Tracking paused; reset explicitly to start again."
            publish()
            return false
        }
    }

    private func startWatching() -> Bool {
        guard !watching else { return true }
        do {
            try observer.start(changed: { [weak self] in self?.networkChanged() }, unavailable: { [weak self] in self?.monitorFailed() })
            watching = true
            monitorProblem = nil
            return true
        } catch {
            status.phase = .unavailable
            monitorProblem = "Wi-Fi change monitoring unavailable. Tracking paused."
            publish()
            return false
        }
    }

    func requestSample() {
        guard shouldPoll, inflight == nil else { return }
        let epoch = self.epoch
        inflight = Task { [weak self] in
            guard let self else { return }
            await self.sampleNow()
            if self.epoch == epoch { self.inflight = nil }
        }
    }

    /// Internal entry point for deterministic tests and the read-only probe.
    func sampleNow() async {
        guard shouldPoll, !reading, startWatching(), load(), let key else { return }
        if tracker == nil {
            tracker = HotspotUsageTracker(ledger: file?.records[key]?.ledger ?? HotspotUsageLedger(budgetBytes: budget))
            enqueue(tracker!.setBudget(budget), for: key)
        }
        reading = true
        let epoch = self.epoch
        defer { if self.epoch == epoch { reading = false } }
        let readingValue = await sampler.read()
        guard self.epoch == epoch, shouldPoll, !Task.isCancelled else { return }
        reading = false
        let connection: HotspotUsageConnection = readingValue.ssid == nil ? .unavailable : readingValue.ssid == ssid ? .configuredHotspot : .otherNetwork
        enqueue(tracker!.record(readingValue.sample, connection: connection), for: key)
        status.phase = connection == .configuredHotspot && readingValue.sample != nil ? .tracking : connection == .otherNetwork ? .otherNetwork : .unavailable
        remember()
        flush(notify: true)
        publish()
    }

    private func enqueue(_ warnings: [HotspotBudgetWarning], for key: String) {
        pending[key, default: []].formUnion(warnings)
    }

    private func remember() {
        guard let key, let tracker, var file else { return }
        let record = HotspotUsageRecord(periodStarted: file.records[key]?.periodStarted ?? clock(), ledger: tracker.ledger)
        if file.records[key] != record {
            file.records[key] = record
            self.file = file
            dirty = true
        }
    }

    private func flush(notify: Bool) {
        if dirty, let file {
            do {
                try store.save(file)
                dirty = false
                storageProblem = nil
            } catch {
                storageProblem = "Hotspot usage could not be saved. Totals are kept in memory; budget notifications are pending."
                return
            }
        }
        guard notify, let key, let ledger = tracker?.ledger, let warnings = pending[key], !warnings.isEmpty else { return }
        let warning: HotspotBudgetWarning = warnings.contains(.reached) ? .reached : .approaching
        notifier.post(title: warning == .reached ? "Hotspot budget reached" : "Hotspot budget nearly used",
                      body: HotspotUsageText.body(warning, ledger: ledger))
        pending[key] = nil
    }

    private func publish() {
        status.problem = storageProblem ?? monitorProblem
        status.ledger = tracker?.ledger
        status.periodStarted = key.flatMap { file?.records[$0]?.periodStarted }
        onChange?(status)
    }

    func networkChanged() {
        epoch += 1
        reading = false
        inflight?.cancel()
        inflight = nil
        tracker?.interrupt()
        status.phase = basePhase
        remember()
        flush(notify: false)
        publish()
    }

    private func monitorFailed() {
        observer.stop()
        watching = false
        networkChanged()
        status.phase = .unavailable
        monitorProblem = "Wi-Fi change monitoring unavailable. Tracking paused."
        publish()
    }

    private func cancelPolling() {
        timer?.invalidate()
        timer = nil
        epoch += 1
        reading = false
        inflight?.cancel()
        inflight = nil
        observer.stop()
        watching = false
        tracker?.stop()
    }

    func stop() {
        active = false
        cancelPolling()
        status.phase = basePhase
        flush(notify: false)
        publish()
    }

    /// UI confirmation precedes this call. An unreadable file is replaced
    /// only here; normal polling never resets saved history on a read error.
    @discardableResult
    func reset() -> Bool {
        guard let key else { return false }
        let candidateTracker = HotspotUsageTracker(ledger: HotspotUsageLedger(budgetBytes: budget))
        var candidate = file ?? HotspotUsageFile()
        candidate.records[key] = HotspotUsageRecord(periodStarted: clock(), ledger: candidateTracker.ledger)
        do { try store.save(candidate) } catch {
            storageProblem = "Hotspot usage could not be reset. Saved totals were kept."
            publish()
            return false
        }
        epoch += 1
        reading = false
        inflight?.cancel()
        inflight = nil
        if file == nil { pending.removeAll() }
        file = candidate
        tracker = candidateTracker
        dirty = false
        pending[key] = nil
        storageProblem = nil
        status.phase = basePhase
        publish()
        return true
    }

    var resetMessage: String {
        file == nil ? "Saved usage cannot be read. Reset replaces all saved hotspot usage history. The power restoration journal is unaffected." : "Clear this hotspot's tracked total and warning history? Other hotspots' totals are kept."
    }
}
