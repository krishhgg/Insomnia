import Foundation

/// User settings, persisted as `config.json` (spec section 10).
/// Decoding tolerates missing keys so configs written by older builds load
/// with defaults filled in.
struct Config: Codable, Equatable, Sendable {
    // Session
    /// Preset durations in seconds, shown as chips.
    var presets: [TimeInterval] = Config.defaultPresets
    var defaultPreset: TimeInterval = 4 * 3600
    /// The pill that is focused when the pills open, for a start and for an
    /// extend.
    var defaultFocusField: DurationInput.Field = .hours
    /// Hard ceiling on a session, including extensions. 30 days.
    var maxDuration: TimeInterval = 30 * 24 * 3600

    // Lid-close actions
    /// Bundle ids to SIGSTOP while the lid is closed.
    var freezeList: [String] = Config.defaultFreezeList
    /// Also SIGSTOP every other Dock app that is not an agent app, an Apple
    /// app, Docker Desktop or built-in protected (`FreezePlanner.builtInProtected`).
    /// Off by default (and for a config.json without the key): a fresh
    /// install freezes only the freeze list until the user opts in. A
    /// config.json an earlier build saved with it on gets it turned off
    /// once (`applyLidCloseDefaults`).
    var freezeAllApps: Bool = false
    /// SIGSTOP Docker Desktop on lid close when `docker ps` finds no running
    /// container, checked once more right before the signal. Off by default
    /// (and for a config.json without the key): a container that starts
    /// between the last check and the signal is frozen with Desktop.
    var dockerRule: Bool = false
    /// Mute the output on lid close and restore the volume on open. On by
    /// default: with sleep disabled, sound otherwise keeps playing from the
    /// closed laptop. A config.json an earlier build saved with it off gets
    /// it turned on once (`applyLidCloseDefaults`).
    var muteOnLidClose: Bool = true
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
    /// The one hotspot joined during an outage while
    /// `hotspotPriorityEnabled` is off.
    var hotspotSSID: String = ""
    /// Join `priorityHotspots` in order during an outage, in place of
    /// `hotspotSSID`. Off by default (and for a config.json without the
    /// key). Turning it off keeps the list for the next time.
    var hotspotPriorityEnabled: Bool = false
    /// Hotspot SSIDs, highest priority first. Each one's password is the
    /// keychain item for that SSID, the same item `hotspotSSID` uses, so a
    /// hotspot on both shares one password.
    var priorityHotspots: [String] = []
    /// With the priority list on, move from a lower hotspot on it to a
    /// higher one once scans find the higher one back in range
    /// (`SwitchUpMachine`). Each move takes the Mac offline for a few
    /// seconds.
    var hotspotSwitchUp: Bool = true
    /// With the priority list on, leave a hotspot Insomnia joined once
    /// scans find a saved Wi-Fi network in range, and let macOS rejoin
    /// it (`HandBackMachine`).
    var hotspotReturnToWiFi: Bool = true
    /// Wake and join a hotspot 5 s into any outage. Off by default (and
    /// for a config.json without the key): an outage that did not start on
    /// a hotspot Insomnia joined waits `FailoverMachine.patientDelay`
    /// first, so macOS can rejoin the network it dropped, such as a blip
    /// of home Wi-Fi, without a hotspot being woken for nothing.
    var aggressiveHotspotJoin: Bool = false
    /// Seconds of outage after which tmux panes are nudged.
    var nudgeThreshold: TimeInterval = 90
    /// tmux targets as `session:window.pane`. Only a pane carrying the
    /// `@insomnia-nudge` pane option is nudged (TmuxNudge).
    var tmuxTargets: [String] = []
    /// Press Enter after typing `continue`. Off: the word is typed and left
    /// for the user or the program; on: Enter also submits anything already
    /// typed in that pane.
    var tmuxNudgePressesEnter: Bool = false

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

