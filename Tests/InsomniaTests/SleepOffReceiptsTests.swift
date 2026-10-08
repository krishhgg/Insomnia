import Darwin
import XCTest
@testable import Insomnia

/// SleepOffReceipts on its own: what a receipt shows about one start, and
/// every receipt or folder it refuses to trust. Each test has its own
/// receipt folder in a temporary home (TestReceipts), trusted for the test
/// user besides root.
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
        home.destroy()
    }

    private let nonce = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    private func attempt(_ identity: String) -> SleepOffAttempt {
        SleepOffAttempt(nonce: nonce, owedBefore: false, receipt: identity, deadline: 1_800_000_000, marker: "1:2")
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

    /// Install.sh's nonce, another start's, and this start's `refused` all
    /// show that this start's command never turned sleep off; only this
    /// start's `writing` shows that it may have.
    func testTheVerdictFollowsTheNonceAndTheWord() throws {
        let identity = try receipts.identity()
        XCTAssertEqual(receipts.verdict(for: attempt(identity)), .neverWrote, "install.sh's content")
        TestReceipts.write(receipts.file, nonce: "00000000-1111-2222-3333-444444444444", word: "writing")
        XCTAssertEqual(receipts.verdict(for: attempt(identity)), .neverWrote, "another start's record")
        TestReceipts.write(receipts.file, nonce: nonce, word: "refused")
        XCTAssertEqual(receipts.verdict(for: attempt(identity)), .neverWrote, "this start's command stopped at its last deadline check")
        TestReceipts.write(receipts.file, nonce: nonce, word: "writing")
        let reason = try XCTUnwrap(mayHaveWritten(receipts.verdict(for: attempt(identity))))
        XCTAssertEqual(reason, "\(receipts.file) shows that the command went on to turn sleep off")
        XCTAssertEqual(try receipts.identity(), identity, "written in place, the receipt stays the same file")
    }

    /// The same bytes in another file (renamed over the receipt) show
    /// nothing about a start that began with the first one.
    func testAReceiptThatIsAnotherFileNowShowsNothing() throws {
        let identity = try receipts.identity()
        let copy = receipts.folder + "/copy"
        try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: copy))
        XCTAssertEqual(chmod(copy, 0o644), 0)
        XCTAssertEqual(rename(copy, receipts.file), 0)

        XCTAssertNotEqual(try receipts.identity(), identity)
        let reason = try XCTUnwrap(mayHaveWritten(receipts.verdict(for: attempt(identity))))
        XCTAssertEqual(reason, "\(receipts.file) is not the file it was when the start began")
    }

    /// Each way a receipt or a folder above it can be something the checks
    /// do not trust. A receipt that would otherwise show "never" shows
    /// nothing, and a start could not begin with it (identity throws), apart
    /// from content that is wrong in a 45-byte file, which only the read
    /// finds.
    func testAReceiptOrFolderTheChecksDoNotTrustShowsNothing() throws {
        let user = String(cString: getpwuid(getuid()).pointee.pw_name)
        let file = receipts.file
        let folder = receipts.folder
        let cases: [(name: String, startable: Bool, says: String, damage: () throws -> Void, repair: () throws -> Void)] = [
            ("missing", false, "No such file or directory", { XCTAssertEqual(unlink(file), 0) }, {}),
            ("44 bytes", false, "is 44 bytes, not 45", { XCTAssertEqual(truncate(file, 44), 0) }, {}),
            ("46 bytes", false, "is 46 bytes, not 45", { XCTAssertEqual(truncate(file, 46), 0) }, {}),
            ("group-writable", false, "can be changed by its group or by others", { XCTAssertEqual(chmod(file, 0o664), 0) }, {}),
            ("writable by others", false, "can be changed by its group or by others", { XCTAssertEqual(chmod(file, 0o646), 0) }, {}),
            ("a hard link", false, "has 2 links", { XCTAssertEqual(link(file, folder + "/link"), 0) }, { unlink(folder + "/link") }),
            ("a symbolic link", false, "is not a regular file", {
                try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: folder + "/target"))
                XCTAssertEqual(unlink(file), 0)
                XCTAssertEqual(symlink(folder + "/target", file), 0)
            }, { unlink(folder + "/target") }),
            ("a folder", false, "is not a regular file", { XCTAssertEqual(unlink(file), 0); XCTAssertEqual(mkdir(file, 0o755), 0) }, { rmdir(file) }),
            ("an allow entry on the receipt", false, "has an access control entry that allows changes", { XCTAssertEqual(try self.runChmod(["+a", "user:\(user) allow write", file]), 0) },
             { _ = try self.runChmod(["-N", file]) }),
            ("a group-writable folder", false, "can be changed by its group or by others", { XCTAssertEqual(chmod(folder, 0o775), 0) }, { chmod(folder, 0o755) }),
            ("an allow entry on the folder", false, "has an access control entry that allows changes", { XCTAssertEqual(try self.runChmod(["+a", "user:\(user) allow add_file", folder]), 0) },
             { _ = try self.runChmod(["-N", folder]) }),
            ("unreadable", true, "Permission denied", { XCTAssertEqual(chmod(file, 0o000), 0) }, {}),
            ("a lower-case nonce", true, "does not hold a nonce and writing or refused", { TestReceipts.write(file, nonce: self.nonce.lowercased(), word: "refused") }, {}),
            ("another word", true, "does not hold a nonce and writing or refused", { TestReceipts.write(file, nonce: self.nonce, word: "written") }, {}),
            ("no newline", true, "does not hold a nonce and writing or refused", { TestReceipts.write(file, nonce: self.nonce, word: "refused\u{20}"); XCTAssertEqual(truncate(file, 45), 0) }, {}),
        ]
        for c in cases {
            receipts = try TestReceipts.make(in: home.root)
            TestReceipts.write(file, nonce: "00000000-0000-0000-0000-000000000000", word: "refused")
            let identity = try receipts.identity()
            XCTAssertEqual(receipts.verdict(for: attempt(identity)), .neverWrote, "\(c.name): the control")
            try c.damage()

            if c.startable {
                XCTAssertNoThrow(try receipts.identity(), c.name)
            } else {
                XCTAssertThrowsError(try receipts.identity(), c.name) { error in
                    XCTAssertTrue(error.localizedDescription.contains(c.says), "\(c.name): \(error.localizedDescription)")
                }
            }
            let reason = try XCTUnwrap(mayHaveWritten(receipts.verdict(for: attempt(identity))), c.name)
            XCTAssertTrue(reason.contains(c.says), "\(c.name): \(reason)")

            try c.repair()
            unlink(file)
        }
    }

    /// The receipt the app ships with trusts root alone, at the fixed path.
    /// A receipt the user owns, in a folder the user owns, which is all a
    /// process running as the user could make, shows nothing under that
    /// trust and cannot begin a start, whatever it holds.
    func testOnlyRootIsTrustedAndAReceiptTheUserOwnsIsNot() throws {
        let live = SleepOffReceipts.live
        XCTAssertEqual(live.folder, "/private/var/db/com.kgarg.insomnia")
        XCTAssertEqual(live.owners, [0])
        XCTAssertEqual(live.user, getuid())
        XCTAssertEqual(live.file, "/private/var/db/com.kgarg.insomnia/\(getuid())")

        let identity = try receipts.identity()
        let shipped = SleepOffReceipts(folder: receipts.folder, owners: [0], user: getuid())
        XCTAssertThrowsError(try shipped.identity()) { error in
            XCTAssertTrue(error.localizedDescription.contains("belongs to uid \(getuid()), not root"), error.localizedDescription)
        }
        for word in ["refused", "writing"] {
            TestReceipts.write(receipts.file, nonce: nonce, word: word)
            let reason = try XCTUnwrap(mayHaveWritten(shipped.verdict(for: attempt(identity))), word)
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
        XCTAssertThrowsError(try SleepOffReceipts(folder: viaVar, owners: [0, getuid()], user: getuid()).identity()) { error in
            XCTAssertEqual(error.localizedDescription, "/var is not a folder")
        }
        XCTAssertNoThrow(try SleepOffReceipts(folder: real, owners: [0, getuid()], user: getuid()).identity())
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
}

/// A start the app journaled (sleepOffAttempt) and never finished, settled
/// by the next transaction of a relaunched app, and the rules around it:
/// round 21's two receipt controls and its two relaunch findings, as
/// safety assertions.
@MainActor
final class SleepOffSettlementTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        chmod(h.home.root.path, 0o755)
        h.home.destroy()
    }

    private let now = 1_800_000_000

    /// What a start journals before its dialog, as performStart writes it:
    /// sleepDisabledByUs with the attempt, its session.json (ending
    /// `endsIn` seconds after the harness clock), and the marker, whose
    /// identity is journaled when `marker` is set. The app then dies.
    @discardableResult
    private func journalUnfinishedStart(owedBefore: Bool = false, endsIn: TimeInterval = 1800, marker: Bool = true) throws -> SleepOffAttempt {
        let session = SessionMath.newSession(now: h.clock.now.addingTimeInterval(endsIn - 3600), duration: 3600, maxDuration: 86400)
        let nonce = UUID().uuidString
        var attempt = SleepOffAttempt(nonce: nonce, owedBefore: owedBefore, receipt: try h.receipts.identity(), deadline: Int(session.endsAt.timeIntervalSince1970.rounded(.down)), marker: nil)
        var journal = RuntimeState.clean
        journal.sleepDisabledByUs = true
        journal.sleepOffAttempt = attempt
        try h.store.saveState(journal)
        try h.store.saveSession(session)
        if marker {
            attempt.marker = try h.store.savePendingStart(nonce).text
            journal.sleepOffAttempt = attempt
            try h.store.saveState(journal)
        }
        return attempt
    }

    private var markerExists: Bool { FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path) }

    /// Settled and nothing resumed: no session in memory or on disk, no
    /// marker, a clean journal.
    private func assertSettledAndNotResumed(_ m: SessionManager, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(m.isActive, "the start never finished, so its session is never resumed", file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), file: file, line: line)
        XCTAssertFalse(markerExists, file: file, line: line)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, file: file, line: line)
    }

    // MARK: Round 21's relaunch findings

    /// Round 21 P1: the app died under the dialog of a start whose session
    /// is still valid, and another tool set SleepDisabled 1 meanwhile.
    /// Before, the relaunch read that 1 as the session's and resumed it,
    /// and its end cleared the other tool's setting. Now the receipt shows
    /// the command never turned sleep off: the session is removed, not
    /// resumed, and the 1 is left alone.
    func testARelaunchDoesNotResumeAnUnexpiredStartOnAnotherToolsSetting() async throws {
        try journalUnfinishedStart()
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertTrue(h.guardFake.sleepDisabled, "the other tool's setting is left alone")
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
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
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
    }

    /// A start that never turned sleep off does not erase a restore an
    /// earlier session still owes: the entry goes back to true and is
    /// restored.
    func testARelaunchKeepsTheRestoreAnEarlierSessionOwes() async throws {
        try journalUnfinishedStart(owedBefore: true)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 0" }.count, 1, "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// The receipt shows this start's `writing`: its command may have
    /// turned sleep off. The session is still not resumed; the start is
    /// undone like an end.
    func testARelaunchUndoesAStartWhoseReceiptShowsItsCommandWrote() async throws {
        let attempt = try journalUnfinishedStart()
        TestReceipts.write(h.receipts.file, nonce: attempt.nonce, word: "writing")
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// Evidence that does not match the start shows nothing, and each is
    /// undone like an end: a receipt that is another file now, a marker
    /// replaced by another file with the same nonce, and a marker that was
    /// already gone (deleted without its lock).
    func testARelaunchUndoesAStartWhoseEvidenceDoesNotMatch() async throws {
        let cases: [(String, (SleepOffAttempt) throws -> Void)] = [
            ("receipt replaced", { _ in
                let copy = self.h.receipts.folder + "/copy"
                try Data(SleepOffReceipts.initialContent.utf8).write(to: URL(fileURLWithPath: copy))
                XCTAssertEqual(chmod(copy, 0o644), 0)
                XCTAssertEqual(rename(copy, self.h.receipts.file), 0)
            }),
            ("marker replaced", { attempt in
                let copy = self.h.home.root.appendingPathComponent("marker-copy")
                try Data(attempt.nonce.utf8).write(to: copy)
                XCTAssertEqual(rename(copy.path, self.h.home.paths.pendingStartFile.path), 0)
            }),
            ("marker gone", { _ in try FileManager.default.removeItem(at: self.h.home.paths.pendingStartFile) }),
            ("receipt missing", { _ in XCTAssertEqual(unlink(self.h.receipts.file), 0) }),
        ]
        for (name, damage) in cases {
            h.home.destroy()
            h = Harness()
            let attempt = try journalUnfinishedStart()
            try damage(attempt)
            h.guardFake.sleepDisabled = true
            let m = h.makeManager()

            await m.reconcile()

            XCTAssertFalse(m.isActive, name)
            XCTAssertNil(try h.store.loadSession(), name)
            XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, name)
            XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(name): \(h.guardFake.calls)")
            XCTAssertFalse(h.guardFake.sleepDisabled, name)
        }
    }

    /// No marker journaled: the start never showed its dialog, so nothing
    /// ran as root for it, whatever the receipt holds.
    func testARelaunchSettlesAStartThatShowedNoDialogAsNeverTurningSleepOff() async throws {
        let attempt = try journalUnfinishedStart(marker: false)
        TestReceipts.write(h.receipts.file, nonce: attempt.nonce, word: "writing")
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()

        await m.reconcile()

        try assertSettledAndNotResumed(m)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
    }

    /// A marker no journaled start accounts for, as a build from before
    /// sleepOffAttempt leaves it: whether its command turned sleep off is
    /// unknown, so the session beside it is never resumed and the journaled
    /// entry is restored. The control, with no marker, resumes.
    func testARelaunchDoesNotResumeASessionBesideAMarkerNoJournaledStartAccountsFor() async throws {
        for marker in [true, false] {
            h.home.destroy()
            h = Harness()
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
                XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
            } else {
                XCTAssertTrue(m.isActive, "control: \(m.lastError ?? "")")
                XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"), "control: \(h.guardFake.calls)")
                await m.end(reason: .user)
            }
        }
    }

    /// The settlement cannot be written. With the app's folder read-only,
    /// neither session.json nor the journal can change: the record stays,
    /// the session is ended rather than resumed and sleep is restored, and
    /// a new start is refused before its dialog (first because that end is
    /// still pending). With only state.json immutable, session.json goes
    /// but the journal keeps the record, and a new start is refused because
    /// of it. Either way the next transaction that can write settles it.
    func testASettlementThatCannotBeWrittenEndsTheSessionAndRefusesStartsUntilItIs() async throws {
        try journalUnfinishedStart()
        try FileManager.default.removeItem(at: h.home.paths.pendingStartFile)
        FileManager.default.createFile(atPath: h.home.paths.recoveryLock.path, contents: nil)
        try FileManager.default.createDirectory(at: h.home.paths.logs, withIntermediateDirectories: true)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        XCTAssertEqual(chmod(h.home.root.path, 0o500), 0)

        await m.reconcile()

        XCTAssertFalse(m.isActive)
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertNotNil(try h.store.loadState()?.sleepOffAttempt, "the record stays")

        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(h.prompt.shown, 0, "no dialog")
        XCTAssertTrue(m.lastError?.hasPrefix("start refused") == true, m.lastError ?? "")

        XCTAssertEqual(chmod(h.home.root.path, 0o755), 0)
        await m.reconcile()

        try assertSettledAndNotResumed(m)

        h.home.destroy()
        h = Harness()
        try journalUnfinishedStart()
        try FileManager.default.removeItem(at: h.home.paths.pendingStartFile)
        h.guardFake.sleepDisabled = true
        let n = h.makeManager()
        let file = h.home.paths.stateFile.path
        // Rename over an immutable state.json is refused.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await n.reconcile()

        XCTAssertFalse(n.isActive)
        XCTAssertNil(try h.store.loadSession(), "the unfinished start's session.json goes")
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertNotNil(try h.store.loadState()?.sleepOffAttempt, "the record stays")

        await n.start(duration: 1800)

        XCTAssertFalse(n.isActive)
        XCTAssertEqual(h.prompt.shown, 0, "no dialog")
        XCTAssertTrue(n.lastError?.contains("an earlier start is still recorded in the journal") == true, n.lastError ?? "")

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)
        await n.reconcile()

        try assertSettledAndNotResumed(n)
    }

    // MARK: A new attempt and a replay

    /// A `writing` left by an earlier start is not this start's: a start
    /// whose dialog fails before its command's record is rolled back with
    /// nothing undone.
    func testAnEarlierStartsWritingDoesNotCountForANewStart() async throws {
        TestReceipts.write(h.receipts.file, nonce: UUID().uuidString, word: "writing")
        h.prompt.mode = .fail
        let m = h.makeManager()

        await m.start(duration: 1800)

        XCTAssertFalse(m.isActive)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertTrue(h.notifier.posts.last?.body.hasSuffix("The receipt shows that the command behind the password dialog never turned sleep off.") == true, h.notifier.posts.last?.body ?? "")
    }

    /// The dialog of a start that was settled is answered late: with no
    /// marker, lockf stops it first; under another start's marker the
    /// command finds another nonce and exits 3. Neither reads or writes
    /// pmset or the receipt.
    func testAReplayedDialogWritesNothing() async throws {
        let attempt = try journalUnfinishedStart()
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
    }

    /// Control: a normal start journals its attempt only while the dialog
    /// runs, and a normal end restores.
    func testANormalStartAndEndLeaveNoRecord() async throws {
        let m = h.makeManager()
        let atShow = JournalAtShow()
        let stateFile = h.home.paths.stateFile
        h.prompt.onShow = { _ in atShow.data = try? Data(contentsOf: stateFile) }

        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(atShow.data)) as? [String: Any])
        let attempt = try XCTUnwrap(journal["sleepOffAttempt"] as? [String: Any], "journaled before the dialog")
        XCTAssertNotNil(attempt["marker"] as? String, "with its marker")
        XCTAssertEqual(journal["sleepDisabledByUs"] as? Bool, true)
        XCTAssertNil(try h.store.loadState()?.sleepOffAttempt)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
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
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0"])
        XCTAssertEqual(TestReceipts.text(h.receipts), "\(fake.nonce ?? "?") writing\n")
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
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0"], "the app undid the write")
        XCTAssertEqual(TestReceipts.text(h.receipts), "\(fake.nonce ?? "?") writing\n")
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
