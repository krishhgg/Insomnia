import Foundation
import Observation

/// UI state for the status item. The controller mutates it; the views only
/// read it. Content state (`visiblePills`, `focusVisible`, `focused`,
/// `input`) is set inside `withAnimation` blocks; layout state (`phase`,
/// `slotsPresent`, `startError`) outside any animation, so the status item
/// changes width once per open and once per close instead of on every frame.
@MainActor
@Observable
final class MenuBarModel {
    enum Mode: Equatable, Sendable {
        /// Enter starts a new session.
        case start
        /// Enter extends the running session (reached by clicking the mark or
        /// the countdown while a session is running).
        case extend
    }

    /// What Enter does with the pills as they stand.
    enum CommitAction: Equatable {
        case run(TimeInterval)
        /// Nothing to act on: shake the focused pill.
        case reject
        /// The time would end past the maximum session (`Config.maxDuration`
        /// from now): shake and say how much still fits, never shorten it
        /// without saying so. `allowed` is what could be entered instead.
        case tooLong(allowed: TimeInterval)
    }

    /// Bare Enter with every pill empty starts the default preset, so the
    /// common case is one keystroke. While extending there is no sensible
    /// default duration, so it shakes instead. A time that would put the end
    /// past `maxDuration` from now (`remaining` is the live session's time
    /// left while extending) is refused with the allowance rather than
    /// clamped: the user typed a number and gets it, or hears why not.
    static func commitAction(mode: Mode, typed: TimeInterval?, defaultPreset: TimeInterval, maxDuration: TimeInterval, remaining: TimeInterval = 0) -> CommitAction {
        let allowed = max(maxDuration, SessionMath.minimumDuration) - max(remaining, 0)
        if let typed {
            return typed > allowed ? .tooLong(allowed: allowed) : .run(typed)
        }
        guard mode == .start, defaultPreset > 0 else { return .reject }
        return defaultPreset > allowed ? .tooLong(allowed: allowed) : .run(defaultPreset)
    }

    /// Label beside the pills for a refused `tooLong`: "Up to 1d", "Up to
    /// 1d30m" (every unit that still fits, floored to the minute, so the
    /// user can type it back), or "At the maximum" once nothing more fits.
    static func tooLongText(allowed: TimeInterval) -> String {
        allowed >= SessionMath.minimumDuration ? "Up to \(exactLabel(for: allowed))" : "At the maximum"
    }

    enum Phase: Equatable, Sendable {
        case idle
        case entering(Mode)
        /// Enter was pressed on the start pills and the manager has not yet
        /// confirmed a session (the recovery agent can take seconds to
        /// answer, or refuse). Shows the projected countdown
        /// (`pendingCountdown`) and nothing that acts on a session.
        case starting
        case running

        var isEntering: Bool {
            if case .entering = self { return true }
            return false
        }

        /// The countdown and the hold-to-end ring belong to a confirmed
        /// session only; a pending start must not draw them.
        var showsRunningControls: Bool { self == .running }
    }

    /// What the item reads while a start is pending and there is no
    /// projected countdown to show.
    static let startingText = "Starting\u{2026}"
    /// What the item reads next to the pills after the manager refused a
    /// start. Short on purpose: the full reason is in the right-click menu.
    static let startFailedText = "Couldn\u{2019}t start"

    var phase: Phase = .idle
    /// Concise start failure, or a refused over-maximum time, shown beside
    /// the pills; cleared on the next commit, open or collapse.
    var startError: String?
    /// The label is drawn only while the pills are up: a retry (Enter)
    /// hides it at once but keeps its text, and so its room in the layout,
    /// until the slots leave, so the bar is written once, then.
    var startErrorShown: Bool { startError != nil && phase.isEntering }
    var input = DurationInput()
    var focused: DurationInput.Field = .hours
    /// The three pill slots are in the layout. Set outside any animation, so
    /// the status item widens once when they arrive and narrows once when the
    /// last one has retracted; `visiblePills` animates the content inside them.
    var slotsPresent: Bool = false
    /// How many pill slots show their content right now (0...3); stepped for
    /// the stagger. Scale and opacity only: the slots themselves stay put.
    var visiblePills: Int = 0
    /// A close is folding the pills shut: a hidden pill travels
    /// towards the eye, shrinks and fades instead of retracting in place.
    /// Set when the retract begins; cleared when the slots leave, and by a
    /// reopen or a refused start, which bring the pills back.
    var pillsCollapsing: Bool = false
    /// Focus glow fades in once the pills have landed.
    var focusVisible: Bool = false
    /// Countdown text shown while the manager is still starting the session.
    var pendingCountdown: String?
    /// The session a pending start will become; the controller ticks
    /// `pendingCountdown` off it at 1 Hz while the phase is `.starting`.
    var pendingProjection: StartProjection?

    // Animation triggers. Views run a bounce whenever one of these changes.
    var iconBounce: Int = 0
    var focusBounce: Int = 0
    var rejectBounce: Int = 0

    var mode: Mode? {
        if case let .entering(m) = phase { return m }
        return nil
    }

    /// The session a start pressed at some moment will become, reduced to
    /// what the countdown needs: the same deadline and the same shape the
    /// manager will use, so the live text replaces the projection without a
    /// jump.
    struct StartProjection: Equatable, Sendable {
        let endsAt: Date
        let shape: CountdownShape

        /// What the countdown reads at `now`.
        func countdown(at now: Date) -> String {
            SessionMath.formatCountdown(remaining: SessionMath.remaining(until: endsAt, at: now), shape: shape)
        }
    }

    /// Project a start pressed at `now`. Pure, so it can be checked without
    /// a manager.
    static func projectedStart(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> StartProjection {
        let session = SessionMath.newSession(now: now, duration: duration, maxDuration: maxDuration)
        return StartProjection(endsAt: session.endsAt, shape: session.countdownShape)
    }

    /// The countdown a start pressed at `now` reads at that moment.
    static func projectedStartCountdown(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> String {
        projectedStart(now: now, duration: duration, maxDuration: maxDuration).countdown(at: now)
    }
}
