import Foundation

/// User settings, persisted as `config.json` (spec section 10).
/// Decoding tolerates missing keys so configs written by older builds load
/// with defaults filled in.
struct Config: Codable, Equatable, Sendable {
    // Session
    /// Preset durations in seconds, shown as chips.
    var presets: [TimeInterval] = Config.defaultPresets
    var defaultPreset: TimeInterval = 4 * 3600
    /// Hard ceiling on a session, including extensions. 30 days.
    var maxDuration: TimeInterval = 30 * 24 * 3600

    // Lid-close actions
    /// Bundle ids to SIGSTOP while the lid is closed.
    var freezeList: [String] = Config.defaultFreezeList
    /// Also SIGSTOP every other Dock app that is not an agent app, an Apple
    /// app, Docker Desktop or built-in protected (`FreezePlanner.builtInProtected`).
    /// Off by default (and for a config.json without the key): a fresh
    /// install freezes only the freeze list until the user opts in.
    var freezeAllApps: Bool = false
    var dockerRule: Bool = true
    var muteOnLidClose: Bool = false
    /// Save the display brightness and keyboard backlight, set both to zero
    /// on lid close and restore them on lid open. With sleep disabled macOS
    /// no longer turns the panel off itself.
    var darkenDisplayOnLidClose: Bool = true
    /// Switch Low Power Mode on while the lid is closed (heat and battery:
    /// with sleep disabled the machine otherwise runs at full speed).
    var lowPowerOnLidClose: Bool = true

    // Agent apps that must never be throttled or frozen.
    var agentList: [String] = Config.defaultAgentList
    /// Write `NSAppSleepDisabled = YES` into each agent app's preferences at
    /// session start so App Nap never throttles it, and put the previous
    /// value back at session end. Off: Insomnia never writes another app's
    /// preferences.
    var disableAppNapForAgents: Bool = false

    // Battery / thermal floors
    /// Battery percentage below which Low Power Mode is switched on.
    var lowPowerFloor: Int = 40
    /// Battery percentage below which the session is ended. 0 turns the
    /// battery end off. Otherwise kept below `lowPowerFloor`, which gives Low
    /// Power Mode a chance to come on before the session ends; a reading
    /// already below both floors still ends it. See `setEndFloor`,
    /// `setLowPowerFloor` and `normalizeFloors`.
    var endFloor: Int = 10
    var thermalRules: Bool = true

    // Network failover
    var hotspotSSID: String = ""
    /// Seconds of outage after which tmux panes are nudged.
    var nudgeThreshold: TimeInterval = 90
    /// tmux targets as `session:window.pane`.
    var tmuxTargets: [String] = []

    // App
    var launchAtLogin: Bool = false
    /// The install (code directory hash, bundle path and the executable's
    /// file identity: `LoginItem.install`) whose login item macOS last
    /// had on file, written when a registration is accepted.
    /// At launch it tells a reinstall, which the app heals by registering
    /// again, from the user removing the item in System Settings, which
    /// the app respects. nil in a config written before this field; the
    /// first launch with the flag on registers once and records it.
    var launchAtLoginInstall: String?

    static let defaultPresets: [TimeInterval] = [
        30 * 60,
        1 * 3600,
        2 * 3600,
        4 * 3600,
        8 * 3600,
        12 * 3600,
        24 * 3600,
        3 * 24 * 3600,
    ]

    /// Default freeze list: chat apps that burn battery in the background.
    static let defaultFreezeList: [String] = [
        "com.tinyspeck.slackmacgap",      // Slack
        "net.whatsapp.WhatsApp",          // WhatsApp
        "com.hnc.Discord",                // Discord
    ]

