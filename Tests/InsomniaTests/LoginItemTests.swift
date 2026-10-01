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
/// is a hardware row in docs/release-validation.md.
@MainActor
final class LoginItemTests: XCTestCase {
    private var home: TempHome!

    override func setUp() async throws {
        home = TempHome()
    }

    override func tearDown() async throws {
        home.destroy()
    }

    private func log() -> String {
        (try? String(contentsOf: home.paths.logFile, encoding: .utf8)) ?? ""
    }

    // MARK: Launch

    /// The flag is on but macOS no longer reports the item enabled (the
    /// shape a reinstall leaves): the app registers again.
    func testLaunchRegistersAgainWhenWantedAndNotEnabled() {
        let service = FakeLoginItemService(status: .notRegistered)
        let item = LoginItem(service: service)

        item.healAtLaunch(wanted: true)

        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(item.status, .enabled)
        XCTAssertTrue(item.isEnabled)
        XCTAssertNil(item.error)
        XCTAssertTrue(log().contains("registering again"), log())
        XCTAssertTrue(log().contains("registered again"), log())
    }

    func testLaunchLeavesAnEnabledItemAlone() {
        let service = FakeLoginItemService(status: .enabled)
        let item = LoginItem(service: service)

        item.healAtLaunch(wanted: true)

        XCTAssertEqual(service.registers, 0)
        XCTAssertTrue(item.isEnabled)
    }

    /// With the flag off nothing is registered or unregistered, whatever
    /// macOS reports: an item the user set up in System Settings is theirs.
    func testLaunchTouchesNothingWhenNotWanted() {
        for status in [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound] {
            let service = FakeLoginItemService(status: status)
            let item = LoginItem(service: service)

            item.healAtLaunch(wanted: false)

            XCTAssertEqual(service.registers, 0, "\(status)")
            XCTAssertEqual(service.unregisters, 0, "\(status)")
            XCTAssertEqual(item.status, status)
        }
    }

    /// macOS accepts the registration but wants the user's approval: not
    /// an error, shown as pending so Settings can offer the Login Items
    /// button.
    func testLaunchSurfacesAPendingApproval() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let item = LoginItem(service: service)

        item.healAtLaunch(wanted: true)

        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(item.status, .requiresApproval)
        XCTAssertTrue(item.needsApproval)
        XCTAssertFalse(item.isEnabled, "the switch shows the real state, not the flag")
        XCTAssertNil(item.error)
        XCTAssertTrue(log().contains("waiting for approval"), log())
    }

    /// A register that throws at launch is kept on `error` for Settings,
    /// not only logged.
    func testLaunchKeepsARegisterFailureForSettings() {
        let service = FakeLoginItemService(status: .notFound)
        service.registerError = "The operation couldn’t be completed. (OSStatus error -10814.)"
        let item = LoginItem(service: service)

        item.healAtLaunch(wanted: true)

        XCTAssertEqual(service.registers, 1)
        XCTAssertEqual(item.error, "The operation couldn’t be completed. (OSStatus error -10814.)")
        XCTAssertEqual(item.status, .notFound)
        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(log().contains("register failed at launch"), log())
    }

    /// Registered again but macOS still does not report it enabled: said
    /// so in the log rather than treated as success.
    func testLaunchReportsAnUnchangedStatusAfterRegistering() {
        let service = FakeLoginItemService(status: .notFound)
        service.statusAfterRegister = .notFound
        let item = LoginItem(service: service)

        item.healAtLaunch(wanted: true)

        XCTAssertEqual(item.status, .notFound)
        XCTAssertTrue(log().contains("still not found by macOS after registering again"), log())
    }

    // MARK: Settings switch

    func testSetOnRegistersAndReportsAcceptance() {
        let service = FakeLoginItemService(status: .notRegistered)
        let item = LoginItem(service: service)

        XCTAssertTrue(item.set(true))

        XCTAssertEqual(service.registers, 1)
        XCTAssertTrue(item.isEnabled)
        XCTAssertNil(item.error)
    }

    /// A registration that waits for approval is accepted (the flag is
    /// persisted) and shown as pending.
    func testSetOnThatNeedsApprovalIsAcceptedAndPending() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let item = LoginItem(service: service)

        XCTAssertTrue(item.set(true))

        XCTAssertTrue(item.needsApproval)
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(item.error)
    }

    func testSetOnFailureKeepsTheErrorAndIsNotAccepted() {
        let service = FakeLoginItemService(status: .notRegistered)
        service.registerError = "refused"
        let item = LoginItem(service: service)

        XCTAssertFalse(item.set(true))

        XCTAssertEqual(item.error, "refused")
        XCTAssertFalse(item.isEnabled)
        XCTAssertTrue(log().contains("launch at login register failed: refused"), log())
    }

    func testSetOffUnregistersAndClearsAnEarlierError() {
        let service = FakeLoginItemService(status: .enabled)
        let item = LoginItem(service: service)
        service.registerError = "refused"
        _ = item.set(true)
        XCTAssertNotNil(item.error)
        service.registerError = nil

        XCTAssertTrue(item.set(false))

        XCTAssertEqual(service.unregisters, 1)
        XCTAssertEqual(item.status, .notRegistered)
        XCTAssertNil(item.error)
    }

    func testSetOffFailureKeepsTheErrorAndIsNotAccepted() {
        let service = FakeLoginItemService(status: .enabled)
        service.unregisterError = "busy"
        let item = LoginItem(service: service)

        XCTAssertFalse(item.set(false))

        XCTAssertEqual(item.error, "busy")
        XCTAssertTrue(item.isEnabled, "macOS still has it")
    }

    /// Settings re-reads the status on appear: an approval given in System
    /// Settings since the launch check is picked up without a relaunch.
    func testRefreshPicksUpAnApprovalGivenElsewhere() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = LoginItem(service: service)
        XCTAssertTrue(item.needsApproval)

        service.status = .enabled
        item.refresh()

        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(item.needsApproval)
    }

    func testOpenLoginItemsForwardsToTheService() {
        let service = FakeLoginItemService(status: .requiresApproval)
        let item = LoginItem(service: service)

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
}
