import Darwin
import Foundation

/// A start's intent to turn sleep off. Journaled with `sleepDisabledByUs`
/// before the password dialog can run anything, and settled by whoever
/// next holds the recovery lock once the pending-start marker is gone
/// under its own lock: the next transaction, backstop.sh or uninstall.sh.
/// A start that finishes, or rolls back, removes it itself.
struct SleepOffAttempt: Codable, Equatable, Sendable {
    /// The marker's content, and what the root command writes to the
    /// receipt (`SleepOffReceipts`).
    var nonce: String
    /// `sleepDisabledByUs` before this start: a restore an earlier session
    /// still owes. A receipt showing that this start never turned sleep off
    /// puts this value back, so it never clears an older entry.
    var owedBefore: Bool
    /// "device:inode" of the receipt when the start began. A receipt that
    /// is another file now shows nothing about this start.
    var receipt: String
    /// The session's end in whole seconds since 1970, as session.json holds
    /// it. A settlement that finds the start never turned sleep off deletes
    /// session.json only when its end matches: that session never began.
    var deadline: Int
    /// "device:inode" of the marker this start wrote, journaled after the
    /// marker and before the dialog. nil: no dialog was shown, so nothing
    /// ran as root for this start.
    var marker: String?
}

/// What a receipt shows about one start.
enum SleepOffVerdict: Equatable, Sendable {
    /// The root command for that start never ran `pmset -a disablesleep 1`,
    /// and with its marker gone it never will.
    case neverWrote
    /// It may have, or nothing shows otherwise; the reason, for the log.
    case mayHaveWritten(String)
}

/// The record the command behind the password dialog keeps as root:
/// `/private/var/db/com.kgarg.insomnia/<uid>`, one file per user, exactly
/// 45 bytes, a start's nonce and `writing` or `refused` on one line.
/// install.sh creates the folder and the file, both root's, and only root
/// can change either. The root command rewrites the file in place, and
/// fsyncs it, once its `pmset -g` read found no `SleepDisabled 1` and
/// before its last deadline check and `pmset -a disablesleep 1`:
/// `<nonce> writing`, then `<nonce> refused` if that deadline check stops
/// it (see AdministratorPrompt.rootCommand).
///
/// The marker lives in the user's folder, where any process running as
/// the user can rewrite it. Nothing running as the user can write the
/// receipt, so it can show that a start's command never turned sleep off:
/// once the marker that start wrote is gone under its lock, no command for
/// it can write again, and a receipt that holds another start's nonce, or
/// this one's with `refused`, shows that none did. Anything else proves
/// nothing, and the start is undone like an end: this start's `writing`, a
/// receipt that is missing, replaced, unreadable or not in that shape, or
/// a folder above it that someone other than root could change.
struct SleepOffReceipts: Sendable {
    /// Root's, outside every user's folders.
    static let folder = "/private/var/db/com.kgarg.insomnia"
    /// What install.sh writes into a new receipt: no start has this nonce.
    static let initialContent = "00000000-0000-0000-0000-000000000000 refused\n"
    /// A nonce (36), a space, `writing` or `refused` (7) and a newline.
    static let size = 45

    /// This user's receipt, trusting root alone.
    static var live: SleepOffReceipts { SleepOffReceipts(folder: folder, owners: [0], user: getuid()) }

    /// An absolute path with no `.`, `..`, empty or symbolic link
    /// component; anything else fails every check.
    let folder: String
    /// Who may own the receipt, its folder and every folder above them.
    /// Only root in production. Tests add their own uid for a folder in
    /// their temporary directory, since they cannot create root's files.
    let owners: Set<uid_t>
    let user: uid_t

    var file: String { folder + "/" + String(user) }

    struct Problem: Error, LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    /// "device:inode" of the receipt, once it and every folder from it up
    /// to / pass the checks. Start asks first, before it writes anything,
    /// so a missing or unsafe receipt stops it before the dialog.
    func identity() throws -> String {
        FileIdentity(try check()).text
    }

