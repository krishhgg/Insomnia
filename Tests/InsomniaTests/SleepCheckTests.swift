import XCTest
@testable import Insomnia

/// The live check during a session (`SessionManager.checkSleepHeld`):
/// SleepDisabled read back from pmset, set again when something turned it
/// back to 0, and a warning only when that fails.
@MainActor
final class SleepCheckTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    private func started() async -> SessionManager {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        return m
    }

    private func callsAfter(_ count: Int) -> [String] {
        Array(h.guardFake.calls.dropFirst(count))
    }

    private func sleepLines(_ m: SessionManager) -> [StatusMenu.Item] {
        StatusItemController.statusItems(manager: m, status: RecordingStatusSource())
            .filter { $0.title.hasPrefix("Sleep") }
    }

    func testNoSessionReadsNothing() async {
        let m = h.makeManager()
        await m.checkSleepHeld()
        XCTAssertEqual(h.guardFake.calls, [])
    }

    /// The bit still set: one read, no lock, nothing set, no line.
    func testHeldSleepIsOnlyRead() async {
        let m = await started()
        let before = h.guardFake.calls.count
        await m.checkSleepHeld()
        XCTAssertEqual(callsAfter(before), ["pmset -g"])
        XCTAssertFalse(m.sleepNotHeld)
        XCTAssertEqual(sleepLines(m), [])
    }

    /// Turned back to 0 mid-session: read again under the lock and set
    /// again, quietly.
    func testSleepTurnedBackOnIsSetAgain() async {
        let m = await started()
        h.guardFake.sleepDisabled = false
        let before = h.guardFake.calls.count
        await m.checkSleepHeld()
        XCTAssertEqual(callsAfter(before), ["pmset -g", "pmset -g", "disablesleep 1"])
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.guardFake.unlockedPrivilegedCalls, [])
        XCTAssertFalse(m.sleepNotHeld)
        XCTAssertNil(m.lastError)
        XCTAssertFalse(h.notifier.posts.map(\.title).contains(SessionManager.sleepNotHeldTitle))
        XCTAssertEqual(sleepLines(m), [])
    }

    /// A set that fails shows "Sleep is not held" and posts once; the next
    /// check tries again, and a set that holds takes the line down.
    func testAFailedSetWarnsOnceAndIsRetried() async {
        let m = await started()
        h.guardFake.sleepDisabled = false
        h.guardFake.throwOn = ["disablesleep 1"]
        await m.checkSleepHeld()
        XCTAssertTrue(m.sleepNotHeld)
        XCTAssertTrue(m.isActive, "the session goes on")
        XCTAssertEqual(sleepLines(m), [
            StatusMenu.Item(title: "Sleep is not held, so this session is not keeping the Mac awake", kind: .warning),
        ])

        await m.checkSleepHeld()
        XCTAssertEqual(h.notifier.posts.map(\.title).filter { $0 == SessionManager.sleepNotHeldTitle }.count, 1)

        h.guardFake.throwOn = []
        await m.checkSleepHeld()
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertFalse(m.sleepNotHeld)
        XCTAssertEqual(sleepLines(m), [])
    }

    /// A read found 0 and the check could not set the bit again for
    /// another reason: the recovery lock busy, then the read under the lock
    /// failing. Each puts the line up as a failed set does, with one
    /// notification. A failed first read changes nothing either way, and a
    /// read of 1 takes the line down.
    func testACheckThatCannotSetTheBitAgainAfterReadingZeroWarns() async throws {
        let m = await started()
        h.guardFake.sleepDisabled = false
        let before = h.guardFake.calls.count
        do {
            let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
            defer { held.release() }
            await m.checkSleepHeld()
        }
        XCTAssertEqual(callsAfter(before), ["pmset -g"], "refused before the read under the lock")
        XCTAssertTrue(m.sleepNotHeld, "the lock busy")
        XCTAssertTrue(m.isActive, "the session goes on")
        XCTAssertEqual(sleepLines(m), [
            StatusMenu.Item(title: "Sleep is not held, so this session is not keeping the Mac awake", kind: .warning),
        ])
        XCTAssertEqual(h.notifier.posts.map(\.title).filter { $0 == SessionManager.sleepNotHeldTitle }.count, 1)

        h.guardFake.throwOn = ["pmset -g"]
        await m.checkSleepHeld()
        XCTAssertTrue(m.sleepNotHeld, "a failed first read keeps the line")
        h.guardFake.throwOn = []
        h.guardFake.sleepDisabled = true
        await m.checkSleepHeld()
        XCTAssertFalse(m.sleepNotHeld)

        h.guardFake.sleepDisabled = false
        h.guardFake.throwOnLockedRead = true
        let second = h.guardFake.calls.count
        await m.checkSleepHeld()
        h.guardFake.throwOnLockedRead = false
        XCTAssertEqual(callsAfter(second), ["pmset -g", "pmset -g"])
        XCTAssertTrue(m.sleepNotHeld, "the read under the lock failed")
        XCTAssertEqual(h.notifier.posts.map(\.title).filter { $0 == SessionManager.sleepNotHeldTitle }.count, 1)
    }

    /// The line belongs to the session: an end takes it down.
    func testAnEndClearsTheWarning() async {
        let m = await started()
        h.guardFake.sleepDisabled = false
        h.guardFake.throwOn = ["disablesleep 1"]
        await m.checkSleepHeld()
        XCTAssertTrue(m.sleepNotHeld)
        _ = await m.end(reason: .user)
        XCTAssertFalse(m.sleepNotHeld)
    }

    // MARK: Only while a session holds sleep

    /// A session that ended, or a start that failed, leaves nothing to
    /// check: not even a read.
    func testNothingIsReadAfterAnEndOrAFailedStart() async {
        let m = await started()
        _ = await m.end(reason: .user)
        XCTAssertFalse(m.isActive)
        let afterEnd = h.guardFake.calls.count
        await m.checkSleepHeld()
        XCTAssertEqual(callsAfter(afterEnd), [])

        h.guardFake.throwOn = ["disablesleep 1"]
        await m.start(duration: 3600)
        XCTAssertFalse(m.isActive)
        h.guardFake.throwOn = []
        let afterFailure = h.guardFake.calls.count
        await m.checkSleepHeld()
        XCTAssertEqual(callsAfter(afterFailure), [])
    }

    /// An end that could not take the lock is still on its way (it is
    /// retried): the session is still in memory and the journal still
    /// claims sleep, but the check must not set it again under that end,
    /// nor under a quit.
    func testAnEndWaitingForItsRetrySetsNothing() async throws {
        for reason in [EndReason.user, .quit] {
            let m = await started()
            let held = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire())
            let outcome = await m.end(reason: reason)
            held.release()
            XCTAssertEqual(outcome, .locked, "\(reason)")
            XCTAssertTrue(m.isActive, "\(reason): the end is pending")
            h.guardFake.sleepDisabled = false
            let before = h.guardFake.calls.count
            await m.checkSleepHeld()
            XCTAssertEqual(callsAfter(before), [], "\(reason)")
            XCTAssertFalse(h.guardFake.sleepDisabled, "\(reason)")
            _ = await m.end(reason: .user)
        }
    }

    // MARK: Never against an end

    /// A check that read 0 just before an end was asked for runs its
    /// transaction after the end: it finds nothing to hold, and the end's
    /// disablesleep 0 is the last word.
    func testACheckInFlightWhenAnEndArrivesSetsNothing() async throws {
        let m = await started()
        h.guardFake.sleepDisabled = false
        let gate = AsyncGate()
        h.guardFake.readGate = gate
        let check = await runUntilSuspended { await m.checkSleepHeld() }
        await gate.waitUntilStarted()
        let end = Task { @MainActor in await m.end(reason: .user) }
        await settleQueuedRequests()
        await gate.open()
        _ = await end.value
        await check.value
        h.guardFake.readGate = nil
        XCTAssertFalse(m.isActive)
        let restore = try XCTUnwrap(h.guardFake.calls.lastIndex(of: "disablesleep 0"))
        XCTAssertFalse(h.guardFake.calls[restore...].contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// An end or a quit asked for while the transaction's own read waits:
    /// the read answers 0, and the check sets nothing. The end, queued
    /// behind the check, restores sleep.
    func testAnEndAskedForDuringTheLockedReadSetsNothing() async throws {
        for reason in [EndReason.user, .quit] {
            let m = await started()
            h.guardFake.sleepDisabled = false
            let gate = AsyncGate()
            h.guardFake.lockedReadGate = gate
            let before = h.guardFake.calls.count
            let check = await runUntilSuspended { await m.checkSleepHeld() }
            await gate.waitUntilStarted()
            XCTAssertEqual(callsAfter(before), ["pmset -g", "pmset -g"], "\(reason): held in the second read")
            let ticket = m.endTicket
            let end = await runUntilSuspended { await m.end(reason: reason) }
            XCTAssertEqual(m.endTicket, ticket + 1, "\(reason): the end was asked for")
            await gate.open()
            await check.value
            _ = await end.value
            h.guardFake.lockedReadGate = nil
            XCTAssertFalse(m.isActive, "\(reason)")
            XCTAssertFalse(callsAfter(before).contains("disablesleep 1"), "\(reason): \(callsAfter(before))")
            XCTAssertTrue(callsAfter(before).contains("disablesleep 0"), "\(reason)")
            XCTAssertFalse(h.guardFake.sleepDisabled, "\(reason)")
        }
    }

    /// An end or a quit asked for after the transaction's last check, while
    /// the runner holds `sudo pmset -a disablesleep 1` just before it
    /// launches. Nothing checks again after the journal write, so the set
    /// runs. The end, queued behind the check, then sets the bit back to 0
    /// and clears the journal. The real guard and runner run here, on
    /// scripted `sudo` and `pmset`.
    func testAnEndAskedForAsTheSetLaunchesRestoresSleepAfterIt() async throws {
        for reason in [EndReason.user, .quit] {
            let pmset = try ScriptedPmset(in: h.home.root)
            let m = h.makeManager(sleepGuard: pmset.sleepGuard)
            await m.start(duration: 3600)
            XCTAssertTrue(m.isActive, "\(reason)")
            XCTAssertEqual(pmset.bit, "1", "\(reason)")
            pmset.bit = "0"
            let before = try pmset.calls().count
            // The check's unlocked read, its locked read, then the set.
            pmset.hold.arm(atLaunch: 3)
            let check = await runUntilSuspended { await m.checkSleepHeld() }
            await pmset.hold.gate.waitUntilStarted()
            XCTAssertEqual(Array(try pmset.calls().dropFirst(before)), ["-g", "-g"], "\(reason): held before the set launches")
            let ticket = m.endTicket
            let end = await runUntilSuspended { await m.end(reason: reason) }
            XCTAssertEqual(m.endTicket, ticket + 1, "\(reason): the end was asked for")
            await pmset.hold.gate.open()
            await check.value
            let outcome = await end.value
            XCTAssertEqual(outcome, .restored, "\(reason)")
            XCTAssertEqual(Array(try pmset.calls().dropFirst(before)), ["-g", "-g", "-a disablesleep 1", "-g", "-a disablesleep 0"], "\(reason)")
            XCTAssertEqual(pmset.bit, "0", "\(reason): sleep restored")
            XCTAssertEqual(try h.store.loadState(), .clean, "\(reason)")
            XCTAssertFalse(m.isActive, "\(reason)")
        }
    }

    /// An end, a quit or the deadline comes while the read under the lock
    /// runs, and that read then fails. Sleep goes back on anyway, so the
    /// check puts up no warning and posts nothing.
    func testAFailedLockedReadDuringAnEndOrPastTheDeadlineDoesNotWarn() async throws {
        for cause in ["user", "quit", "deadline"] {
            let m = await started()
            h.guardFake.sleepDisabled = false
            let gate = AsyncGate()
            h.guardFake.lockedReadGate = gate
            h.guardFake.throwOnLockedRead = true
            let posts = h.notifier.posts.count
            let before = h.guardFake.calls.count
            let check = await runUntilSuspended { await m.checkSleepHeld() }
            await gate.waitUntilStarted()
            XCTAssertEqual(callsAfter(before), ["pmset -g", "pmset -g"], "\(cause): held in the second read")
            var end: Task<EndOutcome, Never>?
            switch cause {
            case "user": end = await runUntilSuspended { await m.end(reason: .user) }
            case "quit": end = await runUntilSuspended { await m.end(reason: .quit) }
            default: h.clock.advance(3601)
            }
            await gate.open()
            await check.value
            _ = await end?.value
            h.guardFake.lockedReadGate = nil
            h.guardFake.throwOnLockedRead = false
            XCTAssertFalse(m.sleepNotHeld, cause)
            XCTAssertEqual(h.notifier.posts.dropFirst(posts).filter { $0.title == SessionManager.sleepNotHeldTitle }.count, 0, cause)
            XCTAssertFalse(callsAfter(before).contains("disablesleep 1"), "\(cause): \(callsAfter(before))")
            if m.isActive { _ = await m.end(reason: .user) }
        }
    }

    /// An end, a quit or the deadline comes while the check's set runs,
    /// and the set then fails. The end restores sleep after it, so the
    /// check puts up no warning and posts nothing.
    func testASetThatFailsDuringAnEndOrPastTheDeadlineDoesNotWarn() async throws {
        for cause in ["user", "quit", "deadline"] {
            let m = await started()
            h.guardFake.sleepDisabled = false
            let gate = AsyncGate()
            h.guardFake.sleepGate = gate
            h.guardFake.throwAfterEffect = ["disablesleep 1"]
            let posts = h.notifier.posts.count
            let check = await runUntilSuspended { await m.checkSleepHeld() }
            await gate.waitUntilStarted()
            var end: Task<EndOutcome, Never>?
            switch cause {
            case "user": end = await runUntilSuspended { await m.end(reason: .user) }
            case "quit": end = await runUntilSuspended { await m.end(reason: .quit) }
            default: h.clock.advance(3601)
            }
            await gate.open()
            await check.value
            _ = await end?.value
            h.guardFake.sleepGate = nil
            h.guardFake.throwAfterEffect = []
            XCTAssertFalse(m.sleepNotHeld, cause)
            XCTAssertEqual(h.notifier.posts.dropFirst(posts).filter { $0.title == SessionManager.sleepNotHeldTitle }.count, 0, cause)
            if m.isActive { _ = await m.end(reason: .user) }
        }
    }

    /// The session's end time passes while the transaction's own read
    /// waits: the deadline timer or the backstop ends it, and the check
    /// sets nothing.
    func testADeadlinePassedDuringTheLockedReadSetsNothing() async {
        let m = await started()
        h.guardFake.sleepDisabled = false
        let gate = AsyncGate()
        h.guardFake.lockedReadGate = gate
        let before = h.guardFake.calls.count
        let check = await runUntilSuspended { await m.checkSleepHeld() }
        await gate.waitUntilStarted()
        h.clock.advance(3601)
        await gate.open()
        await check.value
        h.guardFake.lockedReadGate = nil
        XCTAssertEqual(callsAfter(before), ["pmset -g", "pmset -g"])
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// An end whose restore was refused keeps the journal entry for its
    /// retry; the session is gone, so the check leaves the bit alone.
    func testARefusedRestoreIsNotUndoneByTheCheck() async {
        let m = await started()
        h.guardFake.throwOn = ["disablesleep 0"]
        _ = await m.end(reason: .user)
        XCTAssertFalse(m.isActive)
        h.guardFake.throwOn = []
        h.guardFake.sleepDisabled = false
        let before = h.guardFake.calls.count
        await m.checkSleepHeld()
        XCTAssertEqual(callsAfter(before), [])
    }

    /// The session's end time has passed but its deadline timer has not
    /// run yet (a late timer, a busy main thread): the backstop may already
    /// have restored sleep, and the check must not take it back.
    func testASessionPastItsEndIsNotHeldAgain() async {
        let m = await started()
        h.clock.advance(3601)
        h.guardFake.sleepDisabled = false
        let before = h.guardFake.calls.count
        await m.checkSleepHeld()
        XCTAssertEqual(callsAfter(before), [])
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }

    /// The backstop restored sleep and removed session.json while this
    /// process still holds the session in memory: whether or not its
    /// journal write landed, the check leaves the bit at 0.
    func testABackstopRestoreIsNotUndoneByTheCheck() async throws {
        for journalCleared in [true, false] {
            let m = await started()
            h.guardFake.sleepDisabled = false
            try h.store.deleteSession()
            if journalCleared { try h.store.saveState(.clean) }
            let before = h.guardFake.calls.count
            await m.checkSleepHeld()
            XCTAssertFalse(callsAfter(before).contains("disablesleep 1"), "journal cleared: \(journalCleared)")
            XCTAssertFalse(h.guardFake.sleepDisabled, "journal cleared: \(journalCleared)")
            _ = await m.end(reason: .user)
        }
    }

    // MARK: The journal first

    /// When the set runs, the journal on disk already says Insomnia
    /// disabled sleep, so a crash right after it leaves the backstop an
    /// entry to undo.
    func testTheJournalClaimsSleepBeforeTheSetRuns() async throws {
        let m = await started()
        h.guardFake.sleepDisabled = false
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let check = await runUntilSuspended { await m.checkSleepHeld() }
        await gate.waitUntilStarted()
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        await gate.open()
        await check.value
        h.guardFake.sleepGate = nil
        XCTAssertTrue(h.guardFake.sleepDisabled)
    }

    /// A journal that cannot be written stops the set: nothing would be
    /// left for the backstop to undo it by.
    func testAJournalThatCannotBeWrittenStopsTheSet() async throws {
        let m = await started()
        h.guardFake.sleepDisabled = false
        let dir = h.home.paths.appSupport.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir) }
        let before = h.guardFake.calls.count
        await m.checkSleepHeld()
        XCTAssertFalse(callsAfter(before).contains("disablesleep 1"))
        XCTAssertTrue(m.sleepNotHeld)
    }
}

