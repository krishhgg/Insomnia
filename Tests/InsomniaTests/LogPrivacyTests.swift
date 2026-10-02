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
        // A line that is private by construction shows whether this Mac has
        // private data logging enabled: then the store returns every body
        // in clear and the redaction cannot be observed, whatever Log does.
        let probe = Logger(subsystem: Paths.bundleIdentifier, category: "privacy-probe")
        probe.info("probe \(token, privacy: .private)")

        // The process reads its own entries back the way `log show` would.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@", Paths.bundleIdentifier)
        var entries: [OSLogEntryLog] = []
        let deadline = Date().addingTimeInterval(10)
        repeat {
            entries = try store.getEntries(at: store.position(date: since), matching: predicate)
                .compactMap { $0 as? OSLogEntryLog }
            if entries.count >= 3 { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        if entries.contains(where: { $0.category == "privacy-probe" && $0.composedMessage.contains(token) }) {
            throw XCTSkip("private data logging is enabled on this Mac, so the unified log returns message bodies in clear")
        }
        let messages = entries.filter { $0.category == "core" }.map(\.composedMessage)
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
