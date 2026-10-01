import Foundation

/// What the runner does to a child that has to stop, at the deadline or on
/// task cancellation.
enum StopPolicy: Sendable, Equatable {
    /// SIGTERM, then SIGKILL one second later if it is still running. The
    /// default, for children that leave nothing behind when killed (tmux,
    /// docker, launchctl).
    case terminateThenKill
    /// SIGTERM only. A child still running `grace` seconds later is left
    /// alone and the call throws `CommandStillRunningError`, which carries
    /// the pid and a handle to wait for the exit. For `sudo pmset`: SIGKILL
    /// on sudo orphans a root pmset that can still change power state later,
    /// outside any transaction and after the journal has moved on, with
    /// nothing left to undo it. scripts/backstop.sh run_bounded follows the
    /// same rule.
    case terminateOnly(grace: TimeInterval)
}

/// A child under `StopPolicy.terminateOnly` that was sent SIGTERM and has not
/// exited within the grace period. It is not killed. The caller keeps
/// whatever it was protecting (the recovery lock, the journal entry) until
/// `command.waitUntilExit()` returns.
struct CommandStillRunningError: Error, LocalizedError, Sendable {
    enum Reason: Sendable, Equatable {
        case timeout(seconds: TimeInterval)
        case cancelled
    }

    let command: UnfinishedCommand
    let reason: Reason
    let grace: TimeInterval

    var errorDescription: String? {
        let why: String
        switch reason {
        case let .timeout(seconds): why = "did not finish within \(Int(seconds)) s"
        case .cancelled: why = "was cancelled"
        }
        return "\(command.description) \(why) and did not stop on SIGTERM within \(Int(grace)) s; it is left running, not killed"
    }
}

/// A launched child the runner has given up waiting for. `waitUntilExit()`
/// returns once the runner has reaped it; nothing here polls the pid, so a
/// reused pid is never mistaken for the child.
final class UnfinishedCommand: @unchecked Sendable, CustomStringConvertible {
    let exe: String
    let args: [String]
    let pid: pid_t

    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(exe: String, args: [String], pid: pid_t) {
        self.exe = exe
        self.args = args
        self.pid = pid
    }

    var description: String { "`\(([exe] + args).joined(separator: " "))` (pid \(pid))" }

    var isRunning: Bool { lock.withLock { status == nil } }

    /// The exit status once the child has exited, nil while it runs.
    var terminationStatus: Int32? { lock.withLock { status } }

    func waitUntilExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let done: Bool = lock.withLock {
                if status != nil { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }

    /// Called by the runner once the child has exited and been reaped.
    func markExited(status exitStatus: Int32) {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard status == nil else { return [] }
            status = exitStatus
            let w = waiters
            waiters.removeAll()
            return w
        }
        for waiter in waiting { waiter.resume() }
    }
}

/// A child process run with a wall-clock limit and task cancellation.
///
/// Cancellation and launch are decided under one lock: a task cancelled
/// before the child is launched never reaches `Process.run`; a task
/// cancelled while the child runs has it stopped under the `StopPolicy`
/// and the call throws `CancellationError`. Output the child already
/// produced, or keystrokes it already delivered, are not undone.
///
/// Only the direct child is signalled. A grandchild that keeps the output
/// pipe open delays completion until it exits.
struct CancellableCommand: Sendable {
    typealias Hook = @Sendable () async -> Void

    /// Awaited immediately before the launch decision. Injection point for
    /// tests that must cancel the task in the window between the caller's
    /// last cancellation check and `Process.run`.
    let beforeLaunch: Hook?

    init(beforeLaunch: Hook? = nil) {
        self.beforeLaunch = beforeLaunch
    }

