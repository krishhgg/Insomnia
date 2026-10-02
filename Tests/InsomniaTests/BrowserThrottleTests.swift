import AppKit
import XCTest
@testable import Insomnia

final class BrowserThrottleTests: XCTestCase {
    let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    func testBothFlagsPresent() {
        XCTAssertTrue(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-backgrounding-occluded-windows --disable-renderer-backgrounding"))
        XCTAssertTrue(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-renderer-backgrounding --foo=bar --disable-backgrounding-occluded-windows\n"))
    }

    func testOneFlagIsNotEnough() {
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-backgrounding-occluded-windows"))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-renderer-backgrounding"))
    }

    func testNoFlags() {
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: chrome))
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: ""))
    }

    func testFlagsInsideQuotedArgDoNotCount() {
        let args = "\(chrome) --user-data-dir=\"/tmp/--disable-backgrounding-occluded-windows --disable-renderer-backgrounding\""
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: args))
        let single = "\(chrome) --note='--disable-backgrounding-occluded-windows --disable-renderer-backgrounding'"
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: single))
    }

    func testFlagsNextToQuotedArgStillCount() {
        let args = "\(chrome) --user-data-dir=\"/Users/me/My Profile\" --disable-backgrounding-occluded-windows --disable-renderer-backgrounding"
        XCTAssertTrue(ChromiumFlags.hasBothFlags(args: args))
    }

    func testPrefixLookalikesDoNotCount() {
        XCTAssertFalse(ChromiumFlags.hasBothFlags(args: "\(chrome) --disable-backgrounding-occluded-windows-x --disable-renderer-backgrounding"))
    }

    func testTokenizer() {
        XCTAssertEqual(ChromiumFlags.tokenize("a  b\t'c d' \"e f\" g\\ h"), ["a", "b", "c d", "e f", "g h"])
        XCTAssertEqual(ChromiumFlags.tokenize(""), [])
    }

    func testPreservedArgs() {
        let args = "\(chrome) --user-data-dir=/tmp/p --profile-directory=\"Profile 2\" --no-first-run"
        XCTAssertEqual(ChromiumFlags.preservedArgs(args: args), ["--user-data-dir=/tmp/p", "--profile-directory=Profile 2"])
    }

    func testChromiumBundleIdsFromAgentList() {
        var c = Config()
        c.agentList = ["com.example.chromeagent", "dev.some.Chromium-Fork", "com.apple.Safari"]
        let ids = ChromiumFlags.chromiumBundleIds(config: c)
        XCTAssertTrue(ids.contains("com.google.Chrome"))
        XCTAssertTrue(ids.contains("org.chromium.Chromium"))
        XCTAssertTrue(ids.contains("company.thebrowser.Browser"))
        XCTAssertTrue(ids.contains("com.example.chromeagent"))
        XCTAssertTrue(ids.contains("dev.some.Chromium-Fork"))
        XCTAssertFalse(ids.contains("com.apple.Safari"))
    }

    // MARK: Relaunch

    @MainActor
    private func throttle(args: String, processes: FakeBrowserProcesses) -> BrowserThrottle {
        BrowserThrottle(readArgs: { _ in args }, processes: processes)
    }

    /// The happy path: every instance is asked to quit, the wait ends with
    /// none running, and `open` gets both flags plus the profile arguments.
    @MainActor
    func testRelaunchQuitsWaitsThenLaunchesWithTheFlagsAndTheProfile() async {
        let processes = FakeBrowserProcesses(pids: [42, 43])
        let throttle = throttle(args: "\(chrome) --user-data-dir=/tmp/p --profile-directory=Work --no-first-run", processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .relaunched)
        XCTAssertEqual(processes.terminated, [[42, 43]])
        XCTAssertEqual(processes.launches.map(\.bundleId), ["com.google.Chrome"])
        XCTAssertEqual(processes.startWaits, ["com.google.Chrome"])
        XCTAssertEqual(
            processes.launches.first?.arguments,
            ChromiumFlags.required + ["--user-data-dir=/tmp/p", "--profile-directory=Work"]
        )
    }

    /// The finding: a browser still running when the wait ends must not be
    /// launched again, or a second copy opens beside the first.
    @MainActor
    func testAStillRunningBrowserIsNotLaunchedAgain() async {
        let processes = FakeBrowserProcesses(pids: [42])
        processes.quits = false
        let throttle = throttle(args: chrome, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertEqual(processes.terminated, [[42]])
        XCTAssertEqual(processes.launches.count, 0)
    }

    /// The waiter's verdict is not enough on its own: the running list is
    /// read again after the wait, and an instance there blocks the launch.
    @MainActor
    func testAnInstanceSeenAfterTheWaitAlsoBlocksTheLaunch() async {
        let processes = FakeBrowserProcesses(pids: [42])
        processes.pidsAfterQuit = [77]
        let throttle = throttle(args: chrome, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertEqual(processes.launches.count, 0)
    }

    /// Unreadable arguments stop the relaunch before anything is quit; a
    /// relaunch without them could open another profile. Empty `ps` output
    /// counts as unreadable.
    @MainActor
    func testUnreadableArgumentsStopBeforeAnythingIsQuit() async {
        let failing = FakeBrowserProcesses(pids: [42])
        let throttle = BrowserThrottle(readArgs: { _ in throw BrowserProcessError(detail: "ps timed out") }, processes: failing)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .argumentsUnreadable("ps timed out"))
        XCTAssertEqual(failing.terminated.count, 0)
        XCTAssertEqual(failing.launches.count, 0)

        let empty = FakeBrowserProcesses(pids: [42])
        let outcomeOfEmpty = await self.throttle(args: " \n", processes: empty).relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcomeOfEmpty, .argumentsUnreadable("ps printed nothing for pid 42"))
        XCTAssertEqual(empty.terminated.count, 0)
        XCTAssertEqual(empty.launches.count, 0)
    }

    @MainActor
    func testNothingHappensWhenTheBrowserIsNotRunning() async {
        let processes = FakeBrowserProcesses(pids: [])
        let throttle = throttle(args: chrome, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .notRunning)
        XCTAssertEqual(processes.terminated.count, 0)
        XCTAssertEqual(processes.launches.count, 0)
    }

    /// `open` failing after the quit is the one outcome that leaves the
    /// browser down, and it says so.
    @MainActor
    func testAFailedOpenIsReportedAfterTheQuit() async {
        let processes = FakeBrowserProcesses(pids: [42])
        processes.launchFailure = "LSOpenURLsWithRole() failed with error -10810"
        let throttle = throttle(args: chrome, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .launchFailed("LSOpenURLsWithRole() failed with error -10810"))
        XCTAssertEqual(processes.terminated, [[42]])
        XCTAssertEqual(processes.launches.count, 1)
        XCTAssertEqual(processes.startWaits, [])
    }

    /// `open` returning 0 only means LaunchServices accepted the request.
    /// A browser that is not in the running list afterwards is reported,
    /// not announced as relaunched.
    @MainActor
    func testABrowserThatDoesNotShowUpAfterOpenIsReported() async {
        let processes = FakeBrowserProcesses(pids: [42])
        processes.startWait = .neverAppears
        let throttle = throttle(args: chrome, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .didNotStart)
        XCTAssertEqual(processes.terminated, [[42]])
        XCTAssertEqual(processes.launches.count, 1)
        XCTAssertEqual(processes.startWaits, ["com.google.Chrome"])
    }

    /// The finding: a session that ends during the start wait cancels the
    /// relaunch task. The wait must end at once rather than keep checking,
    /// and the outcome is not a failure to report. The test waits for the
    /// relaunch to be inside the wait, not for a time; the wait's own
    /// sleeps last until cancelled, so no deadline can end it instead.
    @MainActor
    func testACancelledStartWaitEndsAtOnceAndIsNotAFailure() async {
        let processes = FakeBrowserProcesses(pids: [42])
        processes.startWait = .pollsUntilCancelled
        let throttle = throttle(args: chrome, processes: processes)

        let relaunch = Task { await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome") }
        await fulfillment(of: [processes.insideStartWait], timeout: 60)
        let checksAtCancel = processes.startChecks
        relaunch.cancel()
        let outcome = await relaunch.value

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThanOrEqual(processes.startChecks, checksAtCancel + 1, "the wait kept checking after the cancel")
        XCTAssertEqual(processes.launches.count, 1)
    }

    /// The loop itself: once its task is cancelled it checks at most once
    /// more and throws, where ignoring the sleep's error kept it checking
    /// as fast as it could. The sleep is the test's: it reports that the
    /// loop is asleep and then lasts until the task is cancelled.
    @MainActor
    func testThePollStopsCheckingWhenItsTaskIsCancelled() async {
        let checks = Locked(0)
        let asleep = expectation(description: "the poll is asleep")
        asleep.assertForOverFulfill = false
        let poll = Task { @MainActor in
            try await WorkspaceBrowserProcesses.poll(timeout: 60, every: .milliseconds(20), sleep: { _ in
                asleep.fulfill()
                try await Task.sleep(for: .seconds(3600))
            }) {
                checks.value += 1
                return false
            }
        }
        await fulfillment(of: [asleep], timeout: 60)
        let checksAtCancel = checks.value
        poll.cancel()
        let result = await poll.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThanOrEqual(checks.value, checksAtCancel + 1)
    }

    /// Without a cancel the poll gives up after `timeout` worth of sleeps,
    /// and stops as soon as the condition holds; no clock is read.
    @MainActor
    func testThePollCountsItsSleeps() async throws {
        let slept = Locked<[Duration]>([])
        let gaveUp = try await WorkspaceBrowserProcesses.poll(timeout: 1, every: .milliseconds(250), sleep: { slept.value.append($0) }) { false }
        XCTAssertFalse(gaveUp)
        XCTAssertEqual(slept.value, Array(repeating: .milliseconds(250), count: 4))

        let checks = Locked(0)
        let found = try await WorkspaceBrowserProcesses.poll(timeout: 1, sleep: { _ in }) {
            checks.value += 1
            return checks.value == 3
        }
        XCTAssertTrue(found)
        XCTAssertEqual(checks.value, 3)
    }

    /// The main process exits while its arguments are read and another app
    /// gets its pid. `ps` may have read that app's arguments, so nothing is
    /// quit, and the app now holding the pid is left alone.
    @MainActor
    func testAMainProcessThatExitsDuringTheReadStopsTheRelaunch() async {
        let processes = FakeBrowserProcesses(pids: [42])
        let throttle = BrowserThrottle(readArgs: { _ in
            await MainActor.run {
                processes.exit(pid: 42)
                processes.start(bundleId: "com.apple.finder", pid: 42)
            }
            return "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        }, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .argumentsUnreadable("pid 42 exited while they were read, or could not be checked"))
        XCTAssertEqual(processes.terminated, [])
        XCTAssertEqual(processes.launches.count, 0)
        XCTAssertEqual(processes.processes.filter { $0.bundleId == "com.apple.finder" }.map(\.running), [true])
    }

    /// A main process whose start time could not be read cannot be tied to
    /// what `ps` prints for its pid, so its arguments are not read at all
    /// and nothing is quit; the user is told, as for any unreadable read.
    @MainActor
    func testAMainProcessWithoutAStartTimeIsNotReadOrQuit() async {
        let processes = FakeBrowserProcesses(pids: [42])
        processes.processes[0].identity = nil
        let reads = Locked(0)
        let throttle = BrowserThrottle(readArgs: { [chrome] _ in
            reads.value += 1
            return chrome
        }, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .argumentsUnreadable("the start time of pid 42 could not be read to check them"))
        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(processes.terminated, [])
        XCTAssertEqual(processes.launches.count, 0)
        XCTAssertEqual(
            outcome.explanation(browser: "Chrome"),
            "Could not read Chrome's profile arguments (the start time of pid 42 could not be read to check them), so a relaunch could have opened the wrong profile. Chrome was not quit."
        )
    }

    /// The app's check, on whichever app the workspace lists first with a
    /// readable start time: confirmed only with a start time recorded and
    /// still matching. Read-only; nothing is signalled, quit or launched.
    @MainActor
    func testTheWorkspaceCheckFailsClosedWithoutAStartTime() throws {
        let found = NSWorkspace.shared.runningApplications.lazy.compactMap { app -> (NSRunningApplication, ProcessIdentity)? in
            guard !app.isTerminated, case let .present(state) = SignalProcessControl.kernelState(pid: app.processIdentifier) else { return nil }
            return (app, state.identity)
        }.first
        guard let (app, identity) = found else { throw XCTSkip("no running app with a readable start time") }
        let workspace = WorkspaceBrowserProcesses()
        let pid = app.processIdentifier
        let other = ProcessIdentity(startedAt: identity.startedAt - 1, startedAtMicros: 0, bootSession: identity.bootSession)

        XCTAssertTrue(workspace.isRunning(BrowserInstance(pid: pid, process: app, identity: identity)))
        XCTAssertFalse(workspace.isRunning(BrowserInstance(pid: pid, process: app, identity: nil)), "no start time recorded")
        XCTAssertFalse(workspace.isRunning(BrowserInstance(pid: pid, process: app, identity: other)), "another process's start time")
    }

    /// Another instance exits during the read and its pid goes to another
    /// app. The quit goes to the instances the list returned, so that app
    /// is not asked to quit.
    @MainActor
    func testTheQuitGoesToTheInstancesFoundNotToTheirPids() async {
        let processes = FakeBrowserProcesses(pids: [42, 43])
        let found = processes.processes
        let throttle = BrowserThrottle(readArgs: { [chrome] _ in
            await MainActor.run {
                processes.exit(pid: 43)
                processes.start(bundleId: "com.apple.finder", pid: 43)
            }
            return chrome
        }, processes: processes)

        let outcome = await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome")

        XCTAssertEqual(outcome, .relaunched)
        XCTAssertEqual(processes.quitRequests.count, 1)
        XCTAssertTrue(zip(processes.quitRequests.first ?? [], found).allSatisfy { $0 === $1 }, "the quit went to other objects")
        XCTAssertEqual(processes.processes.filter { $0.bundleId == "com.apple.finder" }.map(\.running), [true], "the app that took pid 43 was quit")
    }

    /// Every outcome short of a relaunch has a notification body naming the
    /// browser and saying what was and was not done.
    func testOutcomeMessagesNameTheBrowser() {
        XCTAssertNil(RelaunchOutcome.relaunched.explanation(browser: "Chrome"))
        XCTAssertNil(RelaunchOutcome.cancelled.explanation(browser: "Chrome"))
        XCTAssertEqual(
            RelaunchOutcome.stillRunning.explanation(browser: "Chrome"),
            "Chrome did not quit within 10 s, so nothing was relaunched. It may still quit later. If it does, open it again yourself."
        )
        XCTAssertEqual(
            RelaunchOutcome.notRunning.explanation(browser: "Arc"),
            "Arc is not running. Nothing was quit or relaunched."
        )
        XCTAssertEqual(
            RelaunchOutcome.argumentsUnreadable("ps timed out").explanation(browser: "Arc"),
            "Could not read Arc's profile arguments (ps timed out), so a relaunch could have opened the wrong profile. Arc was not quit."
        )
        XCTAssertEqual(
            RelaunchOutcome.launchFailed("open exited with status 1").explanation(browser: "Chromium"),
            "Chromium quit but could not be relaunched: open exited with status 1. Open it yourself."
        )
        XCTAssertEqual(
            RelaunchOutcome.didNotStart.explanation(browser: "Chromium"),
            "Chromium quit and was asked to open again, but it was not running after 5 s. Open it yourself."
        )
    }
}

/// A running list of fake processes; records what the relaunch asked for.
/// Nothing real is quit or launched.
@MainActor
final class FakeBrowserProcesses: BrowserProcessControlling {
    /// One process. The object is its identity: a later process given the
    /// same pid is another object.
    final class Process {
        let bundleId: String
        let pid: Int32
        fileprivate(set) var running = true
        /// What the list reports as the kernel start time; nil plays an
        /// unreadable one.
        var identity: ProcessIdentity?

        init(bundleId: String, pid: Int32, startedAt: Int64) {
            self.bundleId = bundleId
            self.pid = pid
            identity = ProcessIdentity(startedAt: startedAt, startedAtMicros: 0, bootSession: "fake")
        }
    }

    /// Every process the fake has known, running or not.
    private(set) var processes: [Process]
    /// Whether a quit request makes the instances exit.
    var quits = true
    /// Pids of new instances that appear during the quit wait.
    var pidsAfterQuit: [Int32]?
    /// Makes `launch` throw with this detail.
    var launchFailure: String?
    /// Runs during the quit wait, before it ends.
    var duringQuit: (@MainActor () -> Void)?
    enum StartWait {
        /// An instance is running as soon as the wait begins.
        case appears
        /// The wait reports that none appeared.
        case neverAppears
        /// The app's own poll loop runs against a list that stays empty,
        /// with sleeps that last until the task is cancelled, so only a
        /// cancel ends the wait. `insideStartWait` is fulfilled at the
        /// first sleep.
        case pollsUntilCancelled
    }

    /// What the wait after `launch` sees.
    var startWait = StartWait.appears
    /// Pids of each quit request, in order.
    var terminated: [[Int32]] { quitRequests.map { $0.map(\.pid) } }
    private(set) var quitRequests: [[Process]] = []
    private(set) var launches: [(bundleId: String, arguments: [String])] = []
    private(set) var startWaits: [String] = []
    /// How often the `.pollsUntilCancelled` wait has checked the list.
    private(set) var startChecks = 0
    let insideStartWait: XCTestExpectation = {
        let e = XCTestExpectation(description: "the relaunch is inside the start wait")
        e.assertForOverFulfill = false
        return e
    }()

    init(pids: [Int32], bundleId: String = "com.google.Chrome") {
        processes = pids.enumerated().map { Process(bundleId: bundleId, pid: $1, startedAt: Int64($0)) }
    }

    @discardableResult
    func start(bundleId: String = "com.google.Chrome", pid: Int32) -> Process {
        let process = Process(bundleId: bundleId, pid: pid, startedAt: Int64(processes.count))
        processes.append(process)
        return process
    }

    func exit(pid: Int32) {
        for process in processes where process.pid == pid { process.running = false }
    }

    func runningInstances(bundleId: String) -> [BrowserInstance] {
        processes.filter { $0.bundleId == bundleId && $0.running }
            .map { BrowserInstance(pid: $0.pid, process: $0, identity: $0.identity) }
    }

    /// Fails closed like the app's: no start time, no confirmation.
    func isRunning(_ instance: BrowserInstance) -> Bool {
        guard let process = instance.process as? Process, instance.identity != nil else { return false }
        return process.running && process.identity == instance.identity
    }

    func terminateAndWait(_ instances: [BrowserInstance], timeout: TimeInterval) async -> Bool {
        let asked = instances.compactMap { $0.process as? Process }
        quitRequests.append(asked)
        if quits { asked.forEach { $0.running = false } }
        for pid in pidsAfterQuit ?? [] { start(pid: pid) }
        duringQuit?()
        return quits
    }

    func launch(bundleId: String, arguments: [String]) async throws {
        launches.append((bundleId, arguments))
        if let launchFailure { throw BrowserProcessError(detail: launchFailure) }
    }

    func waitUntilRunning(bundleId: String, timeout: TimeInterval) async throws -> Bool {
        startWaits.append(bundleId)
        switch startWait {
        case .appears: return true
        case .neverAppears: return false
        case .pollsUntilCancelled:
            return try await WorkspaceBrowserProcesses.poll(timeout: 3600, sleep: { [insideStartWait] _ in
                insideStartWait.fulfill()
                try await Task.sleep(for: .seconds(3600))
            }) {
                startChecks += 1
                return false
            }
        }
    }
}
