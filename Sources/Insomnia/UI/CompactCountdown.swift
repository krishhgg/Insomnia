import Foundation

/// Display-only hours and minutes. The lifecycle keeps its precise seconds.
enum CompactCountdown {
    static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds <= Double(Int.max / 120) else { return "" }
        let total = Int(ceil(max(0, seconds) / 60))
        let days = total / 1440
        let hours = days > 0 ? (total % 1440) / 60 : total / 60
        let clock = String(format: "%d:%02d", hours, total % 60)
        return days > 0 ? "\(days)d \(clock)" : clock
    }

    /// Accepts both live and pending core countdowns, including the fixed
    /// minute shape of a short session that has subsequently been extended.
    static func text(_ precise: String) -> String {
        let parts = precise.split(separator: " ")
        guard let clock = parts.last else { return precise }
        let pieces = clock.split(separator: ":", omittingEmptySubsequences: false)
        let fields = pieces.compactMap { Int($0) }
        guard fields.count == pieces.count, fields.count == 2 || fields.count == 3,
              fields.allSatisfy({ $0 >= 0 && $0 <= 30 * 86400 }) else { return precise }
        var days = 0
        if parts.count == 2 {
            guard parts[0].hasSuffix("d"), let value = Int(parts[0].dropLast()), value >= 0, value <= 30 else { return precise }
            days = value
        } else if parts.count != 1 { return precise }
        let seconds = fields.count == 3
            ? fields[0] * 3600 + fields[1] * 60 + fields[2]
            : fields[0] * 60 + fields[1]
        return format(TimeInterval(days * 86400 + seconds))
    }
}
