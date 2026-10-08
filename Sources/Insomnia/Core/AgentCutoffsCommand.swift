import Darwin
import Foundation

/// `Insomnia --agent-cutoffs <seconds>`, config.json's bytes on standard input
/// `Insomnia --agent-session-cutoffs <seconds>`, state.json's bytes on standard input
///
/// One-shot modes for backstop.sh. While the app is alive the agent still
/// enforces the end floor and the thermal rule itself, for an app that has
/// stopped answering, and it must enforce the ones the app takes from the
/// same file. So it does not read config.json a second way: it opens the
/// file once, passes the bytes on standard input, and this mode decodes
/// them with the app's own decoder (`Store.decodeConfig`, which
/// `Store.loadConfig` runs) and prints `Config.agentCutoffs`, what the app
/// adopts from a file that decodes (`adoptConfigFileCutoffs`). Duplicate or
/// escaped keys, numbers the decoder rounds, and errors in any other field
/// therefore come out exactly as in the app. Nothing else runs: no AppKit,
/// no file opened, no setting written, no lock taken, no private API.
///
/// `--agent-session-cutoffs` is for when config.json is missing, cannot be
/// read or is rejected: it decodes the journal's bytes the way the app
/// reads its `sessionCutoffs` (`RuntimeState.decodeSessionCutoffs`) and
/// prints the cutoffs the app recorded for the session, so a hung app's
/// session keeps the floor and rule it had.
///
/// `<seconds>` is how long this process may live, a whole number from 1 to
/// `ResumeFrozenCommand.maxLifetimeSeconds`. As in `--resume-frozen`, it
/// arranges to end itself with SIGALRM that many seconds later before it
/// reads anything, so a caller that dies first cannot leave it waiting on
/// its input. The caller starts it with the recovery lock closed.
///
/// Prints one line:
///
///     cutoffs <endFloor> <true|false>   the bytes decode (and, for the
///                                       journal, record cutoffs); exit 0
///     none                              the journal records none (one an
///                                       older build wrote); exit 0
///     rejected                          the app's decoder rejects them, or
///                                       the journal is not a JSON object
///                                       or records a value the app does
///                                       not write; exit 65
///     unreadable                        standard input failed, or held more
///                                       than `maxInputBytes`; exit 74
///     usage                             bad arguments, nothing read; exit 64
///
/// backstop.sh enforces the printed cutoffs. On `rejected` from
/// config.json it asks for the journal's; on `none` it enforces the app's
/// defaults (`Config.agentDefaultCutoffs`); for any other outcome, the
/// strictest cutoffs (see read_cutoffs there).
///
/// The bundle declares this interface as `InsomniaAgentCutoffsVersion`
/// (`version`) in its Info.plist. backstop.sh runs the binary only when the
/// installed bundle declares the version the script speaks, so it never
/// starts an older build, which would open the menu bar app instead.
enum AgentCutoffsCommand {
    static let flag = "--agent-cutoffs"
    static let sessionFlag = "--agent-session-cutoffs"
    /// `InsomniaAgentCutoffsVersion` in Resources/Info.plist, and
    /// AGENT_CUTOFFS_VERSION in backstop.sh. 2 added `sessionFlag`.
    static let version = 2
    /// EX_USAGE, EX_DATAERR and EX_IOERR from sysexits(3).
    static let usageStatus: Int32 = 64
    static let rejectedStatus: Int32 = 65
    static let unreadableStatus: Int32 = 74
    /// config.json and state.json are a few kilobytes. Anything past this is
    /// not read on, so a huge file cannot make this process hold it all in
    /// memory.
    static let maxInputBytes = 8 << 20

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode. `endAfter` gets the lifetime once the
    /// arguments are valid, before `input` is read (`ResumeFrozenCommand.
    /// endProcess` in the binary). `input` returns nil when the bytes could
    /// not all be read.
    static func run(
        _ arguments: [String],
        input: () -> Data? = { readStandardInput(limit: maxInputBytes) },
        endAfter: (UInt32) -> Void
    ) -> ResumeFrozenCommand.Output? {
        guard let mode = arguments.first, mode == flag || mode == sessionFlag else { return nil }
        guard arguments.count == 2, let seconds = ResumeFrozenCommand.lifetime(arguments[1]) else {
            let file = mode == flag ? "config.json" : "state.json"
            FileHandle.standardError.write(Data("usage: Insomnia \(mode) <seconds 1-\(ResumeFrozenCommand.maxLifetimeSeconds)> < \(file)\n".utf8))
            return .init(lines: ["usage"], status: usageStatus)
        }
        endAfter(seconds)
        guard let data = input() else { return .init(lines: ["unreadable"], status: unreadableStatus) }
        return mode == flag ? answer(for: data) : sessionAnswer(for: data)
    }

    /// The answer for config.json's bytes.
    static func answer(for data: Data) -> ResumeFrozenCommand.Output {
        guard let config = try? Store.decodeConfig(data) else {
            return .init(lines: ["rejected"], status: rejectedStatus)
        }
        return cutoffsOutput(config.agentCutoffs)
    }

    /// The answer for state.json's bytes: the cutoffs the app recorded for
    /// the session, through the reader the app uses for them, which picks
    /// duplicate and escaped keys as the app's decoder does.
    static func sessionAnswer(for data: Data) -> ResumeFrozenCommand.Output {
        guard let journal = try? Store.makeDecoder().decode(JournaledSessionCutoffs.self, from: data) else {
            return .init(lines: ["rejected"], status: rejectedStatus)
        }
        guard let cutoffs = journal.cutoffs else { return .init(lines: ["none"], status: 0) }
        return cutoffsOutput(cutoffs)
    }

    private static func cutoffsOutput(_ cutoffs: AgentCutoffs) -> ResumeFrozenCommand.Output {
        .init(lines: ["cutoffs \(cutoffs.journalValue)"], status: 0)
    }

    /// Everything on fd 0 up to end of file, or nil when a read fails or
    /// there are more than `limit` bytes.
    static func readStandardInput(limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
            if n == 0 { return data }
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(contentsOf: buffer[0..<n])
            if data.count > limit { return nil }
        }
    }
}
