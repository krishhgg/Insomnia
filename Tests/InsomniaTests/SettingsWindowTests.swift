import AppKit
import SwiftUI
import XCTest
@testable import Insomnia

final class SettingsWindowTests: XCTestCase {
    @MainActor
    func testWindowUsesNativePreferencesToolbarAndRetainsTheSamePaneWhenReopened() throws {
        _ = NSApplication.shared
        let settings = SettingsWindow { _ in AnyView(Text("Fixture settings")) }
        let window = settings.makeWindow()
        defer { window.close() }
        let toolbar = try XCTUnwrap(window.toolbar)
        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<AnyView>)
        XCTAssertTrue(host.sizingOptions.isEmpty)
        XCTAssertEqual(window.toolbarStyle, .preference)
        XCTAssertEqual(toolbar.displayMode, .iconAndLabel)
        XCTAssertFalse(toolbar.allowsUserCustomization)
        XCTAssertEqual(settings.toolbarSelectableItemIdentifiers(toolbar).count, 3)
        XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(.zoomButton)).isEnabled)
        XCTAssertFalse(try XCTUnwrap(window.standardWindowButton(.miniaturizeButton)).isEnabled)
        settings.select(.lid)
        XCTAssertEqual(window.title, "Lid actions")
        XCTAssertEqual(settings.navigation.selection, .lid)
        XCTAssertEqual(toolbar.selectedItemIdentifier?.rawValue, "insomnia.settings.lid")
        XCTAssertEqual(window.contentView?.bounds.size.height ?? 0, SettingsPage.lid.contentSize.height, accuracy: 1)
        XCTAssertTrue(settings.makeWindow() === window)
        XCTAssertEqual(settings.navigation.selection, .lid)
    }

    @MainActor
    func testCommandNumberShortcutsApplyOnlyInsideTheSettingsWindow() throws {
        _ = NSApplication.shared
        let settings = SettingsWindow { _ in AnyView(Text("Fixture settings")) }
        let window = settings.makeWindow()
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: .titled, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        func key(_ text: String, flags: NSEvent.ModifierFlags, in target: NSWindow) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: target.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0))
        }
        XCTAssertFalse(settings.handleShortcut(try key("3", flags: .command, in: other)))
        XCTAssertFalse(settings.handleShortcut(try key("3", flags: [], in: window)))
        XCTAssertFalse(settings.handleShortcut(try key("3", flags: [.command, .shift], in: window)))
        XCTAssertFalse(settings.handleShortcut(try key("4", flags: .command, in: window)))
        XCTAssertEqual(settings.navigation.selection, .general)
        XCTAssertTrue(settings.handleShortcut(try key("3", flags: .command, in: window)))
        XCTAssertEqual(settings.navigation.selection, .advanced)
        XCTAssertEqual(window.title, "Advanced")
        XCTAssertTrue(settings.handleShortcut(try key("1", flags: .command, in: window)))
        XCTAssertEqual(settings.navigation.selection, .general)
    }
}
