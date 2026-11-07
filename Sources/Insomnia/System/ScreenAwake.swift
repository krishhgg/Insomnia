import Foundation
import IOKit.pwr_mgt

/// Keeps the screen on and unlocked during a session
/// (`Config.keepScreenAwake`, off by default).
///
/// `pmset -a disablesleep 1` stops system sleep only. The display still
/// sleeps after the `displaysleep` minutes, and with "Require password after
/// screen saver begins or display is turned off" set to Immediately the
/// screen locks right then, which stops agents that drive the screen. This
/// holds a `PreventUserIdleDisplaySleep` assertion, the one `caffeinate -d`
/// holds, from session start to session end, so the display never idles off,
/// the screen saver never starts and the lock never triggers. The lock
/// setting itself is never read or written.
///
/// Nothing is journaled: macOS releases the assertion when the process
/// exits, so a crash or a force-quit restores idle display sleep by itself
/// and the recovery agent has nothing to undo.
protocol DisplayAssertionHolding: Sendable {
    /// Creates the assertion and returns its id.
    func create(name: String) throws -> IOPMAssertionID
    /// Releases the assertion. False when IOKit refused, so the caller keeps
    /// the id and tries again.
    func release(_ id: IOPMAssertionID) -> Bool
}

struct ScreenAwakeError: Error, LocalizedError, Sendable {
    let status: IOReturn

    var errorDescription: String? { "IOPMAssertionCreateWithName(PreventUserIdleDisplaySleep) returned \(status)" }
}

/// IOKit power management.
struct IOPMDisplayAssertions: DisplayAssertionHolding {
    func create(name: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id)
        guard status == kIOReturnSuccess else { throw ScreenAwakeError(status: status) }
        return id
    }

    func release(_ id: IOPMAssertionID) -> Bool {
        let status = IOPMAssertionRelease(id)
        guard status == kIOReturnSuccess else {
            Log.error("screen awake: IOPMAssertionRelease(\(id)) returned \(status)")
            return false
        }
        return true
    }
}

/// Creates nothing. The default for every wiring that does not pass the real
/// one, so no test holds the display of the Mac it runs on.
struct NoopDisplayAssertions: DisplayAssertionHolding {
    func create(name: String) throws -> IOPMAssertionID { 1 }
    func release(_ id: IOPMAssertionID) -> Bool { true }
}

/// At most one assertion, held while `set(true)` was the last call.
@MainActor
final class ScreenAwake {
    static let assertionName = "Insomnia session: keep the screen on and unlocked"

    private let assertions: any DisplayAssertionHolding
    private var held: IOPMAssertionID?

    var isHeld: Bool { held != nil }

    init(assertions: any DisplayAssertionHolding = NoopDisplayAssertions()) {
        self.assertions = assertions
    }

    /// Holds the assertion when `on` and releases it when not. Repeating
    /// the current state does nothing. A failed create is logged and leaves
    /// nothing held, so the next call tries again. A failed release keeps
    /// the id, so the next call releases it again. Returns whether the hold
    /// now matches `on`.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        if on {
            guard held == nil else { return true }
            do {
                held = try assertions.create(name: Self.assertionName)
                Log.info("screen awake: display sleep held off for the session")
                return true
            } catch {
                Log.error("screen awake: \(error.localizedDescription); the display can still sleep and lock the screen")
                return false
            }
        } else {
            guard let id = held else { return true }
            guard assertions.release(id) else { return false }
            held = nil
            Log.info("screen awake: released, idle display sleep and the screen lock are back")
            return true
        }
    }
}
