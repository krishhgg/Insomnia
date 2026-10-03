import Foundation

/// Spec section 4: the fixed, reversible action list run on lid close and
/// undone on lid open. Every step is journaled to state.json *before* the
/// side effect; undo reads state.json, never memory.
///
/// Order on close: darken (save display brightness and keyboard backlight
/// first, then set both to 0 and ask the display to sleep), mute (save
/// volume + mute state first), freeze scope (the freeze list plus every
/// other Dock app when `freezeAllApps` is on; one journal write per app),
/// Docker rule, stop the countdown redraw.
/// Order on open: the exact reverse, driven by `SessionManager.undoLidActions`.
@MainActor
final class LidActions {
    private weak var manager: SessionManager?
    private let freezer: any Freezing
    private let docker: DockerRule
    private let audio: any AudioControlling
    private let display: any DisplayDimming
    private let keyboard: any KeyboardBacklighting
    /// Last trusted brightness values, kept by AppServices while the lid is
    /// open. nil (tests) means the device's own asleep/suppressed reading
    /// decides alone.
    private let sampler: BrightnessSampler?

    init(
        manager: SessionManager,
        freezer: any Freezing,
        docker: DockerRule,
        audio: any AudioControlling,
        display: any DisplayDimming = NoopDisplayDimmer(),
        keyboard: any KeyboardBacklighting = NoopKeyboardBacklight(),
        sampler: BrightnessSampler? = nil
    ) {
        self.manager = manager
        self.freezer = freezer
        self.docker = docker
        self.audio = audio
        self.display = display
        self.keyboard = keyboard
        self.sampler = sampler
    }

    func onClose() async {
        guard let manager, manager.isActive, !Task.isCancelled else {
            Log.info("lid closed: no session, nothing to do")
            return
        }
        // One lifecycle transaction: journal writes and SIGSTOPs happen
        // under the recovery lock, after any end already in flight.
        let ran = await manager.runExclusive("lid close") { [self, manager] in
            guard manager.isActive, !Task.isCancelled else { return }
            let ticket = manager.endTicket
            let config = manager.config

            if config.darkenDisplayOnLidClose {
                darkenSavingCurrent(manager)
            }

            if config.muteOnLidClose {
                muteSavingCurrent(manager)
            }

            let groups = freezer.plan(config: config)
            for group in groups {
                freeze(group, docker: false, manager: manager)
            }

            let dockerGroup = await docker.idleDockerGroup(config: config)
            // An end requested while the probe ran wins: it is queued right
            // behind this transaction and must not find a fresh freeze.
            guard manager.isActive, manager.endTicket == ticket, !Task.isCancelled else { return }
            if let dockerGroup {
                freeze(dockerGroup, docker: true, manager: manager)
            }

            manager.pauseCountdown()
        }
        if !ran { Log.error("lid close actions skipped: recovery lock busy") }
    }

    func onOpen() async {
        guard let manager, manager.isActive, !Task.isCancelled else {
            Log.info("lid opened: no session, nothing to do")
            return
        }
        await manager.undoLidActions()
        guard manager.isActive, !Task.isCancelled else { return }
        manager.resumeCountdown()
    }

    // MARK: Private

