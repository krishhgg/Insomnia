import SwiftUI

/// The duration controls shared by the menu bar and its compact dropdown.
/// The caller owns the row so these slots keep the same spacing next to
/// the eye and one another in either presentation.
struct DurationPillsView: View {
    static let spacing: CGFloat = 7

    let model: MenuBarModel
    let reduceMotion: Bool
    var animateDisclosure = true
    var isEnabled = true
    let onTap: (DurationInput.Field) -> Void

    private static let hiddenPillScale: CGFloat = 0.55
    /// Measured slot widths stay fixed while their contents fold or unfold.
    @State private var pillWidths: [DurationInput.Field: CGFloat] = [:]

    var body: some View {
        ForEach(Array(DurationInput.Field.allCases.enumerated()), id: \.element) { index, field in
            let shown = !animateDisclosure || index < model.visiblePills
            let collapsing = animateDisclosure && !shown && model.pillsCollapsing && !reduceMotion
            let fullSize = shown || reduceMotion
            let scale: CGFloat = collapsing ? Motion.collapseScale : (fullSize ? 1 : Self.hiddenPillScale)
            let travel: CGFloat = collapsing ? collapseTravel(index: index) : 0
            PillView(
                field: field,
                text: model.input.text(for: field),
                focused: model.focused == field,
                valid: model.input.isValid(field),
                glowVisible: model.focusVisible && isEnabled,
                focusBounce: model.focusBounce,
                rejectBounce: model.rejectBounce,
                reduceMotion: reduceMotion,
                onTap: { if isEnabled { onTap(field) } }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                pillWidths[field] = width
            }
            .scaleEffect(scale, anchor: .leading)
            .offset(x: -travel)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(isEnabled)
            .accessibilityHidden(!shown)
            // A slot born visible springs in once. A hidden slot waits for
            // its stagger step; removal never holds the surrounding layout.
            // The dropdown presents all three unchanged in its native reveal.
            .transition(.asymmetric(
                insertion: animateDisclosure && shown ? Motion.pillTransition(reduceMotion: reduceMotion) : .identity,
                removal: .identity
            ))
            .zIndex(Double(10 - index))
        }
    }

    /// Collapse each slot towards the first one, keeping layout stationary.
    /// An unmeasured slot still shrinks and fades in place.
    private func collapseTravel(index: Int) -> CGFloat {
        let before = DurationInput.Field.allCases.prefix(index).reduce(CGFloat(0)) {
            $0 + (pillWidths[$1] ?? 0)
        }
        return before + Self.spacing * CGFloat(index)
    }
}

/// The same countdown and hold-to-end control in both presentations.
/// Direct children let the caller use the shared duration-row spacing.
struct SessionRunningControls: View {
    let text: String
    let isStarting: Bool
    let showEnd: Bool
    let reduceMotion: Bool
    var isEnabled = true
    /// Compact mode can cancel pending work while adding time is disabled.
    /// The default mode retains its existing confirmed-session requirement.
    var endIsEnabled: Bool? = nil
    var usesNativePointer = false
    var foreground: Color = .white
    let onTapCountdown: () -> Void
    let onHoldEnd: () -> Void

    var body: some View {
        Button(action: onTapCountdown) {
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.tick(reduceMotion: reduceMotion), value: text)
                .padding(.trailing, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isStarting)
        .transition(Motion.countdownTransition(reduceMotion: reduceMotion))
        .help("Click to add time")
        .accessibilityLabel(isStarting ? "Starting session" : "Time remaining")
        .accessibilityValue(text)
        .accessibilityHint("Activate to add time")

        if showEnd {
            HoldToEndButton(
                reduceMotion: reduceMotion, foreground: foreground,
                isEnabled: endIsEnabled ?? (isEnabled && !isStarting),
                usesNativePointer: usesNativePointer, action: onHoldEnd
            )
            .disabled(!(endIsEnabled ?? (isEnabled && !isStarting)))
            .transition(Motion.ringTransition(reduceMotion: reduceMotion))
        }
    }
}
