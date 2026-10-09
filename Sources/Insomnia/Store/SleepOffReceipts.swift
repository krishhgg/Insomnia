import Darwin
import Darwin.membership
import Foundation

/// A start's intent to turn sleep off. Journaled with `sleepDisabledByUs`
/// before the password dialog can run anything, and settled from the
/// receipt by whoever next holds the recovery lock: the next transaction,
/// backstop.sh or uninstall.sh. A start that finishes, or rolls back,
/// removes it itself.
struct SleepOffAttempt: Codable, Equatable, Sendable {
    /// The marker's content, and what the root command writes to the
    /// receipt (`SleepOffReceipts`).
    var nonce: String
    /// `sleepDisabledByUs` before this start: a restore an earlier session
    /// still owes. A receipt showing that this start never turned sleep off
    /// puts this value back, so it never clears an older entry.
    var owedBefore: Bool
    /// "device:inode" of the receipt when the start claimed it. The root
    /// command is given it and refuses another file; a receipt that is
    /// another file now shows nothing about this start.
    var receipt: String
    /// The nonce the receipt held when this start claimed it. The root
    /// command writes only while the receipt still holds it, and writes it
    /// beside its own nonce, so a later start's line that names it shows
    /// this start never wrote.
    var predecessor: String
    /// The session's end in whole seconds since 1970, as session.json holds
    /// it. A settlement deletes session.json only when its end matches:
    /// that session never began.
    var deadline: Int
    /// Whole seconds since 1970 from which the root command refuses
    /// (`AdministratorPrompt.answerWindow` after the dialog was shown, or
    /// the session's end if sooner). Journaled with `marker`, before the
    /// dialog. Until then a receipt that still holds `predecessor` proves
    /// nothing: the dialog may yet be answered.
    var expires: Int
    /// "device:inode" of the marker this start wrote, journaled after the
    /// marker and before the dialog. nil: no dialog was shown, so nothing
    /// ran as root for this start.
    var marker: String?
    /// true once a settlement decided this start and journaled what it
    /// owes (`sleepDisabledByUs`), before it gives the start's claim back.
    /// A settled record changes nothing to undo; it waits only for the
    /// claim to be given back, under the receipt's lock, and is then
    /// removed. So a crash or a failure after the decision is published
    /// leaves the decision itself, never a record a later start's receipt
    /// line could be read against again. Left out of the JSON when nil.
    var settled: Bool? = nil
    /// The session the settled record leaves to be resumed while it waits
    /// for its claim to be given back: this start's own once sleep was
    /// turned off for it, the one from before it that its rollback put
    /// back, the one a settlement from the receipt left in place, or none
    /// (`ResumedSession.none`). The app journals it in the same write as
    /// `settled`, before the claim goes back, so a launch while the record
    /// stays resumes that session only (`SessionManager.isResumed`) and
    /// ends any other. nil in a record settled by a build from before it,
    /// or by backstop.sh or uninstall.sh, which remove the start's own
    /// session before they publish: a launch then takes the session whose
    /// first end is `deadline` (`SessionManager.isSession`), and another
    /// session with that first end passes too. Left out of the JSON when
    /// nil. The scripts check only its shape, and a build from before it
    /// drops it when it rewrites the journal.
    var resumes: ResumedSession? = nil

    var isSettled: Bool { settled == true }
}

/// What `SleepOffAttempt.resumes` records of a session, in whole seconds
/// since 1970 as session.json keeps them: its `startedAt`, which no
/// extension changes, and its first end (`SessionMath.firstEnd`). With no
/// `startedAt`, no session.
struct ResumedSession: Codable, Equatable, Sendable {
    var startedAt: Int?
    var firstEnd: Int?

    /// No session is left to be resumed.
    static let none = ResumedSession()

    init(startedAt: Int? = nil, firstEnd: Int? = nil) {
        self.startedAt = startedAt
        self.firstEnd = firstEnd
    }

