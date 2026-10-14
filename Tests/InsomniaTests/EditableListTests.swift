import XCTest
@testable import Insomnia

/// The search over Settings lists and the + popover's app picker.
final class EditableListTests: XCTestCase {
    private func app(_ name: String, _ id: String) -> InstalledApp {
        InstalledApp(bundleID: id, name: name, url: URL(filePath: "/Applications/\(name).app"))
    }

    func testAnEmptyFilterKeepsEveryRow() {
        XCTAssertTrue(ListFilter.matches("", ["Claude"]))
        XCTAssertTrue(ListFilter.matches("   ", ["Claude"]))
    }

    func testTheFilterMatchesAnywhereInAnyFieldIgnoringCaseAndAccents() {
        XCTAssertTrue(ListFilter.matches("anthropic", ["Claude", "com.anthropic.claudefordesktop"]))
        XCTAssertTrue(ListFilter.matches("CLAUDE", ["Claude", "com.anthropic.claudefordesktop"]))
        XCTAssertTrue(ListFilter.matches("cafe", ["Café"]))
        XCTAssertFalse(ListFilter.matches("zoom", ["Claude", "com.anthropic.claudefordesktop"]))
    }

    func testEveryWordOfTheFilterHasToMatch() {
        XCTAssertTrue(ListFilter.matches("visual code", ["Visual Studio Code", "com.microsoft.VSCode"]))
        XCTAssertFalse(ListFilter.matches("visual zed", ["Visual Studio Code", "com.microsoft.VSCode"]))
    }

    func testAppSearchPutsNamePrefixesFirstThenNamesThenBundleIds() {
        let apps = [
            app("Docker", "com.docker.docker"),
            app("Terminal", "com.apple.Terminal"),
            app("iTerm", "com.googlecode.iterm2"),
            app("Termius", "com.termius-dmg.mac"),
        ]
        XCTAssertEqual(InstalledApps.search(apps, "term").map(\.name), ["Terminal", "Termius", "iTerm"])
        XCTAssertEqual(InstalledApps.search(apps, "docker").map(\.name), ["Docker"])
        XCTAssertEqual(InstalledApps.search(apps, "googlecode").map(\.name), ["iTerm"])
        XCTAssertEqual(InstalledApps.search(apps, "").count, apps.count)
    }

    func testMergingKeepsTheFirstAppPerBundleIdDropsSelfAndSortsByName() {
        let merged = InstalledApps.merged([
            app("Zed", "dev.zed.Zed"),
            app("Claude", "com.anthropic.claudefordesktop"),
            app("Claude Copy", "COM.ANTHROPIC.CLAUDEFORDESKTOP"),
            app("Insomnia", "com.kgarg.insomnia"),
        ], excluding: "com.kgarg.insomnia")
        XCTAssertEqual(merged.map(\.name), ["Claude", "Zed"])
    }

    func testAnInfoPlistWithoutABundleIdIsNotAnApp() {
        let url = URL(filePath: "/Applications/Thing.app")
        XCTAssertNil(InstalledApps.app(info: [:], url: url, name: "Thing"))
        XCTAssertNil(InstalledApps.app(info: ["CFBundleIdentifier": " "], url: url, name: "Thing"))
        XCTAssertEqual(InstalledApps.app(info: ["CFBundleIdentifier": "com.example.thing"], url: url, name: "Thing")?.bundleID, "com.example.thing")
    }

    func testATypedBundleIdCanBeAddedWhenNoKnownAppHasIt() {
        XCTAssertEqual(InstalledApps.manualBundleID(" com.example.app ", known: []), "com.example.app")
        XCTAssertEqual(InstalledApps.manualBundleID("com.termius-dmg.mac", known: []), "com.termius-dmg.mac")
        XCTAssertNil(InstalledApps.manualBundleID("com.example.app", known: ["COM.Example.App"]))
        XCTAssertNil(InstalledApps.manualBundleID("claude", known: []))
        XCTAssertNil(InstalledApps.manualBundleID("com..app", known: []))
        XCTAssertNil(InstalledApps.manualBundleID("com.example.", known: []))
        XCTAssertNil(InstalledApps.manualBundleID("com.my app", known: []))
    }

    /// A scan of this Mac finds at least one app with an id and no
    /// duplicate ids.
    func testScanningTheApplicationFoldersFindsApps() async {
        let apps = await InstalledApps.scan(extra: [], excluding: "com.kgarg.insomnia")
        XCTAssertFalse(apps.isEmpty)
        XCTAssertEqual(Set(apps.map { $0.bundleID.lowercased() }).count, apps.count)
    }
}