/// `PmsetSleepGuard` and its `CancellableCommand` over two `/bin/sh`
/// scripts in a private directory, so nothing here runs sudo or pmset.
/// `sudo` drops `-n` and runs the rest. `pmset` appends its arguments to
/// `calls`, prints SleepDisabled from `bit` for `-g`, and writes `bit`
/// for `-a disablesleep`. The settle wait returns at once. `hold` can stop
/// one launch of the runner before `Process.run`.
private struct ScriptedPmset {
    let dir: URL
    let hold = LaunchHold()
    let sleepGuard: PmsetSleepGuard

    init(in root: URL) throws {
        dir = root.appendingPathComponent("pmset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let calls = dir.appendingPathComponent("calls").path
        let bit = dir.appendingPathComponent("bit").path
        let sudo = dir.appendingPathComponent("sudo")
        let pmset = dir.appendingPathComponent("pmset")
        try TestScripts.write("#!/bin/sh\n[ \"$1\" = -n ] && shift\nexec \"$@\"\n", to: sudo)
        try TestScripts.write("""
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(calls)'
        case "$1" in
        -g) printf 'System-wide power settings:\\n SleepDisabled\\t\\t%s\\n' "$(cat '\(bit)')" ;;
        -a) printf '%s' "$3" > '\(bit)' ;;
        esac

        """, to: pmset)
        FileManager.default.createFile(atPath: calls, contents: nil)
        let hold = hold
        sleepGuard = PmsetSleepGuard(
            sudo: sudo.path, pmset: pmset.path, timeout: 10, stopGrace: 1,
            settleWait: { _ in },
            runner: CancellableCommand(beforeLaunch: { await hold.beforeLaunch() })
        )
        self.bit = "0"
    }

    /// SleepDisabled as the scripted pmset reports it.
    var bit: String {
        get { (try? String(contentsOf: dir.appendingPathComponent("bit"), encoding: .utf8)) ?? "" }
        nonmutating set { try? newValue.write(to: dir.appendingPathComponent("bit"), atomically: true, encoding: .utf8) }
    }

    /// The arguments of every pmset run, oldest first.
    func calls() throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
}

/// Holds the `n`th launch after `arm(atLaunch:)` at the runner's
/// `beforeLaunch`, the last step before the child is started, until
/// `gate` opens. Every other launch goes straight through.
private final class LaunchHold: @unchecked Sendable {
    let gate = AsyncGate()
    private let lock = NSLock()
    private var remaining = 0

    func arm(atLaunch n: Int) {
        lock.withLock { remaining = n }
    }

    func beforeLaunch() async {
        let held: Bool = lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return remaining == 0
        }
        if held { await gate.wait() }
    }
}
