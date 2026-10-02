import Darwin
import Foundation

/// `Insomnia --resume-frozen <pid> <startedAt> <startedAtMicros> <bootSession> [...]`
///
/// One-shot mode for backstop.sh. The shell can read a process's start time
/// only to the second (`ps -o lstart`), so for the journal entries that
/// record microseconds it asks this binary to do what the app does on lid
/// open, through the same `SignalProcessControl.resume`: for each entry in
/// turn, one kernel lookup (start time to the microsecond, boot session,
/// stopped state) immediately followed by that entry's SIGCONT, before the
/// next entry is looked up. One launch covers every entry. Nothing else
/// runs: no AppKit, no journal, no lock (the caller holds the recovery
/// lock and rewrites the journal from the answer).
///
/// The arguments are groups of four fields, one group per entry. Prints
/// one line per entry, in argument order, `<pid> <word>`:
///
///     resumed       identity matched, the process was stopped, SIGCONT delivered
///     gone          no such pid, running, or a different process: nothing to do
///     failed        identity matched, SIGCONT failed; try again later
///     unobserved    the kernel would not say what the pid is; try again later
///     unverifiable  the fallthrough for an answer with no boot session to compare; never signaled
///
/// Exits 0 when every entry is `resumed` or `gone`, 1 when any is not. Wrong
/// arguments print the single line `usage` (details on stderr), check
/// nothing, and exit 64. The shell clears an entry on `resumed` and `gone`
/// and keeps it otherwise, and keeps every entry when the answer is not
/// exactly this shape.
enum ResumeFrozenCommand {
    static let flag = "--resume-frozen"
    /// EX_USAGE from sysexits(3).
    static let usageStatus: Int32 = 64

    enum Answer: String, Sendable {
        case resumed, gone, failed, unobserved, unverifiable

        /// Nothing left to do for the entry: the shell may clear it.
        var settled: Bool { self == .resumed || self == .gone }
    }

    struct Output: Equatable, Sendable {
        let lines: [String]
        let status: Int32
    }

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode.
    static func run(_ arguments: [String], control: any ProcessSignaling = SignalProcessControl()) -> Output? {
        guard arguments.first == flag else { return nil }
        guard let entries = parse(Array(arguments.dropFirst())) else {
            FileHandle.standardError.write(Data("usage: Insomnia \(flag) <pid> <startedAt> <startedAtMicros> <bootSession> [<pid> <startedAt> <startedAtMicros> <bootSession> ...]\n".utf8))
            return Output(lines: ["usage"], status: usageStatus)
        }
        var lines: [String] = []
        var settled = true
        for entry in entries {
            // One entry per call: its lookup and its signal, then the next.
            let answer = answer(of: control.resume([entry]), pid: entry.pid)
            lines.append("\(entry.pid) \(answer.rawValue)")
            if !answer.settled { settled = false }
        }
        return Output(lines: lines, status: settled ? 0 : 1)
    }

    /// The journal entries the arguments describe, in order; nil unless
    /// there is at least one group and every group of four is well formed.
    static func parse(_ fields: [String]) -> [FrozenProcess]? {
        guard !fields.isEmpty, fields.count % 4 == 0 else { return nil }
        var entries: [FrozenProcess] = []
        for start in stride(from: 0, to: fields.count, by: 4) {
            guard let entry = entry(Array(fields[start..<start + 4])) else { return nil }
            entries.append(entry)
        }
        return entries
    }

    /// One entry from its four fields; nil unless the pid is positive, the
    /// start second non-negative, the microseconds below one million and
    /// the boot session non-empty.
    static func entry(_ fields: [String]) -> FrozenProcess? {
        guard fields.count == 4,
              let pid = Int32(fields[0]), pid > 0,
              let startedAt = Int64(fields[1]), startedAt >= 0,
              let micros = Int32(fields[2]), (0..<1_000_000).contains(micros),
              !fields[3].isEmpty
        else { return nil }
        return FrozenProcess(pid: pid, identity: ProcessIdentity(startedAt: startedAt, startedAtMicros: micros, bootSession: fields[3]))
    }

    static func answer(of report: ResumeReport, pid: Int32) -> Answer {
        if report.resumed.contains(pid) { return .resumed }
        if report.gone.contains(pid) { return .gone }
        if report.failed.contains(pid) { return .failed }
        if report.unobserved.contains(pid) { return .unobserved }
        return .unverifiable
    }
}
