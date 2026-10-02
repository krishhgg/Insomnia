import AppKit
import ServiceManagement
import XCTest
@testable import Insomnia

/// Stands in for `SMAppService.mainApp`: the status it will report next,
/// and whether register or unregister throws.
@MainActor
final class FakeLoginItemService: LoginItemServicing {
    var status: LoginItemStatus
    /// What `status` becomes after a successful register.
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: String?
    var unregisterError: String?
    private(set) var registers = 0
    private(set) var unregisters = 0
    private(set) var opens = 0

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        registers += 1
        if let registerError {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: registerError])
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisters += 1
        if let unregisterError {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: unregisterError])
        }
        status = .notRegistered
    }

    func openSystemSettingsLoginItems() { opens += 1 }
}

/// Launch at login kept in step with what macOS reports. The suspicion
/// behind this (a login item silently dropped after install.sh renews the
/// ad-hoc signature) is driven here through the fake; the real reinstall
/// is a hardware row in docs/release-validation.md. Nothing here touches
/// `SMAppService`.
@MainActor
final class LoginItemTests: XCTestCase {
    private var home: TempHome!
    /// Where the Mac's activation notification arrives from in these tests,
    /// so a real activation never reaches a test's LoginItem.
    private var activity: NotificationCenter!

    /// The running install and the one a reinstall leaves behind.
    private let thisInstall = "0b1c@/Users/me/Applications/Insomnia.app"
    private let earlierInstall = "a9f0@/Users/me/Applications/Insomnia.app"

    override func setUp() async throws {
        home = TempHome()
        activity = NotificationCenter()
    }

    override func tearDown() async throws {
        home.destroy()
    }

    private func log() -> String {
        (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
    }

    private func makeItem(_ service: FakeLoginItemService) -> LoginItem {
        LoginItem(service: service, install: thisInstall, activity: activity)
    }

    /// config.json with the flag on and the given install on file.
    private func wanted(install: String?) -> Config {
        var c = Config()
        c.launchAtLogin = true
        c.launchAtLoginInstall = install
        return c
    }

    // MARK: Launch

    /// The flag is on, macOS no longer reports the item and the install on
    /// file is a different one (the shape a reinstall leaves): the app
    /// registers again and records the new install.
    func testLaunchRegistersAgainWhenTheInstallChanged() {
        let service = FakeLoginItemService(status: .notRegistered)
        let item = makeItem(service)
        var config = wanted(install: earlierInstall)

        XCTAssertTrue(item.healAtLaunch(config: &config))

        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(item.status, .enabled)
        XCTAssertTrue(item.isEnabled)
        XCTAssertNil(item.error)
        XCTAssertTrue(config.launchAtLogin)
        XCTAssertEqual(config.launchAtLoginInstall, thisInstall)
        XCTAssertTrue(log().contains("the install changed; registering again"), log())
        XCTAssertTrue(log().contains("registered again"), log())
    }

    /// macOS no longer reports the item for the very install it had on
    /// file: nothing but the user removing it in System Settings does
    /// that, so the app follows and turns the flag off instead of putting
    /// the item back.
    func testLaunchRespectsARemovalOfTheSameInstall() {
        for status in [LoginItemStatus.notRegistered, .notFound, .unknown(9)] {
            let service = FakeLoginItemService(status: status)
            let item = makeItem(service)
            var config = wanted(install: thisInstall)

            XCTAssertTrue(item.healAtLaunch(config: &config), "\(status)")

            XCTAssertEqual(service.registers, 0, "\(status)")
            XCTAssertEqual(service.unregisters, 0, "\(status)")
            XCTAssertFalse(config.launchAtLogin, "\(status)")
            XCTAssertNil(config.launchAtLoginInstall, "\(status)")
            XCTAssertEqual(item.status, status)
        }
        XCTAssertTrue(log().contains("treating that as removed in System Settings and turning the flag off"), log())
    }

    /// The first upgrade to a build that records the install: config.json
    /// has the flag on and no record, and the reinstall dropped the item.
    /// That launch is itself a reinstall, so the app registers once and
    /// records the install. Once: if the item then goes away for this
    /// install, the next launch reads it as removed by the user.
    func testFirstUpgradeFromAConfigWithoutARecordRegistersOnce() {
        let service = FakeLoginItemService(status: .notRegistered)
        let item = makeItem(service)
        var config = wanted(install: nil)

        XCTAssertTrue(item.healAtLaunch(config: &config))

        XCTAssertEqual(service.registers, 1)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(config.launchAtLogin)
        XCTAssertEqual(config.launchAtLoginInstall, thisInstall)
        XCTAssertTrue(log().contains("no install is on record (a config from before the record existed); treating this as the first launch after an upgrade, registering once and recording the install"), log())
        XCTAssertTrue(log().contains("registered again; install recorded"), log())

        service.status = .notRegistered
        XCTAssertTrue(item.healAtLaunch(config: &config))

        XCTAssertEqual(service.registers, 1, "not registered a second time")
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertNil(config.launchAtLoginInstall)
    }

    /// The one-time registration fails: nothing is recorded, so the next
    /// launch tries again rather than reading the gap as a removal.
    func testFirstUpgradeWhoseRegisterFailsRecordsNothing() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = "refused"
        let item = makeItem(service)
        var config = wanted(install: nil)

        XCTAssertFalse(item.healAtLaunch(config: &config))

        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(item.error, "refused")
        XCTAssertEqual(config, wanted(install: nil))
    }

