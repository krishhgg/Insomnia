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

    /// The journal the copy that owns the session left: a lid close muted
    /// the USB headset, and the session ended while it was unplugged, so
    /// its entry waits for it to reconnect. Returns the journal's bytes.
    private func leaveAHeadsetOwedItsVolume() throws -> Data {
        var st = RuntimeState()
        st.savedAudioOutputs = [SavedAudioOutput(deviceUID: "usb-headset", name: "USB Headset", volume: 0.3, muted: false, saveID: UUID().uuidString)]
        try h.store.saveState(st)
        return try Data(contentsOf: h.home.paths.stateFile)
    }

    /// A second copy registers for CoreAudio's device changes only once it
    /// holds the alive lock. The headset reconnects while the copy waits at
    /// the gate and again after it is refused: it stays muted and the other
    /// copy's journal is untouched.
    func testACopyWaitingAtTheGateOrRefusedThereRestoresNoReconnectedDevice() async throws {
        let journal = try leaveAHeadsetOwedItsVolume()
        let other = AppAliveLock(url: h.home.paths.appAliveFile)
        XCTAssertTrue(try other.tryAcquire())
        defer { other.release() }
        let mine = AppAliveLock(url: h.home.paths.appAliveFile)
        let m = h.makeManager()
        XCTAssertFalse(h.audio.watched, "init does not register")
        let audio = h.audio
        let reconnect = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(100))
            audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
            audio.fireDevicesChanged()
        }

        let opened = await gate(mine, timeout: 0.5).open(manager: m, start: {})
        try await reconnect.value
        h.audio.fireDevicesChanged()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(opened)
        XCTAssertFalse(h.audio.watched)
        XCTAssertEqual(h.audio.applied.count, 0)
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, true, "the headset stays muted")
        XCTAssertEqual(try Data(contentsOf: h.home.paths.stateFile), journal)
        XCTAssertEqual(h.guardFake.calls, [])
    }

    /// The copy that takes the lock registers before it reconciles: the
    /// headset, unplugged at launch, gets its volume back when it
    /// reconnects.
    func testTheCopyThatTakesTheLockRestoresADeviceWhenItReconnects() async throws {
        _ = try leaveAHeadsetOwedItsVolume()
        let mine = AppAliveLock(url: h.home.paths.appAliveFile)
        defer { mine.release() }
        let m = h.makeManager()
        let audio = h.audio
        var watchedAtStart: Bool?

        let opened = await gate(mine).open(manager: m, start: { watchedAtStart = audio.watched })

        XCTAssertTrue(opened)
        XCTAssertEqual(watchedAtStart, true, "registered once the lock is held, before start and reconcile")
        XCTAssertEqual(h.audio.applied.count, 0, "unplugged at launch: the entry waits")
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs.map(\.deviceUID), ["usb-headset"])

        h.audio.connect("usb-headset", name: "USB Headset", volume: 0.3, muted: true)
        h.audio.fireDevicesChanged()
        for _ in 0..<300 where h.audio.applied.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(h.audio.applied.map { $0.deviceUID }, ["usb-headset"])
        XCTAssertEqual(h.audio.device("usb-headset")?.muted, false)
        XCTAssertEqual(h.audio.device("usb-headset")?.volume, 0.3)
        for _ in 0..<300 where (try? h.store.loadState()) != RuntimeState.clean {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }
}
