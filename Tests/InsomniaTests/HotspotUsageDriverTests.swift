import AppKit
import Foundation
import XCTest
@testable import Insomnia

@MainActor
final class HotspotUsageDriverTests: XCTestCase {
    func testObserverContextCanRetainAndReleaseOnBackgroundQueue() async {
        var callbacks: WiFiUsageObserver.Callbacks? = .init(changed: {}, unavailable: {})
        weak let weakCallbacks = callbacks
        let context = WiFiUsageObserver.context(for: callbacks!)
        let address = UInt(bitPattern: context.info!)
        let retain = context.retain!
        let release = context.release!
        let retainedAddress = await Task.detached {
            UInt(bitPattern: retain(UnsafeRawPointer(bitPattern: address)!))
        }.value
        XCTAssertEqual(retainedAddress, address)
        callbacks = nil
        XCTAssertNotNil(weakCallbacks, "The dynamic store owns the callback context")
        await Task.detached {
            release(UnsafeRawPointer(bitPattern: address)!)
        }.value
        XCTAssertNil(weakCallbacks, "Background cleanup releases the final reference")
    }

    private func config(_ name: String = "Fixture hotspot", budget: UInt64 = 1_000) -> Config {
        var c = Config()
        c.hotspotSSID = name
        c.trackHotspotUsage = true
        c.hotspotBudgetBytes = budget
        return c
    }

    private func reading(_ bytes: UInt64, at: Double, name: String? = "Fixture hotspot") -> HotspotUsageReading {
        HotspotUsageReading(ssid: name, sample: InterfaceByteSample(interfaceIndex: 1, received: bytes, sent: 0, timestamp: at))
    }

    func testPersistsBeforeWarningsAndContinuesBeyondBudget() async throws {
        let store = UsageMemoryStore()
        let sampler = UsageScriptSampler([reading(10_000, at: 0), reading(10_800, at: 5), reading(11_000, at: 10), reading(11_300, at: 15)])
        let notifier = UsageCheckingNotifier(store: store)
        let driver = HotspotUsageDriver(store: store, sampler: sampler, observer: UsageObserver(), notifier: notifier)
        driver.configure(config: config(), sessionActive: true, schedule: false)
        for _ in 0..<4 { await driver.sampleNow() }
        XCTAssertEqual(driver.status.ledger?.total, 1_300)
        XCTAssertEqual(driver.status.phase, .tracking)
        XCTAssertEqual(notifier.titles, ["Hotspot budget nearly used", "Hotspot budget reached"])
        XCTAssertEqual(notifier.persistedAtPost, [800, 1_000])
        XCTAssertTrue(driver.status.warning?.contains("connection left running") == true)
        XCTAssertFalse(notifier.bodies.joined().contains("Fixture hotspot"))
        driver.stop()
    }

    func testRestartRetainsWarningsAndDoesNotCountWhileAppWasClosed() async {
        let store = UsageMemoryStore()
        let notifier = RecordingNotifier()
        let first = HotspotUsageDriver(store: store, sampler: UsageScriptSampler([reading(0, at: 0), reading(800, at: 5)]), observer: UsageObserver(), notifier: notifier)
        first.configure(config: config(), sessionActive: true, schedule: false)
        await first.sampleNow(); await first.sampleNow(); first.stop()
        let second = HotspotUsageDriver(store: store, sampler: UsageScriptSampler([reading(100_000, at: 0), reading(100_200, at: 5)]), observer: UsageObserver(), notifier: notifier)
        second.configure(config: config(), sessionActive: true, schedule: false)
        await second.sampleNow()
        XCTAssertEqual(second.status.ledger?.total, 800)
        await second.sampleNow()
        XCTAssertEqual(second.status.ledger?.total, 1_000)
        XCTAssertEqual(notifier.posts.map(\.title), ["Hotspot budget nearly used", "Hotspot budget reached"])
        second.stop()
    }

    func testOffIdleAndMissingConfigurationDoNotSample() async {
        let sampler = UsageScriptSampler([])
        let observer = UsageObserver()
        let driver = HotspotUsageDriver(store: UsageMemoryStore(), sampler: sampler, observer: observer, notifier: RecordingNotifier())
        var c = config()
        c.trackHotspotUsage = false
        driver.configure(config: c, sessionActive: true, schedule: false)
        await driver.sampleNow()
        XCTAssertEqual(driver.status.phase, .off)
        c.trackHotspotUsage = true
        driver.configure(config: c, sessionActive: false, schedule: false)
        await driver.sampleNow()
        XCTAssertEqual(driver.status.phase, .idle)
        c.hotspotSSID = "  "
        driver.configure(config: c, sessionActive: true, schedule: false)
        await driver.sampleNow()
        XCTAssertEqual(driver.status.phase, .missingHotspot)
        let reads = await sampler.readCount
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(observer.starts, 0)
    }

