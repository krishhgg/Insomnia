import Darwin
import Foundation

/// Explicit work, not process discovery. A caller registers one productive
/// turn/job, heartbeats while it is outstanding, and finishes on success,
/// failure, cancellation, or input-required. Interactive shells are NOT work.
struct AgentJob: Codable, Equatable, Sendable {
    static let leaseSeconds: TimeInterval = 90
    static let maximumSeconds: TimeInterval = 8 * 3600

    let id: UUID
    let name: String
    let pid: Int32
    let identity: ProcessIdentity
    let startedAt: Date
    let deadline: Date
    var heartbeatAt: Date
    let startedUptime: TimeInterval
    var heartbeatUptime: TimeInterval

    func inactiveReason(at now: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                        lookup: (Int32) -> ProcessLookup) -> String? {
        guard !name.isEmpty, name.count <= 120, pid > 0,
              !identity.bootSession.isEmpty,
              deadline > startedAt, deadline.timeIntervalSince(startedAt) <= Self.maximumSeconds,
              heartbeatAt >= startedAt, heartbeatAt <= now.addingTimeInterval(5),
              startedAt <= now.addingTimeInterval(5),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              startedUptime >= 0, heartbeatUptime >= startedUptime,
              heartbeatUptime <= uptime + 5 else { return "invalid activity record" }
        if now >= deadline || uptime - startedUptime >= Self.maximumSeconds { return "8-hour safety limit reached" }
        if now.timeIntervalSince(heartbeatAt) >= Self.leaseSeconds || uptime - heartbeatUptime >= Self.leaseSeconds {
            return "activity disconnected (heartbeat expired)"
        }
        guard case let .present(process) = lookup(pid), process.identity == identity else {
            return "owner exited, changed, or could not be verified"
        }
        // CPU idle, stopped, hidden windows and terminal disconnects by
        // themselves do not prove a productive turn is finished.
        return nil
    }
}

struct AgentSnapshot: Sendable {
    var active: [AgentJob] = []
    var warnings: [String] = []
}

