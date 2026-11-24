import XCTest
@testable import Insomnia

/// A MacBook used closed on an external display (issue #97): a session
/// takes that lid as open.
@MainActor
final class ClosedDisplayModeTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func atDesk() {
        h.clamshell.closed = true
        h.clamshell.atDesk = true
    }

    func testASessionStartedAtADeskRunsItsCountdown() async throws {
        atDesk()
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)
        XCTAssertTrue(m.countdownTimerArmed)
        XCTAssertFalse(m.lidTakenAsClosed)
    }

    func testASessionStartedUnderALidWithNoDisplayStaysPaused() async throws {
        h.clamshell.closed = true
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertFalse(m.countdownTimerArmed)
        XCTAssertTrue(m.lidTakenAsClosed)
    }

    func testARelaunchAtADeskWithNothingToUndoRunsTheCountdown() async throws {
        atDesk()
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        let m = h.makeManager()
        await m.reconcile()
        XCTAssertNotNil(m.session)
        XCTAssertTrue(m.countdownTimerArmed)
        XCTAssertFalse(m.lidTakenAsClosed)
    }

    /// The lid closed in a bag, then a display was plugged in before
    /// relaunch: reconcile resumes frozen apps and audio and runs the
    /// countdown, while deferring saved built-in brightness until the lid
    /// physically opens.
    func testARelaunchAtADeskResumesAppsAndAudioButDefersBrightness() async throws {
        atDesk()
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.frozenProcesses = [FrozenProcess(pid: 111, startedAt: 5)]
        st.dockerFrozen = true
        st.savedAudioOutputs = [SavedAudioOutput(deviceUID: "spk", name: "Speakers", volume: 0.6, muted: false, saveID: "s1")]
        st.savedDisplayBrightness = 0.8
        st.savedKeyboardBrightness = 0.4
        try h.store.saveState(st)
        h.procs.stoppedNow = [111]
        h.audio.connect("spk", name: "Speakers", volume: 0.6, muted: true)
        let m = h.makeManager()
        await m.reconcile()

        XCTAssertNotNil(m.session)
        XCTAssertEqual(h.procs.resumed, [[111]])
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.muted, false)
        XCTAssertEqual(h.display.wakes, 0)
        XCTAssertEqual(h.display.sets, [])
        XCTAssertEqual(h.keyboard.sets, [])
        XCTAssertTrue(m.countdownTimerArmed)
        XCTAssertFalse(m.lidTakenAsClosed)

        let after = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(after.frozenProcesses, [])
        XCTAssertFalse(after.dockerFrozen)
        XCTAssertEqual(after.savedAudioOutputs, [])
        XCTAssertEqual(after.savedDisplayBrightness, 0.8)
        XCTAssertEqual(after.savedKeyboardBrightness, 0.4)
    }

    /// Closed in a bag during an active session, then plugged straight into
    /// a dock/external display without opening the lid: apps thaw, audio
    /// restores, countdown resumes, and built-in brightness waits until the
    /// lid physically opens.
    func testDockingAClosedLidThawsAppsAndRestoresAudioWhileDeferringBrightness() async throws {
        var cfg = Config()
        cfg.freezeList = ["com.example.chat"]
        cfg.muteOnLidClose = true
        cfg.darkenDisplayOnLidClose = true
        try h.store.saveConfig(cfg)
        h.display.brightness = 0.75
        h.keyboard.brightness = 0.5
        h.audio.connect("spk", name: "Speakers", volume: 0.6, muted: false)

        let m = h.makeManager()
        await m.start(duration: 3600)
        let freezer = FakeFreezer(
            apps: [RunningApp(pid: 200, bundleId: "com.example.chat", name: "Chat")],
            processes: [
                ProcessEntry(pid: 1, ppid: 0, startedAt: 1),
                ProcessEntry(pid: 200, ppid: 1, startedAt: 2000),
            ],
            control: h.procs
        )
        let actions = LidActions(
            manager: m,
            freezer: freezer,
            docker: DockerRule(freezer: freezer, probe: { false }),
            audio: h.audio,
            display: h.display,
            keyboard: h.keyboard
        )

        // Close lid in a bag (built-in panel online).
        h.clamshell.closed = true
        h.clamshell.atDesk = false
        h.display.builtInIsOnline = true
        await actions.onClose()

        XCTAssertEqual(h.procs.suspended, [[200]])
        XCTAssertEqual(h.display.sets, [0])
        XCTAssertEqual(h.keyboard.sets, [0])
        XCTAssertFalse(m.countdownTimerArmed)

        // Plug into a Thunderbolt dock / external display without opening the lid.
        h.clamshell.atDesk = true
        h.display.builtInIsOnline = false
        await actions.onOpen()

        XCTAssertEqual(h.procs.resumed, [[200]], "apps must thaw when docked in clamshell mode")
        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.muted, false)
        XCTAssertTrue(m.countdownTimerArmed, "countdown must resume on the external display")
        XCTAssertEqual(h.display.wakes, 0, "built-in display must not wake while lid is shut")
        XCTAssertEqual(h.display.sets, [0], "built-in display brightness must stay deferred")
        XCTAssertEqual(h.keyboard.sets, [0], "keyboard backlight must stay deferred")
        let docked = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(docked.frozenProcesses, [])
        XCTAssertEqual(docked.savedAudioOutputs, [])
        XCTAssertEqual(docked.savedDisplayBrightness, 0.75)
        XCTAssertEqual(docked.savedKeyboardBrightness, 0.5)

        // Later, physically open the lid: deferred brightness restores.
        h.clamshell.closed = false
        h.clamshell.atDesk = false
        h.display.builtInIsOnline = true
        await actions.onPhysicalOpen()

        XCTAssertEqual(h.display.wakes, 1)
        XCTAssertEqual(h.display.sets, [0, 0.75])
        XCTAssertEqual(h.keyboard.sets, [0, 0.5])
        let opened = try XCTUnwrap(try h.store.loadState())
        XCTAssertNil(opened.savedDisplayBrightness)
        XCTAssertNil(opened.savedKeyboardBrightness)
    }

    /// Reconnecting a muted audio device while closed at a desk restores
    /// its volume instead of waiting for the physical lid to open.
    func testOutputDeviceChangeWhileClosedAtADeskRestoresSavedAudio() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        try m.journal {
            $0.savedAudioOutputs = [SavedAudioOutput(deviceUID: "hp", name: "Headphones", volume: 0.5, muted: false, saveID: "s1")]
        }
        h.audio.connect("hp", name: "Headphones", volume: 0.5, muted: true)
        atDesk()

        await m.outputDevicesChanged()

        XCTAssertEqual(h.audio.applied.count, 1)
        XCTAssertEqual(h.audio.applied.first?.deviceUID, "hp")
        XCTAssertEqual(h.audio.applied.first?.muted, false)
        XCTAssertEqual(try h.store.loadState()?.savedAudioOutputs, [])
    }
}