    /// With `pmset disablesleep 1` macOS never turns the built-in panel or
    /// the keyboard backlight off on lid close, so this does. Brightness 0
    /// is the mechanism; the display sleep request is a bonus that macOS
    /// ignores while any process (an agent, say) holds a display assertion.
    ///
    /// What gets journaled is the user's value, not whatever the device
    /// reads at this instant. The display at the close event is never the
    /// user's value when it can be avoided: the lid coming down covers the
    /// ambient light sensor and auto-brightness has already pulled the
    /// panel down by the time the close is reported, Low Power Mode (which
    /// the session itself may have switched on) rescales it, and a panel
    /// that idle-dimmed or slept reads its dim value. So the display
    /// journals the last sample taken with the lid open (every 30 s, at
    /// start, 3 s after each open, and just before Insomnia's own Low Power
    /// Mode goes on, held from then until it goes off); without one, the
    /// value a lid open restored under our Low Power Mode, still journaled
    /// as owed and the mode still ours (the app relaunched under the mode:
    /// the new sampler has no sample and is held; an entry left behind
    /// after the mode was released is stale and not used); only without
    /// either the current read, dim or
    /// not, since a dim panel on open beats a black one. The sample can be
    /// up to 30 s old: a brightness change made right before closing the
    /// lid is not seen. The keyboard reads 0
    /// when suppressed by display sleep, so it takes the current read if
    /// trusted now, else the last trusted sample, else nothing, since
    /// restoring 0 would leave the backlight off for good.
    private func darkenSavingCurrent(_ manager: SessionManager) {
        do {
            let current = try display.readBrightness()
            let value: Float
            if let sampled = sampler?.last?.display {
                value = sampled
                if sampled != current {
                    Log.info("display brightness reads \(current) at the close; journaling the last open-lid sample \(sampled)")
                }
            } else if manager.state.lowPowerSetByUs, let owed = manager.state.displayRestoredUnderLowPower {
                value = owed
                Log.info("display brightness reads \(current) at the close under our low power mode with no sample; journaling the value restored under it, \(owed)")
            } else if sampler?.displayReadIsTrusted ?? !display.isAsleep() {
                value = current
            } else {
                value = current
                Log.info("display brightness read while dimmed or asleep and no trusted sample; restoring that value on open")
            }
            try manager.journal { s in
                // Keep an earlier save if a previous close was never undone.
                if s.savedDisplayBrightness == nil { s.savedDisplayBrightness = value }
            }
            do {
                try display.setBrightness(0)
                Log.info("display darkened (was brightness \(value))")
            } catch {
                // The journal entry stays: the open restores whatever is there.
                Log.error("display darken failed: \(error.localizedDescription)")
            }
        } catch {
            Log.error("display darken on lid close skipped: \(error.localizedDescription)")
        }

        do {
            if let current = try keyboard.readBrightness() {
                let value: Float?
                if sampler?.keyboardReadIsTrusted ?? !keyboard.isSuppressedOrDimmed() {
                    value = current
                } else if let sampled = sampler?.last?.keyboard {
                    value = sampled
                    Log.info("keyboard backlight read while suppressed or dimmed (\(current)); journaling the last trusted sample \(sampled)")
                } else {
                    value = nil
                }
                if let value {
                    try manager.journal { s in
                        if s.savedKeyboardBrightness == nil { s.savedKeyboardBrightness = value }
                    }
                    do {
                        try keyboard.setBrightness(0)
                        Log.info("keyboard backlight off (was brightness \(value))")
                    } catch {
                        Log.error("keyboard backlight off failed: \(error.localizedDescription)")
                    }
                } else {
                    Log.info("keyboard backlight suppressed by display sleep and no trusted sample; leaving it to macOS")
                }
            } else {
                Log.info("no built-in keyboard backlight; skipped")
            }
        } catch {
            Log.error("keyboard backlight on lid close skipped: \(error.localizedDescription)")
        }

        do {
            try display.requestSleep()
            Log.info("display sleep requested")
        } catch {
            Log.info("display sleep request failed: \(error.localizedDescription)")
        }
    }

    private func muteSavingCurrent(_ manager: SessionManager) {
        do {
            let current = try audio.read()
            try manager.journal { s in
                // Keep an earlier save if a previous close was never undone.
                if s.savedOutputVolume == nil { s.savedOutputVolume = current.volume }
                if s.savedMuted == nil { s.savedMuted = current.muted }
            }
            try audio.mute()
            Log.info("muted (was volume \(current.volume), muted \(current.muted))")
        } catch {
            Log.error("mute on lid close failed: \(error.localizedDescription)")
        }
    }

