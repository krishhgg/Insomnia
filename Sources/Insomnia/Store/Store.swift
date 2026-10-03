import Foundation

/// Atomic JSON persistence for the three files Insomnia keeps on disk.
/// Writes go to a temp file in the same directory and are renamed into place
/// so a crash mid-write can never leave a truncated session or state file.
struct Store: Sendable {
    let paths: Paths

    init(paths: Paths) {
        self.paths = paths
    }

    // MARK: Generic

    /// Dates are ISO 8601 (`2026-09-02T10:00:00Z`) so backstop.sh can parse
    /// them with `date -j -f`.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Returns nil when the file does not exist. Throws on unreadable or
    /// undecodable content.
    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Only a regular file is opened. open(2) on a FIFO with no writer
        // blocks, and these reads run on the main actor under the recovery
        // lock. Data(contentsOf:) on macOS 26 refuses a FIFO with EACCES,
        // which reads as a permissions problem; this check names the real
        // cause and does not rely on that. stat(2) follows a symlink, as
        // Data(contentsOf:) does.
        var info = stat()
        if stat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw StoreError.notRegularFile(file: url.path)
        }
        let data = try Data(contentsOf: url)
        return try Store.makeDecoder().decode(T.self, from: data)
    }

    /// Atomic write: temp file + rename(2).
    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try writeAtomically(try Store.makeEncoder().encode(value), to: url)
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [])
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.rename(from: tmp.path, to: url.path, errno: err)
        }
    }

    /// Removes the file; a missing file is not an error.
    func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Typed helpers

    /// Throws StoreError.unreadable, with a one-line reason, when the file
    /// does not decode.
    func loadSession() throws -> Session? {
        do {
            return try read(Session.self, from: paths.sessionFile)
        } catch let error as DecodingError {
            throw StoreError.unreadable(file: paths.sessionFile.path, detail: Self.brief(error))
        }
    }
    func saveSession(_ s: Session) throws { try write(s, to: paths.sessionFile) }
    func deleteSession() throws { try remove(at: paths.sessionFile) }
    /// Whether anything is at session.json, a dangling symlink included.
    /// lstat(2) only: the entry is never opened.
    func sessionEntryExists() -> Bool {
        var st = stat()
        return lstat(paths.sessionFile.path, &st) == 0
    }

    /// Renames an unreadable session.json to a timestamped sibling (see
    /// Paths.unreadableSessionPrefix) and returns the new location. The
    /// bytes are kept for inspection; the next reader sees no session.
    /// Never overwrites: a taken name gets -1, -2, ..., and the rename
    /// itself fails rather than replace a file that appeared meanwhile.
    func moveAsideUnreadableSession(now: Date) throws -> URL {
        let base = Paths.unreadableSessionPrefix + Self.stamp(now)
        var dest = paths.appSupport.appendingPathComponent(base)
        var n = 0
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            dest = paths.appSupport.appendingPathComponent("\(base)-\(n)")
        }
        try FileManager.default.moveItem(at: paths.sessionFile, to: dest)
        return dest
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// Non-mutating. A journal that does not decode stays exactly where it
    /// is: it is the only record of what a previous run changed, and moving
    /// or rewriting it would let the next reader (this app, backstop.sh,
    /// uninstall.sh) see no journal and call the machine clean. The error
    /// names the file so a person can fix or move it.
    func loadState() throws -> RuntimeState? {
        do {
            return try read(RuntimeState.self, from: paths.stateFile)
        } catch let error as DecodingError {
            throw StoreError.corrupt(file: paths.stateFile.path, detail: Self.brief(error))
        }
    }
    func saveState(_ s: RuntimeState) throws { try write(s, to: paths.stateFile) }

    /// The pending-start marker holds the nonce as plain bytes, no newline,
    /// written atomically so the root command never reads half of it.
    func savePendingStart(_ nonce: String) throws {
        try writeAtomically(Data(nonce.utf8), to: paths.pendingStartFile)
    }

    /// Deletes the pending-start marker under the marker's own lock. The
    /// command the password dialog runs as root holds an flock(2) lock on
    /// the marker from before its nonce check until pmset exits (see
    /// AdministratorPrompt.markerLock), so taking that lock first means the
    /// marker goes either before the check, which then fails, or after
    /// pmset has exited, never in between. The link is followed to the
    /// file, as lockf follows it, and the wait is polled so the caller is
    /// never blocked. Returns whether a marker was there.
    ///
    /// Throws `.markerBusy` when the lock is still held after `timeout`,
    /// and `.unlink` when the file cannot be deleted (an immutable flag, a
    /// deny-delete ACL, a directory in its place). unlink(2) never removes
    /// a tree. The marker then stays, and callers must treat the dialog it
    /// belongs to as still able to turn sleep off.
    @discardableResult
    func removePendingStart(timeout: TimeInterval, pollEvery: Duration = .milliseconds(50)) async throws -> Bool {
        let path = paths.pendingStartFile.path
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            // O_NONBLOCK: a FIFO in its place must not hang the open.
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 {
                let err = errno
                guard err == ENOENT else { throw StoreError.open(path: path, errno: err) }
                // Missing, or a link to nothing, which lockf cannot open
                // either; the link itself still goes.
                return try Self.unlinkMarker(path)
            }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                defer { close(fd) }
                return try Self.unlinkMarker(path)
            }
            let err = errno
            close(fd)
            guard err == EWOULDBLOCK else { throw StoreError.lock(path: path, errno: err) }
            guard ContinuousClock.now < deadline else {
                throw StoreError.markerBusy(path: path, seconds: timeout)
            }
            try await Task.sleep(for: pollEvery)
        }
    }

    private static func unlinkMarker(_ path: String) throws -> Bool {
        if unlink(path) == 0 { return true }
        let err = errno
        if err == ENOENT { return false }
        throw StoreError.unlink(path: path, errno: err)
    }

    func loadConfig() throws -> Config? { try read(Config.self, from: paths.configFile) }
    func saveConfig(_ c: Config) throws { try write(c, to: paths.configFile) }

    /// One line about why decoding failed, fit for a notification.
    private static func brief(_ error: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "" : "\(p): "
        }
        switch error {
        case let .dataCorrupted(c): return path(c) + c.debugDescription
        case let .keyNotFound(k, c): return path(c) + "missing key \(k.stringValue)"
        case let .typeMismatch(t, c): return path(c) + "expected \(t)"
        case let .valueNotFound(t, c): return path(c) + "missing \(t)"
        @unknown default: return String(describing: error)
        }
    }
}

