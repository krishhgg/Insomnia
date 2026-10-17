import Foundation

/// Spec section 6 decision table (plus the section 4 lid row), as a pure
/// function plus a small driver.
enum FloorRules {
    /// Why Low Power Mode is being switched on. The strongest cause is
    /// named when several hold: thermal, then battery, then lid.
    enum LowPowerCause: Equatable, Sendable {
        case battery
        case thermal
        case lid
    }

    enum Action: Equatable, Sendable {
        case enableLowPower(LowPowerCause)
        case disableLowPower
        case endSession(EndReason)
    }

    /// Ordered actions for the current inputs. `hot` says the thermal state
    /// read serious or critical earlier in the session and has not read
    /// nominal since, and `seriousFor` how long it has read serious or
    /// critical without a break, nil while it reads anything below serious
    /// (`FloorRuleDriver` keeps both).
    ///
    /// - battery below `endFloor` while not charging: end session. 0 never
    ///   matches, so 0 turns the battery end off; Config keeps a non-zero
    ///   `endFloor` below `lowPowerFloor`.
    /// - thermal `critical` (if `thermalRules`): end session
    /// - thermal `serious` for `seriousThermalLimit` without a break (if
    ///   `thermalRules`; a limit of 0 turns this off): end session. Apple
    ///   silicon throttles before it reaches critical, so a Mac that cannot
    ///   shed its heat, in a bag say, can stay at serious for hours.
    /// - battery present but unreadable on two consecutive reads while not
    ///   charging, with an end floor set: end session. The floor cannot be
    ///   applied to a level nobody can read, and the Mac is on a battery
    ///   that may be about to die. A desktop has no battery and no floor.
    /// - battery below `lowPowerFloor` while not charging, thermal
    ///   `serious` or still `hot` at `fair` (if `thermalRules`), or lid
    ///   closed (if `lowPowerOnLidClose`, charging or not): Low Power Mode on
    /// - none of the above while we set Low Power Mode: Low Power Mode off
    ///   ("charger connected", "thermal back to nominal", "lid opened")
    static func evaluate(
        battery: BatteryStatus,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        hot: Bool,
        seriousFor: TimeInterval?,
        lidClosed: Bool,
        lowPowerSetByUs: Bool,
        config: Config
    ) -> [Action] {
        let onBattery = !isCharging
        let percent = battery.percent
        if let p = percent, onBattery, p < config.endFloor {
            return [.endSession(.batteryFloor)]
        }
        if config.thermalRules, thermal == .critical {
            return [.endSession(.thermalCritical)]
        }
        if config.thermalRules, config.seriousThermalLimit > 0, thermal == .serious,
           let seriousFor, seriousFor >= config.seriousThermalLimit {
            return [.endSession(.thermalSustained)]
        }
        if case let .unreadable(misses) = battery, onBattery, misses >= 2, config.endFloor > 0 {
            return [.endSession(.batteryUnreadable)]
        }
        let cause = lowPowerCause(percent: percent, isCharging: isCharging, thermal: thermal, hot: hot, lidClosed: lidClosed, config: config)
        if let cause, !lowPowerSetByUs { return [.enableLowPower(cause)] }
        if cause == nil, lowPowerSetByUs { return [.disableLowPower] }
        return []
    }

    /// The strongest cause that wants Low Power Mode right now (thermal,
    /// then battery, then lid), or nil when none holds. Independent of
    /// whether the mode is already on, so the driver can track which cause
    /// is keeping it on as the inputs change.
    ///
    /// The thermal cause holds at serious, and at fair while the Mac is
    /// still `hot`: switching the mode off at the first step down brings
    /// back the load that made it serious, and the mode goes on and off
    /// as the Mac heats up and cools down again.
    static func lowPowerCause(
        percent: Int?,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        hot: Bool,
        lidClosed: Bool,
        config: Config
    ) -> LowPowerCause? {
        if config.thermalRules, thermal == .serious || (hot && thermal == .fair) { return .thermal }
        if let p = percent, !isCharging, p < config.lowPowerFloor { return .battery }
        if lidClosed, config.lowPowerOnLidClose { return .lid }
        return nil
    }
}

/// Applies `FloorRules` through the session manager (journal first) and
/// posts the spec section 9 notifications. A lid-caused change is logged
/// but not announced: the user just closed or opened the lid.
///
/// Announce rule for switching the mode off: the disable is announced iff
/// the cause that last held while Insomnia had the mode on was battery or
/// thermal, and silent iff it was the lid. The cause is refreshed on every
/// run while the mode is ours, so a takeover (lid-caused mode kept on by
/// the battery floor, or the reverse) changes which one the disable is
/// attributed to.
@MainActor
struct FloorRuleDriver {
    weak var manager: SessionManager?
    let notifier: any Notifying
    /// The cause that most recently held while Insomnia had the mode on,
    /// so the matching disable knows whether it is announced. Not
    /// journaled: after a relaunch the disable is announced as before.
    private let lastCause = LastCause()
    /// What the runs of this session have read of the heat
    /// (`FloorRules.evaluate`'s `hot` and `seriousFor`). Not journaled:
    /// after a relaunch a Mac at fair counts as cooled down, and a serious
    /// stretch is timed from the first run that reads it.
    private let heatLog = HeatLog()
    /// Times the serious stretch. The continuous clock, like the wait that
    /// runs the floors at the limit: a step of the wall clock (an NTP
    /// correction, a time set by hand) moves neither.
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// Called at the end of each run with the seconds until the serious
    /// stretch reaches `seriousThermalLimit`, or nil when no run is owed
    /// then: the thermal state sends no event while it stays serious, so
    /// the caller runs the floors once more at that moment (spec section 6).
    private let recheck: @MainActor (TimeInterval?) -> Void