    func run(_ exe: String, _ args: [String], timeout: TimeInterval, stop: StopPolicy = .terminateThenKill) async throws -> ShellResult {
        if let beforeLaunch { await beforeLaunch() }
        let state = LaunchState(exe: exe, args: args, policy: stop, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
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

                    switch state.launch(process) {
                    case .cancelled:
                        state.finish(.failure(CancellationError()))
                        return
                    case let .failed(error):
                        state.finish(.failure(ShellError.launchFailed(exe: exe, underlying: error.localizedDescription)))
                        return
                    case .launched:
                        break
                    }

                    let killer = DispatchWorkItem { state.deadline() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                    let group = DispatchGroup()
                    nonisolated(unsafe) var errData = Data()
                    let errHandle = err.fileHandleForReading
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = errHandle.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    killer.cancel()

                    state.exited(ShellResult(
                        status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ p: Process) { process = p }
    }

    /// The one place that knows whether the task was cancelled, whether the
    /// child exists, and whether the caller has already been answered, so
    /// none of the three can be decided separately.
    private final class LaunchState: @unchecked Sendable {
        enum Launch {
            case launched
            case cancelled
            case failed(Error)
        }

        private let exe: String
        private let args: [String]
        private let policy: StopPolicy
        private let timeout: TimeInterval
        private let lock = NSLock()
        private var cancelled = false
        private var timedOut = false
        private var process: Process?
        private var continuation: CheckedContinuation<ShellResult, Error>?
        /// Set once the caller has been answered early with
        /// `CommandStillRunningError`; the exit then goes to this handle.
        private var unfinished: UnfinishedCommand?

        init(exe: String, args: [String], policy: StopPolicy, timeout: TimeInterval) {
            self.exe = exe
            self.args = args
            self.policy = policy
            self.timeout = timeout
        }

        func attach(_ c: CheckedContinuation<ShellResult, Error>) {
            lock.withLock { continuation = c }
        }

        func launch(_ p: Process) -> Launch {
            lock.withLock {
                // Decided under the same lock `cancel()` takes: a cancellation
                // that wins this race means the child is never started.
                if cancelled { return .cancelled }
                do {
                    try p.run()
                    process = p
                    return .launched
                } catch {
                    return .failed(error)
                }
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                stopRunningChild()
            }
        }

        /// The deadline handler. Counts as a timeout only if it found a
        /// launched, still-running child that cancellation had not already
        /// claimed.
        func deadline() {
            lock.withLock {
                guard !cancelled, let p = process, p.isRunning else { return }
                timedOut = true
                stopRunningChild()
            }
        }

        /// Answer the caller before the child has exited (launch failures,
        /// and a child that outlived its grace).
        func finish(_ result: Result<ShellResult, Error>) {
            let c: CheckedContinuation<ShellResult, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            c?.resume(with: result)
        }

        /// The child has exited and been reaped. Classified by what *this*
        /// runner did to the child, not by how the child happened to exit:
        /// a child that signals itself early is a failure, one that traps
        /// TERM and exits 0 after the deadline is still a timeout. A caller
        /// already answered with `CommandStillRunningError` is not answered
        /// again; its handle is told instead.
        func exited(_ result: ShellResult) {
            let (c, handle, outcome): (CheckedContinuation<ShellResult, Error>?, UnfinishedCommand?, Result<ShellResult, Error>) = lock.withLock {
                defer { continuation = nil }
                let outcome: Result<ShellResult, Error>
                if cancelled {
                    outcome = .failure(CancellationError())
                } else if timedOut {
                    outcome = .failure(ShellTimeoutError.timedOut(exe: exe, seconds: timeout))
                } else {
                    outcome = .success(result)
                }
                return (continuation, unfinished, outcome)
            }
            handle?.markExited(status: result.status)
            c?.resume(with: outcome)
        }

        /// Caller holds `lock`.
        private func stopRunningChild() {
            guard let p = process, p.isRunning else { return }
            p.terminate()
            let box = ProcessBox(p)
            switch policy {
            case .terminateThenKill:
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                }
            case let .terminateOnly(grace):
                DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                    graceExpired(box.process, grace: grace)
                }
            }
        }

        /// SIGTERM was sent `grace` seconds ago. A child still running is
        /// left alone and the caller is told now, so it can keep what it
        /// is protecting until the exit instead of waiting for it here.
        private func graceExpired(_ p: Process, grace: TimeInterval) {
            let (c, error): (CheckedContinuation<ShellResult, Error>?, CommandStillRunningError?) = lock.withLock {
                guard continuation != nil, p.isRunning else { return (nil, nil) }
                let handle = UnfinishedCommand(exe: exe, args: args, pid: p.processIdentifier)
                unfinished = handle
                let reason: CommandStillRunningError.Reason = cancelled ? .cancelled : .timeout(seconds: timeout)
                defer { continuation = nil }
                return (continuation, CommandStillRunningError(command: handle, reason: reason, grace: grace))
            }
            if let c, let error { c.resume(throwing: error) }
        }
    }
}
