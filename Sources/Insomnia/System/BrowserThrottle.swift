import AppKit
import Foundation

/// Spec section 5: Chromium browsers throttle occluded windows unless
/// launched with both flags. Detect, and relaunch with them on request.
enum ChromiumFlags {
    static let occluded = "--disable-backgrounding-occluded-windows"
    static let renderer = "--disable-renderer-backgrounding"
    static let required = [occluded, renderer]

    static let knownBrowsers: [String] = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
    ]

    /// Known Chromium ids plus any agent-list id mentioning chrome/chromium.
    static func chromiumBundleIds(config: Config) -> [String] {
        var ids = knownBrowsers
        for id in config.agentList {
            let l = id.lowercased()
            if (l.contains("chrome") || l.contains("chromium")), !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    /// Splits a `ps -o args=` line into arguments, honouring single and
    /// double quotes and backslash escapes, so a flag that only appears
    /// inside another argument's quoted value is not counted.
    static func tokenize(_ args: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inSingle = false, inDouble = false, escaped = false, hasToken = false
        for ch in args {
            if escaped {
                current.append(ch)
                escaped = false
                hasToken = true
                continue
            }
            switch ch {
            case "\\" where !inSingle:
                escaped = true
            case "'" where !inDouble:
                inSingle.toggle()
                hasToken = true
            case "\"" where !inSingle:
                inDouble.toggle()
                hasToken = true
            case " ", "\t", "\n":
                if inSingle || inDouble {
                    current.append(ch)
                } else if hasToken {
                    out.append(current)
                    current = ""
                    hasToken = false
                }
            default:
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { out.append(current) }
        return out
    }

    /// True when both required flags are present as their own arguments.
    static func hasBothFlags(args: String) -> Bool {
        let tokens = Set(tokenize(args).map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0 })
        return required.allSatisfy { tokens.contains($0) }
    }

    /// Arguments worth carrying over on relaunch so the same profile opens.
    static func preservedArgs(args: String) -> [String] {
        tokenize(args).dropFirst().filter {
            $0.hasPrefix("--user-data-dir=") || $0.hasPrefix("--profile-directory=")
        }
    }
}

struct BrowserStatus: Sendable, Equatable {
    let bundleId: String
    let name: String
    let pid: Int32
    let unthrottled: Bool
}

/// Waits for AppKit termination notifications with one timeout event. This
/// keeps relaunch event-driven instead of waking every few hundred ms.
@MainActor
private final class ApplicationTerminationWaiter {
    private let applications: [NSRunningApplication]
    private var pending: Set<Int32> = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var continuation: CheckedContinuation<Bool, Never>?

    init(applications: [NSRunningApplication]) {
        self.applications = applications
    }

    func terminateAndWait(timeout: TimeInterval) async -> Bool {
        pending = Set(applications.lazy.filter { !$0.isTerminated }.map(\.processIdentifier))
        guard !pending.isEmpty else { return true }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let center = NSWorkspace.shared.notificationCenter
            observer = center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in self?.applicationTerminated(pid) }
            }

            let timeoutTimer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(allTerminated: false) }
            }
            RunLoop.main.add(timeoutTimer, forMode: .common)
            timer = timeoutTimer

            for application in applications where !application.isTerminated {
                application.terminate()
            }
        }
    }

    private func applicationTerminated(_ pid: Int32) {
        pending.remove(pid)
        if pending.isEmpty { finish(allTerminated: true) }
    }

    private func finish(allTerminated: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.invalidate()
        timer = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        continuation.resume(returning: allTerminated)
    }
}

