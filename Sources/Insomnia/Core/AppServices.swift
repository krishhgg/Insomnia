import Foundation
import Observation

/// Everything the menu shows about the machine. Updated by AppServices on
/// each OS event; `refreshOnDemand()` fills the on-demand fields (watts,
/// SSID, browser flags) when the popover opens.
@MainActor
@Observable
final class SystemStatus {
    var lidClosed: Bool = false
    var batteryPercent: Int?
    var isCharging: Bool = false
    var thermalState: ProcessInfo.ThermalState = .nominal
    var wifiSSID: String?
    /// Length of the last Wi-Fi outage this session, in seconds.
    var lastGap: TimeInterval?
    var frozenCount: Int = 0
    var dockerPaused: Bool = false
    /// Display names of running Chromium browsers missing the two flags.
    var throttledBrowsers: [String] = []
    /// Full detail for the relaunch item (bundle id + name).
    var browsers: [BrowserStatus] = []

    @ObservationIgnored var refresher: (@MainActor () async -> Void)?

    /// Fire-and-forget refresh of watts, SSID, battery and browser flags.
    func refreshOnDemand() {
        guard let refresher else { return }
        Task { @MainActor in await refresher() }
    }
}

/// Owns and wires every system integration to the SessionManager.
/// Constructed by `SessionManager.live()`; started when a session starts (or
/// is found valid at reconcile) and stopped when it ends.
@MainActor
final class AppServices {
    let status = SystemStatus()
    let notifier: any Notifying
    let locationPermission: LocationPermission

    private let paths: Paths
    private let audio: any AudioControlling
    private let display: any DisplayDimming
    private let keyboard: any KeyboardBacklighting
    private let freezer: any Freezing
    private let docker: DockerRule
    private let keychain: any KeychainStoring
    private let lid = LidObserver()
    /// The file trigger behind scripts/simulate-lid.sh. Compiled into debug
    /// builds and INSOMNIA_LID_SIMULATION release builds only
    /// (`LidSimulationBuild`); nil in every other build, and only started
    /// when `lidSimulationEnabled` is true, so a normal release build never
    /// watches the support directory for lid events.
    private let lidSimulation: (any LidSimulating)?
    private let lidSimulationEnabled: Bool
    private let power = PowerMonitor()
    private let browser: BrowserThrottle
    /// Last trusted display/keyboard brightness for the lid close (spec
    /// section 4): read every 30 s while the lid is open, at start, and 3 s
    /// after each lid open (the backlight stays suppressed briefly after the
    /// wake).
    private let sampler: BrightnessSampler
    private static let sampleInterval: TimeInterval = 30
    private static let sampleLeeway: DispatchTimeInterval = .seconds(5)
    private static let postOpenSampleDelay: Duration = .seconds(3)

    private weak var manager: SessionManager?
    private var lidActions: LidActions?
    private var floors: FloorRuleDriver?
    private var network: NetworkFailover?
    private var networkTask: Task<Void, Never>?
    private var lidTasks: [Task<Void, Never>] = []
    private var floorTasks: [Task<Void, Never>] = []
    private var browserTasks: [Task<Void, Never>] = []
    private var sampleTimer: (any DispatchSourceTimer)?
    private var postOpenSampleTask: Task<Void, Never>?
    private(set) var running = false

    init(
        paths: Paths,
        notifier: any Notifying,
        audio: any AudioControlling,
        processControl: any ProcessSignaling,
        display: any DisplayDimming = NoopDisplayDimmer(),
        keyboard: any KeyboardBacklighting = NoopKeyboardBacklight(),
        keychain: any KeychainStoring = KeychainStore(),
        locationPermission: LocationPermission = LocationPermission(),
        idleSeconds: @escaping @Sendable () -> Double = { UserInput.secondsSinceLastInput() },
        lidSimulation: (any LidSimulating)? = LidSimulationBuild.makeWatcher(),
        lidSimulationEnabled: Bool = LidSimulationBuild.isCompiledIn
    ) {
        self.paths = paths
        self.notifier = notifier
        self.audio = audio
        self.display = display
        self.keyboard = keyboard
        self.lidSimulation = lidSimulation
        self.lidSimulationEnabled = lidSimulationEnabled
        self.sampler = BrightnessSampler(display: display, keyboard: keyboard, idleSeconds: idleSeconds)
        self.freezer = Freezer(control: processControl)
        self.docker = DockerRule(freezer: freezer)
        self.keychain = keychain
        self.locationPermission = locationPermission
        self.browser = BrowserThrottle()
        status.refresher = { [weak self] in await self?.refreshOnDemand() }
    }

