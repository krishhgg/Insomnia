import AppKit
import SwiftUI
import Observation

/// Retained by the status-item controller, including while its dropdown is closed.
@MainActor
@Observable
final class CompactMenuModel {
    let entry = MenuBarModel()
    var isBusy = false
    var isEditing = false
    var isPresented = false
    private(set) var presentationID = 0
    var focusRequest = 0
    /// A local submission fallback, never a saved copy of a manager error.
    var error: String?

    /// Keep drafts across native window dismissal; only presentation and focus change.
    func setPresented(_ presented: Bool) {
        guard isPresented != presented else { return }
        isPresented = presented
        entry.focusVisible = presented
        if presented {
            presentationID += 1
            focusRequest += 1
        }
    }

    func showsInputs(sessionActive: Bool, phase: MenuBarModel.Phase) -> Bool {
        !isBusy && phase != .starting && (!sessionActive || isEditing)
    }

    @discardableResult
    func handleKey(
        _ event: NSEvent, sessionActive: Bool, phase: MenuBarModel.Phase,
        reduceMotion: Bool, onSubmit: () -> Void, onDismiss: () -> Void
    ) -> Bool {
        guard isPresented, showsInputs(sessionActive: sessionActive, phase: phase),
              let command = DurationInputCommand(event) else { return false }
        switch command {
        case .submit: onSubmit()
        case .cancel:
            if sessionActive { isEditing = false } else { onDismiss() }
        default:
            error = nil
            entry.applyInput(command, reduceMotion: reduceMotion)
        }
        return true
    }
}

/// The same duration pills and running controls as the menu bar, housed in
/// the compact dropdown. Layout content and keyboard behavior are shared.
struct CompactMenuView: View {
    @Bindable var model: CompactMenuModel
    let menuBar: MenuBarModel
    let manager: SessionManager
    let onSubmit: () -> Void
    let onEnd: () -> Void
    let onDismiss: () -> Void
    var onContentSizeChange: (CGSize) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv
    @State private var inputWidth: CGFloat = 184

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
    private var isStarting: Bool { menuBar.phase == .starting }
    private var isBusy: Bool { model.isBusy || isStarting }
    private var showsInputs: Bool { model.showsInputs(sessionActive: manager.isActive, phase: menuBar.phase) }
    private var showsEnd: Bool { manager.isActive || isStarting || menuBar.isEnding }
    /// Use the original inline folding duration for content-size changes,
    /// without spatial motion when Reduce Motion is enabled.
    private var resizeAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: Motion.collapseDuration)
    }
    private var countdown: String {
        if menuBar.isEnding { return "Ending\u{2026}" }
        return StatusRootView.countdownText(pending: menuBar.pendingCountdown, live: manager.countdownText, phase: menuBar.phase)
    }
    /// Recovery can fail after the submission finishes. Read its current
    /// error directly so later failures and successful clears stay visible.
    var displayedError: String? { manager.lastError ?? model.error }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if showsInputs {
                    durationFields
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { inputWidth = $0 }
                        .transition(.opacity.animation(resizeAnimation))
                } else {
                    HStack(spacing: DurationPillsView.spacing) {
                        SessionRunningControls(
                            text: countdown, isStarting: isStarting,
                            showEnd: showsEnd,
                            reduceMotion: reduceMotion,
                            isEnabled: model.isPresented && !isBusy,
                            endIsEnabled: model.isPresented && !menuBar.isEnding,
                            usesNativePointer: true,
                            foreground: .primary,
                            onTapCountdown: { model.isEditing = true }, onHoldEnd: onEnd
                        )
                    }
                    .transition(.opacity.animation(resizeAnimation))
                }
            }
            .frame(minHeight: 20)

            if let error = displayedError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: inputWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .fixedSize()
        .padding(12)
        .modifier(CompactContentSize(
            animation: resizeAnimation, isPresented: model.isPresented,
            presentationID: model.presentationID, onSizeChange: onContentSizeChange
        ))
        .background {
            DurationInputKeyResponder(
                active: model.isPresented && showsInputs, focusRequest: model.focusRequest,
                onPresentationChange: model.setPresented,
                onKey: { event in
                    model.handleKey(
                        event, sessionActive: manager.isActive, phase: menuBar.phase,
                        reduceMotion: reduceMotion, onSubmit: onSubmit, onDismiss: onDismiss
                    )
                }
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onExitCommand {
            if manager.isActive, model.isEditing {
                model.isEditing = false
            } else {
                onDismiss()
            }
        }
    }

    private var durationFields: some View {
        HStack(spacing: DurationPillsView.spacing) {
            DurationPillsView(
                model: model.entry, reduceMotion: reduceMotion,
                animateDisclosure: false, isEnabled: model.isPresented && showsInputs,
                onTap: { field in
                    model.entry.applyInput(.focus(field), reduceMotion: reduceMotion)
                    model.focusRequest += 1
                }
            )
        }
    }
}

/// Measure the active controls at their natural size, then animate the outer
/// frame. An explicit frame lets SwiftUI animate the native window as well as
/// its content; a fading outgoing row cannot keep the window at its old width.
private struct CompactContentSize: ViewModifier {
    let animation: Animation?
    let isPresented: Bool
    let presentationID: Int
    let onSizeChange: (CGSize) -> Void
    @State private var measurement: Measurement?

    private struct Measurement: Equatable {
        let size: CGSize
        let presentationID: Int
    }

    /// A reused native window may defer layout while hidden. Use its current
    /// intrinsic content on every opening, even if the previous size is cached.
    private var fittedSize: CGSize? {
        measurement?.presentationID == presentationID ? measurement?.size : nil
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Measurement.self) { proxy in
                Measurement(
                    size: CGSize(width: ceil(proxy.size.width), height: ceil(proxy.size.height)),
                    presentationID: presentationID
                )
            } action: { next in
                guard next != measurement else { return }
                // Opening starts at the correct size, and hidden windows do
                // not replay a resize when they are shown again.
                let motion = fittedSize == nil || !isPresented ? nil : animation
                withAnimation(motion) { measurement = next }
                // Report the natural content, before the animated outer frame.
                // The panel must not retarget itself on every animation frame.
                onSizeChange(next.size)
            }
            .frame(width: fittedSize?.width, height: fittedSize?.height)
            .clipped()
            .windowResizeAnchor(nil)
    }
}
