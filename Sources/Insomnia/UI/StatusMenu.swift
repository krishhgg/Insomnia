import AppKit

/// The right-click menu on the status item: a read-only status block, then
/// End session while a session runs, Settings and Quit. With the menu bar
/// countdown turned off, the time left heads the status block.
///
/// The status section of the menu bar popover, as data: one short row per
/// fact, then one row per warning, with the actions that belong to a
/// warning carried as buttons on its row. Settings and Quit are the
/// popover's fixed footer and are not rows.
///
/// The item lists are pure so the ordering and the omission rules can be
/// tested without a menu bar; the menu builder is the only part that
/// touches AppKit, and `StatusPopoverView` only draws the popover's rows.
enum StatusMenu {
    struct Item: Equatable {
        enum Kind: Equatable {
            /// A fact about the machine or the session.
            case info
            /// Something the user should know is wrong. The popover draws
            /// it with an orange triangle, so the text carries no warning
            /// sign; the menu adds one to the line.
            case warning
            case separator
            /// End the running session. Offered whenever a session runs; with
            /// the menu bar countdown off it stands in for the hold-to-end ring.
            case endSession
            case settings
            case quit
            /// Relaunch this browser with the occlusion flags. Carries the
            /// bundle id and name, so the item still names the same browser
            /// after a scan replaces the list.
            case relaunchBrowser(ThrottledBrowser)
            /// Drop the saved volume of this output device: it is not
            /// connected, and Insomnia stops waiting for it. Carries the
            /// save the item was built for, its save ID included, so a
            /// later one is not dropped.
            case stopWaitingForOutput(SavedAudioOutput)

            var isAction: Bool {
                switch self {
                case .info, .warning, .separator: false
                case .endSession, .settings, .quit, .relaunchBrowser, .stopWaitingForOutput: true
                }
            }
        }

        let title: String
        let kind: Kind
        /// SF Symbol drawn beside an info row; warnings always use the triangle.
        var symbol: String?
        /// Tooltip with the longer explanation, when the row has one.
        var help: String?

        init(title: String, kind: Kind, symbol: String? = nil, help: String? = nil) {
            self.title = title
            self.kind = kind
            self.symbol = symbol
            self.help = help
        }
    }

    /// A drawn row: a fact or a warning, and the action buttons that
    /// follow it in the item list.
    struct Row: Equatable {
        let item: Item
        let actions: [Item]
    }

    static let endSessionTitle = "End session"
    static let settingsTitle = "Settings\u{2026}"
    static let quitTitle = "Quit Insomnia"
    static let warningSymbol = "exclamationmark.triangle.fill"

    /// The time-left line, from the session's minute-granularity text
    /// ("2h 14m").
    static func remainingLine(_ remaining: String) -> String {
        "Time left: \(remaining)"
    }

