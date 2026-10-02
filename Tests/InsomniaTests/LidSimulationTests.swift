import XCTest
@testable import Insomnia

/// The file trigger behind scripts/simulate-lid.sh. Driven through
/// `consume()` directly rather than the directory watcher, so nothing here
/// waits on a dispatch source.
@MainActor
final class LidSimulationTests: XCTestCase {
    var home: TempHome!
    var sim: LidSimulation!
    var events: Locked<[Bool]>!

    override func setUp() async throws {
        home = TempHome()
        try FileManager.default.createDirectory(at: home.paths.appSupport, withIntermediateDirectories: true)
        sim = LidSimulation()
        events = Locked([])
        let events = events!
        sim.onEvent = { events.value.append($0) }
    }

    override func tearDown() async throws {
        sim.stop()
        home.destroy()
    }

    private var trigger: URL { home.paths.simulateLidFile }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: trigger)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path)
            .filter { $0.hasPrefix(trigger.lastPathComponent) }
    }

    private func log() -> String {
        (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
    }

    /// The script says a trigger written outside a session is consumed and
    /// ignored at the next session start; a stale "closed" must not darken
    /// and freeze a session that just started.
    func testStaleTriggerAtStartIsDeletedAndIgnored() throws {
        try write("closed\n")

        sim.start(directory: home.paths.appSupport, file: trigger)

        XCTAssertEqual(events.value, [], "a stale trigger was acted on")
        XCTAssertEqual(try leftovers(), [], "the stale trigger or its claim file was left behind")
        XCTAssertTrue(log().contains("lid simulation: ignored stale trigger \"closed\""), log())
    }

    func testTriggerIsDeliveredAndRemoved() throws {
        sim.start(directory: home.paths.appSupport, file: trigger)
        try write("closed\n")

        sim.consume()

        XCTAssertEqual(events.value, [true])
        XCTAssertEqual(try leftovers(), [], "trigger or claim file left behind")
        XCTAssertTrue(log().contains("lid SIMULATED closed (file trigger)"), log())
    }

    /// Two writes can arrive as one directory event. The second trigger
    /// appears while the first is being delivered; one consume must take
    /// both, in order, so a "closed"/"open" pair is never cut in half.
    func testCoalescedPairIsDeliveredInOrder() throws {
        sim.start(directory: home.paths.appSupport, file: trigger)
        let events = events!
        let trigger = trigger
        sim.onEvent = { closed in
            events.value.append(closed)
            if closed { try? Data("open\n".utf8).write(to: trigger) }
        }
        try write("closed\n")

        sim.consume()

        XCTAssertEqual(events.value, [true, false])
        XCTAssertEqual(try leftovers(), [])
    }

    /// The trigger is claimed by rename before it is read, so a claim file
    /// a crash left behind is replaced rather than blocking the next trigger.
    func testLeftoverClaimFileDoesNotBlockTheNextTrigger() throws {
        sim.start(directory: home.paths.appSupport, file: trigger)
        let stale = trigger.appendingPathExtension("claimed.\(getpid())")
        try Data("closed\n".utf8).write(to: stale)
        try write("open\n")

        sim.consume()

        XCTAssertEqual(events.value, [false])
        XCTAssertEqual(try leftovers(), [])
    }

    func testUnknownTriggerIsIgnoredAndRemoved() throws {
        sim.start(directory: home.paths.appSupport, file: trigger)
        try write("maybe\n")

        sim.consume()

        XCTAssertEqual(events.value, [])
        XCTAssertEqual(try leftovers(), [])
        XCTAssertTrue(log().contains("ignoring trigger \"maybe\""), log())
    }

    func testNoTriggerIsANoOp() throws {
        sim.start(directory: home.paths.appSupport, file: trigger)
        sim.consume()
        XCTAssertEqual(events.value, [])
        XCTAssertFalse(log().contains("cannot claim"), "a missing trigger is not an error: \(log())")
    }
}
