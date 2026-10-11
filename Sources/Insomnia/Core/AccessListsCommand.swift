import Darwin
import Foundation

/// `Insomnia --access-lists <seconds> <path>...`
///
/// One-shot mode for backstop.sh and uninstall.sh: each path's own
/// extended access control list, read the way the app reads the receipt's
/// (`SleepOffReceipts.accessList`), every entry, right and flag through
/// acl(3). The two scripts used to read `ls -le`, which never prints
/// synchronize, prints delete_child and most inheritance flags only for a
/// folder, skips an entry whose rights or flags it cannot read, and stops
/// at an entry it cannot step past; no reading of its text recovers what
/// it leaves out. Both scripts run as the user, so this mode runs as the
/// user too and needs nothing the user does not already have. install.sh
/// and the root command (AdministratorPrompt) still read `ls -le`: the
/// root command must not run a binary the user can replace.
///
/// `<seconds>` is how long this process may live, as for
/// `ResumeFrozenCommand` (1 to 300), armed before any list is read. Each
/// path must be absolute. Nothing is read from standard input. Prints one
/// line per path, in order:
///
///     none              no entry at all
///     installed         exactly the one entry install.sh adds to this
///                       user's receipt (`AccessEntry.installed` for the
///                       uid this process runs as)
///     denies            entries, none of which allows anything
///     allows            an entry that allows something, and not `installed`
///     unreadable <n>    lstat(2) or acl_get_link_np(3) failed with errno n
///     incomplete        an entry, or one of its flags, could not be read
///
/// Exits 0 when every list was read whole (the first four words), 1 when
/// any was not. A missing or malformed `<seconds>`, no path, or a path that
/// is not absolute prints the single line `usage` (details on stderr),
/// reads nothing, and exits 64. A caller takes any other answer, or none,
/// as lists it does not know.
///
/// The app bundle declares this interface as `InsomniaAccessListsVersion`
/// (`version`) in its Info.plist. The scripts run the binary only when the
/// bundle declares the version they speak, so they never start an older
/// build, which would open the menu bar app instead.
enum AccessListsCommand {
    static let flag = "--access-lists"
    /// `InsomniaAccessListsVersion` in Resources/Info.plist, and
    /// ACCESS_LISTS_VERSION in backstop.sh and uninstall.sh.
    static let version = 1

    typealias Output = ResumeFrozenCommand.Output

    enum Word: Equatable, Sendable {
        case none, installed, denies, allows, incomplete
        case unreadable(Int32)

        var text: String {
            switch self {
            case .none: "none"
            case .installed: "installed"
            case .denies: "denies"
            case .allows: "allows"
            case .incomplete: "incomplete"
            case let .unreadable(err): "unreadable \(err)"
            }
        }

        /// The list was read whole.
        var whole: Bool {
            switch self {
            case .none, .installed, .denies, .allows: true
            case .incomplete, .unreadable: false
            }
        }
    }

    /// nil when `arguments` (the command line without the executable) do
    /// not ask for this mode. `endAfter` gets the lifetime once the
    /// arguments are valid, before any list is read (`endProcess` in the
    /// binary). `read` gives a path's list (`native` in the binary).
    static func run(
        _ arguments: [String],
        read: (String) -> AccessList = native,
        user: uid_t = getuid(),
        endAfter: (UInt32) -> Void
    ) -> Output? {
        guard arguments.first == flag else { return nil }
        guard arguments.count >= 3, let seconds = ResumeFrozenCommand.lifetime(arguments[1]) else { return usage() }
        let paths = arguments.dropFirst(2)
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else { return usage() }
        endAfter(seconds)
        let words = paths.map { word(read($0), user: user) }
        return Output(lines: words.map(\.text), status: words.allSatisfy(\.whole) ? 0 : 1)
    }

    private static func usage() -> Output {
        FileHandle.standardError.write(Data("usage: Insomnia \(flag) <seconds 1-\(ResumeFrozenCommand.maxLifetimeSeconds)> <absolute path>...\n".utf8))
        return Output(lines: ["usage"], status: ResumeFrozenCommand.usageStatus)
    }

    /// `path`'s own list, never a link's target's. acl_get_link_np(3)
    /// answers ENOENT both for a path with no list and for no path at all,
    /// so lstat(2) tells the two apart first.
    static func native(_ path: String) -> AccessList {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .unreadable(errno) }
        return SleepOffReceipts.accessList(path)
    }

    /// The word for `list`, for `user`'s receipt.
    static func word(_ list: AccessList, user: uid_t) -> Word {
        switch list {
        case let .unreadable(err):
            return .unreadable(err)
        case .incomplete:
            return .incomplete
        case let .entries(entries):
            if entries.isEmpty { return .none }
            if SleepOffReceipts.receiptAccessProblem(entries, user: user) == nil { return .installed }
            return entries.contains(where: \.allows) ? .allows : .denies
        }
    }
}
