import CoreLocation
import XCTest
@testable import Insomnia

final class IntegrationWiringTests: XCTestCase {
    @MainActor
    func testLiveStatusSourceReadsEveryValueFromSystemStatus() {
        let home = TempHome()
        defer { home.destroy() }
        let services = AppServices(
            paths: home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .authorizedAlways)
        )
        services.status.lidClosed = true
        services.status.batteryPercent = 41
        services.status.isCharging = true
        services.status.wifiSSID = "iPhone"
        services.status.lastGap = 12
        services.status.frozenCount = 3
        services.status.dockerPaused = true
        services.status.throttledBrowsers = [ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")]

        let source = LiveStatusSource(services: services)

        XCTAssertTrue(source.lidClosed)
        XCTAssertEqual(source.batteryPercent, 41)
        XCTAssertTrue(source.isCharging)
        XCTAssertEqual(source.wifiSSID, "iPhone")
        XCTAssertEqual(source.lastGap, 12)
        XCTAssertEqual(source.frozenCount, 3)
        XCTAssertTrue(source.dockerPaused)
        XCTAssertEqual(source.throttledBrowsers, [ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")])
        XCTAssertEqual(source.locationPermission.authorizationStatus, .authorizedAlways)
    }

    /// `reevaluateFloors()` is the hook Settings calls when a floor input
    /// changes. It queues on the floor chain exactly like a power event, so
    /// with no session (no floor driver) it does nothing. Starting the
    /// services needs the real lid and battery observers, so the queued run
    /// itself is covered at the driver level
    /// (`testTogglingLidOptionWhileLidIsClosedAppliesOnTheNextRun`).
    @MainActor
    func testReevaluateFloorsWithoutASessionIsANoOp() {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = RecordingNotifier()
        let services = AppServices(
            paths: home.paths,
            notifier: notifier,
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined)
        )
        services.status.lidClosed = true

        services.reevaluateFloors()

        XCTAssertFalse(services.running)
        XCTAssertTrue(services.status.lidClosed)
        XCTAssertEqual(notifier.posts.count, 0)
    }

    /// A scan that finishes while the confirmation is up can replace the
    /// browser list without the browser in it (a `ps` read that failed
    /// once). The relaunch goes by the bundle id the menu item carried,
    /// not by a lookup in that list, so the confirmed browser is still
    /// quit and opened again.
    @MainActor
    func testAConfirmedRelaunchDoesNotLookTheBrowserUpInTheList() async {
        let home = TempHome()
        defer { home.destroy() }
        let processes = FakeBrowserProcesses(pids: [42])
        processes.startWait = .pollsUntilCancelled
        let services = AppServices(
            paths: home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
        services.status.browsers = []
        services.status.throttledBrowsers = []

        LiveStatusSource(services: services).relaunchUnthrottled(Self.chrome)
        await fulfillment(of: [processes.insideStartWait], timeout: 60)
        services.cancelBrowserTasks()

        XCTAssertEqual(processes.terminated, [[42]])
        XCTAssertEqual(processes.launches.map(\.bundleId), ["com.google.Chrome"])
    }

    /// The confirmed browser quit before the relaunch ran. The throttle
    /// finds no instance of it, quits and launches nothing, and the user
    /// is told, by the name the menu showed, even though the browser list
    /// no longer has it.
    @MainActor
    func testAConfirmedRelaunchOfABrowserThatHasGoneSaysSo() async {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = ExpectingNotifier()
        let processes = FakeBrowserProcesses(pids: [])
        let services = AppServices(
            paths: home.paths,
            notifier: notifier,
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
        services.status.browsers = []

        LiveStatusSource(services: services).relaunchUnthrottled(Self.chrome)
        await fulfillment(of: [notifier.posted], timeout: 60)
        services.cancelBrowserTasks()

        XCTAssertEqual(notifier.posts.map(\.title), ["Browser not relaunched"])
        XCTAssertEqual(notifier.posts.map(\.body), ["Chrome is not running. Nothing was quit or relaunched."])
        XCTAssertEqual(services.status.relaunchProblems, ["com.google.Chrome": "Chrome is not running. Nothing was quit or relaunched."])
        XCTAssertEqual(processes.quitRequests.count, 0)
        XCTAssertEqual(processes.launches.count, 0)
    }

    private static let chrome = ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")

    /// Notifications can be off for Insomnia, so the reason a relaunch
    /// stopped short is also a warning line in the menu, built the way the
    /// status item builds it. Here the browser quit and `open` failed: the
    /// browser is closed, and the line says to open it by hand.
    @MainActor
    func testARelaunchWhoseOpenFailsLeavesTheReasonInTheMenu() async {
        let h = Harness()
        defer { h.home.destroy() }
        let processes = FakeBrowserProcesses(pids: [42])
        processes.launchFailure = "LSOpenURLsWithRole() failed with error -10810"
        let services = AppServices(
            paths: h.home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
        let source = LiveStatusSource(services: services)

        await services.relaunchUnthrottled(Self.chrome)

        let reason = "Chrome quit but could not be relaunched: LSOpenURLsWithRole() failed with error -10810. Open it yourself."
        XCTAssertEqual(source.relaunchProblems, [reason])
        let items = StatusItemController.menuItems(manager: h.makeManager(), status: source)
        // The scan after the relaunch lists whatever browsers this Mac is
        // running, so only the line itself is checked.
        XCTAssertTrue(items.contains(StatusMenu.Item(title: "\u{26A0} \(reason)", kind: .warning)), "\(items.map(\.title))")
    }

    /// The failover's report about the hotspot password is a menu line
    /// while that hotspot is the one configured. After an SSID edit it is
    /// about an item no join reads, and the line goes; editing the SSID
    /// back brings it back, since nothing has changed that item.
    @MainActor
    func testTheMenuShowsTheHotspotReportOnlyForTheConfiguredSSID() {
        let h = Harness()
        defer { h.home.destroy() }
        let services = AppServices(
            paths: h.home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined)
        )
        let source = LiveStatusSource(services: services)
        let manager = h.makeManager()
        manager.config.hotspotSSID = "Phone"
        services.status.hotspotPasswordReport = HotspotPasswordReport(ssid: "Phone", problem: .unreadable)
        // A debug build also has the lid simulation line.
        func warnings() -> [String] {
            StatusItemController.menuItems(manager: manager, status: source).map(\.title).filter { $0.contains("Hotspot") }
        }

        XCTAssertEqual(warnings(), [HotspotPasswordProblem.unreadable.menuLine])
        manager.config.hotspotSSID = "Other Phone"
        XCTAssertEqual(warnings(), [])
        manager.config.hotspotSSID = " Phone "
        XCTAssertEqual(warnings(), [HotspotPasswordProblem.unreadable.menuLine])
    }

    /// The line belongs to the last relaunch. Starting another clears it
    /// while that one runs, and one that relaunches the browser leaves no
    /// line.
    @MainActor
    func testTheNextRelaunchReplacesTheMenuLine() async {
        let home = TempHome()
        defer { home.destroy() }
        let processes = FakeBrowserProcesses(pids: [42])
        processes.quits = false
        let services = AppServices(
            paths: home.paths,
            notifier: RecordingNotifier(),
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
        await services.relaunchUnthrottled(Self.chrome)
        XCTAssertNotNil(services.status.relaunchProblems["com.google.Chrome"])

        processes.quits = true
        processes.startWait = .pollsUntilCancelled
        let waiting = Task { await services.relaunchUnthrottled(Self.chrome) }
        await fulfillment(of: [processes.insideStartWait], timeout: 60)
        XCTAssertNil(services.status.relaunchProblems["com.google.Chrome"], "a relaunch in progress still showed the last one's failure")
        services.cancelBrowserTasks()
        await waiting.value

        processes.startWait = .appears
        processes.start(pid: 43)
        services.status.relaunchProblems["com.google.Chrome"] = "left by an earlier relaunch"
        await services.relaunchUnthrottled(Self.chrome)
        XCTAssertEqual(services.status.relaunchProblems, [:])
        XCTAssertEqual(processes.launches.count, 2)
    }

    /// Two relaunches of the same browser overlap: the first still waits
    /// for the browser to quit when the second relaunches it. The first
    /// then ends without its quit. Its outcome is not the latest word on
    /// that browser, so it leaves no line and posts nothing.
    @MainActor
    func testAnOlderRelaunchOfTheSameBrowserThatEndsLastIsDropped() async {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = RecordingNotifier()
        let processes = FakeBrowserProcesses(pids: [42])
        let services = Self.services(home: home, notifier: notifier, processes: processes)
        processes.quits = false
        processes.holdsNextQuit = true
        let first = Task { await services.relaunchUnthrottled(Self.chrome) }
        await fulfillment(of: [processes.insideQuitWait], timeout: 60)

        processes.quits = true
        await services.relaunchUnthrottled(Self.chrome)
        processes.releaseQuit()
        await first.value

        XCTAssertEqual(processes.launches.count, 1, "the second relaunch opened the browser")
        XCTAssertEqual(notifier.posts.map(\.body), [])
        XCTAssertEqual(services.status.relaunchProblems, [:])
    }

    /// Relaunches of two browsers overlap and both stop short. Each is the
    /// newest relaunch of its browser, so each keeps its own line, beside
    /// a line an earlier relaunch of a third browser left, and each is
    /// notified.
    @MainActor
    func testOverlappingRelaunchesOfTwoBrowsersEachKeepTheirLine() async {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = RecordingNotifier()
        let processes = FakeBrowserProcesses(pids: [42])
        processes.start(bundleId: "com.brave.Browser", pid: 50)
        let services = Self.services(home: home, notifier: notifier, processes: processes)
        services.status.relaunchProblems["com.microsoft.edgemac"] = "Edge is not running. Nothing was quit or relaunched."
        processes.quits = false
        processes.holdsNextQuit = true
        let first = Task { await services.relaunchUnthrottled(Self.chrome) }
        await fulfillment(of: [processes.insideQuitWait], timeout: 60)

        processes.quits = true
        processes.launchFailure = "boom"
        await services.relaunchUnthrottled(ThrottledBrowser(bundleId: "com.brave.Browser", name: "Brave"))
        processes.releaseQuit()
        await first.value

        let brave = "Brave quit but could not be relaunched: boom. Open it yourself."
        let chrome = "Chrome did not quit within 10 s, so nothing was relaunched. It may still quit later. If it does, open it again yourself."
        XCTAssertEqual(notifier.posts.map(\.body), [brave, chrome])
        XCTAssertEqual(LiveStatusSource(services: services).relaunchProblems, [
            brave, chrome, "Edge is not running. Nothing was quit or relaunched.",
        ])
    }

    /// The session ends while a relaunch waits for the browser to quit.
    /// `stop()` cancels the relaunch, but the wait for the quit goes on;
    /// when it ends, its outcome belongs to a session that is over, so it
    /// leaves no line, which a new session's menu would otherwise show,
    /// and posts nothing.
    @MainActor
    func testARelaunchWhoseSessionEndedDuringTheQuitWaitReportsNothing() async {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = RecordingNotifier()
        let processes = FakeBrowserProcesses(pids: [42])
        let services = Self.services(home: home, notifier: notifier, processes: processes)
        processes.quits = false
        processes.holdsNextQuit = true
        let relaunch = Task { await services.relaunchUnthrottled(Self.chrome) }
        await fulfillment(of: [processes.insideQuitWait], timeout: 60)

        services.cancelBrowserTasks()
        processes.releaseQuit()
        await relaunch.value

        XCTAssertEqual(processes.terminated, [[42]])
        XCTAssertEqual(notifier.posts.map(\.body), [])
        XCTAssertEqual(services.status.relaunchProblems, [:])
    }

    @MainActor
    private static func services(home: TempHome, notifier: RecordingNotifier, processes: FakeBrowserProcesses) -> AppServices {
        AppServices(
            paths: home.paths,
            notifier: notifier,
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
    }

    /// Without a delegate asking for them, macOS drops notifications while
    /// Insomnia is frontmost, as it is right after the relaunch
    /// confirmation. The delegate asks for the same presentation as when
    /// another app is frontmost. `install()` needs the notification center,
    /// which only an app bundle has, so here it must do nothing.
    func testNotificationsAreShownWhileInsomniaIsFrontmost() {
        XCTAssertEqual(ForegroundNotifications.presentation, [.banner, .list, .sound])
        XCTAssertFalse(Notifier.runningInsideAppBundle())
        ForegroundNotifications.install()
    }

    /// A relaunch that stops short (here the browser is still running when
    /// the wait ends) reaches the user as a notification naming the browser,
    /// and nothing is launched.
    @MainActor
    func testARelaunchThatStopsShortIsNotifiedAndLaunchesNothing() async {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = RecordingNotifier()
        let processes = FakeBrowserProcesses(pids: [42])
        processes.quits = false
        let services = AppServices(
            paths: home.paths,
            notifier: notifier,
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
        services.status.browsers = [BrowserStatus(bundleId: "com.google.Chrome", name: "Chrome", pid: 42, unthrottled: false)]

        await services.relaunchUnthrottled(Self.chrome)

        XCTAssertEqual(notifier.posts.map(\.title), ["Browser not relaunched"])
        XCTAssertEqual(notifier.posts.map(\.body), ["Chrome did not quit within 10 s, so nothing was relaunched. It may still quit later. If it does, open it again yourself."])
        XCTAssertEqual(processes.terminated, [[42]])
        XCTAssertEqual(processes.launches.count, 0)
    }

    /// The session ending while a relaunched browser has not appeared yet:
    /// `stop()` cancels the relaunch through `cancelBrowserTasks()`. The
    /// relaunch returns at once, without holding the main actor until the
    /// start deadline, and posts nothing, since the user ended the session.
    @MainActor
    func testARelaunchCancelledDuringTheStartWaitReturnsAtOnceAndPostsNothing() async {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = RecordingNotifier()
        let processes = FakeBrowserProcesses(pids: [42])
        processes.startWait = .pollsUntilCancelled
        let services = AppServices(
            paths: home.paths,
            notifier: notifier,
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
        services.status.browsers = [BrowserStatus(bundleId: "com.google.Chrome", name: "Chrome", pid: 42, unthrottled: false)]

        let relaunch = Task { await services.relaunchUnthrottled(Self.chrome) }
        await fulfillment(of: [processes.insideStartWait], timeout: 60)
        let checksAtCancel = processes.startChecks
        services.cancelBrowserTasks()
        await relaunch.value

        XCTAssertEqual(notifier.posts.count, 0)
        XCTAssertLessThanOrEqual(processes.startChecks, checksAtCancel + 1, "the wait kept checking after the cancel")
        XCTAssertEqual(processes.launches.count, 1)
    }

    /// A browser scan that finishes during the relaunch replaces the
    /// browser list, and the quit browser is not in it. The notification
    /// still names the browser, not its bundle id: the name is the one the
    /// user confirmed.
    @MainActor
    func testARelaunchFailureNamesTheBrowserAfterTheListChanged() async {
        let home = TempHome()
        defer { home.destroy() }
        let notifier = RecordingNotifier()
        let processes = FakeBrowserProcesses(pids: [42])
        processes.quits = false
        let services = AppServices(
            paths: home.paths,
            notifier: notifier,
            audio: FakeAudioControl(),
            processControl: FakeProcessControl(),
            locationPermission: LocationPermission(authorizationStatus: .notDetermined),
            browser: BrowserThrottle(readArgs: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" }, processes: processes)
        )
        services.status.browsers = [BrowserStatus(bundleId: "com.google.Chrome", name: "Chrome", pid: 42, unthrottled: false)]
        processes.duringQuit = { services.status.browsers = [] }

        await services.relaunchUnthrottled(Self.chrome)

        XCTAssertEqual(processes.quitRequests.count, 1, "the list was cleared during the quit wait")
        XCTAssertEqual(notifier.posts.map(\.body), ["Chrome did not quit within 10 s, so nothing was relaunched. It may still quit later. If it does, open it again yourself."])
    }

    @MainActor
    func testKeychainSecretStoreUsesFailoverServiceAndCurrentSSID() async throws {
        let keychain = FakeKeychainStore()
        let ssid = Locked("Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }

        try await store.save("secret")

        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "secret")
        let loaded = try await store.load()
        XCTAssertEqual(loaded, "secret")

        ssid.value = "Other Phone"
        let other = try await store.load()
        XCTAssertNil(other)
    }

    @MainActor
    func testKeychainSecretStoreMovesPasswordWhenSSIDChanges() async throws {
        let keychain = FakeKeychainStore()
        let ssid = Locked("Old Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        try await store.save("first")

        ssid.value = "New Phone"
        try await store.save("replacement")

        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Old Phone"))
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "New Phone"), "replacement")
    }

    /// Settings rereads the password when the failover's report clears.
    /// That check must not change which account a save moves the password
    /// from, or an SSID typed meanwhile leaves the old item behind.
    @MainActor
    func testAPeekAfterAnSSIDChangeStillLetsASaveMoveThePassword() async throws {
        let keychain = FakeKeychainStore()
        let ssid = Locked("Old Phone")
        let store = KeychainHotspotSecretStore(keychain: keychain, queue: KeychainQueue()) { ssid.value }
        try await store.save("first")
        let loaded = try await store.load()
        XCTAssertEqual(loaded, "first")

        ssid.value = "New Phone"
        let peeked = try await store.peek()
        XCTAssertNil(peeked)
        try await store.save("replacement")

        XCTAssertNil(try keychain.get(service: KeychainStore.service, account: "Old Phone"))
        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "New Phone"), "replacement")
    }

    func testWiFiStatusNameExplainsLocationRedaction() {
        XCTAssertEqual(
            WiFiStatusName.display(ssid: nil, locationAuthorized: false),
            "on (name hidden until Location is allowed)"
        )
        XCTAssertEqual(WiFiStatusName.display(ssid: "Office", locationAuthorized: false), "Office")
        XCTAssertNil(WiFiStatusName.display(ssid: nil, locationAuthorized: true))
    }

    /// macOS has no `.authorizedWhenInUse`; a granted when-in-use request
    /// reports `.authorizedAlways`, which is the only grant we can observe.
    @MainActor
    func testGrantedLocationCountsAsAuthorized() {
        let permission = LocationPermission(authorizationStatus: .authorizedAlways)
        XCTAssertTrue(permission.isAuthorized)
        XCTAssertFalse(permission.isDenied)
        XCTAssertEqual(permission.statusDescription, "Allowed")
    }

    @MainActor
    func testUngrantedLocationStatusesAreNotAuthorized() {
        let denied = LocationPermission(authorizationStatus: .denied)
        XCTAssertFalse(denied.isAuthorized)
        XCTAssertTrue(denied.isDenied)
        XCTAssertEqual(denied.statusDescription, "Denied")

        let undetermined = LocationPermission(authorizationStatus: .notDetermined)
        XCTAssertFalse(undetermined.isAuthorized)
        XCTAssertEqual(undetermined.statusDescription, "Not requested")
    }
}

/// Records posts like `RecordingNotifier` and fulfills `posted` at the
/// first, for a test that waits on a task it cannot await.
final class ExpectingNotifier: Notifying, @unchecked Sendable {
    private let recorder = RecordingNotifier()
    let posted: XCTestExpectation = {
        let e = XCTestExpectation(description: "a notification was posted")
        e.assertForOverFulfill = false
        return e
    }()
    var posts: [(title: String, body: String)] { recorder.posts }

    func post(title: String, body: String) {
        recorder.post(title: title, body: body)
        posted.fulfill()
    }
}
