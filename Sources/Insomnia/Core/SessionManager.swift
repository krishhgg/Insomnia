import Foundation
import Observation

enum EndReason: String, Sendable {
    case timer
    case user
    case quit
    case batteryFloor
    /// Battery present but its level unreadable on two consecutive reads
    /// while on battery: the end floor could not be applied.
    case batteryUnreadable
    case thermalCritical
    case backstop
    /// session.json was gone while this process still held the session: the
    /// recovery agent ended it (its log line says why: app not running,
    /// battery below the end floor, critical heat) while the app was stopped,
    /// hung, or not holding the alive lock, and restored from the journal.
    /// The app ends on its side from whatever the journal still holds.
    case agentCutoff
    /// Reconcile found a session on disk but could not arm the recovery
    /// agent, journal, or hold sleep for it, so it ended the session instead
    /// of holding sleep with nothing to release it.
    case recoveryUnavailable
    /// `pmset disablesleep 1` failed or timed out during start. The setting
    /// may still have been applied, so the start is undone from the journal
    /// like an end rather than rolled back from memory.
    case startFailed
}

/// What `end` achieved. Callers that are about to quit need to know whether
/// leaving now abandons anything.
enum EndOutcome: Sendable, Equatable {
    /// Journal clean, machine restored.
    case restored
    /// Some entries could not be undone and stay journaled. `agentArmed`
    /// says whether the polling agent is confirmed loaded to retry them.
    case incomplete(agentArmed: Bool)
    /// The recovery lock stayed busy; nothing was read or changed and the
    /// session is still active. An in-process retry is scheduled.
    case locked
    /// session.json could not be removed. Whatever the journal held was
    /// undone, but a relaunch would find a valid session and hold sleep
    /// again, so the end is retried in process and quit is refused.
    case sessionRetained
    /// state.json cannot be read. Nothing was changed: Insomnia does not
    /// know what to undo and will not guess. The session stays active until
    /// a person fixes or moves the file.
    case journalUnreadable
}

/// Why a lifecycle transaction did not run at all.
enum TransactionRefusal: Error, Sendable {
    case lockBusy(String)
    case journalUnreadable(String)
}

/// Owns the session lifecycle: start / extend / end / reconcile.
///
/// Journal-first: every mutation is written to session.json / state.json
/// *before* the matching side effect, and undo always reads state.json from
/// disk, never memory (spec section 8 invariants).
///
/// One transaction at a time: every operation that reads the journal,
/// decides, changes the machine and writes the journal runs on a single
/// queue while holding the cross-process recovery lock shared with
/// backstop.sh, and starts from the journal as it is on disk at that
/// moment, never from a copy cached earlier: backstop.sh may have written
/// it in between. An end requested while a start, extend or Low Power change
/// is still queued or in flight wins: the older operation abandons itself
/// before anything irreversible, or leaves its effect journaled for the
/// end that runs right behind it.
@MainActor
@Observable
final class SessionManager {
    private(set) var session: Session?
    private(set) var state: RuntimeState
    var config: Config
    /// Minute-granularity remaining time for the popover ("2h 14m").
    private(set) var remainingText: String = ""
    /// Live `H:MM:SS` countdown for the status item, updated at 1 Hz.
    private(set) var countdownText: String = ""
    /// Last failure worth showing in the menu; cleared on the next success.
    private(set) var lastError: String?
    /// Reconcile found SleepDisabled set with no session and no journal
    /// claim: something other than Insomnia disabled sleep. Kept apart from
    /// `lastError` so a restore failure from the same reconcile stays
    /// visible beside it. Cleared by a session start, or by
    /// `recheckForeignSleep()` once the bit reads 0 again.
    private(set) var foreignSleepWarning: String?

    var isActive: Bool { session != nil }

    /// Fire date of the single deadline timer, exposed for tests and the menu.
    private(set) var scheduledDeadline: Date?

    let store: Store
    let paths: Paths
    private let sleepGuard: any SleepGuarding
    private let processControl: any ProcessSignaling
    private let backstop: any BackstopScheduling
    private let audio: any AudioControlling
    private let display: any DisplayDimming
    private let keyboard: any KeyboardBacklighting
    private let notifier: any Notifying
    private let clamshell: @Sendable () -> Bool?
    private let clock: @Sendable () -> Date
    /// The manager's idea of now (a fake in tests). UI decisions about the
    /// session the manager holds, such as how much an extension may still add
    /// under `config.maxDuration`, must use this clock, not the wall clock.
    var now: Date { clock() }
    private let recoveryLock: RecoveryLock
    private let recoveryLockTimeout: TimeInterval
    private let recoveryRetryDelay: TimeInterval
    /// How long after a display/keyboard restore the same values are
    /// written once more. powerd re-applies its own remembered brightness
    /// asynchronously after the wake and can override the first write.
    private let reassertDelay: Duration
    /// The pending second write of a display/keyboard restore. One at a
    /// time: the next restore cancels it, and a lid close that darkened
    /// again in the meantime makes it skip (see undoLidActionsInJournal).
    private var reassertTask: Task<Void, Never>?
    /// What the pending re-assert will write, per device, so a new
    /// schedule for one device does not drop the other's second write.
    private var pendingReassert: (display: Float?, keyboard: Float?) = (nil, nil)
    /// Called just before Insomnia takes Low Power Mode over, before the
    /// ownership is journaled: `AppServices` samples the display brightness
    /// then, so the value journaled at a later lid close is the user's,
    /// not the mode's rescaled one. nil in tests that do not wire it.
    var willEnableLowPower: (@MainActor () -> Void)?
    /// How far the panel may have drifted from a value written under Low
    /// Power Mode (auto-brightness moves it slowly) and still count as
    /// untouched by the user when the mode ends. A larger difference is a
    /// brightness key: the panel is the user's again and is left alone.
    static let untouchedDisplayTolerance: Float = 0.05

