import Foundation
import Observation

/// UI state for the status item and its popover. The controller mutates it;
/// the views only read it, apart from the duration fields, which the
/// popover's text fields write through `texts`.
@MainActor
@Observable
final class MenuBarModel {
    enum Mode: Equatable, Sendable {
        /// Enter starts a new session.
        case start
        /// Enter extends the running session.
        case extend
    }

    /// What Enter does with the fields as they stand.
    enum CommitAction: Equatable {
        case run(TimeInterval)
        /// Nothing to act on: shake the fields.
        case reject
    }

    /// Bare Enter with every field empty starts the default preset, so the
    /// common case is one keystroke. While extending there is no sensible
    /// default duration, so it shakes instead.
    static func commitAction(mode: Mode, typed: TimeInterval?, defaultPreset: TimeInterval) -> CommitAction {
        if let typed { return .run(typed) }
        guard mode == .start, defaultPreset > 0 else { return .reject }
        return .run(defaultPreset)
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// A start was asked for and the manager has not yet confirmed a
        /// session (the recovery agent can take seconds to answer, or
        /// refuse). The bar shows the projected countdown
        /// (`pendingCountdown`); nothing that acts on a session is offered.
        case starting
        case running

        /// The countdown and the hold-to-end control belong to a confirmed
        /// session only; a pending start must not draw them.
        var showsRunningControls: Bool { self == .running }
    }

    /// What the bar and the popover header read while a start is pending
    /// and there is no projected countdown to show.
    static let startingText = "Starting\u{2026}"
    /// What the popover says when the manager refused a start and left no
    /// reason of its own.
    static let startFailedText = "Couldn\u{2019}t start"

    var phase: Phase = .idle
    /// Why the last start was refused, shown in the popover in
    /// `DesignTokens.Status.warning`. Cleared by the next start or extend,
    /// and when a session comes up.
    var startError: String?
    /// What is typed into the Days, Hours and Minutes fields, as typed.
    var texts: [DurationInput.Field: String] = [:]
    /// The popover is on screen.
    var popoverShown = false
    /// The Days, Hours and Minutes fields are out (the Custom button). The
    /// popover opens on the time buttons alone, so this is closed on every
    /// open unless a refused start left its value in the fields.
    var customShown = false
    /// Short countdown the bar shows while the manager is still starting
    /// (or extending) the session, at minute resolution like the live one.
    var pendingCountdown: String?
    /// The session a pending start will become; the controller ticks
    /// `pendingCountdown` off it while the phase is `.starting`.
    var pendingProjection: StartProjection?

    /// Animation trigger: the fields shake whenever this changes.
    var rejectBounce: Int = 0
    /// Bumped each time the popover opens, so the view can put the cursor
    /// in the Hours field when the fields are out.
    var focusRequest: Int = 0

    /// The typed fields read through `DurationInput`, which owns the
    /// validation: a field over its ceiling or not a number is invalid,
    /// and `total` is nil until something non-zero and valid is typed.
    var input: DurationInput { DurationInput(texts: texts) }

    func clearFields() {
        texts = [:]
    }

    /// The session a start pressed at some moment will become, reduced to
    /// what the countdown needs: the same deadline and the same shape the
    /// manager will use, so the live text replaces the projection without a
    /// jump.
    struct StartProjection: Equatable, Sendable {
        let endsAt: Date
        let shape: CountdownShape

        /// The full countdown (seconds included) at `now`.
        func countdown(at now: Date) -> String {
            SessionMath.formatCountdown(remaining: SessionMath.remaining(until: endsAt, at: now), shape: shape)
        }

        /// The bar's countdown at `now`, at minute resolution like
        /// `SessionManager.remainingText`.
        func shortCountdown(at now: Date) -> String {
            SessionMath.formatRemaining(SessionMath.remaining(until: endsAt, at: now))
        }
    }

    /// Project a start pressed at `now`. Pure, so it can be checked without
    /// a manager.
    static func projectedStart(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> StartProjection {
        let session = SessionMath.newSession(now: now, duration: duration, maxDuration: maxDuration)
        return StartProjection(endsAt: session.endsAt, shape: session.countdownShape)
    }

    /// The full countdown a start pressed at `now` reads at that moment.
    static func projectedStartCountdown(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> String {
        projectedStart(now: now, duration: duration, maxDuration: maxDuration).countdown(at: now)
    }
}
