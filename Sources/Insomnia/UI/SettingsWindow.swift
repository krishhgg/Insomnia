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
    private let content: () -> AnyView

    init(content: @escaping () -> AnyView) {
        self.content = content
    }

    /// Bring the window up, creating it the first time. An accessory app has
    /// to activate itself first or the window opens behind whatever is front.
    func show() {
        let window = window ?? make()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// A sidebar window as System Settings draws it: the sidebar runs up
    /// under the title bar, the toolbar holds the pane's title (SwiftUI
    /// bridges `navigationTitle` into the window), and there is no
    /// minimize or zoom button, as the HIG asks of a settings window.
    private func make() -> NSWindow {
        let host = NSHostingController(rootView: content())
        host.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: host)
        // The bridged `navigationTitle` names the pane from the first
        // switch on; the pane the window opens on is named here.
        window.title = SettingsPane.stored.title
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // Closing settings must not deallocate the window: the status item
        // keeps a reference and reopens the same one.
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 740, height: 580))
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.isRestorable = false
        return window
    }
}