    /// System integrations (lid, battery, network, ...). Set by `live()`;
    /// nil in tests. Started after a session starts, stopped when it ends.
    @ObservationIgnored var services: AppServices?

    @ObservationIgnored private var deadlineTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var checkingAgentEnd = false
    /// Whether the 1 Hz redraw is currently on the run loop. Tests assert on
    /// this to prove an idle session leaves no repeating wakeup behind.
    var countdownTimerArmed: Bool { countdownTimer != nil }
    @ObservationIgnored private var countdownPaused = false

    /// Counts end requests. Start, extend and Low Power changes capture it
    /// when requested and compare after each await, so an end that arrived
    /// in the meantime wins.
    @ObservationIgnored private(set) var endTicket = 0
    /// Set by a quit request; new sessions are refused from then on.
    @ObservationIgnored private(set) var quitRequested = false
    /// An end that could not complete (lock busy, or dirty with no agent to
    /// retry). Retried in process; new starts wait until it is resolved.
    @ObservationIgnored private(set) var pendingEnd: EndReason?
    /// Tail of the lifecycle queue.
    @ObservationIgnored private var lifecycleTail: Task<Void, Never>?
    /// Detail of the last unreadable-journal notification, so a journal
    /// that stays broken is announced once, not on every transaction.
    @ObservationIgnored private var announcedCorruption: String?
    /// Whether this launch has posted the notification for a SleepDisabled
    /// bit Insomnia did not set (reconcile step 3), so a bit that stays set
    /// is announced once, not on every reconcile.
    @ObservationIgnored private var announcedForeignSleep = false

    init(
        paths: Paths,
        sleepGuard: any SleepGuarding,
        processControl: any ProcessSignaling,
        backstop: any BackstopScheduling,
        audio: any AudioControlling = NoopAudioControl(),
        display: any DisplayDimming = NoopDisplayDimmer(),
        keyboard: any KeyboardBacklighting = NoopKeyboardBacklight(),
        notifier: any Notifying = RecordingNotifier(),
        clamshell: @escaping @Sendable () -> Bool? = { LidObserver.readClamshellState() },
        clock: @escaping @Sendable () -> Date = { Date() },
        recoveryLockTimeout: TimeInterval = 10,
        recoveryRetryDelay: TimeInterval = 30,
        reassertDelay: Duration = .seconds(2)
    ) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.sleepGuard = sleepGuard
        self.processControl = processControl
        self.backstop = backstop
        self.audio = audio
        self.display = display
        self.keyboard = keyboard
        self.notifier = notifier
        self.clamshell = clamshell
        self.clock = clock
        self.recoveryLock = RecoveryLock(url: paths.recoveryLock)
        self.recoveryLockTimeout = recoveryLockTimeout
        self.recoveryRetryDelay = recoveryRetryDelay
        self.reassertDelay = reassertDelay

