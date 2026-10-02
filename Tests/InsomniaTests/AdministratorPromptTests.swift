import XCTest
@testable import Insomnia

/// The osascript runner behind the administrator password dialog, driven
/// against a fake osascript (a shell script in a temp dir) that records its
/// arguments and never shows a dialog or runs pmset.
final class OsascriptAdministratorPromptTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-prompt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var argsFile: URL { dir.appendingPathComponent("args") }
    private var trace: URL { dir.appendingPathComponent("trace") }
    private var start: PendingStart { PendingStart(marker: dir.appendingPathComponent("pending-start"), nonce: "nonce-1") }

    /// A fake osascript. `body` runs after the arguments were recorded, each
    /// ending in a NUL byte (the script spans lines), in `argsFile`.
    private func fakeOsascript(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("osascript")
        let script = """
        #!/bin/bash
        for a in "$@"; do printf '%s\\0' "$a" >> '\(argsFile.path)'; done
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func recordedArgs() throws -> [String] {
        try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// A `beforeDeadline` that returns once the fake has created `file`
    /// (30 s at most), so the timeout clock starts only after the fake's
    /// signal handling is in place.
    private func untilExists(_ file: URL) -> @Sendable () -> Void {
        let path = file.path
        return {
            let limit = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: path), Date() < limit { usleep(10_000) }
        }
    }

    /// A shell loop that runs until `release` exists, for 60 s at most, and
    /// stops early if the test's directory is gone.
    private func until(_ release: URL) -> String {
        "i=0; while [[ ! -e '\(release.path)' && -d '\(dir.path)' && $i -lt 1200 ]]; do sleep 0.05; i=$((i + 1)); done"
    }

    /// The whole script is one literal: the root command with each `"`
    /// escaped for AppleScript, the marker path and nonce taken from argv
    /// through `quoted form of`, the privilege flag and the dialog text.
    func testScriptIsTheExactLiteral() {
        let embedded = AdministratorPrompt.rootCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        XCTAssertEqual(AdministratorPrompt.disableSleepScript, """
        on run argv
        do shell script "/bin/sh -c " & quoted form of "\(embedded)" & " insomnia " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session."
        end run
        """)
    }

    /// osacompile only compiles the script; nothing runs and no dialog is
    /// shown.
    func testScriptCompiles() throws {
        let osacompile = "/usr/bin/osacompile"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: osacompile), "no osacompile")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osacompile)
        process.arguments = ["-o", dir.appendingPathComponent("prompt.scpt").path, "-e", AdministratorPrompt.disableSleepScript]
        process.standardInput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errData, as: UTF8.self))
    }

    func testRunsTheFixedScriptThroughOsascriptWithTheMarkerAndNonceAsArguments() async throws {
        let exe = try fakeOsascript("exit 0")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        let odd = PendingStart(marker: dir.appendingPathComponent("it's \"pending\" $(x)"), nonce: "nonce-1")
        try await prompt.disableSleep(odd)
        XCTAssertEqual(try recordedArgs(), ["-e", AdministratorPrompt.disableSleepScript, odd.marker.path, "nonce-1"])
    }

    func testCancelledDialogIsReportedAsCancelled() async throws {
        let exe = try fakeOsascript("echo 'execution error: User canceled. (-128)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("a cancelled dialog must throw")
        } catch AdministratorPromptError.cancelled {
            // expected
        }
    }

    func testWrongPasswordIsAFailureThatKeepsStderr() async throws {
        let exe = try fakeOsascript("echo 'execution error: The administrator user name or password was incorrect. (-60007)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("a failed dialog must throw")
        } catch let AdministratorPromptError.failed(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("incorrect"), stderr)
        }
    }

    /// The root command's refusal reaches the caller as a failure carrying
    /// its message, the way `do shell script` reports a non-zero exit.
    func testAbandonedStartIsAFailureThatKeepsStderr() async throws {
        let exe = try fakeOsascript("echo 'execution error: the start that asked for this password is over; sleep was not turned off (3)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("must throw")
        } catch let AdministratorPromptError.failed(_, stderr) {
            XCTAssertTrue(stderr.contains("sleep was not turned off"), stderr)
        }
    }

    func testMissingExecutableIsALaunchFailure() async throws {
        let prompt = OsascriptAdministratorPrompt(executable: dir.appendingPathComponent("absent").path, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("must throw")
        } catch AdministratorPromptError.launchFailed {
            // expected
        }
    }

    /// At the deadline the child gets SIGTERM and nothing stronger, and the
    /// runner waits for it to finish before reporting the timeout. The fake
    /// traps TERM, takes 1.5 s to exit (longer than the 1 s SIGKILL grace
    /// CancellableCommand would allow) and exits 0; it is still a timeout.
    /// The deadline starts only once the trap is installed.
    func testTimeoutSendsSigtermOnlyAndWaitsForTheChildToExit() async throws {
        let ready = dir.appendingPathComponent("ready")
        let exe = try fakeOsascript("""
        trap 'echo term >> "\(trace.path)"; kill $! 2>/dev/null; sleep 1.5; echo clean >> "\(trace.path)"; exit 0' TERM
        : > '\(ready.path)'
        sleep 30 >/dev/null 2>&1 &
        wait $!
        echo untouched >> "\(trace.path)"
        """)
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 1, beforeDeadline: untilExists(ready))
        let began = Date()
        do {
            try await prompt.disableSleep(start)
            XCTFail("must time out")
        } catch let AdministratorPromptError.timedOut(seconds) {
            XCTAssertEqual(seconds, 1)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 2.5, "returned before the child had exited")
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8), "term\nclean\n", "the child was not left to finish its TERM handler")
    }

    /// A child that ignores SIGTERM is not killed. The caller is answered
    /// `grace` seconds after the deadline with the pid and a handle, and
    /// the handle resolves only when the child exits on its own.
    func testChildThatIgnoresSigtermIsReportedStillRunningAndNeverKilled() async throws {
        let ready = dir.appendingPathComponent("ready")
        let release = dir.appendingPathComponent("release")
        let exe = try fakeOsascript("""
        trap '' TERM
        : > '\(ready.path)'
        \(until(release))
        echo released >> '\(trace.path)'
        exit 0
        """)
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 1, grace: 1, beforeDeadline: untilExists(ready))
        let began = Date()
        var reported: UnfinishedPrompt?
        do {
            try await prompt.disableSleep(start)
            XCTFail("must be reported still running")
        } catch let AdministratorPromptError.stillRunning(p, grace) {
            reported = p
            XCTAssertEqual(grace, 1)
        }
        let handle = try XCTUnwrap(reported)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 2, "answered before the deadline plus grace")
        XCTAssertTrue(handle.osascriptAlive)
        XCTAssertTrue(handle.isRunning)
        XCTAssertEqual(kill(handle.pid, 0), 0, "the child must be alive, not killed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trace.path), "the child has not finished")

        try "".write(to: release, atomically: true, encoding: .utf8)
        await handle.waitUntilExit()
        XCTAssertFalse(handle.isRunning)
        XCTAssertFalse(handle.osascriptAlive)
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8), "released\n", "the child finished on its own")
    }

    /// osascript dies on SIGTERM but a command it started keeps its output
    /// open: osascript's exit reaches the handle, which stays running until
    /// that command lets go. `Process.terminate()` signals the whole
    /// process group, so the holder ignores SIGTERM the way a root pmset is
    /// out of the user's reach. It runs until the test releases it, and the
    /// deadline starts only once its trap is installed.
    func testOutputHeldAfterOsascriptExitsKeepsThePromptRunningWithoutALivePid() async throws {
        let ready = dir.appendingPathComponent("ready")
        let release = dir.appendingPathComponent("release")
        let exe = try fakeOsascript("""
        ( trap '' TERM; : > '\(ready.path)'; \(until(release)) ) &
        wait
        """)
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 1, grace: 1, beforeDeadline: untilExists(ready))
        var reported: UnfinishedPrompt?
        do {
            try await prompt.disableSleep(start)
            XCTFail("must be reported still running")
        } catch let AdministratorPromptError.stillRunning(p, _) {
            reported = p
        }
        let handle = try XCTUnwrap(reported)
        await handle.waitUntilOsascriptExits()
        XCTAssertFalse(handle.osascriptAlive, "osascript itself died on SIGTERM")
        XCTAssertTrue(handle.isRunning, "its output is still held")

        try "".write(to: release, atomically: true, encoding: .utf8)
        await handle.waitUntilExit()
        XCTAssertFalse(handle.isRunning)
    }

    /// A handle given out while osascript runs learns of its exit when it
    /// happens, while a command it started still holds its output, so the
    /// caller can stop naming the pid before the prompt as a whole is over.
    func testOsascriptExitReachesTheHandleBeforeItsOutputCloses() async throws {
        let ready = dir.appendingPathComponent("ready")
        let releaseOsascript = dir.appendingPathComponent("release-osascript")
        let releaseHolder = dir.appendingPathComponent("release-holder")
        let exe = try fakeOsascript("""
        trap '' TERM
        ( \(until(releaseHolder)) ) &
        : > '\(ready.path)'
        \(until(releaseOsascript))
        exit 0
        """)
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 1, grace: 1, beforeDeadline: untilExists(ready))
        var reported: UnfinishedPrompt?
        do {
            try await prompt.disableSleep(start)
            XCTFail("must be reported still running")
        } catch let AdministratorPromptError.stillRunning(p, _) {
            reported = p
        }
        let handle = try XCTUnwrap(reported)
        XCTAssertTrue(handle.osascriptAlive)
        XCTAssertEqual(kill(handle.pid, 0), 0, "osascript must be alive, not killed")

        try "".write(to: releaseOsascript, atomically: true, encoding: .utf8)
        await handle.waitUntilOsascriptExits()
        XCTAssertFalse(handle.osascriptAlive)
        XCTAssertTrue(handle.isRunning, "the command it started still holds its output")

        try "".write(to: releaseHolder, atomically: true, encoding: .utf8)
        await handle.waitUntilExit()
        XCTAssertFalse(handle.isRunning)
    }
}

/// The command the dialog runs as root, run as the current user under
/// /bin/sh with the dialog's quoting and a fake pmset (runRootCommand).
final class RootCommandTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-root-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var marker: URL { dir.appendingPathComponent("pending-start") }

    func testTurnsSleepOffWhileTheMarkerHoldsTheNonce() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1"])
    }

    /// Recovery (or the start itself) deleted the marker: a late answer
    /// runs nothing.
    func testDoesNothingOnceTheMarkerIsGone() throws {
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertTrue(r.stderr.contains("sleep was not turned off"), r.stderr)
    }

    /// A dialog left from an older start cannot act for a newer one.
    func testDoesNothingWhenANewerStartOwnsTheMarker() throws {
        try Data("nonce-2".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "nonce-2", "the newer start's marker is left alone")
    }

    func testAnEmptyNonceNeverMatches() throws {
        try Data().write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "", in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
    }

    /// Recovery took the lock and deleted the marker while pmset ran, and
    /// may have cleared the journal already: sleep is turned back on.
    func testMarkerDeletedWhilePmsetRunsTurnsSleepBackOn() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir, dropMarkerDuringPmset: true)
        XCTAssertEqual(r.status, 4, r.stderr)
        XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1", "-a disablesleep 0"])
        XCTAssertTrue(r.stderr.contains("sleep was turned back on"), r.stderr)
    }

    /// The marker path and the nonce are data: quotes, spaces and `$(...)`
    /// in either arrive intact and are never run.
    func testPathAndNonceAreNeverRun() throws {
        let odd = dir.appendingPathComponent("it's a \"dir\" $(touch canary)", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let oddMarker = odd.appendingPathComponent("pending-start")
        let nonce = "$(touch canary)'\";touch canary;`touch canary`"
        try Data(nonce.utf8).write(to: oddMarker)
        let r = try runRootCommand(marker: oddMarker, nonce: nonce, in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("canary").path))
    }
}

/// PmsetSleepGuard routes only `disablesleep 1` through the dialog. Its
/// `sudo -n` paths run the real sudo and are not exercised here.
final class PmsetSleepGuardPromptTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-guard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pendingStart() throws -> PendingStart {
        let start = PendingStart(marker: dir.appendingPathComponent("pending-start"), nonce: UUID().uuidString)
        try Data(start.nonce.utf8).write(to: start.marker)
        return start
    }

    func testDisableSleepGoesThroughThePromptWithItsStart() async throws {
        let prompt = FakeAdministratorPrompt()
        let sleepGuard = PmsetSleepGuard(prompt: prompt)
        let start = try pendingStart()
        try await sleepGuard.disableSleep(start)
        XCTAssertEqual(prompt.shown, 1)
        XCTAssertEqual(prompt.starts, [start])
    }

    func testCancelledPromptSurfacesAsCancelled() async throws {
        let prompt = FakeAdministratorPrompt()
        prompt.mode = .cancel
        let sleepGuard = PmsetSleepGuard(prompt: prompt)
        do {
            try await sleepGuard.disableSleep(try pendingStart())
            XCTFail("must throw")
        } catch AdministratorPromptError.cancelled {
            // expected
        }
        XCTAssertEqual(prompt.shown, 1)
    }

    func testStillRunningPromptSurfacesWithItsHandle() async throws {
        let prompt = FakeAdministratorPrompt()
        prompt.mode = .stuck
        let sleepGuard = PmsetSleepGuard(prompt: prompt)
        do {
            try await sleepGuard.disableSleep(try pendingStart())
            XCTFail("must throw")
        } catch let AdministratorPromptError.stillRunning(p, grace) {
            XCTAssertEqual(p.pid, FakeAdministratorPrompt.stuckPid)
            XCTAssertTrue(p === prompt.unfinished)
            XCTAssertEqual(grace, AdministratorPrompt.stopGrace)
        }
        XCTAssertEqual(prompt.shown, 1)
    }
}

/// Session lifecycle around the dialog: Start is the only path that shows
/// it, every failure of it rolls the start back, and a relaunch reads the
/// sleep setting instead of asking.
@MainActor
final class SleepPromptLifecycleTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    private func seedValidSession(journaled: Bool = true) throws -> Session {
        let now = h.clock.now
        let s = Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600))
        try h.store.saveSession(s)
        if journaled {
            var st = RuntimeState()
            st.sleepDisabledByUs = true
            try h.store.saveState(st)
        }
        return s
    }

    private var markerExists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path, isDirectory: &isDir)
    }

    private func assertRolledBackClean(_ m: SessionManager, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(markerExists, "pending-start left behind", file: file, line: line)
        XCTAssertNil(m.session, file: file, line: line)
        XCTAssertFalse(m.isActive, file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), "session.json left behind", file: file, line: line)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, "journal left dirty", file: file, line: line)
        XCTAssertEqual(m.state, RuntimeState.clean, file: file, line: line)
        XCTAssertFalse(h.guardFake.sleepDisabled, "sleep left disabled", file: file, line: line)
    }

    // MARK: Start

    func testStartShowsThePromptOnceAfterJournalAndBackstop() async throws {
        let m = h.makeManager()
        await m.start(duration: 1800)

        let s = try XCTUnwrap(m.session)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertEqual(try h.store.loadSession(), s)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNil(m.lastError)
        // The dialog was shown for this start's marker, which held its
        // nonce then and is gone now that the start is over.
        let shownFor = try XCTUnwrap(h.prompt.starts.first)
        XCTAssertEqual(shownFor.marker, h.home.paths.pendingStartFile)
        XCTAssertFalse(shownFor.nonce.isEmpty)
        XCTAssertEqual(h.prompt.markerAtShow, [shownFor.nonce])
        XCTAssertFalse(markerExists, "the marker must not outlive its start")
    }

    /// Every attempt gets its own nonce, so a dialog left from one start
    /// can never pass for the next.
    func testEachStartWritesAFreshNonce() async throws {
        let m = h.makeManager()
        await m.start(duration: 1800)
        await m.end(reason: .user)
        await m.start(duration: 1800)

        let starts = h.prompt.starts
        XCTAssertEqual(starts.count, 2)
        XCTAssertNotEqual(starts[0].nonce, starts[1].nonce)
        XCTAssertEqual(h.prompt.markerAtShow, starts.map(\.nonce))
        XCTAssertFalse(markerExists)
    }

    /// No marker, no dialog: a start that cannot write it is rolled back
    /// before anything is shown or run.
    func testMarkerThatCannotBeWrittenRollsBackWithoutAPrompt() async throws {
        try FileManager.default.createDirectory(at: h.home.paths.pendingStartFile, withIntermediateDirectories: false)
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("pending-start marker"), err)
    }

    func testCancelledPromptRollsBackAndSaysSo() async throws {
        h.prompt.mode = .cancel
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 1)
        // The undo runs from the journal, through the passwordless line.
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(h.backstop.arms, 1)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("cancelled"), err)
        let last = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(last.title, "Session not started")
        XCTAssertTrue(last.body.contains("password prompt was cancelled or failed"), last.body)
    }

    func testFailedPromptRollsBack() async throws {
        h.prompt.mode = .fail
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("incorrect"), err)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// While the dialog is up the session file, the journal entry and the
    /// armed backstop already exist, so a crash mid-prompt leaves recovery
    /// a record. A dialog nobody answers times out and rolls back.
    func testHungPromptLeavesARecordForRecoveryThenRollsBack() async throws {
        h.prompt.mode = .hang
        let m = h.makeManager()

        let start = Task { await m.start(duration: 1800) }
        await h.prompt.gate.waitUntilStarted()

        XCTAssertEqual(h.prompt.shown, 1)
        let pending = try XCTUnwrap(h.prompt.starts.first)
        XCTAssertEqual(try String(contentsOf: h.home.paths.pendingStartFile, encoding: .utf8), pending.nonce, "the marker holds the nonce while the dialog is up")
        XCTAssertNotNil(try h.store.loadSession(), "session.json must exist before the dialog")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "ownership must be journaled before the dialog")
        XCTAssertEqual(h.backstop.arms, 1, "the backstop must be armed before the dialog")
        XCTAssertNil(m.session, "no session is surfaced while the dialog is up")

        await h.prompt.gate.open()
        await start.value

        try assertRolledBackClean(m)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("not answered within"), err)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    private func waitUntil(_ what: String, within seconds: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A prompt whose process will not stop is reported with its pid and
    /// waited for: the marker goes at once, session.json, the journal entry
    /// and the recovery lock stay, an end requested meanwhile queues behind
    /// it, nothing is killed, the menu stops naming the pid once osascript
    /// exits, and the rollback runs once the whole prompt has exited.
    func testStuckPromptIsReportedWithItsPidAndRolledBackAfterItExits() async throws {
        h.prompt.mode = .stuck
        let m = h.makeManager()

        let start = Task { await m.start(duration: 1800) }
        try await waitUntil("the stuck prompt is reported") {
            h.notifier.posts.contains { $0.title == "Password prompt still running" }
        }

        let handle = try XCTUnwrap(h.prompt.unfinished)
        XCTAssertTrue(handle.isRunning)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertTrue(post.body.contains("pid 4242"), post.body)
        XCTAssertFalse(post.body.contains("kill"), "a notification outlives the pid, which may be reused: \(post.body)")
        XCTAssertTrue(try XCTUnwrap(m.lastError).hasSuffix("kill 4242"), "the menu line offers it while osascript runs")
        XCTAssertNil(m.session, "no session is surfaced")
        XCTAssertFalse(markerExists, "an answer that still comes must not turn sleep off")
        XCTAssertNotNil(try h.store.loadSession(), "session.json stays so the backstop honours the deadline")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the journal entry stays")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "nothing is rolled back beside a command that may still run")
        XCTAssertNil(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire(), "the recovery lock stays held")

        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "the end waits behind the prompt")

        // osascript exits while a command it started still holds its
        // output: the menu line stops offering the kill at once, and
        // nothing else moves.
        handle.markOsascriptExited()
        try await waitUntil("the menu line drops the kill") {
            !(m.lastError?.contains("kill") ?? true)
        }
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("a command it started as root is still running"), m.lastError ?? "")
        XCTAssertTrue(handle.isRunning)
        XCTAssertEqual(h.notifier.posts.filter { $0.title == "Password prompt still running" }.count, 1, "the change is a menu line, not a second notification")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "the rollback still waits for the output to close")
        XCTAssertNotNil(try h.store.loadSession())

        handle.markExited()
        await start.value
        XCTAssertFalse(m.lastError?.contains("kill") ?? false, "the menu line drops the pid once it has exited: \(m.lastError ?? "")")
        _ = await end.value
        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 0" }.count, 1, "\(h.guardFake.calls)")
        XCTAssertTrue(h.notifier.posts.contains { $0.title == "Session not started" })
        XCTAssertEqual(h.prompt.shown, 1)
    }

    // MARK: Abandoned dialog

    /// The app died while its dialog was up: session.json, the journal
    /// entry and the marker are on disk, sleep is still on. The relaunch
    /// deletes the marker under the lock and ends the session; a late
    /// answer to the old dialog then runs nothing.
    func testRelaunchVoidsTheDialogOfAStartThatDied() async throws {
        _ = try seedValidSession()
        let orphan = PendingStart(marker: h.home.paths.pendingStartFile, nonce: UUID().uuidString)
        try h.store.savePendingStart(orphan.nonce)
        h.guardFake.sleepDisabled = false
        let m = h.makeManager()
        await m.reconcile()

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 0)
        let late = try runRootCommand(marker: orphan.marker, nonce: orphan.nonce, in: h.home.root)
        XCTAssertEqual(late.status, 3, late.stderr)
        XCTAssertEqual(late.pmsetCalls, [], "the late answer must not turn sleep off")
    }

    /// The same, and the user has started again since: the old dialog's
    /// nonce is not the new start's, so it still runs nothing.
    func testDialogOfAStartThatDiedCannotActForANewerStart() async throws {
        _ = try seedValidSession()
        let orphan = PendingStart(marker: h.home.paths.pendingStartFile, nonce: UUID().uuidString)
        try h.store.savePendingStart(orphan.nonce)
        h.guardFake.sleepDisabled = false
        let m = h.makeManager()
        await m.reconcile()

        h.prompt.mode = .hang
        let start = Task { await m.start(duration: 1800) }
        await h.prompt.gate.waitUntilStarted()
        let newer = try XCTUnwrap(h.prompt.starts.first)
        XCTAssertNotEqual(newer.nonce, orphan.nonce)
        let late = try runRootCommand(marker: orphan.marker, nonce: orphan.nonce, in: h.home.root)
        XCTAssertEqual(late.status, 3, late.stderr)
        XCTAssertEqual(late.pmsetCalls, [])
        XCTAssertEqual(try String(contentsOf: newer.marker, encoding: .utf8), newer.nonce, "the newer start's marker is untouched")

        await h.prompt.gate.open()
        await start.value
        try assertRolledBackClean(m)
    }

    /// Any transaction that takes the lock clears a leftover marker, not
    /// only reconcile.
    func testAnyTransactionClearsALeftoverMarker() async throws {
        let m = h.makeManager()
        try h.store.savePendingStart(UUID().uuidString)
        await m.setLowPower(true)
        XCTAssertFalse(markerExists)
    }

    // MARK: Relaunch

    func testReconcileWithSleepStillOffContinuesWithoutPrompt() async throws {
        let s = try seedValidSession()
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(m.session, s)
        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertEqual(h.guardFake.calls, ["pmset -g"])
        XCTAssertEqual(h.backstop.arms, 1)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNil(m.lastError)
        XCTAssertTrue(h.notifier.posts.isEmpty, "\(h.notifier.posts)")
    }

    func testReconcileWithSleepReenabledEndsTheSessionWithoutPrompt() async throws {
        _ = try seedValidSession()
        h.guardFake.sleepDisabled = false
        let m = h.makeManager()
        await m.reconcile()

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 0, "a relaunch must never ask for the password")
        // The journal still said ours, so the undo is retried; it is the
        // passwordless line and harmless when sleep is already on.
        XCTAssertEqual(h.guardFake.calls, ["pmset -g", "disablesleep 0"])
        let last = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(last.title, "Session ended")
        XCTAssertEqual(last.body, "Sleep was turned back on while Insomnia was not running, so the session ended.")
    }

    func testReconcileWithUnreadableSleepSettingEndsTheSessionWithoutPrompt() async throws {
        _ = try seedValidSession()
        h.guardFake.sleepDisabled = true
        h.guardFake.throwOn = ["pmset -g"]
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"))
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not read the sleep setting"), err)
    }

    /// Every lifecycle path other than Start, on a session that came back
    /// from disk and on one started here: none of them shows the dialog.
    func testOnlyStartShowsThePrompt() async throws {
        _ = try seedValidSession()
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertTrue(m.isActive)

        await m.extend(by: 600)
        await m.setLowPower(true)
        await m.setLowPower(false)
        await m.undoLidActions()
        m.pauseCountdown()
        m.resumeCountdown()
        await m.end(reason: .user)
        XCTAssertEqual(h.prompt.shown, 0, "\(h.guardFake.calls)")

        // A relaunch over the now clean disk, then one explicit Start.
        let again = h.makeManager()
        await again.reconcile()
        XCTAssertEqual(h.prompt.shown, 0)
        await again.start(duration: 1800)
        XCTAssertEqual(h.prompt.shown, 1)
        await again.extend(by: 600)
        await again.setLowPower(true)
        await again.setLowPower(false)
        XCTAssertEqual(h.prompt.shown, 1, "\(h.guardFake.calls)")
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 1" }.count, 1)
    }
}