    /// Called by SessionManager once a session is active.
    func start(for manager: SessionManager) {
        guard !running else { return }
        running = true
        self.manager = manager
        let config = manager.config
        status.lastGap = nil

        if !config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            locationPermission.requestWhenInUse()
        }

        (notifier as? Notifier)?.requestAuthorizationIfNeeded()

        lidActions = LidActions(manager: manager, freezer: freezer, docker: docker, audio: audio, display: display, keyboard: keyboard, sampler: sampler)
        floors = FloorRuleDriver(manager: manager, notifier: notifier)
        // The panel under Insomnia's own Low Power Mode reads the mode's
        // rescaled value: sample once more just before the mode goes on
        // and keep that sample until it is off (spec section 4).
        manager.willEnableLowPower = { [weak self] in self?.sampleBrightnessIfLidOpen() }
        sampler.displayHeld = { [weak manager] in manager?.state.lowPowerSetByUs ?? false }

        lid.onChange = { [weak self] closed in self?.lidChanged(closed) }
        lid.start()
        status.lidClosed = lid.isClosed
        sampleBrightnessIfLidOpen()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.sampleInterval, repeating: Self.sampleInterval, leeway: Self.sampleLeeway)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.sampleBrightnessIfLidOpen() }
        }
        sampleTimer = timer
        timer.resume()
        startLidSimulation()

        power.onChange = { [weak self] in self?.powerChanged() }
        power.start()
        syncPower()
        // Apply the floors once: the battery may already be below one.
        powerChanged()

        let net = NetworkFailover(paths: paths, keychain: keychain, notifier: notifier) { [weak manager] in
            manager?.config ?? Config()
        }
        net.onRecovered = { [weak self] gap in self?.status.lastGap = gap }
        network = net
        networkTask = Task { [weak self, weak net] in
            guard let self, let net else { return }
            await net.start()
            if Task.isCancelled || !self.running || self.network !== net {
                net.stop()
            }
        }

        browserTasks.append(Task { await self.refreshBrowsers() })
        syncState()
    }

    func stop() {
        guard running else { return }
        running = false
        lid.stop()
        lid.onChange = nil
        stopLidSimulation()
        power.stop()
        power.onChange = nil
        sampleTimer?.cancel()
        sampleTimer = nil
        postOpenSampleTask?.cancel()
        postOpenSampleTask = nil
        networkTask?.cancel()
        networkTask = nil
        for task in lidTasks { task.cancel() }
        lidTasks.removeAll()
        for task in floorTasks { task.cancel() }
        floorTasks.removeAll()
        for task in browserTasks { task.cancel() }
        browserTasks.removeAll()
        network?.stop()
        network = nil
        lidActions = nil
        floors = nil
        syncState()
    }

    /// One-shot launch diagnostics. This does not start any observer or retry
    /// timer, so system integrations remain active only during a session.
    func logStartupSnapshot() {
        if let closed = LidObserver.readClamshellState() {
            status.lidClosed = closed
            Log.info("startup lid state \(closed ? "closed" : "open")")
        } else {
            Log.info("startup lid state unavailable")
        }

        power.refreshBattery()
        syncPower()
        Log.info("startup battery \(PowerMonitor.describe(power.battery))")
        Log.info("startup thermal state \(PowerMonitor.name(status.thermalState))")

        Task { [weak self] in
            guard let self else { return }
            self.status.wifiSSID = await self.currentSSID()
        }
    }

    /// The part of the refresh that reads straight out of the system: battery
    /// and lid. Split out so a caller that cannot await — the right-click
    /// menu, which blocks the main actor once it is up — still opens on these.
    /// Watts are not read here: the menu calls `instantWatts()` itself.
    func refreshInstant() {
        power.refreshBattery()
        syncPower()
        if let now = LidObserver.readClamshellState() { status.lidClosed = now }
        syncState()
    }

    /// Battery + lid + SSID + browser flags. The menu kicks this off for the
    /// next opening, since the last two have to be awaited.
    func refreshOnDemand() async {
        refreshInstant()
        status.wifiSSID = await currentSSID()
        await refreshBrowsers()
    }

    /// Instant battery power, read only when requested by the UI.
    func instantWatts() -> Double? {
        power.instantWatts()
    }

    /// Quit and relaunch a Chromium browser with both anti-throttle flags.
    func relaunchUnthrottled(_ bundleId: String) async {
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.browser.relaunchUnthrottled(bundleId: bundleId)
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self.refreshBrowsers()
        }
        browserTasks.append(task)
        await task.value
    }

    /// Re-run the floors with the current inputs. Settings that change a
    /// floor input (the lid option) call this so the change applies now,
    /// not at the next battery, thermal or lid event. Queued on the floor
    /// chain like a power event; a no-op outside a session.
    func reevaluateFloors() {
        powerChanged()
    }

    // MARK: Lid simulation

    /// scripts/simulate-lid.sh drives the same action path as the hinge.
    /// The hardware reading in refreshInstant/reconcile still reflects the
    /// real lid; the trigger only runs the close/open actions. Nothing is
    /// wired unless the build compiled the watcher in: a release build
    /// without INSOMNIA_LID_SIMULATION has no watcher and leaves the
    /// trigger file alone. Called by `start`; internal so a test can drive
    /// it with an injected watcher.
    func startLidSimulation() {
        guard lidSimulationEnabled, let lidSimulation else { return }
        lidSimulation.onEvent = { [weak self] closed in self?.lidChanged(closed) }
        lidSimulation.start(directory: paths.appSupport, file: paths.simulateLidFile)
    }

    /// Called by `stop`; internal for the same reason.
    func stopLidSimulation() {
        guard let lidSimulation else { return }
        lidSimulation.stop()
        lidSimulation.onEvent = nil
    }

    // MARK: Private

    private func lidChanged(_ closed: Bool) {
        status.lidClosed = closed
        guard let actions = lidActions else { return }
        let previous = lidTasks.last
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, self.running else { return }
            if closed { await actions.onClose() } else { await actions.onOpen() }
            guard !Task.isCancelled, self.running else { return }
            self.syncState()
            // The lid is a Low Power Mode cause (spec section 4): re-run the
            // floors now that the lid transaction is done. Queued on the
            // floor chain, so it stays serialized with battery events.
            self.powerChanged()
            if !closed { self.scheduleSampleAfterOpen() }
        }
        lidTasks.append(task)
    }

    /// A reading taken while the lid is closed is the darkened value, never
    /// the user's, so the sampler only runs with the lid open. The sampler
    /// itself skips anything not trustworthy at that moment.
    private func sampleBrightnessIfLidOpen() {
        guard running, !status.lidClosed else { return }
        sampler.sample()
    }

    /// The keyboard backlight stays suppressed for a moment after the wake
    /// on lid open; a sample right then would be skipped, so wait 3 s. Off
    /// the lid chain so the next lid event is not held behind the wait.
    private func scheduleSampleAfterOpen() {
        postOpenSampleTask?.cancel()
        postOpenSampleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.postOpenSampleDelay)
            guard !Task.isCancelled else { return }
            self?.sampleBrightnessIfLidOpen()
        }
    }

    private func powerChanged() {
        syncPower()
        guard let floors else { return }
        let battery = power.battery
        let charging = power.isCharging
        let thermal = power.thermalState
        let lidClosed = status.lidClosed
        let previous = floorTasks.last
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, self.running else { return }
            await floors.run(battery: battery, isCharging: charging, thermal: thermal, lidClosed: lidClosed)
            guard !Task.isCancelled, self.running else { return }
            self.syncState()
        }
        floorTasks.append(task)
    }

    private func syncPower() {
        status.batteryPercent = power.percent
        status.isCharging = power.isCharging
        status.thermalState = power.thermalState
    }

    private func syncState() {
        let s = manager?.effectiveState ?? .clean
        status.frozenCount = s.frozenPids.count
        status.dockerPaused = s.dockerFrozen
    }

    private func refreshBrowsers() async {
        let config = manager?.config ?? Config()
        let statuses = await browser.scan(config: config)
        status.browsers = statuses
        status.throttledBrowsers = browser.throttledBrowsers
    }

    private func currentSSID() async -> String? {
        if let network { return await network.currentSSID() }
        let probe = NetworkFailover(paths: paths, keychain: keychain, notifier: notifier) { Config() }
        return await probe.currentSSID()
    }
}