    private func freeze(_ group: FreezeGroup, docker: Bool, manager: SessionManager) {
        let already = Set(manager.state.frozenPids)
        var candidates: [FrozenProcess] = []
        for pid in group.pids where !already.contains(pid) {
            guard let identity = group.identities[pid] else {
                Log.error("freeze: no start identity for pid \(pid) of \(group.name); left running")
                continue
            }
            candidates.append(FrozenProcess(pid: pid, identity: identity))
        }
        guard !candidates.isEmpty else { return }
        let candidatePids = Set(candidates.map(\.pid))
        // Journal first, without identity. Neither the app nor backstop.sh
        // ever signals an entry without identity, so until the kernel has
        // said which pids Insomnia itself stopped, the journal claims none
        // of them: a pid somebody else stopped, which the SIGSTOP below
        // skips, cannot be resumed from this entry wherever the app dies.
        // If this write fails nothing is signaled.
        let provisional = candidates.map { FrozenProcess(pid: $0.pid, identity: nil) }
        // Whether this freeze is the one that sets the Docker flag, so an
        // undo below clears only a flag it set.
        let setsDockerFlag = docker && !manager.effectiveState.dockerFrozen
        do {
            try manager.journal { s in
                s.frozenProcesses.append(contentsOf: provisional)
                if docker { s.dockerFrozen = true }
            }
        } catch {
            manager.fail("lid close: could not journal the freeze of \(group.name) (\(group.bundleId)): \(error.localizedDescription); its \(candidates.count) pid(s) were left running")
            return
        }
        let report = freezer.suspend(candidates, expectedParents: group.expectedParents)
        // One write promotes the stops Insomnia made: they gain their
        // identity (start time to the microsecond, boot session) and become
        // resumable. Skipped pids (already stopped, gone, reparented,
        // reused) leave. If the app dies before this write, the stopped
        // pids keep entries without identity and are reported for a person
        // to check instead of being resumed.
        let suspended = Set(report.suspended)
        let confirmed = candidates.filter { suspended.contains($0.pid) }
        do {
            try manager.journal { s in
                s.frozenProcesses.removeAll { candidatePids.contains($0.pid) }
                s.frozenProcesses.append(contentsOf: confirmed)
                if docker, confirmed.isEmpty { s.dockerFrozen = false }
            }
        } catch {
            // Nothing on disk can resume these stops, but this run still
            // knows they are Insomnia's: undo them now. cancelStops checks
            // each identity again and sends SIGCONT even to a process that
            // does not show as stopped yet, since its SIGSTOP may still be
            // pending; resume would call that one running and skip it,
            // leaving it to stop a moment later with nothing to resume it.
            let undo = freezer.cancelStops(confirmed)
            let stuck = undo.failed + undo.unverifiable + undo.unobserved
            // Every provisional entry but the stuck ones now names a pid
            // that runs: resumed, gone, or never stopped by this freeze.
            // They leave the journal, and so does a Docker flag this
            // freeze set, unless part of Docker is still stopped. If the
            // disk refuses that write too, the status leaves them out
            // until a later write takes them off. The stuck ones stay
            // without identity, are never signaled, and lid open reports
            // them if they are still stopped.
            manager.clearUndoneFreeze(.init(
                pids: candidatePids.subtracting(stuck),
                docker: setsDockerFlag && stuck.isEmpty
            ))
            let outcome = stuck.isEmpty
                ? "so this freeze of \(group.name) is undone"
                : "and pid(s) \(stuck.map(String.init).joined(separator: ", ")) may still be stopped; they stay journaled without identity, so Insomnia will not resume them, and lid open reports the ones still stopped"
            manager.fail("lid close: could not confirm the freeze of \(group.name) (\(group.bundleId)) in the journal: \(error.localizedDescription); resumed \(undo.resumed.count) of the \(confirmed.count) pid(s) it had just stopped, \(outcome)")
            return
        }
        Log.info("froze \(group.name) (\(report.suspended.count) pid(s), \(report.skipped.count) skipped)")
    }
}
