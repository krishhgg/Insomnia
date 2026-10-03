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
    /// them with `date -j -f`. Every date written parses with `parseDate`.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Dates are read with `parseDate`, not `.iso8601`, which on macOS 26
    /// also takes `2027-02-30`, hour 25, `GMT` and text after the zone, so
    /// backstop.sh and uninstall.sh could not read the same dates.
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "\(text) is not a date in the form 2027-01-15T08:00:00Z or 2027-01-15T10:00:00+02:00")
            }
            return date
        }
        return d
    }

    /// The one date form session.json may hold, which backstop.sh and
    /// uninstall.sh read the same way (`epoch_of`): `2027-01-15T08:00:00Z`
    /// or the same with an offset such as `+02:00` or `-05:30` in place of
    /// `Z`. Whole seconds, a date and time that exist, years 1970 to 9999,
    /// and offsets up to 23:59. Nil for anything else.
    static func parseDate(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count == 20 || b.count == 25 else { return nil }
        func at(_ i: Int, _ c: Character) -> Bool { b[i] == c.asciiValue }
        func number(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r {
                guard (0x30...0x39).contains(b[i]) else { return nil }
                n = n * 10 + Int(b[i] - 0x30)
            }
            return n
        }
        guard at(4, "-"), at(7, "-"), at(10, "T"), at(13, ":"), at(16, ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1970...9999).contains(year)
        else { return nil }
        var offset = 0
        if b.count == 20 {
            guard at(19, "Z") else { return nil }
        } else {
            guard at(19, "+") || at(19, "-"), at(22, ":"),
                  let oh = number(20..<22), let om = number(23..<25), oh <= 23, om <= 59
            else { return nil }
            offset = (oh * 3600 + om * 60) * (at(19, "-") ? -1 : 1)
        }
        // Calendar.date(from:) rolls an impossible date or time over (the
        // 30th of February becomes March 2nd), so the result must give back
        // the same fields.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fields = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let utc = calendar.date(from: fields) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: utc)
        guard back.year == year, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute, back.second == second
        else { return nil }
        return utc.addingTimeInterval(TimeInterval(-offset))
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

    /// Returns the identity of the file now at `url`, taken from the temp
    /// file before the rename (rename(2) keeps the inode), so nothing that
    /// replaces `url` afterwards can lend it its own.
    @discardableResult
    private func writeAtomically(_ data: Data, to url: URL) throws -> FileIdentity {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: [])
        var info = stat()
        guard lstat(tmp.path, &info) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.open(path: tmp.path, errno: err)
        }
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.rename(from: tmp.path, to: url.path, errno: err)
        }
        return FileIdentity(info)
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
    /// Returns the identity of the file written, for
    /// `removePendingStart(expecting:)`.
    @discardableResult
    func savePendingStart(_ nonce: String) throws -> FileIdentity {
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
    /// The lock belongs to the file, but everything else here goes by path.
    /// Once the lock is held, the path must still name the locked file, or
    /// the lock says nothing about what would be deleted: the file is let
    /// go and looked up again. With `expecting`, the identity
    /// `savePendingStart` returned, the locked file must also be the one
    /// that start wrote. Something that replaced it (or deleted it without
    /// the lock) may have done so after the root command locked the
    /// original, and that command could still be running pmset, so nothing
    /// is deleted. A path check alone cannot see that: the replacement is
    /// unlocked, and it is what the path names.
    ///
    /// Throws `.markerBusy` when the lock is still held after `timeout`,
    /// `.markerReplaced` when the file at the path is not the expected one
    /// or kept changing until `timeout`, and `.unlink` when the file cannot
    /// be deleted (an immutable flag, a deny-delete ACL, a directory in its
    /// place). unlink(2) never removes a tree. The marker then stays, and
    /// callers must treat the dialog it belongs to as still able to turn
    /// sleep off. `onLocked` is for tests: it runs each time the lock is
    /// taken, before the path is checked.
    @discardableResult
    func removePendingStart(
        timeout: TimeInterval,
        expecting written: FileIdentity? = nil,
        pollEvery: Duration = .milliseconds(50),
        onLocked: (() -> Void)? = nil
    ) async throws -> Bool {
        let path = paths.pendingStartFile.path
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            // O_NONBLOCK: a FIFO in its place must not hang the open.
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 {
                let err = errno
                guard err == ENOENT else { throw StoreError.open(path: path, errno: err) }
                // The file that start wrote went without its lock.
                if written != nil { throw StoreError.markerReplaced(path: path) }
                // Missing, or a link to nothing, which lockf cannot open
                // either; the link itself still goes.
                return try Self.unlinkMarker(path)
            }
            let busy: Bool
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                defer { close(fd) }
                onLocked?()
                let locked = FileIdentity(of: fd)
                if let written, locked != written { throw StoreError.markerReplaced(path: path) }
                // stat(2) follows a link, as open(2) and lockf do.
                if let locked, locked == FileIdentity(atPath: path) {
                    return try Self.unlinkMarker(path)
                }
                busy = false
            } else {
                let err = errno
                close(fd)
                guard err == EWOULDBLOCK else { throw StoreError.lock(path: path, errno: err) }
                busy = true
            }
            guard ContinuousClock.now < deadline else {
                if busy { throw StoreError.markerBusy(path: path, seconds: timeout) }
                throw StoreError.markerReplaced(path: path)
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

/// A file's device and inode: what flock(2) locks, whatever path led to it.
struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    /// The open file `fd`; nil if fstat(2) fails.
    init?(of fd: Int32) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        self.init(info)
    }

    /// The file `path` names now, following a link; nil if there is none.
    init?(atPath path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.init(info)
    }
}

enum StoreError: Error, LocalizedError {
    case rename(from: String, to: String, errno: Int32)
    case corrupt(file: String, detail: String)
    case unlink(path: String, errno: Int32)
    case open(path: String, errno: Int32)
    case lock(path: String, errno: Int32)
    case markerBusy(path: String, seconds: TimeInterval)
    case markerReplaced(path: String)
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
        case let .markerReplaced(path):
            return "\(path) was replaced or removed by something other than Insomnia, so its lock cannot show that the command a password dialog started as root is done with it"
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