    @MainActor
    private final class LastCause {
        var value: FloorRules.LowPowerCause?
    }

    @MainActor
    private final class HeatLog {
        var hot = false
        /// When the current serious stretch was first read.
        var seriousSince: ContinuousClock.Instant?

        /// Records the state a run reads at `now` and returns the heat the
        /// rules see for that run.
        func read(_ thermal: ProcessInfo.ThermalState, at now: ContinuousClock.Instant) -> (hot: Bool, seriousFor: TimeInterval?) {
            switch thermal {
            case .serious, .critical:
                hot = true
                if seriousSince == nil { seriousSince = now }
            case .nominal:
                hot = false
                seriousSince = nil
            default:
                seriousSince = nil
            }
            return (hot, seriousSince.map { Self.seconds(now - $0) })
        }

        static func seconds(_ duration: Duration) -> TimeInterval {
            let parts = duration.components
            return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
        }
    }

    init(
        manager: SessionManager,
        notifier: any Notifying,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        recheck: @escaping @MainActor (TimeInterval?) -> Void = { _ in }
    ) {
        self.manager = manager
        self.notifier = notifier
        self.clock = clock
        self.recheck = recheck
    }

    func run(battery: BatteryStatus, isCharging: Bool, thermal: ProcessInfo.ThermalState, lidClosed: Bool) async {
        guard let manager, manager.isActive, !Task.isCancelled else { return }
        let config = manager.config
        let percent = battery.percent
        let (hot, seriousFor) = heatLog.read(thermal, at: clock())
        let actions = FloorRules.evaluate(
            battery: battery,
            isCharging: isCharging,
            thermal: thermal,
            hot: hot,
            seriousFor: seriousFor,
            lidClosed: lidClosed,
            lowPowerSetByUs: manager.state.lowPowerSetByUs,
            config: config
        )
        // Track the effective cause while the mode is ours, not only at the
        // enable: another cause may have taken over since.
        if manager.state.lowPowerSetByUs,
           let cause = FloorRules.lowPowerCause(percent: percent, isCharging: isCharging, thermal: thermal, hot: hot, lidClosed: lidClosed, config: config) {
            lastCause.value = cause
        }
        for action in actions {
            guard manager.isActive, !Task.isCancelled else { return }
            switch action {
            case let .enableLowPower(cause):
                guard await manager.setLowPower(true) else { continue }
                lastCause.value = cause
                guard manager.isActive, !Task.isCancelled else { return }
                switch cause {
                case .thermal:
                    notifier.post(title: "Low Power Mode on", body: "Thermal state is \(PowerMonitor.name(thermal)). Low Power Mode stays on until it is back to nominal.")
                case .battery:
                    notifier.post(title: "Low Power Mode on", body: "Battery at \(percent ?? 0)%, below the \(config.lowPowerFloor)% floor.")
                case .lid:
                    Log.info("low power mode on (lid closed)")
                }
            case .disableLowPower:
                if await manager.setLowPower(false) {
                    let cause = lastCause.value
                    lastCause.value = nil
                    guard manager.isActive, !Task.isCancelled else { return }
                    switch cause {
                    case .lid:
                        Log.info("low power mode off (lid opened)")
                    case .thermal:
                        notifier.post(title: "Low Power Mode off", body: config.thermalRules ? "Thermal state is back to \(PowerMonitor.name(thermal))." : "Thermal rules are off.")
                    case .battery, nil:
                        notifier.post(title: "Low Power Mode off", body: isCharging ? "Charger connected." : "Back above the floor.")
                    }
                }
            case let .endSession(reason):
                await manager.end(reason: reason)
                guard manager.isActive, !Task.isCancelled else { return }
            }
        }
        recheck(secondsUntilSeriousThermalEnd())
    }

    /// Seconds until the serious stretch reaches `seriousThermalLimit`, or
    /// nil when no run is owed: the state is not serious, the rule is off,
    /// or the stretch has reached the limit already. A run that read it
    /// there asked for the end, and the manager retries an end that was
    /// refused (a busy lock, a power command still running), so the wait
    /// is never rescheduled in a loop.
    private func secondsUntilSeriousThermalEnd() -> TimeInterval? {
        guard let manager, manager.isActive, let since = heatLog.seriousSince else { return nil }
        let config = manager.config
        guard config.thermalRules, config.seriousThermalLimit > 0 else { return nil }
        let left = config.seriousThermalLimit - HeatLog.seconds(clock() - since)
        return left > 0 ? left : nil
    }
}
