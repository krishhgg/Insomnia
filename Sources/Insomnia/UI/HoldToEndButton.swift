import SwiftUI

/// Click "end session" control that sits to the right of the countdown.
///
/// Mouse-up ends the session. Dragging more than 12pt away cancels, so a
/// drag that starts on the button does not end the session. On macOS 27 the
/// status item reports every click at its centre, so `StatusHostingView`
/// decides the hit from `NSEvent.mouseLocation` and this gesture often never runs.
struct HoldToEndButton: View {
    let reduceMotion: Bool
    let action: () -> Void

    /// Mouse is down and still inside the cancel distance.
    @State private var holding = false
    /// A press is in flight (even after it was cancelled by dragging away),
    /// so a single gesture never restarts.
    @State private var pressed = false

    private let ringDiameter: CGFloat = 18
    private let lineWidth: CGFloat = 1.6
    /// Moving the pointer this far cancels the click, so a drag that happens
    /// to start on the button does not end the session.
    private let cancelDistance: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.85))
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
                        holding = true
                    } else if holding, hypot(value.translation.width, value.translation.height) > cancelDistance {
                        holding = false
                    }
                }
                .onEnded { _ in
                    let fire = holding
                    pressed = false
                    holding = false
                    if fire { action() }
                }
        )
        .help("Click to end the session")
        .accessibilityLabel("End session")
        .accessibilityHint("Click")
        .accessibilityAction { action() }
    }
}
