import SwiftUI

/// Only this subtree observes the 1 Hz countdown. The eye, glass fields and
/// their layout do not need to be recomputed for a digit change.
struct StatusCountdownView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let reduceMotion: Bool
    let onTap: () -> Void
    var onOpenMenu: () -> Void = {}

    var body: some View {
        let text = CompactCountdown.text(StatusRootView.countdownText(
            pending: model.pendingCountdown,
            live: manager.countdownText,
            phase: model.phase
        ))
        Button(action: onTap) {
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                .animation(Motion.tick(reduceMotion: reduceMotion), value: text)
                .padding(.trailing, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click or right-click to toggle quick actions.")
        .accessibilityLabel(model.phase == .starting ? "Starting session. Toggle quick actions" : "\(text) hours and minutes remaining. Toggle quick actions")
        .accessibilityAction(named: Text("Toggle quick actions"), onOpenMenu)
    }
}
