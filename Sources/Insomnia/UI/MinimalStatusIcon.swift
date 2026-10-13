import AppKit
import SwiftUI

/// A remaining-time arc around the existing eye, hosted by the status item
/// so progress and pointer interactions update without opening a popover.
struct MinimalStatusIcon: View {
    let model: MenuBarModel
    let manager: SessionManager
    let reduceMotion: Bool
    let onTap: () -> Void
    let onHold: () -> Void

    @State private var pressed = false
    @State private var displayedProgress = 1.0

    private var isRunning: Bool { manager.isActive }
    private var isStarting: Bool { model.phase == .starting }
    private var canTap: Bool {
        manager.config.menuBarMode == .minimal && !model.minimalBusy && !isStarting && !model.isEnding
    }
    private var canHold: Bool {
        manager.config.menuBarMode == .minimal && !model.isEnding && (isRunning || isStarting)
    }
    private var showsTimer: Bool { (isRunning || isStarting) && !model.isEnding }
    private var progress: Double? {
        // Startup has a cancellable timer immediately, even while the
        // recovery agent is preparing. Confirmation supplies live progress.
        if isStarting { return 1 }
        guard let value = model.minimalProgress, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
    private var transition: Animation {
        reduceMotion ? Motion.reduced : .easeInOut(duration: Motion.collapseDuration)
    }

    private var status: String {
        if model.isEnding { return "Ending session" }
        if let error = manager.lastError { return error }
        if isStarting { return MenuBarModel.startingText }
        if model.minimalBusy { return isRunning ? "Updating session" : "Ending session" }
        if isRunning {
            let remaining = StatusRootView.countdownText(
                pending: model.pendingCountdown, live: manager.countdownText, phase: model.phase
            )
            return remaining.isEmpty ? "Keeping awake" : "Keeping awake, \(remaining) remaining"
        }
        return model.startError ?? "Inactive"
    }

    private var instructions: String {
        if model.isEnding { return "Restoring settings. Right-click for status and Settings." }
        if isStarting { return "Hold to cancel startup. Right-click for Settings." }
        let click = isRunning ? "Click to add the duration set in Settings." : "Click to start the duration set in Settings."
        let hold = isRunning ? " Hold to end the session." : ""
        return "\(click)\(hold) Right-click for Settings."
    }

    var body: some View {
        ZStack {
            // Keep both arc layers mounted through the whole transition.
            // The thin track remains behind elapsed time; the thicker part
            // represents time still available, without relying on color alone.
            ZStack {
                MinimalProgressArc(fraction: 1)
                    .stroke(.primary.opacity(0.45), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                MinimalProgressArc(fraction: displayedProgress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            .frame(width: 20, height: 20)
            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: displayedProgress)
            .opacity(showsTimer ? 1 : 0)
            .scaleEffect(reduceMotion ? 1 : (showsTimer ? 1 : 0.8))
            .animation(transition, value: showsTimer)
            .accessibilityHidden(true)
            .allowsHitTesting(false)

            if reduceMotion {
                // Fixed-size layers crossfade instead of resizing when the
                // user asks for reduced motion.
                EyeMarkView(isRunning: false, reduceMotion: true, size: 17)
                    .opacity(showsTimer ? 0 : 1)
                EyeMarkView(isRunning: true, reduceMotion: true, size: 11)
                    .opacity(showsTimer ? 1 : 0)
            } else {
                EyeMarkView(isRunning: showsTimer, reduceMotion: false, size: 17,
                            animationOverride: transition)
                    .scaleEffect(showsTimer ? 11.0 / 17.0 : 1)
            }
        }
        .opacity(pressed ? 0.65 : 1)
        .animation(transition, value: showsTimer)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .overlay {
            StatusItemPressArea(
                isEnabled: canTap || canHold, sessionActive: canHold,
                onTap: { if canTap { onTap() } }, onHold: { if canHold { onHold() } },
                onPressedChange: { pressed = $0 }
            )
            .accessibilityHidden(true)
        }
        .help("\(status). \(instructions)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Insomnia")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(status)
        .accessibilityHint(instructions)
        .accessibilityAction { if canTap { onTap() } }
        .accessibilityAction(named: Text("End session")) {
            if canHold { onHold() }
        }
        .onChange(of: progress, initial: true) { _, value in
            // Retain the last arc during its exit instead of briefly filling
            // it again when the manager removes the ended session.
            if let value { displayedProgress = value }
        }
    }
}

/// The opening beneath the eye keeps its lashes clear at menu bar size.
/// Animating the path also handles added time without jumping between arcs.
private struct MinimalProgressArc: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let fraction = min(max(fraction, 0), 1)
        guard fraction > 0 else { return path }
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: max(0, min(rect.width, rect.height) / 2 - 1.2),
            startAngle: .degrees(120), endAngle: .degrees(120 + 300 * fraction),
            clockwise: false
        )
        return path
    }
}

/// AppKit owns pointer delivery inside the status item's hosting view. A
/// transparent native hit area avoids relying on SwiftUI gesture recognition
/// in a menu bar window, while the outer SwiftUI view owns accessibility.
struct StatusItemPressArea: NSViewRepresentable {
    let isEnabled: Bool
    let sessionActive: Bool
    let onTap: () -> Void
    let onHold: () -> Void
    let onPressedChange: (Bool) -> Void

    func makeNSView(context: Context) -> MinimalIconMouseView {
        MinimalIconMouseView()
    }

    func updateNSView(_ view: MinimalIconMouseView, context: Context) {
        view.update(
            isEnabled: isEnabled, sessionActive: sessionActive,
            onTap: onTap, onHold: onHold, onPressedChange: onPressedChange
        )
    }