    func testOtherNetworkAndHiddenNameKeepKnownTotalWithoutBridgingGaps() async {
        let sampler = UsageScriptSampler([reading(0, at: 0), reading(100, at: 5), reading(5_000, at: 10, name: "Other fixture"), reading(6_000, at: 15), reading(6_050, at: 20), reading(7_000, at: 25, name: nil), reading(8_000, at: 30), reading(8_010, at: 35)])
        let driver = HotspotUsageDriver(store: UsageMemoryStore(), sampler: sampler, observer: UsageObserver(), notifier: RecordingNotifier())
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.phase, .otherNetwork)
        XCTAssertEqual(driver.status.ledger?.total, 100)
        await driver.sampleNow(); await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.phase, .unavailable)
        XCTAssertEqual(driver.status.ledger?.total, 150)
        await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 160)
        XCTAssertEqual(driver.status.ledger?.hasUnmeasuredIntervals, true)
        driver.stop()
    }

    func testNetworkEventDiscardsAnInFlightReading() async {
        let gate = AsyncGate()
        let sampler = UsageScriptSampler([reading(0, at: 0), reading(900, at: 5), reading(10_000, at: 10), reading(10_100, at: 15)], gatedRead: 1, gate: gate)
        let observer = UsageObserver()
        let driver = HotspotUsageDriver(store: UsageMemoryStore(), sampler: sampler, observer: observer, notifier: RecordingNotifier())
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow()
        let task = Task { await driver.sampleNow() }
        await gate.waitUntilStarted()
        observer.changed?()
        await gate.open(); await task.value
        XCTAssertEqual(driver.status.ledger?.total, 0)
        await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 100)
        XCTAssertEqual(driver.status.ledger?.hasUnmeasuredIntervals, true)
        driver.stop()
    }

    func testStopDiscardsAnInFlightReadingAndRetainsPreviousTotal() async {
        let gate = AsyncGate()
        let store = UsageMemoryStore()
        let sampler = UsageScriptSampler([reading(0, at: 0), reading(100, at: 5), reading(1_000, at: 10)], gatedRead: 2, gate: gate)
        let driver = HotspotUsageDriver(store: store, sampler: sampler, observer: UsageObserver(), notifier: RecordingNotifier())
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        let task = Task { await driver.sampleNow() }
        await gate.waitUntilStarted(); driver.stop(); await gate.open(); await task.value
        XCTAssertEqual(driver.status.phase, .idle)
        XCTAssertEqual(driver.status.ledger?.total, 100)
        XCTAssertEqual(store.file?.records.values.first?.ledger.total, 100)
    }

    func testResetDiscardsInFlightReadingAndStartsANewPeriod() async {
        let gate = AsyncGate()
        let store = UsageMemoryStore()
        let sampler = UsageScriptSampler([reading(0, at: 0), reading(800, at: 5), reading(1_000, at: 10), reading(5_000, at: 15), reading(5_800, at: 20)], gatedRead: 2, gate: gate)
        let notifier = RecordingNotifier()
        var now = Date(timeIntervalSince1970: 100)
        let driver = HotspotUsageDriver(store: store, sampler: sampler, observer: UsageObserver(), notifier: notifier, clock: { now })
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        let task = Task { await driver.sampleNow() }
        await gate.waitUntilStarted()
        now = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(driver.reset())
        await gate.open(); await task.value
        XCTAssertEqual(driver.status.ledger?.total, 0)
        XCTAssertEqual(driver.status.periodStarted, now)
        await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 800)
        XCTAssertEqual(notifier.posts.count, 2, "The new period can warn again")
        driver.stop()
    }

    func testFailedSaveKeepsTotalsAndDefersNotificationUntilRecovery() async {
        let store = UsageMemoryStore()
        let notifier = RecordingNotifier()
        let driver = HotspotUsageDriver(store: store, sampler: UsageScriptSampler([reading(0, at: 0), reading(800, at: 5), reading(900, at: 10)]), observer: UsageObserver(), notifier: notifier)
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow()
        store.failSave = true
        await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 800)
        XCTAssertEqual(store.file?.records.values.first?.ledger.total, 0)
        XCTAssertNotNil(driver.status.problem)
        XCTAssertEqual(notifier.posts.count, 0)
        store.failSave = false
        await driver.sampleNow()
        XCTAssertEqual(store.file?.records.values.first?.ledger.total, 900)
        XCTAssertNil(driver.status.problem)
        XCTAssertEqual(notifier.posts.count, 1)
        driver.stop()
    }

    func testUnreadableHistoryIsNotOverwrittenWithoutExplicitReset() async {
        let store = UsageMemoryStore()
        store.failLoad = true
        let driver = HotspotUsageDriver(store: store, sampler: UsageScriptSampler([]), observer: UsageObserver(), notifier: RecordingNotifier())
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow()
        XCTAssertNil(driver.status.ledger)
        XCTAssertNotNil(driver.status.problem)
        XCTAssertEqual(store.saves, 0)
        XCTAssertTrue(driver.resetMessage.contains("all saved hotspot usage history"))
        XCTAssertTrue(driver.reset())
        XCTAssertEqual(driver.status.ledger?.total, 0)
        XCTAssertNil(driver.status.problem)
        XCTAssertEqual(store.saves, 1)
        driver.stop()
    }

    func testRetryAfterReadFailureUsesCurrentBudgetAndSavedTotal() async {
        let store = UsageMemoryStore()
        let key = HotspotUsageFile.key(for: "Fixture hotspot")
        store.file = HotspotUsageFile(records: [key: HotspotUsageRecord(periodStarted: Date(timeIntervalSince1970: 10), ledger: HotspotUsageLedger(received: 800, budgetBytes: 2_000))])
        store.failLoad = true
        let notifier = RecordingNotifier()
        let driver = HotspotUsageDriver(store: store, sampler: UsageScriptSampler([reading(50_000, at: 0)]), observer: UsageObserver(), notifier: notifier)
        driver.configure(config: config(), sessionActive: true, schedule: false)
        store.failLoad = false
        await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 800)
        XCTAssertEqual(driver.status.ledger?.budgetBytes, 1_000)
        XCTAssertEqual(notifier.posts.count, 1)
        driver.stop()
    }

    func testFailedResetKeepsPriorTotalsAndWarningHistory() async {
        let store = UsageMemoryStore()
        let driver = HotspotUsageDriver(store: store, sampler: UsageScriptSampler([reading(0, at: 0), reading(800, at: 5)]), observer: UsageObserver(), notifier: RecordingNotifier())
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        let before = driver.status.ledger
        store.failSave = true
        XCTAssertFalse(driver.reset())
        XCTAssertEqual(driver.status.ledger, before)
        XCTAssertEqual(store.file?.records.values.first?.ledger, before)
        driver.stop()
    }

    func testChangingHotspotKeepsSeparateHistoryAndResetOnlyClearsSelectedOne() async {
        let store = UsageMemoryStore()
        let sampler = UsageScriptSampler([reading(0, at: 0), reading(100, at: 5), reading(10_000, at: 10, name: "Second fixture"), reading(10_200, at: 15, name: "Second fixture")])
        let driver = HotspotUsageDriver(store: store, sampler: sampler, observer: UsageObserver(), notifier: RecordingNotifier())
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        driver.configure(config: config("Second fixture"), sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 200)
        XCTAssertTrue(driver.reset())
        XCTAssertEqual(store.file?.records[HotspotUsageFile.key(for: "Fixture hotspot")]?.ledger.total, 100)
        driver.configure(config: config(), sessionActive: false, schedule: false)
        XCTAssertEqual(driver.status.ledger?.total, 100)
        XCTAssertEqual(driver.status.phase, .idle)
        driver.stop()
    }

    func testObserverFailurePausesAndRetriesWithoutInventingTraffic() async {
        let observer = UsageObserver()
        observer.fail = true
        let sampler = UsageScriptSampler([reading(10_000, at: 0), reading(10_100, at: 5)])
        let driver = HotspotUsageDriver(store: UsageMemoryStore(), sampler: sampler, observer: observer, notifier: RecordingNotifier())
        driver.configure(config: config(), sessionActive: true, schedule: false)
        await driver.sampleNow()
        XCTAssertEqual(driver.status.phase, .unavailable)
        XCTAssertNotNil(driver.status.problem)
        observer.fail = false
        await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 100)
        XCTAssertNil(driver.status.problem)
        observer.unavailable?()
        XCTAssertEqual(driver.status.phase, .unavailable)
        XCTAssertNotNil(driver.status.problem)
        driver.stop()
    }

    func testDisableAndResumeRetainTotalsWithoutCountingDisabledTraffic() async {
        let store = UsageMemoryStore()
        let driver = HotspotUsageDriver(store: store, sampler: UsageScriptSampler([reading(0, at: 0), reading(100, at: 5), reading(10_000, at: 10), reading(10_100, at: 15)]), observer: UsageObserver(), notifier: RecordingNotifier())
        var c = config()
        driver.configure(config: c, sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        c.trackHotspotUsage = false
        driver.configure(config: c, sessionActive: true, schedule: false)
        await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 100)
        c.trackHotspotUsage = true
        driver.configure(config: c, sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        XCTAssertEqual(driver.status.ledger?.total, 200)
        driver.stop()
    }

    func testLoweringBudgetWarnsWithoutErasingBytesOrEndingSession() async throws {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        await manager.start(duration: 3_600)
        let notifier = RecordingNotifier()
        let driver = HotspotUsageDriver(store: UsageMemoryStore(), sampler: UsageScriptSampler([reading(0, at: 0), reading(800, at: 5)]), observer: UsageObserver(), notifier: notifier)
        var c = config(budget: 2_000)
        manager.config = c
        driver.configure(config: c, sessionActive: true, schedule: false)
        await driver.sampleNow(); await driver.sampleNow()
        let journal = manager.state
        manager.services = AppServices(paths: h.home.paths, notifier: h.notifier, audio: h.audio, processControl: h.procs, hotspotUsage: driver, lidSimulation: nil, lidSimulationEnabled: false)
        c.hotspotBudgetBytes = 500
        manager.config = c
        XCTAssertEqual(driver.status.ledger?.total, 800)
        XCTAssertEqual(notifier.posts.map(\.title), ["Hotspot budget reached"])
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(manager.state, journal)
        manager.services?.stop()
        XCTAssertEqual(driver.status.phase, .idle)
        manager.services = nil
        await manager.end(reason: .user)
        XCTAssertFalse(h.guardFake.sleepDisabled)
    }
}

