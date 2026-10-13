// Standalone smoke checks for machines with Command Line Tools but no XCTest.
// Links the real debug objects; system effects are injected, never executed.
import AppKit
import Darwin
import Foundation
import SwiftUI
@testable import Insomnia

private struct CheckFailure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
private actor Gate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        for observer in observers { observer.resume() }
        observers = []
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
private actor Power: SleepGuarding {
    var disabled = false
    var low = false
    var gate: Gate?
    var failRestore = false
    func setGate(_ value: Gate?) { gate = value }
    func setFailRestore(_ value: Bool) { failRestore = value }
    func setSleepDisabled(_ value: Bool) async throws {
        if value { await gate?.wait() }
        if !value && failRestore { throw CheckFailure(message: "injected sleep restoration failure") }
        disabled = value
    }
    func isSleepDisabled() -> Bool { disabled }
    func setLowPowerMode(_ value: Bool) { low = value }
    func isLowPowerModeOn() -> Bool { low }
}
private actor Backstop: BackstopScheduling {
    var fails = false
    var gate: Gate?
    func setFails() { fails = true }
    func setGate(_ value: Gate?) { gate = value }
    func arm() async throws {
        await gate?.wait()
        if fails { throw CheckFailure(message: "injected backstop failure") }
    }
}
private struct NoSignals: ProcessSignaling {
    func suspend(_ processes: [FrozenProcess], expectedParents: [Int32: Int32]) -> SuspendReport {
        precondition(processes.isEmpty); return SuspendReport()
    }
    func resume(_ processes: [FrozenProcess]) -> ResumeReport { precondition(processes.isEmpty); return ResumeReport() }
    func cancelStops(_ processes: [FrozenProcess]) -> ResumeReport { precondition(processes.isEmpty); return ResumeReport() }
}
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(now: Date = Date().addingTimeInterval(3600)) { value = now }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@main
struct AgentAutoSmoke {
    @MainActor
    static func main() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment[Paths.environmentKey], rootPath.hasPrefix("/private/tmp/") || rootPath.hasPrefix("/tmp/") else {
            throw CheckFailure(message: "Run through check-agent-auto.sh with its isolated INSOMNIA_HOME")
        }
        let paths = Paths.fromEnvironment()
        let api = AgentActivity(paths: paths)
        let now = Date()
        let identity = ProcessIdentity(startedAt: 42, startedAtMicros: 12, bootSession: "smoke-boot")
        let live: @Sendable (Int32) -> ProcessLookup = { _ in .present(ProcessSignalState(ppid: 1, stopped: false, identity: identity)) }
        let job = try api.begin(name: "Codex smoke job", pid: 4242, now: now, uptime: 100, lookup: live)
        try api.heartbeat(job.id, now: now.addingTimeInterval(15), uptime: 115, lookup: live)
        let refreshed = try api.read(job.id)
        try check(refreshed.deadline == job.deadline, "heartbeat changed hard deadline")
        try check(api.snapshot(now: now.addingTimeInterval(89), uptime: 189, lookup: live).active.count == 1, "idle work prematurely completed")
        try check(api.snapshot(now: now.addingTimeInterval(105), uptime: 205, lookup: live).active.isEmpty, "disconnected job did not expire")
        do {
            try api.heartbeat(job.id, now: now.addingTimeInterval(105), uptime: 205, lookup: live)
            throw CheckFailure(message: "expired lease was revived")
        } catch is AgentActivity.ActivityError { }
        try check(job.inactiveReason(at: now, uptime: 100, lookup: { _ in .absent }) != nil, "owner exit not detected")
        try check(job.inactiveReason(at: now, uptime: 100, lookup: { _ in .unreadable(EPERM) }) != nil, "unverified owner kept awake")
        try check(job.inactiveReason(at: now, uptime: 190, lookup: live) != nil, "wall-clock rollback defeated lease")
        var stuck = job
        stuck.heartbeatUptime = 100 + AgentJob.maximumSeconds
        try check(stuck.inactiveReason(at: now, uptime: stuck.heartbeatUptime, lookup: live) == "8-hour safety limit reached", "monotonic hard cap failed")
        let link = UUID()
        try FileManager.default.createSymbolicLink(at: api.file(link), withDestinationURL: api.file(job.id))
        do { _ = try api.read(link); throw CheckFailure(message: "symlink accepted") }
        catch is AgentActivity.ActivityError { }
        let fifo = UUID()
        try check(mkfifo(api.file(fifo).path, 0o600) == 0, "FIFO fixture failed")
        do { _ = try api.read(fifo); throw CheckFailure(message: "FIFO accepted") }
        catch is AgentActivity.ActivityError { }
        try api.finish(job.id)
        try api.finish(job.id)
        for _ in 0..<16 {
            let race = try api.begin(name: "finish race", pid: 4242, now: now, uptime: 100, lookup: live)
            let renewal = Task.detached {
                try? api.heartbeat(race.id, now: now, uptime: 100, lookup: live)
            }
            try api.finish(race.id)
            _ = await renewal.value
            try check(!FileManager.default.fileExists(atPath: api.file(race.id).path), "racing heartbeat resurrected completed work")
        }
        try check(AgentActivityCommand.run(["--agent", "heartbeat", "../../state.json"], paths: paths)?.status == 2, "invalid CLI token accepted")
        print("PASS activity: idle, heartbeat, finish, disconnect, owner exit, clock rollback, hard cap, symlink/FIFO, concurrent finish, invalid CLI")

