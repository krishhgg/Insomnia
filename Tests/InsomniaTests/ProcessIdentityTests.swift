import Darwin
import XCTest
@testable import Insomnia

/// Resume and suspend must act on the process Insomnia froze, not on
/// whatever now owns that pid, and never on a process someone else stopped.
/// Identity is the kernel start time (seconds and microseconds) plus the boot
/// session, recorded in the journal at freeze time.
final class ProcessIdentityTests: XCTestCase {
    typealias Sent = Locked<[(pid: Int32, sig: Int32)]>

    private func control(_ kernel: [Int32: ProcessSignalState], sent: Sent, result: Int32 = 0) -> SignalProcessControl {
        SignalProcessControl(stateLookup: { kernel[$0].map(ProcessLookup.present) ?? .absent }, send: { pid, sig in
            sent.value.append((pid, sig))
            return result
        })
    }

    // MARK: Resume

    // 100: stopped, ours. 101: same identity but running (someone already
    // resumed it). 102: stopped, started later, so the pid was reused.
    // 103: gone. 104: same second and boot, different microseconds.
    // 105: same start time in a different boot session.
    let resumeKernel: [Int32: ProcessSignalState] = [
        100: ProcessSignalState(ppid: 1, stopped: true, startedAt: 1000),
        101: ProcessSignalState(ppid: 1, stopped: false, startedAt: 1000),
        102: ProcessSignalState(ppid: 1, stopped: true, startedAt: 2000),
        104: ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1000, startedAtMicros: 7, bootSession: "boot")),
        105: ProcessSignalState(ppid: 1, stopped: true, identity: ProcessIdentity(startedAt: 1000, startedAtMicros: 0, bootSession: "other-boot")),
    ]

    func testResumeSignalsOnlyStoppedProcessesWithExactlyMatchingIdentity() {
        let sent = Sent([])
        let report = control(resumeKernel, sent: sent).resume([
            FrozenProcess(pid: 100, startedAt: 1000),
            FrozenProcess(pid: 101, startedAt: 1000),
            FrozenProcess(pid: 102, startedAt: 1000),
            FrozenProcess(pid: 103, startedAt: 1000),
            FrozenProcess(pid: 104, startedAt: 1000),
            FrozenProcess(pid: 105, startedAt: 1000),
        ])
        XCTAssertEqual(sent.value.map(\.pid), [100])
        XCTAssertEqual(sent.value.map(\.sig), [SIGCONT])
        XCTAssertEqual(report.resumed, [100])
        XCTAssertEqual(Set(report.gone), [101, 102, 103, 104, 105])
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(report.unverifiable, [])
    }

    func testStoppedEntryWithoutIdentityIsKeptUnverifiableAndNeverSignaled() {
        let sent = Sent([])
        let report = control(resumeKernel, sent: sent).resume([FrozenProcess(pid: 100, startedAt: nil)])
        XCTAssertEqual(sent.value.count, 0, "legacy journal entry signaled an unverified pid")
        XCTAssertEqual(report.unverifiable, [100])
        XCTAssertEqual(report.gone, [])
    }

    /// A legacy entry whose pid is running or gone needs no one's attention.
    func testEntryWithoutIdentityThatIsNotStoppedResolvesAsGone() {
        let sent = Sent([])
        let report = control(resumeKernel, sent: sent).resume([
            FrozenProcess(pid: 101, startedAt: nil),
            FrozenProcess(pid: 103, startedAt: nil),
        ])
        XCTAssertEqual(sent.value.count, 0)
        XCTAssertEqual(report.gone, [101, 103])
        XCTAssertEqual(report.unverifiable, [])
    }

    func testFailedSignalOnVerifiedProcessIsReportedAsFailed() {
        let sent = Sent([])
        let report = control(resumeKernel, sent: sent, result: EPERM).resume([FrozenProcess(pid: 100, startedAt: 1000)])
        XCTAssertEqual(sent.value.map(\.pid), [100])
        XCTAssertEqual(report.failed, [100])
        XCTAssertEqual(report.resumed, [])
    }

    func testProcessThatExitsDuringSignalCountsAsGone() {
        let sent = Sent([])
        let report = control(resumeKernel, sent: sent, result: ESRCH).resume([FrozenProcess(pid: 100, startedAt: 1000)])
        XCTAssertEqual(report.gone, [100])
        XCTAssertEqual(report.failed, [])
    }

    // MARK: Suspend

    // 200: running, ours. 201: already stopped by someone else. 202: pid
    // reused (different start). 203: reparented. 204: gone.
    let suspendKernel: [Int32: ProcessSignalState] = [
        200: ProcessSignalState(ppid: 1, stopped: false, startedAt: 1000),
        201: ProcessSignalState(ppid: 1, stopped: true, startedAt: 1001),
        202: ProcessSignalState(ppid: 1, stopped: false, startedAt: 9999),
        203: ProcessSignalState(ppid: 5, stopped: false, startedAt: 1003),
    ]

    func testSuspendStopsOnlyRunningProcessesThatStillMatch() {
        let sent = Sent([])
        let report = control(suspendKernel, sent: sent).suspend(
            [
                FrozenProcess(pid: 200, startedAt: 1000),
                FrozenProcess(pid: 201, startedAt: 1001),
                FrozenProcess(pid: 202, startedAt: 1002),
                FrozenProcess(pid: 203, startedAt: 1003),
                FrozenProcess(pid: 204, startedAt: 1004),
            ],
            expectedParents: [200: 1, 201: 1, 202: 1, 203: 1, 204: 1]
        )
        XCTAssertEqual(sent.value.map(\.pid), [200])
        XCTAssertEqual(sent.value.map(\.sig), [SIGSTOP])
        XCTAssertEqual(report.suspended, [200])
        XCTAssertEqual(report.skipped, [201, 202, 203, 204])
    }

    /// A process stopped before Insomnia acted is skipped at suspend, so it
    /// never reaches the journal, and resume of what was journaled never
    /// signals it.
    func testAlreadyStoppedProcessIsNeitherOwnedNorLaterResumed() {
        let sent = Sent([])
        // A kernel that reflects our own SIGSTOP, so the round trip is real.
        let kernel = Locked(suspendKernel)
        let c = SignalProcessControl(stateLookup: { kernel.value[$0].map(ProcessLookup.present) ?? .absent }, send: { pid, sig in
            sent.value.append((pid, sig))
            if sig == SIGSTOP, let s = kernel.value[pid] {
                kernel.value[pid] = ProcessSignalState(ppid: s.ppid, stopped: true, identity: s.identity)
            }
            return 0
        })
        let candidates = [FrozenProcess(pid: 200, startedAt: 1000), FrozenProcess(pid: 201, startedAt: 1001)]
        let report = c.suspend(candidates, expectedParents: [200: 1, 201: 1])
        XCTAssertEqual(report.suspended, [200])
        XCTAssertEqual(report.skipped, [201])

        let journaled = candidates.filter { report.suspended.contains($0.pid) }
        XCTAssertEqual(journaled.map(\.pid), [200])
        let resumed = c.resume(journaled)
        XCTAssertEqual(resumed.resumed, [200])
        XCTAssertEqual(sent.value.map { "\($0.pid):\($0.sig)" }, ["200:\(SIGSTOP)", "200:\(SIGCONT)"])
        XCTAssertFalse(sent.value.contains { $0.pid == 201 }, "a process stopped before Insomnia acted was signaled")
    }

    func testSuspendSkipsProcessWithoutIdentity() {
        let sent = Sent([])
        let report = control(suspendKernel, sent: sent).suspend([FrozenProcess(pid: 200, startedAt: nil)], expectedParents: [200: 1])
        XCTAssertEqual(sent.value.count, 0)
        XCTAssertEqual(report.skipped, [200])
    }

    func testSignalFailureAtSuspendIsReportedAsSkipped() {
        let sent = Sent([])
        let report = control(suspendKernel, sent: sent, result: EPERM).suspend([FrozenProcess(pid: 200, startedAt: 1000)], expectedParents: [200: 1])
        XCTAssertEqual(report.suspended, [])
        XCTAssertEqual(report.skipped, [200])
    }

    // MARK: Observation failures and identity gaps

    /// A pid whose state the kernel would not report (EPERM, a transient
    /// error) is unknown, not gone: it stays journaled and is not signaled.
    func testUnreadableStateKeepsTheEntryJournaledAndUnsignaled() {
        let sent = Sent([])
        let c = SignalProcessControl(
            stateLookup: { pid in pid == 106 ? .unreadable(EPERM) : .absent },
            send: { pid, sig in
                sent.value.append((pid, sig))
                return 0
            }
        )
        let report = c.resume([FrozenProcess(pid: 106, startedAt: 1000), FrozenProcess(pid: 107, startedAt: 1000)])
        XCTAssertEqual(sent.value.count, 0)
        XCTAssertEqual(report.unobserved, [106], "an unreadable pid was dropped as gone")
        XCTAssertEqual(report.gone, [107])

        let stop = c.suspend([FrozenProcess(pid: 106, startedAt: 1000)], expectedParents: [106: 1])
        XCTAssertEqual(stop.skipped, [106])
        XCTAssertEqual(sent.value.count, 0, "SIGSTOP sent to a pid whose state could not be read")
    }

    /// A failed boot-session lookup yields an empty id on both sides. Two
    /// empty ids are not a match: nothing is owned or signaled on that basis.
    func testEmptyBootSessionIsNeverOwned() {
        let noBoot = ProcessIdentity(startedAt: 1000, startedAtMicros: 0, bootSession: "")
        let kernel: [Int32: ProcessSignalState] = [
            300: ProcessSignalState(ppid: 1, stopped: false, identity: noBoot),
            301: ProcessSignalState(ppid: 1, stopped: true, identity: noBoot),
        ]
        let sent = Sent([])
        let c = control(kernel, sent: sent)
        let stop = c.suspend([FrozenProcess(pid: 300, identity: noBoot)], expectedParents: [300: 1])
        XCTAssertEqual(stop.skipped, [300], "two empty boot ids matched each other")
        let report = c.resume([FrozenProcess(pid: 301, identity: noBoot)])
        XCTAssertEqual(report.unverifiable, [301])
        XCTAssertEqual(sent.value.count, 0)
    }

    /// Each signal follows its own lookup. Resuming the first pid changes
    /// what the second one is (reused here); that must be seen before the
    /// second signal, not hidden by a snapshot taken for the whole batch.
    func testEachSignalFollowsItsOwnFreshLookup() {
        let sent = Sent([])
        let kernel = Locked(resumeKernel)
        kernel.value[101] = ProcessSignalState(ppid: 1, stopped: true, startedAt: 1000)
        let c = SignalProcessControl(
            stateLookup: { kernel.value[$0].map(ProcessLookup.present) ?? .absent },
            send: { pid, sig in
                sent.value.append((pid, sig))
                if pid == 100 { kernel.value[101] = ProcessSignalState(ppid: 1, stopped: true, startedAt: 5000) }
                return 0
            }
        )
        let report = c.resume([FrozenProcess(pid: 100, startedAt: 1000), FrozenProcess(pid: 101, startedAt: 1000)])
        XCTAssertEqual(sent.value.map(\.pid), [100], "pid 101 was signaled from a stale batch snapshot")
        XCTAssertEqual(report.resumed, [100])
        XCTAssertEqual(report.gone, [101])
    }

    // MARK: Planner

    func testPlannerRecordsIdentityForEveryPidAndLeavesOutStoppedOnes() {
        let processes = [
            ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
            ProcessEntry(pid: 100, ppid: 1, startedAt: 1000),
            ProcessEntry(pid: 101, ppid: 100, startedAt: 1001),
            ProcessEntry(pid: 102, ppid: 100, startedAt: 1002, stopped: true),
        ]
        let apps = [RunningApp(pid: 100, bundleId: "com.example.app", name: "App")]
        let groups = FreezePlanner.groups(bundleIds: ["com.example.app"], apps: apps, processes: processes, config: Config())
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].pids, [100, 101])
        XCTAssertEqual(groups[0].identities, [100: ProcessIdentity(startedAt: 1000), 101: ProcessIdentity(startedAt: 1001)])
        XCTAssertEqual(groups[0].expectedParents, [100: 1, 101: 100])
    }
}
