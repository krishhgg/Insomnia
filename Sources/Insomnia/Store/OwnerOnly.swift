import Darwin
import Foundation

/// Everything Insomnia writes under its own two directories is owner-only.
/// insomnia.log and handoffs.log name SSIDs, tmux targets and processes;
/// the journal, session and config files say what the machine is doing.
/// Files are created 0600 and the directories Insomnia owns 0700. A file or
/// directory that already exists with a looser mode (an older build, a
/// copied tree, a wide umask) is tightened when it is next opened.
/// Tightening only clears bits: it never adds one, so a file its owner made
/// unreadable stays that way. A symlink is left alone, together with
/// whatever it points at. So is an access control list: removing entries
/// changes what recovery can read. An allow entry can be what lets the
/// owner read a 0200 journal, and a journal recovery cannot read leaves
/// sleep disabled; a deny entry can be what keeps a session unreadable,
/// which recovery treats as ended. A chmod that fails is reported, not
/// dropped: once per path through `reportOnce` for the journal, config and
/// lock, and as an error thrown after the line is written for the two logs.
/// backstop.sh does the same for what it creates with `umask 077`, and
/// tightens what an older build left loose.
///
/// The two logs are also capped: past `maxLogBytes` the file is renamed to
/// `<name>.1`, replacing the previous `.1`, and the next line starts a new
/// file. The rename runs under flock(2) on the file, with a check that the
/// file held is still the one at the path, so two processes that both find
/// the log oversized cannot rotate it twice and rename the fresh log over
/// the retained copy. A log that is a symlink is never rotated, since the
/// rename would move the link itself; that is reported once, and the cap
/// does not hold for it. The user set up the link, so the file it points to
/// is theirs to trim. The backstop appends with `>>` and never rotates, so
/// it simply creates the fresh file. insomnia.log can hold the record of a
/// session's end (`LogEndRecord`), so the app rotates it only under the
/// recovery lock, and copies such a record forward before the rename
/// discards the old `.1` (`LogRotation`).
///
/// That same flock(2) is the one lock every writer of insomnia.log holds
/// from its look at the file's last byte to the end of its write
/// (`lockLog`): `appendToLog`, `LogEndRecord.append`, backstop.sh's log and
/// record_end_in_log, and the LaunchAgent's own line. So no line joins
/// another, a write cut short and then continued included, and no rename
/// runs while a line is in flight. A writer takes no other lock while it
/// holds this one: the recovery lock and `Log`'s lock come first.
enum OwnerOnly {
    static let fileMode: mode_t = 0o600
    static let directoryMode: mode_t = 0o700
    /// 1 MiB. Insomnia writes a few lines a minute at most, so this is weeks
    /// of history, and `.1` doubles it. Not enforced for a symlinked log;
    /// see above.
    static let maxLogBytes: UInt64 = 1 << 20
    /// How long a line waits for another writer's lock on the log
    /// (`lockLog`). backstop.sh and the LaunchAgent hold it for one line,
    /// or for one end record and its read-back.
    static let logLockTimeout: TimeInterval = 2
    /// How many times one append opens the log: once, and again each time
    /// the file it locked is no longer the one the path names.
    static let maxLogOpens = 4

    #if DEBUG
    /// Tests stand in for write(2) in `appendToLog`: given the descriptor,
    /// the bytes still to write and their count, it returns what write(2)
    /// would. So a test can cut each write short, pause between two writes
    /// of one line, or write nothing. Debug builds only; nothing reads it
    /// otherwise.
    nonisolated(unsafe) static var logWriteForTesting: ((Int32, UnsafeRawPointer, Int) -> Int)?
    #endif

