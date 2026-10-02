import Foundation

/// Why the administrator password dialog did not turn sleep off.
enum AdministratorPromptError: Error, LocalizedError, Sendable {
    /// The user dismissed the dialog.
    case cancelled
    /// No answer within the limit. osascript was sent SIGTERM, which takes
    /// the dialog down with it, and it exited.
    case timedOut(seconds: TimeInterval)
    /// SIGTERM was sent at the deadline and `grace` seconds later the
    /// prompt had still not finished: osascript is still running, or it
    /// exited and a command it started as root still holds its output.
    /// Nothing is killed. The caller keeps what it is protecting (the
    /// recovery lock, session.json, the journal entry) until
    /// `prompt.waitUntilExit()` returns, because the command may still turn
    /// sleep off.
    case stillRunning(UnfinishedPrompt, grace: TimeInterval)
    /// osascript exited non-zero for another reason: the password was wrong
    /// too many times, or pmset itself failed.
    case failed(status: Int32, stderr: String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "the administrator password prompt was cancelled"
        case let .timedOut(seconds):
            return "the administrator password prompt was not answered within \(Int(seconds)) s"
        case let .stillRunning(prompt, grace):
            if prompt.osascriptAlive {
                return "osascript (pid \(prompt.pid)) did not stop within \(Int(grace)) s of SIGTERM; it is left running, not killed"
            }
            return "osascript (pid \(prompt.pid)) exited after SIGTERM, but a command it started still holds its output; it is left running, not killed"
        case let .failed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "the administrator password prompt failed (osascript exited \(status))" + (detail.isEmpty ? "" : ": \(detail)")
        case let .launchFailed(detail):
            return "could not launch osascript for the administrator password prompt: \(detail)"
        }
    }
}

/// A prompt the runner stopped waiting for. `waitUntilExit()` returns once
/// osascript has been reaped and both its pipes have closed; nothing polls
/// the pid, so a reused pid is never mistaken for the child. Same shape as
/// the handle the sudo pmset runner hands out for a stuck `sudo pmset`.
final class UnfinishedPrompt: @unchecked Sendable, CustomStringConvertible {
    /// osascript's pid.
    let pid: pid_t
    /// Whether osascript itself was still running when the runner gave up
    /// waiting. False means it exited after SIGTERM and something it started
    /// (the root command behind the dialog) still holds its output; there is
    /// then no pid of ours to signal.
    let osascriptAlive: Bool

    private let lock = NSLock()
    private var exited = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(pid: pid_t, osascriptAlive: Bool) {
        self.pid = pid
        self.osascriptAlive = osascriptAlive
    }

    var description: String { "osascript (pid \(pid))" }

    var isRunning: Bool { lock.withLock { !exited } }

