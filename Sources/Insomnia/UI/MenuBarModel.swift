import Foundation
import Observation
import SwiftUI

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
    }

    /// Bare Enter with every pill empty starts the default preset, so the
    /// common case is one keystroke. While extending there is no sensible
    /// default duration, so it shakes instead.
    static func commitAction(mode: Mode, typed: TimeInterval?, defaultPreset: TimeInterval) -> CommitAction {
        if let typed { return .run(typed) }
        guard mode == .start, defaultPreset > 0 else { return .reject }
        return .run(defaultPreset)
    }

    enum Phase: Equatable, Sendable {
        case idle
        case entering(Mode)
        /// Enter was pressed on the start pills and the manager has not yet
        /// confirmed a session (the recovery agent can take seconds to
        /// answer, or refuse). Shows the projected countdown
        /// (`pendingCountdown`). Compact and Minimal may cancel the request;
        /// Pills waits for confirmation before showing its end ring.
        case starting
        case running

        var isEntering: Bool {
            if case .entering = self { return true }
            return false
        }

        /// The default menu bar's running controls belong to a confirmed
        /// session only; a pending start must not draw its end ring.
        var showsRunningControls: Bool { self == .running }
    }

    /// What the item reads while a start is pending and there is no
    /// projected countdown to show.
    static let startingText = "Starting\u{2026}"
    /// What the Compact panel and the popover read through an end.
    static let endingText = "Ending\u{2026}"
    /// What the item reads next to the pills after the manager refused a
    /// start. Short on purpose: the full reason is in the right-click menu.
    static let startFailedText = "Couldn\u{2019}t start"

    var phase: Phase = .idle
    /// Compensates for native status-item resizing so the Pills eye travels
    /// smoothly instead of jumping when its controls unfold to the right.
    var widthMotion: StatusItemWidthMotion?
    /// Minimal mode keeps the status item interactive without opening an
    /// editor. Block another click while its session request is settling.
    var minimalBusy = false
    /// An end this controller asked for (`sessionEndPending`). Ending
    /// disables both additions and repeated cancellation, even while the
    /// manager is draining a startup or restoring an already-cleared session.
    var isEnding = false

    /// `isEnding`, or an end the manager runs or owes, whoever asked for it:
    /// the timer, a floor, `--session end`, a retry (`SessionManager.isEnding`).
    /// The popover and the Compact panel take no additions while it lasts.
    func endUnderway(_ manager: SessionManager) -> Bool {
        isEnding || manager.isEnding
    }

    /// The manager's end changed nothing and waits for its retry with the
    /// session still active (`SessionManager.endIsWaiting`), and no end of
    /// this controller runs: End may ask for it again now.
    func endCanBeRetried(_ manager: SessionManager) -> Bool {
        !isEnding && manager.endIsWaiting
    }

    /// End can be asked for: no end is underway, or the one owed waits and
    /// can be tried again.
    func endIsEnabled(_ manager: SessionManager) -> Bool {
        !endUnderway(manager) || endCanBeRetried(manager)
    }

    /// The fraction of the confirmed session left, for Minimal's arc, or nil
    /// in the other styles. The controller reads it from the session's start
    /// and end on a session change, a style change or a wake, and on its own
    /// slow timer, which stops while every display sleeps (`syncMinimalTick`).
    var minimalProgress: Double?
    /// Concise start failure shown beside the pills; cleared on the next
    /// commit, open or collapse. In Popover style it is the manager's
    /// reason, shown under the popover's fields until a retry or a session.
    var startError: String?
    /// The label is drawn only while the pills are up: a retry (Enter)
    /// hides it at once but keeps its text, and so its room in the layout,
    /// until the slots leave, so the bar is written once, then.
    var startErrorShown: Bool { startError != nil && phase.isEntering }
    var input = DurationInput()
    /// The exact length of a request that put `input` in place without
    /// typing it (a popover chip, a Minimal click), with the input it
    /// wrote. The fields hold whole minutes, so a 90 s preset reads 1m.
    /// A digit or a backspace drops it.
    var keptRequest: KeptRequest?
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
    /// What is typed into the Days, Hours and Minutes fields, as typed.
    var texts: [DurationInput.Field: String] = [:]
    /// The popover is on screen.
    var popoverShown = false
    /// The Days, Hours and Minutes fields are out (the Custom button). The
    /// popover opens on the time buttons alone, so this is closed on every
    /// open unless a refused start left its value in the fields.
    var customShown = false
    /// The battery draw and time left the popover shows, read when it
    /// opens and again when the battery's percent or charging state
    /// changes while it is up. Its redraws (typing, the header's minute)
    /// read this, not IOKit.
    var popoverPower: PopoverPower?

    struct PopoverPower: Equatable {
        var watts: Double?
        var timeRemaining: BatteryTimeRemaining?
    }

    /// Countdown text shown while the manager is still starting the session.
    var pendingCountdown: String?
    /// The session a pending start or extension will become; the controller
    /// ticks `pendingCountdown` off it at 1 Hz while the phase is `.starting`
    /// and the countdown shows the time left.
    var pendingProjection: StartProjection?

    // Animation triggers. Views run a bounce whenever one of these changes.
    var iconBounce: Int = 0
    var focusBounce: Int = 0
    var rejectBounce: Int = 0
    /// Bumped each time the popover opens, so the view can put the cursor
    /// in the Hours field when the fields are out.
    var focusRequest: Int = 0

    var mode: Mode? {
        if case let .entering(m) = phase { return m }
        return nil
    }

    /// The popover's fields read through `DurationInput`, which owns the
    /// validation: a field over its ceiling or not a number is invalid,
    /// and `total` is nil until something non-zero and valid is typed.
    /// The pills keep their own digits in `input`.
    var popoverInput: DurationInput { DurationInput(texts: texts) }

    struct KeptRequest: Equatable, Sendable {
        let input: DurationInput
        let seconds: TimeInterval
    }

    /// What a submit of `input` asks for: the kept request's exact length
    /// while `input` is still what that request wrote, otherwise the
    /// typed time.
    var submittedTotal: TimeInterval? {
        if let keptRequest, keptRequest.input == input { return keptRequest.seconds }
        return input.total
    }

    func clearFields() {
        texts = [:]
    }

    /// Edit the duration pills in either presentation using the original
    /// menu bar focus and rejection feedback. Submission and dismissal
    /// belong to their controller.
    @discardableResult
    func applyInput(_ command: DurationInputCommand, reduceMotion: Bool) -> Bool {
        switch command {
        case let .focus(field):
            focus(field, reduceMotion: reduceMotion)
        case .next:
            focus(focused.next, reduceMotion: reduceMotion)
        case .previous:
            focus(focused.previous, reduceMotion: reduceMotion)
        case let .digit(digit):
            let field = focused
            keptRequest = nil
            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                if input.append(digit: digit, to: field) {
                    if !input.canAcceptDigit(in: field), field != .minutes {
                        focused = field.next
                        focusBounce += 1
                    }
                } else {
                    rejectBounce += 1
                }
            }
        case .backspace:
            let field = focused
            keptRequest = nil
            withAnimation(Motion.base(reduceMotion: reduceMotion)) {
                if !input.backspace(field), field != .days {
                    focused = field.previous
                    focusBounce += 1
                }
            }
        case .ignore:
            break
        case .submit, .cancel:
            return false
        }
        return true
    }

    private func focus(_ field: DurationInput.Field, reduceMotion: Bool) {
        withAnimation(Motion.snappy(reduceMotion: reduceMotion)) {
            focused = field
            focusVisible = true
        }
        focusBounce += 1
    }

    /// The session a start or an extension pressed at some moment will
    /// become, reduced to what the countdown needs: the same deadline and the
    /// same shape the manager will use, so the live text replaces the
    /// projection without a jump.
    struct StartProjection: Equatable, Sendable {
        let endsAt: Date
        let shape: CountdownShape
        let style: CountdownStyle

        /// What the countdown reads at `now`.
        func countdown(at now: Date) -> String {
            SessionMath.countdownText(endsAt: endsAt, shape: shape, style: style, now: now)
        }

        /// The bar's countdown at `now`, at minute resolution like
        /// `SessionManager.remainingText`.
        func shortCountdown(at now: Date) -> String {
            SessionMath.formatRemaining(SessionMath.remaining(until: endsAt, at: now))
        }
    }

    /// Project a start pressed at `now`. Pure, so it can be checked without
    /// a manager.
    static func projectedStart(
        now: Date,
        duration: TimeInterval,
        maxDuration: TimeInterval,
        style: CountdownStyle = .remaining
    ) -> StartProjection {
        let session = SessionMath.newSession(now: now, duration: duration, maxDuration: maxDuration)
        return StartProjection(endsAt: session.endsAt, shape: session.countdownShape, style: style)
    }

    /// The countdown a start pressed at `now` reads at that moment.
    static func projectedStartCountdown(now: Date, duration: TimeInterval, maxDuration: TimeInterval) -> String {
        projectedStart(now: now, duration: duration, maxDuration: maxDuration).countdown(at: now)
    }
}
