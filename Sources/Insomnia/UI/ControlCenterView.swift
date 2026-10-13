import AppKit
import Network
import Observation
import SwiftUI

enum ControlPage: String, CaseIterable, Identifiable {
    case overview, lid, apps, battery, network, general
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .lid: "Lid & audio"
        case .apps: "Protected apps"
        case .battery: "Battery & power"
        case .network: "Network"
        case .general: "General"
        }
    }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .lid: "laptopcomputer"
        case .apps: "square.stack.3d.up"
        case .battery: "battery.75percent"
        case .network: "wifi"
        case .general: "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: "Give your work time to finish."
        case .lid: "Choose what happens when you close your Mac."
        case .apps: "Keep your agents and their tools running."
        case .battery: "Balance long sessions with battery and temperature."
        case .network: "Set up an optional hotspot fallback."
        case .general: "Make Insomnia fit your day."
        }
    }
}

/// Network availability is a route observation, not an internet reachability test.
@MainActor @Observable
final class DesktopNetworkState {
    var available: Bool?
    @ObservationIgnored private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in self?.available = available }
        }
        monitor.start(queue: DispatchQueue(label: "insomnia.desktop.network"))
    }
    deinit { monitor.cancel() }
}

private enum DesktopStyle {
    static let accent = Color(red: 0.43, green: 0.34, blue: 0.83)
    static let green = Color(red: 0.17, green: 0.62, blue: 0.45)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
}

struct ControlCenterView: View {
    let manager: SessionManager
    let status: any StatusSource
    let secrets: any HotspotSecretStore
    let locationPermission: LocationPermission
    let loginItem: LoginItem

    @State private var page: ControlPage = .overview
    @State private var duration = "4h"
    @State private var didLoad = false
    @State private var busy = false
    @State private var confirmEnd = false
    @State private var network = DesktopNetworkState()
    @State private var notice: String?

