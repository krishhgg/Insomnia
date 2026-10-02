import Darwin
import Foundation
import XCTest
@testable import Insomnia

/// `Insomnia --resume-frozen`: the one-shot mode backstop.sh uses for the
/// microsecond identity check. The mapping is tested with injected kernel
/// closures; the built binary is run for the answers that send no signal.
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

    /// Bad arguments answer "usage" with EX_USAGE and never reach the kernel.
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
        ]
        for argv in bad {
            XCTAssertEqual(ResumeFrozenCommand.run(argv, control: c), .init(word: "usage", status: 64), "\(argv)")
        }
        XCTAssertEqual(looked.value, 0)
        XCTAssertEqual(sent.value.count, 0)
    }

    func testParseBuildsTheExactJournalEntry() {
        XCTAssertEqual(
            ResumeFrozenCommand.parse(["4242", "1789388423", "17", "boot"]),
            FrozenProcess(pid: 4242, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "boot"))
        )
        XCTAssertEqual(ResumeFrozenCommand.parse(["7", "0", "0", "b"])?.identity, ProcessIdentity(startedAt: 0, startedAtMicros: 0, bootSession: "b"))
    }

    /// A stopped process with exactly the journaled identity: one lookup,
    /// then SIGCONT to that pid, "resumed", exit 0.
    func testMatchingStoppedProcessIsResumed() {
        let identity = ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "0F0F0F0F-1111-2222-3333-444444444444")
        let looked = Locked<[Int32]>([])
        let sent = Sent([])
        let c = control({ pid in
            looked.value.append(pid)
            return .present(ProcessSignalState(ppid: 1, stopped: true, identity: identity))
        }, sent: sent)
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: c), .init(word: "resumed", status: 0))
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
            XCTAssertEqual(ResumeFrozenCommand.run(args, control: control({ _ in lookup }, sent: sent)), .init(word: "gone", status: 0), name)
            XCTAssertEqual(sent.value.count, 0, "\(name): signaled")
        }
    }

    func testFailedSignalAndUnreadableKernelKeepTheEntry() {
        let identity = ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: "0F0F0F0F-1111-2222-3333-444444444444")
        let sent = Sent([])
        let failing = control({ _ in .present(ProcessSignalState(ppid: 1, stopped: true, identity: identity)) }, sent: sent, result: EPERM)
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: failing), .init(word: "failed", status: 1))
        XCTAssertEqual(sent.value.map(\.pid), [4242])

        let sent2 = Sent([])
        let unreadable = control({ _ in .unreadable(EACCES) }, sent: sent2)
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: unreadable), .init(word: "unobserved", status: 1))
        XCTAssertEqual(sent2.value.count, 0)

        // The kernel side has no boot session right now (sysctl failed).
        let sent3 = Sent([])
        let noBoot = control({ _ in .present(ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1_789_388_423, startedAtMicros: 17, bootSession: ""))) }, sent: sent3)
        XCTAssertEqual(ResumeFrozenCommand.run(args, control: noBoot), .init(word: "unobserved", status: 1))
        XCTAssertEqual(sent3.value.count, 0)
    }

    func testEveryWordHasOneDocumentedStatus() {
        XCTAssertEqual(ResumeFrozenCommand.result(of: ResumeReport(resumed: [1]), pid: 1), .init(word: "resumed", status: 0))
        XCTAssertEqual(ResumeFrozenCommand.result(of: ResumeReport(gone: [1]), pid: 1), .init(word: "gone", status: 0))
        XCTAssertEqual(ResumeFrozenCommand.result(of: ResumeReport(failed: [1]), pid: 1), .init(word: "failed", status: 1))
        XCTAssertEqual(ResumeFrozenCommand.result(of: ResumeReport(unobserved: [1]), pid: 1), .init(word: "unobserved", status: 1))
        XCTAssertEqual(ResumeFrozenCommand.result(of: ResumeReport(unverifiable: [1]), pid: 1), .init(word: "unverifiable", status: 1))
        XCTAssertEqual(ResumeFrozenCommand.result(of: ResumeReport(), pid: 1), .init(word: "unverifiable", status: 1), "an empty report must not read as success")
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
        let boot = SignalProcessControl.bootSession
        let gone = try runBinary(["--resume-frozen", String(child.processIdentifier), "0", "0", boot])
        XCTAssertEqual(gone.status, 0, gone.stderr)
        XCTAssertEqual(gone.stdout, "gone\n")

        // This test process is running, so whatever identity is claimed it
        // is nothing to resume: "gone", and no signal reaches it.
        let running = try runBinary(["--resume-frozen", String(getpid()), "0", "0", boot])
        XCTAssertEqual(running.status, 0, running.stderr)
        XCTAssertEqual(running.stdout, "gone\n")
    }
}
