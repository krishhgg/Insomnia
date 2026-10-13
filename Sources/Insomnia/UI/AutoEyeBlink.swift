import Foundation

/// A decorative Auto heartbeat, not evidence that sleep is held. SwiftUI
/// owns/cancels the task; each cycle uses the existing PR eye transitions.
@MainActor
enum AutoEyeBlink {
    static func enabled(armed: Bool, reduceMotion: Bool) -> Bool {
        armed && !reduceMotion
    }

    /// Armed Auto rests open, including when Reduce Motion suppresses blinking.
    static func displayOpen(armed: Bool, reduceMotion: Bool, blinkOpen: Bool, fallbackOpen: Bool) -> Bool {
        armed ? (reduceMotion || blinkOpen) : fallbackOpen
    }

    static func run(
        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        setOpen: @MainActor (Bool) -> Void
    ) async throws {
        try Task.checkCancellation()
        setOpen(true)
        while true {
            // Rest open first; closing is only a brief blink.
            try await sleep(.seconds(Motion.autoBlinkPause))
            try Task.checkCancellation()
            setOpen(false)
            try await sleep(.seconds(Motion.autoBlinkCloseDuration))
            try Task.checkCancellation()
            setOpen(true)
            try await sleep(.seconds(Motion.autoBlinkOpenDuration))
            try Task.checkCancellation()
        }
    }
}
