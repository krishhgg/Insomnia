import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// `Insomnia --resume-frozen`: the one-shot mode backstop.sh uses for the
/// microsecond identity check. The mapping is tested with injected kernel
/// closures; the built binary is run against a child process this test
/// spawns, stops, and kills itself.
final class ResumeFrozenCommandTests: XCTestCase {
    typealias Sent = Locked<[(pid: Int32, sig: Int32)]>

    private func control(_ lookup: @escaping @Sendable (Int32) -> ProcessLookup, sent: Sent, result: Int32 = 0) -> SignalProcessControl {
        SignalProcessControl(stateLookup: lookup, send: { pid, sig in
            sent.value.append((pid, sig))
            return result
        })
    }

    private let line = "4242 1789388423 17 0F0F0F0F-1111-2222-3333-444444444444\n"

    /// Runs the mode with `input` as standard input. The lifetime is
    /// recorded, never armed: an alarm would end the test runner.
    private func run(_ input: String, _ control: SignalProcessControl, arguments: [String] = ["--resume-frozen", "30"]) -> ResumeFrozenCommand.Output? {
        ResumeFrozenCommand.run(arguments, input: { Data(input.utf8) }, control: control, endAfter: { _ in })
    }

    /// Other command lines are not this mode, and standard input is not
    /// read for them.
    func testOtherCommandLinesAreNotThisMode() {
        let sent = Sent([])
        let read = Locked(0)
        let c = control({ _ in .absent }, sent: sent)
        let armed = Locked<[UInt32]>([])
        let input: () -> Data = { read.value += 1; return Data(self.line.utf8) }
        let arm: (UInt32) -> Void = { armed.value.append($0) }
        XCTAssertNil(ResumeFrozenCommand.run([], input: input, control: c, endAfter: arm))
        XCTAssertNil(ResumeFrozenCommand.run(["-NSDocumentRevisionsDebugMode", "YES"], input: input, control: c, endAfter: arm))
        XCTAssertNil(ResumeFrozenCommand.run(["4242", "--resume-frozen", "30"], input: input, control: c, endAfter: arm))
        XCTAssertEqual(read.value, 0)
        XCTAssertEqual(armed.value, [], "the menu bar app must never get a lifetime")
        XCTAssertEqual(sent.value.count, 0)
    }

    /// Bad input answers the single line "usage" with EX_USAGE and never
    /// reaches the kernel, even when an earlier line is well formed. A
    /// missing or malformed lifetime, or any argument after it, is a usage
    /// error before standard input is read.
    func testMalformedInputIsAUsageErrorWithoutALookup() {
        let looked = Locked(0)
        let sent = Sent([])
        let c = control({ _ in looked.value += 1; return .absent }, sent: sent)
        let bad: [String] = [
            "",
            "\n",
            "4242 1789388423 17 boot",
            "4242 1789388423 17\n",
            "4242 1789388423 17 boot extra\n",
            "abc 1789388423 17 boot\n",
            "0 1789388423 17 boot\n",
            "-1 1789388423 17 boot\n",
            "4242 -1 17 boot\n",
            "4242 1789388423 1000000 boot\n",
            "4242 1789388423 -1 boot\n",
            "4242 1789388423 17 \n",
            "4242  1789388423 17 boot\n",
            " 4242 1789388423 17 boot\n",
            "4242 1789388423 17 bo\tot\n",
            "4242 1789388423 17 boot\r\n",
            "4242 1789388423 17 boot\n\n",
            "4242 1789388423 17 boot\n\n4243 1789388423 18 boot\n",
            "4242 1789388423 17 boot\n4243 1789388423 x boot\n",
        ]
        for input in bad {
            XCTAssertEqual(run(input, c), .init(lines: ["usage"], status: 64), input.debugDescription)
        }
        XCTAssertEqual(ResumeFrozenCommand.run(["--resume-frozen", "30"], input: { Data([0x34, 0xFF, 0x0A]) }, control: c, endAfter: { _ in }), .init(lines: ["usage"], status: 64), "not UTF-8")

        let read = Locked(0)
        let armed = Locked<[UInt32]>([])
        let badArguments: [[String]] = [
            ["--resume-frozen"],
            ["--resume-frozen", "30", "4242"],
            ["--resume-frozen", ""],
            ["--resume-frozen", "0"],
            ["--resume-frozen", "301"],
            ["--resume-frozen", "1000"],
            ["--resume-frozen", "+5"],
            ["--resume-frozen", "-1"],
            ["--resume-frozen", " 5"],
            ["--resume-frozen", "5 "],
            ["--resume-frozen", "5s"],
            ["--resume-frozen", "\u{0663}"],
        ]
        for arguments in badArguments {
            let output = ResumeFrozenCommand.run(arguments, input: { read.value += 1; return Data(self.line.utf8) }, control: c, endAfter: { armed.value.append($0) })
            XCTAssertEqual(output, .init(lines: ["usage"], status: 64), arguments.debugDescription)
        }
        XCTAssertEqual(read.value, 0, "standard input read although the arguments were already wrong")
        XCTAssertEqual(armed.value, [], "a lifetime armed from bad arguments")
        XCTAssertEqual(looked.value, 0)
        XCTAssertEqual(sent.value.count, 0)
    }

