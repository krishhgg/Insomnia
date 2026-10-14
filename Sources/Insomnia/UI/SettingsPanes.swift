import SwiftUI

/// The panes in the Settings sidebar, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case sessions
    case lidClose
    case agents
    case power
    case network

    var id: String { rawValue }

    /// The UserDefaults key that remembers the pane last shown, so the
    /// window reopens on it (HIG: restore the most recently viewed pane).
    static let storageKey = "SettingsPane"

    /// The pane the window opens on.
    static var stored: SettingsPane {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }

    /// The sidebar row and the window title while the pane is showing.
    var title: String {
        switch self {
        case .general: "General"
        case .sessions: "Sessions"
        case .lidClose: "Lid close"
        case .agents: "Agent apps"
        case .power: "Battery & thermal"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .sessions: "timer"
        case .lidClose: "laptopcomputer"
        case .agents: "cpu.fill"
        case .power: "battery.75percent"
        case .network: "wifi"
        }
    }

    /// The tile behind the symbol, as System Settings draws its panes.
    var tint: Color {
        switch self {
        case .general: .gray
        case .sessions: .indigo
        case .lidClose: .purple
        case .agents: .teal
        case .power: .green
        case .network: .blue
        }
    }
}

/// One setting the search field can find: the pane it lives on, the name
/// the user sees, other words they might type for it, and the explanation
/// its ⓘ button shows, if it has one. `id` is the anchor the pane scrolls
/// to (`SettingsView.anchored`).
struct SettingsEntry: Identifiable, Equatable {
    let id: String
    let pane: SettingsPane
    let title: String
    let keywords: [String]
    var help: SettingHelp? = nil
}

/// What the sidebar search field matches against.
enum SettingsSearch {
    static let entries: [SettingsEntry] = [
        .init(id: "launchAtLogin", pane: .general, title: "Launch at login", keywords: ["startup", "login items", "open at login", "boot"]),
        .init(id: "configFile", pane: .general, title: "Config file", keywords: ["config.json", "json", "path", "location", "folder"]),

        .init(id: "presets", pane: .sessions, title: "Presets", keywords: ["durations", "chips", "time", "timer", "add preset"]),
        .init(id: "defaultPreset", pane: .sessions, title: "Default preset", keywords: ["duration", "time", "timer"]),
        .init(id: "maxSession", pane: .sessions, title: "Maximum session", keywords: ["limit", "longest", "duration", "30 days"]),

        .init(id: "darken", pane: .lidClose, title: "Turn off the display and keyboard backlight", keywords: ["brightness", "screen", "dim", "dark", "keyboard"], help: .darken),
        .init(id: "freezeList", pane: .lidClose, title: "Freeze while the lid is closed", keywords: ["freeze list", "SIGSTOP", "pause", "stop", "apps", "bundle identifier"], help: .freeze),
        .init(id: "freezeAll", pane: .lidClose, title: "Freeze every other app", keywords: ["all apps", "Dock", "would freeze", "protected"]),
        .init(id: "docker", pane: .lidClose, title: "Pause Docker Desktop", keywords: ["containers", "Docker"], help: .docker),
        .init(id: "mute", pane: .lidClose, title: "Mute audio on lid close", keywords: ["sound", "volume", "speakers", "microphone", "mic", "AirPods"]),
        .init(id: "lowPowerOnLidClose", pane: .lidClose, title: "Low Power Mode while the lid is closed", keywords: ["battery", "energy", "power"]),

        .init(id: "agentList", pane: .agents, title: "Never throttle or freeze", keywords: ["agent apps", "protect", "allow", "bundle identifier", "AI"], help: .agents),
        .init(id: "appNap", pane: .agents, title: "Turn App Nap off", keywords: ["App Nap", "throttle", "NSAppSleepDisabled"], help: .appNap),

        .init(id: "lowPowerFloor", pane: .power, title: "Low Power Mode below", keywords: ["battery", "floor", "percent", "energy"]),
        .init(id: "endFloor", pane: .power, title: "End session below", keywords: ["battery", "floor", "percent", "stop"], help: .battery),
        .init(id: "thermal", pane: .power, title: "Thermal rules", keywords: ["heat", "hot", "temperature", "critical", "fan"]),

        .init(id: "hotspot", pane: .network, title: "Hotspot name", keywords: ["SSID", "Wi-Fi", "iPhone", "Personal Hotspot", "failover", "offline", "internet"]),
        .init(id: "hotspotPassword", pane: .network, title: "Hotspot password", keywords: ["keychain", "Wi-Fi password", "secret"], help: .hotspot),
        .init(id: "location", pane: .network, title: "Location Services", keywords: ["permission", "privacy", "Wi-Fi names", "SSID"], help: .location),
        .init(id: "nudge", pane: .network, title: "tmux nudge delay", keywords: ["tmux", "continue", "offline", "threshold", "seconds", "nudge"], help: .nudge),
        .init(id: "pressEnter", pane: .network, title: "Press Enter after continue", keywords: ["tmux", "return", "submit"]),
        .init(id: "tmuxTargets", pane: .network, title: "tmux targets", keywords: ["tmux", "pane", "session", "window", "mark"]),
    ]

