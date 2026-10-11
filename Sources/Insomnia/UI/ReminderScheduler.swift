import Foundation
import UserNotifications

/// One `Timer` at endsAt − 5 min that posts the "5 minutes left" reminder.
/// Rescheduled on extend, cancelled on end. Running unbundled (`swift run`)
/// there is no notification center to talk to; the reminder is logged.
@MainActor
final class ReminderScheduler {
    static let lead: TimeInterval = 5 * 60

    private var timer: Timer?
    private(set) var scheduledFor: Date?
    private var authorizationRequested = false

    /// Bundled apps only: `UNUserNotificationCenter.current()` traps when
    /// there is no bundle proxy for the process.
    static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Keep the timer in step with the session deadline.
    func sync(endsAt: Date?) {
        guard let endsAt else {
            cancel()
            return
        }
        let fireAt = endsAt.addingTimeInterval(-Self.lead)
        if scheduledFor == fireAt { return }
        timer?.invalidate()
        guard fireAt > Date() else {
            // Less than five minutes to go: nothing to remind about.
            scheduledFor = nil
            timer = nil
            return
        }
        let t = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire(endsAt: endsAt) }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scheduledFor = fireAt
        requestAuthorizationIfNeeded()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        scheduledFor = nil
    }

    private func fire(endsAt: Date) {
        scheduledFor = nil
        timer = nil
        let body = "Sleep is restored at \(endsAt.formatted(date: .omitted, time: .shortened)). Extend from the menu bar."
        Log.info("reminder: 5 minutes left")
        guard Self.canNotify else {
            Log.info("reminder not posted: not running from an app bundle")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "5 minutes left"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "insomnia.reminder", content: content, trigger: nil)
        // @Sendable: the center calls back on its own queue. Unmarked, the
        // closure inherits this class's main-actor isolation, and Swift 6
        // traps on the executor check (the macOS 15 SDK does not mark these
        // completion handlers sendable).
        UNUserNotificationCenter.current().add(request) { @Sendable error in
            if let error {
                Log.error("reminder notification failed: \(error.localizedDescription)")
            }
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested, Self.canNotify else { return }
        authorizationRequested = true
        // @Sendable for the same reason as in fire(endsAt:): off the main queue.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable granted, error in
            if let error {
                Log.error("notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.info("notifications not granted")
            }
        }
    }
}
