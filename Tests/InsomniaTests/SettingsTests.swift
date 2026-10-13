import AppKit
@testable import Insomnia
import XCTest

/// What the Settings window shows: hotspot name suggestions, app names and
/// icons, and session lengths.
@MainActor
final class SettingsTests: XCTestCase {
    /// An iPhone names its hotspot with a curly apostrophe and a keyboard
    /// types a straight one; the suggestion fills in the exact name.
    func testHotspotSuggestionsMatchEitherApostrophe() {
        let known = ["Home Wi-Fi", "Avery\u{2019}s iPhone", "Avery\u{2019}s iPad"]
        XCTAssertEqual(
            HotspotSSID.suggestions(for: "avery's iph", among: known),
            ["Avery\u{2019}s iPhone"])
        XCTAssertEqual(
            HotspotSSID.suggestions(for: "Avery\u{2019}s", among: known),
            ["Avery\u{2019}s iPhone", "Avery\u{2019}s iPad"])
    }

    /// An empty field offers every joined network once, in auto-join
    /// order, without blank names; case and accents don't hide a match.
    func testHotspotSuggestionsListEachNetworkOnce() {
        let known = ["Office", "", "Café", "Office", "  "]
        XCTAssertEqual(HotspotSSID.suggestions(for: "", among: known), ["Office", "Café"])
        XCTAssertEqual(HotspotSSID.suggestions(for: " CAFE ", among: known), ["Café"])
        XCTAssertEqual(HotspotSSID.suggestions(for: "Lab", among: known), [])
    }

    /// The summary names up to three installed apps and counts the rest;
    /// a listed app this Mac doesn't have is left out.
    func testAppSummaryNamesUpToThreeInstalledApps() {
        XCTAssertEqual(RunningApps.summary(of: []), "None on this Mac")
        XCTAssertEqual(RunningApps.summary(of: ["test.insomnia.missing"]), "None on this Mac")
        XCTAssertEqual(
            RunningApps.summary(of: ["test.insomnia.missing", "com.apple.finder"]), "Finder")
        let four = [
            "com.apple.finder", "com.apple.calculator", "com.apple.TextEdit",
            "com.apple.Preview", "test.insomnia.missing",
        ]
        XCTAssertTrue(RunningApps.summary(of: four).hasSuffix(" and 1 more"))
        XCTAssertFalse(RunningApps.isInstalled("test.insomnia.missing"))
        XCTAssertTrue(RunningApps.isInstalled("com.apple.finder"))
    }

    /// Choose… reads the picked app's bundle ID; an app that isn't
    /// installed still gets an icon.
    func testChosenAppsGiveTheirBundleIDAndEveryRowHasAnIcon() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        XCTAssertEqual(RunningApps.bundleID(ofAppAt: calculator), "com.apple.calculator")
        XCTAssertNil(RunningApps.bundleID(ofAppAt: URL(fileURLWithPath: "/nonexistent.app")))
        XCTAssertNotEqual(RunningApps.icon(for: "test.insomnia.missing").size, .zero)
        XCTAssertNotEqual(RunningApps.icon(for: "com.apple.finder").size, .zero)
    }

    /// An app Launch Services hasn't seen, such as one just unzipped, has
    /// no URL for its bundle ID until Choose… registers it, so its row
    /// would be left out. Launch Services ignores apps in temporary
    /// folders, so the stand-in sits next to the test bundle, and the test
    /// unregisters it afterwards.
    func testChoosingAnAppLaunchServicesHasNotSeenListsIt() throws {
        let id = "test.insomnia.chosen.\(UUID().uuidString)"
        let app = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("\(id).app")
        defer {
            let lsregister = Process()
            lsregister.executableURL = URL(
                fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                    + "LaunchServices.framework/Support/lsregister")
            lsregister.arguments = ["-u", app.path]
            let exit = ProcessExit(lsregister)
            if (try? lsregister.run()) != nil { exit.wait() }
            try? FileManager.default.removeItem(at: app)
        }
        // Launch Services lists a bundle as an app only with an executable,
        // here named after the bundle.
        let executable = app.appendingPathComponent("Contents/MacOS/\(id)")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        try PropertyListEncoder().encode(["CFBundleIdentifier": id])
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        XCTAssertFalse(RunningApps.isInstalled(id))
        XCTAssertEqual(RunningApps.bundleID(ofAppAt: app), id)
        XCTAssertTrue(RunningApps.isInstalled(id))
    }

    /// On a screen shorter than the form, AppKit fits the window to the
    /// screen, which it does only for a resizable window, and the form can
    /// be shorter than its rows, so it scrolls. The window keeps one width,
    /// so the longest notice wraps instead of widening it, and minimize and
    /// zoom stay dimmed.
    func testTheWindowFitsAScreenShorterThanTheForm() throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.lidCloseDefaultsNotice = LidCloseDefaultsChange(
            turnedOffFreezeAll: true, turnedOnMute: true)
        let loginItem = LoginItem(
            service: FakeLoginItemService(status: .notRegistered), install: "test",
            activity: NotificationCenter())
        let window = SettingsWindow {
            SettingsView(
                manager: manager, secrets: InMemoryHotspotSecretStore(),
                locationPermission: LocationPermission(authorizationStatus: .notDetermined),
                loginItem: loginItem)
        }.make()
        // What showing it does first: the hosting controller sets the
        // window's content size limits from the form.
        window.updateConstraintsIfNeeded()
        let screen = try XCTUnwrap(NSScreen.main)
        let tall = NSRect(x: 0, y: 0, width: window.frame.width, height: screen.frame.height * 2)

        XCTAssertLessThanOrEqual(
            window.constrainFrameRect(tall, to: screen).height, screen.visibleFrame.height)
        XCTAssertLessThan(window.contentMinSize.height, screen.visibleFrame.height)
        XCTAssertEqual(window.contentMinSize.width, 490)
        XCTAssertEqual(window.contentMaxSize.width, 490)
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, false)
    }

    func testSessionLengthsReadAsWords() {
        XCTAssertEqual(SettingsView.lengthLabel(30 * 60), "30 minutes")
        XCTAssertEqual(SettingsView.lengthLabel(3600), "1 hour")
        XCTAssertEqual(SettingsView.lengthLabel(4 * 3600), "4 hours")
        XCTAssertEqual(SettingsView.lengthLabel(3 * 86_400), "3 days")
    }
}
