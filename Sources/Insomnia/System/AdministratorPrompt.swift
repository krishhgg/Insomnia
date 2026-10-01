import Foundation

/// Why the administrator password dialog did not turn sleep off.
enum AdministratorPromptError: Error, LocalizedError, Sendable {
    /// The user dismissed the dialog.
    case cancelled
    /// No answer within the limit. osascript was sent SIGTERM, which takes
    /// the dialog down with it.
    case timedOut(seconds: TimeInterval)
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
        case let .failed(status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "the administrator password prompt failed (osascript exited \(status))" + (detail.isEmpty ? "" : ": \(detail)")
        case let .launchFailed(detail):
            return "could not launch osascript for the administrator password prompt: \(detail)"
        }
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
    /// password was wrong, pmset failed, or nothing came back in time.
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
/// it, so the runner waits for the child (and the pipe its root grandchild
/// inherits) to finish after the signal, and only then reports the
/// timeout. Nothing is rolled back while a root pmset may still be running.
struct OsascriptAdministratorPrompt: AdministratorPromptRunning {
    static let osascript = "/usr/bin/osascript"

    let executable: String
    let timeout: TimeInterval

    /// `executable` is only ever overridden by tests, with a fake that
    /// records its arguments and never shows a dialog.
    init(executable: String = Self.osascript, timeout: TimeInterval = AdministratorPrompt.timeout) {
        self.executable = executable
        self.timeout = timeout
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

    /// Owns the one decision the deadline makes, under a lock: whether the
    /// child was still running when the limit passed. SIGTERM once, never
    /// anything stronger.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var _fired = false

        init(_ p: Process) { process = p }

        func fire() {
            lock.withLock {
                guard process.isRunning else { return }
                _fired = true
                process.terminate()
            }
        }

        var fired: Bool { lock.withLock { _fired } }
    }

    private func run(_ args: [String]) async throws -> ShellResult {
        let exe = executable
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
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
                    continuation.resume(throwing: AdministratorPromptError.launchFailed(error.localizedDescription))
                    return
                }

                let deadline = Deadline(process)
                let terminator = DispatchWorkItem { deadline.fire() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminator)

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
                terminator.cancel()

                // Classified by whether this runner signalled the child: a
                // child that exits 0 after the deadline is still a timeout.
                if deadline.fired {
                    continuation.resume(throwing: AdministratorPromptError.timedOut(seconds: timeout))
                    return
                }
                continuation.resume(returning: ShellResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