        try? paths.createDirectories()
        var loadedState: RuntimeState?
        var loadError: String?
        do {
            loadedState = try store.loadState()
        } catch {
            // The journal stays on disk untouched; every transaction re-reads
            // it under the lock and refuses to run until it decodes again.
            loadError = Self.unreadableJournalMessage(error)
            Log.error(loadError!)
        }
        self.state = loadedState ?? .clean
        self.lastError = loadError
        if let c = (try? store.loadConfig()) ?? nil {
            self.config = c
            // An older build's file was just read with its stock values
            // migrated. Writing it back once marks it current, so a ceiling
            // typed into it later is read as the user's.
            if (try? store.configHasVersion()) == false { try? store.saveConfig(c) }
        } else {
            self.config = Config()
            try? store.saveConfig(self.config)
        }
    }

    /// Production wiring.
    static func live(paths: Paths = .fromEnvironment()) -> SessionManager {
        let notifier = Notifier()
        let audio = CoreAudioControl()
        let display = DisplayServicesDimmer()
        let keyboard = CoreBrightnessKeyboardBacklight()
        let processControl = SignalProcessControl()
        let m = SessionManager(
            paths: paths,
            sleepGuard: PmsetSleepGuard(),
            processControl: processControl,
            backstop: LaunchdBackstop(paths: paths),
            audio: audio,
            display: display,
            keyboard: keyboard,
            notifier: notifier
        )
        let services = AppServices(
            paths: paths,
            notifier: notifier,
            audio: audio,
            processControl: processControl,
            display: display,
            keyboard: keyboard
        )
        m.services = services
        services.logStartupSnapshot()
        return m
    }

    // MARK: Lifecycle queue

    /// Runs `op` after every earlier lifecycle operation, holding the
    /// recovery lock, with `state` freshly read from disk under that lock.
    /// `op` is not run at all when the lock cannot be taken within the
    /// bound or when state.json does not decode: nothing is read, decided
    /// or changed unlocked, and an unreadable journal is never overwritten.
    /// With `syncSession` (every caller but `end`, which does this work
    /// itself) a session the recovery agent has ended meanwhile is ended
    /// here first, so `op` never acts on a session that is over on disk.
    /// Never blocks the main actor; the wait is polled.
    private func exclusive<T: Sendable>(_ what: String, syncSession: Bool = true, _ op: @escaping @MainActor @Sendable () async -> T) async -> Result<T, TransactionRefusal> {
        let previous = lifecycleTail
        let task = Task<Result<T, TransactionRefusal>, Never> { @MainActor in
            await previous?.value
            let handle: RecoveryLockHandle
            do {
                handle = try await self.recoveryLock.acquire(timeout: self.recoveryLockTimeout)
            } catch {
                self.fail("\(what) skipped, nothing changed: \(error.localizedDescription)")
                return .failure(.lockBusy(error.localizedDescription))
            }
            defer { handle.release() }
            do {
                try self.loadJournal()
            } catch {
                self.refuseForUnreadableJournal(what, error)
                return .failure(.journalUnreadable(error.localizedDescription))
            }
            if syncSession { await self.adoptAgentEnd() }
            return .success(await op())
        }
        lifecycleTail = Task { _ = await task.value }
        return await task.value
    }

    /// Disk decides whether a session exists. session.json gone while this
    /// process still holds a session means backstop.sh ended it (its log
    /// line says why) while this process could not act: stopped, hung, or
    /// without the alive lock. The agent has restored what it could; the end
    /// here runs from the journal just read under the lock, so anything it
    /// left is retried, and observers, timers and the countdown stop. An
    /// unreadable session.json is not a vanished one and is left alone.
    private func adoptAgentEnd() async {
        guard let s = session else { return }
        let onDisk: Session?
        do {
            onDisk = try store.loadSession()
        } catch {
            return
        }
        guard onDisk == nil else { return }
        Log.error("session.json is gone while the session until \(iso(s.endsAt)) was active: the recovery agent ended it (its log line says why); ending here from the journal")
        endTicket += 1
        _ = await performEnd(reason: .agentCutoff)
    }

    /// The 1 Hz tick's look for a session the agent ended while the lid was
    /// open and nothing else transacted: a cheap stat first, then the
    /// decision and the end under the lock (`adoptAgentEnd`).
    private func noticeAgentEnd() async {
        guard session != nil, !checkingAgentEnd,
              !FileManager.default.fileExists(atPath: paths.sessionFile.path) else { return }
        checkingAgentEnd = true
        defer { checkingAgentEnd = false }
        _ = await exclusive("agent end") {}
    }

    /// Disk is the source of truth. Missing means clean; anything that does
    /// not decode throws and is left exactly as it is.
    private func loadJournal() throws {
        state = try store.loadState() ?? .clean
    }

    private func refuseForUnreadableJournal(_ what: String, _ error: Error) {
        let message = Self.unreadableJournalMessage(error)
        fail("\(what) refused, nothing changed: \(message)")
        let detail = error.localizedDescription
        if announcedCorruption != detail {
            announcedCorruption = detail
            notifier.post(title: Self.journalTitle, body: message)
        }
    }

    private static func unreadableJournalMessage(_ error: Error) -> String {
        "\(error.localizedDescription). Insomnia has changed nothing and will not start, extend or end sessions until the file is fixed or moved by hand; it is the only record of what a previous run changed."
    }

    /// Lid actions run their journal writes and signals as one transaction
    /// on the same queue. False when the lock could not be taken or the
    /// journal could not be read.
    @discardableResult
    func runExclusive(_ what: String, _ op: @escaping @MainActor @Sendable () async -> Void) async -> Bool {
        if case .success = await exclusive(what, op) { return true }
        return false
    }

    // MARK: Start / extend / end

    /// Start a session of `duration` seconds (clamped to `config.maxDuration`).
    /// Ignored if a session is already active; use `extend`.
    ///
    /// Ordering: session.json, then state.json, then the recovery agent,
    /// then `pmset disablesleep 1`. A failure before pmset is rolled back:
    /// nothing has touched the machine. A pmset failure is ambiguous (the
    /// setting may have been applied before the error or timeout), so it is
    /// undone from the journal like an end, and the journal keeps the entry
    /// until that undo is confirmed.
    func start(duration: TimeInterval) async {
        guard !quitRequested else {
            Log.info("start ignored: quit requested")
            return
        }
        guard pendingEnd == nil else {
            fail("start refused: the previous session is still being ended; retrying shortly")
            return
        }
        let ticket = endTicket
        _ = await exclusive("start") { await self.performStart(duration: duration, ticket: ticket) }
    }

    private func performStart(duration: TimeInterval, ticket: Int) async {
        guard session == nil else {
            Log.info("start ignored: session already active")
            return
        }
        guard endTicket == ticket, !quitRequested else {
            Log.info("start abandoned: an end was requested first")
            return
        }
        let now = clock()
        let new = SessionMath.newSession(now: now, duration: duration, maxDuration: config.maxDuration)
        // What was on disk before this attempt, read under the lock. A
        // rollback puts exactly this back: an entry an earlier failed restore
        // left behind is evidence, not something this start may clear.
        let journalBefore = state
        let sessionBefore = (try? store.loadSession()) ?? nil

        do {
            try store.saveSession(new)
            try journal { $0.sleepDisabledByUs = true }
        } catch {
            fail("could not write session: \(error.localizedDescription)")
            rollBackStart(journal: journalBefore, session: sessionBefore)
            return
        }

        // The agent is confirmed loaded before sleep is disabled, so a crash
        // at any later point already has launchd polling the deadline.
        do {
            try await backstop.arm()
        } catch {
            rollBackStart(journal: journalBefore, session: sessionBefore)
            fail("could not arm backstop: \(error.localizedDescription)")
            return
        }
        guard endTicket == ticket else {
            rollBackStart(journal: journalBefore, session: sessionBefore)
            Log.info("start abandoned before disabling sleep: end requested meanwhile")
            return
        }

        do {
            try await sleepGuard.setSleepDisabled(true)
        } catch {
            fail("could not disable sleep: \(error.localizedDescription)")
            _ = await performEnd(reason: .startFailed)
            return
        }
        guard endTicket == ticket else {
            // Sleep is disabled and journaled as ours. The end that was
            // requested runs next and restores from that journal; the session
            // is never surfaced.
            Log.info("start abandoned after disabling sleep: end requested meanwhile; journal left for it")
            return
        }

        session = new
        lastError = nil
        foreignSleepWarning = nil
        Log.info("session started until \(iso(new.endsAt)) (\(Int(duration))s requested)")
        await armDeadline(new.endsAt)
        // App Nap defaults and every observer live in AppServices.
        services?.start(for: self)
        // PR3: schedule "5 minutes left" notification.
    }

    func extend(by extra: TimeInterval) async {
        guard session != nil else { return }
        let ticket = endTicket
        _ = await exclusive("extend") { await self.performExtend(by: extra, ticket: ticket) }
    }

    private func performExtend(by extra: TimeInterval, ticket: Int) async {
        guard let current = session, endTicket == ticket else { return }
        let updated = SessionMath.extended(current, by: extra, now: clock(), maxDuration: config.maxDuration)
        // The agent enforces whatever deadline is on disk; confirm it is
        // still loaded before moving that deadline out.
        do {
            try await backstop.arm()
        } catch {
            fail("could not confirm backstop: \(error.localizedDescription)")
            return
        }
        guard endTicket == ticket, session == current else {
            Log.info("extend abandoned: end requested meanwhile")
            return
        }
        do {
            try store.saveSession(updated)
        } catch {
            fail("could not write session: \(error.localizedDescription)")
            return
        }
        session = updated
        lastError = nil
        Log.info("session extended by \(Int(extra))s until \(iso(updated.endsAt))")
        await armDeadline(updated.endsAt)
    }

    /// Full session end: delete the session file first (so a crash here leaves
    /// a clean "no session" for reconcile/backstop), then undo RuntimeState
    /// from disk. The polling agent stays loaded.
    ///
    /// Requesting an end invalidates every start, extend or Low Power change
    /// still queued or in flight. If the recovery lock cannot be taken the
    /// end changes nothing and is retried in process. If the journal cannot
    /// be read the end changes nothing and waits for a person.
    @discardableResult
    func end(reason: EndReason) async -> EndOutcome {
        endTicket += 1
        if reason == .quit { quitRequested = true }
        retryTimer?.invalidate()
        retryTimer = nil
        let outcome: EndOutcome
        switch await exclusive("end", syncSession: false, { await self.performEnd(reason: reason) }) {
        case let .success(o): outcome = o
        case .failure(.lockBusy): outcome = .locked
        case .failure(.journalUnreadable): outcome = .journalUnreadable
        }
        switch outcome {
        case .restored, .incomplete(agentArmed: true):
            pendingEnd = nil
        case .locked:
            notifier.post(
                title: Self.notEndedTitle,
                body: "The recovery lock is held by another process, so nothing was changed. The session is still active; Insomnia retries in \(Int(recoveryRetryDelay)) s."
            )
            scheduleEndRetry(reason)
        case .incomplete(agentArmed: false), .sessionRetained:
            scheduleEndRetry(reason)
        case .journalUnreadable:
            // No timer: a broken file does not heal by itself. The end stays
            // pending, so new starts are refused and quit is deferred, until
            // the next end request finds a readable journal.
            pendingEnd = reason
            quitRequested = false
        }
        return outcome
    }

    private func performEnd(reason: EndReason) async -> EndOutcome {
        let had = session != nil
        Log.info("session end (\(reason.rawValue))")
        stopTimers()
        session = nil
        scheduledDeadline = nil
        remainingText = ""
        countdownText = ""
        var deletionError: String?
        do {
            try store.deleteSession()
        } catch {
            deletionError = error.localizedDescription
            fail("could not remove session.json: \(error.localizedDescription)")
        }
        await restoreAll()
        // App Nap defaults are intentionally left set (spec: open decisions).
        services?.stop()

        if state.isDirty || deletionError != nil {
            // The journal is the retry list. Make sure something will read it.
            var armed = true
            if state.isDirty {
                do {
                    try await backstop.arm()
                } catch {
                    armed = false
                    fail("recovery agent could not be confirmed: \(error.localizedDescription)")
                }
            }
            if let deletionError {
                // The agent enforces deadlines, it does not remove a live
                // session file; only this process can, so it stays to retry.
                let journalNote = state.isDirty ? " Some changes are also still journaled." : ""
                notifier.post(
                    title: Self.incompleteTitle,
                    body: "session.json could not be removed (\(deletionError)); a relaunch would hold sleep again for it.\(journalNote) Insomnia retries in \(Int(recoveryRetryDelay)) s; do not quit until it is removed."
                )
                scheduleEndRetry(reason)
                return .sessionRetained
            }
            let detail = lastError ?? "some changes could not be undone"
            let retry = armed ? "The recovery agent retries every minute." : "Insomnia retries in \(Int(recoveryRetryDelay)) s; do not quit until it is restored."
            notifier.post(title: Self.incompleteTitle, body: "\(detail). \(retry)")
            // Reconcile and a failed start reach here without `end()`; the
            // retry is scheduled here so they are covered too (rescheduling
            // from `end()` is harmless).
            if !armed { scheduleEndRetry(reason) }
            return .incomplete(agentArmed: armed)
        }
        notifier.post(title: Self.endTitle(reason, had: had), body: endBody(reason))
        return .restored
    }

    private func scheduleEndRetry(_ reason: EndReason) {
        pendingEnd = reason
        // The app is staying alive for this, so a quit reason no longer applies.
        quitRequested = false
        retryTimer?.invalidate()
        let timer = Timer(timeInterval: recoveryRetryDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pending = self.pendingEnd else { return }
                Log.info("retrying pending end (\(pending.rawValue))")
                await self.end(reason: pending == .quit ? .user : pending)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }

    // MARK: Journal hooks for LidActions / FloorRules

    /// Persist a state mutation (journal first) and keep the in-memory copy
    /// in sync. Throws if state.json cannot be written; callers must then
    /// skip the side effect.
    func journal(_ mutate: (inout RuntimeState) -> Void) throws {
        var s = state
        mutate(&s)
        try persistState(s)
    }

    /// Low Power Mode with journaling: the flag is written before `pmset -b
    /// lowpowermode 1` and cleared only after `... 0` succeeds. Returns true
    /// when the mode was actually changed by Insomnia.
    ///
    /// A mode the user already had on is never taken over: it would be
    /// switched off at session end. If pmset cannot be read, no ownership
    /// is taken either. If `lowpowermode 1` fails or times out, the mode may
    /// still have been applied: the flag stays journaled until `lowpowermode
    /// 0` is confirmed.
    @discardableResult
    func setLowPower(_ on: Bool) async -> Bool {
        let ticket = endTicket
        if case let .success(changed) = await exclusive("low power", { await self.performSetLowPower(on, ticket: ticket) }) {
            return changed
        }
        return false
    }

    private func performSetLowPower(_ on: Bool, ticket: Int) async -> Bool {
        if on {
            guard !state.lowPowerSetByUs, endTicket == ticket else { return false }
            do {
                if try await sleepGuard.isLowPowerModeOn() {
                    Log.info("low power mode already on; leaving it alone")
                    return false
                }
            } catch {
                Log.error("could not read low power mode; not enabling it: \(error.localizedDescription)")
                return false
            }
            guard endTicket == ticket else { return false }
            willEnableLowPower?()
            if state.displayRestoredUnderLowPower != nil {
                Log.info("display restore after low power mode dropped: a new low power mode interval starts")
            }
            do {
                // One write: a write owed from an earlier interval (its
                // clear failed) must not be found by this interval's end.
                try journal { s in
                    s.lowPowerSetByUs = true
                    s.displayRestoredUnderLowPower = nil
                }
            } catch {
                Log.error("could not journal low power mode: \(error.localizedDescription)")
                return false
            }
            do {
                try await sleepGuard.setLowPowerMode(true)
            } catch {
                fail("could not enable low power mode: \(error.localizedDescription)")
                do {
                    try await sleepGuard.setLowPowerMode(false)
                    try? journal { $0.lowPowerSetByUs = false }
                } catch {
                    fail("low power mode may be on and could not be switched off: \(error.localizedDescription); kept in the journal to retry")
                    do { try await backstop.arm() } catch { Log.error("recovery agent could not be confirmed: \(error.localizedDescription)") }
                }
                return false
            }
            guard endTicket == ticket else {
                // The mode is on and journaled as ours; the end queued behind
                // this call clears it. Nothing to announce.
                Log.info("low power mode on, but an end was requested meanwhile; journal left for it")
                return false
            }
            Log.info("low power mode on")
            return true
        } else {
            guard state.lowPowerSetByUs else { return false }
            dropDisplayWriteIfMoved()
            do {
                try await sleepGuard.setLowPowerMode(false)
                try? journal { $0.lowPowerSetByUs = false }
                Log.info("low power mode off")
                settleDisplayAfterLowPower()
                return true
            } catch {
                Log.error("could not disable low power mode: \(error.localizedDescription)")
                return false
            }
        }
    }

    /// Undo every lid-close action recorded on disk: resume frozen pids,
    /// clear the Docker marker, restore volume and mute. Used by lid open.
    func undoLidActions() async {
        _ = await exclusive("lid open") { self.undoLidActionsInJournal() }
    }

    // MARK: Restore

    /// Undo every RuntimeState entry of the journal read under the current
    /// transaction's lock. Each undo is journaled as soon as it succeeds,
    /// through the live journal rather than a copy, so a write that lands
    /// while pmset is running (a lid-close freeze, say) is never overwritten.
    /// Failures are logged and the entry is left set so the next end,
    /// reconcile or the backstop retries it.
    func restoreAll() async {
        if state.sleepDisabledByUs {
            do {
                try await sleepGuard.setSleepDisabled(false)
                try? journal { $0.sleepDisabledByUs = false }
                Log.info("sleep restored")
            } catch {
                fail("could not restore sleep: \(error.localizedDescription)")
            }
        }

        var lowPowerJustCleared = false
        if state.lowPowerSetByUs {
            dropDisplayWriteIfMoved()
            do {
                try await sleepGuard.setLowPowerMode(false)
                try? journal { $0.lowPowerSetByUs = false }
                Log.info("low power mode cleared")
                lowPowerJustCleared = true
            } catch {
                fail("could not clear low power mode: \(error.localizedDescription)")
            }
        } else if state.displayRestoredUnderLowPower != nil {
            dropDisplayWrite(reason: "the mode was cleared by someone else")
        }

        undoLidActionsInJournal()
        // After the undo: a restore just written with the mode off owes
        // nothing more (its journal write clears the entry), and a lid
        // still open gets its second write now.
        if lowPowerJustCleared { settleDisplayAfterLowPower() }
    }

    /// Shared body of lid open, reconcile (lid open) and `restoreAll()`;
    /// each entry is journaled as soon as it is undone.
    private func undoLidActionsInJournal() {
        if !state.frozenProcesses.isEmpty {
            let report = processControl.resume(state.frozenProcesses)
            // Only entries that still need a retry, or that a person has to
            // look at, stay journaled. Gone and resumed entries are done.
            let keep = Set(report.failed + report.unverifiable + report.unobserved)
            try? journal { s in
                s.frozenProcesses.removeAll { !keep.contains($0.pid) }
                // Docker Desktop is frozen via its pids too; the flag is only a marker.
                if s.frozenProcesses.isEmpty { s.dockerFrozen = false }
            }
            Log.info("resumed \(report.resumed.count) frozen pid(s); \(report.gone.count) gone, \(report.failed.count) failed, \(report.unverifiable.count) unverifiable, \(report.unobserved.count) unobserved")
            if !report.failed.isEmpty {
                fail("could not resume pid(s) \(report.failed.map(String.init).joined(separator: ", ")); kept in the journal to retry")
            }
            if !report.unobserved.isEmpty {
                fail("could not read the state of pid(s) \(report.unobserved.map(String.init).joined(separator: ", ")); kept in the journal to retry")
            }
            if !report.unverifiable.isEmpty {
                let list = report.unverifiable.map(String.init).joined(separator: ", ")
                fail("pid(s) \(list) are stopped but journaled without identity (a legacy entry from an older build, or a freeze interrupted before the kernel confirmed the stop), so Insomnia cannot prove it froze them and will not resume them. Check each one first, for example `ps -o pid,stat,lstart,command -p <pid>`, and only if it is a process you expected Insomnia to freeze run `kill -CONT <pid>`; the entry stays in the journal until resumed or gone")
            }
        } else if state.dockerFrozen {
            try? journal { $0.dockerFrozen = false }
        }

        if state.savedOutputVolume != nil || state.savedMuted != nil {
            do {
                let current = try audio.read()
                let volume = state.savedOutputVolume ?? current.volume
                let muted = state.savedMuted ?? current.muted
                try audio.apply(volume: volume, muted: muted)
                Log.info("audio restored (volume \(volume), muted \(muted))")
                try? journal { s in
                    s.savedOutputVolume = nil
                    s.savedMuted = nil
                }
            } catch {
                fail("could not restore audio: \(error.localizedDescription)")
            }
        }

        // Display and keyboard were darkened by us (spec section 4), not by
        // the OS: with the sleep guard on, macOS never turns the panel off on
        // lid close, so brightness 0 is what keeps it dark. Wake first: the
        // panel may also be asleep from the best-effort sleep request.
        if state.savedDisplayBrightness != nil || state.savedKeyboardBrightness != nil {
            display.wake()
        }
        // Read before the entries are cleared: the re-assert below needs them.
        var restoredDisplay: Float?
        var restoredKeyboard: Float?
        if let saved = state.savedDisplayBrightness {
            do {
                try display.setBrightness(saved)
                Log.info("display restored (brightness \(saved))")
                restoredDisplay = saved
                // Written under our Low Power Mode: written again once the
                // mode is off, since the mode's end rescales the panel.
                let underLowPower = state.lowPowerSetByUs
                do {
                    try journal { s in
                        s.savedDisplayBrightness = nil
                        s.displayRestoredUnderLowPower = underLowPower ? saved : nil
                    }
                } catch {
                    fail("display brightness restored but the journal entry could not be cleared: \(error.localizedDescription); it will be retried")
                }
            } catch {
                fail("could not restore display brightness: \(error.localizedDescription)")
            }
        }
        if let saved = state.savedKeyboardBrightness {
            do {
                try keyboard.setBrightness(saved)
                Log.info("keyboard backlight restored (brightness \(saved))")
                restoredKeyboard = saved
                do {
                    try journal { $0.savedKeyboardBrightness = nil }
                } catch {
                    fail("keyboard backlight restored but the journal entry could not be cleared: \(error.localizedDescription); it will be retried")
                }
            } catch {
                fail("could not restore keyboard backlight: \(error.localizedDescription)")
            }
        }
        // powerd applies its own remembered "pre-dim" brightness a moment
        // after the wake and can override the write above, so the same
        // values go out once more.
        scheduleReassert(display: restoredDisplay, keyboard: restoredKeyboard)
    }

    /// Insomnia's own Low Power Mode has just been switched off. A display
    /// restore written while it was on (journaled as
    /// `displayRestoredUnderLowPower`) is written once more now, and
    /// re-asserted like any restore: the mode's end rescales the panel and
    /// can leave it elsewhere than the value written under it. Skipped,
    /// and forgotten, if the lid closed again in the meantime: the close
    /// journaled the value first, and the next open restores it with the
    /// mode already off. A Low Power Mode interval with no restore under
    /// it (a battery floor with the lid open throughout) writes nothing:
    /// the panel was never Insomnia's to set. Best effort like the
    /// re-assert: a failed write is logged and the entry dropped.
    private func settleDisplayAfterLowPower() {
        guard let value = state.displayRestoredUnderLowPower, !state.lowPowerSetByUs else { return }
        guard state.savedDisplayBrightness == nil else {
            dropDisplayWrite(reason: "darkened again")
            return
        }
        do {
            try display.setBrightness(value)
            Log.info("display restored again after low power mode (brightness \(value))")
            try? journal { $0.displayRestoredUnderLowPower = nil }
            scheduleReassert(display: value, keyboard: nil)
        } catch {
            Log.error("display restore after low power mode failed: \(error.localizedDescription)")
            try? journal { $0.displayRestoredUnderLowPower = nil }
        }
    }

    /// Before the mode is switched off: if the panel no longer reads what
    /// was written under it (beyond auto-brightness drift), the user has
    /// moved it since the lid opened, and the second write would undo
    /// that. The panel is theirs; nothing is owed.
    private func dropDisplayWriteIfMoved() {
        guard let value = state.displayRestoredUnderLowPower, state.savedDisplayBrightness == nil else { return }
        guard let now = try? display.readBrightness() else { return }
        if abs(now - value) > Self.untouchedDisplayTolerance {
            dropDisplayWrite(reason: "the display moved since the restore (\(now), restored \(value))")
        }
    }

    private func dropDisplayWrite(reason: String) {
        guard state.displayRestoredUnderLowPower != nil else { return }
        Log.info("display restore after low power mode dropped: \(reason)")
        try? journal { $0.displayRestoredUnderLowPower = nil }
        // The open's own second write of that value, if still pending,
        // would land it all the same.
        pendingReassert.display = nil
    }

    /// The second write of a restore, `reassertDelay` later. Best effort:
    /// errors are only logged. Tracked, not detached: a newer restore
    /// cancels it, and if a lid close journaled fresh values during the
    /// delay (it journals before it darkens) the old values must not light
    /// the panel again.
    ///
    /// A device with a new value takes it; a device without one keeps a
    /// write still pending (the display written again after Low Power
    /// Mode must not drop the keyboard's second write the open scheduled a
    /// moment earlier), and nothing new leaves a pending write alone.
    private func scheduleReassert(display: Float?, keyboard: Float?) {
        guard display != nil || keyboard != nil else { return }
        let restoredDisplay = display ?? pendingReassert.display
        let restoredKeyboard = keyboard ?? pendingReassert.keyboard
        reassertTask?.cancel()
        pendingReassert = (restoredDisplay, restoredKeyboard)
        do {
            let delay = reassertDelay
            reassertTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                // Read when it fires, not when it was scheduled: a drop in
                // the meantime (the user moved the panel) takes the
                // display's write out and leaves the keyboard's.
                let (restoredDisplay, restoredKeyboard) = self.pendingReassert
                self.pendingReassert = (nil, nil)
                if let value = restoredDisplay {
                    if self.state.savedDisplayBrightness != nil {
                        Log.info("display restore re-assert skipped: darkened again")
                    } else {
                        do {
                            try self.display.setBrightness(value)
                            Log.info("display restore re-asserted (brightness \(value))")
                        } catch {
                            Log.info("display restore re-assert failed: \(error.localizedDescription)")
                        }
                    }
                }
                if let value = restoredKeyboard {
                    if self.state.savedKeyboardBrightness != nil {
                        Log.info("keyboard restore re-assert skipped: darkened again")
                    } else {
                        do {
                            try self.keyboard.setBrightness(value)
                            Log.info("keyboard restore re-asserted (brightness \(value))")
                        } catch {
                            Log.info("keyboard restore re-assert failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Reconcile (spec section 8)

    func reconcile() async {
        _ = await exclusive("reconcile") { await self.performReconcile() }
    }

    private func performReconcile() async {
        let now = clock()
        var onDisk: Session?
        do {
            onDisk = try store.loadSession()
        } catch {
            Log.error("session.json unreadable (\(error.localizedDescription)); treating as expired")
            onDisk = nil
        }

        if let s = onDisk, !s.isExpired(at: now) {
            // Step 2: valid session. Arm first, then journal, then hold
            // sleep. Any failure ends the session rather than holding sleep
            // with nothing guaranteed to release it.
            session = s
            do {
                try await backstop.arm()
            } catch {
                fail("could not arm recovery agent for the session on disk: \(error.localizedDescription); ending it")
                _ = await performEnd(reason: .recoveryUnavailable)
                return
            }
            if !state.sleepDisabledByUs {
                do {
                    try journal { $0.sleepDisabledByUs = true }
                } catch {
                    fail("could not journal sleep guard: \(error.localizedDescription); ending session")
                    _ = await performEnd(reason: .recoveryUnavailable)
                    return
                }
            }
            do {
                try await sleepGuard.setSleepDisabled(true)
                lastError = nil
            } catch {
                fail("could not re-apply sleep guard: \(error.localizedDescription); ending session")
                _ = await performEnd(reason: .recoveryUnavailable)
                return
            }
            Log.info("reconcile: session valid until \(iso(s.endsAt))")
            if !state.lowPowerSetByUs, state.displayRestoredUnderLowPower != nil {
                dropDisplayWrite(reason: "the mode is not ours")
            }
            // Lid-close actions still on disk are undone only if the lid is
            // open now. Closed (or unknown): they are already journaled and
            // will be undone on the next lid open or at session end.
            let lidClosed = clamshell()
            if lidClosed == false {
                undoLidActionsInJournal()
            } else if state.hasLidActions {
                Log.info("reconcile: lid \(lidClosed == nil ? "unknown" : "closed"), keeping lid-close actions")
            }
            await armDeadline(s.endsAt)
            services?.start(for: self)
            return
        }

        // Step 1: missing or expired -> full end.
        if onDisk != nil {
            Log.info("reconcile: session expired, restoring")
            _ = await performEnd(reason: .timer)
        } else if state.isDirty {
            Log.info("reconcile: no session but dirty state, restoring")
            _ = await performEnd(reason: .backstop)
        } else if state.displayRestoredUnderLowPower != nil {
            dropDisplayWrite(reason: "no session and the mode is not ours")
        } else {
            Log.info("reconcile: no session, nothing to restore")
        }

        // Step 3: SleepDisabled set with no session. A disable Insomnia
        // journaled was undone in step 1, so a bit still set here was set by
        // something else (a hand-run pmset, another tool), or is still
        // journaled as ours after a failed restore. Neither is cleared from
        // here: the first is not Insomnia's to undo, the second is retried
        // from the journal. The foreign case is observed and reported.
        do {
            if try await sleepGuard.isSleepDisabled() {
                guard session == nil else {
                    Log.info("reconcile: a session started meanwhile; leaving SleepDisabled")
                    return
                }
                if state.sleepDisabledByUs {
                    Log.info("reconcile: SleepDisabled is still journaled as ours; the restore is retried from the journal, not repeated here")
                } else {
                    reportForeignSleepDisable()
                }
            }
        } catch {
            Log.error("reconcile: sleep check failed: \(error.localizedDescription)")
        }
    }

    /// `pmset -g` shows SleepDisabled 1 with no session and no journal
    /// entry: something other than Insomnia disabled sleep, and only its
    /// owner should re-enable it. Shown on its own menu line on every
    /// reconcile that finds it, and posted as a notification once per
    /// launch. The line is cleared by the next session start, whose end
    /// sets `disablesleep 0` whoever set the bit, or by a recheck that
    /// reads the bit as 0.
    private func reportForeignSleepDisable() {
        foreignSleepWarning = Self.foreignSleepLine
        guard !announcedForeignSleep else {
            Log.info("reconcile: \(Self.foreignSleepLine) (already reported)")
            return
        }
        announcedForeignSleep = true
        Log.info("reconcile: \(Self.foreignSleepLine)")
        notifier.post(
            title: Self.foreignSleepTitle,
            body: "pmset reports SleepDisabled 1, but Insomnia has no session and did not set it, so it is left alone. To re-enable sleep: \(Self.foreignSleepCommand). Ending an Insomnia session also sets it to 0."
        )
    }

    /// Re-read `pmset -g` while the foreign-sleep line is up, and drop the
    /// line once the bit reads 0: whoever set it has re-enabled sleep. The
    /// menu calls this on open, so the line goes away on the opening after
    /// the one that found it gone. The read changes nothing and takes no
    /// lock, so it never waits behind a start or an end, and it only ever
    /// clears the line, so an answer that lands after a session start is a
    /// no-op. A bit that still reads 1 keeps the line; a failed read keeps
    /// it too, since nothing is known to have changed.
    func recheckForeignSleep() async {
        guard foreignSleepWarning != nil else { return }
        do {
            if try await sleepGuard.isSleepDisabled() { return }
        } catch {
            Log.error("foreign sleep recheck failed, keeping the warning: \(error.localizedDescription)")
            return
        }
        guard foreignSleepWarning != nil else { return }
        foreignSleepWarning = nil
        Log.info("SleepDisabled reads 0 again; foreign sleep warning cleared")
    }

    // MARK: Countdown (1 Hz redraw)

    /// Stop the countdown redraw. The lid observer calls this on lid close,
    /// which is what keeps a 1 Hz timer from costing battery in the bag.
    func pauseCountdown() {
        countdownPaused = true
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    /// Restart the countdown redraw. The lid observer calls this on lid open.
    func resumeCountdown() {
        countdownPaused = false
        refreshCountdown()
        armCountdownTimer()
    }

    /// Recompute `remainingText` and `countdownText` from the injected clock.
    /// Each is only assigned when it changes, so observers are not woken every
    /// second for the minute-granularity text.
    func refreshCountdown() {
        guard let s = session else {
            remainingText = ""
            countdownText = ""
            return
        }
        let remaining = s.remaining(at: clock())
        let minute = SessionMath.formatRemaining(remaining)
        if remainingText != minute { remainingText = minute }
        let second = SessionMath.formatCountdown(remaining: remaining, shape: s.countdownShape)
        if countdownText != second { countdownText = second }
    }

    // MARK: Private

    /// Undo the writes made at the top of `start` by restoring the journal
    /// and session file exactly as they were read under this transaction's
    /// lock. Nothing has touched the machine at this point.
    private func rollBackStart(journal before: RuntimeState, session previous: Session?) {
        do {
            try persistState(before)
        } catch {
            fail("could not restore the journal after a failed start: \(error.localizedDescription)")
        }
        do {
            if let previous {
                try store.saveSession(previous)
            } else {
                try store.deleteSession()
            }
        } catch {
            fail("could not restore session.json after a failed start: \(error.localizedDescription)")
        }
    }

    /// In-process timers only; the launchd agent is armed by callers before
    /// this runs.
    private func armDeadline(_ endsAt: Date) async {
        deadlineTimer?.invalidate()
        scheduledDeadline = endsAt
        // One timer at the deadline. Fire dates in the past fire immediately.
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.session, s.isExpired(at: self.clock()) else { return }
                await self.end(reason: .timer)
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer

        refreshCountdown()
        if !countdownPaused { armCountdownTimer() }
    }

    /// 1 Hz redraw aligned to whole wall-clock seconds so the digits change
    /// in step with the menu bar clock. `pauseCountdown()` stops it entirely
    /// while the lid is closed.
    private func armCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        // Nothing to redraw without a session. Guarding here rather than in
        // `resumeCountdown` covers every caller: a session that ends while the
        // lid is shut would otherwise leave lid-open arming a 1 Hz timer that
        // wakes the run loop forever to format an empty string.
        guard session != nil else { return }
        let first = SessionMath.nextSecondBoundary(after: clock())
        let timer = Timer(fire: first, interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshCountdown()
                await self.noticeAgentEnd()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func stopTimers() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func persistState(_ s: RuntimeState) throws {
        try store.saveState(s)
        state = s
    }

    private func fail(_ message: String) {
        lastError = message
        Log.error(message)
    }

    private func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    static let incompleteTitle = "Restore incomplete"
    static let notEndedTitle = "Session not ended"
    static let journalTitle = "Recovery journal unreadable"
    static let foreignSleepTitle = "Sleep is disabled by something else"
    static let foreignSleepCommand = "sudo pmset -a disablesleep 0"
    static let foreignSleepLine = "Sleep is disabled by something other than Insomnia; to re-enable it: \(foreignSleepCommand)"

    private static func endTitle(_ reason: EndReason, had: Bool) -> String {
        switch reason {
        case .backstop: "Sleep restored"
        case .startFailed: "Session not started"
        default: had ? "Session ended" : "Session restored"
        }
    }

    private func endBody(_ reason: EndReason) -> String {
        switch reason {
        case .timer: "Time is up. Sleep is back to normal."
        case .user: "Ended by you. Sleep is back to normal."
        case .quit: "Insomnia quit. Sleep is back to normal."
        case .batteryFloor: "Battery fell below \(config.endFloor)%. Sleep is back to normal."
        case .batteryUnreadable: "The battery level could not be read twice in a row, so the \(config.endFloor)% floor could not be applied. Sleep is back to normal."
        case .thermalCritical: "Thermal state is critical. Sleep is back to normal."
        case .backstop: "A previous session left changes behind; everything has been undone."
        case .agentCutoff: "The recovery agent ended the session while Insomnia could not (see insomnia.log for its reason). Sleep is back to normal."
        case .recoveryUnavailable: "Insomnia could not arm its recovery agent for the session found on disk, so it ended the session. Sleep is back to normal."
        case .startFailed: "Insomnia could not disable sleep, so no session was started. Sleep is back to normal."
        }
    }
}
