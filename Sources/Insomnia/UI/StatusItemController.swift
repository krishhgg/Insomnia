import AppKit
import SwiftUI

/// Owns the NSStatusItem and its popover, and drives every state change of
/// the menu bar UI.
///
/// The status bar button hosts a SwiftUI view (the eye, and a short
/// countdown while a session runs) and the item's length is written once
/// per width that view reports (`StatusWidthWriter`). A click on the item,
/// left or right, toggles one NSPopover hanging from it
/// (`StatusPopoverView`), which holds time entry, the status rows and
/// warnings, Settings and Quit. Opening it activates the app so its text
/// fields take typing; Esc, a click outside, switching apps or Spaces
/// closes it.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    /// Builds the width writer over `apply` (which sets the item's length);
    /// tests inject one that records every write.
    typealias WidthWriterFactory = @MainActor (_ apply: @escaping (CGFloat) -> Void) -> StatusWidthWriter

    let manager: SessionManager
    let status: any StatusSource
    let model = MenuBarModel()
    let reminder = ReminderScheduler()
    /// Opens the settings window. Injected because the window is owned by the
    /// app delegate, which outlives any one status item.
    private let showSettings: () -> Void
    private let makeWidthWriter: WidthWriterFactory?
    /// Asks before a browser is quit for a relaunch; true means go ahead.
    /// Injected so tests never see the NSAlert.
    private let confirmRelaunch: @MainActor (String) -> Bool
    /// What the projected countdown reads the time from. Tests inject the
    /// manager's fake clock so the text does not depend on when the tick
    /// happens to run.
    private let clock: @Sendable () -> Date

    private let statusItem: NSStatusItem
    private var hostingView: StatusHostingView?
    private var widthWriter: StatusWidthWriter?
    /// Built on first open.
    private(set) var popover: NSPopover?
    /// What the popover hangs from; nil means the item's button. Tests
    /// point it at a plain window's view, since a status item in a test
    /// process may never be on screen for a popover to hang from.
    var popoverAnchor: NSView?
    /// What closes the open popover besides the item: mouse-downs in other
    /// apps and in this app's other windows, the app going inactive, a
    /// Space change. Installed on open, removed on close.
    private var dismissMonitors: [Any] = []
    private var dismissObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Windows taken off screen while the app activates for the popover,
    /// each with the window it goes back under (`activateLeavingWindowsInPlace`).
    private var parkedWindows: [(window: NSWindow, above: Int)] = []
    private var parkObserver: NSObjectProtocol?
    /// Counts opens, so a start that completes after the popover was closed
    /// and opened again does not close the new one.
    private var popoverOpenings = 0

    /// 1 Hz redraw of the projected countdown while a start is pending, so
    /// it does not sit frozen for the seconds the recovery agent and pmset
    /// take and then jump on confirmation.
    private var pendingTick: Timer?
    var pendingTickArmed: Bool { pendingTick != nil }
    /// Identifies the run whose completion is allowed to touch the UI. The
    /// manager answers in order, so an older completion can land while a
    /// newer run is still pending (extend, then extend again); it must not
    /// clear what the newer one is showing.
    private var startGeneration = 0
    /// The width the status item is heading for.
    private(set) var widthTarget: CGFloat = 0
    /// How many times the width target has changed. The layout is meant to
    /// change once when a session starts and once when it ends (and, at
    /// minute resolution, rarely in between); tests pin that.
    private(set) var widthTargetChangeCount = 0
    /// The width the hosting view is laid out at (the widest content it has held).
    var hostWidth: CGFloat { hostingView?.frame.width ?? 0 }

    /// Autosave name so macOS remembers where the user drags the item.
    static let autosaveName = "insomnia.status"

    init(
        manager: SessionManager,
        status: any StatusSource,
        showSettings: @escaping () -> Void,
        makeWidthWriter: WidthWriterFactory? = nil,
        confirmRelaunch: (@MainActor (String) -> Bool)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manager = manager
        self.status = status
        self.showSettings = showSettings
        self.makeWidthWriter = makeWidthWriter
        self.confirmRelaunch = confirmRelaunch ?? Self.askBeforeRelaunch
        self.clock = clock
        Self.seedPreferredPositionIfNeeded()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = [.terminationOnRemoval]
        super.init()
        installHostingView()
        observeManager()
    }

    // MARK: Status item

    /// New status items are appended at the left of the existing group. On a
    /// crowded menu bar (notch Macs) that lands in the hidden overflow, so the
    /// item exists but is never seen. Seed a position near the right end the
    /// first time only; after that macOS keeps whatever the user drags to.
    static func seedPreferredPositionIfNeeded(defaults: UserDefaults = .standard) {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(40, forKey: key)
    }

    private func installHostingView() {
        guard let button = statusItem.button else { return }
        let apply: (CGFloat) -> Void = { [statusItem] width in statusItem.length = width }
        widthWriter = makeWidthWriter?(apply) ?? StatusWidthWriter(apply: apply)
        let root = StatusRootView(
            model: model,
            manager: manager,
            onWidthChange: { [weak self] w in self?.retargetWidth(w) }
        )
        let host = Self.makeHostingView(root)
        host.translatesAutoresizingMaskIntoConstraints = true
        // The height follows the button; the width is set from the layout
        // (`retargetWidth`) and never from the button, whose width is the
        // item's length: the content is laid out once at its own width,
        // anchored at the leading edge, and the item's window reveals or
        // clips it.
        host.autoresizingMask = [.height]
        host.frame = NSRect(x: 0, y: 0, width: 0, height: button.bounds.height)
        button.addSubview(host)
        button.title = ""
        button.image = nil
        // The button takes the clicks (the host lets them through), on
        // either mouse button, and toggles the popover on mouse-down like
        // the system's own items.
        button.target = self
        button.action = #selector(buttonClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        hostingView = host
        // The layout may already have reported through `onGeometryChange`
        // while the host was measured above, before `hostingView` was set,
        // in which case `retargetWidth` treats the fitting width as a
        // repeat and never grows the frame: size the host here.
        host.frame.size.width = max(widthTarget, host.fittingSize.width.rounded(.up), StatusRootView.width)
        retargetWidth(host.fittingSize.width)
        logFrames("installed")
    }

    /// Centralizes the AppKit/SwiftUI boundary so its sizing contract can be
    /// regression-tested independently of a live menu bar.
    static func makeHostingView(_ root: StatusRootView) -> StatusHostingView {
        let host = StatusHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        return host
    }

    /// Where the item sits on screen; used to find it for screenshots.
    func logFrames(_ tag: String) {
        guard let button, let host = hostingView else { return }
        let win = button.window.map { NSStringFromRect($0.frame) } ?? "?"
        Log.info("status item \(tag): window \(win) button \(NSStringFromRect(button.frame)) host \(NSStringFromRect(host.frame)) fitting \(NSStringFromSize(host.fittingSize)) length \(statusItem.length)")
    }

    /// Set the item's length to `width`, once; a repeat of the current
    /// target is ignored. The host only ever grows: it is laid out at the
    /// widest content it has held, so a countdown on its way out has room
    /// to finish its transition when the length narrows over it.
    private func retargetWidth(_ width: CGFloat) {
        let w = max(width.rounded(.up), StatusRootView.width)
        guard w != widthTarget else { return }
        widthTarget = w
        widthTargetChangeCount += 1
        if let host = hostingView, host.frame.width < w {
            host.frame.size.width = w
        }
        widthWriter?.write(w)
    }

    private var button: NSStatusBarButton? { statusItem.button }

    // MARK: Manager observation

    /// Sessions can start or end without the UI (reconcile at launch, the
    /// deadline timer, the battery floor). Keep the phase and the reminder
    /// in step with the manager.
    private func observeManager() {
        withObservationTracking {
            _ = manager.session
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.managerChanged()
                self.observeManager()
            }
        }
    }

    private func managerChanged() {
        reminder.sync(endsAt: manager.session?.endsAt)
        guard let next = Self.phase(forActive: manager.isActive, phase: model.phase) else { return }
        stopPendingTick()
        // The session can land a hop before its countdown text does; the
        // projection stays up until the live text is there to replace it
        // (the run's completion clears it otherwise).
        if !manager.remainingText.isEmpty {
            model.pendingCountdown = nil
            model.pendingProjection = nil
        }
        if next == .running { model.startError = nil }
        model.phase = next
    }

    /// The phase a manager-side change puts the UI in, or nil to leave it
    /// alone. Pure so the transitions can be checked without a status item.
    static func phase(forActive active: Bool, phase: MenuBarModel.Phase) -> MenuBarModel.Phase? {
        switch (active, phase) {
        case (true, .idle), (true, .starting):
            // A pending start is confirmed the moment the session lands. A
            // start that stays inactive is the controller's to report: the
            // manager does not change under a refusal.
            .running
        case (false, .running):
            .idle
        default:
            nil
        }
    }

    // MARK: Popover

    @objc private func buttonClicked() {
        togglePopover()
    }

    /// Every click on the item flips the popover, however fast they come.
    /// `model.popoverShown` is the one source of truth and changes the
    /// moment a click lands; nothing is read back from NSPopover, whose own
    /// state trails its animations.
    func togglePopover() {
        if model.popoverShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    /// Open the popover on what the machine is doing now, with empty fields
    /// (or, after a refused start, the value that was refused), and the
    /// cursor in Hours.
    func openPopover() {
        guard !model.popoverShown else { return }
        // The lid, the battery and the watts are read right here; the SSID
        // and the throttled browser list are awaited, and fill in as the
        // scan lands, since the popover follows the status source.
        status.refreshInstant()
        status.refreshOnDemand()
        // Same for the foreign-sleep line: re-read the bit now.
        Task { await manager.recheckForeignSleep() }
        if model.startError == nil {
            model.clearFields()
        }
        // The time buttons by default; the fields stay out only to show a
        // refused value.
        model.customShown = !model.texts.isEmpty
        model.popoverShown = true
        model.focusRequest += 1
        popoverOpenings += 1
        let popover = self.popover ?? makePopover()
        self.popover = popover
        guard let anchor = popoverAnchor ?? button, anchor.window != nil else { return }
        // A menu bar app is never frontmost by itself; without this the
        // fields would not take typing.
        activateLeavingWindowsInPlace()
        button?.highlight(true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        watchForDismissal()
    }

    /// Activate the app without bringing its other windows forward.
    /// Activation raises an app's windows, so a Settings window the user had
    /// left behind other apps came back every time the popover opened. Each
    /// window another app's window covers is taken off screen for the
    /// activation and put back just where it was in the stack.
    private func activateLeavingWindowsInPlace() {
        guard !NSApp.isActive else { return }
        let ours = NSApp.windows.filter { $0.isVisible && $0.level == .normal && $0 !== popover?.contentViewController?.view.window }
        let stack = Self.onScreenWindowStack()
        let placements = Self.coveredWindows(stack: stack, ours: Set(ours.map(\.windowNumber)))
        restoreParkedWindows()
        parkedWindows = ours.compactMap { window in placements[window.windowNumber].map { (window, $0) } }
        parkedWindows.forEach { $0.window.orderOut(nil) }
        NSApp.activate(ignoringOtherApps: true)
        guard !parkedWindows.isEmpty else { return }
        // Back once activation is done (so it cannot raise them), or soon
        // anyway if the system turns the activation down.
        parkObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreParkedWindows() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.restoreParkedWindows() }
        }
    }

    /// Put the windows `activateLeavingWindowsInPlace` took off screen back
    /// under the window that was just above each. Once per activation.
    private func restoreParkedWindows() {
        if let parkObserver { NotificationCenter.default.removeObserver(parkObserver) }
        parkObserver = nil
        let parked = parkedWindows
        parkedWindows = []
        for (window, above) in parked {
            window.order(.below, relativeTo: above)
        }
    }

    /// The on-screen windows of the normal level, front to back, as window
    /// numbers and owning process ids.
    private nonisolated static func onScreenWindowStack() -> [(number: Int, pid: pid_t)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return (number, pid)
        }
    }

    /// Which of `ours` sit under another app's window in `stack` (front to
    /// back), each with the window just above it, to be put back under.
    /// One of ours with nothing of another app's above it is on top already
    /// and is left out: activation cannot raise it any further.
    nonisolated static func coveredWindows(stack: [(number: Int, pid: pid_t)], ours: Set<Int>) -> [Int: Int] {
        var placements: [Int: Int] = [:]
        var otherAppAbove = false
        var previous: Int?
        for entry in stack {
            if ours.contains(entry.number) {
                if otherAppAbove, let previous { placements[entry.number] = previous }
            } else {
                otherAppAbove = true
            }
            previous = entry.number
        }
        return placements
    }

    /// Close at once. The popover never animates closed: during AppKit's
    /// close animation (about half a second) the popover stays on screen and
    /// a show is put off until it ends, so a quick click after a close was
    /// swallowed and the popover fell out of step with the clicks.
    func closePopover() {
        guard model.popoverShown else { return }
        model.popoverShown = false
        stopWatchingForDismissal()
        button?.highlight(false)
        popover?.close()
    }

    /// The popover is `.applicationDefined`, so AppKit never closes it on
    /// its own; this does what `.transient` did, without the race.
    ///
    /// On current macOS the menu bar is drawn by another process, so a click
    /// on the item reaches this app twice: first as a click outside it (a
    /// global mouse-down, and the app resigning active), then as the item's
    /// action. A transient popover closed on the first and the action opened
    /// it again, so a click meant to close did nothing visible and the
    /// popover fell out of step. Anything on the item itself is left to the
    /// action (`dismissUnlessOnItem`).
    private func watchForDismissal() {
        stopWatchingForDismissal()
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps, where the item's own click shows up too. A
        // global event's location is in screen coordinates.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            let point = event.locationInWindow
            MainActor.assumeIsolated { self?.dismissUnlessOnItem(at: point) }
        }) {
            dismissMonitors.append(monitor)
        }
        // Clicks in this app's other windows (Settings). The item's own click
        // is left to its action, which toggles.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.clickedInApp(window: event.window) }
            return event
        }) {
            dismissMonitors.append(monitor)
        }
        // Switching apps; a click on the item makes the app resign active
        // too, before its action arrives.
        let center = NotificationCenter.default
        dismissObservers.append((center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissUnlessOnItem(at: NSEvent.mouseLocation) }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        dismissObservers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }))
    }

    private func stopWatchingForDismissal() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        for (center, observer) in dismissObservers {
            center.removeObserver(observer)
        }
        dismissObservers.removeAll()
    }

    /// Close the popover for something that happened at `point` (screen
    /// coordinates) outside this app, unless that is on the item: the
    /// item's action is on its way and toggles.
    func dismissUnlessOnItem(at point: NSPoint) {
        guard model.popoverShown else { return }
        if let item = (popoverAnchor ?? button)?.window?.frame, item.contains(point) { return }
        closePopover()
    }

    /// A mouse-down somewhere in this app while the popover is open: one in
    /// another of its windows closes the popover, as a click outside a
    /// transient popover did. One in the popover is its own; one on the
    /// item is the item's click, which its action handles.
    func clickedInApp(window: NSWindow?) {
        guard model.popoverShown else { return }
        let own = [popover?.contentViewController?.view.window, button?.window, popoverAnchor?.window]
        if let window, own.contains(where: { $0 === window }) { return }
        closePopover()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        // Closed by this controller only (`watchForDismissal`), and never
        // animated: both keep the popover in step with every click.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: makePopoverView())
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        return popover
    }

    /// The popover's content over this controller. Separate so a test can
    /// lay it out without a menu bar.
    func makePopoverView() -> StatusPopoverView {
        StatusPopoverView(
            model: model,
            manager: manager,
            items: { [weak self] in
                guard let self else { return [] }
                return Self.statusItems(manager: self.manager, status: self.status, startError: self.model.startError, starting: self.model.phase == .starting)
            },
            actions: StatusPopoverView.Actions(
                commit: { [weak self] in self?.commit() },
                start: { [weak self] in self?.startPreset($0) },
                extend: { [weak self] in self?.extendBy($0) },
                holdToEnd: { [weak self] in self?.holdToEnd() },
                relaunch: { [weak self] in self?.relaunchBrowser($0) },
                stopWaiting: { [weak self] in self?.stopWaitingForOutput($0) },
                openSettings: { [weak self] in self?.openSettings() },
                quit: { NSApplication.shared.terminate(nil) },
                close: { [weak self] in self?.closePopover() }
            ),
            now: { [clock] in clock() }
        )
    }

    // NSPopoverDelegate: should AppKit ever close the popover itself, keep
    // the model in step.
    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard model.popoverShown, popover?.isShown == false else { return }
            model.popoverShown = false
            stopWatchingForDismissal()
            button?.highlight(false)
        }
    }

    // MARK: Commit

    /// The mode the popover is in: a live session is extended, otherwise a
    /// new one starts.
    var mode: MenuBarModel.Mode { manager.isActive ? .extend : .start }

    /// Enter or Start/Extend: run with the typed value. With nothing typed
    /// it starts the default preset; while extending it shakes instead, as
    /// it does for a value out of range. Ignored while a start is pending.
    func commit() {
        guard model.phase != .starting else { return }
        let input = model.input
        let typed = DurationInput.Field.allCases.allSatisfy(input.isValid) ? input.total : nil
        if typed == nil, !input.isEmpty {
            // Something is typed but it is not a duration: never fall back
            // to the default preset over it.
            model.rejectBounce += 1
            return
        }
        switch MenuBarModel.commitAction(mode: mode, typed: typed, defaultPreset: manager.config.defaultPreset) {
        case let .run(duration):
            run(mode: mode, duration: duration)
        case .reject:
            model.rejectBounce += 1
        }
    }

    /// A preset chip: start that long at once.
    func startPreset(_ duration: TimeInterval) {
        guard model.phase != .starting, !manager.isActive, duration > 0 else { return }
        run(mode: .start, duration: duration)
    }

    /// An extend chip: extend the live session at once.
    func extendBy(_ duration: TimeInterval) {
        guard model.phase != .starting, manager.isActive, duration > 0 else { return }
        run(mode: .extend, duration: duration)
    }

    private func run(mode: MenuBarModel.Mode, duration: TimeInterval) {
        startGeneration += 1
        let generation = startGeneration
        let opening = popoverOpenings
        // What the fields held when this was submitted. During an extend
        // they stay editable; a new time typed before it finishes is kept.
        let typed = model.texts
        model.startError = nil
        let now = clock()
        if mode == .extend, let s = manager.session {
            // The session is live, so the countdown stays up. Project the
            // session so the countdown already reads the new end while the
            // manager catches up (pmset takes a moment).
            let projected = SessionMath.extended(s, by: duration, now: now, maxDuration: manager.config.maxDuration)
            model.pendingProjection = nil
            model.pendingCountdown = SessionMath.formatRemaining(projected.remaining(at: now))
        } else {
            // No session yet: the manager has to arm the recovery agent and
            // disable sleep first, and either can take seconds or refuse. Show
            // the countdown the session will read the moment it is confirmed,
            // ticking meanwhile; the phase stays pending, so nothing that acts
            // on a session is offered until then.
            let projection = MenuBarModel.projectedStart(now: now, duration: duration, maxDuration: manager.config.maxDuration)
            model.pendingProjection = projection
            model.pendingCountdown = projection.shortCountdown(at: now)
        }
        model.phase = mode == .extend && manager.isActive ? .running : .starting
        if model.phase == .starting { armPendingTick() } else { stopPendingTick() }

        Task { @MainActor in
            switch mode {
            case .start: await manager.start(duration: duration)
            case .extend: await manager.extend(by: duration)
            }
            guard generation == startGeneration else { return }
            stopPendingTick()
            model.pendingCountdown = nil
            model.pendingProjection = nil
            if manager.isActive {
                // Normally `managerChanged` has already done this; a session
                // that was live before the start (extend, or a start refused
                // as "already active") never changes and never fires it.
                if model.phase == .starting {
                    model.phase = .running
                }
                if mode == .start || manager.lastError == nil {
                    // Done: the value is spent and the fields are put away.
                    // The popover stays open on the running session; the
                    // user closes it. Unless the popover was closed and
                    // opened again meanwhile, or the fields were edited
                    // since: either way they hold something typed since.
                    if opening == popoverOpenings, model.texts == typed {
                        model.clearFields()
                        model.customShown = false
                    }
                }
            } else if model.phase == .starting {
                // Start refused: the typed value stays in the fields, and the
                // popover says why in its own words.
                model.phase = .idle
                model.startError = Self.startErrorText(manager.lastError)
            }
        }
    }

    /// What the popover says about a refused start: the manager's reason,
    /// or a short line when it left none.
    static func startErrorText(_ lastError: String?) -> String {
        guard let lastError, !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MenuBarModel.startFailedText
        }
        return lastError
    }

    // MARK: Projected countdown

    /// 1 Hz redraw of the projected countdown, aligned to whole wall-clock
    /// seconds like the manager's live one. Runs only while the phase is
    /// `.starting`; stopped on confirmation or refusal. The timer runs on the
    /// real run loop, so it is scheduled from `Date()`; the text it draws
    /// reads `clock`.
    private func armPendingTick() {
        stopPendingTick()
        let first = SessionMath.nextSecondBoundary(after: Date())
        let timer = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPendingCountdown() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        pendingTick = timer
    }

    private func stopPendingTick() {
        pendingTick?.invalidate()
        pendingTick = nil
    }

    private func refreshPendingCountdown() {
        guard model.phase == .starting, let projection = model.pendingProjection else {
            stopPendingTick()
            return
        }
        model.pendingCountdown = projection.shortCountdown(at: clock())
    }

    // MARK: Session actions

    /// The popover's hold-to-end ring completed. Ignored while a start is
    /// still in flight.
    func holdToEnd() {
        guard manager.isActive else { return }
        Task { @MainActor in
            await manager.end(reason: .user)
        }
    }

    // MARK: Status rows

    /// The popover's status rows from what the session and the status
    /// source report now. Static, so a test can check them without a
    /// status item.
    /// `startError` is the refusal the popover shows under the fields, so
    /// the same text is not repeated as a warning row.
    /// `starting` is a start in flight: the manager records sleep as held
    /// before the session itself lands, so for those moments a hold with no
    /// session is the start on its way, not one left behind, and the
    /// "still held" warning is not shown.
    static func statusItems(manager: SessionManager, status: any StatusSource, startError: String? = nil, starting: Bool = false) -> [StatusMenu.Item] {
        StatusMenu.items(
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs && !(starting && !manager.isActive),
            machine: StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: status.instantWatts(),
                wifi: WiFiStatusName.display(
                    ssid: status.wifiSSID,
                    locationAuthorized: (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
                ),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging,
                timeRemaining: status.batteryTimeRemaining()
            ),
            actions: StatusLines.actions(
                frozenCount: status.frozenCount,
                dockerPaused: status.dockerPaused,
                lastGap: status.lastGap
            ),
            throttledBrowsers: status.throttledBrowsers,
            relaunchProblems: status.relaunchProblems,
            // A report about an SSID edited away since is not shown.
            hotspotWarning: status.hotspotPasswordReport?.problem(for: manager.config.hotspotSSID)?.menuLine,
            error: manager.lastError,
            shownStartError: startError,
            commandRunning: manager.commandWarning,
            foreignSleep: manager.foreignSleepWarning,
            outputsWaiting: manager.outputsWaitingForRestore
        )
    }

    func stopWaitingForOutput(_ waiting: SavedAudioOutput) {
        Task { await manager.stopWaitingForOutput(waiting) }
    }

    /// The relaunch button: ask first, since the browser is quit and its
    /// windows come back only through its own session restore. Cancel does
    /// nothing. Confirming hands on the bundle id and name the button
    /// carried; a scan that replaced the browser list while the alert was
    /// up does not change them.
    func relaunchBrowser(_ browser: ThrottledBrowser) {
        // The alert is modal; a transient popover would close under it anyway.
        closePopover()
        guard confirmRelaunch(browser.name) else { return }
        status.relaunchUnthrottled(browser)
    }

    private static func askBeforeRelaunch(_ name: String) -> Bool {
        let prompt = RelaunchPrompt(browser: name)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: RelaunchPrompt.confirmTitle)
        alert.addButton(withTitle: RelaunchPrompt.cancelTitle)
        // A menu bar app has no window to carry the alert; bring the app
        // forward so the alert is not behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Settings

    func openSettings() {
        closePopover()
        showSettings()
    }
}

/// The SwiftUI host drawn over the status bar button. It takes no clicks:
/// they fall through to the button, which toggles the popover.
final class StatusHostingView: NSHostingView<StatusRootView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
