import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Insomnia

/// Popover style next to the other three: a hold that outlives the popover
/// ends nothing, an end the manager started takes the popover's additions
/// away, a style change leaves nothing of the old style behind, and the
/// popover gives focus back to the app the user was in.
final class PopoverStyleTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            for window in NSApp.windows where window.isVisible
                && (window.className.contains("Popover") || window is KeyCatcherPanel) {
                window.orderOut(nil)
            }
        }
        super.tearDown()
    }

    @MainActor
    private struct Rig {
        let h: Harness
        let manager: SessionManager
        let controller: StatusItemController

        init(mode: Config.MenuBarMode = .popover, focus: CompactDropdownController.AppFocus = UIStatusTests.quietFocus) {
            _ = NSApplication.shared
            h = Harness()
            manager = h.makeManager()
            manager.config.menuBarMode = mode
            let clock = h.clock
            controller = StatusItemController(
                manager: manager, status: PlaceholderStatus(), showSettings: {}, clock: { clock.now }, appFocus: focus
            )
        }

        var model: MenuBarModel { controller.model }

        func changeMode(_ mode: Config.MenuBarMode) {
            manager.config.menuBarMode = mode
            controller.synchronizePresentation()
        }

        func startSession(_ duration: TimeInterval = 3600) async {
            await manager.start(duration: duration)
            XCTAssertTrue(manager.isActive)
        }

        /// Waits for the latest start, extend or end the controller handed
        /// to the manager, until its result is shown.
        func waitForRequest() async {
            await controller.sessionRequest?.value
        }

        /// A plain on-screen window for the popover to hang from: a status
        /// item in a test process may never be on screen.
        func anchor() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 120, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            controller.popoverAnchor = window.contentView
            return window
        }
    }

    /// Returns once every block queued on the main queue before the call
    /// has run.
    @MainActor
    private func mainQueueTurn() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }

    // MARK: The bar

    /// In the time-left style the bar reads the minute text only. The
    /// manager's H:MM:SS text changes every second, and a bar that read it
    /// would be redrawn every second, which main's policy (1cd9d3a5) rules
    /// out.
    @MainActor
    func testThePopoverBarIsRedrawnOnceAMinuteNotEverySecond() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.startSession(2 * 3600)
        rig.h.clock.advance(30)
        rig.manager.refreshCountdown()
        let root = StatusRootView(
            model: rig.model, manager: rig.manager, onTapIcon: {}, onTapPill: { _ in },
            onTapCountdown: {}, onHoldEnd: {}, onWidthChange: { _ in }
        )
        func redrawn(after seconds: TimeInterval) -> Bool {
            let changed = Locked(false)
            withObservationTracking { _ = root.body } onChange: { changed.value = true }
            rig.h.clock.advance(seconds)
            rig.manager.refreshCountdown()
            return changed.value
        }
        XCTAssertFalse(redrawn(after: 1), "a second inside the same minute")
        XCTAssertEqual(rig.manager.remainingText, "1h 59m")
        XCTAssertTrue(redrawn(after: 60), "the next minute")
        XCTAssertEqual(rig.manager.remainingText, "1h 58m")
    }

    // MARK: Hold to end

    /// The popover's ring ends the session only while the popover is up in
    /// Popover style. A hold whose ring closes after the popover was closed
    /// (a click outside, Esc, the item) or after a style change ends
    /// nothing.
    @MainActor
    func testTheRingEndsTheSessionOnlyWhileThePopoverIsUp() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.startSession()

        rig.controller.openPopover()
        rig.controller.closePopover()
        rig.controller.popoverHoldToEnd()
        rig.controller.holdToEnd()
        await settleQueuedRequests()
        XCTAssertTrue(rig.manager.isActive, "the popover was closed before the ring closed")

        rig.controller.openPopover()
        rig.changeMode(.pills)
        XCTAssertFalse(rig.model.popoverShown)
        rig.controller.popoverHoldToEnd()
        await settleQueuedRequests()
        XCTAssertTrue(rig.manager.isActive, "the style changed under the hold")

        rig.changeMode(.popover)
        rig.controller.openPopover()
        rig.controller.popoverHoldToEnd()
        await rig.waitForRequest()
        XCTAssertFalse(rig.manager.isActive, "the ring ends the session while the popover is up")
    }

    /// The ring itself drops a hold when it leaves the screen or is turned
    /// off before it closes: the popover closing takes it away, and an end
    /// already on its way turns it off. The ring's own timer is the only
    /// thing left that could end the session, and it must not.
    @MainActor
    func testTheRingEndsNothingOnceItIsGoneOrTurnedOffMidHold() async {
        for change in [RingChange.none, .removed, .disabled] {
            let holds = await holdRing(change)
            XCTAssertEqual(holds, change == .none ? 1 : 0, "\(change)")
        }
    }

    /// Press the ring, make `change` 0.2 s in (the ring closes at 0.6 s),
    /// and return how many times it ended the session. The button stays
    /// down and the pointer still: only the change can stop the hold.
    @MainActor
    private func holdRing(_ change: RingChange) async -> Int {
        _ = NSApplication.shared
        var holds = 0
        let box = RingBox()
        let host = NSHostingView(rootView: RingHost(box: box, action: { holds += 1 }))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 20, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.3))
        NSApp.sendEvent(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!)
        try? await Task.sleep(for: .seconds(0.2))
        switch change {
        case .none: break
        case .removed: box.shown = false
        case .disabled: box.enabled = false
        }
        try? await Task.sleep(for: .seconds(0.7))
        return holds
    }

    // MARK: An end the manager started

    /// `--session end` refused for a busy lock leaves the session active
    /// and the end waiting for its retry, which would end any time added
    /// now. The popover reads the manager's end as the Compact panel
    /// does: Ending…, and no chip and no Return hands anything to the
    /// manager. The same holds while the retry restores sleep after it
    /// cleared the session, for the start chips.
    @MainActor
    func testAnEndTheManagerStartedTakesTheChipsAndReturnAway() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.startSession()
        let session = try XCTUnwrap(rig.manager.session)
        rig.controller.openPopover()
        let held = try XCTUnwrap(try RecoveryLock(url: rig.h.home.paths.recoveryLock).tryAcquire())
        let reply = await rig.manager.run(.end)
        XCTAssertNotNil(reply, "--session end went through over a busy lock")
        held.release()
        XCTAssertTrue(rig.manager.endIsWaiting)
        await assertAddsNothing(rig, "an end waiting for its retry")
        XCTAssertEqual(rig.manager.session, session, "time was added that the retry would end")

        let restore = AsyncGate()
        rig.h.guardFake.restoreGate = restore
        let retry = Task { await rig.manager.end(reason: .user) }
        await restore.waitUntilStarted()
        XCTAssertFalse(rig.manager.isActive)
        await assertAddsNothing(rig, "the retry restoring sleep")
        await restore.open()
        let outcome = await retry.value
        XCTAssertEqual(outcome, .restored)

        XCTAssertFalse(rig.model.endUnderway(rig.manager))
        rig.controller.makePopoverView().actions.start(3600)
        await rig.waitForRequest()
        XCTAssertTrue(rig.manager.isActive, "the chips are still off after the end")
        _ = await rig.manager.end(reason: .user)
    }

    /// The ring is off while an end the manager started runs (the timer's,
    /// waiting here for a busy lock), as it is through the popover's own.
    /// Once that end gives up and waits for its retry with the session
    /// still active, the ring asks for the end again at once, as the
    /// Compact panel's does.
    @MainActor
    func testTheRingEndsASessionWhoseEndWaitsForItsRetry() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.startSession()
        rig.controller.openPopover()
        let held = try XCTUnwrap(try RecoveryLock(url: rig.h.home.paths.recoveryLock).tryAcquire())
        let timer = await runUntilSuspended { await rig.manager.end(reason: .timer) }
        XCTAssertTrue(rig.manager.isEnding)
        XCTAssertFalse(rig.model.endIsEnabled(rig.manager))
        let ticket = rig.manager.endTicket
        rig.controller.popoverHoldToEnd()
        XCTAssertNil(rig.controller.sessionRequest, "the ring asked for a second end while the timer's ran")
        XCTAssertEqual(rig.manager.endTicket, ticket)
        let outcome = await timer.value
        XCTAssertEqual(outcome, .locked)
        held.release()

        XCTAssertTrue(rig.manager.endIsWaiting)
        XCTAssertTrue(rig.model.endUnderway(rig.manager), "the popover does not show the end")
        XCTAssertTrue(rig.model.endIsEnabled(rig.manager), "the ring is off for an end that waits")
        rig.controller.popoverHoldToEnd()
        await rig.waitForRequest()
        XCTAssertFalse(rig.manager.isActive, "the ring did not end the session")
        XCTAssertNil(rig.manager.pendingEnd)
        XCTAssertFalse(rig.model.endUnderway(rig.manager))
        // Opening the popover also reads the bit (`pmset -g`).
        XCTAssertEqual(rig.h.guardFake.calls.filter { $0 != "pmset -g" }, ["disablesleep 1", "disablesleep 0"])
        XCTAssertFalse(rig.h.guardFake.sleepDisabled)
    }

    /// Clicks every chip the popover shows and presses Return in its fields
    /// with a time typed, as the view would, then checks that nothing
    /// reached the manager and the time is still typed. Through the
    /// manager's end the view reads `endUnderway`: the header says
    /// Ending… and the chips and fields are off.
    @MainActor
    private func assertAddsNothing(_ rig: Rig, _ name: String) async {
        XCTAssertTrue(rig.model.endUnderway(rig.manager), "\(name): the popover does not show the end")
        let request = rig.controller.sessionRequest
        let fails = rig.manager.failCount
        let actions = rig.controller.makePopoverView().actions
        for seconds in rig.manager.config.presets { actions.start(seconds) }
        for seconds in StatusPopoverView.extendChoices { actions.extend(seconds) }
        rig.model.customShown = true
        rig.model.texts = [.hours: "1"]
        actions.commit()
        await settleQueuedRequests()
        XCTAssertEqual(rig.controller.sessionRequest, request, "\(name): a request reached the manager")
        XCTAssertEqual(rig.manager.failCount, fails, "\(name): the manager refused a request")
        XCTAssertNil(rig.model.pendingProjection, name)
        XCTAssertEqual(rig.model.texts, [.hours: "1"], "\(name): the time typed was spent")
        rig.model.texts = [:]
        rig.model.customShown = false
    }

    // MARK: Style changes

    /// Leaving Popover style with the popover up closes it, stops watching
    /// for clicks outside it and takes the button's action away; the
    /// popover does not open in another style.
    @MainActor
    func testLeavingPopoverStyleLeavesNoPopoverOrMonitorBehind() async {
        for next in [Config.MenuBarMode.pills, .compact, .minimal] {
            let rig = Rig()
            defer { rig.h.home.destroy() }
            let window = rig.anchor()
            defer { window.orderOut(nil) }
            await rig.startSession()
            rig.controller.openPopover()
            XCTAssertEqual(rig.controller.popover?.isShown, true)
            XCTAssertTrue(rig.controller.watchesForPopoverDismissal)

            rig.changeMode(next)
            XCTAssertFalse(rig.model.popoverShown, "\(next)")
            XCTAssertEqual(rig.controller.popover?.isShown, false, "\(next)")
            XCTAssertFalse(rig.controller.watchesForPopoverDismissal, "\(next)")
            XCTAssertNil(rig.controller.nativeStatusItem.button?.action, "\(next)")
            rig.controller.openPopover()
            XCTAssertFalse(rig.model.popoverShown, "\(next): no popover outside Popover style")
            XCTAssertEqual(next == .minimal, rig.controller.minimalTick != nil, "\(next): only Minimal ticks")
        }
    }

    /// Entering Popover style with the pills open, or from Minimal during a
    /// session, takes the pills, their key catcher and Minimal's tick down.
    @MainActor
    func testEnteringPopoverStyleLeavesNoPillsPanelOrTickBehind() async {
        let pills = Rig(mode: .pills)
        defer { pills.h.home.destroy() }
        pills.controller.expand(mode: .start)
        XCTAssertTrue(NSApp.windows.contains { ($0 as? KeyCatcherPanel)?.isVisible == true })
        pills.changeMode(.popover)
        XCTAssertFalse(pills.model.slotsPresent)
        XCTAssertFalse(pills.model.focusVisible)
        XCTAssertEqual(pills.model.phase, .idle)
        XCTAssertFalse(NSApp.windows.contains { ($0 as? KeyCatcherPanel)?.isVisible == true })
        XCTAssertNotNil(pills.controller.nativeStatusItem.button?.action, "the button takes the clicks now")

        let minimal = Rig(mode: .minimal)
        defer { minimal.h.home.destroy() }
        await minimal.startSession()
        XCTAssertNotNil(minimal.controller.minimalTick)
        minimal.changeMode(.popover)
        XCTAssertNil(minimal.controller.minimalTick)
    }

    /// A start asked for in the popover and still pending when the style
    /// changes keeps going in the new style: its countdown takes the new
    /// style's form, it is confirmed once, and nothing of the popover is
    /// left up.
    @MainActor
    func testAPendingPopoverStartCarriesOverToTheNewStyle() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.controller.openPopover()
        rig.model.texts[.hours] = "2"
        rig.controller.commit()
        await gate.waitUntilStarted()
        XCTAssertEqual(rig.model.pendingCountdown, "2h", "Popover's short form")

        rig.changeMode(.pills)
        XCTAssertFalse(rig.model.popoverShown)
        XCTAssertEqual(rig.model.phase, .starting)
        XCTAssertEqual(rig.model.pendingCountdown, "2:00:00", "the pills' form")
        await gate.open()
        await rig.waitForRequest()
        XCTAssertTrue(rig.manager.isActive)
        XCTAssertEqual(rig.model.phase, .running)
        XCTAssertNil(rig.model.pendingCountdown)
        XCTAssertEqual(rig.h.backstop.arms, 1)
        XCTAssertFalse(rig.controller.pendingTickArmed)
    }

    /// The same start refused after the change: the pills reopen on the
    /// value typed in the popover, as they do for one typed in the Compact
    /// panel.
    @MainActor
    func testAPopoverStartRefusedAfterSwitchingToPillsReopensThePillsOnTheValue() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.controller.openPopover()
        rig.model.texts[.hours] = "2"
        rig.controller.commit()
        await gate.waitUntilStarted()
        rig.changeMode(.pills)

        await gate.open()
        await rig.waitForRequest()
        XCTAssertTrue(rig.model.phase.isEntering)
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.input.total, 7200)
        XCTAssertEqual(rig.model.startError, MenuBarModel.startFailedText)
        XCTAssertFalse(rig.model.popoverShown)
        XCTAssertFalse(rig.controller.pendingTickArmed)
        rig.controller.collapse()
    }

    /// A chip's start refused after a switch to Pills: the pills reopen on
    /// the chip's duration, and Return asks for that duration again, not
    /// for the default preset.
    @MainActor
    func testAChipStartRefusedAfterSwitchingToPillsRetriesTheChipsDuration() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        XCTAssertNotEqual(rig.manager.config.defaultPreset, 7200)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.controller.openPopover()
        rig.controller.startPreset(7200)
        await gate.waitUntilStarted()
        rig.changeMode(.pills)

        await gate.open()
        await rig.waitForRequest()
        XCTAssertTrue(rig.model.phase.isEntering)
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertEqual(rig.model.input.total, 7200)

        rig.h.backstop.armGate = nil
        rig.h.backstop.failArm = false
        rig.controller.commit()
        await rig.waitForRequest()
        XCTAssertTrue(rig.manager.isActive)
        let session = rig.manager.session
        XCTAssertEqual(session.map { $0.endsAt.timeIntervalSince($0.startedAt) }, 7200)
        _ = await rig.manager.end(reason: .user)
    }

    /// An extend chip refused after a switch to Compact: the panel's entry
    /// opens on the chip's duration, not on an older value, and submitting
    /// it extends by that duration.
    @MainActor
    func testAnExtendChipRefusedAfterSwitchingToCompactRetriesTheChipsDuration() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.startSession()
        let endsAt = rig.manager.session?.endsAt
        // Left over from an earlier entry in the pills.
        rig.model.input = DurationInput.from(seconds: 4 * 3600)
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.controller.openPopover()
        rig.controller.extendBy(1800)
        await gate.waitUntilStarted()
        rig.changeMode(.compact)

        await gate.open()
        await rig.waitForRequest()
        XCTAssertFalse(rig.controller.compactModel.isBusy)
        XCTAssertTrue(rig.manager.isActive)
        XCTAssertEqual(rig.manager.session?.endsAt, endsAt)
        XCTAssertTrue(rig.controller.compactModel.isEditing)
        XCTAssertEqual(rig.controller.compactModel.entry.input.total, 1800)

        rig.h.backstop.armGate = nil
        rig.h.backstop.failArm = false
        rig.controller.compactSubmit()
        await rig.waitForRequest()
        XCTAssertNotEqual(rig.manager.session?.endsAt, endsAt)
        XCTAssertEqual(rig.manager.session?.extensions, [1800])
        _ = await rig.manager.end(reason: .user)
    }

    /// A 90 s start, from a popover chip or a Minimal click, refused after
    /// a switch to Pills or Compact. The pills and the panel's entry show
    /// whole minutes, so they read 1m, but submitting that input as it
    /// stands asks for 90 s again.
    @MainActor
    func testA90SecondStartRefusedAfterASwitchIsRetriedAt90Seconds() async {
        let switches: [(from: Config.MenuBarMode, to: Config.MenuBarMode)] = [
            (.popover, .pills), (.popover, .compact), (.minimal, .pills), (.minimal, .compact),
        ]
        for (from, to) in switches {
            let label = "\(from) to \(to)"
            let rig = Rig(mode: from)
            defer { rig.h.home.destroy() }
            let gate = AsyncGate()
            rig.h.backstop.armGate = gate
            rig.h.backstop.failArm = true
            if from == .popover {
                rig.controller.openPopover()
                rig.controller.startPreset(90)
            } else {
                rig.manager.config.defaultPreset = 90
                rig.controller.iconTapped()
            }
            await gate.waitUntilStarted()
            rig.changeMode(to)

            await gate.open()
            await rig.waitForRequest()
            XCTAssertFalse(rig.controller.compactModel.isBusy, label)
            XCTAssertFalse(rig.manager.isActive, label)
            rig.h.backstop.armGate = nil
            rig.h.backstop.failArm = false
            if to == .pills {
                XCTAssertTrue(rig.model.phase.isEntering, label)
                XCTAssertEqual(rig.model.input.total, 60, label)
                rig.controller.commit()
            } else {
                XCTAssertEqual(rig.controller.compactModel.entry.input.total, 60, label)
                rig.controller.compactSubmit()
            }
            await rig.waitForRequest()
            XCTAssertTrue(rig.manager.isActive, label)
            let session = rig.manager.session
            XCTAssertEqual(session.map { $0.endsAt.timeIntervalSince($0.startedAt) }, 90, label)
            _ = await rig.manager.end(reason: .user)
        }
    }

    /// The same for a 90 s extend chip refused after a switch to Compact:
    /// the entry reads 1m, and submitting it extends by 90 s.
    @MainActor
    func testA90SecondExtendChipRefusedAfterSwitchingToCompactIsRetriedAt90Seconds() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        await rig.startSession()
        let endsAt = rig.manager.session?.endsAt
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.controller.openPopover()
        rig.controller.extendBy(90)
        await gate.waitUntilStarted()
        rig.changeMode(.compact)

        await gate.open()
        await rig.waitForRequest()
        XCTAssertFalse(rig.controller.compactModel.isBusy)
        XCTAssertEqual(rig.manager.session?.endsAt, endsAt)
        XCTAssertEqual(rig.controller.compactModel.entry.input.total, 60)

        rig.h.backstop.armGate = nil
        rig.h.backstop.failArm = false
        rig.controller.compactSubmit()
        await rig.waitForRequest()
        XCTAssertNotEqual(rig.manager.session?.endsAt, endsAt)
        XCTAssertEqual(rig.manager.session?.extensions, [90])
        _ = await rig.manager.end(reason: .user)
    }

    /// A Custom start refused after the popover was closed and opened again
    /// while the start was on its way. The reopen cleared the fields, and
    /// the refusal puts the value back in them, so Start retries it.
    /// Something typed after the reopen is kept instead.
    @MainActor
    func testACustomStartRefusedAfterAReopenKeepsTheValueForTheRetry() async {
        for typedAgain in [nil, "3"] {
            let rig = Rig()
            defer { rig.h.home.destroy() }
            let gate = AsyncGate()
            rig.h.backstop.armGate = gate
            rig.h.backstop.failArm = true
            rig.controller.openPopover()
            rig.model.texts[.hours] = "2"
            rig.controller.popoverCommit()
            await gate.waitUntilStarted()
            rig.controller.closePopover()
            rig.controller.openPopover()
            XCTAssertEqual(rig.model.texts, [:], "the reopen shows the time buttons")
            if let typedAgain {
                rig.model.customShown = true
                rig.model.texts[.hours] = typedAgain
            }

            await gate.open()
            await rig.waitForRequest()
            XCTAssertFalse(rig.manager.isActive)
            XCTAssertNotNil(rig.model.startError)
            XCTAssertEqual(rig.model.texts, [.hours: typedAgain ?? "2"])
            XCTAssertTrue(rig.model.customShown)

            rig.h.backstop.armGate = nil
            rig.h.backstop.failArm = false
            rig.controller.popoverCommit()
            await rig.waitForRequest()
            let session = rig.manager.session
            XCTAssertEqual(session.map { $0.endsAt.timeIntervalSince($0.startedAt) }, typedAgain == nil ? 7200 : 10800)
            rig.controller.closePopover()
            _ = await rig.manager.end(reason: .user)
        }
    }

    /// A chip's start refused after a close and reopen leaves the fields
    /// empty: a time typed in Custom before the chip was not what the
    /// refused start asked for, so the retry doesn't get it.
    @MainActor
    func testAChipStartRefusedAfterAReopenDoesNotBringBackAnOlderDraft() async {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let gate = AsyncGate()
        rig.h.backstop.armGate = gate
        rig.h.backstop.failArm = true
        rig.controller.openPopover()
        rig.model.customShown = true
        rig.model.texts[.hours] = "2"
        rig.controller.startPreset(3600)
        await gate.waitUntilStarted()
        rig.controller.closePopover()
        rig.controller.openPopover()
        XCTAssertEqual(rig.model.texts, [:])

        await gate.open()
        await rig.waitForRequest()
        XCTAssertFalse(rig.manager.isActive)
        XCTAssertNotNil(rig.model.startError)
        XCTAssertEqual(rig.model.texts, [:], "the 2 hours typed before the chip stay out")
        XCTAssertFalse(rig.model.customShown)
        rig.controller.closePopover()
    }

    /// An edit drops the chip's 90 s, even one that leaves the input as it
    /// was: after a backspace and the same digit again, the submit asks
    /// for the 1m typed.
    @MainActor
    func testAnEditAfterARefusalAsksForWhatIsTyped() async {
        for to in [Config.MenuBarMode.pills, .compact] {
            let rig = Rig()
            defer { rig.h.home.destroy() }
            let gate = AsyncGate()
            rig.h.backstop.armGate = gate
            rig.h.backstop.failArm = true
            rig.controller.openPopover()
            rig.controller.startPreset(90)
            await gate.waitUntilStarted()
            rig.changeMode(to)

            await gate.open()
            await rig.waitForRequest()
            XCTAssertFalse(rig.controller.compactModel.isBusy, "\(to)")
            rig.h.backstop.armGate = nil
            rig.h.backstop.failArm = false
            let entry = to == .pills ? rig.model : rig.controller.compactModel.entry
            let shown = entry.input
            entry.applyInput(.focus(.minutes), reduceMotion: true)
            entry.applyInput(.backspace, reduceMotion: true)
            entry.applyInput(.digit(1), reduceMotion: true)
            XCTAssertEqual(entry.input, shown, "\(to)")
            if to == .pills {
                rig.controller.commit()
            } else {
                rig.controller.compactSubmit()
            }
            await rig.waitForRequest()
            XCTAssertTrue(rig.manager.isActive, "\(to)")
            let session = rig.manager.session
            XCTAssertEqual(session.map { $0.endsAt.timeIntervalSince($0.startedAt) }, 60, "\(to)")
            _ = await rig.manager.end(reason: .user)
        }
    }

    // MARK: Focus

    /// The popover takes focus when it opens, with the cursor asked into its
    /// fields, and gives focus back to the app the user was in when Esc,
    /// the item or a style change closes it. A close because focus went
    /// somewhere else (a click outside, another of the app's windows,
    /// Settings, a Space change, another app in front, a window of the app
    /// taking key) leaves focus there.
    @MainActor
    func testThePopoverTakesFocusAndGivesItBackToTheAppTheUserWasIn() async throws {
        _ = NSApplication.shared
        let editor = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current })
        let recorder = PopoverFocusRecorder(front: editor)
        let rig = Rig(focus: recorder.focus)
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.orderOut(nil) }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false

        /// Open with another app in front, as from the menu bar.
        func open() {
            recorder.active = false
            let requests = rig.model.focusRequest
            rig.controller.openPopover()
            XCTAssertTrue(rig.model.popoverShown)
            XCTAssertEqual(rig.model.focusRequest, requests + 1, "the fields are asked to take the cursor")
            recorder.active = true
        }

        // Esc.
        open()
        XCTAssertEqual(recorder.activations, 1, "opening activates Insomnia")
        XCTAssertEqual(rig.controller.popoverReturnApp, editor)
        rig.controller.makePopoverView().actions.close()
        XCTAssertEqual(recorder.yields, [editor], "Esc gives focus back")

        // A second click on the item.
        open()
        rig.controller.togglePopover()
        XCTAssertEqual(recorder.yields, [editor, editor])

        // A style change.
        open()
        rig.changeMode(.pills)
        XCTAssertEqual(recorder.yields.count, 3)
        rig.changeMode(.popover)

        // A click outside that brings no app forward, such as one on
        // another menu bar item, gives focus back once it has had its turn.
        let outside = NSPoint(x: window.frame.minX - 40, y: window.frame.midY)
        open()
        rig.controller.dismissUnlessOnItemOrPopover(at: outside)
        XCTAssertFalse(rig.model.popoverShown)
        XCTAssertEqual(recorder.yields.count, 3, "not before the click has had its turn")
        await mainQueueTurn()
        XCTAssertEqual(recorder.yields.count, 4, "a click outside that leaves Insomnia in front gives focus back")
        XCTAssertEqual(recorder.yields.last, editor)

        // Focus went elsewhere: it stays there. A click outside that has
        // brought another app forward by the time it is checked, then one
        // the user followed by opening the popover again and clicking into
        // Settings before the check ran.
        open()
        rig.controller.dismissUnlessOnItemOrPopover(at: outside)
        recorder.active = false
        try? await Task.sleep(for: .milliseconds(50))
        open()
        rig.controller.dismissUnlessOnItemOrPopover(at: outside)
        open()
        rig.controller.clickedInApp(window: other, at: .zero)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.yields.count, 4)
        open()
        rig.controller.openSettingsFromPopover()
        open()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await mainQueueTurn()
        XCTAssertFalse(rig.model.popoverShown, "a Space change closes it")
        open()
        recorder.keyWindow = true
        rig.controller.closePopover()
        recorder.keyWindow = false
        open()
        recorder.active = false
        rig.controller.closePopover()
        recorder.active = true
        XCTAssertEqual(recorder.yields.count, 4)

        // Opened while Insomnia was in front: there is no app to return to.
        recorder.front = .current
        open()
        XCTAssertNil(rig.controller.popoverReturnApp)
        rig.controller.closePopover()
        XCTAssertEqual(recorder.yields.count, 4)
        XCTAssertNil(rig.controller.popoverReturnApp)
    }

    /// A switch to another app by keyboard with the pointer resting on the
    /// item: no item click follows, so the popover closes once the wait for
    /// one is over. A click on the item in that wait is the item's own and
    /// toggles as before, and a popover opened again meanwhile stays up.
    /// Off the item, a switch closes it at once.
    @MainActor
    func testSwitchingAppsWithThePointerOnTheItemClosesThePopover() async {
        let recorder = PopoverFocusRecorder(front: nil)
        let rig = Rig(focus: recorder.focus)
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.close() }
        rig.controller.itemClickGrace = 0.05
        let onItem = NSPoint(x: window.frame.midX, y: window.frame.midY)

        rig.controller.openPopover()
        recorder.active = false
        rig.controller.resignedActive(pointer: onItem)
        XCTAssertTrue(rig.model.popoverShown, "left to an item click for a moment")
        for _ in 0..<200 where rig.model.popoverShown {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(rig.model.popoverShown, "no click came")

        // The item's own click: the resign, then its action closes the
        // popover, and a second click opens it again inside the wait.
        recorder.active = true
        rig.controller.openPopover()
        recorder.active = false
        rig.controller.resignedActive(pointer: onItem)
        rig.controller.togglePopover()
        XCTAssertFalse(rig.model.popoverShown)
        rig.controller.togglePopover()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(rig.model.popoverShown, "the wait belonged to the earlier opening")

        rig.controller.resignedActive(pointer: NSPoint(x: window.frame.minX - 40, y: window.frame.midY))
        XCTAssertFalse(rig.model.popoverShown, "off the item it closes at once")
    }

    /// A click on the item closes the popover and gives focus back, and a
    /// second click opens it again before that yield lands, with Insomnia
    /// still active. The yield then lands, with the pointer still on the
    /// item or already in the popover. The reopen asked for focus after
    /// the yield, so Insomnia ends up in front again and the popover stays
    /// up, taking typing. The same holds for two such cycles, where
    /// Insomnia is in front at the second open. A reopen once the yield
    /// has had its time asks for nothing while Insomnia is active.
    @MainActor
    func testAReopenBeforeTheCloseHasGivenFocusBackKeepsThePopover() async throws {
        _ = NSApplication.shared
        let editor = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current })
        let recorder = PopoverFocusRecorder(front: editor)
        let rig = Rig(focus: recorder.focus)
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.close() }
        rig.controller.itemClickGrace = 0.05
        let onItem = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let inPopover = NSPoint(x: window.frame.midX, y: window.frame.minY - 40)

        for (pointer, cycles) in [(onItem, 1), (inPopover, 1), (inPopover, 2)] {
            let label = "\(pointer), \(cycles) cycles"
            recorder.front = editor
            recorder.active = false
            rig.controller.openPopover()
            recorder.active = true
            recorder.front = .current
            let activations = recorder.activations
            let yields = recorder.yields.count
            for _ in 0..<cycles {
                rig.controller.togglePopover()
                rig.controller.togglePopover()
            }
            XCTAssertTrue(rig.model.popoverShown, label)
            XCTAssertEqual(recorder.yields.count, yields + cycles, "\(label): each close gives focus back")
            XCTAssertEqual(recorder.yields.last, editor, label)
            XCTAssertEqual(recorder.activations, activations + cycles, "\(label): each reopen asks for focus after the yield")
            XCTAssertEqual(rig.controller.popoverReturnApp, editor, label)

            // Each yield lands, then the activation asked for after it.
            for _ in 0..<cycles {
                recorder.active = false
                rig.controller.resignedActive(pointer: pointer)
                XCTAssertTrue(rig.model.popoverShown, label)
                recorder.active = true
            }
            recorder.active = recorder.lastRequestActivates
            try? await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(rig.model.popoverShown, label)
            XCTAssertTrue(recorder.active, "\(label): Insomnia is in front, so the fields take typing")

            // Leaving for real still closes it once the wait is over.
            recorder.active = false
            rig.controller.resignedActive(pointer: inPopover)
            try? await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(rig.model.popoverShown, label)
        }

        rig.controller.yieldLandingWindow = 0
        recorder.front = editor
        recorder.active = false
        rig.controller.openPopover()
        recorder.active = true
        rig.controller.togglePopover()
        let activations = recorder.activations
        rig.controller.togglePopover()
        XCTAssertEqual(recorder.activations, activations, "the yield has landed or was turned down")
        rig.controller.resignedActive(pointer: NSPoint(x: window.frame.minX - 40, y: window.frame.midY))
        XCTAssertFalse(rig.model.popoverShown, "off the item and the popover it closes at once")
    }

    /// The item closes the popover before the activation its open asked for
    /// has landed, with another app in front: a popover just opened from
    /// another app, or a quick reopen after the close's yield landed, once
    /// or after two cycles. That activation lands with nothing open, and
    /// focus goes back to the app in front at the close, or to the app the
    /// user went to after it. A reopen before it lands keeps the popover
    /// and moves nothing, and so does an activation after the wait for it
    /// is over. Nothing is left watching once it lands or the wait ends.
    @MainActor
    func testACloseBeforeTheOpensActivationLandsGivesFocusBack() async throws {
        _ = NSApplication.shared
        let editor = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current })
        let recorder = PopoverFocusRecorder(front: editor)
        let rig = Rig(focus: recorder.focus)
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.close() }
        rig.controller.itemClickGrace = 0.05
        let onItem = NSPoint(x: window.frame.midX, y: window.frame.midY)

        func activationLands() {
            recorder.active = true
            recorder.front = .current
            rig.controller.becameActive()
        }
        func yieldLands() {
            recorder.active = false
            recorder.front = editor
            rig.controller.resignedActive(pointer: onItem)
        }

        for cycles in [0, 1, 2] {
            let label = "\(cycles) cycles"
            recorder.front = editor
            recorder.active = false
            rig.controller.openPopover()
            if cycles > 0 {
                activationLands()
                for _ in 0..<cycles {
                    rig.controller.togglePopover()
                    rig.controller.togglePopover()
                }
                // Each yield before the last lands with its activation.
                for _ in 1..<cycles {
                    yieldLands()
                    activationLands()
                }
                yieldLands()
            }
            XCTAssertTrue(rig.model.popoverShown, label)
            let yields = recorder.yields.count
            rig.controller.togglePopover()
            XCTAssertFalse(rig.model.popoverShown, label)
            XCTAssertEqual(recorder.yields.count, yields, "\(label): another app is in front")
            activationLands()
            XCTAssertEqual(recorder.yields.count, yields + 1, "\(label): the activation brought Insomnia forward with nothing open")
            XCTAssertEqual(recorder.yields.last, editor, label)
            XCTAssertFalse(rig.controller.awaitsActivation, label)
            recorder.active = false
            recorder.front = editor
        }

        // The user goes to another app before the activation lands.
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current && $0 != editor })
        rig.controller.openPopover()
        rig.controller.togglePopover()
        rig.controller.otherAppActivated(other)
        rig.controller.otherAppActivated(.current)
        activationLands()
        XCTAssertEqual(recorder.yields.last, other, "the app the user went to last")
        recorder.active = false
        recorder.front = editor

        // Opened again before the activation lands.
        rig.controller.openPopover()
        rig.controller.togglePopover()
        rig.controller.togglePopover()
        let yields = recorder.yields.count
        activationLands()
        XCTAssertTrue(rig.model.popoverShown)
        XCTAssertEqual(recorder.yields.count, yields)
        rig.controller.closePopover(returnFocus: false)

        // An activation after the wait for one.
        rig.controller.yieldLandingWindow = 0
        recorder.active = false
        recorder.front = editor
        rig.controller.openPopover()
        rig.controller.togglePopover()
        activationLands()
        XCTAssertEqual(recorder.yields.count, yields, "no activation is on its way")

        // One the system turned down never lands.
        rig.controller.yieldLandingWindow = 0.05
        recorder.active = false
        recorder.front = editor
        rig.controller.openPopover()
        rig.controller.togglePopover()
        XCTAssertTrue(rig.controller.awaitsActivation)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(rig.controller.awaitsActivation, "the wait is over")
        activationLands()
        XCTAssertEqual(recorder.yields.count, yields)
    }

    // MARK: Input in the popover

    /// A mouse-down inside the popover is its own. On a MacBook most clicks
    /// inside also reached the global monitor, with the popover's window
    /// number and a location in the popover's coordinates; read as screen
    /// coordinates that was far outside, and the popover closed and gave
    /// focus back. A resign with the pointer in the popover waits, as on
    /// the item, and closes only if Insomnia is still in the background
    /// after that.
    @MainActor
    func testAClickInsideThePopoverLeavesItOpen() async throws {
        _ = NSApplication.shared
        let editor = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current })
        let recorder = PopoverFocusRecorder(front: editor)
        let rig = Rig(focus: recorder.focus)
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.close() }
        rig.controller.itemClickGrace = 0.05
        recorder.active = false
        rig.controller.openPopover()
        recorder.active = true
        let popoverWindow = try XCTUnwrap(rig.controller.popover?.contentViewController?.view.window)
        let frame = popoverWindow.frame
        let inside = NSPoint(x: frame.midX, y: frame.midY)
        XCTAssertFalse(window.frame.contains(inside))

        // The copy the global monitor got: the popover's number, and the
        // point in its coordinates.
        let copy = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: frame.width / 2, y: frame.height / 2), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popoverWindow.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        XCTAssertEqual(StatusItemController.screenLocation(of: copy), inside)
        let windowless = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inside, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        XCTAssertEqual(StatusItemController.screenLocation(of: windowless), inside, "already on the screen")

        rig.controller.dismissUnlessOnItemOrPopover(at: StatusItemController.screenLocation(of: copy))
        await mainQueueTurn()
        XCTAssertTrue(rig.model.popoverShown, "a click inside is the popover's own")
        XCTAssertEqual(recorder.yields, [])

        recorder.active = false
        rig.controller.resignedActive(pointer: inside)
        XCTAssertTrue(rig.model.popoverShown, "left to the click for a moment")
        recorder.active = true
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(rig.model.popoverShown, "Insomnia came back, so the popover stays")

        recorder.active = false
        rig.controller.resignedActive(pointer: inside)
        for _ in 0..<200 where rig.model.popoverShown {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(rig.model.popoverShown, "another app is in front after the wait")
        XCTAssertEqual(recorder.yields, [], "focus stays with that app")
    }

    /// Esc closes the popover and gives focus back with no field holding
    /// the cursor, as when only the time buttons are out. `onExitCommand`
    /// alone needs a focused field.
    @MainActor
    func testEscClosesThePopoverWithNoFieldFocused() async throws {
        _ = NSApplication.shared
        let editor = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0 != .current })
        let recorder = PopoverFocusRecorder(front: editor)
        let rig = Rig(focus: recorder.focus)
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.close() }
        recorder.active = false
        rig.controller.openPopover()
        recorder.active = true
        let popoverWindow = try XCTUnwrap(rig.controller.popover?.contentViewController?.view.window)
        XCTAssertFalse(rig.model.customShown)
        XCTAssertFalse(popoverWindow.firstResponder is NSText, "no field has the cursor")

        func key(_ characters: String, code: UInt16, in window: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ))
        }
        // Another key, or Esc in another window, leaves it.
        NSApp.sendEvent(try key("k", code: 40, in: popoverWindow))
        NSApp.sendEvent(try key("\u{1b}", code: 53, in: window))
        XCTAssertTrue(rig.model.popoverShown)

        NSApp.sendEvent(try key("\u{1b}", code: 53, in: popoverWindow))
        XCTAssertFalse(rig.model.popoverShown, "Esc closes it")
        XCTAssertEqual(recorder.yields, [editor], "and gives focus back")
    }

    /// Custom puts the cursor in Hours. On a MacBook the focus asked for
    /// with the same update that puts the fields out was dropped, and the
    /// popover itself kept it; this test process lays the popover out
    /// sooner and did not drop it, so it pins only where the cursor lands.
    @MainActor
    func testCustomPutsTheCursorInHours() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.close() }
        rig.controller.openPopover()
        let popoverWindow = try XCTUnwrap(rig.controller.popover?.contentViewController?.view.window)
        popoverWindow.makeKey()

        // As the Custom button does, with the run loop left to lay the
        // popover out and draw it, as in the app.
        rig.model.customShown = true
        let focused = await eventually {
            ((popoverWindow.firstResponder as? NSText)?.delegate as? NSTextField)?.placeholderString == "Hours"
        }
        XCTAssertTrue(focused, "the cursor is in Hours")
    }

    /// The popover's arrow follows the item when it moves or changes width
    /// with the popover up, as when an end takes the countdown off the bar.
    /// The menu bar moves the item after a resize, and on a MacBook the
    /// popover stayed where it was, its arrow about 50 pt beside the eye.
    /// Here the popover is taken off the item's window so the move does
    /// not carry it, as the menu bar's does not.
    @MainActor
    func testThePopoverFollowsTheItemWhenItMoves() async throws {
        let rig = Rig()
        defer { rig.h.home.destroy() }
        let window = rig.anchor()
        defer { window.close() }
        rig.controller.openPopover()
        let popoverWindow = try XCTUnwrap(rig.controller.popover?.contentViewController?.view.window)
        XCTAssertEqual(popoverWindow.frame.midX, window.frame.midX, accuracy: 1)
        popoverWindow.parent?.removeChildWindow(popoverWindow)

        // The item keeps its right edge and loses 94 pt, then moves.
        window.setFrame(NSRect(x: window.frame.maxX - 26, y: window.frame.minY, width: 26, height: window.frame.height), display: true)
        var followed = await eventually { abs(popoverWindow.frame.midX - window.frame.midX) < 1 }
        XCTAssertTrue(followed, "\(popoverWindow.frame.midX) against \(window.frame.midX) after a resize")
        popoverWindow.parent?.removeChildWindow(popoverWindow)
        window.setFrameOrigin(NSPoint(x: window.frame.minX - 60, y: window.frame.minY))
        followed = await eventually { abs(popoverWindow.frame.midX - window.frame.midX) < 1 }
        XCTAssertTrue(followed, "\(popoverWindow.frame.midX) against \(window.frame.midX) after a move")

        // Closed, it follows nothing.
        rig.controller.closePopover()
        XCTAssertFalse(rig.controller.watchesForPopoverDismissal)
    }

    @MainActor
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Stands in for the app activation calls, so a test run never changes the
/// app in front on the Mac.
@MainActor
private final class PopoverFocusRecorder {
    var front: NSRunningApplication?
    var active = true
    var keyWindow = false
    private(set) var activations = 0
    private(set) var yields: [NSRunningApplication] = []
    /// The last request, which is the one that wins once both land.
    private(set) var lastRequestActivates = false

    init(front: NSRunningApplication?) { self.front = front }

    var focus: CompactDropdownController.AppFocus {
        CompactDropdownController.AppFocus(
            frontmost: { [unowned self] in front },
            isActive: { [unowned self] in active },
            hasKeyWindow: { [unowned self] in keyWindow },
            activate: { [unowned self] in activations += 1; lastRequestActivates = true },
            yield: { [unowned self] app in yields.append(app); lastRequestActivates = false }
        )
    }
}

private enum RingChange { case none, removed, disabled }

@MainActor @Observable
fileprivate final class RingBox {
    var shown = true
    var enabled = true
}

private struct RingHost: View {
    let box: RingBox
    let action: () -> Void

    var body: some View {
        ZStack {
            Color.clear
            if box.shown {
                HoldToEndButton(
                    reduceMotion: true, isEnabled: box.enabled, action: action,
                    isPressed: { true }, pointer: { .zero }
                )
            }
        }
        .frame(width: 20, height: 20)
    }
}
