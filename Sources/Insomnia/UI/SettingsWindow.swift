import AppKit
import SwiftUI

/// The settings window, owned by AppKit instead of SwiftUI's `Settings` scene.
///
/// `LSUIElement` apps have no app menu and, most of the time, no key window.
/// `NSApp.sendAction(Selector(("showSettingsWindow:")))` walks the responder
/// chain looking for whoever SwiftUI registered for that action and finds
/// nobody, so the scene never opens. (Quit works from the same menu because
/// `NSApplication.terminate` needs no responder chain at all.) Holding the
/// window ourselves removes the private selector and the guesswork.
@MainActor
final class SettingsWindow: NSObject, NSToolbarDelegate {
    private(set) var window: NSWindow?
    let navigation = SettingsNavigationModel()
    private let content: (SettingsNavigationModel) -> AnyView
    private var keyMonitor: Any?

    init(content: @escaping (SettingsNavigationModel) -> AnyView) {
        self.content = content
        super.init()
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Bring the window up, creating it the first time. An accessory app has
    /// to activate itself first or the window opens behind whatever is front.
    func show() {
        let window = makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Creates the native preferences window without ordering it on screen.
    /// A single model supplies both toolbar selection and pane content.
    func makeWindow() -> NSWindow {
        if let window { return window }
        let host = NSHostingController(rootView: content(navigation))
        // AppKit owns pane resizing. A new Form's intrinsic height must not
        // shrink the window again after the toolbar's animated resize.
        host.sizingOptions = []
        let window = PreferencesWindow(contentViewController: host)
        window.title = navigation.selection.title
        window.identifier = NSUserInterfaceItemIdentifier("insomnia.settings")
        window.styleMask = [.titled, .closable, .resizable]
        window.titleVisibility = .visible
        window.toolbarStyle = .preference
        window.tabbingMode = .disallowed
        let toolbar = NSToolbar(identifier: "insomnia.settings.panes")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = Self.identifier(for: navigation.selection)
        window.toolbar = toolbar
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // Closing settings must not deallocate the window: the status item
        // keeps a reference and reopens the same one.
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 320)
        window.setContentSize(navigation.selection.contentSize)
        window.center()
        #if DEBUG
        if UIPreview.isEnabled && CommandLine.arguments.contains("--ui-preview-compact") {
            // Deterministic capture size without editing saved window preferences.
        } else {
            window.setFrameAutosaveName("insomnia.settings")
        }
        #else
        window.setFrameAutosaveName("insomnia.settings")
        #endif
        // Retain the saved position, then fit the initial pane. A frame
        // saved by the former sidebar layout would leave a large empty pane.
        window.setContentSize(navigation.selection.contentSize)
        window.isRestorable = false
        self.window = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleShortcut(event) ?? false }
            return handled ? nil : event
        }
        return window
    }

    func select(_ page: SettingsPage) {
        guard navigation.selection != page else { return }
        withAnimation(Motion.interface()) { navigation.selection = page }
        guard let window else { return }
        window.title = page.title
        window.toolbar?.selectedItemIdentifier = Self.identifier(for: page)
        if window.isVisible {
            // Let SwiftUI replace the Form before AppKit applies its size.
            // Otherwise first-responder/layout changes can override the resize.
            Task { @MainActor [weak self, weak window] in
                await Task.yield()
                guard let self, let window, self.navigation.selection == page else { return }
                window.contentView?.layoutSubtreeIfNeeded()
                self.resize(window, for: page)
            }
        } else {
            resize(window, for: page)
        }
    }

    private func resize(_ window: NSWindow, for page: SettingsPage) {
        let desired = window.frameRect(forContentRect: NSRect(origin: .zero, size: page.contentSize)).size
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - desired.height, width: desired.width, height: desired.height)
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true, animate: window.isVisible && !Motion.reduceMotion)
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let key = event.charactersIgnoringModifiers,
              let index = Int(key), (1...SettingsPage.allCases.count).contains(index) else { return false }
        select(SettingsPage.allCases[index - 1])
        return true
    }

    private static func identifier(for page: SettingsPage) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("insomnia.settings.\(page.rawValue)")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + SettingsPage.allCases.map(Self.identifier(for:)) + [.flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map(Self.identifier(for:))
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = SettingsPage.allCases.first(where: { Self.identifier(for: $0) == identifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = page.title
        item.paletteLabel = page.title
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
        item.target = self
        item.action = #selector(selectToolbarPane(_:))
        return item
    }

    @objc private func selectToolbarPane(_ sender: NSToolbarItem) {
        guard let page = SettingsPage.allCases.first(where: { Self.identifier(for: $0) == sender.itemIdentifier }) else { return }
        select(page)
    }
}

private final class PreferencesWindow: NSWindow {
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.16 }
}
