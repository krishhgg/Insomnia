import AppKit
import SwiftUI

/// Native cursor rectangles avoid a global push/pop cursor stack and are
/// removed by AppKit when their owning view leaves the window.
private struct HandCursorRegion: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> HandCursorView { HandCursorView() }

    func updateNSView(_ view: HandCursorView, context: Context) {
        if view.cursorEnabled != enabled {
            view.cursorEnabled = enabled
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

final class HandCursorView: NSView {
    var cursorEnabled = true
    private var previousBounds = CGRect.zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        if cursorEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func layout() {
        super.layout()
        if bounds != previousBounds {
            previousBounds = bounds
            window?.invalidateCursorRects(for: self)
        }
    }
}

extension View {
    func handCursor() -> some View {
        background(HandCursorRegion().frame(maxWidth: .infinity, maxHeight: .infinity))
    }
}
