import Foundation

/// Every on-disk location Insomnia uses. The whole tree can be relocated with
/// the `INSOMNIA_HOME` environment variable (tests, and `backstop.sh` honours
/// the same variable with the same layout).
///
/// Default layout:
///   ~/Library/Application Support/Insomnia/{session.json,state.json,config.json,backstop.sh}
///   ~/Library/Logs/Insomnia/{insomnia.log,handoffs.log}
///   ~/Library/LaunchAgents/com.insomnia.backstop.plist
///
/// With INSOMNIA_HOME=/x:
///   /x/{session.json,state.json,config.json,backstop.sh}
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
    /// Written when a session is ended but session.json cannot be removed (an
    /// immutable file): a copy of that file's exact bytes. While the two
    /// match, the session is over whatever its endsAt says. backstop.sh
    /// writes and honours the same file.
    var endedSessionFile: URL { appSupport.appendingPathComponent("ended-session.json") }
    var stateFile: URL { appSupport.appendingPathComponent("state.json") }
    var configFile: URL { appSupport.appendingPathComponent("config.json") }
    /// Installed copy of scripts/backstop.sh, placed there by install.sh.
    var backstopScript: URL { appSupport.appendingPathComponent("backstop.sh") }
    /// flock(2) file shared with backstop.sh (`lockf -k` on the same path).
    /// Created once, never unlinked, so both sides lock the same inode.
    var recoveryLock: URL { appSupport.appendingPathComponent(".recovery.lock") }
    /// flock(2) file the app holds for its whole lifetime (`AppAliveLock`).
    /// backstop.sh probes it without waiting: acquiring it means no Insomnia
    /// process is alive, and a valid session is then ended. Never unlinked.
    var appAliveFile: URL { appSupport.appendingPathComponent(".app.alive") }
    /// Written by scripts/simulate-lid.sh ("closed" or "open") to drive the
    /// lid-close action path without touching the hinge. See LidSimulation.
    var simulateLidFile: URL { appSupport.appendingPathComponent("simulate-lid") }

    var logFile: URL { logs.appendingPathComponent("insomnia.log") }
    var handoffsLog: URL { logs.appendingPathComponent("handoffs.log") }

    var backstopPlist: URL { launchAgents.appendingPathComponent("\(Paths.backstopLabel).plist") }

    /// Create every directory Insomnia writes into.
    func createDirectories() throws {
        for dir in [appSupport, logs, launchAgents] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
