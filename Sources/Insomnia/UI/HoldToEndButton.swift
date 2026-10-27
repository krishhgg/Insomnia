import SwiftUI

/// Press-and-hold "end session" control that sits to the right of the
/// countdown in the status item.
///
/// A ring draws around the glyph for `Motion.holdDuration` while the mouse
/// is down; only a completed ring ends the session. Releasing early, or
/// dragging away, springs the ring back with no action, so a stray click
/// while reaching for the menu bar clock cannot kill a session.
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

    private let ringDiameter: CGFloat = 18
    private let lineWidth: CGFloat = 1.6
    /// Moving the pointer this far cancels the hold, so a drag that happens
    /// to start on the button does not end the session.
    private let cancelDistance: CGFloat = 12

    var body: some View {
        ZStack {
            // `Color.primary`, not white: the button sits on the menu bar
            // itself, not inside a pill, so a light bar made a white ring and
            // glyph invisible. Primary follows the bar's appearance.
            Circle()
                .stroke(Color.primary.opacity(0.28), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(brand: BrandPalette.violet), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.75))
        }
        .frame(width: ringDiameter, height: ringDiameter)
        .scaleEffect(holding && !reduceMotion ? 1.12 : 1)
        .animation(Motion.snappy(reduceMotion: reduceMotion), value: holding)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
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
