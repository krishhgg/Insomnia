import Foundation
import Observation

/// Live machine status shown in the right-click menu and the menu bar
/// popover. The system layer (lid, battery, network, freeze, browser
/// throttle) provides the real object; the UI only ever talks to this
/// protocol.
@MainActor
protocol StatusSource: AnyObject, Observable {
    var lidClosed: Bool { get }
    var batteryPercent: Int? { get }
    var isCharging: Bool { get }
    var wifiSSID: String? { get }
    /// Length of the most recent network outage, nil if none this session.
    var lastGap: TimeInterval? { get }
    var frozenCount: Int { get }
    var dockerPaused: Bool { get }
    /// Browsers running without the occlusion flags.
    var throttledBrowsers: [ThrottledBrowser] { get }
    /// Why each browser's last relaunch did not happen, ordered by
    /// bundle id; one warning line each in the menu and the popover.
    var relaunchProblems: [String] { get }
    /// Why a hotspot join was skipped this session, if one was, and for
    /// which SSID.
    var hotspotPasswordReport: HotspotPasswordReport? { get }

    /// Called when the menu or the popover opens; observers refresh
    /// anything not pushed.
    func refreshOnDemand()
    /// The part of that refresh that needs no awaiting, so a caller that has
    /// to read the status right now still gets it fresh.
    func refreshInstant()
    /// Battery draw read on demand from AppleSmartBattery. Never polled.
    func instantWatts() -> Double?
    /// The battery's time to empty or to full, read on demand like the
    /// watts. Never polled.
    func batteryTimeRemaining() -> BatteryTimeRemaining?
    /// Relaunch the browser the user confirmed, as the menu item or the
    /// popover's button named it.
    func relaunchUnthrottled(_ browser: ThrottledBrowser)
}

extension StatusSource {
    func batteryTimeRemaining() -> BatteryTimeRemaining? { nil }
}

/// Stand-in until the system layer is plugged in. Reports nothing.
@MainActor
@Observable
final class PlaceholderStatus: StatusSource {
    var lidClosed: Bool = false
    var batteryPercent: Int? = nil
    var isCharging: Bool = false
    var wifiSSID: String? = nil
    var lastGap: TimeInterval? = nil
    var frozenCount: Int = 0
    var dockerPaused: Bool = false
    var throttledBrowsers: [ThrottledBrowser] = []
    var relaunchProblems: [String] = []
    var hotspotPasswordReport: HotspotPasswordReport? = nil

    init() {}

    func refreshOnDemand() {}
    func refreshInstant() {}
    func instantWatts() -> Double? { nil }
    func relaunchUnthrottled(_ browser: ThrottledBrowser) {}
}