    /// Disabled status lines, a separator, then session and app actions. Empty
    /// lines are dropped, and the separator only appears when something
    /// precedes it, so the menu never opens with a stray rule at the top.
    /// `hotspotWarning` is the line about a hotspot password the failover
    /// could not use (`HotspotPasswordProblem.menuLine`).
    /// `lidSimulationBuild` adds the line that marks a build with the
    /// scripts/simulate-lid.sh watcher compiled in (`LidSimulationBuild`),
    /// so such a build is never mistaken for a normal one.
    /// `relaunchProblems` say why browser relaunches did not happen, one
    /// line per browser; they follow the browser lines, since the browsers
    /// they name may no longer be in them.
    /// `outputsWaiting` are output devices still muted from a lid close
    /// because they were not connected to get their volume back; each gets
    /// a line and an item to stop waiting for it.
    /// `remaining` is the time left, given while a session runs and the bar
    /// does not show it: the countdown is turned off, or it shows the end
    /// time. It heads the menu.
    static func items(
        sessionActive: Bool,
        sleepHeld: Bool,
        machine: String?,
        network: String? = nil,
        actions: String?,
        throttledBrowsers: [ThrottledBrowser],
        relaunchProblems: [String] = [],
        hotspotWarning: String? = nil,
        error: String?,
        commandRunning: String? = nil,
        foreignSleep: String? = nil,
        outputsWaiting: [SavedAudioOutput] = [],
        lidSimulationBuild: Bool = false,
        remaining: String? = nil
    ) -> [Item] {
        var out: [Item] = []
        if sessionActive, let remaining = present(remaining) {
            out.append(Item(title: remainingLine(remaining), kind: .info))
        }
        if let held = SleepHeldLine.line(sessionActive: sessionActive, sleepHeld: sleepHeld) {
            out.append(Item(title: held.text, kind: held.isWarning ? .warning : .info))
        }
        if let machine = present(machine) {
            out.append(Item(title: machine, kind: .info))
        }
        if let network = present(network) {
            out.append(Item(title: network, kind: .info))
        }
        if let actions = present(actions) {
            out.append(Item(title: actions, kind: .info))
        }
        if lidSimulationBuild {
            out.append(Item(title: LidSimulationBuild.marker, kind: .warning))
        }
        if let throttle = present(StatusLines.throttleWarning(throttledBrowsers.map(\.name))) {
            out.append(Item(title: "\u{26A0} \(throttle)", kind: .warning))
            // The warning alone is a dead end; each throttled browser gets a
            // live item so the relaunch is still one click away, as it was
            // from the popover this menu replaced.
            for browser in throttledBrowsers {
                out.append(Item(title: "Relaunch \(browser.name) unthrottled", kind: .relaunchBrowser(browser)))
            }
        }
        for problem in relaunchProblems.compactMap(present) {
            out.append(Item(title: "\u{26A0} \(problem)", kind: .warning))
        }
        if let hotspot = present(hotspotWarning) {
            out.append(Item(title: "\u{26A0} \(hotspot)", kind: .warning))
        }
        // The sudo pmset left running comes before the session error: it
        // holds every change and quit until it exits, and the line goes
        // away then.
        if let command = present(commandRunning) {
            out.append(Item(title: "\u{26A0} \(command)", kind: .warning))
        }
        if let error = present(error) {
            out.append(Item(title: "\u{26A0} \(error)", kind: .warning))
        }
        // Its own line, after the error: a restore that failed and a bit
        // someone else set can both be true of the same reconcile.
        if let foreignSleep = present(foreignSleep) {
            out.append(Item(title: "\u{26A0} \(foreignSleep)", kind: .warning))
        }
        for waiting in outputsWaiting {
            out.append(Item(title: "\u{26A0} \(SessionManager.stillMutedLine(waiting))", kind: .warning))
            out.append(Item(title: "Stop waiting for \(waiting.label)", kind: .stopWaitingForOutput(waiting)))
        }
        if !out.isEmpty {
            out.append(Item(title: "", kind: .separator))
        }
        if sessionActive {
            out.append(Item(title: endSessionTitle, kind: .endSession))
        }
        out.append(Item(title: settingsTitle, kind: .settings))
        out.append(Item(title: quitTitle, kind: .quit))
        return out
    }