/// The process side of a relaunch: which instances of a browser are
/// running, quitting them, launching one. The app's implementation is
/// NSWorkspace and `open -b`; tests inject a fake, so nothing real is quit.
@MainActor
protocol BrowserProcessControlling: AnyObject {
    /// Process ids of every running application with this bundle id.
    func runningPids(bundleId: String) -> [Int32]
    /// Ask each application to quit and wait: true once all have quit,
    /// false when `timeout` passes first.
    func terminateAndWait(pids: [Int32], timeout: TimeInterval) async -> Bool
    /// `open -b <bundleId> --args <arguments>`; throws when `open` fails.
    func launch(bundleId: String, arguments: [String]) async throws
    /// Wait for an application with this bundle id to appear in the running
    /// list: true as soon as one does, false when `timeout` passes first.
    func waitUntilRunning(bundleId: String, timeout: TimeInterval) async -> Bool
}

struct BrowserProcessError: Error, LocalizedError, Equatable {
    let detail: String
    var errorDescription: String? { detail }
}

@MainActor
final class WorkspaceBrowserProcesses: BrowserProcessControlling {
    func runningPids(bundleId: String) -> [Int32] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleId && !$0.isTerminated }
            .map(\.processIdentifier)
    }

    func terminateAndWait(pids: [Int32], timeout: TimeInterval) async -> Bool {
        let applications = pids.compactMap { NSRunningApplication(processIdentifier: $0) }
        return await ApplicationTerminationWaiter(applications: applications).terminateAndWait(timeout: timeout)
    }

    func launch(bundleId: String, arguments: [String]) async throws {
        let r = try await Shell.run("/usr/bin/open", ["-b", bundleId, "--args"] + arguments, timeout: 15)
        guard r.succeeded else {
            let stderr = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BrowserProcessError(detail: stderr.isEmpty ? "open exited with status \(r.status)" : stderr)
        }
    }

    func waitUntilRunning(bundleId: String, timeout: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while runningPids(bundleId: bundleId).isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }
}

/// What "Relaunch <browser> unthrottled" did. Anything but `.relaunched`
/// is reported to the user in a notification; the browser was quit only
/// in `.launchFailed` and `.didNotStart`.
enum RelaunchOutcome: Equatable, Sendable {
    /// Every instance quit, `open` returned 0, and an instance was running
    /// within `startTimeout`.
    case relaunched
    /// No instance was running; nothing to quit.
    case notRunning
    /// The main process's arguments could not be read, so the profile
    /// could not have been carried over. Nothing was quit.
    case argumentsUnreadable(String)
    /// An instance was still running after the wait. Nothing was launched:
    /// `open` would have put a second copy beside it.
    case stillRunning
    /// Every instance quit, then `open` failed. The browser is not running.
    case launchFailed(String)
    /// Every instance quit and `open` returned 0, but no instance was
    /// running `startTimeout` later. The browser is not running.
    case didNotStart

    /// The notification body, naming the browser; nil when the relaunch
    /// happened.
    func explanation(browser name: String) -> String? {
        switch self {
        case .relaunched:
            nil
        case .notRunning:
            "\(name) is not running. Nothing was quit or relaunched."
        case let .argumentsUnreadable(detail):
            "Could not read \(name)'s profile arguments (\(detail)), so a relaunch could have opened the wrong profile. \(name) was not quit."
        case .stillRunning:
            "\(name) did not quit within \(Int(BrowserThrottle.quitTimeout)) s, so nothing was relaunched. It may still quit later. If it does, open it again yourself."
        case let .launchFailed(detail):
            "\(name) quit but could not be relaunched: \(detail). Open it yourself."
        case .didNotStart:
            "\(name) quit and was asked to open again, but it was not running after \(Int(BrowserThrottle.startTimeout)) s. Open it yourself."
        }
    }
}

@MainActor
final class BrowserThrottle {
    typealias ArgsReader = @Sendable (_ pid: Int32) async throws -> String

    /// How long a browser gets to quit before the relaunch gives up.
    nonisolated static let quitTimeout: TimeInterval = 10
    /// How long a relaunched browser gets to show up in the running list
    /// before the relaunch is reported as failed.
    nonisolated static let startTimeout: TimeInterval = 5

