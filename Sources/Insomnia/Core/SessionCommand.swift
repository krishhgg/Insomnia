import AppKit
import Darwin
import Foundation

/// A session action that arrives from outside the menu, through
/// `Insomnia --session` (`SessionCommandLine`). Each runs like its menu
/// counterpart: `start` like the start pills, `extend` like the extend
/// pills, `end` like hold-to-end.
enum SessionCommand: Equatable, Sendable {
    case start(seconds: Int)
    case extend(seconds: Int)
    case end

    static let alreadyRunning = "a session is already running; use extend"

    /// The text of a request file: `start <seconds>`, `extend <seconds>` or
    /// `end`. `<seconds>` is a whole number from 1 to `Int32.max`
    /// (`SessionMath` still caps a session at `Config.maxDuration`). nil for
    /// anything else.
    init?(text: String) {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if words == ["end"] {
            self = .end
            return
        }
        guard words.count == 2, let seconds = Self.seconds(words[1]) else { return nil }
        switch words[0] {
        case "start": self = .start(seconds: seconds)
        case "extend": self = .extend(seconds: seconds)
        default: return nil
        }
    }

    var text: String {
        switch self {
        case let .start(seconds): "start \(seconds)"
        case let .extend(seconds): "extend \(seconds)"
        case .end: "end"
        }
    }

    /// Digits only, from 1 to `Int32.max`.
    static func seconds(_ word: String) -> Int? {
        guard !word.isEmpty, word.utf8.allSatisfy(isDigit),
              let seconds = Int(word), seconds > 0, seconds <= Int(Int32.max)
        else { return nil }
        return seconds
    }