    /// What the receipt shows about `attempt`. Called only once the marker
    /// that start wrote is gone under its lock.
    func verdict(for attempt: SleepOffAttempt) -> SleepOffVerdict {
        let found: (identity: String, nonce: String, refused: Bool)
        do {
            found = try read()
        } catch {
            return .mayHaveWritten(error.localizedDescription)
        }
        guard found.identity == attempt.receipt else {
            return .mayHaveWritten("\(file) is not the file it was when the start began")
        }
        guard found.nonce == attempt.nonce else { return .neverWrote }
        return found.refused ? .neverWrote : .mayHaveWritten("\(file) shows that the command went on to turn sleep off")
    }

    /// lstat(2) of the receipt and of each folder up to /: never through a
    /// link, each one root's (or an owner in `owners`), with no write
    /// permission for group or others and no access control entry that
    /// allows anything. The receipt itself must also be a regular file with
    /// one link and `size` bytes.
    private func check() throws -> stat {
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false)
        guard folder.hasPrefix("/"), parts.count > 1, parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Problem(detail: "\(folder) is not a plain absolute path")
        }
        let info = try inspect(file, directory: false)
        guard info.st_nlink == 1 else { throw Problem(detail: "\(file) has \(info.st_nlink) links") }
        guard info.st_size == off_t(Self.size) else { throw Problem(detail: "\(file) is \(info.st_size) bytes, not \(Self.size)") }
        var dir = folder
        while true {
            _ = try inspect(dir, directory: true)
            if dir == "/" { break }
            let cut = dir.lastIndex(of: "/")!
            dir = cut == dir.startIndex ? "/" : String(dir[..<cut])
        }
        return info
    }

    private func inspect(_ path: String, directory: Bool) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Problem(detail: "\(path): \(String(cString: strerror(errno)))")
        }
        let type = info.st_mode & S_IFMT
        guard type == (directory ? S_IFDIR : S_IFREG) else {
            throw Problem(detail: "\(path) is not a \(directory ? "folder" : "regular file")")
        }
        guard owners.contains(info.st_uid) else {
            throw Problem(detail: "\(path) belongs to uid \(info.st_uid), not root")
        }
        guard info.st_mode & 0o022 == 0 else {
            throw Problem(detail: "\(path) can be changed by its group or by others")
        }
        switch Self.allowsAnything(path) {
        case false?: break
        case true?: throw Problem(detail: "\(path) has an access control entry that allows changes")
        case nil: throw Problem(detail: "the access control list of \(path) could not be read")
        }
        return info
    }

    /// Whether `path` itself (never a link's target) has an extended access
    /// control entry of the allow kind. nil when the list cannot be read.
    private static func allowsAnything(_ path: String) -> Bool? {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? false : nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0 {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { return nil }
            if tag == ACL_EXTENDED_ALLOW { return true }
        }
        return false
    }

    /// The checks, then the file's 45 bytes through a descriptor that is
    /// still the file checked.
    private func read() throws -> (identity: String, nonce: String, refused: Bool) {
        let info = try check()
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Problem(detail: "\(file): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_nlink == 1, opened.st_size == off_t(Self.size) else {
            throw Problem(detail: "\(file) changed while it was read")
        }
        var bytes = [UInt8](repeating: 0, count: Self.size + 1)
        guard pread(fd, &bytes, bytes.count, 0) == Self.size else {
            throw Problem(detail: "\(file) could not be read whole")
        }
        let nonce = bytes[0..<36]
        let word = String(decoding: bytes[37..<44], as: UTF8.self)
        guard nonce.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || $0 == 0x2D }),
              bytes[36] == 0x20, word == "writing" || word == "refused", bytes[44] == 0x0A else {
            throw Problem(detail: "\(file) does not hold a nonce and writing or refused")
        }
        return (FileIdentity(info).text, String(decoding: nonce, as: UTF8.self), word == "refused")
    }
}