    /// `s` as session.json keeps it, or `.none` for a session with no first
    /// end or a start session.json cannot hold. Both times are checked
    /// against `SessionMath.storableTimes` first, so neither conversion
    /// can trap.
    init(_ s: Session) {
        let started = s.startedAt.timeIntervalSince1970.rounded(.down)
        guard SessionMath.storableTimes.contains(started), let first = SessionMath.firstEnd(of: s) else {
            self.init()
            return
        }
        self.init(startedAt: Int(started), firstEnd: Int(first.rounded(.down)))
    }
}

/// What a receipt shows about one start.
enum SleepOffVerdict: Equatable, Sendable {
    /// The root command for that start never ran `pmset -a disablesleep 1`,
    /// and never will (when that rests on `expires` having passed, only
    /// while the wall clock does not go back).
    case neverWrote
    /// It may have, or nothing shows otherwise; the reason, for the log.
    case mayHaveWritten(String)
    /// Not known yet, because a command for that start could still write:
    /// the receipt is locked, or its dialog can still be answered. The
    /// start stays journaled and is settled again later; the reason, for
    /// the menu and the log.
    case undecided(String)
}

/// The record the command behind the password dialog keeps as root:
/// `/private/var/db/com.kgarg.insomnia/<uid>`, one file per user, exactly
/// 82 bytes: a start's nonce, the nonce the receipt held before it, and
/// `writing` or `refused`, on one line. install.sh creates the folder and
/// the file, both root's, and only root can change either. The file is
/// 0600 with one access control entry, `user:<name> allow read`, for the
/// user its name is the uid of (`AccessEntry.installed`): only root and
/// that user can open it, so only they can hold its lock. Every Insomnia
/// folder of the user (INSOMNIA_HOME) shares it.
///
/// It is also the lock every party takes before it acts on a start (see
/// AdministratorPrompt.rootCommand). The root command opens it read-only,
/// takes an flock(2) lock on it with `lockf` before any check, and holds
/// the lock until the command and pmset exit. It writes only while the
/// receipt still holds the nonce this start claimed it from
/// (`SleepOffAttempt.predecessor`), and only before the start's
/// `SleepOffAttempt.expires`, and then first `<nonce> <predecessor>
/// writing`, flushed to the drive with F_FULLFSYNC and read back, before
/// `pmset -a disablesleep 1`. Readers open it read-only and take the same
/// exclusive lock, so they read either before the command took it or
/// after the command and its pmset exited. The lock is advisory: it
/// orders the parties that take it, and root can still change the file
/// without it.
///
/// So, under the lock, the receipt shows that a start's command never
/// turned sleep off when it holds that start's nonce with `refused`; or
/// another start's line that names the same predecessor (that start wrote
/// first, and this one's command needs the predecessor); or the
/// predecessor itself once the start has expired (or its dialog has
/// ended), when no command for it can still write. This start's
/// `writing`, a receipt that is missing, replaced, unreadable or not in
/// that shape, a folder above it that someone other than root could
/// change, or a later start's line that names another predecessor all
/// prove nothing: once the start has expired it is undone like an end,
/// and until then it stays journaled (`SleepOffVerdict.undecided`). So
/// does a receipt that stays locked or cannot be locked, whenever it is
/// read.
///
/// The release file beside it (`releaseFile`) keeps those lines from
/// being overwritten while a start is not settled: see `claimable`.
struct SleepOffReceipts: Sendable {
    /// Root's, outside every user's folders.
    static let folder = "/private/var/db/com.kgarg.insomnia"
    /// The nonce no start has: what a new receipt and release file hold.
    static let zero = "00000000-0000-0000-0000-000000000000"
    /// What install.sh writes into a new receipt.
    static let initialContent = "\(zero) \(zero) refused\n"
    /// Two nonces (36 each), two spaces, `writing` or `refused` (7) and a
    /// newline.
    static let size = 82
    /// What install.sh writes into a new release file: the new receipt's
    /// nonce, free.
    static let initialRelease = "\(zero) free\n"
    /// A nonce (36), a space, `free` or `held` (4) and a newline.
    static let releaseSize = 42

    /// This user's receipt, trusting root alone.
    static var live: SleepOffReceipts { SleepOffReceipts(folder: folder, owners: [0], user: getuid()) }

