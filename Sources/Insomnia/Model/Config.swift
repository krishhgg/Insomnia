import Foundation

/// User settings, persisted as `config.json` (spec section 10).
/// Decoding tolerates missing keys so configs written by older builds load
/// with defaults filled in.
struct Config: Codable, Equatable, Sendable {
    // Session
    /// Preset durations in seconds, shown as chips.
    var presets: [TimeInterval] = Config.defaultPresets
    var defaultPreset: TimeInterval = 4 * 3600
    /// Hard ceiling on a session, including extensions. 24 hours by default:
    /// the backstop ends a session within a minute of the app going away, but
    /// the deadline is still the last line, and one typo should not hold a
    /// closed laptop awake for days. Raise it in config.json for longer
    /// sessions; the Days pill accepts up to 30 days.
    var maxDuration: TimeInterval = 24 * 3600

    // Lid-close actions
    /// Bundle ids to SIGSTOP while the lid is closed.
    var freezeList: [String] = Config.defaultFreezeList
    /// Also SIGSTOP every other Dock app that is not an agent app, an Apple
    /// app, Docker Desktop or built-in protected (`FreezePlanner.builtInProtected`).
    /// Off: the freeze list only.
    var freezeAllApps: Bool = true
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

    // Battery / thermal floors
    /// Battery percentage below which Low Power Mode is switched on.
    var lowPowerFloor: Int = 40
    /// Battery percentage below which the session is ended.
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

    /// Which defaults the file was written under; 2 is the 24-hour ceiling.
    /// A file without the key comes from an older build, and only such a
    /// file has its stock values migrated on read.
    var configVersion: Int = Config.currentVersion
    static let currentVersion = 2

    static let defaultPresets: [TimeInterval] = [
        30 * 60,
        1 * 3600,
        2 * 3600,
        4 * 3600,
        8 * 3600,
        12 * 3600,
        24 * 3600,
    ]

    /// What builds before the 24-hour ceiling wrote into config.json as
    /// their defaults. Settings saves the whole struct, so an ordinary
    /// install has these as explicit values; in a file without
    /// `configVersion` the decoder reads exactly these as the current
    /// defaults and keeps any other value, which a person chose by hand,
    /// unless it no longer fits under the new ceiling.
    static let legacyMaxDuration: TimeInterval = 30 * 24 * 3600
    static let legacyPresets: [TimeInterval] = defaultPresets + [3 * 24 * 3600]

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
        let savedMax = try c.decodeIfPresent(TimeInterval.self, forKey: .maxDuration)
        maxDuration = savedMax ?? d.maxDuration
        // In a current file every value was written by this build or by
        // hand, a 30-day ceiling included; only an older file is migrated.
        if try c.decodeIfPresent(Int.self, forKey: .configVersion) == nil {
            if presets == Config.legacyPresets { presets = d.presets }
            if maxDuration == Config.legacyMaxDuration { maxDuration = d.maxDuration }
            // A ceiling the user never set is now 24 hours, not the 30 days
            // the presets and default were picked under. Presets above it go
            // (Settings refuses to add them), and a default above it moves
            // to the largest preset left, since bare Enter would refuse it.
            if savedMax == nil || savedMax == Config.legacyMaxDuration {
                presets.removeAll { $0 > maxDuration }
                if defaultPreset > maxDuration { defaultPreset = presets.max() ?? d.defaultPreset }
            }
        }
        freezeList = try c.decodeIfPresent([String].self, forKey: .freezeList) ?? d.freezeList
        freezeAllApps = try c.decodeIfPresent(Bool.self, forKey: .freezeAllApps) ?? d.freezeAllApps
        dockerRule = try c.decodeIfPresent(Bool.self, forKey: .dockerRule) ?? d.dockerRule
        muteOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .muteOnLidClose) ?? d.muteOnLidClose
        darkenDisplayOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .darkenDisplayOnLidClose) ?? d.darkenDisplayOnLidClose
        lowPowerOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lowPowerOnLidClose) ?? d.lowPowerOnLidClose
        agentList = try c.decodeIfPresent([String].self, forKey: .agentList) ?? d.agentList
        lowPowerFloor = try c.decodeIfPresent(Int.self, forKey: .lowPowerFloor) ?? d.lowPowerFloor
        endFloor = try c.decodeIfPresent(Int.self, forKey: .endFloor) ?? d.endFloor
        thermalRules = try c.decodeIfPresent(Bool.self, forKey: .thermalRules) ?? d.thermalRules
        hotspotSSID = try c.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? d.hotspotSSID
        nudgeThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .nudgeThreshold) ?? d.nudgeThreshold
        tmuxTargets = try c.decodeIfPresent([String].self, forKey: .tmuxTargets) ?? d.tmuxTargets
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }
}
