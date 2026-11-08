import AppKit
import SwiftUI

/// Owns the NSStatusItem and its popover, and drives every state change of
/// the menu bar UI.
///
/// The status bar button hosts a SwiftUI view and the item's length is
/// written once to whatever that view fits into (`StatusWidthWriter`).
/// Compact mode moves the same controls into an arrowless AppKit panel.
/// Keyboard input never reaches a text field inside a status bar window, so
/// a local key monitor routes digits / Tab / Enter / Esc / Delete to the
/// focused pill while the pills are open.
///
/// In Popover style a click on the item, left or right, toggles one
/// NSPopover hanging from it (`StatusPopoverView`), which holds time entry,
/// the status rows and warnings, Settings and Quit. Opening it activates
/// the app so its text fields take typing; Esc, a click outside, switching
/// apps or Spaces closes it.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    /// Builds the width writer over `apply` (which sets the item's length);
    /// tests inject one that records every write.
    typealias WidthWriterFactory = @MainActor (_ apply: @escaping (CGFloat) -> Void) -> StatusWidthWriter

    let manager: SessionManager
    let status: any StatusSource
    let model = MenuBarModel()
    let compactModel = CompactMenuModel()
    let reminder = ReminderScheduler()
    /// Whether the hotspot password is readable, for the failover row;
    /// checked on each open (`recheckHotspotPassword`).
    let hotspotPassword = HotspotPasswordCheck()
    /// Where that check reads; nil leaves the failover row out.
    private let secrets: (any HotspotSecretStore)?
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
    /// Stable identity across all modes, including Compact.
    var nativeStatusItem: NSStatusItem { statusItem }
    private var hostingView: StatusHostingView?
    private var widthWriter: StatusWidthWriter?
    private(set) var compactDropdown: CompactDropdownController?
    private var appliedMenuBarMode: Config.MenuBarMode?
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
    /// Whether any of those is installed; tests check that none is left.
    var watchesForPopoverDismissal: Bool { !dismissMonitors.isEmpty || !dismissObservers.isEmpty }
    /// Windows taken off screen while the app activates for the popover,
    /// each with the window it goes back under (`activateLeavingWindowsInPlace`).
    private var parkedWindows: [(window: NSWindow, above: Int)] = []
    private var parkObserver: NSObjectProtocol?
    /// Counts opens, so a start that completes after the popover was closed
    /// and opened again does not close the new one, and a click outside an
    /// earlier one does not move focus away from it.
    private var popoverOpenings = 0
    /// How long a resign with the pointer on the item waits for the item's
    /// click to arrive (`resignedActive`). The click's action comes with
    /// the same mouse-down, well inside this.
    var itemClickGrace: TimeInterval = 0.5
    /// How the popover moves focus between apps. Tests pass a recorder, so
    /// a run neither reads nor changes the app in front on the Mac.
    private let appFocus: CompactDropdownController.AppFocus
    /// The app the user was in when the popover opened, to give focus back
    /// to when it closes; nil when that was Insomnia itself.
    private(set) var popoverReturnApp: NSRunningApplication?
    /// The app a close last gave focus back to, and when (system uptime).
    /// The yield lands a moment later, with Insomnia still active until
    /// then. `yieldLandingWindow` is a guess at the longest that takes; a
    /// yield normally lands well inside it.
    private var lastYield: (app: NSRunningApplication, at: TimeInterval)?
    var yieldLandingWindow: TimeInterval = 1
    /// Counts the resigns that wait for an item click or an activation
    /// (`resignedActive`). Only the latest one's check may close.
    private var resignWaits = 0
    /// The activations an open asked for that have not landed, and when
    /// the last was asked for (system uptime). Behind a yield one lands
    /// only after the yield. One the system turns down never lands, so
    /// the wait ends `yieldLandingWindow` after the last ask.
    private var activationsAwaited = 0
    private var lastActivationAsked: TimeInterval = 0
    /// Insomnia becoming active and other apps coming to the front, watched
    /// while an activation is awaited. Read once more in `deinit`, which
    /// does not run on the main actor.
    nonisolated(unsafe) private var activationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Whether any of those is installed; tests check that none is left.
    var awaitsActivation: Bool { !activationObservers.isEmpty }
    /// The app in front when the popover closed with an activation still
    /// on its way, or the last one the user went to after that. Once the
    /// activation lands, focus goes back to it (`becameActive`).
    private var focusAfterActivation: NSRunningApplication?

    /// Keep clicks disabled through restoration even when the manager has
    /// already cleared its session, including a mode change during the wait.
    /// The Compact panel and the popover get it as well, since a Pills end
    /// leaves the panel's `isBusy` alone, together with the manager's own
    /// end (`MenuBarModel.endUnderway`, `syncCompactEnding`).
    private var sessionEndPending = false {
        didSet {
            model.isEnding = sessionEndPending
            syncCompactEnding()
        }
    }

    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    /// Holds keyboard focus while the pills are open; see `KeyCatcherPanel`.
    private var keyCatcher: KeyCatcherPanel?
    /// Waits out a press on the status item that took focus from the
    /// catcher; see `focusLost(_:)`.
    private var refocusWatch: Timer?
    /// The pointer in screen coordinates, read when the catcher loses focus.
    /// Tests pin it, so the real pointer resting on the item does not change
    /// which branch they take.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    /// 1 Hz redraw of the projected countdown while a start is pending, so
    /// it does not sit frozen for the seconds the recovery agent and pmset
    /// take and then jump on confirmation. The end time has nothing to tick.
    private var pendingTick: Timer?
    var pendingTickArmed: Bool { pendingTick != nil }
    /// Redraw of Minimal's arc between session changes. See `syncMinimalTick`.
    private(set) var minimalTick: Timer?
    /// While the popover is up, the watts and the battery's time left are
    /// read again this often. Both can change with no change in the
    /// percent or the charging state: IOKit's estimate goes from
    /// Calculating… to a time, and the draw moves.
    var popoverPowerInterval: TimeInterval = 10
    private(set) var popoverPowerTick: Timer?
    /// The latest start, extend or end handed to the manager. The task
    /// finishes once its result is shown; tests wait for it.
    private(set) var sessionRequest: Task<Void, Never>?
    /// Invalidates in-flight stagger steps when expand/collapse interleave.
    private var stageGeneration = 0
    /// Identifies the run whose completion is allowed to touch the UI. The
    /// manager answers in order, so an older completion can land while a
    /// newer run is still pending (extend, then extend again through the
    /// countdown); it must not clear what the newer one is showing.
    private var startGeneration = 0
    /// The width the status item is heading for.
    private(set) var widthTarget: CGFloat = 0
    /// How many times the width target has changed. The layout is meant to
    /// change once per open and once per close; tests pin that.
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
        clock: @escaping @Sendable () -> Date = { Date() },
        secrets: (any HotspotSecretStore)? = nil,
        appFocus: CompactDropdownController.AppFocus = CompactDropdownController.AppFocus()
    ) {
        self.manager = manager
        self.secrets = secrets
        self.appFocus = appFocus
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
        statusItem.isVisible = true
        installHostingView()
        observeManager()
        observeCountdownStyle()
        observeDisplaySleep()
        observePresentation()
        observeMinimalProgress()
        observeEnding()
        observePopoverPower()
        recheckHotspotPassword()
    }

    /// Not `isolated deinit`, for the macOS 26.2 runtime abort described on
    /// `DisplaySleepObserver`. A controller released while it waits for an
    /// activation leaves no observer behind.
    deinit {
        for (center, observer) in activationObservers {
            center.removeObserver(observer)
        }
    }

    /// Peeks at the hotspot password for the failover row, without a
    /// keychain prompt. The row stays out until the first answer.
    private func recheckHotspotPassword() {
        guard let secrets else { return }
        let ssid = manager.config.hotspotSSID
        Task { [hotspotPassword] in await hotspotPassword.refresh(ssid: ssid, peek: secrets.peek) }
    }

    /// Settings take effect immediately, independently of countdown updates.
    private func observePresentation() {
        withObservationTracking {
            _ = manager.config.menuBarMode
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePresentation() }
        }
        synchronizePresentation()
    }

    /// Change presentation without cancelling session work already in flight.
    func synchronizePresentation() {
        let mode = manager.config.menuBarMode
        let compact = mode == .compact
        guard appliedMenuBarMode != mode else { return }
        let previous = appliedMenuBarMode
        appliedMenuBarMode = mode
        // Only Popover style takes clicks on the button; the others take
        // them in the SwiftUI view, as they always have.
        routeClicks(toButton: mode == .popover)
        if mode != .popover {
            closePopover()
        }
        // A pending start or extension keeps its projection; its text takes
        // the new style's form (Popover's is to the minute).
        if let projection = model.pendingProjection {
            model.pendingCountdown = pendingText(projection, at: clock())
        }
        // A presentation change must not leave a delayed Pills
        // reservation to land after Compact or Minimal takes over.
        model.widthMotion?.retarget(widthTarget, reduceMotion: true)
        refreshMinimalProgress()
        syncMinimalTick()
        guard previous != nil else { return }
        // Folding slots can outlive a successful submission; only transfer
        // an unfinished entry or a request still awaiting confirmation.
        if compact, model.phase.isEntering || model.phase == .starting || compactModel.isBusy {
            compactModel.isEditing = model.phase.isEntering
            compactModel.entry.input = model.input
            compactModel.entry.keptRequest = model.keptRequest
            compactModel.entry.focused = model.focused
        }
        closeCompactDropdown()
        stageGeneration += 1
        removeMonitors()
        model.slotsPresent = false
        model.visiblePills = 0
        model.pillsCollapsing = false
        model.focusVisible = false
        model.startError = nil
        if model.phase != .starting {
            model.phase = Self.collapseTarget(sessionActive: manager.isActive)
        }
    }

    // MARK: Compact dropdown

    func makeCompactDropdown() -> CompactDropdownController {
        if let compactDropdown { return compactDropdown }
        let content = CompactMenuView(
            model: compactModel, menuBar: model, manager: manager,
            onSubmit: { [weak self] in self?.compactSubmit() },
            onEnd: { [weak self] in self?.compactEnd() },
            onDismiss: { [weak self] in self?.closeCompactDropdown() },
            onContentSizeChange: { [weak self] size in self?.compactDropdown?.updateContentSize(size) }
        )
        let menu = CompactStatusMenu(
            manager: manager, status: status,
            performAction: { [weak self] in self?.performMenuAction($0) },
            refresh: { [weak self] in self?.refreshMenuStatus() }
        )
        let dropdown = CompactDropdownController(content: AnyView(content.contextMenu { menu })) { [weak self] in
            self?.compactModel.setPresented(false)
            self?.button?.highlight(false)
        }
        compactDropdown = dropdown
        return dropdown
    }

    func closeCompactDropdown(returnFocus: Bool = true) {
        compactDropdown?.close(returnFocus: returnFocus)
        compactModel.setPresented(false)
        button?.highlight(false)
    }

    func compactSubmit() {
        guard manager.config.compactMode, !compactModel.isBusy, !compactModel.isEnding, model.phase != .starting else { return }
        let mode: MenuBarModel.Mode = manager.isActive ? .extend : .start
        switch MenuBarModel.commitAction(mode: mode, typed: compactModel.entry.submittedTotal, defaultPreset: manager.config.defaultPreset) {
        case let .run(duration):
            compactModel.error = nil
            model.input = compactModel.entry.input
            model.keptRequest = compactModel.entry.keptRequest
            run(mode: mode, duration: duration)
        case .reject:
            compactModel.entry.rejectBounce += 1
        }
    }

    func compactEnd() {
        guard manager.config.compactMode, compactModel.endIsEnabled else { return }
        endPresentedSession()
    }

    /// The panel shows every end, not only one this controller asked for:
    /// the timer's, a floor's or `--session end`'s, and one the manager
    /// left to its retry after it cleared the session.
    private func observeEnding() {
        withObservationTracking {
            _ = manager.isEnding
            _ = manager.endIsWaiting
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeEnding() }
        }
        syncCompactEnding()
    }

    /// `model.isEnding` mirrors `sessionEndPending`, set before this runs.
    private func syncCompactEnding() {
        compactModel.isEnding = model.endUnderway(manager)
        compactModel.endCanBeRetried = model.endCanBeRetried(manager)
    }

    /// A change in the battery's percent or charging state reads the watts
    /// and the time left again for a popover that is up.
    private func observePopoverPower() {
        withObservationTracking {
            _ = status.batteryPercent
            _ = status.isCharging
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePopoverPower() }
        }
        if model.popoverShown { readPopoverPower() }
    }

    private func readPopoverPower() {
        model.popoverPower = MenuBarModel.PopoverPower(
            watts: status.instantWatts(), timeRemaining: status.batteryTimeRemaining())
    }

    private func armPopoverPowerTick() {
        stopPopoverPowerTick()
        let timer = Timer(timeInterval: popoverPowerInterval, repeats: true) { [weak self] timer in
            // A controller released with the popover up: the run loop
            // would keep the timer firing for nothing.
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated {
                guard self.model.popoverShown else { return }
                self.readPopoverPower()
            }
        }
        timer.tolerance = popoverPowerInterval / 5
        RunLoop.main.add(timer, forMode: .common)
        popoverPowerTick = timer
    }

    private func stopPopoverPowerTick() {
        popoverPowerTick?.invalidate()
        popoverPowerTick = nil
    }

    // MARK: Minimal mode

    /// A short click starts or extends by the one duration chosen in Settings.
    /// Repeated additions wait for confirmation; cancellation remains available.
    private func minimalTap() {
        guard manager.config.menuBarMode == .minimal,
              !model.minimalBusy, !compactModel.isBusy, !sessionEndPending, model.phase != .starting else { return }
        let duration = manager.config.defaultPreset
        // The session manager records the requested seconds as an Int.
        // Settings cannot produce this value, but a hand-edited config can.
        guard duration.isFinite, duration > 0, duration < Double(Int.max) else { return }
        keepForRetry(duration)
        model.startError = nil
        compactModel.error = nil
        run(mode: manager.isActive ? .extend : .start, duration: duration)
    }

    /// A request not typed into the pills (a Minimal click, a popover chip)
    /// puts its duration in their input, which the Compact panel shares: a
    /// mode change during startup can expose the retry pills or the
    /// panel's entry, and they must hold the submitted duration rather
    /// than an older typed draft. Bound before converting to integer
    /// minutes, including a manually edited preset larger than
    /// DurationInput can represent. The input holds whole minutes, so the
    /// exact duration is kept beside it: a retry of a 90 s preset asks for
    /// 90 s, not the 1m the fields show, until the input is edited.
    private func keepForRetry(_ duration: TimeInterval) {
        let input = DurationInput.from(seconds: min(duration, TimeInterval(DurationInput.maxDays) * 86400))
        model.input = input
        model.keptRequest = MenuBarModel.KeptRequest(input: input, seconds: duration)
    }

    /// The completed hold uses the same journal-backed end operation as the
    /// other modes. A release after this hold must never add time or restart.
    private func minimalEnd() {
        guard manager.config.menuBarMode == .minimal else { return }
        endPresentedSession()
    }

    /// Compact and Minimal expose cancellation as soon as a start is submitted.
    /// The manager invalidates the pending transaction and restores its journal;
    /// a second submission stays blocked until that operation returns.
    private func endPresentedSession() {
        guard !sessionEndPending, manager.isActive || model.phase == .starting else { return }
        // Also invalidate a run whose Task has not entered the manager yet.
        // Otherwise it could start after this end captured the lifecycle queue.
        startGeneration += 1
        sessionEndPending = true
        model.minimalBusy = true
        compactModel.isBusy = true
        compactModel.error = nil
        stopPendingTick()
        sessionRequest = Task { @MainActor [weak self] in
            guard let self else { return }
            await manager.end(reason: .user)
            model.pendingCountdown = nil
            model.pendingProjection = nil
            model.phase = Self.collapseTarget(sessionActive: manager.isActive)
            if !manager.isActive {
                compactModel.isEditing = false
                compactModel.entry.input = DurationInput()
                compactModel.entry.keptRequest = nil
                compactModel.entry.focused = manager.config.defaultFocusField
            }
            // Update the settled presentation before reenabling interaction.
            sessionEndPending = false
            model.minimalBusy = false
            compactModel.isBusy = false
            refreshMinimalProgress()
        }
    }

    /// The arc follows a start, an extension or an end at once, and its own
    /// slow tick in between. It reads the session's times, not the countdown
    /// text, which never changes between sessions with the end-time style.
    private func observeMinimalProgress() {
        withObservationTracking {
            _ = manager.session
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMinimalProgress() }
        }
        refreshMinimalProgress()
        syncMinimalTick()
    }

    /// The arc is 300 degrees of a 20 pt ring: about 46 pt, so a second of an
    /// hour-long session moves it far less than a pixel. It redraws about
    /// every hundredth of the session instead, from 2 s up to 60 s. Runs
    /// only in Minimal, with a session, while a display is awake, like the
    /// tick of a pending start. A wake redraws at once (`observeDisplaySleep`).
    private func syncMinimalTick() {
        guard manager.config.menuBarMode == .minimal, let session = manager.session,
              !manager.displaysAsleep else {
            stopMinimalTick()
            return
        }
        let interval = Self.minimalTickInterval(for: session)
        // Keep a tick already running at this pace, so unrelated changes do
        // not push its next redraw back.
        if let minimalTick, minimalTick.timeInterval == interval { return }
        stopMinimalTick()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.refreshMinimalProgress() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        minimalTick = timer
    }

    private func stopMinimalTick() {
        minimalTick?.invalidate()
        minimalTick = nil
    }

    static func minimalTickInterval(for session: Session) -> TimeInterval {
        let total = session.endsAt.timeIntervalSince(session.startedAt)
        guard total.isFinite, total > 0 else { return 60 }
        return min(max(total / 100, 2), 60)
    }

    private func refreshMinimalProgress() {
        model.minimalProgress = manager.config.menuBarMode == .minimal
            ? Self.minimalProgress(session: manager.session, now: clock()) : nil
    }

    static func minimalProgress(session: Session?, now: Date) -> Double? {
        guard let session else { return nil }
        let total = session.endsAt.timeIntervalSince(session.startedAt)
        guard total.isFinite, total > 0 else { return 0 }
        return min(1, max(0, session.remaining(at: now) / total))
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
        let apply: (CGFloat) -> Void = { [weak statusItem] width in statusItem?.length = width }
        widthWriter = makeWidthWriter?(apply) ?? StatusWidthWriter(apply: apply)
        if let widthWriter {
            model.widthMotion = StatusItemWidthMotion(writer: widthWriter)
        }
        let root = StatusRootView(
            model: model,
            manager: manager,
            onTapIcon: { [weak self] in self?.iconTapped() },
            onTapPill: { [weak self] field in self?.focus(field) },
            onTapCountdown: { [weak self] in self?.customExtend() },
            onHoldEnd: { [weak self] in self?.holdToEnd() },
            onWidthChange: { [weak self] w in self?.widthChanged(w) }
        )
        let host = Self.makeHostingView(root)
        host.onRightMouseDown = { [weak self] event in self?.showMenu(event: event) }
        host.translatesAutoresizingMaskIntoConstraints = true
        // The height follows the button; the width is set from the layout
        // (`retargetWidth`) and never from the button, whose width is the
        // item's length: the content is laid out once at its own width,
        // anchored at the leading edge. The root compensates for the
        // native window's move while its visible width animates.
        host.frame = NSRect(x: 0, y: 0, width: 0, height: button.bounds.height)
        button.addSubview(host)
        button.title = ""
        button.image = nil
        // SwiftUI handles the clicks; the cell must not paint a highlight.
        (button.cell as? NSButtonCell)?.highlightsBy = []
        hostingView = host
        // The layout may already have reported through `onGeometryChange`
        // while the host was measured above, before `hostingView` was set,
        // in which case `retargetWidth` treats the fitting width as a
        // repeat and never grows the frame: size the host here.
        host.frame.size.width = max(widthTarget, host.fittingSize.width.rounded(.up), 24)
        widthChanged(host.fittingSize.width)
        logFrames("installed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logFrames("after 1s") }
    }

    /// Centralizes the AppKit/SwiftUI boundary so its sizing contract can be
    /// regression-tested independently of a live menu bar.
    static func makeHostingView(_ root: StatusRootView) -> StatusHostingView {
        let host = StatusHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.autoresizingMask = [.height]
        return host
    }

    /// Where the item sits on screen; used to find it for screenshots.
    func logFrames(_ tag: String) {
        guard let button, let host = hostingView else { return }
        let win = button.window.map { NSStringFromRect($0.frame) } ?? "?"
        Log.info("status item \(tag): window \(win) button \(NSStringFromRect(button.frame)) host \(NSStringFromRect(host.frame)) fitting \(NSStringFromSize(host.fittingSize)) length \(statusItem.length)")
        if let window = button.window, let screen = window.screen {
            let safe = screen.safeAreaInsets
            Log.info("status item \(tag): visible \(window.isVisible) alpha \(window.alphaValue) occlusion \(window.occlusionState.rawValue) screen \(screen.localizedName) \(NSStringFromRect(screen.frame)) safe {\(safe.top),\(safe.left),\(safe.bottom),\(safe.right)} button hidden \(button.isHidden) alpha \(button.alphaValue) host hidden \(host.isHidden) alpha \(host.alphaValue)")
        }
    }

    /// The layout reported a new width: send the item to it.
    private func widthChanged(_ width: CGFloat) {
        retargetWidth(width)
    }

    /// Reserve native space once, then animate the Pills content inside it.
    /// A shrink releases space only after the eye arrives. The host only
    /// grows, preserving room for departing controls throughout the reveal.
    private func retargetWidth(_ width: CGFloat) {
        let w = max(width.rounded(.up), 24)
        if w != widthTarget {
            widthTarget = w
            widthTargetChangeCount += 1
            if let host = hostingView, host.frame.width < w {
                host.frame.size.width = w
            }
        }
        model.widthMotion?.retarget(w, reduceMotion: reduceMotion || manager.config.menuBarMode != .pills)
    }

    /// Take the pills away and land on `landing()`'s layout, read when the
    /// last pill has gone: the session can end, or a pending start be
    /// confirmed, in that window.
    ///
    /// The pills fold shut towards the eye with their stagger
    /// (`pillsCollapsing` picks that shape over the in-place retract), the
    /// slots leave once the last has gone, and the length is written when
    /// the layout reports that, never before, so it does not cut across
    /// collapsing content. Outside any animation: the flag only changes how
    /// a hidden pill is drawn, and a pill still hidden here (Esc during the
    /// open stagger) is at zero opacity.
    private func retract(landing: @escaping @MainActor () -> MenuBarModel.Phase) {
        model.pillsCollapsing = true
        stagePills(to: 0) { [weak self] in
            guard let self else { return }
            // Outside any animation: the slots and the error label leave
            // and the phase changes in one relayout; the countdown, if
            // any, runs its own transition. The collapse ends with the
            // slots, in the same step, so no hidden pill is ever drawn
            // in the retract shape.
            self.model.pillsCollapsing = false
            self.model.slotsPresent = false
            self.model.startError = nil
            self.model.phase = landing()
        }
    }

    private var button: NSStatusBarButton? { statusItem.button }

    /// In Popover style the button takes the clicks (the host lets them
    /// through), on either mouse button, and toggles the popover on
    /// mouse-down like the system's own items. In the other styles the
    /// SwiftUI view and the host's right-click handling take them, and the
    /// button has no action.
    private func routeClicks(toButton: Bool) {
        hostingView?.passesClicksThrough = toButton
        guard let button else { return }
        button.target = toButton ? self : nil
        button.action = toButton ? #selector(buttonClicked) : nil
        button.sendAction(on: toButton ? [.leftMouseDown, .rightMouseDown] : [.leftMouseUp])
    }

    private var reduceMotion: Bool { Motion.reduceMotion }

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

    /// Settings can change the countdown style while a start or an extension
    /// is pending; the projected text and its tick follow it at once.
    private func observeCountdownStyle() {
        withObservationTracking {
            _ = manager.config.countdownStyle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.restylePendingCountdown()
                self.observeCountdownStyle()
            }
        }
    }

    /// The projected countdown stops redrawing while the displays sleep,
    /// like the manager's, and catches up as soon as one wakes.
    private func observeDisplaySleep() {
        withObservationTracking {
            _ = manager.displaysAsleep
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.manager.displaysAsleep {
                    self.refreshPendingCountdown()
                    self.refreshMinimalProgress()
                }
                self.syncPendingTick()
                self.syncMinimalTick()
                self.observeDisplaySleep()
            }
        }
    }

    private func restylePendingCountdown() {
        let style = manager.config.countdownStyle
        guard let projection = model.pendingProjection, projection.style != style else { return }
        let restyled = MenuBarModel.StartProjection(endsAt: projection.endsAt, shape: projection.shape, style: style)
        model.pendingProjection = restyled
        model.pendingCountdown = pendingText(restyled, at: clock())
        syncPendingTick()
    }

    private func managerChanged() {
        reminder.sync(endsAt: manager.session?.endsAt)
        if let next = Self.phase(forActive: manager.isActive, phase: model.phase) {
            switch next {
            case .idle, .running:
                // Outside any animation: the phase changes the layout, whose
                // new width the status item then heads for. What comes and
                // goes with it (the countdown and the ring at an end, the
                // ring at a confirmation) runs its own transition.
                stopPendingTick()
                // The session can land a hop before its countdown text does;
                // the projection stays up until the live text is there to
                // replace it (the run's completion clears it otherwise).
                if !manager.countdownText.isEmpty {
                    model.pendingCountdown = nil
                    model.pendingProjection = nil
                }
                // A session coming up answers a refusal the popover still
                // shows under its fields.
                if next == .running, manager.config.menuBarMode == .popover {
                    model.startError = nil
                }
                model.phase = next
            case .entering, .starting:
                // Only the mode of the open pills changes, so nothing to animate.
                model.phase = next
            }
        }
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
        case (false, .entering(.extend)):
            // The session ended under the extend pills: they now start a new one.
            .entering(.start)
        case (true, .entering(.start)):
            // A session came up while the start pills were open (the user
            // reopened them before the start finished): they now extend it.
            .entering(.extend)
        default:
            nil
        }
    }

    // MARK: Clicks

    func iconTapped() {
        if manager.config.compactMode {
            guard let button else { return }
            let dropdown = makeCompactDropdown()
            if dropdown.isShown {
                closeCompactDropdown()
            } else {
                compactModel.focusDefaultFieldIfUntouched(manager.config.defaultFocusField)
                compactModel.setPresented(true)
                dropdown.show(relativeTo: button)
                button.highlight(dropdown.isShown)
            }
            return
        }
        if manager.config.menuBarMode == .minimal {
            minimalTap()
            return
        }
        model.iconBounce += 1
        switch model.phase {
        case .idle:
            expand(mode: .start)
        case let .entering(mode):
            if model.pillsCollapsing {
                // A close is in flight (Esc, a click away): the phase is
                // still `.entering` but the pills are folding and the key
                // catcher is gone, so there is nothing to commit and nothing
                // more to collapse. The click brings the pills back.
                expand(mode: mode)
            } else if model.submittedTotal != nil {
                commit()
            } else {
                collapse()
            }
        case .starting:
            // Nothing to act on until the manager answers.
            break
        case .running:
            customExtend()
        }
    }

    // MARK: Popover

    @objc private func buttonClicked() {
        guard manager.config.menuBarMode == .popover else { return }
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
        guard manager.config.menuBarMode == .popover, !model.popoverShown else { return }
        // The lid, the battery and the watts are read right here; the SSID
        // and the throttled browser list are awaited, and fill in as the
        // scan lands, since the popover follows the status source.
        status.refreshInstant()
        readPopoverPower()
        armPopoverPowerTick()
        status.refreshOnDemand()
        // Same for the sleep lines: re-read the bit now.
        Task { await manager.recheckForeignSleep() }
        Task { await manager.checkSleepHeld() }
        recheckHotspotPassword()
        if model.startError == nil {
            model.clearFields()
        }
        // The time buttons by default; the fields stay out only to show a
        // refused value.
        model.customShown = !model.texts.isEmpty
        model.popoverShown = true
        model.focusRequest += 1
        popoverOpenings += 1
        focusAfterActivation = nil
        let popover = self.popover ?? makePopover()
        self.popover = popover
        guard let anchor = popoverAnchor ?? button, anchor.window != nil else { return }
        // Given back on close, as the pills and the Compact panel do. A
        // close just before may have yielded focus with Insomnia still
        // active; that yield is on its way, and its app is the one to
        // give focus back to.
        let front = appFocus.frontmost()
        let yieldInFlight = yieldIsRecent && appFocus.isActive() ? lastYield?.app : nil
        popoverReturnApp = front == .current ? yieldInFlight : front
        // A menu bar app is never frontmost by itself; without this the
        // fields would not take typing. With a yield on its way this asks
        // although Insomnia is active: the request goes after the yield,
        // and Insomnia ends up in front. The resigns the yield brings wait
        // for that (`resignedActive`), and a close before it lands gives
        // focus back once it does (`becameActive`). No windows are parked
        // for it: a yield the system turned down brings no activation to
        // put them back. So a Settings window behind another app can come
        // forward on a reopen this quick.
        let asksForFocus = yieldInFlight != nil || !appFocus.isActive()
        if yieldInFlight != nil {
            appFocus.activate()
        } else {
            activateLeavingWindowsInPlace()
        }
        if asksForFocus { awaitActivation() }
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
        guard !appFocus.isActive() else { return }
        let ours = NSApp.windows.filter { $0.isVisible && $0.level == .normal && $0 !== popover?.contentViewController?.view.window }
        let stack = Self.onScreenWindowStack()
        let placements = Self.coveredWindows(stack: stack, ours: Set(ours.map(\.windowNumber)))
        restoreParkedWindows()
        parkedWindows = ours.compactMap { window in placements[window.windowNumber].map { (window, $0) } }
        parkedWindows.forEach { $0.window.orderOut(nil) }
        appFocus.activate()
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
    ///
    /// Esc, a click on the item and a style change give focus back to the
    /// app the user was in. A close because focus went elsewhere (another
    /// app, Settings, another Space) passes false, and focus stays there; a
    /// click outside decides later (`dismissUnlessOnItemOrPopover`).
    func closePopover(returnFocus: Bool = true) {
        guard model.popoverShown else { return }
        model.popoverShown = false
        stopWatchingForDismissal()
        stopPopoverPowerTick()
        button?.highlight(false)
        popover?.close()
        let app = popoverReturnApp
        popoverReturnApp = nil
        // Closed with another app in front before an activation the popover
        // asked for has landed, as when the item closes a quick reopen
        // after the close's yield landed. That activation would bring
        // Insomnia forward with nothing open.
        if activationIsOnItsWay, !appFocus.isActive(), let front = appFocus.frontmost(), front != .current {
            focusAfterActivation = front
        }
        if returnFocus { giveFocusBack(to: app) }
    }

    /// Count an activation the popover just asked for, until it lands or
    /// can no longer be on its way.
    private func awaitActivation() {
        activationsAwaited = activationIsOnItsWay ? activationsAwaited + 1 : 1
        lastActivationAsked = ProcessInfo.processInfo.systemUptime
        if activationObservers.isEmpty {
            let center = NotificationCenter.default
            activationObservers.append((center, center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            }))
            let workspace = NSWorkspace.shared.notificationCenter
            activationObservers.append((workspace, workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.otherAppActivated(app) }
            }))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + yieldLandingWindow) { [weak self] in
            MainActor.assumeIsolated { self?.stopAwaitingActivationIfOver() }
        }
    }

    private var activationIsOnItsWay: Bool {
        activationsAwaited > 0 && ProcessInfo.processInfo.systemUptime - lastActivationAsked < yieldLandingWindow
    }

    /// Insomnia became active, which lands one activation the popover asked
    /// for. If the popover closed before it with another app in front,
    /// focus goes back to that app.
    func becameActive() {
        let awaited = activationIsOnItsWay
        activationsAwaited = awaited ? activationsAwaited - 1 : 0
        if activationsAwaited == 0 { stopObservingActivation() }
        let app = focusAfterActivation
        focusAfterActivation = nil
        guard awaited, !model.popoverShown else { return }
        giveFocusBack(to: app)
    }

    /// Another app came to the front. After a close that left an
    /// activation on its way, the user went there, and focus goes back to
    /// it once the activation lands.
    func otherAppActivated(_ app: NSRunningApplication?) {
        guard focusAfterActivation != nil, let app, app != .current else { return }
        focusAfterActivation = app
    }

    /// The last activation asked for can no longer land: stop waiting.
    private func stopAwaitingActivationIfOver() {
        guard !activationIsOnItsWay else { return }
        activationsAwaited = 0
        focusAfterActivation = nil
        stopObservingActivation()
    }

    private func stopObservingActivation() {
        for (center, observer) in activationObservers {
            center.removeObserver(observer)
        }
        activationObservers.removeAll()
    }

    /// Yield to `app`, the one the user was in. Nothing moves if another app
    /// already has focus or a window of this app such as Settings is key.
    private func giveFocusBack(to app: NSRunningApplication?) {
        guard let app, !app.isTerminated, appFocus.isActive(), !appFocus.hasKeyWindow() else { return }
        appFocus.yield(app)
        lastYield = (app, ProcessInfo.processInfo.systemUptime)
    }

    /// A close gave focus back less than `yieldLandingWindow` ago.
    private var yieldIsRecent: Bool {
        lastYield.map { ProcessInfo.processInfo.systemUptime - $0.at < yieldLandingWindow } == true
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
    /// action (`dismissUnlessOnItemOrPopover`).
    private func watchForDismissal() {
        stopWatchingForDismissal()
        let mouseDowns: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps, where the item's own click shows up too.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            MainActor.assumeIsolated {
                let point = Self.screenLocation(of: event)
                self?.dismissUnlessOnItemOrPopover(at: point)
            }
        }) {
            dismissMonitors.append(monitor)
        }
        // Clicks in this app's other windows (Settings). The item's own click
        // is left to its action, which toggles.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseDowns, handler: { [weak self] event in
            MainActor.assumeIsolated {
                let point = Self.screenLocation(of: event)
                self?.clickedInApp(window: event.window, at: point)
            }
            return event
        }) {
            dismissMonitors.append(monitor)
        }
        // Esc, wherever the cursor is. `onExitCommand` needs a field with
        // the cursor, and with the time buttons out there is none.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let window = event.window
            let handled = MainActor.assumeIsolated { self?.escapePressed(in: window) ?? false }
            return handled ? nil : event
        }) {
            dismissMonitors.append(monitor)
        }
        // Switching apps; a click on the item makes the app resign active
        // too, before its action arrives.
        let center = NotificationCenter.default
        dismissObservers.append((center, center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignedActive(pointer: NSEvent.mouseLocation) }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        dismissObservers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover(returnFocus: false) }
        }))
        // Not a dismissal, but over when the popover is: the item's width
        // changes with the countdown, and the menu bar moves the item after
        // a resize. The popover follows a resize by itself; after the move
        // its arrow pointed beside the eye (about 50 pt after an end).
        if let itemWindow = (popoverAnchor ?? button)?.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                dismissObservers.append((center, center.addObserver(forName: name, object: itemWindow, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.followItem() }
                }))
            }
        }
    }

    /// Put the popover's arrow back on the item, which moved or changed
    /// width with the popover up.
    private func followItem() {
        guard model.popoverShown, let popover, popover.isShown,
              let anchor = popoverAnchor ?? button, anchor.window != nil else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func stopWatchingForDismissal() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        for (center, observer) in dismissObservers {
            center.removeObserver(observer)
        }
        dismissObservers.removeAll()
    }

    /// Insomnia went to the background with the popover up and the pointer
    /// at `pointer`. Off the item and the popover that closes the popover,
    /// as a click outside does. On the item it may be the item's own click,
    /// whose action is on its way and toggles, so the popover is left to
    /// that action for `itemClickGrace`; in the popover it may be a click
    /// there, which brings Insomnia back. A switch by keyboard
    /// (Command-Tab) with the pointer resting on either has no action
    /// coming, and the popover closes then if Insomnia is still in the
    /// background.
    ///
    /// Soon after a close gave focus back, a resign can be that yield
    /// landing, with a quick reopen's activation right behind it. One
    /// then waits too, wherever the pointer has gone since. With two
    /// quick close and reopen cycles two yields land, each followed by an
    /// activation; only the last resign's check decides, so a check can't
    /// land between a later yield and its activation.
    func resignedActive(pointer: NSPoint) {
        guard model.popoverShown else { return }
        guard yieldIsRecent || isOnItem(pointer) || isOnPopover(pointer) else {
            dismissUnlessOnItemOrPopover(at: pointer)
            return
        }
        let opening = popoverOpenings
        resignWaits += 1
        let wait = resignWaits
        DispatchQueue.main.asyncAfter(deadline: .now() + itemClickGrace) { [weak self] in
            guard let self, self.model.popoverShown, self.popoverOpenings == opening, self.resignWaits == wait,
                  !self.appFocus.isActive() else { return }
            self.closePopover(returnFocus: false)
        }
    }

    /// Where a mouse event happened, in screen coordinates. A global event
    /// can carry the number of one of this app's windows, and its location
    /// is then in that window: on a MacBook a click in the popover reached
    /// the global monitor that way, at the popover's own coordinates.
    static func screenLocation(of event: NSEvent) -> NSPoint {
        if let window = event.window ?? NSApp.window(withWindowNumber: event.windowNumber) {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }

    /// `point`, in screen coordinates, is on the item.
    private func isOnItem(_ point: NSPoint) -> Bool {
        (popoverAnchor ?? button)?.window?.frame.contains(point) ?? false
    }

    /// `point`, in screen coordinates, is on the popover.
    private func isOnPopover(_ point: NSPoint) -> Bool {
        popover?.contentViewController?.view.window?.frame.contains(point) ?? false
    }

    /// Close the popover for something that happened at `point` (screen
    /// coordinates) outside this app, unless that is on the item, whose
    /// action is on its way and toggles, or on the popover. A click in the
    /// popover can reach this too: on a MacBook, most came with a second
    /// copy that had no target app.
    func dismissUnlessOnItemOrPopover(at point: NSPoint) {
        guard model.popoverShown else { return }
        if isOnItem(point) || isOnPopover(point) { return }
        let app = popoverReturnApp
        // A popover opened again before the check below runs decides about
        // focus itself.
        let opening = popoverOpenings
        closePopover(returnFocus: false)
        // A click that brings another app forward leaves focus there. One
        // that does not, such as a click on another menu bar item, gives it
        // back once the click has had its turn, as the Compact panel does.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popoverOpenings == opening else { return }
            self.giveFocusBack(to: app)
        }
    }

    /// A mouse-down somewhere in this app while the popover is open, at
    /// `point` in screen coordinates: one in another of its windows closes
    /// the popover, as a click outside a transient popover did. One in the
    /// popover is its own; one on the item is the item's click, which its
    /// action handles. One with no window goes by where it is.
    func clickedInApp(window: NSWindow?, at point: NSPoint) {
        guard model.popoverShown else { return }
        let own = [popover?.contentViewController?.view.window, button?.window, popoverAnchor?.window]
        if let window, own.contains(where: { $0 === window }) { return }
        if window == nil, isOnItem(point) || isOnPopover(point) { return }
        closePopover(returnFocus: false)
    }

    /// Esc in `window` while the popover is open: close it and give focus
    /// back, unless it is for another window or a field is composing text.
    /// True when it closed the popover.
    func escapePressed(in window: NSWindow?) -> Bool {
        guard model.popoverShown else { return false }
        let popoverWindow = popover?.contentViewController?.view.window
        if let window, window !== popoverWindow { return false }
        if let editor = popoverWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        closePopover()
        return true
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
                return Self.statusItems(manager: self.manager, status: self.status, power: self.model.popoverPower, startError: self.model.startError, starting: self.model.phase == .starting, hotspotPassword: self.secrets == nil ? nil : self.hotspotPassword)
            },
            actions: StatusPopoverView.Actions(
                commit: { [weak self] in self?.popoverCommit() },
                start: { [weak self] in self?.startPreset($0) },
                extend: { [weak self] in self?.extendBy($0) },
                holdToEnd: { [weak self] in self?.popoverHoldToEnd() },
                relaunch: { [weak self] in self?.relaunchBrowser($0) },
                stopWaiting: { [weak self] in self?.stopWaitingForOutput($0) },
                openSettings: { [weak self] in self?.openSettingsFromPopover() },
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
            popoverReturnApp = nil
            stopWatchingForDismissal()
            stopPopoverPowerTick()
            button?.highlight(false)
        }
    }

    /// The mode the popover is in: a live session is extended, otherwise a
    /// new one starts.
    var mode: MenuBarModel.Mode { manager.isActive ? .extend : .start }

    /// A preset chip: start that long at once. The chips and the fields do
    /// nothing through any end, also one the manager started
    /// (`MenuBarModel.endUnderway`).
    func startPreset(_ duration: TimeInterval) {
        guard manager.config.menuBarMode == .popover, model.phase != .starting, !model.endUnderway(manager),
              !manager.isActive, duration > 0 else { return }
        keepForRetry(duration)
        run(mode: .start, duration: duration)
    }

    /// An extend chip: extend the live session at once.
    func extendBy(_ duration: TimeInterval) {
        guard manager.config.menuBarMode == .popover, model.phase != .starting, !model.endUnderway(manager),
              manager.isActive, duration > 0 else { return }
        keepForRetry(duration)
        run(mode: .extend, duration: duration)
    }

    /// The popover's Start or Extend, and Return in its fields: the typed
    /// time, or with nothing typed the default preset (a start only).
    func popoverCommit() {
        guard manager.config.menuBarMode == .popover, model.phase != .starting, !model.endUnderway(manager) else { return }
        let input = model.popoverInput
        let typed = DurationInput.Field.allCases.allSatisfy(input.isValid) ? input.total : nil
        if typed == nil, !input.isEmpty {
            // Something is typed but it is not a duration: never fall back
            // to the default preset over it.
            model.rejectBounce += 1
            return
        }
        switch MenuBarModel.commitAction(mode: mode, typed: typed, defaultPreset: manager.config.defaultPreset) {
        case let .run(duration):
            // As the Compact panel does: a style change before the manager
            // answers hands the value to the new style, and the pills
            // reopen on it if the start is refused.
            model.input = input
            model.keptRequest = nil
            run(mode: mode, duration: duration, fromPopoverFields: true)
        case .reject:
            model.rejectBounce += 1
        }
    }

    /// The popover's ring closed its hold. The ring checks the button and
    /// the pointer itself (`HoldToEndButton`); this ends the session only
    /// while the popover is still up in Popover style, so a hold in a
    /// popover closed by code (a click outside, a style change) ends
    /// nothing. Through an end it ends nothing either, unless the manager's
    /// end waits for its retry: then it asks for the end again at once, as
    /// the Compact panel's ring does.
    func popoverHoldToEnd() {
        guard manager.config.menuBarMode == .popover, model.popoverShown,
              manager.isActive, model.endIsEnabled(manager) else { return }
        endNow()
    }

    /// What the popover says about a refused start: the manager's reason,
    /// or a short line when it left none.
    static func startErrorText(_ lastError: String?) -> String {
        guard let lastError, !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MenuBarModel.startFailedText
        }
        return lastError
    }

    // MARK: Expand / collapse

    func expand(mode: MenuBarModel.Mode) {
        guard manager.config.menuBarMode == .pills, !sessionEndPending else { return }
        // Reopened under a fold (the generation bump in `stagePills` drops
        // its landing): end the fold first, before any state below can
        // change the layout. Clearing the error label, say, can make the
        // hosting view lay out and report at once, and that report is
        // written; it must not land under a fold still flagged. A pill
        // still on its way to the eye slides back to its slot on the
        // collapse curve while the stagger brings it up; animated, so it
        // is not seen jumping back.
        endFoldIfAny()
        model.input = DurationInput()
        model.keptRequest = nil
        model.focused = manager.config.defaultFocusField
        model.focusVisible = false
        stopPendingTick()
        model.pendingCountdown = nil
        model.pendingProjection = nil
        model.startError = nil
        // Layout next, outside any animation: the three slots arrive at once
        // and the status item widens to them. The content staggers in
        // meanwhile.
        model.phase = .entering(mode)
        model.slotsPresent = true
        stagePills(to: DurationInput.Field.allCases.count)
        installMonitors()
    }

    /// Ends a fold in flight on the collapse curve, so a pill caught
    /// mid-travel slides back to its slot rather than jumping there.
    /// Must run before any layout-affecting state changes: the hosting
    /// view can lay out and report synchronously, and a width write under
    /// `pillsCollapsing` is the cut across moving content the design
    /// forbids.
    private func endFoldIfAny() {
        guard model.pillsCollapsing else { return }
        withAnimation(Motion.collapse(reduceMotion: reduceMotion)) {
            model.pillsCollapsing = false
        }
    }

    /// Collapse to idle, or back to the countdown when a session is running.
    func collapse(returnFocus: Bool = true) {
        guard model.phase.isEntering else { return }
        removeMonitors(returnFocus: returnFocus)
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
        }
        // The session is read at landing, not now: the pills take a moment
        // to leave and the session can end (or a restored one can land) in
        // that window, which would make a target captured up front install
        // a countdown for a session that is already over.
        retract { [manager] in Self.collapseTarget(sessionActive: manager.isActive) }
    }

    /// Where the pills land when dismissed. A live session always goes back
    /// to its countdown, whichever mode the pills were opened in: start-mode
    /// pills can outlive the start they were typed into.
    static func collapseTarget(sessionActive: Bool) -> MenuBarModel.Phase {
        sessionActive ? .running : .idle
    }

    /// Step `visiblePills` towards `target`, one pill per `Motion.stagger`.
    private func stagePills(to target: Int, completion: (() -> Void)? = nil) {
        stageGeneration += 1
        // Read once for the whole stage: a Reduce Motion change mid-fold
        // must not shorten the settle under a pill still on the long curve.
        let reduceMotion = self.reduceMotion
        let generation = stageGeneration
        let current = model.visiblePills
        let steps: [Int] = current < target ? Array((current + 1)...target) : Array((target..<current).reversed())
        guard !steps.isEmpty else {
            if target == 0 {
                // Already retracted, so a retract is settling (Esc, then a
                // click on the mark): the generation bump above just cancelled
                // its completion, and the last pill may still be fading. Wait
                // the settle out again rather than snap under it.
                let settle = Motion.retractSettle(reduceMotion: reduceMotion)
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                    guard let self, self.stageGeneration == generation else { return }
                    completion?()
                }
            } else {
                // Already shown: just breathe the focus glow in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.stageGeneration == generation else { return }
                    withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                        self.model.focusVisible = true
                    }
                }
                completion?()
            }
            return
        }
        let count = steps.count
        // Staging to zero is the close: each pill leaves on the
        // collapse curve (fixed duration, so the settle below is exact)
        // rather than the base spring the open uses.
        let animation = target == 0 ? Motion.collapse(reduceMotion: reduceMotion) : Motion.base(reduceMotion: reduceMotion)
        for (i, value) in steps.enumerated() {
            let delay = Motion.staggerDelay(index: i, count: count, reversed: false, reduceMotion: reduceMotion)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.stageGeneration == generation else { return }
                withAnimation(animation) {
                    self.model.visiblePills = value
                }
                if i == count - 1 {
                    if target > 0 {
                        // Let the last pill land, then breathe the focus glow in.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                            guard let self, self.stageGeneration == generation else { return }
                            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                                self.model.focusVisible = true
                            }
                        }
                        completion?()
                    } else {
                        // The completion takes the slots out of the layout:
                        // wait for the last pill's collapse curve to have
                        // run out (`retractSettle` covers it, plus a frame)
                        // so nothing visible is removed.
                        let settle = Motion.retractSettle(reduceMotion: reduceMotion)
                        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                            guard let self, self.stageGeneration == generation else { return }
                            completion?()
                        }
                    }
                }
            }
        }
    }

    // MARK: Focus and typing

    func focus(_ field: DurationInput.Field) {
        guard model.phase.isEntering else { return }
        keyCatcher?.takeFocus()
        model.applyInput(.focus(field), reduceMotion: reduceMotion)
    }

    // MARK: Commit

    /// Enter: start or extend with the typed value. With nothing typed it
    /// starts the default preset; while extending it shakes instead.
    func commit() {
        if manager.config.menuBarMode == .popover {
            popoverCommit()
            return
        }
        guard case let .entering(mode) = model.phase else { return }
        // Nothing to commit once the monitors are down: Enter has already
        // been pressed (or Esc), and the slots are retracting.
        guard keyCatcher != nil else { return }
        switch MenuBarModel.commitAction(mode: mode, typed: model.submittedTotal, defaultPreset: manager.config.defaultPreset) {
        case let .run(duration):
            run(mode: mode, duration: duration)
        case .reject:
            model.rejectBounce += 1
        }
    }

    /// `fromPopoverFields`: the popover's Start or Return asked for what
    /// its fields hold, not a chip.
    private func run(mode: MenuBarModel.Mode, duration: TimeInterval, fromPopoverFields: Bool = false) {
        guard !sessionEndPending else { return }
        let submittedFromCompact = manager.config.compactMode
        let submittedFromPopover = manager.config.menuBarMode == .popover
        let opening = popoverOpenings
        // What the popover's fields held when this was submitted. During an
        // extend they stay editable; a new time typed before it finishes is
        // kept.
        let typed = model.texts
        if submittedFromPopover {
            // The popover's refusal line goes with the retry.
            model.startError = nil
        }
        compactModel.error = nil
        compactModel.isBusy = true
        model.minimalBusy = true
        removeMonitors()
        startGeneration += 1
        let generation = startGeneration
        // On a retry after a refusal the label goes with the retry, not
        // only with its success (UIStartupTests pins that), but it is hidden
        // (`startErrorShown`), not cleared: its text keeps the label's room
        // in the layout until the slots leave, so the bar is written once,
        // then, and never under the folding pills.
        let now = clock()
        if mode == .extend, let s = manager.session {
            // The session is live, so the countdown stays up. Project the
            // session so the countdown already has the final shape while the
            // manager catches up (pmset takes a moment).
            let projected = SessionMath.extended(s, by: duration, now: now, maxDuration: manager.config.maxDuration)
            let projection = MenuBarModel.StartProjection(
                endsAt: projected.endsAt,
                shape: projected.countdownShape,
                style: manager.config.countdownStyle
            )
            model.pendingProjection = projection
            model.pendingCountdown = pendingText(projection, at: now)
        } else {
            // No session yet: the manager has to arm the recovery agent and
            // disable sleep first, and either can take seconds or refuse. Show
            // the countdown the session will read the moment it is confirmed,
            // ticking meanwhile. Pills waits for confirmation to
            // show its end ring; Compact and Minimal can cancel this request.
            let projection = MenuBarModel.projectedStart(
                now: now,
                duration: duration,
                maxDuration: manager.config.maxDuration,
                style: manager.config.countdownStyle
            )
            model.pendingProjection = projection
            model.pendingCountdown = pendingText(projection, at: now)
        }
        // The phase flips now, outside any animation, so nothing can act on
        // the pills again while they leave (and the eye starts opening);
        // the slots stay in the layout until the last pill has gone, then
        // leave in one relayout and the countdown scales in. Enter during
        // the open stagger folds whatever is up.
        model.phase = mode == .extend && manager.isActive ? .running : .starting
        syncPendingTick()
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.focusVisible = false
        }
        if manager.config.menuBarMode == .pills {
            retract { [model] in model.phase }
        }

        sessionRequest = Task { @MainActor in
            guard generation == startGeneration else { return }
            switch mode {
            case .start: await manager.start(duration: duration)
            case .extend: await manager.extend(by: duration)
            }
            guard generation == startGeneration else { return }
            compactModel.isBusy = false
            model.minimalBusy = sessionEndPending
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
                if manager.lastError == nil {
                    compactModel.isEditing = false
                    compactModel.entry.input = DurationInput()
                    compactModel.entry.keptRequest = nil
                    compactModel.entry.focused = manager.config.defaultFocusField
                } else if submittedFromCompact || manager.config.compactMode {
                    compactModel.isEditing = true
                }
                // Done: the popover's value is spent and its fields are put
                // away. The popover stays open on the running session; the
                // user closes it. Unless the popover was closed and opened
                // again meanwhile, or the fields were edited since: either
                // way they hold something typed since.
                if submittedFromPopover, mode == .start || manager.lastError == nil,
                   opening == popoverOpenings, model.texts == typed {
                    model.clearFields()
                    model.customShown = false
                }
            } else if model.phase == .starting {
                // Start refused: bring the pills back with the value intact
                // and say so. The full reason is in the right-click menu.
                if manager.config.menuBarMode == .popover {
                    // The typed value stays in the popover's fields, and the
                    // popover says why in the manager's own words. A close
                    // and reopen while the start was on its way cleared the
                    // fields; the value comes back to them for the retry,
                    // unless something was typed since. A chip's start
                    // leaves them alone: what they held was not asked for.
                    model.phase = .idle
                    model.startError = Self.startErrorText(manager.lastError)
                    if fromPopoverFields, opening != popoverOpenings, model.texts.isEmpty, !typed.isEmpty {
                        model.texts = typed
                        model.customShown = true
                    }
                } else if manager.config.menuBarMode != .pills {
                    model.phase = .idle
                    compactModel.error = manager.lastError == nil ? MenuBarModel.startFailedText : nil
                } else {
                    reopenAfterFailure(mode: .start)
                }
            } else if submittedFromCompact {
                compactModel.error = manager.lastError == nil ? "The session ended before it could be extended." : nil
            }
        }
    }

    /// Put the pills straight back, all at once. No stagger: the refusal can
    /// arrive within the same frame the pills were retracting in, and
    /// replaying the open sequence on top of that half-finished retract is
    /// the churn the user sees as flicker. One animated retarget instead.
    private func reopenAfterFailure(mode: MenuBarModel.Mode) {
        let keep = model.input
        // Cancels a close still in flight: its landing and any stagger
        // work are dropped by the generation, and the fold ends now, on
        // its own curve, before the layout below (the hosting view can lay
        // out and report the label's width as soon as the error is set,
        // and that report is written: it must not land under a fold still
        // flagged; and a pill mid-travel slides back rather than jumping).
        stageGeneration += 1
        endFoldIfAny()
        // Layout outside any animation (one relayout, whether the slots were
        // still there or already gone), then the content springs back.
        model.phase = .entering(mode)
        model.slotsPresent = true
        model.startError = MenuBarModel.startFailedText
        withAnimation(Motion.base(reduceMotion: reduceMotion)) {
            model.input = keep
            model.visiblePills = DurationInput.Field.allCases.count
            model.focusVisible = true
        }
        installMonitors()
    }

    // MARK: Projected countdown

    /// 1 Hz redraw of the projected countdown, aligned to whole wall-clock
    /// seconds like the manager's live one. Runs only while the phase is
    /// `.starting`, the countdown shows the time left and a display is
    /// awake; stopped on confirmation, refusal or reopening. The timer runs
    /// on the real run loop, so it is scheduled from `Date()`; the text it
    /// draws reads `clock`.
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

    private func syncPendingTick() {
        if model.phase == .starting, manager.config.countdownStyle == .remaining, !manager.displaysAsleep {
            armPendingTick()
        } else {
            stopPendingTick()
        }
    }

    private func refreshPendingCountdown() {
        guard model.phase == .starting, let projection = model.pendingProjection else {
            stopPendingTick()
            return
        }
        // Assigned only on a change: Popover's text changes once a minute.
        let text = pendingText(projection, at: clock())
        if model.pendingCountdown != text { model.pendingCountdown = text }
    }

    /// What a projected countdown reads at `now` in the current style.
    /// Popover's bar shows the time left to the minute, the form
    /// `SessionManager.remainingText` takes; the other styles show the full
    /// countdown. The end time reads the same in every style.
    private func pendingText(_ projection: MenuBarModel.StartProjection, at now: Date) -> String {
        manager.config.menuBarMode == .popover && projection.style == .remaining
            ? projection.shortCountdown(at: now)
            : projection.countdown(at: now)
    }

    // MARK: Session actions

    private func endNow() {
        guard !sessionEndPending else { return }
        sessionEndPending = true
        model.minimalBusy = true
        sessionRequest = Task { @MainActor in
            await manager.end(reason: .user)
            sessionEndPending = false
            model.minimalBusy = compactModel.isBusy
        }
    }

    /// The status item's hold-to-end gesture completed. Minimal can cancel
    /// startup; Pills keeps its confirmed-session behavior.
    func holdToEnd() {
        guard !sessionEndPending else { return }
        if manager.config.menuBarMode == .popover {
            popoverHoldToEnd()
            return
        }
        if manager.config.menuBarMode == .minimal {
            minimalEnd()
            return
        }
        guard manager.isActive else { return }
        endNow()
    }

    /// Clicking the mark or the countdown while a session runs: reopen the
    /// pills, this time to extend. Ignored while a start is still in flight.
    func customExtend() {
        guard manager.isActive else { return }
        expand(mode: .extend)
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
    /// "still held" warning is not shown. A session whose live check could
    /// not set sleep off again (`sleepNotHeld`) counts as not holding it.
    /// `hotspotPassword` is what the failover row reads; nil leaves the
    /// row out. So does a warning about the hotspot password, which
    /// already says what is wrong.
    /// `power` is the popover's last reading of the watts and the time
    /// left (`MenuBarModel.popoverPower`); nil reads them now.
    static func statusItems(manager: SessionManager, status: any StatusSource, power: MenuBarModel.PopoverPower? = nil, startError: String? = nil, starting: Bool = false, hotspotPassword: HotspotPasswordCheck? = nil) -> [StatusMenu.Item] {
        let power = power ?? MenuBarModel.PopoverPower(watts: status.instantWatts(), timeRemaining: status.batteryTimeRemaining())
        let ssid = manager.config.hotspotSSID
        let locationAuthorized = (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
        // A report about an SSID edited away since is not shown.
        let hotspotWarning = status.hotspotPasswordReport?.problem(for: ssid)?.menuLine
        let failover = hotspotPassword.flatMap { check in
            hotspotWarning == nil
                ? HotspotFailoverRow.item(ssid: ssid, password: check.reading(for: ssid), locationAuthorized: locationAuthorized)
                : nil
        }
        return StatusMenu.popoverItems(
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs && !manager.sleepNotHeld && !(starting && !manager.isActive),
            machine: StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: power.watts,
                wifi: WiFiStatusName.row(ssid: status.wifiSSID, locationAuthorized: locationAuthorized),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging,
                timeRemaining: power.timeRemaining,
                failover: failover
            ),
            actions: StatusLines.actionRows(
                frozenCount: status.frozenCount,
                dockerPaused: status.dockerPaused,
                lastGap: status.lastGap
            ),
            throttledBrowsers: status.throttledBrowsers,
            relaunchProblems: status.relaunchProblems,
            hotspotWarning: hotspotWarning,
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

    // MARK: Right-click menu

    /// Secondary clicks use a contextual menu. Assigning `statusItem.menu`
    /// instead selects the regular menu-bar presentation and its material.
    private func showMenu(event: NSEvent) {
        guard let button else { return }
        showMenu(from: button, event: event)
    }

    private func showMenu(from button: NSView, event: NSEvent) {
        let dropdown = compactDropdown?.isShown == true ? compactDropdown : nil
        closeCompactDropdown(returnFocus: false)
        let typingPanel = keyCatcher
        collapse(returnFocus: false)
        defer {
            if NSApp.keyWindow == nil {
                typingPanel?.returnFocus()
                dropdown?.returnFocus()
            }
        }
        // The lid, the battery and the watts are read right here, so the menu
        // opens on what the machine is doing now. The SSID and the throttled
        // browser list are whatever the last scan found: both have to be
        // awaited, and an open NSMenu blocks the main actor, so there is no
        // moment at which they could be filled into a menu that is already up.
        // Kick that scan off anyway, for the next opening.
        refreshMenuStatus()
        let menu = StatusMenu.menu(
            Self.menuItems(manager: manager, status: status),
            target: self,
            endSession: #selector(menuEndSession),
            settings: #selector(menuOpenSettings),
            quit: #selector(menuQuit),
            relaunchBrowser: #selector(menuRelaunchBrowser(_:)),
            stopWaitingForOutput: #selector(menuStopWaitingForOutput(_:))
        )
        // Pass the original event so AppKit chooses contextual-menu chrome
        // and placement, including Control-click and mirrored menu bars.
        // The status item stays free to handle its ordinary primary click.
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    /// Refresh both menu presentations through the same path, including
    /// the upstream recovery status that may change outside Insomnia.
    func refreshMenuStatus() {
        status.refreshInstant()
        status.refreshOnDemand()
        // An open AppKit menu blocks the main actor; this scan updates the
        // next opening if the foreign sleep setting has since been cleared.
        Task { await manager.recheckForeignSleep() }
        // The time left is read now too: the redraw timer stops while the
        // lid is closed, and the menu can open then on an external display.
        // Nothing ticks it at all while the bar shows the end time.
        manager.refreshCountdown()
    }

    func menuItems() -> [StatusMenu.Item] {
        Self.menuItems(manager: manager, status: status)
    }

    /// The menu's lines from what the session and the status source report
    /// now. Static, so a test can check them without a status item.
    /// The menu also carries the time left while a session runs and the bar
    /// does not show it: the countdown is off, so the bar shows only the eye,
    /// or the countdown shows the end time, or the style is Compact or
    /// Minimal, which have no countdown in the bar.
    static func menuItems(manager: SessionManager, status: any StatusSource) -> [StatusMenu.Item] {
        let inMenu = manager.isActive
            && (manager.config.menuBarMode != .pills
                || !manager.config.showMenuBarCountdown
                || manager.config.countdownStyle == .endTime)
        return StatusMenu.items(
            sessionActive: manager.isActive,
            sleepHeld: manager.state.sleepDisabledByUs,
            machine: StatusLines.machine(
                lidClosed: status.lidClosed,
                watts: status.instantWatts(),
                batteryPercent: status.batteryPercent,
                isCharging: status.isCharging
            ),
            network: StatusLines.network(
                wifiSSID: WiFiStatusName.display(
                    ssid: status.wifiSSID,
                    locationAuthorized: (status as? LiveStatusSource)?.locationPermission.isAuthorized ?? true
                )
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
            commandRunning: manager.commandWarning,
            foreignSleep: manager.foreignSleepWarning,
            outputsWaiting: manager.outputsWaitingForRestore,
            lidSimulationBuild: LidSimulationBuild.isCompiledIn,
            remaining: inMenu ? manager.remainingText : nil
        )
    }

    @objc private func menuStopWaitingForOutput(_ sender: NSMenuItem) {
        guard let waiting = sender.representedObject as? SavedAudioOutput else { return }
        performMenuAction(.stopWaitingForOutput(waiting))
    }

    @objc private func menuRelaunchBrowser(_ sender: NSMenuItem) {
        guard let browser = sender.representedObject as? ThrottledBrowser else { return }
        performMenuAction(.relaunchBrowser(browser))
    }

    /// Both the AppKit menu and compact SwiftUI menu dispatch here so a
    /// presentation change cannot bypass confirmation or recovery actions.
    func performMenuAction(_ kind: StatusMenu.Item.Kind) {
        switch kind {
        case .info, .warning, .separator:
            break
        case .endSession:
            guard manager.isActive else { break }
            // The same end as each style's hold control.
            if manager.config.menuBarMode == .pills {
                endNow()
            } else {
                endPresentedSession()
            }
        case .settings:
            openSettings()
            showSettings()
        case .quit:
            NSApplication.shared.terminate(nil)
        case let .relaunchBrowser(browser):
            relaunchBrowser(browser)
        case let .stopWaitingForOutput(waiting):
            Task { await manager.stopWaitingForOutput(waiting) }
        }
    }

    /// The relaunch item: ask first, since the browser is quit and its
    /// windows come back only through its own session restore. Cancel does
    /// nothing. Confirming hands on the bundle id and name the item
    /// carried; a scan that replaced the browser list while the alert was
    /// up does not change them.
    func relaunchBrowser(_ browser: ThrottledBrowser) {
        // The popover goes first, so the alert is not left under it; the
        // alert takes focus.
        closePopover(returnFocus: false)
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

    /// A normal menu click ends through the same restoration path as the hold
    /// control. A menu kept open after timer expiry must not end an idle session.
    @objc func menuEndSession() {
        performMenuAction(.endSession)
    }

    @objc func menuQuit() {
        performMenuAction(.quit)
    }

    @objc func menuOpenSettings() {
        performMenuAction(.settings)
    }

    // MARK: Settings

    /// The popover's Settings button: the popover goes first, so the
    /// window comes up over the app that was in front.
    func openSettingsFromPopover() {
        // Settings takes focus next; yielding it to another app first could
        // leave the window behind that app.
        closePopover(returnFocus: false)
        showSettings()
    }

    private func openSettings() {
        // Settings takes focus next; yielding it to another app first could
        // leave the window behind that app.
        closeCompactDropdown(returnFocus: false)
        if model.phase.isEntering {
            removeMonitors()
            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                model.focusVisible = false
            }
            retract { [manager] in Self.collapseTarget(sessionActive: manager.isActive) }
        }
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        // Local monitors only receive keys routed to our own key window.
        let panel = KeyCatcherPanel()
        if let button { panel.move(toStatusButton: button) }
        keyCatcher = panel
        panel.onFocusLost = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.focusLost(panel)
        }
        panel.takeFocus()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors always run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleLocalMouse(window: event.window)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            // Read now: by the time the task runs the pointer may have moved.
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, !Self.isClickOnItem(at: point, itemFrame: self.button?.window?.frame) else { return }
                self.collapse()
            }
        }
    }

    private func removeMonitors(returnFocus: Bool = true) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        localMouseMonitor = nil
        globalMouseMonitor = nil
        stopRefocusWatch()
        let panel = keyCatcher
        keyCatcher = nil
        panel?.onFocusLost = nil
        panel?.orderOut(nil)
        if returnFocus { panel?.returnFocus() }
    }

    /// The catcher lost key status. On macOS 27 a press on the status item
    /// does that by itself: it deactivates the app while the button is still
    /// down, so collapsing here would fold the pills before a pill could take
    /// the click. A press on the item is waited out instead (`RefocusWait`).
    /// A pill takes focus back (`focus(_:)`) and the eye commits or collapses
    /// (`iconTapped`); if the catcher is still not key once the button has
    /// been up for `RefocusWait.grace`, the pills close, so typing never goes
    /// to another app while they show. Focus lost anywhere else (another app,
    /// Cmd-Tab) collapses at once.
    private func focusLost(_ panel: KeyCatcherPanel) {
        guard Self.isClickOnItem(at: pointerLocation(), itemFrame: button?.window?.frame) else {
            collapse(returnFocus: false)
            return
        }
        // One watch at a time, and nothing queued behind it: a second press
        // replaces the first press's watch rather than racing it.
        stopRefocusWatch()
        var wait = RefocusWait()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let panel, self.keyCatcher === panel else {
                    self.stopRefocusWatch()
                    return
                }
                let step = wait.step(
                    buttonDown: NSEvent.pressedMouseButtons & 1 != 0,
                    catcherIsKey: panel.isKeyWindow,
                    now: ProcessInfo.processInfo.systemUptime
                )
                switch step {
                case .wait:
                    break
                case .refocused:
                    self.stopRefocusWatch()
                case .collapse:
                    self.stopRefocusWatch()
                    self.collapse(returnFocus: false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refocusWatch = timer
    }

    private func stopRefocusWatch() {
        refocusWatch?.invalidate()
        refocusWatch = nil
    }

    /// On macOS 27 a click on the status item reaches the global monitor as
    /// well, so it would collapse the pills before a pill could take the
    /// click. Only a click away from the item's window is a click away. On
    /// macOS 26 the monitor never sees a click on the item, so this changes
    /// nothing there.
    static func isClickOnItem(at point: NSPoint, itemFrame: NSRect?) -> Bool {
        itemFrame?.contains(point) ?? false
    }

    /// A click anywhere in this app that is not the status item collapses
    /// the pills.
    private func handleLocalMouse(window: NSWindow?) {
        guard model.phase.isEntering else { return }
        // The catcher panel ignores the mouse so it should never be reported
        // here, but it is ours: it must not dismiss the pills either.
        if let w = window, w === button?.window || w === keyCatcher { return }
        collapse(returnFocus: false)
    }

    /// Returns true when the key was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard manager.config.menuBarMode == .pills, model.phase.isEntering else { return false }
        guard let command = DurationInputCommand(event) else { return false }
        switch command {
        case .cancel:
            collapse()
            return true
        case .submit:
            commit()
            return true
        default:
            return model.applyInput(command, reduceMotion: reduceMotion)
        }
    }
}

/// The SwiftUI host covers the status bar button, so the right click has to
/// be caught here rather than on the button. Ctrl-click is the same gesture
/// on a one-button mouse.
private struct EventBox: @unchecked Sendable {
    let event: NSEvent?
    init(_ event: NSEvent?) { self.event = event }
}

final class StatusHostingView: NSHostingView<StatusRootView> {
    var onRightMouseDown: ((NSEvent) -> Void)?
    /// Popover style: every click goes to the status bar button under this
    /// view, which toggles the popover, and nothing here sees it. The other
    /// styles leave it false.
    var passesClicksThrough = false {
        // A release held back for the other styles' hold is not sent later.
        didSet { if passesClicksThrough { stopWatchingRelease() } }
    }
    /// Where the pointer really is, in the window's coordinates. A test
    /// replaces it; the app reads the live pointer.
    var pointerInWindow: (NSWindow) -> NSPoint = { $0.convertPoint(fromScreen: NSEvent.mouseLocation) }
    /// Whether the left button is physically down right now.
    var buttonIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    /// The system's major version. A test replaces it.
    var osMajorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    private var pointerMonitor: Any?
    private var releaseWatch: Timer?

    /// On macOS 27 a click on a status item reaches the app with its location
    /// at the middle of the item's window, wherever the pointer was (every
    /// press logged the window's exact centre, at three different widths).
    /// SwiftUI hit-tests that point, so every press landed on the countdown:
    /// the hold-to-end ring never saw a press and the pills opened instead.
    /// SwiftUI reads the location from the window's current event, not from
    /// the one passed to `mouseDown`, so the event has to be replaced before
    /// dispatch: a local monitor may return a different event. Only an event
    /// at the window's middle is replaced; any other passes through as it came.
    /// The monitor exists on macOS 27 and later only: earlier systems report a
    /// click where it happened, even one at the middle.
    ///
    /// The release has the same problem: the system sends the mouse-up at
    /// once, while the button is still down, so a press-and-hold never lasts.
    /// That release is held back, and sent when the button really comes up,
    /// with the pointer's movement in between sent as drags.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatchingRelease()
        if let monitor = pointerMonitor { NSEvent.removeMonitor(monitor) }
        pointerMonitor = nil
        // Only macOS 27 relays the click: on macOS 26 every event is already
        // where it happened, and the pointer may have moved since it was queued.
        guard window != nil, osMajorVersion >= 27 else { return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Local monitors always run on the main thread; `NSEvent` is not
            // Sendable, so it crosses `assumeIsolated` in a box.
            let incoming = EventBox(event)
            return MainActor.assumeIsolated {
                // nil is a release held back, so it must not fall back to the original.
                guard let self else { return incoming }
                return EventBox(self.route(incoming.event!))
            }.event
        }
    }

    /// What the monitor hands on for `event`: nil holds a release back.
    /// Popover style needs neither change: its click goes to the button,
    /// which acts on the mouse-down wherever it lands, and has no hold.
    private func route(_ event: NSEvent) -> NSEvent? {
        guard !passesClicksThrough, let window, event.window === window else { return event }
        switch event.type {
        case .leftMouseDown:
            stopWatchingRelease()
        case .leftMouseUp:
            if buttonIsDown() {
                watchRelease(like: event, in: window)
                return nil
            }
            stopWatchingRelease()
        default:
            break
        }
        return atPointer(event, in: window)
    }

    private func atPointer(_ event: NSEvent, in window: NSWindow) -> NSEvent {
        let reported = event.locationInWindow
        // Only the relayed click: it sits at the exact middle of the window.
        // An event anywhere else is accurate (macOS 26), and the pointer may
        // have moved since it was queued, so it passes through as it is.
        let middle = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        guard abs(reported.x - middle.x) < 1.5, abs(reported.y - middle.y) < 1.5 else { return event }
        let real = pointerInWindow(window)
        guard hypot(real.x - reported.x, real.y - reported.y) > 2 else { return event }
        return mouseEvent(event.type, at: real, like: event) ?? event
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, like event: NSEvent) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: event.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: event.windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: type == .leftMouseUp ? 0 : 1
        )
    }

    /// Poll the button and the pointer until the button is really released.
    private func watchRelease(like event: NSEvent, in window: NSWindow) {
        stopWatchingRelease()
        var last = pointerInWindow(window)
        let template = EventBox(event)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                let now = self.pointerInWindow(window)
                if !self.buttonIsDown() {
                    self.stopWatchingRelease()
                    if let up = self.mouseEvent(.leftMouseUp, at: now, like: template.event!) { NSApp.sendEvent(up) }
                } else if hypot(now.x - last.x, now.y - last.y) >= 1 {
                    last = now
                    if let drag = self.mouseEvent(.leftMouseDragged, at: now, like: template.event!) { NSApp.sendEvent(drag) }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    private func stopWatchingRelease() {
        releaseWatch?.invalidate()
        releaseWatch = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightMouseDown?(event)
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(event)
    }
}
