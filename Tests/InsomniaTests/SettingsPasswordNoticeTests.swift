import Security
import XCTest
@testable import Insomnia

/// The notice under the Settings password field, as pure functions: no
/// window, no status item, no keychain.
@MainActor
final class SettingsPasswordNoticeTests: XCTestCase {
    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    /// Stopping the session clears the failover's report. The password is
    /// still unreadable, so the notice must stay.
    func testAReportClearedBySessionEndKeepsTheNoticeWhileThePasswordIsUnreadable() {
        let notice = SettingsView.hotspotNotice(reported: nil) { throw KeychainError(status: errSecAuthFailed) }

        XCTAssertEqual(notice, HotspotPasswordProblem.unreadable.settingsNotice)
        XCTAssertNotNil(notice)
    }

    func testAReportClearedAfterTheFixClearsTheNotice() {
        XCTAssertNil(SettingsView.hotspotNotice(reported: nil) { "pw" })
        XCTAssertNil(SettingsView.hotspotNotice(reported: nil) { nil }, "no saved password is not a problem here")
    }

    /// A report is shown as it is, without reading the keychain again.
    func testAReportedProblemIsShownWithoutAReread() {
        var reread = false

        let notice = SettingsView.hotspotNotice(reported: .unreadable) { reread = true; return "pw" }

        XCTAssertEqual(notice, HotspotPasswordProblem.unreadable.settingsNotice)
        XCTAssertFalse(reread)
    }

    func testLoadingFillsTheFieldOrSaysWhyItCannot() {
        XCTAssertEqual(SettingsView.loadedPassword { "pw" }.password, "pw")
        XCTAssertNil(SettingsView.loadedPassword { "pw" }.notice)

        let unreadable = SettingsView.loadedPassword { throw KeychainError(status: errSecInteractionNotAllowed) }
        XCTAssertEqual(unreadable.password, "")
        XCTAssertEqual(unreadable.notice, HotspotPasswordProblem.unreadable.settingsNotice)

        let other = SettingsView.loadedPassword { throw Boom() }
        XCTAssertEqual(other.password, "")
        XCTAssertEqual(other.notice, HotspotPasswordProblem.error("boom").settingsNotice)
    }
}
