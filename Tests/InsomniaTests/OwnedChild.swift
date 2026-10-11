import Darwin
import Foundation

/// Why an owned child could not be started.
struct ChildError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A child started by `spawnOwnedChild`. Nothing in the test process reaps
/// it but `wait`: Foundation reaps only the Processes it started, and
/// nothing else here calls waitpid. Until `wait`, its pid stays its own
/// even after it exits (as a zombie), so `signal` reaches this child or
/// nothing, never a process that reused the pid.
final class OwnedChild {
    let pid: pid_t
    /// Started as the leader of a process group of its own (see spawnOwnedChild).
    let leadsGroup: Bool
    private(set) var status: Int32?

    init(pid: pid_t, leadsGroup: Bool) {
        self.pid = pid
        self.leadsGroup = leadsGroup
    }

    /// Whether the child has exited, checked without reaping it.
    var hasExited: Bool {
        guard status == nil else { return true }
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    /// Sends `sig` to the child. Refuses with -1 once `wait` has reaped
    /// it, since the pid may then belong to another process.
    func signal(_ sig: Int32) -> Int32 {
        guard status == nil else { return -1 }
        return kill(pid, sig)
    }

    /// Sends `sig` to every process in the group the child leads, the
    /// way launchd signals what is left of a job's process group once
    /// its main process has exited. Only for a child spawned with
    /// `ownProcessGroup`, so the group holds nothing but the child and
    /// what it started. Refuses with -1 once `wait` has reaped the
    /// child: until then its pid, the group's id, cannot name another
    /// process or group.
    func signalGroup(_ sig: Int32) -> Int32 {
        guard leadsGroup, status == nil else { return -1 }
        return killpg(pid, sig)
    }

    /// Waits for the child to exit, reaps it, and returns its wait
    /// status (-1 if waitpid failed).
    @discardableResult
    func wait() -> Int32 {
        if let status { return status }
        var raw: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &raw, 0) } while reaped == -1 && errno == EINTR
        let result = reaped == pid ? raw : -1
        status = result
        return result
    }

    /// Waits at most `seconds` for the child to exit, then reaps it and
    /// returns its wait status, as `wait` does. Returns nil, with the
    /// child neither reaped nor signalled, when it has not exited by then.
    func wait(within seconds: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while !hasExited {
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return wait()
    }

    /// A wait status in words: "exit N" or "signal N".
    static func describe(_ raw: Int32) -> String {
        if raw == -1 { return "no status (waitpid failed)" }
        return raw & 0x7f == 0 ? "exit \((raw >> 8) & 0xff)" : "signal \(raw & 0x7f)"
    }
}

/// Starts `path` with `arguments` (argv[0] first), `environment` and
/// working directory `directory`, and returns without waiting for it.
/// Standard input, output and error are the given descriptors, or
/// /dev/null for each one left nil. Like a Process, the child gets no other
/// descriptor of the test process, an empty signal mask and default signal
/// actions. With `ownProcessGroup` it leads a new process group, as launchd
/// starts a job, instead of joining the test's. Each setup call is checked:
/// one that fails throws before anything starts, with what was set up so
/// far released.
func spawnOwnedChild(
    _ path: String, _ arguments: [String], environment: [String: String], directory: URL,
    standardInput: Int32? = nil, standardOutput: Int32? = nil, standardError: Int32? = nil,
    ownProcessGroup: Bool = false
) throws -> OwnedChild {
    func check(_ rc: Int32, _ call: String) throws {
        guard rc == 0 else { throw ChildError("\(call) failed (\(rc)) for \(path); nothing started") }
    }
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
    defer { posix_spawn_file_actions_destroy(&actions) }
    for (target, given, flags) in [(Int32(0), standardInput, O_RDONLY), (1, standardOutput, O_WRONLY), (2, standardError, O_WRONLY)] {
        if let given {
            try check(posix_spawn_file_actions_adddup2(&actions, given, target), "posix_spawn_file_actions_adddup2 \(target)")
        } else {
            try check(posix_spawn_file_actions_addopen(&actions, target, "/dev/null", flags, 0), "posix_spawn_file_actions_addopen \(target)")
        }
    }
    try check(posix_spawn_file_actions_addchdir(&actions, directory.path), "posix_spawn_file_actions_addchdir")

    var attr: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attr), "posix_spawnattr_init")
    defer { posix_spawnattr_destroy(&attr) }
    var mask = sigset_t()
    try check(sigemptyset(&mask), "sigemptyset")
    var defaults = sigset_t()
    try check(sigfillset(&defaults), "sigfillset")
    try check(sigdelset(&defaults, SIGKILL), "sigdelset SIGKILL")
    try check(sigdelset(&defaults, SIGSTOP), "sigdelset SIGSTOP")
    try check(posix_spawnattr_setsigmask(&attr, &mask), "posix_spawnattr_setsigmask")
    try check(posix_spawnattr_setsigdefault(&attr, &defaults), "posix_spawnattr_setsigdefault")
    var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
    if ownProcessGroup {
        try check(posix_spawnattr_setpgroup(&attr, 0), "posix_spawnattr_setpgroup")
        flags |= POSIX_SPAWN_SETPGROUP
    }
    try check(posix_spawnattr_setflags(&attr, Int16(flags)), "posix_spawnattr_setflags")

    let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
        throw ChildError("strdup failed for \(path); nothing started")
    }

    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, path, &actions, &attr, argv, envp)
    guard spawned == 0, pid > 0 else { throw ChildError("posix_spawn \(path) failed: \(spawned)") }
    return OwnedChild(pid: pid, leadsGroup: ownProcessGroup)
}

