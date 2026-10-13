import SwiftUI

struct SettingsSessionControls: View {
    let presets: [TimeInterval]
    @Binding var defaultPreset: TimeInterval
    let maximum: TimeInterval
    let add: (TimeInterval) -> Void
    let remove: (TimeInterval) -> Void
    @State private var expanded = true
    @State private var newPreset = ""
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            Picker("Default duration", selection: $defaultPreset) {
                ForEach(presets, id: \.self) { preset in
                    Text(chipLabel(for: preset)).tag(preset)
                }
                if !presets.contains(defaultPreset) {
                    Text(chipLabel(for: defaultPreset)).tag(defaultPreset)
                }
            }
            .handCursor()
            SettingsDisclosureGroup("Manage durations", systemImage: "clock", isExpanded: $expanded) {
                if expanded {
                    SettingsListField(items: presets, emptyLabel: "No saved durations") { preset in
                        HStack {
                            Text(chipLabel(for: preset)).monospacedDigit()
                            Spacer()
                            if preset == defaultPreset {
                                Text("Default").font(.caption).foregroundStyle(.secondary)
                            }
                            SettingsRemoveButton(label: "Remove \(chipLabel(for: preset)) preset") { remove(preset) }
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("New duration")
                        TextField("", text: $newPreset, prompt: Text("1h 30m"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addPreset)
                            .accessibilityLabel("New duration")
                        Button("Add", action: addPreset)
                            .handCursor()
                            .disabled(DurationParser.seconds(from: newPreset) == nil)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("Use h for hours and m for minutes. Maximum: \(chipLabel(for: maximum)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .animation(Motion.interface(reduceMotion: reduceMotion), value: expanded)
        } header: {
            SettingsSectionHeader(title: "Session", symbol: "timer")
        } footer: {
            Text("Click the menu bar eye to open quick actions and choose a timer or Auto.")
        }
    }

    private func addPreset() {
        guard let seconds = DurationParser.seconds(from: newPreset) else { return }
        guard seconds <= maximum else {
            error = "Durations cannot exceed \(chipLabel(for: maximum))."
            return
        }
        error = nil
        add(seconds)
        newPreset = ""
    }
}