    // One-time updates
    /// Whether this config has had the lid-close update
    /// (`applyLidCloseDefaults`). True for a config this build creates;
    /// false for a config.json without the key, which an earlier build
    /// saved. Once true it stays true, so a user who turns either setting
    /// back is never overridden again.
    var lidCloseDefaultsApplied: Bool = true
    /// What that update changed, shown in Settings until the user dismisses
    /// it. nil on a fresh install, when the update changed nothing, and
    /// after dismissal.
    var lidCloseDefaultsNotice: LidCloseDefaultsChange?

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
        // A value this build does not know falls back to hours; it must not
        // cost the user the rest of the config.
        defaultFocusField = (try? c.decodeIfPresent(DurationInput.Field.self, forKey: .defaultFocusField)) ?? d.defaultFocusField
        maxDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxDuration) ?? d.maxDuration
        freezeList = try c.decodeIfPresent([String].self, forKey: .freezeList) ?? d.freezeList
        freezeAllApps = try c.decodeIfPresent(Bool.self, forKey: .freezeAllApps) ?? d.freezeAllApps
        dockerRule = try c.decodeIfPresent(Bool.self, forKey: .dockerRule) ?? d.dockerRule
        lidCloseDefaultsApplied = try c.decodeIfPresent(Bool.self, forKey: .lidCloseDefaultsApplied) ?? false
        lidCloseDefaultsNotice = try c.decodeIfPresent(LidCloseDefaultsChange.self, forKey: .lidCloseDefaultsNotice)
        // Earlier builds read a missing key as off, so the update below
        // sees what such a config.json actually did.
        muteOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .muteOnLidClose) ?? (lidCloseDefaultsApplied && d.muteOnLidClose)
        darkenDisplayOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .darkenDisplayOnLidClose) ?? d.darkenDisplayOnLidClose
        lowPowerOnLidClose = try c.decodeIfPresent(Bool.self, forKey: .lowPowerOnLidClose) ?? d.lowPowerOnLidClose
        agentList = try c.decodeIfPresent([String].self, forKey: .agentList) ?? d.agentList
        disableAppNapForAgents = try c.decodeIfPresent(Bool.self, forKey: .disableAppNapForAgents) ?? d.disableAppNapForAgents
        lowPowerFloor = try c.decodeIfPresent(Int.self, forKey: .lowPowerFloor) ?? d.lowPowerFloor
        endFloor = try c.decodeIfPresent(Int.self, forKey: .endFloor) ?? d.endFloor
        thermalRules = try c.decodeIfPresent(Bool.self, forKey: .thermalRules) ?? d.thermalRules
        hotspotSSID = try c.decodeIfPresent(String.self, forKey: .hotspotSSID) ?? d.hotspotSSID
        hotspotPriorityEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotspotPriorityEnabled) ?? d.hotspotPriorityEnabled
        priorityHotspots = try c.decodeIfPresent([String].self, forKey: .priorityHotspots) ?? d.priorityHotspots
        hotspotSwitchUp = try c.decodeIfPresent(Bool.self, forKey: .hotspotSwitchUp) ?? d.hotspotSwitchUp
        hotspotReturnToWiFi = try c.decodeIfPresent(Bool.self, forKey: .hotspotReturnToWiFi) ?? d.hotspotReturnToWiFi
        aggressiveHotspotJoin = try c.decodeIfPresent(Bool.self, forKey: .aggressiveHotspotJoin) ?? d.aggressiveHotspotJoin
        nudgeThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .nudgeThreshold) ?? d.nudgeThreshold
        tmuxTargets = try c.decodeIfPresent([String].self, forKey: .tmuxTargets) ?? d.tmuxTargets
        tmuxNudgePressesEnter = try c.decodeIfPresent(Bool.self, forKey: .tmuxNudgePressesEnter) ?? d.tmuxNudgePressesEnter
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        launchAtLoginInstall = try c.decodeIfPresent(String.self, forKey: .launchAtLoginInstall)
    }
}

// MARK: Lid-close update

extension Config {
    /// The one-time lid-close update for a config.json an earlier build
    /// saved: freeze-all off and mute on lid close on, the defaults since
    /// freeze-all stopped a meeting notetaker and sound kept playing with
    /// the lid closed. Marks the config either way, so it runs once.
    /// Returns what it changed and records that for Settings; nil when the
    /// config already had the update or both settings already matched.
    mutating func applyLidCloseDefaults() -> LidCloseDefaultsChange? {
        guard !lidCloseDefaultsApplied else { return nil }
        lidCloseDefaultsApplied = true
        let change = LidCloseDefaultsChange(turnedOffFreezeAll: freezeAllApps, turnedOnMute: !muteOnLidClose)
        freezeAllApps = false
        muteOnLidClose = true
        guard change.turnedOffFreezeAll || change.turnedOnMute else { return nil }
        lidCloseDefaultsNotice = change
        return change
    }
}

