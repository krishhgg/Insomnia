import XCTest
@testable import Insomnia

/// Stands in for the running app at every wait of `SessionCommandLine`:
/// takes the request of `id`, records it, writes `session` when set, and
/// answers.
final class FakeRunningApp {
    var takes = true
    var answer: SessionCommandReply? = SessionCommandReply(error: nil)
    var session: Session?
    let id: String
    private(set) var requests: [String] = []
    private(set) var waits = 0

    init(id: String = "9-9") {
        self.id = id
    }

    func wait(paths: Paths) {
        waits += 1
        let file = paths.sessionCommandRequest(id)
        guard takes, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        requests.append(text.trimmingCharacters(in: .newlines))
        let store = Store(paths: paths)
        if let session { try? store.saveSession(session) }
        if let answer { try? store.write(answer, to: paths.sessionCommandReply(id)) }
    }
}

/// `Insomnia --session`: the request format, the app side (the manager runs
/// each command like its menu action and answers it; the watcher on the
/// support directory) and the command line that waits for the answer.
@MainActor
final class SessionCommandTests: XCTestCase {
    var h: Harness!
    private let utc = TimeZone(identifier: "UTC")!

    override func setUp() async throws {
        h = Harness()
        try h.home.paths.createDirectories()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    // MARK: Request format

    func testCommandsRoundTripThroughTheirText() {
        let commands: [SessionCommand] = [.start(seconds: 7200), .extend(seconds: 600), .end]
        for command in commands {
            XCTAssertEqual(SessionCommand(text: command.text), command, command.text)
        }
        XCTAssertEqual(commands.map(\.text), ["start 7200", "extend 600", "end"])
    }

    func testMalformedCommandsAreRefused() {
        let texts = [
            "", "start", "start 0", "start -5", "start 1.5", "start +5", "start 2147483648", "extend abc",
            "stop", "start 7200 3", "end now", "start  7200", "END", "start 1h",
        ]
        for text in texts {
            XCTAssertNil(SessionCommand(text: text), text)
        }
    }

    func testOnlyDigitAndDashIDsNameFiles() {
        XCTAssertTrue(SessionCommand.isRequestID("4242-17"))
        for id in ["", "a-b", "../x", "1/2", "1.2", String(repeating: "1", count: 33)] {
            XCTAssertFalse(SessionCommand.isRequestID(id), id)
        }
        XCTAssertEqual(Paths.sessionCommandRequestID("session-command.4242-17.request"), "4242-17")
        XCTAssertEqual(Paths.sessionCommandReplyID("session-command.4242-17.reply"), "4242-17")
        for name in ["session-command.4242-17.request.tmp", "session-command..request", "session-command.x.request", "state.json"] {
            XCTAssertNil(Paths.sessionCommandRequestID(name), name)
        }
    }

    // MARK: The app side

    func testCommandsRunLikeTheirMenuActions() async throws {
        let m = h.makeManager()
        let started = await m.run(.start(seconds: 3600))
        XCTAssertNil(started)
        let session = try XCTUnwrap(m.session)
        XCTAssertEqual(session.endsAt, h.clock.now.addingTimeInterval(3600))
        XCTAssertEqual(try h.store.loadSession(), session)

        let again = await m.run(.start(seconds: 60))
        XCTAssertEqual(again, SessionCommand.alreadyRunning)
        XCTAssertEqual(m.session, session, "a second start changes nothing")

        let extended = await m.run(.extend(seconds: 600))
        XCTAssertNil(extended)
        XCTAssertEqual(m.session?.endsAt, session.endsAt.addingTimeInterval(600))

        let ended = await m.run(.end)
        XCTAssertNil(ended)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())

        let extendNothing = await m.run(.extend(seconds: 600))
        XCTAssertEqual(extendNothing, "no session is running")
        let endNothing = await m.run(.end)
        XCTAssertNil(endNothing, "ending with no session is already done")
    }

    func testAFailedStartAnswersWithTheReason() async throws {
        h.guardFake.throwOn = ["disablesleep 1"]
        let m = h.makeManager()
        let answer = await m.run(.start(seconds: 3600))
        let error = try XCTUnwrap(answer)
        XCTAssertTrue(error.contains("password is required"), error)
        XCTAssertNil(m.session)
    }

