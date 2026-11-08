import Foundation

/// What to do, frame by frame, after a press on the status item took key
/// status from the catcher panel while the pills are open (macOS 27 does
/// that on every press). A pill takes the click on release and focus with
/// it; until the catcher is key again the answer is to wait while the button
/// is down, and to collapse once it has been up for `grace`. A new press
/// starts the count again, so an earlier release never folds the pills
/// under a later press.
struct RefocusWait {
    enum Step: Equatable {
        case wait
        /// The catcher is key again: stop watching.
        case refocused
        /// Nothing took focus back: close the pills.
        case collapse
    }

    /// Long enough for the held-back release, the pill's tap and the app's
    /// activation, which together take a few frames.
    static let grace: TimeInterval = 0.2

    private var releasedAt: TimeInterval?

    mutating func step(buttonDown: Bool, catcherIsKey: Bool, now: TimeInterval) -> Step {
        if catcherIsKey { return .refocused }
        if buttonDown {
            releasedAt = nil
            return .wait
        }
        guard let releasedAt else {
            self.releasedAt = now
            return .wait
        }
        return now - releasedAt >= Self.grace ? .collapse : .wait
    }
}
