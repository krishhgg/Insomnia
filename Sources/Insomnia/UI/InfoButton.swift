import SwiftUI

/// The longer explanation behind a setting: a short help tag for the ⓘ
/// button and the text its popover shows. Each lives on a `SettingsEntry`,
/// so the sidebar search finds words that are only in the popover.
struct SettingHelp: Equatable {
    /// The help tag on hover. HIG: one line, at most 60 to 75 characters.
    let summary: String
    /// The popover. Paragraphs are separated by a blank line.
    let text: String
}

/// An ⓘ button beside a setting's name or its section's title, as System
/// Settings has. Hovering shows the help tag; clicking opens the full
/// explanation in a popover that closes on the next click outside it.
/// Warnings and live status stay on the pane, never in here (HIG,
/// Popovers: "Avoid using a popover to show a warning").
struct InfoButton: View {
    let help: SettingHelp
    @State private var shown = false

    /// The button for the setting `id` names in `SettingsSearch.entries`.
    init(for id: String) {
        help = SettingsSearch.entry(id)?.help ?? SettingHelp(summary: "", text: "")
    }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help.summary)
        .accessibilityLabel("More information")
        .accessibilityHint(help.summary)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(help.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(DesignTokens.Space.l)
        }
    }
}

/// A setting's name with its ⓘ button right after it, for a row label or
/// a section header.
struct TitleWithInfo: View {
    let title: String
    let id: String

    init(_ title: String, info id: String) {
        self.title = title
        self.id = id
    }

    var body: some View {
        HStack(spacing: DesignTokens.Space.xs) {
            Text(title)
            InfoButton(for: id)
        }
    }
}
