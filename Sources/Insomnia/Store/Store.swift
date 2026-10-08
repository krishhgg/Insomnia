import Foundation

/// Atomic JSON persistence for the three files Insomnia keeps on disk.
/// Writes go to a temp file in the same directory and are renamed into place
/// so a crash mid-write can never leave a truncated session or state file.
/// The temp file is created mode 0600, so the published file is owner-only
/// from its first byte; a file written by an older build is tightened when
/// it is read.
struct Store: Sendable {
    let paths: Paths

    init(paths: Paths) {
        self.paths = paths
    }

    // MARK: Generic

    /// Dates are ISO 8601 (`2026-09-02T10:00:00Z`) so backstop.sh can parse
    /// them with `date -j -f`. Every date written parses with `parseDate`.
    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Dates are read with `parseDate`, not `.iso8601`, which on macOS 26
    /// also takes `2027-02-30`, hour 25, `GMT` and text after the zone, so
    /// backstop.sh and uninstall.sh could not read the same dates.
    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "\(text) is not a date in the form 2027-01-15T08:00:00Z or 2027-01-15T10:00:00+02:00")
            }
            return date
        }
        return d
    }

    /// The one date form session.json may hold, which backstop.sh and
    /// uninstall.sh read the same way (`epoch_of`): `2027-01-15T08:00:00Z`
    /// or the same with an offset such as `+02:00` or `-05:30` in place of
    /// `Z`. Whole seconds, a date and time that exist, years 1970 to 9999,
    /// and offsets up to 23:59. Nil for anything else.
    static func parseDate(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count == 20 || b.count == 25 else { return nil }
        func at(_ i: Int, _ c: Character) -> Bool { b[i] == c.asciiValue }
        func number(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r {
                guard (0x30...0x39).contains(b[i]) else { return nil }
                n = n * 10 + Int(b[i] - 0x30)
            }
            return n
        }
        guard at(4, "-"), at(7, "-"), at(10, "T"), at(13, ":"), at(16, ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1970...9999).contains(year)
        else { return nil }
        var offset = 0
        if b.count == 20 {
            guard at(19, "Z") else { return nil }
        } else {
            guard at(19, "+") || at(19, "-"), at(22, ":"),
                  let oh = number(20..<22), let om = number(23..<25), oh <= 23, om <= 59
            else { return nil }
            offset = (oh * 3600 + om * 60) * (at(19, "-") ? -1 : 1)
        }
        // Calendar.date(from:) rolls an impossible date or time over (the
        // 30th of February becomes March 2nd), so the result must give back
        // the same fields.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fields = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let utc = calendar.date(from: fields) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: utc)
        guard back.year == year, back.month == month, back.day == day,
              back.hour == hour, back.minute == minute, back.second == second
        else { return nil }
        return utc.addingTimeInterval(TimeInterval(-offset))
    }

    /// Returns nil when the file does not exist. Throws on unreadable or
    /// undecodable content.
    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let data = try readData(from: url) else { return nil }
        return try Store.makeDecoder().decode(T.self, from: data)
    }

    /// The file's bytes, or nil when it does not exist. Throws when it
    /// cannot be read or is not a regular file.
    func readData(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Only a regular file is opened. open(2) on a FIFO with no writer
        // blocks, and these reads run on the main actor under the recovery
        // lock. Data(contentsOf:) on macOS 26 refuses a FIFO with EACCES,
        // which reads as a permissions problem; this check names the real
        // cause and does not rely on that. stat(2) follows a symlink, as
        // Data(contentsOf:) does.
        var info = stat()
        if stat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw StoreError.notRegularFile(file: url.path)
        }
        if let problem = OwnerOnly.tighten(path: url.path) { OwnerOnly.reportOnce(problem) }
        return try Data(contentsOf: url)
    }

    /// Atomic write: temp file + rename(2).
    func write<T: Encodable>(_ value: T, to url: URL) throws {
        try write(data: Store.makeEncoder().encode(value), to: url)
    }

    private func write(data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if let problem = try OwnerOnly.createDirectory(dir) { OwnerOnly.reportOnce(problem) }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try OwnerOnly.createFile(at: tmp, contents: data)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw StoreError.rename(from: tmp.path, to: url.path, errno: err)
        }
    }

    /// Removes the file; a missing file is not an error.
    func remove(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Typed helpers

    /// Throws StoreError.unreadable, with a one-line reason, when the file
    /// does not decode.
    func loadSession() throws -> Session? {
        do {
            return try read(Session.self, from: paths.sessionFile)
        } catch let error as DecodingError {
            throw StoreError.unreadable(file: paths.sessionFile.path, detail: Self.brief(error))
        }
    }
    func saveSession(_ s: Session) throws { try write(s, to: paths.sessionFile) }
    /// Puts back session.json's exact bytes, as read before a write that is
    /// being undone: every record of a session's end matches exact bytes,
    /// which encoding the decoded session again need not give.
    func restoreSessionFile(_ data: Data) throws { try write(data: data, to: paths.sessionFile) }
    /// Removes session.json, then the records of its end, which mean
    /// something only while the file they copy is there. A record that
    /// cannot be removed is left and logged: it matches no later
    /// session.json, but it is still a copy of the session's times. The
    /// record in the recovery lock file is emptied in place, through the
    /// lock this transaction holds; one that cannot be is left and logged
    /// too. It ends nothing while no session.json is there, and the next
    /// start (once it has written its session.json) or recovery agent run
    /// empties it.
    func deleteSession() throws {
        try remove(at: paths.sessionFile)
        for record in [paths.endedSessionFile] + sessionEndRecordsAside() {
            do {
                try remove(at: record)
            } catch {
                Log.error("could not remove \(record.path) (\(error.localizedDescription)); it matches no session.json, so it ends nothing, but it stays until removed by hand")
            }
        }
        if !clearLockEndRecord() {
            Log.error("could not empty \(paths.recoveryLock.path) of the record of a session's end; it matches no session.json, so it ends nothing, and the next start or recovery agent run empties it")
        }
    }

    /// Whether session.json is a session already ended: ended-session.json
    /// holds its exact bytes (`recordSessionEnd`, or backstop.sh's
    /// record_end). False when either file is missing, unreadable, or not
    /// a regular file; the 1 Hz tick calls this, so neither is ever opened
    /// unless it is one.
    func sessionEndIsRecorded() -> Bool {
        guard let recorded = try? readData(from: paths.endedSessionFile),
              let current = try? readData(from: paths.sessionFile) else { return false }
        return recorded == current
    }

    /// For an end that could not remove session.json: copies its bytes to
    /// ended-session.json, so this app after a relaunch and backstop.sh treat
    /// the session as over. True only when the record now matches the file.
    func recordSessionEnd() -> Bool {
        if sessionEndIsRecorded() { return true }
        guard let current = try? readData(from: paths.sessionFile) else { return false }
        do {
            try write(data: current, to: paths.endedSessionFile)
        } catch {
            return false
        }
        return sessionEndIsRecorded()
    }

    /// The records written aside (Paths.endedSessionAsidePrefix) in
    /// `Paths.endedSessionAsideFolders`: regular files, not symlinks, owned
    /// by this user, with exactly that name shape, folder by folder in
    /// name order. The log folder is searched only while it is a directory,
    /// not a symlink, owned by this user. Nothing else is ever opened or
    /// removed as one.
    func sessionEndRecordsAside() -> [URL] {
        recordAsideFolders().flatMap { folder -> [URL] in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
            return names.filter(Paths.isEndedSessionAsideName).sorted().compactMap { name in
                let url = folder.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return nil }
                return url
            }
        }
    }

    /// `Paths.endedSessionAsideFolders` as they may be used now: the log
    /// folder only while it is a directory (lstat, so not a symlink) this
    /// user owns.
    private func recordAsideFolders() -> [URL] {
        paths.endedSessionAsideFolders.filter { folder in
            guard folder != paths.appSupport else { return true }
            var st = stat()
            return lstat(folder.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid()
        }
    }

    /// The record aside that holds session.json's exact bytes, if one does:
    /// that session is over, as with ended-session.json.
    func sessionEndRecordAside() -> URL? {
        let records = sessionEndRecordsAside()
        guard !records.isEmpty, let current = try? readData(from: paths.sessionFile) else { return nil }
        return records.first { (try? readData(from: $0)) == current }
    }

    /// For an end that could not remove session.json or write
    /// ended-session.json or the journal: copies its bytes to a new file,
    /// created exclusively under a random name, beside them, or in the log
    /// folder when their folder takes no new file. A record aside that
    /// already matches, in either folder, is used again. Returns the
    /// record, only once it reads back identical to the file.
    func recordSessionEndAside() -> URL? {
        if let existing = sessionEndRecordAside() { return existing }
        guard let current = try? readData(from: paths.sessionFile) else { return nil }
        _ = try? OwnerOnly.createDirectory(paths.logs)
        for folder in recordAsideFolders() {
            if let record = createRecordAside(in: folder, contents: current) { return record }
        }
        return nil
    }

    /// One record aside in `folder`, or nil when none could be created
    /// there and read back identical to `contents`.
    private func createRecordAside(in folder: URL, contents: Data) -> URL? {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for _ in 0..<8 {
            let suffix = String((0..<8).map { _ in letters.randomElement()! })
            let url = folder.appendingPathComponent(Paths.endedSessionAsidePrefix + suffix)
            do {
                try OwnerOnly.createFile(at: url, contents: contents)
            } catch OwnerOnlyError.open(_, EEXIST) {
                continue
            } catch OwnerOnlyError.write {
                // Created here, then a write failed: the partial copy goes.
                try? FileManager.default.removeItem(at: url)
                return nil
            } catch {
                return nil
            }
            if (try? readData(from: url)) == contents { return url }
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return nil
    }

    /// Writes session.json's bytes back over it, unchanged: a new file
    /// renamed into its place, as every write here. True only when that
    /// worked and the file then reads back as the same bytes. Reconcile
    /// runs it before it resumes a session: a session.json that cannot be
    /// replaced is one an end could not remove either, so an end of it may
    /// have gone unrecorded.
    func rewriteSessionFile() -> Bool {
        guard let current = try? readData(from: paths.sessionFile) else { return false }
        do {
            try write(data: current, to: paths.sessionFile)
        } catch {
            return false
        }
        return (try? readData(from: paths.sessionFile)) == current
    }

    /// session.json's bytes in base64, the form `RuntimeState.endedSession`
    /// records them in (backstop.sh's session_base64 prints the same), or
    /// nil when the file is missing, unreadable or not a regular file.
    func sessionEndMarker() -> String? {
        (try? readData(from: paths.sessionFile))?.base64EncodedString()
    }

    /// Whether `journal` records the end of the session in session.json:
    /// its endedSession holds that file's bytes. The record written when
    /// ended-session.json could not be (SessionManager's
    /// `journalSessionEnd`, or backstop.sh's record_end_in_journal).
    func sessionEndIsJournaled(in journal: RuntimeState) -> Bool {
        guard let recorded = journal.endedSession, let current = sessionEndMarker() else { return false }
        return recorded == current
    }

    // MARK: The end record in the recovery lock file

    /// The last place the end of a session is recorded, for when
    /// ended-session.json, the journal and both folders of records aside
    /// refuse it: the recovery lock file, which exists already, so the
    /// record needs no new file. It then holds this tag, a space,
    /// session.json's bytes in base64 (`sessionEndMarker`), a newline, and
    /// nothing else. It is written in place (`RecoveryLockHandle
    /// .replaceContents`), so it keeps its inode and stays the lock, and it
    /// is never unlinked. backstop.sh reads and writes the same record
    /// (read_lock_record, record_end_in_lock) and uninstall.sh empties it.
    static let lockEndRecordTag = "ended-session-v1"
    /// A larger lock file holds no whole record.
    static let lockEndRecordMaxBytes = 1 << 20

    #if DEBUG
    /// Tests set a lower limit on the record this app writes in the lock
    /// file, 0 for a lock file that refuses it (a stand-in for a full disk),
    /// as `PatchedBackstop.refuseLockRecord` does for the agent. Debug
    /// builds only; nothing reads it otherwise.
    nonisolated(unsafe) static var lockRecordWriteLimitForTesting: Int?
    #endif

    private static var lockRecordWriteLimit: Int {
        #if DEBUG
        return lockRecordWriteLimitForTesting ?? lockEndRecordMaxBytes
        #else
        return lockEndRecordMaxBytes
        #endif
    }

    /// What the recovery lock file says about the end of a session.
    enum LockEndRecord: Equatable {
        /// Nothing: the file is empty or missing, or not a regular file
        /// (lstat, so not a symlink) this user owns, which is never read or
        /// written as a record.
        case none
        /// A whole record: the end of the session.json whose bytes this
        /// base64 holds.
        case record(String)
        /// Read, and not one whole record (the text says why): a write cut
        /// short, other bytes, or more bytes than any record. It ends no
        /// session. No writer counts a record before it reads it back
        /// whole, so a write cut short was never taken for an end, and the
        /// end it was for is in the log or still to be recorded. It is
        /// emptied like a stale record (backstop.sh's
        /// remove_stale_lock_record, `deleteSession`, a start), and a
        /// record written here replaces it.
        case foreign(String)
        /// The file could not be read whole (the text says why). It may
        /// hold a whole record of the session in session.json, so it counts
        /// as that session's end, the safe side, until it can be read or
        /// session.json is gone. No writer takes it for a record it wrote.
        case unreadable(String)
    }

    func lockEndRecord() -> LockEndRecord {
        switch readLockFile() {
        case .notUsable: return .none
        case let .tooLarge(size): return .foreign("it holds \(size) bytes, more than an end record")
        case let .unreadable(why): return .unreadable(why)
        case let .bytes(data): return Self.parseLockEndRecord(data)
        }
    }

    private enum LockFile {
        /// Missing, or not a regular file (lstat) this user owns.
        case notUsable
        case bytes(Data)
        /// Larger than `lockEndRecordMaxBytes`, so not read.
        case tooLarge(Int64)
        case unreadable(String)
    }

    /// The recovery lock file's bytes, read only while it is a regular file
    /// (lstat, so not a symlink) this user owns and at most
    /// `lockEndRecordMaxBytes` long.
    private func readLockFile() -> LockFile {
        let path = paths.recoveryLock.path
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return .notUsable }
        if st.st_size == 0 { return .bytes(Data()) }
        guard st.st_size <= Self.lockEndRecordMaxBytes else { return .tooLarge(Int64(st.st_size)) }
        // O_NONBLOCK and O_NOFOLLOW: what took the place of the file checked
        // above is never waited on or followed.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .unreadable("it could not be read (\(String(cString: strerror(errno))))") }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
            return .unreadable("it changed while it was read")
        }
        // One byte more than the size: a file that grew meanwhile is not
        // read as the shorter content it held.
        var bytes = [UInt8](repeating: 0, count: Int(st.st_size) + 1)
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + count, $0.count - count) }
            if n < 0 {
                if errno == EINTR { continue }
                return .unreadable("it could not be read (\(String(cString: strerror(errno))))")
            }
            if n == 0 { break }
            count += n
        }
        guard count == Int(st.st_size) else { return .unreadable("it changed while it was read") }
        return .bytes(Data(bytes[..<count]))
    }

    /// Content backstop.sh's read_lock_record reads the same way: the tag,
    /// one space, base64 (letters, digits, + and /, then at most two =,
    /// a multiple of four in all) and one newline is a record; nothing is
    /// none; anything else is foreign.
    static func parseLockEndRecord(_ data: Data) -> LockEndRecord {
        guard !data.isEmpty else { return .none }
        let other = LockEndRecord.foreign("it holds bytes other than one whole end record")
        let prefix = Array((lockEndRecordTag + " ").utf8)
        let bytes = Array(data)
        guard bytes.last == 0x0A, bytes.count > prefix.count + 1, Array(bytes.prefix(prefix.count)) == prefix else { return other }
        let encoded = bytes[prefix.count..<(bytes.count - 1)]
        let padding = encoded.reversed().prefix { $0 == 0x3D }.count
        let digits = encoded.dropLast(padding)
        func isDigit(_ b: UInt8) -> Bool {
            (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || (0x30...0x39).contains(b) || b == 0x2B || b == 0x2F
        }
        guard padding <= 2, !digits.isEmpty, digits.allSatisfy(isDigit), encoded.count % 4 == 0 else { return other }
        return .record(String(decoding: encoded, as: UTF8.self))
    }

    /// Where the recovery lock file records the end of the session in
    /// session.json, for the log, or nil when it does not: a record of
    /// exactly that file's bytes, or a file that cannot be read whole,
    /// which may hold one (`LockEndRecord.unreadable`). Content read whole
    /// that is not a record ends nothing (`LockEndRecord.foreign`). Nothing
    /// is recorded for a session.json that is not a regular file.
    func sessionEndRecordedInLock() -> String? {
        var st = stat()
        guard stat(paths.sessionFile.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        switch lockEndRecord() {
        case .none, .foreign:
            return nil
        case let .unreadable(why):
            return "\(paths.recoveryLock.lastPathComponent), which \(why), so it may hold this session's end and counts as one"
        case let .record(encoded):
            return encoded == sessionEndMarker() ? paths.recoveryLock.lastPathComponent : nil
        }
    }

    /// For an end that could not remove session.json and could write
    /// neither ended-session.json, the journal nor a record aside: the record of its
    /// bytes in the recovery lock file, written through `lock`, the handle
    /// this transaction holds, over anything else there. A record already
    /// there for these bytes is kept. A file that cannot be read whole
    /// counts as an end for readers, but not here: it is written over too,
    /// as no read shows what it holds. True only when the file then reads
    /// back as a whole record of these bytes.
    func recordSessionEndInLock(lock: RecoveryLockHandle? = RecoveryLock.held) -> Bool {
        guard let encoded = sessionEndMarker() else { return false }
        if lockEndRecord() == .record(encoded) { return true }
        guard let lock else { return false }
        let record = Data("\(Self.lockEndRecordTag) \(encoded)\n".utf8)
        guard record.count <= Self.lockRecordWriteLimit else { return false }
        _ = lock.replaceContents(with: record, at: paths.recoveryLock.path)
        return lockEndRecord() == .record(encoded) && sessionEndRecordedInLock() != nil
    }

    /// Empties the recovery lock file of any record, through `lock`, once
    /// the session it may end is gone or replaced. True when nothing is
    /// left to empty: the file holds none, or is not a regular file this
    /// user owns, which is never written.
    func clearLockEndRecord(lock: RecoveryLockHandle? = RecoveryLock.held) -> Bool {
        if lockEndRecord() == .none { return true }
        guard let lock else { return false }
        _ = lock.replaceContents(with: Data(), at: paths.recoveryLock.path)
        return lockEndRecord() == .none
    }

    /// The recovery lock file's bytes, to put back with
    /// `restoreLockContents` when what replaced them is undone: empty for a
    /// file that is missing or not a regular file this user owns, which is
    /// never written, and for one larger than any record, which ends
    /// nothing and is not kept; nil when it cannot be read whole.
    func lockContents() -> Data? {
        switch readLockFile() {
        case .notUsable, .tooLarge: return Data()
        case .unreadable: return nil
        case let .bytes(data): return data
        }
    }

    /// Puts `data` back in the recovery lock file through `lock`. True when
    /// it then holds exactly those bytes.
    func restoreLockContents(_ data: Data, lock: RecoveryLockHandle? = RecoveryLock.held) -> Bool {
        if lockContents() == data { return true }
        guard let lock else { return false }
        _ = lock.replaceContents(with: data, at: paths.recoveryLock.path)
        return lockContents() == data
    }

    // MARK: The end record in the log

    /// Where the log records the end of the session in session.json
    /// (`LogEndRecord`): "insomnia.log" or "insomnia.log.1", the file that
    /// holds a whole record of exactly that file's bytes, or nil. A log that
    /// cannot be read records nothing here; a rotation keeps it
    /// (`LogEndRecord.keepRecords`). Nothing is recorded for a session.json
    /// that is missing, unreadable or not a regular file.
    func sessionEndRecordedInLog() -> String? {
        guard let current = try? readData(from: paths.sessionFile),
              let line = LogEndRecord.line(for: current) else { return nil }
        for url in [paths.logFile, OwnerOnly.rotated(paths.logFile)] {
            if case .read(found: true, _) = LogEndRecord.scan(url, for: line) { return url.lastPathComponent }
        }
        return nil
    }

    /// For an end that could not remove session.json and could write
    /// neither ended-session.json, the journal, a record aside nor the
    /// recovery lock file: the record of its bytes appended to insomnia.log,
    /// only while `lock` is the recovery lock this transaction holds, and
    /// under `Log.withFileLock`, so no line or rotation from this process
    /// runs between the write and the read-back. A record already in either
    /// log for these bytes is used again. True only when a whole record of
    /// session.json's bytes then reads back.
    func recordSessionEndInLog(lock: RecoveryLockHandle? = RecoveryLock.held) -> Bool {
        if sessionEndRecordedInLog() != nil { return true }
        guard let lock, lock.locks(path: paths.recoveryLock.path),
              let current = try? readData(from: paths.sessionFile),
              let line = LogEndRecord.line(for: current) else { return false }
        let logFile = paths.logFile
        guard Log.withFileLock({ LogEndRecord.append(line, to: logFile) }) else { return false }
        return sessionEndRecordedInLog() != nil
    }

    /// What `sessionEndRecordedInLog` reads, as device, inode, size and
    /// modification time of session.json (followed, as it is read) and both
    /// logs (not followed), so the 1 Hz tick reads the logs again only after
    /// one of them changed.
    func logEndRecordFingerprint() -> String {
        [(paths.sessionFile, true), (paths.logFile, false), (OwnerOnly.rotated(paths.logFile), false)].map { url, follow in
            var st = stat()
            guard (follow ? stat(url.path, &st) : lstat(url.path, &st)) == 0 else { return "-" }
            return "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }.joined(separator: " ")
    }

    /// Whether anything is at session.json, a dangling symlink included.
    /// lstat(2) only: the entry is never opened.
    func sessionEntryExists() -> Bool {
        var st = stat()
        return lstat(paths.sessionFile.path, &st) == 0
    }

    /// Renames an unreadable session.json to a timestamped sibling (see
    /// Paths.unreadableSessionPrefix) and returns the new location. The
    /// bytes are kept for inspection; the next reader sees no session.
    /// Never overwrites: a taken name gets -1, -2, ..., and the rename
    /// itself fails rather than replace a file that appeared meanwhile.
    func moveAsideUnreadableSession(now: Date) throws -> URL {
        try moveAside(paths.sessionFile, prefix: Paths.unreadableSessionPrefix, now: now)
    }

    /// The same for a config.json that does not decode (see Paths.
    /// unreadableConfigPrefix): it holds the user's settings, so it is kept
    /// for a person to fix rather than written over with defaults.
    func moveAsideUnreadableConfig(now: Date) throws -> URL {
        try moveAside(paths.configFile, prefix: Paths.unreadableConfigPrefix, now: now)
    }

    private func moveAside(_ file: URL, prefix: String, now: Date) throws -> URL {
        let base = prefix + Self.stamp(now)
        var dest = paths.appSupport.appendingPathComponent(base)
        var n = 0
        while FileManager.default.fileExists(atPath: dest.path) {
            n += 1
            dest = paths.appSupport.appendingPathComponent("\(base)-\(n)")
        }
        try FileManager.default.moveItem(at: file, to: dest)
        return dest
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// Non-mutating. A journal that does not decode stays exactly where it
    /// is: it is the only record of what a previous run changed, and moving
    /// or rewriting it would let the next reader (this app, backstop.sh,
    /// uninstall.sh) see no journal and call the machine clean. The error
    /// names the file so a person can fix or move it.
    func loadState() throws -> RuntimeState? {
        do {
            guard let data = try readData(from: paths.stateFile) else { return nil }
            return try Self.decodeState(data)
        } catch let error as DecodingError {
            throw StoreError.corrupt(file: paths.stateFile.path, detail: Self.brief(error))
        }
    }

    /// state.json's bytes as the app reads them: the one decoder behind
    /// `loadState` and `Insomnia --agent-session-cutoffs`
    /// (AgentCutoffsCommand), which backstop.sh runs on the same bytes
    /// before it uses the journal's cutoffs. Pure: it opens no file.
    static func decodeState(_ data: Data) throws -> RuntimeState {
        try makeDecoder().decode(RuntimeState.self, from: data)
    }
    func saveState(_ s: RuntimeState) throws { try write(s, to: paths.stateFile) }

    /// Throws StoreError.unreadable, with a one-line reason, when the file
    /// does not decode.
    func loadConfig() throws -> Config? {
        guard let data = try readData(from: paths.configFile) else { return nil }
        do {
            return try Self.decodeConfig(data)
        } catch let error as DecodingError {
            throw StoreError.unreadable(file: paths.configFile.path, detail: Self.brief(error))
        }
    }

    /// config.json's bytes as the app reads them: the one decoder behind
    /// `loadConfig` and `Insomnia --agent-cutoffs` (AgentCutoffsCommand),
    /// which backstop.sh runs on the same bytes. Pure: it opens no file.
    static func decodeConfig(_ data: Data) throws -> Config {
        try makeDecoder().decode(Config.self, from: data)
    }
    func saveConfig(_ c: Config) throws { try write(c, to: paths.configFile) }

    /// False for a config.json written before `configVersion` existed.
    func configHasVersion() throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile))
        return (object as? [String: Any])?["configVersion"] != nil
    }
    /// nil when there is none, or it cannot be read: it only names the
    /// command in a message.
    func loadUnfinishedCommand() -> UnfinishedCommandRecord? {
        try? read(UnfinishedCommandRecord.self, from: paths.unfinishedCommandFile)
    }
    func saveUnfinishedCommand(_ r: UnfinishedCommandRecord) throws { try write(r, to: paths.unfinishedCommandFile) }
    func removeUnfinishedCommand() throws { try remove(at: paths.unfinishedCommandFile) }

    /// One line about why decoding failed, fit for a notification.
    private static func brief(_ error: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "" : "\(p): "
        }
        switch error {
        case let .dataCorrupted(c): return path(c) + c.debugDescription
        case let .keyNotFound(k, c): return path(c) + "missing key \(k.stringValue)"
        case let .typeMismatch(t, c): return path(c) + "expected \(t)"
        case let .valueNotFound(t, c): return path(c) + "missing \(t)"
        @unknown default: return String(describing: error)
        }
    }
}

enum StoreError: Error, LocalizedError {
    case rename(from: String, to: String, errno: Int32)
    case corrupt(file: String, detail: String)
    case unreadable(file: String, detail: String)
    case notRegularFile(file: String)
    case lockRecordNotCleared(file: String)

    var errorDescription: String? {
        switch self {
        case let .rename(from, to, errno):
            return "rename \(from) -> \(to) failed: \(String(cString: strerror(errno)))"
        case let .corrupt(file, detail):
            return "\(file) could not be decoded (\(detail)); it was left in place"
        case let .unreadable(file, detail):
            return "\(file) could not be decoded (\(detail))"
        case let .notRegularFile(file):
            return "\(file) is not a regular file; it was not opened"
        case let .lockRecordNotCleared(file):
            return "\(file) holds the record of an earlier session's end and could not be emptied"
        }
    }
}
