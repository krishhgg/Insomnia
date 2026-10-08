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

    /// The root command exits 5 when the restore check fails, after root
    /// has turned sleep back on; osascript ends its error with that status.
    /// The error says what to do about it.
    func testARefusedRestoreCheckIsReportedWithTheFix() async throws {
        let exe = try fakeOsascript("printf '0:812: execution error: sudo: a password is required\\rturning sleep back on needs a password, so it was turned back on at once and not left off (5)\\n' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("must throw")
        } catch let error as AdministratorPromptError {
            guard case .restoreNeedsPassword = error else { return XCTFail("\(error)") }
            let text = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(text.hasPrefix("sleep was not left off: turning it back on needs a password (`sudo -k -n /usr/bin/pmset -a disablesleep 0` failed: "), text)
            XCTAssertTrue(text.contains("sudo: a password is required"), text)
            XCTAssertTrue(text.hasSuffix("/etc/sudoers.d/insomnia is missing or not in effect; run scripts/install.sh again"), text)
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

    /// Each exit that means the root command stopped without leaving
    /// sleep off (its own 3, 4 and 6, lockf's 69 and 75) is a refusal:
    /// nothing to undo, and the error names the status.
    func testRootRefusalsLeaveNothingToUndo() async throws {
        for status: Int32 in [3, 4, 6, 69, 75] {
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
                XCTAssertTrue(text.hasPrefix("Insomnia did not leave sleep off (the command behind the password dialog stopped with status \(status) and undid anything it had changed)"), text)
            }
        }
    }

    /// Every other status, and a status that is not the end of the line,
    /// may have come after `disablesleep 1` (pmset's failure is 1, a
    /// signal 128 and up), so it stays an ambiguous failure the start
    /// undoes like an end.
    func testOtherRootStatusesAreFailuresToUndo() async throws {
        let lines = ["(1)", "(2)", "(7)", "(70)", "(71)", "(73)", "(126)", "(127)", "(143)", "(255)", "(-6)", "( 6)", "(6) pmset failed (1)", "(6).", "6"]
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

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("insomnia-root-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var marker: URL { dir.appendingPathComponent("pending-start") }
    private var store: Store { Store(paths: Paths(root: dir)) }

    private var restoreCheck: [String] {
        ["-n -u #\(getuid()) /usr/bin/sudo -k -n /usr/bin/pmset -a disablesleep 0", "-k -n /usr/bin/pmset -a disablesleep 0"]
    }

    private var uid: String { String(getuid()) }

    /// Every pmset call a command that turns sleep off makes: the read, the
    /// change the check undoes, the restore check, the read after it, and
    /// the session's change.
    private let allCalls = ["-g", "-a disablesleep 1", "-a disablesleep 0", "-g", "-a disablesleep 1"]
    /// Who runs them: root, except the restore check, run as the user.
    private var allAs: [String] { ["root", "root", uid, "root", "root"] }
    /// A restore check that fails: the read, root's change, and root's own
    /// restore of it. The user's sudo starts no pmset.
    private let refusedCalls = ["-g", "-a disablesleep 1", "-a disablesleep 0"]
    private let refusedAs = ["root", "root", "root"]

    /// With the rule in effect, root reads sleep on and turns it off. The
    /// restore check then runs as the user who pressed Start, through that
    /// user's sudo with -k and -n, and turns sleep back on, undoing root's
    /// own change. Root reads sleep on again and turns it off for the
    /// session.
    func testTurnsSleepOffWhileTheMarkerHoldsTheNonce() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.sudoCalls, restoreCheck)
        XCTAssertEqual(r.pmsetCalls, allCalls)
        XCTAssertEqual(r.pmsetAs, allAs)
        XCTAssertEqual(r.sleepDisabled, "1")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "nonce-1", "lockf -k leaves the file")
    }

    /// The check runs the line the app's end runs (`sudo -n /usr/bin/pmset`
    /// with `PmsetSleepGuard.restoreArguments`), so a pass means that end
    /// can run. It runs right after root's own `disablesleep 1`, so the
    /// 0 it writes is the undo of that change.
    func testTheCheckRunsTheRestoreTheEndRuns() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        let endLine = ([PmsetSleepGuard.pmset] + PmsetSleepGuard.restoreArguments).joined(separator: " ")
        XCTAssertEqual(r.sudoCalls.last, "-k -n " + endLine)
        XCTAssertEqual(r.pmsetCalls[2], PmsetSleepGuard.restoreArguments.joined(separator: " "))
        XCTAssertEqual(r.pmsetAs[2], uid)
        XCTAssertEqual(Array(r.pmsetCalls[1...2]), ["-a disablesleep 1", "-a disablesleep 0"], "the check undoes the change root made just before it")
        XCTAssertEqual(r.pmsetAs[1], "root")
    }

    /// No rule, and a credential a recent sudo in a terminal cached: sudo
    /// would run the restore without asking, but -k makes it ignore that
    /// credential, so the check fails, and root turns sleep back on itself.
    func testRefusesWhenOnlyACachedCredentialWouldRunTheRestore() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", policy: .cached, in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.sudoCalls, restoreCheck)
        XCTAssertEqual(r.pmsetCalls, refusedCalls)
        XCTAssertEqual(r.pmsetAs, refusedAs, "the user's sudo ran nothing; root restored its own change")
        XCTAssertEqual(r.sleepDisabled, "0")
        XCTAssertTrue(r.stderr.contains("sudo: a password is required"), r.stderr)
        XCTAssertTrue(r.stderr.contains("turning sleep back on needs a password, so it was turned back on at once and not left off"), r.stderr)
    }

    /// No rule, but another passwordless entry lets `sudo -l` list the
    /// restore without a password. Listing is not running: the check
    /// fails.
    func testRefusesWhenTheRestoreIsListedButNeedsAPasswordToRun() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", policy: .listOnly, in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.sudoCalls, restoreCheck, "the check runs the restore; it never lists")
        XCTAssertEqual(r.pmsetCalls, refusedCalls)
        XCTAssertEqual(r.pmsetAs, refusedAs)
        XCTAssertEqual(r.sleepDisabled, "0")
    }

    func testRefusesWithoutTheRule() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", policy: .noRule, in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.pmsetCalls, refusedCalls)
        XCTAssertEqual(r.sleepDisabled, "0")
    }

    /// Root's own sudoers entry is gone, so root cannot run the check as
    /// the user: that fails closed too.
    func testRefusesWhenRootCannotRunTheCheckAsTheUser() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", policy: .noRootEntry, in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.sudoCalls, [restoreCheck[0]])
        XCTAssertEqual(r.pmsetCalls, refusedCalls)
        XCTAssertEqual(r.pmsetAs, refusedAs)
        XCTAssertEqual(r.sleepDisabled, "0")
    }

    /// Every policy but the NOPASSWD rule, in both copies of the command:
    /// a cached credential, a listing-only entry, no rule, the rule without
    /// NOPASSWD, a rule that denies the restore, and no root entry. Each
    /// fails the check, which never prompts, and each leaves sleep on with
    /// nothing the user's sudo started.
    func testEveryPolicyButTheRuleLeavesSleepOn() throws {
        for policy: RootSudoPolicy in [.cached, .listOnly, .noRule, .passwd, .deny, .noRootEntry] {
            for (name, command) in try bothCommands() {
                try Data("nonce-1".utf8).write(to: marker)
                let r = try runRootCommand(marker: marker, nonce: "nonce-1", policy: policy, command: command, in: dir)
                let label = "\(policy) \(name)"
                XCTAssertEqual(r.status, 5, "\(label): \(r.stderr)")
                XCTAssertEqual(r.pmsetCalls, refusedCalls, label)
                XCTAssertEqual(r.pmsetAs, refusedAs, label)
                XCTAssertEqual(r.sleepDisabled, "0", label)
                XCTAssertFalse(r.stderr.contains("would have prompted"), label)
            }
        }
        let control = try runRootCommand(marker: marker, nonce: "nonce-1", policy: .rule, in: dir)
        XCTAssertEqual(control.status, 0, control.stderr)
        XCTAssertEqual(control.pmsetAs, allAs)
    }

    /// The rule belongs to the user who pressed Start. Checked as another
    /// user, it does not pass.
    func testTheCheckIsForTheUserItIsGiven() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let other = String(getuid() + 1)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", uid: other, in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.sudoCalls.first, "-n -u #\(other) /usr/bin/sudo -k -n /usr/bin/pmset -a disablesleep 0")
        XCTAssertEqual(r.pmsetCalls, refusedCalls)
        XCTAssertEqual(r.sleepDisabled, "0")
    }

    /// A uid that is not a positive whole number is refused before sudo
    /// or pmset runs: root (0) never needs a password, so a check as root
    /// would prove nothing.
    func testAnUnusableUidRefusesWithoutRunningSudo() throws {
        try Data("nonce-1".utf8).write(to: marker)
        for uid in ["", "0", "-1", "abc", "501x", "1e3", "99999999999999999999", "$(touch canary)"] {
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", uid: uid, in: dir)
            XCTAssertEqual(r.status, 5, "uid \(uid.debugDescription): \(r.stderr)")
            XCTAssertEqual(r.sudoCalls, [], "uid \(uid.debugDescription)")
            XCTAssertEqual(r.pmsetCalls, [], "uid \(uid.debugDescription)")
            XCTAssertTrue(r.stderr.contains("turning sleep back on needs a password, so sleep was not turned off"), r.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("canary").path))
    }

    /// Recovery (or the start itself) deleted the marker: lockf -n has
    /// nothing to open, and a late answer runs nothing.
    func testDoesNothingOnceTheMarkerIsGone() throws {
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 69, r.stderr)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sudoCalls, [], "no restore check either")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "lockf -n never creates the marker")
    }

    /// A dialog left from an older start cannot act for a newer one.
    func testDoesNothingWhenANewerStartOwnsTheMarker() throws {
        try Data("nonce-2".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sudoCalls, [])
        XCTAssertTrue(r.stderr.contains("sleep was not turned off"), r.stderr)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "nonce-2", "the newer start's marker is left alone")
    }

    func testAnEmptyNonceNeverMatches() throws {
        try Data().write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "", in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
    }

    /// A password accepted at or after the session's end turns nothing
    /// off, even though the marker still holds the nonce.
    func testDoesNothingOnceTheSessionHasEnded() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let now = Int(Date().timeIntervalSince1970)
        for deadline in [now - 1, now, now - 86_400] {
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", deadline: String(deadline), in: dir)
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

    /// The embedded command, started 100 s before `fakeDeadline` on a fake
    /// clock that reads `afterRestore` once the restore check has run.
    private func runOnFakeClock(afterRestore: Int, policy: RootSudoPolicy = .rule, sleepDisabled: String = "0", owned: String = "0", foreignAfter: String? = nil, foreignSets: String = "1") throws -> RootCommandRun {
        try Data("nonce-1".utf8).write(to: marker)
        return try runRootCommand(
            marker: marker, nonce: "nonce-1", deadline: String(fakeDeadline), policy: policy,
            command: appleScriptEmbeddedRootCommand(),
            clock: RootCommandClock(start: fakeDeadline - 100, afterRestore: afterRestore),
            sleepDisabled: sleepDisabled, owned: owned, foreignAfter: foreignAfter, foreignSets: foreignSets, in: dir)
    }

    /// Control: a restore check that ends a second before the deadline
    /// turns sleep off after it.
    func testTurnsSleepOffWhenTheRestoreCheckEndsBeforeTheDeadline() throws {
        let r = try runOnFakeClock(afterRestore: fakeDeadline - 1)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.sudoCalls, restoreCheck)
        XCTAssertEqual(r.pmsetCalls, allCalls)
    }

    /// The restore check can be slow (sudo may wait on a directory
    /// service). When the session's end comes while it runs, at the very
    /// second of the deadline or after it, sleep is left as the check left
    /// it: on, root's own change undone, and nothing read or written after.
    func testLeavesSleepOnWhenTheRestoreCheckEndsAtOrAfterTheDeadline() throws {
        for afterRestore in [fakeDeadline, fakeDeadline + 1, fakeDeadline + 86_400] {
            let r = try runOnFakeClock(afterRestore: afterRestore)
            XCTAssertEqual(r.status, 4, "\(afterRestore): \(r.stderr)")
            XCTAssertEqual(r.sudoCalls, restoreCheck, "\(afterRestore)")
            XCTAssertEqual(r.pmsetCalls, ["-g", "-a disablesleep 1", "-a disablesleep 0"], "the check undid root's change; nothing ran after it: \(afterRestore)")
            XCTAssertEqual(r.pmsetAs, ["root", "root", uid], "\(afterRestore)")
            XCTAssertEqual(r.sleepDisabled, "0", "\(afterRestore)")
            XCTAssertTrue(r.stderr.contains("the session this password was for ended while the restore was checked; the check turned sleep back on and it was not left off"), r.stderr)
        }
    }

    /// A restore check that fails is still exit 5, on the same clock.
    func testAFailedRestoreCheckStillExitsFiveOnTheFakeClock() throws {
        let r = try runOnFakeClock(afterRestore: fakeDeadline - 1, policy: .noRule)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.sudoCalls, restoreCheck)
        XCTAssertEqual(r.pmsetCalls, refusedCalls)
        XCTAssertEqual(r.sleepDisabled, "0")
        XCTAssertTrue(r.stderr.contains("turning sleep back on needs a password, so it was turned back on at once and not left off"), r.stderr)
    }

    /// A deadline that is not a plain number fails the comparison, which
    /// refuses: a malformed one can never mean "no deadline".
    func testAnUnreadableDeadlineNeverPasses() throws {
        try Data("nonce-1".utf8).write(to: marker)
        for deadline in ["", "soon", "1e12", "0x2540BE3FF", "9999999999s", "99999999999999999999", "$(echo 9999999999)"] {
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", deadline: deadline, in: dir)
            XCTAssertEqual(r.status, 4, "deadline \(deadline.debugDescription): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, [], "deadline \(deadline.debugDescription)")
        }
    }

    /// When root's own restore after a failed check fails too, the command
    /// exits 1, never 5: the start then undoes it like an end.
    func testARootRestoreThatFailsIsNotARefusal() throws {
        for (name, command) in try bothCommands() {
            try Data("nonce-1".utf8).write(to: marker)
            let r = try RootCommandProcess(marker: marker, nonce: "nonce-1", policy: .noRule, command: command, rootRestoreFails: true, in: dir).wait()
            XCTAssertEqual(r.status, 1, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, refusedCalls, name)
            XCTAssertEqual(r.sleepDisabled, "1", "\(name): root's change is still in place, for the start's undo")
            XCTAssertFalse(r.stderr.contains("turning sleep back on needs a password"), "\(name): nothing claims sleep went back on")
        }
    }

    /// osascript may already have exited (SIGTERM at the deadline) when the
    /// check fails, and then the first write to the command's stderr kills
    /// it with SIGPIPE. Root turns sleep back on before it prints, so even
    /// then sleep is not left off. sudo's own message hits the closed pipe
    /// first; whatever kills it, the check has failed.
    func testAClosedDialogCannotStopRootsRestore() throws {
        for (name, command) in try bothCommands() {
            try Data("nonce-1".utf8).write(to: marker)
            let r = try RootCommandProcess(marker: marker, nonce: "nonce-1", policy: .noRule, command: command, outputClosed: true, in: dir).wait()
            XCTAssertNotEqual(r.status, 0, name)
            XCTAssertEqual(r.pmsetCalls, refusedCalls, name)
            XCTAssertEqual(r.sleepDisabled, "0", "\(name): sleep must not be left off")
        }
    }

    /// The command holds the marker's lock from before its check until
    /// pmset exits, so the app cannot delete the marker in between: the
    /// removal times out and the marker stays, and once pmset is done it
    /// goes.
    func testTheMarkerCannotBeRemovedWhilePmsetRuns() async throws {
        try Data("nonce-1".utf8).write(to: marker)
        let command = try RootCommandProcess(marker: marker, nonce: "nonce-1", in: dir, holdPmset: true)
        XCTAssertTrue(command.waitUntilPmsetRuns())

        do {
            try await store.removePendingStart(timeout: 0.3)
            XCTFail("the marker must not go while pmset runs")
        } catch StoreError.markerBusy {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "nonce-1")

        command.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
        let removed = try await store.removePendingStart(timeout: 5)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Greptile's case: the command holds the lock on the marker it opened
    /// and runs pmset, and a copy with the same nonce takes the marker's
    /// place. The copy is not locked, so a removal by path alone would
    /// delete it while pmset runs. The start knows which file it wrote and
    /// deletes nothing else.
    func testAReplacedMarkerIsNotDeletedWhilePmsetRuns() async throws {
        let written = try store.savePendingStart("nonce-1")
        let command = try RootCommandProcess(marker: marker, nonce: "nonce-1", in: dir, holdPmset: true)
        XCTAssertTrue(command.waitUntilPmsetRuns())
        let copy = dir.appendingPathComponent("copy")
        try Data("nonce-1".utf8).write(to: copy)
        XCTAssertEqual(rename(copy.path, marker.path), 0)

        do {
            try await store.removePendingStart(timeout: 0.3, expecting: written)
            XCTFail("the copy must not stand in for the locked marker")
        } catch StoreError.markerReplaced {
            // expected
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "nonce-1")

        command.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
    }

    /// The restore check runs under the same lock: while it runs, the
    /// marker cannot go, so recovery never undoes beside it.
    func testTheMarkerCannotBeRemovedWhileTheRestoreCheckRuns() async throws {
        try Data("nonce-1".utf8).write(to: marker)
        let command = try RootCommandProcess(marker: marker, nonce: "nonce-1", in: dir, holdPmset: true, holdAt: "-a disablesleep 0")
        XCTAssertTrue(command.waitUntilPmsetRuns())

        do {
            try await store.removePendingStart(timeout: 0.3)
            XCTFail("the marker must not go while the check runs")
        } catch StoreError.markerBusy {
            // expected
        }

        command.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, allCalls)
        let removed = try await store.removePendingStart(timeout: 5)
        XCTAssertTrue(removed)
    }

    /// The other order: a remover holds the lock when the answer comes.
    /// The command has opened the marker and waits for the lock, and by
    /// the time it has it the marker is gone, so nothing runs. The marker
    /// is deleted only once lockf is seen blocked on it (see
    /// `waitUntilLockfWaits`); a command that had not reached it yet would
    /// exit 69, not 3.
    func testAnAnswerThatWaitsOnARemovalRunsNothing() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let holder = try FileLockHolder(marker)
        let command = try RootCommandProcess(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertTrue(waitUntilLockfWaits(under: command.pid), "lockf never blocked on the marker")
        try FileManager.default.removeItem(at: marker)
        holder.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 3, r.stderr)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertEqual(r.sudoCalls, [])
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
        XCTAssertEqual(r.pmsetCalls, allCalls)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("canary").path))
    }

    // MARK: Someone else's SleepDisabled 1

    /// Both copies of the command: `rootCommand` and the one the
    /// AppleScript embeds.
    private func bothCommands() throws -> [(name: String, command: String)] {
        [("rootCommand", AdministratorPrompt.rootCommand), ("embedded", try appleScriptEmbeddedRootCommand())]
    }

    /// Round 14 P1: another tool sets SleepDisabled 1 while the password is
    /// typed. Start's own read found 0, but the command reads `pmset -g`
    /// again as root, before it writes anything, and leaves the 1 alone:
    /// no sudo, no pmset write.
    func testLeavesASleepSettingMadeWhileTheDialogWasUp() throws {
        for (name, command) in try bothCommands() {
            try Data("nonce-1".utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", command: command, sleepDisabled: "1", in: dir)
            XCTAssertEqual(r.status, 6, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-g"], name)
            XCTAssertEqual(r.sudoCalls, [], "\(name): the restore check would have cleared it")
            XCTAssertEqual(r.sleepDisabled, "1", name)
            XCTAssertTrue(r.stderr.contains("pmset -g shows a SleepDisabled 1 this start did not set, or could not be read; it was left alone and sleep was not turned off"), r.stderr)
        }
    }

    /// The reviewer's case on the fake clock: a 1 set while the dialog was
    /// up, and a deadline that passes during the restore check. Before,
    /// the check cleared the 1 and the deadline then stopped the command,
    /// leaving 0. Now the read stops it first, so the 1 stays, whatever
    /// the clock does after.
    func testASettingMadeWhileTheDialogWasUpSurvivesADeadlineDuringTheCheck() throws {
        for afterRestore in [fakeDeadline - 1, fakeDeadline, fakeDeadline + 1] {
            let r = try runOnFakeClock(afterRestore: afterRestore, sleepDisabled: "1")
            XCTAssertEqual(r.status, 6, "\(afterRestore): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-g"], "\(afterRestore)")
            XCTAssertEqual(r.sudoCalls, [], "\(afterRestore)")
            XCTAssertEqual(r.sleepDisabled, "1", "\(afterRestore)")
        }
    }

    /// A 1 set right after the restore check's write of 0: before the
    /// deadline, the read after the check finds it and leaves it; after
    /// the deadline, the command stops before that read and leaves it too.
    func testLeavesASleepSettingMadeAfterTheRestoreCheck() throws {
        let inTime = try runOnFakeClock(afterRestore: fakeDeadline - 1, foreignAfter: "-a disablesleep 0")
        XCTAssertEqual(inTime.status, 6, inTime.stderr)
        XCTAssertEqual(inTime.sudoCalls, restoreCheck)
        XCTAssertEqual(inTime.pmsetCalls, ["-g", "-a disablesleep 1", "-a disablesleep 0", "-g"])
        XCTAssertEqual(inTime.sleepDisabled, "1")
        XCTAssertTrue(inTime.stderr.contains("pmset -g shows a SleepDisabled 1 set after the restore check turned sleep back on, or could not be read; it was left alone and this start did not turn sleep off again"), inTime.stderr)

        let late = try runOnFakeClock(afterRestore: fakeDeadline + 1, foreignAfter: "-a disablesleep 0")
        XCTAssertEqual(late.status, 4, late.stderr)
        XCTAssertEqual(late.pmsetCalls, ["-g", "-a disablesleep 1", "-a disablesleep 0"])
        XCTAssertEqual(late.sleepDisabled, "1")

        let plain = try runRootCommand(marker: marker, nonce: "nonce-1", foreignAfter: "-a disablesleep 0", in: dir)
        XCTAssertEqual(plain.status, 6, plain.stderr)
        XCTAssertEqual(plain.sleepDisabled, "1")
    }

    /// `pmset -g` that fails is not taken for 0: the command stops before
    /// it writes anything, as Start does.
    func testAnUnreadableSettingStopsBeforeTheRestoreCheck() throws {
        for (name, command) in try bothCommands() {
            try Data("nonce-1".utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", command: command, sleepDisabled: "fail", in: dir)
            XCTAssertEqual(r.status, 6, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-g"], name)
            XCTAssertEqual(r.sudoCalls, [], name)
            XCTAssertEqual(r.sleepDisabled, "fail", name)
        }
    }

    /// The read after the check fails the same way: the command stops
    /// before the session's change, and its own change is already undone.
    func testAnUnreadableSettingAfterTheCheckStopsBeforeTheChange() throws {
        let r = try runOnFakeClock(afterRestore: fakeDeadline - 1, foreignAfter: "-a disablesleep 0", foreignSets: "fail")
        XCTAssertEqual(r.status, 6, r.stderr)
        XCTAssertEqual(r.pmsetCalls, ["-g", "-a disablesleep 1", "-a disablesleep 0", "-g"])
        XCTAssertEqual(r.sleepDisabled, "fail")
    }

    /// `$5` is `1` only when the journal already owned the SleepDisabled 1
    /// (an earlier restore failed). Start skipped its read for that 1, and
    /// so does the command: it turns sleep off, runs the restore that was
    /// owed as its check, and turns sleep off again.
    func testAJournalOwnedSettingSkipsTheReads() throws {
        for (name, command) in try bothCommands() {
            try Data("nonce-1".utf8).write(to: marker)
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", command: command, sleepDisabled: "1", owned: "1", in: dir)
            XCTAssertEqual(r.status, 0, "\(name): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1", "-a disablesleep 0", "-a disablesleep 1"], name)
            XCTAssertEqual(r.pmsetAs, ["root", uid, "root"], name)
            XCTAssertEqual(r.sudoCalls, restoreCheck, name)
            XCTAssertEqual(r.sleepDisabled, "1", name)
        }
    }

    /// The same journal-owned 1 when the check fails: root runs the owed
    /// restore itself, so the Mac is left with sleep on. The journal entry
    /// the start rolls back to still says the restore is owed, and running
    /// it again sets 0 over 0.
    func testAJournalOwnedSettingIsRestoredWhenTheCheckFails() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", policy: .noRule, sleepDisabled: "1", owned: "1", in: dir)
        XCTAssertEqual(r.status, 5, r.stderr)
        XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1", "-a disablesleep 0"])
        XCTAssertEqual(r.pmsetAs, ["root", "root"])
        XCTAssertEqual(r.sleepDisabled, "0")
    }

    /// Only exactly `1` skips the reads; anything else, empty or odd,
    /// reads, and is never run.
    func testOnlyExactlyOneSkipsTheReads() throws {
        try Data("nonce-1".utf8).write(to: marker)
        for owned in ["", "0", "true", "yes", "01", " 1", "1 ", "1\n", "$(touch canary)", "1;touch canary"] {
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", sleepDisabled: "1", owned: owned, in: dir)
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
        try Data("nonce-1".utf8).write(to: marker)
        for output in outputs {
            let startReads = PmsetSleepGuard.parseSleepDisabled(output)
            let r = try runRootCommand(marker: marker, nonce: "nonce-1", pmsetOutput: output, in: dir)
            XCTAssertEqual(r.status, startReads ? 6 : 0, "\(output.debugDescription): \(r.stderr)")
            XCTAssertEqual(r.pmsetCalls, startReads ? ["-g"] : allCalls, output.debugDescription)
        }
    }

    /// Where another tool's SleepDisabled 1 lands decides whether it
    /// survives. Each row injects one 1 at one point, on the fake clock,
    /// through a check that passes, a check that fails (exit 5) and a
    /// deadline that passes during the check (exit 4).
    ///
    /// Before any write (set while the dialog was up) or after the check's
    /// write, the 1 survives every path. In between it does not: pmset has
    /// no compare-and-set, so a 1 set in the moment between the read and
    /// root's `disablesleep 1` cannot be told from that change, and neither
    /// can a 1 set while root's change is in effect. The check's write (or
    /// root's own restore when the check fails) clears it, and on the
    /// passing path the session's end would. These rows record that limit;
    /// they do not make it go away.
    func testWhereAnotherToolsOneLandsDecidesWhetherItSurvives() throws {
        struct Row {
            let at: String?
            let initial: String
            let policy: RootSudoPolicy
            let afterRestore: Int
            let status: Int32
            let left: String
            let survives: Bool
        }
        let pass = fakeDeadline - 1
        let late = fakeDeadline + 1
        let rows = [
            // Set while the dialog was up: the first read stops everything.
            Row(at: nil, initial: "1", policy: .rule, afterRestore: pass, status: 6, left: "1", survives: true),
            Row(at: nil, initial: "1", policy: .noRule, afterRestore: pass, status: 6, left: "1", survives: true),
            Row(at: nil, initial: "1", policy: .rule, afterRestore: late, status: 6, left: "1", survives: true),
            // Between the read and root's change: taken for Insomnia's own.
            Row(at: "-g", initial: "0", policy: .rule, afterRestore: pass, status: 0, left: "1", survives: false),
            Row(at: "-g", initial: "0", policy: .noRule, afterRestore: pass, status: 5, left: "0", survives: false),
            Row(at: "-g", initial: "0", policy: .rule, afterRestore: late, status: 4, left: "0", survives: false),
            // While root's change is in effect, before the check's write.
            Row(at: "-a disablesleep 1", initial: "0", policy: .rule, afterRestore: pass, status: 0, left: "1", survives: false),
            Row(at: "-a disablesleep 1", initial: "0", policy: .noRule, afterRestore: pass, status: 5, left: "0", survives: false),
            Row(at: "-a disablesleep 1", initial: "0", policy: .rule, afterRestore: late, status: 4, left: "0", survives: false),
            // After the check's write: the deadline or the second read
            // stops the command and the 1 stays.
            Row(at: "-a disablesleep 0", initial: "0", policy: .rule, afterRestore: pass, status: 6, left: "1", survives: true),
            Row(at: "-a disablesleep 0", initial: "0", policy: .rule, afterRestore: late, status: 4, left: "1", survives: true),
        ]
        for row in rows {
            let label = "\(row.at ?? "dialog") \(row.policy) \(row.afterRestore == pass ? "in time" : "late")"
            let r = try runOnFakeClock(afterRestore: row.afterRestore, policy: row.policy, sleepDisabled: row.initial, foreignAfter: row.at)
            XCTAssertEqual(r.status, row.status, "\(label): \(r.stderr)")
            XCTAssertEqual(r.sleepDisabled, row.left, label)
            // A 1 that survives is still there and the command stopped;
            // one that does not was cleared by a write of 0, or (status
            // 0) is now Insomnia's journaled 1, which the end clears.
            XCTAssertEqual(row.survives, r.status != 0 && r.sleepDisabled == "1", label)
        }
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
        let first = try await store.removePendingStart(timeout: 1)
        let second = try await store.removePendingStart(timeout: 1)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Waits for a lock that is let go within the timeout.
    func testWaitsForTheLockToBeLetGo() async throws {
        try Data("n".utf8).write(to: marker)
        let holder = try FileLockHolder(marker)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { holder.release() }
        let removed = try await store.removePendingStart(timeout: 5)
        XCTAssertTrue(removed)
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
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
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
        let locks = Locked(0)
        let removed = try await store.removePendingStart(timeout: 5, pollEvery: .milliseconds(10), onLocked: {
            locks.value += 1
            if locks.value == 1 { try? self.replaceMarker(with: "m") }
        })
        XCTAssertTrue(removed)
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
        XCTAssertTrue(removed)
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

    /// The password is accepted, but the root command finds that turning
    /// sleep back on needs a password, turns it back on itself and exits 5.
    /// Nothing is left that an undo would reverse: the start rolls back
    /// with no pmset, and the user is told to run install.sh again.
    func testStartWhoseRestoreCheckFailsRollsBackWithNothingToUndo() async throws {
        h.prompt.restoreNeedsPassword = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        try assertRolledBackClean(m)
        XCTAssertEqual(h.prompt.shown, 1)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"], "no restore runs after the check refused")
        XCTAssertEqual(h.guardFake.unlockedPrivilegedCalls, [])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("could not disable sleep: sleep was not left off: turning it back on needs a password"), err)
        XCTAssertTrue(err.hasSuffix("run scripts/install.sh again"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session not started")
        XCTAssertTrue(post.body.hasPrefix("No session was started, and Insomnia undid anything it changed: sleep was not left off"), post.body)
        XCTAssertTrue(post.body.contains("run scripts/install.sh again"), post.body)

        h.prompt.restoreNeedsPassword = false
        await m.start(duration: 1800)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.prompt.shown, 2)
    }

    /// A restore the journal already owed (an earlier one failed) stays
    /// owed when the check refuses: the rollback puts that entry back.
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
        XCTAssertTrue(err.hasPrefix("could not disable sleep: Insomnia did not leave sleep off (the command behind the password dialog stopped with status 6 and undid anything it had changed)"), err)
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session not started")
        XCTAssertTrue(post.body.hasPrefix("No session was started, and Insomnia undid anything it changed: Insomnia did not leave sleep off"), post.body)
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

    /// The limit on the other side: a failure that may have come after
    /// `disablesleep 1` (here osascript's own error) is still undone like
    /// an end, so a 1 another tool set while that dialog was up is cleared
    /// too. Leaving it would risk leaving Insomnia's own 1 with no
    /// journal entry.
    func testAnAmbiguousFailureStillUndoesASettingMadeMeanwhile() async throws {
        let guardFake = h.guardFake
        h.prompt.onShow = { _ in guardFake.sleepDisabled = true }
        h.prompt.mode = .fail
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
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1", "disablesleep 0"])
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
        let late = try runRootCommand(marker: orphan.marker, nonce: orphan.nonce, deadline: orphan.deadlineArgument, in: h.home.root)
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
        let command = try RootCommandProcess(marker: orphan.marker, nonce: orphan.nonce, deadline: orphan.deadlineArgument, in: h.home.root, holdPmset: true)
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
        XCTAssertEqual(r.pmsetCalls, ["-g", "-a disablesleep 1", "-a disablesleep 0", "-g", "-a disablesleep 1"])
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
        let late = try runRootCommand(marker: orphan.marker, nonce: orphan.nonce, deadline: orphan.deadlineArgument, in: h.home.root)
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
/// the real lockf, with fake sudo, pmset and clock. No dialog, sudo or
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

    private func machine(clockStart: Int? = nil, clockAfterRestore: Int? = nil) throws -> FakeDialogMachine {
        try FakeDialogMachine(
            in: h.home.root.appendingPathComponent("machine", isDirectory: true),
            clockStart: clockStart ?? now, clockAfterRestore: clockAfterRestore ?? now + 5)
    }

    private var restoreCheck: [String] {
        ["-n -u #\(getuid()) /usr/bin/sudo -k -n /usr/bin/pmset -a disablesleep 0", "-k -n /usr/bin/pmset -a disablesleep 0"]
    }

    private func assertRolledBackWithNothingUndone(_ m: SessionManager, _ fake: FakeDialogMachine, status: Int32, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertNil(m.session, file: file, line: line)
        XCTAssertNil(try h.store.loadSession(), "session.json left behind", file: file, line: line)
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean, "journal left dirty", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path), "pending-start left behind", file: file, line: line)
        XCTAssertFalse(fake.sudoCalls().contains("-n /usr/bin/pmset -a disablesleep 0"), "the app ran an undo", file: file, line: line)
        let err = try XCTUnwrap(m.lastError, file: file, line: line)
        XCTAssertTrue(err.hasPrefix("could not disable sleep: Insomnia did not leave sleep off (the command behind the password dialog stopped with status \(status) and undid anything it had changed)"), err, file: file, line: line)
        XCTAssertEqual(h.notifier.posts.last?.title, "Session not started", file: file, line: line)
    }

    /// Control: the command reads sleep on, turns it off, runs the restore
    /// check (which turns it back on), reads sleep on again and turns it
    /// off for the session; the end turns it back on.
    func testStartTurnsSleepOffAndTheEndTurnsItBackOn() async throws {
        let fake = try machine()
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        XCTAssertEqual(fake.script, AdministratorPrompt.disableSleepScript)
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0", "-g", "-a disablesleep 1"], "Start's read, then the command's")
        XCTAssertEqual(fake.sudoCalls(), restoreCheck)
        XCTAssertEqual(fake.sleepDisabled, "1")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)

        await m.end(reason: .user)
        XCTAssertEqual(fake.sudoCalls().last, "-n /usr/bin/pmset -a disablesleep 0")
        XCTAssertEqual(fake.sleepDisabled, "0")
    }

    /// Round 14 P1, reproduced end to end: a SleepDisabled 1 set while the
    /// dialog is up, and a session whose end passes during the restore
    /// check. Before, the check cleared the 1, the command stopped at the
    /// deadline, and the Mac was left at 0. Now the 1 stays, and nothing
    /// runs through sudo at all.
    func testASettingMadeWhileTheDialogIsUpSurvivesALateEnd() async throws {
        let fake = try machine(clockAfterRestore: now + 90)
        fake.foreignDuringDialog = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 60)

        XCTAssertEqual(fake.sleepDisabled, "1", "the other tool's setting must survive")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g"])
        XCTAssertEqual(fake.sudoCalls(), [])
        try assertRolledBackWithNothingUndone(m, fake, status: 6)
    }

    /// The same 1 with time to spare: still left alone.
    func testASettingMadeWhileTheDialogIsUpIsLeftAlone() async throws {
        let fake = try machine()
        fake.foreignDuringDialog = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertEqual(fake.sleepDisabled, "1")
        XCTAssertEqual(fake.sudoCalls(), [])
        try assertRolledBackWithNothingUndone(m, fake, status: 6)
    }

    /// A 1 set right after the restore check's write: the read after the
    /// check finds it, and the start is rolled back with no pmset.
    func testASettingMadeAfterTheRestoreCheckIsLeftAlone() async throws {
        let fake = try machine()
        fake.foreignAfterRestore = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertEqual(fake.sleepDisabled, "1")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0", "-g"])
        XCTAssertEqual(fake.sudoCalls(), restoreCheck)
        try assertRolledBackWithNothingUndone(m, fake, status: 6)
    }

    /// A password typed after the session's end: the command stops before
    /// any read or write (status 4) and nothing is undone.
    func testALatePasswordRunsNothing() async throws {
        let fake = try machine(clockStart: now + 90)
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 60)

        XCTAssertEqual(fake.pmsetCalls(), ["-g"], "Start's read only")
        XCTAssertEqual(fake.sudoCalls(), [])
        XCTAssertEqual(fake.sleepDisabled, "0")
        try assertRolledBackWithNothingUndone(m, fake, status: 4)
    }

    /// The session's end passes during the restore check, with no other
    /// tool involved: the check's 0 undid root's own change, the command
    /// stops there, and the start is rolled back with no further pmset.
    func testAnEndDuringTheRestoreCheckIsRolledBackWithoutAnUndo() async throws {
        let fake = try machine(clockAfterRestore: now + 90)
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 60)

        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0"])
        XCTAssertEqual(fake.sudoCalls(), restoreCheck)
        XCTAssertEqual(fake.sleepDisabled, "0")
        try assertRolledBackWithNothingUndone(m, fake, status: 4)
    }

    /// A 1 the journal already owned (an earlier restore failed): neither
    /// Start nor the command reads it as someone else's. The command runs
    /// the owed restore as its check and turns sleep off again.
    func testASettingTheJournalOwnsIsNotReadAsSomeoneElses() async throws {
        var earlier = RuntimeState()
        earlier.sleepDisabledByUs = true
        try h.store.saveState(earlier)
        let fake = try machine()
        fake.sleepDisabled = "1"
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        XCTAssertEqual(fake.pmsetCalls(), ["-a disablesleep 1", "-a disablesleep 0", "-a disablesleep 1"])
        XCTAssertEqual(fake.sudoCalls(), restoreCheck)
        XCTAssertEqual(fake.sleepDisabled, "1")
    }

    /// /etc/sudoers.d/insomnia is not in effect: the check fails, root
    /// turns its own change back on, and the start rolls back with no
    /// undo. Sleep is on, the journal is clean, and the app ran no pmset
    /// of its own after the dialog.
    func testAFailedRestoreCheckLeavesSleepOnWithNoUndo() async throws {
        let fake = try machine()
        fake.ruleMissing = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0"], "Start's read, then root's read, change and own restore")
        XCTAssertEqual(fake.sudoCalls(), restoreCheck)
        XCTAssertEqual(fake.sleepDisabled, "0")
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.pendingStartFile.path))
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.hasPrefix("could not disable sleep: sleep was not left off: turning it back on needs a password"), err)
    }

    /// The deadline path with another tool's 1 after the check's write: the
    /// session's end passed during the check, the command stops before
    /// reading again, and the rollback runs no pmset, so the 1 stays.
    func testASettingMadeAfterTheCheckSurvivesALateEnd() async throws {
        let fake = try machine(clockAfterRestore: now + 90)
        fake.foreignAfterRestore = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 60)

        XCTAssertEqual(fake.sleepDisabled, "1")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0"])
        try assertRolledBackWithNothingUndone(m, fake, status: 4)
    }

    /// The limit, end to end. Another tool sets 1 right after the command's
    /// own read found 0. pmset has no compare-and-set, so root's change
    /// writes 1 over it and the check's write clears it. With the rule in
    /// effect the start goes on, that 1 is now journaled as Insomnia's, and
    /// the end clears it; with the rule missing, root's restore clears it
    /// and the rollback leaves 0. The other tool's 1 is lost either way.
    func testASettingMadeRightAfterTheCommandsReadIsStillCleared() async throws {
        let fake = try machine()
        fake.foreignAfterRootRead = true
        let m = h.makeManager(sleepGuard: fake.sleepGuard())
        await m.start(duration: 1800)

        XCTAssertTrue(m.isActive, m.lastError ?? "")
        XCTAssertFalse(fake.foreignAfterRootRead, "the other tool's 1 was set")
        XCTAssertEqual(fake.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0", "-g", "-a disablesleep 1"])
        await m.end(reason: .user)
        XCTAssertEqual(fake.sleepDisabled, "0", "the end cleared it")

        let refused = try FakeDialogMachine(in: h.home.root.appendingPathComponent("machine-no-rule", isDirectory: true), clockStart: now, clockAfterRestore: now + 5)
        refused.foreignAfterRootRead = true
        refused.ruleMissing = true
        let m2 = h.makeManager(sleepGuard: refused.sleepGuard())
        await m2.start(duration: 1800)

        XCTAssertNil(m2.session)
        XCTAssertFalse(refused.foreignAfterRootRead, "the other tool's 1 was set")
        XCTAssertEqual(refused.pmsetCalls(), ["-g", "-g", "-a disablesleep 1", "-a disablesleep 0"])
        XCTAssertEqual(refused.sleepDisabled, "0", "root's restore cleared it")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }
}