    /// Default agent list (spec section 5). Bundle ids confirmed against
    /// installed apps where possible; see README for how to edit.
    static let defaultAgentList: [String] = [
        "com.t3tools.t3code",             // T3 Code (Nightly)
        "com.t3tools.t3code.reasoning",   // T3 Code (Reasoning)
        "com.conductor.app",              // Conductor
        "com.apple.Terminal",             // Terminal
        "com.googlecode.iterm2",          // iTerm2
        "com.mitchellh.ghostty",          // Ghostty
        "dev.warp.Warp-Stable",           // Warp
        "com.google.Chrome",              // Google Chrome
        "org.chromium.Chromium",          // Chromium
        "company.thebrowser.Browser",     // Arc
        "com.docker.docker",              // Docker Desktop
        "com.microsoft.VSCode",           // Visual Studio Code
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",                    // Zed
        "com.google.antigravity",         // Antigravity
        "com.anthropic.claudefordesktop", // Claude
        "com.openai.codex",               // ChatGPT (hosts Codex and computer use)
        "io.tailscale.ipn.macsys",        // Tailscale
        "ai.elementlabs.lmstudio",        // LM Studio
        "com.electron.ollama",            // Ollama
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        presets = try c.decodeIfPresent([TimeInterval].self, forKey: .presets) ?? d.presets
        defaultPreset = try c.decodeIfPresent(TimeInterval.self, forKey: .defaultPreset) ?? d.defaultPreset
        maxDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxDuration) ?? d.maxDuration
        freezeList = try c.decodeIfPresent([String].self, forKey: .freezeList) ?? d.freezeList
        freezeAllApps = try c.decodeIfPresent(Bool.self, forKey: .freezeAllApps) ?? d.freezeAllApps
        dockerRule = try c.decodeIfPresent(Bool.self, forKey: .dockerRule) ?? d.dockerRule
        muteOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .muteOnLidClose) ?? d.muteOnLidClose
        darkenDisplayOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .darkenDisplayOnLidClose) ?? d.darkenDisplayOnLidClose
        lowPowerOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lowPowerOnLidClose) ?? d.lowPowerOnLidClose
        agentList = try c.decodeIfPresent([String].self, forKey: .agentList) ?? d.agentList
        disableAppNapForAgents = try c.decodeIfPresent(Bool.self, forKey: .disableAppNapForAgents) ?? d.disableAppNapForAgents
        lowPowerFloor = try c.decodeIfPresent(Int.self, forKey: .lowPowerFloor) ?? d.lowPowerFloor
        endFloor = try c.decodeIfPresent(Int.self, forKey: .endFloor) ?? d.endFloor
        thermalRules = try c.decodeIfPresent(Bool.self, forKey: .thermalRules) ?? d.thermalRules
        hotspotSSID = try c.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? d.hotspotSSID
        nudgeThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .nudgeThreshold) ?? d.nudgeThreshold
        tmuxTargets = try c.decodeIfPresent([String].self, forKey: .tmuxTargets) ?? d.tmuxTargets
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        launchAtLoginInstall = try c.decodeIfPresent(String.self, forKey: .launchAtLoginInstall)
    }
}

// MARK: Battery floors

extension Config {
    /// Settings step for both floors; the floors are kept at least one step
    /// apart.
    static let floorStep = 5
    /// Highest end floor Settings offers: one step below a 100% Low Power
    /// Mode floor.
    static let maxEndFloor = 100 - floorStep

    /// A non-zero end floor sits below the Low Power Mode floor, so the mode
    /// gets its chance before the end.
    var floorsAreOrdered: Bool { endFloor == 0 || endFloor < lowPowerFloor }

    /// Sets the end floor (0...`maxEndFloor`) and raises the Low Power Mode
    /// floor one step above it when it would otherwise not be above it.
    mutating func setEndFloor(_ value: Int) {
        endFloor = min(max(value, 0), Config.maxEndFloor)
        if endFloor > 0, lowPowerFloor <= endFloor {
            lowPowerFloor = min(endFloor + Config.floorStep, 100)
        }
    }

    /// Sets the Low Power Mode floor (0...100) and lowers the end floor one
    /// step below it when it would otherwise not be below it. An end floor
    /// pushed to 0 is off.
    mutating func setLowPowerFloor(_ value: Int) {
        lowPowerFloor = min(max(value, 0), 100)
        if endFloor > 0, endFloor >= lowPowerFloor {
            endFloor = max(lowPowerFloor - Config.floorStep, 0)
        }
    }

    /// Clamps both floors to their ranges and restores the order by raising
    /// the Low Power Mode floor, never by lowering the end the user asked
    /// for. Returns a description of the change for the log, or nil when
    /// nothing changed. Run on a config.json that Settings did not write.
    mutating func normalizeFloors() -> String? {
        let before = (lowPowerFloor, endFloor)
        lowPowerFloor = min(max(lowPowerFloor, 0), 100)
        endFloor = min(max(endFloor, 0), Config.maxEndFloor)
        if !floorsAreOrdered {
            lowPowerFloor = min(endFloor + Config.floorStep, 100)
        }
        guard (lowPowerFloor, endFloor) != before else { return nil }
        return "battery floors corrected: lowPowerFloor \(before.0) -> \(lowPowerFloor), endFloor \(before.1) -> \(endFloor)"
    }
}