    /// The popover's status rows, then warnings. Empty lines are dropped.
    /// `machine` and `actions` are the rows from `StatusLines`.
    /// `hotspotWarning` is the line about a hotspot password the failover
    /// could not use (`HotspotPasswordProblem.menuLine`).
    /// `shownStartError` is the refusal the popover already shows under
    /// the fields; the session error is left out when it is that same
    /// text, so one failure is never said twice. (The lid simulation
    /// marker is a footer badge, `StatusPopoverView.lidSimulationBadge`,
    /// not a row.)
    /// `relaunchProblems` say why browser relaunches did not happen, one
    /// line per browser; they follow the browser lines, since the browsers
    /// they name may no longer be in them.
    /// `outputsWaiting` are output devices still muted from a lid close
    /// because they were not connected to get their volume back; each gets
    /// a line and a button to stop waiting for it.
    /// Named apart from `items`, the menu's list, so a call can never
    /// reach the other one by its labels.
    static func popoverItems(
        sessionActive: Bool,
        sleepHeld: Bool,
        machine: [Item] = [],
        actions: [Item] = [],
        throttledBrowsers: [ThrottledBrowser],
        relaunchProblems: [String] = [],
        hotspotWarning: String? = nil,
        error: String?,
        shownStartError: String? = nil,
        commandRunning: String? = nil,
        foreignSleep: String? = nil,
        outputsWaiting: [SavedAudioOutput] = []
    ) -> [Item] {
        var out: [Item] = []
        if let held = SleepHeldLine.warning(sessionActive: sessionActive, sleepHeld: sleepHeld) {
            out.append(Item(title: held, kind: .warning))
        }
        out += machine.filter { present($0.title) != nil }
        out += actions.filter { present($0.title) != nil }
        if let throttle = present(StatusLines.throttleWarning(throttledBrowsers.map(\.name))) {
            out.append(Item(title: throttle, kind: .warning))
            // The warning alone is a dead end; each throttled browser gets a
            // button so the relaunch is one click away.
            for browser in throttledBrowsers {
                out.append(Item(title: "Relaunch \(browser.name) unthrottled", kind: .relaunchBrowser(browser)))
            }
        }
        for problem in relaunchProblems.compactMap(present) {
            out.append(Item(title: problem, kind: .warning))
        }
        if let hotspot = present(hotspotWarning) {
            out.append(Item(title: hotspot, kind: .warning))
        }
        // The sudo pmset left running comes before the session error: it
        // holds every change and quit until it exits, and the line goes
        // away then.
        if let command = present(commandRunning) {
            out.append(Item(title: command, kind: .warning))
        }
        if let error = present(error), error != shownStartError {
            out.append(Item(title: error, kind: .warning))
        }
        // Its own line, after the error: a restore that failed and a bit
        // someone else set can both be true of the same reconcile.
        if let foreignSleep = present(foreignSleep) {
            out.append(Item(title: foreignSleep, kind: .warning))
        }
        for waiting in outputsWaiting {
            out.append(Item(title: SessionManager.stillMutedLine(waiting), kind: .warning))
            out.append(Item(title: "Stop waiting for \(waiting.label)", kind: .stopWaitingForOutput(waiting)))
        }
        return out
    }

    /// Group the items into drawn rows: each action joins the row before
    /// it as a button. An action with no row before it (not produced by
    /// `popoverItems`) is a row of its own.
    static func rows(_ items: [Item]) -> [Row] {
        var out: [Row] = []
        for item in items {
            if item.kind.isAction, let last = out.last {
                out[out.count - 1] = Row(item: last.item, actions: last.actions + [item])
            } else {
                out.append(Row(item: item, actions: []))
            }
        }
        return out
    }

    private static func present(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Build the AppKit menu. Status lines are disabled small text; warnings
    /// are orange. `autoenablesItems` is off so the disabled lines stay
    /// disabled and the actions stay live without validation.
    @MainActor
    static func menu(
        _ items: [Item],
        target: AnyObject?,
        endSession: Selector,
        settings: Selector,
        quit: Selector,
        relaunchBrowser: Selector,
        stopWaitingForOutput: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .info, .warning:
                let entry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                entry.isEnabled = false
                // A title participates in the menu-wide shortcut column,
                // even when this disabled line has no shortcut. A native
                // label gives the status row its own fitting width; the
                // actionable rows keep AppKit's normal title/shortcut layout.
                entry.view = StatusMenuLabel(title: item.title, warning: item.kind == .warning)
                entry.setAccessibilityLabel(item.title)
                menu.addItem(entry)
            case .endSession:
                menu.addItem(action(title: item.title, selector: endSession, key: "", target: target))
            case .settings:
                menu.addItem(action(title: item.title, selector: settings, key: ",", target: target))
            case .quit:
                menu.addItem(action(title: item.title, selector: quit, key: "q", target: target))
            case let .relaunchBrowser(browser):
                let entry = action(title: item.title, selector: relaunchBrowser, key: "", target: target)
                entry.representedObject = browser
                menu.addItem(entry)
            case let .stopWaitingForOutput(waiting):
                let entry = action(title: item.title, selector: stopWaitingForOutput, key: "", target: target)
                entry.representedObject = waiting
                menu.addItem(entry)
            }
        }
        return menu
    }

    @MainActor
    private static func action(title: String, selector: Selector, key: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = true
        return item
    }
}

