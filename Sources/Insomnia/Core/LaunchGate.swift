import Foundation

/// One Insomnia runs at a time: the process that holds the alive lock (see
/// AppAliveLock). backstop.sh reads that lock as proof that the app behind
/// a session is alive, so a copy without it must never own one: a session
/// it started would outlive its crash, because the backstop would still see
/// the other copy's lock. Launch Services keeps one instance, but `open -n`
/// or running the binary directly gives two. The copy that cannot take the
/// lock does nothing at all (no reconcile, no menu, no session, no end on
/// quit), says why, and quits.
@MainActor
struct LaunchGate {
    let aliveLock: AppAliveLock
    let notifier: any Notifying
    /// Covers a backstop probe, which holds the lock for a moment. A hold
    /// that outlasts it is another Insomnia.
    var timeout: TimeInterval = 2

    static let anotherCopyTitle = "Insomnia is already running"
    static let lockFailedTitle = "Insomnia did not start"

    /// Takes the alive lock, then watches for output device changes, runs
    /// `start` and reconciles. Taken before reconcile, so the first backstop
    /// run after launch already sees this process, and never released: the
    /// kernel drops it when the process exits, however that happens. Without
    /// the lock none of these run (a device change during the wait or after
    /// the refusal restores nothing), the user is told why, and the result
    /// is false for the caller to quit; the notification has reached the
    /// system by then.
    func open(manager: SessionManager, start: () -> Void) async -> Bool {
        let title: String
        let why: String
        do {
            if try await aliveLock.acquire(timeout: timeout) {
                Log.info("alive lock held")
                manager.watchOutputDevices()
                start()
                await manager.reconcile()
                return true
            }
            title = Self.anotherCopyTitle
            why = "Another copy of Insomnia holds \(aliveLock.path), so this one quit without changing anything. Use the one in the menu bar."
        } catch {
            title = Self.lockFailedTitle
            why = "Insomnia could not take its lock \(aliveLock.path) (\(error.localizedDescription)), so it cannot tell whether another copy is running. It quit without changing anything."
        }
        Log.error(why)
        await notifier.postBeforeExit(title: title, body: why)
        return false
    }
}