    /// Creates `dir` and any missing parents, then makes `dir` itself 0700.
    /// Parents are left alone: only Insomnia's own directory is tightened.
    /// Throws when the directory cannot be created; returns the chmod
    /// failure, if any, for the caller to report.
    @discardableResult
    static func createDirectory(_ dir: URL) throws -> OwnerOnlyError? {
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(directoryMode)]
        )
        return tighten(path: dir.path, to: directoryMode)
    }

    /// chmod(2) away every permission bit outside `mode`, when there is one.
    /// No bit is added: 0644 becomes 0600 and 0444 becomes 0400. A symlink
    /// is skipped: its target may be shared with other users or
    /// programs and is not Insomnia's to change. Returns the failure, if
    /// any; the read or write that follows goes ahead either way, and the
    /// caller reports the problem.
    static func tighten(path: String, to mode: mode_t = fileMode) -> OwnerOnlyError? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return nil }
        guard (st.st_mode & 0o777) & ~mode != 0 else { return nil }
        return chmod(path, st.st_mode & 0o777 & mode) == 0 ? nil : .chmod(path: path, errno: errno)
    }

    /// Same, on an open descriptor, so the file checked is the file held.
    /// `path` names it in the error, and a `path` that is a symlink is
    /// skipped as above, since open(2) followed it to the file held.
    static func tighten(fd: Int32, path: String, to mode: mode_t = fileMode) -> OwnerOnlyError? {
        var st = stat()
        guard lstat(path, &st) != 0 || (st.st_mode & S_IFMT) != S_IFLNK else { return nil }
        guard fstat(fd, &st) == 0 else { return nil }
        guard (st.st_mode & 0o777) & ~mode != 0 else { return nil }
        return fchmod(fd, st.st_mode & 0o777 & mode) == 0 ? nil : .chmod(path: path, errno: errno)
    }

    /// Logs a chmod failure once per path per process. Store.read runs on
    /// every transaction and a file this user cannot chmod stays that way,
    /// so one line says it. Not for the logs' own paths: `appendToLog` runs
    /// under the log lock and throws instead.
    static func reportOnce(_ problem: OwnerOnlyError) {
        guard reported.insert(problem.path) else { return }
        Log.error(problem.localizedDescription)
    }

    private static let reported = PathSet()
    private static let symlinkedLogs = PathSet()
    private static let recordsNotKept = PathSet()

    private final class PathSet: @unchecked Sendable {
        private let lock = NSLock()
        private var paths = Set<String>()

        /// True the first time `path` is seen.
        func insert(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.insert(path).inserted
        }
    }

    /// Appends `text` to the log at `url`: the directory is created 0700,
    /// the file 0600 (an existing file is tightened), and a file already
    /// past `maxBytes` is rotated first so the line lands in a new file.
    /// The file opened is locked (`lockLog`, at most `lockTimeout`) before
    /// its last byte is read, and stays locked until the whole of `text`
    /// is written, every write a short write leaves to do included. Once
    /// locked, a file the path no longer names (another process rotated it
    /// meanwhile) is let go and the path opened again, up to `maxLogOpens`
    /// opens in all; after that the line goes to the file held, which the
    /// lock still keeps whole. A file whose last line was cut short
    /// (`endsMidLine`) gets a newline first, so `text` never joins it: that
    /// line may be the record of a session's end without its newline, which
    /// counts as the end only while nothing follows it on its line
    /// (`LogEndRecord`). A lock not taken in time throws `.busy`, and one
    /// that fails throws `.lock`, with nothing written. Otherwise the line is
    /// written even when a chmod or the rotation fails; the first such
    /// failure is then thrown so the caller can report it. `rotation` says
    /// whether the file may be rotated now (`LogRotation`). `beforeRotating`
    /// runs once, the first time a file opened is found past the cap, before
    /// its lock is taken; a throw from it ends the append there, with
    /// nothing rotated or written. Tests use it to rotate from outside
    /// first.
    static func appendToLog(
        _ text: String,
        at url: URL,
        maxBytes: UInt64 = maxLogBytes,
        rotation: LogRotation = .free,
        lockTimeout: TimeInterval = logLockTimeout,
        beforeRotating: () throws -> Void = {}
    ) throws {
        var problems: [OwnerOnlyError] = []
        if let problem = try createDirectory(url.deletingLastPathComponent()) { problems.append(problem) }
        // Closing the descriptor lets its lock go.
        var fd: Int32 = -1
        defer { if fd >= 0 { close(fd) } }
        var opens = 0
        var askedBeforeRotating = false
        while true {
            if fd >= 0 { close(fd) }
            fd = -1
            fd = try openForAppend(url)
            opens += 1
            // Before any rotation, so a legacy 0644 log is 0600 by the time it
            // becomes `.1`.
            if let problem = tighten(fd: fd, path: url.path) { problems.append(problem) }
            if !askedBeforeRotating, size(of: fd) > maxBytes, !rotation.isDeferred {
                askedBeforeRotating = true
                try beforeRotating()
            }
            try lockLog(fd, path: url.path, timeout: lockTimeout)
            if opens < maxLogOpens, !names(url, fd) { continue }
            if size(of: fd) > maxBytes, !rotation.isDeferred {
                switch rotateHeld(fd, at: url, maxBytes: maxBytes, keep: rotation.keep) {
                case let .keep(problem):
                    // The held file is still the log: keep writing to it.
                    if let problem { problems.append(problem) }
                case .reopen:
                    // Rotated, by this process or another: the path is a fresh file.
                    if opens < maxLogOpens { continue }
                }
            }
            break
        }
        var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
        #if DEBUG
        if let injected = logWriteForTesting { write = injected }
        #endif
        try writeAll((endsMidLine(fd) ? Data([0x0A]) : Data()) + Data(text.utf8), to: fd, path: url.path, using: write)
        if let first = problems.first { throw first }
    }

    /// Takes flock(2) on the log open on `fd`, trying again every 2 ms for
    /// at most `timeout`: the lock every writer of the log holds from its
    /// look at the last byte to the end of its write (see the type's
    /// documentation). Closing `fd` lets it go; the caller holds no other
    /// descriptor on that open file. Throws `.busy` once `timeout` has
    /// passed and `.lock` when flock(2) fails another way.
    static func lockLog(_ fd: Int32, path: String, timeout: TimeInterval) throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(max(0, timeout) * 1000))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            if err == EINTR { continue }
            guard err == EWOULDBLOCK else { throw OwnerOnlyError.lock(path: path, errno: err) }
            guard ContinuousClock.now < deadline else { throw OwnerOnlyError.busy(path: path, seconds: timeout) }
            usleep(2000)
        }
    }

    /// Whether `url` names the file open on `fd`, following a symlink as
    /// open(2) did: the same device and inode.
    private static func names(_ url: URL, _ fd: Int32) -> Bool {
        var held = stat()
        var named = stat()
        return fstat(fd, &held) == 0 && stat(url.path, &named) == 0
            && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    /// Opened for reading too, so `endsMidLine` can read the last byte; a
    /// file this user may only write to is still appended to.
    private static func openForAppend(_ url: URL) throws -> Int32 {
        var fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, fileMode)
        if fd < 0, errno == EACCES { fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, fileMode) }
        guard fd >= 0 else { throw OwnerOnlyError.open(path: url.path, errno: errno) }
        return fd
    }

    /// Whether the file open on `fd` ends in a line cut short: it is not
    /// empty and its last byte, read through `fd`, is not a newline, or
    /// that byte cannot be read. An appender then writes a newline before
    /// its own line, so a line cut short, by a write that failed partway or
    /// by a record whose newline alone is missing, stays a line of its own.
    /// backstop.sh's ends_mid_line reads the same way.
    static func endsMidLine(_ fd: Int32) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return true }
        guard st.st_size > 0 else { return false }
        var last: UInt8 = 0
        while true {
            let n = pread(fd, &last, 1, st.st_size - 1)
            if n < 0, errno == EINTR { continue }
            return n != 1 || last != 0x0A
        }
    }

    private static func size(of fd: Int32) -> UInt64 {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return 0 }
        return UInt64(max(0, st.st_size))
    }

    /// `<name>.1` next to the log: insomnia.log.1, handoffs.log.1.
    static func rotated(_ url: URL) -> URL { url.appendingPathExtension("1") }

    /// When a log past the cap is rotated.
    enum LogRotation {
        /// At once: handoffs.log.
        case free
        /// Not now: the line goes to the file as it is, past the cap, and
        /// the next append that may rotate does. insomnia.log while this
        /// process does not hold the recovery lock, since backstop.sh writes
        /// and reads back an end record there under that lock alone.
        case deferred
        /// Once `keep`, given the descriptor on the file about to be
        /// renamed, has copied into it what the rename would discard
        /// (`LogEndRecord.keepRecords`). False keeps the file as it is, past
        /// the cap, and the next append tries again. insomnia.log under the
        /// recovery lock.
        case keeping((Int32) -> Bool)

        var isDeferred: Bool {
            if case .deferred = self { return true }
            return false
        }

        var keep: ((Int32) -> Bool)? {
            if case let .keeping(keep) = self { return keep }
            return nil
        }
    }

    /// What `rotateHeld` leaves the appender to do.
    private enum Rotation {
        /// The path names a fresh file, whoever rotated: open it.
        case reopen
        /// The held file is still the log: write to it, and report the
        /// problem, if any.
        case keep(OwnerOnlyError?)
    }

    /// rename(2) the held file over the previous `.1`. The caller holds
    /// flock(2) on it (`lockLog`). Two processes can both find the log
    /// oversized; the one that locks first renames, and the other then sees
    /// that the path no longer names the file it holds and leaves the fresh
    /// log alone. The path is read with lstat(2): a symlinked log is not
    /// renamed, because rename moves the link, not its target, and the next
    /// open would start a plain file in its place. A rename keeps the inode
    /// and its mode. A writer that opened the file before the rename waits
    /// for the lock, then finds the path names another file and opens it.
    /// `keep`, when given, runs under the same flock once the file held is
    /// found to be the log and past the cap; false keeps it, reported once.
    private static func rotateHeld(_ fd: Int32, at url: URL, maxBytes: UInt64, keep: ((Int32) -> Bool)?) -> Rotation {
        var held = stat()
        var named = stat()
        guard fstat(fd, &held) == 0 else { return .keep(.rotate(path: url.path, errno: errno)) }
        if lstat(url.path, &named) != 0 {
            // Gone from the path: another process rotated it and has not
            // written yet. Nothing to rename.
            return errno == ENOENT ? .reopen : .keep(.rotate(path: url.path, errno: errno))
        }
        if (named.st_mode & S_IFMT) == S_IFLNK {
            return .keep(symlinkedLogs.insert(url.path) ? .symlinkNotRotated(path: url.path) : nil)
        }
        guard held.st_ino == named.st_ino, held.st_dev == named.st_dev else { return .reopen }
        guard UInt64(max(0, held.st_size)) > maxBytes else { return .keep(nil) }
        if let keep, !keep(fd) {
            return .keep(recordsNotKept.insert(url.path) ? .endRecordNotKept(path: url.path) : nil)
        }
        guard rename(url.path, rotated(url).path) == 0 else { return .keep(.rotate(path: url.path, errno: errno)) }
        return .reopen
    }

    /// Creates `url` holding `data`, mode 0600 from the first byte. Fails
    /// when the file exists: callers pass a fresh temp name and rename it.
    static func createFile(at url: URL, contents data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw OwnerOnlyError.open(path: url.path, errno: errno) }
        defer { close(fd) }
        try writeAll(data, to: fd, path: url.path)
    }

    /// Writes all of `data`, a write cut short followed by one for the
    /// rest, through `write`, write(2) unless a test stands in for it.
    private static func writeAll(
        _ data: Data,
        to fd: Int32,
        path: String,
        using write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    ) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = write(fd, base + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw OwnerOnlyError.write(path: path, errno: errno)
                }
                // A write that moved nothing would be tried forever.
                guard n > 0 else { throw OwnerOnlyError.write(path: path, errno: EIO) }
                offset += n
            }
        }
    }
}

