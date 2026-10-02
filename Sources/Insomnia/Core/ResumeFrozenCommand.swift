import Darwin
import Foundation

/// `Insomnia --resume-frozen <pid> <startedAt> <startedAtMicros> <bootSession>`
///
/// One-shot mode for backstop.sh. The shell can read a process's start time
/// only to the second (`ps -o lstart`), so for a journal entry that records
/// microseconds it asks this binary to do what the app does on lid open:
/// one kernel lookup (start time to the microsecond, boot session, stopped
/// state) immediately followed by the SIGCONT, for one pid, through the
/// same `SignalProcessControl.resume` the app uses. Nothing else runs: no
/// AppKit, no journal, no lock (the caller holds the recovery lock and
/// rewrites the journal from the answer).
///
/// Prints one word on stdout and exits:
///
///     resumed       0   identity matched, the process was stopped, SIGCONT delivered
///     gone          0   no such pid, running, or a different process: nothing to do
///     failed        1   identity matched, SIGCONT failed; try again later
///     unobserved    1   the kernel would not say what the pid is; try again later
///     unverifiable  1   the fallthrough for an answer with no boot session to compare; never signaled
///     usage         64  wrong arguments (details on stderr)
///
/// The shell clears the entry on `resumed` and `gone` and keeps it on every
/// other answer, including one it does not recognise.
enum ResumeFrozenCommand {
    static let flag = "--resume-frozen"
    /// EX_USAGE from sysexits(3).
    static let usageStatus: Int32 = 64

    struct Result: Equatable, Sendable {
        let word: String
        let status: Int32
    }

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode.
    static func run(_ arguments: [String], control: any ProcessSignaling = SignalProcessControl()) -> Result? {
        guard arguments.first == flag else { return nil }
        guard let entry = parse(Array(arguments.dropFirst())) else {
            FileHandle.standardError.write(Data("usage: Insomnia \(flag) <pid> <startedAt> <startedAtMicros> <bootSession>\n".utf8))
            return Result(word: "usage", status: usageStatus)
        }
        return result(of: control.resume([entry]), pid: entry.pid)
    }

    /// The journal entry the four arguments describe; nil unless all four
    /// are well formed (positive pid, non-negative start second, microseconds
    /// below one million, non-empty boot session).
    static func parse(_ fields: [String]) -> FrozenProcess? {
        guard fields.count == 4,
              let pid = Int32(fields[0]), pid > 0,
              let startedAt = Int64(fields[1]), startedAt >= 0,
              let micros = Int32(fields[2]), (0..<1_000_000).contains(micros),
              !fields[3].isEmpty
        else { return nil }
        return FrozenProcess(pid: pid, identity: ProcessIdentity(startedAt: startedAt, startedAtMicros: micros, bootSession: fields[3]))
    }

    static func result(of report: ResumeReport, pid: Int32) -> Result {
        if report.resumed.contains(pid) { return Result(word: "resumed", status: 0) }
        if report.gone.contains(pid) { return Result(word: "gone", status: 0) }
        if report.failed.contains(pid) { return Result(word: "failed", status: 1) }
        if report.unobserved.contains(pid) { return Result(word: "unobserved", status: 1) }
        return Result(word: "unverifiable", status: 1)
    }
}