/// What `Config.applyLidCloseDefaults` changed. The notification and the
/// line in Settings name each change and where to change it back.
struct LidCloseDefaultsChange: Codable, Equatable, Sendable {
    var turnedOffFreezeAll: Bool
    var turnedOnMute: Bool

    static let title = "Lid-close settings changed"

    /// The changes as one clause, for example: "Mute audio on lid close"
    /// is now on.
    var changes: String {
        var parts: [String] = []
        if turnedOffFreezeAll { parts.append("\"Freeze every other app while the lid is closed\" is now off") }
        if turnedOnMute { parts.append("\"Mute audio on lid close\" is now on") }
        return parts.joined(separator: " and ")
    }

    private var both: Bool { turnedOffFreezeAll && turnedOnMute }

    var notificationBody: String {
        "This update changed \(both ? "two lid-close settings" : "a lid-close setting"): \(changes). "
            + "To change \(both ? "them" : "it") back, choose Settings\u{2026} from the Insomnia menu bar icon and look under Lid-close actions."
    }

    var settingsLine: String {
        "This update changed \(both ? "two lid-close settings" : "a lid-close setting"): \(changes). "
            + "\(both ? "Both toggles are" : "The toggle is") below."
    }
}

// MARK: Hotspots

extension Config {
    /// The hotspots an outage tries, in order: the priority list when it
    /// is on, otherwise `hotspotSSID`. Normalized, without blanks or
    /// repeats.
    var hotspotsToJoin: [String] {
        hotspotPriorityEnabled ? priorityHotspotList : Self.distinct([hotspotSSID])
    }

    /// The priority list as the failover and Settings read it, whether or
    /// not it is on: normalized, without blanks or repeats, which a
    /// config.json edited by hand can hold.
    var priorityHotspotList: [String] {
        Self.distinct(priorityHotspots)
    }

    private static func distinct(_ ssids: [String]) -> [String] {
        var seen = Set<String>()
        return ssids.map(HotspotSSID.normalized).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Whether `hotspotSSID` or the priority list, on or off, names `ssid`.
    /// Its keychain item is removed only when neither does.
    func namesHotspot(_ ssid: String) -> Bool {
        let ssid = HotspotSSID.normalized(ssid)
        guard !ssid.isEmpty else { return false }
        return HotspotSSID.normalized(hotspotSSID) == ssid
            || priorityHotspots.contains { HotspotSSID.normalized($0) == ssid }
    }

    /// Turns the priority list on or off. Turned on with an empty list,
    /// the list starts with `hotspotSSID`, whose saved password it shares.
    mutating func setHotspotPriority(_ enabled: Bool) {
        hotspotPriorityEnabled = enabled
        let single = HotspotSSID.normalized(hotspotSSID)
        if enabled, priorityHotspotList.isEmpty, !single.isEmpty {
            priorityHotspots = [single]
        }
    }

    /// Adds `ssid` at the bottom of the list, unless it is blank or listed.
    /// Each change to the list stores it as `priorityHotspotList` first,
    /// so what Settings shows is what it moves.
    mutating func addPriorityHotspot(_ ssid: String) {
        let ssid = HotspotSSID.normalized(ssid)
        priorityHotspots = priorityHotspotList
        // The same device whichever apostrophe it was typed with.
        guard !ssid.isEmpty, !HotspotSSID.any(of: priorityHotspots, matches: ssid) else { return }
        priorityHotspots.append(ssid)
    }

    mutating func removePriorityHotspot(_ ssid: String) {
        let ssid = HotspotSSID.normalized(ssid)
        priorityHotspots = priorityHotspotList.filter { $0 != ssid }
    }

    /// Moves `ssid` `offset` places down the list (negative: up), stopping
    /// at either end.
    mutating func movePriorityHotspot(_ ssid: String, by offset: Int) {
        let ssid = HotspotSSID.normalized(ssid)
        priorityHotspots = priorityHotspotList
        guard let from = priorityHotspots.firstIndex(of: ssid) else { return }
        let to = min(max(from + offset, 0), priorityHotspots.count - 1)
        guard to != from else { return }
        priorityHotspots.insert(priorityHotspots.remove(at: from), at: to)
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
