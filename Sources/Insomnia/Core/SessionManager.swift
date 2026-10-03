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

    /// Why the display or the keyboard backlight is left alone on lid close
    /// on this Mac (a macOS the private calls were not measured on, a
    /// private class that no longer looks as measured). Empty when both run.
    /// Shown in Settings next to the darken toggle.
    var darkenRefusals: [String] {
        [
            display.refusal().map { "Display: \($0).\(Self.keptLevelNote(state.savedDisplayBrightness))" },
            keyboard.refusal().map { "Keyboard backlight: \($0).\(Self.keptLevelNote(state.savedKeyboardBrightness))" },
        ].compactMap { $0 }
    }

    /// A refused device cannot have been darkened by this build, so a
    /// value saved for it was kept after a refused restore.
    private static func keptLevelNote(_ saved: Float?) -> String {
        guard let saved else { return "" }
        return " The level saved before the lid closed, \(saved), was not restored; set it with the brightness keys or Control Center."
    }
    /// Last failure worth showing in the menu; cleared on the next success.
    private(set) var lastError: String?
    /// Reconcile found SleepDisabled set with no session and no journal
    /// claim: something other than Insomnia disabled sleep. Kept apart from
    /// `lastError` so a restore failure from the same reconcile stays
    /// visible beside it. Cleared by a session start, or by
    /// `recheckForeignSleep()` once the bit reads 0 again.
    private(set) var foreignSleepWarning: String?

    var isActive: Bool { session != nil }

    /// Journal edits owed by a freeze that `LidActions` undid because the
    /// write confirming it failed (`clearUndoneFreeze`).
    struct UndoneFreeze: Equatable, Sendable {
        /// Pids whose provisional entry (identity nil) no longer describes
        /// a stop: resumed, gone, or never stopped by that freeze.
        var pids: Set<Int32> = []
        /// That freeze set `dockerFrozen`, and none of it is still stopped.
        var docker = false

        var isEmpty: Bool { pids.isEmpty && !docker }

        func apply(to s: inout RuntimeState) {
            s.frozenProcesses.removeAll { $0.identity == nil && pids.contains($0.pid) }
            if docker { s.dockerFrozen = false }
        }
    }

    /// Edits not on disk yet because the disk refused them too. Applied
    /// before every journal write and dropped once one succeeds, and tried
    /// on their own at the start of every transaction. In memory only:
    /// after a relaunch, reconcile finds those pids running and clears
    /// their entries itself.
    private var owedEdits = UndoneFreeze()

    /// The journal as it reads once the owed edits are written: what is
    /// frozen right now. The status menu shows this, not `state`.
    var effectiveState: RuntimeState {
        var s = state
        owedEdits.apply(to: &s)
        return s
    }

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
    private let appNap: any AppNapPreferencing
    private let notifier: any Notifying
    private let clamshell: @Sendable () -> Bool?
    private let clock: @Sendable () -> Date
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
    /// How often, and how many times, a brightness kept after a refused
    /// restore is read again while macOS holds the device down, and how
    /// often after that (see scheduleKeptRecheck).
    private let keptRecheckDelay: Duration
    private let keptRecheckAttempts: Int
    private let keptRecheckSlowDelay: Duration
    @ObservationIgnored private var keptRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var keptRecheckAttempt = 0
    /// The re-read has logged that the lid is not known to be open, so the
    /// reads at the slow pace while it stays so log nothing.
    @ObservationIgnored private var keptRecheckSawLidClosed = false
    /// Set by the last undo when a kept value this build could write
    /// failed to restore and its flag could not be cleared either, so on
    /// disk it still reads as refused and not dirty. An end counts it.
    @ObservationIgnored private var keptRestoreFailed = false
    /// The saved value of a kept entry found set since whose clear from
    /// the journal failed. The entry is done: only the clear is retried,
    /// with no read and no write, so a later reading of 0 does not bring
    /// the old value back over the level the user set. In memory only, so
    /// a launch reads the device again.
    @ObservationIgnored private var keptDisplayClearOwed: Float?
    @ObservationIgnored private var keptKeyboardClearOwed: Float?
    /// Called just before Insomnia takes Low Power Mode over, before the
    /// ownership is journaled: `AppServices` samples the display brightness
    /// then, so the value journaled at a later lid close is the user's,
    /// not the mode's rescaled one. nil in tests that do not wire it.
    var willEnableLowPower: (@MainActor () -> Void)?
    /// Called with each brightness level known to be the user's: a value
    /// written from the journal, and the reading that finds a kept value
    /// set since. `AppServices` gives it to the sampler, which does not
    /// read a device while its brightness is journaled
    /// (`BrightnessSampler.follow`). nil in tests that do not wire it.
    var didSettleBrightness: (@MainActor (_ display: Float?, _ keyboard: Float?) -> Void)?
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
    /// Set by reconcile when session.json could not be read, or was not a
    /// session, and could not be moved aside either. The file is evidence,
    /// never deleted. Left under its own name, every later launch and the
    /// recovery agent read it again: one that could not read it may find a
    /// future end time once it can and resume it, and a reader that decodes
    /// a session differently from this one (an older Insomnia) could act on
    /// one that is not a session here. So an end restores the journal,
    /// tries the rename again and, while that fails, is not finished: quit
    /// is refused and the end is retried. Cleared by the next reconcile, and
    /// by a start, whose own session.json replaces it.
    @ObservationIgnored private var keptSessionFile: KeptSessionFile?

    private enum KeptSessionFile {
        /// Opening or reading it failed, or it is not a regular file.
        case cannotBeRead
        /// Its bytes were read and are not a session.
        case notASession
    }

    init(
        paths: Paths,
        sleepGuard: any SleepGuarding,
        processControl: any ProcessSignaling,
        backstop: any BackstopScheduling,
        audio: any AudioControlling = NoopAudioControl(),
        display: any DisplayDimming = NoopDisplayDimmer(),
        keyboard: any KeyboardBacklighting = NoopKeyboardBacklight(),
        appNap: any AppNapPreferencing = NoopAppNapPreferences(),
        notifier: any Notifying = RecordingNotifier(),
        clamshell: @escaping @Sendable () -> Bool? = { LidObserver.readClamshellState() },
        clock: @escaping @Sendable () -> Date = { Date() },
        recoveryLockTimeout: TimeInterval = 10,
        recoveryRetryDelay: TimeInterval = 30,
        reassertDelay: Duration = .seconds(2),
        keptRecheckDelay: Duration = .seconds(3),
        keptRecheckAttempts: Int = 20,
        keptRecheckSlowDelay: Duration = .seconds(60)
    ) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.sleepGuard = sleepGuard
        self.processControl = processControl
        self.backstop = backstop
        self.audio = audio
        self.display = display
        self.keyboard = keyboard
        self.appNap = appNap
        self.notifier = notifier
        self.clamshell = clamshell
        self.clock = clock
        self.recoveryLock = RecoveryLock(url: paths.recoveryLock)
        self.recoveryLockTimeout = recoveryLockTimeout
        self.recoveryRetryDelay = recoveryRetryDelay
        self.reassertDelay = reassertDelay
        self.keptRecheckDelay = keptRecheckDelay
        self.keptRecheckAttempts = keptRecheckAttempts
        self.keptRecheckSlowDelay = keptRecheckSlowDelay

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
        if var c = (try? store.loadConfig()) ?? nil {
            // Settings keeps the end floor below the Low Power Mode floor; a
            // hand-edited config.json may not. Fix it here and write it back.
            if let change = c.normalizeFloors() {
                do {
                    try store.saveConfig(c)
                    Log.info("config.json: \(change); saved")
                } catch {
                    // The corrected floors apply in memory either way; the
                    // file stays as it was and is corrected again next launch.
                    Log.error("config.json: \(change); could not save the correction: \(error.localizedDescription)")
                }
            }
            self.config = c
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
            appNap: CFAppNapPreferences(),
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
    /// Never blocks the main actor; the wait is polled.
    private func exclusive<T: Sendable>(_ what: String, _ op: @escaping @MainActor @Sendable () async -> T) async -> Result<T, TransactionRefusal> {
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
            self.writeOwedEdits()
            return .success(await op())
        }
        lifecycleTail = Task { _ = await task.value }
        return await task.value
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
        let sessionBefore: Session?
        do {
            sessionBefore = try store.loadSession()
        } catch {
            // A session.json this start cannot read is never replaced: it
            // appeared or lost its permissions after reconcile, or reconcile
            // could not move it aside. It may be a valid session, and a
            // rollback could not put it back.
            fail("start refused, nothing changed: session.json could not be read (\(error.localizedDescription)). Remove it or move it out of \(paths.appSupport.path), then start again")
            return
        }

        do {
            try store.saveSession(new)
            keptSessionFile = nil
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
        applyAppNapInJournal()
        // Every observer lives in AppServices.
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
        switch await exclusive("end", { await self.performEnd(reason: reason) }) {
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
        // Why session.json is still in place when a relaunch could act on
        // it; the end is then retried and quit refused.
        var retainedBecause: String?
        if let kept = keptSessionFile {
            retainedBecause = retryMovingAsideKeptSessionFile(kept)
        } else {
            do {
                try store.deleteSession()
            } catch {
                retainedBecause = "session.json could not be removed (\(error.localizedDescription)); a relaunch would hold sleep again for it."
                fail("could not remove session.json: \(error.localizedDescription)")
            }
        }
        await restoreAll()
        services?.stop()

        let needsRestore = journalNeedsRestore
        if needsRestore || retainedBecause != nil {
            // The journal is the retry list. Make sure something will read it.
            var armed = true
            if needsRestore {
                do {
                    try await backstop.arm()
                } catch {
                    armed = false
                    fail("recovery agent could not be confirmed: \(error.localizedDescription)")
                }
            }
            if let retainedBecause {
                // The agent enforces deadlines, it does not remove a live
                // session file; only this process can, so it stays to retry.
                let journalNote = needsRestore ? " Some changes are also still journaled." : ""
                notifier.post(
                    title: Self.incompleteTitle,
                    body: "\(retainedBecause)\(journalNote) Insomnia retries in \(Int(recoveryRetryDelay)) s; do not quit until it is gone."
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

    /// What an end checks before it reports a restore. A brightness kept
    /// after a refused restore is left out of `isDirty`, since no build
    /// whose guard refuses it can restore it, and so is one waiting for a
    /// reading it can trust: nothing failed, and it is read again. It
    /// counts here only when this build wrote it, the write failed, and so
    /// did the journal write that would have cleared the flag.
    private var journalNeedsRestore: Bool {
        state.isDirty || keptRestoreFailed
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
        owedEdits.apply(to: &s)
        mutate(&s)
        try persistState(s)
        owedEdits = UndoneFreeze()
    }

    /// Take the entries of an undone freeze off the journal now, or with
    /// the next journal write that succeeds. Only for `LidActions.freeze`,
    /// inside its transaction.
    func clearUndoneFreeze(_ undone: UndoneFreeze) {
        owedEdits.pids.formUnion(undone.pids)
        owedEdits.docker = owedEdits.docker || undone.docker
        writeOwedEdits()
    }

    private func writeOwedEdits() {
        guard !owedEdits.isEmpty else { return }
        do {
            try journal { _ in }
        } catch {
            Log.error("could not clear the entries of an undone freeze from the journal: \(error.localizedDescription); the status leaves them out, and the next journal write takes them off")
        }
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
        restoreAppNapInJournal()
        // After the undo: a restore just written with the mode off owes
        // nothing more (its journal write clears the entry), and a lid
        // still open gets its second write now.
        if lowPowerJustCleared { settleDisplayAfterLowPower() }
    }

    // MARK: App Nap (spec section 5)

    /// `NSAppSleepDisabled = YES` for each agent app, when the user opted
    /// in. Journal first: the value the key has now (absent, true or false)
    /// is on disk before the preference is touched, so a crash between the
    /// two still restores it, and a journal write that fails means no
    /// preference write. A key already YES is left alone and not journaled,
    /// since there is nothing to put back; a value that is not a boolean is
    /// left alone too. An app already journaled (reconcile after a crash)
    /// keeps its recorded value and is set to YES again. An id backstop.sh
    /// could not restore (`AppNap.isRestorable`) is skipped before anything
    /// is journaled.
    private func applyAppNapInJournal() {
        guard config.disableAppNapForAgents else { return }
        var seen = Set<String>()
        var written = 0
        var alreadyOff = 0
        for id in config.agentList where !id.isEmpty && seen.insert(id).inserted {
            guard AppNap.isRestorable(bundleId: id) else {
                Log.error("app nap: \(id.debugDescription) is not a bundle id the recovery agent can restore; left alone")
                continue
            }
            if !state.appNapOverrides.contains(where: { $0.bundleId == id }) {
                let previous: Bool?
                do {
                    previous = try appNap.readSleepDisabled(bundleId: id)
                } catch {
                    Log.error("app nap: \(error.localizedDescription)")
                    continue
                }
                if previous == true {
                    alreadyOff += 1
                    continue
                }
                do {
                    try journal { $0.appNapOverrides.append(AppNapOverride(bundleId: id, previous: previous)) }
                } catch {
                    fail("could not journal the App Nap setting of \(id): \(error.localizedDescription); its preferences are left unchanged")
                    break
                }
            }
            do {
                try appNap.writeSleepDisabled(true, bundleId: id)
                written += 1
            } catch {
                // Already journaled: the restore puts the recorded value
                // back whether or not this write landed.
                fail("app nap: \(error.localizedDescription); kept in the journal to restore")
            }
        }
        if written > 0 || alreadyOff > 0 {
            Log.info("app nap disabled for \(written) app(s); \(alreadyOff) already had it off")
        }
    }

    /// Put back what `applyAppNapInJournal` recorded: the previous value,
    /// or delete the key when it was absent. An entry is cleared only after
    /// its write succeeded; a failed one stays for the next end, reconcile
    /// or the backstop (`defaults write` / `defaults delete`).
    private func restoreAppNapInJournal() {
        guard !state.appNapOverrides.isEmpty else { return }
        var restored = 0
        for entry in state.appNapOverrides {
            do {
                try appNap.writeSleepDisabled(entry.previous, bundleId: entry.bundleId)
                restored += 1
                do {
                    try journal { $0.appNapOverrides.removeAll { $0.bundleId == entry.bundleId } }
                } catch {
                    fail("App Nap restored for \(entry.bundleId) but the journal entry could not be cleared: \(error.localizedDescription); it will be retried")
                }
            } catch {
                fail("could not restore App Nap for \(entry.bundleId): \(error.localizedDescription); kept in the journal to retry")
            }
        }
        Log.info("app nap restored for \(restored) app(s)")
    }

    /// Shared body of lid open, reconcile (lid open) and `restoreAll()`;
    /// each entry is journaled as soon as it is undone.
    private func undoLidActionsInJournal() {
        // Every error of this undo goes into one report at the end, so a
        // refused brightness restore, which recurs at every lid open and
        // launch, does not hide a failed resume, audio or write beside it.
        var errors: [String] = []
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
                errors.append("could not resume pid(s) \(report.failed.map(String.init).joined(separator: ", ")); kept in the journal to retry")
            }
            if !report.unobserved.isEmpty {
                errors.append("could not read the state of pid(s) \(report.unobserved.map(String.init).joined(separator: ", ")); kept in the journal to retry")
            }
            if !report.unverifiable.isEmpty {
                let list = report.unverifiable.map(String.init).joined(separator: ", ")
                errors.append("pid(s) \(list) are stopped but journaled without identity, so Insomnia cannot prove it froze them and will not resume them. Either an older build recorded the pid alone, or a freeze stopped the pid and Insomnia quit, crashed or failed to write before the stop was confirmed in the journal. Check each one first, for example `ps -o pid,stat,lstart,command -p <pid>`, and only if it is a process you expected Insomnia to freeze run `kill -CONT <pid>`; the entry stays in the journal until resumed or gone")
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
                errors.append("could not restore audio: \(error.localizedDescription)")
            }
        }

        // Display and keyboard were darkened by us (spec section 4), not by
        // the OS: with the sleep guard on, macOS never turns the panel off on
        // lid close, so brightness 0 is what keeps it dark. Wake first: the
        // panel may also be asleep from the best-effort sleep request.
        if state.brightnessJournaled {
            display.wake()
        }
        // Read before the entries are cleared: the re-assert below needs them.
        var restoredDisplay: Float?
        var restoredKeyboard: Float?
        // A value saved before an update (of macOS, or of Insomnia's
        // measured tables) that the private-call guard now refuses is kept,
        // not written and not dropped: see keepRefusedRestore. Both devices
        // go into one message, so neither saved level hides the other. A
        // kept value on a build that can make the call is written only if
        // a reading macOS is not holding down shows nobody set the level
        // since: see keptLevel.
        keptRestoreFailed = false
        var refused: [String] = []
        var waiting: [String] = []
        if let saved = state.savedDisplayBrightness, let why = display.refusal() {
            refused.append(keepRefusedRestore("Display brightness", saved: saved, why: why, flag: \.displayRestoreRefused))
        } else if let saved = state.savedDisplayBrightness {
            restoredDisplay = restoreDisplay(saved: saved, waiting: &waiting, errors: &errors)
        }
        if let saved = state.savedKeyboardBrightness, let why = keyboard.refusal() {
            refused.append(keepRefusedRestore("Keyboard backlight", saved: saved, why: why, flag: \.keyboardRestoreRefused))
        } else if let saved = state.savedKeyboardBrightness {
            restoredKeyboard = restoreKeyboard(saved: saved, waiting: &waiting, errors: &errors)
        }
        if !refused.isEmpty {
            let one = refused.count == 1
            errors.append("could not restore the brightness saved before the lid closed on this macOS build. \(refused.joined(separator: " ")) Set \(one ? "the level" : "the levels") with the brightness keys or Control Center; the saved \(one ? "value stays" : "values stay") in the journal for a version that can restore \(one ? "it" : "them")")
        }
        if !errors.isEmpty {
            fail(errors.joined(separator: ". "))
        }
        if waiting.isEmpty {
            keptRecheckTask?.cancel()
        } else {
            Log.info("\(waiting.joined(separator: "; ")); nothing written or cleared, tried again in \(keptRecheckDelay)")
            keptRecheckAttempt = 0
            keptRecheckSawLidClosed = false
            scheduleKeptRecheck(after: keptRecheckDelay)
        }
        // powerd applies its own remembered "pre-dim" brightness a moment
        // after the wake and can override the write above, so the same
        // values go out once more.
        scheduleReassert(display: restoredDisplay, keyboard: restoredKeyboard)
    }

    /// The display's saved brightness, on a build whose guard allows the
    /// call: written, and the entry cleared. Returns the value written, for
    /// the re-assert. A value kept after a refused restore is read first,
    /// and may be cleared without a write or left waiting: see keptLevel.
    private func restoreDisplay(saved: Float, waiting: inout [String], errors: inout [String]) -> Float? {
        if state.displayRestoreRefused {
            let clear: (inout RuntimeState) -> Void = { s in
                s.savedDisplayBrightness = nil
                s.displayRestoreRefused = false
            }
            if keptDisplayClearOwed == saved {
                if retryClear("display brightness", saved: saved, waiting: &waiting, clear: clear) {
                    keptDisplayClearOwed = nil
                }
                return nil
            }
            keptDisplayClearOwed = nil
            switch keptLevel(read: { try display.readBrightness() },
                             untrusted: { display.isAsleep() ? "the display is asleep" : nil }) {
            case .undecided(let why):
                waiting.append("display brightness \(saved), kept after a refused restore, not read: \(why)")
                return nil
            case .setSince(let now):
                if !clearSetSince("display brightness", saved: saved, now: now, waiting: &waiting, errors: &errors, clear: clear) {
                    keptDisplayClearOwed = saved
                }
                didSettleBrightness?(now, nil)
                return nil
            case .dark:
                break
            }
        } else {
            keptDisplayClearOwed = nil
        }
        do {
            try display.setBrightness(saved)
        } catch {
            errors.append("could not restore display brightness: \(error.localizedDescription)")
            makeRetryable("display brightness", flag: \.displayRestoreRefused, errors: &errors)
            return nil
        }
        Log.info("display restored (brightness \(saved))")
        didSettleBrightness?(saved, nil)
        // Written under our Low Power Mode: written again once the
        // mode is off, since the mode's end rescales the panel.
        let underLowPower = state.lowPowerSetByUs
        do {
            try journal { s in
                s.savedDisplayBrightness = nil
                s.displayRestoreRefused = false
                s.displayRestoredUnderLowPower = underLowPower ? saved : nil
            }
        } catch {
            errors.append("display brightness restored but the journal entry could not be cleared: \(error.localizedDescription); it will be retried")
        }
        return saved
    }

    /// As restoreDisplay, for the keyboard backlight.
    private func restoreKeyboard(saved: Float, waiting: inout [String], errors: inout [String]) -> Float? {
        if state.keyboardRestoreRefused {
            let clear: (inout RuntimeState) -> Void = { s in
                s.savedKeyboardBrightness = nil
                s.keyboardRestoreRefused = false
            }
            if keptKeyboardClearOwed == saved {
                if retryClear("keyboard backlight", saved: saved, waiting: &waiting, clear: clear) {
                    keptKeyboardClearOwed = nil
                }
                return nil
            }
            keptKeyboardClearOwed = nil
            switch keptLevel(read: { try keyboard.readBrightness() },
                             untrusted: { keyboard.isSuppressedOrDimmed() ? "macOS has the backlight suppressed or dimmed" : nil }) {
            case .undecided(let why):
                waiting.append("keyboard backlight \(saved), kept after a refused restore, not read: \(why)")
                return nil
            case .setSince(let now):
                if !clearSetSince("keyboard backlight", saved: saved, now: now, waiting: &waiting, errors: &errors, clear: clear) {
                    keptKeyboardClearOwed = saved
                }
                didSettleBrightness?(nil, now)
                return nil
            case .dark:
                break
            }
        } else {
            keptKeyboardClearOwed = nil
        }
        do {
            try keyboard.setBrightness(saved)
        } catch {
            errors.append("could not restore keyboard backlight: \(error.localizedDescription)")
            makeRetryable("keyboard backlight", flag: \.keyboardRestoreRefused, errors: &errors)
            return nil
        }
        Log.info("keyboard backlight restored (brightness \(saved))")
        didSettleBrightness?(nil, saved)
        do {
            try journal { s in
                s.savedKeyboardBrightness = nil
                s.keyboardRestoreRefused = false
            }
        } catch {
            errors.append("keyboard backlight restored but the journal entry could not be cleared: \(error.localizedDescription); it will be retried")
        }
        return saved
    }

    /// The keyboard backlight stays suppressed for a moment after the wake,
    /// and a display asleep reads its idle-dim value, so a kept value whose
    /// reading decided nothing is read again, each time as its own
    /// transaction under the recovery lock: every `keptRecheckDelay` for
    /// `keptRecheckAttempts` readings, then every `keptRecheckSlowDelay`
    /// for as long as it waits and the app runs. The re-read keeps itself
    /// going: outside a session no lid service runs, so no lid open would
    /// start it again. A busy lock skips one read, not the ones after it.
    /// An unreadable journal ends it, as it refuses every transaction until
    /// the file is fixed; the next launch reads again.
    private func scheduleKeptRecheck(after delay: Duration) {
        keptRecheckTask?.cancel()
        keptRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let result = await self.exclusive("brightness re-check") { self.recheckKeptBrightness() }
            if case .failure(.lockBusy) = result, !Task.isCancelled {
                self.scheduleKeptRecheck(after: self.keptRecheckSlowDelay)
            }
        }
    }

    /// Only the kept values the guard allows: the rest of the journal is
    /// for a lid open, an end or the backstop. Only with the lid known to
    /// be open, as reconcile undoes lid actions: under a closed lid a write
    /// would light what the close keeps dark. Until the lid is known open
    /// nothing is read, at the slow pace, and the first reading after that
    /// starts a new count, since the wake holds the backlight down again.
    private func recheckKeptBrightness() {
        let rereadDisplay = state.savedDisplayBrightness != nil && state.displayRestoreRefused && display.refusal() == nil
        let rereadKeyboard = state.savedKeyboardBrightness != nil && state.keyboardRestoreRefused && keyboard.refusal() == nil
        guard rereadDisplay || rereadKeyboard else { return }
        guard clamshell() == false else {
            if !keptRecheckSawLidClosed {
                keptRecheckSawLidClosed = true
                Log.info("brightness re-check: the lid is not known to be open, so the kept value is not read; checked again every \(keptRecheckSlowDelay) until it is")
            }
            keptRecheckAttempt = 0
            scheduleKeptRecheck(after: keptRecheckSlowDelay)
            return
        }
        keptRecheckSawLidClosed = false
        var waiting: [String] = []
        var errors: [String] = []
        var restoredDisplay: Float?
        var restoredKeyboard: Float?
        if rereadDisplay, let saved = state.savedDisplayBrightness {
            restoredDisplay = restoreDisplay(saved: saved, waiting: &waiting, errors: &errors)
        }
        if rereadKeyboard, let saved = state.savedKeyboardBrightness {
            restoredKeyboard = restoreKeyboard(saved: saved, waiting: &waiting, errors: &errors)
        }
        if !errors.isEmpty {
            fail(errors.joined(separator: ". "))
        }
        scheduleReassert(display: restoredDisplay, keyboard: restoredKeyboard)
        guard !waiting.isEmpty else { return }
        keptRecheckAttempt += 1
        if keptRecheckAttempt < keptRecheckAttempts {
            scheduleKeptRecheck(after: keptRecheckDelay)
            return
        }
        if keptRecheckAttempt == keptRecheckAttempts {
            Log.info("\(waiting.joined(separator: "; ")); still so after \(keptRecheckAttempt) readings, so it is read again every \(keptRecheckSlowDelay) while it waits")
        }
        scheduleKeptRecheck(after: keptRecheckSlowDelay)
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
            didSettleBrightness?(value, nil)
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
        keptSessionFile = nil
        var onDisk: Session?
        do {
            onDisk = try store.loadSession()
        } catch StoreError.unreadable(_, let detail) {
            // The bytes were read and are not a session, so nothing in them
            // can be trusted and nothing in them is needed: the journal, not
            // the session file, says what to undo. Moved aside (never
            // deleted or overwritten) and treated as no session; a dirty
            // journal is still restored below. An unreadable state.json
            // never gets here: exclusive() refuses the transaction first,
            // and the session file stays with it.
            moveAsideUnreadableSession(detail)
            onDisk = nil
        } catch {
            // The file exists but could not be read at all (permissions,
            // I/O, or not a regular file, which Store never opens). Its end
            // time is unknown, and sleep is never held without a deadline
            // that can be enforced, so it counts as expired: a dirty journal
            // is restored below. It may have been a valid session, so it is
            // kept as evidence, renamed aside without being opened. Left
            // under its own name, a later launch that could read it would
            // resume the session this one treated as ended.
            moveAsideSessionThatCannotBeRead(error.localizedDescription)
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
            applyAppNapInJournal()
            services?.start(for: self)
            return
        }

        // Step 1: missing or expired -> full end.
        if onDisk != nil {
            Log.info("reconcile: session expired, restoring")
            _ = await performEnd(reason: .timer)
        } else if state.isDirty {
            Log.info(keptSessionFile != nil
                ? "reconcile: session.json kept in place, restoring the journal as for an expired session"
                : "reconcile: no session but dirty state, restoring")
            _ = await performEnd(reason: .backstop)
        } else {
            if state.displayRestoredUnderLowPower != nil {
                dropDisplayWrite(reason: "no session and the mode is not ours")
            } else if !state.hasRefusedBrightness {
                Log.info("reconcile: no session, nothing to restore")
            }
            // Not dirty, but this launch may be the build or macOS that
            // can make the call; still refused, the entry stays.
            if state.hasRefusedBrightness {
                Log.info("reconcile: no session; trying again the brightness kept after a refused restore")
                undoLidActionsInJournal()
            }
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

    /// The outcome of restoring the journal is reported by the end itself,
    /// not here: this only says where the file went.
    private func moveAsideUnreadableSession(_ detail: String) {
        do {
            let moved = try store.moveAsideUnreadableSession(now: clock())
            Log.error("session.json unreadable (\(detail)); moved to \(moved.path) and treated as no session")
            notifier.post(
                title: Self.sessionFileTitle,
                body: "session.json is not a valid session file (\(detail)). It was moved to \(moved.path); Insomnia treats it as no session."
            )
        } catch let moveError {
            // Kept, not deleted. A start is refused while it is there, and
            // every end restores the journal, tries the rename again, and
            // stays unfinished while it fails.
            keptSessionFile = .notASession
            fail("session.json unreadable (\(detail)) and could not be moved aside: \(moveError.localizedDescription); left in place and treated as no session")
            notifier.post(
                title: Self.sessionFileTitle,
                body: "session.json is not a valid session file (\(detail)). It could not be moved aside (\(moveError.localizedDescription)) and was left in place; Insomnia treats it as no session. Insomnia retries the rename and will not quit until it is gone. Remove it or move it out of \(paths.appSupport.path)."
            )
        }
    }

    /// session.json that could not be read at all, renamed without being
    /// opened; a FIFO or a file without read permission moves the same way.
    /// The restore of a dirty journal reports its own outcome.
    private func moveAsideSessionThatCannotBeRead(_ detail: String) {
        let expired = "session.json could not be read (\(detail)), so its end time is unknown. Insomnia treats the session as expired and undoes what its journal recorded."
        do {
            let moved = try store.moveAsideUnreadableSession(now: clock())
            Log.error("session.json could not be read (\(detail)); treated as expired and moved, unopened, to \(moved.path)")
            notifier.post(title: Self.sessionFileTitle, body: "\(expired) The file was moved, unopened, to \(moved.path).")
        } catch let moveError {
            // Kept, not deleted. A start is refused while it is there, and
            // every end restores the journal, tries the rename again, and
            // stays unfinished while it fails.
            keptSessionFile = .cannotBeRead
            fail("session.json could not be read (\(detail)) and could not be moved aside: \(moveError.localizedDescription); treated as expired and left in place")
            notifier.post(
                title: Self.sessionFileTitle,
                body: "\(expired) The file could not be moved aside (\(moveError.localizedDescription)) and was left in place. If it became readable there, a relaunch would resume it, so Insomnia retries the rename and will not quit until it is gone. Remove it or move it out of \(paths.appSupport.path)."
            )
        }
    }

    /// An end's second try at renaming a session.json reconcile could not
    /// move aside. The rename never opens it. Nil once nothing is left at
    /// session.json (renamed now, or removed by a person); otherwise why it
    /// is still there.
    private func retryMovingAsideKeptSessionFile(_ kept: KeptSessionFile) -> String? {
        let which = kept == .cannotBeRead ? "could not be read" : "is not a session"
        guard store.sessionEntryExists() else {
            keptSessionFile = nil
            Log.info("session.json that \(which) is gone")
            return nil
        }
        do {
            let moved = try store.moveAsideUnreadableSession(now: clock())
            keptSessionFile = nil
            switch kept {
            case .cannotBeRead:
                Log.info("session.json that could not be read moved, unopened, to \(moved.path)")
                notifier.post(title: Self.sessionFileTitle, body: "session.json, which could not be read, was moved, unopened, to \(moved.path).")
            case .notASession:
                Log.info("session.json that is not a session moved to \(moved.path)")
                notifier.post(title: Self.sessionFileTitle, body: "session.json, which is not a valid session file, was moved to \(moved.path).")
            }
            return nil
        } catch {
            switch kept {
            case .cannotBeRead:
                fail("session.json could not be read and still could not be moved aside: \(error.localizedDescription)")
                return "session.json could not be read or moved aside (\(error.localizedDescription)). If it became readable where it is, a relaunch would resume it and hold sleep again. Remove it or move it out of \(paths.appSupport.path)."
            case .notASession:
                fail("session.json is not a session and still could not be moved aside: \(error.localizedDescription); left in place")
                return "session.json is not a valid session file and could not be moved aside (\(error.localizedDescription)). Where it is, every launch and the recovery agent read it again. Remove it or move it out of \(paths.appSupport.path)."
            }
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
            Task { @MainActor in self?.refreshCountdown() }
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

    /// Logs `message` and shows it in the status menu until the next
    /// success clears it.
    func fail(_ message: String) {
        lastError = message
        Log.error(message)
    }

    /// The guard refuses this device on this Mac, so this build cannot
    /// write the saved value. It stays journaled, since an entry is cleared
    /// only after its undo, and is flagged so it stops counting as dirty:
    /// no retry, backstop run or end on this build can restore it, and
    /// counting it would post "Restore incomplete" at every end and launch,
    /// fail the backstop every minute and stop uninstall.sh. The app tries
    /// again at every lid open and launch, so a build or macOS that can
    /// make the call restores it then. Returns the device's line for the
    /// message the caller posts, which tells the user each time.
    private func keepRefusedRestore(_ what: String, saved: Float, why: String, flag: WritableKeyPath<RuntimeState, Bool>) -> String {
        let line = "\(what) \(saved): \(why)."
        guard !state[keyPath: flag] else { return line }
        do {
            try journal { $0[keyPath: flag] = true }
            return line
        } catch {
            return "\(what) \(saved): \(why); it could not be marked as refused (\(error.localizedDescription)), so it still counts as not restored."
        }
    }

    private enum KeptLevel {
        /// Still 0 as the close left it: the kept value is written.
        case dark
        /// Above 0: set since, and left as it is.
        case setSince(Float)
        /// Nothing to go on yet: the entry waits.
        case undecided(String)
    }

    /// A value kept after a refused restore, on a build whose guard allows
    /// the call. The user was told to set the level by hand, and the close
    /// left the device at 0, so a reading above 0 is a level set since: the
    /// darkening is already undone, and the old value would overwrite that
    /// choice. Only a reading macOS is not holding down decides. A display
    /// asleep reads its idle-dim value, and a keyboard backlight suppressed
    /// after the wake, or idle-dimmed, reads 0 whatever its level. Such a
    /// reading decides nothing, and neither does a read that fails or a
    /// keyboard that reads as absent: the entry stays as it is and is read
    /// again (see scheduleKeptRecheck). `untrusted` is asked before and
    /// after the read, so a device macOS took over in between does not
    /// count either. Nor does any reading while the lid is not known to be
    /// open: the closed lid left the device at 0 or macOS turned it off,
    /// and a write would light what the close keeps dark. An end or launch
    /// under a closed lid leaves the entry to the re-read, which waits for
    /// the lid to open.
    private func keptLevel(read: () throws -> Float?, untrusted: () -> String?) -> KeptLevel {
        guard clamshell() == false else { return .undecided("the lid is not known to be open") }
        if let why = untrusted() { return .undecided(why) }
        let now: Float?
        do {
            now = try read()
        } catch {
            return .undecided("it could not be read (\(error.localizedDescription))")
        }
        if let why = untrusted() { return .undecided(why) }
        guard let now else { return .undecided("it reads as absent") }
        return now > 0 ? .setSince(now) : .dark
    }

    /// The level was set since the refused restore: the entry is done, and
    /// is cleared without a write. Returns false if the journal cannot be
    /// written: the entry stays on disk, waits, and only its clear is
    /// retried (see `keptDisplayClearOwed`).
    private func clearSetSince(_ what: String, saved: Float, now: Float, waiting: inout [String], errors: inout [String], clear: (inout RuntimeState) -> Void) -> Bool {
        Log.info("\(what) reads \(now), set since its restore to \(saved) was refused; left as set, and the saved value cleared")
        do {
            try journal(clear)
            return true
        } catch {
            errors.append("\(what) was set since its restore was refused, but the saved value could not be cleared: \(error.localizedDescription); it will be retried")
            waiting.append("\(what) \(saved), set since its refused restore, still to be cleared from the journal")
            return false
        }
    }

    /// A clear that failed after the level was found set since, tried
    /// again with no read and no write. Returns true once it lands.
    private func retryClear(_ what: String, saved: Float, waiting: inout [String], clear: (inout RuntimeState) -> Void) -> Bool {
        do {
            try journal(clear)
            Log.info("\(what) \(saved), set since its refused restore, cleared from the journal")
            return true
        } catch {
            waiting.append("\(what) \(saved), set since its refused restore, still to be cleared from the journal (\(error.localizedDescription))")
            return false
        }
    }

    /// A value kept after a refusal that this build may write after all,
    /// and the write failed: it is retried like any failed restore from
    /// now on, so the flag goes. If the flag cannot be cleared, an end
    /// still counts the entry, through `keptRestoreFailed`.
    private func makeRetryable(_ what: String, flag: WritableKeyPath<RuntimeState, Bool>, errors: inout [String]) {
        guard state[keyPath: flag] else { return }
        do {
            try journal { $0[keyPath: flag] = false }
        } catch {
            keptRestoreFailed = true
            errors.append("could not mark the \(what) for retry: \(error.localizedDescription); it still counts as not restored")
        }
    }

    private func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    static let incompleteTitle = "Restore incomplete"
    static let notEndedTitle = "Session not ended"
    static let journalTitle = "Recovery journal unreadable"
    static let sessionFileTitle = "Session file unreadable"
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
        case .recoveryUnavailable: "Insomnia could not arm its recovery agent for the session found on disk, so it ended the session. Sleep is back to normal."
        case .startFailed: "Insomnia could not disable sleep, so no session was started. Sleep is back to normal."
        }
    }
}
