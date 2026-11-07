import SwiftUI

/// Reports the laid-out width of the view it is attached to, once per layout
/// change.
///
/// `onGeometryChange(for:of:action:)` is macOS 15 (Package.swift targets
/// macOS 14), so the same number comes from a `GeometryReader` behind the
/// view: the reader is laid out with the width of the content in front of it,
/// and its width is read outside any animation transaction. A background
/// takes no part in layout itself, so attaching it never changes the size it
/// reports.
extension View {
    func onLayoutWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        action(width)
                    }
            }
        )
    }
}
