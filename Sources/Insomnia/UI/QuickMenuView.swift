import SwiftUI

struct QuickMenuView: View {
    let manager: SessionManager
    let model: MenuBarModel
    let onPreset: (TimeInterval) -> Void
    let onToggle: () -> Void
    let onSettings: () -> Void
    let onDetails: () -> Void
    let onQuit: () -> Void
    let onDismiss: () -> Void
    var onToggleAuto: () -> Void = {}
    var onFocusAgent: (AgentJob) -> Void = { _ in }
    /// Fixtures can capture settled content without playing the entrance.
    var animateEntrance = true

    private var starting: Bool { model.phase == .starting }
    private var autoPresentation: AutoMenuBarPresentation { .current(manager: manager, model: model) }
    private var autoVisible: Bool {
        manager.agentAuto?.enabled == true || manager.session?.agentAuto == true
            || (manager.agentAuto?.pauseReason != nil && !manager.isActive)
            || model.autoActionPending || AutoMenuBarPresentation.isRestoring(manager: manager)
    }
    static let durations: [TimeInterval] = [1800, 3600, 7200, 14400, 21600, 28800]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false

    var body: some View {
        GlassEffectContainer(spacing: 6) {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Insomnia").font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(starting || autoPresentation == .checking || autoPresentation == .restoring ? Color.orange : manager.isActive ? Color.green : Color.secondary).frame(width: 5, height: 5)
                    Text(starting ? "Starting" : autoVisible ? autoPresentation.title : manager.isActive ? "Awake" : "Off")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
            QuickSessionSummary(manager: manager, model: model)
            if let auto = manager.agentAuto {
                let title = model.autoActionPending ? "Please wait…" : manager.isActive && manager.session?.agentAuto != true
                    ? "End timer to enable Auto" : autoPresentation.actionTitle
                let allowed = AutoMenuBarPresentation.autoControlEnabled(manager: manager, model: model)
                menuRow(title, symbol: "bolt.circle", action: onToggleAuto)
                    .disabled(!allowed)
                    .opacity(allowed ? 1 : 0.45)
                    .help("Auto holds sleep only for registered agent work. Idle Auto allows normal sleep. Battery floor ≥10%; thermal safety stays on.")
                if autoPresentation == .working || autoPresentation == .checking {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(auto.jobs.prefix(5)), id: \.id) { job in
                            menuRow(job.name, symbol: "terminal") { onFocusAgent(job) }
                                .help("Show \(job.name)")
                        }
                        if auto.jobs.count > 5 {
                            Text("And \(auto.jobs.count - 5) more — see Status details")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                    }
                }
                ForEach(Array(auto.warnings.prefix(3).enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Self.durations, id: \.self) { duration in
                    let allowed = AutoMenuBarPresentation.timerControlsEnabled(manager: manager, model: model)
                        && duration <= manager.config.maxDuration
                    Button { onPreset(duration) } label: {
                        HStack {
                            Text(chipLabel(for: duration)).monospacedDigit()
                            Spacer()
                            Image(systemName: manager.isActive ? "plus" : "play")
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 9))
                        .glassRim(radius: 9)
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!allowed)
                    .opacity(allowed ? 1 : 0.45)
                    .accessibilityLabel("\(manager.isActive ? "Add" : "Start") \(chipLabel(for: duration))")
                }
            }
            if let error = manager.lastError ?? manager.foreignSleepWarning {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            Divider()
            VStack(spacing: 0) {
                if manager.agentAuto?.enabled != true && manager.session?.agentAuto != true {
                    menuRow(starting ? "Starting session…" : manager.isActive ? "End session" : "Start \(chipLabel(for: manager.config.defaultPreset))", symbol: manager.isActive ? "stop.circle" : "play.circle", emphasized: true, action: onToggle)
                        .disabled(!AutoMenuBarPresentation.timerControlsEnabled(manager: manager, model: model))
                        .opacity(AutoMenuBarPresentation.timerControlsEnabled(manager: manager, model: model) ? 1 : 0.45)
                }
                menuRow("Settings", symbol: "gearshape", shortcut: "⌘,", action: onSettings)
                    .keyboardShortcut(",", modifiers: .command)
                menuRow("Status details", symbol: "info.circle", action: onDetails)
                menuRow("Quit Insomnia", symbol: "power", shortcut: "⌘Q", action: onQuit)
                    .keyboardShortcut("q", modifiers: .command)
            }
            Text("Click to toggle menu · ⌘-drag to move")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassRim(radius: 16)
        .opacity(presented || !animateEntrance ? 1 : 0)
        .scaleEffect(reduceMotion || !animateEntrance ? 1 : presented ? 1 : 0.97, anchor: .top)
        .onAppear { withAnimation(Motion.snappy(reduceMotion: reduceMotion)) { presented = true } }
        .onDisappear { presented = false }
        .onExitCommand(perform: onDismiss)
        }
    }

    private func menuRow(_ title: String, symbol: String, shortcut: String? = nil, emphasized: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 12, weight: emphasized ? .medium : .regular))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .modifier(QuickActionSurface(emphasized: emphasized))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(QuietButtonStyle())
    }
}

private struct QuickActionSurface: ViewModifier {
    let emphasized: Bool
    func body(content: Content) -> some View {
        if emphasized {
            content
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 10))
                .glassRim(radius: 10)
        } else {
            content
        }
    }
}

/// Isolates the second-by-second text from the menu's controls.
private struct QuickSessionSummary: View {
    let manager: SessionManager
    let model: MenuBarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let auto = AutoMenuBarPresentation.current(manager: manager, model: model)
        let showAuto = manager.agentAuto?.enabled == true || manager.session?.agentAuto == true
            || (manager.agentAuto?.pauseReason != nil && !manager.isActive)
            || model.autoActionPending || AutoMenuBarPresentation.isRestoring(manager: manager)
        let text = showAuto ? auto.title : manager.isActive || model.phase == .starting
            ? CompactCountdown.text(StatusRootView.countdownText(pending: model.pendingCountdown, live: manager.countdownText, phase: model.phase))
            : CompactCountdown.format(manager.config.defaultPreset)
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .tracking(-1)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                .animation(Motion.tick(reduceMotion: reduceMotion), value: text)
            Text(showAuto ? auto.detail : manager.isActive ? "Your Mac stays awake until the timer ends." : "Default session")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if showAuto, let reason = manager.agentAuto?.pauseReason {
                Text("Paused: \(reason.rawValue)")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