@MainActor
final class HotspotUsageStoreTests: XCTestCase {
    func testDiskRoundTripIsOwnerOnlyAndLeavesPowerJournalUntouched() throws {
        let home = TempHome(); defer { home.destroy() }
        let store = Store(paths: home.paths)
        let usage = HotspotUsageStore(store: store)
        let state = RuntimeState.clean
        try store.saveState(state)
        let before = try Data(contentsOf: home.paths.stateFile)
        let key = HotspotUsageFile.key(for: "Fixture hotspot")
        let file = HotspotUsageFile(records: [key: HotspotUsageRecord(periodStarted: Date(timeIntervalSince1970: 100), ledger: HotspotUsageLedger(received: 400, sent: 400, budgetBytes: 1_000, warned: [.approaching]))])
        try usage.save(file)
        XCTAssertEqual(try usage.load(), file)
        let data = try Data(contentsOf: home.paths.hotspotUsageFile)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Fixture hotspot"))
        let mode = try FileManager.default.attributesOfItem(atPath: home.paths.hotspotUsageFile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try Data(contentsOf: home.paths.stateFile), before)
    }

    func testMissingCorruptUnknownVersionAndOversizedFilesAreDistinctFromZero() throws {
        let home = TempHome(); defer { home.destroy() }
        let store = Store(paths: home.paths)
        let usage = HotspotUsageStore(store: store)
        XCTAssertNil(try usage.load())
        for content in ["{broken", #"{"version":2,"records":{}}"#, String(repeating: "x", count: HotspotUsageStore.maximumBytes + 1)] {
            try OwnerOnly.createDirectory(home.paths.appSupport)
            try Data(content.utf8).write(to: home.paths.hotspotUsageFile)
            XCTAssertThrowsError(try usage.load())
            XCTAssertEqual(try Data(contentsOf: home.paths.hotspotUsageFile), Data(content.utf8))
        }
    }
}