    init(folder: String, owners: Set<uid_t>, user: uid_t, standIn: [AccessEntry]? = nil, folderStandIn: [String: [AccessEntry]] = [:]) {
        self.folder = folder
        self.owners = owners
        self.user = user
        self.standIn = standIn
        self.folderStandIn = folderStandIn
    }

    /// An absolute path with no `.`, `..`, empty or symbolic link
    /// component; anything else fails every check.
    let folder: String
    /// Who may own the receipt, its folder and every folder above them.
    /// Only root in production. Tests add their own uid for a folder in
    /// their temporary directory, since they cannot create root's files.
    let owners: Set<uid_t>
    let user: uid_t
    /// nil in the app. Tests cannot make root's file, and cannot give a
    /// file of their own the entry install.sh adds without changing a real
    /// access control list, so they name entries here: the checks read
    /// them first in the receipt's list, before the entries it really has.
    let standIn: [AccessEntry]?
    /// Empty in the app. The same for the folders the checks walk, by
    /// path: entries read in front of the folder's real ones.
    let folderStandIn: [String: [AccessEntry]]

    var file: String { folder + "/" + String(user) }
    /// `<uid>.released`, beside the receipt: the user's own file, 42 bytes,
    /// a nonce and `free` or `held` on one line. install.sh creates it.
    var releaseFile: String { file + ".released" }

    struct Problem: Error, LocalizedError {
        let detail: String
        var errorDescription: String? { detail }
    }

    /// The receipt stayed locked for the whole wait.
    struct Busy: Error, LocalizedError {
        let file: String
        let seconds: TimeInterval
        var errorDescription: String? {
            "\(file) stayed locked for \(Int(seconds)) s: the command behind a password dialog may be running, or another Insomnia folder of this user, or something else running as this user, is holding it"
        }
    }

    /// flock(2) failed other than by finding the receipt locked.
    struct LockFailed: Error, LocalizedError {
        let file: String
        let errno: Int32
        var errorDescription: String? { "\(file) could not be locked: \(String(cString: strerror(errno)))" }
    }

    /// The release file shows another start's claim.
    struct Claimed: Error, LocalizedError {
        let nonce: String
        var errorDescription: String? {
            "another Insomnia start (\(nonce)) has claimed the receipt and is not settled yet. Its own Insomnia folder settles it: open Insomnia from that folder, or wait for its recovery agent, which tries every minute"
        }
    }

    /// One line of the receipt.
    struct Record: Equatable, Sendable {
        let nonce: String
        let predecessor: String
        let refused: Bool
    }

    /// The release file's line.
    enum Release: Equatable, Sendable {
        /// No start is unsettled; the next may claim the receipt while it
        /// holds this nonce.
        case free(String)
        /// The start with this nonce claimed the receipt and is not
        /// settled.
        case held(String)

        var line: String {
            switch self {
            case let .free(nonce): "\(nonce) free\n"
            case let .held(nonce): "\(nonce) held\n"
            }
        }
    }

    /// The receipt, open read-only and locked by this process (flock(2),
    /// exclusive), as the root command locks it. Released by `release()`
    /// or when it goes.
    final class Guard: @unchecked Sendable {
        let fd: Int32
        /// "device:inode" of the locked file.
        let identity: String
        private let lock = NSLock()
        private var open = true

        init(fd: Int32, identity: String) {
            self.fd = fd
            self.identity = identity
        }

        func release() {
            lock.withLock {
                guard open else { return }
                open = false
                close(fd)
            }
        }

        deinit { release() }
    }

    /// "device:inode" of the receipt, once it and every folder from it up
    /// to / pass the checks.
    func identity() throws -> String {
        FileIdentity(try check()).text
    }

