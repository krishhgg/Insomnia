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

    /// The whole script is one literal: lockf on the marker, the root
    /// command with each `"` escaped for AppleScript, the marker path and
    /// nonce taken from argv through `quoted form of`, the privilege flag
    /// and the dialog text.
    func testScriptIsTheExactLiteral() {
        let embedded = AdministratorPrompt.rootCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        XCTAssertEqual(AdministratorPrompt.markerLock, "/usr/bin/lockf -k -n -t 10")
        XCTAssertEqual(AdministratorPrompt.disableSleepScript, """
        on run argv
        do shell script "\(AdministratorPrompt.markerLock) " & quoted form of (item 1 of argv) & " /bin/sh -c " & quoted form of "\(embedded)" & " insomnia " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with administrator privileges with prompt "Insomnia needs your password to turn off system sleep for this session."
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

    /// Only the dialog's own -128 is a cancel. A command that ran and
    /// failed ends osascript's error with its own status, whatever its
    /// message contains (here a marker path with the cancel text in it).
    func testCancelTextInACommandsOutputIsNotACancel() async throws {
        let exe = try fakeOsascript("echo 'execution error: lockf: /x/User canceled. (-128)/pending-start: No such file or directory (69)' >&2; exit 1")
        let prompt = OsascriptAdministratorPrompt(executable: exe, timeout: 5)
        do {
            try await prompt.disableSleep(start)
            XCTFail("must throw")
        } catch let AdministratorPromptError.failed(status, stderr) {
            XCTAssertEqual(status, 1)
            XCTAssertTrue(stderr.hasSuffix("(69)\n"), stderr)
        }
    }

    func testOnlyCancelAndLaunchFailureRanNothing() {
        XCTAssertTrue(AdministratorPromptError.cancelled.nothingRan)
        XCTAssertTrue(AdministratorPromptError.launchFailed("x").nothingRan)
        XCTAssertFalse(AdministratorPromptError.timedOut(seconds: 1).nothingRan)
        XCTAssertFalse(AdministratorPromptError.failed(status: 1, stderr: "").nothingRan)
        XCTAssertFalse(AdministratorPromptError.stillRunning(UnfinishedPrompt(pid: 1, osascriptAlive: false), grace: 1).nothingRan)
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
/// /bin/sh with the dialog's quoting, the real lockf and a fake pmset
/// (RootCommandProcess).
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

    func testTurnsSleepOffWhileTheMarkerHoldsTheNonce() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1"])
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "nonce-1", "lockf -k leaves the file")
    }

    /// Recovery (or the start itself) deleted the marker: lockf -n has
    /// nothing to open, and a late answer runs nothing.
    func testDoesNothingOnceTheMarkerIsGone() throws {
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 69, r.stderr)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "lockf -n never creates the marker")
    }

    /// A dialog left from an older start cannot act for a newer one.
    func testDoesNothingWhenANewerStartOwnsTheMarker() throws {
        try Data("nonce-2".utf8).write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "nonce-1", in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
        XCTAssertTrue(r.stderr.contains("sleep was not turned off"), r.stderr)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "nonce-2", "the newer start's marker is left alone")
    }

    func testAnEmptyNonceNeverMatches() throws {
        try Data().write(to: marker)
        let r = try runRootCommand(marker: marker, nonce: "", in: dir)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.pmsetCalls, [])
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
        XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1"])
        let removed = try await store.removePendingStart(timeout: 5)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The other order: a remover holds the lock when the answer comes.
    /// The command waits for the lock, and by the time it has it the
    /// marker is gone, so nothing runs.
    func testAnAnswerThatWaitsOnARemovalRunsNothing() throws {
        try Data("nonce-1".utf8).write(to: marker)
        let holder = try FileLockHolder(marker)
        let command = try RootCommandProcess(marker: marker, nonce: "nonce-1", in: dir)
        usleep(300_000)
        try FileManager.default.removeItem(at: marker)
        holder.release()
        let r = command.wait()
        XCTAssertEqual(r.status, 3, r.stderr)
        XCTAssertEqual(r.pmsetCalls, [])
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
        XCTAssertEqual(last.body, "No session was started, and nothing was changed: the administrator password prompt was cancelled.")
    }

    /// The README's promise: cancelling leaves sleep as it was, so a
    /// SleepDisabled bit another tool set before the start stays set.
    func testCancelLeavesASleepSettingSomeoneElseOwns() async throws {
        h.prompt.mode = .cancel
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertTrue(h.guardFake.sleepDisabled, "another tool's setting must survive a cancel")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertFalse(markerExists)
        XCTAssertNil(m.session)
    }

    /// osascript never started, so nothing ran as root: the same exact
    /// rollback with no pmset.
    func testLaunchFailureRollsBackWithoutPmset() async throws {
        h.prompt.mode = .launchFail
        h.guardFake.sleepDisabled = true
        let m = h.makeManager()
        await m.start(duration: 1800)

        XCTAssertEqual(h.guardFake.calls, ["disablesleep 1"])
        XCTAssertTrue(h.guardFake.sleepDisabled)
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
        let orphan = PendingStart(marker: h.home.paths.pendingStartFile, nonce: UUID().uuidString)
        try h.store.savePendingStart(orphan.nonce)
        let command = try RootCommandProcess(marker: orphan.marker, nonce: orphan.nonce, in: h.home.root, holdPmset: true)
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
        XCTAssertEqual(r.pmsetCalls, ["-a disablesleep 1"])
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

    /// The stuck prompt's root command is past its check and holds the
    /// marker's lock: the marker stays while it runs, and goes once the
    /// prompt has exited, before the rollback clears the sleep entry.
    func testStuckPromptWhoseCommandHoldsTheMarkerClearsItAfterExit() async throws {
        let box = LockHolderBox()
        h.prompt.onShow = { start in box.hold(start.marker) }
        h.prompt.mode = .stuck
        let m = h.makeManager()

        let start = Task { await m.start(duration: 1800) }
        try await waitUntil("the stuck prompt is reported") {
            h.notifier.posts.contains { $0.title == "Password prompt still running" }
        }
        XCTAssertTrue(markerExists, "the command holding its lock keeps it")
        XCTAssertNotNil(m.markerProblem)
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true)

        let handle = try XCTUnwrap(h.prompt.unfinished)
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
