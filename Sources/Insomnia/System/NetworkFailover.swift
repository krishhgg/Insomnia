import Foundation
import Network
import Security

// MARK: - Pure state machine (spec section 7)

/// Drives hotspot failover from three events. No clocks, no timers, no I/O:
/// the driver owns those and feeds `Date`s in.
struct FailoverMachine: Sendable, Equatable {
    enum Output: Sendable, Equatable {
        case joinHotspot
        case scheduleRetry(after: TimeInterval)
        case recovered(start: Date, gap: TimeInterval)
    }

    /// Seconds the path must stay unsatisfied before the first join.
    static let initialDelay: TimeInterval = 5
    /// Delays after each join attempt: 5, 10, 20, 30, 30, 30, ...
    static let backoff: [TimeInterval] = [5, 10, 20, 30]

    private(set) var outageStart: Date?
    private(set) var joins: Int = 0
    private(set) var nextAttemptAt: Date?

    var inOutage: Bool { outageStart != nil }

    static func delay(afterJoin n: Int) -> TimeInterval {
        backoff[min(max(n - 1, 0), backoff.count - 1)]
    }

    mutating func pathUnsatisfied(at now: Date) -> [Output] {
        guard outageStart == nil else { return [] }
        outageStart = now
        joins = 0
        nextAttemptAt = now.addingTimeInterval(Self.initialDelay)
        return [.scheduleRetry(after: Self.initialDelay)]
    }

    mutating func pathSatisfied(at now: Date) -> [Output] {
        guard let start = outageStart else { return [] }
        outageStart = nil
        joins = 0
        nextAttemptAt = nil
        return [.recovered(start: start, gap: max(0, now.timeIntervalSince(start)))]
    }

    mutating func timerFired(at now: Date) -> [Output] {
        guard outageStart != nil, let due = nextAttemptAt, now >= due else { return [] }
        joins += 1
        let delay = Self.delay(afterJoin: joins)
        nextAttemptAt = now.addingTimeInterval(delay)
        return [.joinHotspot, .scheduleRetry(after: delay)]
    }

    /// One handoffs.log line per outage.
    static func logLine(start: Date, end: Date, gap: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        return "\(f.string(from: end)) outage start=\(f.string(from: start)) end=\(f.string(from: end)) gap=\(Int(gap.rounded()))s"
    }

    /// "2m 10s", "45s", "1h 2m 3s".
    static func humanGap(_ gap: TimeInterval) -> String {
        let total = Int(gap.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }
}

// MARK: - networksetup parsing

enum HardwarePortsParser {
    /// Device name of the Wi-Fi port in `networksetup -listallhardwareports`
    /// output, e.g. "en0".
    static func wifiInterface(from output: String) -> String? {
        var currentIsWifi = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                let name = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces)
                currentIsWifi = name == "Wi-Fi" || name == "AirPort" || name.lowercased().contains("wi-fi")
            } else if line.hasPrefix("Device:"), currentIsWifi {
                let dev = line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)
                if !dev.isEmpty { return dev }
            }
        }
        return nil
    }

    /// SSID from `networksetup -getairportnetwork en0`
    /// ("Current Wi-Fi Network: Foo"), nil when not associated.
    static func ssid(fromGetAirportNetwork output: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = line.range(of: "Current Wi-Fi Network:") else { return nil }
        let ssid = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return ssid.isEmpty ? nil : ssid
    }
}

// MARK: - Keychain