    /// Opens the receipt read-only, once it passes the checks, and locks
    /// it, trying every `pollEvery` for up to `timeout`. Throws `Busy` when
    /// it stays locked, `LockFailed` when flock(2) fails another way, and
    /// `Problem` when the receipt is missing, unsafe, or not the file at
    /// its path once locked.
    func lock(timeout: TimeInterval, pollEvery: Duration = .milliseconds(50)) async throws -> Guard {
        let info = try check()
        // O_NONBLOCK: the checks found a regular file, but a FIFO put in its
        // place since must not hang the open.
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Problem(detail: "\(file): \(String(cString: strerror(errno)))") }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            close(fd)
            throw Problem(detail: "\(file) changed while it was opened")
        }
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
            let err = errno
            guard err == EWOULDBLOCK else {
                close(fd)
                throw LockFailed(file: file, errno: err)
            }
            guard ContinuousClock.now < deadline else {
                close(fd)
                throw Busy(file: file, seconds: timeout)
            }
            do {
                try await Task.sleep(for: pollEvery)
            } catch {
                close(fd)
                throw error
            }
        }
        let held = Guard(fd: fd, identity: FileIdentity(opened).text)
        // The path must still name the locked file, and pass the checks.
        guard let now = try? check(), FileIdentity(now).text == held.identity else {
            held.release()
            throw Problem(detail: "\(file) was replaced while it was locked")
        }
        return held
    }

    /// The receipt's line, through the locked descriptor.
    func record(under held: Guard) throws -> Record {
        var opened = stat()
        guard fstat(held.fd, &opened) == 0, opened.st_nlink == 1, opened.st_size == off_t(Self.size) else {
            throw Problem(detail: "\(file) is not the \(Self.size)-byte file install.sh made")
        }
        var bytes = [UInt8](repeating: 0, count: Self.size + 1)
        guard pread(held.fd, &bytes, bytes.count, 0) == Self.size else {
            throw Problem(detail: "\(file) could not be read whole")
        }
        let nonce = bytes[0..<36]
        let predecessor = bytes[37..<73]
        let word = String(decoding: bytes[74..<81], as: UTF8.self)
        guard Self.isNonce(nonce), bytes[36] == 0x20, Self.isNonce(predecessor), bytes[73] == 0x20,
              word == "writing" || word == "refused", bytes[81] == 0x0A else {
            throw Problem(detail: "\(file) does not hold two nonces and writing or refused")
        }
        return Record(nonce: String(decoding: nonce, as: UTF8.self), predecessor: String(decoding: predecessor, as: UTF8.self), refused: word == "refused")
    }

    /// What the receipt shows about `attempt`, from `lock`'s outcome
    /// (`held`, or the error it threw) at `now` (seconds since 1970).
    /// `dialogOver`: the dialog this start showed has ended on its own
    /// (osascript exited by itself, so the command it ran, if any, has
    /// exited too, and no other can start for it). Until then, or until
    /// `expires`, a command for the start may still write, so a receipt
    /// that still holds the predecessor decides nothing, and neither does
    /// a receipt this process could not lock as the file the start
    /// claimed: a command may hold that file's lock, and after `expires` it
    /// is undone like an end. A receipt that is locked, or a lock that
    /// fails, decides nothing.
    func verdict(for attempt: SleepOffAttempt, lock outcome: Result<Guard, Error>, now: Int, dialogOver: Bool = false) -> SleepOffVerdict {
        // Nothing ran as root for a start that never showed its dialog.
        guard attempt.marker != nil else { return .neverWrote }
        let over = dialogOver || now >= attempt.expires
        let until = "until \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(attempt.expires))))"
        let held: Guard
        switch outcome {
        case let .success(g):
            held = g
        case let .failure(error) where error is Busy || error is LockFailed || error is CancellationError:
            return .undecided(error.localizedDescription)
        case let .failure(error):
            return over ? .mayHaveWritten(error.localizedDescription) : .undecided("\(error.localizedDescription); a command for that start could still write \(until)")
        }
        guard held.identity == attempt.receipt else {
            let why = "\(file) is not the file it was when the start began"
            return over ? .mayHaveWritten(why) : .undecided("\(why); a command for that start could still write \(until)")
        }
        let found: Record
        do {
            found = try record(under: held)
        } catch {
            // Locked as the file the start claimed: no command for it is
            // running. One that starts before `expires` may still find its
            // predecessor at the front of a damaged line.
            return over ? .mayHaveWritten(error.localizedDescription) : .undecided("\(error.localizedDescription); a command for that start could still write \(until)")
        }
        if found.nonce == attempt.nonce {
            return found.refused ? .neverWrote : .mayHaveWritten("\(file) holds that start's writing line: its command was about to turn sleep off and may have")
        }
        if found.nonce == attempt.predecessor {
            return over ? .neverWrote : .undecided("the password dialog of that start can still be answered \(until)")
        }
        if found.predecessor == attempt.predecessor { return .neverWrote }
        return .mayHaveWritten("\(file) holds a later start's line, which no longer shows what the command for this start did")
    }

    /// Under `held`, for a start about to journal itself: the receipt's
    /// nonce, which becomes the start's predecessor, once the release file
    /// shows it free. The start then journals itself and writes
    /// `.held(nonce)` (`writeRelease`) under the same lock. Until that
    /// start gives the claim back (`release`), no start in another Insomnia
    /// folder can claim the receipt, so no root command can replace the
    /// line its settlement reads. Throws `Claimed` for another start's
    /// claim, and `Problem` for a receipt or release file that is missing,
    /// not in its shape, or a release file that names another nonce.
    func claimable(under held: Guard) throws -> String {
        let holder = try record(under: held).nonce
        switch try readRelease() {
        case let .free(free) where free == holder:
            return holder
        case let .held(other):
            throw Claimed(nonce: other)
        case .free:
            throw Problem(detail: "\(releaseFile) names a start other than the one \(file) holds. Run install.sh again")
        }
    }

    /// Under `held`: gives back `nonce`'s claim, so the release file shows
    /// the receipt's nonce free, and says whether it wrote. Writes nothing
    /// when the file shows anything but that claim (it was given back
    /// already, or never written). Throws when the file cannot be read or
    /// written.
    @discardableResult
    func release(_ nonce: String, under held: Guard) throws -> Bool {
        guard try readRelease() == .held(nonce) else { return false }
        try writeRelease(.free(try record(under: held).nonce))
        return true
    }

    /// The release file's line. It is the user's own file, so anything
    /// running as the user can rewrite it: it never shows that a start
    /// did not turn sleep off, it only keeps starts from replacing the
    /// receipt's line. A false one can only make a settlement find a later
    /// start's line, which proves nothing, or refuse every Start.
    func readRelease() throws -> Release {
        let fd = open(releaseFile, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Problem(detail: "\(releaseFile): \(String(cString: strerror(errno))). Run install.sh again") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == off_t(Self.releaseSize) else {
            throw Problem(detail: "\(releaseFile) is not the \(Self.releaseSize)-byte file install.sh made. Run install.sh again")
        }
        var bytes = [UInt8](repeating: 0, count: Self.releaseSize + 1)
        guard pread(fd, &bytes, bytes.count, 0) == Self.releaseSize else {
            throw Problem(detail: "\(releaseFile) could not be read whole")
        }
        let nonce = bytes[0..<36]
        let word = String(decoding: bytes[37..<41], as: UTF8.self)
        guard Self.isNonce(nonce), bytes[36] == 0x20, word == "free" || word == "held", bytes[41] == 0x0A else {
            throw Problem(detail: "\(releaseFile) does not hold a nonce and free or held. Run install.sh again")
        }
        let text = String(decoding: nonce, as: UTF8.self)
        return word == "free" ? .free(text) : .held(text)
    }

    /// Writes `release` over the file in place: never creates it, never
    /// through a link, fsync(2), then reads it back.
    func writeRelease(_ release: Release) throws {
        let fd = open(releaseFile, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Problem(detail: "\(releaseFile) could not be opened for writing: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == off_t(Self.releaseSize) else {
            throw Problem(detail: "\(releaseFile) is not the \(Self.releaseSize)-byte file install.sh made. Run install.sh again")
        }
        let bytes = Array(release.line.utf8)
        guard pwrite(fd, bytes, bytes.count, 0) == bytes.count, fsync(fd) == 0 else {
            throw Problem(detail: "\(releaseFile) could not be written: \(String(cString: strerror(errno)))")
        }
        guard try readRelease() == release else {
            throw Problem(detail: "\(releaseFile) did not read back as written")
        }
    }

    /// Uppercase hexadecimal digits and hyphens: what a nonce (an uppercase
    /// UUID) is made of.
    private static func isNonce(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.count == 36 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || $0 == 0x2D }
    }

    /// lstat(2) of the receipt and of each folder up to /: never through a
    /// link, each one root's (or an owner in `owners`), with no write
    /// permission for group or others. Each folder has no access control
    /// entry that allows anything. The receipt itself must also be a
    /// regular file with one link, `size` bytes and mode 0600, whose list
    /// is exactly `AccessEntry.installed(for: user)`.
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
        guard directory || info.st_mode & 0o7777 == 0o600 else {
            throw Problem(detail: "\(path) has mode \(String(info.st_mode & 0o7777, radix: 8)), not the 600 install.sh gives it")
        }
        guard let found = Self.accessEntries(path) else {
            throw Problem(detail: "the access control list of \(path) could not be read")
        }
        let real = (directory ? folderStandIn[path] ?? [] : []) + found
        if directory {
            guard !real.contains(where: \.allows) else {
                throw Problem(detail: "\(path) has an access control entry that allows changes")
            }
        } else if let why = Self.receiptAccessProblem((standIn ?? []) + real, user: user) {
            throw Problem(detail: "\(path) \(why)")
        }
        return info
    }

    /// Why `entries` are not the receipt's list as install.sh makes it, or
    /// nil. It must be exactly one entry, `AccessEntry.installed(for:
    /// user)`: it allows, names `user`, grants `read` alone, and carries no
    /// flag, so it was not inherited from the folder. Anything else lets
    /// another account open the receipt and hold its lock, or lets someone
    /// other than root change it, or is not what install.sh made.
    static func receiptAccessProblem(_ entries: [AccessEntry], user: uid_t) -> String? {
        let wanted = AccessEntry.installed(for: user)
        guard entries.count == 1, let only = entries.first else {
            return entries.isEmpty
                ? "has no access control entry, so uid \(user) cannot read it"
                : "has \(entries.count) access control entries, not the one that lets uid \(user) read it"
        }
        guard only == wanted else {
            return "has an access control entry other than the one that lets uid \(user) read it: \(only.text)"
        }
        return nil
    }

    /// `path`'s own extended access control list (never a link's target),
    /// in order; empty when it has none, nil when it cannot be read whole.
    static func accessEntries(_ path: String) -> [AccessEntry]? {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? [] : nil
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return accessEntries(of: acl)
    }

    /// The acl(3) calls `accessEntries(of:)` makes to walk a list and read
    /// each entry's flags, so a test can make either fail on a list it
    /// builds in memory, without changing a real one.
    struct ListCalls {
        var entry: (acl_t?, Int32, UnsafeMutablePointer<acl_entry_t?>) -> Int32 = { acl_get_entry($0, $1, $2) }
        var flag: (acl_flagset_t?, acl_flag_t) -> Int32 = { acl_get_flag_np($0, $1) }
    }

    /// `acl`'s entries, in order; nil when any of them cannot be read
    /// whole. acl_get_entry(3) ends the list with -1 and EINVAL; any other
    /// failure, or an answer it does not document, is not taken for the end
    /// of the list, and a flag acl_get_flag_np(3) cannot read is not taken
    /// for one that is clear: either could hide an entry or a flag that
    /// makes the list one the checks refuse.
    static func accessEntries(of acl: acl_t?, calls: ListCalls = ListCalls()) -> [AccessEntry]? {
        var entries: [AccessEntry] = []
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while true {
            errno = 0
            let got = calls.entry(acl, which, &entry)
            if got == -1 && errno == EINVAL { break }
            guard got == 0 else { return nil }
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG
            var rights: acl_permset_mask_t = 0
            var flags: acl_flagset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &rights) == 0,
                  acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0,
                  let qualifier = acl_get_qualifier(entry) else { return nil }
            defer { acl_free(qualifier) }
            var set: Set<String> = []
            for (flag, word) in AccessEntry.flagWords {
                switch calls.flag(flags, flag) {
                case 1: set.insert(word)
                case 0: break
                default: return nil
                }
            }
            var id: id_t = 0
            var type: Int32 = -1
            let principal: AccessEntry.Principal
            if mbr_uuid_to_id(qualifier.assumingMemoryBound(to: UInt8.self), &id, &type) == 0, type == ID_TYPE_UID {
                principal = .user(id)
            } else if type == ID_TYPE_GID {
                principal = .group(id)
            } else {
                principal = .unknown
            }
            entries.append(AccessEntry(
                allows: tag == ACL_EXTENDED_ALLOW,
                principal: principal,
                rights: AccessEntry.words(rights),
                flags: set
            ))
        }
        return entries
    }
}

