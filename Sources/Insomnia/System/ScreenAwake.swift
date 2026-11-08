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
/// and the recovery agent has nothing to undo. A process that hangs keeps
/// it, so the assertion also times out at the session's deadline: past it
/// macOS turns the assertion off, as the backstop restores sleep for a
/// session whose app no longer ends it.
protocol DisplayAssertionHolding: Sendable {
    /// Creates the assertion, on for `timeout` seconds, and returns its id.
    func create(name: String, timeout: TimeInterval) throws -> IOPMAssertionID
    /// Moves the assertion's timeout to `timeout` seconds from now. False
    /// when IOKit refused, so the caller keeps the old timeout and tries
    /// again.
    func renew(_ id: IOPMAssertionID, timeout: TimeInterval) -> Bool
    /// Releases the assertion. False when IOKit refused, so the caller keeps
    /// the id and tries again.
    func release(_ id: IOPMAssertionID) -> Bool
}

struct ScreenAwakeError: Error, LocalizedError, Sendable {
    let status: IOReturn

    var errorDescription: String? { "IOPMAssertionCreateWithProperties(PreventUserIdleDisplaySleep) returned \(status)" }
}

/// IOKit power management.
struct IOPMDisplayAssertions: DisplayAssertionHolding {
    func create(name: String, timeout: TimeInterval) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        // On a timeout macOS turns the assertion off and keeps its id, so
        // the release at the session's end still finds it.
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey: kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionLevelKey: IOPMAssertionLevel(kIOPMAssertionLevelOn),
            kIOPMAssertionNameKey: name,
            kIOPMAssertionTimeoutKey: Self.seconds(timeout),
            kIOPMAssertionTimeoutActionKey: kIOPMAssertionTimeoutActionTurnOff,
        ]
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        guard status == kIOReturnSuccess else { throw ScreenAwakeError(status: status) }
        return id
    }

    func renew(_ id: IOPMAssertionID, timeout: TimeInterval) -> Bool {
        let status = IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, Self.seconds(timeout) as CFNumber)
        guard status == kIOReturnSuccess else {
            Log.error("screen awake: IOPMAssertionSetProperty(\(id), TimeoutSeconds) returned \(status)")
            return false
        }
        return true
    }

    /// Whole seconds, rounded up, and at least one: a timeout of 0 would
    /// mean none.
    static func seconds(_ timeout: TimeInterval) -> Int {
        guard timeout.isFinite, timeout > 1 else { return 1 }
        return Int(min(timeout.rounded(.up), Double(Int32.max)))
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
    func create(name: String, timeout: TimeInterval) throws -> IOPMAssertionID { 1 }
    func renew(_ id: IOPMAssertionID, timeout: TimeInterval) -> Bool { true }
    func release(_ id: IOPMAssertionID) -> Bool { true }
}

/// At most one assertion, held while `hold(until:now:)` was the last call,
/// and on until the deadline it was given.
@MainActor
final class ScreenAwake {
    static let assertionName = "Insomnia session: keep the screen on and unlocked"

    private let assertions: any DisplayAssertionHolding
    private var held: IOPMAssertionID?
    /// The deadline the held assertion times out at.
    private(set) var heldUntil: Date?

    var isHeld: Bool { held != nil }

    init(assertions: any DisplayAssertionHolding = NoopDisplayAssertions()) {
        self.assertions = assertions
    }

    /// Holds the assertion until `deadline`, or moves the held one's
    /// timeout there when the deadline moved. Repeating the same deadline
    /// does nothing. A failed create is logged and leaves nothing held, so
    /// the next call tries again. A failed renew keeps the old timeout,
    /// so the next call renews again. Returns whether the hold now lasts
    /// until `deadline`.
    @discardableResult
    func hold(until deadline: Date, now: Date) -> Bool {
        let timeout = deadline.timeIntervalSince(now)
        if let id = held {
            guard heldUntil != deadline else { return true }
            guard assertions.renew(id, timeout: timeout) else {
                Log.error("screen awake: could not move the hold's timeout to the new deadline; the display can sleep and lock the screen at the old one")
                return false
            }
            heldUntil = deadline
            Log.info("screen awake: hold moved to the session's new deadline")
            return true
        }
        do {
            held = try assertions.create(name: Self.assertionName, timeout: timeout)
            heldUntil = deadline
            Log.info("screen awake: display sleep held off for the session")
            return true
        } catch {
            Log.error("screen awake: \(error.localizedDescription); the display can still sleep and lock the screen")
            return false
        }
    }

    /// Releases the assertion. Nothing held does nothing. A failed release
    /// keeps the id, so the next call releases it again. Returns whether
    /// nothing is held now.
    @discardableResult
    func release() -> Bool {
        guard let id = held else { return true }
        guard assertions.release(id) else { return false }
        held = nil
        heldUntil = nil
        Log.info("screen awake: released, idle display sleep and the screen lock are back")
        return true
    }
}
