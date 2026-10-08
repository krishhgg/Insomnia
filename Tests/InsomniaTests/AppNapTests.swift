import XCTest
@testable import Insomnia

/// Spec section 5: `NSAppSleepDisabled` for agent apps is opt-in, journaled
/// before it is written, and put back from the journal. Every preference
/// access goes through `FakeAppNapPreferences`; nothing here reads or
/// writes a real app's preferences.
@MainActor
final class AppNapTests: XCTestCase {
    var h: Harness!

    private let chrome = "com.google.Chrome"
    private let terminal = "com.apple.Terminal"
    private let cursor = "com.todesktop.230313mzl4w4u92"
    private let warp = "dev.warp.Warp-Stable"

    override func setUp() async throws {
        h = Harness()
    }

    override func tearDown() async throws {
        h.home.destroy()
    }

    private func makeManager(optIn: Bool, agents: [String]) -> SessionManager {
        let m = h.makeManager()
        m.config.disableAppNapForAgents = optIn
        m.config.agentList = agents
        try? m.store.saveConfig(m.config)
        return m
    }

    private func writes(_ prefs: FakeAppNapPreferences) -> [String] {
        prefs.writes.map { "\($0.bundleId)=\($0.value.map { $0 ? "true" : "false" } ?? "deleted")" }
    }

    // MARK: Opt-in

    /// The default: a session start and end touch no other app's preferences.
    func testOptInOffWritesNothing() async throws {
        h.appNap.values = [terminal: false]
        let m = makeManager(optIn: false, agents: [chrome, terminal])
        XCTAssertFalse(Config().disableAppNapForAgents, "the opt-in is off by default")

        await m.start(duration: 3600)
        XCTAssertTrue(m.isActive)
        XCTAssertEqual(h.appNap.writes.count, 0)
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [])

