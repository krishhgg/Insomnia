import Foundation

/// Every on-disk location Insomnia uses. The whole tree can be relocated with
/// the `INSOMNIA_HOME` environment variable (tests, and `backstop.sh` honours
/// the same variable with the same layout).
///
/// Default layout:
///   ~/Library/Application Support/Insomnia/{session.json,state.json,config.json,backstop.sh,pending-start,unfinished-command.json}
///   ~/Library/Logs/Insomnia/{insomnia.log,handoffs.log}
///   ~/Library/LaunchAgents/com.insomnia.backstop.plist
///
/// With INSOMNIA_HOME=/x:
///   /x/{session.json,state.json,config.json,backstop.sh,pending-start,unfinished-command.json}
///   /x/Logs/{insomnia.log,handoffs.log}
///   /x/LaunchAgents/com.insomnia.backstop.plist
struct Paths: Sendable, Equatable {
    static let environmentKey = "INSOMNIA_HOME"
    static let backstopLabel = "com.insomnia.backstop"
    static let bundleIdentifier = "com.kgarg.insomnia"

    let appSupport: URL
    let logs: URL
    let launchAgents: URL

    init(appSupport: URL, logs: URL, launchAgents: URL) {
        self.appSupport = appSupport
        self.logs = logs
        self.launchAgents = launchAgents
    }

    /// Relocated layout rooted at one directory (used for INSOMNIA_HOME).
    init(root: URL) {
        self.init(
            appSupport: root,
            logs: root.appendingPathComponent("Logs", isDirectory: true),
            launchAgents: root.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }

    /// The standard per-user layout under ~/Library.
    static var standard: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return Paths(
            appSupport: library.appendingPathComponent("Application Support/Insomnia", isDirectory: true),
            logs: library.appendingPathComponent("Logs/Insomnia", isDirectory: true),
            launchAgents: library.appendingPathComponent("LaunchAgents", isDirectory: true)
        )
    }

    /// `INSOMNIA_HOME` if set, else `standard`.
    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let root = env[environmentKey], !root.isEmpty {
            return Paths(root: URL(fileURLWithPath: root, isDirectory: true))
        }
        return .standard
    }

    var sessionFile: URL { appSupport.appendingPathComponent("session.json") }
    /// Where an unreadable session.json goes: this prefix, a UTC stamp
    /// (yyyyMMddTHHmmssZ) and, if that name is taken, -1, -2, ... The same
    /// shape is produced by backstop.sh and removed by `uninstall.sh --purge`.
    static let unreadableSessionPrefix = "session.json.unreadable-"
    var stateFile: URL { appSupport.appendingPathComponent("state.json") }
    var configFile: URL { appSupport.appendingPathComponent("config.json") }
    /// Installed copy of scripts/backstop.sh, placed there by install.sh.
    var backstopScript: URL { appSupport.appendingPathComponent("backstop.sh") }
    /// flock(2) file shared with backstop.sh (`lockf -k` on the same path).
    /// Created once, never unlinked, so both sides lock the same inode.
    var recoveryLock: URL { appSupport.appendingPathComponent(".recovery.lock") }
    /// The nonce a Start writes just before the password dialog and deletes
    /// before it releases the recovery lock (see PendingStart). backstop.sh
    /// and uninstall.sh delete it under the same lock. Every deleter also
    /// locks the file itself first (`lockf` or flock(2)), the lock the
    /// dialog's root command holds while it runs.
    var pendingStartFile: URL { appSupport.appendingPathComponent("pending-start") }
    /// The `sudo pmset` left running that holds the recovery lock, written
    /// while it runs so a relaunch after a crash can name it. Removed when
    /// it exits, and by the next transaction that takes the lock.
    var unfinishedCommandFile: URL { appSupport.appendingPathComponent("unfinished-command.json") }
    /// Written by scripts/simulate-lid.sh ("closed" or "open") to drive the
    /// lid-close action path without touching the hinge. See LidSimulation.
    var simulateLidFile: URL { appSupport.appendingPathComponent("simulate-lid") }

    /// Both logs are owner-only and rotate to `<name>.1` past
    /// `OwnerOnly.maxLogBytes`; uninstall.sh --purge removes the `.1` too.
    var logFile: URL { logs.appendingPathComponent("insomnia.log") }
    var handoffsLog: URL { logs.appendingPathComponent("handoffs.log") }

    var backstopPlist: URL { launchAgents.appendingPathComponent("\(Paths.backstopLabel).plist") }

    /// Create every directory Insomnia writes into. Its own two are made
    /// 0700 (an existing one is tightened); the LaunchAgents directory is
    /// shared with every other login agent, so it is only created.
    func createDirectories() throws {
        if let problem = try OwnerOnly.createDirectory(appSupport) { OwnerOnly.reportOnce(problem) }
        if let problem = try OwnerOnly.createDirectory(logs) { OwnerOnly.reportOnce(problem) }
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
    }
}