    private(set) var statuses: [BrowserStatus] = []
    /// Display names of running Chromium browsers missing either flag.
    var throttledBrowsers: [String] { statuses.filter { !$0.unthrottled }.map(\.name) }

    private let readArgs: ArgsReader
    private let processes: any BrowserProcessControlling

    init(readArgs: ArgsReader? = nil, processes: (any BrowserProcessControlling)? = nil) {
        self.readArgs = readArgs ?? BrowserThrottle.psArgs
        self.processes = processes ?? WorkspaceBrowserProcesses()
    }

    /// Inspect every running Chromium browser's main process.
    @discardableResult
    func scan(config: Config) async -> [BrowserStatus] {
        let ids = ChromiumFlags.chromiumBundleIds(config: config)
        var out: [BrowserStatus] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, ids.contains(id) else { continue }
            let pid = app.processIdentifier
            let name = app.localizedName ?? id
            do {
                let args = try await readArgs(pid)
                out.append(BrowserStatus(bundleId: id, name: name, pid: pid, unthrottled: ChromiumFlags.hasBothFlags(args: args)))
            } catch {
                Log.error("browser throttle: could not read args of \(name): \(error.localizedDescription)")
            }
        }
        statuses = out
        if !throttledBrowsers.isEmpty {
            Log.info("throttled browsers: \(throttledBrowsers.joined(separator: ", "))")
        }
        return out
    }

    /// Quit the browser, wait up to `quitTimeout` for every instance to
    /// exit, and only then launch it with both flags and the profile
    /// arguments it had. The arguments are read first: a browser whose
    /// arguments cannot be read is not quit, since a relaunch without them
    /// could open another profile. After the wait the running list is read
    /// again, and an instance still there (the waiter timed out, or one
    /// appeared meanwhile) means nothing is launched. `open` returning 0
    /// is not the end either: the running list is polled for up to
    /// `startTimeout`, and a browser that has not appeared by then is
    /// reported, so the user is not left without a browser and without a
    /// word.
    func relaunchUnthrottled(bundleId: String) async -> RelaunchOutcome {
        let pids = processes.runningPids(bundleId: bundleId)
        guard let main = pids.first else {
            Log.info("relaunch: \(bundleId) is not running")
            return .notRunning
        }
        let extra: [String]
        do {
            let args = try await readArgs(main)
            guard !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BrowserProcessError(detail: "ps printed nothing for pid \(main)")
            }
            extra = ChromiumFlags.preservedArgs(args: args)
        } catch {
            Log.error("relaunch: could not read args of \(bundleId) (pid \(main)): \(error.localizedDescription); not quitting")
            return .argumentsUnreadable(error.localizedDescription)
        }
        let quit = await processes.terminateAndWait(pids: pids, timeout: Self.quitTimeout)
        let remaining = processes.runningPids(bundleId: bundleId)
        guard quit, remaining.isEmpty else {
            Log.error("relaunch: \(bundleId) still running after \(Int(Self.quitTimeout)) s (pids \(remaining)); not launching")
            return .stillRunning
        }
        do {
            try await processes.launch(bundleId: bundleId, arguments: ChromiumFlags.required + extra)
        } catch {
            Log.error("open -b \(bundleId) failed: \(error.localizedDescription)")
            return .launchFailed(error.localizedDescription)
        }
        guard await processes.waitUntilRunning(bundleId: bundleId, timeout: Self.startTimeout) else {
            Log.error("relaunch: \(bundleId) not running \(Int(Self.startTimeout)) s after open returned")
            return .didNotStart
        }
        Log.info("relaunched \(bundleId) unthrottled")
        return .relaunched
    }

    static let psArgs: ArgsReader = { pid in
        let r = try await Shell.run("/bin/ps", ["-o", "args=", "-p", String(pid)], timeout: 5)
        return r.stdout
    }
}
