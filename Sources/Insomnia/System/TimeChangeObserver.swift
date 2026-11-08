import Foundation

/// Reports a change to how a clock time reads: the time zone, the system
/// clock, the calendar day (midnight) or the locale (12 or 24 hour). The end
/// time countdown has no timer, so these are the only times it needs
/// formatting again. Lives as long as the app.
@MainActor
final class TimeChangeObserver {
    static let names: [Notification.Name] = [
        .NSSystemTimeZoneDidChange,
        .NSSystemClockDidChange,
        .NSCalendarDayChanged,
        NSLocale.currentLocaleDidChangeNotification,
    ]

    private let center: NotificationCenter
    /// Set once in `init` and read once more in `deinit`, which does not
    /// run on the main actor; `removeObserver` is safe from any thread.
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    /// `center` is the default one; tests pass their own.
    init(center: NotificationCenter = .default, onChange: @escaping @MainActor () -> Void) {
        self.center = center
        for name in Self.names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            })
        }
    }

    /// Not `isolated deinit`, for the macOS 26.2 runtime abort described on
    /// `DisplaySleepObserver`.
    deinit {
        tokens.forEach(center.removeObserver)
    }
}
