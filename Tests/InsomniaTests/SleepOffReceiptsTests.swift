import Darwin
import XCTest
@testable import Insomnia

/// SleepOffReceipts on its own: what a receipt shows about one start under
/// its lock, the claim kept in the release file, and every receipt or
/// folder it refuses to trust. Each test has its own receipt folder in a
/// temporary home (TestReceipts), trusted for the test user besides root.
final class SleepOffReceiptsTests: XCTestCase {
    private var home: TempHome!
    private var receipts: SleepOffReceipts!

    override func setUpWithError() throws {
        home = TempHome()
        receipts = try TestReceipts.make(in: home.root)
    }

    override func tearDown() {
        _ = try? runChmod(["-N", receipts.file])
        _ = try? runChmod(["-N", receipts.folder])
        chmod(receipts.folder, 0o755)
        chmod(receipts.file, 0o600)
        home.destroy()
    }

    /// This start's nonce, the one it claimed the receipt from, and two
    /// others.
    private let nonce = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    private let predecessor = "6F9619FF-8B86-D011-B42D-00C04FC96400"
    private let later = "6F9619FF-8B86-D011-B42D-00C04FC96401"
    private let other = "6F9619FF-8B86-D011-B42D-00C04FC96402"
    /// When this start's answer window ends.
    private let expires = 1_800_000_100

    private func attempt(_ identity: String, marker: String? = "1:2") -> SleepOffAttempt {
        SleepOffAttempt(nonce: nonce, owedBefore: false, receipt: identity, predecessor: predecessor, deadline: 1_800_000_000, expires: expires, marker: marker)
    }

    private func runChmod(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        return p.terminationStatus
    }

    private func mayHaveWritten(_ verdict: SleepOffVerdict) -> String? {
        if case let .mayHaveWritten(reason) = verdict { return reason }
        return nil
    }

    private func undecided(_ verdict: SleepOffVerdict) -> String? {
        if case let .undecided(reason) = verdict { return reason }
        return nil
    }

    /// The verdict for `attempt`, read under the receipt's lock at `now`.
    private func verdict(_ attempt: SleepOffAttempt, now: Int, dialogOver: Bool = false) async -> SleepOffVerdict {
        let outcome: Result<SleepOffReceipts.Guard, Error>
        do { outcome = .success(try await receipts.lock(timeout: 0.2)) } catch { outcome = .failure(error) }
        defer { if case let .success(held) = outcome { held.release() } }
        return receipts.verdict(for: attempt, lock: outcome, now: now, dialogOver: dialogOver)
    }

    /// Round 24 F1. Under the lock, at any time: this start's `refused`,
    /// or another start's line that names the same predecessor (that start
    /// claimed the receipt from the same line and wrote first, so this
    /// start's command, which writes only while the receipt holds the
    /// predecessor, never can) shows that this start's command never
    /// turned sleep off. This start's `writing`, and a line naming another
    /// predecessor (a later start's, which shows nothing about this one),
    /// show that it may have. The predecessor itself shows nothing until
    /// the start has expired or its dialog is over, and then that it never
    /// did.
    func testTheVerdictFollowsTheLineThePredecessorAndTheTime() async throws {
        let identity = try receipts.identity()
        let a = attempt(identity)
        for now in [expires - 1, expires, expires + 3600] {
            let over = now >= expires
            let at = "\(now - expires) s from expires"
            TestReceipts.write(receipts.file, nonce: predecessor, predecessor: other, word: "refused")
            if over {
                let v = await verdict(a, now: now)
                XCTAssertEqual(v, .neverWrote, "\(at): the predecessor, once no command can still write")
            } else {
                let early = await verdict(a, now: now)
                let why = try XCTUnwrap(undecided(early), at)
                XCTAssertTrue(why.hasPrefix("the password dialog of that start can still be answered until 2027-01-15T08:01:40Z"), "\(at): \(why)")
                let v = await verdict(a, now: now, dialogOver: true)
                XCTAssertEqual(v, .neverWrote, "\(at): the dialog ended on its own")
            }
            TestReceipts.write(receipts.file, nonce: predecessor, predecessor: other, word: "writing")
            if over {
                let v = await verdict(a, now: now)
                XCTAssertEqual(v, .neverWrote, "\(at): the predecessor's own word is not this start's")
            }
            TestReceipts.write(receipts.file, nonce: nonce, predecessor: predecessor, word: "refused")
            var v = await verdict(a, now: now)
            XCTAssertEqual(v, .neverWrote, "\(at): this start's command stopped before pmset")
            TestReceipts.write(receipts.file, nonce: nonce, predecessor: predecessor, word: "writing")
            v = await verdict(a, now: now)
            let wrote = try XCTUnwrap(mayHaveWritten(v), at)
            XCTAssertEqual(wrote, "\(receipts.file) holds that start's writing line: its command was about to turn sleep off and may have")
            for word in ["writing", "refused"] {
                TestReceipts.write(receipts.file, nonce: later, predecessor: predecessor, word: word)
                v = await verdict(a, now: now)
                XCTAssertEqual(v, .neverWrote, "\(at): another start claimed the same line and wrote first (\(word))")
                TestReceipts.write(receipts.file, nonce: later, predecessor: other, word: word)
                v = await verdict(a, now: now)
                let reason = try XCTUnwrap(mayHaveWritten(v), "\(at), \(word)")
                XCTAssertEqual(reason, "\(receipts.file) holds a later start's line, which no longer shows what the command for this start did")
            }
        }
        XCTAssertEqual(try receipts.identity(), identity, "written in place, the receipt stays the same file")
    }

    /// A start that never showed its dialog never ran anything as root,
    /// whatever the receipt holds, and its verdict needs no lock.
    func testAStartWithNoDialogNeverWrote() async throws {
        TestReceipts.write(receipts.file, nonce: nonce, predecessor: predecessor, word: "writing")
        let a = attempt(try receipts.identity(), marker: nil)
        XCTAssertEqual(receipts.verdict(for: a, lock: .failure(SleepOffReceipts.Busy(file: receipts.file, seconds: 1)), now: expires - 1), .neverWrote)
        let v = await verdict(a, now: expires - 1)
        XCTAssertEqual(v, .neverWrote)
    }

    /// Round 24 F2. A receipt that stays locked (a root command for some
    /// start holds it until its pmset exits, or another Insomnia folder of
    /// this user, or anything running as the user), a lock that fails, or
    /// a wait that was cancelled decide nothing, at any time: the start
    /// stays recorded and is read again later.
    func testALockedReceiptDecidesNothing() async throws {
        TestReceipts.write(receipts.file, nonce: nonce, predecessor: predecessor, word: "refused")
        let a = attempt(try receipts.identity())
        let held = try await receipts.lock(timeout: 0.2)
        defer { held.release() }
        let started = Date()
        do {
            _ = try await receipts.lock(timeout: 0.3)
            XCTFail("a second lock was granted")
        } catch let busy as SleepOffReceipts.Busy {
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
            XCTAssertEqual(busy.localizedDescription, "\(receipts.file) stayed locked for 0 s: the command behind a password dialog may be running, or another Insomnia folder of this user, or something else running as this user, is holding it")
        }
        for now in [expires - 1, expires + 3600] {
            for dialogOver in [false, true] {
                for error: Error in [SleepOffReceipts.Busy(file: receipts.file, seconds: 10), SleepOffReceipts.LockFailed(file: receipts.file, errno: EIO), CancellationError()] {
                    let why = undecided(receipts.verdict(for: a, lock: .failure(error), now: now, dialogOver: dialogOver))
                    XCTAssertEqual(why, error.localizedDescription, "\(error), \(now - expires) s from expires, dialogOver \(dialogOver)")
                }
            }
        }
        held.release()
        let v = await verdict(a, now: expires - 1)
        XCTAssertEqual(v, .neverWrote, "once let go, the same receipt decides")
    }

    /// The same bytes in another file (renamed over the receipt) show
    /// nothing about a start that began with the first one: undecided
    /// while a command for it could still write, and undone like an end
    /// after that.
    func testAReceiptThatIsAnotherFileNowShowsNothing() async throws {
        let identity = try receipts.identity()
        let copy = receipts.folder + "/copy"
        try Data(line(nonce, "refused").utf8).write(to: URL(fileURLWithPath: copy))
        XCTAssertEqual(chmod(copy, 0o600), 0)
        XCTAssertEqual(rename(copy, receipts.file), 0)

        XCTAssertNotEqual(try receipts.identity(), identity)
        let early = await verdict(attempt(identity), now: expires - 1)
        let why = try XCTUnwrap(undecided(early))
        XCTAssertTrue(why.hasPrefix("\(receipts.file) is not the file it was when the start began; a command for that start could still write until "), why)
        let late = await verdict(attempt(identity), now: expires)
        let reason = try XCTUnwrap(mayHaveWritten(late))
        XCTAssertEqual(reason, "\(receipts.file) is not the file it was when the start began")
    }

    private func line(_ nonce: String, _ word: String, after: String? = nil) -> String {
        "\(nonce) \(after ?? predecessor) \(word)\n"
    }

