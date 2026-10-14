import Foundation

/// The status section of the menu bar popover, as data: one short row per
/// fact, then one row per warning, with the actions that belong to a
/// warning carried as buttons on its row. Settings and Quit are the
/// popover's fixed footer and are not rows.
///
/// The item list is pure so the ordering and the omission rules can be
/// tested without a menu bar; `StatusPopoverView` only draws it.
enum StatusMenu {
    struct Item: Equatable {
        enum Kind: Equatable {
            /// A fact about the machine or the session.
            case info
            /// Something the user should know is wrong. Drawn with an
            /// orange triangle, so the text carries no warning sign.
            case warning
            /// Relaunch this browser with the occlusion flags. Carries the
            /// bundle id and name, so the button still names the same
            /// browser after a scan replaces the list.
            case relaunchBrowser(ThrottledBrowser)
            /// Drop the saved volume of this output device: it is not
            /// connected, and Insomnia stops waiting for it. Carries the
            /// save the button was built for, its save ID included, so a
            /// later one is not dropped.
            case stopWaitingForOutput(SavedAudioOutput)

            var isAction: Bool {
                switch self {
                case .info, .warning: false
                case .relaunchBrowser, .stopWaitingForOutput: true
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

    static let settingsTitle = "Settings\u{2026}"
    static let quitTitle = "Quit Insomnia"
    static let warningSymbol = "exclamationmark.triangle.fill"

    /// Status rows, then warnings. Empty lines are dropped.
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
    static func items(
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
        if let held = SleepHeldLine.line(sessionActive: sessionActive, sleepHeld: sleepHeld) {
            out.append(held.isWarning
                ? Item(title: held.text, kind: .warning)
                : Item(title: held.text, kind: .info, symbol: "moon.zzz"))
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
    /// `items`) is a row of its own.
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
}

/// What the popover asks before "Relaunch <browser> unthrottled" quits
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
