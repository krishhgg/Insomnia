import XCTest
@testable import Insomnia

/// What Settings and the README tell the user about the lid closing: the
/// built-in microphone and the one-time lid-close update.
final class LidCloseCopyTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Words joined by single spaces, so a wrapped paragraph reads as one line.
    private func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The body of `SettingsView.lidSection`.
    private func lidSection() throws -> String {
        let source = try read("Sources/Insomnia/UI/SettingsView.swift")
        let start = try XCTUnwrap(source.range(of: "private var lidSection: some View {")).upperBound
        let end = try XCTUnwrap(source.range(of: "private var agentSection: some View {")).lowerBound
        return String(source[start..<end])
    }

    func testMicrophoneNoteSaysTheMicIsDisconnectedAndWhatToUseInstead() {
        let note = SettingsView.microphoneNote
        XCTAssertTrue(note.contains("closing the lid disconnects the built-in microphone in hardware"), note)
        XCTAssertTrue(note.contains("AirPods or an external mic"), note)
    }

    /// The note sits right under the mute toggle, next to the other
    /// lid-close options.
    func testSettingsShowsTheMicrophoneNoteUnderTheMuteToggle() throws {
        let lid = try lidSection()
        let toggle = try XCTUnwrap(lid.range(of: #"Toggle("Mute audio on lid close", isOn: bind(\.muteOnLidClose))"#))
        let next = lid[toggle.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(next.hasPrefix("Text(Self.microphoneNote)"), String(next.prefix(80)))
    }

    func testReadmeExplainsTheMicrophone() throws {
        let readme = flattened(try read("README.md"))
        XCTAssertTrue(readme.contains("closing the lid disconnects the built-in microphone in hardware. Recording a meeting with the lid closed needs AirPods or an external mic"))
    }

    /// The update's notice also lives in Settings, for a user who has
    /// notifications off, until dismissed.
    func testSettingsShowsTheLidCloseUpdateNoticeUntilDismissed() throws {
        let lid = try lidSection()
        XCTAssertTrue(lid.contains("if let notice = manager.config.lidCloseDefaultsNotice"))
        XCTAssertTrue(lid.contains("Text(notice.settingsLine)"))
        XCTAssertTrue(lid.contains(#"Button("Dismiss") { manager.dismissLidCloseNotice() }"#))
    }
}
