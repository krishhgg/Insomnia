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
        XCTAssertEqual(processes.quitRequests.count, 0)
        XCTAssertEqual(processes.launches.count, 0)
    }

    private static let chrome = ThrottledBrowser(bundleId: "com.google.Chrome", name: "Chrome")

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

    func testKeychainSecretStoreUsesFailoverServiceAndCurrentSSID() throws {
        let keychain = FakeKeychainStore()
        var ssid = "Phone"
        let store = KeychainHotspotSecretStore(keychain: keychain) { ssid }

        try store.save("secret")

        XCTAssertEqual(try keychain.get(service: KeychainStore.service, account: "Phone"), "secret")
        XCTAssertEqual(try store.load(), "secret")

        ssid = "Other Phone"
        XCTAssertNil(try store.load())
    }

    func testKeychainSecretStoreMovesPasswordWhenSSIDChanges() throws {
        let keychain = FakeKeychainStore()
        var ssid = "Old Phone"
        let store = KeychainHotspotSecretStore(keychain: keychain) { ssid }
        try store.save("first")

        ssid = "New Phone"
        try store.save("replacement")

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