/// One entry of an extended access control list, as `SleepOffReceipts`
/// reads it: the words are chmod(1)'s and ls(1)'s.
struct AccessEntry: Equatable, Sendable {
    enum Principal: Equatable, Sendable {
        case user(uid_t)
        case group(gid_t)
        /// A UUID the directory does not map to a user or a group.
        case unknown
    }

    /// ACL_EXTENDED_ALLOW. false for a deny entry, or a tag that is
    /// neither.
    var allows: Bool
    var principal: Principal
    /// The rights it names.
    var rights: Set<String>
    /// Its flags, `inherited` for an entry the file took from its folder.
    var flags: Set<String>

    /// The one entry install.sh adds to the receipt, with `chmod +a
    /// "user:<name> allow read"`.
    static func installed(for user: uid_t) -> AccessEntry {
        AccessEntry(allows: true, principal: .user(user), rights: ["read"], flags: [])
    }

    /// For a message, about as `ls -le` prints it.
    var text: String {
        let who = switch principal {
        case let .user(uid): "uid \(uid)"
        case let .group(gid): "gid \(gid)"
        case .unknown: "an unknown account"
        }
        let words = (rights.sorted() + flags.subtracting(["inherited"]).sorted()).joined(separator: ",")
        return "\(who)\(flags.contains("inherited") ? " inherited" : "") \(allows ? "allow" : "deny") \(words)"
    }