struct AgentActivity: Sendable {
    let paths: Paths
    var directory: URL { paths.appSupport.appendingPathComponent("agent-jobs", isDirectory: true) }
    private var store: Store { Store(paths: paths) }
    func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func checkDirectory(create: Bool) throws {
        if create { try OwnerOnly.createDirectory(directory) }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
              st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw ActivityError("Activity directory must be an owner-only, non-symlink directory")
        }
    }

    /// Serialize begin/heartbeat/finish so a heartbeat that read just before
    /// finish cannot publish afterward and resurrect a completed turn. The
    /// lock is kernel-owned, close-on-exec, and has a bounded wait.
    private func mutate<T>(_ body: () throws -> T) throws -> T {
        try checkDirectory(create: false)
        let lock = directory.appendingPathComponent(".activity.lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ActivityError("Activity lock unavailable") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_uid == getuid(), st.st_mode & 0o077 == 0 else { throw ActivityError("Unsafe activity lock") }
        for _ in 0..<200 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return try body() }
            guard errno == EWOULDBLOCK else { throw ActivityError("Could not lock activity records") }
            usleep(10_000)
        }
        throw ActivityError("Activity lock busy; retry or let the lease expire")
    }

    /// Descriptor-level validation: never follow symlinks or block on FIFOs,
    /// and bound bytes before decoding. This API is local to the current UID;
    /// it is deliberately not a remote, unauthenticated power-control API.
    func read(_ id: UUID) throws -> AgentJob {
        try checkDirectory(create: false)
        let fd = open(file(id).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ActivityError("Activity record unavailable") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              st.st_size > 0, st.st_size <= 16_384 else { throw ActivityError("Unsafe activity record") }
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw ActivityError("Incomplete activity record") }
        let job = try Store.makeDecoder().decode(AgentJob.self, from: Data(bytes))
        guard job.id == id else { throw ActivityError("Activity ID mismatch") }
        return job
    }

    func begin(name: String, pid: Int32, now: Date = Date(),
               uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
               lookup: (Int32) -> ProcessLookup = SignalProcessControl.processTableState) throws -> AgentJob {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              case let .present(process) = lookup(pid), !process.identity.bootSession.isEmpty else {
            throw ActivityError("Supply a job name (1–120 characters) and a verifiable live owner PID")
        }
        try checkDirectory(create: true)
        // Match Store's whole-second dates so the returned lease is exactly
        // the one other processes read, rather than up to a second longer.
        let timestamp = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        let job = AgentJob(id: UUID(), name: name, pid: pid, identity: process.identity,
                           startedAt: timestamp, deadline: timestamp.addingTimeInterval(AgentJob.maximumSeconds), heartbeatAt: timestamp,
                           startedUptime: uptime, heartbeatUptime: uptime)
        return try mutate {
            try store.write(job, to: file(job.id))
            return job
        }
    }

    func heartbeat(_ id: UUID, now: Date = Date(),
                   uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                   lookup: (Int32) -> ProcessLookup = SignalProcessControl.processTableState) throws {
        try mutate {
            var job = try read(id)
            guard job.inactiveReason(at: now, uptime: uptime, lookup: lookup) == nil else {
                throw ActivityError("Activity expired or owner is gone; it cannot be revived")
            }
            job.heartbeatAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            job.heartbeatUptime = uptime
            try store.write(job, to: file(id))
        }
    }

    func finish(_ id: UUID) throws {
        // Idempotent but never remove an unvalidated entry.
        guard FileManager.default.fileExists(atPath: file(id).path) else { return }
        try mutate {
            guard FileManager.default.fileExists(atPath: file(id).path) else { return }
            _ = try read(id)
            try store.remove(at: file(id))
        }
    }

    func snapshot(now: Date = Date(),
                  uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                  lookup: (Int32) -> ProcessLookup = SignalProcessControl.processTableState) -> AgentSnapshot {
        guard FileManager.default.fileExists(atPath: directory.path) else { return AgentSnapshot() }
        do {
            try checkDirectory(create: false)
            var enumerationError: Error?
            guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw ActivityError("Activity directory unreadable") }
            var urls: [URL] = []
            // Bound enumeration itself, not just the number of JSON reads.
            for case let url as URL in iterator {
                urls.append(url)
                guard urls.count <= 256 else { throw ActivityError("Too many activity records; finish old jobs before using Auto") }
            }
            if let enumerationError { throw enumerationError }
            var result = AgentSnapshot()
            for url in urls where url.pathExtension == "json" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                do {
                    let job = try read(id)
                    if let reason = job.inactiveReason(at: now, uptime: uptime, lookup: lookup) {
                        result.warnings.append("\(job.name): \(reason)")
                    } else {
                        result.active.append(job)
                    }
                } catch { result.warnings.append("Activity \(id.uuidString.prefix(8)): invalid or unreadable; not keeping awake") }
            }
            result.active.sort { $0.id.uuidString < $1.id.uuidString }
            return result
        } catch { return AgentSnapshot(warnings: [error.localizedDescription]) }
    }

    struct ActivityError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// CLI dispatch before AppKit starts. UUIDs are capability tokens for local
/// integrations. No arbitrary file paths and no commands executed by the app.
enum AgentActivityCommand {
    static func run(_ args: [String], paths: Paths = .fromEnvironment()) -> (status: Int32, text: String)? {
        guard args.first == "--agent" else { return nil }
        let activity = AgentActivity(paths: paths)
        do {
            if args.count == 4, args[1] == "begin", let pid = Int32(args[3]) {
                return (0, try activity.begin(name: args[2], pid: pid).id.uuidString)
            }
            if args.count == 3, let id = UUID(uuidString: args[2]) {
                switch args[1] {
                case "heartbeat": try activity.heartbeat(id)
                case "finish": try activity.finish(id)
                default: throw AgentActivity.ActivityError("Unknown activity operation")
                }
                return (0, "")
            }
            throw AgentActivity.ActivityError("Usage: Insomnia --agent begin NAME OWNER_PID | heartbeat UUID | finish UUID")
        } catch { return (2, error.localizedDescription) }
    }
}