enum OwnerOnlyError: Error, LocalizedError {
    case open(path: String, errno: Int32)
    case write(path: String, errno: Int32)
    case chmod(path: String, errno: Int32)
    case rotate(path: String, errno: Int32)
    case symlinkNotRotated(path: String)
    case endRecordNotKept(path: String)
    case lock(path: String, errno: Int32)
    case busy(path: String, seconds: TimeInterval)

    var path: String {
        switch self {
        case let .open(path, _), let .write(path, _), let .chmod(path, _), let .rotate(path, _), let .lock(path, _):
            return path
        case let .symlinkNotRotated(path), let .endRecordNotKept(path), let .busy(path, _):
            return path
        }
    }

    var errorDescription: String? {
        switch self {
        case let .open(path, errno): return "could not open \(path): \(String(cString: strerror(errno)))"
        case let .write(path, errno): return "could not write \(path): \(String(cString: strerror(errno)))"
        case let .chmod(path, errno): return "could not make \(path) owner-only: \(String(cString: strerror(errno)))"
        case let .rotate(path, errno): return "could not rotate \(path) to \(path).1: \(String(cString: strerror(errno)))"
        case let .symlinkNotRotated(path): return "not rotating \(path): it is a symlink, so its target can grow past the cap"
        case let .endRecordNotKept(path): return "not rotating \(path) yet: \(path).1 may hold the record of the end of the session in session.json, and it could not be read or copied forward; the next line tries again"
        case let .lock(path, errno): return "could not lock \(path) to append to it: \(String(cString: strerror(errno)))"
        case let .busy(path, seconds): return "\(path) stayed locked by another writer for \(seconds.formatted()) s; nothing was written to it"
        }
    }
}