        await m.end(reason: .user)
        XCTAssertEqual(h.appNap.writes.count, 0)
        XCTAssertEqual(h.appNap.values, [terminal: false], "nothing changed")
    }

    // MARK: Record, then write

    /// The previous value (absent, true, false) is on disk before the
    /// preference is written. A key already YES is left alone and not
    /// journaled; a value that is not a boolean is left alone.
    func testStartJournalsPreviousValueBeforeEachWrite() async throws {
        h.appNap.values = [terminal: false, cursor: true, warp: true]
        h.appNap.unreadable = [warp]
        let m = makeManager(optIn: true, agents: [chrome, terminal, cursor, warp, chrome])
        let store = h.store
        let box = JournalSnapshots()
        h.appNap.onWrite = { id, _ in
            // What is on disk at the instant the preference changes.
            box.record(id, (try? store.loadState())?.appNapOverrides ?? [])
        }

        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(writes(h.appNap), ["\(chrome)=true", "\(terminal)=true"])
        XCTAssertEqual(box.snapshots[chrome], [AppNapOverride(bundleId: chrome, previous: nil)], "journaled before the first write")
        XCTAssertEqual(box.snapshots[terminal], [
            AppNapOverride(bundleId: chrome, previous: nil),
            AppNapOverride(bundleId: terminal, previous: false),
        ], "journaled before the second write")
        let onDisk = try XCTUnwrap(try store.loadState())
        XCTAssertEqual(onDisk.appNapOverrides, [
            AppNapOverride(bundleId: chrome, previous: nil),
            AppNapOverride(bundleId: terminal, previous: false),
        ])
        XCTAssertTrue(onDisk.isDirty)
        XCTAssertEqual(h.appNap.values, [chrome: true, terminal: true, cursor: true, warp: true])
        XCTAssertNil(m.lastError)
    }

    /// An agent-list id that `defaults` reads as an option, a plist path or
    /// the global domain is left alone: backstop.sh could not put it back
    /// after a force-quit, so it is never journaled or written.
    func testIdsTheBackstopCannotRestoreAreNeverJournaledOrWritten() async throws {
        let m = makeManager(optIn: true, agents: ["-g", "/tmp/prefs", "NSGlobalDomain", "com.example app", chrome])

        await m.start(duration: 3600)

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(writes(h.appNap), ["\(chrome)=true"])
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [AppNapOverride(bundleId: chrome, previous: nil)])
        XCTAssertNil(m.lastError)
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("\"-g\" is not a bundle id the recovery agent can restore"), log)
    }

    func testRestorableIdsAreTheOnesDefaultsNamesTheSameWay() {
        for id in Config.defaultAgentList + [warp, "org.example.my_app", "2BUA8C4S2C.com.example"] {
            XCTAssertTrue(AppNap.isRestorable(bundleId: id), id)
        }
        for id in ["", "-", "-g", "--help", "/Users/x/foo.plist", "~/foo", "NSGlobalDomain", ".GlobalPreferences",
                   "_foo", "com.example app", "com.example\n", "com.exämple"] {
            XCTAssertFalse(AppNap.isRestorable(bundleId: id), id.debugDescription)
        }
    }

    /// Session end puts every recorded value back: a deleted key for an
    /// absent one, false for false, and clears the entries. The key that
    /// was already YES is untouched.
    func testEndRestoresAbsentAndFalseValuesAndClearsEntries() async throws {
        h.appNap.values = [terminal: false, cursor: true]
        let m = makeManager(optIn: true, agents: [chrome, terminal, cursor])
        await m.start(duration: 3600)
        XCTAssertEqual(h.appNap.values, [chrome: true, terminal: true, cursor: true])

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(writes(h.appNap).suffix(2), ["\(chrome)=deleted", "\(terminal)=false"])
        XCTAssertEqual(h.appNap.values, [terminal: false, cursor: true], "exactly as before the session")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(m.state, RuntimeState.clean)
    }

    /// Turning the setting off during a session changes nothing about the
    /// restore: what was journaled is still put back.
    func testToggleOffMidSessionStillRestoresAtEnd() async throws {
        let m = makeManager(optIn: true, agents: [chrome])
        await m.start(duration: 3600)
        XCTAssertEqual(h.appNap.values, [chrome: true])
        m.config.disableAppNapForAgents = false

        await m.end(reason: .user)

        XCTAssertEqual(h.appNap.values, [:])
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [])
    }

    // MARK: Failures

    /// A restore that fails keeps its entry, the end reports incomplete and
    /// arms the agent; the next end finishes the job.
    func testFailedRestoreKeepsEntryAndIsRetried() async throws {
        h.appNap.values = [terminal: false]
        let m = makeManager(optIn: true, agents: [chrome, terminal])
        await m.start(duration: 3600)
        h.appNap.failWrites = [chrome]

        let outcome = await m.end(reason: .user)

        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertEqual(h.backstop.arms, 2, "the agent is confirmed for the retry")
        let kept = try XCTUnwrap(try h.store.loadState())
        XCTAssertEqual(kept.appNapOverrides, [AppNapOverride(bundleId: chrome, previous: nil)], "only the failed one stays")
        XCTAssertTrue(kept.isDirty)
        XCTAssertEqual(h.appNap.values, [chrome: true, terminal: false])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains(chrome), err)
        XCTAssertTrue(err.contains("kept in the journal"), err)
        XCTAssertEqual(h.notifier.posts.last?.title, SessionManager.incompleteTitle)

        h.appNap.failWrites = []
        let again = await m.end(reason: .user)
        XCTAssertEqual(again, .restored)
        XCTAssertEqual(h.appNap.values, [terminal: false])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// The write succeeded but its journal entry could not be cleared: the
    /// entry stays and the next restore writes the same value again.
    func testRestoreWhoseJournalClearFailsIsReported() async throws {
        let m = makeManager(optIn: true, agents: [chrome])
        await m.start(duration: 3600)
        let file = h.home.paths.stateFile.path
        h.appNap.onWrite = { _, value in
            if value == nil { try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file) }
        }
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        let outcome = await m.end(reason: .user)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertEqual(outcome, .incomplete(agentArmed: true))
        XCTAssertEqual(h.appNap.values, [:], "the preference was put back")
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [AppNapOverride(bundleId: chrome, previous: nil)])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not be cleared"), err)

        h.appNap.onWrite = nil
        await m.end(reason: .user)
        XCTAssertEqual(writes(h.appNap), ["\(chrome)=true", "\(chrome)=deleted", "\(chrome)=deleted"])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// A journal that cannot be written means no preference write: the
    /// session still runs, the app's preferences are untouched, and the
    /// failure is reported. The journal becomes unwritable once the resume
    /// has journaled its sleep guard and is holding sleep, because a resume
    /// that cannot write the journal at all is refused (the next test).
    func testJournalWriteFailureMeansNoPreferenceWrite() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true // the crashed session's hold
        let m = makeManager(optIn: true, agents: [chrome, terminal])
        let file = h.home.paths.stateFile.path
        let gate = AsyncGate()
        h.guardFake.sleepGate = gate
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        let reconcile = Task { await m.reconcile() }
        await gate.waitUntilStarted()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        await gate.open()
        await reconcile.value
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertTrue(m.isActive, "the session itself is unaffected")
        XCTAssertEqual(h.appNap.writes.count, 0)
        XCTAssertEqual(h.appNap.values, [:])
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [])
        let err = try XCTUnwrap(m.lastError)
        XCTAssertTrue(err.contains("could not journal the App Nap setting"), err)
        XCTAssertTrue(err.contains("left unchanged"), err)
    }

    /// A journal that cannot be written when reconcile finds a valid
    /// session means no resume at all, even with `sleepDisabledByUs`
    /// already set. The write that fails is the one a resume needs, so
    /// sleep is not held again and no preference is written.
    func testUnwritableJournalAtReconcileResumesNothingAndWritesNoPreference() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now, endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        try h.store.saveState(st)
        h.guardFake.sleepDisabled = true // the crashed session's hold
        let m = makeManager(optIn: true, agents: [chrome, terminal])
        let file = h.home.paths.stateFile.path
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file) }

        await m.reconcile()
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file)

        XCTAssertFalse(m.isActive, "a session resumes only from a journal it can write")
        XCTAssertFalse(h.guardFake.calls.contains("disablesleep 1"), "\(h.guardFake.calls)")
        XCTAssertEqual(h.appNap.writes.count, 0)
        XCTAssertEqual(h.appNap.values, [:])
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [])
        let log = (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("could not journal sleep guard"), log)
    }

    /// A preference write that fails after its entry was journaled keeps
    /// the entry: the restore puts the recorded value back either way.
    func testFailedPreferenceWriteKeepsTheEntryForRestore() async throws {
        h.appNap.failWrites = [chrome]
        let m = makeManager(optIn: true, agents: [chrome, terminal])

        await m.start(duration: 3600)

        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [
            AppNapOverride(bundleId: chrome, previous: nil),
            AppNapOverride(bundleId: terminal, previous: nil),
        ])
        XCTAssertEqual(h.appNap.values, [terminal: true])
        XCTAssertTrue(try XCTUnwrap(m.lastError).contains(chrome))

        h.appNap.failWrites = []
        await m.end(reason: .user)
        XCTAssertEqual(h.appNap.values, [:])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    // MARK: Reconcile

    /// Entries left by a crashed session are restored from disk at launch,
    /// with nothing in memory.
    func testReconcileExpiredSessionRestoresFromDisk() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-60)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.appNapOverrides = [AppNapOverride(bundleId: chrome, previous: nil), AppNapOverride(bundleId: terminal, previous: false)]
        try h.store.saveState(st)
        h.appNap.values = [chrome: true, terminal: true]

        let m = makeManager(optIn: false, agents: [])
        await m.reconcile()

        XCTAssertNil(m.session)
        XCTAssertEqual(writes(h.appNap), ["\(chrome)=deleted", "\(terminal)=false"])
        XCTAssertEqual(h.appNap.values, [terminal: false])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// A journal with nothing but App Nap entries and no session is dirty:
    /// reconcile restores it rather than calling the machine clean.
    func testReconcileNoSessionDirtyWithAppNapOnlyRestores() async throws {
        var st = RuntimeState()
        st.appNapOverrides = [AppNapOverride(bundleId: chrome, previous: nil)]
        try h.store.saveState(st)
        h.appNap.values = [chrome: true]

        let m = makeManager(optIn: false, agents: [])
        await m.reconcile()

        XCTAssertEqual(h.appNap.values, [:])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertEqual(h.notifier.posts.last?.title, "Sleep restored")
    }

    /// Relaunch under a valid session: apps already journaled keep their
    /// recorded value (the previous one is not read again, the key may be
    /// YES by now) and are set to YES again; new agents are recorded first.
    func testReconcileValidSessionReappliesWithoutRerecording() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        var st = RuntimeState()
        st.sleepDisabledByUs = true
        st.appNapOverrides = [AppNapOverride(bundleId: chrome, previous: nil)]
        try h.store.saveState(st)
        // Chrome: journaled, then the crash came before or after the write.
        h.appNap.values = [chrome: true, terminal: false]
        h.guardFake.sleepDisabled = true // the crashed session's hold

        let m = makeManager(optIn: true, agents: [chrome, terminal])
        await m.reconcile()

        XCTAssertTrue(m.isActive)
        XCTAssertEqual(writes(h.appNap), ["\(chrome)=true", "\(terminal)=true"])
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [
            AppNapOverride(bundleId: chrome, previous: nil),
            AppNapOverride(bundleId: terminal, previous: false),
        ])

        await m.end(reason: .user)
        XCTAssertEqual(h.appNap.values, [terminal: false])
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
    }

    /// With the lid closed at relaunch the lid actions wait, but App Nap is
    /// not a lid action: a valid session re-applies it regardless.
    /// Only a CFBoolean is read as the Bool it will be written back as.
    /// An integer (`defaults write -int 0`), a string or anything else
    /// would come back as a boolean, not as what it was, so the read
    /// refuses and the app is skipped rather than rewritten.
    func testOnlyACFBooleanIsReadAsTheValueToPutBack() throws {
        XCTAssertNil(try AppNap.sleepDisabled(from: nil, bundleId: chrome))
        XCTAssertEqual(try AppNap.sleepDisabled(from: kCFBooleanTrue, bundleId: chrome), true)
        XCTAssertEqual(try AppNap.sleepDisabled(from: kCFBooleanFalse, bundleId: chrome), false)
        XCTAssertEqual(try AppNap.sleepDisabled(from: NSNumber(value: true), bundleId: chrome), true, "a BOOL NSNumber is the same CFBoolean object")
        let notBooleans: [(String, CFTypeRef)] = [
            ("-int 0", NSNumber(value: 0)),
            ("-int 1", NSNumber(value: 1)),
            ("-float 1", NSNumber(value: 1.0)),
            ("-string YES", "YES" as CFString),
            ("-string 1", "1" as CFString),
            ("-array", [kCFBooleanTrue] as CFArray),
        ]
        for (label, value) in notBooleans {
            XCTAssertThrowsError(try AppNap.sleepDisabled(from: value, bundleId: chrome), label) { error in
                XCTAssertEqual(error.localizedDescription, "NSAppSleepDisabled for com.google.Chrome is not a boolean; left alone", label)
            }
        }
    }

    func testReconcileValidSessionLidClosedStillAppliesAppNap() async throws {
        let now = h.clock.now
        try h.store.saveSession(Session(startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(3600)))
        h.clamshell.closed = true
        let m = makeManager(optIn: true, agents: [chrome])

        await m.reconcile()

        XCTAssertEqual(h.appNap.values, [chrome: true])
        XCTAssertEqual(try h.store.loadState()?.appNapOverrides, [AppNapOverride(bundleId: chrome, previous: nil)])
    }
}

/// Journal contents captured inside the preference write hook.
private final class JournalSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [String: [AppNapOverride]] = [:]
    var snapshots: [String: [AppNapOverride]] { lock.withLock { _snapshots } }
    func record(_ id: String, _ entries: [AppNapOverride]) {
        lock.withLock { _snapshots[id] = entries }
    }
}
