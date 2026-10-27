import AppKit

/// The invisible key window that exists only while the duration pills are open.
///
/// The pills read the keyboard through a *local* event monitor, which only
/// sees what AppKit routes to this app, and AppKit routes key events to the
/// key window. Insomnia is an `.accessory` app whose whole interface lives in
/// the status bar, so without this it has no window at all and the digits go
/// to whichever app the user was in.
///
/// Activate Insomnia while typing, then yield to the previous app when the
/// pills close. A non-activating panel can leave input in the previous app.
final class KeyCatcherPanel: NSPanel {
    private var previousApplication: NSRunningApplication?
    var onFocusLost: (() -> Void)?

    /// A borderless window refuses key status by default.
    override var canBecomeKey: Bool { true }

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Never take a click: the status item and the global monitor own the
        // mouse while the pills are open.
        ignoresMouseEvents = true
        level = .statusBar
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    func takeFocus() {
        let front = NSWorkspace.shared.frontmostApplication
        if front != .current { previousApplication = front }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }

    func returnFocus() {
        defer { previousApplication = nil }
        guard NSApp.isActive, let previousApplication, !previousApplication.isTerminated else { return }
        NSApp.yieldActivation(to: previousApplication)
        previousApplication.activate()
    }

    override func resignKey() {
        super.resignKey()
        onFocusLost?()
    }

    /// Park the panel on the status item, so it comes up on the screen and the
    /// space the pills are on rather than wherever the window server last put
    /// a 1×1 window.
    func move(toStatusButton button: NSStatusBarButton) {
        guard let anchor = button.window?.convertToScreen(button.bounds) else { return }
        setFrameOrigin(NSPoint(x: anchor.midX, y: anchor.minY))
    }
}