    /// The lifetime is armed with the caller's number of seconds before
    /// standard input is read, so a process that blocks on its input still
    /// ends on time.
    func testTheLifetimeIsArmedBeforeStandardInputIsRead() {
        let events = Locked<[String]>([])
        let c = control({ _ in .absent }, sent: Sent([]))
        for (argument, seconds) in [("1", UInt32(1)), ("33", 33), ("300", 300), ("007", 7)] {
            events.value = []
            let output = ResumeFrozenCommand.run(
                ["--resume-frozen", argument],
                input: { events.value.append("read"); return Data(self.line.utf8) },
                control: c,
                endAfter: { events.value.append("end after \($0)") }
            )
            XCTAssertEqual(output, .init(lines: ["4242 gone"], status: 0), argument)
            XCTAssertEqual(events.value, ["end after \(seconds)", "read"], argument)
        }
    }

    func testParseBuildsTheExactJournalEntries() {
        XCTAssertEqual(
            ResumeFrozenCommand.parse("4242 1789388423 17 boot\n"),
            [FrozenProcess(pid: 4242, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "boot"))]
        )
        XCTAssertEqual(
            ResumeFrozenCommand.parse("7 0 0 b\n8 1 999999 c\n"),
            [
                FrozenProcess(pid: 7, identity: ProcessIdentity(startedAt: 0, startedAtMicros: 0, bootSession: "b")),
                FrozenProcess(pid: 8, identity: ProcessIdentity(startedAt: 1, startedAtMicros: 999_999, bootSession: "c")),
            ]
        )
        XCTAssertNil(ResumeFrozenCommand.parse(""))
    }

    /// Standard input has no size limit, so a journal far beyond what an
    /// argument list could carry (ARG_MAX) is still one call with one
    /// answer line per entry.
    func testInputBeyondTheArgumentLimitIsAnsweredInOneCall() {
        let boot = "0F0F0F0F-1111-2222-3333-444444444444"
        let count = 40_000
        let input = (1...count).map { "\($0) 1789388423 \($0 % 1_000_000) \(boot)\n" }.joined()
        XCTAssertGreaterThan(input.utf8.count, Int(sysconf(_SC_ARG_MAX)))
        let looked = Locked(0)
        let sent = Sent([])
        let output = run(input, control({ _ in looked.value += 1; return .absent }, sent: sent))
        XCTAssertEqual(output?.status, 0)
        XCTAssertEqual(output?.lines.count, count)
        XCTAssertEqual(output?.lines.first, "1 gone")
        XCTAssertEqual(output?.lines.last, "\(count) gone")
        XCTAssertEqual(looked.value, count)
        XCTAssertEqual(sent.value.count, 0)
    }

    /// A stopped process with exactly the journaled identity: one lookup,
    /// then SIGCONT to that pid, "<pid> resumed", exit 0.
    func testMatchingStoppedProcessIsResumed() {
        let identity = ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "0F0F0F0F-1111-2222-3333-444444444444")
        let looked = Locked<[Int32]>([])
        let sent = Sent([])
        let c = control({ pid in
            looked.value.append(pid)
            return .present(ProcessSignalState(ppid: 1, stopped: true, identity: identity))
        }, sent: sent)
        XCTAssertEqual(run(line, c), .init(lines: ["4242 resumed"], status: 0))
        XCTAssertEqual(looked.value, [4242])
        XCTAssertEqual(sent.value.map(\.pid), [4242])
        XCTAssertEqual(sent.value.map(\.sig), [SIGCONT])
    }

    /// Absent, running, a different microsecond, and a different boot
    /// session all answer "gone" (exit 0) without a signal.
    func testGoneRunningAndMismatchedAnswerGoneWithoutASignal() {
        let boot = "0F0F0F0F-1111-2222-3333-444444444444"
        let cases: [(String, ProcessLookup)] = [
            ("absent", .absent),
            ("running", .present(ProcessSignalState(ppid: 1, stopped: false, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: boot)))),
            ("other micros", .present(ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 18, bootSession: boot)))),
            ("other second", .present(ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1_789_388_424, startedAtMicros: 17, bootSession: boot)))),
            ("other boot", .present(ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "other")))),
        ]
        for (name, lookup) in cases {
            let sent = Sent([])
            XCTAssertEqual(run(line, control({ _ in lookup }, sent: sent)), .init(lines: ["4242 gone"], status: 0), name)
            XCTAssertEqual(sent.value.count, 0, "\(name): signaled")
        }
    }

    func testFailedSignalAndUnreadableKernelKeepTheEntry() {
        let identity = ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "0F0F0F0F-1111-2222-3333-444444444444")
        let sent = Sent([])
        let failing = control({ _ in .present(ProcessSignalState(ppid: 1, stopped: true, identity: identity)) }, sent: sent, result: EPERM)
        XCTAssertEqual(run(line, failing), .init(lines: ["4242 failed"], status: 1))
        XCTAssertEqual(sent.value.map(\.pid), [4242])

        let sent2 = Sent([])
        let unreadable = control({ _ in .unreadable(EACCES) }, sent: sent2)
        XCTAssertEqual(run(line, unreadable), .init(lines: ["4242 unobserved"], status: 1))
        XCTAssertEqual(sent2.value.count, 0)

        // The kernel side has no boot session right now (sysctl failed).
        let sent3 = Sent([])
        let noBoot = control({ _ in .present(ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: ""))) }, sent: sent3)
        XCTAssertEqual(run(line, noBoot), .init(lines: ["4242 unobserved"], status: 1))
        XCTAssertEqual(sent3.value.count, 0)
    }

    /// Several entries in one call: one line each, in input order, and
    /// each entry's lookup comes right before its own signal, never all
    /// lookups first. One unsettled entry makes the exit status 1.
    func testEachEntryIsLookedUpRightBeforeItsOwnSignal() {
        let boot = "0F0F0F0F-1111-2222-3333-444444444444"
        @Sendable func id(_ micros: Int32) -> ProcessIdentity {
            ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: micros, bootSession: boot)
        }
        let events = Locked<[String]>([])
        let lookup: @Sendable (Int32) -> ProcessLookup = { pid in
            events.value.append("look \(pid)")
            switch pid {
            case 11: return .present(ProcessSignalState(ppid: 1, stopped: true, identity: id(1)))
            case 12: return .absent
            case 13: return .present(ProcessSignalState(ppid: 1, stopped: true, identity: id(3)))
            default: return .present(ProcessSignalState(ppid: 1, stopped: true, identity: id(4)))
            }
        }
        let c = SignalProcessControl(stateLookup: lookup, send: { pid, _ in
            events.value.append("send \(pid)")
            return pid == 13 ? EPERM : 0
        })
        let input = "11 1789388423 1 \(boot)\n12 1789388423 2 \(boot)\n13 1789388423 3 \(boot)\n14 1789388423 4 \(boot)\n"
        XCTAssertEqual(run(input, c), .init(lines: ["11 resumed", "12 gone", "13 failed", "14 resumed"], status: 1))
        XCTAssertEqual(events.value, ["look 11", "send 11", "look 12", "look 13", "send 13", "look 14", "send 14"])

        events.value = []
        let settled = "11 1789388423 1 \(boot)\n12 1789388423 2 \(boot)\n"
        XCTAssertEqual(run(settled, c), .init(lines: ["11 resumed", "12 gone"], status: 0))
        XCTAssertEqual(events.value, ["look 11", "send 11", "look 12"])
    }

    func testEveryWordAndWhetherItSettlesTheEntry() {
        typealias A = ResumeFrozenCommand.Answer
        XCTAssertEqual(ResumeFrozenCommand.answer(of: ResumeReport(resumed: [1]), pid: 1), A.resumed)
        XCTAssertEqual(ResumeFrozenCommand.answer(of: ResumeReport(gone: [1]), pid: 1), A.gone)
        XCTAssertEqual(ResumeFrozenCommand.answer(of: ResumeReport(failed: [1]), pid: 1), A.failed)
        XCTAssertEqual(ResumeFrozenCommand.answer(of: ResumeReport(unobserved: [1]), pid: 1), A.unobserved)
        XCTAssertEqual(ResumeFrozenCommand.answer(of: ResumeReport(unverifiable: [1]), pid: 1), A.unverifiable)
        XCTAssertEqual(ResumeFrozenCommand.answer(of: ResumeReport(), pid: 1), A.unverifiable, "an empty report must not read as success")
        XCTAssertEqual([A.resumed, .gone, .failed, .unobserved, .unverifiable].map(\.settled), [true, true, false, false, false])
    }

    // MARK: The built binary

    /// The executable SwiftPM built next to this test bundle.
    private var builtBinary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Insomnia")
    }

    /// Runs the real binary in the mode with `input` as standard input, and
    /// with INSOMNIA_HOME in a temp dir so its log line (if any) never
    /// touches ~/Library. Standard input, output and error are files: nothing
    /// to drain, nothing to deadlock, whatever the size.
    private func runBinary(_ arguments: [String] = ["--resume-frozen", "30"], input: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let home = TempHome()
        defer { home.destroy() }
        let inURL = home.root.appendingPathComponent("stdin")
        let outURL = home.root.appendingPathComponent("stdout")
        let errURL = home.root.appendingPathComponent("stderr")
        try Data(input.utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: inURL)
        let stdout = try FileHandle(forWritingTo: outURL)
        let stderr = try FileHandle(forWritingTo: errURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let p = Process()
        p.executableURL = builtBinary
        p.arguments = arguments
        p.environment = ["INSOMNIA_HOME": home.root.path, "PATH": "/usr/bin:/bin"]
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        let exit = ProcessExit(p)
        try p.run()
        exit.wait()
        return (p.terminationStatus,
                (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    /// The real binary answers before AppKit starts: a usage error exits 64
    /// at once, and a pid that has exited answers "gone" after one kernel
    /// lookup. Neither sends a signal (the pid no longer exists, and the
    /// test's own running pid is never stopped, so it is "gone" too).
    func testBuiltBinaryAnswersWithoutStartingTheAppOrSignaling() throws {
        guard FileManager.default.isExecutableFile(atPath: builtBinary.path) else {
            throw XCTSkip("no built Insomnia executable at \(builtBinary.path)")
        }
        let usage = try runBinary(input: "4242\n")
        XCTAssertEqual(usage.status, 64)
        XCTAssertEqual(usage.stdout, "usage\n")
        XCTAssertTrue(usage.stderr.contains("usage: Insomnia --resume-frozen"), usage.stderr)

        // A child that has already exited: its pid is gone.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let exited = child.processIdentifier
        let boot = SignalProcessControl.bootSession
        let gone = try runBinary(input: "\(exited) 0 0 \(boot)\n")
        XCTAssertEqual(gone.status, 0, gone.stderr)
        XCTAssertEqual(gone.stdout, "\(exited) gone\n")

        // This test process is running, so whatever identity is claimed it
        // is nothing to resume: "gone", and no signal reaches it. Both in
        // one call: one line each, in order.
        let both = try runBinary(input: "\(exited) 0 0 \(boot)\n\(getpid()) 0 0 \(boot)\n")
        XCTAssertEqual(both.status, 0, both.stderr)
        XCTAssertEqual(both.stdout, "\(exited) gone\n\(getpid()) gone\n")

        // More input than an argument list could carry, read whole: one
        // answer line per entry. A start second of 0 matches no process, so
        // nothing can be signaled whatever the pid has become.
        let many = 40_000
        let large = try runBinary(input: String(repeating: "\(exited) 0 0 \(boot)\n", count: many))
        XCTAssertEqual(large.status, 0, large.stderr)
        XCTAssertEqual(large.stdout, String(repeating: "\(exited) gone\n", count: many))
    }

    /// The real binary resumes a stopped process whose identity matches to
    /// the microsecond, and leaves it stopped when the microseconds differ.
    /// The only process signaled is a `/bin/sleep 30` this test spawns: the
    /// test stops it, the binary resumes it, and the test kills and reaps it
    /// in a defer. It is spawned with posix_spawn and reaped only by that
    /// defer, so its pid cannot be reused before the kill.
    func testBuiltBinaryResumesAStoppedChildOfThisTest() throws {
        guard FileManager.default.isExecutableFile(atPath: builtBinary.path) else {
            throw XCTSkip("no built Insomnia executable at \(builtBinary.path)")
        }
        let boot = SignalProcessControl.bootSession
        guard !boot.isEmpty else { throw XCTSkip("kern.bootsessionuuid unreadable") }

        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        let spawned = posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ)
        XCTAssertEqual(spawned, 0, "posix_spawn /bin/sleep")
        guard spawned == 0, pid > 0 else { return }
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }

        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        let stopped = try XCTUnwrap(waitForInfo(pid) { $0.pbi_status == UInt32(SSTOP) }, "child never showed as stopped")
        let started = Int64(stopped.pbi_start_tvsec)
        let micros = Int32(truncatingIfNeeded: stopped.pbi_start_tvusec)
        let otherMicros = (micros + 1) % 1_000_000

        // One microsecond off: not the process, so "gone" and no signal.
        let mismatch = try runBinary(input: "\(pid) \(started) \(otherMicros) \(boot)\n")
        XCTAssertEqual(mismatch.status, 0, mismatch.stderr)
        XCTAssertEqual(mismatch.stdout, "\(pid) gone\n")
        XCTAssertEqual(info(pid)?.pbi_status, UInt32(SSTOP), "a mismatched identity must leave the child stopped")

        // Exact identity, batched after an entry for a pid that has exited.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let answer = try runBinary(input: "\(exited.processIdentifier) 0 0 \(boot)\n\(pid) \(started) \(micros) \(boot)\n")
        XCTAssertEqual(answer.status, 0, answer.stderr)
        XCTAssertEqual(answer.stdout, "\(exited.processIdentifier) gone\n\(pid) resumed\n")
        XCTAssertNotNil(waitForInfo(pid) { $0.pbi_status != UInt32(SSTOP) }, "the binary answered resumed but the child is still stopped")
    }

    /// The built binary ends itself with SIGALRM once its lifetime is up,
    /// here 1 s while it waits for standard input that never ends. That
    /// holds when its parent ignored SIGALRM and when its parent blocked
    /// it, since both survive exec. The test sends no signal: a binary that
    /// did not end gets end of input when the test closes the pipe, exits
    /// 64, and fails the SIGALRM assertion.
    func testBuiltBinaryEndsItselfWhenItsLifetimeIsUp() throws {
        guard FileManager.default.isExecutableFile(atPath: builtBinary.path) else {
            throw XCTSkip("no built Insomnia executable at \(builtBinary.path)")
        }
        for parent in [ParentAlarm.default, .ignored, .blocked] {
            let end = try spawnWithOpenInput(lifetime: "1", parent: parent)
            XCTAssertTrue(end.endedByItself, "\(parent): still running after 15 s")
            XCTAssertEqual(end.status & 0x7f, SIGALRM, "\(parent): wait status \(end.status)")
            XCTAssertGreaterThan(end.seconds, 0.5, "\(parent): ended before its lifetime")
        }
    }

    private enum ParentAlarm { case `default`, ignored, blocked }

    /// Spawns the built binary with `--resume-frozen <lifetime>` and a pipe
    /// on standard input that stays open, and waits up to 15 s for it to
    /// end. `parent` is the SIGALRM state it inherits: the default, ignored
    /// (a bash that runs `trap '' ALRM` and then execs it), or blocked (the
    /// spawn mask). If it is still running then, the pipe is closed and it
    /// is reaped once it exits on end of input.
    private func spawnWithOpenInput(lifetime: String, parent: ParentAlarm) throws -> (status: Int32, seconds: TimeInterval, endedByItself: Bool) {
        let home = TempHome()
        defer { home.destroy() }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw XCTSkip("pipe failed: errno \(errno)") }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        var writeOpen = true
        defer {
            close(readEnd)
            if writeOpen { close(writeEnd) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, readEnd, 0)
        posix_spawn_file_actions_addclose(&actions, readEnd)
        posix_spawn_file_actions_addclose(&actions, writeEnd)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var mask = sigset_t()
        sigemptyset(&mask)
        if parent == .blocked { sigaddset(&mask, SIGALRM) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGALRM)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let binary = builtBinary.path
        let arguments = parent == .ignored
            ? ["/bin/bash", "-c", #"trap '' ALRM; exec "$0" "$@""#, binary, "--resume-frozen", lifetime]
            : [binary, "--resume-frozen", lifetime]
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let environment = ["INSOMNIA_HOME=\(home.root.path)", "PATH=/usr/bin:/bin"]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        // The clock starts before the spawn, so the time measured is never
        // shorter than the binary's own: it cannot arm its alarm before
        // `start`, however late the test gets to run again.
        let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        func elapsed() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1e9 }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, arguments[0], &actions, &attr, argv, envp)
        guard spawned == 0, pid > 0 else { throw XCTSkip("posix_spawn failed: \(spawned)") }
        var status: Int32 = 0
        var endedByItself = false
        while elapsed() < 15 {
            if waitpid(pid, &status, WNOHANG) == pid {
                endedByItself = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let seconds = elapsed()
        if !endedByItself {
            close(writeEnd)
            writeOpen = false
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        }
        return (status, seconds, endedByItself)
    }

    /// The child's BSD info, or nil when the kernel has none for it.
    private func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// Polls the child's BSD info for up to 5 s until `condition` holds.
    private func waitForInfo(_ pid: pid_t, _ condition: (proc_bsdinfo) -> Bool) -> proc_bsdinfo? {
        let deadline = Date(timeIntervalSinceNow: 5)
        repeat {
            if let i = info(pid), condition(i) { return i }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return nil
    }
}