    /// The entries every word of `query` matches, in sidebar order. A word
    /// matches when it starts a word of the entry's title, its keywords,
    /// its pane's title or its ⓘ text, ignoring case, accents and hyphens
    /// ("wifi" finds "Wi-Fi", "freez" finds "Freeze").
    static func results(for query: String) -> [SettingsEntry] {
        let wanted = words(query)
        guard !wanted.isEmpty else { return [] }
        return entries.filter { entry in
            let help = entry.help.map { [$0.summary, $0.text] } ?? []
            let have = words(([entry.title, entry.pane.title] + entry.keywords + help).joined(separator: " "))
            return wanted.allSatisfy { w in have.contains { $0.hasPrefix(w) } }
        }
    }

    static func entry(_ id: String) -> SettingsEntry? {
        entries.first { $0.id == id }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: "")
            .split { !$0.isLetter && !$0.isNumber && $0 != "." }
            .map(String.init)
    }
}

/// What the ⓘ buttons explain, beside the setting or section each names.
/// Only what a user can do without: what must be seen (a warning, a
/// status, what a switch does) stays on the pane.
extension SettingHelp {
    static let darken = SettingHelp(
        summary: "How brightness comes back when the lid opens",
        text: "The display brightness and keyboard backlight are saved, set to zero and restored when the lid opens.\n\nIf Insomnia is not running when you open the lid, press the brightness-up key."
    )
    static let freeze = SettingHelp(
        summary: "Which apps are frozen and which are protected",
        text: "Apps on the freeze list are stopped with SIGSTOP while the lid is closed and resumed when it opens.\n\nWith \u{201C}Freeze every other app\u{201D} on (off by default), every other Dock app is stopped too, except agent apps, Apple apps, Docker Desktop and built-in protected apps: editors, terminals, browsers, AI apps, password managers, local databases, Tailscale, local model servers, and meeting, recording and dictation apps such as Zoom, Teams, Webex, Wispr Flow, Granola, Otter, OBS and Loom. Agent apps are never frozen."
    )
    static let docker = SettingHelp(
        summary: "How Insomnia checks for containers before pausing",
        text: "Docker Desktop is paused only if a second check right before the pause still finds no running container. A container that starts in that last moment is paused with it."
    )
    static let agents = SettingHelp(
        summary: "Which other apps are protected from freezing",
        text: "Agent apps are never frozen or throttled.\n\nEditors, AI apps, terminals, browsers, password managers, local databases, Tailscale, local model servers, and meeting, recording and dictation apps are also protected from \u{201C}Freeze every other app\u{201D} even when they are not listed here. Adding one to the freeze list in Lid close overrides that."
    )
    static let appNap = SettingHelp(
        summary: "What changes in each app's preferences",
        text: "Writes NSAppSleepDisabled = YES into each listed app's preferences when a session starts and puts the previous value back when it ends."
    )
    static let battery = SettingHelp(
        summary: "How the two battery floors work together",
        text: "Below the first floor Insomnia turns on Low Power Mode; below the second it ends the session.\n\nThe end floor stays below the Low Power Mode floor: setting one at or past the other moves the other \(Config.floorStep)% away."
    )
    static let hotspot = SettingHelp(
        summary: "Where the name and password are saved",
        text: "Save writes the name to the config file and keeps the password in your login keychain.\n\nAfter you update or reinstall Insomnia, enter the password again: only the build that saved it can read it without asking."
    )
    static let location = SettingHelp(
        summary: "Why Insomnia asks for Location access",
        text: "Without Location permission macOS hides Wi-Fi network names, so Insomnia cannot find the hotspot. Insomnia asks once a hotspot name is set, when you save the password or start a session.\n\nmacOS records this grant as Location Services access for Insomnia. Insomnia uses it only to read Wi-Fi network names and never requests your location."
    )
    static let nudge = SettingHelp(
        summary: "When and where Insomnia types \u{201C}continue\u{201D}",
        text: "After that long offline, Insomnia types \u{201C}continue\u{201D} into each pane listed below. Only a pane you have marked with the command shown is nudged.\n\nThe nudge works on its own, with or without a hotspot: any Wi-Fi gap during a session counts."
    )
}