    /// Each way a receipt or a folder above it can be something the checks
    /// do not trust. A receipt that would otherwise show "never" shows
    /// nothing (undecided before expires, may have written after), and a
    /// start could not begin with it (identity throws), apart from content
    /// that is wrong in an 82-byte file, which only the read under the lock
    /// finds. A receipt nobody can read has a mode other than 600. Round
    /// 28 F3: every refused list of entries (TestReceipts.refusedLists) is
    /// a stand-in in front of the file's real entries, so none changes a
    /// real list.
    func testAReceiptOrFolderTheChecksDoNotTrustShowsNothing() async throws {
        let user = String(cString: getpwuid(getuid()).pointee.pw_name)
        let file = receipts.file
        let folder = receipts.folder
        let cases: [(name: String, startable: Bool, says: String, damage: () throws -> Void, repair: () throws -> Void)] = [
            ("missing", false, "No such file or directory", { XCTAssertEqual(unlink(file), 0) }, {}),
            ("81 bytes", false, "is 81 bytes, not 82", { XCTAssertEqual(truncate(file, 81), 0) }, {}),
            ("83 bytes", false, "is 83 bytes, not 82", { XCTAssertEqual(truncate(file, 83), 0) }, {}),
            ("an earlier build's 45 bytes", false, "is 45 bytes, not 82", { try Data("\(self.nonce) refused\n".utf8).write(to: URL(fileURLWithPath: file)) }, {}),
            ("group-writable", false, "can be changed by its group or by others", { XCTAssertEqual(chmod(file, 0o664), 0) }, {}),
            ("writable by others", false, "can be changed by its group or by others", { XCTAssertEqual(chmod(file, 0o646), 0) }, {}),
            ("a hard link", false, "has 2 links", { XCTAssertEqual(link(file, folder + "/link"), 0) }, { unlink(folder + "/link") }),
            ("a symbolic link", false, "is not a regular file", {
                try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: folder + "/target"))
                XCTAssertEqual(unlink(file), 0)
                XCTAssertEqual(symlink(folder + "/target", file), 0)
            }, { unlink(folder + "/target") }),
            ("a folder", false, "is not a regular file", { XCTAssertEqual(unlink(file), 0); XCTAssertEqual(mkdir(file, 0o755), 0) }, { rmdir(file) }),
            ("an allow entry on the receipt", false, "has 2 access control entries, not the one that lets uid \(getuid()) read it", { XCTAssertEqual(try self.runChmod(["+a", "user:\(user) allow write", file]), 0) },
             { _ = try self.runChmod(["-N", file]) }),
            ("mode 644, as an earlier build made it", false, "has mode 644, not the 600 install.sh gives it", { XCTAssertEqual(chmod(file, 0o644), 0) }, {}),
            ("mode 400", false, "has mode 400, not the 600 install.sh gives it", { XCTAssertEqual(chmod(file, 0o400), 0) }, {}),
            ("a group-writable folder", false, "can be changed by its group or by others", { XCTAssertEqual(chmod(folder, 0o775), 0) }, { chmod(folder, 0o755) }),
            ("an allow entry on the folder", false, "has an access control entry that allows changes", { XCTAssertEqual(try self.runChmod(["+a", "user:\(user) allow add_file", folder]), 0) },
             { _ = try self.runChmod(["-N", folder]) }),
            ("unreadable", false, "has mode 0, not the 600 install.sh gives it", { XCTAssertEqual(chmod(file, 0o000), 0) }, { chmod(file, 0o600) }),
            ("a lower-case nonce", true, "does not hold two nonces and writing or refused", { TestReceipts.write(file, nonce: self.nonce.lowercased(), predecessor: self.predecessor, word: "refused") }, {}),
            ("a lower-case predecessor", true, "does not hold two nonces and writing or refused", { TestReceipts.write(file, nonce: self.nonce, predecessor: self.predecessor.lowercased(), word: "refused") }, {}),
            ("another word", true, "does not hold two nonces and writing or refused", { TestReceipts.write(file, nonce: self.nonce, predecessor: self.predecessor, word: "written") }, {}),
            ("no newline", true, "does not hold two nonces and writing or refused", { TestReceipts.write(file, nonce: self.nonce, predecessor: self.predecessor, word: "refused\u{20}"); XCTAssertEqual(truncate(file, 82), 0) }, {}),
        ] + TestReceipts.refusedLists.map { list in
            let says = list.entries.isEmpty ? "has no access control entry, so uid \(getuid()) cannot read it"
                : list.entries.count > 1 ? "has \(list.entries.count) access control entries, not the one that lets uid \(getuid()) read it"
                : "has an access control entry other than the one that lets uid \(getuid()) read it: \(list.entries[0].text)"
            return (list.name, false, says, { self.receipts = TestReceipts.with(self.receipts, standIn: list.entries) }, {})
        }
        for c in cases {
            receipts = try TestReceipts.make(in: home.root)
            TestReceipts.write(file, nonce: nonce, predecessor: predecessor, word: "refused")
            let identity = try receipts.identity()
            let control = await verdict(attempt(identity), now: expires - 1)
            XCTAssertEqual(control, .neverWrote, "\(c.name): the control")
            try c.damage()

            if c.startable {
                XCTAssertNoThrow(try receipts.identity(), c.name)
            } else {
                XCTAssertThrowsError(try receipts.identity(), c.name) { error in
                    XCTAssertTrue(error.localizedDescription.contains(c.says), "\(c.name): \(error.localizedDescription)")
                }
            }
            let early = await verdict(attempt(identity), now: expires - 1)
            let why = try XCTUnwrap(undecided(early), c.name)
            XCTAssertTrue(why.contains(c.says), "\(c.name): \(why)")
            XCTAssertTrue(why.contains("a command for that start could still write until"), "\(c.name): \(why)")
            let late = await verdict(attempt(identity), now: expires)
            let reason = try XCTUnwrap(mayHaveWritten(late), c.name)
            XCTAssertTrue(reason.contains(c.says), "\(c.name): \(reason)")

            try c.repair()
            unlink(file)
        }
    }

    /// F3 (round 28). Only the one entry install.sh adds is the receipt's
    /// list: it allows, names the user, grants read alone and carries no
    /// flag. Each right and flag acl(3) defines, including those ls(1)
    /// does not print for a file (synchronize, delete_child and the
    /// inheritance flags), and a right bit the words do not name, makes it
    /// another entry.
    func testOnlyTheEntryInstallShAddsIsTheReceiptsList() {
        let me = getuid()
        let mine = AccessEntry.installed(for: me)
        XCTAssertEqual(mine, AccessEntry(allows: true, principal: .user(me), rights: ["read"], flags: []))
        XCTAssertNil(SleepOffReceipts.receiptAccessProblem([mine], user: me))
        XCTAssertEqual(SleepOffReceipts.receiptAccessProblem([], user: me), "has no access control entry, so uid \(me) cannot read it")
        XCTAssertEqual(SleepOffReceipts.receiptAccessProblem([mine, mine], user: me), "has 2 access control entries, not the one that lets uid \(me) read it")
        XCTAssertNotNil(SleepOffReceipts.receiptAccessProblem([.installed(for: me + 1)], user: me))
        XCTAssertEqual(SleepOffReceipts.receiptAccessProblem([mine], user: me + 1), "has an access control entry other than the one that lets uid \(me + 1) read it: uid \(me) allow read")
        for (right, word) in AccessEntry.rightWords where word != "read" {
            var entry = mine
            entry.rights.insert(word)
            XCTAssertNotNil(SleepOffReceipts.receiptAccessProblem([entry], user: me), word)
            XCTAssertEqual(AccessEntry.words(acl_permset_mask_t(ACL_READ_DATA.rawValue) | acl_permset_mask_t(right.rawValue)), ["read", word])
        }
        for (_, word) in AccessEntry.flagWords {
            var entry = mine
            entry.flags.insert(word)
            XCTAssertNotNil(SleepOffReceipts.receiptAccessProblem([entry], user: me), word)
        }
        let unnamed = acl_permset_mask_t(1) << 40
        XCTAssertEqual(AccessEntry.words(acl_permset_mask_t(ACL_READ_DATA.rawValue) | unnamed), ["read", "0x10000000000"])
        XCTAssertEqual(AccessEntry.words(acl_permset_mask_t(ACL_READ_DATA.rawValue)), ["read"])
        for principal: AccessEntry.Principal in [.group(me), .unknown] {
            var entry = mine
            entry.principal = principal
            XCTAssertNotNil(SleepOffReceipts.receiptAccessProblem([entry], user: me), "\(principal)")
        }
        var deny = mine
        deny.allows = false
        XCTAssertEqual(SleepOffReceipts.receiptAccessProblem([deny], user: me), "has an access control entry other than the one that lets uid \(me) read it: uid \(me) deny read")
    }

    /// A read-only control of the reader on real lists: for this user's
    /// home folder, a folder of the system's and a folder with no list,
    /// `accessEntries` reads what `/bin/ls -led` prints, entry by entry,
    /// in order (lsText of each entry is ls's line for a folder's rights
    /// and flags that it prints for files too). Nothing is changed. On a
    /// Mac where none of them has an entry it is skipped.
    func testTheReaderReadsWhatLsPrints() throws {
        var seen = 0
        for path in [NSHomeDirectory(), "/private/var/db/fseventsd", "/private/var/db", "/usr/bin"] {
            guard let entries = SleepOffReceipts.accessEntries(path) else {
                XCTFail("\(path): the list could not be read")
                continue
            }
            let p = Process()
            let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/ls")
            p.arguments = ["-led", path]
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let exit = ProcessExit(p)
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            exit.wait()
            guard p.terminationStatus == 0 else { continue }
            let printed = text.split(separator: "\n").dropFirst().map(String.init)
            XCTAssertEqual(printed.count, entries.count, "\(path): \(text)")
            for (i, entry) in entries.enumerated() where i < printed.count {
                // A folder's names for the rights a file calls read, write,
                // execute and append.
                var shown = entry
                shown.rights = Set(entry.rights.map { ["read": "list", "write": "add_file", "execute": "search", "append": "add_subdirectory"][$0] ?? $0 })
                let folderWords = ["list", "add_file", "search", "delete", "add_subdirectory", "delete_child", "readattr", "writeattr", "readextattr", "writeextattr", "readsecurity", "writesecurity", "chown"]
                let flags = ["file_inherit", "directory_inherit", "limit_inherit", "only_inherit"].filter(entry.flags.contains)
                let head = TestReceipts.lsText(AccessEntry(allows: entry.allows, principal: entry.principal, rights: [], flags: entry.flags.intersection(["inherited"])))
                let words = (folderWords.filter(shown.rights.contains) + flags).joined(separator: ",")
                XCTAssertEqual(printed[i], " \(i): \(head)\(words)", path)
                seen += 1
            }
        }
        if seen == 0 { throw XCTSkip("none of these folders has an access control entry on this Mac, so only empty lists were compared") }
    }

    /// The receipt the app ships with trusts root alone, at the fixed path.
    /// A receipt the user owns, in a folder the user owns, which is all a
    /// process running as the user could make, shows nothing under that
    /// trust and cannot begin a start, whatever it holds.
    func testOnlyRootIsTrustedAndAReceiptTheUserOwnsIsNot() async throws {
        let live = SleepOffReceipts.live
        XCTAssertEqual(live.folder, "/private/var/db/com.kgarg.insomnia")
        XCTAssertEqual(live.owners, [0])
        XCTAssertEqual(live.user, getuid())
        XCTAssertEqual(live.file, "/private/var/db/com.kgarg.insomnia/\(getuid())")
        XCTAssertEqual(live.releaseFile, "/private/var/db/com.kgarg.insomnia/\(getuid()).released")

        let identity = try receipts.identity()
        let shipped = SleepOffReceipts(folder: receipts.folder, owners: [0], user: getuid())
        XCTAssertThrowsError(try shipped.identity()) { error in
            XCTAssertTrue(error.localizedDescription.contains("belongs to uid \(getuid()), not root"), error.localizedDescription)
        }
        for word in ["refused", "writing"] {
            TestReceipts.write(receipts.file, nonce: nonce, predecessor: predecessor, word: word)
            let outcome: Result<SleepOffReceipts.Guard, Error>
            do { outcome = .success(try await shipped.lock(timeout: 0.2)) } catch { outcome = .failure(error) }
            XCTAssertThrowsError(try outcome.get(), word)
            let reason = try XCTUnwrap(mayHaveWritten(shipped.verdict(for: attempt(identity), lock: outcome, now: expires)), word)
            XCTAssertTrue(reason.contains("not root"), reason)
        }
    }

    /// Only an absolute path with no empty, `.` or `..` component and no
    /// link on the way is a folder the checks accept. The temporary
    /// directory's own path goes through /var, a link to /private/var.
    func testOnlyAPlainAbsoluteFolderWithNoLinkIsAccepted() throws {
        let real = receipts.folder
        let base = (real as NSString).deletingLastPathComponent
        XCTAssertTrue(real.hasPrefix("/private/var/"), real)
        let viaVar = String(real.dropFirst("/private".count))
        for folder in ["receipts", base + "/./receipts", base + "/../" + (base as NSString).lastPathComponent + "/receipts", base + "//receipts", real + "/", "/"] {
            XCTAssertThrowsError(try SleepOffReceipts(folder: folder, owners: [0, getuid()], user: getuid()).identity(), folder) { error in
                XCTAssertTrue(error.localizedDescription.hasSuffix("is not a plain absolute path"), "\(folder): \(error.localizedDescription)")
            }
        }
        XCTAssertThrowsError(try SleepOffReceipts(folder: viaVar, owners: [0, getuid()], user: getuid(), standIn: [.installed(for: getuid())]).identity()) { error in
            XCTAssertEqual(error.localizedDescription, "/var is not a folder")
        }
        XCTAssertNoThrow(try SleepOffReceipts(folder: real, owners: [0, getuid()], user: getuid(), standIn: [.installed(for: getuid())]).identity())
    }

    /// The identity the journal keeps is what `stat -f '%d:%i'` prints,
    /// which backstop.sh and uninstall.sh compare it with.
    func testTheIdentityIsWhatStatPrints() throws {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        p.arguments = ["-f", "%d:%i", receipts.file]
        p.standardOutput = out
        let exit = ProcessExit(p)
        try p.run()
        let printed = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        exit.wait()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(try receipts.identity() + "\n", printed)
        XCTAssertEqual(FileIdentity(atPath: receipts.file)?.text, try receipts.identity())
    }

    // MARK: The claim

    /// Round 24 F1. A start claims the receipt under its lock while the
    /// release file shows the receipt's nonce free, and the receipt's
    /// nonce becomes its predecessor. A claim another start holds, from
    /// this Insomnia folder or another of this user's, refuses the claim,
    /// so no root command can replace the line that start's settlement
    /// reads; so does a release file that names another nonce, or is
    /// missing or not in its shape.
    func testAStartClaimsTheReceiptOnlyWhileItIsFree() async throws {
        TestReceipts.write(receipts.file, nonce: predecessor, predecessor: other, word: "refused")
        TestReceipts.setRelease(receipts, "\(predecessor) free\n")
        let held = try await receipts.lock(timeout: 0.2)
        defer { held.release() }
        XCTAssertEqual(try receipts.claimable(under: held), predecessor)

        TestReceipts.setRelease(receipts, "\(later) held\n")
        XCTAssertThrowsError(try receipts.claimable(under: held)) { error in
            XCTAssertTrue(error is SleepOffReceipts.Claimed, "\(error)")
            XCTAssertEqual(error.localizedDescription, "another Insomnia start (\(later)) has claimed the receipt and is not settled yet. Its own Insomnia folder settles it: open Insomnia from that folder, or wait for its recovery agent, which tries every minute")
        }
        TestReceipts.setRelease(receipts, "\(other) free\n")
        XCTAssertThrowsError(try receipts.claimable(under: held)) { error in
            XCTAssertTrue(error.localizedDescription.hasSuffix("names a start other than the one \(receipts.file) holds. Run install.sh again"), error.localizedDescription)
        }
        for (what, text) in [("lower case", "\(predecessor.lowercased()) free\n"), ("another word", "\(predecessor) gone\n"), ("41 bytes", "\(predecessor) free"), ("43 bytes", "\(predecessor) free\n\n")] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: receipts.releaseFile))
            XCTAssertThrowsError(try receipts.claimable(under: held), what) { error in
                XCTAssertTrue(error.localizedDescription.hasSuffix("Run install.sh again"), "\(what): \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(unlink(receipts.releaseFile), 0)
        XCTAssertThrowsError(try receipts.claimable(under: held)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No such file or directory. Run install.sh again"), error.localizedDescription)
        }
        XCTAssertEqual(symlink(receipts.file, receipts.releaseFile), 0)
        XCTAssertThrowsError(try receipts.claimable(under: held), "never through a link")
        XCTAssertThrowsError(try receipts.writeRelease(.free(predecessor)), "never through a link")
        XCTAssertEqual(TestReceipts.text(receipts), "\(predecessor) \(other) refused\n", "the receipt behind the link is untouched")
    }

    /// Giving a claim back writes the receipt's nonce free, and only when
    /// the release file shows that claim: a claim given back already, or
    /// another start's, is left as it is.
    func testAClaimIsGivenBackOnlyByItsOwnStart() async throws {
        TestReceipts.write(receipts.file, nonce: nonce, predecessor: predecessor, word: "refused")
        let held = try await receipts.lock(timeout: 0.2)
        defer { held.release() }
        TestReceipts.setRelease(receipts, "\(nonce) held\n")
        XCTAssertTrue(try receipts.release(nonce, under: held))
        XCTAssertEqual(TestReceipts.release(receipts), "\(nonce) free\n", "free, under the nonce the receipt holds now")
        XCTAssertFalse(try receipts.release(nonce, under: held), "given back already")
        TestReceipts.setRelease(receipts, "\(later) held\n")
        XCTAssertFalse(try receipts.release(nonce, under: held))
        XCTAssertEqual(TestReceipts.release(receipts), "\(later) held\n", "another start's claim stays")

        // The command for the start never ran: the receipt still holds
        // its predecessor, which is free again.
        TestReceipts.write(receipts.file, nonce: predecessor, predecessor: other, word: "writing")
        TestReceipts.setRelease(receipts, "\(nonce) held\n")
        XCTAssertTrue(try receipts.release(nonce, under: held))
        XCTAssertEqual(TestReceipts.release(receipts), "\(predecessor) free\n")
        XCTAssertEqual(try receipts.claimable(under: held), predecessor)
    }

    /// The release file is written in place, never created or truncated
    /// to another size, and read back.
    func testTheReleaseFileIsWrittenInPlace() throws {
        let before = FileIdentity(atPath: receipts.releaseFile)
        try receipts.writeRelease(.held(nonce))
        XCTAssertEqual(TestReceipts.release(receipts), "\(nonce) held\n")
        XCTAssertEqual(try receipts.readRelease(), .held(nonce))
        XCTAssertEqual(FileIdentity(atPath: receipts.releaseFile), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: receipts.releaseFile)[.size] as? Int, SleepOffReceipts.releaseSize)
        XCTAssertEqual(truncate(receipts.releaseFile, 41), 0)
        XCTAssertThrowsError(try receipts.writeRelease(.free(nonce)))
        XCTAssertEqual(unlink(receipts.releaseFile), 0)
        XCTAssertThrowsError(try receipts.writeRelease(.free(nonce)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipts.releaseFile), "never created")
    }
}

