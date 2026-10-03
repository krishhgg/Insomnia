import Foundation
import XCTest
@testable import Insomnia

/// A second Insomnia (`open -n`, or the binary run directly) cannot take the
/// alive lock. It must not reconcile, start the app or touch power state:
/// backstop.sh sees only the other copy's lock, so a session this copy
/// owned would outlive its crash. It says why and quits.
@MainActor
final class LaunchGateTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    /// An expired session over a dirty journal, which any reconcile
    /// restores. Returns the journal's bytes.
    private func leaveAnExpiredSession() throws -> Data {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true
        return try Data(contentsOf: h.home.paths.stateFile)
    }

    private func gate(_ lock: AppAliveLock, timeout: TimeInterval = 0.3) -> LaunchGate {
        LaunchGate(aliveLock: lock, notifier: h.notifier, timeout: timeout)
    }

    func testACopyWithoutTheAliveLockNeitherStartsNorReconciles() async throws {
        let journal = try leaveAnExpiredSession()
        let other = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try other.tryAcquire())
        defer { other.release() }
        let mine = AppAliveLock(url: h.home.paths.appAliveFile)
        var started = false

        let opened = await gate(mine).open(manager: h.makeManager(), start: { started = true })

        XCTAssertFalse(opened)
        XCTAssertFalse(started, "no menu, no settings window, no login item check")
        XCTAssertFalse(mine.isHeld)
        XCTAssertEqual(h.guardFake.calls, [], "power state untouched")
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), journal)
        XCTAssertNotNil(try h.store.loadSession())
        let posts = h.notifier.posts
        XCTAssertEqual(posts.map(\.title), [LaunchGate.anotherCopyTitle])
        XCTAssertTrue(posts.first?.body.contains(h.home.paths.appAliveFile.path) == true, "\(posts)")
    }

    /// A lock that cannot be taken at all (here a directory at its path)
    /// proves nothing about another copy, so it stops the launch the same way.
    func testALockThatCannotBeTakenAtAllAlsoStopsTheLaunch() async throws {
        let journal = try leaveAnExpiredSession()
        try FileManager.default.createDirectory(at: h.home.paths.appAliveFile, withIntermediateDirectories: true)
        let mine = AppAliveLock(url: h.home.paths.appAliveFile)
        var started = false

        let opened = await gate(mine).open(manager: h.makeManager(), start: { started = true })

        XCTAssertFalse(opened)
        XCTAssertFalse(started)
        XCTAssertEqual(h.guardFake.calls, [])
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), journal)
        XCTAssertEqual(h.notifier.posts.map(\.title), [LaunchGate.lockFailedTitle])
    }

    /// The copy that takes the lock starts the app, then reconciles.
    func testTheCopyThatTakesTheLockStartsAndThenReconciles() async throws {
        _ = try leaveAnExpiredSession()
        let mine = AppAliveLock(url: h.home.paths.appAliveFile)
        defer { mine.release() }
        let fake = h.guardFake
        var callsAtStart: [String]?

        let opened = await gate(mine).open(manager: h.makeManager(), start: { callsAtStart = fake.calls })

        XCTAssertTrue(opened)
        XCTAssertTrue(mine.isHeld)
        XCTAssertEqual(callsAtStart, [], "start runs before reconcile")
        XCTAssertTrue(h.guardFake.calls.contains("disablesleep 0"), "\(h.guardFake.calls)")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == LaunchGate.anotherCopyTitle })
    }

    /// backstop.sh's probe holds the lock for a moment; the wait outlasts it.
    func testABriefHoldSuchAsABackstopProbeIsWaitedOut() async throws {
        let probe = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try probe.tryAcquire())
        let letGo = Task {
            try await Task.sleep(for: .milliseconds(150))
            probe.release()
        }
        let mine = AppAliveLock(url: h.home.paths.appAliveFile)
        defer { mine.release() }
        var started = false

        let opened = await gate(mine, timeout: 3).open(manager: h.makeManager(), start: { started = true })
        try await letGo.value

        XCTAssertTrue(opened)
        XCTAssertTrue(started)
        XCTAssertTrue(mine.isHeld)
    }
}
