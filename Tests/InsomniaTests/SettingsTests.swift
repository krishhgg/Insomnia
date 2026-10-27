import AppKit
@testable import Insomnia
import SwiftUI
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
        // The name the system gives Finder, which is localized.
        XCTAssertEqual(
            RunningApps.summary(of: ["test.insomnia.missing", "com.apple.finder"]),
            RunningApps.displayName(for: "com.apple.finder"))
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
                loginItem: loginItem, releases: ReleaseChecker())
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

    /// The hotspot sheet has no fixed height, so macOS can make it shorter
    /// than its rows when they would pass the bottom of the Settings window,
    /// such as a long tmux list, and the form scrolls.
    func testTheHotspotSheetCanBeShorterThanItsRows() {
        let h = Harness()
        defer { h.home.destroy() }
        let sheet = NSHostingController(
            rootView: HotspotSheet(
                manager: h.makeManager(), secrets: InMemoryHotspotSecretStore(),
                locationPermission: LocationPermission(authorizationStatus: .notDetermined)))
        let short = sheet.sizeThatFits(in: NSSize(width: 470, height: 120))
        XCTAssertLessThanOrEqual(short.height, 120)
    }

    /// The menu bar style is a General setting, on #147's one page, not a
    /// section of its own above the lid: its picker is the first menu in
    /// General, after the battery floors and before the default length.
    func testTheMenuBarStylePickerOpensTheGeneralGroup() throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        let titles = try popUpTitles(manager)
        let style = try XCTUnwrap(titles.firstIndex(of: "Pills"), "\(titles)")
        let endFloor = try XCTUnwrap(titles.firstIndex(of: "\(manager.config.endFloor)%"), "\(titles)")
        XCTAssertGreaterThan(style, endFloor, "\(titles)")
        XCTAssertEqual(titles[style + 1], SettingsView.lengthLabel(manager.config.defaultPreset), "\(titles)")
    }

    /// Every Minimal click adds the default length, so Minimal types it in
    /// a field in place of the preset menu, under the same name.
    func testMinimalTypesTheDefaultLengthInPlaceOfThePresetMenu() throws {
        let h = Harness()
        defer { h.home.destroy() }
        let manager = h.makeManager()
        manager.config.menuBarMode = .minimal
        let titles = try popUpTitles(manager)
        let style = try XCTUnwrap(titles.firstIndex(of: "Minimal"), "\(titles)")
        XCTAssertFalse(titles.contains(SettingsView.lengthLabel(manager.config.defaultPreset)), "\(titles)")
        XCTAssertEqual(titles[style + 1], manager.config.defaultFocusField.placeholder, "\(titles)")
    }

    /// Each style has a name and one line on what it does, short enough
    /// to sit on one line under the picker's label.
    func testEachMenuBarStyleHasANameAndOneLineOnWhatItDoes() {
        XCTAssertEqual(Config.MenuBarMode.allCases.map(SettingsView.styleName), ["Pills", "Compact", "Minimal"])
        let lines = Config.MenuBarMode.allCases.map(SettingsView.styleDescription)
        XCTAssertEqual(Set(lines).count, lines.count)
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertFalse(line.contains("\n"), line)
            XCTAssertLessThan((line as NSString).size(withAttributes: [.font: font]).width, 300, line)
        }
    }

    /// The titles of the Settings window's menus, top to bottom. On macOS 27
    /// SwiftUI draws a form's pickers itself, with no NSPopUpButton and no
    /// Accessibility element to read in the test process, so the tests that
    /// need the titles skip there. They still run on macOS 26.
    private func popUpTitles(_ manager: SessionManager) throws -> [String] {
        let loginItem = LoginItem(
            service: FakeLoginItemService(status: .notRegistered), install: "test",
            activity: NotificationCenter())
        let window = SettingsWindow {
            SettingsView(
                manager: manager, secrets: InMemoryHotspotSecretStore(),
                locationPermission: LocationPermission(authorizationStatus: .notDetermined),
                loginItem: loginItem, releases: ReleaseChecker())
        }.make()
        // Tall enough for every row, so none is left out of the layout.
        window.setContentSize(NSSize(width: 490, height: 3000))
        window.layoutIfNeeded()
        var popUps: [NSPopUpButton] = []
        func collect(_ view: NSView) {
            if let popUp = view as? NSPopUpButton { popUps.append(popUp) }
            view.subviews.forEach(collect)
        }
        collect(try XCTUnwrap(window.contentView))
        if popUps.isEmpty, ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            throw XCTSkip("SwiftUI on macOS 27 draws the form's pickers without NSPopUpButton")
        }
        return popUps
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            .map(\.title)
    }

    /// Session lengths read as words. The test passes an English locale, so
    /// it also passes on a Mac set to another language.
    func testSessionLengthsReadAsWords() {
        let english = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(SettingsView.lengthLabel(30 * 60, locale: english), "30 minutes")
        XCTAssertEqual(SettingsView.lengthLabel(3600, locale: english), "1 hour")
        XCTAssertEqual(SettingsView.lengthLabel(4 * 3600, locale: english), "4 hours")
        XCTAssertEqual(SettingsView.lengthLabel(3 * 86_400, locale: english), "3 days")
    }
}
