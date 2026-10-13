import AppKit
import QuartzCore
import SwiftUI

/// An arrowless, transient container for the existing compact controls. It is
/// independent of the status item, which stays installed across all modes.
@MainActor
final class CompactDropdownController: NSObject, NSWindowDelegate {
    let window: NSPanel
    private let hosting: NSHostingView<AnyView>
    private let onDismiss: () -> Void
    private weak var anchor: NSView?
    private var contentSize = CGSize(width: 208, height: 44)
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var anchorClickInProgress = false
    private var pendingSize: CGSize?
    private var hasPendingSizeUpdate = false
    private(set) var isShown = false

    init(content: AnyView, onDismiss: @escaping () -> Void) {
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

    func close() {
        guard isShown else { return }
        isShown = false
        anchorClickInProgress = false
        removeEventMonitors()
        window.orderOut(nil)
        onDismiss()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click on the same icon is handled by toggle. Closing here first
        // would turn that click into another opening instead of a dismissal.
        guard !anchorClickInProgress else { return }
        close()
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
        if Self.shouldDismiss(at: point, panel: window.frame, anchor: source) { close() }
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

    isolated deinit {
        removeEventMonitors()
        NotificationCenter.default.removeObserver(self)
        window.orderOut(nil)
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
