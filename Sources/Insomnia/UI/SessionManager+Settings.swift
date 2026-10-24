import SwiftUI

/// The two ways Settings changes `config`: a binding for one control, and
/// `updateConfig` for an edit that touches more than one field. Both save
/// config.json, and only when something changed.
extension SessionManager {
    func binding<Value: Equatable>(_ keyPath: WritableKeyPath<Config, Value>) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in self.updateConfig { $0[keyPath: keyPath] = value } }
        )
    }

    func updateConfig(_ change: (inout Config) -> Void) {
        var edited = config
        change(&edited)
        guard edited != config else { return }
        config = edited
        do {
            try store.saveConfig(config)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
    }
}
