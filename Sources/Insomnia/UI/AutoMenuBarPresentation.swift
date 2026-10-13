import Foundation

/// Pure UI copy/state. Arming Auto is not the same as holding sleep, and
/// restoring a hold is not the same as being safely idle.
enum AutoMenuBarPresentation: Equatable {
    case off
    case idle
    case checking
    case working
    case paused
    case restoring

    static func resolve(enabled: Bool, autoSessionActive: Bool, paused: Bool, restoring: Bool, pending: Bool = false) -> Self {
        if restoring || (autoSessionActive && !enabled) { return .restoring }
        if autoSessionActive { return .working }
        if pending { return .checking }
        if enabled { return .idle }
        return paused ? .paused : .off
    }

    @MainActor
    static func current(manager: SessionManager, model: MenuBarModel) -> Self {
        let auto = manager.agentAuto
        return resolve(enabled: auto?.enabled == true,
                       autoSessionActive: manager.session?.agentAuto == true,
                       paused: auto?.pauseReason != nil,
                       restoring: isRestoring(manager: manager),
                       pending: model.autoActionPending || (auto?.enabled == true && auto?.jobs.isEmpty == false))
    }

    @MainActor
    static func isRestoring(manager: SessionManager) -> Bool {
        // A failed undo can be delegated to the armed backstop: the end
        // request clears, but the journal still owns a live sleep guard.
        manager.pendingEnd != nil || (!manager.isActive && manager.startingSessionIsAuto == nil && manager.state.sleepDisabledByUs)
    }

    @MainActor
    static func autoControlEnabled(manager: SessionManager, model: MenuBarModel) -> Bool {
        manager.agentAuto != nil && !model.autoActionPending && model.phase != .starting
            && manager.startingSessionIsAuto != false
            && !isRestoring(manager: manager) && (!manager.isActive || manager.session?.agentAuto == true)
            && current(manager: manager, model: model) != .restoring
    }

    @MainActor
    static func timerControlsEnabled(manager: SessionManager, model: MenuBarModel) -> Bool {
        !model.autoActionPending && model.phase != .starting && manager.startingSessionIsAuto == nil && !isRestoring(manager: manager)
            && manager.session?.agentAuto != true
            && !(manager.agentAuto?.enabled == true && manager.agentAuto?.jobs.isEmpty == false)
    }

    var title: String {
        switch self {
        case .off: "Auto: off"
        case .idle: "Auto: idle"
        case .checking: "Auto: checking"
        case .working: "Auto: working"
        case .paused: "Auto: paused"
        case .restoring: "Restoring sleep"
        }
    }

    var detail: String {
        switch self {
        case .off: "Until agents finish"
        case .idle: "Normal sleep allowed"
        case .checking: "Checking agent work"
        case .working: "Registered agent work"
        case .paused: "Enable to resume"
        case .restoring: "Waiting for sleep restoration"
        }
    }

    var actionTitle: String {
        switch self {
        case .off, .paused: "Enable Auto"
        case .idle, .working: "Disable Auto"
        case .checking: "Disable Auto"
        case .restoring: "Restoring…"
        }
    }
}
