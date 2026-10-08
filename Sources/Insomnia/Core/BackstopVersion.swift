import Foundation

/// The recovery contract the agent's backstop.sh implements, read from
/// its `# insomnia-backstop-version: N` line.
///
/// Start reads it before the password dialog, under the recovery lock.
/// Version 2 is the first backstop.sh that deletes the pending-start marker
/// under its lock before it restores sleep. An older one restores sleep
/// after a crash but leaves the marker, so a dialog still open could turn
/// sleep off again with nothing journaled. Version 3 is the first that
/// settles a start the journal still records (`sleepOffAttempt`) from its
/// receipt. Version 4 is the first that reads the receipt under its lock,
/// as the 82-byte line with the predecessor nonce, and the start's
/// `expires`, and gives the start's claim back (SleepOffReceipts). An older
/// one would misread that receipt, or leave the entry, so the session of a
/// start that never finished would stay on disk and no later Start could
/// run until the app settled it. With any of them in place no dialog is
/// shown at all. The script read is the copy sealed in the bundle the
/// agent runs (LaunchdBackstop.scriptPath), so this refuses a bundle whose
/// copy is missing, unreadable or older than this build expects.
enum BackstopVersion {
    static let required = 4
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
