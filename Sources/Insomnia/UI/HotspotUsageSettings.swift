import SwiftUI

/// Shared by Settings and the safe preview. The driver observes Wi-Fi only;
/// editing or resetting usage never ends a session or changes a connection.
struct HotspotUsageSettings: View {
    @Binding var config: Config
    let driver: HotspotUsageDriver?
    @State private var confirmingReset = false

    private var status: HotspotUsageStatus { driver?.status ?? HotspotUsageStatus() }
    private var budgetGB: Binding<Double> {
        Binding(get: { Double(config.hotspotBudgetBytes) / 1_000_000_000 }, set: {
            if let bytes = Self.budgetBytes(gigabytes: $0) { config.hotspotBudgetBytes = bytes }
        })
    }

    static func budgetBytes(gigabytes: Double) -> UInt64? {
        guard gigabytes.isFinite, gigabytes >= 0, gigabytes <= 1_000 else { return nil }
        return UInt64((gigabytes * 1_000_000_000).rounded())
    }

    var body: some View {
        Toggle("Track hotspot usage during sessions", isOn: $config.trackHotspotUsage)
        LabeledContent("Budget (GB)") {
            TextField("GB", value: budgetGB, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden()
                .accessibilityLabel("Budget in GB")
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
        }
        Text("Warn at 80% and 100%. Set 0 to turn budget warnings off.")
            .font(.caption).foregroundStyle(.secondary)
        if let ledger = status.ledger {
            LabeledContent("Tracked", value: HotspotUsageText.amount(ledger.total))
            Text("Download \(HotspotUsageText.amount(ledger.received)) · Upload \(HotspotUsageText.amount(ledger.sent))")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            LabeledContent("Tracked", value: "Unavailable")
        }
        if let start = status.periodStarted {
            LabeledContent("Since", value: start.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
        }
        Text(status.phase.text).font(.caption).foregroundStyle(.secondary)
        if let warning = status.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
        if let problem = status.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
        if status.ledger?.hasUnmeasuredIntervals == true {
            Text("Some intervals unmeasured; total may be incomplete.")
                .font(.caption).foregroundStyle(.orange)
        }
        Button("Reset tracked usage…") { confirmingReset = true }
            .disabled(driver == nil || config.hotspotSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .confirmationDialog("Reset hotspot usage?", isPresented: $confirmingReset) {
                Button("Reset usage", role: .destructive) { driver?.reset() }
                Button("Cancel", role: .cancel) {}
            } message: { Text(driver?.resetMessage ?? "") }
        Text("Estimate of this Mac's upload and download on the configured hotspot during Insomnia sessions, including local traffic. Excludes the phone and other devices. Missing readings are skipped. Warnings leave the connection running; this is not a carrier meter or a data cap.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