/// `/usr/bin/lockf -k -t <wait> <file> /bin/cat`: holds `file`'s lock from
/// a process of its own, the way a running app or a concurrent backstop.sh
/// would, until stopped. lockf leads a process group of its own. cat reads
/// a pipe only the test writes to and writes to a pipe only the test
/// reads; lockf's own messages go to `errors`. lockf runs cat only once it
/// holds the lock, so a line cat prints back shows the lock held.
///
/// `stop` closes cat's input: cat ends, lockf reaps it and exits with its
/// status, and `stop` reaps lockf, so nothing outlives the holder. If lockf
/// has not exited in time, `stop` sends SIGINT to the group. lockf ignores
/// SIGINT and SIGQUIT once it has forked its command (its code calls
/// signal(SIGINT, SIG_IGN) right after the fork), so cat stops, lockf
/// reaps it and exits 70 (EX_SOFTWARE), and `stop` reaps lockf. No other
/// signal is sent, never SIGKILL. A holder that still has not exited stays
/// unsettled, and whoever made it keeps the folders it uses.
final class LockfHolder {
    let child: OwnedChild
    /// lockf's own messages (standard error).
    let errors: URL
    /// The test's end of cat's input, nonblocking; -1 once closed.
    private var input: Int32
    /// The test's end of cat's output, nonblocking; -1 once closed.
    private var output: Int32
    private var printed: [UInt8] = []
    /// lockf's wait status once `stop` has reaped it.
    private(set) var waitStatus: Int32?
    /// What went wrong, in order. Empty when the holder ended as it should.
    private(set) var problems: [String] = []

    init(file: URL, wait seconds: Int, errors: URL, environment: [String: String], directory: URL) throws {
        self.errors = errors
        guard FileManager.default.createFile(atPath: errors.path, contents: nil) else {
            throw ChildError("could not create \(errors.path) for lockf's messages")
        }
        let errorsFD = open(errors.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard errorsFD >= 0 else { throw ChildError("could not open \(errors.path): errno \(errno)") }
        var toCat: [Int32] = [-1, -1]
        var fromCat: [Int32] = [-1, -1]
        func release(_ fds: [Int32]) { for fd in fds where fd >= 0 { close(fd) } }
        guard pipe(&toCat) == 0 else {
            let err = errno
            release([errorsFD])
            throw ChildError("could not make cat's input pipe: errno \(err)")
        }
        guard pipe(&fromCat) == 0 else {
            let err = errno
            release([errorsFD] + toCat)
            throw ChildError("could not make cat's output pipe: errno \(err)")
        }
        // The test's ends: close-on-exec, so no other child gets them, and
        // nonblocking, so no write or read here waits.
        for fd in [toCat[1], fromCat[0]] {
            let flags = fcntl(fd, F_GETFL)
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                let err = errno
                release([errorsFD] + toCat + fromCat)
                throw ChildError("could not set up the test's end of a pipe to cat: errno \(err)")
            }
        }
        do {
            child = try spawnOwnedChild(
                "/usr/bin/lockf", ["/usr/bin/lockf", "-k", "-t", String(seconds), file.path, "/bin/cat"],
                environment: environment, directory: directory,
                standardInput: toCat[0], standardOutput: fromCat[1], standardError: errorsFD, ownProcessGroup: true)
        } catch {
            release([errorsFD] + toCat + fromCat)
            throw error
        }
        input = toCat[1]
        output = fromCat[0]
        // The child's ends are its own now.
        for (fd, name) in [(toCat[0], "cat's input"), (fromCat[1], "cat's output"), (errorsFD, "lockf's errors")] where close(fd) != 0 {
            problems.append("closing the test's copy of \(name): errno \(errno)")
        }
    }

