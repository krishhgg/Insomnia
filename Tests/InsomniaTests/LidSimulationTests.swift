import XCTest
@testable import Insomnia

/// Records what `AppServices` does with the watcher, so the gating can be
/// proved without a dispatch source or a directory.
@MainActor
final class FakeLidSimulation: LidSimulating {
    var onEvent: ((Bool) -> Void)?
    private(set) var starts: [(directory: URL, file: URL)] = []
    private(set) var stops = 0

    func start(directory: URL, file: URL) { starts.append((directory, file)) }
    func stop() { stops += 1 }
}

/// The watcher is compiled into debug builds and INSOMNIA_LID_SIMULATION
/// release builds only. `swift test` builds debug, so the flag reads true
/// here; what these tests pin is that the flag is what `AppServices` obeys,
/// and that a build whose flag is false never starts an injected watcher.
@MainActor
final class LidSimulationGateTests: XCTestCase {
    private func makeServices(home: TempHome, watcher: (any LidSimulating)?, enabled: Bool) -> AppServices {
        AppServices(
            paths: home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            lidSimulation: watcher,
            lidSimulationEnabled: enabled
        )
    }

    func testTheFlagMatchesTheCompilationCondition() {
        #if DEBUG || INSOMNIA_LID_SIMULATION
        XCTAssertTrue(LidSimulationBuild.isCompiledIn)
        XCTAssertNotNil(LidSimulationBuild.makeWatcher())
        #else
        XCTAssertFalse(LidSimulationBuild.isCompiledIn)
        XCTAssertNil(LidSimulationBuild.makeWatcher())
        #endif
    }

    /// A release build has `isCompiledIn` false: even with a watcher in
    /// hand (an injected one here, since such a build has none), the
    /// services never start it and never wire its events.
    func testAWatcherIsNotStartedWhenTheBuildFlagIsOff() {
        let home = TempHome()
        defer { home.destroy() }
        let watcher = FakeLidSimulation()
        let services = makeServices(home: home, watcher: watcher, enabled: false)

        services.startLidSimulation()

        XCTAssertTrue(watcher.starts.isEmpty, "the watcher was started with the flag off")
        XCTAssertNil(watcher.onEvent, "the watcher's events were wired with the flag off")
        XCTAssertFalse(services.status.lidClosed)
    }

    func testAWatcherIsStartedOnTheSupportDirectoryWhenTheBuildFlagIsOn() {
        let home = TempHome()
        defer { home.destroy() }
        let watcher = FakeLidSimulation()
        let services = makeServices(home: home, watcher: watcher, enabled: true)

        services.startLidSimulation()

        XCTAssertEqual(watcher.starts.count, 1)
        XCTAssertEqual(watcher.starts.first?.directory, home.paths.appSupport)
        XCTAssertEqual(watcher.starts.first?.file, home.paths.simulateLidFile)
        // The event reaches the services: the status reflects the trigger.
        watcher.onEvent?(true)
        XCTAssertTrue(services.status.lidClosed)
        watcher.onEvent?(false)
        XCTAssertFalse(services.status.lidClosed)

        services.stopLidSimulation()
        XCTAssertEqual(watcher.stops, 1)
        XCTAssertNil(watcher.onEvent)
    }

    /// Without a watcher (a release build) stop has nothing to do and the
    /// start never touches the directory.
    func testNoWatcherMeansNothingIsStartedOrStopped() {
        let home = TempHome()
        defer { home.destroy() }
        let services = makeServices(home: home, watcher: nil, enabled: true)

        services.startLidSimulation()
        services.stopLidSimulation()

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.paths.simulateLidFile.path))
    }

    /// Such a build says so in the status menu, as a warning line, so it is
    /// never mistaken for a normal release.
    func testTheStatusMenuMarksALidSimulationBuild() {
        let marked = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], error: nil, lidSimulationBuild: true)
        XCTAssertEqual(marked.map(\.kind), [.warning, .separator, .settings, .quit])
        XCTAssertEqual(marked.first?.title, LidSimulationBuild.marker)
        XCTAssertTrue(LidSimulationBuild.marker.contains("simulate-lid.sh"))

        let plain = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], error: nil, lidSimulationBuild: false)
        XCTAssertEqual(plain.map(\.kind), [.settings, .quit])
    }
}

#if DEBUG || INSOMNIA_LID_SIMULATION
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
#endif
