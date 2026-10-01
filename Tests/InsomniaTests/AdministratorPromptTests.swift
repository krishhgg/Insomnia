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
    private var marker: URL { dir.appendingPathComponent("marker") }

    /// A fake osascript. `body` runs after the arguments were recorded, one
    /// per line, in `argsFile`.
    private func fakeOsascript(_ body: String) throws -> String {
        let url = dir.appendingPathComponent("osascript")
        let script = """
        #!/bin/bash
        for a in "$@"; do printf '%s\\n' "$a" >> '\(argsFile.path)'; done
        \(body)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func recordedArgs() throws -> [String] {
        try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// The whole script is one literal: the command, the privilege flag and
    /// the dialog text, with nothing interpolated.
    func testScriptIsTheExactLiteral() {
        XCTAssertEqual(
            AdministratorPrompt.disableSleepScript,
            "do shell script \"/usr/bin/pmset -a disablesleep 1\" with administrator privileges with prompt \"Insomnia needs your password to turn off system sleep for this session.\""
        )
    }

    func testRunsTheFixedScriptThroughOsascriptAndSucceedsOnExitZero() async throws {
        let exe = try fakeOsascript("exit 0")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        try await prompt.disableSleep()
        XCTAssertEqual(try recordedArgs(), ["-e", AdministratorPrompt.disableSleepScript])
    }

    func testCancelledDialogIsReportedAsCancelled() async throws {
        let exe = try fakeOsascript("echo 'execution error: User canceled. (-128)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep()
            XCTFail("a cancelled dialog must throw")
        } catch AdministratorPromptError.cancelled {
            // expected
        }
    }

    func testWrongPasswordIsAFailureThatKeepsStderr() async throws {
        let exe = try fakeOsascript("echo 'execution error: The administrator user name or password was incorrect. (-60007)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep()
            XCTFail("a failed dialog must throw")
        } catch let AdministratorPromptError.failed(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.contains("incorrect"), stderr)
        }
    }

    func testMissingExecutableIsALaunchFailure() async throws {
        let prompt = OsascriptAdministratorPrompt(executable: dir.appendingPathComponent("absent").path, timeout: 5)
        do {
            try await prompt.disableSleep()
            XCTFail("must throw")
        } catch AdministratorPromptError.launchFailed {
            // expected
        }
    }

    /// At the deadline the child gets SIGTERM and nothing stronger, and the
    /// runner waits for it to finish before reporting the timeout. The fake
    /// traps TERM, takes 1.5 s to exit (longer than the 1 s SIGKILL grace
    /// CancellableCommand would allow) and exits 0; it is still a timeout.
    /// The deadline is 3 s so that a loaded machine still has the trap
    /// installed before the signal lands.
    func testTimeoutSendsSigtermOnlyAndWaitsForTheChildToExit() async throws {
        let exe = try fakeOsascript("""
        trap 'echo term >> "\(marker.path)"; kill $! 2>/dev/null; sleep 1.5; echo clean >> "\(marker.path)"; exit 0' TERM
        sleep 30 >/dev/null 2>&1 &
        wait $!
        echo untouched >> "\(marker.path)"
        """)
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 3)
        let began = Date()
        do {
            try await prompt.disableSleep()
            XCTFail("must time out")
        } catch let AdministratorPromptError.timedOut(seconds) {
            XCTAssertEqual(seconds, 3)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 4.5, "returned before the child had exited")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "term\nclean\n", "the child was not left to finish its TERM handler")
    }
}

/// PmsetSleepGuard routes only `disablesleep 1` through the dialog. Its
/// `sudo -n` paths run the real sudo and are not exercised here.
final class PmsetSleepGuardPromptTests: XCTestCase {
    func testDisableSleepGoesThroughThePrompt() async throws {
        let prompt = FakeAdministratorPrompt()
        let sleepGuard = PmsetSleepGuard(prompt: prompt)
        try await sleepGuard.setSleepDisabled(true)
        XCTAssertEqual(prompt.shown, 1)
    }

    func testCancelledPromptSurfacesAsCancelled() async throws {
        let prompt = FakeAdministratorPrompt()
        prompt.mode = .cancel
        let sleepGuard = PmsetSleepGuard(prompt: prompt)
        do {
            try await sleepGuard.setSleepDisabled(true)
            XCTFail("must throw")
        } catch AdministratorPromptError.cancelled {
            // expected
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

    private func assertRolledBackClean(_ m: SessionManager, file: StaticString = #filePath, line: UInt = #line) throws {
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
