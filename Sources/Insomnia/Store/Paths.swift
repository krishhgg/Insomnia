import Foundation

/// Every on-disk location Insomnia uses. The whole tree can be relocated with
/// the `INSOMNIA_HOME` environment variable (tests, and `backstop.sh` honours
/// the same variable with the same layout).
///
/// Default layout:
///   ~/Applications/Insomnia.app/Contents/Resources/backstop.sh
///   ~/Library/Application Support/Insomnia/{session.json,state.json,config.json}
///   ~/Library/Logs/Insomnia/{insomnia.log,handoffs.log}
///   ~/Library/LaunchAgents/com.insomnia.backstop.plist
///
/// With INSOMNIA_HOME=/x:
///   /x/Insomnia.app/Contents/Resources/backstop.sh
///   /x/{session.json,state.json,config.json}
///   /x/Logs/{insomnia.log,handoffs.log}
///   /x/LaunchAgents/com.insomnia.backstop.plist
struct Paths: Sendable, Equatable {
    static let environmentKey = "INSOMNIA_HOME"
    static let backstopLabel = "com.insomnia.backstop"
    static let bundleIdentifier = "com.kgarg.insomnia"

    let appSupport: URL
    let logs: URL
    let launchAgents: URL
    /// Where install.sh puts the app bundle. backstop.sh is sealed inside it.
    let appBundle: URL

    init(appSupport: URL, logs: URL, launchAgents: URL, appBundle: URL) {
        self.appSupport = appSupport
        self.logs = logs
        self.launchAgents = launchAgents
        self.appBundle = appBundle
    }

    /// Relocated layout rooted at one directory (used for INSOMNIA_HOME).
    init(root: URL) {
        self.init(
            appSupport: root,
            logs: root.appendingPathComponent("Logs", isDirectory: true),
            launchAgents: root.appendingPathComponent("LaunchAgents", isDirectory: true),
            appBundle: root.appendingPathComponent("Insomnia.app", isDirectory: true)
        )
    }

    /// The standard per-user layout under ~/Library.
    static var standard: Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)
        return Paths(
            appSupport: library.appendingPathComponent("Application Support/Insomnia", isDirectory: true),
            logs: library.appendingPathComponent("Logs/Insomnia", isDirectory: true),
            launchAgents: library.appendingPathComponent("LaunchAgents", isDirectory: true),
            appBundle: home.appendingPathComponent("Applications/Insomnia.app", isDirectory: true)
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
    /// scripts/backstop.sh as install.sh seals it into a bundle, under
    /// Contents/Resources, before the bundle is signed. The LaunchAgent
    /// verifies the bundle's signature before running it (LaunchdBackstop).
    static func backstopScript(inBundle bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/backstop.sh")
    }
    /// The sealed backstop.sh of the installed bundle.
    var backstopScript: URL { Self.backstopScript(inBundle: appBundle) }
    /// flock(2) file shared with backstop.sh (`lockf -k` on the same path).
    /// Created once, never unlinked, so both sides lock the same inode.
    var recoveryLock: URL { appSupport.appendingPathComponent(".recovery.lock") }
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
