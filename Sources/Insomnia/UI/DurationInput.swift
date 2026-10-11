import Foundation

/// The three pills in the menu bar, as data. Pure: no clocks, no UI.
///
/// Each field is `nil` while it still shows its placeholder. Digits are
/// appended one at a time by the key monitor; a field never holds more than
/// two digits and never exceeds its ceiling, so what is on screen is always
/// a value the session can use.
struct DurationInput: Equatable, Sendable {
    enum Field: Int, CaseIterable, Sendable {
        case days
        case hours
        case minutes

        var placeholder: String {
            switch self {
            case .days: return "Days"
            case .hours: return "Hours"
            case .minutes: return "Minutes"
            }
        }

        /// Tooltip on the "?" badge. Days names the configured maximum
        /// session (`Config.maxDuration`), not the pill's own 30-day entry
        /// ceiling: that is the number a session is held to.
        func help(maxDuration: TimeInterval) -> String {
            switch self {
            case .days: return "Up to \(exactLabel(for: maxDuration)) per session"
            case .hours: return "0\u{2013}\(DurationInput.maxHours)"
            case .minutes: return "0\u{2013}\(DurationInput.maxMinutes)"
            }
        }

        var maximum: Int {
            switch self {
            case .days: return DurationInput.maxDays
            case .hours: return DurationInput.maxHours
            case .minutes: return DurationInput.maxMinutes
            }
        }

        var next: Field {
            Field(rawValue: (rawValue + 1) % Field.allCases.count)!
        }

        var previous: Field {
            Field(rawValue: (rawValue + Field.allCases.count - 1) % Field.allCases.count)!
        }
    }

    static let maxDays = 30
    static let maxHours = 23
    static let maxMinutes = 59
    /// Every field is two digits wide at most.
    static let maxDigits = 2

    var days: Int?
    var hours: Int?
    var minutes: Int?

    init(days: Int? = nil, hours: Int? = nil, minutes: Int? = nil) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
    }

    subscript(field: Field) -> Int? {
        get {
            switch field {
            case .days: return days
            case .hours: return hours
            case .minutes: return minutes
            }
        }
        set {
            switch field {
            case .days: days = newValue
            case .hours: hours = newValue
            case .minutes: minutes = newValue
            }
        }
    }

    // MARK: Validation

    /// True while every pill still shows its placeholder.
    var isEmpty: Bool { days == nil && hours == nil && minutes == nil }

    func isValid(_ field: Field) -> Bool {
        guard let v = self[field] else { return true }
        return v >= 0 && v <= field.maximum
    }

    /// Every field in range and at least one non-zero.
    var isValid: Bool {
        Field.allCases.allSatisfy(isValid) && (total ?? 0) > 0
    }

    /// Seconds represented, or nil when a field is out of range or nothing
    /// non-zero has been entered.
    var total: TimeInterval? {
        guard Field.allCases.allSatisfy(isValid) else { return nil }
        let seconds = TimeInterval((days ?? 0) * 86_400 + (hours ?? 0) * 3_600 + (minutes ?? 0) * 60)
        return seconds > 0 ? seconds : nil
    }

    // MARK: Presets

    /// Fill the pills from a preset. Seconds are floored to the minute; fields
    /// that would be zero stay empty so the pills read like the chip did
    /// ("2h" fills only Hours). Values beyond 30 days are clamped.
    static func from(seconds: TimeInterval) -> DurationInput {
        let totalMinutes = min(max(Int(seconds / 60), 0), maxDays * 24 * 60)
        let d = totalMinutes / (24 * 60)
        let h = (totalMinutes % (24 * 60)) / 60
        let m = totalMinutes % 60
        return DurationInput(days: d > 0 ? d : nil, hours: h > 0 ? h : nil, minutes: m > 0 ? m : nil)
    }

    // MARK: Editing

    /// Text shown in the pill, nil while it shows its placeholder.
    func text(for field: Field) -> String? {
        self[field].map(String.init)
    }

    /// True when another digit could still be typed into `field`.
    func canAcceptDigit(in field: Field) -> Bool {
        guard let v = self[field] else { return true }
        return String(v).count < DurationInput.maxDigits && v * 10 <= field.maximum
    }

    /// Append a digit (0...9) to `field`. Returns false, leaving the value
    /// alone, when the field is full or the result would exceed its ceiling.
    @discardableResult
    mutating func append(digit: Int, to field: Field) -> Bool {
        guard (0...9).contains(digit) else { return false }
        let current = self[field]
        if current == 0 && digit == 0 { return false }
        if let c = current, String(c).count >= DurationInput.maxDigits { return false }
        let proposed = (current ?? 0) * 10 + digit
        guard proposed <= field.maximum else { return false }
        self[field] = proposed
        return true
    }

    /// Remove the last digit of `field`. Returns false when it was already
    /// empty, so the caller can move focus to the previous pill instead.
    @discardableResult
    mutating func backspace(_ field: Field) -> Bool {
        guard let v = self[field] else { return false }
        let shorter = v / 10
        self[field] = (v < 10) ? nil : shorter
        return true
    }

    mutating func clear(_ field: Field) {
        self[field] = nil
    }

    mutating func clearAll() {
        days = nil
        hours = nil
        minutes = nil
    }
}

/// Parses the short durations typed into settings ("30m", "2h", "1h30m", "3d").
enum DurationParser {
    /// Seconds, or nil when the text is not a duration. Bare numbers are minutes.
    static func seconds(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let bare = Int(trimmed) {
            guard bare > 0 else { return nil }
            let (seconds, overflow) = bare.multipliedReportingOverflow(by: 60)
            return overflow ? nil : TimeInterval(seconds)
        }
        var total = 0
        var number = ""
        var sawUnit = false
        for ch in trimmed {
            if ch.isNumber {
                number.append(ch)
            } else if ch == " " {
                continue
            } else {
                guard let n = Int(number) else { return nil }
                let multiplier: Int
                switch ch {
                case "d": multiplier = 86_400
                case "h": multiplier = 3_600
                case "m": multiplier = 60
                default: return nil
                }
                // Reject rather than trap on absurd values.
                let (seconds, mulOverflow) = n.multipliedReportingOverflow(by: multiplier)
                guard !mulOverflow else { return nil }
                let (sum, addOverflow) = total.addingReportingOverflow(seconds)
                guard !addOverflow else { return nil }
                total = sum
                number = ""
                sawUnit = true
            }
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        return TimeInterval(total)
    }
}
