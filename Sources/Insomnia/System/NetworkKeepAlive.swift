import Foundation

/// Session-only traffic for an otherwise idle phone hotspot. This is not a
/// tunnel watchdog: an HTTPS failure must never restart cloudflared/Rex or
/// reassociate Wi-Fi, which would interrupt unrelated, healthy connections.
@MainActor
final class NetworkKeepAlive {
    static let interval: TimeInterval = 30
    nonisolated static let endpoint = URL(string: "https://cp.cloudflare.com/generate_204")!

    private let probe: @Sendable () async throws -> Bool
    private let beginActivity: () -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    private(set) var task: Task<Void, Never>?
    private var generation = 0
    private(set) var lastHealthy: Bool?

    init(
        probe: @escaping @Sendable () async throws -> Bool = NetworkKeepAlive.httpsProbe,
        beginActivity: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Insomnia network session")
        },
        endActivity: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.probe = probe
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func start() {
        guard activity == nil else { return }
        // Keep Insomnia's own timers responsive while its UI is hidden. The
        // token ends with the session (or automatically on process exit).
        // It holds no display-sleep assertion; pmset still handles the lid.
        activity = beginActivity()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.info("network heartbeat started (30s, HTTPS, metered connections allowed)")
        tick()
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        if let activity { endActivity(activity) }
        activity = nil
        lastHealthy = nil
    }

    /// At most one request in flight. A late response after stop/restart
    /// cannot alter the next session or clear its in-flight request.
    func tick() {
        guard activity != nil, task == nil else { return }
        let generation = self.generation
        let probe = self.probe
        task = Task { [weak self] in
            let healthy: Bool
            do { healthy = try await probe() } catch { healthy = false }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            if self.lastHealthy != healthy {
                if healthy {
                    Log.info("network heartbeat reachable")
                } else {
                    Log.error("network heartbeat unavailable; leaving tunnels and Wi-Fi intact")
                }
            }
            self.lastHealthy = healthy
            self.task = nil
        }
    }

    nonisolated static func httpsProbe() async throws -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // HEAD bounds the response body even on a captive portal. Cache
        // headers ensure a real request, rather than a local cache hit.
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 204
    }
}