    /// The name a command line gives its request and answer files: 1 to 32
    /// characters, digits and `-`, so neither file can land outside the
    /// support directory.
    static func isRequestID(_ word: String) -> Bool {
        (1...32).contains(word.utf8.count) && word.utf8.allSatisfy { isDigit($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}

/// One command from one command line. Each command line writes its own
/// file, `Paths.sessionCommandRequest(id)`, so no two ever share a path:
/// publishing, the app's claim and a take-back are each one `rename(2)` of
/// that caller's own file.
struct SessionRequest: Equatable, Sendable {
    let command: SessionCommand
    let id: String
}

/// The app's answer to one request, at `Paths.sessionCommandReply(id)`.
struct SessionCommandReply: Codable, Equatable, Sendable {
    /// nil when the command took effect, otherwise why not, for the person
    /// or script that sent it.
    var error: String?
}

extension SessionManager {
    /// Runs `command` like its menu counterpart. nil when this call took
    /// effect, otherwise why not. Only a failure recorded during this call
    /// is given as the reason; an older `lastError` is about something else.
    func run(_ command: SessionCommand) async -> String? {
        let fails = failCount
        var reason: String? { failCount == fails ? nil : lastError }
        switch command {
        case let .start(seconds):
            if session != nil { return SessionCommand.alreadyRunning }
            if await tryStart(duration: TimeInterval(seconds)) { return nil }
            if session != nil { return SessionCommand.alreadyRunning }
            return reason ?? "the session did not start; see the log"
        case let .extend(seconds):
            // A start still queued or in flight has no session yet.
            if session == nil { await waitForQueuedWork() }
            guard session != nil else { return "no session is running" }
            if await tryExtend(by: TimeInterval(seconds)) { return nil }
            if session == nil { return "the session ended first" }
            return reason ?? "the session was not extended; it may already be as long as a session can be"
        case .end:
            // Always a real end, session or not: it abandons a start still
            // queued or in flight, and finishes an earlier end, a journal
            // left dirty, or a session.json that a delayed launch recovery
            // has not adopted yet.
            switch await end(reason: .user) {
            case .restored:
                return nil
            case .incomplete:
                return reason ?? "the session ended, but not every change is undone yet; see the log"
            case .locked:
                return "the recovery lock is held by another process, so nothing changed; Insomnia retries the end"
            case .sessionRetained:
                return "session.json could not be removed; Insomnia retries the end"
            case .journalUnreadable:
                return "state.json cannot be read, so nothing was undone; see the log"
            case let .privilegedCommandRunning(pid):
                return "a sudo pmset (pid \(pid)) is still running; the end finishes when it exits"
            }
        }
    }

    /// Runs `request` and writes the answer where `Insomnia --session`
    /// waits for it.
    func serve(_ request: SessionRequest) async {
        let error = await run(request.command)
        Log.info("session command \(request.command.text) (\(request.id)): \(error ?? "done")")
        do {
            try store.write(SessionCommandReply(error: error), to: paths.sessionCommandReply(request.id))
        } catch {
            Log.error("session command: could not answer \(request.id): \(error.localizedDescription)")
        }
    }
}

/// Watches the support directory for request files
/// (`Paths.sessionCommandRequest`) and hands each request to `onRequest` on
/// the main actor, oldest first. AppDelegate starts it once the launch
/// reconcile has run, and it runs for as long as the app does, with or
/// without a session. The files are the same trust boundary as config.json
/// and the simulate-lid trigger: only this user can write the directory. A
/// request is served only while it is fresh: one written more than
/// `SessionCommandLine.staleAfter` seconds before the app reads it is
/// claimed, logged and dropped, never run, because the command line that
/// wrote it has given up by then.
@MainActor
final class SessionCommandWatcher {
    var onRequest: ((SessionRequest) -> Void)?

    private var source: (any DispatchSourceFileSystemObject)?
    private var paths: Paths?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func start(paths: Paths) {
        guard source == nil else { return }
        self.paths = paths
        // Nobody waits for an answer from before this launch: a command
        // line waits only while the app that took its request runs.
        removeAnswers(olderThan: 0)
        let fd = open(paths.appSupport.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("session command: cannot watch \(paths.appSupport.path): \(String(cString: strerror(errno)))")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in
            Task { @MainActor in self?.consume() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
        // A request written before the watch began has no event of its own.
        consume()
    }

    func stop() {
        source?.cancel()
        source = nil
        paths = nil
    }

    /// Serves every request on disk, oldest first. The watcher calls this on
    /// each directory write; internal so tests can drive it without the
    /// watcher.
    func consume() {
        guard let paths else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.appSupport.path)) ?? []
        let claimed = names.compactMap(Paths.sessionCommandRequestID).compactMap { claim($0, paths: paths) }
        guard !claimed.isEmpty else { return }
        // Answers whose command line stopped waiting go with each new
        // batch, so a long-running app does not collect them.
        removeAnswers(olderThan: SessionCommandLine.replyTimeout)
        for item in claimed.sorted(by: { ($0.written, $0.id) < ($1.written, $1.id) }) {
            guard now().timeIntervalSince(item.written) <= SessionCommandLine.staleAfter else {
                Log.info("session command: ignored stale \"\(item.text)\" (\(item.id))")
                continue
            }
            guard let command = SessionCommand(text: item.text) else {
                Log.error("session command: ignoring \"\(item.text)\" (\(item.id)); expected start <seconds>, extend <seconds> or end")
                continue
            }
            onRequest?(SessionRequest(command: command, id: item.id))
        }
    }

    // MARK: Private

    /// Claims one request before reading it: `rename(2)` to a per-process
    /// path is atomic, so the command line taking its request back and the
    /// app cannot both have it. `written` is the file's modification time,
    /// which the rename keeps (a file whose time cannot be read counts as
    /// stale). nil when the command line took it back first.
    private func claim(_ id: String, paths: Paths) -> (id: String, text: String, written: Date)? {
        let file = paths.sessionCommandRequest(id)
        let claimed = file.appendingPathExtension("claimed.\(getpid())")
        guard rename(file.path, claimed.path) == 0 else {
            let code = errno
            if code != ENOENT {
                Log.error("session command: cannot claim \(file.path): \(String(cString: strerror(code)))")
            }
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        let written = (try? FileManager.default.attributesOfItem(atPath: claimed.path))?[.modificationDate] as? Date
        let text = (try? String(contentsOf: claimed, encoding: .utf8)) ?? ""
        return (id, text.trimmingCharacters(in: .whitespacesAndNewlines), written ?? .distantPast)
    }

    private func removeAnswers(olderThan age: TimeInterval) {
        guard let paths else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.appSupport.path)) ?? []
        for id in names.compactMap(Paths.sessionCommandReplyID) {
            let url = paths.sessionCommandReply(id)
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if now().timeIntervalSince(written ?? .distantPast) >= age {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// `Insomnia --session start <seconds> | extend <seconds> | end | status`.
/// One-shot mode for scripts and agents. It drives the running menu bar app
/// and changes nothing itself, so the session it starts is the one the menu
/// bar counts down, ends from the menu like any other, and keeps the
/// battery and thermal floors. It writes its own request file
/// (`Paths.sessionCommandRequest`) for the app's `SessionCommandWatcher`,
/// then waits for the app's `SessionCommandReply`. `status` only reads
/// session.json.
///
/// Prints one line. Exits 0 when the command took effect (and for `status`
/// whenever session.json can be read), 1 when the app refused the command,
/// did not take it within `claimTimeout`, or did not answer within
/// `replyTimeout`, and 64 on a usage error.
enum SessionCommandLine {
    static let flag = "--session"
    /// `InsomniaSessionCommandVersion` in Resources/Info.plist. A script
    /// that may meet an older build reads it before running the binary,
    /// because a build without this mode opens the menu bar app instead.
    static let version = 1
    /// EX_USAGE from sysexits(3).
    static let usageStatus: Int32 = 64
    /// How long a running app has to take the request before the command
    /// line takes it back.
    static let claimTimeout: TimeInterval = 2
    /// A request older than this when the app reads it is dropped. Longer
    /// than `claimTimeout` plus a busy main thread.
    static let staleAfter: TimeInterval = 5
    /// How long the app has to answer. A start arms the backstop and runs
    /// pmset, which has its own 20 s limit, then reads it back.
    static let replyTimeout: TimeInterval = 60
    static let pollInterval: TimeInterval = 0.1

    struct Output: Equatable, Sendable {
        let lines: [String]
        let status: Int32
    }

    /// What runs under this bundle id besides this command line.
    enum RunningApp: Sendable {
        case none
        /// A build whose Info.plist lacks this interface.
        case older
        case current
    }

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode. `id` names this call's files.
    /// `runningApp` explains a request nothing took. `wait` sleeps between
    /// reads of the files.
    static func run(
        _ arguments: [String],
        paths: Paths = .fromEnvironment(),
        now: () -> Date = Date.init,
        timeZone: TimeZone = .current,
        id: String = "\(getpid())-\(UInt32.random(in: .min ... .max))",
        runningApp: () -> RunningApp = runningApp,
        wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Output? {
        guard arguments.first == flag else { return nil }
        let words = Array(arguments.dropFirst())
        let store = Store(paths: paths)
        if words == ["status"] {
            do {
                return Output(lines: [describe(try store.loadSession(), now: now(), timeZone: timeZone)], status: 0)
            } catch {
                return failure(error.localizedDescription)
            }
        }
        guard let command = SessionCommand(text: words.joined(separator: " ")), SessionCommand.isRequestID(id) else {
            return Output(lines: ["usage: Insomnia --session start <seconds> | extend <seconds> | end | status"], status: usageStatus)
        }

        let request = paths.sessionCommandRequest(id)
        do {
            try publish(command.text + "\n", at: request)
        } catch {
            return failure("cannot write \(request.path): \(error.localizedDescription)")
        }

        var waited: TimeInterval = 0
        while FileManager.default.fileExists(atPath: request.path) {
            if waited >= claimTimeout {
                guard takeBack(request) else { break }  // the app claimed it just now
                switch runningApp() {
                case .none:
                    return failure("Insomnia is not running, so nothing took the command; open the app and try again")
                case .older:
                    return failure("the Insomnia that is running is a version without --session; quit it and open the new one")
                case .current:
                    return failure("Insomnia did not take the command within \(Int(claimTimeout)) s; it may still be starting, so try again")
                }
            }
            wait(pollInterval)
            waited += pollInterval
        }

        let replyFile = paths.sessionCommandReply(id)
        waited = 0
        while true {
            if let data = try? Data(contentsOf: replyFile),
               let reply = try? JSONDecoder().decode(SessionCommandReply.self, from: data) {
                try? FileManager.default.removeItem(at: replyFile)
                if let error = reply.error { return failure(error) }
                return Output(lines: [describe(try? store.loadSession(), now: now(), timeZone: timeZone)], status: 0)
            }
            guard waited < replyTimeout else {
                return failure("Insomnia took the command but did not answer within \(Int(replyTimeout)) s; see \(paths.logFile.path)")
            }
            wait(pollInterval)
            waited += pollInterval
        }
    }

    /// `running until <ISO 8601 time> (<remaining> left)` or
    /// `no session is running`. The remaining time is rounded up to the
    /// minute, so a session just started for 2m reads 2m, not 1m.
    static func describe(_ session: Session?, now: Date, timeZone: TimeZone) -> String {
        guard let session, !session.isExpired(at: now) else { return "no session is running" }
        let format = ISO8601DateFormatter()
        format.timeZone = timeZone
        let left = (session.remaining(at: now) / 60).rounded(.up) * 60
        return "running until \(format.string(from: session.endsAt)) (\(SessionMath.formatRemaining(left)) left)"
    }

    /// Another process of this bundle id, that is the menu bar app, and
    /// whether its bundle declares this interface. This command line is not
    /// a registered application, and its own pid is left out in case it is.
    static func runningApp() -> RunningApp {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Paths.bundleIdentifier)
            .filter { $0.processIdentifier != getpid() }
        guard let app = apps.first else { return .none }
        guard let info = app.bundleURL?.appendingPathComponent("Contents/Info.plist"),
              let plist = NSDictionary(contentsOf: info),
              plist["InsomniaSessionCommandVersion"] as? Int == version
        else { return .older }
        return .current
    }

    // MARK: Private

    private static func failure(_ line: String) -> Output {
        Output(lines: [line], status: 1)
    }

    /// Writes the request under a private name and renames it into place,
    /// so the app never reads half a request.
    private static func publish(_ text: String, at request: URL) throws {
        let tmp = request.appendingPathExtension("tmp")
        try Data(text.utf8).write(to: tmp)
        guard rename(tmp.path, request.path) == 0 else {
            let code = errno
            unlink(tmp.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Takes this command line's unclaimed request back so that it cannot
    /// run later. false when the app claimed it first.
    private static func takeBack(_ request: URL) -> Bool {
        let taken = request.appendingPathExtension("taken")
        guard rename(request.path, taken.path) == 0 else { return false }
        unlink(taken.path)
        return true
    }
}