    /// Every right acl(3) defines, by its word. A file's `read` is the bit
    /// a folder calls `list`, `write` is `add_file`, `execute` is `search`
    /// and `append` is `add_subdirectory`.
    static let rightWords: [(right: acl_perm_t, word: String)] = [
        (ACL_READ_DATA, "read"), (ACL_WRITE_DATA, "write"), (ACL_EXECUTE, "execute"),
        (ACL_DELETE, "delete"), (ACL_APPEND_DATA, "append"), (ACL_DELETE_CHILD, "delete_child"),
        (ACL_READ_ATTRIBUTES, "readattr"), (ACL_WRITE_ATTRIBUTES, "writeattr"),
        (ACL_READ_EXTATTRIBUTES, "readextattr"), (ACL_WRITE_EXTATTRIBUTES, "writeextattr"),
        (ACL_READ_SECURITY, "readsecurity"), (ACL_WRITE_SECURITY, "writesecurity"),
        (ACL_CHANGE_OWNER, "chown"), (ACL_SYNCHRONIZE, "synchronize"),
    ]

    /// The words for the rights in `mask`, an entry's whole permission set,
    /// and the bits of any right not in `rightWords` in hex, so that a
    /// right this list does not name still makes the entry differ from
    /// `installed`.
    static func words(_ mask: acl_permset_mask_t) -> Set<String> {
        var words = Set(rightWords.filter { mask & acl_permset_mask_t($0.right.rawValue) != 0 }.map(\.word))
        let named = rightWords.reduce(acl_permset_mask_t(0)) { $0 | acl_permset_mask_t($1.right.rawValue) }
        if mask & ~named != 0 {
            words.insert("0x" + String(mask & ~named, radix: 16))
        }
        return words
    }

    /// Every entry flag acl(3) defines, by its word.
    static let flagWords: [(flag: acl_flag_t, word: String)] = [
        (ACL_ENTRY_INHERITED, "inherited"), (ACL_ENTRY_FILE_INHERIT, "file_inherit"),
        (ACL_ENTRY_DIRECTORY_INHERIT, "directory_inherit"), (ACL_ENTRY_LIMIT_INHERIT, "limit_inherit"),
        (ACL_ENTRY_ONLY_INHERIT, "only_inherit"),
    ]
}