    private var seconds: TimeInterval? {
        guard let value = DurationParser.seconds(from: duration), value > 0,
              value <= manager.config.maxDuration else { return nil }
        return value
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.6)
                if page == .overview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            sessionCard
                            metrics
                            notices
                            lidSummary
                            footer
                        }.padding(28)
                    }
                } else {
                    SettingsView(manager: manager, secrets: secrets,
                                 locationPermission: locationPermission,
                                 loginItem: loginItem, page: page)
                        .id(page)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesktopStyle.background)
        .tint(DesktopStyle.accent)
        .onAppear {
            if !didLoad {
                duration = chipLabel(for: manager.config.defaultPreset)
                didLoad = true
            }
            status.refreshOnDemand()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status.refreshOnDemand()
        }
        .alert("End this session?", isPresented: $confirmEnd) {
            Button("Keep running", role: .cancel) {}
            Button("End session", role: .destructive) { endSession() }
        } message: {
            Text("Insomnia will restore the settings it changed and allow your Mac to sleep. Your AI apps will stay open.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesktopStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(DesktopStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insomnia").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("YOUR MAC, AWAKE").font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 38)

            Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).tracking(1.5)
                .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
            ForEach(ControlPage.allCases) { item in
                Button {
                    page = item
                    status.refreshOnDemand()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon).font(.system(size: 15)).frame(width: 19)
                        Text(item.title).font(.system(size: 13, weight: page == item ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                        if page == item { Circle().fill(DesktopStyle.accent).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(page == item ? DesktopStyle.accent : Color.primary.opacity(0.7))
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .background(page == item ? DesktopStyle.accent.opacity(0.09) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 4)
            }
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(manager.isActive ? DesktopStyle.green : Color.secondary).frame(width: 6, height: 6)
                    Text(manager.isActive ? "Session active" : "Ready when you are").font(.system(size: 12, weight: .medium))
                }
                Text("Closing this window keeps Insomnia in the menu bar.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(DesktopStyle.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("DESKTOP EDITION").font(.system(size: 9, weight: .medium)).tracking(1)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1").font(.system(size: 10, design: .monospaced))
            }.foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 18)
        }
        .padding(.horizontal, 18).padding(.top, 55).padding(.bottom, 22)
        .frame(width: 220)
        .background(DesktopStyle.accent.opacity(0.025))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.title).font(.system(size: 25, weight: .semibold, design: .rounded))
                Text(page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if page != .overview {
                Label("Changes save automatically", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Button { status.refreshOnDemand() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                }.buttonStyle(.bordered).help("Refresh machine status")
            }
        }.padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 23)
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Circle().fill(manager.isActive ? Color.mint : Color.white.opacity(0.5)).frame(width: 6, height: 6)
                        Text(manager.isActive ? "SESSION IN PROGRESS" : "TIMED AWAKE SESSION")
                            .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                    }.foregroundStyle(.white.opacity(0.7))
                    Text(manager.isActive ? manager.countdownText : "Let your work\nkeep going.")
                        .font(.system(size: manager.isActive ? 46 : 36, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.white)
                        .accessibilityLabel(manager.isActive ? "Time remaining: \(manager.countdownText)" : "Let your work keep going")
                    if let session = manager.session {
                        Text("Ends \(session.endsAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                    } else {
                        Text("Keep your Mac awake for the time you choose.")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.72))
                    }
                }
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.07), lineWidth: 1).frame(width: 128, height: 128)
                    Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: 98, height: 98)
                    Circle().fill(.white.opacity(0.07)).frame(width: 70, height: 70)
                    Image(systemName: manager.isActive ? "eye.fill" : "moon.stars.fill")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.9))
                }.accessibilityHidden(true)
            }
            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach([1800.0, 3600, 7200, 14400, 28800], id: \.self) { preset in
                        Button { duration = chipLabel(for: preset) } label: {
                            Text(chipLabel(for: preset)).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .foregroundStyle(.white.opacity(seconds == preset ? 1 : 0.65))
                                .background(.white.opacity(seconds == preset ? 0.22 : 0.07), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    TextField("Duration, e.g. 2h 30m", text: $duration)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .textFieldStyle(.plain).foregroundStyle(.white)
                        .padding(12).frame(width: 135)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(manager.isActive ? "Time to add" : "Session duration")
                        .onSubmit { beginOrExtend() }
                    Button { beginOrExtend() } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: manager.isActive ? "plus" : "play.fill") }
                            Text(manager.isActive ? "Add time" : "Start session")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.19, green: 0.16, blue: 0.34))
                        .padding(.horizontal, 19).padding(.vertical, 12)
                        .background(Color.white.opacity(seconds == nil || busy ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).disabled(seconds == nil || busy)
                    if manager.isActive {
                        Button("End session") { confirmEnd = true }
                            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8)).padding(.leading, 4).disabled(busy)
                    }
                    Spacer(minLength: 0)
                }
                Text(seconds == nil ? "Enter a duration between 1 second and \(chipLabel(for: manager.config.maxDuration))." :
                        (manager.isActive ? "Added time extends the current session." : "Choose a preset or enter your own duration, like 1h30m."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.60))
            }
        }
        .padding(26)
        .background(LinearGradient(colors: [Color(red: 0.19, green: 0.15, blue: 0.32),
                                            Color(red: 0.34, green: 0.27, blue: 0.53)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metric("Battery", value: status.batteryPercent.map { "\($0)%" } ?? "Unavailable",
                   detail: status.isCharging ? "Charging" : "Battery level", icon: "battery.75percent")
            metric("Network", value: network.available.map { $0 ? "Available" : "No connection" } ?? "Checking",
                   detail: "Local network route", icon: "wifi")
            metric("Lid", value: status.lidClosed ? "Closed" : "Open",
                   detail: manager.isActive ? "Session continues" : "No awake session", icon: "laptopcomputer")
        }
    }

    private func metric(_ title: String, value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).foregroundStyle(DesktopStyle.accent.opacity(0.7))
            }
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(DesktopStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.04), lineWidth: 1))
    }

    private var lidSummary: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("When you close the lid").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Customize", systemImage: "arrow.up.right") { page = .lid }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(DesktopStyle.accent)
            }
            HStack(spacing: 20) {
                summary("speaker.slash", title: "Audio", value: manager.config.muteOnLidClose ? "Mute" : "Keep playing")
                summary("leaf", title: "Low Power Mode", value: manager.config.lowPowerOnLidClose ? "Requested" : "Unchanged")
                summary("app.badge", title: "App freezing", value: manager.config.freezeAllApps ? "Automatic + list" :
                            manager.config.freezeList.isEmpty ? "Off" : "\(manager.config.freezeList.count) selected")
            }
        }.padding(20).background(DesktopStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func summary(_ icon: String, title: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(DesktopStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .medium))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var notices: some View {
        if let notice { message(notice, icon: "info.circle", color: DesktopStyle.accent) }
        if let error = manager.lastError { message(error, icon: "exclamationmark.triangle", color: .orange) }
        if let warning = manager.commandWarning { message(warning, icon: "exclamationmark.triangle", color: .orange) }
        if let warning = manager.foreignSleepWarning { message(warning, icon: "exclamationmark.triangle", color: .orange) }
        if manager.isActive && !manager.state.sleepDisabledByUs {
            message("This session is not holding sleep prevention. Check the status menu before closing the lid.", icon: "exclamationmark.triangle", color: .orange)
        }
        if !manager.darkenRefusals.isEmpty && manager.config.darkenDisplayOnLidClose {
            message("Automatic display or keyboard darkening is unavailable on this Mac. Review Lid & audio for details; use brightness controls manually.", icon: "display.trianglebadge.exclamationmark", color: .orange)
        }
        ForEach(manager.outputsWaitingForRestore, id: \.deviceUID) { output in
            message("Audio restore is waiting for \(output.label) to reconnect.", icon: "speaker.wave.2", color: .orange)
        }
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).padding(.top, 1)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("Use a ventilated desk. Insomnia keeps your Mac awake; AI completion and internet access still depend on your apps and network. Experimental software.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            Spacer(minLength: 0)
            Button("View logs") { NSWorkspace.shared.open(manager.paths.logs) }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(DesktopStyle.accent)
        }.padding(.horizontal, 3)
    }

    private func beginOrExtend() {
        guard !busy, let seconds else { return }
        busy = true
        notice = nil
        Task {
            if manager.isActive { await manager.extend(by: seconds) }
            else { await manager.start(duration: seconds) }
            busy = false
            status.refreshOnDemand()
        }
    }

    private func endSession() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await manager.end(reason: .user)
            if outcome != .restored { notice = "Session cleanup needs attention. Check the status menu and any warnings below." }
            else { notice = "Session ended. Insomnia restored the settings it changed." }
            busy = false
            status.refreshOnDemand()
        }
    }
}