    func waitUntilExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if exited { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Called by the runner once the child has exited and its output has
    /// closed. Tests call it in place of a child.
    func markExited() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !exited else { return [] }
            exited = true
            let w = waiters
            waiters.removeAll()
            return w
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// The one privileged command Insomnia cannot run without a password:
/// `pmset -a disablesleep 1`, through the standard macOS administrator
/// dialog. The sudoers rule install.sh writes only covers turning sleep
/// back on and the battery Low Power Mode floor, so nothing running as the
/// user can keep the Mac awake unattended. Only an explicit Start by the
/// user may reach this; relaunch and reconcile read `pmset -g` instead.
protocol AdministratorPromptRunning: Sendable {
    /// Returns once `pmset -a disablesleep 1` has run as root. Throws an
    /// `AdministratorPromptError` when the dialog was cancelled, the
    /// password was wrong, pmset failed, nothing came back in time, or the
    /// prompt's process would not stop (`.stillRunning`).
    func disableSleep() async throws
}

enum AdministratorPrompt {
    /// The whole AppleScript, as one literal. The command, the privilege
    /// flag and the dialog text are fixed at compile time: no user input,
    /// configuration value, path or environment variable reaches the
    /// command that runs as root.
    static let disableSleepScript = #"do shell script "/usr/bin/pmset -a disablesleep 1" with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session.""#
    /// The user is typing a password, so the limit is generous. At the
    /// deadline osascript gets SIGTERM, and the start is rolled back.
    static let timeout: TimeInterval = 120
    /// How long after SIGTERM the runner keeps waiting before it answers
    /// the caller with `.stillRunning`. The same 3 s as KILL_GRACE_SECONDS
    /// in scripts/backstop.sh.
    static let stopGrace: TimeInterval = 3
}

/// `/usr/bin/osascript -e <script>` as a child process, not NSAppleScript
/// in-process: AppleScript is main-thread only, and a dialog waited on
/// from the main actor would freeze the menu bar, the lifecycle queue and
/// every timer for as long as the dialog is up, with no way to time out.
/// A child can be waited on from a background queue and signalled at the
/// deadline.
///
/// Only SIGTERM is ever sent. The command osascript runs after the dialog
/// is a root pmset; a SIGKILL could not reach it and would only orphan
/// it. The wait is bounded all the same: `grace` seconds after the
/// deadline the caller is answered with `.stillRunning`, carrying the pid
/// and a handle that resolves when the child and its pipes are gone, so
/// the caller can say what is running, keep its lock, and roll back after
/// the exit instead of beside a root pmset.
struct OsascriptAdministratorPrompt: AdministratorPromptRunning {
    static let osascript = "/usr/bin/osascript"

    let executable: String
    let timeout: TimeInterval
    let grace: TimeInterval

    /// `executable` is only ever overridden by tests, with a fake that
    /// records its arguments and never shows a dialog.
    init(
        executable: String = Self.osascript,
        timeout: TimeInterval = AdministratorPrompt.timeout,
        grace: TimeInterval = AdministratorPrompt.stopGrace
    ) {
        self.executable = executable
        self.timeout = timeout
        self.grace = grace
    }

    func disableSleep() async throws {
        let r = try await run(["-e", AdministratorPrompt.disableSleepScript])
        guard r.status == 0 else {
            // `User canceled. (-128)` is what the dialog's Cancel button
            // produces; everything else is a failure with its stderr.
            if r.stderr.contains("User canceled") || r.stderr.contains("(-128)") {
                throw AdministratorPromptError.cancelled
            }
            throw AdministratorPromptError.failed(status: r.status, stderr: r.stderr)
        }
    }

    /// The one place that knows whether the child exists, whether this
    /// runner signalled it, and whether the caller has already been
    /// answered, so none of the three is decided separately.
    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private let timeout: TimeInterval
        private let grace: TimeInterval
        private var process: Process?
        private var continuation: CheckedContinuation<ShellResult, Error>?
        /// SIGTERM was sent by this runner.
        private var signalled = false
        /// Set once the caller was answered with `.stillRunning`; the exit
        /// then goes to this handle.
        private var unfinished: UnfinishedPrompt?

        init(timeout: TimeInterval, grace: TimeInterval) {
            self.timeout = timeout
            self.grace = grace
        }

        func attach(_ c: CheckedContinuation<ShellResult, Error>) {
            lock.withLock { continuation = c }
        }

        func launched(_ p: Process) {
            lock.withLock { process = p }
        }

        /// Answer the caller before the child has exited (launch failure).
        func finish(_ result: Result<ShellResult, Error>) {
            let c: CheckedContinuation<ShellResult, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: result)
        }

        /// The limit passed. A child still running gets SIGTERM, once.
        /// Either way, if the exit has not answered the caller `grace`
        /// seconds from now, `graceExpired` does.
        func deadline() {
            let pending: Bool = lock.withLock {
                guard continuation != nil, let p = process else { return false }
                if p.isRunning {
                    signalled = true
                    p.terminate()
                }
                return true
            }
            guard pending else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in graceExpired() }
        }

        private func graceExpired() {
            let (c, error): (CheckedContinuation<ShellResult, Error>?, AdministratorPromptError?) = lock.withLock {
                guard let c = continuation, let p = process else { return (nil, nil) }
                let handle = UnfinishedPrompt(pid: p.processIdentifier, osascriptAlive: p.isRunning)
                unfinished = handle
                continuation = nil
                return (c, .stillRunning(handle, grace: grace))
            }
            if let c, let error { c.resume(throwing: error) }
        }

        /// The child has been reaped and both pipes have closed. Classified
        /// by what *this* runner did to the child, not by how the child
        /// happened to exit: one that traps TERM and exits 0 after the
        /// deadline is still a timeout. A caller already answered with
        /// `.stillRunning` is not answered again; its handle is told.
        func exited(_ result: ShellResult) {
            let (c, handle, outcome): (CheckedContinuation<ShellResult, Error>?, UnfinishedPrompt?, Result<ShellResult, Error>) = lock.withLock {
                defer { continuation = nil }
                let outcome: Result<ShellResult, Error> = signalled
                    ? .failure(AdministratorPromptError.timedOut(seconds: timeout))
                    : .success(result)
                return (continuation, unfinished, outcome)
            }
            handle?.markExited()
            c?.resume(with: outcome)
        }
    }

    private func run(_ args: [String]) async throws -> ShellResult {
        let exe = executable
        let state = RunState(timeout: timeout, grace: grace)
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            state.attach(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exe)
                process.arguments = args
                process.standardInput = FileHandle.nullDevice
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do {
                    try process.run()
                } catch {
                    state.finish(.failure(AdministratorPromptError.launchFailed(error.localizedDescription)))
                    return
                }
                state.launched(process)

                let deadline = DispatchWorkItem { state.deadline() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                // Each pipe is drained on its own thread and the child is
                // reaped here; none of the three waits blocks the answer
                // the grace path gives, it only delays `exited`.
                let group = DispatchGroup()
                nonisolated(unsafe) var outData = Data()
                nonisolated(unsafe) var errData = Data()
                let outHandle = out.fileHandleForReading
                let errHandle = err.fileHandleForReading
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = outHandle.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = errHandle.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()
                deadline.cancel()

                state.exited(ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
