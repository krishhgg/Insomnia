import Darwin
import Foundation

/// Everything Insomnia writes under its own directories is owner-only.
/// insomnia.log and handoffs.log name SSIDs, tmux targets and processes;
/// the journal, session and config files say what the machine is doing.
/// Files are created 0600 and the directories Insomnia owns 0700. A file or
/// directory that already exists with a looser mode (an older build, a
/// copied tree, a wide umask) is tightened when it is next opened.
/// backstop.sh does the same for what it creates with `umask 077`.
///
/// The two logs are also capped: past `maxLogBytes` the file is renamed to
/// `<name>.1`, replacing the previous `.1`, and the next line starts a new
/// file. The backstop appends with `>>`, so it simply creates that file.
enum OwnerOnly {
    static let fileMode: mode_t = 0o600
    static let directoryMode: mode_t = 0o700
    /// 1 MiB. Insomnia writes a few lines a minute at most, so this is weeks
    /// of history, and `.1` doubles it.
    static let maxLogBytes: UInt64 = 1 << 20

    /// Creates `dir` and any missing parents, then makes `dir` itself 0700.
    /// Parents are left alone: only Insomnia's own directory is tightened.
    static func createDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(directoryMode)]
        )
        tighten(path: dir.path, to: directoryMode)
    }

    /// chmod(2) to `mode` when the current mode grants anything beyond it.
    /// Best effort: a failure here must not stop the write that follows,
    /// and a file this user cannot chmod is not this user's to protect.
    static func tighten(path: String, to mode: mode_t = fileMode) {
        var st = stat()
        guard stat(path, &st) == 0 else { return }
        if (st.st_mode & 0o777) & ~mode != 0 { chmod(path, mode) }
    }

    /// Same, on an open descriptor, so the file checked is the file held.
    static func tighten(fd: Int32, to mode: mode_t = fileMode) {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return }
        if (st.st_mode & 0o777) & ~mode != 0 { fchmod(fd, mode) }
    }

    /// Appends `text` to the log at `url`: the directory is created 0700,
    /// the file 0600 (an existing file is tightened), and a file already
    /// past `maxBytes` is rotated first so the line lands in a new file.
    static func appendToLog(_ text: String, at url: URL, maxBytes: UInt64 = maxLogBytes) throws {
        try createDirectory(url.deletingLastPathComponent())
        rotateIfNeeded(url, maxBytes: maxBytes)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw OwnerOnlyError.open(path: url.path, errno: errno) }
        defer { close(fd) }
        tighten(fd: fd)
        try writeAll(Data(text.utf8), to: fd, path: url.path)
    }

    /// `<name>.1` next to the log: insomnia.log.1, handoffs.log.1.
    static func rotated(_ url: URL) -> URL { url.appendingPathExtension("1") }

    /// rename(2) over the previous `.1` once the file is larger than
    /// `maxBytes`. A rename keeps the old inode and its mode; the backstop
    /// may still have a line in flight to it, which then lands in `.1`.
    static func rotateIfNeeded(_ url: URL, maxBytes: UInt64) {
        var st = stat()
        guard stat(url.path, &st) == 0, UInt64(max(0, st.st_size)) > maxBytes else { return }
        rename(url.path, rotated(url).path)
    }

    /// Creates `url` holding `data`, mode 0600 from the first byte. Fails
    /// when the file exists: callers pass a fresh temp name and rename it.
    static func createFile(at url: URL, contents data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw OwnerOnlyError.open(path: url.path, errno: errno) }
        defer { close(fd) }
        try writeAll(data, to: fd, path: url.path)
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, base + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw OwnerOnlyError.write(path: path, errno: errno)
                }
                offset += n
            }
        }
    }
}

enum OwnerOnlyError: Error, LocalizedError {
    case open(path: String, errno: Int32)
    case write(path: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case let .open(path, errno): return "could not open \(path): \(String(cString: strerror(errno)))"
        case let .write(path, errno): return "could not write \(path): \(String(cString: strerror(errno)))"
        }
    }
}
