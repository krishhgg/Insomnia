import SwiftUI

/// Press-and-hold "end session" control in the menu bar popover, shown
/// while a session runs.
///
/// A ring draws around the glyph for `Motion.holdDuration` while the mouse
/// is down; only a completed ring ends the session. Releasing early, or
/// dragging away, springs the ring back with no action, so a stray click
/// on the way to another control cannot kill a session.
struct HoldToEndButton: View {
    let reduceMotion: Bool
    let action: () -> Void

    @State private var progress: CGFloat = 0
    /// Mouse is down and the ring is drawing.
    @State private var holding = false
    /// A press is in flight (even after it was cancelled by dragging away),
    /// so a single gesture never restarts the hold.
    @State private var pressed = false
    @State private var holdTask: Task<Void, Never>?
    /// The pointer is over the ring: a soft fill behind it, like every other
    /// popover button's hover, shown at once.
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private let ringDiameter: CGFloat = 18
    private let lineWidth: CGFloat = DesignTokens.Stroke.ring
    /// Moving the pointer this far cancels the hold, so a drag that happens
    /// to start on the button does not end the session.
    private let cancelDistance: CGFloat = 12

    var body: some View {
        ZStack {
            // The bar's track and glyph opacities, over the popover's own
            // text colour, so the control reads in light and dark alike;
            // in dark mode they are exactly `DesignTokens.Bar` values.
            Circle()
                .fill(Color.primary.opacity(hovering ? DesignTokens.Hover.fill : 0))
            Circle()
                .stroke(Color.primary.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(DesignTokens.accent(for: colorScheme), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.85))
        }
        .frame(width: ringDiameter, height: ringDiameter)
        .scaleEffect(holding && !reduceMotion ? 1.12 : 1)
        .animation(Motion.snappy(reduceMotion: reduceMotion), value: holding)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressed {
                        pressed = true
                        begin()
                    } else if holding, hypot(value.translation.width, value.translation.height) > cancelDistance {
                        release()
                    }
                }
                .onEnded { _ in
                    pressed = false
                    if holding { release() }
                }
        )
        .help("Hold to end the session")
        .accessibilityLabel("End session")
        .accessibilityHint("Press and hold")
        .accessibilityAction { action() }
    }

    /// Start drawing the ring and arm the completion.
    private func begin() {
        holding = true
        let duration = Motion.holdDuration
        withAnimation(.linear(duration: duration)) {
            progress = 1
        }
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, holding else { return }
            fire()
        }
    }

    /// Released or dragged away before the ring closed: no action.
    private func release() {
        holdTask?.cancel()
        holdTask = nil
        holding = false
        withAnimation(Motion.snappy(reduceMotion: reduceMotion)) {
            progress = 0
        }
    }

    private func fire() {
        holdTask = nil
        holding = false
        action()
        // The view normally leaves with the session; if it stays (nothing to
        // end), the ring settles back so a second hold starts clean.
        withAnimation(Motion.snappy(reduceMotion: reduceMotion)) {
            progress = 0
        }
    }
}
