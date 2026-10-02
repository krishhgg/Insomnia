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

    private let args = ["--resume-frozen", "4242", "1789388423", "17", "0F0F0F0F-1111-2222-3333-444444444444"]

    func testOtherCommandLinesAreNotThisMode() {
        let sent = Sent([])
        let c = control({ _ in .absent }, sent: sent)
        XCTAssertNil(ResumeFrozenCommand.run([], control: c))
        XCTAssertNil(ResumeFrozenCommand.run(["-NSDocumentRevisionsDebugMode", "YES"], control: c))
        XCTAssertNil(ResumeFrozenCommand.run(["4242", "--resume-frozen"], control: c))
        XCTAssertEqual(sent.value.count, 0)
    }

    /// Bad arguments answer the single line "usage" with EX_USAGE and never
    /// reach the kernel, even when an earlier group is well formed.
    func testMalformedArgumentsAreUsageErrorsWithoutALookup() {
        let looked = Locked(0)
        let sent = Sent([])
        let c = control({ _ in looked.value += 1; return .absent }, sent: sent)
        let bad: [[String]] = [
            ["--resume-frozen"],
            ["--resume-frozen", "4242", "1789388423", "17"],
            ["--resume-frozen", "4242", "1789388423", "17", "boot", "extra"],
            ["--resume-frozen", "abc", "1789388423", "17", "boot"],
            ["--resume-frozen", "0", "1789388423", "17", "boot"],
            ["--resume-frozen", "-1", "1789388423", "17", "boot"],
            ["--resume-frozen", "4242", "-1", "17", "boot"],
            ["--resume-frozen", "4242", "1789388423", "1000000", "boot"],
            ["--resume-frozen", "4242", "1789388423", "-1", "boot"],
            ["--resume-frozen", "4242", "1789388423", "17", ""],
            ["--resume-frozen", "4242", "1789388423", "17", "boot", "4243", "1789388423", "x", "boot"],
        ]
        for argv in bad {
            XCTAssertEqual(ResumeFrozenCommand.run(argv, control: c), .init(lines: ["usage"], status: 64), "\(argv)")
        }
        XCTAssertEqual(looked.value, 0)
        XCTAssertEqual(sent.value.count, 0)
    }

    func testParseBuildsTheExactJournalEntries() {
        XCTAssertEqual(
            ResumeFrozenCommand.parse(["4242", "1789388423", "17", "boot"]),
            [FrozenProcess(pid: 4242, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "boot"))]
        )
        XCTAssertEqual(
            ResumeFrozenCommand.parse(["7", "0", "0", "b", "8", "1", "999999", "c"]),
            [
                FrozenProcess(pid: 7, identity: ProcessIdentity(startedAt: 0, startedAtMicros: 0, bootSession: "b")),
                FrozenProcess(pid: 8, identity: ProcessIdentity(startedAt: 1, startedAtMicros: 999_999, bootSession: "c")),
            ]
        )
        XCTAssertNil(ResumeFrozenCommand.parse([]))
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
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: c), .init(lines: ["4242 resumed"], status: 0))
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
            XCTAssertEqual(ResumeFrozenCommand.run(args, control: control({ _ in lookup }, sent: sent)), .init(lines: ["4242 gone"], status: 0), name)
            XCTAssertEqual(sent.value.count, 0, "\(name): signaled")
        }
    }

    func testFailedSignalAndUnreadableKernelKeepTheEntry() {
        let identity = ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "0F0F0F0F-1111-2222-3333-444444444444")
        let sent = Sent([])
        let failing = control({ _ in .present(ProcessSignalState(ppid: 1, stopped: true, identity: identity)) }, sent: sent, result: EPERM)
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: failing), .init(lines: ["4242 failed"], status: 1))
        XCTAssertEqual(sent.value.map(\.pid), [4242])

        let sent2 = Sent([])
        let unreadable = control({ _ in .unreadable(EACCES) }, sent: sent2)
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: unreadable), .init(lines: ["4242 unobserved"], status: 1))
        XCTAssertEqual(sent2.value.count, 0)

        // The kernel side has no boot session right now (sysctl failed).
        let sent3 = Sent([])
        let noBoot = control({ _ in .present(ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: ""))) }, sent: sent3)
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: noBoot), .init(lines: ["4242 unobserved"], status: 1))
        XCTAssertEqual(sent3.value.count, 0)
    }

    /// Several entries in one call: one line each, in argument order, and
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
        let argv = ["--resume-frozen"]
            + ["11", "1789388423", "1", boot]
            + ["12", "1789388423", "2", boot]
            + ["13", "1789388423", "3", boot]
            + ["14", "1789388423", "4", boot]
        XCTAssertEqual(ResumeFrozenCommand.run(argv, control: c), .init(lines: ["11 resumed", "12 gone", "13 failed", "14 resumed"], status: 1))
        XCTAssertEqual(events.value, ["look 11", "send 11", "look 12", "look 13", "send 13", "look 14", "send 14"])

        events.value = []
        let settled = ["--resume-frozen"] + ["11", "1789388423", "1", boot] + ["12", "1789388423", "2", boot]
        XCTAssertEqual(ResumeFrozenCommand.run(settled, control: c), .init(lines: ["11 resumed", "12 gone"], status: 0))
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

    /// Runs the real binary in the mode, with INSOMNIA_HOME in a temp dir so
    /// its log line (if any) never touches ~/Library.
    private func runBinary(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let home = TempHome()
        defer { home.destroy() }
        let p = Process()
        p.executableURL = builtBinary
        p.arguments = arguments
        p.environment = ["INSOMNIA_HOME": home.root.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, stdout, stderr)
    }

    /// The real binary answers before AppKit starts: a usage error exits 64
    /// at once, and a pid that has exited answers "gone" after one kernel
    /// lookup. Neither sends a signal (the pid no longer exists, and the
    /// test's own running pid is never stopped, so it is "gone" too).
    func testBuiltBinaryAnswersWithoutStartingTheAppOrSignaling() throws {
        guard FileManager.default.isExecutableFile(atPath: builtBinary.path) else {
            throw XCTSkip("no built Insomnia executable at \(builtBinary.path)")
        }
        let usage = try runBinary(["--resume-frozen", "4242"])
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
        let gone = try runBinary(["--resume-frozen", String(exited), "0", "0", boot])
        XCTAssertEqual(gone.status, 0, gone.stderr)
        XCTAssertEqual(gone.stdout, "\(exited) gone\n")

        // This test process is running, so whatever identity is claimed it
        // is nothing to resume: "gone", and no signal reaches it. Both in
        // one call: one line each, in order.
        let both = try runBinary(["--resume-frozen", String(exited), "0", "0", boot, String(getpid()), "0", "0", boot])
        XCTAssertEqual(both.status, 0, both.stderr)
        XCTAssertEqual(both.stdout, "\(exited) gone\n\(getpid()) gone\n")
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
        let mismatch = try runBinary(["--resume-frozen", String(pid), String(started), String(otherMicros), boot])
        XCTAssertEqual(mismatch.status, 0, mismatch.stderr)
        XCTAssertEqual(mismatch.stdout, "\(pid) gone\n")
        XCTAssertEqual(info(pid)?.pbi_status, UInt32(SSTOP), "a mismatched identity must leave the child stopped")

        // Exact identity, batched after an entry for a pid that has exited.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let answer = try runBinary([
            "--resume-frozen",
            String(exited.processIdentifier), "0", "0", boot,
            String(pid), String(started), String(micros), boot,
        ])
        XCTAssertEqual(answer.status, 0, answer.stderr)
        XCTAssertEqual(answer.stdout, "\(exited.processIdentifier) gone\n\(pid) resumed\n")
        XCTAssertNotNil(waitForInfo(pid) { $0.pbi_status != UInt32(SSTOP) }, "the binary answered resumed but the child is still stopped")
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
