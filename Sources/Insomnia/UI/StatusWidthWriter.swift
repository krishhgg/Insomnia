import AppKit

/// Writes `NSStatusItem.length`, once per target.
///
/// Control Center re-lays out the whole menu bar on every change of a status
/// item's length, and the app's next Core Animation commit waits for that
/// relayout: 8 ms on a good pass, 30-40 ms on a bad one, over 100 ms at a
/// session end (measured; see the design spec, revision 4). Driving the
/// length per frame therefore stalls the main thread on every frame, and
/// no pacing or frame-rate request changes that. So the length is written
/// exactly once per layout change, as Apple's own items do, and everything
/// that moves does so inside the item's window: the content is laid out at
/// its final width and its countdown and mark animate in place.
///
/// A repeat of the current width is not written again.
@MainActor
final class StatusWidthWriter {
    private let apply: (CGFloat) -> Void
    private(set) var current: CGFloat?

    /// - Parameter apply: sets the length. Never called twice with the same
    ///   value in a row.
    init(apply: @escaping (CGFloat) -> Void) {
        self.apply = apply
    }

    func write(_ width: CGFloat) {
        guard width != current else { return }
        current = width
        apply(width)
    }
}
