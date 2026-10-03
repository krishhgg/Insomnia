import Foundation

/// A child process run with a wall-clock limit and task cancellation.
///
/// Cancellation and launch are decided under one lock: a task cancelled
/// before the child is launched never reaches `Process.run`; a task
/// cancelled while the child runs has it terminated (SIGTERM, then SIGKILL
/// after a second) and the call throws `CancellationError`. Output the child
/// already produced, or keystrokes it already delivered, are not undone.
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

    func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> ShellResult {
        if let beforeLaunch { await beforeLaunch() }
        let state = LaunchState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: exe)
                    process.arguments = args
                    process.standardInput = FileHandle.nullDevice
                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    let childExit = ProcessExit(process)

                    switch state.launch(process) {
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                        return
                    case let .failed(error):
                        continuation.resume(throwing: ShellError.launchFailed(exe: exe, underlying: error.localizedDescription))
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
                    childExit.wait()
                    killer.cancel()

                    // Classified by what *this* runner did to the child, not by
                    // how the child happened to exit: a child that signals
                    // itself early is a failure, one that traps TERM and exits
                    // 0 after the deadline is still a timeout.
                    if state.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if state.timedOut {
                        continuation.resume(throwing: ShellTimeoutError.timedOut(exe: exe, seconds: timeout))
                        return
                    }
                    continuation.resume(returning: ShellResult(
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

    /// The one place that knows both whether the task was cancelled and
    /// whether the child exists, so the two cannot be decided separately.
    private final class LaunchState: @unchecked Sendable {
        enum Launch {
            case launched
            case cancelled
            case failed(Error)
        }

        private let lock = NSLock()
        private var cancelled = false
        private var _timedOut = false
        private var process: Process?

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
                _timedOut = true
                stopRunningChild()
            }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
        var timedOut: Bool { lock.withLock { _timedOut } }

        /// Caller holds `lock`.
        private func stopRunningChild() {
            guard let p = process, p.isRunning else { return }
            p.terminate()
            let box = ProcessBox(p)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
            }
        }
    }
}
