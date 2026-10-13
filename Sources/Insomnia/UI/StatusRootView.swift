import SwiftUI

/// Everything drawn inside the status item: the mark, the three pill slots
/// while entering, or the countdown while a session runs or starts.
///
/// The layout here changes only on state the controller sets outside any
/// animation transaction (`slotsPresent`, `phase` and `startError`), and
/// reports its width once per such change; the controller writes the
/// status item's length to it once (`StatusWidthWriter`), decoupled from
/// this layout. Everything that animates inside (the pills staggering in and out,
/// the focus ring, the countdown and the ring coming and going) is scale,
/// offset and opacity. Default's reveal compensates for the native item's
/// right-anchored resizing, so the eye glides while its controls unfold to
/// the right; native space is released only after the return settles.
struct StatusRootView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let onTapIcon: () -> Void
    let onTapPill: (DurationInput.Field) -> Void
    let onTapCountdown: () -> Void
    let onHoldEnd: () -> Void
    let onWidthChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
    private var compact: Bool { manager.config.compactMode }
    private var minimal: Bool { manager.config.menuBarMode == .minimal }
    /// Sleep is held right now (journal-backed), independent of the UI phase.
    private var isRunning: Bool { manager.isActive }
    /// Both, not either: the phase can lag the manager by a hop when a
    /// session ends, and that window must not offer an end ring and a
    /// countdown for a session that is already gone.
    private var showsRunningControls: Bool { model.phase.showsRunningControls && isRunning }
    /// A pending start shows its projected countdown; a confirmed session its
    /// live one.
    private var showsCountdown: Bool { model.phase == .starting || showsRunningControls }
    /// The eye opens the moment Enter starts a session, not when the manager
    /// confirms it: the blink is the first thing that answers the keystroke.
    /// A refused start closes it again with the pills coming back.
    private var eyeOpen: Bool { isRunning || model.phase == .starting }

    private var countdownText: String {
        Self.countdownText(pending: model.pendingCountdown, live: manager.countdownText, phase: model.phase)
    }

    /// What the countdown reads. A projection, when there is one, wins over
    /// the live text: an extension typed over a running session shows its
    /// new end at Enter, not when the manager confirms it. Static so the
    /// precedence can be pinned without a manager.
    static func countdownText(pending: String?, live: String, phase: MenuBarModel.Phase) -> String {
        if let pending { return pending }
        if !live.isEmpty { return live }
        // A start with no projection; should not happen but keeps the view total.
        return phase == .starting ? MenuBarModel.startingText : ""
    }

    var body: some View {
        HStack(spacing: DurationPillsView.spacing) {
            if minimal {
                MinimalStatusIcon(
                    model: model, manager: manager, reduceMotion: reduceMotion,
                    onTap: onTapIcon, onHold: onHoldEnd
                )
            } else {
                icon
            }
            // What comes and goes with the layout carries its own animation
            // on its transition (`Motion.countdownTransition` and friends):
            // the branch switches outside any animation, and an
            // `.animation(_:value:)` on this container did not reach it.
            if !compact && !minimal && model.slotsPresent {
                DurationPillsView(model: model, reduceMotion: reduceMotion, onTap: onTapPill)
                if let error = model.startError {
                    startError(error)
                        .opacity(model.startErrorShown ? 1 : 0)
                        .animation(Motion.base(reduceMotion: reduceMotion), value: model.startErrorShown)
                }
            } else if !compact && !minimal && showsCountdown {
                SessionRunningControls(
                    text: countdownText, isStarting: model.phase == .starting,
                    showEnd: showsRunningControls, reduceMotion: reduceMotion,
                    onTapCountdown: onTapCountdown, onHoldEnd: onHoldEnd
                )
            }
        }
        .padding(.leading, 6)
        // Never animated: `slotsPresent` can land in the same transaction as
        // a `withAnimation` (a refused start reopens the pills in one turn),
        // and an interpolated inset would report a width per frame.
        .animation(nil) { $0.padding(.trailing, !compact && !minimal && model.slotsPresent ? 8 : 6) }
        .frame(height: NSStatusBar.system.thickness)
        .fixedSize()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            onWidthChange(width)
        }
        .modifier(StatusItemRevealEffect(
            reservedWidth: !compact && !minimal ? (model.widthMotion?.reservedWidth ?? 0) : 0,
            displayedWidth: !compact && !minimal ? (model.widthMotion?.displayedWidth ?? 0) : 0
        ))
        // The host is kept as wide as the widest content it has held, so the
        // content must sit at its leading edge rather than centred in it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A closed eye while idle; it opens while sleep is held, so the app
    /// visibly does something even when Low Power Mode is not showing.
    private var icon: some View {
        EyeMarkView(isRunning: eyeOpen, reduceMotion: reduceMotion)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .phaseAnimator([CGFloat(1), reduceMotion ? 1 : 0.86, 1], trigger: model.iconBounce) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in
                Motion.snappy(reduceMotion: reduceMotion)
            }
            .onTapGesture(perform: onTapIcon)
            .accessibilityLabel("Insomnia")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isRunning ? "Keeping awake" : (model.phase == .starting ? "Starting" : "Inactive"))
            .help(compact ? "Open Insomnia" : "Insomnia")
    }

    /// The manager refused the start: say so next to the pills the value is
    /// still in. The full reason lives in the right-click menu.
    private func startError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(brand: BrandPalette.violet))
            .lineLimit(1)
            .fixedSize()
            .transition(Motion.errorTransition(reduceMotion: reduceMotion))
            .accessibilityLabel("Start failed")
    }
}