    static func dismantleNSView(_ view: MinimalIconMouseView, coordinator: ()) {
        view.stopTracking()
    }
}

@MainActor
final class MinimalIconMouseView: NSView {
    private var isEnabled = false
    private var sessionActive = false
    private var onTap: () -> Void = {}
    private var onHold: () -> Void = {}
    private var onPressedChange: (Bool) -> Void = { _ in }
    private var press = MinimalIconPress()
    private var initialLocation: CGPoint = .zero
    private var holdTask: Task<Void, Never>?
    private let holdDuration: TimeInterval
    private let clock: () -> TimeInterval

    init(holdDuration: TimeInterval = Motion.holdDuration,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.holdDuration = holdDuration
        self.clock = clock
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { return nil }

    isolated deinit { holdTask?.cancel() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(isEnabled: Bool, sessionActive: Bool,
                onTap: @escaping () -> Void, onHold: @escaping () -> Void,
                onPressedChange: @escaping (Bool) -> Void) {
        let shouldCancel = !isEnabled || self.sessionActive != sessionActive
        self.isEnabled = isEnabled
        self.sessionActive = sessionActive
        self.onTap = onTap
        self.onHold = onHold
        self.onPressedChange = onPressedChange
        if shouldCancel {
            press.cancel()
            cancelHoldTask()
            // updateNSView runs during SwiftUI reconciliation. Publish its
            // visual feedback on the next turn, not from inside that update.
            reportPressedLater()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            stopTracking()
            nextResponder?.mouseDown(with: event)
            return
        }
        guard isEnabled, !press.isPressed else { return }
        initialLocation = convert(event.locationInWindow, from: nil)
        press.begin(at: clock(), sessionActive: sessionActive)
        press.move(to: initialLocation, translation: .zero)
        reportPressed()
        guard !press.isCancelled else { return }
        cancelHoldTask()
        holdTask = Task { @MainActor [weak self] in
            guard let duration = self?.holdDuration else { return }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            guard isEnabled, !NSEvent.modifierFlags.contains(.control) else {
                cancelPress()
                return
            }
            let action = press.holdElapsed(sessionActive: sessionActive)
            holdTask = nil
            perform(action)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !event.modifierFlags.contains(.control) else {
            cancelPress()
            return
        }
        movePress(with: event)
        if press.isCancelled { cancelHoldTask() }
        reportPressed()
    }

    override func mouseUp(with event: NSEvent) {
        movePress(with: event)
        cancelHoldTask()
        let action = press.release(at: clock(), sessionActive: sessionActive, holdDuration: holdDuration)
        reportPressed()
        guard isEnabled, !event.modifierFlags.contains(.control) else { return }
        perform(action)
    }

    override func rightMouseDown(with event: NSEvent) {
        stopTracking()
        nextResponder?.rightMouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    func stopTracking() {
        cancelHoldTask()
        press = MinimalIconPress()
        reportPressedLater()
    }

    private func movePress(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        press.move(to: location, translation: CGSize(
            width: location.x - initialLocation.x, height: location.y - initialLocation.y
        ))
    }

    private func perform(_ action: MinimalIconPress.Action) {
        switch action {
        case .none: break
        case .tap: onTap()
        case .end: onHold()
        }
    }

    private func cancelPress() {
        press.cancel()
        cancelHoldTask()
        reportPressed()
    }

    private func cancelHoldTask() {
        holdTask?.cancel()
        holdTask = nil
    }

    private func reportPressed() { onPressedChange(press.isPressed && !press.isCancelled) }

    private func reportPressedLater() {
        Task { @MainActor [weak self] in self?.reportPressed() }
    }
}

/// One physical press produces at most one command. Keeping this small
/// state machine separate also lets tests cover a release delayed beyond
/// the hold threshold without relying on real-time gesture scheduling.
struct MinimalIconPress {
    enum Action: Equatable { case none, tap, end }

    private(set) var isPressed = false
    private(set) var isCancelled = false
    private var beganAt: TimeInterval = 0
    private var beganActive = false
    private var completedHold = false

    mutating func begin(at time: TimeInterval, sessionActive: Bool) {
        guard !isPressed else { return }
        isPressed = true
        isCancelled = false
        beganAt = time
        beganActive = sessionActive
        completedHold = false
    }

    mutating func move(to location: CGPoint, translation: CGSize) {
        guard isPressed else { return }
        if location.x < 0 || location.x > 20 || location.y < 0 || location.y > 20 ||
            hypot(translation.width, translation.height) > 12 {
            cancel()
        }
    }

    mutating func cancel() {
        // Keep the press claimed until mouse-up; dragging back in, or an
        // operation finishing while the pointer stays down, cannot rearm it.
        if isPressed { isCancelled = true }
    }

    mutating func holdElapsed(sessionActive: Bool) -> Action {
        guard isPressed, !isCancelled, !completedHold else { return .none }
        completedHold = true
        return beganActive && sessionActive ? .end : .none
    }

    mutating func release(at time: TimeInterval, sessionActive: Bool, holdDuration: TimeInterval) -> Action {
        defer { self = MinimalIconPress() }
        guard isPressed, !isCancelled, !completedHold, beganActive == sessionActive else { return .none }
        // If the main thread postponed the hold task until mouse-up, retain
        // hold semantics instead of accidentally treating it as a click.
        if time - beganAt >= holdDuration {
            return beganActive && sessionActive ? .end : .none
        }
        return .tap
    }
}
