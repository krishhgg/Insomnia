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
/// offset and opacity, anchored at the leading edge so the bar reads as
/// growing out of the mark; the bar narrows only once the content on its
/// way out has gone.
struct StatusRootView: View {
    let model: MenuBarModel
    let manager: SessionManager
    let onTapIcon: () -> Void
    let onTapPill: (DurationInput.Field) -> Void
    let onTapCountdown: () -> Void
    let onHoldEnd: () -> Void
    let onWidthChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    /// Scale of a pill slot's content while hidden; the same shape as
    /// `Motion.pillTransition`, driven by `visiblePills` instead of by
    /// inserting and removing the pill (which would move the layout).
    private static let hiddenPillScale: CGFloat = 0.55
    /// Gap between the mark and the slots, and between the slots.
    private static let slotSpacing: CGFloat = 7
    /// Each slot's laid-out width, for the distance a collapsing pill
    /// travels; a fixed slot's width never changes once measured.
    @State private var pillWidths: [DurationInput.Field: CGFloat] = [:]

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
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
        HStack(spacing: Self.slotSpacing) {
            icon
            // What comes and goes with the layout carries its own animation
            // on its transition (`Motion.countdownTransition` and friends):
            // the branch switches outside any animation, and an
            // `.animation(_:value:)` on this container did not reach it.
            if model.slotsPresent {
                pills
                if let error = model.startError {
                    startError(error)
                        .opacity(model.startErrorShown ? 1 : 0)
                        .animation(Motion.base(reduceMotion: reduceMotion), value: model.startErrorShown)
                }
            } else if showsCountdown {
                countdown
                if showsRunningControls {
                    HoldToEndButton(reduceMotion: reduceMotion, action: onHoldEnd)
                        .transition(Motion.ringTransition(reduceMotion: reduceMotion))
                }
            }
        }
        .padding(.leading, 6)
        // Never animated: `slotsPresent` can land in the same transaction as
        // a `withAnimation` (a refused start reopens the pills in one turn),
        // and an interpolated inset would report a width per frame.
        .animation(nil) { $0.padding(.trailing, model.slotsPresent ? 8 : 6) }
        .frame(height: NSStatusBar.system.thickness)
        .fixedSize()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            onWidthChange(width)
        }
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
    }

    /// All three slots are in the layout whenever they are present;
    /// `visiblePills` only scales, moves and fades each slot's content, so
    /// the stagger never moves the layout. A hidden pill has two shapes:
    /// retracted in place (the open stagger's starting point, scaled down
    /// from its leading edge), and while `pillsCollapsing` (a close)
    /// folded towards the eye: shifted left by its own distance from the
    /// first slot, so all three converge on the mark, and shrunk to
    /// `Motion.collapseScale`. The farthest pill leaves first (the stagger
    /// steps `visiblePills` down), so the pills still up always run
    /// unbroken from the eye and each one slides under its neighbour
    /// (`zIndex`) as the bar folds shut. Reduce Motion: opacity only.
    private var pills: some View {
        ForEach(Array(DurationInput.Field.allCases.enumerated()), id: \.element) { index, field in
            let shown = index < model.visiblePills
            let collapsing = !shown && model.pillsCollapsing && !reduceMotion
            let fullSize = shown || reduceMotion
            let scale: CGFloat = collapsing ? Motion.collapseScale : (fullSize ? 1 : Self.hiddenPillScale)
            let travel: CGFloat = collapsing ? collapseTravel(index: index) : 0
            PillView(
                field: field,
                text: model.input.text(for: field),
                focused: model.focused == field,
                valid: model.input.isValid(field),
                glowVisible: model.focusVisible,
                focusBounce: model.focusBounce,
                rejectBounce: model.rejectBounce,
                reduceMotion: reduceMotion,
                maxDuration: manager.config.maxDuration,
                onTap: { onTapPill(field) }
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                pillWidths[field] = width
            }
            .scaleEffect(scale, anchor: .leading)
            .offset(x: -travel)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
            // A slot born already shown (the first pill when its stagger step
            // lands in the same transaction as the slots, every pill when a
            // refused start puts them straight back) has no hidden frame to
            // spring from, so it springs in through the same shape as a
            // transition. One born hidden must not: its stagger step would
            // then compound with a transition still in flight. Removal is
            // instant either way, so a leaving slot never holds the layout.
            .transition(.asymmetric(insertion: shown ? Motion.pillTransition(reduceMotion: reduceMotion) : .identity, removal: .identity))
            .zIndex(Double(10 - index))
        }
    }

    /// How far the pill in slot `index` travels to put its leading edge on
    /// the first slot's: the slots before it and the gaps between. Zero for
    /// the first slot, which shrinks and fades where it is (its leading
    /// edge already abuts the mark). A slot not yet measured contributes
    /// nothing, so the pill still shrinks and fades in place.
    private func collapseTravel(index: Int) -> CGFloat {
        let before = DurationInput.Field.allCases.prefix(index).reduce(CGFloat(0)) { $0 + (pillWidths[$1] ?? 0) }
        return before + Self.slotSpacing * CGFloat(index)
    }

    /// The live countdown while running, or the projected one while a start
    /// is pending: the manager has to arm the recovery agent and disable
    /// sleep first, and either can take seconds. The projection is what the
    /// session will read once confirmed, so the live text replaces it
    /// without a jump; the hold-to-end ring waits for the confirmation.
    private var countdown: some View {
        Text(countdownText)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(Motion.tick(reduceMotion: reduceMotion), value: countdownText)
            .padding(.trailing, 1)
            .transition(Motion.countdownTransition(reduceMotion: reduceMotion))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapCountdown)
            .accessibilityLabel(model.phase == .starting ? "Starting session" : countdownText)
    }

    /// The manager refused the start, or the time typed is over the maximum
    /// session: say so next to the pills the value is still in. The full
    /// reason for a refused start lives in the right-click menu.
    private func startError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(brand: BrandPalette.violet))
            .lineLimit(1)
            .fixedSize()
            .transition(Motion.errorTransition(reduceMotion: reduceMotion))
            .accessibilityLabel(text)
    }
}
