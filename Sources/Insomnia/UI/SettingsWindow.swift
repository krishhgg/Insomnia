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
final class SettingsWindow {
    private var window: NSWindow?
    private let content: () -> SettingsView

    init(content: @escaping () -> SettingsView) {
        self.content = content
    }

    /// Bring the window up, creating it the first time. An accessory app has
    /// to activate itself first or the window opens behind whatever is front.
    func show() {
        let window = window ?? make()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible, let form = window.contentView {
            // The form's full height, for the rows it shows now. AppKit
            // fits a resizable window to a shorter screen, and the form
            // scrolls the rest.
            window.setContentSize(form.fittingSize)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func make() -> NSWindow {
        let host = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: host)
        window.title = "Insomnia Settings"
        // Resizable only so it can fit the screen (the form fixes the
        // width). HIG Settings: minimize and zoom dimmed; the menu bar icon
        // reopens it.
        window.styleMask = [.titled, .closable, .resizable]
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // Closing settings must not deallocate the window: the status item
        // keeps a reference and reopens the same one.
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        return window
    }
}