/// The line at the top of the hotspot section. Failover has no switch of
/// its own: it is on whenever a hotspot name is set, so this says whether
/// it is on and, if it cannot join yet, what is missing.
struct HotspotSetupStatus: Equatable {
    enum Level: Equatable {
        case off
        case incomplete
        case ready
    }

    let level: Level
    let text: String

    /// `passwordEntered` is whether the password field holds anything (a
    /// load fills it with the saved password); `passwordNotice` is the
    /// notice under the field.
    static func of(ssid: String, passwordEntered: Bool, passwordNotice: String?, locationAuthorized: Bool) -> HotspotSetupStatus {
        let name = HotspotSSID.normalized(ssid)
        if name.isEmpty {
            return .init(level: .off, text: "Off. Enter your hotspot's name to turn failover on.")
        }
        if passwordNotice != nil || !passwordEntered {
            return .init(level: .incomplete, text: "Needs the password for \u{201C}\(name)\u{201D}.")
        }
        if !locationAuthorized {
            return .init(level: .incomplete, text: "Needs Location access to find \u{201C}\(name)\u{201D}.")
        }
        return .init(level: .ready, text: "On. If Wi-Fi drops during a session, Insomnia joins \u{201C}\(name)\u{201D}.")
    }
}

private struct RevealedSettingKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The setting a search result just jumped to, tinted for a moment.
    /// (Written out by hand: the `@Entry` macro needs Xcode's plugin.)
    var revealedSetting: String? {
        get { self[RevealedSettingKey.self] }
        set { self[RevealedSettingKey.self] = newValue }
    }
}

/// Rows that make up one searchable setting: the scroll target for its
/// search result, tinted while the jump lands on it.
struct SettingAnchor<Content: View>: View {
    let id: String
    let content: Content
    @Environment(\.revealedSetting) private var revealed

    var body: some View {
        Group { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(id)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(revealed == id ? 0.16 : 0))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            }
    }
}

/// A pane's sidebar icon, drawn as System Settings draws its own: a white
/// glyph centred on a coloured rounded square. The glyph is fitted into a
/// box 60% of the tile high and 70% wide, so square symbols keep a 4 pt
/// margin and wide ones (the laptop, the battery) 3 pt, instead of running
/// to the tile's edges.
struct PaneIcon: View {
    let pane: SettingsPane

    static let tile: CGFloat = 20
    static let glyph = CGSize(width: 14, height: 12)
    static let radius: CGFloat = 5

    var body: some View {
        Image(systemName: pane.symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(width: Self.glyph.width, height: Self.glyph.height)
            .frame(width: Self.tile, height: Self.tile)
            .background(pane.tint.gradient, in: .rect(cornerRadius: Self.radius, style: .continuous))
    }
}
