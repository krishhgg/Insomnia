import SwiftUI

/// Secondary actions within the compact panel use the same menu model and
/// command handlers as secondary clicks on the persistent status item.
struct CompactStatusMenu: View {
    let manager: SessionManager
    let status: any StatusSource
    let performAction: (StatusMenu.Item.Kind) -> Void
    let refresh: () -> Void

    var body: some View {
        Group {
            ForEach(Array(StatusItemController.menuItems(manager: manager, status: status).enumerated()), id: \.offset) { _, item in
                switch item.kind {
                case .separator:
                    Divider()
                case .info:
                    Text(item.title).font(.caption)
                case .warning:
                    Text(item.title).font(.caption).foregroundStyle(.orange)
                case .settings:
                    Button(item.title) { performAction(item.kind) }
                        .keyboardShortcut(",", modifiers: .command)
                case .quit:
                    Button(item.title) { performAction(item.kind) }
                        .keyboardShortcut("q", modifiers: .command)
                case .relaunchBrowser, .stopWaitingForOutput:
                    Button(item.title) { performAction(item.kind) }
                }
            }
        }
        .onAppear(perform: refresh)
    }
}
