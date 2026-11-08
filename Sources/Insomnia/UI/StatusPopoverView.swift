import SwiftUI

/// The menu bar popover: everything the status item offers apart from the
/// eye and the countdown.
///
/// Top to bottom: a header with the state in one line; the duration
/// section (preset chips while idle, extend chips while running, each with
/// Custom, which puts out the Days / Hours / Minutes fields with Start or
/// Extend; and hold-to-end while a session runs); the start error, when the manager refused one; the status rows
/// and warnings (`StatusMenu`); and a footer with Settings and Quit.
///
/// Fixed width: long text wraps and the popover grows downwards, never
/// sideways. Everything above the footer scrolls once it would pass
/// `maxScrollHeight`, so a long list of warnings never pushes Settings and
/// Quit off the screen.
struct StatusPopoverView: View {
    /// What the popover's controls do. The controller supplies them.
    struct Actions {
        var commit: () -> Void = {}
        var start: (TimeInterval) -> Void = { _ in }
        var extend: (TimeInterval) -> Void = { _ in }
        var holdToEnd: () -> Void = {}
        var relaunch: (ThrottledBrowser) -> Void = { _ in }
        var stopWaiting: (SavedAudioOutput) -> Void = { _ in }
        var openSettings: () -> Void = {}
        var quit: () -> Void = {}
        var close: () -> Void = {}
    }

    static let width: CGFloat = 300
    /// A chip cell is at least this wide; wider labels widen their cell.
    static let chipMinWidth: CGFloat = 52
    /// The extend chips shown while a session runs.
    static let extendChoices: [TimeInterval] = [30 * 60, 3600]

    let model: MenuBarModel
    let manager: SessionManager
    /// The status rows, read on every draw so the view follows the manager
    /// and the status source (both observable).
    let items: () -> [StatusMenu.Item]
    let actions: Actions
    /// What the header's "until" time is read from; tests inject a clock.
    var now: () -> Date = { Date() }
    /// How tall the part above the footer may grow before it scrolls; nil
    /// reads it from the screen. Tests set it.
    var maxScrollHeight: CGFloat?

    @FocusState private var focused: DurationInput.Field?
    /// Error rows the user clicked open to read in full, by their text.
    @State private var expanded: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnv

    private var reduceMotion: Bool { reduceMotionEnv || Motion.reduceMotion }
    private var running: Bool { model.phase.showsRunningControls && manager.isActive }
    private var starting: Bool { model.phase == .starting }
    /// Any end, also one the manager started (the timer's, `--session
    /// end`'s, a retry): the header reads Ending… and nothing adds time.
    private var ending: Bool { model.endUnderway(manager) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeightCap(max: maxScrollHeight ?? Self.maxScrollHeight(screenHeight: NSScreen.main?.visibleFrame.height)) {
                // The padding is inside the scroll view, so its clip edge is
                // the popover's edge: a shake or a hover fill near the side
                // is not cut off.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: DesignTokens.Space.l) {
                        header
                        Divider()
                        durationSection
                        if let error = model.startError {
                            startError(error)
                        }
                        let rows = StatusMenu.rows(items())
                        if !rows.isEmpty {
                            Divider()
                            statusSection(rows)
                        }
                    }
                    .padding([.horizontal, .top], DesignTokens.Space.l)
                    .padding(.bottom, DesignTokens.Space.l)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            Divider()
                .padding(.horizontal, DesignTokens.Space.l)
            footer
                .padding(DesignTokens.Space.l)
        }
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: actions.close)
        .onAppear { focusHoursIfOut() }
        .onChange(of: model.focusRequest) { focusHoursIfOut() }
        .onChange(of: model.customShown) { focusHoursIfOut() }
    }

    /// The part above the footer may be at most this tall: the screen's
    /// usable height, less room for the footer, the popover's arrow and a
    /// margin. Never below `minScrollHeight`, so a short screen still shows
    /// the header and the time buttons.
    static func maxScrollHeight(screenHeight: CGFloat?) -> CGFloat {
        guard let screenHeight else { return 640 }
        return max(minScrollHeight, screenHeight - 110)
    }

    static let minScrollHeight: CGFloat = 240

    // MARK: Header

    /// "Not keeping your Mac awake", "Starting…", "Ending…" through any
    /// end, or "Awake until 12:40 AM, 2h 31m left". Pure so the copy can be
    /// pinned.
    static func headerText(phase: MenuBarModel.Phase, ending: Bool = false, session: Session?, remaining: String, now: Date, calendar: Calendar = .current) -> String {
        if ending { return MenuBarModel.endingText }
        if let session {
            let sameDay = calendar.isDate(session.endsAt, inSameDayAs: now)
            let style: Date.FormatStyle = sameDay
                ? .dateTime.hour().minute()
                : .dateTime.weekday(.abbreviated).hour().minute()
            let until = session.endsAt.formatted(style)
            return remaining.isEmpty ? "Awake until \(until)" : "Awake until \(until), \(remaining) left"
        }
        if phase == .starting { return MenuBarModel.startingText }
        return "Not keeping your Mac awake"
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Space.m) {
            EyeMarkView(isRunning: manager.isActive || starting, reduceMotion: reduceMotion)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(Self.headerText(
                phase: model.phase,
                ending: ending,
                session: manager.session,
                remaining: manager.remainingText,
                now: now()
            ))
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Duration

    /// The time buttons, then, behind Custom, the Days / Hours / Minutes
    /// fields with Start or Extend; hold-to-end while a session runs.
    private var durationSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.m) {
            chips
            if model.customShown {
                customFields
            }
            if running {
                HStack(spacing: DesignTokens.Space.s) {
                    // Off as the popover closes or an end starts, which
                    // cancels a hold in progress (`HoldToEndButton`). On
                    // again while the manager's end waits for its retry.
                    HoldToEndButton(
                        reduceMotion: reduceMotion,
                        isEnabled: model.popoverShown && model.endIsEnabled(manager),
                        hoverFill: true,
                        action: actions.holdToEnd
                    )
                    Text("Hold to end the session")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The fields come in with the same update that puts them out, and a
    /// focus asked for before they are in the window is dropped: on a
    /// MacBook the popover itself kept it. So it is asked for on the next
    /// turn, once they are there.
    private func focusHoursIfOut() {
        guard model.customShown else { return }
        DispatchQueue.main.async {
            if model.customShown { focused = .hours }
        }
    }

    private var customFields: some View {
        HStack(spacing: DesignTokens.Space.s) {
            ForEach(DurationInput.Field.allCases, id: \.self) { field in
                durationField(field)
            }
            Spacer(minLength: 0)
            // Greyed out until the fields hold a time: every field in range
            // and something above zero. The presets cover "just start".
            Button(running ? "Extend" : "Start", action: actions.commit)
                .buttonStyle(PopoverButtonStyle(kind: .prominent))
                .disabled(starting || ending || !model.popoverInput.isValid)
        }
        .phaseAnimator([CGFloat(0), reduceMotion ? 0 : -4, reduceMotion ? 0 : 4, 0], trigger: model.rejectBounce) { content, dx in
            content.offset(x: dx)
        } animation: { _ in
            Motion.snappy(reduceMotion: reduceMotion)
        }
    }

    static let customTitle = "Custom"

    /// Presets while idle (they start at once), +30m and +1h while running
    /// (they extend at once), and Custom, which puts the fields out or away.
    /// Nothing to press while a start is pending or through an end.
    private var chips: some View {
        let values = running ? Self.extendChoices : manager.config.presets
        // One row of equal chips when they fit; otherwise a wrapping grid
        // (eight presets do not fit 300 pt), and a chip never truncates its
        // label either way.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Space.s) {
                chipButtons(values)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.chipMinWidth), spacing: DesignTokens.Space.s)], alignment: .leading, spacing: DesignTokens.Space.s) {
                chipButtons(values)
            }
        }
        .disabled(starting || ending)
    }

    @ViewBuilder
    private func chipButtons(_ values: [TimeInterval]) -> some View {
        ForEach(values, id: \.self) { seconds in
            Button {
                running ? actions.extend(seconds) : actions.start(seconds)
            } label: {
                chipText(running ? "+\(chipLabel(for: seconds))" : chipLabel(for: seconds))
            }
            .buttonStyle(PopoverButtonStyle(kind: .chip))
        }
        Button {
            model.customShown.toggle()
        } label: {
            chipText(Self.customTitle)
        }
        .buttonStyle(PopoverButtonStyle(kind: .chip, selected: model.customShown))
        .accessibilityValue(model.customShown ? "Shown" : "Hidden")
        .help("Type a time in days, hours and minutes")
    }

    private func chipText(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .frame(maxWidth: .infinity)
    }

    private func durationField(_ field: DurationInput.Field) -> some View {
        let valid = model.popoverInput.isValid(field)
        return TextField(field.placeholder, text: Binding(
            get: { model.texts[field] ?? "" },
            set: { model.texts[field] = $0 }
        ))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.center)
        .monospacedDigit()
        .frame(width: 62)
        .focused($focused, equals: field)
        // Return does nothing until the fields hold a time, like the button.
        .onSubmit { if model.popoverInput.isValid { actions.commit() } }
        .disabled(starting || ending)
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(DesignTokens.Status.error, lineWidth: 1)
                .opacity(valid ? 0 : 1)
                .allowsHitTesting(false)
        }
        .help(field.help)
        .accessibilityLabel(field.placeholder)
    }

    // MARK: Start error

    private func startError(_ text: String) -> some View {
        let summary = ErrorSummary.summarize(text)
        let open = expanded.contains(text)
        return Label {
            Text(open ? text : summary.short)
                .lineLimit(open ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: StatusMenu.warningSymbol)
        }
        .font(.callout)
        .foregroundStyle(DesignTokens.Status.warning)
        .contentShape(Rectangle())
        .onTapGesture { toggle(text, when: summary.full != nil) }
        .help(summary.full ?? "")
        .accessibilityLabel("Start failed: \(summary.short)")
        .accessibilityHint(summary.full ?? "")
    }

    /// A summarised row opens to its full text on a click, and closes again.
    private func toggle(_ text: String, when expandable: Bool) {
        guard expandable else { return }
        if expanded.contains(text) { expanded.remove(text) } else { expanded.insert(text) }
    }

    // MARK: Status

    private func statusSection(_ rows: [StatusMenu.Row]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                statusRow(row)
            }
        }
    }

    private func statusRow(_ row: StatusMenu.Row) -> some View {
        let warning = row.item.kind == .warning
        // Warnings read as a short line; the raw text (paths and all) is
        // the tooltip, the accessibility hint, and the row opened by a click.
        let summary = warning ? ErrorSummary.summarize(row.item.title) : ErrorSummary.Summary(short: row.item.title, full: nil)
        let open = expanded.contains(row.item.title)
        let help = row.item.help ?? summary.full
        return HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.m) {
            Image(systemName: warning ? StatusMenu.warningSymbol : (row.item.symbol ?? "circle.fill"))
                .foregroundStyle(warning ? DesignTokens.Status.warning : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: DesignTokens.Space.xs) {
                if row.item.kind.isAction {
                    actionButton(row.item)
                } else {
                    Text(open ? row.item.title : summary.short)
                        .lineLimit(open ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(row.item.title, when: summary.full != nil) }
                        .accessibilityHint(summary.full ?? "")
                }
                ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in
                    actionButton(action)
                }
            }
        }
        .font(.callout)
        .help(help ?? "")
    }

    @ViewBuilder
    private func actionButton(_ item: StatusMenu.Item) -> some View {
        switch item.kind {
        case let .relaunchBrowser(browser):
            Button(item.title) { actions.relaunch(browser) }
                .buttonStyle(PopoverButtonStyle(kind: .chip))
        case let .stopWaitingForOutput(waiting):
            Button(item.title) { actions.stopWaiting(waiting) }
                .buttonStyle(PopoverButtonStyle(kind: .chip))
        case .info, .warning, .separator, .endSession, .settings, .quit:
            EmptyView()
        }
    }

    // MARK: Footer

    /// The footer badge that marks a build with the scripts/simulate-lid.sh
    /// watcher compiled in, so it is never mistaken for a normal one; nil
    /// in a normal release build. Its text lives behind the same build
    /// flag as the watcher (`LidSimulationBuild.badge`).
    static var lidSimulationBadge: (text: String, help: String)? {
        badge(compiledIn: LidSimulationBuild.isCompiledIn, text: LidSimulationBuild.badge, help: LidSimulationBuild.marker)
    }

    static func badge(compiledIn: Bool, text: String, help: String) -> (text: String, help: String)? {
        guard compiledIn, !text.isEmpty else { return nil }
        return (text, help)
    }

    private var footer: some View {
        HStack {
            Button(action: actions.openSettings) {
                Label(StatusMenu.settingsTitle, systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            if let badge = Self.lidSimulationBadge {
                Text(badge.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignTokens.Space.s)
                    .padding(.vertical, DesignTokens.Space.xxs)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .help(badge.help)
                    .accessibilityLabel(badge.help)
            }
            Spacer()
            Button(StatusMenu.quitTitle, action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(PopoverButtonStyle(kind: .plain))
        // The buttons' hover fill reaches past their labels; outset the row
        // so the labels still line up with the rest of the popover.
        .padding(.horizontal, -PopoverButtonStyle.insets(.plain).leading)
    }
}

/// Lays its one subview out at its ideal height, but no taller than `max`.
/// A scroll view inside takes its content's ideal height, so a short
/// popover hugs its content and a tall one stops at `max` and scrolls.
private struct HeightCap: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, max))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
