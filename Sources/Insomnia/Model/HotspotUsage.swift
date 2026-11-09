import Foundation

/// Interface traffic is an estimate of this Mac's hotspot use, not the
/// phone's cellular bill. Includes upload, download and local traffic.
struct InterfaceByteSample: Equatable, Sendable {
    let interfaceIndex: UInt32
    let received: UInt64
    let sent: UInt64
    let timestamp: TimeInterval
}

enum HotspotUsageConnection: Equatable, Sendable {
    case configuredHotspot
    case otherNetwork
    /// A hidden network name or a failed reading cannot confirm the hotspot.
    case unavailable
}

enum HotspotBudgetWarning: String, Codable, Sendable {
    case approaching
    case reached
}

/// Persist only accumulated amounts and warning history, never an interface
/// baseline: bytes while the app was closed cannot be attributed to a hotspot.
struct HotspotUsageLedger: Codable, Equatable, Sendable {
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var budgetBytes: UInt64
    var warned: Set<HotspotBudgetWarning> = []
    var hasUnmeasuredIntervals = false

    var total: UInt64 { Self.add(received, sent) }

    static func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? .max : result.partialValue
    }
}

/// Pure accounting and warning decisions. The driver confirms the configured
/// SSID, clears the baseline on stop, and saves before posting warnings.
/// No timers, notification delivery or system changes happen here.
struct HotspotUsageTracker: Sendable {
    private(set) var ledger: HotspotUsageLedger
    private var baseline: InterfaceByteSample?
    let maximumSampleGap: TimeInterval

    init(ledger: HotspotUsageLedger, maximumSampleGap: TimeInterval = 15) {
        self.ledger = ledger
        self.maximumSampleGap = maximumSampleGap
    }

    mutating func record(
        _ sample: InterfaceByteSample?,
        connection: HotspotUsageConnection
    ) -> [HotspotBudgetWarning] {
        guard connection == .configuredHotspot else {
            if connection == .unavailable { ledger.hasUnmeasuredIntervals = true }
            baseline = nil
            return []
        }
        guard let sample, sample.timestamp.isFinite else {
            ledger.hasUnmeasuredIntervals = true
            baseline = nil
            return []
        }
        defer { baseline = sample }
        guard let previous = baseline else { return warnings() }
        let elapsed = sample.timestamp - previous.timestamp
        guard sample.interfaceIndex == previous.interfaceIndex,
              elapsed > 0, elapsed <= maximumSampleGap,
              sample.received >= previous.received,
              sample.sent >= previous.sent else {
            // A reset, sleep gap or changed interface must not invent usage.
            ledger.hasUnmeasuredIntervals = true
            return warnings()
        }
        ledger.received = HotspotUsageLedger.add(ledger.received, sample.received - previous.received)
        ledger.sent = HotspotUsageLedger.add(ledger.sent, sample.sent - previous.sent)
        return warnings()
    }

    /// Invalidate at session stop or a network transition. Never carry a
    /// baseline across time when this driver was not observing the network.
    mutating func stop() { baseline = nil }

    mutating func interrupt() {
        baseline = nil
        ledger.hasUnmeasuredIntervals = true
    }

    /// Editing the amount starts warning history for the new budget; it does
    /// not erase the tracked bytes. A zero budget turns warnings off.
    mutating func setBudget(_ bytes: UInt64) -> [HotspotBudgetWarning] {
        guard bytes != ledger.budgetBytes else { return [] }
        ledger.budgetBytes = bytes
        ledger.warned = []
        return warnings()
    }

    /// Explicit user reset starts a new accounting period and a new baseline.
    mutating func reset() {
        ledger = HotspotUsageLedger(budgetBytes: ledger.budgetBytes)
        baseline = nil
    }

    private mutating func warnings() -> [HotspotBudgetWarning] {
        let budget = ledger.budgetBytes
        guard budget > 0 else { return [] }
        if ledger.total >= budget {
            // A jump past both levels produces one alert, not a burst of two.
            let alreadyWarned = ledger.warned.contains(.reached)
            ledger.warned.formUnion([.approaching, .reached])
            return alreadyWarned ? [] : [.reached]
        }
        // ceil(budget * 4 / 5), without overflowing UInt64 or rounding bytes.
        let threshold = (budget / 5) * 4 + ((budget % 5) * 4 + 4) / 5
        guard ledger.total >= threshold, !ledger.warned.contains(.approaching) else { return [] }
        ledger.warned.insert(.approaching)
        return [.approaching]
    }
}

enum HotspotUsagePhase: String, Sendable {
    case off, idle, waiting, tracking, otherNetwork, unavailable, missingHotspot

    var text: String {
        switch self {
        case .off: "Off, saved usage retained"
        case .idle: "Paused, no active session"
        case .waiting: "Waiting for a hotspot reading"
        case .tracking: "Tracking configured hotspot"
        case .otherNetwork: "Paused, on another Wi-Fi network"
        case .unavailable: "Paused, Wi-Fi name or counters unavailable"
        case .missingHotspot: "Set a hotspot name in Network settings"
        }
    }
}

struct HotspotUsageStatus: Equatable, Sendable {
    var ledger: HotspotUsageLedger?
    var periodStarted: Date?
    var phase: HotspotUsagePhase = .off
    var problem: String?

    var summary: String {
        guard let ledger else { return "Hotspot usage unavailable" }
        return "Hotspot: \(HotspotUsageText.amount(ledger.total)) / \(ledger.budgetBytes == 0 ? "no budget" : HotspotUsageText.amount(ledger.budgetBytes))"
    }

    var warning: String? {
        guard let ledger, ledger.budgetBytes > 0 else { return nil }
        if ledger.total >= ledger.budgetBytes { return "Hotspot budget reached, connection left running" }
        let threshold = (ledger.budgetBytes / 5) * 4 + ((ledger.budgetBytes % 5) * 4 + 4) / 5
        return ledger.total >= threshold ? "Hotspot budget nearly used (80%)" : nil
    }

    var detail: String? {
        if let problem { return problem }
        if phase != .tracking { return phase.text }
        return ledger?.hasUnmeasuredIntervals == true ? "Some intervals unmeasured; total may be incomplete" : nil
    }
}

enum HotspotUsageText {
    static func amount(_ bytes: UInt64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", Double(bytes) / 1_000) }
        return "\(bytes) B"
    }

    static func body(_ warning: HotspotBudgetWarning, ledger: HotspotUsageLedger) -> String {
        let sentence = "\(amount(ledger.total)) tracked against your \(amount(ledger.budgetBytes)) budget."
        switch warning {
        case .approaching: return sentence + " \(amount(ledger.budgetBytes - min(ledger.total, ledger.budgetBytes))) left."
        case .reached: return sentence + " Connection left running."
        }
    }
}