    // A second start queued behind one still in flight is not this call's
    // session: the second caller hears so instead of a false success.
    func testAStartQueuedBehindAnotherIsToldTheSessionIsAlreadyRunning() async throws {
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let m = h.makeManager()

        let first = Task { await m.run(.start(seconds: 3600)) }
        await gate.waitUntilStarted()
        let second = await runUntilSuspended { await m.run(.start(seconds: 32400)) }
        await gate.open()

        let firstAnswer = await first.value
        let secondAnswer = await second.value
        XCTAssertNil(firstAnswer)
        XCTAssertEqual(secondAnswer, SessionCommand.alreadyRunning)
        XCTAssertEqual(m.session?.endsAt, h.clock.now.addingTimeInterval(3600))
    }

    // An end is always a full end: one that arrives while a start is still
    // in flight abandons that start, and nothing is left running.
    func testAnEndDuringAnInFlightStartAbandonsIt() async throws {
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        let m = h.makeManager()

        let start = Task { await m.run(.start(seconds: 3600)) }
        await gate.waitUntilStarted()
        let end = await runUntilSuspended { await m.run(.end) }
        await gate.open()

        let startAnswer = await start.value
        let endAnswer = await end.value
        XCTAssertNotNil(startAnswer, "the start did not make the session; it must not answer done")
        XCTAssertNil(endAnswer)
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    // Requests run oldest first: a start sent after an end that still waits
    // in the queue runs once that end has, and makes a new session, instead
    // of being refused for the session the end is about to stop.
    func testAStartSentAfterAQueuedEndStartsANewSession() async throws {
        let m = h.makeManager()
        let first = await m.run(.start(seconds: 3600))
        XCTAssertNil(first)
        let gate = AsyncGate()
        h.backstop.armGate = gate

        let extend = Task { await m.run(.extend(seconds: 600)) }
        await gate.waitUntilStarted()
        let end = await runUntilSuspended { await m.run(.end) }
        let start = await runUntilSuspended { await m.run(.start(seconds: 7200)) }
        await gate.open()

        _ = await extend.value
        let endAnswer = await end.value
        let startAnswer = await start.value
        XCTAssertNil(endAnswer)
        XCTAssertNil(startAnswer, "the start runs after the end and makes the new session")
        let session = try XCTUnwrap(m.session)
        XCTAssertEqual(session.endsAt, h.clock.now.addingTimeInterval(7200))
        XCTAssertEqual(try h.store.loadSession(), session)
    }

    // A start queued behind an end that is left to retry is refused, as one
    // sent after that end would be: the retry would stop the new session.
    func testAStartQueuedBehindAnEndLeftToRetryIsRefused() async throws {
        let m = h.makeManager()
        let first = await m.run(.start(seconds: 3600))
        XCTAssertNil(first)
        h.guardFake.throwOn = ["disablesleep 0"]
        let endArm = AsyncGate()
        h.backstop.armGate = endArm

        let end = await runUntilSuspended { await m.run(.end) }
        await endArm.waitUntilStarted()
        let start = await runUntilSuspended { await m.run(.start(seconds: 7200)) }
        // The end's arm fails, so the end is left to its retry; a later arm,
        // the start's, would succeed.
        let startArm = AsyncGate()
        h.backstop.armGate = startArm
        h.backstop.failArm = true
        await endArm.open()
        let endAnswer = await end.value
        h.backstop.failArm = false
        await startArm.open()
        let startAnswer = await start.value

        XCTAssertNotNil(endAnswer)
        XCTAssertEqual(m.pendingEnd, .user)
        XCTAssertNotNil(startAnswer, "a session started now would be stopped by the retry")
        XCTAssertNil(m.session)
        XCTAssertNil(try h.store.loadSession())
    }

    // A session.json that the app has not adopted (a launch recovery that is
    // still waiting, for example) is ended too, not answered as done.
    func testAnEndFinishesASessionTheManagerHasNotAdopted() async throws {
        let m = h.makeManager()
        try h.store.saveSession(Session(startedAt: h.clock.now, endsAt: h.clock.now.addingTimeInterval(3600)))
        XCTAssertNil(m.session)

        let answer = await m.run(.end)

        XCTAssertNil(answer)
        XCTAssertNil(try h.store.loadSession(), "a deadline left on disk would resume at the next launch")
    }

    func testAnEndWhoseRestoreFailsAnswersWithAReason() async throws {
        let m = h.makeManager()
        let started = await m.run(.start(seconds: 3600))
        XCTAssertNil(started)
        h.guardFake.throwOn = ["disablesleep 0"]

        let answer = await m.run(.end)

        XCTAssertNotNil(answer, "sleep is still disabled, so the end must not read as done")
        XCTAssertEqual(try h.store.loadState()?.sleepDisabledByUs, true, "the entry stays journaled for the retry")
    }

    func testServeAnswersInTheRequestsReplyFile() async throws {
        let m = h.makeManager()
        await m.serve(SessionRequest(command: .start(seconds: 60), id: "7-7"))
        XCTAssertNotNil(m.session)
        XCTAssertEqual(try reply("7-7"), SessionCommandReply(error: nil))

        await m.serve(SessionRequest(command: .start(seconds: 60), id: "7-8"))
        XCTAssertEqual(try reply("7-8"), SessionCommandReply(error: SessionCommand.alreadyRunning))
    }

    // MARK: The watcher

    func testTheWatcherServesFreshRequestsOldestFirstAndRemovesThem() throws {
        let watcher = SessionCommandWatcher()
        var got: [SessionRequest] = []
        watcher.onRequest = { got.append($0) }
        watcher.start(paths: h.home.paths)
        defer { watcher.stop() }

        try drop("end", id: "2-2", age: 1)
        try drop("start 60", id: "1-1", age: 2)
        watcher.consume()

        XCTAssertEqual(got, [SessionRequest(command: .start(seconds: 60), id: "1-1"), SessionRequest(command: .end, id: "2-2")])
        XCTAssertFalse(exists(h.home.paths.sessionCommandRequest("1-1")))
        XCTAssertFalse(exists(h.home.paths.sessionCommandRequest("2-2")))
    }

    func testTheWatcherDropsStaleAndMalformedRequestsWithoutServingThem() throws {
        let watcher = SessionCommandWatcher()
        var got: [SessionRequest] = []
        watcher.onRequest = { got.append($0) }
        watcher.start(paths: h.home.paths)
        defer { watcher.stop() }

        // The command line that wrote it gave up long ago.
        try drop("start 60", id: "1-1", age: SessionCommandLine.staleAfter + 1)
        try drop("start sixty", id: "2-2")
        watcher.consume()

        XCTAssertEqual(got, [])
        XCTAssertFalse(exists(h.home.paths.sessionCommandRequest("1-1")))
        XCTAssertFalse(exists(h.home.paths.sessionCommandRequest("2-2")))
    }

    func testARequestWrittenBeforeTheWatchStartsIsServedAndOldAnswersAreCleared() throws {
        let leftover = h.home.paths.sessionCommandReply("3-3")
        try h.store.write(SessionCommandReply(error: nil), to: leftover)
        try drop("end", id: "5-5")
        let watcher = SessionCommandWatcher()
        var got: [SessionRequest] = []
        watcher.onRequest = { got.append($0) }

        watcher.start(paths: h.home.paths)
        defer { watcher.stop() }

        XCTAssertEqual(got, [SessionRequest(command: .end, id: "5-5")])
        XCTAssertFalse(exists(leftover), "nobody waits for an answer from before the launch")
    }

    // MARK: The command line

    func testAnAnsweredStartPrintsTheSessionItStarted() {
        let app = FakeRunningApp()
        let now = h.clock.now
        app.session = Session(startedAt: now, endsAt: now.addingTimeInterval(7200))

        let output = commandLine(["start", "7200"], app: app)

        XCTAssertEqual(app.requests, ["start 7200"])
        XCTAssertEqual(output, .init(lines: ["running until \(iso(now.addingTimeInterval(7200))) (2h left)"], status: 0))
        XCTAssertFalse(exists(h.home.paths.sessionCommandReply("9-9")), "the answer is removed once read")
    }

    func testARefusalIsPrintedAndExitsOne() {
        let app = FakeRunningApp()
        app.answer = SessionCommandReply(error: SessionCommand.alreadyRunning)

        XCTAssertEqual(commandLine(["start", "60"], app: app), .init(lines: [SessionCommand.alreadyRunning], status: 1))
    }

    func testNothingTakingTheRequestMeansTheAppIsNotRunningAndTheRequestIsTakenBack() throws {
        let app = FakeRunningApp()
        app.takes = false

        let output = try XCTUnwrap(commandLine(["end"], app: app))

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.lines.first?.contains("not running") == true, "\(output.lines)")
        XCTAssertFalse(exists(h.home.paths.sessionCommandRequest("9-9")), "a request left behind could run at the next launch")
        XCTAssertEqual(Double(app.waits) * SessionCommandLine.pollInterval, SessionCommandLine.claimTimeout, accuracy: 0.5)
    }

