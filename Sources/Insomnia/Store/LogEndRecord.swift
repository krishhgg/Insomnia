import Darwin
import Foundation

/// The last place the end of a session is recorded, after the recovery lock
/// file: one line appended to insomnia.log, a file that already exists, so
/// the record needs no new file and no write in place. The line is this
/// tag, a space, the number of bytes in session.json, a space, and those
/// bytes in base64, then a newline:
///
///     insomnia-ended-session-v1 92 eyJlbmRzQXQiOiIyMDI3LTAxLTE1VDA4OjMwOjAwWiIs...
///
/// A record ends exactly the session.json whose bytes it holds, and only
/// as a whole line: a reader builds the line from session.json's current
/// bytes and looks for a line equal to it, in insomnia.log and in
/// insomnia.log.1. A write cut short, a line another write broke into, a
/// different length or other bytes match nothing. A line is ended by a
/// newline or by the end of the file, as grep(1) reads it, so a record
/// whose newline alone is missing still counts: it holds every byte. Every
/// writer of the log (`OwnerOnly.appendToLog`, `append` here, backstop.sh's
/// log and record_end_in_log, the LaunchAgent's own line) puts a newline
/// first when the file ends in a line cut short, so such a record keeps
/// its line and a record written after a line cut short starts its own. A
/// session.json with the same bytes as one that ended earlier, which takes
/// the same start and end times to the second, would read as ended too.
///
/// It is written only under the recovery lock (`RecoveryLockHandle.locks`),
/// to insomnia.log while that is a regular file (lstat, so not a symlink)
/// this user owns, through a descriptor checked to be on that same file
/// (device and inode), in one write(2), and counts only once it reads back
/// whole from the same file. backstop.sh writes and reads the same line
/// (record_end_in_log, end_recorded_in_log), with the same tag, the same
/// longest session.json and the same largest log searched.
///
/// The log is rotated by the app alone, and only under the recovery lock
/// (`OwnerOnly.LogRotation`), so no rotation runs while a record is being
/// written and read back. A rotation renames insomnia.log over
/// insomnia.log.1, which discards the old `.1`; before that it copies a
/// record still in `.1` into the file it renames (`keepRecords`), so any
/// number of rotations keep the record of a session whose session.json is
/// still there. A record is dropped only once session.json is gone or holds
/// other bytes, as that session's file was then removed. When `.1` cannot
/// be read, or session.json cannot be read and `.1` holds any record, the
/// rotation waits and is tried again with the next line.
enum LogEndRecord {
    static let tag = "insomnia-ended-session-v1"
    /// The longest session.json a record copies; the app writes a few
    /// hundred bytes.
    static let maxSessionBytes = 64 * 1024
    /// The longest record line, without its newline.
    static let maxLineBytes = tag.utf8.count + 1 + 5 + 1 + (maxSessionBytes + 2) / 3 * 4
    /// The most of one log file read when looking for a record. A larger
    /// file cannot be searched, which counts as a read that failed.
    static let maxScanBytes: Int = 64 << 20

    /// The record line for `session`'s bytes, without its newline, or nil
    /// for an empty or oversized file, which is never recorded.
    static func line(for session: Data) -> Data? {
        guard !session.isEmpty, session.count <= maxSessionBytes else { return nil }
        return Data("\(tag) \(session.count) \(session.base64EncodedString())".utf8)
    }

    enum Scan: Equatable {
        /// Missing, or not a regular file (lstat) this user owns, which is
        /// never read as a log.
        case notUsable
        /// It could not be read whole (the text says why).
        case unreadable(String)
        /// Read whole: whether a line equals the one searched for, and
        /// whether any line starts with the tag.
        case read(found: Bool, anyRecord: Bool)
    }

