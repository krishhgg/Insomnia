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
                await freeze(group, docker: false, manager: manager)
            }

            let dockerGroup = await docker.idleDockerGroup(config: config)
            // An end requested while the probe ran wins: it is queued right
            // behind this transaction and must not find a fresh freeze.
            guard manager.isActive, manager.endTicket == ticket, !Task.isCancelled else { return }
            if let dockerGroup {
                // The idle answer above is already stale by the time the
                // journal write is done, so Docker is asked once more right
                // before its SIGSTOP; busy, a failed probe or a timeout
                // leaves it running. The end check repeats for the same
                // reason as above.
                await freeze(dockerGroup, docker: true, manager: manager) { [docker] in
                    guard await docker.isStillIdle() else { return false }
                    guard manager.isActive, manager.endTicket == ticket, !Task.isCancelled else {
                        Log.info("docker rule: session ending during the second check, Docker left alone")
                        return false
                    }
                    return true
                }
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

    /// `beforeSignal`, when given, runs after the journal write and right
    /// before the SIGSTOP; false means leave the group running and take its
    /// entries out of the journal again.
    private func freeze(_ group: FreezeGroup, docker: Bool, manager: SessionManager, beforeSignal: (() async -> Bool)? = nil) async {
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
        // Journal first, but without identity: an entry with no identity is
        // never resumed by the app or backstop.sh, so until the kernel has
        // said which pids it actually stopped the journal claims none of
        // them. Identity is added below only for the confirmed stops.
        let provisional = candidates.map { FrozenProcess(pid: $0.pid, identity: nil) }
        do {
            try manager.journal { s in
                s.frozenProcesses.append(contentsOf: provisional)
                if docker { s.dockerFrozen = true }
            }
        } catch {
            Log.error("could not journal freeze of \(group.bundleId): \(error.localizedDescription); left running")
            return
        }
        if let beforeSignal, await !beforeSignal() {
            do {
                try manager.journal { s in
                    s.frozenProcesses.removeAll { candidatePids.contains($0.pid) }
                    if docker { s.dockerFrozen = false }
                }
            } catch {
                // Entries without identity are never signaled, and a running
                // pid is cleared as gone on the next resume.
                Log.error("could not drop the unsignaled entries of \(group.bundleId) from the journal: \(error.localizedDescription); \(candidates.count) pid(s) stay journaled without identity")
            }
            Log.info("\(group.name) left running: the check before the signal said no")
            return
        }
        let report = freezer.suspend(candidates, expectedParents: group.expectedParents)
        // One write replaces the provisional entries: confirmed stops gain
        // their identity, skipped pids (already stopped, gone, reparented,
        // reused) leave. If this write fails the provisional entries stay
        // on disk, still without identity, so nothing later resumes them;
        // any that really are stopped are reported for manual recovery.
        let suspended = Set(report.suspended)
        let confirmed = candidates.filter { suspended.contains($0.pid) }
        do {
            try manager.journal { s in
                s.frozenProcesses.removeAll { candidatePids.contains($0.pid) }
                s.frozenProcesses.append(contentsOf: confirmed)
                if docker, confirmed.isEmpty { s.dockerFrozen = false }
            }
        } catch {
            Log.error("could not confirm freeze of \(group.bundleId) in the journal: \(error.localizedDescription); \(candidates.count) pid(s) stay journaled without identity and will not be resumed automatically")
        }
        Log.info("froze \(group.name) (\(report.suspended.count) pid(s), \(report.skipped.count) skipped)")
    }
}
