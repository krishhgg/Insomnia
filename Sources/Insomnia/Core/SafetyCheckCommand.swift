import Foundation

/// A read-only, one-shot power check for the recovery agent. It starts
/// before AppKit, reads no secrets, and performs no power changes. The
/// caller holds the recovery lock and applies any undo from the journal.
enum SafetyCheckCommand {
    static let flag = "--check-safety"
    static let version = 1

    struct Output: Equatable, Sendable {
        let line: String
        let status: Int32
    }

    /// The lifetime is armed before any system or config read. A helper
    /// whose caller dies cannot keep the inherited recovery lock forever.
    static func run(
        _ arguments: [String],
        readBattery: () -> (battery: BatteryStatus, charging: Bool) = { PowerMonitor.readBattery() },
        readLid: () -> Bool? = { LidObserver.readClamshellState() },
        readThermal: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        readConfig: () throws -> Config? = { try Store(paths: Paths.fromEnvironment()).loadConfig() },
        endAfter: (UInt32) -> Void
    ) -> Output? {
        guard arguments.first == flag else { return nil }
        guard arguments.count == 2, let seconds = ResumeFrozenCommand.lifetime(arguments[1]) else {
            return Output(line: "usage", status: ResumeFrozenCommand.usageStatus)
        }
        endAfter(seconds)
        var config: Config
        do {
            config = try readConfig() ?? Config()
            _ = config.normalizeFloors()
        } catch {
            return Output(line: "end configuration-unreadable", status: 0)
        }
        var power = readBattery()
        // The one-shot helper has no notification history. Re-read an
        // unavailable battery before declaring two consecutive misses.
        if case .unreadable = power.battery, !power.charging, config.endFloor > 0 {
            let again = readBattery()
            if case .unreadable = again.battery {
                power = (.unreadable(misses: 2), again.charging)
            } else if again.battery == .none {
                // The first read established a laptop. A disappearing
                // battery entry is not evidence that it became a desktop.
                power = (.unreadable(misses: 2), again.charging)
            } else {
                power = again
            }
        }
        return Output(line: decision(
            battery: power.battery, isCharging: power.charging,
            thermal: readThermal(), lidClosed: readLid(), config: config
        ), status: 0)
    }

    static func decision(
        battery: BatteryStatus,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        lidClosed: Bool?,
        config: Config
    ) -> String {
        // A desktop has no lid. On a laptop, guessing "open" would silently
        // disable its closed-lid cutoff when the registry read fails.
        if lidClosed == nil, battery != .none { return "end lid-unreadable" }
        if lidClosed == true, battery == .none, !isCharging, config.endFloor > 0 {
            return "end batteryUnreadable"
        }
        switch thermal {
        case .nominal, .fair, .serious, .critical:
            break
        @unknown default:
            if config.thermalRules || (lidClosed == true && config.endClosedLidWhenHot) {
                return "end thermal-unreadable"
            }
        }
        let actions = FloorRules.evaluate(
            battery: battery, isCharging: isCharging, thermal: thermal,
            lidClosed: lidClosed == true, lowPowerSetByUs: false, config: config
        )
        for case let .endSession(reason) in actions { return "end \(reason.rawValue)" }
        return "continue"
    }
}
