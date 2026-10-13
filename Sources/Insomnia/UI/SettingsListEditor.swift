import SwiftUI

/// A bounded list field keeps every item reachable without growing the pane.
struct SettingsListField<Item: Hashable, Row: View>: View {
    let items: [Item]
    let emptyLabel: String
    var rowHeight: CGFloat = 36
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        GroupBox {
            if items.isEmpty {
                Text(emptyLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            row(item)
                                .frame(minHeight: rowHeight)
                                .padding(.horizontal, 8)
                            if item != items.last { Divider() }
                        }
                    }
                }
                .frame(height: min(CGFloat(items.count) * (rowHeight + 1) - 1, 180))
            }
        }
    }
}

struct SettingsRemoveButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .handCursor()
        .help(label)
        .accessibilityLabel(label)
    }
}
