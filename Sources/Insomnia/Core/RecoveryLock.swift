import Darwin
import Foundation

/// Mutual exclusion between the app and backstop.sh over the recovery
/// journal: read, decide, change the machine, write, as one transaction.
///
/// Kernel `flock(2)` on `Paths.recoveryLock`, a file that is never unlinked
/// during ordinary runs so both sides always lock the same inode. The lock
/// belongs to the open file description, and the kernel drops it once every
/// descriptor on that description is closed, so a crash can never leave it
/// stuck. backstop.sh takes the same lock with `lockf -k` on the same path.
///
/// A privileged command a transaction runs gets one of those descriptors
/// (`RecoveryLockHandle.descriptorForChild()`), so the lock outlives this
/// process for as long as that command runs: a crash or a force quit
/// cannot free it beside a live `sudo pmset`. backstop.sh keeps it the
/// same way, in the subshell that supervises each command.
enum RecoveryLockError: Error, LocalizedError, Equatable {
    case busy(path: String, seconds: TimeInterval)
    case open(path: String, errno: Int32)
    case lock(path: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case let .busy(path, seconds):
            return "recovery lock \(path) still held by another process after \(Int(seconds)) s (backstop running?)"
        case let .open(path, errno):
            return "could not open recovery lock \(path): \(String(cString: strerror(errno)))"
        case let .lock(path, errno):
            return "could not lock \(path): \(String(cString: strerror(errno)))"
        }
    }
}

/// Owns one held lock. Releasing twice is harmless; going away releases.
final class RecoveryLockHandle: @unchecked Sendable {
    private let mutex = NSLock()
    private var fd: Int32

    fileprivate init(fd: Int32) { self.fd = fd }

    /// Closes this process's descriptor, as exiting would. No `LOCK_UN`:
    /// that would unlock the description for every descriptor on it, a
    /// child's included. A child that still holds one keeps the lock until
    /// it exits; with none, the lock is free once this returns.
    func release() {
        mutex.withLock {
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }

    /// Whether this handle still holds the lock on the file at `path`: not
    /// released, and `path` names the file its descriptor is open on. The
    /// log's rotation and its end record (`LogEndRecord`) run only then, so
    /// a handle inherited by a task that outlived its transaction, or one
    /// on another home's lock, never counts.
    func locks(path: String) -> Bool {
        mutex.withLock {
            guard fd >= 0 else { return false }
            var held = stat()
            var named = stat()
            return fstat(fd, &held) == 0 && stat(path, &named) == 0
                && held.st_dev == named.st_dev && held.st_ino == named.st_ino
        }
    }

    /// A new close-on-exec descriptor on the locked file, for a child that
    /// must keep the lock while it runs: the spawn installs it without the
    /// flag. The caller closes its copy once the child has been started.
    /// nil once released.
    func descriptorForChild() -> Int32? {
        mutex.withLock {
            guard fd >= 0 else { return nil }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            return copy >= 0 ? copy : nil
        }
    }

    /// Makes the locked file hold exactly `data`, written in place through
    /// this handle's descriptor, so the file keeps its inode and stays the
    /// lock every party takes (`Store.recordSessionEndInLock`). Only while
    /// `path` still names that same file, a regular file (lstat, so not a
    /// symlink) this user owns. The bytes the file already shares with the
    /// start of `data`, read through the same descriptor, are kept; the
    /// file is cut to them, then the rest of `data` is appended. So a step
    /// cut short leaves the old bytes untouched, or a prefix of `data` at
    /// least as long as the part they shared: never `data`'s first bytes
    /// over old bytes that differ. A record's first bytes count as its end
    /// (`Store.lockHoldsRecordCutShort`), so the end of a session written
    /// here counts from the moment the file changes, and its first bytes
    /// already there only grow. A file that cannot be read through the
    /// descriptor is left as it is. True once written and synced; the
    /// caller reads the file back. False once released or when a step
    /// fails.
    func replaceContents(with data: Data, at path: String) -> Bool {
        mutex.withLock {
            guard fd >= 0 else { return false }
            var held = stat()
            var named = stat()
            guard fstat(fd, &held) == 0, lstat(path, &named) == 0,
                  named.st_mode & S_IFMT == S_IFREG, named.st_uid == getuid(),
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else { return false }
            let size = Int(held.st_size)
            guard let kept = sharedPrefix(with: data, upTo: min(size, data.count)) else { return false }
            if size > kept, ftruncate(fd, off_t(kept)) != 0 { return false }
            let written = data.withUnsafeBytes { raw -> Bool in
                var offset = kept
                while offset < raw.count {
                    let n = pwrite(fd, raw.baseAddress! + offset, raw.count - offset, off_t(offset))
                    if n < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += n
                }
                return true
            }
            return written && fsync(fd) == 0
        }
    }

    /// How many of the file's first `count` bytes equal `data`'s, read
    /// through the held descriptor; nil when they cannot be read.
    private func sharedPrefix(with data: Data, upTo count: Int) -> Int? {
        guard count > 0 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + read, count - read, off_t(read)) }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { break }
            read += n
        }
        return zip(bytes.prefix(read), data).prefix { $0 == $1 }.count
    }

    deinit { release() }
}

struct RecoveryLock: Sendable {
    let path: String

    /// The lock the current transaction holds, set by `SessionManager` for
    /// the length of the transaction. `PmsetSleepGuard` hands it to every
    /// `sudo pmset` and runs none without it.
    @TaskLocal static var held: RecoveryLockHandle?

    init(url: URL) { path = url.path }

    /// nil when another holder (any process, or another handle in this one)
    /// has it. Never blocks.
    func tryAcquire() throws -> RecoveryLockHandle? {
        // O_CLOEXEC: no child inherits the lock by accident. One that must
        // keep it is given its own descriptor (`descriptorForChild()`).
        // Owner-only like every other file here; an older 0644 lock is
        // tightened in place, never replaced (same inode for both sides).
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, OwnerOnly.fileMode)
        guard fd >= 0 else { throw RecoveryLockError.open(path: path, errno: errno) }
        if let problem = OwnerOnly.tighten(fd: fd, path: path) { OwnerOnly.reportOnce(problem) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return RecoveryLockHandle(fd: fd) }
        let err = errno
        close(fd)
        if err == EWOULDBLOCK { return nil }
        throw RecoveryLockError.lock(path: path, errno: err)
    }

    /// Polls with `tryAcquire`, sleeping between attempts so the calling
    /// actor is never blocked. Throws `.busy` once `timeout` has passed;
    /// callers must then do nothing, never proceed unlocked.
    func acquire(timeout: TimeInterval, pollEvery: Duration = .milliseconds(50)) async throws -> RecoveryLockHandle {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if let handle = try tryAcquire() { return handle }
            guard ContinuousClock.now < deadline else {
                throw RecoveryLockError.busy(path: path, seconds: timeout)
            }
            try await Task.sleep(for: pollEvery)
        }
    }
}