/// Read-only menu content, using a standard AppKit label. Only the content
/// is a view: the containing NSMenu still owns chrome, tracking and actions.
@MainActor
final class StatusMenuLabel: NSView {
    let label: NSTextField

    init(title: String, warning: Bool) {
        label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = warning ? .systemOrange : .disabledControlTextColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.sizeToFit()
        let size = label.frame.size
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(size.width) + 32, height: ceil(size.height) + 10))
        label.frame.origin = NSPoint(x: 16, y: 5)
        addSubview(label)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
}

/// What the menu asks before "Relaunch <browser> unthrottled" quits
/// anything. Pure so the copy is testable; the controller shows it as an
/// NSAlert.
struct RelaunchPrompt: Equatable {
    static let confirmTitle = "Quit and relaunch"
    static let cancelTitle = "Cancel"

    let title: String
    let message: String

    init(browser name: String) {
        title = "Quit and relaunch \(name)?"
        message = "Insomnia quits \(name) and opens it again with the two flags that stop it throttling hidden windows. Your windows and tabs come back only if \(name) is set to reopen them on startup. If \(name) has not quit after \(Int(BrowserThrottle.quitTimeout)) s, nothing is relaunched."
    }
}

/// A short, human line for an error the popover shows, with the original
/// text kept for the tooltip, the accessibility hint and the expanded row.
/// The errors themselves are not changed: the log, notifications and tests
/// read them as they are. Pure so the mapping is testable.
enum ErrorSummary {
    struct Summary: Equatable {
        /// What the row reads.
        let short: String
        /// The original text when `short` leaves something out; nil when
        /// the row already says all of it.
        let full: String?
    }

    /// Longest fallback summary, about two lines of the popover's callout text.
    static let maxLength = 90
    static let reinstall = " Reinstall with scripts/install.sh."

    /// Known prefixes and what they mean, most specific first.
    static let known: [(prefix: String, summary: String)] = [
        ("could not arm backstop:", "Couldn\u{2019}t arm the recovery backstop."),
        ("could not confirm backstop:", "Couldn\u{2019}t confirm the recovery backstop."),
        ("could not arm recovery agent", "Couldn\u{2019}t arm the recovery backstop."),
        ("recovery agent could not be confirmed:", "Couldn\u{2019}t confirm the recovery backstop."),
        ("could not disable sleep:", "Couldn\u{2019}t keep the Mac awake."),
        ("could not restore sleep:", "Couldn\u{2019}t give sleep back to macOS."),
        ("could not re-apply sleep guard:", "Couldn\u{2019}t re-apply the sleep setting."),
        ("could not journal sleep guard:", "Couldn\u{2019}t record the sleep setting on disk."),
        ("could not enable low power mode:", "Couldn\u{2019}t turn on Low Power Mode."),
        ("could not clear low power mode:", "Couldn\u{2019}t turn Low Power Mode back off."),
        ("low power mode may be on and could not be switched off:", "Low Power Mode may still be on."),
        ("could not write session:", "Couldn\u{2019}t save the session to disk."),
        ("could not remove session.json:", "Couldn\u{2019}t remove the ended session from disk."),
        ("start refused:", "Couldn\u{2019}t start yet."),
        ("start refused, nothing changed:", "Couldn\u{2019}t start: the saved session can\u{2019}t be read."),
    ]

    static func summarize(_ text: String) -> Summary {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if let match = known
            .filter({ lower.hasPrefix($0.prefix) })
            .max(by: { $0.prefix.count < $1.prefix.count }) {
            var short = match.summary
            if lower.contains("sudo: a password is required") {
                short += " sudo asked for a password."
            } else if lower.contains("install.sh") {
                short += reinstall
            }
            return Summary(short: short, full: trimmed)
        }
        // Unknown: the first sentence, cut to about two lines.
        var first = trimmed
        for separator in [". ", "; "] {
            if let range = first.range(of: separator) {
                first = String(first[..<range.lowerBound]) + (separator == ". " ? "." : "")
            }
        }
        if first.count > maxLength {
            first = String(first.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
        }
        return Summary(short: first, full: first == trimmed ? nil : trimmed)
    }
}
