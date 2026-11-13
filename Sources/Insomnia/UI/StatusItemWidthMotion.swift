import AppKit
import Observation
import SwiftUI

/// Animates the width people see without repeatedly resizing the system's
/// status item. macOS reserves space at the item's fixed right edge; the
/// reveal effect below compensates for that reservation while the content
/// moves inside it.
@MainActor
@Observable
final class StatusItemWidthMotion {
    /// The space currently reserved by the native status item.
    private(set) var reservedWidth: CGFloat = 0
    /// The animated width. SwiftUI interpolates this value in the reveal
    /// effect, so an interrupted animation continues from its visible frame.
    private(set) var displayedWidth: CGFloat = 0

    private let writer: StatusWidthWriter
    private let duration: TimeInterval
    private var target: CGFloat?
    private var generation = 0

    init(writer: StatusWidthWriter, duration: TimeInterval = Motion.itemResizeDuration) {
        self.writer = writer
        self.duration = duration
    }

    /// Covers a delayed first rendering frame before releasing native space.
    var settleDuration: TimeInterval { duration + Motion.collapseSettleMargin }

    /// A grow reserves room immediately. A shrink keeps its old reservation
    /// until the content reaches the compact position, then gives the space
    /// back in one native write. A newer request invalidates that landing.
    func retarget(_ width: CGFloat, reduceMotion: Bool) {
        // A repeated layout report must not restart a shrink's settle timer.
        // Reduce Motion can still finish a reservation pending at this target.
        guard target != width || (reduceMotion && reservedWidth != width) else { return }
        target = width
        generation += 1
        let generation = self.generation

        if reservedWidth == 0 || reduceMotion {
            withoutAnimation {
                reservedWidth = width
                displayedWidth = width
                writer.write(width)
            }
            return
        }

        if width > reservedWidth {
            // Only displayedWidth is animatable. Changing the reservation
            // adds the same amount to the content's local x compensation,
            // cancelling the window's move on this first frame.
            withoutAnimation {
                reservedWidth = width
                writer.write(width)
            }
        }

        withAnimation(.easeInOut(duration: duration)) {
            displayedWidth = width
        }

        guard width < reservedWidth else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDuration) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.withoutAnimation {
                self.reservedWidth = width
                self.displayedWidth = width
                self.writer.write(width)
            }
        }
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
}

/// The native item starts at `rightEdge - reservedWidth`. Its content starts
/// at `reservedWidth - displayedWidth`, so the screen position is always
/// `rightEdge - displayedWidth`, including a native resize mid-animation.
/// The reservation itself never interpolates.
nonisolated struct StatusItemRevealEffect: GeometryEffect {
    var reservedWidth: CGFloat
    var displayedWidth: CGFloat

    var animatableData: CGFloat {
        get { displayedWidth }
        set { displayedWidth = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: reservedWidth - displayedWidth, y: 0))
    }
}
