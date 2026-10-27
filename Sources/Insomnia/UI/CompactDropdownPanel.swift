import AppKit
import QuartzCore
import SwiftUI

/// An arrowless, transient container for the existing compact controls. It is
/// independent of the status item, which stays installed across all modes.
@MainActor
final class CompactDropdownController: NSObject, NSWindowDelegate {
    /// How the panel moves focus between apps. Tests pass a recorder, so a
    /// run neither reads nor changes the app in front on the Mac.
    struct AppFocus {
        var frontmost: @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
        var isActive: @MainActor () -> Bool = { NSApp.isActive }
        var hasKeyWindow: @MainActor () -> Bool = { NSApp.keyWindow != nil }
        var activate: @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }
        var yield: @MainActor (NSRunningApplication) -> Void = { app in
            NSApp.yieldActivation(to: app)
            app.activate()
        }
    }

    let window: NSPanel
    private let hosting: NSHostingView<AnyView>
    private let focus: AppFocus
    private let onDismiss: () -> Void
    /// The app the user was in when the panel opened, to give focus back to
    /// when it closes; nil when that was Insomnia itself.
    private(set) var previousApplication: NSRunningApplication?
    private weak var anchor: NSView?
    private var contentSize = CGSize(width: 208, height: 44)
    /// Read once more in `deinit`, which does not run on the main actor;
    /// `NSEvent.removeMonitor` is safe from any thread.
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var globalMonitor: Any?
    private var anchorClickInProgress = false
    private var pendingSize: CGSize?
    private var hasPendingSizeUpdate = false
    private(set) var isShown = false

    init(content: AnyView, focus: AppFocus = AppFocus(), onDismiss: @escaping () -> Void) {
        self.focus = focus
        self.onDismiss = onDismiss
        hosting = NSHostingView(rootView: content)
        window = CompactDropdownPanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 208, height: 44)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        window.delegate = self
        window.title = "Insomnia"
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isMovable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none

        let material = CompactDropdownMaterial(frame: NSRect(origin: .zero, size: contentSize))
        hosting.frame = material.bounds
        hosting.autoresizingMask = [.width, .height]
        material.addSubview(hosting)
        window.contentView = material
        (window as? CompactDropdownPanel)?.onCancel = { [weak self] in self?.close() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    func toggle(relativeTo view: NSView) {
        if isShown { close() } else { show(relativeTo: view) }
    }

    func show(relativeTo view: NSView) {
        guard view.window != nil else { return }
        anchor = view
        // Layout can be deferred while hidden. Resolve the current controls
        // before ordering the retained panel front again.
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        if Self.isValidSize(fitted) { contentSize = Self.rounded(fitted) }
        guard let target = targetFrame(size: contentSize) else { return }
        window.setFrame(target, display: false)
        guard !isShown else { return }
        isShown = true
        anchorClickInProgress = false
        installEventMonitors()
        // Activate first, as `KeyCatcherPanel.takeFocus` does: a key panel
        // in an app that is not active can leave the digits going to the app
        // in front.
        let front = focus.frontmost()
        previousApplication = front == .current ? nil : front
        focus.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Called with the shared view's natural padded size, never its animated
    /// frame. Coalescing also avoids window layout reentry from SwiftUI layout.
    func updateContentSize(_ size: CGSize) {
        guard Self.isValidSize(size) else { return }
        pendingSize = Self.rounded(size)
        guard !hasPendingSizeUpdate else { return }
        hasPendingSizeUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasPendingSizeUpdate = false
            guard let next = self.pendingSize else { return }
            self.pendingSize = nil
            self.resize(to: next)
        }
    }

    /// Escape, a second click on the eye and a mode change give focus back
    /// to the app the user was in. A caller that hands focus to something of
    /// its own (Settings, the right-click menu) passes false.
    func close(returnFocus: Bool = true) {
        guard isShown else { return }
        isShown = false
        anchorClickInProgress = false
        removeEventMonitors()
        window.orderOut(nil)
        onDismiss()
        if returnFocus { self.returnFocus() }
    }

    /// Yield to the app the user was in, once. Nothing moves if another app
    /// has already taken focus, or a window of this app such as Settings is
    /// key, or the panel is open again.
    func returnFocus() {
        defer { previousApplication = nil }
        guard !isShown, focus.isActive(), !focus.hasKeyWindow(),
              let previousApplication, !previousApplication.isTerminated else { return }
        focus.yield(previousApplication)
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click on the same icon is handled by toggle. Closing here first
        // would turn that click into another opening instead of a dismissal.
        // Ordering the panel out in `close` also resigns key; that close has
        // already started and decides about focus itself.
        guard isShown, !anchorClickInProgress else { return }
        // Focus went to another app or another window: it stays there, as
        // it does when the Pills lose focus.
        previousApplication = nil
        close(returnFocus: false)
    }

    func windowWillClose(_ notification: Notification) { close() }

    @objc private func screenParametersChanged() { close() }

    private func resize(to size: CGSize) {
        guard contentSize != size else { return }
        contentSize = size
        guard isShown, let target = targetFrame(size: size) else { return }
        guard !Motion.reduceMotion else {
            window.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.collapseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        }
    }

    private func targetFrame(size: CGSize) -> NSRect? {
        guard let anchor, let sourceWindow = anchor.window else { return nil }
        let source = sourceWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: source.midX, y: source.midY)) })
                ?? sourceWindow.screen ?? NSScreen.main else { return nil }
        return Self.frame(size: size, anchor: source, visibleFrame: screen.visibleFrame)
    }

    /// AppKit screen coordinates, including displays with negative origins.
    /// The left and top edges stay attached to the button as content resizes,
    /// unless the display edge requires shifting the panel to keep it visible.
    static func frame(size: CGSize, anchor: NSRect, visibleFrame: NSRect) -> NSRect {
        let margin: CGFloat = 6
        let gap: CGFloat = 2
        let usable = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(size.width, max(1, usable.width))
        let height = min(size.height, max(1, usable.height))
        let x = min(max(anchor.minX, usable.minX), usable.maxX - width)
        let top = min(anchor.minY - gap, visibleFrame.maxY - gap)
        let y = max(top - height, usable.minY)
        return NSRect(x: round(x), y: round(y), width: width, height: height)
    }

    /// Excluding the anchor is essential: it already owns the toggle action.
    static func shouldDismiss(at point: NSPoint, panel: NSRect, anchor: NSRect?) -> Bool {
        !panel.contains(point) && !(anchor?.contains(point) ?? false)
    }

    private func anchorFrame() -> NSRect? {
        guard let anchor, let source = anchor.window else { return nil }
        return source.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    private func handlePointer(_ event: NSEvent) {
        guard isShown else { return }
        let point: NSPoint
        if let eventWindow = event.window {
            point = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            point = NSEvent.mouseLocation
        }
        if event.type == .leftMouseUp || event.type == .rightMouseUp || event.type == .otherMouseUp {
            // Let the status button's action run before clearing this guard.
            DispatchQueue.main.async { [weak self] in self?.anchorClickInProgress = false }
            return
        }
        let source = anchorFrame()
        anchorClickInProgress = source?.contains(point) == true
        guard Self.shouldDismiss(at: point, panel: window.frame, anchor: source) else { return }
        close(returnFocus: false)
        // A click that brings another app forward leaves focus there. One
        // that does not, such as a click on another menu bar item, gives it
        // back once the click has had its turn, as for the Pills.
        DispatchQueue.main.async { [weak self] in self?.returnFocus() }
    }

    private func installEventMonitors() {
        removeEventMonitors()
        let events: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer(event) }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePointer(event) }
        }
    }

    private func removeEventMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private static func isValidSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func rounded(_ size: CGSize) -> CGSize {
        CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Not `isolated deinit`, for the macOS 26.2 runtime abort described on
    /// `DisplaySleepObserver`. The status item controller owns this one for
    /// the life of the app and releases it on the main thread.
    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        NotificationCenter.default.removeObserver(self)
        MainActor.assumeIsolated { [window] in window.orderOut(nil) }
    }
}

private final class CompactDropdownPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Native material, vibrancy and shadow follow the system's appearance and
/// accessibility settings; only the arrowless shape belongs to this app.
private final class CompactDropdownMaterial: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
