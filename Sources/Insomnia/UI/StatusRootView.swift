import SwiftUI

/// Everything drawn inside the status item: the eye alone, closed while
/// idle and open while sleep is held, in the menu bar's own label colour.
/// Nothing else ever appears beside it, so the item keeps one width, hugging
/// the eye like any other menu bar icon; the time left lives in the popover.
///
/// The layout reports its width once and the controller writes the status
/// item's length from it (`StatusWidthWriter`). Clicks go to the status bar
/// button under this view (`StatusHostingView` lets them through).
struct StatusRootView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let onWidthChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }

    private var eyeOpen: Bool { Self.eyeOpen(isRunning: manager.isActive, phase: model.phase) }

    /// The eye's size in the bar, in points.
    static let eyeSize: CGFloat = 17
    /// Space either side of the eye: the item's highlight sits this far
    /// outside it, as it does around the system's own icons.
    static let sidePadding: CGFloat = 2.5
    /// The item's whole width: the eye and its padding, and never less.
    static let width: CGFloat = eyeSize + 2 * sidePadding

    /// The eye opens the moment a start is asked for, not when the manager
    /// confirms it: the blink is the first thing that answers the click.
    /// A refused start closes it again. Static so it can be pinned without
    /// a manager.
    static func eyeOpen(isRunning: Bool, phase: MenuBarModel.Phase) -> Bool {
        isRunning || phase == .starting
    }

    private var accessibilityValue: String {
        if manager.isActive, !manager.remainingText.isEmpty { return "Awake, \(manager.remainingText) left" }
        if model.phase == .starting { return "Starting session" }
        return manager.isActive ? "Awake" : "Idle"
    }

    var body: some View {
        EyeMarkView(isRunning: eyeOpen, reduceMotion: reduceMotion, size: Self.eyeSize)
            .accessibilityLabel("Insomnia")
            .accessibilityValue(accessibilityValue)
            .padding(.horizontal, Self.sidePadding)
            .frame(height: NSStatusBar.system.thickness)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                onWidthChange(width)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