protocol KeychainStoring: Sendable {
    func get(service: String, account: String) throws -> String?
    func set(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

struct KeychainError: Error, LocalizedError, Sendable {
    let status: OSStatus
    var errorDescription: String? {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain: \(msg)"
    }
}

/// Login keychain generic password, service `insomnia-hotspot`, account = SSID.
struct KeychainStore: KeychainStoring {
    static let service = "insomnia-hotspot"

    func get(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func set(service: String, account: String, value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

final class FakeKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    func get(service: String, account: String) throws -> String? { lock.withLock { items["\(service)/\(account)"] } }
    func set(service: String, account: String, value: String) throws { lock.withLock { items["\(service)/\(account)"] = value } }
    func delete(service: String, account: String) throws { lock.withLock { _ = items.removeValue(forKey: "\(service)/\(account)") } }
}

// MARK: - Driver

/// NWPathMonitor on Wi-Fi, one retry timer that exists only during an
/// outage, CoreWLAN for the join, handoffs.log, tmux nudge and a
/// notification on recovery. Active only while a session is active.
@MainActor
final class NetworkFailover {
    static let networksetup = "/usr/sbin/networksetup"

    /// Called after every recovery with the gap length.
    var onRecovered: ((TimeInterval) -> Void)?

    private(set) var machine = FailoverMachine()
    private(set) var wifiInterface: String?
    private(set) var lastGap: TimeInterval?

    private let paths: Paths
    private let keychain: any KeychainStoring
    private let nudge: TmuxNudge
    private let hotspotJoiner: any HotspotJoining
    private let notifier: any Notifying
    private let configProvider: @MainActor () -> Config
    private let clock: @Sendable () -> Date

    private var monitor: NWPathMonitor?
    private(set) var retryTimer: Timer?
    private var generation = 0
    /// Bumped by `stop()`. Work that started under an older epoch (a
    /// recovery mid-nudge) stops issuing commands as soon as it notices.
    private var epoch = 0
    /// Path/timer work spawned by the driver, cancelled by `stop()`.
    private var inflight: [UUID: Task<Void, Never>] = [:]

    init(
        paths: Paths,
        keychain: any KeychainStoring = KeychainStore(),
        nudge: TmuxNudge = TmuxNudge(),
        hotspotJoiner: any HotspotJoining = CoreWLANHotspotJoiner(),
        notifier: any Notifying,
        wifiInterface: String? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        config: @escaping @MainActor () -> Config
    ) {
        self.paths = paths
        self.keychain = keychain
        self.nudge = nudge
        self.hotspotJoiner = hotspotJoiner
        self.notifier = notifier
        self.wifiInterface = wifiInterface
        self.clock = clock
        self.configProvider = config
    }

    func start() async {
        guard monitor == nil else { return }
        let epoch = self.epoch
        await resolveInterface()
        // stop() may have run while networksetup was being awaited.
        guard !Task.isCancelled, self.epoch == epoch else { return }
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        let id = ObjectIdentifier(m)
        m.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                // An update queued before stop() must not revive the driver.
                guard let self, let current = self.monitor, ObjectIdentifier(current) == id else { return }
                self.handlePath(satisfied: satisfied)
            }
        }
        m.start(queue: .main)
        monitor = m
        Log.info("network failover started (wifi \(wifiInterface ?? "unresolved"))")
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        cancelTimer()
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
        epoch += 1
        machine = FailoverMachine()
    }

    /// Current SSID via `networksetup -getairportnetwork`; nil when unknown.
    func currentSSID() async -> String? {
        if wifiInterface == nil { await resolveInterface() }
        guard let iface = wifiInterface else { return nil }
        do {
            let r = try await Shell.run(Self.networksetup, ["-getairportnetwork", iface], timeout: 5)
            return HardwarePortsParser.ssid(fromGetAirportNetwork: r.stdout)
        } catch {
            Log.error("getairportnetwork failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Private

    private func resolveInterface() async {
        guard wifiInterface == nil else { return }
        do {
            let r = try await Shell.run(Self.networksetup, ["-listallhardwareports"], timeout: 5)
            wifiInterface = HardwarePortsParser.wifiInterface(from: r.stdout)
            if wifiInterface == nil {
                Log.error("could not find a Wi-Fi port in networksetup -listallhardwareports")
            } else {
                Log.info("wifi interface \(wifiInterface!)")
            }
        } catch {
            Log.error("listallhardwareports failed: \(error.localizedDescription)")
        }
    }

    /// What the NWPathMonitor calls. Internal so tests can exercise the
    /// driver-owned task without a monitor.
    func handlePath(satisfied: Bool) {
        track { [weak self] in await self?.process(satisfied: satisfied) }
    }

    /// Feed one path update through the machine and apply its outputs.
    /// Public so tests can drive the driver without an NWPathMonitor.
    func simulate(satisfied: Bool) async {
        await process(satisfied: satisfied)
    }

    /// Runs `operation` in a task that `stop()` cancels.
    private func track(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        inflight[id] = Task { @MainActor [weak self] in
            await operation()
            self?.inflight[id] = nil
        }
    }

    private func process(satisfied: Bool) async {
        guard !Task.isCancelled else { return }
        let now = clock()
        let outputs = satisfied ? machine.pathSatisfied(at: now) : machine.pathUnsatisfied(at: now)
        if outputs.isEmpty { return }
        if !satisfied { Log.info("wifi path unsatisfied") }
        await apply(outputs)
    }

    /// What the retry timer calls. Internal so tests can exercise the
    /// driver-owned join/retry task without waiting for a real timer.
    func fireTimer() {
        retryTimer = nil
        let outputs = machine.timerFired(at: clock())
        track { [weak self] in await self?.apply(outputs) }
    }

    private func apply(_ outputs: [FailoverMachine.Output]) async {
        let epoch = self.epoch
        for o in outputs {
            // A join or recovery above may have been awaited across stop():
            // the machine is reset by then, so the remaining outputs (a retry
            // timer, most importantly) belong to a session that is gone.
            guard !Task.isCancelled, self.epoch == epoch else {
                Log.info("network failover: dropping queued outputs after stop")
                return
            }
            switch o {
            case let .scheduleRetry(after):
                schedule(after: after)
            case .joinHotspot:
                await joinHotspot()
            case let .recovered(start, gap):
                cancelTimer()
                await recovered(start: start, gap: gap)
            }
        }
    }

    private func schedule(after: TimeInterval) {
        cancelTimer()
        generation += 1
        let gen = generation
        let t = Timer(timeInterval: after, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.fireTimer()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    private func cancelTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
        generation += 1
    }

    func joinHotspot() async {
        let config = configProvider()
        let ssid = config.hotspotSSID.trimmingCharacters(in: .whitespaces)
        guard !ssid.isEmpty else {
            Log.info("hotspot join skipped: no hotspotSSID configured")
            return
        }
        guard let iface = wifiInterface else {
            Log.error("hotspot join skipped: no Wi-Fi interface")
            return
        }
        let password: String
        do {
            guard let p = try keychain.get(service: KeychainStore.service, account: ssid) else {
                Log.error("hotspot join skipped: no Keychain item \(KeychainStore.service)/\(ssid)")
                return
            }
            password = p
        } catch {
            Log.error("hotspot join skipped: \(error.localizedDescription)")
            return
        }
        Log.info("joining hotspot \(ssid) on \(iface) (attempt \(machine.joins))")
        do {
            let joined = try await hotspotJoiner.join(ssid: ssid, password: password, interfaceName: iface)
            if !joined {
                Log.error("CoreWLAN scan found no network for hotspot \(ssid); retrying with backoff")
            }
        } catch {
            Log.error("CoreWLAN hotspot join failed: \(error.localizedDescription)")
        }
    }

    private func recovered(start: Date, gap: TimeInterval) async {
        let epoch = self.epoch
        let end = clock()
        lastGap = gap
        let line = FailoverMachine.logLine(start: start, end: end, gap: gap)
        appendHandoff(line)
        Log.info("wifi path satisfied after \(FailoverMachine.humanGap(gap))")
        let config = configProvider()
        if gap >= config.nudgeThreshold {
            // Each pane is only nudged while this session is still the live one.
            let count = await nudge.nudge(targets: config.tmuxTargets, pressEnter: config.tmuxNudgePressesEnter) { [weak self] in self?.epoch == epoch }
            let stopped = self.epoch != epoch
            if stopped {
                Log.info("network failover stopped during recovery; \(count) tmux pane(s) had already been nudged")
            }
            // A keystroke that went out before the stop is still reported.
            if !stopped || count > 0 {
                let panes = count == 1 ? "1 tmux pane" : "\(count) tmux panes"
                notifier.post(
                    title: "Network recovered",
                    body: "Network was down \(FailoverMachine.humanGap(gap)). Nudged \(panes). Check GUI agents."
                )
            }
        }
        // A stopped driver must not write into the next session's status.
        guard self.epoch == epoch else { return }
        onRecovered?(gap)
    }

    /// Owner-only, rotated to handoffs.log.1 past OwnerOnly.maxLogBytes.
    private func appendHandoff(_ line: String) {
        do {
            try OwnerOnly.appendToLog(line + "\n", at: paths.handoffsLog)
        } catch {
            Log.error("handoffs.log: \(error.localizedDescription)")
        }
    }
}
