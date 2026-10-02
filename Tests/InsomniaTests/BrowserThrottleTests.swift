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
    /// relaunch task. The wait must end at once rather than spin until the
    /// deadline, and the outcome is not a failure to report.
    @MainActor
    func testACancelledStartWaitEndsAtOnceAndIsNotAFailure() async throws {
        let processes = FakeBrowserProcesses(pids: [42])
        processes.startWait = .pollsUntilCancelled
        let throttle = throttle(args: chrome, processes: processes)

        let relaunch = Task { await throttle.relaunchUnthrottled(bundleId: "com.google.Chrome") }
        try await processes.waitForStartWait()
        let cancelledAt = ContinuousClock.now
        relaunch.cancel()
        let outcome = await relaunch.value

        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(1))
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(processes.launches.count, 1)
    }

    /// The loop itself: once its task is cancelled it checks at most once
    /// more and throws, where ignoring the sleep's error kept it checking
    /// as fast as it could until the deadline.
    @MainActor
    func testThePollStopsCheckingWhenItsTaskIsCancelled() async {
        let checks = Locked(0)
        let poll = Task { @MainActor in
            try await WorkspaceBrowserProcesses.poll(timeout: 3, every: .milliseconds(20)) {
                checks.value += 1
                return false
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let checksAtCancel = checks.value
        poll.cancel()
        let result = await poll.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThanOrEqual(checks.value, checksAtCancel + 1)
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

/// Records what the relaunch asked for and answers from scripted state;
/// nothing real is quit or launched.
@MainActor
final class FakeBrowserProcesses: BrowserProcessControlling {
    /// Pids reported before the quit.
    var pids: [Int32]
    /// Whether the wait reports every instance gone.
    var quits = true
    /// Pids reported after the wait. Default: none when `quits`, else `pids`.
    var pidsAfterQuit: [Int32]?
    /// Makes `launch` throw with this detail.
    var launchFailure: String?
    enum StartWait {
        /// An instance is running as soon as the wait begins.
        case appears
        /// The wait reports that none appeared.
        case neverAppears
        /// The app's own poll loop runs against a list that stays empty,
        /// so the wait lasts until its task is cancelled.
        case pollsUntilCancelled
    }

    /// What the wait after `launch` sees.
    var startWait = StartWait.appears
    private(set) var terminated: [[Int32]] = []
    private(set) var launches: [(bundleId: String, arguments: [String])] = []
    private(set) var startWaits: [String] = []

    init(pids: [Int32]) {
        self.pids = pids
    }

    func runningPids(bundleId: String) -> [Int32] {
        guard !terminated.isEmpty else { return pids }
        return pidsAfterQuit ?? (quits ? [] : pids)
    }

    func terminateAndWait(pids: [Int32], timeout: TimeInterval) async -> Bool {
        terminated.append(pids)
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
        case .pollsUntilCancelled: return try await WorkspaceBrowserProcesses.poll(timeout: 3) { false }
        }
    }

    /// Yield until the relaunch under test is inside the start wait.
    func waitForStartWait() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while startWaits.isEmpty {
            guard ContinuousClock.now < deadline else {
                XCTFail("the relaunch never reached the start wait")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
