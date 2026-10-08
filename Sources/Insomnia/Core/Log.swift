import Foundation
import os

/// Unified logging plus a plain-text line appended to insomnia.log, which is
/// shared with backstop.sh so one file tells the whole story.
///
/// The unified log is readable by every program running as the user (and
/// by anyone with a sysdiagnose), so message bodies go there as private
/// data: `log show` prints `<private>` in their place. The bodies name
/// SSIDs, tmux targets, process names and bundle ids. insomnia.log keeps
/// the full text for the user; its permissions are its own protection.
enum Log {
    static let logger = Logger(subsystem: Paths.bundleIdentifier, category: "core")
    private static let lock = NSLock()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        append(level: "info", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        append(level: "error", message)
    }

    static func append(level: String, _ message: String, paths: Paths = .fromEnvironment()) {
        let now = Date().formatted(.iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        let line = "\(now) [\(level)] insomnia: \(message)\n"
        // insomnia.log can hold the record of a session's end, which
        // backstop.sh writes and reads back under the recovery lock alone
        // (`LogEndRecord`), so it is rotated only while this task's
        // transaction holds that lock, and a record still in force is
        // copied forward first. Without the lock the line goes to the file
        // as it is; the next line written under the lock rotates it.
        let rotation: OwnerOnly.LogRotation = RecoveryLock.held?.locks(path: paths.recoveryLock.path) == true
            ? .keeping { LogEndRecord.keepRecords(in: $0, log: paths.logFile, session: paths.sessionFile) }
            : .deferred
        lock.lock()
        defer { lock.unlock() }
        do {
            // Owner-only, and rotated to insomnia.log.1 past OwnerOnly.maxLogBytes.
            // A chmod or rotation that fails is thrown after the line is
            // written, so it reaches the unified log below.
            try OwnerOnly.appendToLog(line, at: paths.logFile, rotation: rotation)
        } catch {
            // The description carries a path under the home directory.
            logger.error("insomnia.log: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Runs `body` under the lock every line appended here takes, so no
    /// line and no rotation from this process runs meanwhile. `body` must
    /// not log.
    static func withFileLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