/// A start the app journaled (sleepOffAttempt) and never finished, settled
/// by the next transaction of a relaunched app, and the rules around it:
/// round 21's two receipt controls and its two relaunch findings, and
/// round 24's shared receipt (F1), receipt lock (F2), answer window (F3)
/// and settlements that cannot be written (F4), as safety assertions.
@MainActor
final class SleepOffSettlementTests: XCTestCase {
    private var h: Harness!
    /// Harnesses for other Insomnia folders that share `h`'s receipt.
    private var others: [Harness] = []

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        for harness in others + [h!] {
            chmod(harness.home.root.path, 0o755)
            harness.home.destroy()
        }
        others = []
    }

    /// A new harness in place of `h`, for the next case of a loop.
    private func fresh() {
        chmod(h.home.root.path, 0o755)
        h.home.destroy()
        h = Harness()
    }

    private let now = 1_800_000_000

    /// What a start journals before its dialog, as performStart writes it,
    /// in `harness` (`h` unless given), and the app then dies:
    /// sleepDisabledByUs with the attempt, whose predecessor is the nonce
    /// the receipt holds; the claim (the release file shows the attempt's
    /// nonce held); its session.json, ending `endsIn` seconds after the
    /// harness clock; and with `marker`, the marker, whose identity is
    /// journaled with `expires`: AdministratorPrompt.answerWindow after the
    /// clock, or the session's end if sooner.
    @discardableResult
    private func journalUnfinishedStart(owedBefore: Bool = false, endsIn: TimeInterval = 1800, marker: Bool = true, in harness: Harness? = nil) throws -> SleepOffAttempt {
        let h = harness ?? self.h!
        let session = SessionMath.newSession(now: h.clock.now.addingTimeInterval(endsIn - 3600), duration: 3600, maxDuration: 86400)
        let nonce = UUID().uuidString
        let deadline = Int(session.endsAt.timeIntervalSince1970.rounded(.down))
        let predecessor = try XCTUnwrap(TestReceipts.nonce(h.receipts.file))
        var attempt = SleepOffAttempt(nonce: nonce, owedBefore: owedBefore, receipt: try h.receipts.identity(), predecessor: predecessor, deadline: deadline, expires: deadline, marker: nil)
        var journal = RuntimeState.clean
        journal.sleepDisabledByUs = true
        journal.sleepOffAttempt = attempt
        try h.store.saveState(journal)
        TestReceipts.setRelease(h.receipts, "\(nonce) held\n")
        try h.store.saveSession(session)
        if marker {
            attempt.expires = min(deadline, Int(h.clock.now.addingTimeInterval(AdministratorPrompt.answerWindow).timeIntervalSince1970.rounded(.down)))
            attempt.marker = try h.store.savePendingStart(nonce).text
            journal.sleepOffAttempt = attempt
            try h.store.saveState(journal)
        }
        return attempt
    }

    /// Moves `harness`'s clock (`h`'s unless given) past the answer window
    /// of a start journaled at its current time.
    private func pastExpiry(_ harness: Harness? = nil) {
        (harness ?? h).clock.advance(AdministratorPrompt.answerWindow + 1)
    }

    private var markerExists: Bool { FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path) }

    private var restores: Int { h.guardFake.calls.filter { $0 == "disablesleep 0" }.count }

    /// Settled and nothing resumed: no session in memory or on disk, no
    /// marker, a clean journal.
    private func assertSettledAndNotResumed(_ m: SessionManager, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(m.isActive, "the start never finished, so its session is never resumed", file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), file: file, line: line)
        XCTAssertFalse(markerExists, file: file, line: line)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, file: file, line: line)
    }

    /// Not settled: the start stays recorded with the sleep entry and its
    /// claim, its session is ended rather than resumed, and a start is
    /// refused before its dialog with a reason that contains each of
    /// `saying`.
    private func assertStillRecorded(_ m: SessionManager, _ attempt: SleepOffAttempt, saying: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertFalse(m.isActive, file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), "ended rather than resumed", file: file, line: line)
        let journal = try XCTUnwrap(h.store.loadState(), file: file, line: line)
        XCTAssertEqual(journal.sleepOffAttempt, attempt, file: file, line: line)
        XCTAssertTrue(journal.sleepDisabledByUs, file: file, line: line)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) held\n", "the claim stays", file: file, line: line)
        let shown = h.prompt.shown
        await m.start(duration: 1800)
        XCTAssertFalse(m.isActive, file: file, line: line)
        XCTAssertEqual(h.prompt.shown, shown, "no dialog", file: file, line: line)
        let error = m.lastError ?? ""
        XCTAssertTrue(error.hasPrefix("start refused, nothing changed: an earlier start is still recorded in the journal and is not settled ("), error, file: file, line: line)
        for part in saying {
            XCTAssertTrue(error.contains(part), "\(error) does not say \(part)", file: file, line: line)
        }
    }

    // MARK: Round 21's relaunch findings, and the answer window

    /// Round 21 P1: the app died under the dialog of a start whose session
    /// is still valid, and another tool set SleepDisabled 1 meanwhile.
    /// Before, the relaunch read that 1 as the session's and resumed it,
    /// and its end cleared the other tool's setting. Round 24 F3: while
    /// the dialog can still be answered, a receipt that still holds the
    /// predecessor shows nothing yet, so the session is ended rather than
    /// resumed, nothing is undone, the start stays recorded and starts are
    /// refused. Once the answer window is over, the same receipt shows
    /// the command never turned sleep off: the record and the claim go, and
    /// the 1 is left alone throughout.
    func testARelaunchDoesNotResumeAnUnexpiredStartOnAnotherToolsSetting() async throws {
        let attempt = try journalUnfinishedStart()
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try await assertStillRecorded(m, attempt, saying: ["the password dialog of that start can still be answered until "])
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")

        pastExpiry()
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(SleepOffReceipts.zero) free\n", "the claim is given back")
        XCTAssertTrue(h.guardFake.sleepDisabled, "the other tool's setting is left alone")
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
    }

    /// Round 21 P1, the expired case: before, the relaunch restored from
    /// the journal and cleared the other tool's 1. Now nothing is restored
    /// for a start whose receipt shows it never turned sleep off.
    func testARelaunchDoesNotRestoreAnExpiredStartThatNeverTurnedSleepOff() async throws {
        try journalUnfinishedStart(endsIn: -120)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(SleepOffReceipts.zero) free\n")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
    }

    /// A start that never turned sleep off does not erase a restore an
    /// earlier session still owes. Round 25 R25-2: while the start's
    /// dialog can still be answered, its command may still act, so that
    /// restore waits too, rather than run beside a `disablesleep 1` that
    /// may follow it. The start stays recorded with the entry; once its
    /// window is over the entry stays true and the owed restore runs.
    func testARelaunchKeepsTheRestoreAnEarlierSessionOwes() async throws {
        let attempt = try journalUnfinishedStart(owedBefore: true)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        try await assertStillRecorded(m, attempt, saying: ["the password dialog of that start can still be answered until "])

        pastExpiry()
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// The receipt shows this start's `writing`: its command may have
    /// turned sleep off, whenever this is read. The session is still not
    /// resumed; the start is undone like an end, and the claim goes back
    /// under the start's own nonce, which the receipt now holds.
    func testARelaunchUndoesAStartWhoseReceiptShowsItsCommandWrote() async throws {
        let attempt = try journalUnfinishedStart()
        TestReceipts.write(h.receipts.file, nonce: attempt.nonce, predecessor: attempt.predecessor, word: "writing")
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) free\n")
    }

    /// Round 24 F1: a line another start wrote shows nothing about this
    /// one unless it names this start's predecessor. Another nonce after
    /// another predecessor (a later start's, or a line written some other
    /// way) is undone like an end at once, `refused` or `writing`; it is
    /// never read as "this start never wrote".
    func testARelaunchUndoesAStartWhoseReceiptHoldsALaterStartsLine() async throws {
        for word in ["refused", "writing"] {
            fresh()
            try journalUnfinishedStart()
            TestReceipts.write(h.receipts.file, nonce: UUID().uuidString, predecessor: UUID().uuidString, word: word)
            h.guardFake.sleepDisabled = true
            let m = h.makeManager()

            await m.reconcile()

            try assertSettledAndNotResumed(m)
            XCTAssertEqual(restores, 1, "\(word): \(h.guardFake.calls)")
            XCTAssertFalse(h.guardFake.sleepDisabled, word)
        }
    }

    /// A receipt that is another file now shows nothing about this start:
    /// while a command for it could still write, the start stays recorded
    /// and nothing is undone; after that it is undone like an end.
    func testARelaunchUndoesAStartWhoseReceiptIsAnotherFileOnceItsWindowIsOver() async throws {
        let attempt = try journalUnfinishedStart()
        let copy = h.receipts.folder + "/copy"
        try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: copy))
        XCTAssertEqual(chmod(copy, 0o600), 0)
        XCTAssertEqual(rename(copy, h.receipts.file), 0)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try await assertStillRecorded(m, attempt, saying: ["is not the file it was when the start began; a command for that start could still write until "])
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)

        pastExpiry()
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// Round 24 F2: a missing receipt keeps the start recorded. Nothing is
    /// undone while a command for it could still write. After that sleep
    /// is restored, but the claim cannot be given back without the
    /// receipt's lock, so the record stays and starts are refused at every
    /// run, each trying again, until install.sh makes the receipt again.
    func testAMissingReceiptKeepsTheStartRecorded() async throws {
        let attempt = try journalUnfinishedStart()
        XCTAssertEqual(unlink(h.receipts.file), 0)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try await assertStillRecorded(m, attempt, saying: ["No such file or directory", "a command for that start could still write until "])
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)

        pastExpiry()
        for run in 1...2 {
            await m.reconcile()

            XCTAssertGreaterThanOrEqual(restores, 1, "run \(run): \(h.guardFake.calls)")
            XCTAssertFalse(h.guardFake.sleepDisabled, "run \(run)")
            try await assertStillRecorded(m, attempt, saying: ["the receipt could not be locked to give that start's claim back (", "No such file or directory"])
        }

        // install.sh again: a new receipt, free.
        _ = try TestReceipts.make(in: h.home.root)
        await m.reconcile()

        try assertSettledAndNotResumed(m)
    }

    /// Round 24 F2: a receipt whose lock stays held (by a root command
    /// still in pmset, by another Insomnia folder of this user, or by
    /// anything running as the user) decides nothing. Round 25 R25-2: the
    /// end of the answer window only shows no command for the start can
    /// begin; one already in pmset may still turn sleep off, so nothing is
    /// undone before or after it. The start stays recorded, refusing
    /// starts, until a run gets the lock, and that run settles it: here the
    /// receipt shows the command never turned sleep off, so the 1 stays.
    func testALockedReceiptKeepsTheStartRecordedUntilItIsLetGo() async throws {
        let attempt = try journalUnfinishedStart()
        h.guardFake.sleepDisabled = true
        let held = try await h.receipts.lock(timeout: 0.2)
        defer { held.release() }
        let m = h.makeManager()

        await m.reconcile()

        try await assertStillRecorded(m, attempt, saying: ["\(h.receipts.file) stayed locked for 0 s"])
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)

        pastExpiry()
        await m.reconcile()

        try await assertStillRecorded(m, attempt, saying: ["\(h.receipts.file) stayed locked for 0 s"])
        XCTAssertEqual(restores, 0, "a command already in pmset may still write: \(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)

        held.release()
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(SleepOffReceipts.zero) free\n")
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)
    }

    /// The marker decides nothing any more: replaced by another file with
    /// the same nonce, or already gone (deleted without its lock), a start
    /// whose receipt still holds its predecessor stays recorded while its
    /// dialog can still be answered, and is settled as never having turned
    /// sleep off after that, with no pmset.
    func testTheMarkerDecidesNothing() async throws {
        let cases: [(String, (SleepOffAttempt) throws -> Void)] = [
            ("marker replaced", { attempt in
                let copy = self.h.home.root.appendingPathComponent("marker-copy")
                try Data(attempt.nonce.utf8).write(to: copy)
                XCTAssertEqual(rename(copy.path, self.h.home.paths.pendingStartFile.path), 0)
            }),
            ("marker gone", { _ in try FileManager.default.removeItem(at: self.h.home.paths.pendingStartFile) }),
        ]
        for (name, damage) in cases {
            fresh()
            let attempt = try journalUnfinishedStart()
            try damage(attempt)
            h.guardFake.sleepDisabled = true
            let m = h.makeManager()

            await m.reconcile()

            XCTAssertFalse(m.isActive, name)
            XCTAssertNil(try h.store.loadSession(), name)
            XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, attempt, name)
            XCTAssertEqual(restores, 0, "\(name): \(h.guardFake.calls)")

            pastExpiry()
            await m.reconcile()

            try assertSettledAndNotResumed(m)
            XCTAssertTrue(h.guardFake.sleepDisabled, name)
            XCTAssertEqual(restores, 0, "\(name): \(h.guardFake.calls)")
        }
    }

    /// No marker journaled: the start never showed its dialog, so nothing
    /// ran as root for it, whatever the receipt holds, and it is settled at
    /// once.
    func testARelaunchSettlesAStartThatShowedNoDialogAsNeverTurningSleepOff() async throws {
        let attempt = try journalUnfinishedStart(marker: false)
        TestReceipts.write(h.receipts.file, nonce: attempt.nonce, predecessor: attempt.predecessor, word: "writing")
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
    }

    /// A marker no journaled start accounts for, as a build from before
    /// sleepOffAttempt leaves it: whether its command turned sleep off is
    /// unknown, so the session beside it is never resumed and the journaled
    /// entry is restored. The control, with no marker, resumes.
    func testARelaunchDoesNotResumeASessionBesideAMarkerNoJournaledStartAccountsFor() async throws {
        for marker in [true, false] {
            fresh()
            let session = SessionMath.newSession(now: h.clock.now, duration: 1800, maxDuration: 86400)
            try h.store.saveSession(session)
            var journal = RuntimeState.clean
            journal.sleepDisabledByUs = true
            try h.store.saveState(journal)
            if marker { _ = try h.store.savePendingStart(UUID().uuidString) }
            h.guardFake.sleepDisabled = true
            let m = h.makeManager()

            await m.reconcile()

            if marker {
                try assertSettledAndNotResumed(m)
                XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
            } else {
                XCTAssertTrue(m.isActive, "control: \(m.lastError ?? "")")
                XCTAssertEqual(restores, 0, "control: \(h.guardFake.calls)")
                await m.end(reason: .user)
            }
        }
    }

    // MARK: Settlements that cannot be written (round 24 F4)

    /// The receipt shows this start's `writing`, so it is undone like an
    /// end, but with the app's folder read-only nothing can be removed:
    /// the record and the claim stay, the session is ended rather than
    /// resumed and sleep is restored, a new start is refused before its
    /// dialog, and the next run that can write settles it.
    func testAStartThatMayHaveWrittenIsUndoneWhileItsSettlementCannotBeWritten() async throws {
        let attempt = try journalUnfinishedStart()
        TestReceipts.write(h.receipts.file, nonce: attempt.nonce, predecessor: attempt.predecessor, word: "writing")
        try FileManager.default.removeItem(at: h.home.paths.pendingStartFile)
        FileManager.default.createFile(atPath: h.home.paths.recoveryLock.path, contents: nil)
        try FileManager.default.createDirectory(at: h.home.paths.logs, withIntermediateDirectories: true)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        XCTAssertEqual(chmod(h.home.root.path, 0o500), 0)

        await m.reconcile()

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, attempt, "the record stays")
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) held\n", "and so does the claim")

        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.prompt.shown, 0, "no dialog")
        // With the folder read-only the end of that session is pending
        // too, and that refusal comes first.
        XCTAssertTrue(m.lastError?.hasPrefix("start refused") == true, m.lastError ?? "")

        XCTAssertEqual(chmod(h.home.root.path, 0o755), 0)
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) free\n")
    }

    /// Round 24 F4: the receipt shows the start's command never turned
    /// sleep off and no earlier restore is owed, so no pmset may run for
    /// it: a SleepDisabled 1 now is someone else's. When the settlement
    /// cannot be written the record stays, starts are refused, and still
    /// no pmset runs, at every run, until one can write. With state.json
    /// immutable, session.json goes but the journal keeps the record, and
    /// the claim stays, since the decision is published before the claim
    /// is given back; the error says the session.json was removed only at
    /// the run that removed it. With the
    /// folder read-only, neither the marker, session.json nor the journal
    /// can change (and the end of that session is pending too, which
    /// refuses a start first).
    func testAStartThatNeverWroteRunsNoPmsetWhileItsSettlementCannotBeWritten() async throws {
        let attempt = try journalUnfinishedStart()
        h.guardFake.sleepDisabled = true
        pastExpiry()
        let m = h.makeManager()
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        for run in 1...2 {
            await m.reconcile()

            XCTAssertFalse(m.isActive, "run \(run)")
            XCTAssertNil(try h.store.loadSession(), "run \(run): the start's session.json goes")
            XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, attempt, "run \(run): the record stays")
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) held\n", "run \(run): the claim stays")
            XCTAssertTrue(h.guardFake.sleepDisabled, "run \(run)")
            XCTAssertEqual(restores, 0, "run \(run): \(h.guardFake.calls)")
            let error = m.lastError ?? ""
            XCTAssertTrue(error.hasPrefix("could not settle an earlier start: the journal could not be updated ("), "run \(run): \(error)")
            XCTAssertEqual(error.contains("; session.json of that start was removed. "), run == 1, "run \(run): \(error)")

            await m.start(duration: 1800)

            XCTAssertFalse(m.isActive, "run \(run)")
            XCTAssertEqual(h.prompt.shown, 0, "run \(run): no dialog")
            XCTAssertTrue(m.lastError?.hasPrefix("start refused, nothing changed: an earlier start is still recorded in the journal and is not settled (the journal could not be updated (") == true, "run \(run): \(m.lastError ?? "")")
        }

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(SleepOffReceipts.zero) free\n")

        fresh()
        let second = try journalUnfinishedStart()
        FileManager.default.createFile(atPath: h.home.paths.recoveryLock.path, contents: nil)
        try FileManager.default.createDirectory(at: h.home.paths.logs, withIntermediateDirectories: true)
        h.guardFake.sleepDisabled = true
        pastExpiry()
        let n = h.makeManager()
        XCTAssertEqual(chmod(h.home.root.path, 0o500), 0)

        for run in 1...2 {
            await n.reconcile()

            XCTAssertFalse(n.isActive, "run \(run)")
            XCTAssertTrue(markerExists, "run \(run): the marker could not be removed")
            XCTAssertNotNil(try h.store.loadSession(), "run \(run): nor session.json")
            XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, second, "run \(run): nor the journal")
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(second.nonce) held\n", "run \(run)")
            XCTAssertTrue(h.guardFake.sleepDisabled, "run \(run)")
            XCTAssertEqual(restores, 0, "run \(run): \(h.guardFake.calls)")

            await n.start(duration: 1800)

            XCTAssertFalse(n.isActive, "run \(run)")
            XCTAssertEqual(h.prompt.shown, 0, "run \(run): no dialog")
            XCTAssertTrue(n.lastError?.hasPrefix("start refused") == true, "run \(run): \(n.lastError ?? "")")
        }

        XCTAssertEqual(chmod(h.home.root.path, 0o755), 0)
        await n.reconcile()

        try assertSettledAndNotResumed(n)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
    }

    // MARK: Two Insomnia folders of one user (round 24 F1)

    /// Two Insomnia folders of one user (INSOMNIA_HOME) share the user's
    /// receipt. While a start from one of them is not settled, its claim
    /// refuses a start from the other before anything is written or shown,
    /// so no command for the second start can replace the line the first
    /// one's settlement reads. Once the first folder settles its start, the
    /// second starts.
    func testAStartFromAnotherFolderWaitsForTheClaimToBeSettled() async throws {
        let attempt = try journalUnfinishedStart()
        let b = Harness(sharing: h.receipts)
        others.append(b)
        let mB = b.makeManager()

        await mB.start(duration: 1800)

        XCTAssertFalse(mB.isActive)
        XCTAssertEqual(b.prompt.shown, 0)
        XCTAssertTrue(b.guardFake.calls.isEmpty, "\(b.guardFake.calls)")
        XCTAssertNil(try b.store.loadSession())
        XCTAssertNil(try b.store.loadState()?.sleepOffAttempt)
        XCTAssertEqual(mB.lastError, "start refused, nothing changed: the receipt \(h.receipts.file) cannot be claimed: another Insomnia start (\(attempt.nonce)) has claimed the receipt and is not settled yet. Its own Insomnia folder settles it: open Insomnia from that folder, or wait for its recovery agent, which tries every minute")
        XCTAssertEqual(TestReceipts.text(h.receipts), SleepOffReceipts.initialContent)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) held\n")

        pastExpiry()
        pastExpiry(b)
        let m = h.makeManager()
        await m.reconcile()
        try assertSettledAndNotResumed(m)

        await mB.start(duration: 1800)

        XCTAssertTrue(mB.isActive, mB.lastError ?? "")
        let second = try XCTUnwrap(b.prompt.starts.last)
        XCTAssertEqual(second.predecessor, SleepOffReceipts.zero)
        XCTAssertEqual(TestReceipts.text(h.receipts), "\(second.nonce) \(SleepOffReceipts.zero) writing\n")
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(second.nonce) free\n")
        await mB.end(reason: .user)
        XCTAssertEqual(try b.store.loadState(), RuntimeState.clean)
    }

    /// Round 24 F1, overlapping: something running as the user writes the
    /// release file (0600, the user's) free while a start from one folder
    /// is still under its dialog, and a start from another folder claims
    /// the same line and turns sleep off. The first start's command, which
    /// writes only while the receipt holds the predecessor both claimed,
    /// stops before pmset (exit 8) and leaves the second start's line in
    /// place. The first start's settlement reads that line, which names
    /// the same predecessor, as "never wrote", at once: it is rolled back
    /// with no pmset, and the second start's session and claim are left
    /// alone.
    func testTwoStartsThatClaimTheSameLineCannotBothWrite() async throws {
        let attempt = try journalUnfinishedStart()
        let b = Harness(sharing: h.receipts)
        others.append(b)
        TestReceipts.setRelease(h.receipts, "\(attempt.predecessor) free\n")
        let mB = b.makeManager()

        await mB.start(duration: 1800)

        XCTAssertTrue(mB.isActive, mB.lastError ?? "")
        let second = try XCTUnwrap(b.prompt.starts.last)
        XCTAssertEqual(second.predecessor, attempt.predecessor)
        let line = "\(second.nonce) \(attempt.predecessor) writing\n"
        XCTAssertEqual(TestReceipts.text(h.receipts), line)

        let dir = h.home.root.appendingPathComponent("late-answer")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let late = try runRootCommand(marker: h.home.paths.pendingStartFile, nonce: attempt.nonce, receipts: h.receipts, predecessor: attempt.predecessor, receiptIdentity: attempt.receipt, in: dir)
        XCTAssertEqual(late.status, 8, late.stderr)
        XCTAssertEqual(late.pmsetCalls, [])
        XCTAssertEqual(TestReceipts.text(h.receipts), line, "the second start's line stays")

        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertTrue(mB.isActive)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(second.nonce) free\n", "a settlement gives back no claim but its own")
        await mB.end(reason: .user)
    }

    // MARK: Round 25: a busy receipt, and settlements cut short

    /// Round 25 R25-2: a busy receipt holds back every sleep undo for the
    /// start, whether or not its answer window is over and whether or not
    /// an earlier session owes a restore. The end of the window shows no
    /// command for the start can begin, not that one already in pmset has
    /// exited. The record, the entry and the claim stay at every run, and
    /// starts are refused, while undo that does not touch sleep (frozen
    /// processes, Low Power Mode, the volume) runs all the same. Once the
    /// lock is free the receipt decides: here it shows the command never
    /// turned sleep off, so only a restore that was owed runs, once the
    /// window is over.
    func testABusyReceiptHoldsTheSleepUndoWhateverTheWindowAndTheOwedRestore() async throws {
        for (expired, owed) in [(false, false), (true, false), (false, true), (true, true)] {
            let name = "expired \(expired), owed \(owed)"
            fresh()
            let attempt = try journalUnfinishedStart(owedBefore: owed)
            var journal = try XCTUnwrap(h.store.loadState())
            journal.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5)]
            journal.lowPowerSetByUs = true
            journal.savedOutputVolume = 0.6
            journal.savedMuted = false
            try h.store.saveState(journal)
            h.procs.stoppedNow = [111]
            if expired { pastExpiry() }
            h.guardFake.sleepDisabled = true
            let held = try await h.receipts.lock(timeout: 0.2)
            let m = h.makeManager()

            for run in 1...2 {
                await m.reconcile()

                try await assertStillRecorded(m, attempt, saying: ["\(h.receipts.file) stayed locked for 0 s"])
                XCTAssertEqual(restores, 0, "\(name), run \(run): \(h.guardFake.calls)")
                XCTAssertTrue(h.guardFake.sleepDisabled, "\(name), run \(run)")
            }
            XCTAssertEqual(h.procs.resumed, [[111]], name)
            XCTAssertTrue(h.guardFake.calls.contains("lowpowermode 0"), "\(name): \(h.guardFake.calls)")
            XCTAssertEqual(h.audio.applied.count, 1, name)
            let left = try XCTUnwrap(h.store.loadState())
            XCTAssertEqual(left.frozenProcesses, [], name)
            XCTAssertFalse(left.lowPowerSetByUs, name)
            XCTAssertNil(left.savedOutputVolume, name)

            held.release()
            if !expired {
                await m.reconcile()

                try await assertStillRecorded(m, attempt, saying: ["the password dialog of that start can still be answered until "])
                XCTAssertEqual(restores, 0, "\(name): \(h.guardFake.calls)")
                pastExpiry()
            }
            await m.reconcile()

            try assertSettledAndNotResumed(m)
            XCTAssertEqual(restores, owed ? 1 : 0, "\(name): \(h.guardFake.calls)")
            XCTAssertEqual(h.guardFake.sleepDisabled, !owed, name)
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(SleepOffReceipts.zero) free\n", name)
        }
    }

    /// Round 25 R25-1: a settlement journals its decision, with the record
    /// marked settled, before it gives the claim back. When the claim
    /// cannot be given back (the release file is read-only here) the
    /// decision stays with the claim still held, so no start from another
    /// Insomnia folder can add a receipt line meanwhile. Starts are refused
    /// in both folders and, for a start that never wrote, no pmset runs,
    /// at every run. The first run that can write the release file finishes
    /// the settlement without reading the receipt again, and the other
    /// folder can start.
    func testASettlementThatCannotGiveTheClaimBackKeepsItsDecision() async throws {
        let attempt = try journalUnfinishedStart()
        pastExpiry()
        h.guardFake.sleepDisabled = true
        let b = Harness(sharing: h.receipts)
        others.append(b)
        pastExpiry(b)
        let mB = b.makeManager()
        XCTAssertEqual(chmod(h.receipts.releaseFile, 0o400), 0)
        defer { chmod(h.receipts.releaseFile, 0o600) }
        var settled = attempt
        settled.settled = true
        let m = h.makeManager()

        for run in 1...2 {
            await m.reconcile()

            XCTAssertFalse(m.isActive, "run \(run)")
            XCTAssertNil(try h.store.loadSession(), "run \(run)")
            let journal = try XCTUnwrap(h.store.loadState())
            XCTAssertEqual(journal.sleepOffAttempt, settled, "run \(run): the decision is kept")
            XCTAssertFalse(journal.sleepDisabledByUs, "run \(run): the command never turned sleep off")
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) held\n", "run \(run): the claim stays")
            XCTAssertEqual(restores, 0, "run \(run): \(h.guardFake.calls)")
            XCTAssertTrue(h.guardFake.sleepDisabled, "run \(run)")
            let error = m.lastError ?? ""
            let opening = run == 1 ? "settled an earlier start, but " : "an earlier start is settled, but "
            XCTAssertTrue(error.hasPrefix(opening + "its claim on the receipt could not be given back ("), "run \(run): \(error)")

            await m.start(duration: 1800)

            XCTAssertFalse(m.isActive, "run \(run)")
            XCTAssertEqual(h.prompt.shown, 0, "run \(run): no dialog")
            let refusal = m.lastError ?? ""
            XCTAssertTrue(refusal.hasPrefix("start refused, nothing changed: an earlier start is still recorded in the journal (it is settled, but its claim on the receipt could not be given back ("), "run \(run): \(refusal)")
            XCTAssertTrue(refusal.hasSuffix("Starts are refused until a later run gives its claim on the receipt back"), "run \(run): \(refusal)")

            await mB.start(duration: 1800)

            XCTAssertFalse(mB.isActive, "run \(run)")
            XCTAssertEqual(b.prompt.shown, 0, "run \(run)")
            XCTAssertTrue(mB.lastError?.contains("another Insomnia start (\(attempt.nonce)) has claimed the receipt") == true, "run \(run): \(mB.lastError ?? "")")
        }
        XCTAssertEqual(TestReceipts.text(h.receipts), SleepOffReceipts.initialContent, "no line was added")

        XCTAssertEqual(chmod(h.receipts.releaseFile, 0o600), 0)
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(SleepOffReceipts.zero) free\n")
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)

        await mB.start(duration: 1800)

        XCTAssertTrue(mB.isActive, mB.lastError ?? "")
        await mB.end(reason: .user)
    }

    /// The same for a start whose receipt shows its command may have
    /// turned sleep off: the decision keeps the entry, so the restore runs
    /// and clears it once, while the settled record and its claim stay and
    /// refuse starts until the claim can be given back.
    func testASettledStartThatMayHaveWrittenIsRestoredWhileItsClaimCannotBeGivenBack() async throws {
        let attempt = try journalUnfinishedStart()
        TestReceipts.write(h.receipts.file, nonce: attempt.nonce, predecessor: attempt.predecessor, word: "writing")
        h.guardFake.sleepDisabled = true
        XCTAssertEqual(chmod(h.receipts.releaseFile, 0o400), 0)
        defer { chmod(h.receipts.releaseFile, 0o600) }
        var settled = attempt
        settled.settled = true
        let m = h.makeManager()

        for run in 1...2 {
            await m.reconcile()

            XCTAssertFalse(m.isActive, "run \(run)")
            XCTAssertNil(try h.store.loadSession(), "run \(run)")
            XCTAssertEqual(restores, 1, "run \(run): \(h.guardFake.calls)")
            XCTAssertFalse(h.guardFake.sleepDisabled, "run \(run)")
            let journal = try XCTUnwrap(h.store.loadState())
            XCTAssertEqual(journal.sleepOffAttempt, settled, "run \(run)")
            XCTAssertFalse(journal.sleepDisabledByUs, "run \(run): restored and cleared")
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) held\n", "run \(run)")

            await m.start(duration: 1800)

            XCTAssertFalse(m.isActive, "run \(run)")
            XCTAssertEqual(h.prompt.shown, 0, "run \(run)")
            XCTAssertTrue(m.lastError?.hasPrefix("start refused, nothing changed: an earlier start is still recorded in the journal (it is settled, but ") == true, "run \(run): \(m.lastError ?? "")")
        }

        XCTAssertEqual(chmod(h.receipts.releaseFile, 0o600), 0)
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) free\n")
    }

    /// Round 25 R25-1, the crash gap: the app died after a settlement
    /// journaled its decision, with the claim still held, or given back
    /// already but the record not removed yet. Once the claim is back,
    /// starts from another Insomnia folder of this user can claim the
    /// receipt and leave their own lines: here none, one or two `refused`
    /// lines, each settled in its own folder. After two, the receipt alone
    /// no longer shows that this start never wrote. A settled record is
    /// never read against the receipt again: the journaled decision
    /// stands. Never wrote, with nothing owed, leaves the SleepDisabled 1
    /// alone; never wrote behind an owed restore, and may have written,
    /// restore once.
    func testAJournaledDecisionSurvivesACrashAndLaterStarts() async throws {
        let decisions: [(name: String, owedBefore: Bool, owes: Bool)] = [
            ("never wrote", false, false),
            ("never wrote behind an owed restore", true, true),
            ("may have written", false, true),
        ]
        for decision in decisions {
            for (givenBack, later) in [(false, 0), (true, 0), (true, 1), (true, 2)] {
                let name = "\(decision.name), claim \(givenBack ? "given back" : "held"), \(later) later starts"
                fresh()
                let attempt = try journalUnfinishedStart(owedBefore: decision.owedBefore)
                pastExpiry()
                // What the settlement wrote before the app died.
                try h.store.deleteSession()
                var settled = attempt
                settled.settled = true
                var journal = try XCTUnwrap(h.store.loadState())
                journal.sleepOffAttempt = settled
                journal.sleepDisabledByUs = decision.owes
                try h.store.saveState(journal)
                if givenBack {
                    let held = try await h.receipts.lock(timeout: 0.2)
                    XCTAssertTrue(try h.receipts.release(attempt.nonce, under: held), name)
                    held.release()
                } else {
                    let b = Harness(sharing: h.receipts)
                    others.append(b)
                    let mB = b.makeManager()
                    await mB.start(duration: 1800)
                    XCTAssertFalse(mB.isActive, name)
                    XCTAssertEqual(b.prompt.shown, 0, name)
                }
                var lastNonce = SleepOffReceipts.zero
                for _ in 0..<later {
                    let b = Harness(sharing: h.receipts)
                    others.append(b)
                    let next = try journalUnfinishedStart(in: b)
                    TestReceipts.write(h.receipts.file, nonce: next.nonce, predecessor: next.predecessor, word: "refused")
                    await b.makeManager().reconcile()
                    XCTAssertEqual(try b.store.loadState(), RuntimeState.clean, name)
                    XCTAssertEqual(TestReceipts.release(h.receipts), "\(next.nonce) free\n", name)
                    lastNonce = next.nonce
                }
                let line = TestReceipts.text(h.receipts)
                if later == 2 {
                    let held = try await h.receipts.lock(timeout: 0.2)
                    XCTAssertNotEqual(h.receipts.verdict(for: attempt, lock: .success(held), now: Self.seconds(h)), .neverWrote, "\(name): the receipt alone no longer shows it")
                    held.release()
                }
                h.guardFake.sleepDisabled = true
                let m = h.makeManager()

                await m.reconcile()

                try assertSettledAndNotResumed(m)
                XCTAssertEqual(restores, decision.owes ? 1 : 0, "\(name): \(h.guardFake.calls)")
                XCTAssertEqual(h.guardFake.sleepDisabled, !decision.owes, name)
                XCTAssertEqual(TestReceipts.text(h.receipts), line, "\(name): the receipt is not touched")
                XCTAssertEqual(TestReceipts.release(h.receipts), "\(lastNonce) free\n", name)
            }
        }
    }

    private static func seconds(_ h: Harness) -> Int { Int(h.clock.now.timeIntervalSince1970.rounded(.down)) }

    /// A settled record whose claim went back but which cannot be removed
    /// from the journal (state.json is immutable here) refuses starts at
    /// every run, with no pmset for a start that never wrote, until a run
    /// can remove it.
    func testASettledRecordThatCannotBeRemovedRefusesStartsUntilItIs() async throws {
        let attempt = try journalUnfinishedStart()
        pastExpiry()
        try h.store.deleteSession()
        var settled = attempt
        settled.settled = true
        var journal = try XCTUnwrap(h.store.loadState())
        journal.sleepOffAttempt = settled
        journal.sleepDisabledByUs = false
        try h.store.saveState(journal)
        let held = try await h.receipts.lock(timeout: 0.2)
        XCTAssertTrue(try h.receipts.release(attempt.nonce, under: held))
        held.release()
        h.guardFake.sleepDisabled = true
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        let m = h.makeManager()

        for run in 1...2 {
            await m.reconcile()

            XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, settled, "run \(run)")
            XCTAssertEqual(restores, 0, "run \(run): \(h.guardFake.calls)")
            XCTAssertTrue(h.guardFake.sleepDisabled, "run \(run)")
            XCTAssertTrue(m.lastError?.hasPrefix("an earlier start is settled, but its settled record could not be removed from the journal (") == true, "run \(run): \(m.lastError ?? "")")

            await m.start(duration: 1800)

            XCTAssertFalse(m.isActive, "run \(run)")
            XCTAssertEqual(h.prompt.shown, 0, "run \(run)")
            XCTAssertTrue(m.lastError?.hasPrefix("start refused, nothing changed: an earlier start is still recorded in the journal (it is settled, but its settled record could not be removed from the journal (") == true, "run \(run): \(m.lastError ?? "")")
        }

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertTrue(h.guardFake.sleepDisabled)
    }

    // MARK: Independent27 F4: the session of a settled start that went through

    /// What a start that turned sleep off leaves when the app dies after
    /// finishAttempt published its settlement and before the claim went
    /// back and the record went: the session it began, ending `endsIn`
    /// seconds after the harness clock, the receipt's `writing` line for
    /// it, no marker, the sleep entry, the record marked settled, and the
    /// claim, still held or, with `givenBack`, given back already.
    /// SleepDisabled is 1.
    private func journalSettledStart(endsIn: TimeInterval = 1800, givenBack: Bool) async throws -> (attempt: SleepOffAttempt, session: Session) {
        var attempt = try journalUnfinishedStart(endsIn: endsIn)
        let session = try XCTUnwrap(h.store.loadSession())
        TestReceipts.write(h.receipts.file, nonce: attempt.nonce, predecessor: attempt.predecessor, word: "writing")
        try FileManager.default.removeItem(at: h.home.paths.pendingStartFile)
        attempt.settled = true
        var journal = try XCTUnwrap(h.store.loadState())
        journal.sleepOffAttempt = attempt
        try h.store.saveState(journal)
        if givenBack {
            let held = try await h.receipts.lock(timeout: 0.2)
            XCTAssertTrue(try h.receipts.release(attempt.nonce, under: held))
            held.release()
        }
        h.guardFake.sleepDisabled = true
        return (attempt, session)
    }

    /// What keeps a settlement from finishing.
    private enum CleanupFault: String, CaseIterable {
        case receiptLocked = "another start or recovery holds the receipt's lock"
        case releaseReadOnly = "the release file is read-only"
        case releaseDamaged = "the release file is damaged"
        case journalImmutable = "state.json cannot be replaced"
    }

    /// Puts `fault` in place in `h` and returns what takes it away, which
    /// may run more than once.
    private func impose(_ fault: CleanupFault) async throws -> () -> Void {
        switch fault {
        case .receiptLocked:
            let held = try await h.receipts.lock(timeout: 0.2)
            return { held.release() }
        case .releaseReadOnly:
            let file = h.receipts.releaseFile
            XCTAssertEqual(chmod(file, 0o400), 0)
            return { chmod(file, 0o600) }
        case .releaseDamaged:
            let file = URL(fileURLWithPath: h.receipts.releaseFile)
            let before = try Data(contentsOf: file)
            try Data(repeating: 0x78, count: before.count).write(to: file)
            return {
                do { try before.write(to: file) } catch { XCTFail("the release file could not be put back: \(error)") }
            }
        case .journalImmutable:
            let file = h.home.paths.stateFile.path
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
            return { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
        }
    }

    /// Independent27 F4 (round 28): a start that turned sleep off
    /// published its settlement, and the app died before the claim went
    /// back or the record went. The relaunch cannot finish either (each
    /// `CleanupFault`, with the claim still held or given back already).
    /// Before, it ended that session as if it had never begun. It now
    /// resumes it as it resumes any session: the agent is armed, sleep
    /// must still be off, the deadline is kept, and no pmset writes and no
    /// dialog shows. The decision stays journaled with the sleep entry,
    /// and the receipt is never read against it again. Every later
    /// transaction tries the cleanup again. When the fault goes while the
    /// session runs, the next transaction (an extend) finishes it.
    /// Otherwise the session's end restores sleep once, and Starts are
    /// refused until a run can finish it.
    func testTheSessionOfASettledStartThatWentThroughResumesWhileItsCleanupFails() async throws {
        for fault in CleanupFault.allCases {
            for givenBack in [false, true] where !(givenBack && fault == .releaseReadOnly) {
                let name = "\(fault.rawValue), claim \(givenBack ? "given back" : "held")"
                // The end's journal write needs state.json, and finishing
                // needs the claim held, to show the refusal.
                let endsFirst = !givenBack && fault != .journalImmutable
                fresh()
                let (attempt, session) = try await journalSettledStart(givenBack: givenBack)
                let receipt = TestReceipts.text(h.receipts)
                let clear = try await impose(fault)
                defer { clear() }
                let release = TestReceipts.release(h.receipts)
                let m = h.makeManager()

                await m.reconcile()

                XCTAssertTrue(m.isActive, "\(name): \(m.lastError ?? "")")
                XCTAssertEqual(m.session, session, "\(name): the deadline is kept")
                XCTAssertEqual(h.backstop.arms, 1, name)
                XCTAssertEqual(h.guardFake.calls, ["pmset -g"], "\(name): sleep is read, never written")
                XCTAssertEqual(h.prompt.shown, 0, name)
                let journal = try XCTUnwrap(h.store.loadState())
                XCTAssertEqual(journal.sleepOffAttempt, attempt, "\(name): the decision stays")
                XCTAssertTrue(journal.sleepDisabledByUs, name)
                XCTAssertEqual(try h.store.loadSession(), session, name)
                XCTAssertEqual(TestReceipts.text(h.receipts), receipt, "\(name): the receipt is not touched")
                XCTAssertEqual(TestReceipts.release(h.receipts), fault == .journalImmutable ? "\(attempt.nonce) free\n" : release, "\(name): the claim goes back only when the release file can be written")

                if endsFirst {
                    await m.end(reason: .user)

                    XCTAssertFalse(m.isActive, name)
                    XCTAssertEqual(restores, 1, "\(name): \(h.guardFake.calls)")
                    XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, attempt, "\(name): still recorded")

                    await m.start(duration: 1800)

                    XCTAssertFalse(m.isActive, name)
                    XCTAssertEqual(h.prompt.shown, 0, "\(name): no dialog")
                    XCTAssertTrue(m.lastError?.hasPrefix("start refused, nothing changed: an earlier start is still recorded in the journal (it is settled, but ") == true, "\(name): \(m.lastError ?? "")")

                    clear()
                    await m.start(duration: 1800)

                    XCTAssertTrue(m.isActive, "\(name): \(m.lastError ?? "")")
                    XCTAssertEqual(h.prompt.shown, 1, name)
                } else {
                    clear()
                    await m.extend(by: 600)

                    XCTAssertTrue(m.isActive, name)
                    XCTAssertEqual(m.session?.endsAt, session.endsAt.addingTimeInterval(600), name)
                    let after = try XCTUnwrap(h.store.loadState())
                    XCTAssertNil(after.sleepOffAttempt, "\(name): the next transaction finishes it")
                    XCTAssertTrue(after.sleepDisabledByUs, name)
                    XCTAssertEqual(TestReceipts.release(h.receipts), "\(attempt.nonce) free\n", name)
                    XCTAssertEqual(h.guardFake.calls, ["pmset -g"], name)

                    await m.end(reason: .user)

                    XCTAssertEqual(restores, 1, "\(name): \(h.guardFake.calls)")
                    await m.start(duration: 1800)
                    XCTAssertTrue(m.isActive, "\(name): \(m.lastError ?? "")")
                }
                await m.end(reason: .user)
            }
        }
    }

    /// The same start's claim went back before the app died, and a start
    /// in another Insomnia folder of this user has claimed the receipt
    /// since. The relaunch resumes the session, and finishing the
    /// settlement leaves the other start's claim alone: the release file
    /// no longer shows this start's nonce, so nothing is given back, and
    /// the record goes. With state.json immutable the record stays, and
    /// the other claim is still left alone.
    func testTheSessionOfASettledStartResumesBesideAnotherFoldersLaterClaim() async throws {
        for immutable in [false, true] {
            fresh()
            let (attempt, session) = try await journalSettledStart(givenBack: true)
            let b = Harness(sharing: h.receipts)
            others.append(b)
            let other = try journalUnfinishedStart(in: b)
            let receipt = TestReceipts.text(h.receipts)
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(other.nonce) held\n")
            var clear: () -> Void = {}
            if immutable { clear = try await impose(.journalImmutable) }
            defer { clear() }
            let m = h.makeManager()

            await m.reconcile()

            XCTAssertTrue(m.isActive, "immutable \(immutable): \(m.lastError ?? "")")
            XCTAssertEqual(m.session, session, "immutable \(immutable)")
            XCTAssertEqual(h.guardFake.calls, ["pmset -g"], "immutable \(immutable)")
            XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, immutable ? attempt : nil, "immutable \(immutable)")
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(other.nonce) held\n", "immutable \(immutable): the other start's claim is left alone")
            XCTAssertEqual(TestReceipts.text(h.receipts), receipt, "immutable \(immutable)")

            clear()
            await m.end(reason: .user)
        }
    }

    /// Only that start's own session resumes beside a settled record: the
    /// one whose first end is the start's deadline, extended or not, with
    /// the sleep entry journaled. Another session (one a rolled-back start
    /// put back, or one ending a second earlier), an extended one whose
    /// first end is two seconds off, or a journal with no sleep entry ends
    /// it as before. Sleep turned back on ends it as it ends any resumed
    /// session, and an expired one is restored. The claim cannot be given
    /// back throughout, so the record stays.
    func testOnlyTheSettledStartsOwnSessionResumes() async throws {
        let cases: [(name: String, resumes: Bool, restores: Int, change: (inout Session, inout RuntimeState) -> Void)] = [
            ("its own session", true, 0, { _, _ in }),
            ("its own, extended by 900 s", true, 0, { s, _ in
                s.endsAt = s.endsAt.addingTimeInterval(900)
                s.extensions = [900]
            }),
            ("its own, extended by 899.6 s, cut short at the maximum", true, 0, { s, _ in
                s.endsAt = s.endsAt.addingTimeInterval(899)
                s.extensions = [899.6]
            }),
            ("another session, ending 600 s later", false, 1, { s, _ in s.endsAt = s.endsAt.addingTimeInterval(600) }),
            ("another session, ending a second earlier", false, 1, { s, _ in s.endsAt = s.endsAt.addingTimeInterval(-1) }),
            ("extended by 900 s, its first end two seconds off", false, 1, { s, _ in
                s.endsAt = s.endsAt.addingTimeInterval(902)
                s.extensions = [900]
            }),
            ("no sleep entry", false, 0, { _, j in j.sleepDisabledByUs = false }),
        ]
        for c in cases {
            fresh()
            let (attempt, original) = try await journalSettledStart(givenBack: false)
            var session = original
            var journal = try XCTUnwrap(h.store.loadState())
            c.change(&session, &journal)
            try h.store.saveSession(session)
            try h.store.saveState(journal)
            let saved = try XCTUnwrap(h.store.loadSession())
            let clear = try await impose(.releaseReadOnly)
            defer { clear() }
            let m = h.makeManager()

            await m.reconcile()

            XCTAssertEqual(m.isActive, c.resumes, "\(c.name): \(m.lastError ?? "")")
            XCTAssertEqual(try h.store.loadSession(), c.resumes ? saved : nil, c.name)
            XCTAssertEqual(restores, c.restores, "\(c.name): \(h.guardFake.calls)")
            XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), c.name)
            XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, attempt, "\(c.name): the record stays")
            if c.resumes {
                XCTAssertEqual(m.session, saved, c.name)
                await m.end(reason: .user)
            }
        }

        // Sleep turned back on while Insomnia was not running.
        fresh()
        let (attempt, _) = try await journalSettledStart(givenBack: false)
        h.guardFake.sleepDisabled = false
        var clear = try await impose(.releaseReadOnly)
        let m = h.makeManager()
        await m.reconcile()
        clear()
        XCTAssertFalse(m.isActive, m.lastError ?? "")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, attempt, "the record stays")

        // Expired: restored as any expired session is.
        fresh()
        let (expired, _) = try await journalSettledStart(endsIn: 60, givenBack: false)
        h.clock.advance(61)
        clear = try await impose(.releaseReadOnly)
        defer { clear() }
        let late = h.makeManager()
        await late.reconcile()
        XCTAssertFalse(late.isActive)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
        XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt, expired, "the record stays")
    }

    /// A claim that cannot be written (the release file is read-only here)
    /// rolls the start back before any dialog: the journal goes back as it
    /// was, with the record marked settled, the release file, which still
    /// shows the receipt free, is left alone, and the record goes. No
    /// pmset runs.
    func testAStartWhoseClaimCannotBeWrittenIsRolledBackBeforeItsDialog() async throws {
        XCTAssertEqual(chmod(h.receipts.releaseFile, 0o400), 0)
        defer { chmod(h.receipts.releaseFile, 0o600) }
        let m = h.makeManager()

        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertTrue(h.guardFake.calls.isEmpty, "\(h.guardFake.calls)")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(markerExists)
        XCTAssertEqual(TestReceipts.release(h.receipts), SleepOffReceipts.initialRelease)
        XCTAssertTrue(m.lastError?.hasPrefix("could not claim the receipt: ") == true, m.lastError ?? "")
    }

    /// A start whose dialog was cancelled is rolled back, but its claim
    /// cannot be given back (the release file turns read-only while the
    /// dialog is up): the journal is back as it was, with the record
    /// marked settled and the claim held, and starts are refused until a
    /// run can give the claim back. Then a start runs.
    func testARolledBackStartWhoseClaimCannotBeGivenBackStaysSettled() async throws {
        let release = h.receipts.releaseFile
        h.prompt.onShow = { _ in chmod(release, 0o400) }
        h.prompt.mode = .cancel
        defer { chmod(release, 0o600) }
        let m = h.makeManager()

        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        let nonce = try XCTUnwrap(h.prompt.starts.last?.nonce)
        let journal = try XCTUnwrap(h.store.loadState())
        XCTAssertEqual(journal.sleepOffAttempt?.nonce, nonce)
        XCTAssertEqual(journal.sleepOffAttempt?.settled, true)
        XCTAssertFalse(journal.sleepDisabledByUs, "the journal is back as it was")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(markerExists)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(nonce) held\n")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "the dialog, and no undo")
        XCTAssertTrue(m.lastError?.hasPrefix("the failed start was rolled back, but its claim on the receipt could not be given back (") == true, m.lastError ?? "")

        h.prompt.onShow = nil
        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.prompt.shown, 1, "no second dialog")
        XCTAssertTrue(m.lastError?.hasPrefix("start refused, nothing changed: an earlier start is still recorded in the journal (it is settled, but its claim on the receipt could not be given back (") == true, m.lastError ?? "")

        XCTAssertEqual(chmod(release, 0o600), 0)
        h.prompt.mode = .succeed
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        XCTAssertEqual(h.prompt.starts.last?.predecessor, SleepOffReceipts.zero)
        await m.end(reason: .user)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    // MARK: Round 28 F7

    /// Round 27 F7, the live path. Another tool sets 1 right after the
    /// command's record, its second read finds it, the `refused` over the
    /// record cannot be written, and the command stops with 6. The
    /// rollback cannot be journaled either (state.json is immutable from
    /// the dialog on), so the start stays recorded, and the receipt still
    /// shows its `writing`. Before, the next transaction settled the start
    /// from that line alone, undid it and set the other tool's 1 to 0,
    /// though this process had received the refusal. Now that refusal stays
    /// the verdict in this process: while the journal cannot be written no
    /// pmset runs, and once it can, the start is settled as one that never
    /// turned sleep off, the claim goes back and the 1 stays.
    ///
    /// The limit, as a control: a relaunch never saw that status. It reads
    /// `writing`, undoes the start like an end and sets the 1 to 0, as
    /// backstop.sh and uninstall.sh would.
    func testARefusalWhoseRollbackCannotBeJournaledStaysARefusalInThisProcess() async throws {
        for relaunch in [false, true] {
            if relaunch { fresh() }
            let label = relaunch ? "relaunch" : "same process"
            let file = h.home.paths.stateFile.path
            let guardFake = h.guardFake
            h.prompt.afterRecord = { guardFake.sleepDisabled = true }
            h.prompt.refusedLineFails = true
            h.prompt.onShow = { _ in try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file) }
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }
            let m = h.makeManager()

            await m.start(duration: 1800)

            XCTAssertFalse(m.isActive, label)
            let start = try XCTUnwrap(h.prompt.starts.last, label)
            XCTAssertEqual(TestReceipts.text(h.receipts), "\(start.nonce) \(start.predecessor) writing\n", "\(label): the record's writing stays")
            XCTAssertTrue(h.guardFake.sleepDisabled, "\(label): the other tool's 1")
            XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "\(label): the dialog, and no undo")
            XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt?.nonce, start.nonce, "\(label): the start stays recorded")
            XCTAssertEqual(TestReceipts.release(h.receipts), "\(start.nonce) held\n", "\(label): and keeps its claim")
            XCTAssertNil(try h.store.loadSession(), label)
            let error = m.lastError ?? ""
            XCTAssertTrue(error.hasPrefix("the failed start stays recorded in the journal: the journal could not be updated ("), "\(label): \(error)")

            if !relaunch {
                await m.reconcile()

                XCTAssertTrue(h.guardFake.sleepDisabled, "while the journal cannot be written")
                XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
                XCTAssertEqual(try h.store.loadState()?.sleepOffAttempt?.nonce, start.nonce, "the record stays")
                XCTAssertTrue(m.lastError?.hasPrefix("could not settle an earlier start: the journal could not be updated (") == true, m.lastError ?? "")

                try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
                await m.reconcile()

                try assertSettledAndNotResumed(m)
                XCTAssertTrue(h.guardFake.sleepDisabled, "the other tool's 1 stays")
                XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
                XCTAssertEqual(TestReceipts.release(h.receipts), "\(start.nonce) free\n")
            } else {
                try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
                let n = h.makeManager()
                await n.reconcile()

                try assertSettledAndNotResumed(n)
                XCTAssertEqual(restores, 1, "\(h.guardFake.calls)")
                XCTAssertFalse(h.guardFake.sleepDisabled, "the limit: the relaunch reads writing and sets the other tool's 1 to 0")
                XCTAssertEqual(TestReceipts.release(h.receipts), "\(start.nonce) free\n")
            }
        }
    }

    // MARK: A new attempt and a replay

    /// A `writing` left by an earlier start is not this start's: a start
    /// whose dialog fails before its command's record is rolled back with
    /// nothing undone, and the claim goes back.
    func testAnEarlierStartsWritingDoesNotCountForANewStart() async throws {
        let earlier = UUID().uuidString
        TestReceipts.write(h.receipts.file, nonce: earlier, word: "writing")
        TestReceipts.setRelease(h.receipts, "\(earlier) free\n")
        h.prompt.mode = .fail
        let m = h.makeManager()

        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(restores, 0, "\(h.guardFake.calls)")
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(earlier) free\n")
        XCTAssertTrue(h.notifier.posts.last?.body.hasSuffix("The receipt shows that the command behind the password dialog never turned sleep off.") == true, h.notifier.posts.last?.body ?? "")
    }

    /// The dialog of a start that was settled is answered late: with no
    /// marker, lockf stops it first; under another start's marker the
    /// command finds another nonce and exits 3. Neither reads or writes
    /// pmset or the receipt.
    func testAReplayedDialogWritesNothing() async throws {
        let attempt = try journalUnfinishedStart()
        pastExpiry()
        let m = h.makeManager()
        await m.reconcile()
        try assertSettledAndNotResumed(m)
        let receipt = TestReceipts.text(h.receipts)

        for name in ["replay-absent", "replay-other"] {
            try FileManager.default.createDirectory(at: h.home.root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let absent = try runRootCommand(marker: h.home.paths.pendingStartFile, nonce: attempt.nonce, receipts: h.receipts, in: h.home.root.appendingPathComponent("replay-absent"))
        XCTAssertNotEqual(absent.status, 0, absent.stderr)
        XCTAssertEqual(absent.pmsetCalls, [])
        XCTAssertEqual(TestReceipts.text(h.receipts), receipt)

        _ = try h.store.savePendingStart(UUID().uuidString)
        let other = try runRootCommand(marker: h.home.paths.pendingStartFile, nonce: attempt.nonce, receipts: h.receipts, in: h.home.root.appendingPathComponent("replay-other"))
        XCTAssertEqual(other.status, 3, other.stderr)
        XCTAssertEqual(other.pmsetCalls, [])
        XCTAssertEqual(TestReceipts.text(h.receipts), receipt)
    }

    // MARK: Trust

    /// The receipt as the app ships it trusts root alone, so a receipt the
    /// user owns (all a process running as the user could make) stops a
    /// start before anything is written or shown.
    func testAStartRefusesAReceiptTheUserOwnsUnderTheShippedTrust() async throws {
        let m = h.makeManager(receipts: SleepOffReceipts(folder: h.receipts.folder, owners: [0], user: getuid()))

        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertTrue(h.guardFake.calls.isEmpty, "\(h.guardFake.calls)")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(markerExists)
        XCTAssertNil(try h.store.loadState()?.sleepOffAttempt)
        XCTAssertTrue(m.lastError?.contains("is missing or unsafe") == true, m.lastError ?? "")
        XCTAssertTrue(m.lastError?.contains("not root") == true, m.lastError ?? "")
        XCTAssertEqual(TestReceipts.release(h.receipts), SleepOffReceipts.initialRelease, "nothing claimed")
    }

    /// Control: a normal start journals its attempt and claims the receipt
    /// only while the dialog runs, and a normal end restores.
    func testANormalStartAndEndLeaveNoRecord() async throws {
        let m = h.makeManager()
        let atShow = JournalAtShow()
        let releaseAtShow = JournalAtShow()
        let stateFile = h.home.paths.stateFile
        let releaseFile = URL(fileURLWithPath: h.receipts.releaseFile)
        h.prompt.onShow = { _ in
            atShow.data = try? Data(contentsOf: stateFile)
            releaseAtShow.data = try? Data(contentsOf: releaseFile)
        }

        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        let nonce = try XCTUnwrap(h.prompt.starts.last?.nonce)
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(atShow.data)) as? [String: Any])
        let attempt = try XCTUnwrap(journal["sleepOffAttempt"] as? [String: Any], "journaled before the dialog")
        XCTAssertNotNil(attempt["marker"] as? String, "with its marker")
        XCTAssertEqual(attempt["predecessor"] as? String, SleepOffReceipts.zero)
        XCTAssertEqual(attempt["expires"] as? Int, now + Int(AdministratorPrompt.answerWindow))
        XCTAssertEqual(journal["sleepDisabledByUs"] as? Bool, true)
        XCTAssertEqual(releaseAtShow.data.map { String(decoding: $0, as: UTF8.self) }, "\(nonce) held\n", "claimed before the dialog")
        XCTAssertNil(try h.store.loadState()?.sleepOffAttempt)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(nonce) free\n", "given back once sleep is off")
        await m.end(reason: .user)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    // MARK: Round 21's receipt controls

    private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Makes the fake pmset's `-a disablesleep 1` set 1 and then fail, as a
    /// pmset that applied the setting and exited 1 would, after the marker
    /// identity is recorded. With `forge`, a process running as the user
    /// first rewrites the marker in place (the same inode) to the bare
    /// nonce, round 21's forgery.
    private func failAfterTheWrite(_ fake: FakeDialogMachine, forge: Bool) throws {
        var script = try String(contentsOf: fake.pmset, encoding: .utf8)
        let marker = quote(h.home.paths.pendingStartFile.path)
        let dir = quote(fake.dir.path)
        let old = "\"-a disablesleep 1\") printf 1 > '\(fake.dir.appendingPathComponent("sleep-disabled").path)' ;;"
        let injected = """
        "-a disablesleep 1")
          printf 1 > '\(fake.dir.appendingPathComponent("sleep-disabled").path)'
          /usr/bin/stat -f '%d:%i' \(marker) > \(dir)/marker-before
          if \(forge ? "true" : "false"); then nonce=$(/usr/bin/head -c 36 \(marker)); printf %s "$nonce" > \(marker); fi
          /usr/bin/stat -f '%d:%i' \(marker) > \(dir)/marker-after
          exit 1 ;;
        """
        XCTAssertTrue(script.contains(old))
        script = script.replacingOccurrences(of: old, with: injected)
        try script.write(to: fake.pmset, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(fake.pmset.path, 0o755), 0)
    }

    private func machine(_ name: String) throws -> FakeDialogMachine {
        try FakeDialogMachine(in: h.home.root.appendingPathComponent(name, isDirectory: true), clockStart: now, clockLater: now + 5, receipts: h.receipts)
    }

    /// Round 21's control: pmset applied the setting and failed after the
    /// command's record. The receipt holds this start's `writing`, so the
    /// start is undone and sleep comes back on.
    func testAFailureAfterTheWriteIsUndone() async throws {
        let fake = try machine("control")
        try failAfterTheWrite(fake, forge: false)
        let m = h.makeManager(sleepGuard: fake.sleepGuard())

        await m.start(duration: 1800)

        XCTAssertEqual(fake.sleepDisabled, "0")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-g", "-a disablesleep 1", "-a disablesleep 0"])
        XCTAssertEqual(TestReceipts.text(h.receipts), "\(fake.nonce ?? "?") \(SleepOffReceipts.zero) writing\n")
        XCTAssertEqual(TestReceipts.release(h.receipts), "\(fake.nonce ?? "?") free\n")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertNil(m.session)
    }

    /// Round 21 P1, the same-inode forgery: before, a process running as
    /// the user rewrote the marker in place to the bare nonce, the start
    /// read that as "never reached the sleep setting", dropped the restore
    /// it owed and left sleep off. The marker is not the evidence any more;
    /// the receipt still holds this start's `writing`, so the start is
    /// undone exactly like the control.
    func testAForgedMarkerDoesNotDropTheRestore() async throws {
        let fake = try machine("forged")
        try failAfterTheWrite(fake, forge: true)
        let m = h.makeManager(sleepGuard: fake.sleepGuard())

        await m.start(duration: 1800)

        XCTAssertEqual(try Data(contentsOf: fake.dir.appendingPathComponent("marker-before")), try Data(contentsOf: fake.dir.appendingPathComponent("marker-after")), "the same inode was rewritten, not replaced")
        XCTAssertEqual(fake.sleepDisabled, "0", "sleep is back on")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-g", "-a disablesleep 1", "-a disablesleep 0"], "the app undid the write")
        XCTAssertEqual(TestReceipts.text(h.receipts), "\(fake.nonce ?? "?") \(SleepOffReceipts.zero) writing\n")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, "the restore was made, then cleared")
        XCTAssertNil(try h.store.loadSession())
        XCTAssertNil(m.session)
        XCTAssertFalse(h.notifier.posts.contains { $0.body.contains("never turned sleep off") }, "\(h.notifier.posts.map(\.body))")
    }
}

/// The journal's bytes as the dialog was shown.
private final class JournalAtShow: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    var data: Data? {
        get { lock.withLock { _data } }
        set { lock.withLock { _data = newValue } }
    }
}