    /// Reads the log at `url` for a line equal to `line`.
    static func scan(_ url: URL, for line: Data?) -> Scan {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return .notUsable }
        guard st.st_size <= maxScanBytes else {
            return .unreadable("it holds \(st.st_size) bytes, more than is searched for a record")
        }
        // O_NONBLOCK and O_NOFOLLOW: what took the place of the file checked
        // above is never waited on or followed.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable("it could not be read (\(String(cString: strerror(errno))))") }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
            return .unreadable("it changed while it was opened")
        }
        return scan(fd: fd, for: line)
    }

    private static func scan(fd: Int32, for wanted: Data?) -> Scan {
        let prefix = Array((tag + " ").utf8)
        let want = wanted.map { Array($0) }
        var found = false
        var anyRecord = false
        var current: [UInt8] = []
        // Past maxLineBytes a line can hold no record; the rest of it is
        // skipped up to the next newline.
        var skipping = false
        func endOfLine() {
            if !skipping, current.starts(with: prefix) {
                anyRecord = true
                if let want, current == want { found = true }
            }
            current.removeAll(keepingCapacity: true)
            skipping = false
        }
        func add(_ bytes: UnsafeRawBufferPointer) {
            guard !skipping else { return }
            if current.count + bytes.count > maxLineBytes {
                current.removeAll(keepingCapacity: true)
                skipping = true
            } else {
                current.append(contentsOf: bytes)
            }
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        var total = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return .unreadable("it could not be read (\(String(cString: strerror(errno))))")
            }
            if n == 0 { break }
            total += n
            guard total <= maxScanBytes else { return .unreadable("it grew past \(maxScanBytes) bytes while it was read") }
            buffer.withUnsafeBytes { raw in
                var start = 0
                while start < n, let hit = memchr(raw.baseAddress! + start, 0x0A, n - start) {
                    let at = raw.baseAddress!.distance(to: UnsafeRawPointer(hit))
                    add(UnsafeRawBufferPointer(rebasing: raw[start..<at]))
                    endOfLine()
                    start = at + 1
                }
                if start < n { add(UnsafeRawBufferPointer(rebasing: raw[start..<n])) }
            }
        }
        if skipping || !current.isEmpty { endOfLine() }
        return .read(found: found, anyRecord: anyRecord)
    }

    /// Appends `line` and a newline to the log at `url` and reads it back.
    /// Only while `url` is a regular file (lstat) this user owns; it is
    /// opened without O_CREAT and without following a symlink, and the
    /// descriptor must be on the file the path names. The line goes out in
    /// one write(2) under flock(2) on the file, as a rotation by another
    /// copy of the app takes it, after a newline when the file ends in a
    /// line cut short (`OwnerOnly.endsMidLine`), so the record is a line of
    /// its own. True only when the whole write went out and the file,
    /// still the one at `url`, then holds the record as a line. The
    /// caller holds the recovery lock and `Log.withFileLock`.
    static func append(_ line: Data, to url: URL) -> Bool {
        var named = stat()
        guard lstat(url.path, &named) == 0, named.st_mode & S_IFMT == S_IFREG, named.st_uid == getuid() else { return false }
        // Opened for reading too, for its last byte; write-only when that
        // is all this user may do, and then the newline always goes first.
        var fd = open(url.path, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0, errno == EACCES { fd = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var held = stat()
        guard fstat(fd, &held) == 0, held.st_mode & S_IFMT == S_IFREG, held.st_uid == getuid(),
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { return false }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        return appendHeld(line, to: fd, at: url)
    }

    /// The write and the read-back, on a descriptor already checked to be on
    /// the log at `url` (O_APPEND).
    private static func appendHeld(_ line: Data, to fd: Int32, at url: URL) -> Bool {
        let whole = (OwnerOnly.endsMidLine(fd) ? Data([0x0A]) : Data()) + line + Data([0x0A])
        let written = whole.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard written == whole.count else { return false }
        var held = stat()
        var named = stat()
        guard fstat(fd, &held) == 0, lstat(url.path, &named) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { return false }
        return scan(url, for: line) == .read(found: true, anyRecord: true)
    }

    /// For a rotation of the log at `url`, held open (O_APPEND) on `fd`,
    /// about to be renamed over `url`.1: copies into it the record in `.1`
    /// of the session in `session` (session.json), when `.1` holds one, so
    /// the rename discards no record still in force. True when the rename
    /// may go ahead: session.json is gone, `.1` holds no record of its
    /// bytes, or the copy reads back whole. False keeps the log as it is:
    /// `.1` cannot be read, the copy fails, or session.json cannot be read
    /// and `.1` holds any record.
    static func keepRecords(in fd: Int32, log url: URL, session: URL) -> Bool {
        let previous = OwnerOnly.rotated(url)
        var st = stat()
        var bytes: Data?
        if stat(session.path, &st) != 0 {
            // Gone, or a symlink to nothing, which no reader takes for a
            // session: every record is spent.
            if errno == ENOENT { return true }
        } else if st.st_mode & S_IFMT == S_IFREG {
            // Larger than any record copies: no record can be of it.
            if st.st_size > maxSessionBytes { return true }
            bytes = try? Data(contentsOf: session)
        }
        guard let bytes else {
            switch scan(previous, for: nil) {
            case .notUsable, .read(found: _, anyRecord: false): return true
            default: return false
            }
        }
        guard let line = line(for: bytes) else { return true }
        switch scan(previous, for: line) {
        case .notUsable, .read(found: false, anyRecord: _): return true
        case .unreadable: return false
        case .read(found: true, anyRecord: _): return appendHeld(line, to: fd, at: url)
        }
    }
}
