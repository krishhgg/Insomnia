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
        services.status.throttledBrowsers = ["Chrome"]

        let source = LiveStatusSource(services: services)

        XCTAssertTrue(source.lidClosed)
        XCTAssertEqual(source.batteryPercent, 41)
        XCTAssertTrue(source.isCharging)
        XCTAssertEqual(source.wifiSSID, "iPhone")
        XCTAssertEqual(source.lastGap, 12)
        XCTAssertEqual(source.frozenCount, 3)
        XCTAssertTrue(source.dockerPaused)
        XCTAssertEqual(source.throttledBrowsers, ["Chrome"])
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

    @MainActor
    func testLiveStatusSourceMapsBrowserDisplayNameToBundleID() {
        let statuses = [
            BrowserStatus(bundleId: "com.google.Chrome", name: "Chrome", pid: 10, unthrottled: false),
            BrowserStatus(bundleId: "company.thebrowser.Browser", name: "Arc", pid: 11, unthrottled: false),
        ]

        XCTAssertEqual(LiveStatusSource.bundleID(forDisplayName: "Arc", in: statuses), "company.thebrowser.Browser")
        XCTAssertNil(LiveStatusSource.bundleID(forDisplayName: "Safari", in: statuses))
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