/// Pure formatting for the right-click menu's status block and the
/// popover's status rows, kept out of the views so it can be tested. The
/// menu gets one line per group; the popover one row per fact, each with
/// its SF Symbol.
enum StatusLines {
    /// "Lid: closed · 4.1 W · 82%". Unknown parts are omitted.
    static func machine(lidClosed: Bool, watts: Double?, batteryPercent: Int?, isCharging: Bool) -> String {
        var parts: [String] = ["Lid: \(lidClosed ? "closed" : "open")"]
        if let w = watts {
            parts.append(String(format: "%.1f W", w))
        }
        if let p = batteryPercent {
            parts.append(isCharging ? "\(p)% charging" : "\(p)%")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Wi-Fi gets its own row so a long network or permission status doesn't
    /// widen the machine status line. Preserve the supplied display name.
    static func network(wifiSSID: String?) -> String? {
        guard let ssid = wifiSSID, !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "Wi-Fi: \(ssid)"
    }

    /// "3 apps frozen · Docker paused", or nil when nothing is held.
    static func actions(frozenCount: Int, dockerPaused: Bool, lastGap: TimeInterval?) -> String? {
        var parts: [String] = []
        if frozenCount > 0 {
            parts.append(frozenCount == 1 ? "1 app frozen" : "\(frozenCount) apps frozen")
        }
        if dockerPaused {
            parts.append("Docker paused")
        }
        if let gap = lastGap, gap > 0 {
            parts.append("last gap \(Int(gap.rounded()))s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Lid, power, hotspot failover and Wi-Fi rows, in that order. The lid
    /// is always known; the power row is left out when neither the draw
    /// nor the charge is known, the failover row when the caller has none
    /// (`HotspotFailoverRow`), and the Wi-Fi row when there is no network
    /// to name.
    static func machine(lidClosed: Bool, watts: Double?, wifi: WiFiStatusName.Display?, batteryPercent: Int?, isCharging: Bool, timeRemaining: BatteryTimeRemaining? = nil, failover: StatusMenu.Item? = nil) -> [StatusMenu.Item] {
        var rows = [StatusMenu.Item(title: lidClosed ? "Lid closed" : "Lid open", kind: .info, symbol: "laptopcomputer")]
        // Plugged in at the charge limit the battery reports charging but
        // draws nothing: "80% · Charging 0.0 W" says the wrong thing. Under
        // half a watt the draw is left out and the row says the Mac is on
        // its power adapter instead.
        let idleOnAdapter = isCharging && watts.map { abs($0) < 0.5 } == true
        // `isCharging` is true for any adapter connection. Plugged in, the
        // battery can still drain (a heavy load, or charge management
        // lowering it); the current's sign says so, and the row then names
        // the adapter and the draw rather than calling it charging.
        let drainingOnAdapter = isCharging && watts.map { $0 <= -0.5 } == true
        let charging = isCharging && !drainingOnAdapter
        if let title = powerTitle(watts: watts, batteryPercent: batteryPercent, isCharging: charging, idleOnAdapter: idleOnAdapter, drainingOnAdapter: drainingOnAdapter, timeRemaining: timeRemaining) {
            let symbol = idleOnAdapter || drainingOnAdapter ? "powerplug" : charging ? "battery.100percent.bolt" : (batteryPercent == nil ? "bolt" : "battery.75percent")
            rows.append(StatusMenu.Item(title: title, kind: .info, symbol: symbol))
        }
        if let failover {
            rows.append(failover)
        }
        if let wifi, !wifi.text.isEmpty {
            rows.append(StatusMenu.Item(title: wifi.text, kind: .info, symbol: "wifi", help: wifi.help))
        }
        return rows
    }

    /// The power row: the charge, then what the battery is doing, then the
    /// time, as in "48% · 5.6 W · 2:32 left" or "54% · Charging 51 W · 1:10
    /// to full". The watts carry no sign: the words say which way the
    /// power flows, as Stats and pmset do. nil when nothing is known.
    static func powerTitle(watts: Double?, batteryPercent: Int?, isCharging: Bool, idleOnAdapter: Bool, drainingOnAdapter: Bool = false, timeRemaining: BatteryTimeRemaining?) -> String? {
        var parts: [String] = []
        if let p = batteryPercent { parts.append("\(p)%") }
        // One decimal only where it says something: "4.1 W", "51 W".
        let draw = watts.flatMap { abs($0) >= 0.5 ? abs($0) : nil }.map { $0 < 10 ? String(format: "%.1f W", $0) : String(format: "%.0f W", $0) }
        if idleOnAdapter {
            parts.append("On power adapter")
        } else if drainingOnAdapter {
            parts.append("On power adapter")
            if let draw { parts.append(draw) }
        } else if isCharging {
            parts.append(draw.map { "Charging \($0)" } ?? "Charging")
        } else if let draw {
            parts.append(draw)
        }
        if !idleOnAdapter, let time = timeRemaining {
            switch time {
            case let .untilEmpty(minutes) where !isCharging: parts.append("\(clock(minutes: minutes)) left")
            case let .untilFull(minutes) where isCharging: parts.append("\(clock(minutes: minutes)) to full")
            case .calculating: parts.append("Calculating\u{2026}")
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Minutes as h:mm, the way pmset and Activity Monitor write a battery
    /// time: "2:32", "0:45".
    static func clock(minutes: Int) -> String {
        "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// Frozen apps, paused Docker and the last network gap, each only when
    /// it applies; empty when nothing is held. The popover's rows for what
    /// `actions` puts on one menu line.
    static func actionRows(frozenCount: Int, dockerPaused: Bool, lastGap: TimeInterval?) -> [StatusMenu.Item] {
        var rows: [StatusMenu.Item] = []
        if frozenCount > 0 {
            rows.append(StatusMenu.Item(title: frozenCount == 1 ? "1 app frozen" : "\(frozenCount) apps frozen", kind: .info, symbol: "snowflake"))
        }
        if dockerPaused {
            rows.append(StatusMenu.Item(title: "Docker paused", kind: .info, symbol: "shippingbox"))
        }
        if let gap = lastGap, gap > 0 {
            rows.append(StatusMenu.Item(title: "Last network gap \(Int(gap.rounded()))s", kind: .info, symbol: "wifi.exclamationmark"))
        }
        return rows
    }

    /// "Chrome is throttled" / "Chrome and Arc are throttled". No warning
    /// sign: the row draws one.
    static func throttleWarning(_ browsers: [String]) -> String? {
        guard !browsers.isEmpty else { return nil }
        let names: String
        switch browsers.count {
        case 1: names = browsers[0]
        case 2: names = "\(browsers[0]) and \(browsers[1])"
        default: names = browsers.dropLast().joined(separator: ", ") + ", and " + browsers.last!
        }
        return "\(names) \(browsers.count == 1 ? "is" : "are") throttled"
    }
}

/// The line about sleep, read from the journal
/// (`RuntimeState.sleepDisabledByUs`) rather than inferred from the presence
/// of a session. The journal records what Insomnia asked pmset to do; it is
/// not live proof, so the line never promises the lid is safe to close.
/// The right-click menu shows `line`; the popover shows only `warning`: a
/// session that is not holding sleep, or a hold with no session. A session
/// holding sleep as it should gets no popover row, since the header above
/// already says the Mac is being kept awake.
/// Pure so it can be tested.
enum SleepHeldLine {
    struct Line: Equatable {
        let text: String
        let isWarning: Bool
    }

    static func line(sessionActive: Bool, sleepHeld: Bool) -> Line? {
        switch (sessionActive, sleepHeld) {
        case (true, true):
            Line(text: "Sleep held per journal \u{2014} not verified live", isWarning: false)
        case (true, false):
            Line(text: "Sleep is not held \u{2014} this session is not keeping the Mac awake", isWarning: true)
        case (false, true):
            Line(text: "Sleep still held with no session", isWarning: true)
        case (false, false):
            nil
        }
    }

    static func warning(sessionActive: Bool, sleepHeld: Bool) -> String? {
        switch (sessionActive, sleepHeld) {
        case (true, false):
            "Sleep is not held, so this session is not keeping the Mac awake"
        case (false, true):
            "Sleep still held with no session"
        case (true, true), (false, false):
            nil
        }
    }
}

/// macOS hides Wi-Fi network names until Location is allowed; say so rather
/// than reporting no network at all. The menu says it in the line; the
/// popover says the Wi-Fi is on, with the reason as a tooltip.
enum WiFiStatusName {
    struct Display: Equatable {
        let text: String
        let help: String?
    }

    static let hiddenHelp = "macOS hides the network name until Insomnia is allowed to use Location (System Settings \u{203A} Privacy & Security \u{203A} Location Services)."

    static func display(ssid: String?, locationAuthorized: Bool) -> String? {
        if let ssid, !ssid.isEmpty { return ssid }
        return locationAuthorized ? nil : "on (name hidden until Location is allowed)"
    }

    /// The popover's Wi-Fi row: the name, or "On" with the reason as a
    /// tooltip. The menu's line is `display`.
    static func row(ssid: String?, locationAuthorized: Bool) -> Display? {
        if let ssid, !ssid.isEmpty { return Display(text: ssid, help: nil) }
        return locationAuthorized ? nil : Display(text: "On", help: hiddenHelp)
    }
}

/// Short label for a duration: "30m", "2h", "3d". Used by the popover's
/// time buttons.
func chipLabel(for seconds: TimeInterval) -> String {
    SessionMath.formatRemaining(seconds).replacingOccurrences(of: " ", with: "")
}
