import AppKit
import UniformTypeIdentifiers

/// Apps as Settings shows them: names, icons, summaries, and the running
/// apps Add App offers, everything with a bundle ID that is not Apple's own.
@MainActor
enum RunningApps {
    struct Entry: Hashable {
        let bundleID: String
        let name: String
    }

    static func candidates(excluding: [String]) -> [Entry] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !id.hasPrefix("com.apple."), id != me,
                app.activationPolicy != .prohibited,
                !excluding.contains(id), !seen.contains(id)
            else { continue }
            seen.insert(id)
            out.append(Entry(bundleID: id, name: app.localizedName ?? id))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Name of a running app for a bundle ID, or the last path component.
    static func displayName(for bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }), let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    static func byName(_ lhs: String, _ rhs: String) -> Bool {
        displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs))
            == .orderedAscending
    }

    /// The app's own icon, or the generic app icon for one not installed.
    static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// The bundle ID of the app Choose… picked, after registering the app
    /// with Launch Services. An app it hasn't seen yet, such as one just
    /// unzipped, has no URL for its bundle ID, so its row would be left out
    /// as not installed and could not be changed or removed.
    static func bundleID(ofAppAt url: URL) -> String? {
        LSRegisterURL(url as CFURL, false)
        return Bundle(url: url)?.bundleIdentifier
    }

    /// Whether this Mac has the app. Settings leaves out listed apps it
    /// doesn't have: they have no name to show, and nothing to freeze.
    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Up to three installed apps by name, then how many more: "Slack,
    /// WhatsApp, Discord" or "Claude, Conductor, Cursor and 5 more".
    static func summary(of ids: [String]) -> String {
        let names = ids.filter(isInstalled).map(displayName(for:))
        guard !names.isEmpty else { return "None on this Mac" }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) and \(names.count - 3) more" : shown
    }
}