        let clock = Clock()
        let power = Power()
        let backstop = Backstop()
        let manager = SessionManager(paths: paths, sleepGuard: power, processControl: NoSignals(), backstop: backstop,
                                     clamshell: { false }, clock: { clock.now })
        let auto = AgentAutoController(manager: manager, clock: { clock.now }, pollInterval: nil)
        manager.agentAuto = auto
        await auto.setEnabled(true)
        try check(!manager.isActive, "idle Auto started a hold")
        let off = await power.isSleepDisabled()
        try check(!off, "idle Auto changed power")
        var work = AgentJob(id: UUID(), name: "Claude Code turn", pid: 4242, identity: identity,
                            startedAt: clock.now, deadline: clock.now.addingTimeInterval(8 * 3600), heartbeatAt: clock.now,
                            startedUptime: 100, heartbeatUptime: 100)
        let other = AgentJob(id: UUID(), name: "Codex turn", pid: 4242, identity: identity,
                             startedAt: clock.now, deadline: clock.now.addingTimeInterval(8 * 3600), heartbeatAt: clock.now,
                             startedUptime: 100, heartbeatUptime: 100)
        await auto.poll(snapshot: AgentSnapshot(active: [work, other]))
        try check(manager.session?.agentAuto == true, "Auto did not start")
        let persisted = try manager.store.loadSession()
        try check(persisted?.agentAuto == true, "Auto not journaled")
        let on = await power.isSleepDisabled()
        try check(on, "active job did not hold sleep")
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        try check(manager.isActive, "one completed job ended other work")
        clock.advance(15); work.heartbeatAt = clock.now
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        try check(manager.session?.endsAt == clock.now.addingTimeInterval(90), "lease not renewed")
        let deadline = manager.session?.endsAt
        await manager.extend(by: 3600)
        try check(manager.session?.endsAt == deadline, "manual extension changed Auto")
        let items = StatusItemController.menuItems(manager: manager, status: PlaceholderStatus())
        try check(items.contains { $0.title.contains("Claude Code turn") && $0.title.contains("4242") }, "job missing from menu")
        await auto.poll(snapshot: AgentSnapshot())
        try check(!manager.isActive && auto.enabled, "completion did not release hold and remain armed")
        work.heartbeatAt = clock.now.addingTimeInterval(-85)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        try check(manager.session?.endsAt == clock.now.addingTimeInterval(5), "short lease clamped to a minute")
        manager.config.endFloor = 0
        manager.config.thermalRules = false
        try check(manager.floorConfig.endFloor == 10 && manager.floorConfig.thermalRules, "Auto safety was disabled by timed-session settings")
        await FloorRuleDriver(manager: manager, notifier: RecordingNotifier()).run(battery: .percent(9), isCharging: false, thermal: .nominal, lidClosed: true)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        try check(!auto.enabled && !manager.isActive, "battery floor restarted outstanding work")
        print("PASS Auto: idle, multiple jobs, journal, renewal, short leases, completion, UI, battery-floor latch")

