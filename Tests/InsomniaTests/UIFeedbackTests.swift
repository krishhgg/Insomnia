import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

final class UIFeedbackTests: XCTestCase {
    @MainActor
    func testIdleAutoOnOffPlaysModeSoundsWithoutHoldingSleep() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        let auto = AgentAutoController(manager: manager, pollInterval: nil)
        manager.agentAuto = auto
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {},
                                              playSessionSound: { cues.append($0) }, captureEvents: false)
        await controller.toggleAuto()
        XCTAssertTrue(auto.enabled)
        XCTAssertEqual(cues, [.activated])
        XCTAssertFalse(manager.isActive)
        XCTAssertFalse(harness.guardFake.sleepDisabled)
        await controller.toggleAuto()
        XCTAssertFalse(auto.enabled)
        XCTAssertEqual(cues, [.activated, .deactivated])
    }

    @MainActor
    func testSoundWaitsForSuccessfulActivationAndCompletedDeactivation() async throws {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, playSessionSound: { cues.append($0) })
        let gate = AsyncGate()
        harness.backstop.armGate = gate
        controller.toggleSession()
        await gate.waitUntilStarted()
        XCTAssertTrue(cues.isEmpty)
        controller.toggleSession()
        await gate.open()
        await settle { cues == [.activated] }
        XCTAssertTrue(manager.isActive)
        XCTAssertEqual(cues, [.activated])
        let restoreGate = AsyncGate()
        harness.guardFake.restoreGate = restoreGate
        controller.toggleSession()
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
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, playSessionSound: { cues.append($0) })
        controller.toggleSession()
        await settle { cues == [.activated] }
        harness.guardFake.throwOn = ["disablesleep 0"]
        controller.toggleSession()
        await settle { manager.lastError != nil }
        XCTAssertTrue(harness.guardFake.sleepDisabled)
        XCTAssertEqual(cues, [.activated])
        harness.guardFake.throwOn = []
        await manager.end(reason: .user)
    }

    @MainActor
    func testQuickMenuFitsTheCompactPanelWithAllSixChoices() {
        let harness = Harness()
        defer { harness.home.destroy() }
        let view = QuickMenuView(
            manager: harness.makeManager(), model: MenuBarModel(),
            onPreset: { _ in }, onToggle: {}, onSettings: {},
            onDetails: {}, onQuit: {}, onDismiss: {}
        )
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        XCTAssertEqual(host.fittingSize.width, 260, accuracy: 1)
        XCTAssertLessThan(host.fittingSize.height, 400)
        XCTAssertGreaterThan(host.fittingSize.height, 250)
    }

    @MainActor
    func testRegisteredAgentResolvesNearestOwningApplication() {
        let parents: [Int32: Int32] = [900: 800, 800: 700, 700: 1]
        let parent: (Int32) -> Int32? = { parents[$0] }
        XCTAssertEqual(RunningApps.ownerApplicationPID(ownerPID: 900, applicationPIDs: [700], parentPID: parent), 700)
        XCTAssertEqual(RunningApps.ownerApplicationPID(ownerPID: 900, applicationPIDs: [900, 700], parentPID: parent), 900)
        XCTAssertNil(RunningApps.ownerApplicationPID(ownerPID: 900, applicationPIDs: [600], parentPID: parent))
        XCTAssertNil(RunningApps.ownerApplicationPID(ownerPID: 900, applicationPIDs: [700], parentPID: { $0 == 900 ? 800 : 900 }))
    }

    @MainActor
    func testAgentRowFocusesItsOwnerApplication() {
        let harness = Harness()
        defer { harness.home.destroy() }
        var activated: [Int32] = []
        let controller = StatusItemController(
            manager: harness.makeManager(), status: PlaceholderStatus(), showSettings: {}, captureEvents: false,
            activateAgentApplication: { activated.append($0); return true }
        )
        let now = Date()
        let job = AgentJob(
            id: UUID(), name: "HerdR agent", pid: 4242,
            identity: ProcessIdentity(startedAt: 42, startedAtMicros: 12, bootSession: "test"),
            startedAt: now, deadline: now.addingTimeInterval(3600), heartbeatAt: now,
            startedUptime: 100, heartbeatUptime: 100
        )

        controller.focusAgent(job)

        XCTAssertEqual(activated, [job.pid])
    }

    @MainActor
    func testFailedStartIsSilent() async {
        let harness = Harness()
        defer { harness.home.destroy() }
        harness.backstop.failArm = true
        let manager = harness.makeManager()
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, playSessionSound: { cues.append($0) })
        controller.toggleSession()
        await settle { controller.model.phase != .starting }
        XCTAssertFalse(manager.isActive)
        XCTAssertNotNil(manager.lastError)
        XCTAssertTrue(cues.isEmpty)
    }

    @MainActor
    func testSixAndEightHourQuickItemsStartAndExtendWithoutRepeatingActivationSound() async throws {
        let harness = Harness()
        defer { harness.home.destroy() }
        let manager = harness.makeManager()
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {}, playSessionSound: { cues.append($0) })
        XCTAssertEqual(QuickMenuView.durations, [1800, 3600, 7200, 14400, 21600, 28800])
        controller.startPreset(21600)
        await settle { cues == [.activated] }
        let session = try XCTUnwrap(manager.session)
        XCTAssertEqual(session.endsAt.timeIntervalSince(session.startedAt), 21600)
        controller.startPreset(28800)
        await settle { manager.session?.endsAt != session.endsAt }
        XCTAssertEqual(try XCTUnwrap(manager.session).endsAt.timeIntervalSince(session.endsAt), 28800)
        XCTAssertEqual(cues, [.activated])
        await manager.end(reason: .user)
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

    @MainActor
    private func settle(_ complete: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !complete(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