enum StoreError: Error, LocalizedError {
    case rename(from: String, to: String, errno: Int32)
    case corrupt(file: String, detail: String)
    case unlink(path: String, errno: Int32)
    case open(path: String, errno: Int32)
    case lock(path: String, errno: Int32)
    case markerBusy(path: String, seconds: TimeInterval)
    case unreadable(file: String, detail: String)
    case notRegularFile(file: String)

    var errorDescription: String? {
        switch self {
        case let .unlink(path, errno):
            return "deleting \(path) failed: \(String(cString: strerror(errno)))"
        case let .open(path, errno):
            return "opening \(path) failed: \(String(cString: strerror(errno)))"
        case let .lock(path, errno):
            return "locking \(path) failed: \(String(cString: strerror(errno)))"
        case let .markerBusy(path, seconds):
            return "\(path) was still locked after \(String(format: "%g", seconds)) s by the command a password dialog started as root"
        case let .rename(from, to, errno):
            return "rename \(from) -> \(to) failed: \(String(cString: strerror(errno)))"
        case let .corrupt(file, detail):
            return "\(file) could not be decoded (\(detail)); it was left in place"
        case let .unreadable(file, detail):
            return "\(file) could not be decoded (\(detail))"
        case let .notRegularFile(file):
            return "\(file) is not a regular file; it was not opened"
        }
    }
}
