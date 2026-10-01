import Foundation
import os

/// Unified logging plus a plain-text line appended to insomnia.log, which is
/// shared with backstop.sh so one file tells the whole story.
enum Log {
    static let logger = Logger(subsystem: Paths.bundleIdentifier, category: "core")
    private static let lock = NSLock()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append(level: "info", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append(level: "error", message)
    }

    static func append(level: String, _ message: String, paths: Paths = .fromEnvironment()) {
        let now = Date().formatted(.iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        let line = "\(now) [\(level)] insomnia: \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            // Owner-only, and rotated to insomnia.log.1 past OwnerOnly.maxLogBytes.
            try OwnerOnly.appendToLog(line, at: paths.logFile)
        } catch {
            logger.error("log append failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
