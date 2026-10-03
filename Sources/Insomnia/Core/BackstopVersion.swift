import Foundation

/// The recovery contract the installed backstop.sh implements, read from
/// its `# insomnia-backstop-version: N` line.
///
/// Start reads it before the password dialog, under the recovery lock.
/// Version 2 is the first backstop.sh that deletes the pending-start marker
/// under its lock before it restores sleep. An older one, left installed by
/// an upgrade that stopped early, restores sleep after a crash but leaves
/// the marker, so a dialog still open could turn sleep off again with
/// nothing journaled: with it installed no dialog is shown at all.
/// install.sh replaces backstop.sh before the bundle, so only an install
/// that never reached the new script leaves one behind.
enum BackstopVersion {
    static let required = 2
    static let linePrefix = "# insomnia-backstop-version: "

    /// The number on the script's first version line; nil when there is
    /// no such line or it does not hold a number.
    static func declared(in text: String) -> Int? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(linePrefix) }) else { return nil }
        return Int(line.dropFirst(linePrefix.count).trimmingCharacters(in: .whitespaces))
    }

    /// Throws, with the reason and the fix, unless the script at `url`
    /// declares at least `required`.
    static func check(scriptAt url: URL) throws {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BackstopError(message: "could not read backstop.sh at \(url.path) (\(error.localizedDescription)); run scripts/install.sh again")
        }
        guard let version = declared(in: text), version >= required else {
            throw BackstopError(message: "the installed backstop.sh at \(url.path) is older than this build and cannot cancel a password dialog left open by a crash; run scripts/install.sh again")
        }
    }
}

extension LaunchdBackstop {
    func checkVoidsPrompts() throws {
        try BackstopVersion.check(scriptAt: URL(fileURLWithPath: scriptPath))
    }
}