@MainActor
final class HotspotUsageUITests: XCTestCase {
    func testCompactMenuShowsWarningAndPausedStateBesideSavedTotal() {
        let usage = HotspotUsageStatus(ledger: HotspotUsageLedger(received: 820_000_000, budgetBytes: 1_000_000_000), phase: .otherNetwork)
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], error: nil, hotspotUsage: usage)
        XCTAssertEqual(items.map(\.kind), [.hotspotUsage, .warning, .info, .separator, .settings, .quit])
        XCTAssertEqual(items[0].title, "Hotspot: 820 MB / 1.00 GB")
        XCTAssertEqual(items[2].title, "Paused, on another Wi-Fi network")
        let menu = StatusMenu.menu(items, target: nil, settings: #selector(UsageMenuTarget.settings), quit: #selector(UsageMenuTarget.quit), relaunchBrowser: #selector(UsageMenuTarget.quit), stopWaitingForOutput: #selector(UsageMenuTarget.quit))
        XCTAssertEqual(menu.items[0].action, #selector(UsageMenuTarget.settings))
        XCTAssertTrue(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[0].keyEquivalent, "")
        XCTAssertFalse(menu.items[1].isEnabled)
    }

    func testOptOutHidesMenuWhileSettingsRetainsSavedTotal() {
        let h = Harness(); defer { h.home.destroy() }
        let manager = h.makeManager()
        let source = PlaceholderStatus()
        source.hotspotUsage = HotspotUsageStatus(ledger: HotspotUsageLedger(received: 800, budgetBytes: 1_000), phase: .off)
        XCTAssertFalse(StatusItemController.menuItems(manager: manager, status: source).contains { $0.kind == .hotspotUsage })
        manager.config.trackHotspotUsage = true
        XCTAssertTrue(StatusItemController.menuItems(manager: manager, status: source).contains { $0.kind == .hotspotUsage })
    }

    func testBudgetEditorRejectsInvalidAndOverflowingValues() {
        XCTAssertEqual(HotspotUsageSettings.budgetBytes(gigabytes: 1.5), 1_500_000_000)
        XCTAssertEqual(HotspotUsageSettings.budgetBytes(gigabytes: 0), 0)
        for value in [Double.nan, .infinity, -1, 1_001, Double(UInt64.max)] {
            XCTAssertNil(HotspotUsageSettings.budgetBytes(gigabytes: value))
        }
    }

    func testNewConfigKeysDefaultToOptOutAndRoundTrip() throws {
        let old = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.trackHotspotUsage)
        XCTAssertEqual(old.hotspotBudgetBytes, 1_000_000_000)
        var c = Config(); c.trackHotspotUsage = true; c.hotspotBudgetBytes = 500_000_000
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: Store.makeEncoder().encode(c)), c)
        XCTAssertThrowsError(try Store.makeDecoder().decode(Config.self, from: Data(#"{"hotspotBudgetBytes":-1}"#.utf8)))
    }
}

@MainActor
private final class UsageMenuTarget: NSObject {
    @objc func settings() {}
    @objc func quit() {}
}

@MainActor
private final class UsageMemoryStore: HotspotUsageStoring {
    enum Failure: Error { case injected }
    var file: HotspotUsageFile?
    var failLoad = false
    var failSave = false
    var saves = 0
    func load() throws -> HotspotUsageFile? { if failLoad { throw Failure.injected }; return file }
    func save(_ file: HotspotUsageFile) throws { if failSave { throw Failure.injected }; self.file = file; saves += 1 }
}

private actor UsageScriptSampler: HotspotUsageSampling {
    private var values: [HotspotUsageReading]
    private let gatedRead: Int?
    private let gate: AsyncGate?
    private(set) var readCount = 0
    init(_ values: [HotspotUsageReading], gatedRead: Int? = nil, gate: AsyncGate? = nil) {
        self.values = values; self.gatedRead = gatedRead; self.gate = gate
    }
    func read() async -> HotspotUsageReading {
        let count = readCount; readCount += 1
        let value = values.isEmpty ? HotspotUsageReading(ssid: nil, sample: nil) : values.removeFirst()
        if count == gatedRead { await gate?.wait() }
        return value
    }
}

@MainActor
private final class UsageObserver: HotspotUsageObserving {
    var changed: (@MainActor () -> Void)?
    var unavailable: (@MainActor () -> Void)?
    var fail = false
    var starts = 0
    func start(changed: @escaping @MainActor () -> Void, unavailable: @escaping @MainActor () -> Void) throws {
        starts += 1
        if fail { throw UsageMemoryStore.Failure.injected }
        self.changed = changed; self.unavailable = unavailable
    }
    func stop() { changed = nil; unavailable = nil }
}

private final class UsageCheckingNotifier: Notifying, @unchecked Sendable {
    private let store: UsageMemoryStore
    @MainActor private(set) var titles: [String] = []
    @MainActor private(set) var bodies: [String] = []
    @MainActor private(set) var persistedAtPost: [UInt64] = []
    @MainActor init(store: UsageMemoryStore) { self.store = store }
    func post(title: String, body: String) {
        MainActor.assumeIsolated {
            titles.append(title); bodies.append(body)
            persistedAtPost.append(store.file?.records.values.first?.ledger.total ?? .max)
        }
    }
}