        for reason in [EndReason.user, .thermalCritical, .batteryUnreadable, .quit, .timer] {
            // A new manager also resets quitRequested for this isolated case.
            let m = SessionManager(paths: paths, sleepGuard: power, processControl: NoSignals(), backstop: backstop,
                                   clamshell: { false }, clock: { clock.now })
            let controller = AgentAutoController(manager: m, clock: { clock.now }, pollInterval: nil)
            m.agentAuto = controller
            await controller.setEnabled(true)
            work.heartbeatAt = clock.now
            await controller.poll(snapshot: AgentSnapshot(active: [work]))
            await m.end(reason: reason)
            await controller.poll(snapshot: AgentSnapshot(active: [work]))
            try check(!controller.enabled && !m.isActive, "\(reason) failed to disarm Auto")
        }
        await auto.setEnabled(true)
        work.heartbeatAt = clock.now
        let gate = Gate()
        await power.setGate(gate)
        let start = Task { await auto.poll(snapshot: AgentSnapshot(active: [work])) }
        await gate.waitUntilEntered()
        let disable = Task { await auto.setEnabled(false) }
        while auto.enabled { await Task.yield() }
        await gate.release()
        await start.value
        await disable.value
        let raceOff = await power.isSleepDisabled()
        try check(!manager.isActive && !raceOff, "disable during start leaked sleep hold")
        await power.setGate(nil)
        await auto.setEnabled(true)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        let relaunched = SessionManager(paths: paths, sleepGuard: power, processControl: NoSignals(), backstop: backstop,
                                       clamshell: { false }, clock: { clock.now })
        await relaunched.reconcile()
        let recoveredOff = await power.isSleepDisabled()
        try check(!relaunched.isActive && !recoveredOff, "relaunch re-held sleep for old Auto session")
        await auto.setEnabled(false)
        await auto.setEnabled(true)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        clock.advance(15); work.heartbeatAt = clock.now
        await backstop.setFails()
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        let failureOff = await power.isSleepDisabled()
        try check(!auto.enabled && !manager.isActive && !failureOff, "recovery failure did not release and disarm")
        print("PASS safety: enforced Auto floors, manual End, thermal critical, unknown battery, Quit, deadline, start cancellation, relaunch, recovery failure")
        try await checkMenuBarUI(paths: paths)
    }

    /// Optional render evidence for visual review; never activated in normal
    /// checks unless the caller explicitly chooses an output directory.
    @MainActor
    private static func snapshot(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["INSOMNIA_UI_SNAPSHOT_DIR"] else { return }
        let size = host.fittingSize
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = rect
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw CheckFailure(message: "snapshot bitmap unavailable") }
        host.cacheDisplay(in: rect, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure(message: "snapshot PNG unavailable") }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
        window.close()
    }

    @MainActor
    private static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try check(condition(), "UI state did not settle within two seconds")
    }

    @MainActor
    private static func checkMenuBarUI(paths: Paths) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let clock = Clock()
        let power = Power()
        let backstop = Backstop()
        let manager = SessionManager(paths: paths, sleepGuard: power, processControl: NoSignals(), backstop: backstop,
                                     clamshell: { false }, clock: { clock.now })
        let auto = AgentAutoController(manager: manager, clock: { clock.now }, pollInterval: nil)
        manager.agentAuto = auto
        var cues: [SessionSoundCue] = []
        let controller = StatusItemController(manager: manager, status: PlaceholderStatus(), showSettings: {},
                                              clock: { clock.now }, playSessionSound: { cues.append($0) }, captureEvents: false)
        let model = MenuBarModel()
        func root() -> StatusRootView {
            StatusRootView(model: model, manager: manager, onTapIcon: {}, onTapPill: { _ in },
                           onTapCountdown: {}, onWidthChange: { _ in })
        }
        func width() -> CGFloat { StatusItemController.makeHostingView(root()).fittingSize.width }
        func render(_ name: String) throws {
            try snapshot(StatusItemController.makeHostingView(root()), name: name)
            let menu = QuickMenuView(manager: manager, model: model, onPreset: { _ in }, onToggle: {},
                                     onSettings: {}, onDetails: {}, onQuit: {}, onDismiss: {}, animateEntrance: false)
            let host = NSHostingView(rootView: menu)
            try check(host.fittingSize.width == 260, "PR quick-menu width changed")
            try snapshot(host, name: name + "-menu")
        }

        var blinkFrames: [Bool] = []
        var blinkWaits: [Duration] = []
        do {
            try await AutoEyeBlink.run(sleep: { delay in
                blinkWaits.append(delay)
                if blinkWaits.count == 3 { throw CheckFailure(message: "bounded blink fixture complete") }
            }, setOpen: { blinkFrames.append($0) })
        } catch is CheckFailure { }
        try check(blinkFrames == [true, false, true] && blinkWaits.first == .seconds(3), "Auto blink did not rest open before briefly closing/reopening")
        try check(AutoEyeBlink.displayOpen(armed: true, reduceMotion: true, blinkOpen: false, fallbackOpen: false), "Reduce Motion closed armed Auto")
        try check(!AutoEyeBlink.enabled(armed: true, reduceMotion: true), "Auto blink ignored Reduce Motion")

        await controller.reconcileAndEnableDefaultAuto()
        try check(cues == [.activated], "default idle Auto did not play its on cue")
        let navigation = controller.makeStatusRootView()
        let bounce = controller.model.iconBounce
        navigation.onTapIcon()
        navigation.onTapCountdown()
        try check(controller.model.iconBounce == bounce + 2 && auto.enabled && cues == [.activated], "menu navigation changed Auto or played a sound")
        let idlePower = await power.isSleepDisabled()
        try check(auto.enabled && !manager.isActive && !idlePower && model.pendingCountdown == nil, "Auto enable started a timer")
        try check(AutoMenuBarPresentation.current(manager: manager, model: model) == .idle, "armed idle copy")
        let idleWidth = width()
        try check(idleWidth == 32, "Auto added text beside the icon")
        try render("pr63-auto-idle")
        model.autoActionPending = true
        try check(width() == idleWidth && AutoMenuBarPresentation.current(manager: manager, model: model) == .checking, "pending Auto claimed idle or changed width")
        model.autoActionPending = false

        let work = AgentJob(id: UUID(), name: "UI work", pid: 4242,
                            identity: ProcessIdentity(startedAt: 42, startedAtMicros: 12, bootSession: "test"),
                            startedAt: clock.now, deadline: clock.now.addingTimeInterval(8 * 3600), heartbeatAt: clock.now,
                            startedUptime: 100, heartbeatUptime: 100)
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        try await waitFor { controller.model.phase == .running }
        try check(width() == idleWidth, "Auto working copy changed status width")
        model.phase = .running
        try check(width() == 32, "Auto's live lease appeared next to the icon")
        try render("pr63-auto-working")
        let deadline = manager.session?.endsAt
        controller.customExtend()
        controller.startPreset(1800)
        try check(!controller.model.slotsPresent && manager.session?.endsAt == deadline && auto.enabled, "Auto became a timer or extension editor")
        try check(!AutoMenuBarPresentation.timerControlsEnabled(manager: manager, model: model), "Auto work enabled timer presets")
        await auto.poll(snapshot: AgentSnapshot(active: []))
        try check(auto.enabled && !manager.isActive, "job completion disarmed Auto or retained the hold")
        try check(cues == [.activated], "job transitions repeated the mode cue")
        await controller.toggleAuto()
        try check(cues == [.activated, .deactivated], "idle Auto disable did not play its off cue")
        controller.toggleSession()
        try await waitFor { manager.isActive }
        try check(manager.session?.agentAuto == nil, "menu action did not start a default timer after Auto disarm")
        await controller.toggleAuto()
        try check(!auto.enabled && manager.session?.agentAuto == nil, "Auto replaced a running timer")
        controller.toggleSession()
        try await waitFor { !manager.isActive }
        await controller.toggleAuto()
        controller.startPreset(1800)
        try await waitFor { manager.isActive }
        try check(!auto.enabled && manager.session?.agentAuto == nil, "explicit Timer preset did not disarm idle Auto")
        await manager.end(reason: .user)

        await controller.toggleAuto()
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        await manager.end(reason: .thermalCritical)
        model.phase = .idle
        try check(auto.pauseReason == .thermalCritical && width() == idleWidth, "safety pause disappeared or changed width")
        try render("pr63-auto-paused")
        try check(AutoMenuBarPresentation.resolve(enabled: false, autoSessionActive: true, paused: false, restoring: false) == .restoring, "restoration shown as idle")
        await controller.toggleAuto()
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        await power.setFailRestore(true)
        await controller.toggleAuto()
        try check(AutoMenuBarPresentation.current(manager: manager, model: model) == .restoring, "failed restoration claimed idle")
        try check(!AutoMenuBarPresentation.timerControlsEnabled(manager: manager, model: model)
                  && !AutoMenuBarPresentation.autoControlEnabled(manager: manager, model: model), "failed restoration allowed another start")
        try check(width() == idleWidth, "restoration copy changed status width")
        try render("pr63-auto-restoring")
        await power.setFailRestore(false)
        await manager.end(reason: .user)
        await controller.toggleAuto()
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        await power.setFailRestore(true)
        await auto.poll(snapshot: AgentSnapshot(active: []))
        try check(!auto.enabled && auto.pauseReason == .recoveryUnavailable, "delegated restoration failure did not pause Auto")
        try check(manager.pendingEnd == nil && manager.state.sleepDisabledByUs, "delegated-recovery fixture not exercised")
        await auto.poll(snapshot: AgentSnapshot(active: [work]))
        try check(!manager.isActive && AutoMenuBarPresentation.current(manager: manager, model: model) == .restoring, "failed recovery rearmed Auto or claimed idle")
        await power.setFailRestore(false)
        await manager.end(reason: .user)

        let busyPower = Power()
        let busyBackstop = Backstop()
        let busyManager = SessionManager(paths: paths, sleepGuard: busyPower, processControl: NoSignals(), backstop: busyBackstop,
                                         clamshell: { false })
        let busyAuto = AgentAutoController(manager: busyManager, pollInterval: nil)
        busyManager.agentAuto = busyAuto
        let busyController = StatusItemController(manager: busyManager, status: PlaceholderStatus(), showSettings: {}, captureEvents: false)
        let api = AgentActivity(paths: paths)
        let realLease = try api.begin(name: "UI pending-start smoke", pid: getpid())
        let gate = Gate()
        await busyBackstop.setGate(gate)
        let start = Task { await busyController.toggleAuto() }
        await gate.waitUntilEntered()
        try check(busyController.model.autoActionPending && !busyManager.isActive, "pending start claimed a confirmed hold")
        await busyController.toggleAuto()
        busyController.toggleSession()
        busyController.startPreset(1800)
        try check(busyAuto.enabled && busyController.model.pendingCountdown == nil, "repeat actions escaped pending Auto")
        await gate.release()
        await start.value
        try check(busyManager.session?.agentAuto == true && !busyController.model.autoActionPending, "Auto did not settle")
        try api.finish(realLease.id)
        await busyAuto.poll()

        let autonomousGate = Gate()
        await busyBackstop.setGate(autonomousGate)
        let autonomousStart = Task { await busyAuto.poll(snapshot: AgentSnapshot(active: [work])) }
        await autonomousGate.waitUntilEntered()
        try check(!busyManager.isActive && !busyController.model.autoActionPending, "autonomous start did not suspend")
        busyController.startPreset(1800)
        try check(busyAuto.enabled && busyController.model.pendingCountdown == nil, "Timer cancelled agent work being armed")
        let cancel = Task { await busyController.toggleAuto() }
        try await waitFor { !busyAuto.enabled }
        await autonomousGate.release()
        await autonomousStart.value
        await cancel.value
        let cancelOff = await busyPower.isSleepDisabled()
        try check(!busyManager.isActive && !cancelOff, "explicit Disable could not cancel an autonomous start")
        let timerGate = Gate()
        await busyBackstop.setGate(timerGate)
        busyController.startPreset(1800)
        await timerGate.waitUntilEntered()
        try check(busyManager.startingSessionIsAuto == false && busyManager.state.sleepDisabledByUs
                  && !AutoMenuBarPresentation.isRestoring(manager: busyManager), "journaled Timer start misclassified as recovery")
        await busyController.toggleAuto()
        try check(!busyAuto.enabled, "Auto overlapped a pending Timer start")
        await timerGate.release()
        try await waitFor { busyManager.isActive && busyController.model.phase == .running }
        await busyManager.end(reason: .user)
        await busyAuto.setEnabled(true)
        await busyBackstop.setFails()
        await busyAuto.poll(snapshot: AgentSnapshot(active: [work]))
        try check(!busyAuto.enabled && !busyManager.isActive && busyManager.lastError != nil, "failed Auto start was hidden")
        try check(AutoMenuBarPresentation.current(manager: busyManager, model: busyController.model) == .paused, "failed start claimed idle")
        print("PASS PR #63 UI: quick-menu layout, icon-only states, full-speed normal-eye springs, three-second open pause, Reduce Motion, default Auto, mode sounds, menu-only clicks, stable width, Timer isolation, pending actions, autonomous-start cancellation")
    }
}