    func testARunningAppThatTakesNothingIsNamedAsAnOlderVersion() throws {
        let app = FakeRunningApp()
        app.takes = false

        let output = try XCTUnwrap(commandLine(["end"], app: app, runningApp: .older))

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.lines.first?.contains("version without --session") == true, "\(output.lines)")
        XCTAssertFalse(exists(h.home.paths.sessionCommandRequest("9-9")))
    }

    func testACurrentAppThatTakesNothingInTimeMayStillBeStarting() throws {
        let app = FakeRunningApp()
        app.takes = false

        let output = try XCTUnwrap(commandLine(["end"], app: app, runningApp: .current))

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.lines.first?.contains("may still be starting, so try again") == true, "\(output.lines)")
    }

    func testATakenRequestWithNoAnswerTimesOut() throws {
        let app = FakeRunningApp()
        app.answer = nil

        let output = try XCTUnwrap(commandLine(["extend", "600"], app: app))

        XCTAssertEqual(output.status, 1)
        XCTAssertTrue(output.lines.first?.contains("did not answer") == true, "\(output.lines)")
    }

    // Another command line's request, waiting or left behind by one that was
    // killed, has its own file: this one neither waits on it nor touches it.
    func testAnotherCommandLinesRequestIsLeftAlone() throws {
        try drop("start 60", id: "1-1", age: SessionCommandLine.staleAfter + 1)
        let app = FakeRunningApp()

        let output = try XCTUnwrap(commandLine(["end"], app: app))

        XCTAssertEqual(output.status, 0, "\(output.lines)")
        XCTAssertEqual(app.requests, ["end"])
        XCTAssertEqual(try String(contentsOf: h.home.paths.sessionCommandRequest("1-1"), encoding: .utf8), "start 60")
    }

    func testStatusReadsTheSessionFileAndSendsNothing() throws {
        XCTAssertEqual(commandLine(["status"]), .init(lines: ["no session is running"], status: 0))

        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(90 * 60)))

        XCTAssertEqual(commandLine(["status"]), .init(lines: ["running until \(iso(now.addingTimeInterval(5400))) (1h 30m left)"], status: 0))
        XCTAssertFalse(exists(h.home.paths.sessionCommandRequest("9-9")))
    }

    func testTheRemainingTimeIsRoundedUpToTheMinute() {
        let now = h.clock.now
        let session = Session(startedAt: now, endsAt: now.addingTimeInterval(119))
        XCTAssertEqual(SessionCommandLine.describe(session, now: now, timeZone: utc), "running until \(iso(now.addingTimeInterval(119))) (2m left)")
    }

    func testUsageErrorsExit64AndOtherArgumentsAreNotThisMode() {
        for words in [[], ["start"], ["start", "0"], ["start", "1h"], ["stop"], ["status", "now"], ["end", "now"]] {
            XCTAssertEqual(commandLine(words)?.status, SessionCommandLine.usageStatus, "\(words)")
        }
        XCTAssertNil(SessionCommandLine.run(["--resume-frozen", "5"], paths: h.home.paths))
        XCTAssertNil(SessionCommandLine.run([], paths: h.home.paths))
    }

    /// Scripts read the bundle's key before they run the binary.
    func testTheBundleDeclaresTheSessionCommandVersion() throws {
        // .../Tests/InsomniaTests/SessionCommandTests.swift -> .../Resources/Info.plist
        let info = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any])
        XCTAssertEqual(plist["InsomniaSessionCommandVersion"] as? Int, SessionCommandLine.version)
    }

    // MARK: Helpers

    private func commandLine(
        _ words: [String], app: FakeRunningApp = FakeRunningApp(), runningApp: SessionCommandLine.RunningApp = .none
    ) -> SessionCommandLine.Output? {
        let paths = h.home.paths
        let now = h.clock.now
        return SessionCommandLine.run(
            ["--session"] + words, paths: paths, now: { now }, timeZone: utc, id: app.id, runningApp: { runningApp }
        ) { _ in
            app.wait(paths: paths)
        }
    }

    /// Writes a request file the way a command line does, written `age`
    /// seconds ago.
    private func drop(_ text: String, id: String, age: TimeInterval = 0) throws {
        let file = h.home.paths.sessionCommandRequest(id)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    private func reply(_ id: String) throws -> SessionCommandReply? {
        try h.store.read(SessionCommandReply.self, from: h.home.paths.sessionCommandReply(id))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func iso(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.timeZone = utc
        return format.string(from: date)
    }
}
