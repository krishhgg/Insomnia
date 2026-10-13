import SwiftUI

/// Compact editor over the existing configuration bindings. App identifiers
/// appear beneath resolved names and remain available as tooltips.
struct SettingsAppList: View {
    let title: String
    let items: [String]
    @Binding var newValue: String
    let add: (String) -> Void
    let remove: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(items.count) \(items.count == 1 ? "app" : "apps")").monospacedDigit()
            }
            .font(.callout).foregroundStyle(.secondary)
            SettingsListField(items: items, emptyLabel: "No apps added", rowHeight: 44) { id in
                let name = RunningApps.displayName(for: id)
                HStack(spacing: 10) {
                    Group {
                        if let icon = RunningApps.icon(for: id) {
                            Image(nsImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "app.fill").foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).lineLimit(1)
                        if name != id {
                            Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help(id)
                    Spacer()
                    SettingsRemoveButton(label: "Remove \(name)") { remove(id) }
                }
            }
            Menu {
                let apps = RunningApps.candidates(excluding: items)
                if apps.isEmpty { Text("No other apps running") }
                ForEach(apps.filter { !$0.isBackground }, id: \.bundleID) { app in
                    Button(app.name) { add(app.bundleID) }
                }
                let background = apps.filter(\.isBackground)
                if !background.isEmpty {
                    Menu("Background apps") {
                        ForEach(background, id: \.bundleID) { app in
                            Button(app.name) { add(app.bundleID) }
                        }
                    }
                }
            } label: { Label("Add app", systemImage: "plus") }
            .fixedSize()
            .handCursor()
            SettingsDisclosureGroup("Add by bundle identifier") {
                HStack {
                    TextField("", text: $newValue, prompt: Text("com.example.app"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addIdentifier)
                        .accessibilityLabel("App bundle identifier")
                    Button("Add", action: addIdentifier)
                        .handCursor()
                        .disabled(newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func addIdentifier() {
        let id = newValue.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        add(id)
        newValue = ""
    }
}