    /// Enabled: nothing to register. The install is recorded when it is
    /// not yet (or no longer) the one on file, so a later removal can be
    /// told from a reinstall.
    func testLaunchLeavesAnEnabledItemAloneAndRecordsTheInstall() {
        let service = FakeLoginItemService(status: .enabled)
        let item = makeItem(service)
        var config = wanted(install: nil)

        XCTAssertTrue(item.healAtLaunch(config: &config))
        XCTAssertEqual(config.launchAtLoginInstall, thisInstall)

        XCTAssertFalse(item.healAtLaunch(config: &config), "already on file")

        XCTAssertEqual(service.registers, 0)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(log().contains("launch at login: enabled"), log())
    }

    /// Waiting for approval is registered: registering again would not
    /// move macOS, so the app only says so and records the install.
    func testLaunchDoesNotRegisterAgainWhileWaitingForApproval() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = makeItem(service)
        var config = wanted(install: earlierInstall)

        XCTAssertTrue(item.healAtLaunch(config: &config))

        XCTAssertEqual(service.registers, 0)
        XCTAssertTrue(item.needsApproval)
        XCTAssertTrue(item.isRegistered)
        XCTAssertTrue(config.launchAtLogin)
        XCTAssertEqual(config.launchAtLoginInstall, thisInstall)
        XCTAssertTrue(log().contains("launch at login: waiting for approval"), log())
    }

    /// With the flag off nothing is registered, unregistered or written,
    /// whatever macOS reports: an item the user set up in System Settings
    /// is theirs.
    func testLaunchTouchesNothingWhenNotWanted() {
        for status in [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound] {
            let service = FakeLoginItemService(status: status)
            let item = makeItem(service)
            var config = Config()

            XCTAssertFalse(item.healAtLaunch(config: &config), "\(status)")

            XCTAssertEqual(service.registers, 0, "\(status)")
            XCTAssertEqual(service.unregisters, 0, "\(status)")
            XCTAssertEqual(config, Config(), "\(status)")
            XCTAssertEqual(item.status, status)
        }
    }

    /// macOS accepts the registration but wants the user's approval: not
    /// an error, shown as pending so Settings can offer the Login Items
    /// button, and the install is on file.
    func testLaunchSurfacesAPendingApproval() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let item = makeItem(service)
        var config = wanted(install: earlierInstall)

        XCTAssertTrue(item.healAtLaunch(config: &config))

        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(item.status, .requiresApproval)
        XCTAssertTrue(item.needsApproval)
        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(item.isRegistered, "the switch shows it as on, so it can be withdrawn")
        XCTAssertNil(item.error)
        XCTAssertEqual(config.launchAtLoginInstall, thisInstall)
        XCTAssertTrue(log().contains("waiting for approval"), log())
    }

    /// A register that throws at launch is kept on `error` for Settings,
    /// not only logged, and the config is left as it was.
    func testLaunchKeepsARegisterFailureForSettings() {
        let service = FakeLoginItemService(status: .notFound)
        service.registerError = "The operation couldn’t be completed. (OSStatus error -10814.)"
        let item = makeItem(service)
        var config = wanted(install: earlierInstall)

        XCTAssertFalse(item.healAtLaunch(config: &config))

        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(item.error, "The operation couldn’t be completed. (OSStatus error -10814.)")
        XCTAssertEqual(item.status, .notFound)
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(config, wanted(install: earlierInstall))
        XCTAssertTrue(log().contains("register failed at launch"), log())
    }

    /// Registered again but macOS still does not report it: said so in the
    /// log rather than treated as success, and the install is not recorded
    /// (recording it would read as a removal at the next launch).
    func testLaunchReportsAnUnchangedStatusAfterRegistering() {
        let service = FakeLoginItemService(status: .notFound)
        service.statusAfterRegister = .notFound
        let item = makeItem(service)
        var config = wanted(install: earlierInstall)

        XCTAssertFalse(item.healAtLaunch(config: &config))

        XCTAssertEqual(item.status, .notFound)
        XCTAssertEqual(config.launchAtLoginInstall, earlierInstall)
        XCTAssertTrue(log().contains("still not found by macOS after registering again"), log())
    }

    // MARK: Settings switch

    func testSetOnRegistersAndRecordsTheInstall() {
        let service = FakeLoginItemService(status: .notRegistered)
        let item = makeItem(service)
        var config = Config()

        XCTAssertTrue(item.set(true, config: &config))

        XCTAssertEqual(service.registers, 1)
        XCTAssertTrue(item.isEnabled)
        XCTAssertNil(item.error)
        XCTAssertTrue(config.launchAtLogin)
        XCTAssertEqual(config.launchAtLoginInstall, thisInstall)
    }

    /// A registration that waits for approval is accepted (the flag and
    /// the install are persisted) and shown as pending, with the switch on.
    func testSetOnThatNeedsApprovalIsAcceptedAndPending() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let item = makeItem(service)
        var config = Config()

        XCTAssertTrue(item.set(true, config: &config))

        XCTAssertTrue(item.needsApproval)
        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(item.isRegistered)
        XCTAssertNil(item.error)
        XCTAssertTrue(config.launchAtLogin)
        XCTAssertEqual(config.launchAtLoginInstall, thisInstall)
    }

    /// Turning the switch off while the registration waits for approval
    /// withdraws it: macOS is asked to unregister and the flag goes off,
    /// so later launches stop asking.
    func testSetOffWithdrawsAPendingApproval() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = makeItem(service)
        var config = wanted(install: thisInstall)
        XCTAssertTrue(item.isRegistered, "the switch starts on")

        XCTAssertTrue(item.set(false, config: &config))

        XCTAssertEqual(service.unregisters, 1)
        XCTAssertEqual(service.registers, 0)
        XCTAssertFalse(item.isRegistered)
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertNil(config.launchAtLoginInstall)
    }

    /// Accepted by macOS but still not on file (not found): the flag is
    /// persisted, the install is not, so the next launch does not read it
    /// as a removal.
    func testSetOnThatStaysNotFoundRecordsNoInstall() {
        let service = FakeLoginItemService(status: .notFound)
        service.statusAfterRegister = .notFound
        let item = makeItem(service)
        var config = Config()

        XCTAssertTrue(item.set(true, config: &config))

        XCTAssertTrue(config.launchAtLogin)
        XCTAssertNil(config.launchAtLoginInstall)
    }

    func testSetOnFailureKeepsTheErrorAndIsNotAccepted() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = "refused"
        let item = makeItem(service)
        var config = Config()

        XCTAssertFalse(item.set(true, config: &config))

        XCTAssertEqual(item.error, "refused")
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(config, Config())
        XCTAssertTrue(log().contains("launch at login register failed: refused"), log())
    }

    func testSetOffUnregistersAndClearsAnEarlierError() {
        let service = FakeLoginItemService(status: .enabled)
        let item = makeItem(service)
        var config = wanted(install: thisInstall)
        service.registerError = "refused"
        _ = item.set(true, config: &config)
        XCTAssertNotNil(item.error)
        service.registerError = nil

        XCTAssertTrue(item.set(false, config: &config))

        XCTAssertEqual(service.unregisters, 1)
        XCTAssertEqual(item.status, .notRegistered)
        XCTAssertNil(item.error)
        XCTAssertFalse(config.launchAtLogin)
        XCTAssertNil(config.launchAtLoginInstall)
    }

    func testSetOffFailureKeepsTheErrorAndIsNotAccepted() {
        let service = FakeLoginItemService(status: .enabled)
        service.unregisterError = "busy"
        let item = makeItem(service)
        var config = wanted(install: thisInstall)

        XCTAssertFalse(item.set(false, config: &config))

        XCTAssertEqual(item.error, "busy")
        XCTAssertTrue(item.isEnabled, "macOS still has it")
        XCTAssertEqual(config, wanted(install: thisInstall))
    }

    // MARK: Status refresh

    /// Settings re-reads the status on appear: an approval given in System
    /// Settings since the launch check is picked up without a relaunch.
    func testRefreshPicksUpAnApprovalGivenElsewhere() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = makeItem(service)
        XCTAssertTrue(item.needsApproval)

        service.status = .enabled
        item.refresh()

        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(item.needsApproval)
    }

    /// The user approves (or removes) the item in System Settings and comes
    /// back to a Settings window that stayed open: the app becoming active
    /// re-reads the status, since onAppear does not run again.
    func testAppBecomingActiveRefreshesTheStatus() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = makeItem(service)
        XCTAssertTrue(item.needsApproval)

        service.status = .enabled
        activity.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(item.isEnabled, "approval picked up")

        service.status = .notRegistered
        activity.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(item.isRegistered, "removal picked up")
    }

    /// Activations from another center (the real one, in the app) do not
    /// reach an item built on this one, and vice versa.
    func testOnlyTheGivenCenterDrivesTheRefresh() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = makeItem(service)

        service.status = .enabled
        NotificationCenter().post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(item.needsApproval, "still the cached status")
    }

    func testOpenLoginItemsForwardsToTheService() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = makeItem(service)

        item.openLoginItems()

        XCTAssertEqual(service.opens, 1)
    }

    // MARK: Status mapping

    func testEverySMAppServiceStatusMaps() {
        XCTAssertEqual(LoginItemStatus(.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemStatus(.enabled), .enabled)
        XCTAssertEqual(LoginItemStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItemStatus(.notFound), .notFound)
        XCTAssertEqual(LoginItemStatus.unknown(9).description, "unknown status 9")
        XCTAssertEqual(LoginItemStatus.requiresApproval.description, "waiting for approval")
    }

    /// The live install identity has the two parts macOS ties the item
    /// to: a hash (or "unsigned") and the bundle path. Read only.
    func testLiveInstallNamesHashAndPath() {
        let install = LoginItem.liveInstall()
        let parts = install.split(separator: "@", maxSplits: 1)
        XCTAssertEqual(parts.count, 2, install)
        XCTAssertEqual(String(parts[1]), Bundle.main.bundleURL.path)
        XCTAssertTrue(parts[0] == "unsigned" || parts[0].allSatisfy(\.isHexDigit), install)
    }
}
