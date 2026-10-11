import XCTest
@testable import Insomnia

/// UNUserNotificationCenter calls its completion handlers on its own queue.
/// A handler isolated to the main actor traps there on Swift 6's executor
/// check; on macOS 15, whose SDK does not mark the handlers sendable, that
/// crashed the app 28 s into its first session. These run the very closures
/// ReminderScheduler hands the center, from a queue that is not the main one.
final class ReminderSchedulerTests: XCTestCase {
    private var home: TempHome!

    override func setUp() async throws {
        home = TempHome()
    }

    override func tearDown() async throws {
        home.destroy()
    }

    private func logLines() -> [String] {
        let text = (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
        // Drop the timestamp: "<time> [level] insomnia: message".
        return text.split(separator: "\n").map { line in
            line.range(of: " [").map { String(line[$0.lowerBound...].dropFirst()) } ?? String(line)
        }
    }

    func testNotificationCenterCallbacksRunOffTheMainQueueAndLogTheAnswer() {
        struct Refused: LocalizedError {
            var errorDescription: String? { "refused" }
        }
        let ran = expectation(description: "every callback returned")
        DispatchQueue.global(qos: .utility).async {
            XCTAssertFalse(Thread.isMainThread)
            ReminderScheduler.authorizationAnswered(true, nil)
            ReminderScheduler.authorizationAnswered(false, nil)
            ReminderScheduler.authorizationAnswered(false, Refused())
            ReminderScheduler.reminderAdded(nil)
            ReminderScheduler.reminderAdded(Refused())
            ran.fulfill()
        }
        wait(for: [ran], timeout: 5)

        XCTAssertEqual(logLines(), [
            "[info] insomnia: notifications not granted",
            "[error] insomnia: notification authorization failed: refused",
            "[error] insomnia: reminder notification failed: refused",
        ])
    }
}
