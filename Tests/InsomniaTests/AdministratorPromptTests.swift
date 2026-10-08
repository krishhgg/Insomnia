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
    private var start: PendingStart { PendingStart(marker: dir.appendingPathComponent("pending-start"), nonce: "nonce-1", deadline: Date().addingTimeInterval(3600)) }

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

    /// The whole script is one literal: lockf on the marker, the root
    /// command with each `"` escaped for AppleScript, the marker path,
    /// nonce, deadline, uid and ownership flag taken from argv through
    /// `quoted form of`, the privilege flag and the dialog text.
    func testScriptIsTheExactLiteral() {
        let embedded = AdministratorPrompt.rootCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        XCTAssertEqual(AdministratorPrompt.markerLock, "/usr/bin/lockf -k -n -t 10")
        XCTAssertEqual(AdministratorPrompt.disableSleepScript, """
        on run argv
        do shell script "\(AdministratorPrompt.markerLock) " & quoted form of (item 1 of argv) & " /bin/sh -c " & quoted form of "\(embedded)" & " insomnia " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & quoted form of (item 4 of argv) & " " & quoted form of (item 5 of argv) with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session."
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
        let compileExit = ProcessExit(process)
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        compileExit.wait()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errData, as: UTF8.self))
    }

    /// The deadline goes as whole seconds since 1970, rounded down, the
    /// uid is this process's (the user whose rule the restore check must
    /// find), and the ownership flag is `1` only when the journal already
    /// owned the SleepDisabled 1.
    func testRunsTheFixedScriptThroughOsascriptWithTheMarkerNonceDeadlineUidAndOwnershipAsArguments() async throws {
        let exe = try fakeOsascript("exit 0")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        let odd = PendingStart(marker: dir.appendingPathComponent("it's \"pending\" $(x)"), nonce: "nonce-1", deadline: Date(timeIntervalSince1970: 1_800_000_900.9))
        try await prompt.disableSleep(odd)
        XCTAssertEqual(try recordedArgs(), ["-e", AdministratorPrompt.disableSleepScript, odd.marker.path, "nonce-1", "1800000900", String(getuid()), "0"])

        try FileManager.default.removeItem(at: argsFile)
        var owned = odd
        owned.sleepOffIsOurs = true
        try await prompt.disableSleep(owned)
        XCTAssertEqual(try recordedArgs(), ["-e", AdministratorPrompt.disableSleepScript, odd.marker.path, "nonce-1", "1800000900", String(getuid()), "1"])
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

    /// Only the dialog's own -128 is a cancel. A command that ran ends
    /// osascript's error with its own status, whatever its message
    /// contains (here a marker path with the cancel text in it): lockf's
    /// 69, no marker.
    func testCancelTextInACommandsOutputIsNotACancel() async throws {
        let exe = try fakeOsascript("echo 'execution error: lockf: /x/User canceled. (-128)/pending-start: No such file or directory (69)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("must throw")
        } catch let AdministratorPromptError.refused(status, stderr) {
            XCTAssertEqual(status, 69)
            XCTAssertTrue(stderr.hasSuffix("(69)\n"), stderr)
        }
    }

    /// The root command exits 5 when sudo does not confirm the restore,
    /// before anything is written; osascript ends its error with that
    /// status. The error says what to do about it.
    func testARefusedRestoreCheckIsReportedWithTheFix() async throws {
        let exe = try fakeOsascript("printf '0:812: execution error: sudo: a password is required\\rsudo -k -n -l did not list this user'\\''s sudoers rules without a password; sleep was not turned off (5)\\n' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("must throw")
        } catch let error as AdministratorPromptError {
            guard case .restoreNeedsPassword = error else { return XCTFail("\(error)") }
            let text = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(text.hasPrefix("sleep was not turned off: sudo did not confirm that `sudo -n /usr/bin/pmset -a disablesleep 0` runs for you without a password ("), text)
            XCTAssertTrue(text.contains("sudo: a password is required"), text)
            XCTAssertTrue(text.contains("If /etc/sudoers.d/insomnia is missing or not in effect, run scripts/install.sh again."), text)
            XCTAssertTrue(text.hasSuffix("install.sh changes none of those, and the message above names the one found"), text)
        }
    }

    /// Only an exit of exactly 5 is the restore check's.
    func testOtherStatusesAreNotARefusedRestoreCheck() async throws {
        for status in ["15", "-5", "1"] {
            try? FileManager.default.removeItem(at: argsFile)
            let exe = try fakeOsascript("echo 'execution error: pmset: (5) failed (\(status))' >&2; exit 1")
            do {
                try await OsascriptAdministratorPrompt(executable: exe, timeout: 5).disableSleep(start)
                XCTFail("must throw")
            } catch let AdministratorPromptError.failed(code, _) {
                XCTAssertEqual(code, 1, status)
            }
        }
    }

    func testOnlyCancelLaunchFailureAndARootRefusalLeaveNothingToUndo() {
        XCTAssertTrue(AdministratorPromptError.cancelled.nothingToUndo)
        XCTAssertTrue(AdministratorPromptError.launchFailed("x").nothingToUndo)
        XCTAssertTrue(AdministratorPromptError.restoreNeedsPassword(stderr: "").nothingToUndo)
        XCTAssertTrue(AdministratorPromptError.refused(rootStatus: 6, stderr: "").nothingToUndo)
        XCTAssertFalse(AdministratorPromptError.timedOut(seconds: 1).nothingToUndo)
        XCTAssertFalse(AdministratorPromptError.failed(status: 1, stderr: "").nothingToUndo)
        XCTAssertFalse(AdministratorPromptError.stillRunning(UnfinishedPrompt(pid: 1, osascriptAlive: false), grace: 1).nothingToUndo)
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

    /// The root command's refusal reaches the caller with its status and
    /// message, the way `do shell script` reports a non-zero exit.
    func testAbandonedStartIsARefusalThatKeepsStderr() async throws {
        let exe = try fakeOsascript("echo 'execution error: the start that asked for this password is over; sleep was not turned off (3)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("must throw")
        } catch let AdministratorPromptError.refused(status, stderr) {
            XCTAssertEqual(status, 3)
            XCTAssertTrue(stderr.contains("sleep was not turned off"), stderr)
        }
    }

    /// Each exit that means the root command stopped before it wrote
    /// anything (its own 3, 4, 6 and 7, lockf's 69 and 75) is a refusal:
    /// nothing to undo, and the error names the status.
    func testRootRefusalsLeaveNothingToUndo() async throws {
        for status: Int32 in [3, 4, 6, 7, 69, 75] {
            try? FileManager.default.removeItem(at: argsFile)
            let exe = try fakeOsascript("printf '0:1: execution error: stopped\\rsleep was not turned off (\(status))\\n' >&2; exit 1")
            do {
                try await OsascriptAdministratorPrompt(executable: exe, timeout: 5).disableSleep(start)
                XCTFail("must throw: \(status)")
            } catch let error as AdministratorPromptError {
                guard case let .refused(code, _) = error else { return XCTFail("\(status): \(error)") }
                XCTAssertEqual(code, status)
                XCTAssertTrue(error.nothingToUndo, "\(status)")
                let text = try XCTUnwrap(error.errorDescription)
                XCTAssertTrue(text.hasPrefix("Insomnia did not turn sleep off (the command behind the password dialog stopped with status \(status) before it changed anything)"), text)
            }
        }
    }

    /// Every other status, and a status that is not the end of the line,
    /// may have come after `disablesleep 1` (pmset's failure is 1, a
    /// signal 128 and up), so it stays an ambiguous failure the start
    /// undoes like an end.
    func testOtherRootStatusesAreFailuresToUndo() async throws {
        let lines = ["(1)", "(2)", "(8)", "(70)", "(71)", "(73)", "(126)", "(127)", "(143)", "(255)", "(-6)", "( 6)", "(6) pmset failed (1)", "(6).", "6"]
        for line in lines {
            try? FileManager.default.removeItem(at: argsFile)
            let exe = try fakeOsascript("printf '%s\\n' 'execution error: pmset failed \(line)' >&2; exit 1")
            do {
                try await OsascriptAdministratorPrompt(executable: exe, timeout: 5).disableSleep(start)
                XCTFail("must throw: \(line)")
            } catch let error as AdministratorPromptError {
                guard case .failed = error else { return XCTFail("\(line): \(error)") }
                XCTAssertFalse(error.nothingToUndo, line)
            }
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
    /// The deadline starts only once the trap is installed. The grace is
    /// set here, not taken from the default, and a machine slow enough to
    /// outlast it gets `.stillRunning`, whose handle is awaited: either way
    /// the handler must have finished, untouched by anything stronger.
    func testTimeoutSendsSigtermOnlyAndWaitsForTheChildToExit() async throws {
        let ready = dir.appendingPathComponent("ready")
        let exe = try fakeOsascript("""
        trap 'echo term >> "\(trace.path)"; kill $! 2>/dev/null; sleep 1.5; echo clean >> "\(trace.path)"; exit 0' TERM
        : > '\(ready.path)'
        sleep 30 >/dev/null 2>&1 &
        wait $!
        echo untouched >> "\(trace.path)"
        """)
        let grace: TimeInterval = 20
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 1, grace: grace, beforeDeadline: untilExists(ready))
        let began = Date()
        do {
            try await prompt.disableSleep(start)
            XCTFail("must time out")
        } catch let AdministratorPromptError.timedOut(seconds) {
            XCTAssertEqual(seconds, 1)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 2.5, "returned before the child had exited")
        } catch let AdministratorPromptError.stillRunning(handle, reported) {
            XCTAssertEqual(reported, grace)
            await handle.waitUntilExit()
        }
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
/// /bin/sh with the dialog's quoting, the real lockf, a fake pmset and a
/// fake sudo that answers as a sudoers policy would (RootCommandProcess).
final class RootCommandTests: XCTestCase {
    private var dir: URL!

    /// The receipt the command writes: TestReceipts in `dir`, which every
    /// run here uses unless it is given another.
    private var receipts: SleepOffReceipts!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-root-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        receipts = try TestReceipts.make(in: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var marker: URL { dir.appendingPathComponent("pending-start") }
    private var store: Store { Store(paths: Paths(root: dir)) }
    private var uid: String { String(getuid()) }

    /// Nonces as the app makes them (`UUID().uuidString`). The command
    /// takes only an uppercase UUID, since the receipt holds it.
    private let nonce1 = "6F1C2B4A-0000-4000-8000-000000000001"
    private let nonce2 = "6F1C2B4A-0000-4000-8000-000000000002"

    /// The receipt's content: its 45 bytes as text.
    private var receipt: String? { TestReceipts.text(receipts) }
    private func line(_ nonce: String, _ word: String) -> String { "\(nonce) \(word)\n" }

    /// Puts install.sh's content back in the receipt, in place.
    private func resetReceipt() {
        TestReceipts.write(receipts.file, nonce: "00000000-0000-0000-0000-000000000000", word: "refused")
    }

    /// The three questions, in order, each as root's sudo to the user and
    /// as the user's own sudo it starts.
    private var queries: [String] {
        let asUser = "-n -u #\(uid) /usr/bin/env -i LC_ALL=C /usr/bin/sudo "
        return ["-V", "-k -n -l", "-k -n -ll /usr/bin/pmset -a disablesleep 0"].flatMap { [asUser + $0, $0] }
    }

    /// Every pmset call of a command that turns sleep off: its read, then
    /// its only write.
    private let allCalls = ["-g", "-a disablesleep 1"]

    /// Every sudo call of a command that gets past the questions: only
    /// those. Root writes the receipt itself, and nothing writes the marker.
    private var throughTheRecord: [String] { queries }

    /// With the rule in effect, root asks the user's sudo three questions
    /// (through `sudo -u`, then `env -i LC_ALL=C`), reads sleep on, and
    /// turns it off. Nothing else runs pmset.
    func testTurnsSleepOffOnceSudoConfirmsThePasswordlessRestore() throws {
        try Data(nonce1.utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.sudoCalls, throughTheRecord)
        XCTAssertEqual(r.envCalls, ["-V", "-k -n -l", "-k -n -ll /usr/bin/pmset -a disablesleep 0"].map { "-i LC_ALL=C /usr/bin/sudo " + $0 })
        XCTAssertEqual(r.pmsetCalls, allCalls)
        XCTAssertEqual(r.pmsetAs, ["root", "root"])
        XCTAssertEqual(r.sleepDisabled, "1")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1, "lockf -k leaves the file, and nothing writes it")
        XCTAssertEqual(receipt, line(nonce1, "writing"), "the receipt records the start before its write")
    }

    /// Round 17 R1: the check used to run the restore, after root had
    /// turned sleep off for it to undo. Now the user's sudo only lists and
    /// prints its version, and the line it lists is the one every end runs
    /// (`sudo -n /usr/bin/pmset` with `PmsetSleepGuard.restoreArguments`).
    func testTheQueriesNameTheRestoreTheEndRunsAndRunNothing() throws {
        let endLine = ([PmsetSleepGuard.pmset] + PmsetSleepGuard.restoreArguments).joined(separator: " ")
        XCTAssertEqual(RootCommandProcess.ruleQuery, "sudo -k -n -ll " + endLine)
        XCTAssertTrue(AdministratorPrompt.rootCommand.contains("r=$(q -k -n -ll \(endLine))"))
        XCTAssertTrue(AdministratorPrompt.rootCommand.contains("BEGIN { c = \"\(endLine)\" }"))
        try Data(nonce1.utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.sudoCalls.filter { !$0.hasPrefix("-n -u ") }, ["-V", "-k -n -l", "-k -n -ll " + endLine], "each of the user's sudo calls lists or prints a version; none runs a command")
        XCTAssertEqual(r.pmsetAs, ["root", "root"], "no pmset runs as the user")
    }

    /// Every policy but the rule makes the command exit 5 before it reads
    /// or writes pmset, in both copies of the command, and none prompts.
    /// Each stops at the first answer that does not fit: root's switch to
    /// the user, `-V`, `-l` or `-ll`.
    func testEveryOtherPolicyRefusesBeforeAnyPmset() throws {
        let version = "sudo -V, run as this user, failed or does not show sudo 1.9.17p2 with only the sudoers plugins."
        let listing = "sudo -k -n -l did not list this user's sudoers rules without a password"
        let defaults = "sudo -k -n -l shows a Defaults entry this check does not accept: "
        let rule = "sudo -k -n -ll does not show the rule in /etc/sudoers.d/insomnia"
        // How many of `queries` each policy lets run, and what it says.
        let stops: [RootSudoPolicy: (calls: Int, says: String)] = [
            .noRootEntry: (1, version), .oldSudo: (2, version), .newSudo: (2, version),
            .noRule: (4, listing),
            .boundDefaults: (4, defaults + "Defaults bound to a Runas user or a command, which apply to the restore but not to a listing."),
            .userDefaults: (4, defaults + "log_output. Settings like that can make the restore fail where a listing does not"),
            .listOnly: (6, rule), .noTag: (6, rule), .deny: (6, rule), .laterRule: (6, rule), .runAsAll: (6, rule),
            .extraOption: (6, rule), .timeLimited: (6, rule), .ldap: (6, rule), .pathOnly: (6, rule), .truncated: (6, rule),
        ]
        XCTAssertEqual(Set(stops.keys).union([.rule, .etcPath]), Set(RootSudoPolicy.allCases), "every policy is covered")
        for (policy, stop) in stops.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for (name, command) in try bothCommands() {
                try Data(nonce1.utf8).write(to: marker)
                let r = try runRootCommand(marker: marker, nonce: nonce1, policy: policy, command: command, receipts: receipts, in: dir)
                let label = "\(policy) \(name)"
                XCTAssertEqual(r.status, 5, "\(label): \(r.stderr)")
                XCTAssertEqual(r.sudoCalls, Array(queries.prefix(stop.calls)), label)
                XCTAssertEqual(r.pmsetCalls, [], "\(label): nothing read, nothing written")
                XCTAssertEqual(r.sleepDisabled, "0", label)
                XCTAssertTrue(r.stderr.contains(stop.says), "\(label): \(r.stderr)")
                XCTAssertTrue(r.stderr.hasSuffix("sleep was not turned off\n"), "\(label): \(r.stderr)")
                XCTAssertFalse(r.stderr.contains("fake "), "\(label): a fake was used as the command never uses it: \(r.stderr)")
            }
        }
    }

    /// Round 19 P1 (silent approval plugin). `sudo -V` lists no approval
    /// plugin whose show_version is NULL, and sudo consults approval
    /// plugins only when it runs a command, so no answer the user's sudo
    /// gives can show one. The fixture loads such a plugin from a private
    /// sudo.conf: the fake sudo's answers stay those of the rule, and the
    /// restore is rejected. Any /etc/sudo.conf now stops the command
    /// before it runs sudo at all, whatever the file holds.
    func testAnySudoConfStopsTheCommandBeforeSudoRuns() throws {
        let confs = [
            "a silent approval plugin": SudoFormat.silentApprovalConf,
            "an empty file": "",
            "comments only": "# Plugin sudoers_policy sudoers.so\n",
            "a setting, no plugin": "Set disable_coredump false\n",
        ]
        for (what, conf) in confs {
            for (name, command) in try bothCommands() {
                try Data(nonce1.utf8).write(to: marker)
                let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, sudoConf: conf, receipts: receipts, in: dir)
                let label = "\(what), \(name)"
                XCTAssertEqual(r.status, 5, "\(label): \(r.stderr)")
                XCTAssertEqual(r.sudoCalls, [], label)
                XCTAssertEqual(r.pmsetCalls, [], label)
                XCTAssertTrue(r.stderr.contains("/etc/sudo.conf exists. sudo -V does not list every plugin that file can load"), "\(label): \(r.stderr)")
                XCTAssertTrue(r.stderr.hasSuffix("sleep was not turned off\n"), "\(label): \(r.stderr)")
            }
        }
    }

    /// The fixture's plugin behaves as the source says such a plugin does:
    /// the version, the listing and the rule check answer as without it,
    /// and only running the restore fails. Before this round, the command
    /// took those answers and turned sleep off (the round 19 review's
    /// probe); the restore at the session's end would then fail.
    func testTheSilentApprovalFixtureChangesNothingButTheRestore() throws {
        let tools = dir.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let fake = try FakeDialogMachine(in: tools, clockStart: 1_800_000_000, clockLater: 1_800_000_005)
        func run(_ args: [String]) throws -> (status: Int32, out: String) {
            let p = Process()
            let out = Pipe()
            p.executableURL = fake.sudo
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("FAKE_") }
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let exit = ProcessExit(p)
            try p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            exit.wait()
            return (p.terminationStatus, text)
        }
        let questions = [["-V"], ["-k", "-n", "-l"], ["-k", "-n", "-ll", "/usr/bin/pmset", "-a", "disablesleep", "0"]]
        let restore = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
        let without = try questions.map(run)
        XCTAssertEqual(try run(restore).status, 0, "the restore runs without the plugin")
        fake.sudoConf = SudoFormat.silentApprovalConf
        let with = try questions.map(run)
        XCTAssertEqual(with.map(\.status), without.map(\.status))
        XCTAssertEqual(with.map(\.out), without.map(\.out))
        XCTAssertEqual(try run(restore).status, 1, "the plugin rejects the restore")
    }

    /// sudo opens a PAM session for a command it runs, never for a listing
    /// (pam.c in sudoers), so only macOS's own single `session required
    /// pam_permit.so` line, which cannot fail, lets the listing stand for
    /// the restore. Comments and lines of the other stacks do not matter.
    func testOnlyMacOSsOwnPamSessionLinePasses() throws {
        let stock = SudoFormat.macPamSudo
        let accepted = [
            "macOS's own": stock,
            "a comment that names a session": stock + "# session optional pam_foo.so\n",
            "another auth line": stock.replacingOccurrences(of: "auth       include        sudo_local\n", with: "auth       include        sudo_local\nauth       sufficient     pam_tid.so\n"),
        ]
        let refused: [String: String?] = [
            "no file": nil,
            "a second session line": stock + "session    optional       pam_launchd.so\n",
            "an option on the line": stock.replacingOccurrences(of: "session    required       pam_permit.so", with: "session    required       pam_permit.so debug"),
            "another module": stock.replacingOccurrences(of: "session    required       pam_permit.so", with: "session    required       pam_deny.so"),
            "an include": stock.replacingOccurrences(of: "session    required       pam_permit.so", with: "session    include        sudo_local"),
            "no session line": stock.replacingOccurrences(of: "session    required       pam_permit.so\n", with: ""),
        ]
        for (what, pam) in accepted {
            try Data(nonce1.utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: nonce1, pamSudo: pam, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 0, "\(what): \(r.stderr)")
        }
        for (what, pam) in refused {
            try Data(nonce1.utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: nonce1, pamSudo: pam, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 5, "\(what): \(r.stderr)")
            XCTAssertEqual(r.sudoCalls, [], what)
            XCTAssertEqual(r.pmsetCalls, [], what)
            XCTAssertTrue(r.stderr.contains("/etc/pam.d/sudo could not be read, or its session lines are not macOS's own single session required pam_permit.so"), "\(what): \(r.stderr)")
        }
    }

    /// sudo names the rule's file as the includedir names it:
    /// /private/etc/sudoers.d on macOS, /etc/sudoers.d under an
    /// `#includedir /etc/sudoers.d`. Either is the rule.
    func testTakesTheRuleUnderEitherNameOfItsFile() throws {
        for policy: RootSudoPolicy in [.rule, .etcPath] {
            try Data(nonce1.utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: nonce1, policy: policy, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 0, "\(policy): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, allCalls, "\(policy)")
        }
    }

    /// The questions are about the user who pressed Start. Asked of
    /// another user, who has no sudoers lines, they fail.
    func testTheQueriesAreForTheUserTheyAreGiven() throws {
        try Data(nonce1.utf8).write(to: marker)
        let other = String(getuid() + 1)
        let r = try runRootCommand(marker: marker, nonce: nonce1, uid: other, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.sudoCalls.first, "-n -u #\(other) /usr/bin/env -i LC_ALL=C /usr/bin/sudo -V")
        XCTAssertEqual(r.sudoCalls.count, 4, "anyone may see the version; that user's listing needs a password")
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sleepDisabled, "0")
    }

    /// A uid that is not a positive whole number is refused before sudo
    /// or pmset runs: root (0) never needs a password, so asking about
    /// root would prove nothing.
    func testAnUnusableUidRefusesWithoutRunningSudo() throws {
        try Data(nonce1.utf8).write(to: marker)
        for uid in ["", "0", "-1", "abc", "501x", "1e3", "99999999999999999999", "$(touch canary)"] {
            let r = try runRootCommand(marker: marker, nonce: nonce1, uid: uid, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 5, "uid \(uid.debugDescription): \(r.stderr)")
            XCTAssertEqual(r.sudoCalls, [], "uid \(uid.debugDescription)")
            XCTAssertEqual(r.pmsetCalls, [], "uid \(uid.debugDescription)")
            XCTAssertTrue(r.stderr.contains("no user id came with the password, so sudo could not be asked whether sleep can be turned back on without one; sleep was not turned off"), r.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("canary").path))
    }

    /// Recovery (or the start itself) deleted the marker: lockf -n has
    /// nothing to open, and a late answer runs nothing.
    func testDoesNothingOnceTheMarkerIsGone() throws {
        let r = try runRootCommand(marker: marker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 69, r.stderr)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sudoCalls, [], "no question either")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "lockf -n never creates the marker")
    }

    /// A dialog left from an older start cannot act for a newer one.
    func testDoesNothingWhenANewerStartOwnsTheMarker() throws {
        try Data(nonce2.utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sudoCalls, [])
        XCTAssertTrue(r.stderr.contains("sleep was not turned off"), r.stderr)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce2, "the newer start's marker is left alone")
    }

    func testAnEmptyNonceNeverMatches() throws {
        try Data().write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "", receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
    }

    /// A password accepted at or after the session's end asks nothing and
    /// turns nothing off, even though the marker still holds the nonce.
    func testDoesNothingOnceTheSessionHasEnded() throws {
        try Data(nonce1.utf8).write(to: marker)
        let now = Int(Date().timeIntervalSince1970)
        for deadline in [now - 1, now, now - 86_400] {
            let r = try runRootCommand(marker: marker, nonce: nonce1, deadline: String(deadline), receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 4, "deadline \(deadline): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, [], "deadline \(deadline)")
            XCTAssertEqual(r.sudoCalls, [], "deadline \(deadline)")
            XCTAssertTrue(r.stderr.contains("the session this password was for has already ended; sleep was not turned off"), r.stderr)
        }
    }

    /// The command the AppleScript literal hands to `/bin/sh -c`, read back
    /// from it, is `rootCommand` exactly. The clock tests below run that
    /// embedded copy.
    func testTheAppleScriptEmbedsTheRootCommandUnchanged() throws {
        XCTAssertEqual(try appleScriptEmbeddedRootCommand(), AdministratorPrompt.rootCommand)
    }

    /// A deadline far from the real clock, so a read that missed the fake
    /// clock would show.
    private let fakeDeadline = 2_000_000_100

    /// Each call before the write that can take a while: the three
    /// questions and root's read.
    private let slowCalls = [RootCommandProcess.versionQuery, RootCommandProcess.listQuery, RootCommandProcess.ruleQuery, RootCommandProcess.read]

    /// The command (the embedded copy unless given), started 100 s before
    /// `fakeDeadline` on a fake clock that reads `later` once the call `at`
    /// has answered.
    private func runOnFakeClock(at: String, later: Int, command: String? = nil, policy: RootSudoPolicy = .rule, sleepDisabled: String = "0", owned: String = "0", foreignAfter: String? = nil) throws -> RootCommandRun {
        try Data(nonce1.utf8).write(to: marker)
        resetReceipt()
        return try runRootCommand(
            marker: marker, nonce: nonce1, deadline: String(fakeDeadline), policy: policy,
            command: command ?? appleScriptEmbeddedRootCommand(),
            clock: RootCommandClock(start: fakeDeadline - 100, later: later, at: at),
            sleepDisabled: sleepDisabled, owned: owned, foreignAfter: foreignAfter, receipts: receipts, in: dir)
    }

    /// Control: whichever call takes the time, when it ends a second
    /// before the deadline, sleep is turned off after it.
    func testTurnsSleepOffWhenEveryAnswerComesBeforeTheDeadline() throws {
        for at in slowCalls {
            let r = try runOnFakeClock(at: at, later: fakeDeadline - 1)
            XCTAssertEqual(r.status, 0, "\(at): \(r.stderr)")
            XCTAssertEqual(r.sudoCalls, throughTheRecord, at)
            XCTAssertEqual(r.pmsetCalls, allCalls, at)
            XCTAssertEqual(r.sleepDisabled, "1", at)
        }
    }

    /// Round 17 R3. Any call before the write can use up the rest of the
    /// session: sudo may wait on a directory service, pmset on powerd.
    /// Before, the clock was read before the last `pmset -g`, so a read
    /// that ended at the deadline or later was still followed by the
    /// write. The clock is now read after the questions and again after
    /// the read, right before the write. When the deadline comes during
    /// any of them, at its very second or after, the command writes
    /// nothing, and reads nothing after it.
    func testWritesNothingWhenTheDeadlineComesDuringAnyCallBeforeTheWrite() throws {
        for at in slowCalls {
            for later in [fakeDeadline, fakeDeadline + 1, fakeDeadline + 86_400] {
                for (name, command) in try bothCommands() {
                    let label = "\(at), \(later - fakeDeadline) s after the deadline, \(name)"
                    let r = try runOnFakeClock(at: at, later: later, command: command)
                    XCTAssertEqual(r.status, 4, "\(label): \(r.stderr)")
                    XCTAssertEqual(r.sudoCalls, queries, label)
                    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1, "\(label): nothing writes the marker")
                    XCTAssertEqual(receipt, at == RootCommandProcess.read ? line(nonce1, "refused") : SleepOffReceipts.initialContent, "\(label): a deadline after the receipt's write leaves this nonce refused")
                    XCTAssertEqual(r.pmsetCalls, at == RootCommandProcess.read ? ["-g"] : [], label)
                    XCTAssertEqual(r.sleepDisabled, "0", label)
                    let says = at == RootCommandProcess.read
                        ? "the session this password was for ended while pmset -g was read; sleep was not turned off"
                        : "the session this password was for ended while sudo was asked about the restore; sleep was not turned off"
                    XCTAssertTrue(r.stderr.contains(says), "\(label): \(r.stderr)")
                }
            }
        }
    }

    /// The journal-owned path skips the read, so the comparison after the
    /// questions is the one right before the write, and it still stops it.
    func testAJournalOwnedSettingWritesNothingWhenTheDeadlineComesDuringTheQuestions() throws {
        for (name, command) in try bothCommands() {
            let r = try runOnFakeClock(at: RootCommandProcess.ruleQuery, later: fakeDeadline, command: command, sleepDisabled: "1", owned: "1")
            XCTAssertEqual(r.status, 4, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, [], name)
            XCTAssertEqual(r.sleepDisabled, "1", name)
        }
    }

    /// A refusal on the fake clock is still exit 5.
    func testARefusalStillExitsFiveOnTheFakeClock() throws {
        let r = try runOnFakeClock(at: RootCommandProcess.versionQuery, later: fakeDeadline - 1, policy: .noRule)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.sudoCalls, Array(queries.prefix(4)))
        XCTAssertEqual(r.pmsetCalls, [])
    }

    /// A deadline that is not a plain number fails the comparison, which
    /// refuses: a malformed one can never mean "no deadline".
    func testAnUnreadableDeadlineNeverPasses() throws {
        try Data(nonce1.utf8).write(to: marker)
        for deadline in ["", "soon", "1e12", "0x2540BE3FF", "9999999999s", "99999999999999999999", "$(echo 9999999999)"] {
            let r = try runRootCommand(marker: marker, nonce: nonce1, deadline: deadline, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 4, "deadline \(deadline.debugDescription): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, [], "deadline \(deadline.debugDescription)")
        }
    }

    /// When pmset's own write fails, the command exits 1, never a refusal:
    /// pmset may have changed the setting before it failed, so the start
    /// undoes it like an end.
    func testAFailedWriteIsNotARefusal() throws {
        try Data(nonce1.utf8).write(to: marker)
        let r = try RootCommandProcess(marker: marker, nonce: nonce1, writeFails: true, receipts: receipts, in: dir).wait()
        XCTAssertEqual(r.status, 1, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
        XCTAssertFalse(OsascriptAdministratorPrompt.refusalStatuses.contains(r.status))
        XCTAssertEqual(receipt, line(nonce1, "writing"), "the receipt tells the start that the write may have run")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1)
    }

    // MARK: The receipt

    /// Round 19 P1 (ownership), now in the receipt. The command writes its
    /// record only after every check and root's read, right before the
    /// last deadline check and the write, so the receipt shows which side
    /// of that line a failure came from. While sudo is asked and while
    /// root reads it still holds install.sh's content; from the write on it
    /// holds this nonce with `writing`. The marker never changes.
    func testTheReceiptTakesTheRecordOnlyAfterEveryCheckAndTheRead() throws {
        for at in [RootCommandProcess.versionQuery, RootCommandProcess.listQuery, RootCommandProcess.ruleQuery, RootCommandProcess.read] {
            try Data(nonce1.utf8).write(to: marker)
            resetReceipt()
            let command = try RootCommandProcess(marker: marker, nonce: nonce1, receipts: receipts, in: dir, holdAt: at)
            XCTAssertTrue(command.waitUntilPmsetRuns(), at)
            XCTAssertEqual(receipt, SleepOffReceipts.initialContent, "\(at): no record before the read has answered")
            command.release()
            XCTAssertEqual(command.wait().status, 0, at)
            XCTAssertEqual(receipt, line(nonce1, "writing"), at)
        }
        try Data(nonce1.utf8).write(to: marker)
        resetReceipt()
        let command = try RootCommandProcess(marker: marker, nonce: nonce1, receipts: receipts, in: dir, holdAt: RootCommandProcess.write)
        XCTAssertTrue(command.waitUntilPmsetRuns())
        XCTAssertEqual(receipt, line(nonce1, "writing"), "published, synced and read back before pmset starts")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1)
        command.release()
        XCTAssertEqual(command.wait().status, 0)
    }

    /// The receipt is written in place by root itself, not through a sudo
    /// to the user, with `dd conv=notrunc,fsync` and read back: the file
    /// keeps its inode and its 45 bytes, so a reader can tell it from a
    /// file put in its place. The marker the start wrote is the same file
    /// with the same content afterwards.
    func testTheReceiptIsWrittenInPlaceAndTheMarkerNeverIs() throws {
        XCTAssertTrue(AdministratorPrompt.rootCommand.contains(#"put() { printf '%s %s\n' "$2" "$1" | /bin/dd of="$f" conv=notrunc,fsync 2>/dev/null && [ "$(/usr/bin/head -c 45 "$f" 2>/dev/null)" = "$2 $1" ]; }"#))
        let written = try store.savePendingStart(nonce1)
        let before = FileIdentity(atPath: receipts.file)
        let r = try runRootCommand(marker: marker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(FileIdentity(atPath: receipts.file), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: receipts.file)[.size] as? Int, SleepOffReceipts.size)
        XCTAssertEqual(receipt, line(nonce1, "writing"))
        XCTAssertEqual(FileIdentity(atPath: marker.path), written)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1)
        XCTAssertEqual(r.sudoCalls, queries, "no sudo call writes anything")
    }

    /// A receipt the command cannot write and read back stops it before
    /// pmset writes, with its own refusal (7), after root's read: a dd
    /// that fails, and a receipt this run cannot write. Nothing of this
    /// start is left in it.
    func testAReceiptThatCannotBeWrittenStopsBeforeTheWrite() throws {
        for (name, command) in try bothCommands() {
            for unwritable in [false, true] {
                try Data(nonce1.utf8).write(to: marker)
                resetReceipt()
                if unwritable { XCTAssertEqual(chmod(receipts.file, 0o444), 0) }
                defer { chmod(receipts.file, 0o644) }
                let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, receipts: receipts, receiptWriteFails: !unwritable, in: dir)
                let label = "\(name), \(unwritable ? "read-only receipt" : "dd fails")"
                XCTAssertEqual(r.status, 7, "\(label): \(r.stderr)")
                XCTAssertEqual(r.pmsetCalls, ["-g"], label)
                XCTAssertEqual(r.sleepDisabled, "0", label)
                XCTAssertEqual(receipt, SleepOffReceipts.initialContent, label)
                XCTAssertTrue(r.stderr.contains("could not be written, synced and read back with this start's nonce; sleep was not turned off"), "\(label): \(r.stderr)")
                XCTAssertTrue(OsascriptAdministratorPrompt.refusalStatuses.contains(r.status), label)
            }
        }
    }

    /// Every receipt that is not the file install.sh made, or that someone
    /// other than root (here, the test user standing in for root) could
    /// change, or whose folders above could, stops the command before
    /// root's read, with nothing written anywhere.
    func testAMissingOrUnsafeReceiptStopsBeforeTheRead() throws {
        let file = URL(fileURLWithPath: receipts.file)
        let folder = URL(fileURLWithPath: receipts.folder)
        let above = folder.deletingLastPathComponent().path
        let user = String(cString: getpwuid(getuid()).pointee.pw_name)
        func acl(_ path: String, _ spec: String?) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/chmod")
            p.arguments = spec.map { ["+a", $0, path] } ?? ["-N", path]
            let exit = ProcessExit(p)
            XCTAssertNoThrow(try p.run())
            exit.wait()
            XCTAssertEqual(p.terminationStatus, 0, path)
        }
        func put(_ text: String) throws { try Data(text.utf8).write(to: file) }
        let initial = SleepOffReceipts.initialContent
        let cases: [(what: String, change: () throws -> Void, undo: () throws -> Void)] = [
            ("missing", { try FileManager.default.removeItem(at: file) }, { try put(initial) }),
            ("44 bytes", { try put(String(initial.dropLast())) }, { try put(initial) }),
            ("46 bytes", { try put(initial + "\n") }, { try put(initial) }),
            ("group-writable", { XCTAssertEqual(chmod(file.path, 0o664), 0) }, { XCTAssertEqual(chmod(file.path, 0o644), 0) }),
            ("writable by others", { XCTAssertEqual(chmod(file.path, 0o646), 0) }, { XCTAssertEqual(chmod(file.path, 0o644), 0) }),
            ("a second link", { XCTAssertEqual(link(file.path, folder.path + "/other"), 0) }, { XCTAssertEqual(unlink(folder.path + "/other"), 0) }),
            ("a symbolic link to a 45-byte file", {
                try Data(initial.utf8).write(to: folder.appendingPathComponent("target"))
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: folder.appendingPathComponent("target").path)
            }, {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.removeItem(at: folder.appendingPathComponent("target"))
                try put(initial)
            }),
            ("a folder in its place", {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }, {
                try FileManager.default.removeItem(at: file)
                try put(initial)
            }),
            ("an allow entry on the receipt", { acl(file.path, "user:\(user) allow write") }, { acl(file.path, nil) }),
            ("a group-writable folder", { XCTAssertEqual(chmod(folder.path, 0o775), 0) }, { XCTAssertEqual(chmod(folder.path, 0o755), 0) }),
            ("an allow entry on the folder", { acl(folder.path, "user:\(user) allow add_file") }, { acl(folder.path, nil) }),
            ("an allow entry on the folder above", { acl(above, "user:\(user) allow add_subdirectory") }, { acl(above, nil) }),
            ("a folder above writable by others", { XCTAssertEqual(chmod(above, 0o757), 0) }, { XCTAssertEqual(chmod(above, 0o755), 0) }),
        ]
        for c in cases {
            for (name, command) in try bothCommands() {
                try Data(nonce1.utf8).write(to: marker)
                resetReceipt()
                try c.change()
                let before = try? Data(contentsOf: file)
                let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, receipts: receipts, in: dir)
                let after = try? Data(contentsOf: file)
                try c.undo()
                let label = "\(c.what), \(name)"
                XCTAssertEqual(r.status, 7, "\(label): \(r.stderr)")
                XCTAssertEqual(r.pmsetCalls, [], "\(label): nothing read, nothing written")
                XCTAssertEqual(r.sudoCalls, queries, label)
                XCTAssertEqual(r.sleepDisabled, "0", label)
                XCTAssertEqual(after, before, "\(label): the receipt, or what stands in its place, is untouched")
                XCTAssertTrue(r.stderr.contains("is missing, is not the 45-byte file install.sh made, or someone other than root can change it or a folder above it. Run install.sh again; sleep was not turned off"), "\(label): \(r.stderr)")
            }
        }
        // The control: the same receipt, unchanged, is taken.
        try Data(nonce1.utf8).write(to: marker)
        resetReceipt()
        let r = try runRootCommand(marker: marker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(receipt, line(nonce1, "writing"))
    }

    /// No test bypass reaches production: the command as it ships trusts
    /// root alone, so the same receipt, owned by the user running the
    /// tests and otherwise as install.sh makes it, is refused.
    func testTheShippedCommandTrustsOnlyRootsReceipt() throws {
        XCTAssertEqual(AdministratorPrompt.rootCommand.components(separatedBy: "/usr/bin/awk -v o=0 -v n=$n ").count - 1, 1)
        XCTAssertEqual(SleepOffReceipts.live.owners, [0])
        XCTAssertEqual(SleepOffReceipts.live.folder, "/private/var/db/com.kgarg.insomnia")
        XCTAssertEqual(SleepOffReceipts.live.user, getuid())
        for (name, command) in try bothCommands() {
            try Data(nonce1.utf8).write(to: marker)
            resetReceipt()
            let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, receipts: receipts, trustTestUser: false, in: dir)
            XCTAssertEqual(r.status, 7, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, [], name)
            XCTAssertEqual(receipt, SleepOffReceipts.initialContent, name)
        }
    }

    /// The nonce goes in the receipt, so only an uppercase UUID is taken,
    /// and anything else stops the command before root's read. Each is
    /// also the marker's content, so only this check stops it.
    func testOnlyAnUppercaseUUIDNonceReachesTheReceipt() throws {
        for nonce in [nonce1.lowercased(), String(nonce1.dropLast()), nonce1 + "0", "6F1C2B4A-0000-4000-8000-00000000000G", "6F1C2B4A 0000-4000-8000-000000000001"] {
            try Data(nonce.utf8).write(to: marker)
            resetReceipt()
            let r = try runRootCommand(marker: marker, nonce: nonce, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 7, "\(nonce): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, [], nonce)
            XCTAssertEqual(receipt, SleepOffReceipts.initialContent, nonce)
            XCTAssertTrue(r.stderr.contains("the nonce is not an uppercase UUID, so it cannot go in the receipt; sleep was not turned off"), "\(nonce): \(r.stderr)")
        }
    }

    /// Round 17 R2. osascript may already have exited (SIGTERM at the
    /// app's deadline) when the command refuses, so its stderr is a pipe
    /// nobody reads. Before, the first write to it killed the shell with
    /// SIGPIPE: lockf reported 70, the start took that for a failure and
    /// undid, and the command's own fallback had already written 0 over
    /// another tool's 1. The command now ignores SIGPIPE, so each refusal
    /// still exits with its own status, and none writes anything.
    func testARefusalKeepsItsStatusWhenTheDialogsOutputIsGone() throws {
        struct Case {
            let name: String
            let policy: RootSudoPolicy
            let initial: String
            let foreignAfter: String?
            let status: Int32
            let pmset: [String]
            let left: String
        }
        let cases = [
            Case(name: "no rule", policy: .noRule, initial: "0", foreignAfter: nil, status: 5, pmset: [], left: "0"),
            Case(name: "no rule, another tool's 1 while sudo is asked", policy: .noRule, initial: "0", foreignAfter: RootCommandProcess.versionQuery, status: 5, pmset: [], left: "1"),
            Case(name: "an old sudo", policy: .oldSudo, initial: "0", foreignAfter: nil, status: 5, pmset: [], left: "0"),
            Case(name: "a later rule", policy: .laterRule, initial: "0", foreignAfter: nil, status: 5, pmset: [], left: "0"),
            Case(name: "another tool's 1 from while the dialog was up", policy: .rule, initial: "1", foreignAfter: nil, status: 6, pmset: ["-g"], left: "1"),
            Case(name: "another tool's 1 while sudo is asked", policy: .rule, initial: "0", foreignAfter: RootCommandProcess.ruleQuery, status: 6, pmset: ["-g"], left: "1"),
        ]
        for c in cases {
            for (name, command) in try bothCommands() {
                try Data(nonce1.utf8).write(to: marker)
                let r = try RootCommandProcess(marker: marker, nonce: nonce1, policy: c.policy, command: command, sleepDisabled: c.initial, foreignAfter: c.foreignAfter, outputClosed: true, receipts: receipts, in: dir).wait()
                let label = "\(c.name), \(name)"
                XCTAssertEqual(r.status, c.status, label)
                XCTAssertEqual(r.pmsetCalls, c.pmset, label)
                XCTAssertEqual(r.sleepDisabled, c.left, label)
            }
        }
        try Data(nonce2.utf8).write(to: marker)
        XCTAssertEqual(try RootCommandProcess(marker: marker, nonce: nonce1, outputClosed: true, receipts: receipts, in: dir).wait().status, 3)
        try Data(nonce1.utf8).write(to: marker)
        let ended = try RootCommandProcess(marker: marker, nonce: nonce1, deadline: String(Int(Date().timeIntervalSince1970) - 1), outputClosed: true, receipts: receipts, in: dir).wait()
        XCTAssertEqual(ended.status, 4)
        XCTAssertEqual(ended.pmsetCalls, [])
    }

    /// The command holds the marker's lock from before its checks until
    /// pmset exits, so the app cannot delete the marker in between: the
    /// removal times out and the marker stays, and once pmset is done it
    /// goes.
    func testTheMarkerCannotBeRemovedWhilePmsetRuns() async throws {
        try Data(nonce1.utf8).write(to: marker)
        let command = try RootCommandProcess(marker: marker, nonce: nonce1, receipts: receipts, in: dir, holdAt: RootCommandProcess.write)
        XCTAssertTrue(command.waitUntilPmsetRuns())

        do {
            try await store.removePendingStart(timeout: 0.3)
            XCTFail("the marker must not go while pmset runs")
        } catch StoreError.markerBusy {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1)
        XCTAssertEqual(receipt, line(nonce1, "writing"))

        command.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
        let removed = try await store.removePendingStart(timeout: 5)
        XCTAssertNotNil(removed?.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Greptile's case: the command holds the lock on the marker it opened
    /// and runs pmset, and a copy with the same nonce takes the marker's
    /// place. The copy is not locked, so a removal by path alone would
    /// delete it while pmset runs. The start knows which file it wrote and
    /// deletes nothing else.
    func testAReplacedMarkerIsNotDeletedWhilePmsetRuns() async throws {
        let written = try store.savePendingStart(nonce1)
        let command = try RootCommandProcess(marker: marker, nonce: nonce1, receipts: receipts, in: dir, holdAt: RootCommandProcess.write)
        XCTAssertTrue(command.waitUntilPmsetRuns())
        let copy = dir.appendingPathComponent("copy")
        try Data(nonce1.utf8).write(to: copy)
        XCTAssertEqual(rename(copy.path, marker.path), 0)

        do {
            try await store.removePendingStart(timeout: 0.3, expecting: written)
            XCTFail("the copy must not stand in for the locked marker")
        } catch StoreError.markerReplaced {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1)

        command.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
    }

    /// sudo is asked under the same lock: while it answers, the marker
    /// cannot go, so recovery never undoes beside a command that may still
    /// write.
    func testTheMarkerCannotBeRemovedWhileSudoIsAsked() async throws {
        try Data(nonce1.utf8).write(to: marker)
        let command = try RootCommandProcess(marker: marker, nonce: nonce1, receipts: receipts, in: dir, holdAt: RootCommandProcess.ruleQuery)
        XCTAssertTrue(command.waitUntilPmsetRuns())

        do {
            try await store.removePendingStart(timeout: 0.3)
            XCTFail("the marker must not go while sudo is asked")
        } catch StoreError.markerBusy {
            // expected
        }

        command.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
        let removed = try await store.removePendingStart(timeout: 5)
        XCTAssertNotNil(removed)
    }

    /// The other order: a remover holds the lock when the answer comes.
    /// The command has opened the marker and waits for the lock, and by
    /// the time it has it the marker is gone, so nothing runs. The marker
    /// is deleted only once lockf is seen blocked on it (see
    /// `waitUntilLockfWaits`); a command that had not reached it yet would
    /// exit 69, not 3.
    func testAnAnswerThatWaitsOnARemovalRunsNothing() throws {
        try Data(nonce1.utf8).write(to: marker)
        let holder = try FileLockHolder(marker)
        let command = try RootCommandProcess(marker: marker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertTrue(waitUntilLockfWaits(under: command.pid), "lockf never blocked on the marker")
        try FileManager.default.removeItem(at: marker)
        holder.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 3, r.stderr)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sudoCalls, [])
    }

    /// The marker path and the nonce are data: quotes, spaces and `$(...)`
    /// in either arrive intact and are never run. An odd path with a UUID
    /// nonce turns sleep off; an odd nonce is refused (7) before root's
    /// read, since it cannot go in the receipt, and is not run either.
    func testPathAndNonceAreNeverRun() throws {
        let odd = dir.appendingPathComponent("it's a \"dir\" $(touch canary)", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let oddMarker = odd.appendingPathComponent("pending-start")
        try Data(nonce1.utf8).write(to: oddMarker)
        let r = try runRootCommand(marker: oddMarker, nonce: nonce1, receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
        let nonce = "$(touch canary)'\";touch canary;`touch canary`"
        try Data(nonce.utf8).write(to: oddMarker)
        resetReceipt()
        let refused = try runRootCommand(marker: oddMarker, nonce: nonce, receipts: receipts, in: dir)
        XCTAssertEqual(refused.status, 7, refused.stderr)
        XCTAssertEqual(refused.pmsetCalls, [])
        XCTAssertEqual(receipt, SleepOffReceipts.initialContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("canary").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: odd.appendingPathComponent("canary").path))
    }

    // MARK: Someone else's SleepDisabled 1

    /// Both copies of the command: `rootCommand` and the one the
    /// AppleScript embeds.
    private func bothCommands() throws -> [(name: String, command: String)] {
        [("rootCommand", AdministratorPrompt.rootCommand), ("embedded", try appleScriptEmbeddedRootCommand())]
    }

    /// Round 14 P1: another tool sets SleepDisabled 1 while the password is
    /// typed. Start's own read found 0, but the command reads `pmset -g`
    /// again as root, right before its write, and leaves the 1 alone. The
    /// questions before that read change nothing.
    func testLeavesASleepSettingMadeWhileTheDialogWasUp() throws {
        for (name, command) in try bothCommands() {
            try Data(nonce1.utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, sleepDisabled: "1", receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 6, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-g"], name)
            XCTAssertEqual(r.sudoCalls, queries, name)
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nonce1, name)
            XCTAssertEqual(receipt, SleepOffReceipts.initialContent, "\(name): a refusal at the read writes nothing")
            XCTAssertEqual(r.sleepDisabled, "1", name)
            XCTAssertTrue(r.stderr.contains("pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off"), r.stderr)
        }
    }

    /// Round 17 R1: a 1 set while sudo is asked. Before, root had already
    /// turned sleep off for its check, and the check's write of 0 (or
    /// root's own restore when the check failed) cleared that 1. Now
    /// nothing has been written by then, and the read finds it.
    func testLeavesASleepSettingMadeWhileSudoIsAsked() throws {
        for at in [RootCommandProcess.versionQuery, RootCommandProcess.listQuery, RootCommandProcess.ruleQuery] {
            for (name, command) in try bothCommands() {
                try Data(nonce1.utf8).write(to: marker)
                let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, foreignAfter: at, receipts: receipts, in: dir)
                XCTAssertEqual(r.status, 6, "\(at) \(name): \(r.stderr)")
                XCTAssertEqual(r.pmsetCalls, ["-g"], "\(at) \(name)")
                XCTAssertEqual(r.sleepDisabled, "1", "\(at) \(name)")
            }
        }
    }

    /// The same 1 when sudo does not confirm the restore: the command
    /// stops before it reads, and nothing is written over the 1.
    func testASudoRefusalLeavesASettingMadeWhileSudoIsAsked() throws {
        for (policy, at) in [(RootSudoPolicy.noRule, RootCommandProcess.versionQuery), (.listOnly, RootCommandProcess.listQuery), (.laterRule, RootCommandProcess.ruleQuery)] {
            try Data(nonce1.utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: nonce1, policy: policy, foreignAfter: at, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 5, "\(policy): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, [], "\(policy)")
            XCTAssertEqual(r.sleepDisabled, "1", "\(policy)")
        }
    }

    /// `pmset -g` that fails is not taken for 0: the command stops before
    /// it writes anything, as Start does.
    func testAnUnreadableSettingStopsBeforeTheWrite() throws {
        for (name, command) in try bothCommands() {
            try Data(nonce1.utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, sleepDisabled: "fail", receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 6, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-g"], name)
            XCTAssertEqual(r.sudoCalls, queries, name)
            XCTAssertEqual(r.sleepDisabled, "fail", name)
        }
    }

    /// `$5` is `1` only when the journal already owned the SleepDisabled 1
    /// (an earlier restore failed). Start skipped its read for that 1, and
    /// so does the command, but it still asks sudo first, and then writes
    /// once.
    func testAJournalOwnedSettingSkipsTheReadButNotTheQuestions() throws {
        for (name, command) in try bothCommands() {
            try Data(nonce1.utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: nonce1, command: command, sleepDisabled: "1", owned: "1", receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 0, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1"], name)
            XCTAssertEqual(r.pmsetAs, ["root"], name)
            XCTAssertEqual(r.sudoCalls, throughTheRecord, name)
            XCTAssertEqual(r.sleepDisabled, "1", name)
        }
    }

    /// The same journal-owned 1 when sudo does not confirm the restore.
    /// Before, root ran the owed restore itself while the journal entry
    /// the start rolls back to still said it was owed. Now nothing is
    /// written: the 1 stays, and that entry keeps owing its restore.
    func testAJournalOwnedSettingIsLeftToTheJournalWhenSudoRefuses() throws {
        try Data(nonce1.utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: nonce1, policy: .noRule, sleepDisabled: "1", owned: "1", receipts: receipts, in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sleepDisabled, "1")
    }

    /// Only exactly `1` skips the read; anything else, empty or odd,
    /// reads, and is never run.
    func testOnlyExactlyOneSkipsTheRead() throws {
        try Data(nonce1.utf8).write(to: marker)
        for owned in ["", "0", "true", "yes", "01", " 1", "1 ", "1\n", "$(touch canary)", "1;touch canary"] {
            let r = try runRootCommand(marker: marker, nonce: nonce1, sleepDisabled: "1", owned: owned, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, 6, "owned \(owned.debugDescription): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-g"], "owned \(owned.debugDescription)")
            XCTAssertEqual(r.sleepDisabled, "1", "owned \(owned.debugDescription)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("canary").path))
    }

    /// The command's read of `pmset -g` and PmsetSleepGuard.parseSleepDisabled,
    /// Start's own read, agree on what is a 1: the first line whose first
    /// word is SleepDisabled and that has a value.
    func testTheCommandReadsSleepDisabledAsStartDoes() throws {
        let outputs = [
            "System-wide power settings:\nCurrently in use:\n SleepDisabled\t\t1\n sleep 1\n",
            "Currently in use:\n SleepDisabled        0\n",
            "  \tSleepDisabled\t1\n",
            "SleepDisabled 1 (imposed by something)\n",
            "SleepDisabled\nSleepDisabled 1\n",
            "SleepDisabled 0\nSleepDisabled 1\n",
            "SleepDisabled 1\nSleepDisabled 0\n",
            "SleepDisabledX 1\n",
            "sleepdisabled 1\n",
            "Sleep Disabled 1\n",
            "SleepDisabled 10\n",
            "SleepDisabled true\n",
            "SleepDisabled\n",
            "",
            "standby 1\nsleep 1\n",
        ]
        for output in outputs {
            try Data(nonce1.utf8).write(to: marker)
            let startReads = PmsetSleepGuard.parseSleepDisabled(output)
            let r = try runRootCommand(marker: marker, nonce: nonce1, pmsetOutput: output, receipts: receipts, in: dir)
            XCTAssertEqual(r.status, startReads ? 6 : 0, "\(output.debugDescription): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, startReads ? ["-g"] : allCalls, output.debugDescription)
        }
    }

    /// Where another tool's SleepDisabled 1 lands decides whether it
    /// survives. Each row injects one 1 at one point, on the fake clock,
    /// through a confirmed restore, a refused one (exit 5) and a deadline
    /// that passes (exit 4).
    ///
    /// Before root's read (set while the dialog was up, or while sudo is
    /// asked) the 1 survives every path, because nothing has been written:
    /// the read stops the command (6), or a refusal or the deadline stops
    /// it before the read. After the read it does not survive a confirmed
    /// restore: pmset has no compare-and-set, so a 1 set in the moment
    /// between root's read of 0 and its write cannot be told from that
    /// write, and the session's end clears it as Insomnia's own. A
    /// deadline that comes during that read still stops the write, and
    /// the 1 stays. These rows record that limit; they do not make it go
    /// away.
    func testWhereAnotherToolsOneLandsDecidesWhetherItSurvives() throws {
        struct Row {
            let at: String?
            let initial: String
            let policy: RootSudoPolicy
            let clockAt: String
            let late: Bool
            let status: Int32
            let left: String
            let survives: Bool
        }
        let V = RootCommandProcess.versionQuery, l = RootCommandProcess.listQuery, ll = RootCommandProcess.ruleQuery, g = RootCommandProcess.read
        let rows = [
            // Set while the dialog was up.
            Row(at: nil, initial: "1", policy: .rule, clockAt: ll, late: false, status: 6, left: "1", survives: true),
            Row(at: nil, initial: "1", policy: .noRule, clockAt: ll, late: false, status: 5, left: "1", survives: true),
            Row(at: nil, initial: "1", policy: .rule, clockAt: ll, late: true, status: 4, left: "1", survives: true),
            // Set while sudo is asked.
            Row(at: V, initial: "0", policy: .rule, clockAt: ll, late: false, status: 6, left: "1", survives: true),
            Row(at: l, initial: "0", policy: .rule, clockAt: ll, late: false, status: 6, left: "1", survives: true),
            Row(at: ll, initial: "0", policy: .rule, clockAt: ll, late: false, status: 6, left: "1", survives: true),
            Row(at: V, initial: "0", policy: .noRule, clockAt: ll, late: false, status: 5, left: "1", survives: true),
            Row(at: ll, initial: "0", policy: .listOnly, clockAt: ll, late: false, status: 5, left: "1", survives: true),
            Row(at: ll, initial: "0", policy: .rule, clockAt: ll, late: true, status: 4, left: "1", survives: true),
            // Set right after root's read of 0: taken for Insomnia's own.
            Row(at: g, initial: "0", policy: .rule, clockAt: ll, late: false, status: 0, left: "1", survives: false),
            // The same, with the deadline coming during that read.
            Row(at: g, initial: "0", policy: .rule, clockAt: g, late: true, status: 4, left: "1", survives: true),
        ]
        for row in rows {
            let label = "\(row.at ?? "dialog") \(row.policy) \(row.late ? "late at \(row.clockAt)" : "in time")"
            let r = try runOnFakeClock(at: row.clockAt, later: row.late ? fakeDeadline : fakeDeadline - 1, policy: row.policy, sleepDisabled: row.initial, foreignAfter: row.at)
            XCTAssertEqual(r.status, row.status, "\(label): \(r.stderr)")
            XCTAssertEqual(r.sleepDisabled, row.left, label)
            XCTAssertEqual(r.pmsetCalls.contains("-a disablesleep 1"), row.status == 0, "\(label): only a confirmed start writes")
            // A 1 that survives is still there and the command stopped;
            // one that does not is now Insomnia's journaled 1 (status 0),
            // which the end clears.
            XCTAssertEqual(row.survives, r.status != 0 && r.sleepDisabled == "1", label)
        }
    }
}

/// The root command's readers of sudo's answers: the awk programs exactly
/// as `AdministratorPrompt.rootCommand` holds them, fed text in the shapes
/// sudo 1.9.17p2's source prints (SudoFormat). That text was built from the
/// source, not captured from a running sudo, so these show that the
/// readers take the shapes the source prints and refuse the near misses
/// around them, not that a given Mac prints those shapes.
final class RootCommandSudoAnswerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-sudo-answer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The command's awk programs that take no variables, in order: the
    /// /etc/pam.d/sudo reader, the `-V` reader, the `-l` reader, the `-ll`
    /// reader, the receipt's access control reader and the `pmset -g`
    /// reader. The receipt's lstat reader is given `-v` variables and is
    /// not among them.
    private func programs() throws -> [String] {
        let programs = AdministratorPrompt.rootCommand.components(separatedBy: "/usr/bin/awk '").dropFirst().compactMap { $0.components(separatedBy: "'").first }
        XCTAssertEqual(programs.count, 6)
        XCTAssertEqual(AdministratorPrompt.rootCommand.components(separatedBy: "/usr/bin/awk ").count - 1, 7)
        guard programs.count == 6 else { throw XCTSkip("the command's awk programs moved") }
        return programs
    }

    /// The program's exit status for `text` as the command hands it over,
    /// `printf %s "$(...)"`: without its trailing newlines.
    private func status(_ program: String, _ text: String) throws -> Int32 {
        var input = text
        while input.hasSuffix("\n") { input.removeLast() }
        let file = dir.appendingPathComponent("input")
        try Data(input.utf8).write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
        p.arguments = [program]
        p.environment = ["LC_ALL": "C"]
        p.standardInput = try FileHandle(forReadingFrom: file)
        p.standardOutput = FileHandle.nullDevice
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        return p.terminationStatus
    }

    /// Round 19 P1 (Defaults). The command follows how sudo 1.9.17p2,
    /// macOS's, lists and runs a command, so it takes that version alone,
    /// with the grammar that version reads.
    func testTheVersionReaderTakesOnlySudo1_9_17p2WithTheSudoersPlugins() throws {
        let reader = try programs()[1]
        let v = SudoFormat.version
        let accepted = [
            "1.9.17p2 with sudoers' I/O and audit plugins": SudoFormat.versionOutput(),
            "1.9.17p2 without the audit plugin": SudoFormat.versionOutput(audit: false),
            "1.9.17p2 without the I/O plugin": SudoFormat.versionOutput(io: false),
            "1.9.17p2 with the policy plugin alone": SudoFormat.versionOutput(io: false, audit: false),
        ]
        let refused = [
            "1.9.15": SudoFormat.versionOutput("1.9.15"),
            "1.9.16p2": SudoFormat.versionOutput("1.9.16p2"),
            "1.9.17p1": SudoFormat.versionOutput("1.9.17p1"),
            "1.9.17p3": SudoFormat.versionOutput("1.9.17p3"),
            "1.9.18": SudoFormat.versionOutput("1.9.18"),
            "grammar 51": SudoFormat.versionOutput().replacingOccurrences(of: "grammar version 50", with: "grammar version 51"),
            "1.9.14p3": SudoFormat.versionOutput("1.9.14p3"),
            "1.9.9": SudoFormat.versionOutput("1.9.9"),
            "1.10.0": SudoFormat.versionOutput("1.10.0"),
            "2.0.0": SudoFormat.versionOutput("2.0.0"),
            "1.9.17x": SudoFormat.versionOutput("1.9.17x"),
            "an approval plugin": SudoFormat.versionOutput(more: ["Sample approval plugin version \(v)"]),
            "another I/O plugin": SudoFormat.versionOutput(more: ["Sample I/O plugin version \(v)"]),
            "the policy plugin of another version": "Sudo version \(v)\nSudoers policy plugin version 1.9.16\nSudoers file grammar version 50\n",
            "another policy plugin": "Sudo version \(v)\nSample policy plugin version \(v)\n",
            "root's long answer": "Sudo version \(v)\nConfigure options: --with-pam\nSudoers policy plugin version \(v)\nSudoers file grammar version 50\n\nSudoers path: /etc/sudoers\n",
            "the audit plugin twice": SudoFormat.versionOutput(more: ["Sudoers audit plugin version \(v)"]),
            "the I/O plugin after the audit plugin": SudoFormat.versionOutput(io: false, more: ["Sudoers I/O plugin version \(v)"]),
            "no grammar line": "Sudo version \(v)\nSudoers policy plugin version \(v)\n",
            "a blank after the version": SudoFormat.versionOutput().replacingOccurrences(of: "Sudo version \(v)\n", with: "Sudo version \(v) \n"),
            "CRLF": SudoFormat.versionOutput().replacingOccurrences(of: "\n", with: "\r\n"),
            "nothing": "",
        ]
        for (name, text) in accepted { XCTAssertEqual(try status(reader, text), 0, name) }
        for (name, text) in refused { XCTAssertNotEqual(try status(reader, text), 0, name) }
    }

    /// Round 19 P1 (Defaults). The `-l` reader takes only Defaults that
    /// cannot make the restore fail where a listing passes: environment
    /// lists, the lecture, the password prompt's text and limits, and
    /// syslog of allowed and denied commands. Anything else that applies
    /// to the user (I/O logs, a log file, Runas and group settings, other
    /// authentication), any Defaults bound to a Runas user or a command,
    /// and text it cannot read for certain stop the command. Whether the
    /// listing ran without a password is its exit status, which the
    /// command checks before this reader.
    func testTheListingReaderTakesOnlyTheDefaultsItAccepts() throws {
        let reader = try programs()[2]
        let rule = ["(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0"]
        func listing(_ defaults: [String]) -> String { SudoFormat.listing(defaults: defaults, rules: rule) }
        let accepted = [
            "macOS's own": RootSudoPolicy.rule.answers().listing.stdout,
            "none": listing([]),
            "the header's words inside a value": listing(["env_keep+=\"Runas and Command-specific defaults for user:\""]),
            "each one taken": listing([
                "!env_reset", "env_keep-=TZ", "env_check+=TERM", "env_delete=\"PERL5LIB PYTHONPATH\"", "lecture", "!lecture",
                "lecture=always", "lecture_file=/etc/sudo_lecture", "log_allowed", "log_denied", "!log_denied",
                "passprompt=\"Password for %p:\"", "badpass_message=\"Try again\"", "passwd_timeout=5", "passwd_tries=3",
                "timestamp_timeout=15", "!timestamp_timeout", "timestamp_type=tty", "tty_tickets", "pwfeedback", "insults",
            ]),
        ]
        let refused = [
            "the round 19 review's user Defaults": RootSudoPolicy.userDefaults.answers().listing.stdout,
            "log_output": listing(["log_output"]),
            "!ignore_iolog_errors": listing(["!ignore_iolog_errors"]),
            "an I/O log directory": listing(["iolog_dir=/var/log/sudo-io"]),
            "a log file": listing(["logfile=/var/log/sudo.log"]),
            "use_pty": listing(["use_pty"]),
            "requiretty": listing(["requiretty"]),
            "rootpw": listing(["rootpw"]),
            "!authenticate": listing(["!authenticate"]),
            "group_source": listing(["group_source=static"]),
            "preserve_groups": listing(["preserve_groups"]),
            "runas_default": listing(["runas_default=nobody"]),
            "a Runas or command Defaults": RootSudoPolicy.boundDefaults.answers().listing.stdout,
            "a Runas Defaults after the user's": SudoFormat.listing(bound: ["Defaults>root log_output"], rules: rule),
            "only bound Defaults": SudoFormat.listing(defaults: [], bound: ["Defaults>root !authenticate", "Defaults!/usr/bin/pmset log_output"], rules: rule),
            "env_reset as a list": listing(["env_reset+=FOO"]),
            "lecture_file added to": listing(["lecture_file+=/etc/x"]),
            "a backslash in a value": listing(["env_keep+=\"A\\\" log_output B\""]),
            "an escaped comma": listing(["passprompt=a\\,b"]),
            "a tab": listing(["env_reset,\tlog_output"]),
            "no space after the comma": listing(["env_reset,log_output"]),
            "a doubled comma": listing(["env_reset", ", log_output"]),
            "a quote left open": listing(["passprompt=\"Password"]),
            "an unknown name": listing(["env_resetx"]),
            "upper case": listing(["ENV_RESET"]),
            "a second Matching header": listing(["env_reset"]).replacingOccurrences(of: "User user may run", with: "Matching Defaults entries for user on mac:\n    log_output\n\nUser user may run"),
            "no blank line after the entries": listing(["env_reset"]).replacingOccurrences(of: "env_reset\n\n", with: "env_reset\n"),
            "unindented entries": listing(["env_reset"]).replacingOccurrences(of: "    env_reset", with: "env_reset"),
            "the header alone": "Matching Defaults entries for user on mac:\n",
        ]
        for (name, text) in accepted { XCTAssertEqual(try status(reader, text), 0, name) }
        for (name, text) in refused { XCTAssertNotEqual(try status(reader, text), 0, name) }
    }

    /// The `-ll` reader takes the rule install.sh writes, as sudo names its
    /// file either way, and nothing else: every policy that differs in the
    /// answer to `-ll`, and near misses of the rule's own answer.
    func testTheRuleReaderTakesOnlyTheInsomniaRuleWithoutAPassword() throws {
        let reader = try programs()[3]
        let restore = "/usr/bin/pmset -a disablesleep 0"
        for policy: RootSudoPolicy in [.rule, .etcPath] {
            XCTAssertEqual(try status(reader, policy.answers().check.stdout), 0, "\(policy)")
        }
        for policy: RootSudoPolicy in [.listOnly, .noTag, .deny, .laterRule, .runAsAll, .extraOption, .timeLimited, .ldap, .pathOnly, .truncated] {
            XCTAssertNotEqual(try status(reader, policy.answers().check.stdout), 0, "\(policy)")
        }
        let rule = RootSudoPolicy.rule.answers().check.stdout
        let refused = [
            "the rule's PASSWD tag": SudoFormat.check(SudoFormat.longEntry(options: ["authenticate"], commands: [restore]), matched: restore),
            "a rule-level option before the tag": SudoFormat.check(SudoFormat.longEntry(options: ["log_output", "!authenticate"], commands: [restore]), matched: restore),
            "run-as root and wheel": SudoFormat.check(SudoFormat.longEntry(runAsUsers: "root, wheel", commands: [restore]), matched: restore),
            "a RunAsGroups line": rule.replacingOccurrences(of: "    RunAsUsers: root\n", with: "    RunAsUsers: root\n    RunAsGroups: wheel\n"),
            "pmset with any arguments": SudoFormat.check(SudoFormat.longEntry(commands: ["/usr/bin/pmset"]), matched: restore),
            "two commands": SudoFormat.check(SudoFormat.longEntry(commands: [restore, "/usr/bin/pmset -b lowpowermode 1"]), matched: restore),
            "another command matched": SudoFormat.check(SudoFormat.longEntry(commands: [restore]), matched: "/usr/bin/pmset -a disablesleep 1"),
            "another file of the same name": SudoFormat.check(SudoFormat.longEntry(source: "Sudoers entry: /private/etc/sudoers.d/insomnia~", commands: [restore]), matched: restore),
            "a Timeout line": SudoFormat.check(SudoFormat.longEntry(limits: ["Timeout: 30"], commands: [restore]), matched: restore),
            "spaces for the tab": rule.replacingOccurrences(of: "\t", with: "    "),
            "CRLF": rule.replacingOccurrences(of: "\n", with: "\r\n"),
            "a second entry": rule + "\n" + rule,
            "a line after Matched": rule + "    Matched: \(restore)\n",
            "no Matched line": SudoFormat.longEntry(commands: [restore]),
            "nothing": "",
        ]
        for (name, text) in refused { XCTAssertNotEqual(try status(reader, text), 0, name) }
    }
}

/// Store.removePendingStart: lock, then unlink.
final class PendingStartRemovalTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-marker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        chflags(marker.path, 0)
        try? FileManager.default.removeItem(at: dir)
    }

    private var marker: URL { dir.appendingPathComponent("pending-start") }
    private var store: Store { Store(paths: Paths(root: dir)) }

    func testRemovesAMarkerAndReportsAMissingOne() async throws {
        try Data("n".utf8).write(to: marker)
        let written = FileIdentity(atPath: marker.path)
        let first = try await store.removePendingStart(timeout: 1)
        let second = try await store.removePendingStart(timeout: 1)
        XCTAssertNotNil(written)
        XCTAssertEqual(first, RemovedMarker(file: written))
        XCTAssertNil(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Waits for a lock that is let go within the timeout.
    func testWaitsForTheLockToBeLetGo() async throws {
        try Data("n".utf8).write(to: marker)
        let holder = try FileLockHolder(marker)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { holder.release() }
        let removed = try await store.removePendingStart(timeout: 5)
        XCTAssertNotNil(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAHeldLockKeepsTheMarker() async throws {
        try Data("n".utf8).write(to: marker)
        let holder = try FileLockHolder(marker)
        defer { holder.release() }
        do {
            try await store.removePendingStart(timeout: 0.2)
            XCTFail("must throw")
        } catch StoreError.markerBusy {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// An immutable flag makes unlink fail; the failure is reported, not
    /// swallowed.
    func testAnImmutableMarkerIsReported() async throws {
        try Data("n".utf8).write(to: marker)
        XCTAssertEqual(chflags(marker.path, UInt32(UF_IMMUTABLE)), 0)
        do {
            try await store.removePendingStart(timeout: 0.2)
            XCTFail("must throw")
        } catch StoreError.unlink {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A directory is never removed as a tree.
    func testADirectoryIsNotRemoved() async throws {
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: marker.appendingPathComponent("keep"))
        do {
            try await store.removePendingStart(timeout: 0.2)
            XCTFail("must throw")
        } catch StoreError.unlink {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.appendingPathComponent("keep").path))
    }

    /// Puts a new file with `content` in the marker's place, the way
    /// another process or an editor's save would: written aside, then
    /// renamed onto the path.
    private func replaceMarker(with content: String) throws {
        let tmp = dir.appendingPathComponent("replacement-\(UUID().uuidString)")
        try Data(content.utf8).write(to: tmp)
        XCTAssertEqual(rename(tmp.path, marker.path), 0)
    }

    func testTheMarkerAStartWroteIsRemoved() async throws {
        let written = try store.savePendingStart("n")
        XCTAssertEqual(written, FileIdentity(atPath: marker.path))
        let removed = try await store.removePendingStart(timeout: 1, expecting: written)
        XCTAssertEqual(removed, RemovedMarker(file: written))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// What goes is reported by identity alone. A rewrite in place keeps
    /// the file the start wrote, whatever it holds now: anything running
    /// as the user can do that, so what the marker holds shows nothing
    /// about the command behind the dialog, and only the receipt does
    /// (SleepOffReceiptsTests). A copy in its place is another file, and
    /// so is a later start's own marker.
    func testTheFileThatGoesIsReportedByIdentityAlone() async throws {
        let nonce = "6F1C2B4A-0000-4000-8000-00000000000A"
        for text in [nonce, "", nonce + " writing", nonce + " refused\n", "6F1C2B4A-0000-4000-8000-00000000000B"] {
            let written = try store.savePendingStart(nonce)
            FakeAdministratorPrompt.overwrite(marker, with: text)
            XCTAssertEqual(FileIdentity(atPath: marker.path), written, "\(text): rewritten in place")
            let removed = try await store.removePendingStart(timeout: 1)
            XCTAssertEqual(removed, RemovedMarker(file: written), text)
        }

        let copiedFrom = try store.savePendingStart(nonce)
        try replaceMarker(with: nonce)
        let copied = try await store.removePendingStart(timeout: 1)
        XCTAssertNotNil(copied?.file)
        XCTAssertNotEqual(copied?.file, copiedFrom)
        let earlier = try store.savePendingStart(nonce)
        try FileManager.default.removeItem(at: marker)
        let later = try store.savePendingStart(nonce)
        XCTAssertNotEqual(later, earlier)
        let removed = try await store.removePendingStart(timeout: 1)
        XCTAssertEqual(removed, RemovedMarker(file: later))
    }

    /// A copy in the marker's place is not the file the start wrote. The
    /// root command may hold the original's lock and still run pmset, so
    /// nothing is deleted, even though the copy itself is not locked.
    func testAReplacedMarkerIsNotTakenForTheOneWritten() async throws {
        let written = try store.savePendingStart("n")
        try replaceMarker(with: "n")
        do {
            try await store.removePendingStart(timeout: 1, expecting: written)
            XCTFail("must throw")
        } catch StoreError.markerReplaced {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "n", "the copy stays")
    }

    /// The marker the start wrote, deleted without its lock: nothing shows
    /// that the command behind its dialog is done with it.
    func testAMarkerDeletedWithoutItsLockDoesNotCountAsRemoved() async throws {
        let written = try store.savePendingStart("n")
        try FileManager.default.removeItem(at: marker)
        do {
            try await store.removePendingStart(timeout: 1, expecting: written)
            XCTFail("must throw")
        } catch StoreError.markerReplaced {
            // expected
        }
    }

    /// Once the lock is held the path must still name the locked file. A
    /// file swapped in after the open is not deleted under the old file's
    /// lock: it is looked up again, and goes once its own lock is held.
    func testAFileSwappedInAfterTheOpenIsLockedBeforeItGoes() async throws {
        try Data("n".utf8).write(to: marker)
        let first = FileIdentity(atPath: marker.path)
        let locks = Locked(0)
        let swapped = Locked<FileIdentity?>(nil)
        let removed = try await store.removePendingStart(timeout: 5, pollEvery: .milliseconds(10), onLocked: {
            locks.value += 1
            if locks.value == 1 {
                try? self.replaceMarker(with: "m")
                swapped.value = FileIdentity(atPath: self.marker.path)
            }
        })
        XCTAssertNotNil(swapped.value)
        XCTAssertNotEqual(swapped.value, first)
        XCTAssertEqual(removed, RemovedMarker(file: swapped.value), "what goes is the file locked last")
        XCTAssertEqual(locks.value, 2, "the swapped-in file was locked before it went")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// A path that names another file each time the lock is taken is
    /// never deleted, and the failure says why.
    func testAMarkerThatKeepsBeingReplacedIsReported() async throws {
        try Data("n".utf8).write(to: marker)
        do {
            try await store.removePendingStart(timeout: 0.3, pollEvery: .milliseconds(10), onLocked: {
                try? self.replaceMarker(with: "m")
            })
            XCTFail("must throw")
        } catch let error as StoreError {
            guard case .markerReplaced = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("replaced or removed by something other than Insomnia"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "m")
    }

    /// A link to nothing cannot be opened by lockf either; the link goes.
    func testADanglingLinkIsRemoved() async throws {
        try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: dir.appendingPathComponent("nowhere").path)
        let removed = try await store.removePendingStart(timeout: 1)
        XCTAssertEqual(removed, RemovedMarker(file: nil))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: marker.path))
    }
}

/// PmsetSleepGuard routes only `disablesleep 1` through the dialog. Its
/// `sudo -n` paths run the real sudo and are not exercised here.
/// A fake sudo and a fake pmset in a temp directory, for PmsetSleepGuard.
/// Both record their arguments; neither runs anything. The sudo passes
/// every `-n` call, as the sudoers rule would for the commands the app
/// runs, and fails one without `-n`, which would have prompted. The pmset
/// prints `SleepDisabled` as `sleepDisabled` says, or exits 1 for `fail`.
final class FakeRestoreTools: @unchecked Sendable {
    let sudo: String
    let pmset: String
    private let sudoLog: URL
    private let pmsetLog: URL
    private let stateFile: URL

    init(in dir: URL) throws {
        sudo = dir.appendingPathComponent("fake-sudo").path
        pmset = dir.appendingPathComponent("fake-pmset").path
        sudoLog = dir.appendingPathComponent("sudo-calls")
        pmsetLog = dir.appendingPathComponent("pmset-calls")
        stateFile = dir.appendingPathComponent("pmset-sleep-disabled")
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(sudoLog.path)'
        if [[ "$1" != -n ]]; then echo "fake sudo: would have prompted" >&2; exit 2; fi
        exit 0
        """.write(toFile: sudo, atomically: true, encoding: .utf8)
        try """
        #!/bin/bash
        printf '%s\\n' "$*" >> '\(pmsetLog.path)'
        state="$(cat '\(stateFile.path)' 2>/dev/null)"
        if [[ "$state" == fail ]]; then echo "pmset: could not read the settings" >&2; exit 1; fi
        printf 'System-wide power settings:\\n SleepDisabled\\t\\t%s\\n' "${state:-0}"
        """.write(toFile: pmset, atomically: true, encoding: .utf8)
        for path in [sudo, pmset] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    /// What the fake pmset reports: `0` (the default), `1` or `fail`.
    var sleepDisabled: String {
        get { (try? String(contentsOf: stateFile, encoding: .utf8)) ?? "0" }
        set { try! Data(newValue.utf8).write(to: stateFile) }
    }

    func sudoCalls() -> [String] { Self.lines(sudoLog) }
    func pmsetCalls() -> [String] { Self.lines(pmsetLog) }

    func clearCalls() {
        try? FileManager.default.removeItem(at: sudoLog)
        try? FileManager.default.removeItem(at: pmsetLog)
    }

    func sleepGuard(prompt: any AdministratorPromptRunning = FakeAdministratorPrompt()) -> PmsetSleepGuard {
        PmsetSleepGuard(prompt: prompt, sudo: sudo, pmset: pmset)
    }

    private static func lines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

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
        let start = PendingStart(marker: dir.appendingPathComponent("pending-start"), nonce: UUID().uuidString, deadline: Date().addingTimeInterval(3600))
        try Data(start.nonce.utf8).write(to: start.marker)
        return start
    }

    /// Start's check only reads: `pmset -g`, and no sudo at all.
    func testSleepSettingCheckOnlyReads() async throws {
        let tools = try FakeRestoreTools(in: dir)
        try await tools.sleepGuard().checkSleepSettingForStart(sleepOffIsOurs: false)
        XCTAssertEqual(tools.pmsetCalls(), ["-g"])
        XCTAssertEqual(tools.sudoCalls(), [])
    }

    /// SleepDisabled 1 the journal does not own is someone else's setting:
    /// refused, with nothing run.
    func testSleepSettingCheckRefusesWhileSleepIsAlreadyOff() async throws {
        let tools = try FakeRestoreTools(in: dir)
        tools.sleepDisabled = "1"
        do {
            try await tools.sleepGuard().checkSleepSettingForStart(sleepOffIsOurs: false)
            XCTFail("must throw")
        } catch SleepSettingRefusal.sleepAlreadyOff {
            // expected
        }
        XCTAssertEqual(tools.pmsetCalls(), ["-g"])
        XCTAssertEqual(tools.sudoCalls(), [])
    }

    /// A 1 the journal owns (an earlier restore failed) is Insomnia's own:
    /// nothing is read and Start may go on.
    func testSleepSettingCheckTrustsTheJournal() async throws {
        let tools = try FakeRestoreTools(in: dir)
        tools.sleepDisabled = "1"
        try await tools.sleepGuard().checkSleepSettingForStart(sleepOffIsOurs: true)
        XCTAssertEqual(tools.pmsetCalls(), [])
        XCTAssertEqual(tools.sudoCalls(), [])
    }

    /// An unreadable setting is not taken for 0.
    func testSleepSettingCheckRefusesWhenTheSettingCannotBeRead() async throws {
        let tools = try FakeRestoreTools(in: dir)
        tools.sleepDisabled = "fail"
        do {
            try await tools.sleepGuard().checkSleepSettingForStart(sleepOffIsOurs: false)
            XCTFail("must throw")
        } catch let error as SleepSettingRefusal {
            guard case .sleepSettingUnreadable = error else { return XCTFail("\(error)") }
            let text = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(text.hasPrefix("`pmset -g` could not be read ("), text)
        }
        XCTAssertEqual(tools.sudoCalls(), [])
    }

    func testDisableSleepGoesThroughThePromptWithItsStart() async throws {
        let prompt = FakeAdministratorPrompt()
        let receipts = try TestReceipts.make(in: dir)
        prompt.receiptFile = receipts.file
        let sleepGuard = PmsetSleepGuard(prompt: prompt)
        let start = try pendingStart()
        try await sleepGuard.disableSleep(start)
        XCTAssertEqual(prompt.shown, 1)
        XCTAssertEqual(prompt.starts, [start])
        XCTAssertEqual(TestReceipts.text(receipts), "\(start.nonce) writing\n")
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
        XCTAssertEqual(shownFor.deadline, s.endsAt)
        XCTAssertEqual(h.prompt.markerAtShow, [shownFor.nonce])
        XCTAssertFalse(markerExists, "the marker must not outlive its start")
    }

    /// An installed backstop.sh that cannot void a dialog (an upgrade that
    /// stopped before replacing it) means no dialog: Start is refused before
    /// anything is written, and the user is told to run install.sh again.
    func testStartWithAnOlderBackstopShowsNoPrompt() async throws {
        h.backstop.outdatedScript = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.backstop.checks, 1)
        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertNil(try h.store.loadState())
        XCTAssertFalse(markerExists)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("start refused, nothing changed: "), err)
        XCTAssertTrue(err.hasSuffix("run scripts/install.sh again"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session not started")
        XCTAssertTrue(post.body.hasPrefix("Nothing was changed: "), post.body)
        XCTAssertTrue(post.body.contains("run scripts/install.sh again"), post.body)

        h.backstop.outdatedScript = false
        await m.start(duration: 1800)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.shown, 1)
    }

    /// The password is accepted, but sudo does not confirm that turning
    /// sleep back on runs without a password, so the root command exits 5
    /// before it reads or writes pmset. Nothing is left that an undo would
    /// reverse: the start rolls back with no pmset, and the user is told
    /// to run install.sh again.
    func testStartWhoseRestoreCheckFailsRollsBackWithNothingToUndo() async throws {
        h.prompt.restoreNeedsPassword = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "no restore runs after the check refused")
        XCTAssertEqual(h.guardFake.unlockedPrivilegedCalls, [])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("could not disable sleep: sleep was not turned off: sudo did not confirm"), err)
        XCTAssertTrue(err.contains("run scripts/install.sh again"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session not started")
        XCTAssertTrue(post.body.hasPrefix("No session was started, and Insomnia undid anything it changed: sleep was not turned off"), post.body)
        XCTAssertTrue(post.body.contains("run scripts/install.sh again"), post.body)

        h.prompt.restoreNeedsPassword = false
        await m.start(duration: 1800)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.shown, 2)
    }

    /// A restore the journal already owed (an earlier one failed) stays
    /// owed when sudo does not confirm the restore: the root command
    /// writes nothing, and the rollback puts that entry back.
    func testARefusedRestoreCheckKeepsAnEntryAnEarlierRestoreLeft() async throws {
        var earlier = RuntimeState()
        earlier.sleepDisabledByUs = true
        try h.store.saveState(earlier)
        h.prompt.restoreNeedsPassword = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertEqual(try h.store.loadState(), earlier)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(markerExists)
    }

    /// The sleep setting is read once per start, before session.json, the
    /// journal, the backstop or the marker exist.
    func testTheSleepSettingIsReadBeforeAnythingIsWritten() async throws {
        let paths = h.home.paths
        let prompt = h.prompt
        let backstop = h.backstop
        let seen = Locked<[String]?>(nil)
        h.guardFake.onSleepSettingCheck = {
            var found: [String] = []
            for (name, url) in [("session.json", paths.sessionFile), ("state.json", paths.stateFile), ("pending-start", paths.pendingStartFile)]
            where FileManager.default.fileExists(atPath: url.path) {
                found.append(name)
            }
            if prompt.shown > 0 { found.append("prompt") }
            if backstop.arms > 0 { found.append("arm") }
            seen.value = found
        }
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.guardFake.sleepSettingChecks, 1)
        XCTAssertEqual(seen.value, [], "the check ran after the start had begun to change things")
        XCTAssertEqual(h.guardFake.lastSleepOffIsOurs, false)
        XCTAssertEqual(h.prompt.shown, 1)
    }

    // MARK: Start with the real sleep guard

    /// The real PmsetSleepGuard against a fake sudo and pmset, with the
    /// harness's dialog.
    private func realGuard(sleepDisabled: String = "0") throws -> FakeRestoreTools {
        let dir = h.home.root.appendingPathComponent("fake-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tools = try FakeRestoreTools(in: dir)
        tools.sleepDisabled = sleepDisabled
        return tools
    }

    private func assertRefusedUntouched(_ m: SessionManager, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(h.prompt.shown, 0, "a dialog was shown", file: file, line: line)
        XCTAssertEqual(h.backstop.arms, 0, file: file, line: line)
        XCTAssertNil(m.session, file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), "session.json written", file: file, line: line)
        XCTAssertNil(try h.store.loadState(), "state.json written", file: file, line: line)
        XCTAssertFalse(markerExists, "pending-start written", file: file, line: line)
        let post = try XCTUnwrap(h.notifier.posts.last, file: file, line: line)
        XCTAssertEqual(post.title, "Session not started", file: file, line: line)
        XCTAssertTrue(post.body.hasPrefix("Nothing was changed: "), post.body, file: file, line: line)
    }

    /// Greptile 4171743074: Start used to prove the restore by running it
    /// right after reading SleepDisabled 0, so a 1 set in between was
    /// turned back to 0 with no journal entry and no dialog. Now nothing
    /// runs through sudo before the dialog: Start only reads, and the end
    /// runs the restore.
    func testStartRunsNoSudoBeforeTheDialog() async throws {
        let tools = try realGuard()
        let m = h.makeManager(sleepGuard: tools.sleepGuard(prompt: h.prompt))
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(tools.pmsetCalls(), ["-g"])
        XCTAssertEqual(tools.sudoCalls(), [], "sudo ran before the dialog")
        await m.end(reason: .user)
        XCTAssertEqual(tools.sudoCalls(), ["-n /usr/bin/pmset -a disablesleep 0"])
    }

    /// SleepDisabled already 1: nothing runs through sudo, the setting
    /// stays, and Start is refused with the command to run.
    func testStartWhileSleepIsAlreadyOffRunsNothing() async throws {
        let tools = try realGuard(sleepDisabled: "1")
        let m = h.makeManager(sleepGuard: tools.sleepGuard(prompt: h.prompt))
        await m.start(duration: 1800)

        try assertRefusedUntouched(m)
        XCTAssertEqual(tools.pmsetCalls(), ["-g"])
        XCTAssertEqual(tools.sudoCalls(), [], "sudo ran while sleep was off")
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("start refused, nothing changed: sleep is already off (pmset reports SleepDisabled 1)"), err)
        XCTAssertTrue(err.hasSuffix("To re-enable sleep: sudo pmset -a disablesleep 0, then start again"), err)
    }

    /// A setting that cannot be read is not taken for 0: Start is refused
    /// with nothing written.
    func testStartWithAnUnreadableSleepSettingRunsNothing() async throws {
        let tools = try realGuard(sleepDisabled: "fail")
        let m = h.makeManager(sleepGuard: tools.sleepGuard(prompt: h.prompt))
        await m.start(duration: 1800)

        try assertRefusedUntouched(m)
        XCTAssertEqual(tools.sudoCalls(), [])
        XCTAssertTrue(try XCTUnwrap(m.lastError).hasPrefix("start refused, nothing changed: `pmset -g` could not be read ("), m.lastError ?? "")
    }

    /// SleepDisabled 1 that the journal says Insomnia set, after a restore
    /// that failed: it is not someone else's, so Start goes on without
    /// reading it. The root command's check then runs the restore that was
    /// owed anyway, right before sleep is turned off again.
    func testStartWithARestoreTheJournalOwesGoesOn() async throws {
        var earlier = RuntimeState()
        earlier.sleepDisabledByUs = true
        try h.store.saveState(earlier)
        let tools = try realGuard(sleepDisabled: "1")
        let m = h.makeManager(sleepGuard: tools.sleepGuard(prompt: h.prompt))
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(tools.pmsetCalls(), [])
        XCTAssertEqual(tools.sudoCalls(), [])
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
    /// before anything is shown or run. A directory takes the marker's
    /// place after the transaction cleared the path, while the backstop is
    /// being armed.
    func testMarkerThatCannotBeWrittenRollsBackWithoutAPrompt() async throws {
        let gate = AsyncGate()
        h.backstop.armGate = gate
        let m = h.makeManager()
        let start = Task { await m.start(duration: 1800) }
        await gate.waitUntilStarted()
        try FileManager.default.createDirectory(at: h.home.paths.pendingStartFile, withIntermediateDirectories: false)
        await gate.open()
        await start.value

        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("pending-start marker"), err)
    }

    /// A cancelled dialog ran nothing as root, so nothing is undone
    /// either: the journal and session.json go back as they were and no
    /// pmset runs.
    func testCancelledPromptRollsBackAndSaysSo() async throws {
        h.prompt.mode = .cancel
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "no pmset runs after a cancel")
        XCTAssertEqual(h.backstop.arms, 1)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("cancelled"), err)
        let last = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(last.title, "Session not started")
        XCTAssertEqual(last.body, "No session was started, and Insomnia undid anything it changed: the administrator password prompt was cancelled.")
    }

    /// The README's promise: a SleepDisabled bit another tool set stays
    /// set. The session's end would turn it off, so Start is refused
    /// before it runs anything, writes anything or shows the dialog.
    func testStartLeavesASleepSettingSomeoneElseOwns() async throws {
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.sleepSettingChecks, 1)
        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertTrue(h.guardFake.sleepDisabled, "another tool's setting must survive a start")
        XCTAssertEqual(h.backstop.arms, 0)
        XCTAssertNil(try h.store.loadState())
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(markerExists)
        XCTAssertNil(m.session)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("start refused, nothing changed: sleep is already off (pmset reports SleepDisabled 1)"), err)
        XCTAssertTrue(err.hasSuffix("To re-enable sleep: sudo pmset -a disablesleep 0, then start again"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session not started")
        XCTAssertTrue(post.body.hasPrefix("Nothing was changed: sleep is already off"), post.body)

        // Once whoever set it turns sleep back on, Start works.
        h.guardFake.sleepDisabled = false
        await m.start(duration: 1800)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.shown, 1)
    }

    /// osascript never started, so nothing ran as root: the same exact
    /// rollback with no pmset.
    func testLaunchFailureRollsBackWithoutPmset() async throws {
        h.prompt.mode = .launchFail
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(markerExists)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not launch osascript"), err)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// The rollback puts back what was on disk, not a clean slate: an
    /// entry an earlier failed restore left stays for recovery.
    func testCancelKeepsAnEntryAnEarlierRestoreLeft() async throws {
        var earlier = RuntimeState()
        earlier.sleepDisabledByUs = true
        try h.store.saveState(earlier)
        h.prompt.mode = .cancel
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertEqual(h.guardFake.lastSleepOffIsOurs, true, "the check was not told the journal owes a restore")
        XCTAssertEqual(try h.store.loadState(), earlier)
        XCTAssertNil(try h.store.loadSession())
    }

    /// A wrong password: no root command ran, so the receipt still holds
    /// another start's nonce, and the start is rolled back with no undo.
    func testFailedPromptRollsBack() async throws {
        h.prompt.mode = .fail
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "nothing reached the sleep setting, so nothing is undone")
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("incorrect"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session not started")
        XCTAssertTrue(post.body.hasSuffix("The receipt shows that the command behind the password dialog never turned sleep off."), post.body)
        XCTAssertEqual(TestReceipts.text(h.receipts), SleepOffReceipts.initialContent)
    }

    /// A failure after the command wrote its record is undone like an end.
    func testAFailureAfterTheRecordIsUndone() async throws {
        h.prompt.mode = .fail
        h.prompt.wroteRecord = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// A one-minute session whose password is typed 90 s later: the
    /// dialog's command is given the session's end and refuses after it,
    /// so sleep stays on and the start is rolled back with no pmset.
    func testPasswordTypedAfterTheSessionsEndTurnsNothingOff() async throws {
        let clock = h.clock
        h.prompt.onShow = { _ in clock.advance(90) }
        let m = h.makeManager()
        await m.start(duration: 60)

        XCTAssertEqual(h.prompt.starts.first?.deadline, Date(timeIntervalSince1970: 1_800_000_060))
        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "a refusal leaves nothing to undo")
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("the session this password was for has already ended"), err)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// Round 14 P1: another tool turns sleep off while the password is
    /// typed. The dialog's command finds that 1 and stops (status 6), and
    /// the start is rolled back with no pmset, so the setting stays.
    func testASleepSettingMadeWhileThePasswordIsTypedIsLeftAlone() async throws {
        let guardFake = h.guardFake
        h.prompt.onShow = { _ in guardFake.sleepDisabled = true }
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.prompt.starts.first?.sleepOffIsOurs, false)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "no undo after a refusal")
        XCTAssertTrue(h.guardFake.sleepDisabled, "the other tool's setting must survive")
        XCTAssertFalse(markerExists)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("could not disable sleep: Insomnia did not turn sleep off (the command behind the password dialog stopped with status 6 before it changed anything)"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session not started")
        XCTAssertTrue(post.body.hasPrefix("No session was started, and Insomnia undid anything it changed: Insomnia did not turn sleep off"), post.body)
    }

    /// The reviewer's case through Start: a 1 set while the dialog is up
    /// and a password typed after the session's end. The command stops
    /// before any write and the rollback runs no pmset, so the 1 stays.
    func testALatePasswordLeavesASettingMadeMeanwhile() async throws {
        let clock = h.clock
        let guardFake = h.guardFake
        h.prompt.onShow = { _ in
            guardFake.sleepDisabled = true
            clock.advance(90)
        }
        let m = h.makeManager()
        await m.start(duration: 60)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("stopped with status 4"), m.lastError ?? "")
    }

    /// The dialog is told the journal owns a SleepDisabled 1 only when it
    /// did before the start; then the command skips its reads, as Start
    /// skipped its own, and turns sleep off.
    func testTheDialogIsToldWhetherTheJournalOwnsTheSetting() async throws {
        var earlier = RuntimeState()
        earlier.sleepDisabledByUs = true
        try h.store.saveState(earlier)
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.starts.map(\.sleepOffIsOurs), [true])
        await m.end(reason: .user)
        XCTAssertFalse(h.guardFake.sleepDisabled)

        await m.start(duration: 1800)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.starts.map(\.sleepOffIsOurs), [true, false])
    }

    /// Round 19 P1 (ownership). A failure whose status cannot say where
    /// it came from, while the marker still holds the bare nonce: no
    /// command for this start reached the sleep setting, so a 1 another
    /// tool set while the dialog was up is left alone.
    func testAFailureBeforeTheRecordLeavesASettingMadeMeanwhile() async throws {
        let guardFake = h.guardFake
        h.prompt.onShow = { _ in guardFake.sleepDisabled = true }
        h.prompt.mode = .fail
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertTrue(h.guardFake.sleepDisabled, "the other tool's setting must survive")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(try h.store.loadSession())
    }

    /// Only the file the start wrote can show that no command reached the
    /// sleep setting. A copy put in its place while the dialog was up
    /// proves nothing, even holding the start's nonce, so the failure is
    /// undone like an end.
    func testAFailureWithAReplacedMarkerIsUndoneEvenWhenItHoldsTheNonce() async throws {
        h.prompt.onShow = { start in
            let copy = start.marker.deletingLastPathComponent().appendingPathComponent("copy-\(UUID().uuidString)")
            try? Data(start.nonce.utf8).write(to: copy)
            _ = rename(copy.path, start.marker.path)
        }
        h.prompt.mode = .fail
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// The same for a marker that is gone: nothing shows the command
    /// stopped short, so the failure is undone like an end.
    func testAFailureWithNoMarkerLeftIsUndone() async throws {
        h.prompt.onShow = { start in try? FileManager.default.removeItem(at: start.marker) }
        h.prompt.mode = .fail
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// The limit on the other side: once the record is in the marker, a
    /// failure that may have come after `disablesleep 1` is still undone
    /// like an end, so a 1 another tool set while that dialog was up is
    /// cleared too, even if the failure came before the write. Leaving it
    /// would risk leaving Insomnia's own 1 with no journal entry.
    func testAnAmbiguousFailureAfterTheRecordStillUndoesASettingMadeMeanwhile() async throws {
        let guardFake = h.guardFake
        h.prompt.onShow = { _ in guardFake.sleepDisabled = true }
        h.prompt.mode = .fail
        h.prompt.wroteRecord = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
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

    /// Starts with a prompt that never exits by itself. Returns its handle
    /// once the start has been rolled back with the prompt still running;
    /// nil (after recording a failure and letting the prompt go, so the
    /// test ends instead of hanging) if the start waited for it instead.
    private func startWithAVoidedStuckPrompt(_ m: SessionManager) async throws -> UnfinishedPrompt? {
        h.prompt.mode = .stuck
        let start = Task { await m.start(duration: 1800) }
        let notifier = h.notifier
        let rolledBack = { notifier.posts.contains { $0.title == "Session not started" } }
        try await waitUntil("the start is rolled back while the prompt runs", rolledBack)
        let handle = try XCTUnwrap(h.prompt.unfinished)
        guard rolledBack() else {
            handle.markExited()
            await start.value
            return nil
        }
        await start.value
        return handle
    }

    /// A prompt whose process will not stop, with its marker gone under
    /// the marker's lock: the command behind it can no longer change
    /// anything, so the start is rolled back at once and the recovery lock
    /// is let go while osascript still runs. Nothing is killed. The menu
    /// names the pid while osascript runs, drops the kill when it exits,
    /// and drops the line once the whole prompt has exited.
    func testStuckPromptWhoseMarkerIsGoneIsRolledBackWithoutWaiting() async throws {
        let m = h.makeManager()
        guard let handle = try await startWithAVoidedStuckPrompt(m) else { return }

        XCTAssertTrue(handle.osascriptAlive, "osascript has not exited")
        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "the marker still held the bare nonce, so nothing is undone")
        let free = try XCTUnwrap(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire(), "the recovery lock is let go")
        free.release()
        let stuck = h.notifier.posts.filter { $0.title == "Password prompt still running" }
        XCTAssertEqual(stuck.count, 1, "\(h.notifier.posts)")
        let body = try XCTUnwrap(stuck.first).body
        XCTAssertTrue(body.contains("pid 4242"), body)
        XCTAssertTrue(body.contains("can no longer turn sleep off"), body)
        XCTAssertFalse(body.contains("kill"), "a notification outlives the pid, which may be reused: \(body)")
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
        XCTAssertTrue(try XCTUnwrap(m.lastError).hasSuffix("kill 4242"), "the menu line offers it while osascript runs")

        // Nothing waits behind it: an end runs and a later start shows its
        // own dialog.
        let outcome = await m.end(reason: .user)
        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(handle.isRunning)

        // osascript exits while a command it started still holds its
        // output: the kill goes, the line stays until that exits too.
        handle.markOsascriptExited()
        try await waitUntil("the menu line drops the kill") {
            !(m.lastError?.contains("kill") ?? true)
        }
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("a command it started as root is still running"), m.lastError ?? "")
        handle.markExited()
        try await waitUntil("the menu line goes with the prompt") { m.lastError == nil }

        h.prompt.mode = .succeed
        await m.start(duration: 1800)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.shown, 2)
    }

    /// A menu line set by something else after the report is not the
    /// watcher's to replace or clear.
    func testVoidedPromptWatcherLeavesALaterLineAlone() async throws {
        let m = h.makeManager()
        guard let handle = try await startWithAVoidedStuckPrompt(m) else { return }
        h.backstop.outdatedScript = true
        await m.start(duration: 1800)
        let later = try XCTUnwrap(m.lastError)
        XCTAssertTrue(later.hasPrefix("start refused"), later)

        handle.markExited()
        try await waitUntil("the watcher sees the prompt exit") {
            ((try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? "").contains("whose start was voided, has exited")
        }
        XCTAssertEqual(m.lastError, later)
    }

    // MARK: Abandoned dialog

    /// The app died while its dialog was up: session.json, the journal
    /// entry and the marker are on disk, sleep is still on. The relaunch
    /// deletes the marker under the lock and ends the session; a late
    /// answer to the old dialog then runs nothing.
    func testRelaunchVoidsTheDialogOfAStartThatDied() async throws {
        _ = try seedValidSession()
        let orphan = PendingStart(marker: h.home.paths.pendingStartFile, nonce: UUID().uuidString, deadline: Date().addingTimeInterval(3600))
        try h.store.savePendingStart(orphan.nonce)
        h.guardFake.sleepDisabled = false
        let m = h.makeManager()
        await m.reconcile()

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 0)
        let late = try runRootCommand(marker: orphan.marker, nonce: orphan.nonce, deadline: orphan.deadlineArgument, receipts: h.receipts, in: h.home.root)
        XCTAssertEqual(late.status, 69, late.stderr)
        XCTAssertEqual(late.pmsetCalls, [], "the late answer must not turn sleep off")
    }

    /// The app died under its dialog, the dialog was answered, and its
    /// root command is still in pmset when the app comes back. Reconcile
    /// cannot take the marker's lock: sleep is restored, but the entry
    /// stays, which the menu and a notification report. After the command
    /// is done, the next run removes the marker, restores again and
    /// clears the entry.
    func testRelaunchWhileTheAbandonedDialogsCommandRunsKeepsTheSleepEntry() async throws {
        _ = try seedValidSession()
        let orphan = PendingStart(marker: h.home.paths.pendingStartFile, nonce: UUID().uuidString, deadline: Date().addingTimeInterval(3600))
        try h.store.savePendingStart(orphan.nonce)
        let command = try RootCommandProcess(marker: orphan.marker, nonce: orphan.nonce, deadline: orphan.deadlineArgument, receipts: h.receipts, in: h.home.root, holdAt: RootCommandProcess.write)
        defer { command.release() }
        XCTAssertTrue(command.waitUntilPmsetRuns())
        h.guardFake.sleepDisabled = false
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(h.guardFake.calls, ["pmset -g", "disablesleep 0"], "sleep itself is still restored")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the entry stays while the command may still turn sleep off")
        XCTAssertTrue(markerExists)
        XCTAssertNotNil(m.markerProblem)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("pending-start marker could not be removed"), err)
        XCTAssertTrue(err.contains("still locked"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Restore incomplete")
        XCTAssertTrue(post.body.contains("pending-start marker could not be removed"), post.body)

        // No new dialog while the old command may still act.
        await m.start(duration: 1800)
        XCTAssertEqual(h.prompt.shown, 0)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
        XCTAssertTrue(try XCTUnwrap(h.notifier.posts.last).body.hasPrefix("Nothing was changed: the pending-start marker could not be removed"))

        command.release()
        let r = command.wait()
        XCTAssertEqual(r.pmsetCalls, ["-g", "-a disablesleep 1"])
        h.guardFake.sleepDisabled = true
        await m.reconcile()

        try assertRolledBackClean(m)
        XCTAssertNil(m.markerProblem)
        XCTAssertNil(m.lastError, "the marker line goes with the marker")
    }

    /// A marker that cannot be deleted (an immutable flag) is the same to
    /// recovery as one still in use: sleep is restored, the entry stays,
    /// starts are refused, and once the flag is gone the next run
    /// finishes.
    func testUndeletableMarkerKeepsTheSleepEntryAndRefusesStarts() async throws {
        var dirty = RuntimeState()
        dirty.sleepDisabledByUs = true
        try h.store.saveState(dirty)
        try h.store.savePendingStart(UUID().uuidString)
        let path = h.home.paths.pendingStartFile.path
        XCTAssertEqual(chflags(path, UInt32(UF_IMMUTABLE)), 0)
        defer { chflags(path, 0) }
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 0" }.count, 1)
        XCTAssertFalse(h.guardFake.sleepDisabled, "sleep itself is restored")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertTrue(markerExists)
        XCTAssertEqual(h.notifier.posts.last?.title, "Restore incomplete")
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("pending-start marker could not be removed"))

        await m.start(duration: 1800)
        XCTAssertEqual(h.prompt.shown, 0, "no start while the marker stays")
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertTrue(try XCTUnwrap(m.lastError).hasPrefix("the pending-start marker could not be removed"), m.lastError ?? "")
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
        XCTAssertTrue(try XCTUnwrap(h.notifier.posts.last).body.hasPrefix("Nothing was changed: the pending-start marker could not be removed"))

        chflags(path, 0)
        await m.reconcile()
        try assertRolledBackClean(m)
        XCTAssertNil(m.markerProblem)
        XCTAssertNil(m.lastError, "the marker line goes with the marker")
    }

    /// Sleep is restored but its journal entry cannot be cleared: the end
    /// reports itself incomplete and logs why, the entry stays, and the
    /// next run restores again and clears it.
    func testSleepRestoreWhoseJournalClearFailsIsReported() async throws {
        let m = h.makeManager()
        await m.start(duration: 1800)
        XCTAssertTrue(m.isActive)
        let file = h.home.paths.stateFile.path
        // Rename over an immutable state.json is refused.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        let outcome = await m.end(reason: .user)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertFalse(h.guardFake.sleepDisabled)
        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the entry stays for the next run")
        XCTAssertEqual(m.state.sleepDisabledByUs, true)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("sleep restored but the journal entry could not be cleared: "), err)
        XCTAssertTrue(err.hasSuffix("; it will be retried"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Restore incomplete")
        XCTAssertTrue(post.body.hasPrefix(err), post.body)
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("[error] insomnia: \(err)"), log)

        await m.reconcile()
        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls.filter { $0 == "disablesleep 0" }.count, 2)
    }

    /// The stuck prompt's root command is past its check and holds the
    /// marker's lock, so it may still run pmset: the marker, session.json,
    /// the journal entry and the recovery lock all stay, an end requested
    /// meanwhile queues behind it, nothing is killed, the menu stops naming
    /// the pid once osascript exits, and the rollback runs, after the
    /// marker goes, once the whole prompt has exited.
    func testStuckPromptWhoseCommandHoldsTheMarkerIsWaitedFor() async throws {
        let box = LockHolderBox()
        h.prompt.onShow = { start in box.hold(start.marker) }
        h.prompt.mode = .stuck
        h.prompt.wroteRecord = true
        let m = h.makeManager()

        let start = Task { await m.start(duration: 1800) }
        try await waitUntil("the stuck prompt is reported") {
            h.notifier.posts.contains { $0.title == "Password prompt still running" }
        }
        let handle = try XCTUnwrap(h.prompt.unfinished)
        XCTAssertTrue(handle.isRunning)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertTrue(post.body.contains("pid 4242"), post.body)
        XCTAssertTrue(post.body.contains("waits for it before rolling the start back"), post.body)
        XCTAssertFalse(post.body.contains("kill"), "a notification outlives the pid, which may be reused: \(post.body)")
        XCTAssertTrue(try XCTUnwrap(m.lastError).hasSuffix("kill 4242"), "the menu line offers it while osascript runs")
        XCTAssertTrue(markerExists, "the command holding its lock keeps it")
        XCTAssertNotNil(m.markerProblem)
        XCTAssertNil(m.session, "no session is surfaced")
        XCTAssertNotNil(try h.store.loadSession(), "session.json stays so the backstop honours the deadline")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the journal entry stays")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "nothing is rolled back beside a command that may still run")
        XCTAssertNil(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire(), "the recovery lock stays held")

        let end = Task { await m.end(reason: .user) }
        await settleQueuedRequests()
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "the end waits behind the prompt")

        // osascript exits while the command it started still holds its
        // output: the menu line stops offering the kill at once, and
        // nothing else moves.
        handle.markOsascriptExited()
        try await waitUntil("the menu line drops the kill") {
            !(m.lastError?.contains("kill") ?? true)
        }
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains("a command it started as root is still running"), m.lastError ?? "")
        XCTAssertEqual(h.notifier.posts.filter { $0.title == "Password prompt still running" }.count, 1, "the change is a menu line, not a second notification")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "the rollback still waits for the output to close")

        box.release()
        handle.markExited()
        await start.value
        _ = await end.value
        try assertRolledBackClean(m)
        XCTAssertNil(m.markerProblem)
        XCTAssertFalse(m.lastError?.contains("kill") ?? false, "\(m.lastError ?? "")")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        XCTAssertTrue(h.notifier.posts.contains { $0.title == "Session not started" })
        XCTAssertEqual(h.prompt.shown, 1)
    }

    /// The same wait, for a command that held the marker's lock but had
    /// not written its record when it exited: once the marker goes it
    /// still holds the bare nonce, so the rollback runs no undo and a 1
    /// another tool set while the dialog was up stays.
    func testStuckPromptWhoseCommandExitsBeforeItsRecordIsRolledBackWithoutAnUndo() async throws {
        let box = LockHolderBox()
        let guardFake = h.guardFake
        h.prompt.onShow = { start in
            box.hold(start.marker)
            guardFake.sleepDisabled = true
        }
        h.prompt.mode = .stuck
        let m = h.makeManager()

        let start = Task { await m.start(duration: 1800) }
        try await waitUntil("the stuck prompt is reported") {
            h.notifier.posts.contains { $0.title == "Password prompt still running" }
        }
        let handle = try XCTUnwrap(h.prompt.unfinished)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the journal entry stays while the command may run")
        box.release()
        handle.markExited()
        await start.value

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertTrue(h.guardFake.sleepDisabled, "the other tool's setting must survive")
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(markerExists)
        XCTAssertNil(m.markerProblem)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started")
    }

    /// A stuck prompt whose marker goes at once, holding the record: the
    /// command got past its checks before it was voided, so the start is
    /// undone like an end.
    func testStuckPromptWhoseMarkerHeldTheRecordIsUndone() async throws {
        h.prompt.wroteRecord = true
        let m = h.makeManager()
        guard let handle = try await startWithAVoidedStuckPrompt(m) else { return }

        try assertRolledBackClean(m)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
        handle.markExited()
    }

    /// The stuck prompt's command holds the lock on the marker this start
    /// wrote, and a copy has taken its place. The copy is unlocked, but it
    /// is not the file the start wrote, so the prompt is not counted as
    /// voided: nothing is rolled back beside the command, and the rollback
    /// runs once the prompt has exited.
    func testStuckPromptWhoseMarkerWasReplacedIsWaitedFor() async throws {
        let box = LockHolderBox()
        h.prompt.onShow = { start in
            box.hold(start.marker)
            let copy = start.marker.deletingLastPathComponent().appendingPathComponent("copy")
            try? Data(start.nonce.utf8).write(to: copy)
            _ = rename(copy.path, start.marker.path)
        }
        h.prompt.mode = .stuck
        let m = h.makeManager()

        let start = Task { await m.start(duration: 1800) }
        try await waitUntil("the stuck prompt is reported") {
            h.notifier.posts.contains { $0.title == "Password prompt still running" }
        }
        let handle = try XCTUnwrap(h.prompt.unfinished)
        XCTAssertTrue(markerExists, "the copy is not deleted")
        let problem = try XCTUnwrap(m.markerProblem)
        XCTAssertTrue(problem.contains("replaced or removed by something other than Insomnia"), problem)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the journal entry stays")
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "nothing is rolled back beside a command that may still run")
        XCTAssertNil(try RecoveryLock(url: h.home.paths.recoveryLock).tryAcquire(), "the recovery lock stays held")

        box.release()
        handle.markExited()
        await start.value
        try assertRolledBackClean(m)
        XCTAssertNil(m.markerProblem)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
    }

    /// The same, and the user has started again since: the old dialog's
    /// nonce is not the new start's, so it still runs nothing.
    func testDialogOfAStartThatDiedCannotActForANewerStart() async throws {
        _ = try seedValidSession()
        let orphan = PendingStart(marker: h.home.paths.pendingStartFile, nonce: UUID().uuidString, deadline: Date().addingTimeInterval(3600))
        try h.store.savePendingStart(orphan.nonce)
        h.guardFake.sleepDisabled = false
        let m = h.makeManager()
        await m.reconcile()

        h.prompt.mode = .hang
        let start = Task { await m.start(duration: 1800) }
        await h.prompt.gate.waitUntilStarted()
        let newer = try XCTUnwrap(h.prompt.starts.first)
        XCTAssertNotEqual(newer.nonce, orphan.nonce)
        let late = try runRootCommand(marker: orphan.marker, nonce: orphan.nonce, deadline: orphan.deadlineArgument, receipts: h.receipts, in: h.home.root)
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

/// Start end to end through the real PmsetSleepGuard and
/// OsascriptAdministratorPrompt, on a fake machine (FakeDialogMachine)
/// whose osascript runs the root command embedded in the AppleScript under
/// the real lockf, with fake sudo, env, pmset and clock. No dialog, sudo or
/// pmset of the machine's own runs.
@MainActor
final class StartOwnershipEndToEndTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    /// The harness clock: every session starts at this second.
    private let now = 1_800_000_000

    /// A fake machine in its own directory. Its clock reads `clockStart`
    /// until the root command's call `clockAt` has answered, then
    /// `clockLater`.
    /// It writes the harness's receipt, which the manager reads; each
    /// machine starts it over with install.sh's content.
    private func machine(_ name: String = "machine", clockStart: Int? = nil, clockLater: Int? = nil, clockAt: String = RootCommandProcess.ruleQuery) throws -> FakeDialogMachine {
        TestReceipts.write(h.receipts.file, nonce: "00000000-0000-0000-0000-000000000000", word: "refused")
        XCTAssertEqual(TestReceipts.text(h.receipts), SleepOffReceipts.initialContent)
        return try FakeDialogMachine(
            in: h.home.root.appendingPathComponent(name, isDirectory: true),
            clockStart: clockStart ?? now, clockLater: clockLater ?? now + 5, clockAt: clockAt, receipts: h.receipts)
    }

    /// The root command's three questions, each as root's sudo to the user
    /// and as the user's own sudo it starts.
    private var queries: [String] {
        let asUser = "-n -u #\(getuid()) /usr/bin/env -i LC_ALL=C /usr/bin/sudo "
        return ["-V", "-k -n -l", "-k -n -ll /usr/bin/pmset -a disablesleep 0"].flatMap { [asUser + $0, $0] }
    }

    /// The receipt after the start, with the nonce the dialog was given
    /// shown as `N`. Root writes nothing else: none of its sudo calls
    /// writes the marker (each test compares them all).
    private func receipt(_ fake: FakeDialogMachine) -> String {
        let text = TestReceipts.text(h.receipts) ?? "unreadable"
        guard let nonce = fake.nonce, !nonce.isEmpty else { return text }
        return text.replacingOccurrences(of: nonce, with: "N")
    }

    private func assertRolledBackWithNothingUndone(_ m: SessionManager, _ fake: FakeDialogMachine, status: Int32, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(m.session, file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), "session.json left behind", file: file, line: line)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, "journal left dirty", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path), "pending-start left behind", file: file, line: line)
        XCTAssertFalse(fake.sudoCalls().contains("-n /usr/bin/pmset -a disablesleep 0"), "the app ran an undo", file: file, line: line)
        let err = try XCTUnwrap(m.lastError, file: file, line: line)
        XCTAssertTrue(err.hasPrefix("could not disable sleep: Insomnia did not turn sleep off (the command behind the password dialog stopped with status \(status) before it changed anything)"), err, file: file, line: line)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started", file: file, line: line)
    }

    /// Control: the command asks sudo its three questions, reads sleep on
    /// and turns it off once; the end turns it back on.
    func testStartTurnsSleepOffAndTheEndTurnsItBackOn() async throws {
        let fake = try machine()
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        XCTAssertEqual(fake.script, AdministratorPrompt.disableSleepScript)
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1"], "Start's read, then the command's read and its write")
        XCTAssertEqual(fake.sudoCalls(), queries)
        XCTAssertEqual(receipt(fake), "N writing\n")
        XCTAssertEqual(fake.sleepDisabled, "1")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)
        XCTAssertNil(try h.store.loadState()?.sleepOffAttempt, "a start that finished settles its own record")

        await m.end(reason: .user)
        XCTAssertEqual(fake.sudoCalls().last, "-n /usr/bin/pmset -a disablesleep 0")
        XCTAssertEqual(fake.sleepDisabled, "0")
    }

    /// Round 14 P1, end to end: a SleepDisabled 1 set while the dialog is
    /// up, and a session whose end passes while sudo is asked. The command
    /// stops after the questions without reading or writing pmset, and the
    /// rollback runs none, so the 1 stays.
    func testASettingMadeWhileTheDialogIsUpSurvivesALateEnd() async throws {
        let fake = try machine(clockLater: now + 90)
        fake.foreignDuringDialog = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 60)

        XCTAssertEqual(fake.sleepDisabled, "1", "the other tool's setting must survive")
        XCTAssertEqual(fake.pmsetCalls(), ["-g"], "Start's read only")
        XCTAssertEqual(fake.sudoCalls(), queries)
        try assertRolledBackWithNothingUndone(m, fake, status: 4)
    }

    /// The same 1 with time to spare: the command's read finds it.
    func testASettingMadeWhileTheDialogIsUpIsLeftAlone() async throws {
        let fake = try machine()
        fake.foreignDuringDialog = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertEqual(fake.sleepDisabled, "1")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g"])
        XCTAssertEqual(fake.sudoCalls(), queries)
        XCTAssertEqual(receipt(fake), SleepOffReceipts.initialContent, "the read comes before the record")
        try assertRolledBackWithNothingUndone(m, fake, status: 6)
    }

    /// Round 17 R1, end to end: a 1 set while sudo is asked. Before, root
    /// had turned sleep off for its check by then, and the check's 0
    /// cleared the 1. Now nothing has been written, and the read finds it.
    func testASettingMadeWhileSudoIsAskedIsLeftAlone() async throws {
        for at in [RootCommandProcess.versionQuery, RootCommandProcess.listQuery, RootCommandProcess.ruleQuery] {
            let fake = try machine("machine \(at)".replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "_"))
            fake.foreignAfter = at
            let m = h.makeManager(sleepGuard: fake.sleepGuard())
            await m.start(duration: 1800)

            XCTAssertNil(fake.foreignAfter, "\(at): the other tool's 1 was set")
            XCTAssertEqual(fake.sleepDisabled, "1", at)
            XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g"], at)
            XCTAssertEqual(fake.sudoCalls(), queries, at)
            XCTAssertEqual(receipt(fake), SleepOffReceipts.initialContent, at)
            try assertRolledBackWithNothingUndone(m, fake, status: 6)
        }
    }

    /// A password typed after the session's end: the command stops before
    /// it asks or reads anything (status 4) and nothing is undone.
    func testALatePasswordRunsNothing() async throws {
        let fake = try machine(clockStart: now + 90)
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 60)

        XCTAssertEqual(fake.pmsetCalls(), ["-g"], "Start's read only")
        XCTAssertEqual(fake.sudoCalls(), [])
        XCTAssertEqual(fake.sleepDisabled, "0")
        try assertRolledBackWithNothingUndone(m, fake, status: 4)
    }

    /// The session's end passes while sudo is asked, with no other tool
    /// involved. Before, root had already turned sleep off and the check
    /// turned it back on. Now nothing was written, and the start is rolled
    /// back with no pmset at all after Start's read.
    func testAnEndWhileSudoIsAskedIsRolledBackWithoutAnUndo() async throws {
        let fake = try machine(clockLater: now + 90)
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 60)

        XCTAssertEqual(fake.pmsetCalls(), ["-g"])
        XCTAssertEqual(fake.sudoCalls(), queries)
        XCTAssertEqual(fake.sleepDisabled, "0")
        try assertRolledBackWithNothingUndone(m, fake, status: 4)
    }

    /// Round 17 R3, end to end: the session's end comes while root reads
    /// `pmset -g`, at its very second or later. Before, the clock was read
    /// before that read, and the write followed it. Now the clock is read
    /// again right before the write, which does not happen.
    func testAnEndDuringRootsReadWritesNothing() async throws {
        for later in [now + 60, now + 90] {
            let fake = try machine("machine-\(later - now)", clockLater: later, clockAt: RootCommandProcess.read)
            let m = h.makeManager(sleepGuard: fake.sleepGuard())
            await m.start(duration: 60)

            XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g"], "\(later - now) s")
            XCTAssertEqual(fake.sudoCalls(), queries, "\(later - now) s")
            XCTAssertEqual(receipt(fake), "N refused\n", "\(later - now) s: the record, then the refusal over it")
            XCTAssertEqual(fake.sleepDisabled, "0", "\(later - now) s")
            try assertRolledBackWithNothingUndone(m, fake, status: 4)
        }
    }

    /// A 1 the journal already owned (an earlier restore failed): neither
    /// Start nor the command reads it as someone else's. The command still
    /// asks sudo first, then turns sleep off; it no longer runs the owed
    /// restore itself.
    func testASettingTheJournalOwnsIsNotReadAsSomeoneElses() async throws {
        var earlier = RuntimeState()
        earlier.sleepDisabledByUs = true
        try h.store.saveState(earlier)
        let fake = try machine()
        fake.sleepDisabled = "1"
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        XCTAssertEqual(fake.pmsetCalls(), ["-a disablesleep 1"])
        XCTAssertEqual(fake.sudoCalls(), queries)
        XCTAssertEqual(receipt(fake), "N writing\n")
        XCTAssertEqual(fake.sleepDisabled, "1")
    }

    /// /etc/sudoers.d/insomnia is not in effect, or sudo's answers do not
    /// show it alone: the command stops before any pmset and the start
    /// rolls back with no undo. Sleep stays on, the journal is clean, and
    /// pmset ran only for Start's read.
    func testARefusedRestoreQueryLeavesSleepOnWithNoUndo() async throws {
        for (policy, calls): (RootSudoPolicy, Int) in [(.noRule, 4), (.laterRule, 6), (.oldSudo, 2)] {
            let fake = try machine("machine-\(policy)")
            fake.policy = policy
            let m = h.makeManager(sleepGuard: fake.sleepGuard())
            await m.start(duration: 1800)

            XCTAssertEqual(fake.pmsetCalls(), ["-g"], "\(policy): Start's read only")
            XCTAssertEqual(fake.sudoCalls(), Array(queries.prefix(calls)), "\(policy)")
            XCTAssertEqual(fake.sleepDisabled, "0", "\(policy)")
            XCTAssertNil(m.session, "\(policy)")
            XCTAssertNil(try h.store.loadSession(), "\(policy)")
            XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, "\(policy)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path), "\(policy)")
            let err = try XCTUnwrap(m.lastError)
            XCTAssertTrue(err.hasPrefix("could not disable sleep: sleep was not turned off: sudo did not confirm"), "\(policy): \(err)")
        }
    }

    /// Round 17 R2, end to end: another tool's 1 set while sudo is asked,
    /// and sudo does not confirm the restore. Before, root's own restore
    /// wrote 0 over it. Now nothing is written, and the 1 stays.
    func testASettingMadeWhileSudoIsAskedSurvivesARefusal() async throws {
        let fake = try machine()
        fake.policy = .noRule
        fake.foreignAfter = RootCommandProcess.versionQuery
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertNil(fake.foreignAfter, "the other tool's 1 was set")
        XCTAssertEqual(fake.sleepDisabled, "1")
        XCTAssertEqual(fake.pmsetCalls(), ["-g"])
        XCTAssertNil(m.session)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(fake.sudoCalls().contains("-n /usr/bin/pmset -a disablesleep 0"), "the app ran an undo")
    }

    /// The limit, end to end. Another tool sets 1 right after the
    /// command's own read found 0. pmset has no compare-and-set, so the
    /// write that follows cannot be told from it: the start goes on, that
    /// 1 is journaled as Insomnia's, and the end clears it. When the
    /// session's end comes during that read, the write does not follow,
    /// and the 1 stays.
    func testASettingMadeRightAfterTheCommandsReadIsClearedOnlyWhenTheWriteFollows() async throws {
        let fake = try machine()
        fake.foreignAfter = RootCommandProcess.read
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        XCTAssertNil(fake.foreignAfter, "the other tool's 1 was set")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1"])
        await m.end(reason: .user)
        XCTAssertEqual(fake.sleepDisabled, "0", "the end cleared it")

        let late = try machine("machine-late", clockLater: now + 90, clockAt: RootCommandProcess.read)
        late.foreignAfter = RootCommandProcess.read
        let m2 = h.makeManager(sleepGuard: late.sleepGuard())
        await m2.start(duration: 60)

        XCTAssertNil(late.foreignAfter, "the other tool's 1 was set")
        XCTAssertEqual(late.pmsetCalls(), ["-g", "-g"])
        XCTAssertEqual(late.sleepDisabled, "1", "no write followed the read")
        try assertRolledBackWithNothingUndone(m2, late, status: 4)
    }

    // MARK: Round 19

    /// Round 19 P1 (ownership), end to end. Another tool sets 1 while the
    /// dialog is up, and the command is stopped before its record: while
    /// sudo is asked, or as root's read starts. lockf reports the signal as
    /// 70, which could have come from anywhere. The receipt still holds
    /// another start's nonce, so the start is rolled back with no undo, and
    /// the 1 stays. Round 22: the read is before the record now, so a stop
    /// there leaves the 1 too.
    func testACommandStoppedBeforeItsRecordLeavesASettingMadeWhileTheDialogWasUp() async throws {
        for at in [RootCommandProcess.versionQuery, RootCommandProcess.listQuery, RootCommandProcess.ruleQuery, RootCommandProcess.read] {
            let fake = try machine("machine \(at)".replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "_"))
            fake.foreignDuringDialog = true
            fake.interruptAt = at
            let m = h.makeManager(sleepGuard: fake.sleepGuard())
            await m.start(duration: 1800)

            XCTAssertNil(fake.interruptAt, "\(at): the command was stopped")
            XCTAssertEqual(fake.sleepDisabled, "1", "\(at): the other tool's setting must survive")
            XCTAssertEqual(fake.pmsetCalls(), at == RootCommandProcess.read ? ["-g", "-g"] : ["-g"], "\(at): Start's read, and root's when it was stopped there")
            XCTAssertEqual(receipt(fake), SleepOffReceipts.initialContent, at)
            XCTAssertFalse(fake.sudoCalls().contains("-n /usr/bin/pmset -a disablesleep 0"), "\(at): the app ran an undo")
            XCTAssertNil(m.session, at)
            XCTAssertNil(try h.store.loadSession(), at)
            XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, at)
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path), at)
            let err = try XCTUnwrap(m.lastError)
            XCTAssertTrue(err.hasPrefix("could not disable sleep: the administrator password prompt failed (osascript exited 1)"), "\(at): \(err)")
            XCTAssertTrue(err.hasSuffix("(70)"), "\(at): lockf's status for a command ended by a signal: \(err)")
            let post = try XCTUnwrap(h.notifier.posts.last)
            XCTAssertEqual(post.title, "Session not started", at)
            XCTAssertTrue(post.body.hasSuffix("The receipt shows that the command behind the password dialog never turned sleep off."), post.body)
        }
    }

    /// The limit that stays: another tool sets 1 right after root's read,
    /// and the command is stopped after its record, as its write starts.
    /// The receipt holds this start's `writing`, which cannot show whether
    /// the write ran, so the start is undone like an end and the other
    /// tool's 1 is cleared with it.
    func testACommandStoppedAfterItsRecordIsUndoneEvenBeforeItsWrite() async throws {
        let fake = try machine()
        fake.foreignAfter = RootCommandProcess.read
        fake.interruptAt = RootCommandProcess.write
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertNil(fake.foreignAfter, "the other tool's 1 was set")
        XCTAssertNil(fake.interruptAt, "the command was stopped")
        XCTAssertEqual(receipt(fake), "N writing\n")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0"], "the write was stopped as it started; then the app's undo")
        XCTAssertEqual(fake.sudoCalls(), queries + ["-n /usr/bin/pmset -a disablesleep 0"], "the app undid")
        XCTAssertEqual(fake.sleepDisabled, "0", "and cleared the other tool's 1")
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// Round 19 P1 (silent approval plugin), end to end. Before, sudo's
    /// answers passed, the start turned sleep off, and the end's restore
    /// was rejected, leaving sleep off. Now the sudo.conf that loads the
    /// plugin stops the command before it asks sudo anything.
    func testASudoConfStopsTheStartBeforeSudoIsAsked() async throws {
        let fake = try machine()
        fake.sudoConf = SudoFormat.silentApprovalConf
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertEqual(fake.sudoCalls(), [])
        XCTAssertEqual(fake.pmsetCalls(), ["-g"], "Start's read only")
        XCTAssertEqual(fake.sleepDisabled, "0")
        XCTAssertNil(m.session)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("could not disable sleep: sleep was not turned off: sudo did not confirm"), err)
        XCTAssertTrue(err.contains("/etc/sudo.conf exists"), err)
    }

    /// Round 19 P1 (Defaults), end to end: the review's user Defaults
    /// (`log_output`, `!ignore_iolog_errors` and an I/O log directory under
    /// a regular file) make the restore fail, but not a listing. The
    /// command names the first one it does not accept and stops before any
    /// pmset; macOS's own Defaults pass (every other test here).
    func testUserDefaultsTheCheckDoesNotAcceptStopTheStart() async throws {
        let fake = try machine()
        fake.policy = .userDefaults
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertEqual(fake.sudoCalls(), Array(queries.prefix(4)))
        XCTAssertEqual(fake.pmsetCalls(), ["-g"])
        XCTAssertEqual(fake.sleepDisabled, "0")
        XCTAssertNil(m.session)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("sudo -k -n -l shows a Defaults entry this check does not accept: log_output."), err)
    }
}
