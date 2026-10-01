import OSLog
import XCTest
@testable import Insomnia

/// What reaches the unified log is readable by every program running as
/// the user. The message bodies (SSIDs, tmux targets, process names) must
/// arrive there as private data; the file log keeps the full text.
final class LogPrivacyTests: XCTestCase {
    var home: TempHome!

    override func setUp() { home = TempHome() }
    override func tearDown() { home.destroy() }

    func testUnifiedLogRedactsMessageBodiesWhileTheFileKeepsThem() throws {
        let token = "ssid-\(UUID().uuidString)"
        let since = Date()
        Log.info("joining hotspot \(token) on en0 (attempt 1)")
        Log.error("tmux nudge to \(token) rejected")

        // The process reads its own entries back the way `log show` would.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", Paths.bundleIdentifier)
        var messages: [String] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let entries = try store.getEntries(at: store.position(date: since), matching: predicate)
            messages = entries.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
            if messages.count >= 2 { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        if messages.isEmpty {
            throw XCTSkip("the unified log delivered no entries for this process within 10 s")
        }

        XCTAssertGreaterThanOrEqual(messages.count, 2, "only \(messages.count) of the two lines reached the unified log")
        for m in messages {
            XCTAssertFalse(m.contains(token), "unified log carries the message body: \(m)")
        }
        XCTAssertTrue(messages.contains("<private>"), "no entry was redacted: \(messages)")

        let file = try String(contentsOf: home.paths.logFile, encoding: .utf8)
        XCTAssertTrue(file.contains("[info] insomnia: joining hotspot \(token) on en0 (attempt 1)"), file)
        XCTAssertTrue(file.contains("[error] insomnia: tmux nudge to \(token) rejected"), file)
    }
}
