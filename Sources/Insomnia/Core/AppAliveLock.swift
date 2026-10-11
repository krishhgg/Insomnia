import Darwin
import Foundation

/// Proof to backstop.sh that an Insomnia process is alive: an exclusive
/// flock(2) on `Paths.appAliveFile`, taken at launch before reconcile and
/// held until the process exits. The kernel drops the lock when the holder
/// dies, so a crash or force-quit is visible to the backstop on its next
/// run: it probes the lock without waiting (`lockf -t 0`) and ends a valid
/// session when it acquires it. The file is created 0600 and never unlinked,
/// so both sides lock the same inode. O_CLOEXEC: children (pmset, osascript,
/// tmux) must not inherit the lock and keep a session alive after the app
/// is gone.
///
/// One lock per process is the point, so this is a class that owns the
/// descriptor rather than a handle factory like `RecoveryLock`.
final class AppAliveLock: @unchecked Sendable {
    let path: String
    private let mutex = NSLock()
    private var fd: Int32 = -1

    init(url: URL) { path = url.path }

    /// Whether this instance holds the lock right now.
    var isHeld: Bool { mutex.withLock { fd >= 0 } }

    /// The held descriptor, for tests that inspect its flags; -1 when not held.
    var fileDescriptor: Int32 { mutex.withLock { fd } }

    /// One attempt. False when another process (or another instance in this
    /// one) holds it; true when held, including when it was already held by
    /// this instance. Throws when the file cannot be opened or locked for
    /// any other reason.
    func tryAcquire() throws -> Bool {
        try mutex.withLock {
            if fd >= 0 { return true }
            let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard opened >= 0 else { throw RecoveryLockError.open(path: path, errno: errno) }
            if flock(opened, LOCK_EX | LOCK_NB) == 0 {
                fd = opened
                return true
            }
            let err = errno
            close(opened)
            if err == EWOULDBLOCK { return false }
            throw RecoveryLockError.lock(path: path, errno: err)
        }
    }

    /// Polls `tryAcquire` until it succeeds or `timeout` has passed, sleeping
    /// between attempts so the calling actor is never blocked. The wait is
    /// short on purpose: another holder is another Insomnia, or a backstop
    /// probe that gives the lock back within milliseconds. False when the
    /// lock is still held elsewhere at the end.
    func acquire(timeout: TimeInterval, pollEvery: Duration = .milliseconds(100)) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if try tryAcquire() { return true }
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: pollEvery)
        }
    }

    /// Lets the lock go. Releasing twice is harmless; going away releases.
    func release() {
        mutex.withLock {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    deinit { release() }
}
