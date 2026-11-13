import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

/// The start and end sounds. Each test records the cues the controller
/// asks the app to play; none plays audio. The switch ("Play a sound when
/// you start or end a session") is off by default, so the tests that
/// expect a sound turn it on, and one-click start too, to start with a
/// click.
final class UIFeedbackTests: XCTestCase {
    /// A refused one-click start reopens the pills, and with them the
    /// key-catcher panel, which must not stay up for the next test.
    override func tearDown() {
        MainActor.assumeIsolated {
            for panel in NSApp.windows.compactMap({ $0 as? KeyCatcherPanel }) where panel.isVisible {
                panel.orderOut(nil)
            }
        }
        super.tearDown()
    }

    @MainActor
    func testSoundWaitsForSuccessfulActivationAndCompletedDeactivation() async throws {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        manager.config.sessionSounds = true
        manager.config.oneClickStart = true
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, readLid: { nil }, playSessionSound: { cues.append($0) })
        let gate = AsyncGate()
        harness.backstop.armGate = gate
        controller.iconTapped(modifiers: [])
        await gate.waitUntilStarted()
        XCTAssertTrue(cues.isEmpty)
        controller.iconTapped(modifiers: [])
        await gate.open()
        await settle { cues == [.activated] }
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(cues, [.activated])
        let restoreGate = AsyncGate()
        harness.guardFake.restoreGate = restoreGate
        // A click never ends a session; the hold does.
        controller.holdToEnd()
        await restoreGate.waitUntilStarted()
        XCTAssertEqual(cues, [.activated], "The stop sound waits until restoration finishes")
        await restoreGate.open()
        await settle { cues.count == 2 }
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(cues, [.activated, .deactivated])
    }

    @MainActor
    func testIncompleteRestorationDoesNotPlayASuccessSound() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        manager.config.sessionSounds = true
        manager.config.oneClickStart = true
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, readLid: { nil }, playSessionSound: { cues.append($0) })
        controller.iconTapped(modifiers: [])
        await settle { cues == [.activated] }
        harness.guardFake.throwOn = ["disablesleep 0"]
        controller.holdToEnd()
        await settle { manager.lastError != nil }
        XCTAssertTrue(harness.guardFake.sleepDisabled)
        XCTAssertEqual(cues, [.activated])
        harness.guardFake.throwOn = []
        await manager.end(reason: .user)
    }

    @MainActor
    func testFailedStartIsSilent() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        harness.backstop.failArm = true
        let manager = harness.makeManager()
        manager.config.sessionSounds = true
        manager.config.oneClickStart = true
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, readLid: { nil }, playSessionSound: { cues.append($0) })
        controller.iconTapped(modifiers: [])
        await settle { controller.model.phase != .starting }
        XCTAssertFalse(manager.isActive)
        XCTAssertNotNil(manager.lastError)
        XCTAssertTrue(cues.isEmpty)
    }

    @MainActor
    func testBothCuesDecodeAsDistinctShortSoundsWithoutPlayingAudio() throws {
        let start = SessionSoundCue.activated.waveData
        let end = SessionSoundCue.deactivated.waveData
        XCTAssertNotEqual(start, end)
        for data in [start, end] {
            let sound = try XCTUnwrap(NSSound(data: data))
            XCTAssertEqual(sound.duration, 0.14, accuracy: 0.002)
            XCTAssertEqual(Array(data[44..<46]), [0, 0])
            XCTAssertEqual(Array(data.suffix(2)), [0, 0])
        }
    }

    // MARK: The switch and when nothing plays

    /// Off by default, and off nothing plays. The app's closure is the
    /// only thing that touches `SessionSounds`, so with no call nothing is
    /// generated or loaded either.
    @MainActor
    func testNothingPlaysWithTheSwitchOff() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        XCTAssertFalse(manager.config.sessionSounds)
        manager.config.oneClickStart = true
        let recorder = CueRecorder()
        let controller = recorder.controller(manager)
        controller.iconTapped(modifiers: [])
        await settle { manager.isActive && controller.model.phase == .running }
        XCTAssertTrue(manager.isActive)
        controller.holdToEnd()
        await controller.sessionRequest?.value
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(recorder.cues, [])
        XCTAssertEqual(recorder.lidReads, 0, "With the switch off, nothing reads the lid")
    }

    /// Compact's panel starts and ends through its own path, and plays the
    /// same sounds.
    @MainActor
    func testTheCompactPanelsStartAndEndPlay() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        manager.config.sessionSounds = true
        manager.config.menuBarMode = .compact
        let recorder = CueRecorder()
        let controller = recorder.controller(manager)
        controller.compactSubmit()
        await settle { manager.isActive && !controller.compactModel.isBusy }
        XCTAssertEqual(recorder.cues, [.activated])
        controller.compactEnd()
        await controller.sessionRequest?.value
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(recorder.cues, [.activated, .deactivated])
    }

    /// An end the user did not ask for plays nothing: the deadline, the
    /// recovery agent, a quit or a battery floor.
    @MainActor
    func testAnEndTheUserDidNotAskForIsSilent() async {
        for reason in [EndReason.timer, .backstop, .quit, .batteryFloor] {
            let harness = Harness()
            let manager = harness.makeManager()
            manager.config.sessionSounds = true
            manager.config.oneClickStart = true
            let recorder = CueRecorder()
            let controller = recorder.controller(manager)
            controller.iconTapped(modifiers: [])
            await settle { recorder.cues == [.activated] }
            XCTAssertTrue(manager.isActive, "\(reason)")
            await manager.end(reason: reason)
            await settleQueuedRequests()
            XCTAssertFalse(manager.isActive, "\(reason)")
            XCTAssertEqual(recorder.cues, [.activated], "\(reason)")
            harness.home.destroy()
        }
    }

    /// Crash recovery at launch ends a session an earlier run left behind,
    /// and plays nothing.
    @MainActor
    func testCrashRecoveryIsSilent() async throws {
        let harness = Harness()
        defer { harness.home.destroy() }
        let now = harness.clock.now
        try harness.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var state = RuntimeState()
        state.sleepDisabledByUs = true
        try harness.store.saveState(state)
        harness.guardFake.sleepDisabled = true
        let manager = harness.makeManager()
        manager.config.sessionSounds = true
        let recorder = CueRecorder()
        _ = recorder.controller(manager)
        await manager.reconcile()
        await settleQueuedRequests()
        XCTAssertFalse(manager.isActive)
        XCTAssertFalse(harness.guardFake.sleepDisabled)
        XCTAssertEqual(recorder.cues, [])
    }

    /// The user's end can wait in the manager's queue behind the timer's.
    /// The timer's end then finds the session and restores, and the user's
    /// finds nothing left to end. That end was the timer's: nothing plays.
    @MainActor
    func testAnEndThatWaitedBehindTheTimersIsSilent() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let waits = HeldLockWaits()
        let manager = harness.makeManager(acquireRecoveryLock: { try await waits.acquire($0, timeout: $1) })
        manager.config.sessionSounds = true
        manager.config.oneClickStart = true
        let recorder = CueRecorder()
        let controller = recorder.controller(manager)
        controller.iconTapped(modifiers: [])
        await settle { recorder.cues == [.activated] && controller.model.phase == .running }
        XCTAssertEqual(recorder.cues, [.activated])

        let gate = AsyncGate()
        waits.holdNext(until: gate, then: .take)
        let timerEnd = Task { await manager.end(reason: .timer) }
        await gate.waitUntilStarted()
        XCTAssertTrue(manager.isActive)
        controller.holdToEnd()
        await settleQueuedRequests()
        await gate.open()
        _ = await timerEnd.value
        await controller.sessionRequest?.value
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(manager.lastEndReason, .timer)
        XCTAssertEqual(recorder.cues, [.activated])
    }

    /// Nothing plays while every display sleeps or the lid is closed.
    @MainActor
    func testNothingPlaysWhileTheDisplaysSleepOrTheLidIsClosed() async {
        for lid in [false, true] {
            let harness = Harness()
            let manager = harness.makeManager()
            manager.config.sessionSounds = true
            manager.config.oneClickStart = true
            let status = PlaceholderStatus()
            if lid {
                status.lidClosed = true
            } else {
                manager.displaysAsleepChanged(true)
            }
            let recorder = CueRecorder()
            let controller = recorder.controller(manager, status: status)
            controller.iconTapped(modifiers: [])
            await settle { manager.isActive && controller.model.phase == .running }
            XCTAssertTrue(manager.isActive, lid ? "lid closed" : "displays asleep")
            controller.holdToEnd()
            await controller.sessionRequest?.value
            XCTAssertFalse(manager.isActive, lid ? "lid closed" : "displays asleep")
            XCTAssertEqual(recorder.cues, [], lid ? "lid closed" : "displays asleep")
            harness.home.destroy()
        }
    }

    /// On an external display, a start or an end within 2 s of closing the
    /// lid finds `status.lidClosed` still open: the lid observer waits that
    /// long before it reports a close, and an end stops it. The registry
    /// already says closed, and nothing plays.
    @MainActor
    func testNothingPlaysInTheTwoSecondsAfterTheLidCloses() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        manager.config.sessionSounds = true
        manager.config.oneClickStart = true
        let status = PlaceholderStatus()
        let recorder = CueRecorder()
        recorder.lid = true
        let controller = recorder.controller(manager, status: status)
        controller.iconTapped(modifiers: [])
        await settle { manager.isActive && controller.model.phase == .running }
        await controller.sessionRequest?.value
        XCTAssertTrue(manager.isActive)
        XCTAssertFalse(status.lidClosed)
        XCTAssertEqual(recorder.cues, [], "The start cue")
        controller.holdToEnd()
        await controller.sessionRequest?.value
        XCTAssertFalse(manager.isActive)
        XCTAssertEqual(recorder.cues, [], "The end cue")
    }

    @MainActor
    private final class CueRecorder {
        var cues: [SessionSoundCue] = []
        /// What the registry says of the lid when a cue would play: true is
        /// closed. Nil, as on a Mac with no lid, leaves `status.lidClosed`.
        var lid: Bool?
        var lidReads = 0

        func controller(_ manager: SessionManager, status: PlaceholderStatus = PlaceholderStatus()) -> StatusItemController {
            StatusItemController(
                manager: manager, status: status, showSettings: {},
                appFocus: UIStatusTests.quietFocus,
                readLid: { [weak self] in
                    self?.lidReads += 1
                    return self?.lid
                },
                playSessionSound: { [weak self] in self?.cues.append($0) }
            )
        }
    }

    @MainActor
    private func settle(_ complete: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !complete(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
