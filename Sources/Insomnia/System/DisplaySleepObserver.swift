import AppKit

/// Reports when every display goes to sleep and when the first one wakes,
/// from NSWorkspace's screensDidSleep and screensDidWake notifications.
/// Nothing runs between them. Lives as long as the app, so the state is
/// known when a session starts. The state at launch is read once and
/// reported before anything else: the app can start, and resume a session,
/// while the displays already sleep.
@MainActor
final class DisplaySleepObserver {
    private let center: NotificationCenter
    /// Set once in `init` and read once more in `deinit`, which does not
    /// run on the main actor; `removeObserver` is safe from any thread.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    /// `center` is NSWorkspace's and `asleepNow` reads the displays; tests
    /// pass their own.
    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        asleepNow: () -> Bool = DisplaySleepObserver.displaysAsleepNow,
        onChange: @escaping @MainActor (_ asleep: Bool) -> Void
    ) {
        self.center = center
        onChange(asleepNow())
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange(asleep) }
            })
        }
    }

    /// Every online display reads asleep. False when none is online or the
    /// list cannot be read.
    nonisolated static func displaysAsleepNow() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else { return false }
        return ids.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    /// Not `isolated deinit`: on macOS 26.2 the Swift runtime frees a
    /// pointer it never allocated while it runs an isolated deinit
    /// (`swift_task_deinitOnExecutorImpl`), and the process aborts.
    deinit {
        tokens.forEach(center.removeObserver)
    }
}