    /// Writes a line to cat and returns true once cat has printed it back
    /// within `seconds`: lockf holds the lock and runs cat. False, with the
    /// reason in `problems`, when lockf exited without running cat (it did
    /// not get the lock), the time ran out, or a write or read failed.
    func held(within seconds: TimeInterval) -> Bool {
        let line = Array("held\n".utf8)
        guard input >= 0, output >= 0 else {
            problems.append("asked whether the lock is held after stop")
            return false
        }
        let written = line.withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
        guard written == line.count else {
            problems.append("writing to cat: \(written) of \(line.count) bytes, errno \(errno)")
            return false
        }
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else {
                problems.append("cat printed \(printed.count) of \(line.count) bytes back within \(seconds) s")
                return false
            }
            var ready = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, Int32(min(left, 1) * 1000) + 1)
            if polled < 0 {
                if errno == EINTR { continue }
                problems.append("poll on cat's output: errno \(errno)")
                return false
            }
            if polled == 0 { continue }
            let got = read(output, &buffer, buffer.count)
            if got > 0 {
                printed += buffer[0..<got]
                if printed == line { return true }
                if printed.count >= line.count || !line.starts(with: printed) {
                    problems.append("cat printed \(String(decoding: printed, as: UTF8.self).debugDescription)")
                    return false
                }
            } else if got == 0 {
                problems.append("cat's output ended before the line came back: lockf exited without running cat")
                return false
            } else if errno != EAGAIN && errno != EINTR {
                problems.append("reading cat's output: errno \(errno)")
                return false
            }
        }
    }

    /// Writes to cat, without reading what it prints, until neither pipe
    /// takes more for `seconds`: cat is then stuck writing to a full pipe,
    /// and closing its input no longer ends it. Returns the bytes written.
    /// For the test of `stop`'s SIGINT.
    func jam(quietFor seconds: TimeInterval) -> Int {
        let chunk = [UInt8](repeating: 0x2e, count: 4096)
        var total = 0
        var quietSince = Date()
        while input >= 0, Date().timeIntervalSince(quietSince) < seconds {
            let n = chunk.withUnsafeBytes { write(input, $0.baseAddress, $0.count) }
            if n > 0 {
                total += n
                quietSince = Date()
            } else if n < 0 && errno != EAGAIN && errno != EINTR {
                problems.append("writing to cat: errno \(errno)")
                return total
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return total
    }

    /// Ends the holder and returns lockf's exit status once it has exited
    /// and been reaped: 0 once cat has read the end of its input and lockf
    /// has reaped it, 70 when cat had to be interrupted, 128 plus the signal
    /// if lockf itself was ended by one. -1 when lockf had not exited
    /// `seconds` after its input closed nor `grace` after SIGINT: it is
    /// then unsettled (`isSettled` false). A lockf still waiting for the
    /// lock gives up on its own at its -t limit, as it does without the
    /// lock. Every call after the first returns the same.
    @discardableResult
    func stop(within seconds: TimeInterval = 15, grace: TimeInterval = 5) -> Int32 {
        if let waitStatus { return Self.code(waitStatus) }
        if input >= 0 {
            if close(input) != 0 { problems.append("closing cat's input: errno \(errno)") }
            input = -1
        }
        var raw = child.wait(within: seconds)
        if raw == nil {
            let sent = child.signalGroup(SIGINT)
            problems.append("lockf had not exited \(seconds) s after cat's input closed; SIGINT to its group: \(sent == 0 ? "sent" : "errno \(errno)")")
            raw = child.wait(within: grace)
        }
        guard let raw else {
            problems.append("lockf had not exited \(grace) s after SIGINT either: left as it is, unsettled")
            return -1
        }
        guard raw != -1 else {
            problems.append("waitpid failed for lockf \(child.pid): unsettled")
            return -1
        }
        if output >= 0 {
            if close(output) != 0 { problems.append("closing cat's output: errno \(errno)") }
            output = -1
        }
        if raw & 0x7f != 0 { problems.append("lockf ended by \(OwnedChild.describe(raw))") }
        waitStatus = raw
        return Self.code(raw)
    }

    /// Whether `stop` has reaped lockf.
    var isSettled: Bool { waitStatus != nil }

    /// lockf's messages so far, or why they could not be read.
    func errorText() -> String {
        do { return try String(contentsOf: errors, encoding: .utf8) } catch { return "(could not read \(errors.path): \(error))" }
    }

    private static func code(_ raw: Int32) -> Int32 { raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f) }
}
