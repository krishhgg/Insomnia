import AppKit

/// User-facing apps first, with standalone background apps in a submenu.
/// Embedded helpers and Insomnia itself are not configuration candidates.
@MainActor
enum RunningApps {
    private static var resolvedNames: [String: String] = [:]
    private static var resolvedIcons: [String: NSImage] = [:]
    private static var missingIcons: Set<String> = []
    /// Names from Config's documented defaults, used when an app is absent.
    private static let defaultNames: [String: String] = [
        "com.t3tools.t3code": "T3 Code (Nightly)",
        "com.t3tools.t3code.reasoning": "T3 Code (Reasoning)",
        "com.conductor.app": "Conductor",
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp",
        "com.google.Chrome": "Google Chrome",
        "org.chromium.Chromium": "Chromium",
        "company.thebrowser.Browser": "Arc",
        "com.docker.docker": "Docker Desktop",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "dev.zed.Zed": "Zed",
        "com.google.antigravity": "Antigravity",
        "com.anthropic.claudefordesktop": "Claude",
        "com.openai.codex": "ChatGPT",
        "io.tailscale.ipn.macsys": "Tailscale",
        "ai.elementlabs.lmstudio": "LM Studio",
        "com.electron.ollama": "Ollama",
    ]

    struct Entry: Hashable {
        let bundleID: String
        let name: String
        let isBackground: Bool
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        let excluded = Set(excluding)
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me, id != Paths.bundleIdentifier,
                  app.activationPolicy != .prohibited,
                  !excluded.contains(id), !seen.contains(id) else { continue }
            if let url = app.bundleURL,
               url.pathComponents.filter({ $0.hasSuffix(".app") }).count > 1 { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id, isBackground: app.activationPolicy != .regular))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle id, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let cached = resolvedNames[bundleID] { return cached }
        let name = defaultNames[bundleID] ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?
            .deletingPathExtension().lastPathComponent
            ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        resolvedNames[bundleID] = name
        return name
    }

    /// Resolve an installed app icon once, outside countdown updates.
    static func icon(for bundleID: String) -> NSImage? {
        if let icon = resolvedIcons[bundleID] { return icon }
        guard !missingIcons.contains(bundleID) else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            missingIcons.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        resolvedIcons[bundleID] = icon
        return icon
    }
}
